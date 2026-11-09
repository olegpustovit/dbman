import Foundation

public struct Permission: Equatable, Sendable {
    public var level: String // off | read | overlay
    public var timeoutMs: Int?
    public var rowCap: Int?
}

/// Everything the MCP server persists about agents (SPEC §6): agents, permissions, sensitive columns, activity, approvals.
public extension Store {
    func upsertAgent(id: String, name: String, version: String?) throws {
        try locked {
            try h.query("""
                INSERT INTO agents(id, client_name, platform, version) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET version = excluded.version, last_seen = CAST(unixepoch('subsec') * 1000 AS INTEGER),
                  updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
                """, [id, name, name, version])
        }
    }

    /// The agent's row for a connection, created lazily with the SPEC default (production → read, else overlay). Never for the internal store.
    func permission(agent: String, connection: ConnectionRow) throws -> Permission {
        guard connection.env != "system" else { return Permission(level: "off") }
        return try locked {
            try h.query("INSERT OR IGNORE INTO permissions(agent_id, connection_id, level) VALUES (?, ?, ?)",
                        [agent, connection.id, connection.env == "production" ? "read" : "overlay"])
            let r = try h.query("SELECT level, timeout_ms, row_cap FROM permissions WHERE agent_id = ? AND connection_id = ?", [agent, connection.id])[0]
            return Permission(level: r[0] as! String, timeoutMs: (r[1] as? Int64).map(Int.init), rowCap: (r[2] as? Int64).map(Int.init))
        }
    }

    /// First schema load of a connection: auto-mark `columns` once. Later calls are no-ops, so the human's unmarks stick.
    func autoMarkSensitive(connection: String, columns: [(table: String, column: String)]) throws {
        try locked {
            try h.transaction {
                let key = "sensitive_scanned:" + connection
                guard try h.scalar("SELECT value FROM meta WHERE key = ?", [key]) == nil else { return }
                for c in columns {
                    try h.query("INSERT OR IGNORE INTO sensitive_columns(connection_id, table_name, column_name, source) VALUES (?, ?, ?, 'auto')", [connection, c.table, c.column])
                }
                try h.query("INSERT INTO meta(key, value) VALUES (?, '1')", [key])
            }
        }
    }

    /// Lower-cased names of columns hidden from agents on this connection.
    func hiddenColumns(connection: String) throws -> Set<String> {
        try locked { Set(try h.query("SELECT column_name FROM sensitive_columns WHERE connection_id = ? AND hidden = 1", [connection]).map { ($0[0] as! String).lowercased() }) }
    }

    func logActivity(agent: String?, connection: String?, tool: String, args: String, ms: Int, rows: Int?, status: String, error: String?) throws {
        try locked {
            try h.query("INSERT INTO activity(agent_id, connection_id, tool, args_summary, ms, \"rows\", status, error) VALUES (?,?,?,?,?,?,?,?)",
                        [agent, connection, tool, String(args.prefix(120)), ms, rows, status, error])
        }
    }

    /// 30-day retention (SPEC §6); call at launch.
    func pruneActivity() throws {
        try locked { try h.query("DELETE FROM activity WHERE ts < CAST(unixepoch('subsec') * 1000 AS INTEGER) - 30 * 86400000") }
    }

    func addApproval(kind: String, agent: String, connection: String?, payload: String) throws -> String {
        let id = UUID().uuidString
        let ttl = Int(setting("approval_ttl_s") ?? "") ?? 600
        try locked {
            try h.query("INSERT INTO approvals(id, kind, agent_id, connection_id, payload, expires_at) VALUES (?,?,?,?,?, CAST(unixepoch('subsec') * 1000 AS INTEGER) + ?)",
                        [id, kind, agent, connection, payload, ttl * 1000])
        }
        return id
    }

    @discardableResult private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}
