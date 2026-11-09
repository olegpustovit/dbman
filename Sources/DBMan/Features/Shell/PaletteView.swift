import DBCore
import Halftone
import SwiftUI

/// ⌘K overlay: fuzzy jump to tables, columns, actions and recent queries.
struct PaletteView: View {
    let ws: WorkspaceModel
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String, group: String, title: String, detail: String?, hits: Set<Int>, table: String?, run: () -> Void
    }

    /// Subsequence match: matched character offsets, or nil. Empty query matches everything.
    private static func match(_ q: String, in s: String) -> Set<Int>? {
        var hits = Set<Int>(), qi = q.lowercased().makeIterator(), want = qi.next()
        for (i, ch) in s.lowercased().enumerated() { if let w = want, w == ch { hits.insert(i); want = qi.next() } }
        return want == nil ? hits : nil
    }

    private var items: [Item] {
        var out: [Item] = []
        func add(_ group: String, _ title: String, detail: String? = nil, table: String? = nil, limit: Int, run: @escaping () -> Void) {
            guard out.filter({ $0.group == group }).count < limit, let h = Self.match(query, in: title) else { return }
            out.append(Item(id: "\(group)/\(title)/\(detail ?? "")", group: group, title: title, detail: detail, hits: h, table: table, run: run))
        }
        let tables = ws.schema?.tables ?? []
        for t in tables { add("Tables", t.name, detail: "\(t.rowCount.formatted()) rows", table: t.name, limit: 6) { ws.go(.table(t.name)) } }
        if !query.isEmpty {
            for t in tables { for c in t.columns { add("Columns", c.name, detail: "\(t.name) · \(c.type)", table: t.name, limit: 6) { ws.go(.table(t.name)) } } }
        }
        let locked = !ws.writesUnlocked
        let actions: [(String, () -> Void)] = [
            ("New query", { ws.newQuery() }),
            ("Toggle inspector", { ws.showInspector.toggle() }),
            ("Toggle console", { ws.showConsole.toggle() }),
            ("Refresh schema", { Task { await ws.refreshSchema() } }),
            (locked ? "Unlock writes" : "Lock writes", { locked ? ws.unlockWrites() : ws.lockWrites() }),
            ("Review changes", { ws.reviewOpen = true }),
            ("Disconnect", { ws.disconnect() }),
        ]
        for (n, run) in actions { add("Actions", n, limit: 7, run: run) }
        var seen = Set<String>()
        for e in ws.console where !e.isError && seen.insert(e.sql).inserted {
            add("Recent queries", e.sql.replacingOccurrences(of: "\n", with: " "), limit: 4) { ws.newQuery(sql: e.sql) }
        }
        return out
    }

    var body: some View {
        let list = items
        let cur = list.indices.contains(selected) ? list[selected] : nil
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().onTapGesture(perform: close)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(HT.C.ink3).accessibilityHidden(true)
                        TextField("Jump to table, column, action…", text: $query).textFieldStyle(.plain).ht(.body)
                            .focused($focused)
                            .onSubmit { run(cur) }
                            .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                            .onKeyPress(.downArrow) { selected = min(selected + 1, list.count - 1); return .handled }
                            .onKeyPress(.escape) { close(); return .handled }
                            .accessibilityAddTraits(.isSearchField)
                        Text("↑↓ ⏎ esc").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                                if i == 0 || list[i - 1].group != it.group {
                                    CapsLabel(it.group).foregroundStyle(HT.C.ink3).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                                }
                                resultRow(it, on: i == selected).onTapGesture { run(it) }
                            }
                            if list.isEmpty { Text("No matches").ht(.label).foregroundStyle(HT.C.ink3).padding(10) }
                        }
                    }
                }
                if let t = cur?.table.flatMap({ ws.schema?.table($0) }) {
                    Divider()
                    preview(t).frame(width: 220)
                }
            }
            .frame(width: 640, height: 380)
            .background(HT.C.paper, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
            .padding(.top, 80)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command palette")
        }
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func resultRow(_ it: Item, on: Bool) -> some View {
        HStack {
            highlighted(it).lineLimit(1)
            Spacer(minLength: 6)
            if let d = it.detail { Text(d).ht(.dataSmall).foregroundStyle(on ? HT.C.paper.opacity(0.7) : HT.C.ink3).lineLimit(1) }
        }
        .foregroundStyle(on ? HT.C.paper : HT.C.ink)
        .padding(.horizontal, 10).frame(height: 24)
        .background(on ? HT.C.ink : .clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func highlighted(_ it: Item) -> some View {
        var a = AttributedString(it.title)
        for i in it.hits {
            let r = a.index(a.startIndex, offsetByCharacters: i)
            a[r..<a.index(afterCharacter: r)].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(a).ht(.bodySmall)
    }

    private func preview(_ t: TableInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Readout(value: t.rowCount.formatted(), label: t.name, tail: "rows", size: .s)
            CapsLabel("Columns", String(t.columns.count)).foregroundStyle(HT.C.ink3)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(t.columns) { c in
                        HStack { Text(c.name).ht(.dataSmall); Spacer(); Text(c.type.lowercased()).ht(.dataSmall).foregroundStyle(HT.C.ink3) }
                    }
                }
            }
        }
        .padding(10).frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func run(_ it: Item?) { guard let it else { return }; close(); it.run() }
    private func close() { ws.paletteOpen = false }
}
