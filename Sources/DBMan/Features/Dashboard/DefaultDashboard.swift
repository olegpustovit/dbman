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
/// Row counts and footprint come from the schema snapshot's estimates (DashSource), never COUNT(*); activity and the tx/s rate are DashSource too.
@MainActor enum DefaultDashboard {
    static let title = "Overview · default"

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
    static func isAttention(_ name: String) -> Bool { ["pending", "failed", "error", "warn", "cancelled", "canceled"].contains(name.lowercased()) }

    static func make(_ ws: WorkspaceModel) async -> DashboardSpec {
        let e = ws.profile.engine, tables = (ws.schema?.tables ?? []).filter { $0.kind == .table }.sorted { $0.rowCount > $1.rowCount }
        var top: [DashWidget] = []
        func w(_ id: String, _ type: String, _ title: String, _ h: Int, query: String? = nil, enc: [String: DashEnc]? = nil) -> DashWidget {
            DashWidget(id: id, type: type, title: title, x: 0, y: 0, w: 4, h: h, query: query, encoding: enc)
        }
        for (i, t) in tables.prefix(2).enumerated() { top.append(w("rows\(i + 1)", "kpi", "\(t.name) · rows", 2, query: "schema:\(t.name)", enc: ["value": DashEnc("rows")])) }
        // records added per day on the biggest table with a timestamp
        if let t = tables.first(where: { dateColumn($0) != nil }), let dc = dateColumn(t) {
            top.append(w("growth", "kpi.spark", "\(t.name) · added per day", 2, query: """
                SELECT x, y, (SELECT COUNT(*) FROM \(quoteIdent(t.name, e)) WHERE \(since(e, t.name, dc))) AS value FROM (SELECT \(bucket(e, dc)) AS x, COUNT(*) AS y FROM \(quoteIdent(t.name, e)) WHERE \(since(e, t.name, dc)) GROUP BY 1) d ORDER BY x
                """, enc: ["x": DashEnc("x"), "y": DashEnc("y")]))
        }
        // live rate: transactions/s (Postgres), questions/s (MySQL), or this app's own queries/s (SQLite has no server counter)
        top.append(w("rate", "kpi.spark", e == .postgres ? "Tx/s" : "Queries/s", 2, query: {
            switch e {
            case .postgres: "rate:SELECT xact_commit + xact_rollback AS value FROM pg_stat_database WHERE datname = current_database()"
            // shortcut: MariaDB keeps it in information_schema (its performance_schema.global_status is empty); MySQL 5.6 has neither, upgrade by falling back to SHOW
            case .mysql: "rate:SELECT VARIABLE_VALUE FROM \(ws.schema?.serverVersion.contains("MariaDB") == true ? "information_schema.GLOBAL_STATUS" : "performance_schema.global_status") WHERE VARIABLE_NAME = 'Questions'"
            case .sqlite: "rate:console"
            }
        }(), enc: ["x": DashEnc("x"), "y": DashEnc("y")]))
        top[top.count - 1].format = DashFormat(unit: nil, compact: nil, decimals: 1)
        let base = await detect(ws)
        let line = base.sql.map { w("over_time", "line", "\(base.table) · over time", 4, query: $0, enc: ["x": DashEnc("day"), "y": DashEnc("n"), "series": DashEnc("category")]) }
        var out: [DashWidget] = []
        let share = top.isEmpty ? 12 : 12 / top.count
        for (i, var t) in top.enumerated() { t.x = i * share; t.w = i == top.count - 1 ? 12 - i * share : share; out.append(t) }
        let y1 = top.isEmpty ? 0 : 2
        let bytes = tables.contains { $0.sizeBytes != nil }
        var foot = w("footprint", "bars.horizontal", "Footprint · \(bytes ? "bytes" : "rows")", 4, query: "schema:", enc: ["label": DashEnc("label"), "value": DashEnc(bytes ? "bytes" : "rows")])
        if bytes { foot.format = DashFormat(unit: "B", compact: nil, decimals: nil) }
        if var l = line { l.x = 0; l.y = y1; l.w = 8; out.append(l); foot.x = 8; foot.y = y1; foot.w = 4 } else { foot.x = 0; foot.y = y1; foot.w = 12 }
        out.append(foot)
        // insights and activity: v1's two lists, both live (DashSource)
        var ins = w("insights", "status.feed", "Insights", 4, query: "insights:", enc: ["ts": DashEnc("ts"), "title": DashEnc("title"), "status": DashEnc("status"), "body": DashEnc("body")])
        var act = w("activity", "status.feed", "Activity feed", 4, query: "activity:", enc: ["ts": DashEnc("ts"), "title": DashEnc("title"), "status": DashEnc("status"), "body": DashEnc("body")])
        let y2 = y1 + 4
        ins.x = 0; ins.y = y2; ins.w = 6; act.x = 6; act.y = y2; act.w = 6
        out += [ins, act]
        let y3 = y2 + 4
        switch e {
        case .postgres:
            var s = w("sessions", "table", "Sessions", 3, query: """
                SELECT pid::text AS pid, COALESCE(usename, '') AS "user", COALESCE(state, '') AS state, round(COALESCE(EXTRACT(EPOCH FROM (now() - COALESCE(state_change, backend_start))), 0)::numeric, 0) AS seconds, COALESCE(left(query, 160), '') AS query FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() ORDER BY 4 DESC LIMIT 12
                """)
            s.y = y3; s.w = 12
            out.append(s)
        case .mysql:
            var s = w("sessions", "table", "Sessions", 3, query: "SELECT ID AS id, USER AS user, LOWER(COMMAND) AS state, TIME AS seconds, COALESCE(LEFT(INFO, 160), '') AS query FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY TIME DESC LIMIT 12")
            s.y = y3; s.w = 12
            out.append(s)
        case .sqlite:
            var n = w("sessions", "text", "Sessions", 1, enc: ["markdown": DashEnc("SQLite runs in-process with a single connection, so there is no session list.")])
            n.y = y3; n.w = 12
            out.append(n)
        }
        return DashboardSpec(title: title, connection: ws.profile.name, refresh: "30s", widgets: out)
    }

    /// "Start from template" (DashGen board): subsets of the Overview's own widgets over this connection's tables, re-packed into rows.
    /// shortcut: the blurbs are the board's copy, but the widgets are schema-generic (row counts, growth, status over time, footprint, sessions), so no domain metrics; upgrade by letting an agent propose a tailored default.
    static let templates: [(name: String, blurb: String, ids: [String]?, thumb: [[CGFloat]])] = [
        ("Sales health", "revenue, orders, AOV, top products, refunds", ["rows1", "rows2", "growth", "over_time", "footprint"], [[3, 3, 6, 4], [10, 3, 6, 4], [17, 3, 6, 4], [24, 3, 7, 4], [3, 9, 19, 12], [24, 9, 7, 12]]),
        ("Ops health", "sessions, locks, slow queries, bloat", ["rate", "insights", "activity", "sessions"], [[3, 3, 13, 8], [18, 3, 13, 8], [3, 13, 28, 8]]),
        ("Product usage", "events by day, funnels, cohorts", ["growth", "over_time", "footprint"], [[3, 3, 28, 8], [3, 13, 9, 8], [14, 13, 8, 8], [24, 13, 7, 8]]),
        ("Overview · default", "the v1 overview, as a dashboard", nil, [[3, 3, 8, 18], [13, 3, 18, 6], [13, 11, 18, 10]]),
    ]

    static func template(_ i: Int, _ ws: WorkspaceModel) async -> DashboardSpec {
        var s = await make(ws)
        guard let ids = templates[i].ids else { return s }
        let picked = s.widgets.filter { ids.contains($0.id) }
        let rest = picked.filter { $0.h != 2 }
        let rows = [picked.filter { $0.h == 2 }] + stride(from: 0, to: rest.count, by: 2).map { Array(rest[$0..<min($0 + 2, rest.count)]) }
        var out: [DashWidget] = [], y = 0
        for var row in rows where !row.isEmpty {
            for k in row.indices { row[k].x = k * (12 / row.count); row[k].w = k == row.count - 1 ? 12 - k * (12 / row.count) : 12 / row.count; row[k].y = y }
            y += row.map(\.h).max() ?? 0; out += row
        }
        s.title = "\(templates[i].name) · \(ws.profile.name)"; s.widgets = out
        return s
    }

    /// What the Overview tracks over time and its null scan: the first big table with a timestamp and a low-cardinality text column (status first).
    struct Base { var table = "", column = "", names: [String] = [], sql: String?, nulls: [(table: String, column: String, fraction: Double)] = [] }

    static func detect(_ ws: WorkspaceModel) async -> Base {
        let e = ws.profile.engine, tables = (ws.schema?.tables ?? []).filter { $0.kind == .table }.sorted { $0.rowCount > $1.rowCount }
        var base = Base()
        guard let s = ws.session else { return base }
        var stats: [String: [ColumnStats]] = [:]
        for t in tables.prefix(4) { stats[t.name] = try? await s.columnStats(table: t.name) }
        for t in tables.prefix(2) {
            for st in stats[t.name] ?? [] where st.nullFraction > 0.4 && t.columns.first(where: { $0.name == st.column })?.nullable == true { base.nulls.append((t.name, st.column, st.nullFraction)) }
        }
        let hasStatus = { (t: TableInfo) in t.columns.contains { ["status", "state"].contains($0.name.lowercased()) } }
        for t in tables.prefix(4).sorted(by: { hasStatus($0) && !hasStatus($1) }) {
            guard let dc = dateColumn(t), let stats = stats[t.name] else { continue }
            let textish = t.columns.filter { c in
                let ty = c.type.lowercased()
                return c.name != dc && !c.isPrimaryKey && (ty.isEmpty || ty.contains("char") || ty.contains("text") || ty.contains("enum"))
            }.map(\.name)
            let cands = stats.filter { textish.contains($0.column) && (2...8).contains($0.distinct ?? 99) }
            guard let c = cands.first(where: { $0.column.lowercased() == "status" }) ?? cands.first else { continue }
            let vals = c.topValues.map(\.value), names = Array((vals.filter { !isAttention($0) }.prefix(3) + vals.filter(isAttention)).prefix(4))
            let cc = quoteIdent(c.column, e)
            base.table = t.name; base.column = c.column; base.names = names
            base.sql = """
                SELECT \(bucket(e, dc)) AS day, \(cc) AS category, COUNT(*) AS n FROM \(quoteIdent(t.name, e)) WHERE \(since(e, t.name, dc)) AND \(cc) IN (\(names.map { Cell.text($0).sqlLiteral(e) }.joined(separator: ", "))) GROUP BY 1, 2 ORDER BY 1
                """
            break
        }
        return base
    }

    /// v1's Insights, per refresh: biggest-table share, fastest-growing category value (last 7 days vs the 7 before), mostly-NULL column, unused Postgres index.
    static func insights(_ ws: WorkspaceModel, _ base: Base) async -> [DashInsights.Item] {
        guard let s = ws.session else { return [] }
        var growth: [(value: String, last: Double, prior: Double)] = []
        if let sql = base.sql, let r = try? await s.run(sql, limit: 500), let newest = r.rows.compactMap({ DashData.date($0[0]) }).max() {
            var last: [String: Double] = [:], prior: [String: Double] = [:]
            for row in r.rows {
                guard let d = DashData.date(row[0]) else { continue }
                let age = Int(newest.timeIntervalSince(d) / 86400), name = row[1].display
                if age < 7 { last[name, default: 0] += DashData.num(row[2]) } else if age < 14 { prior[name, default: 0] += DashData.num(row[2]) }
            }
            growth = base.names.map { ($0, last[$0] ?? 0, prior[$0] ?? 0) }
        }
        var unused: [(table: String, index: String)] = []
        if ws.profile.engine == .postgres, let r = try? await s.run("""
            SELECT s.relname::text, s.indexrelname::text FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
            WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 5
            """, limit: 5) { unused = r.rows.map { ($0[0].display, $0[1].display) } }
        let tables = (ws.schema?.tables ?? []).filter { $0.kind == .table }
        return DashInsights.make(tables: tables, table: base.table, column: base.column, growth: growth, nulls: base.nulls, unusedIndexes: unused, attention: isAttention)
    }
}
