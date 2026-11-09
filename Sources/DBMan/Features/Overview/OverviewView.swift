import DBCore
import Halftone
import SwiftUI

private struct SessionRow: Identifiable {
    let id: String
    var user: String, state: String, secs: Double, query: String
    var stuck: Bool { state == "idle in transaction" && secs > 60 }
}

/// Dashboard data. All SQL goes through the session actor; failures just leave a section empty.
@MainActor @Observable
private final class OverviewModel {
    var records: [Double] = []
    var recordsTable: String?
    var cat: CategoryData?
    var nulls: [(table: String, column: String, fraction: Double)] = []
    var unused: [(table: String, index: String)] = []
    var sessions: [SessionRow] = []
    var tx: [Double] = []
    private var prev: (count: Double, at: Date)?

    func loadRecords(_ ws: WorkspaceModel, _ w: OverviewWindow) async {
        guard let s = ws.session, let schema = ws.schema else { return }
        let e = ws.profile.engine
        for t in schema.tables.filter({ $0.kind == .table }).sorted(by: { $0.rowCount > $1.rowCount }) {
            guard let col = OverviewLogic.dateColumn(t) else { continue }
            let keys = OverviewLogic.keys(now: (await latest(s, e, t.name, col)).addingTimeInterval(w.hourly ? -3600 : -86400), hourly: w.hourly, count: w.count)
            let r = try? await s.run(OverviewLogic.growthSQL(e, table: t.name, dateCol: col, keys: keys, hourly: w.hourly))
            records = OverviewLogic.fill((r?.rows ?? []).map { ($0[0].display, OverviewLogic.num($0[1])) }, keys: keys)
            recordsTable = t.name
            return
        }
        records = []; recordsTable = nil
    }

    /// Category series (first big table with a timestamp + low-cardinality text column), null scan, unused indexes.
    func loadStatic(_ ws: WorkspaceModel) async {
        guard let s = ws.session, let schema = ws.schema else { return }
        let e = ws.profile.engine
        // Tables with a `status`/`state` column first: that is the category people track over time.
        let hasStatus = { (t: TableInfo) in t.columns.contains { ["status", "state"].contains($0.name.lowercased()) } }
        let big = schema.tables.filter { $0.kind == .table }.sorted { $0.rowCount > $1.rowCount }.prefix(4).sorted { hasStatus($0) && !hasStatus($1) }
        var found = false
        for (i, t) in big.enumerated() {
            guard let stats = try? await s.columnStats(table: t.name) else { continue }
            if i < 2 {
                for st in stats where st.nullFraction > 0.4 && t.columns.first(where: { $0.name == st.column })?.nullable == true {
                    nulls.append((t.name, st.column, st.nullFraction))
                }
            }
            guard !found, let dc = OverviewLogic.dateColumn(t) else { continue }
            let textish = t.columns.filter { c in
                let ty = c.type.lowercased()
                return c.name != dc && !c.isPrimaryKey && (ty.isEmpty || ty.contains("char") || ty.contains("text") || ty.contains("enum"))
            }.map(\.name)
            let cands = stats.filter { textish.contains($0.column) && (2...8).contains($0.distinct ?? 99) }
            guard let c = cands.first(where: { $0.column.lowercased() == "status" }) ?? cands.first else { continue }
            let top = c.topValues.map(\.value)
            let names = Array((top.filter { !OverviewLogic.isAttention($0) }.prefix(3) + top.filter(OverviewLogic.isAttention)).prefix(4))
            async let d = series(s, e, t.name, dc, c.column, names, hourly: false, count: 14)
            async let h = series(s, e, t.name, dc, c.column, names, hourly: true, count: 24)
            cat = CategoryData(table: t.name, dateColumn: dc, column: c.column, names: names, daily: await d, hourly: await h)
            found = true
        }
        if e == .postgres {
            let r = try? await s.run("""
                SELECT s.relname::text, s.indexrelname::text FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
                WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 5
                """, limit: 5)
            unused = (r?.rows ?? []).map { ($0[0].display, $0[1].display) }
        }
    }

    private func series(_ s: DatabaseSession, _ e: Engine, _ table: String, _ dc: String, _ cc: String, _ names: [String], hourly: Bool, count: Int) async -> [[Double]] {
        let keys = OverviewLogic.keys(now: (await latest(s, e, table, dc)).addingTimeInterval(hourly ? -3600 : -86400), hourly: hourly, count: count) // last complete bucket
        let r = try? await s.run(OverviewLogic.categorySQL(e, table: table, dateCol: dc, catCol: cc, names: names, keys: keys, hourly: hourly))
        return names.map { n in OverviewLogic.fill((r?.rows ?? []).filter { $0[1].display == n }.map { ($0[0].display, OverviewLogic.num($0[2])) }, keys: keys) }
    }

    /// Newest timestamp in the column (falls back to now). Text dates are parsed as ISO prefixes.
    private func latest(_ s: DatabaseSession, _ e: Engine, _ table: String, _ col: String) async -> Date {
        let r = try? await s.run("SELECT MAX(\(quoteIdent(col, e))) FROM \(quoteIdent(table, e))", limit: 1)
        switch r?.rows.first?.first {
        case .date(let d)?: return d
        case .text(let t)?: return OverviewLogic.parseDate(t) ?? Date()
        default: return Date()
        }
    }

    /// One 5 s poll: transaction/query counter -> rate sample, plus the session list.
    func tick(_ ws: WorkspaceModel) async {
        guard let s = ws.session else { return }
        let now = Date()
        var counter: Double?
        switch ws.profile.engine {
        case .postgres:
            counter = (try? await s.run("SELECT (xact_commit + xact_rollback)::float8 FROM pg_stat_database WHERE datname = current_database()", limit: 1))?.rows.first.map { OverviewLogic.num($0[0]) }
            let r = try? await s.run("""
                SELECT pid::text, COALESCE(usename, '')::text, COALESCE(state, '')::text,
                       COALESCE(EXTRACT(EPOCH FROM (now() - COALESCE(state_change, backend_start))), 0)::float8, COALESCE(left(query, 160), '')::text
                FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() ORDER BY 4 DESC LIMIT 12
                """, limit: 12)
            sessions = (r?.rows ?? []).map { SessionRow(id: $0[0].display, user: $0[1].display, state: $0[2].display, secs: OverviewLogic.num($0[3]), query: $0[4].display) }
        case .mysql:
            counter = (try? await s.run("SHOW GLOBAL STATUS LIKE 'Questions'", limit: 1))?.rows.first.map { OverviewLogic.num($0[1]) }
            let r = try? await s.run("SELECT ID, USER, COMMAND, TIME, COALESCE(LEFT(INFO, 160), '') FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() ORDER BY TIME DESC LIMIT 12", limit: 12)
            sessions = (r?.rows ?? []).map { SessionRow(id: $0[0].display, user: $0[1].display, state: $0[2].display.lowercased(), secs: OverviewLogic.num($0[3]), query: $0[4].display) }
        case .sqlite:
            // queries run from this app in the last interval
            let n = ws.console.filter { $0.at > now.addingTimeInterval(-5) }.count
            push(Double(n) / 5)
            return
        }
        if let c = counter, let p = prev, c >= p.count, now > p.at { push((c - p.count) / now.timeIntervalSince(p.at)) }
        if let c = counter { prev = (c, now) }
    }
    private func push(_ v: Double) { tx = Array((tx + [v]).suffix(60)) }
}

struct OverviewView: View {
    let ws: WorkspaceModel
    @State private var model = OverviewModel()
    @State private var win = 0
    @State private var catLive = false

    private let rail: [(number: String, title: String)] = OverviewWindow.allCases.map { (String(format: "%02d", $0.rawValue + 1), $0.title) }
    private var window: OverviewWindow { OverviewWindow(rawValue: win) ?? .live }
    private var tables: [TableInfo] { (ws.schema?.tables ?? []).filter { $0.kind == .table } }
    private var largest: [TableInfo] { tables.sorted { $0.rowCount > $1.rowCount } }
    private var engine: Engine { ws.profile.engine }

    var body: some View {
        HStack(spacing: HT.M.gap) {
            NumberRail(items: rail, selection: $win)
            HStack(spacing: HT.M.gap) {
                VStack(spacing: HT.M.gap) { header; entities; overTime }.frame(width: 290)
                VStack(spacing: HT.M.gap) {
                    HStack(spacing: HT.M.gap) { records; txFrame }.frame(height: 196)
                    insightsFrame
                    sessionsFrame.frame(height: 168)
                }
                VStack(spacing: HT.M.gap) { activity; footprint.frame(height: 210) }.frame(width: 280)
            }
        }
        .task {
            #if DEBUG
            OverviewLogic.selfCheck()
            #endif
            await model.loadStatic(ws)
        }
        .task(id: win) { await model.loadRecords(ws, window) }
        // cancelled automatically when the view disappears
        .task { while !Task.isCancelled { await model.tick(ws); try? await Task.sleep(for: .seconds(5)) } }
    }

    // MARK: frames
    private func empty(_ s: String) -> some View {
        Text(s).ht(.label).foregroundStyle(HT.C.ink3).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HTFrame(title: "Dashboard", tail: Date().formatted(.dateTime.weekday(.wide).month(.wide).day(.twoDigits)).uppercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ",", with: "")) {
            Text("\(ws.profile.name) · \(engine.displayName)").ht(.strong).padding(8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var entities: some View {
        HTFrame(title: "Entities") {
            HStack(spacing: 12) {
                ForEach(Array(largest.prefix(2).enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Rectangle().fill(HT.C.line).frame(width: 1, height: 48) }
                    Readout(value: HTFormat.compact(t.rowCount), label: t.name, size: .m).frame(maxWidth: .infinity)
                }
                if largest.isEmpty { empty("NO_TABLES") }
            }.padding(10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overTime: some View {
        let cat = model.cat
        return HTFrame(title: "\(cat?.table ?? "Table")_over_time", accessory: {
            HTSegmented(selection: $catLive, options: [(true, "LIVE"), (false, "14_DAYS")])
        }) {
            if let cat {
                let styles = styles(cat)
                VStack(alignment: .leading, spacing: 6) {
                    LineChart(series: catLive ? cat.hourly : cat.daily, styles: styles, markers: false,
                              accessibilityLabel: "\(cat.table) by \(cat.column)").frame(maxHeight: .infinity)
                    HStack(spacing: 12) {
                        ForEach(Array(cat.names.enumerated()), id: \.offset) { i, n in
                            Text("\(n.uppercased())").ht(.labelSmall).foregroundStyle(styles[i] == .amber ? HT.C.amber : HT.C.ink.opacity(styles[i] == .solid ? 1 : styles[i] == .ink55 ? 0.55 : 0.3))
                        }
                    }
                }.padding(10)
            } else { empty("NO_TIMESTAMP_+_CATEGORY_COLUMN") }
        }
    }

    private func styles(_ c: CategoryData) -> [LineStyle] {
        var plain: [LineStyle] = [.solid, .ink55, .ink30]
        return c.names.map { OverviewLogic.isAttention($0) ? .amber : (plain.isEmpty ? .ink30 : plain.removeFirst()) }
    }

    private var records: some View {
        HTFrame(title: "Records", tail: window.title) {
            VStack(alignment: .leading, spacing: 6) {
                Readout(value: HTFormat.grouped(ws.schema?.totalRows ?? 0), label: "Rows", tail: model.recordsTable, size: .l)
                if model.records.count > 1 && model.records.contains(where: { $0 > 0 }) {
                    LineChart(series: [model.records], markers: false, accessibilityLabel: "Rows added per \(window.hourly ? "hour" : "day")").frame(maxHeight: .infinity)
                } else { empty("NO_TIMESTAMPED_ROWS") }
            }.padding(10)
        }
    }

    private var txFrame: some View {
        HTFrame(title: "Tx/s", tail: "Live") {
            VStack(alignment: .leading, spacing: 6) {
                Readout(value: model.tx.last.map { $0 < 10 ? String(format: "%.1f", $0) : String(Int($0.rounded())) } ?? "—", label: engine == .sqlite ? "Queries/s" : "Rate", size: .l)
                if model.tx.count > 1 { LineChart(series: [model.tx], markers: false, accessibilityLabel: "Transactions per second").frame(maxHeight: .infinity) }
                else { empty("SAMPLING…") }
            }.padding(10)
        }
    }

    private var insightsFrame: some View {
        let list = OverviewLogic.insights(tables: tables, cat: model.cat, nulls: model.nulls, unusedIndexes: model.unused, engine: engine)
        return HTFrame(title: "Insights", tail: "New_in_24_hours") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list) { i in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.title).ht(.label).foregroundStyle(i.warn ? HT.C.amber : HT.C.ink)
                                    .lineLimit(1).truncationMode(.middle).help(i.title)
                                Text(i.detail).ht(.bodySmall).foregroundStyle(HT.C.ink2)
                            }
                            Spacer(minLength: 4)
                            if let sql = i.sql { Button("RESOLVE") { ws.newQuery(sql: sql) }.buttonStyle(.htOutline) }
                            if let t = i.table { Button("OPEN") { ws.go(.table(t)) }.buttonStyle(.htOutline) }
                        }
                    }
                    if list.isEmpty { Text("NOTHING_NEW").ht(.label).foregroundStyle(HT.C.ink3) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sessionsFrame: some View {
        HTFrame(title: "Sessions", tail: engine == .sqlite ? "Single_connection" : "\(model.sessions.count)") {
            if engine == .sqlite {
                Text("SQLite runs in-process with a single connection, so there is no session list.").ht(.bodySmall).foregroundStyle(HT.C.ink2).padding(10)
            } else {
                VStack(spacing: 6) {
                    BarSpectrum(values: model.sessions.map(\.secs), accessibilityLabel: "Session durations").frame(height: 28)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.sessions) { s in
                                HStack(spacing: 8) {
                                    Text(s.id).frame(width: 44, alignment: .leading)
                                    Text(s.user).frame(width: 60, alignment: .leading).lineLimit(1)
                                    Text(s.state.isEmpty ? "—" : s.state).frame(width: 110, alignment: .leading).lineLimit(1).foregroundStyle(s.stuck ? HT.C.amber : HT.C.ink2)
                                    Text(s.secs < 60 ? "\(Int(s.secs))s" : "\(Int(s.secs / 60))m").frame(width: 36, alignment: .trailing).foregroundStyle(s.stuck ? HT.C.amber : HT.C.ink)
                                    Text(s.query).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(HT.C.ink2)
                                }.ht(.dataSmall)
                            }
                            if model.sessions.isEmpty { Text("NO_OTHER_SESSIONS").ht(.label).foregroundStyle(HT.C.ink3) }
                        }
                    }
                }.padding(10)
            }
        }
    }

    private var activity: some View {
        HTFrame(title: "Activity_feed") {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ws.console.prefix(10)) { e in
                            let kw = SQLClassifier.firstKeyword(e.sql)
                            ActivityItem(icon: e.isError ? "exclamationmark.triangle" : kw == "COMMIT" ? "checkmark" : "bolt",
                                         title: e.isError ? "ERROR" : kw.isEmpty ? "EVENT" : kw,
                                         detail: e.isError ? "\(e.summary) — \(e.sql)" : e.sql.replacingOccurrences(of: "\n", with: " "),
                                         time: OverviewLogic.ago(e.at, now: ctx.date), tone: e.isError ? .alert : .normal)
                        }
                        if ws.console.isEmpty { Text("NO_ACTIVITY_YET").ht(.label).foregroundStyle(HT.C.ink3) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footprint: some View {
        let rows = tables.sorted { ($0.sizeBytes ?? $0.rowCount) > ($1.sizeBytes ?? $1.rowCount) }.prefix(6)
        let top = Double(rows.first.map { $0.sizeBytes ?? $0.rowCount } ?? 1)
        return HTFrame(title: "Footprint", tail: ws.schema?.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }) {
            VStack(spacing: 6) {
                ForEach(Array(rows)) { t in
                    let v = t.sizeBytes ?? t.rowCount
                    Button { ws.go(.table(t.name)) } label: {
                        VStack(spacing: 3) {
                            HStack {
                                Text(t.name).ht(.dataSmall)
                                Spacer()
                                Text(t.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "\(HTFormat.compact(t.rowCount)) rows")
                                    .ht(.dataSmall).foregroundStyle(HT.C.ink3)
                            }
                            SegmentedMeter(value: top > 0 ? Double(v) / top : 0, segments: 24, accessibilityLabel: t.name)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Open table")
                }
                Spacer(minLength: 0)
            }.padding(10)
        }
    }
}
