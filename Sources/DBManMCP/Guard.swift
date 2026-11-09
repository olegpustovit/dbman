import DBCore
import Foundation

/// A typed, human-readable tool error: `CODE (detail)` (SPEC §2). `status` is what the activity row records.
struct ToolError: Error {
    var code: String, detail: String, status: String
    init(_ code: String, _ detail: String, status: String = "error") { self.code = code; self.detail = detail; self.status = status }
    var message: String { "\(code) (\(detail))" }
}

/// Pure rules: what an agent may run, what it must not see, when production says no.
enum Rules {
    enum Kind { case read, write, other }

    static func classify(_ sql: String) -> Kind {
        let k = SQLClassifier.firstKeyword(sql)
        if ["SELECT", "WITH", "VALUES", "TABLE", "SHOW", "DESCRIBE", "DESC"].contains(k) { return .read }
        let more: Set = ["MERGE", "CALL", "COPY", "SET", "LOCK", "ATTACH", "DETACH", "PRAGMA", "DO", "REINDEX", "ANALYZE", "REFRESH", "COMMENT", "CLUSTER", "EXEC", "EXECUTE"]
        return SQLClassifier.isWrite(sql) || more.contains(k) ? .write : .other
    }

    /// Case-insensitive substring match of `patterns` on column names. shortcut: names only, never values or comments; upgrade with a value sampler.
    static func sensitive(_ schema: SchemaSnapshot, patterns: [String]) -> [(table: String, column: String)] {
        let ps = patterns.map { $0.lowercased() }
        return schema.tables.flatMap { t in t.columns.filter { c in ps.contains { c.name.lowercased().contains($0) } }.map { (t.name, $0.name) } }
    }

    static let redacted = Cell.text("«redacted»")
    /// shortcut: projection by result column name, so `select email as e` or `email || ''` slip through; upgrade with SQL column lineage.
    static func redact(columns: [String], rows: [[Cell]], hidden: Set<String>) -> [[Cell]] {
        let idx = Set(columns.indices.filter { hidden.contains(columns[$0].lowercased()) })
        guard !idx.isEmpty else { return rows }
        return rows.map { r in r.enumerated().map { idx.contains($0.offset) ? redacted : $0.element } }
    }

    /// Reason to block a production query, or nil. Cost comes from the plan root (Postgres total cost, MySQL query_cost); SQLite has no cost,
    /// so only the seq-scan rule applies there, using the schema's row counts. Nothing below a Limit counts: it bounds the scan.
    static func prodVerdict(_ plan: PlanNode, schema: SchemaSnapshot, maxCost: Double, maxRows: Double) -> String? {
        var worst: (table: String, rows: Double)?
        func walk(_ n: PlanNode) {
            if n.operation == "Limit" { return }
            let seq = n.operation.hasSuffix("Seq Scan") || n.operation == "Table Scan" || (n.operation == "SCAN" && !(n.detail ?? "").contains("INDEX"))
            if seq, let rel = n.relation {
                let rows = schema.table(rel).map { Double($0.rowCount) } ?? n.estimatedRows
                if rows > (worst?.rows ?? -1) { worst = (rel, rows) }
            }
            n.children.forEach(walk)
        }
        walk(plan)
        let costly = plan.cost > maxCost, bigScan = (worst?.rows ?? 0) > maxRows
        guard costly || bigScan else { return nil }
        var parts: [String] = []
        if let w = worst { parts.append("seq scan on \(w.table), \(Int(w.rows).formatted(.number.locale(Locale(identifier: "en_US")))) rows") }
        if plan.cost > 0 { parts.append("est. cost " + sci(plan.cost)) }
        return parts.joined(separator: " ")
    }

    private static func sci(_ c: Double) -> String {
        guard c >= 1000 else { return String(format: "%.0f", c) }
        let e = Int(floor(log10(c)))
        return String(format: "%.1fe%d", c / pow(10, Double(e)), e)
    }
}

/// Opaque continuation for `query.run`. shortcut: offset-based, so the statement re-runs per page and rows can shift if data changes; upgrade to a server-side cursor.
struct Cursor: Codable {
    var sql: String, offset: Int
    var token: String { (try? JSONEncoder().encode(self))?.base64EncodedString() ?? "" }
    init(sql: String, offset: Int) { self.sql = sql; self.offset = offset }
    init?(token: String) {
        guard let d = Data(base64Encoded: token), let c = try? JSONDecoder().decode(Cursor.self, from: d), c.offset >= 0 else { return nil }
        self = c
    }
}
