import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO

public enum MySQLDriver {
    public static func connect(_ profile: ConnectionProfile, password: String?) async throws -> any DatabaseDriver {
        let driver = MyDriver(profile: profile, password: password)
        try await driver.open()
        return driver
    }
}

private final class RowBox: @unchecked Sendable {
    var cols: [String] = []; var rows: [[Cell]] = []; var truncated = false; var affected = 0
}

final class MyDriver: DatabaseDriver, @unchecked Sendable {
    let engine: Engine = .mysql
    private let profile: ConnectionProfile
    private let password: String?
    private let logger = Logger(label: "dbman.mysql")
    private var conn: MySQLConnection?
    private var connectionID: Int64 = 0
    private let gate = SerialGate()

    init(profile: ConnectionProfile, password: String?) { self.profile = profile; self.password = password }

    private func connectNew() async throws -> MySQLConnection {
        var tls: TLSConfiguration? = TLSConfiguration.makeClientConfiguration()
        if let r = profile.sslRootCert { tls?.trustRoots = .file(r) }
        switch profile.sslMode {
        case .disable: tls = nil
        case .prefer, .require: tls?.certificateVerification = .none
        case .verifyFull: break
        }
        do {
            let addr = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
            return try await MySQLConnection.connect(to: addr, username: profile.user, database: profile.database, password: password,
                                                     tlsConfiguration: tls, serverHostname: addr.ipAddress == nil ? profile.host : nil, logger: logger,
                                                     on: MultiThreadedEventLoopGroup.singleton.next()).get()
        } catch { throw DBError.connection(Self.message(error)) }
    }

    func open() async throws {
        conn = try await connectNew()
        if case .integer(let id)? = try await run("SELECT CONNECTION_ID()", limit: 1).rows.first?.first { connectionID = id }
    }

    static func message(_ e: Error) -> String {
        if let m = e as? MySQLError {
            if case .server(let p) = m { return p.errorMessage }
            return m.message
        }
        return "\(e)"
    }

    private func wrap(_ e: Error) -> DBError {
        if let e = e as? DBError { return e }
        if let m = e as? MySQLError, case .server(let p) = m {
            if p.errorCode.rawValue == 1317 { return .cancelled } // ER_QUERY_INTERRUPTED
            return .query(p.errorMessage, code: p.sqlState)
        }
        return .query(Self.message(e))
    }

    static func cell(_ d: MySQLData, _ col: MySQLProtocol.ColumnDefinition41) -> Cell {
        guard d.buffer != nil else { return .null }
        switch col.columnType {
        case .tiny, .short, .long, .longlong, .int24, .year: if let v = d.int64 { return .integer(v) }
        case .float, .double, .decimal, .newdecimal: if let v = d.double { return .real(v) }
        case .date, .datetime, .timestamp, .datetime2, .timestamp2: if let v = d.date { return .date(v) }
        case .tinyBlob, .blob, .mediumBlob, .longBlob, .geometry:
            if col.characterSet == .binary { return .blob(d.buffer?.readableBytes ?? 0) }
        default: break
        }
        return .text(d.string ?? "")
    }

    private func run(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let conn else { throw DBError.connection("Connection is closed") }
        let box = RowBox()
        let start = Date()
        do {
            try await conn.query(sql, onRow: { row in
                if limit > 0 && box.rows.count >= limit { box.truncated = true; return }
                if box.rows.isEmpty { box.cols = row.columnDefinitions.map(\.name) }
                var cells: [Cell] = []
                for (def, v) in zip(row.columnDefinitions, row.values) {
                    cells.append(Self.cell(MySQLData(type: def.columnType, format: row.format, buffer: v, isUnsigned: def.flags.contains(.COLUMN_UNSIGNED)), def))
                }
                box.rows.append(cells)
            }, onMetadata: { box.affected = Int($0.affectedRows) }).get()
        } catch { throw wrap(error) }
        return QueryResult(columns: box.cols, rows: box.rows, rowsAffected: box.cols.isEmpty ? box.affected : box.rows.count,
                           elapsedMs: Date().timeIntervalSince(start) * 1000, truncated: box.truncated)
    }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult { try await gate.run { try await self.runAll(sql, limit: limit) } }

    func executeReadOnly(_ sql: String, limit: Int) async throws -> QueryResult {
        try await gate.run {
            _ = try await self.run("START TRANSACTION READ ONLY", limit: 0)
            do { let r = try await self.runAll(sql, limit: limit); _ = try? await self.run("ROLLBACK", limit: 0); return r }
            catch { _ = try? await self.run("ROLLBACK", limit: 0); throw error }
        }
    }

    private func runAll(_ sql: String, limit: Int) async throws -> QueryResult {
        // shortcut: a SELECT matching zero rows reports no column names (MySQLNIO exposes them only on rows)
        let start = Date()
        var result = QueryResult()
        var affected = 0
        for stmt in splitStatements(sql, mysql: true) {
            let r = try await run(stmt, limit: limit)
            if r.columns.isEmpty { affected += r.rowsAffected; if result.columns.isEmpty { result = r; result.rowsAffected = affected } }
            else { result = r }
        }
        result.elapsedMs = Date().timeIntervalSince(start) * 1000
        return result
    }

    func stream(_ sql: String, pageSize: Int) -> AsyncThrowingStream<RowPage, Error> {
        let size = max(pageSize, 1)
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        // shortcut: LIMIT/OFFSET paging re-runs the query per page; ordering is only stable if the query has ORDER BY
        let hasLimit = body.lowercased().range(of: #"\blimit\b"#, options: .regularExpression) != nil
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var offset = 0
                    while !Task.isCancelled {
                        let paged = hasLimit ? "SELECT * FROM (\(body)) AS _dbman LIMIT \(size) OFFSET \(offset)" : "\(body) LIMIT \(size) OFFSET \(offset)"
                        let r = try await run(paged, limit: 0)
                        let last = r.rows.count < size
                        cont.yield(RowPage(columns: r.columns, rows: r.rows, isLast: last))
                        if last { break }
                        offset += size
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func schema() async throws -> SchemaSnapshot {
        func s(_ c: Cell?) -> String? { if case .text(let v)? = c { return v } else { return nil } }
        func n(_ c: Cell?) -> Int64? {
            switch c { case .integer(let v)?: return v; case .real(let d)?: return Int64(d); case .text(let t)?: return Int64(t); default: return nil }
        }
        let tableRows = try await run("SELECT CAST(TABLE_NAME AS CHAR), CAST(TABLE_TYPE AS CHAR), TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME", limit: 0).rows
        let colRows = try await run("SELECT CAST(TABLE_NAME AS CHAR), CAST(COLUMN_NAME AS CHAR), CAST(COLUMN_TYPE AS CHAR), CAST(IS_NULLABLE AS CHAR), CAST(COLUMN_DEFAULT AS CHAR), CAST(COLUMN_KEY AS CHAR) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION", limit: 0).rows
        let fkRows = try await run("""
            SELECT CAST(k.TABLE_NAME AS CHAR), CAST(k.COLUMN_NAME AS CHAR), CAST(k.REFERENCED_TABLE_NAME AS CHAR), CAST(k.REFERENCED_COLUMN_NAME AS CHAR), CAST(r.DELETE_RULE AS CHAR)
            FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = DATABASE() AND k.REFERENCED_TABLE_NAME IS NOT NULL
            """, limit: 0).rows
        let idxRows = try await run("SELECT CAST(TABLE_NAME AS CHAR), CAST(INDEX_NAME AS CHAR), NON_UNIQUE, CAST(COLUMN_NAME AS CHAR) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX", limit: 0).rows
        var fks: [String: ForeignKey] = [:]
        for r in fkRows { if let t = s(r[0]), let c = s(r[1]), let ft = s(r[2]), let fc = s(r[3]) { fks["\(t).\(c)"] = ForeignKey(table: ft, column: fc, onDelete: s(r[4])) } }

        var tables: [TableInfo] = []
        var total: Int64 = 0
        for r in tableRows {
            guard let name = s(r[0]) else { continue }
            let cols = colRows.compactMap { c -> ColumnInfo? in
                guard s(c[0]) == name, let cn = s(c[1]) else { return nil }
                return ColumnInfo(name: cn, type: s(c[2]) ?? "", nullable: s(c[3]) == "YES", defaultValue: s(c[4]), isPrimaryKey: s(c[5]) == "PRI", foreignKey: fks["\(name).\(cn)"])
            }
            var grouped: [(name: String, unique: Bool, cols: [String])] = []
            for i in idxRows where s(i[0]) == name {
                guard let iname = s(i[1]), let col = s(i[3]) else { continue }
                if let last = grouped.indices.last, grouped[last].name == iname { grouped[last].cols.append(col) }
                else { grouped.append((iname, n(i[2]) == 0, [col])) }
            }
            let idx = grouped.map { g in
                IndexInfo(name: g.name, columns: g.cols, unique: g.unique,
                          definition: "CREATE \(g.unique ? "UNIQUE " : "")INDEX \(quoteIdent(g.name, .mysql)) ON \(quoteIdent(name, .mysql)) (\(g.cols.map { quoteIdent($0, .mysql) }.joined(separator: ", ")))")
            }
            let size = n(r[3])
            total += size ?? 0
            tables.append(TableInfo(schema: profile.database, name: name, kind: s(r[1]) == "VIEW" ? .view : .table, rowCount: n(r[2]) ?? 0, sizeBytes: size, columns: cols, indexes: idx))
        }
        let meta = try await run("SELECT VERSION(), DATABASE()", limit: 1).rows.first ?? []
        return SchemaSnapshot(serverVersion: "MySQL " + (s(meta.first) ?? ""), databaseName: s(meta.last) ?? profile.database, tables: tables, sizeBytes: total)
    }

    func explain(_ sql: String, analyze: Bool) async throws -> PlanNode? {
        // shortcut: ANALYZE not supported (MySQL returns text trees); plan is estimates only
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        let r = try await run("EXPLAIN FORMAT=JSON \(body)", limit: 1)
        guard case .text(let json)? = r.rows.first?.first,
              let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let qb = root["query_block"] as? [String: Any] else { return nil }
        return Self.node(qb, "Query Block")
    }

    /// MySQL: `cost_info`, `rows_examined_per_scan`. MariaDB: `cost`, `rows`, and wrappers (`block-nl-join`, `read_sorted_file`, `filesort`, `temporary_table`) around tables.
    static func node(_ d: [String: Any], _ label: String) -> PlanNode {
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double(v as? String ?? "") ?? 0 }
        let info = d["cost_info"] as? [String: Any]
        let cost = num(info?["query_cost"] ?? info?["prefix_cost"] ?? d["cost"])
        if label == "table" {
            let access = d["access_type"] as? String ?? ""
            return PlanNode(operation: access == "ALL" ? "Table Scan" : "Index " + access, relation: d["table_name"] as? String,
                            detail: (d["key"] as? String).map { "using " + $0 }, estimatedRows: num(d["rows_examined_per_scan"] ?? d["rows"]), cost: cost)
        }
        func kids(_ x: [String: Any]) -> [PlanNode] {
            var out: [PlanNode] = []
            if let t = x["table"] as? [String: Any], t["table_name"] != nil { out.append(node(t, "table")) }
            for k in ["ordering_operation", "grouping_operation", "duplicates_removal", "buffer_result", "windowing", "block-nl-join", "read_sorted_file", "filesort", "temporary_table"] {
                if let sub = x[k] as? [String: Any] { out.append(node(sub, k)) }
            }
            for item in x["nested_loop"] as? [[String: Any]] ?? [] { out += kids(item) }
            return out
        }
        let k = kids(d)
        if k.count == 1 && (d["nested_loop"] as? [Any])?.count == 1 { var only = k[0]; if cost > 0 { only.cost = cost }; return only } // root cost, not the table's prefix cost
        let op = d["nested_loop"] != nil ? "Nested Loop" : label.replacingOccurrences(of: "_", with: " ").capitalized
        return PlanNode(operation: op, estimatedRows: k.first?.estimatedRows ?? 0, cost: cost, children: k)
    }

    func cancelCurrent() async {
        guard connectionID != 0, let other = try? await connectNew() else { return }
        _ = try? await other.query("KILL QUERY \(connectionID)").get()
        try? await other.close().get()
    }

    func close() async {
        try? await conn?.close().get()
        conn = nil
    }
}
