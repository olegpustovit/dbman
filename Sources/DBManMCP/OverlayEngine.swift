import DBCore
import DBStore
import Foundation

/// Store ⇄ database glue for overlays, shared by the MCP tools and the app: what a reader sees, stale detection, patches as RowPatch.
public enum OverlayEngine {
    public static func patch(_ i: OverlayItem) -> RowPatch? {
        guard i.kind == "row_patch", let t = i.table, let op = i.op.flatMap(RowPatch.Op.init) else { return nil }
        return RowPatch(id: i.id, layer: i.layer, table: t, key: Overlay.values(i.pk), op: op, before: Overlay.values(i.before), after: Overlay.values(i.after), baseHash: i.baseHash, stale: i.status == "stale")
    }

    /// `{"sql": …}` payload of a view or saved query.
    public static func sql(_ i: OverlayItem) -> String {
        ((try? JSONSerialization.jsonObject(with: Data(i.payload.utf8))) as? [String: Any])?["sql"] as? String ?? ""
    }
    public static func payload(sql: String) -> String { (try? JSONSerialization.data(withJSONObject: ["sql": sql])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }

    /// Notes of the given items as `table` / `table.column` → text.
    public static func notes(_ items: [OverlayItem]) -> [String: String] {
        Dictionary(items.filter { $0.kind == "note" }.compactMap { i in i.name.map { ($0, ((try? JSONSerialization.jsonObject(with: Data(i.payload.utf8))) as? [String: Any])?["text"] as? String ?? "") } }, uniquingKeysWith: { $1 })
    }

    /// What an agent reads on a connection: DATABASE + MINE + its own layer, MINE first so the agent's layer wins. `only` narrows it (`mine`).
    public static func scope(_ store: Store, connection: String, agent: String, mineOnly: Bool = false) throws -> (items: [OverlayItem], own: String?) {
        let layers = try store.layers(connection)
        let own = mineOnly ? nil : layers.first { $0.agentID == agent && !$0.archived }?.id
        let ids = [Store.mineID(connection)] + [own].compactMap { $0 }
        let items = try store.items(connection, layers: ids)
        return (items.filter { $0.layer == ids[0] } + items.filter { $0.layer != ids[0] }, own)
    }

    // MARK: stale detection (G19)

    static func literal(_ c: Cell, _ e: Engine) -> String {
        if case .text(let s) = c, e == .mysql { return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'" }
        return c.sqlLiteral
    }

    /// Current database rows for `keys` of one table: key string → (columns, row). Chunked OR-lists; names come from the schema, values are literals.
    public static func fetch(_ session: DatabaseSession, _ t: TableInfo, keys: [[String: Cell]]) async throws -> [String: (columns: [String], row: [Cell])] {
        let e = await session.profile.engine, pk = t.primaryKey
        var out: [String: (columns: [String], row: [Cell])] = [:]
        for chunk in stride(from: 0, to: keys.count, by: 40).map({ Array(keys[$0..<min($0 + 40, keys.count)]) }) {
            let cond = chunk.map { k in "(" + pk.map { n in "\(quoteIdent(n, e)) = \(literal(k.first { $0.key.lowercased() == n.lowercased() }?.value ?? .null, e))" }.joined(separator: " AND ") + ")" }.joined(separator: " OR ")
            let r = try await session.run("SELECT * FROM \(quoteIdent(t.name, e)) WHERE \(cond)", limit: chunk.count + 1)
            for row in r.rows {
                let m = Dictionary(zip(r.columns, row), uniquingKeysWith: { a, _ in a })
                out[Overlay.keyString(pk, m)] = (r.columns, row)
            }
        }
        return out
    }

    /// Re-checks the live row patches of `layers` against the database: a patch whose row changed (or vanished, or an insert whose key now exists)
    /// becomes `stale`, one that no longer differs goes back to `active`. Returns the current row of every patch (item id → column → value) for diffs.
    @discardableResult
    public static func check(_ store: Store, _ session: DatabaseSession, _ schema: SchemaSnapshot, connection: String, layers: [String]) async throws -> [String: [String: Cell]] {
        let items = try store.items(connection, layers: layers, kind: "row_patch")
        var current: [String: [String: Cell]] = [:], toStale: [String] = [], toActive: [String] = []
        for (table, group) in Dictionary(grouping: items.compactMap { i in patch(i).map { (i, $0) } }, by: { $0.1.table }) {
            let info = schema.table(table)
            var rows: [String: (columns: [String], row: [Cell])]?
            if let info { rows = try await fetch(session, info, keys: group.map(\.1.key)) }
            for (item, p) in group {
                let now = rows?[Overlay.keyString(info?.primaryKey ?? [], p.key)]
                if let now { current[item.id] = Dictionary(zip(now.columns, now.row), uniquingKeysWith: { a, _ in a }) }
                let stale: Bool
                switch p.op {
                case .insert: stale = now != nil
                default: stale = now.map { p.baseHash != nil && Overlay.hash(columns: $0.columns, row: $0.row) != p.baseHash } ?? true
                }
                if stale != p.stale { if stale { toStale.append(item.id) } else { toActive.append(item.id) } }
            }
        }
        try store.setStatus(toStale, "stale"); try store.setStatus(toActive, "active")
        return current
    }

    // MARK: merging into a statement's result

    public enum Target: Equatable { case table(String, plainEnd: Bool), no(String) }

    /// The one real table a plain `SELECT … FROM t [alias] [WHERE|ORDER|LIMIT …]` returns rows of, or why it is not that.
    /// `plainEnd`: no WHERE/ORDER/LIMIT, so patched inserts belong at the end of the result. shortcut: no CTE/subquery/join support, upgrade with column lineage.
    public static func target(_ t: [SQLToken]) -> Target {
        guard t.first?.isWord("SELECT") == true else { return .no("not a plain select") }
        func has(_ ws: String...) -> Bool { t.contains { tok in ws.contains { tok.isWord($0) } } }
        if has("JOIN", "UNION", "INTERSECT", "EXCEPT") { return .no("join") }
        if has("GROUP", "HAVING", "DISTINCT", "OVER") { return .no("aggregate") }
        guard t.filter({ $0.isWord("SELECT") }).count == 1, t.filter({ $0.isWord("FROM") }).count == 1, let f = t.firstIndex(where: { $0.isWord("FROM") }), f + 1 < t.count, t[f + 1].isIdentifier else { return .no("no single table") }
        var i = f + 1, name = t[i].text; i += 1
        if i + 1 < t.count, t[i].isPunct("."), t[i + 1].isIdentifier { name = t[i + 1].text; i += 2 }
        let fromPart = t[i...].prefix { !($0.isWord("WHERE") || $0.isWord("ORDER") || $0.isWord("LIMIT") || $0.isWord("OFFSET")) }
        if fromPart.contains(where: { $0.isPunct(",") || $0.isPunct("(") }) { return .no("join") }
        return .table(name, plainEnd: !has("WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH"))
    }

    /// Lays `patches` over a query result. Returns the merged rows and the value of the result's `overlay` field (nil: nothing to say).
    public static func merge(sql: String, mysql: Bool, schema: SchemaSnapshot, columns: [String], rows: [[Cell]], patches: [RowPatch], lastPage: Bool) -> (rows: [[Cell]], note: String?) {
        let toks = sqlTokens(sql, mysql: mysql)
        let named = Set(toks.filter(\.isIdentifier).map { $0.text.lowercased() })
        let relevant = patches.filter { named.contains($0.table.lowercased()) }
        guard !relevant.isEmpty else { return (rows, nil) }
        guard case .table(let name, let plainEnd) = target(toks), let info = schema.tables.first(where: { $0.name.lowercased() == name.lowercased() && $0.kind == .table }) else {
            if case .no(let why) = target(toks) { return (rows, "not applied (\(why))") }
            return (rows, "not applied (view)")
        }
        let mine = relevant.filter { $0.table.lowercased() == name.lowercased() }
        guard !mine.isEmpty else { return (rows, nil) }
        if info.primaryKey.contains(where: { k in !columns.contains { $0.lowercased() == k.lowercased() } }) { return (rows, "not applied (primary key not selected)") }
        let m = Overlay.merge(columns: columns, rows: rows, pk: info.primaryKey, patches: mine, addInserts: plainEnd && lastPage)
        return (m.rows, "applied (\(m.applied) patches)")
    }
}
