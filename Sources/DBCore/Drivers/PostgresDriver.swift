import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

public enum PostgresDriver {
    public static func connect(_ profile: ConnectionProfile, password: String?, serverName: String? = nil) async throws -> any DatabaseDriver {
        var tls = TLSConfiguration.makeClientConfiguration()
        if let r = profile.sslRootCert { tls.trustRoots = .file(r) }
        let mode: PostgresConnection.Configuration.TLS
        do {
            switch profile.sslMode {
            case .disable: mode = .disable
            case .prefer: tls.certificateVerification = .none; mode = .prefer(try NIOSSLContext(configuration: tls))
            case .require: tls.certificateVerification = .none; mode = .require(try NIOSSLContext(configuration: tls))
            case .verifyFull: mode = .require(try NIOSSLContext(configuration: tls))
            }
        } catch { throw DBError.connection("TLS setup failed: \(error)") }
        var config = PostgresConnection.Configuration(host: profile.host, port: profile.port, username: profile.user, password: password, database: profile.database.isEmpty ? nil : profile.database, tls: mode)
        if let serverName { config.options.tlsServerName = serverName } // through an SSH tunnel: verify the database's name, not 127.0.0.1
        let driver = PGDriver(config: config)
        try await driver.open()
        return driver
    }
}

private final class RowBox: @unchecked Sendable { var cols: [String] = []; var rows: [[Cell]] = []; var truncated = false }

final class PGDriver: DatabaseDriver, @unchecked Sendable {
    let engine: Engine = .postgres
    private let config: PostgresConnection.Configuration
    private let logger = Logger(label: "dbman.postgres")
    private var conn: PostgresConnection?
    private var pid: Int64 = 0
    private var cursorCounter = 0
    private let gate = SerialGate()

    init(config: PostgresConnection.Configuration) { self.config = config }

    func open() async throws {
        do {
            conn = try await PostgresConnection.connect(configuration: config, id: 1, logger: logger)
        } catch { throw DBError.connection(Self.message(error)) }
        if case .integer(let p)? = try await run("SELECT pg_backend_pid()", limit: 1).rows.first?.first { pid = p }
    }

    static func message(_ e: Error) -> String {
        guard let p = e as? PSQLError else { return "\(e)" }
        if let m = p.serverInfo?[.message] { return m }
        return p.underlying.map { "\($0)" } ?? p.code.description
    }

    private func wrap(_ e: Error) -> DBError {
        if let e = e as? DBError { return e }
        let code = (e as? PSQLError)?.serverInfo?[.sqlState]
        if code == "57014" { return .cancelled }
        return .query(Self.message(e), code: code)
    }

    // MARK: cell mapping

    static func cell(_ c: PostgresCell) -> Cell {
        guard c.bytes != nil else { return .null }
        let ctx = PostgresDecodingContext.default
        func d<T: PostgresDecodable>(_ t: T.Type) -> T? { try? c.decode(t, context: ctx) }
        switch c.dataType {
        case .int2, .int4, .int8, .oid: if let v = d(Int64.self) { return .integer(v) }
        case .float4, .float8: if let v = d(Double.self) { return .real(v) }
        case .numeric: if let v = d(Decimal.self) { return .real(NSDecimalNumber(decimal: v).doubleValue) }
        case .bool: if let v = d(Bool.self) { return .bool(v) }
        case .uuid: if let v = d(UUID.self) { return .text(v.uuidString.lowercased()) }
        case .date, .timestamp, .timestamptz: if let v = d(Date.self) { return .date(v) }
        case .bytea: return .blob(c.bytes?.readableBytes ?? 0)
        case .text, .varchar, .bpchar, .name, .json, .jsonb: if let v = d(String.self) { return .text(v) }
        default: break
        }
        if let v = d(String.self) { return .text(v) }
        for arr in [d([String].self).map { $0 }, d([Int64].self).map { $0.map(String.init) }, d([Double].self).map { $0.map { String($0) } }, d([Bool].self).map { $0.map(String.init) }] {
            if let arr { return .text("{" + arr.joined(separator: ",") + "}") }
        }
        // shortcut: other binary types (time, interval, ranges, ...) show as raw text/bytes, add decoders as needed
        var b = c.bytes
        let len = b?.readableBytes ?? 0
        if let s = b?.readString(length: len), !s.unicodeScalars.contains(where: { $0.value < 9 }) { return .text(s) }
        return .blob(c.bytes?.readableBytes ?? 0)
    }

    // MARK: running

    private func run(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let conn else { throw DBError.connection("Connection is closed") }
        let box = RowBox()
        let start = Date()
        do {
            let meta = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: logger) { row in
                if limit > 0 && box.rows.count >= limit { box.truncated = true; return }
                var cells: [Cell] = []
                for c in row {
                    if box.rows.isEmpty { box.cols.append(c.columnName) }
                    cells.append(Self.cell(c))
                }
                box.rows.append(cells)
            }.get()
            return QueryResult(columns: box.cols, rows: box.rows, rowsAffected: box.cols.isEmpty ? (meta.rows ?? 0) : box.rows.count,
                               elapsedMs: Date().timeIntervalSince(start) * 1000, truncated: box.truncated)
        } catch { throw wrap(error) }
    }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult { try await gate.run { try await self.runAll(sql, limit: limit) } }

    /// A READ ONLY transaction can't be flipped by set_config/SET once started, unlike a session default.
    func executeReadOnly(_ sql: String, limit: Int) async throws -> QueryResult {
        try await gate.run {
            _ = try await self.run("BEGIN READ ONLY", limit: 0)
            do { let r = try await self.runAll(sql, limit: limit); _ = try? await self.run("ROLLBACK", limit: 0); return r }
            catch { _ = try? await self.run("ROLLBACK", limit: 0); throw error }
        }
    }

    private func gated(_ sql: String, limit: Int) async throws -> QueryResult { try await gate.run { try await self.run(sql, limit: limit) } }

    private func runAll(_ sql: String, limit: Int) async throws -> QueryResult {
        // shortcut: a SELECT matching zero rows reports no column names (PostgresNIO exposes them only on rows)
        let start = Date()
        var result = QueryResult()
        var affected = 0
        for stmt in splitStatements(sql) {
            let r = try await run(stmt, limit: limit)
            if r.columns.isEmpty { affected += r.rowsAffected; if result.columns.isEmpty { result = r; result.rowsAffected = affected } }
            else { result = r }
        }
        result.elapsedMs = Date().timeIntervalSince(start) * 1000
        return result
    }

    func stream(_ sql: String, pageSize: Int) -> AsyncThrowingStream<RowPage, Error> {
        cursorCounter += 1
        let name = "dbman_c\(cursorCounter)_\(UInt32.random(in: 0...UInt32.max))"
        let size = max(pageSize, 1)
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        return AsyncThrowingStream { cont in
            let task = Task {
                var declared = false
                do {
                    // WITH HOLD keeps the cursor usable outside a transaction so other queries can interleave.
                    _ = try await gated("DECLARE \(name) NO SCROLL CURSOR WITH HOLD FOR \(body)", limit: 0)
                    declared = true
                    while !Task.isCancelled {
                        let r = try await gated("FETCH FORWARD \(size) FROM \(name)", limit: 0)
                        let last = r.rows.count < size
                        cont.yield(RowPage(columns: r.columns, rows: r.rows, isLast: last))
                        if last { break }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
                if declared { _ = try? await gated("CLOSE \(name)", limit: 0) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: schema

    func schema() async throws -> SchemaSnapshot { try await schema(progress: nil) }

    /// The catalogue is read in five queries; `progress` hears about each part as it lands.
    func schema(progress: SchemaProgress?) async throws -> SchemaSnapshot {
        progress?("reading tables (1/5)")
        func s(_ c: Cell?) -> String? { if case .text(let v)? = c { return v } else { return nil } }
        func n(_ c: Cell?) -> Int64? { if case .integer(let v)? = c { return v } else { return nil } }
        let ns = "n.nspname = current_schema()"
        let tableRows = try await run("""
            SELECT c.relname::text, c.relkind::text, c.reltuples::bigint, pg_total_relation_size(c.oid) FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace WHERE \(ns) AND c.relkind IN ('r','p','v','m') ORDER BY 1
            """, limit: 0).rows
        progress?("\(tableRows.count.formatted()) tables · reading columns (2/5)")
        let colRows = try await run("""
            SELECT c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
            FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE \(ns) AND c.relkind IN ('r','p','v','m') AND a.attnum > 0 AND NOT a.attisdropped ORDER BY c.relname, a.attnum
            """, limit: 0).rows
        progress?("\(tableRows.count.formatted()) tables · \(colRows.count.formatted()) columns · reading primary keys (3/5)")
        let pkRows = try await run("""
            SELECT c.relname::text, a.attname::text FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL unnest(con.conkey) AS k(attnum)
            JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum WHERE \(ns) AND con.contype = 'p'
            """, limit: 0).rows
        progress?("\(tableRows.count.formatted()) tables · \(colRows.count.formatted()) columns · reading foreign keys (4/5)")
        let fkRows = try await run("""
            SELECT c.relname::text, a.attname::text, fc.relname::text, fa.attname::text, con.confdeltype::text
            FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class fc ON fc.oid = con.confrelid CROSS JOIN LATERAL unnest(con.conkey, con.confkey) AS k(attnum, fattnum)
            JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
            JOIN pg_attribute fa ON fa.attrelid = con.confrelid AND fa.attnum = k.fattnum WHERE \(ns) AND con.contype = 'f'
            """, limit: 0).rows
        progress?("\(tableRows.count.formatted()) tables · \(colRows.count.formatted()) columns · \(fkRows.count.formatted()) foreign keys · reading indexes (5/5)")
        let idxRows = try await run("""
            SELECT t.relname::text, i.relname::text, ix.indisunique, pg_get_indexdef(ix.indexrelid), pg_relation_size(ix.indexrelid),
              (SELECT string_agg(a.attname::text, ',' ORDER BY k.ord) FROM unnest(ix.indkey) WITH ORDINALITY k(attnum, ord)
                 JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum)
            FROM pg_index ix JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace WHERE \(ns) ORDER BY 1, 2
            """, limit: 0).rows
        let pks = Set(pkRows.compactMap { r in s(r[0]).flatMap { t in s(r[1]).map { "\(t).\($0)" } } })
        var fks: [String: ForeignKey] = [:]
        let actions = ["a": "NO ACTION", "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL", "d": "SET DEFAULT"]
        for r in fkRows { if let t = s(r[0]), let c = s(r[1]), let ft = s(r[2]), let fc = s(r[3]) { fks["\(t).\(c)"] = ForeignKey(table: ft, column: fc, onDelete: s(r[4]).flatMap { actions[$0] }) } }

        var tables: [TableInfo] = []
        // never-analysed tables have no estimate (reltuples = -1): they are counted exactly, one by one, so say which
        let uncounted = tableRows.filter { (n($0[2]) ?? -1) < 0 && s($0[1]) != "v" }.count
        var counted = 0
        for r in tableRows {
            guard let name = s(r[0]) else { continue }
            let isView = s(r[1]) == "v"
            var rows = n(r[2]) ?? -1
            if rows < 0 && !isView {
                counted += 1
                progress?("\(tableRows.count.formatted()) tables · counting rows of \(name) (\(counted)/\(uncounted) never analysed)")
                let q = quoteIdent(name, .postgres)
                rows = n(try await run("SELECT count(*) FROM \(q)", limit: 1).rows.first?.first) ?? 0
            }
            let cols = colRows.compactMap { c -> ColumnInfo? in
                guard s(c[0]) == name, let cn = s(c[1]) else { return nil }
                var nullable = true; if case .bool(let b) = c[3] { nullable = b }
                return ColumnInfo(name: cn, type: s(c[2]) ?? "", nullable: nullable, defaultValue: s(c[4]), isPrimaryKey: pks.contains("\(name).\(cn)"), foreignKey: fks["\(name).\(cn)"])
            }
            let idx = idxRows.compactMap { i -> IndexInfo? in
                guard s(i[0]) == name, let iname = s(i[1]) else { return nil }
                var uniq = false; if case .bool(let b) = i[2] { uniq = b }
                return IndexInfo(name: iname, columns: (s(i[5]) ?? "").split(separator: ",").map(String.init), unique: uniq, definition: s(i[3]) ?? "", sizeBytes: n(i[4]))
            }
            tables.append(TableInfo(schema: "public", name: name, kind: isView ? .view : .table, rowCount: max(rows, 0), sizeBytes: n(r[3]), columns: cols, indexes: idx))
        }
        progress?("\(tableRows.count.formatted()) tables · \(colRows.count.formatted()) columns · database size")
        let meta = try await run("SELECT current_database()::text, current_setting('server_version'), pg_database_size(current_database())", limit: 1).rows.first ?? []
        return SchemaSnapshot(serverVersion: "PostgreSQL " + (s(meta.dropFirst().first) ?? ""), databaseName: s(meta.first) ?? "", tables: tables, sizeBytes: n(meta.last))
    }

    // MARK: explain

    func explain(_ sql: String, analyze: Bool) async throws -> PlanNode? {
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        let r = try await run("EXPLAIN (ANALYZE \(analyze), FORMAT JSON) \(body)", limit: 1)
        guard case .text(let json)? = r.rows.first?.first,
              let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]],
              let plan = arr.first?["Plan"] as? [String: Any] else { return nil }
        return Self.node(plan)
    }

    static func node(_ p: [String: Any]) -> PlanNode {
        func num(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        let kids = (p["Plans"] as? [[String: Any]] ?? []).map(node)
        var total: Double?
        if let t = num("Actual Total Time") { total = t * (num("Actual Loops") ?? 1) }
        let selfMs = total.map { max(0, $0 - kids.reduce(0) { $0 + ($1.totalMs ?? 0) }) }
        var detail: String? = (p["Index Name"] as? String).map { "using " + $0 }
        if detail == nil { detail = p["Join Type"] as? String }
        return PlanNode(operation: p["Node Type"] as? String ?? "?", relation: p["Relation Name"] as? String, detail: detail,
                        estimatedRows: num("Plan Rows") ?? 0, actualRows: num("Actual Rows"), totalMs: total, selfMs: selfMs,
                        cost: num("Total Cost") ?? 0, children: kids)
    }

    // MARK: lifecycle

    func cancelCurrent() async {
        guard pid != 0, let other = try? await PostgresConnection.connect(configuration: config, id: 2, logger: logger) else { return }
        _ = try? await other.query(PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(pid))"), logger: logger)
        try? await other.close()
    }

    func close() async {
        try? await conn?.close()
        conn = nil
    }
}
