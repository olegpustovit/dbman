import AppKit
import DBCore
import Halftone
import SwiftUI

struct QueryView: View {
    let ws: WorkspaceModel
    let tab: QueryTab

    @State private var view = DevHooks.view
    @State private var selection: Int?
    @State private var focusedColumn = 0
    @State private var expanded: Set<String> = []
    @State private var task: Task<Void, Never>?
    @State private var messageIDs: Set<UUID> = []
    @State private var readOnlyHit = false
    @State private var planning = false
    @State private var planError: String?

    private static let rail = [("01", "Result"), ("02", "Messages"), ("03", "Plan"), ("04", "Chart")]
    private static let readKeywords: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE"]

    var body: some View {
        HStack(spacing: HT.M.gap) {
            NumberRail(items: Self.rail.map { (number: $0.0, title: $0.1) }, selection: $view)
            schema.frame(width: 200)
            VStack(spacing: HT.M.gap) {
                editor.frame(height: 240)
                results
            }
        }
        .onAppear {
            #if DEBUG
            _ = QueryLogicCheck.once
            #endif
            if DevHooks.autorun, tab.result == nil, !tab.sql.isEmpty { run(tab.sql, all: true); view = DevHooks.view } // run() shows the result tab
        }
        .task { if view == 2, tab.plan == nil { explain() } } // first appearance on the PLAN rail
        .onChange(of: view) { _, v in if v == 2, tab.plan == nil { explain() } }
    }

    // MARK: schema

    private var schema: some View {
        HTFrame(title: "SCHEMA", tail: ws.schema.map { "\($0.tables.count)" }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ws.schema?.tables ?? []) { t in
                        HStack(spacing: 4) {
                            Button { toggle(t.name) } label: {
                                Image(systemName: expanded.contains(t.name) ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                    .frame(width: 16, height: HT.M.row)
                            }.buttonStyle(.plain).accessibilityLabel(expanded.contains(t.name) ? "Collapse \(t.name)" : "Expand \(t.name)")
                            Button { insert(t.name) } label: { Text(t.name).ht(.dataSmall).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                                .buttonStyle(.plain).accessibilityHint("Insert into editor")
                        }.frame(height: HT.M.row)
                        if expanded.contains(t.name) {
                            ForEach(t.columns) { c in
                                Button { insert(c.name) } label: {
                                    HStack(spacing: 4) {
                                        Text(c.name).ht(.dataSmall).lineLimit(1)
                                        Spacer(minLength: 2)
                                        if c.isPrimaryKey { Text("PK").ht(.labelSmall).foregroundStyle(HT.C.accent) }
                                        if c.foreignKey != nil { Text("FK").ht(.labelSmall).foregroundStyle(HT.C.amber) }
                                        Text(c.type).ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                                    }.padding(.leading, 22).padding(.trailing, 6).frame(height: 20).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }
        }
    }

    private func toggle(_ name: String) { if !expanded.insert(name).inserted { expanded.remove(name) } }

    // MARK: editor

    private var completions: [String] {
        Array(Set((ws.schema?.tables ?? []).flatMap { [$0.name] + $0.columns.map(\.name) }))
    }

    private var editor: some View {
        @Bindable var t = tab
        return HTFrame(title: "EDITOR", tail: tab.isEdited ? "EDITED" : "SAVED", accessory: {
            TextField("Title", text: $t.title).textFieldStyle(.plain).ht(.label).frame(width: 90).accessibilityLabel("Query title")
            Button("SAVE") { tab.savedSQL = tab.sql }.buttonStyle(.htOutline).disabled(!tab.isEdited).keyboardShortcut("s", modifiers: .command)
            Button("EXPLAIN") { explain() }.buttonStyle(.htOutline)
            Button("SAVE AS WIDGET") { Task { await ws.dash.saveQuery(currentStatement(), title: tab.title, ws) } }.buttonStyle(.htOutline).help("Add this query as a table widget to the default dashboard")
            Button("RUN ALL") { run(tab.sql, all: true) }.buttonStyle(.htOutline).keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("STOP") { stop() }.buttonStyle(.htOutline).disabled(!tab.running)
            Button("RUN // ⌘⏎") { run(currentStatement()) }.buttonStyle(.htPrimary).keyboardShortcut(.return, modifiers: .command)
        }) {
            SQLEditor(text: $t.sql, completions: completions, onRunStatement: { run($0) }, onRunAll: { run($0, all: true) })
        }
    }

    // The editor is AppKit; the toolbar and schema tree reach it through the key window's first responder.
    private func editorView() -> EditorTextView? {
        func find(_ v: NSView?) -> EditorTextView? { v.flatMap { $0 as? EditorTextView ?? $0.subviews.lazy.compactMap(find).first } }
        return find(NSApp.keyWindow?.contentView)
    }

    private func currentStatement() -> String {
        SQLEditor.statement(at: editorView()?.selectedRange().location ?? .max, in: tab.sql)
    }

    private func insert(_ name: String) {
        if let tv = editorView() { tv.insertText(name, replacementRange: tv.selectedRange()) } // shortcut: appends when the editor view isn't found
        else { tab.sql += (tab.sql.isEmpty || tab.sql.hasSuffix(" ") || tab.sql.hasSuffix("\n") ? "" : " ") + name }
    }

    // MARK: running

    private func run(_ sql: String, all: Bool = false) {
        let s = ws.layers.expand(sql.trimmingCharacters(in: .whitespacesAndNewlines), mysql: ws.profile.engine == .mysql) // virtual views from visible layers
        guard !s.isEmpty, !tab.running, let session = ws.session else { return }
        tab.running = true; tab.startedAt = Date(); tab.error = nil; tab.result = nil; tab.plan = nil
        readOnlyHit = false; view = 0
        task = Task {
            let t0 = Date()
            let ms = { Date().timeIntervalSince(t0) * 1000 }
            do {
                if !all, Self.readKeywords.contains(SQLClassifier.firstKeyword(s)) {
                    for try await page in session.stream(s) {
                        if tab.result == nil { tab.result = QueryResult(columns: page.columns) }
                        tab.result?.rows.append(contentsOf: page.rows)
                        // shortcut: stops at 100k rows (grid memory); add paging when needed
                        if tab.result!.rows.count >= 100_000 { tab.result?.truncated = true; await session.cancel(); break }
                    }
                    tab.result = tab.result ?? QueryResult()
                    tab.result?.elapsedMs = ms()
                } else {
                    tab.result = try await session.run(s)
                }
                let n = tab.result?.rows.count ?? 0
                log(s, tab.result?.columns.isEmpty == false ? "\(n) rows, \(Int(ms())) ms" : "ok, \(tab.result?.rowsAffected ?? 0) affected, \(Int(ms())) ms")
            } catch {
                if case DBError.readOnly = error { readOnlyHit = true }
                tab.error = error.localizedDescription
                log(s, tab.error ?? "error", error: true)
            }
            tab.running = false
        }
    }

    private func log(_ sql: String, _ summary: String, error: Bool = false) {
        ws.log(sql, summary, error: error)
        if let id = ws.console.first?.id { messageIDs.insert(id) }
    }

    private func stop() {
        task?.cancel()
        Task { await ws.session?.cancel() }
    }

    private func explain() {
        let s = currentStatement().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !planning, let session = ws.session else { return }
        view = 2; planning = true; planError = nil; tab.plan = nil
        Task {
            do {
                tab.plan = try await session.explain(s)
                if tab.plan == nil { planError = "\(ws.profile.engine.displayName) returned no plan for this statement." }
            } catch { planError = error.localizedDescription; log("EXPLAIN " + s, error.localizedDescription, error: true) }
            planning = false
        }
    }

    // MARK: results

    @ViewBuilder private var results: some View {
        switch view {
        case 1: messages
        case 2: plan
        case 3: chart
        default: resultFrame
        }
    }

    private var resultFrame: some View {
        HTFrame(title: "RESULT", tail: tab.result.map { "\($0.rows.count) ROWS" }, accessory: { runningText }) {
            VStack(spacing: 0) {
                body(for: tab.result)
                if let r = tab.result, !tab.running, tab.error == nil, !r.columns.isEmpty {
                    HStack {
                        Readout(value: r.rows.count.formatted(), label: "ROWS", tail: "\(Int(r.elapsedMs)) MS", size: .s)
                        if r.truncated { StatusText(label: "TRUNCATED", value: "FIRST \(r.rows.count.formatted())", tone: .amber) }
                        Spacer()
                    }.padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
                }
            }
        }
    }

    /// Doherty: silent for 400 ms, then a live count and elapsed time.
    @ViewBuilder private var runningText: some View {
        if tab.running {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                let e = ctx.date.timeIntervalSince(tab.startedAt ?? ctx.date)
                if e > 0.4 { StatusText(label: "RUNNING", value: "\((tab.result?.rows.count ?? 0).formatted()) ROWS // \(String(format: "%.1f", e)) S") }
            }
        }
    }

    @ViewBuilder private func body(for r: QueryResult?) -> some View {
        if let err = tab.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(err).ht(.data).foregroundStyle(HT.C.alert).textSelection(.enabled)
                if readOnlyHit {
                    Text("Unlock writes to run this statement.").ht(.bodySmall).foregroundStyle(HT.C.ink2)
                    Button("UNLOCK WRITES") { ws.unlockWrites(); readOnlyHit = false }.buttonStyle(.htOutline)
                }
            }.padding(12).accessibilityAddTraits(.updatesFrequently)
        } else if let r = tab.result, !r.columns.isEmpty {
            DataGrid(columns: r.columns.enumerated().map { i, n in
                        GridColumn(name: n, alignRight: r.rows.first.map { i < $0.count && $0[i].isNumeric } ?? false)
                     },
                     rows: r.rows, selection: $selection, focusedColumn: $focusedColumn)
        } else if let r = tab.result {
            Readout(value: r.rowsAffected.formatted(), label: "ROWS AFFECTED", tail: "\(Int(r.elapsedMs)) MS", size: .m).padding(12)
        } else if tab.running {
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                if ctx.date.timeIntervalSince(tab.startedAt ?? ctx.date) > 0.4 {
                    StateFrame(title: "RUNNING", tail: nil, message: "Waiting for first rows…", running: true)
                }
            }
        } else {
            Text("Write a statement and press ⌘⏎.").ht(.bodySmall).foregroundStyle(HT.C.ink3).padding(12)
        }
    }

    private var messages: some View {
        let mine = ws.console.filter { messageIDs.contains($0.id) }
        return HTFrame(title: "MESSAGES", tail: "\(mine.count)") {
            if mine.isEmpty {
                Text("No statements run from this tab yet.").ht(.bodySmall).foregroundStyle(HT.C.ink3).padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(mine) { e in
                            ActivityItem(icon: e.isError ? "exclamationmark.triangle" : "checkmark", title: e.summary.uppercased(),
                                         detail: e.sql, time: e.at.formatted(date: .omitted, time: .standard), tone: e.isError ? .alert : .normal)
                        }
                    }.padding(10)
                }
            }
        }
    }

    private var plan: some View {
        HTFrame(title: "PLAN", tail: planning ? "RUNNING" : nil) {
            if let p = tab.plan { PlanDiagram(root: p) }
            else if planning { StateFrame(title: "EXPLAIN", tail: nil, message: "Planning…", running: true) }
            else { Text(planError ?? "Press EXPLAIN to plan the statement under the cursor.").ht(.bodySmall)
                .foregroundStyle(planError == nil ? HT.C.ink3 : HT.C.alert).padding(12) }
        }
    }

    private var chart: some View {
        let spec = tab.result.flatMap(ChartSpec.detect)
        return HTFrame(title: "CHART", tail: { () -> String? in
            switch spec { case .bars(let l, let v, _, _)?: "\(v) BY \(l)"; case .line(let l, let n, _, _, _)?: "\(n.joined(separator: ", ")) OVER \(l)"; case nil: nil }
        }()) {
            switch spec {
            case .bars(_, _, let labels, let values):
                VStack(spacing: 8) {
                    BarSpectrum(values: values, highlight: values.indices.max { values[$0] < values[$1] }, accessibilityLabel: "Bar chart").frame(height: 120)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(labels.indices.prefix(200), id: \.self) { i in // shortcut: first 200 labelled rows
                                HStack(spacing: 8) {
                                    Text(labels[i]).ht(.dataSmall).lineLimit(1).frame(width: 140, alignment: .leading)
                                    SegmentedMeter(value: values[i] / max(values.max() ?? 1, .ulpOfOne), segments: 30, accessibilityLabel: labels[i],
                                                   accessibilityValue: values[i].formatted())
                                    Text(values[i].formatted()).ht(.dataSmall).frame(width: 80, alignment: .trailing)
                                }.frame(height: 18)
                            }
                        }
                    }
                }.padding(12)
            case .line(_, _, let series, let first, let last):
                VStack(spacing: 4) {
                    LineChart(series: series, styles: series.indices.map { $0 == 0 ? .solid : .ink55 }, accessibilityLabel: "Line chart").frame(maxHeight: .infinity)
                    HStack { Text(first); Spacer(); Text(last) }.ht(.labelSmall).foregroundStyle(HT.C.ink3)
                }.padding(12)
            case nil:
                Text("Charts need one text column plus a number column (bars), or a date column plus a number column (line). Run a query like SELECT status, COUNT(*) FROM orders GROUP BY status.")
                    .ht(.bodySmall).foregroundStyle(HT.C.ink3).padding(12)
            }
        }
    }
}
