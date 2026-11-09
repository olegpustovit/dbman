import DBCore
import Halftone
import SwiftUI

/// 220pt sidebar: connection block, filter, WORKSPACE / TABLES / VIEWS.
struct NavigatorView: View {
    let ws: WorkspaceModel
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var prod: Bool { ws.profile.environment == .production }
    private func shown(_ k: TableKind) -> [TableInfo] {
        (ws.schema?.tables ?? []).filter { $0.kind == k && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }

    var body: some View {
        HTFrame(title: ws.profile.name, tail: ws.profile.environment.rawValue) {
            VStack(alignment: .leading, spacing: 8) {
                if prod { Text("Production // writes locked").ht(.labelSmall).foregroundStyle(HT.C.amber) }
                Readout(value: (ws.schema?.totalRows ?? 0).formatted(), label: "Rows", tail: size, size: .m)
                HTSearchField(text: $filter, prompt: "Filter", shortcut: "⌥⌘F").focused($filterFocused)
                    .background(Button("") { filterFocused = true }.keyboardShortcut("f", modifiers: [.option, .command]).opacity(0).accessibilityHidden(true))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Workspace")
                        row(ws.profile.environment == .system ? "Agent activity" : "Overview", trailing: "⌘0", selected: ws.route == .overview) { ws.go(.overview) }
                        row("Schema map", trailing: "⌘4", selected: ws.route == .schemaMap) { ws.go(.schemaMap) }
                        ForEach(ws.queryTabs) { t in
                            row(t.title, edited: t.isEdited, selected: ws.route == .query(t.id)) { ws.go(.query(t.id)) }
                        }
                        dashboards
                        tableSection("Tables", shown(.table))
                        tableSection("Views", shown(.view))
                        virtualViews
                    }
                }
            }
            .padding(8)
        }
    }

    /// The connection's other dashboards: MINE first, then each agent's layer with its monogram; NEW marks an agent's proposal.
    @ViewBuilder private var dashboards: some View {
        let list = ws.dash.entries.filter { $0.id != ws.dash.defaultEntry?.id && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter)) }
        section("Dashboards", count: list.count)
        ForEach(list) { e in
            row(e.title, trailing: e.mine ? nil : "NEW · " + layerMono(e.layer), selected: ws.route == .dashboard(e.id)) { ws.go(.dashboard(e.id)) }
        }
        row("+ New dashboard", trailing: "⌥⌘N", selected: false) { ws.dash.create(ws) }
    }

    /// Virtual views from visible store layers: a query tab on the view (expanded as a CTE when it runs).
    @ViewBuilder private var virtualViews: some View {
        let vv = ws.layers.views.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        if !vv.isEmpty {
            section("Virtual views", count: vv.count)
            ForEach(vv, id: \.name) { v in
                row(v.name, trailing: layerMono(ws.layers.name(v.layer)), selected: false) { ws.newQuery(sql: "SELECT * FROM \(quoteIdent(v.name, ws.profile.engine))") }
            }
        }
    }

    private var size: String? {
        ws.schema?.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private func section(_ title: String, count: Int? = nil) -> some View {
        CapsLabel(title, count.map(String.init)).foregroundStyle(HT.C.ink3).padding(.top, 10).padding(.bottom, 3)
    }

    @ViewBuilder private func tableSection(_ title: String, _ items: [TableInfo]) -> some View {
        if !items.isEmpty {
            section(title, count: items.count)
            let biggest = Double(max(items.map { $0.sizeBytes ?? $0.rowCount }.max() ?? 1, 1))
            ForEach(items) { t in
                row(t.name, trailing: t.kind == .table ? HTFormat.compact(t.rowCount) : nil,
                    meter: Double(t.sizeBytes ?? t.rowCount) / biggest, selected: ws.route == .table(t.name)) { ws.go(.table(t.name)) }
            }
        }
    }

    private func row(_ title: String, trailing: String? = nil, meter: Double? = nil, edited: Bool = false, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).ht(.bodySmall).lineLimit(1)
                if edited { Circle().fill(HT.C.amber).frame(width: 5, height: 5) }
                Spacer(minLength: 4)
                if let trailing { Text(trailing).ht(.dataSmall).foregroundStyle(selected ? HT.C.paper : HT.C.ink3) }
                if let meter { SegmentedMeter(value: meter, segments: 6, accessibilityLabel: "Relative size").frame(width: 28, height: 4) }
            }
            .foregroundStyle(selected ? HT.C.paper : HT.C.ink)
            .padding(.horizontal, 6).frame(height: 22)
            .background(selected ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
