import DBCore
import Foundation

/// Cell and date helpers shared by the widget views.
enum DashData {
    static func num(_ c: Cell?) -> Double {
        switch c {
        case .integer(let v)?: return Double(v)
        case .real(let v)?: return v
        case .text(let s)?: return Double(s) ?? 0
        default: return 0
        }
    }

    private static let utc: (String) -> DateFormatter = { f in
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = TimeZone(identifier: "UTC"); d.dateFormat = f; return d
    }
    /// "2026-11-09", "2026-11-09 14:32:09" or ISO-8601 with T/zone; real dates pass through.
    static func date(_ c: Cell) -> Date? {
        if case .date(let d) = c { return d }
        let t = c.display.replacingOccurrences(of: "T", with: " ")
        for (len, f) in [(19, "yyyy-MM-dd HH:mm:ss"), (10, "yyyy-MM-dd")] where t.count >= len { if let d = utc(f).date(from: String(t.prefix(len))) { return d } }
        return nil
    }
}

/// The seeded "Overview // default" dashboard: what v1's fixed Overview showed, as widgets over this connection's own tables.
/// Insights, the in-app activity feed and the live tx/s rate had no catalog equivalent and went with the fixed view.
@MainActor enum DefaultDashboard {
    static let title = "Overview // default"

    private static func bucket(_ e: Engine, _ col: String) -> String {
        let c = quoteIdent(col, e)
        switch e {
        case .sqlite: return "substr(\(c), 1, 10)"
        case .postgres: return "to_char(\(c), 'YYYY-MM-DD')"
        case .mysql: return "DATE_FORMAT(\(c), '%Y-%m-%d')"
        }
    }
    /// 14 days back from the newest row, so a quiet or old database still draws.
    private static func since(_ e: Engine, _ t: String, _ col: String) -> String {
        let c = quoteIdent(col, e), latest = "(SELECT MAX(\(c)) FROM \(quoteIdent(t, e)))"
        switch e {
        case .sqlite: return "\(c) >= date(\(latest), '-14 days')"
        case .postgres: return "\(c) >= \(latest) - interval '14 days'"
        case .mysql: return "\(c) >= DATE_SUB(\(latest), INTERVAL 14 DAY)"
        }
    }
    static func dateColumn(_ t: TableInfo) -> String? {
        let c = t.columns.filter { c in
            let ty = c.type.lowercased(), n = c.name.lowercased()
            return ty.contains("date") || ty.contains("time") || n.hasSuffix("_at") || n.hasSuffix("_date")
        }
        return (c.first { $0.name.lowercased().contains("creat") } ?? c.first)?.name
    }
    static func isAttention(_ name: String) -> Bool { ["pending", "failed", "error", "cancelled", "canceled"].contains(name.lowercased()) }

    static func make(_ ws: WorkspaceModel) async -> DashboardSpec {
        let e = ws.profile.engine, tables = (ws.schema?.tables ?? []).filter { $0.kind == .table }.sorted { $0.rowCount > $1.rowCount }
        func lit(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        var top: [DashWidget] = []
        func w(_ id: String, _ type: String, _ title: String, _ h: Int, query: String? = nil, enc: [String: DashEnc]? = nil) -> DashWidget {
            DashWidget(id: id, type: type, title: title, x: 0, y: 0, w: 4, h: h, query: query, encoding: enc)
        }
        for (i, t) in tables.prefix(2).enumerated() { top.append(w("rows\(i + 1)", "kpi", "\(t.name) // rows", 2, query: "SELECT COUNT(*) AS value FROM \(quoteIdent(t.name, e))")) }
        // records added per day on the biggest table with a timestamp
        if let t = tables.first(where: { dateColumn($0) != nil }), let dc = dateColumn(t) {
            top.append(w("growth", "kpi.spark", "\(t.name) // added per day", 2, query: """
                SELECT x, y, SUM(y) OVER () AS value FROM (SELECT \(bucket(e, dc)) AS x, COUNT(*) AS y FROM \(quoteIdent(t.name, e)) WHERE \(since(e, t.name, dc)) GROUP BY 1) d ORDER BY x
                """, enc: ["x": DashEnc("x"), "y": DashEnc("y")]))
        }
        // category over time: first big table with a timestamp and a low-cardinality text column (status first)
        var line: DashWidget?
        if let s = ws.session {
            let hasStatus = { (t: TableInfo) in t.columns.contains { ["status", "state"].contains($0.name.lowercased()) } }
            for t in tables.prefix(4).sorted(by: { hasStatus($0) && !hasStatus($1) }) {
                guard let dc = dateColumn(t), let stats = try? await s.columnStats(table: t.name) else { continue }
                let textish = t.columns.filter { c in
                    let ty = c.type.lowercased()
                    return c.name != dc && !c.isPrimaryKey && (ty.isEmpty || ty.contains("char") || ty.contains("text") || ty.contains("enum"))
                }.map(\.name)
                let cands = stats.filter { textish.contains($0.column) && (2...8).contains($0.distinct ?? 99) }
                guard let c = cands.first(where: { $0.column.lowercased() == "status" }) ?? cands.first else { continue }
                let vals = c.topValues.map(\.value), names = Array((vals.filter { !isAttention($0) }.prefix(3) + vals.filter(isAttention)).prefix(4))
                let cat = quoteIdent(c.column, e)
                line = w("over_time", "line", "\(t.name) // over time", 4, query: """
                    SELECT \(bucket(e, dc)) AS day, \(cat) AS category, COUNT(*) AS n FROM \(quoteIdent(t.name, e)) WHERE \(since(e, t.name, dc)) AND \(cat) IN (\(names.map(lit).joined(separator: ", "))) GROUP BY 1, 2 ORDER BY 1
                    """, enc: ["x": DashEnc("day"), "y": DashEnc("n"), "series": DashEnc("category")])
                break
            }
        }
        var out: [DashWidget] = []
        let share = top.isEmpty ? 12 : 12 / top.count
        for (i, var t) in top.enumerated() { t.x = i * share; t.w = i == top.count - 1 ? 12 - i * share : share; out.append(t) }
        let y1 = top.isEmpty ? 0 : 2
        var foot = w("footprint", "bars.horizontal", "Footprint // rows", 4, query: tables.prefix(6).map { "SELECT \(lit($0.name)) AS label, COUNT(*) AS value FROM \(quoteIdent($0.name, e))" }.joined(separator: " UNION ALL "),
                     enc: ["label": DashEnc("label"), "value": DashEnc("value")])
        if tables.isEmpty { foot.query = "SELECT 'no tables' AS label, 0 AS value" }
        if var l = line { l.x = 0; l.y = y1; l.w = 8; out.append(l); foot.x = 8; foot.y = y1; foot.w = 4 } else { foot.x = 0; foot.y = y1; foot.w = 12 }
        out.append(foot)
        let y2 = y1 + 4
        switch e {
        case .postgres:
            var s = w("sessions", "table", "Sessions", 3, query: """
                SELECT pid::text AS pid, COALESCE(usename, '') AS "user", COALESCE(state, '') AS state, round(COALESCE(EXTRACT(EPOCH FROM (now() - COALESCE(state_change, backend_start))), 0)::numeric, 0) AS seconds, COALESCE(left(query, 160), '') AS query FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() ORDER BY 4 DESC LIMIT 12
                """)
            s.y = y2; s.w = 8
            var tx = w("tx", "kpi", "Transactions // total", 3, query: "SELECT xact_commit + xact_rollback AS value FROM pg_stat_database WHERE datname = current_database()")
            tx.x = 8; tx.y = y2
            out += [s, tx]
        case .mysql:
            var s = w("sessions", "table", "Sessions", 3, query: "SELECT ID AS id, USER AS user, LOWER(COMMAND) AS state, TIME AS seconds, COALESCE(LEFT(INFO, 160), '') AS query FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY TIME DESC LIMIT 12")
            s.y = y2; s.w = 12
            out.append(s)
        case .sqlite:
            var n = w("sessions", "text", "Sessions", 1, enc: ["markdown": DashEnc("SQLite runs in-process with a single connection, so there is no session list.")])
            n.y = y2; n.w = 12
            out.append(n)
        }
        return DashboardSpec(title: title, connection: ws.profile.name, refresh: "1m", widgets: out)
    }
}
