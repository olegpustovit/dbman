import AppKit
import DBCore
import Halftone
import SwiftUI

/// Filters handed to the next-opened table (FK follow / child-row links); `ws.go` carries no payload.

/// What the grid shows: database rows with store layers merged, then staged changes; `src` maps back to `rows` (-1: a layer's insert).
private typealias Shown = (rows: [[Cell]], src: [Int], marks: [Int: Set<Int>], stale: Set<Int>)

private struct EditTarget: Identifiable { let id = UUID(); var src: Int; var col: Int; var text: String; var isNull: Bool }

struct TableBrowserView: View {
    let ws: WorkspaceModel
    let tableName: String

    @State private var tab = DevHooks.view
    @Environment(AppModel.self) private var app
    private var pageSize: Int { app.pageSize } // Settings → Results
    @State private var whereText = ""
    @State private var applied = ""
    @State private var sort: TableSQL.Sort?
    @State private var columnNames: [String] = []
    @State private var rows: [[Cell]] = []
    @State private var done = false
    @State private var loading = false
    @State private var loadStarted = Date()
    @State private var savedWidths: [String: CGFloat] = [:]
    @State private var statsLoading = false
    @State private var statsStarted = Date()
    @State private var gen = 0
    @State private var error: String?
    @State private var notice: String?
    @State private var stats: [ColumnStats] = []
    @State private var selection: Int?
    @State private var focused = 0
    @State private var edit: EditTarget?
    @State private var confirmDelete = false

    private var info: TableInfo? { ws.schema?.table(tableName) }
    private var engine: Engine { ws.profile.engine }
    private var pk: [String] { info?.primaryKey ?? [] }
    private var mine: [StagedChange] { ws.staged.items.filter { $0.table == tableName } }

    var body: some View {
        let d = display
        HStack(spacing: HT.M.seam) {
            NumberRail(items: [("01", "Data"), ("02", "Structure"), ("03", "Relations"), ("04", "Stats")], selection: $tab)
            VStack(spacing: HT.M.seam) {
                HStack(spacing: HT.M.seam) {
                    mainFrame(d)
                    if ws.showInspector, tab == 0, !ws.layers.open {
                        AgentsInspector(ws: ws) {
                            TableInspector(ws: ws, info: info, columns: columnNames, row: selection.flatMap { $0 < d.rows.count ? d.rows[$0] : nil },
                                           focused: $focused, stats: stats, statsLoading: statsLoading, statsStarted: statsStarted, staged: mine, onFollow: { follow($0, in: d.rows) })
                        }
                        .frame(width: HT.M.inspector)
                    }
                }
                if ws.showConsole { ConsolePanel(ws: ws).frame(height: 160) }
            }
        }
        .task(id: tableName) { await open() }
        .sheet(item: $edit) { t in
            CellEditSheet(column: columnNames[t.col], initial: t) { text, isNull in commitEdit(t, text: text, isNull: isNull) }
        }
        .confirmationDialog("Stage deletion of this row?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Stage delete", role: .destructive) { stageDelete(d.src) }
        } message: { Text("Nothing is written until you review and commit.") }
    }

    // MARK: layout

    private func mainFrame(_ d: Shown) -> some View {
        HTFrame(title: tableName, tail: ([info?.schema] + [info?.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]).compactMap { $0 }.joined(separator: " · "),
                accessory: { rowCount }) {
            switch tab {
            case 1: if let info { StructureView(info: info, notes: ws.layers.notes(tableName)) }
            case 2: if let info { RelationsView(ws: ws, info: info) }
            case 3: StatsView(info: info, stats: stats, loading: statsLoading, since: statsStarted)
            default: dataView(d)
            }
        }
    }

    private func dataView(_ d: Shown) -> some View {
        VStack(spacing: 0) {
            filterBar(d)
                .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
            if !mine.isEmpty { stagedBar }
            if let m = error ?? notice { Text(m).ht(.bodySmall).foregroundStyle(error == nil ? HT.C.amber : HT.C.alert).padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading) }
            DataGrid(columns: gridColumns, rows: d.rows, selection: $selection, focusedColumn: $focused, sparklines: sparklines,
                     onSort: toggleSort, onEdit: { r, c in beginEdit(src: d.src, row: r, col: c) },
                     onFilterValue: { c, v in whereText = TableSQL.and(whereText, TableSQL.equals(c, v, engine: engine)); applyFilter() },
                     onFollowFK: { r, c in follow(c, in: d.rows, row: r) },
                     onReachEnd: { Task { await loadMore() } }, tableName: tableName, engine: engine, markedRows: markedRows(d.rows), layerCells: d.marks, staleRows: d.stale,
                     savedWidths: savedWidths, onColumnsResized: saveWidths)
                .onKeyPress(.delete) { guard selection != nil else { return .ignored }; requestDelete(); return .handled }
                .overlay(alignment: .top) { if loading && rows.isEmpty { firstLoadSkeleton } }
                .overlay(alignment: .bottom) { if loading && !rows.isEmpty { loadingStrip.background(HT.C.paper).padding(8) } }
        }
    }

    /// First page: skeleton rows under the real header (no layout jump), with the strip saying what is being fetched.
    private var firstLoadSkeleton: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 27).allowsHitTesting(false) // DataGrid's header stays visible
            LateReveal {
                VStack(spacing: 6) {
                    loadingStrip.padding(.horizontal, 8).padding(.top, 8)
                    SkeletonRows(columns: min(max(gridColumns.count, info?.columns.count ?? 4), 9), rows: 16)
                }
                .background(HT.C.paper)
            }
        }
    }

    /// Silent under 400 ms; then what is being fetched, how far in, and for how long.
    private var loadingStrip: some View {
        let from = rows.count
        let label = from == 0 ? "Fetching rows" : "Loading more"
        var detail: String = from == 0 ? "first \(pageSize.formatted())" : "rows \((from + 1).formatted())–\((from + pageSize).formatted())"
        if let n = info?.rowCount, n > 0 { detail += " of ~" + HTFormat.grouped(n) }
        if !applied.trimmingCharacters(in: .whitespaces).isEmpty { detail += " · filtered" }
        if let c = sort?.column { detail += " · sorted by " + c }
        return HTLoadingStrip(label, detail: detail, since: loadStarted).id(gen * 1_000_000 + from)
    }

    /// `1,253 ROWS │ LOADED 500+` in the frame's title line, right side.
    private var rowCount: some View {
        let tail = (loading && rows.isEmpty ? "loading…" : "loaded \(rows.count.formatted())\(done ? "" : "+")") + (sort.map { " · \($0.column) \($0.descending ? "↓" : "↑")" } ?? "")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text((info?.rowCount).map(HTFormat.grouped) ?? "–").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(HT.C.ink).contentTransition(.numericText())
            CapsLabel("Rows", tail).foregroundStyle(HT.C.ink3)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func filterBar(_ d: Shown) -> some View {
        HStack(spacing: 6) {
            CapsLabel("Where").foregroundStyle(HT.C.ink3).fixedSize()
            TextField("", text: $whereText, prompt: Text("status = 'paid' AND total > 100").foregroundStyle(HT.C.ink3)).textFieldStyle(.plain).ht(.data)
                .padding(.horizontal, 6).frame(height: 24).frame(minWidth: 120, maxWidth: .infinity)
                .layoutPriority(1)
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                .onSubmit(applyFilter)
                .accessibilityLabel("WHERE filter, press return to apply")
            Text("⏎").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            // quick-filter chips: scroll instead of widening the window's minimum content width
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { v in
                            let clause = TableSQL.equals(chipColumn ?? "", .text(v), engine: engine)
                            HTToggleChip(v, isOn: Binding(get: { applied == clause }, set: { whereText = $0 ? clause : ""; applyFilter() }))
                        }
                    }
                }.frame(maxWidth: 320)
            }
            // SEE AS lives in the Store panel; here only a reminder while it changes what this grid shows
            if let s = ws.layers.seeAs {
                Button { ws.layers.seeAs = nil } label: {
                    HStack(spacing: 5) { Text("SEEING AS \(s == "db" ? "DB" : ws.layers.name(s).uppercased())").ht(.labelSmall); Text("✕").ht(.labelSmall) }
                        .foregroundStyle(HT.C.accent).padding(.horizontal, 6).frame(height: 20)
                        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.accent, lineWidth: 1))
                }.buttonStyle(.plain).help("Back to everything you can see").fixedSize()
            }
            Button("Delete row ⌫") { requestDelete() }.buttonStyle(.htOutline).disabled(selection == nil).fixedSize()
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 8)
    }

    private var stagedBar: some View {
        let s = ws.staged.summary
        return HStack(spacing: 8) {
            Text("Staged · not_written").ht(.label).foregroundStyle(HT.C.amber)
            Text("\(s.updates) updates · \(s.inserts) inserts · \(s.deletes) deletes").ht(.labelSmall).foregroundStyle(HT.C.ink2)
            Spacer(minLength: 0)
            Button("Undo ⌘Z") { ws.undoStaged() }.buttonStyle(.htOutline).keyboardShortcut("z", modifiers: .command)
            Button("Discard") { ws.discardStaged() }.buttonStyle(.htOutline)
            Button("Review & commit ⇧⌘R") { ws.reviewOpen = true }.buttonStyle(.htPrimary).keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 8).frame(height: 30)
        .overlay(Rectangle().strokeBorder(HT.C.amber, lineWidth: 1))
        .padding(.horizontal, 8).padding(.bottom, 4)
    }

    // MARK: derived

    private var gridColumns: [GridColumn] {
        columnNames.map { n in
            let c = info?.columns.first { $0.name == n }, t = (c?.type ?? "").lowercased()
            return GridColumn(name: n, type: c?.type ?? "", isPrimaryKey: c?.isPrimaryKey ?? false, isForeignKey: c?.foreignKey != nil,
                              alignRight: ["int", "real", "num", "dec", "float", "double"].contains { t.contains($0) })
        }
    }
    private var sparklines: [String: [Double]] { Dictionary(stats.filter { $0.histogram.count > 1 }.map { ($0.column, $0.histogram) }, uniquingKeysWith: { a, _ in a }) }

    /// First low-cardinality text column becomes the quick filter.
    private var chipStat: ColumnStats? {
        stats.first { s in
            let t = info?.columns.first { $0.name == s.column }
            return (2...6).contains(s.distinct ?? 99) && t?.isPrimaryKey == false && t?.foreignKey == nil
                && ["char", "text", "enum"].contains { t?.type.lowercased().contains($0) ?? false }
        }
    }
    private var chipColumn: String? { chipStat?.column }
    private var chips: [String] { chipStat?.topValues.map(\.value) ?? [] }

    /// Display rows that carry a staged update (amber gutter in the grid).
    private func markedRows(_ rows: [[Cell]]) -> Set<Int> {
        let keys: [[String: Cell]] = mine.compactMap { if case .update(_, let k, _, _, _) = $0 { return k } else { return nil } }
        guard !keys.isEmpty, !pk.isEmpty else { return [] }
        return Set(rows.indices.filter { keys.contains(key(rows[$0])) })
    }

    private func key(_ r: [Cell]) -> [String: Cell] {
        Dictionary(pk.compactMap { c in columnNames.firstIndex(of: c).map { (c, r[$0]) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Database rows, store layers merged over them (cobalt marks), then staged updates applied and staged deletes hidden.
    private var display: Shown {
        var base = rows, src = Array(rows.indices), marks: [Int: Set<Int>] = [:], stale = Set<Int>()
        let patches = ws.layers.patches(tableName)
        if !patches.isEmpty, !pk.isEmpty {
            // inserts belong at the end of the table: only when nothing filters or sorts the page and every row is loaded
            let m = Overlay.merge(columns: columnNames, rows: rows, pk: pk, patches: patches, addInserts: applied.isEmpty && sort == nil && done)
            (base, src, marks) = (m.rows, m.source, m.cells)
            let staleKeys = Set(patches.filter(\.stale).map { Overlay.keyString(pk, $0.key) })
            stale = Set(base.indices.filter { marks[$0] != nil && staleKeys.contains(Overlay.keyString(pk, key(base[$0]))) })
        }
        if ws.layers.seeingAsAgent { // the agent's view: what its query.run returns
            let h = Set(columnNames.indices.filter { ws.layers.hidden.contains(columnNames[$0].lowercased()) })
            base = base.map { r in r.enumerated().map { h.contains($0) ? Cell.text("«redacted»") : $1 } }
        }
        guard !mine.isEmpty, !pk.isEmpty else { return (base, src, marks, stale) }
        var out: [[Cell]] = [], osrc: [Int] = [], omarks: [Int: Set<Int>] = [:], ostale = Set<Int>()
        for (i, r) in base.enumerated() {
            let k = key(r)
            var r2 = r, gone = false
            for c in mine {
                switch c {
                case .update(_, let ck, let col, _, let new) where ck == k: if let j = columnNames.firstIndex(of: col) { r2[j] = new }
                case .delete(_, let ck) where ck == k: gone = true
                default: break
                }
            }
            if !gone {
                if let m = marks[i] { omarks[out.count] = m }
                if stale.contains(i) { ostale.insert(out.count) }
                out.append(r2); osrc.append(src[i])
            }
        }
        return (out, osrc, omarks, ostale)
    }

    // MARK: loading

    /// Column widths live in DBMan's own store, per connection and table (the same per-connection layout table the schema map uses).
    private var widthsKey: String { "grid:" + tableName }
    private func loadWidths() {
        savedWidths = app.store.mapLayout(ws.storeID, widthsKey).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) }?.mapValues { CGFloat($0) } ?? [:]
    }
    private func saveWidths(_ w: [String: CGFloat]) {
        savedWidths = w
        guard let json = try? JSONEncoder().encode(w.mapValues(Double.init)), let s = String(data: json, encoding: .utf8) else { return }
        try? app.store.setMapLayout(ws.storeID, widthsKey, positions: s)
    }

    /// The connection is one serial session: the first page goes first, the 5,000-row stats sample after it, the debug self-check last.
    /// The loader shows from the moment the table opens, not from when the page query reaches the front of the queue.
    private func open() async {
        loadWidths()
        whereText = ws.pendingFilter.removeValue(forKey: tableName) ?? ""
        applied = whereText; sort = nil; selection = nil; stats = []; focused = 0; error = nil; notice = nil
        rows = []; done = false; loading = true; loadStarted = Date() // skeleton + strip right away
        statsLoading = true; statsStarted = Date()
        Task { await ws.layers.refresh(ws) } // stale marks for patched rows (store only, no database query)
        await reload()
        if selection == nil { selection = DevHooks.select }
        guard !Task.isCancelled else { statsLoading = false; return } // switched tables: don't queue a sample nobody will see
        await loadStats()
        #if DEBUG
        if !Task.isCancelled, let s = ws.session, let i = info { await TableSQL.selfCheck(session: s, engine: engine, table: i) }
        #endif
    }

    private func applyFilter() {
        guard TableSQL.isSingleStatement(whereText) else { error = "Filter must be a single expression (no \";\")."; return }
        applied = whereText
        Task { await reload() }
    }

    private func toggleSort(_ column: String) {
        sort = sort?.column != column ? .init(column: column, descending: false) : (sort!.descending ? nil : .init(column: column, descending: true))
        Task { await reload() }
    }

    private func reload() async {
        gen += 1; rows = []; done = false; loading = false; selection = nil; error = nil
        loadStarted = Date()
        // headers from the schema right away, so the first-load skeleton sits under real column names
        if let cols = info?.columns.map(\.name), !cols.isEmpty, columnNames != cols, columnNames.isEmpty || !Set(columnNames).isSubset(of: Set(cols)) { columnNames = cols }
        await loadMore()
    }

    private func loadMore() async {
        guard let session = ws.session, !loading, !done else { return }
        let g = gen, name = tableName
        loading = true; if !rows.isEmpty { loadStarted = Date() } // the first page keeps the time from when the table opened
        let sql = TableSQL.select(table: name, engine: engine, filter: applied, sort: sort, pk: info?.primaryKey ?? [], limit: pageSize, offset: rows.count)
        let t0 = Date()
        do {
            // The stream is eager, so page with LIMIT/OFFSET and take only the first page.
            for try await page in session.stream(sql, pageSize: pageSize) {
                guard g == gen else { return }
                if columnNames != page.columns { columnNames = page.columns }
                rows += page.rows
                done = page.rows.count < pageSize
                ws.log(sql, "\(page.rows.count) rows · \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                break
            }
        } catch {
            guard g == gen else { return }
            self.error = error.localizedDescription; done = true
            ws.log(sql, error.localizedDescription, error: true)
        }
        if g == gen { loading = false }
    }

    private func loadStats() async {
        guard let session = ws.session else { return }
        statsLoading = true; statsStarted = Date()
        defer { statsLoading = false }
        let name = tableName
        let sql = "SELECT * FROM \(quoteIdent(name, engine)) LIMIT 5000 -- column stats"
        do {
            let s = try await session.columnStats(table: name)
            if name == tableName { stats = s }
            ws.log(sql, "profiled \(s.count) columns")
        } catch { ws.log(sql, error.localizedDescription, error: true) }
    }

    // MARK: actions

    private func follow(_ col: Int, in shown: [[Cell]], row: Int? = nil) {
        guard let r = row ?? selection, r < shown.count, col < columnNames.count,
              let fk = info?.columns.first(where: { $0.name == columnNames[col] })?.foreignKey else { return }
        let clause = TableSQL.equals(fk.column, shown[r][col], engine: engine)
        if fk.table == tableName { whereText = clause; applyFilter(); return }
        ws.pendingFilter[fk.table] = clause
        ws.go(.table(fk.table))
    }

    private func readOnlyReason() -> String? {
        if info?.kind == .view { return "READ-ONLY · views cannot be edited." }
        if pk.isEmpty { return "READ-ONLY · \(tableName) has no primary key, so a single row cannot be targeted safely." }
        return nil
    }

    private func beginEdit(src: [Int], row: Int, col: Int) {
        if let why = readOnlyReason() { notice = why; return }
        guard row < src.count, src[row] >= 0, col < columnNames.count else { notice = "READ-ONLY · this row exists only in a store layer."; return }
        let cell = display.rows[row][col]
        if case .blob = cell { notice = "READ-ONLY · binary values cannot be edited here."; return }
        notice = nil
        edit = EditTarget(src: src[row], col: col, text: cell.isNull ? "" : cell.display, isNull: cell.isNull)
    }

    private func commitEdit(_ t: EditTarget, text: String, isNull: Bool) -> String? {
        let old = rows[t.src][t.col]
        guard let new = isNull ? .null : TableSQL.parse(text, like: old) else { return "Not a valid value for this column." }
        ws.stage(.update(table: tableName, key: key(rows[t.src]), column: columnNames[t.col], old: old, new: new))
        return nil
    }

    private func requestDelete() {
        if let why = readOnlyReason() { notice = why } else if selection != nil { confirmDelete = true }
    }

    private func stageDelete(_ src: [Int]) {
        guard let s = selection, s < src.count, src[s] >= 0 else { return }
        ws.stage(.delete(table: tableName, key: key(rows[src[s]])))
        selection = nil
    }
}

/// Inline edit popup for one cell; `onStage` returns an error message or nil on success.
private struct CellEditSheet: View {
    let column: String
    let initial: EditTarget
    let onStage: (String, Bool) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isNull = false
    @State private var err: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel("Edit cell", column)
            TextField("value", text: $text, axis: .vertical).textFieldStyle(.plain).ht(.data).lineLimit(1...8)
                .padding(6).overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
                .disabled(isNull).onSubmit(stage)
            HTToggleChip("Set NULL", isOn: $isNull)
            if let err { Text(err).ht(.bodySmall).foregroundStyle(HT.C.alert) }
            Text("Staged only — written when you review and commit.").ht(.bodySmall).foregroundStyle(HT.C.ink3)
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(.htOutline).keyboardShortcut(.cancelAction)
                Button("Stage") { stage() }.buttonStyle(.htPrimary).keyboardShortcut(.defaultAction) }
        }
        .padding(16).frame(width: 380)
        .onAppear { text = initial.text; isNull = initial.isNull }
    }
    private func stage() { if let e = onStage(text, isNull) { err = e } else { dismiss() } }
}
