import Foundation

/// A recorded change to one row by primary key: what an agent (or the human) left in a layer instead of writing to the database.
public struct RowPatch: Hashable, Sendable {
    public enum Op: String, Sendable { case insert, update, delete }
    public var id: String          // overlay item id
    public var layer: String       // layer id
    public var table: String
    public var key: [String: Cell]
    public var op: Op
    public var before: [String: Cell]   // update: old values of the patched columns; delete: the whole row
    public var after: [String: Cell]
    public var baseHash: String?   // hash of the database row when the patch was recorded
    public var stale: Bool
    public init(id: String = "", layer: String = "", table: String, key: [String: Cell], op: Op, before: [String: Cell] = [:], after: [String: Cell] = [:], baseHash: String? = nil, stale: Bool = false) {
        self.id = id; self.layer = layer; self.table = table; self.key = key; self.op = op; self.before = before; self.after = after; self.baseHash = baseHash; self.stale = stale
    }
}

/// Overlay maths shared by the MCP server and the app: patch merge, JSON codec, row hash, view expansion, ChangeSet. Pure.
public enum Overlay {
    // MARK: JSON codec (store columns are JSON text)

    public static func json(_ v: [String: Cell]) -> String {
        let o = v.mapValues { c -> Any in
            switch c {
            case .null: return NSNull()
            case .integer(let n): return n
            case .real(let d): return d.isFinite ? d : NSNull()
            case .bool(let b): return b
            default: return c.display
            }
        }
        return (try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func values(_ json: String?) -> [String: Cell] {
        guard let json, let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [:] }
        return o.mapValues(cell)
    }

    /// JSON value → Cell. Whole numbers become integers (merge coerces them to the column's type).
    public static func cell(_ v: Any) -> Cell {
        switch v {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if ["d", "f"].contains(String(cString: n.objCType)), n.doubleValue != n.doubleValue.rounded() || abs(n.doubleValue) >= 9e15 { return .real(n.doubleValue) }
            return .integer(n.int64Value)
        case let s as String: return .text(s)
        default: return .null
        }
    }

    /// FNV-1a over `column=value` pairs: stable across launches (Swift's Hasher is not), so it can sit in the store.
    public static func hash(columns: [String], row: [Cell]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for (c, v) in zip(columns, row) { for b in "\(c)=\(v.display)\u{1f}".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return String(h, radix: 16)
    }

    /// Key columns' values as one comparable string (display forms, so JSON `1` and a database `1` agree).
    public static func keyString(_ pk: [String], _ key: [String: Cell]) -> String {
        pk.map { n in key.first { $0.key.lowercased() == n.lowercased() }?.value.display ?? "" }.joined(separator: "\u{1f}")
    }

    // MARK: merge

    public struct Merged: Sendable {
        public var rows: [[Cell]]
        public var source: [Int]           // output row → input row, -1 for inserted rows
        public var cells: [Int: Set<Int>]  // output row → patched column indexes
        public var applied = 0
    }

    /// Patches (lowest layer first, so the top layer wins) laid over `rows` by primary key. Rows outside the page are ignored;
    /// inserts are appended only when `addInserts` (the caller knows the page is the unfiltered end of the table).
    public static func merge(columns: [String], rows: [[Cell]], pk: [String], patches: [RowPatch], addInserts: Bool) -> Merged {
        var out = Merged(rows: rows, source: Array(rows.indices), cells: [:])
        var col: [String: Int] = [:]
        for (i, c) in columns.enumerated() where col[c.lowercased()] == nil { col[c.lowercased()] = i }
        guard !pk.isEmpty, !patches.isEmpty, pk.allSatisfy({ col[$0.lowercased()] != nil }) else { return out }
        func key(_ name: String, _ m: [String: Cell]) -> Cell? { m.first { $0.key.lowercased() == name.lowercased() }?.value }
        let rowKey = { (r: [Cell]) in pk.map { r[col[$0.lowercased()]!].display }.joined(separator: "\u{1f}") }
        var gone = Set<Int>(), index: [String: Int] = [:]
        for (i, r) in rows.enumerated() where r.count == columns.count { index[rowKey(r)] = index[rowKey(r)] ?? i }
        func set(_ i: Int, _ after: [String: Cell]) {
            for (name, v) in after {
                guard let j = col[name.lowercased()] else { continue }
                if case .real = out.rows[i][j], case .integer(let n) = v { out.rows[i][j] = .real(Double(n)) } else { out.rows[i][j] = v }
                out.cells[i, default: []].insert(j)
            }
        }
        for p in patches {
            let parts = pk.map { key($0, p.key) }
            guard parts.allSatisfy({ $0 != nil }) else { continue }
            let k = parts.map { $0!.display }.joined(separator: "\u{1f}")
            if let i = index[k] {
                switch p.op {
                case .delete: gone.insert(i)
                case .update, .insert: gone.remove(i); set(i, p.after); out.applied += 1
                }
            } else if p.op == .insert, addInserts {
                out.rows.append(columns.map { n in key(n, p.after) ?? key(n, p.key) ?? .null }); out.source.append(-1)
                let i = out.rows.count - 1
                index[k] = i; out.cells[i] = Set(columns.indices); out.applied += 1
            }
            if p.op == .delete, index[k] != nil { out.applied += 1 }
        }
        guard !gone.isEmpty else { return out }
        let keep = out.rows.indices.filter { !gone.contains($0) }
        let remap = Dictionary(uniqueKeysWithValues: keep.enumerated().map { ($1, $0) })
        out.cells = Dictionary(uniqueKeysWithValues: out.cells.compactMap { k, v in remap[k].map { ($0, v) } })
        (out.rows, out.source) = (keep.map { out.rows[$0] }, keep.map { out.source[$0] })
        return out
    }

    /// The patches as the v1 staged changes the Review sheet and the migration export already know how to print.
    public static func changes(_ patches: [RowPatch]) -> [StagedChange] {
        patches.flatMap { p -> [StagedChange] in
            switch p.op {
            case .update: return p.after.keys.sorted().map { .update(table: p.table, key: p.key, column: $0, old: p.before[$0] ?? .null, new: p.after[$0]!) }
            case .insert: return [.insert(table: p.table, values: p.key.merging(p.after) { $1 })]
            case .delete: return [.delete(table: p.table, key: p.key)]
            }
        }
    }

    // MARK: virtual views

    /// Expands the virtual `views` (lowest layer first, so a later one shadows an earlier one) that `sql` names into CTEs, merging into an existing WITH.
    /// Names resolve by identifier tokens; a CTE the statement defines itself wins over a view of the same name. Views may use other views.
    public static func expand(_ sql: String, views: [(name: String, sql: String)], mysql: Bool = false) -> (sql: String, used: [String]) {
        guard !views.isEmpty else { return (sql, []) }
        let byName = Dictionary(views.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { $1 })
        let toks = sqlTokens(sql, mysql: mysql), own = cteNames(toks)
        func refs(_ t: [SQLToken]) -> [String] {
            var seen = Set<String>(), r: [String] = []
            for (i, tok) in t.enumerated() where tok.isIdentifier && !(i > 0 && t[i - 1].isPunct(".")) {
                let n = tok.text.lowercased()
                if byName[n] != nil, seen.insert(n).inserted { r.append(n) }
            }
            return r
        }
        var ordered: [String] = [], visiting = Set<String>()
        func visit(_ n: String) {
            guard !ordered.contains(n), visiting.insert(n).inserted else { return }
            for d in refs(sqlTokens(byName[n]!.sql, mysql: mysql)) where d != n { visit(d) }
            ordered.append(n)
        }
        for r in refs(toks) where !own.contains(r) { visit(r) }
        guard !ordered.isEmpty else { return (sql, []) }
        let ctes = ordered.map { n -> String in
            var body = byName[n]!.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            while body.hasSuffix(";") { body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
            return "\(byName[n]!.name) AS (\(body))"
        }.joined(separator: ", ")
        let used = ordered.map { byName[$0]!.name }
        if let w = toks.first, w.isWord("WITH") {
            let at = (toks.count > 1 && toks[1].isWord("RECURSIVE") ? toks[1] : w).range.upperBound
            return (String(sql[..<at]) + " " + ctes + "," + String(sql[at...]), used)
        }
        return ("WITH " + ctes + " " + sql, used)
    }

    /// Lower-cased names of the CTEs a statement's own top-level WITH defines.
    static func cteNames(_ t: [SQLToken]) -> Set<String> {
        guard t.first?.isWord("WITH") == true else { return [] }
        var names = Set<String>(), depth = 0
        for i in 1..<max(t.count, 1) {
            if t[i].isPunct("(") { depth += 1 } else if t[i].isPunct(")") { depth -= 1 }
            guard depth == 0, t[i].isIdentifier, i + 1 < t.count, t[i - 1].isWord("WITH") || t[i - 1].isWord("RECURSIVE") || t[i - 1].isPunct(",") else { continue }
            if t[i + 1].isWord("AS") || t[i + 1].isPunct("(") { names.insert(t[i].text.lowercased()) }
        }
        return names
    }
}
