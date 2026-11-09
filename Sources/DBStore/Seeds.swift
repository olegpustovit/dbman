import Foundation

/// Dashboards the store seeds itself (SPEC §6): the internal connection's default, built from its own views.
enum Seeds {
    static let agentActivityTitle = "Agent activity"

    /// DashboardSpec JSON (the DBStore target does not link DBCore; tests decode and validate it there).
    static var agentActivity: String {
        let since = "ts > cast(strftime('%s', 'now', :range) as integer) * 1000"
        func w(_ id: String, _ type: String, _ title: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ query: String, _ enc: [String: String] = [:], thresholds: [[String: Any]]? = nil) -> [String: Any] {
            var o: [String: Any] = ["id": id, "type": type, "title": title, "x": x, "y": y, "w": w, "h": h, "query": query]
            if !enc.isEmpty { o["encoding"] = enc }
            if let thresholds { o["thresholds"] = thresholds }
            return o
        }
        let spec: [String: Any] = [
            "version": 1, "title": agentActivityTitle, "connection": Store.internalName, "refresh": "30s",
            "variables": [["name": "range", "type": "timeRange", "default": "24h"]],
            "widgets": [
                w("calls", "kpi", "Calls", 0, 0, 3, 2, "select count(*) as value from activity where \(since)"),
                w("blocked", "kpi", "Blocked", 3, 0, 3, 2, "select count(*) as value from activity where status in ('blocked','denied') and \(since)", thresholds: [["op": ">", "value": 0, "level": "warn"]]),
                w("overlay", "kpi", "Overlay writes", 6, 0, 3, 2, "select count(*) as value from activity where status = 'overlay' and \(since)"),
                w("pending", "kpi", "Pending approvals", 9, 0, 3, 2, "select count(*) as value from v_pending_approvals", thresholds: [["op": ">", "value": 0, "level": "warn"]]),
                w("hourly", "line", "Calls per hour", 0, 2, 8, 4, "select strftime('%Y-%m-%d %H:00', ts / 1000, 'unixepoch') as hour, count(*) as calls from activity where \(since) group by 1 order by 1", ["x": "hour", "y": "calls"]),
                w("by_agent", "bars.horizontal", "Blocked by agent", 8, 2, 4, 4, "select coalesce(agent_id, 'unknown') as agent, count(*) as blocked from activity where status in ('blocked','denied') and \(since) group by 1 order by 2 desc limit 8", ["label": "agent", "value": "blocked"]),
                w("layers", "bars.horizontal", "Layer sizes", 0, 6, 6, 3, "select name || ' // ' || coalesce((select c.name from connections c where c.id = v_layer_summary.connection_id), connection_id) as layer, items from v_layer_summary where items > 0 order by items desc limit 8", ["label": "layer", "value": "items"]),
                w("approvals", "table", "Pending approvals", 6, 6, 6, 3, "select kind, coalesce(agent_id, '') as agent, coalesce(connection_id, '') as connection, datetime(expires_at / 1000, 'unixepoch') as expires from v_pending_approvals order by expires_at"),
            ],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
    }
}
