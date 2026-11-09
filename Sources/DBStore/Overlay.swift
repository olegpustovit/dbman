import Foundation

public struct Layer: Identifiable, Equatable, Sendable {
    public var id: String
    public var connection: String
    public var owner: String           // human | agent
    public var agentID: String?
    public var name: String
    public var visible: Bool
    public var archived: Bool
    public var items = 0               // active + stale
    public var stale = 0
    public var last: Date?             // newest write into the layer
    public var isMine: Bool { owner == "human" }
}

/// One overlay object; `table…after` are set for row patches (kind `row_patch`), JSON as text.
public struct OverlayItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var layer: String
    public var kind: String            // view | relation | row_patch | note | saved_query | dashboard | computed_column
    public var name: String?
    public var payload: String
    public var baseHash: String?
    public var status: String          // active | stale | adopted | discarded
    public var updated: Date
    public var table: String?, pk: String?, op: String?, before: String?, after: String?
}

/// Layers and their items (SPEC §1.10). Agents are only ever handed their own layer id by the MCP server; MINE is the human's.
public extension Store {
    static func mineID(_ connection: String) -> String { "mine:" + connection }

    func layers(_ connection: String) throws -> [Layer] {
        try locked {
            try h.query("""
                SELECT l.id, l.connection_id, l.owner, l.agent_id, l.name, l.visible, l.archived_at IS NOT NULL, l.updated_at,
                       (SELECT count(*) FROM overlay_items i WHERE i.layer_id = l.id AND i.status IN ('active','stale')),
                       (SELECT count(*) FROM overlay_items i WHERE i.layer_id = l.id AND i.status = 'stale'),
                       (SELECT max(i.updated_at) FROM overlay_items i WHERE i.layer_id = l.id)
                FROM layers l WHERE l.connection_id = ? ORDER BY l.owner = 'agent', l.position, l.rowid
                """, [connection]).map { r in
                Layer(id: r[0] as! String, connection: r[1] as! String, owner: r[2] as! String, agentID: r[3] as? String, name: r[4] as! String,
                      visible: (r[5] as! Int64) == 1, archived: (r[6] as! Int64) == 1, items: Int(r[8] as! Int64), stale: Int(r[9] as! Int64),
                      last: ((r[10] as? Int64) ?? (r[7] as! Int64)).ms)
            }
        }
    }

    /// The agent's layer on a connection, created on its first overlay write and un-archived by any later one. Named after the agent.
    func agentLayer(_ connection: String, agent: String) throws -> String {
        let id = "agent:\(agent):\(connection)"
        try locked {
            try h.query("""
                INSERT INTO layers(id, connection_id, owner, agent_id, name, position)
                VALUES (?, ?, 'agent', ?, COALESCE((SELECT client_name FROM agents WHERE id = ?), ?), COALESCE((SELECT max(position) + 1 FROM layers WHERE connection_id = ?), 1))
                ON CONFLICT(id) DO UPDATE SET archived_at = NULL WHERE archived_at IS NOT NULL
                """, [id, connection, agent, agent, agent, connection])
        }
        return id
    }

    func setLayerVisible(_ id: String, _ visible: Bool) throws { try locked { try h.query("UPDATE layers SET visible = ? WHERE id = ?", [visible, id]) } }

    /// Layers untouched for `days` days are archived (hidden from merges, listed as archived), never deleted. Call at launch.
    func archiveIdleLayers(days: Int = 30) throws {
        try locked {
            try h.query("""
                UPDATE layers SET archived_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
                WHERE owner = 'agent' AND archived_at IS NULL
                  AND COALESCE((SELECT max(updated_at) FROM overlay_items WHERE layer_id = layers.id), updated_at) < CAST(unixepoch('subsec') * 1000 AS INTEGER) - ? * 86400000
                """, [days])
        }
    }

    // MARK: items

    /// Items of `layers` (empty = all of the connection's), oldest first. Default statuses are the live ones.
    func items(_ connection: String, layers ids: [String] = [], kind: String? = nil, statuses: [String] = ["active", "stale"]) throws -> [OverlayItem] {
        try locked {
            var sql = """
                SELECT i.id, i.layer_id, i.kind, i.name, i.payload, i.base_hash, i.status, i.updated_at, p.table_name, p.pk, p.op, p."before", p."after"
                FROM overlay_items i JOIN layers l ON l.id = i.layer_id LEFT JOIN row_patches p ON p.item_id = i.id
                WHERE l.connection_id = ? AND i.status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))
                """
            var args: [Any?] = [connection] + statuses
            if let kind { sql += " AND i.kind = ?"; args.append(kind) }
            if !ids.isEmpty { sql += " AND i.layer_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"; args += ids }
            return try h.query(sql + " ORDER BY i.rowid", args).map { r in
                OverlayItem(id: r[0] as! String, layer: r[1] as! String, kind: r[2] as! String, name: r[3] as? String, payload: r[4] as! String, baseHash: r[5] as? String,
                            status: r[6] as! String, updated: (r[7] as! Int64).ms, table: r[8] as? String, pk: r[9] as? String, op: r[10] as? String, before: r[11] as? String, after: r[12] as? String)
            }
        }
    }

    /// Adds an item; a live item of the same kind and name in that layer is replaced (views, notes, saved queries, relations).
    @discardableResult
    func addItem(layer: String, kind: String, name: String?, payload: String, baseHash: String? = nil) throws -> String {
        let id = UUID().uuidString
        try locked {
            try h.transaction {
                if let name { try h.query("DELETE FROM overlay_items WHERE layer_id = ? AND kind = ? AND name = ? AND status IN ('active','stale')", [layer, kind, name]) }
                try h.query("INSERT INTO overlay_items(id, layer_id, kind, name, payload, base_hash) VALUES (?,?,?,?,?,?)", [id, layer, kind, name, payload, baseHash])
                try touch(layer)
            }
        }
        return id
    }

    /// Records a row patch, replacing a live patch of the same row in that layer (the caller merges first when it wants to keep earlier columns).
    @discardableResult
    func putPatch(layer: String, table: String, pk: String, op: String, before: String?, after: String?, baseHash: String?) throws -> String {
        let id = UUID().uuidString
        try locked {
            try h.transaction {
                try h.query("""
                    DELETE FROM overlay_items WHERE kind = 'row_patch' AND layer_id = ? AND status IN ('active','stale')
                      AND id IN (SELECT item_id FROM row_patches WHERE table_name = ? AND pk = ?)
                    """, [layer, table, pk])
                try h.query("INSERT INTO overlay_items(id, layer_id, kind, name, base_hash) VALUES (?, ?, 'row_patch', ?, ?)", [id, layer, table, baseHash])
                try h.query("INSERT INTO row_patches(item_id, table_name, pk, op, \"before\", \"after\") VALUES (?,?,?,?,?,?)", [id, table, pk, op, before, after])
                try touch(layer)
            }
        }
        return id
    }

    func setStatus(_ ids: [String], _ status: String) throws {
        try locked {
            try h.transaction { for id in ids { try h.query("UPDATE overlay_items SET status = ?, updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE id = ?", [status, id]) } }
        }
    }

    /// ADOPT: copies the items into MINE (replacing a same-named item or same-row patch there) and marks the originals adopted.
    func adopt(_ ids: [String], connection: String) throws {
        let mine = Self.mineID(connection)
        try locked {
            try h.transaction {
                for id in ids {
                    guard let r = try h.query("SELECT kind, name, payload, base_hash, layer_id FROM overlay_items WHERE id = ? AND status IN ('active','stale')", [id]).first, (r[4] as! String) != mine else { continue }
                    let copy = UUID().uuidString, kind = r[0] as! String
                    if let p = try h.query("SELECT table_name, pk, op, \"before\", \"after\" FROM row_patches WHERE item_id = ?", [id]).first {
                        try h.query("""
                            DELETE FROM overlay_items WHERE kind = 'row_patch' AND layer_id = ? AND status IN ('active','stale')
                              AND id IN (SELECT item_id FROM row_patches WHERE table_name = ? AND pk = ?)
                            """, [mine, p[0], p[1]])
                        try h.query("INSERT INTO overlay_items(id, layer_id, kind, name, base_hash) VALUES (?,?,?,?,?)", [copy, mine, kind, r[1], r[3]])
                        try h.query("INSERT INTO row_patches(item_id, table_name, pk, op, \"before\", \"after\") VALUES (?,?,?,?,?,?)", [copy, p[0], p[1], p[2], p[3], p[4]])
                    } else {
                        if let name = r[1] as? String { try h.query("DELETE FROM overlay_items WHERE layer_id = ? AND kind = ? AND name = ? AND status IN ('active','stale')", [mine, kind, name]) }
                        try h.query("INSERT INTO overlay_items(id, layer_id, kind, name, payload, base_hash) VALUES (?,?,?,?,?,?)", [copy, mine, kind, r[1], r[2], r[3]])
                    }
                    try h.query("UPDATE overlay_items SET status = 'adopted', updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE id = ?", [id])
                }
                try touch(mine)
            }
        }
    }

    /// DISCARD: marks live items discarded (history stays in the file). `ids` nil = the whole layer. The note is what the agent reads in overlay.status.
    func discard(layer: String, ids: [String]? = nil, note: String?) throws {
        try locked {
            try h.transaction {
                if let ids { for id in ids { try h.query("UPDATE overlay_items SET status = 'discarded', updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE id = ? AND layer_id = ?", [id, layer]) } }
                else { try h.query("UPDATE overlay_items SET status = 'discarded', updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE layer_id = ? AND status IN ('active','stale')", [layer]) }
                if let note, !note.isEmpty {
                    try h.query("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)", ["discard_note:" + layer, note])
                }
            }
        }
    }

    /// The human's last discard note for a layer and how many items were discarded since the agent last wrote.
    func discardNote(layer: String) -> (note: String, at: Date)? {
        locked {
            (try? h.query("SELECT value, updated_at FROM meta WHERE key = ?", ["discard_note:" + layer]))?.first.map { ($0[0] as! String, ($0[1] as! Int64).ms) }
        }
    }

    private func touch(_ layer: String) throws { try h.query("UPDATE layers SET updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE id = ?", [layer]) }
    @discardableResult private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}

private extension Int64 { var ms: Date { Date(timeIntervalSince1970: Double(self) / 1000) } }
