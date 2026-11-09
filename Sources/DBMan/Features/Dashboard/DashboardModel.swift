import AppKit
import DBCore
import DBManMCP
import DBStore
import Foundation
import Observation
import UniformTypeIdentifiers

/// One widget's result set.
struct WTable: Sendable {
    var columns: [String], rows: [[Cell]], ms: Double
    func index(_ name: String?) -> Int? { name.flatMap { n in columns.firstIndex { $0.lowercased() == n.lowercased() } } }
    func nums(_ i: Int?) -> [Double] { i.map { i in rows.map { DashData.num($0[i]) } } ?? [] }
    func strs(_ i: Int?) -> [String] { i.map { i in rows.map { $0[i].display } } ?? [] }
}

enum WState { case loading, ready(WTable, stale: Bool), failed(String) }

/// The dashboards of one workspace: the store's `dashboard` items (MINE and agent layers), the one on screen, its variables and data, edit mode, proposal review.
@MainActor @Observable
final class DashboardModel {
    struct Entry: Identifiable {
        var item: OverlayItem, spec: DashboardSpec?, layer: String, mine: Bool
        var id: String { item.id }
        var title: String { spec?.title ?? item.name ?? "Dashboard" }
    }

    private(set) var entries: [Entry] = []
    private(set) var itemID: String?
    var spec: DashboardSpec?
    var edit = false
    var selected: String?
    var values: [String: String] = [:]
    var options: [String: [String]] = [:]
    var data: [String: WState] = [:]
    var asTable: Set<String> = []
    var accepted: Set<String> = []
    var costs: [String: String] = [:]
    var notice: String?
    var updated: Date?
    private var conn = ""
    private var insightBase: DefaultDashboard.Base?
    private var rates: [String: (n: Double, at: Date, series: [Double])] = [:]
    private var store: Store { AppModel.shared.store }

    var entry: Entry? { entries.first { $0.id == itemID } }
    /// An agent's dashboard: reviewed as a proposal, never edited in place.
    var isProposal: Bool { entry.map { !$0.mine } ?? false }
    var defaultEntry: Entry? { entries.first { $0.mine } }
    func title(of id: String) -> String { entries.first { $0.id == id }?.title ?? "Dashboard" }

    // MARK: store

    func reload(_ ws: WorkspaceModel) {
        conn = ws.storeID
        let layers = (try? store.layers(conn)) ?? []
        entries = ((try? store.items(conn, kind: "dashboard")) ?? []).map { i in
            let l = layers.first { $0.id == i.layer }
            return Entry(item: i, spec: try? DashboardSpec.parse(i.payload), layer: l?.name ?? i.layer, mine: l?.isMine ?? false)
        }.sorted { $0.mine && !$1.mine } // stable: MINE first, then agents, each oldest first
        guard let itemID else { return }
        guard let e = entry else { self.itemID = nil; spec = nil; return }     // adopted, discarded or deleted elsewhere
        if !edit, let s = e.spec, s != spec { spec = s; Task { await refresh(ws) } } // an agent changed it (dashboard.update)
    }

    /// The first dashboard of a connection is "Overview // default" (the internal store seeds its own). Seeded once: a deleted default stays deleted.
    func ensureDefault(_ ws: WorkspaceModel) async {
        conn = ws.storeID
        let mine = Store.mineID(conn)
        guard ws.profile.environment != .system, ((try? store.items(conn, layers: [mine], kind: "dashboard", statuses: ["active", "stale", "adopted", "discarded"])) ?? []).isEmpty else { return }
        let s = await DefaultDashboard.make(ws)
        try? store.ensureMineLayer(conn)
        _ = try? store.addItem(layer: mine, kind: "dashboard", name: s.title, payload: s.json())
    }

    /// Shows a dashboard (nil = the default one) and loads its data.
    func open(_ id: String?, _ ws: WorkspaceModel) async {
        reload(ws)
        guard let e = id.flatMap({ id in entries.first { $0.id == id } }) ?? defaultEntry else { itemID = nil; spec = nil; return }
        guard e.id != itemID else { return }
        itemID = e.id; spec = e.spec
        edit = false; selected = nil; data = [:]; asTable = []; costs = [:]; rates = [:]; insightBase = nil; notice = nil
        accepted = Set(e.spec?.widgets.map(\.id) ?? [])
        values = Dictionary(uniqueKeysWithValues: (e.spec?.variables ?? []).compactMap { v in (v.default ?? (v.type == "enum" ? "all" : "30d")).isEmpty ? nil : (v.name, v.default ?? (v.type == "enum" ? "all" : "30d")) })
        await loadOptions(ws)
        await refresh(ws)
        if !e.mine { await loadCosts(ws) }
    }

    private func save() {
        guard let itemID, let spec else { return }
        do { try store.setPayload(itemID, name: spec.title, spec.json()) } catch { notice = error.localizedDescription }
    }

    // MARK: data

    func refresh(_ ws: WorkspaceModel, only: Set<String>? = nil) async {
        guard let s = ws.session, let spec else { return }
        let e = ws.profile.engine, id = itemID
        let jobs = spec.widgets.filter { ($0.query ?? "").isEmpty == false && (only?.contains($0.id) ?? true) }.map { w in
            (w, ws.layers.expand(DashSQL.bind(w.query ?? "", variables: spec.variables, values: values, engine: e), mysql: e == .mysql))
        }
        for (w, _) in jobs { if only != nil || data[w.id] == nil { data[w.id] = .loading } }
        func store(_ wid: String, _ r: Result<WTable, Error>) {
            guard id == itemID else { return }
            switch r {
            case .success(let t): data[wid] = .ready(t, stale: false)
            case .failure(let err):
                if case .ready(let t, _)? = data[wid] { data[wid] = .ready(t, stale: true) } else { data[wid] = .failed(err.localizedDescription) }
            }
        }
        await withTaskGroup(of: (String, Result<WTable, Error>).self) { g in
            for (w, sql) in jobs {
                if let src = DashSource.split(w.query ?? "") { store(w.id, await local(w, src, ws, s)) } else { g.addTask { (w.id, await Self.fetch(s, w, sql)) } }
            }
            for await (wid, r) in g { store(wid, r) }
        }
        updated = Date()
    }

    /// DashSource queries: snapshot estimates, the console, a per-second rate. Nothing here scans a table.
    private func local(_ w: DashWidget, _ src: (kind: String, arg: String), _ ws: WorkspaceModel, _ s: DatabaseSession) async -> Result<WTable, Error> {
        let t0 = Date()
        func table(_ cols: [String], _ rows: [[Cell]]) -> Result<WTable, Error> { .success(WTable(columns: cols, rows: rows, ms: Date().timeIntervalSince(t0) * 1000)) }
        switch src.kind {
        case "schema":
            let all = (ws.schema?.tables ?? []).filter { $0.kind == .table }
            if src.arg == "*" { return table(["rows", "bytes"], [[.integer(ws.schema?.totalRows ?? 0), .integer(ws.schema?.sizeBytes ?? 0)]]) }
            let ts = src.arg.isEmpty ? all.sorted { ($0.sizeBytes ?? $0.rowCount) > ($1.sizeBytes ?? $1.rowCount) } : all.filter { $0.name == src.arg }
            return table(["label", "rows", "bytes"], ts.map { [.text($0.name), .integer($0.rowCount), .integer($0.sizeBytes ?? 0)] })
        case "activity":
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            return table(["ts", "title", "status", "body"], ws.console.prefix(30).map { e in
                let kw = SQLClassifier.firstKeyword(e.sql)
                return [.text(f.string(from: e.at)), .text(e.isError ? "ERROR" : kw.isEmpty ? "EVENT" : kw), .text(e.isError ? "error" : ""),
                        .text(e.isError ? "\(e.summary) — \(e.sql)" : e.sql.replacingOccurrences(of: "\n", with: " "))]
            })
        case "insights":
            let base: DefaultDashboard.Base
            if let b = insightBase { base = b } else { base = await DefaultDashboard.detect(ws); insightBase = base } // detection samples columns: once per open
            let items = await DefaultDashboard.insights(ws, base), f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            return table(["ts", "title", "status", "body"], items.isEmpty ? [[.text(""), .text("Nothing new"), .text(""), .text("")]]
                         : items.map { [.text(f.string(from: Date())), .text($0.title), .text($0.warn ? "warn" : ""), .text($0.detail)] })
        default:
            let now = Date(), prev = rates[w.id]
            var counter = 0.0
            if src.arg != "console" {
                do { counter = DashData.num(try await s.run(src.arg, limit: 1).rows.first?.first) } catch { return .failure(DashError(message: Self.drift(error.localizedDescription))) }
            }
            var series = prev?.series ?? []
            if let p = prev, now.timeIntervalSince(p.at) < 1 { /* a refresh right behind another: keep the sample */ }
            else {
                if let p = prev {
                    let d = src.arg == "console" ? Double(ws.console.filter { $0.at > p.at }.count) : counter - p.n // a counter reset (restart) skips one sample
                    if d >= 0 { series = Array((series + [d / now.timeIntervalSince(p.at)]).suffix(60)) }
                }
                rates[w.id] = (counter, now, series)
            }
            if series.isEmpty { series = [0] } // first sample: nothing to difference yet
            return table(["x", "y", "value"], series.enumerated().map { [.integer(Int64($0)), .real($1), .real(series.last ?? 0)] })
        }
    }

    private nonisolated static func fetch(_ s: DatabaseSession, _ w: DashWidget, _ sql: String) async -> Result<WTable, Error> {
        guard ["SELECT", "WITH", "VALUES"].contains(SQLClassifier.firstKeyword(sql)) else { return .failure(DashError(message: "widgets run one read-only SELECT")) }
        do {
            let r = try await s.run(sql, limit: 500)
            if let missing = w.missingColumn(in: r.columns) { return .failure(DashError(message: "column `\(missing)` not found")) }
            return .success(WTable(columns: r.columns, rows: r.rows, ms: r.elapsedMs))
        } catch { return .failure(DashError(message: drift(error.localizedDescription))) }
    }

    /// "no such column: total" / `column "total" does not exist` / "Unknown column 'total'" → "column `total` not found" (G10).
    nonisolated static func drift(_ m: String) -> String {
        for (p, kind) in [(#"no such column: ([\w.]+)"#, "column"), (#"column "([\w.]+)" does not exist"#, "column"), (#"Unknown column '([\w.]+)'"#, "column"),
                          (#"no such table: ([\w.]+)"#, "table"), (#"relation "([\w.]+)" does not exist"#, "table"), (#"Table '(?:\w+\.)?(\w+)' doesn't exist"#, "table")] {
            if let re = try? NSRegularExpression(pattern: p), let hit = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)), let r = Range(hit.range(at: 1), in: m) {
                return "\(kind) `\(m[r].split(separator: ".").last ?? m[r])` not found"
            }
        }
        return m
    }

    func loadOptions(_ ws: WorkspaceModel) async {
        guard let s = ws.session else { return }
        for v in spec?.variables ?? [] where v.type == "enum" {
            guard let sql = v.sql, let r = try? await s.run(sql, limit: 50) else { continue }
            options[v.name] = ["all"] + r.rows.compactMap { $0.first?.display }
        }
    }

    /// EXPLAIN cost per widget for the proposal review (G18); production-sized plans show as 2.1e6.
    func loadCosts(_ ws: WorkspaceModel) async {
        guard let s = ws.session, let spec else { return }
        let e = ws.profile.engine
        for w in spec.widgets {
            guard let q = w.query, DashSource.split(q) == nil, let plan = try? await s.explain(DashSQL.bind(q, variables: spec.variables, values: values, engine: e), analyze: false) else { continue }
            costs[w.id] = plan.cost <= 0 ? "—" : plan.cost < 1000 ? String(Int(plan.cost.rounded())) : String(format: "%.1e", plan.cost).replacingOccurrences(of: "e+0", with: "e").replacingOccurrences(of: "e+", with: "e")
        }
    }

    func setValue(_ name: String, _ v: String, _ ws: WorkspaceModel) { values[name] = v; Task { await refresh(ws, only: Set((spec?.widgets ?? []).filter { ($0.query ?? "").contains(":" + name) }.map(\.id))) } }
    func setRefresh(_ r: String) { spec?.refresh = r; save() }

    // MARK: edit mode

    func toggleEdit() { guard !isProposal, spec != nil else { return }; edit.toggle(); if !edit { selected = nil } }
    func widget(_ id: String?) -> DashWidget? { spec?.widgets.first { $0.id == id } }

    func place(_ id: String, x: Int, y: Int, w: Int, h: Int) {
        guard let s = spec else { return }
        spec?.widgets = DashGrid.place(s.widgets, id: id, x: x, y: y, w: w, h: h); save()
    }

    func add(_ type: String, at: (x: Int, y: Int)? = nil, _ ws: WorkspaceModel) {
        guard let t = DashCatalog.type(type), let s = spec else { return }
        var n = s.widgets.count + 1
        while s.widgets.contains(where: { $0.id == "w\(n)" }) { n += 1 }
        let (w, h) = (max(t.minW, 3), max(t.minH, 2)), free = DashGrid.nextFree(s.widgets, w: w, h: h)
        var nw = DashWidget(id: "w\(n)", type: type, title: type, x: at?.x ?? free.x, y: at?.y ?? free.y, w: w, h: h)
        if type == "text" { nw.encoding = ["markdown": DashEnc("Note")] }
        if type == "er.mini" { nw.encoding = ["table": DashEnc(ws.schema?.tables.max { $0.rowCount < $1.rowCount }?.name ?? "")] }
        spec?.widgets.append(nw)
        if at != nil { spec?.widgets = DashGrid.place(spec!.widgets, id: nw.id, x: nw.x, y: nw.y, w: w, h: h) }
        selected = nw.id; save()
    }

    /// SAVE AS WIDGET (query tab): the statement becomes a table widget at the next free spot of the default dashboard, which opens.
    func saveQuery(_ sql: String, title: String, _ ws: WorkspaceModel) async {
        await open(nil, ws)
        guard !isProposal, spec != nil else { return }
        add("table", ws)
        guard let id = selected else { return }
        update(id, ws, refetch: true) { $0.query = sql; $0.title = title }
        ws.go(.dashboard(itemID ?? ""))
    }

    func remove(_ id: String) { spec?.widgets.removeAll { $0.id == id }; data[id] = nil; if selected == id { selected = nil }; save() }

    /// Inspector edit of one widget; `refetch` when the query, encoding or type changed.
    func update(_ id: String, _ ws: WorkspaceModel, refetch: Bool = false, _ body: (inout DashWidget) -> Void) {
        guard let i = spec?.widgets.firstIndex(where: { $0.id == id }) else { return }
        body(&spec!.widgets[i]); save()
        if refetch { data[id] = nil; Task { await self.refresh(ws, only: [id]) } }
    }

    func addVariable(_ type: String) {
        let n = (spec?.variables.filter { $0.type == type }.count ?? 0)
        spec?.variables.append(type == "timeRange" ? DashVariable(name: n == 0 ? "range" : "range\(n + 1)", type: type, default: "30d") : DashVariable(name: "filter\(n + 1)", type: type, sql: "SELECT DISTINCT col FROM tbl"))
        save()
    }
    func updateVariable(_ i: Int, _ ws: WorkspaceModel, _ body: (inout DashVariable) -> Void) {
        guard spec?.variables.indices.contains(i) == true else { return }
        body(&spec!.variables[i]); save(); Task { await loadOptions(ws) }
    }
    func removeVariable(_ i: Int) { spec?.variables.remove(at: i); save() }

    // MARK: dashboards

    @discardableResult
    private func addMine(_ s: DashboardSpec) -> String? {
        var s = s
        let taken = Set(entries.filter(\.mine).map(\.title))
        if taken.contains(s.title) { var n = 2; while taken.contains("\(s.title) (\(n))") { n += 1 }; s.title += " (\(n))" } // addItem replaces a same-named item: never clobber the human's
        try? store.ensureMineLayer(conn)
        do { let id = try store.addItem(layer: Store.mineID(conn), kind: "dashboard", name: s.title, payload: s.json()); reloadSoon(); return id } catch { notice = error.localizedDescription; return nil }
    }
    private func reloadSoon() { AppModel.shared.reload() }

    func create(_ ws: WorkspaceModel) {
        if let id = addMine(DashboardSpec(title: "Untitled dashboard", connection: ws.profile.name)) { ws.go(.dashboard(id)) }
    }
    /// START FROM TEMPLATE: fills this empty dashboard with a seeded spec.
    func useTemplate(_ i: Int, _ ws: WorkspaceModel) async {
        let s = await DefaultDashboard.template(i, ws)
        spec?.title = s.title; spec?.widgets = s.widgets; spec?.refresh = s.refresh
        save(); await refresh(ws)
    }
    func duplicate(_ ws: WorkspaceModel) {
        guard var s = spec else { return }
        s.title += " // copy"
        if let id = addMine(s) { ws.go(.dashboard(id)) }
    }
    func delete(_ ws: WorkspaceModel) {
        guard let id = itemID else { return }
        try? store.setStatus([id], "discarded"); reloadSoon()
        ws.closeTab(ws.route); if ws.route == .overview { Task { await open(nil, ws) } }
    }

    func exportJSON() {
        guard let spec else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]; p.nameFieldStringValue = spec.title.replacingOccurrences(of: " // ", with: "-").replacingOccurrences(of: " ", with: "-").lowercased() + ".json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try spec.json(pretty: true).write(to: url, atomically: true, encoding: .utf8); notice = "Exported \(url.lastPathComponent)" } catch { notice = error.localizedDescription }
    }
    func importJSON(_ ws: WorkspaceModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            var s = try DashboardSpec.parse(try String(contentsOf: url, encoding: .utf8))
            if let bad = s.validate().first(where: \.fatal) { notice = "Not imported: " + bad.message; return }
            s.connection = ws.profile.name
            if let id = addMine(s) { ws.go(.dashboard(id)) }
        } catch { notice = "Not imported: " + error.localizedDescription }
    }

    // MARK: proposals (F5)

    /// ADOPT N OF M: the accepted widgets become a dashboard in MINE and the proposal is marked adopted.
    func adopt(_ ws: WorkspaceModel) {
        guard var s = spec, let id = itemID else { return }
        s.widgets = s.widgets.filter { accepted.contains($0.id) && !failed($0.id) }
        guard !s.widgets.isEmpty, let new = addMine(s) else { return }
        try? store.setStatus([id], "adopted"); reloadSoon()
        ws.closeTab(.dashboard(id)); ws.go(.dashboard(new))
    }

    /// ASK FOR CHANGES: the proposal is discarded with a note the agent reads in overlay.status (the P3 discard-note mechanism).
    func askForChanges(_ note: String, _ ws: WorkspaceModel) {
        guard let e = entry else { return }
        try? store.discard(layer: e.item.layer, ids: [e.id], note: "Changes requested on dashboard \"\(e.title)\": \(note)"); reloadSoon()
        ws.closeTab(.dashboard(e.id)); ws.go(.overview)
    }

    // MARK: agents

    /// GENERATE WITH AGENT: the build-dashboard prompt on the clipboard (there is no channel into a running agent).
    func copyBuildPrompt(_ ws: WorkspaceModel, goal: String, agent: String?) {
        copy("Use the dbman MCP server. " + MCPService.buildDashboardPrompt(connection: ws.profile.name, goal: goal))
        notice = agent.map { "PROMPT COPIED // PASTE INTO \($0.uppercased())" } ?? "PROMPT COPIED // PASTE INTO ANY AGENT WITH DBMAN MCP"
    }

    /// ASK AGENT TO FIX (G10): dashboard.get + the error as a prompt. MINE is read-only for agents, so the fix arrives as a new proposal.
    func copyFixPrompt(_ w: DashWidget, error: String, _ ws: WorkspaceModel) {
        guard let e = entry else { return }
        let how = e.mine ? "You cannot edit MINE; call dashboard.create with the corrected spec (same title) and I will adopt it."
                         : "Apply the fix with dashboard.update {id, ops: [{op: replace, path: /widgets/N/query, value: ...}]}."
        copy("Use the dbman MCP server. In DBMan, widget \"\(w.title)\" (id \(w.id)) of dashboard \"\(e.title)\" (id \(e.id), connection \(ws.profile.name)) fails: \(error). Call dashboard.get {id: \"\(e.id)\"}, check the current columns with schema.describe, fix the query, test it with query.run. \(how)")
        notice = "PROMPT COPIED // PASTE INTO YOUR AGENT"
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}
