import Foundation

public struct ApprovalRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String            // credentials | prod_guard | remove | apply
    public var agent: String?, connection: String?
    public var payload: String         // JSON, see Store.payloadValue
    public var status: String          // pending | approved | rejected | expired | consumed
    public var expiresAt: Date

    /// One field of the payload JSON (nil if absent or not a string/number).
    public func field(_ key: String) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], let v = o[key] else { return nil }
        return v is NSNull ? nil : "\(v)"
    }
}

/// The human's side of approvals (SPEC §1.5, §3 F2/F4): list pending, decide, expire; plus the one-time prod-guard allowance.
public extension Store {
    private static let cols = "id, kind, agent_id, connection_id, payload, status, expires_at"
    private static func row(_ r: [Any?]) -> ApprovalRow {
        ApprovalRow(id: r.s(0), kind: r.s(1), agent: r[2] as? String, connection: r[3] as? String, payload: r.s(4), status: r.s(5),
                    expiresAt: Date(timeIntervalSince1970: Double(r.n(6)) / 1000))
    }

    func approval(_ id: String) throws -> ApprovalRow? {
        return try locked {
            try h.query("SELECT \(Self.cols) FROM approvals WHERE id = ?", [id]).first.map(Self.row)
        }
    }

    /// Oldest first. Expires overdue rows first, so a caller never sees a stale "pending".
    func pendingApprovals() throws -> [ApprovalRow] {
        try expireApprovals()
        return try locked {
            try h.query("SELECT \(Self.cols) FROM approvals WHERE status = 'pending' ORDER BY created_at").map(Self.row)
        }
    }

    func expireApprovals() throws {
        try locked {
            try h.query("UPDATE approvals SET status = 'expired', updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE status = 'pending' AND expires_at <= CAST(unixepoch('subsec') * 1000 AS INTEGER)")
        }
    }

    /// pending → approved | rejected | expired; no-op on anything already decided. `merge` (JSON object text) is merged into the payload
    /// (e.g. the new connection id, the note shown to the agent). An approval stays usable for another approval_ttl_s from now (ALLOW ONCE).
    @discardableResult
    func decideApproval(_ id: String, _ status: String, merge: String = "{}") throws -> Bool {
        let ttl = Int(setting("approval_ttl_s") ?? "") ?? 600 // before the lock: setting() takes it too
        return try locked {
            try h.query("""
                UPDATE approvals SET status = ?2, payload = json_patch(payload, ?3), decided_at = CAST(unixepoch('subsec') * 1000 AS INTEGER),
                  expires_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) + ?4 * 1000, updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
                WHERE id = ?1 AND status = 'pending' RETURNING id
                """, [id, status, merge, ttl]).count == 1
        }
    }

    /// A prod-guard block asks the human once per (agent, connection, statement): a retry while the row is pending adds nothing.
    func requestOverride(agent: String, connection: String, hash: String, payload: String) throws {
        let ttl = Int(setting("approval_ttl_s") ?? "") ?? 600
        try locked {
            guard try h.query("SELECT 1 FROM approvals WHERE kind = 'prod_guard' AND status = 'pending' AND agent_id = ? AND connection_id = ? AND json_extract(payload, '$.sql_hash') = ?",
                              [agent, connection, hash]).isEmpty else { return }
            try h.query("INSERT INTO approvals(id, kind, agent_id, connection_id, payload, expires_at) VALUES (?, 'prod_guard', ?, ?, json_insert(?, '$.sql_hash', ?), CAST(unixepoch('subsec') * 1000 AS INTEGER) + ? * 1000)",
                        [UUID().uuidString, agent, connection, payload, hash, ttl])
        }
    }

    /// ALLOW ONCE: true (and spends the allowance) if the human allowed exactly this statement for this agent and connection and it is still unused.
    func consumeAllowance(agent: String, connection: String, hash: String) throws -> Bool {
        return try locked {
            try h.query("""
                UPDATE approvals SET status = 'consumed', updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) WHERE id = (
                  SELECT id FROM approvals WHERE kind = 'prod_guard' AND status = 'approved' AND json_extract(payload, '$.action') = 'allow_once'
                    AND agent_id = ? AND connection_id = ? AND json_extract(payload, '$.sql_hash') = ? AND expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER) LIMIT 1
                ) RETURNING id
                """, [agent, connection, hash]).count == 1
        }
    }
}
