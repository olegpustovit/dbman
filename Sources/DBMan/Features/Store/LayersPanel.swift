import DBCore
import DBManMCP
import DBStore
import Halftone
import SwiftUI

/// Layer monogram, as on the Agents board: two letters in an ink outline (cobalt for agents).
func layerMono(_ name: String) -> String {
    let parts = name.split { !$0.isLetter && !$0.isNumber }
    return (parts.count > 1 ? parts.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.prefix(2))).uppercased()
}

/// SEE AS (Store board): the workspace as you, as DATABASE alone, as MINE, or as one agent's query.run sees it.
struct SeeAsPicker: View {
    let ws: WorkspaceModel
    var body: some View {
        @Bindable var m = ws.layers
        HStack(spacing: 6) {
            CapsLabel("See as").foregroundStyle(HT.C.ink3)
            HTSegmented(selection: $m.seeAs, options: [(nil, "YOU"), ("db", "DB")] + m.layers.map { ($0.id, $0.isMine ? "MINE" : layerMono($0.name)) })
                .help("YOU: everything you can see. An agent: MINE plus its layer, hidden columns redacted.")
        }
    }
}

private func ago(_ d: Date?) -> String {
    guard let d else { return "never" }
    return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
}

/// Right-hand STORE panel: the layer switcher (visibility, counts, last activity), the selected layer's actions and its items.
struct LayersPanel: View {
    let ws: WorkspaceModel
    @State private var discarding = false
    @State private var note = ""
    private var m: LayerModel { ws.layers }

    var body: some View {
        HTFrame(title: "Store", tail: ws.profile.name, accessory: { Text("⌥⌘L").ht(.labelSmall).foregroundStyle(HT.C.ink3) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    CapsLabel("Layers", "\(m.layers.count + 1) · top wins").foregroundStyle(HT.C.ink3)
                    VStack(spacing: 2) {
                        ForEach(m.stack) { layerRow($0) }
                        databaseRow
                    }
                    if let l = m.layer { selectedLayer(l) } else { databaseDetail }
                    if let n = m.notice { Text(n).ht(.bodySmall).foregroundStyle(HT.C.amber) }
                }.padding(8)
            }
        }
        .task(id: ws.layers.selected) { await m.refresh(ws) }
        .alert("Discard \(m.layer?.name ?? "layer")?", isPresented: $discarding) {
            TextField("Note for the agent (optional)", text: $note)
            Button("Discard", role: .destructive) { if let l = m.layer { m.discard(layer: l.id, note: note) }; note = "" }
            Button("Cancel", role: .cancel) { note = "" }
        } message: { Text("Items stay in the store as history. The agent reads your note in overlay.status.") }
    }

    // MARK: switcher

    private func tile(_ s: String, on: Bool, agent: Bool) -> some View {
        Text(s).ht(.labelSmall).foregroundStyle(on ? HT.C.paper : (agent ? HT.C.accent : HT.C.ink)).frame(width: 22, height: 22)
            .background(on ? (agent ? HT.C.accent : HT.C.ink) : .clear, in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(agent ? HT.C.accent : HT.C.ink, lineWidth: 1))
    }

    private func layerRow(_ l: Layer) -> some View {
        let on = m.selected == l.id, vis = m.visible.contains(l.id)
        return HStack(spacing: 6) {
            Button { m.toggle(l) } label: { Image(systemName: vis ? "eye" : "eye.slash").font(.system(size: 11)).frame(width: 20, height: 24) }
                .buttonStyle(.plain).foregroundStyle(vis ? HT.C.ink : HT.C.ink3).disabled(m.seeAs != nil)
                .accessibilityLabel(m.seeAs != nil ? "Visibility follows SEE AS" : "\(vis ? "Hide" : "Show") layer \(l.name)")
            Button { m.selected = l.id } label: {
                HStack(spacing: 6) {
                    tile(layerMono(l.name), on: on, agent: !l.isMine)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(l.name).ht(.bodySmall).lineLimit(1)
                            if l.archived { Text("archived").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
                        }
                        HStack(spacing: 4) {
                            Text(l.isMine ? "yours" : "last \(ago(l.last))").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                            if l.stale > 0 { Text("\(l.stale) stale").ht(.labelSmall).foregroundStyle(HT.C.amber) }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(l.items)").ht(.data).foregroundStyle(HT.C.ink2)
                }
                .padding(.horizontal, 4).frame(height: 30).contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(on ? HT.C.accent : HT.C.line, lineWidth: 1))
            }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
        }
        .opacity(vis ? 1 : 0.55)
    }

    private var databaseRow: some View {
        let on = m.selected == nil
        return HStack(spacing: 6) {
            Image(systemName: "lock").font(.system(size: 10)).frame(width: 20, height: 24).foregroundStyle(HT.C.ink3)
            Button { m.selected = nil } label: {
                HStack(spacing: 6) {
                    tile("DB", on: on, agent: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DATABASE").ht(.bodySmall)
                        Text("read-only // never touched by agents").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).frame(height: 30).contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(on ? HT.C.accent : HT.C.line, lineWidth: 1))
            }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    // MARK: selected

    private var databaseDetail: some View {
        let hidden = ((try? AppModel.shared.store.hiddenColumns(connection: ws.storeID)) ?? []).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            CapsLabel("Hidden from agents", "\(hidden.count) columns").foregroundStyle(HT.C.ink3)
            Text(hidden.isEmpty ? "none" : hidden.joined(separator: ", ")).ht(.dataSmall).foregroundStyle(HT.C.ink2)
            Text("Agents get «redacted» for these. Nothing an agent does can write to the database: only APPLY TO DATABASE from a layer, by you, through the review sheet.")
                .ht(.bodySmall).foregroundStyle(HT.C.ink3)
        }
    }

    private func selectedLayer(_ l: Layer) -> some View {
        let live = m.items(of: l.id)
        let patches = live.filter { $0.kind == "row_patch" }.count
        return VStack(alignment: .leading, spacing: 8) {
            Readout(value: "\(live.count)", label: l.isMine ? "Layer // yours" : "Layer // agent", tail: l.name, size: .m)
            Button { m.compare.toggle() } label: { Text("Compare with database ⌘D").frame(maxWidth: .infinity) }.buttonStyle(m.compare ? .htPrimary : .htOutline)
                .keyboardShortcut("d", modifiers: .command)
            HStack(spacing: 6) {
                Button { m.adopt(live.map(\.id)) } label: { Text("Adopt all → mine").frame(maxWidth: .infinity) }.buttonStyle(.htOutline).disabled(l.isMine || live.isEmpty)
                Button { discarding = true } label: { Text("Discard layer").frame(maxWidth: .infinity) }.buttonStyle(.htOutline).disabled(live.isEmpty)
            }
            Button { m.apply(ws, layer: l.id) } label: { Text("Apply to database… ⇧⌘↩").frame(maxWidth: .infinity) }.buttonStyle(.htPrimary).disabled(patches == 0)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button { m.export(ws, layer: l.id) } label: { Text("Export migration .sql").frame(maxWidth: .infinity) }.buttonStyle(.htOutline).disabled(patches == 0)
            if live.isEmpty { Text("Nothing here. Agents write to their own layer with overlay.patch_rows, views.create …").ht(.bodySmall).foregroundStyle(HT.C.ink3) }
            ForEach(Self.kinds, id: \.0) { kind, title in
                let group = live.filter { $0.kind == kind }
                if !group.isEmpty {
                    CapsLabel(title, "\(group.count)").foregroundStyle(HT.C.ink3).padding(.top, 4)
                    ForEach(group) { itemRow($0, in: l) }
                }
            }
            CapsLabel("Last", ago(l.last)).foregroundStyle(HT.C.ink3).padding(.top, 4)
        }
    }

    static let kinds = [("row_patch", "Row patches"), ("view", "Virtual views"), ("relation", "Relations"), ("note", "Notes"), ("saved_query", "Saved queries"), ("dashboard", "Dashboards")]

    private func itemRow(_ i: OverlayItem, in l: Layer) -> some View {
        let p = OverlayEngine.patch(i)
        let title = p.map { "\($0.table) #" + $0.key.sorted { $0.key < $1.key }.map(\.value.display).joined(separator: "·") } ?? (i.name ?? i.kind)
        let sub = p.map { "\($0.op.rawValue)" + ($0.after.isEmpty ? "" : " · " + $0.after.keys.sorted().joined(separator: ", ")) } ?? (i.kind == "view" ? OverlayEngine.sql(i) : "")
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).ht(.dataSmall).lineLimit(1)
                if !sub.isEmpty { Text(sub).ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if i.status == "stale" { Text("stale").ht(.labelSmall).foregroundStyle(HT.C.amber) }
            if !l.isMine { Button("→ Mine") { m.adopt([i.id]) }.buttonStyle(.htOutline) }
            Button { m.discard(layer: l.id, ids: [i.id], note: nil) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).accessibilityLabel("Discard \(title)")
        }
        .padding(.vertical, 3).overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
    }
}
