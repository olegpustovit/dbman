import Foundation
import SQLite3

/// Parses ISO-ish date text ("2024-05-01", "2024-05-01 12:30:00", "...T12:30:00Z").
func parseISODate(_ s: String) -> Date? {
    guard s.count >= 10, s.count <= 35, s.first?.isNumber == true else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    if s.count == 10 { return f.date(from: s) }
    var t = s.replacingOccurrences(of: " ", with: "T")
    if !t.hasSuffix("Z") && t.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil { t += "Z" }
    for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
        f.formatOptions = opts
        if let d = f.date(from: t) { return d }
    }
    return nil
}

public final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    public let engine: Engine = .sqlite
    private let queue = DispatchQueue(label: "dbman.sqlite")
    private var db: OpaquePointer?
    private let path: String

    public init(path: String, readOnly: Bool) throws {
        self.path = path
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw DBError.connection("Cannot open \(path): \(msg)")
        }
        db = h
        sqlite3_busy_timeout(h, 2000) // the internal store (unlocked) is also written by agent activity logging: wait instead of SQLITE_BUSY
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: plumbing

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func fail(_ rc: Int32) -> DBError {
        if rc == SQLITE_INTERRUPT { return .cancelled }
        guard let db else { return .connection("Database is closed") }
        return .query(String(cString: sqlite3_errmsg(db)), code: String(sqlite3_extended_errcode(db)))
    }

    private func cell(_ st: OpaquePointer, _ i: Int32) -> Cell {
        switch sqlite3_column_type(st, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(st, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(st, i))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(st, i)))
        case SQLITE_NULL: return .null
        default:
            guard let p = sqlite3_column_text(st, i) else { return .null }
            let s = String(cString: p)
            if let decl = sqlite3_column_decltype(st, i) {
                let d = String(cString: decl).uppercased()
                if d.contains("DATE") || d.contains("TIMESTAMP"), let date = parseISODate(s) { return .date(date) }
            }
            return .text(s)
        }
    }

    private func columns(_ st: OpaquePointer) -> [String] {
        (0..<sqlite3_column_count(st)).map { String(cString: sqlite3_column_name(st, $0)) }
    }

    /// Runs a query with its own statement and returns all rows (internal helper for introspection). Queue-only.
    private func rows(_ sql: String) throws -> [[Cell]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw fail(sqlite3_errcode(db)) }
        defer { sqlite3_finalize(st) }
        var out: [[Cell]] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW, let st else { throw fail(rc) }
            out.append((0..<sqlite3_column_count(st)).map { cell(st, $0) })
        }
    }

    // MARK: DatabaseDriver

    public func execute(_ sql: String, limit: Int) async throws -> QueryResult { try await onQueue { [self] in try runAll(sql, limit: limit) } }

    /// query_only on for the call, then back to whatever the session had (a locked session stays locked).
    public func executeReadOnly(_ sql: String, limit: Int) async throws -> QueryResult {
        try await onQueue { [self] in
            let was = try rows("PRAGMA query_only").first?.first
            _ = try rows("PRAGMA query_only = 1")
            defer { _ = try? rows("PRAGMA query_only = \(was == .integer(0) ? 0 : 1)") }
            return try runAll(sql, limit: limit)
        }
    }

    private func runAll(_ sql: String, limit: Int) throws -> QueryResult {
        let start = Date()
        var result = QueryResult()
        var affected = 0
        try sql.withCString { base in
            var cursor: UnsafePointer<CChar>? = base
            while let cur = cursor, cur.pointee != 0 {
                var st: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(db, cur, -1, &st, &tail)
                guard rc == SQLITE_OK else { throw fail(rc) }
                cursor = tail
                guard let st else { continue } // whitespace/comment only
                defer { sqlite3_finalize(st) }
                let cols = columns(st)
                var out: [[Cell]] = []
                var truncated = false
                while true {
                    let rc = sqlite3_step(st)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw fail(rc) }
                    if limit > 0 && out.count >= limit { truncated = true; break }
                    out.append((0..<Int32(cols.count)).map { cell(st, $0) })
                }
                if cols.isEmpty { affected = Int(sqlite3_changes(db)) }
                else { result = QueryResult(columns: cols, rows: out, truncated: truncated); affected = 0 }
            }
        }
        result.rowsAffected = result.columns.isEmpty ? affected : result.rows.count
        result.elapsedMs = Date().timeIntervalSince(start) * 1000
        return result
    }

    public func stream(_ sql: String, pageSize: Int) -> AsyncThrowingStream<RowPage, Error> {
        let stop = StopFlag()
        return AsyncThrowingStream { cont in
            cont.onTermination = { _ in stop.value = true }
            queue.async { [self] in
                var st: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
                    cont.finish(throwing: fail(sqlite3_errcode(db))); return
                }
                defer { sqlite3_finalize(st) }
                let cols = columns(st)
                let size = max(pageSize, 1)
                while !stop.value {
                    var page: [[Cell]] = []
                    var done = false
                    while page.count < size {
                        let rc = sqlite3_step(st)
                        if rc == SQLITE_DONE { done = true; break }
                        guard rc == SQLITE_ROW else { cont.finish(throwing: fail(rc)); return }
                        page.append((0..<Int32(cols.count)).map { cell(st, $0) })
                    }
                    cont.yield(RowPage(columns: cols, rows: page, isLast: done))
                    if done { cont.finish(); return }
                }
            }
        }
    }

    public func schema() async throws -> SchemaSnapshot {
        try await onQueue { [self] in
            let version = String(cString: sqlite3_libversion())
            var tables: [TableInfo] = []
            let master = try rows("SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
            for m in master {
                guard case .text(let name) = m[0], case .text(let type) = m[1] else { continue }
                let q = "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
                var fks: [String: ForeignKey] = [:]
                for r in try rows("PRAGMA foreign_key_list(\(q))") {
                    if case .text(let t) = r[2], case .text(let from) = r[3] {
                        var to = ""; if case .text(let x) = r[4] { to = x }
                        var od: String?; if case .text(let x) = r[6] { od = x }
                        fks[from] = ForeignKey(table: t, column: to, onDelete: od)
                    }
                }
                var cols: [ColumnInfo] = []
                for r in try rows("PRAGMA table_info(\(q))") {
                    guard case .text(let cn) = r[1] else { continue }
                    var ty = ""; if case .text(let x) = r[2] { ty = x }
                    var nn = 0; if case .integer(let x) = r[3] { nn = Int(x) }
                    var pk = 0; if case .integer(let x) = r[5] { pk = Int(x) }
                    var dv: String?; if case .text(let x) = r[4] { dv = x }
                    cols.append(ColumnInfo(name: cn, type: ty, nullable: nn == 0 && pk == 0, defaultValue: dv, isPrimaryKey: pk > 0, foreignKey: fks[cn]))
                }
                var idx: [IndexInfo] = []
                if type == "table" {
                    for r in try rows("PRAGMA index_list(\(q))") {
                        guard case .text(let iname) = r[1] else { continue }
                        var uniq = false; if case .integer(let x) = r[2] { uniq = x != 0 }
                        let iq = "'" + iname.replacingOccurrences(of: "'", with: "''") + "'"
                        let icols: [String] = try rows("PRAGMA index_info(\(iq))").compactMap { if case .text(let c) = $0[2] { return c } else { return nil } }
                        var def = "(auto) " + icols.joined(separator: ", ")
                        if let s = try rows("SELECT sql FROM sqlite_master WHERE name = \(iq)").first?.first, case .text(let sql) = s { def = sql }
                        idx.append(IndexInfo(name: iname, columns: icols, unique: uniq, definition: def))
                    }
                }
                var count: Int64 = 0
                if type == "table", let c = try rows("SELECT COUNT(*) FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"").first?.first, case .integer(let n) = c { count = n }
                tables.append(TableInfo(schema: "main", name: name, kind: type == "view" ? .view : .table, rowCount: count, columns: cols, indexes: idx))
            }
            var size: Int64?
            if case .integer(let pc)? = try rows("PRAGMA page_count").first?.first, case .integer(let ps)? = try rows("PRAGMA page_size").first?.first { size = pc * ps }
            return SchemaSnapshot(serverVersion: "SQLite " + version, databaseName: URL(fileURLWithPath: path).lastPathComponent, tables: tables, sizeBytes: size)
        }
    }

    public func explain(_ sql: String, analyze: Bool) async throws -> PlanNode? {
        // shortcut: SQLite has no ANALYZE plan, only the query plan; estimates are 0
        let plan = try await onQueue { [self] in try rows("EXPLAIN QUERY PLAN " + sql) }
        struct Raw { var id: Int64; var parent: Int64; var text: String }
        let raws: [Raw] = plan.compactMap {
            guard case .integer(let id) = $0[0], case .integer(let p) = $0[1], case .text(let t) = $0[3] else { return nil }
            return Raw(id: id, parent: p, text: t)
        }
        func build(_ r: Raw) -> PlanNode {
            let words = r.text.split(separator: " ", maxSplits: 2).map(String.init)
            var op = r.text, rel: String?, detail: String?
            if let w = words.first, w == "SCAN" || w == "SEARCH", words.count > 1 {
                op = w; rel = words[1]; detail = words.count > 2 ? words[2] : nil
            }
            return PlanNode(operation: op, relation: rel, detail: detail, estimatedRows: 0, cost: 0,
                            children: raws.filter { $0.parent == r.id }.map(build))
        }
        let roots = raws.filter { r in !raws.contains { $0.id == r.parent } }.map(build)
        if roots.count == 1 { return roots[0] }
        return PlanNode(operation: "Query", estimatedRows: 0, cost: 0, children: roots)
    }

    public func cancelCurrent() async { if let db { sqlite3_interrupt(db) } }

    public func close() async {
        queue.sync { if let db { sqlite3_close_v2(db); self.db = nil } }
    }
}

final class StopFlag: @unchecked Sendable { var value = false }
