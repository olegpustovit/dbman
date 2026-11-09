import AppKit
import DBCore
import Halftone
import SwiftUI

/// Filters handed to the next-opened table (FK follow / child-row links); `ws.go` carries no payload.

private struct EditTarget: Identifiable { let id = UUID(); var src: Int; var col: Int; var text: String; var isNull: Bool }

struct TableBrowserView: View {
    let ws: WorkspaceModel
    let tableName: String

    @State private var tab = DevHooks.view
    @AppStorage("pageSize") private var pageSize = 500 // Settings → Results
    @State private var whereText = ""
    @State private var applied = ""
    @State private var sort: TableSQL.Sort?
    @State private var columnNames: [String] = []
    @State private var rows: [[Cell]] = []
    @State private var done = false
    @State private var loading = false
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
        HStack(spacing: HT.M.gap) {
            NumberRail(items: [("01", "Data"), ("02", "Structure"), ("03", "Relations"), ("04", "Stats")], selection: $tab)
            VStack(spacing: HT.M.gap) {
                HStack(spacing: HT.M.gap) {
                    mainFrame(d)
                    if ws.showInspector, tab == 0 {
                        TableInspector(ws: ws, info: info, columns: columnNames, row: selection.flatMap { $0 < d.rows.count ? d.rows[$0] : nil },
                                       focused: $focused, stats: stats, staged: mine, onFollow: { follow($0, in: d.rows) })
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

    private func mainFrame(_ d: (rows: [[Cell]], src: [Int])) -> some View {
        HTFrame(title: tableName, tail: ([info?.schema] + [info?.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]).compactMap { $0 }.joined(separator: " · ")) {
            switch tab {
            case 1: if let info { StructureView(info: info) }
            case 2: if let info { RelationsView(ws: ws, info: info) }
            case 3: StatsView(info: info, stats: stats)
            default: dataView(d)
            }
        }
    }

    private func dataView(_ d: (rows: [[Cell]], src: [Int])) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                filterBar(d)
                Readout(value: (info?.rowCount).map(HTFormat.grouped) ?? "–", label: "Rows",
                        tail: "loaded \(rows.count)\(done ? "" : "+")" + (sort.map { " // sort \($0.column) \($0.descending ? "↓" : "↑")" } ?? ""), size: .l).padding(.horizontal, 10)
            }
            if !mine.isEmpty { stagedBar }
            if let m = error ?? notice { Text(m).ht(.bodySmall).foregroundStyle(error == nil ? HT.C.amber : HT.C.alert).padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading) }
            DataGrid(columns: gridColumns, rows: d.rows, selection: $selection, focusedColumn: $focused, sparklines: sparklines,
                     onSort: toggleSort, onEdit: { r, c in beginEdit(src: d.src, row: r, col: c) },
                     onFilterValue: { c, v in whereText = TableSQL.and(whereText, TableSQL.equals(c, v, engine: engine)); applyFilter() },
                     onFollowFK: { r, c in follow(c, in: d.rows, row: r) },
                     onReachEnd: { Task { await loadMore() } }, tableName: tableName, markedRows: markedRows(d.rows))
                .onKeyPress(.delete) { guard selection != nil else { return .ignored }; requestDelete(); return .handled }
        }
    }

    private func filterBar(_ d: (rows: [[Cell]], src: [Int])) -> some View {
        HStack(spacing: 6) {
            CapsLabel("Where").foregroundStyle(HT.C.ink3)
            TextField("status = 'paid' AND total > 100", text: $whereText).textFieldStyle(.plain).ht(.data)
                .padding(.horizontal, 6).frame(height: 22).frame(minWidth: 120, maxWidth: 380)
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                .onSubmit(applyFilter)
                .accessibilityLabel("WHERE filter, press return to apply")
            Text("⏎").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            // Scrolls instead of widening the window's minimum content width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { v in
                        let clause = TableSQL.equals(chipColumn ?? "", .text(v), engine: engine)
                        HTToggleChip(v, isOn: Binding(get: { applied == clause }, set: { whereText = $0 ? clause : ""; applyFilter() }))
                    }
                }
            }
            Button("Delete row ⌫") { requestDelete() }.buttonStyle(.htOutline).disabled(selection == nil)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 8).frame(height: 30)
    }

    private var stagedBar: some View {
        let s = ws.staged.summary
        return HStack(spacing: 8) {
            Text("Staged // not_written").ht(.label).foregroundStyle(HT.C.amber)
            Text("\(s.updates) updates // \(s.inserts) inserts // \(s.deletes) deletes").ht(.labelSmall).foregroundStyle(HT.C.ink2)
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

    /// Rows with staged updates applied and staged deletes hidden; `src` maps back to `rows`.
    private var display: (rows: [[Cell]], src: [Int]) {
        guard !mine.isEmpty, !pk.isEmpty else { return (rows, Array(rows.indices)) }
        var out: [[Cell]] = [], src: [Int] = []
        for (i, r) in rows.enumerated() {
            let k = key(r)
            var r2 = r, gone = false
            for c in mine {
                switch c {
                case .update(_, let ck, let col, _, let new) where ck == k: if let j = columnNames.firstIndex(of: col) { r2[j] = new }
                case .delete(_, let ck) where ck == k: gone = true
                default: break
                }
            }
            if !gone { out.append(r2); src.append(i) }
        }
        return (out, src)
    }

    // MARK: loading

    private func open() async {
        whereText = ws.pendingFilter.removeValue(forKey: tableName) ?? ""
        applied = whereText; sort = nil; selection = nil; stats = []; focused = 0; error = nil; notice = nil
        #if DEBUG
        if let s = ws.session, let i = info { await TableSQL.selfCheck(session: s, engine: engine, table: i) }
        #endif
        async let st: Void = loadStats()
        await reload()
        await st
        if selection == nil { selection = DevHooks.select }
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
        await loadMore()
    }

    private func loadMore() async {
        guard let session = ws.session, !loading, !done else { return }
        let g = gen, name = tableName
        loading = true
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
        if info?.kind == .view { return "READ-ONLY // views cannot be edited." }
        if pk.isEmpty { return "READ-ONLY // \(tableName) has no primary key, so a single row cannot be targeted safely." }
        return nil
    }

    private func beginEdit(src: [Int], row: Int, col: Int) {
        if let why = readOnlyReason() { notice = why; return }
        guard row < src.count, col < columnNames.count else { return }
        let cell = display.rows[row][col]
        if case .blob = cell { notice = "READ-ONLY // binary values cannot be edited here."; return }
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
        guard let s = selection, s < src.count else { return }
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
