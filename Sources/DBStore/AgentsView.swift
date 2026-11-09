import Foundation

public struct AgentRow: Equatable, Sendable {
    public var id: String, name: String, version: String?, lastSeen: Date
}
public struct ActivityRow: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var ts: Date
    public var agent: String?, connection: String?, connectionId: String?, tool: String, args: String
    public var ms: Int?, rows: Int?, status: String, error: String?
}
public struct SensitiveColumn: Equatable, Sendable, Identifiable {
    public var table: String, column: String, source: String, hidden: Bool
    public var id: String { table + "." + column }
}

/// What the Agents window reads and edits: the roster, the permission matrix, sensitive columns and the activity feed.
public extension Store {
    func agents() throws -> [AgentRow] {
        lock.lock(); defer { lock.unlock() }
        return try h.query("SELECT id, client_name, version, last_seen FROM agents ORDER BY last_seen DESC").map {
            AgentRow(id: $0[0] as! String, name: $0[1] as! String, version: $0[2] as? String, lastSeen: Date(timeIntervalSince1970: Double($0[3] as! Int64) / 1000))
        }
    }

    /// Writes one matrix cell. The CHECK constraint (and the caller) keep the internal store out; timeout/cap nil = default.
    func setPermission(agent: String, connection: String, level: String, timeoutMs: Int? = nil, rowCap: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try h.query("""
            INSERT INTO permissions(agent_id, connection_id, level, timeout_ms, row_cap) VALUES (?,?,?,?,?)
            ON CONFLICT(agent_id, connection_id) DO UPDATE SET level = excluded.level, timeout_ms = excluded.timeout_ms, row_cap = excluded.row_cap,
              updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
            """, [agent, connection, level, timeoutMs, rowCap])
    }

    func sensitiveColumns(connection: String) throws -> [SensitiveColumn] {
        lock.lock(); defer { lock.unlock() }
        return try h.query("SELECT table_name, column_name, source, hidden FROM sensitive_columns WHERE connection_id = ? ORDER BY table_name, column_name", [connection]).map {
            SensitiveColumn(table: $0[0] as! String, column: $0[1] as! String, source: $0[2] as! String, hidden: ($0[3] as! Int64) == 1)
        }
    }

    /// Mark (hidden) or unmark one column; the human's choice sticks because auto-marking runs once per connection.
    func setSensitive(connection: String, table: String, column: String, hidden: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try h.query("""
            INSERT INTO sensitive_columns(connection_id, table_name, column_name, source, hidden) VALUES (?,?,?,'user',?)
            ON CONFLICT(connection_id, table_name, column_name) DO UPDATE SET hidden = excluded.hidden, updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
            """, [connection, table, column, hidden ? 1 : 0])
    }

    /// Newest first. `connection`/`agent` filter by id; the connection comes back as its name.
    func activity(connection: String? = nil, agent: String? = nil, limit: Int = 200) throws -> [ActivityRow] {
        lock.lock(); defer { lock.unlock() }
        return try h.query("""
            SELECT a.id, a.ts, a.agent_id, c.name, a.connection_id, a.tool, a.args_summary, a.ms, a."rows", a.status, a.error
            FROM activity a LEFT JOIN connections c ON c.id = a.connection_id
            WHERE (?1 IS NULL OR a.connection_id = ?1) AND (?2 IS NULL OR a.agent_id = ?2)
            ORDER BY a.id DESC LIMIT ?3
            """, [connection, agent, limit]).map {
            ActivityRow(id: $0[0] as! Int64, ts: Date(timeIntervalSince1970: Double($0[1] as! Int64) / 1000), agent: $0[2] as? String, connection: $0[3] as? String,
                        connectionId: $0[4] as? String, tool: $0[5] as! String, args: ($0[6] as? String) ?? "", ms: ($0[7] as? Int64).map(Int.init),
                        rows: ($0[8] as? Int64).map(Int.init), status: $0[9] as! String, error: $0[10] as? String)
        }
    }
}
