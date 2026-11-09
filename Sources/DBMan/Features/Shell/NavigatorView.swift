import DBCore
import Halftone
import SwiftUI

/// 220pt sidebar: connection block, filter, WORKSPACE / TABLES / VIEWS.
struct NavigatorView: View {
    let ws: WorkspaceModel
    @State private var filter = ""
    @Environment(AppModel.self) private var app
    @State private var confirmDeleteQuery: QueryTab?
    @State private var confirmDeleteDashboard: (id: String, title: String)?
    @FocusState private var filterFocused: Bool

    private var prod: Bool { ws.profile.environment == .production }
    private func shown(_ k: TableKind) -> [TableInfo] {
        let t = (ws.schema?.tables ?? []).filter { $0.kind == k && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
        switch app.tableSort {
        case "rows": return t.sorted { $0.rowCount != $1.rowCount ? $0.rowCount > $1.rowCount : $0.name < $1.name }
        case "size": return t.sorted { ($0.sizeBytes ?? -1) != ($1.sizeBytes ?? -1) ? ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) : $0.name < $1.name }
        default: return t.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// A–Z · ROWS · SIZE next to the TABLES heading; the choice is saved for every connection.
    private var sortPicker: some View {
        HStack(spacing: 2) {
            ForEach([("name", "A–Z"), ("rows", "ROWS"), ("size", "SIZE")], id: \.0) { key, title in
                let on = app.tableSort == key
                Button { withAnimation(HT.Motion.snap) { app.tableSort = key } } label: {
                    Text(title).ht(.labelSmall).foregroundStyle(on ? HT.C.paper : HT.C.ink3)
                        .padding(.horizontal, 4).frame(height: 16)
                        .background(on ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Sort tables by \(key == "name" ? "name" : key == "rows" ? "row count, largest first" : "size on disk, largest first")")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    var body: some View {
        HTFrame(title: ws.profile.name, tail: ws.profile.environment.rawValue) {
            VStack(alignment: .leading, spacing: 8) {
                if prod { Text("Production · writes locked").ht(.labelSmall).foregroundStyle(HT.C.amber) }
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
                                .contextMenu {
                                    Button("Open") { ws.go(.query(t.id)) }
                                    Button("Duplicate") { ws.duplicateQuery(t.id) }
                                    Divider()
                                    Button("Delete query", role: .destructive) { if t.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ws.deleteQuery(t.id) } else { confirmDeleteQuery = t } }
                                }
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
        .confirmationDialog("Delete \(confirmDeleteQuery?.title ?? "query")?", isPresented: Binding(get: { confirmDeleteQuery != nil }, set: { if !$0 { confirmDeleteQuery = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let t = confirmDeleteQuery { ws.deleteQuery(t.id) }; confirmDeleteQuery = nil }
        } message: { Text("Its SQL lives only in this tab; deleting it cannot be undone.") }
        .confirmationDialog("Delete \(confirmDeleteDashboard?.title ?? "dashboard")?", isPresented: Binding(get: { confirmDeleteDashboard != nil }, set: { if !$0 { confirmDeleteDashboard = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = confirmDeleteDashboard { ws.dash.delete(d.id, ws) }; confirmDeleteDashboard = nil }
        } message: { Text("Removed from this connection's dashboards. The database is not touched.") }
    }

    /// The connection's other dashboards: MINE first, then each agent's layer with its monogram; NEW marks an agent's proposal.
    @ViewBuilder private var dashboards: some View {
        let list = ws.dash.entries.filter { $0.id != ws.dash.defaultEntry?.id && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter)) }
        section("Dashboards", count: list.count)
        ForEach(list) { e in
            row(e.title, trailing: e.mine ? nil : "NEW · " + layerMono(e.layer), selected: ws.route == .dashboard(e.id)) { ws.go(.dashboard(e.id)) }
                .contextMenu {
                    Button("Open") { ws.go(.dashboard(e.id)) }
                    Divider()
                    Button(e.mine ? "Delete dashboard" : "Discard proposal", role: .destructive) { confirmDeleteDashboard = (e.id, e.title) }
                }
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
            HStack(alignment: .lastTextBaseline) { section(title, count: items.count); Spacer(minLength: 4); if title == "Tables" { sortPicker.padding(.bottom, 3) } }
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
