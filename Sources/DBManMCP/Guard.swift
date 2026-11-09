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

    /// Hidden values never leave. A result column named like a hidden column is wholly masked. If the statement also names a hidden column
    /// anywhere (`email as e`, `lower(email)`, `email || ''`, a subquery), every text/blob cell is masked except columns that are provably a
    /// plain, non-hidden column of the outer SELECT; numbers, booleans and NULLs pass so COUNT/SUM still work. `SELECT *` alone keeps the name match.
    static func redact(sql: String, mysql: Bool = false, columns: [String], rows: [[Cell]], hidden: Set<String>) -> [[Cell]] {
        guard !hidden.isEmpty else { return rows }
        let byName = Set(columns.indices.filter { hidden.contains(columns[$0].lowercased()) })
        let toks = sqlTokens(sql, mysql: mysql)
        var scrub = Set<Int>()
        let wholeRow = hasWholeRowRef(toks)
        if wholeRow || toks.contains(where: { $0.isIdentifier && hidden.contains($0.text.lowercased()) }) {
            let flat = toks.filter { $0.isWord("SELECT") }.count == 1 // a subquery or CTE can alias a hidden column into a plain-looking name
            let items = flat ? selectItems(toks) : nil
            let starOnly = items?.allSatisfy { $0.last?.isPunct("*") == true } == true
            if !starOnly {
                var plain = Set<Int>()
                if !wholeRow, let items, items.count == columns.count { plain = Set(items.indices.filter { isPlainColumn(items[$0], hidden: hidden) }) }
                scrub = Set(columns.indices).subtracting(plain)
            }
        }
        guard !byName.isEmpty || !scrub.isEmpty else { return rows }
        return rows.map { r in
            r.enumerated().map { i, c in
                if byName.contains(i) { return redacted }
                guard scrub.contains(i) else { return c }
                switch c { case .text, .blob, .date: return redacted; default: return c }
            }
        }
    }

    /// `to_jsonb(c)`, `row_to_json(c)`, `select c from customers c`: a FROM/JOIN table or alias used bare carries every column, hidden ones included.
    /// shortcut: a column named like a table or alias over-redacts (safe side); upgrade by resolving names against the schema.
    private static func hasWholeRowRef(_ t: [SQLToken]) -> Bool {
        let stop = ["WHERE", "JOIN", "ON", "USING", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL", "NATURAL", "GROUP", "ORDER", "LIMIT", "HAVING", "UNION", "INTERSECT", "EXCEPT", "WINDOW", "OFFSET", "SELECT"]
        var names = Set<String>(), decl = Set<Int>()
        func take(_ j: Int) { decl.insert(j); names.insert(t[j].text.lowercased()) }
        for (i, tok) in t.enumerated() where tok.isWord("FROM") || tok.isWord("JOIN") {
            var j = i + 1
            guard j < t.count, t[j].isIdentifier, !stop.contains(where: t[j].isWord) else { continue }
            while j + 2 < t.count, t[j + 1].isPunct("."), t[j + 2].isIdentifier { decl.insert(j); j += 2 } // schema.table
            take(j); j += 1
            if j < t.count, t[j].isWord("AS") { j += 1 }
            if j < t.count, t[j].isIdentifier, !stop.contains(where: t[j].isWord) { take(j) }
        }
        return t.indices.contains { i in
            !decl.contains(i) && t[i].isIdentifier && names.contains(t[i].text.lowercased())
                && !(i > 0 && t[i - 1].isPunct(".")) && !(i + 1 < t.count && (t[i + 1].isPunct(".") || t[i + 1].isPunct("(")))
        }
    }

    /// The outermost SELECT's list items, or nil when the statement is not a plain `SELECT … [FROM …]` (WITH, set operations, no SELECT).
    static func selectItems(_ t: [SQLToken]) -> [[SQLToken]]? {
        guard t.first?.isWord("SELECT") == true else { return nil }
        var items: [[SQLToken]] = [[]], depth = 0
        for (i, tok) in t.enumerated().dropFirst() {
            if tok.isPunct("(") { depth += 1 } else if tok.isPunct(")") { depth -= 1 }
            if depth == 0 {
                if ["UNION", "INTERSECT", "EXCEPT"].contains(where: tok.isWord) { return nil }
                if tok.isWord("FROM") { break }
                if tok.isPunct(",") { items.append([]); continue }
                if i == 1, tok.isWord("DISTINCT") || tok.isWord("ALL") { continue }
            }
            items[items.count - 1].append(tok)
        }
        return depth == 0 ? items : nil
    }

    /// `col`, `t.col`, optionally followed by `[AS] alias`, and `col` is not hidden.
    private static func isPlainColumn(_ t: [SQLToken], hidden: Set<String>) -> Bool {
        var i = 0
        guard i < t.count, t[i].isIdentifier else { return false }
        var name = t[i].text; i += 1
        if i + 1 < t.count, t[i].isPunct("."), t[i + 1].isIdentifier { name = t[i + 1].text; i += 2 }
        if i < t.count, t[i].isWord("AS") { i += 1; guard i < t.count else { return false } }
        if i < t.count { guard t[i].isIdentifier else { return false }; i += 1 }
        return i == t.count && !hidden.contains(name.lowercased())
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
