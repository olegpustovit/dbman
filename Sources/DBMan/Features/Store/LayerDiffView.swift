import DBCore
import DBManMCP
import DBStore
import Halftone
import SwiftUI

/// COMPARE: what a layer changes against the database, item by item. A stale patch shows the value it was based on, the database's value now, and the layer's.
struct LayerDiffView: View {
    let ws: WorkspaceModel
    private var m: LayerModel { ws.layers }
    private var scope: [Layer] { m.layer.map { [$0] } ?? m.layers.filter { !$0.isMine && $0.visible && !$0.archived } }

    var body: some View {
        HTFrame(title: "Compare", tail: (scope.map(\.name).joined(separator: ", ").nilIfEmpty ?? "all layers") + " with database",
                accessory: { Button("Merged ⌘D") { m.compare = false }.buttonStyle(.htOutline) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let live = scope.flatMap { l in m.items(of: l.id).map { (l, $0) } }
                    if live.isEmpty { Text("Nothing to compare: the selected layers hold no live items.").ht(.bodySmall).foregroundStyle(HT.C.ink3) }
                    ForEach(live, id: \.1.id) { l, i in card(i, l) }
                }.padding(12)
            }
        }
        .task { await m.refresh(ws) }
    }

    private func card(_ i: OverlayItem, _ l: Layer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let p = OverlayEngine.patch(i) {
                    Text(p.op.rawValue).ht(.label).foregroundStyle(p.op == .delete ? HT.C.alert : HT.C.accent)
                    Text(p.table).ht(.label)
                    Text("#" + p.key.sorted { $0.key < $1.key }.map(\.value.display).joined(separator: "·")).ht(.dataSmall).foregroundStyle(HT.C.ink3)
                } else {
                    Text(i.kind.replacingOccurrences(of: "_", with: " ")).ht(.label).foregroundStyle(HT.C.accent)
                    Text(i.name ?? "").ht(.label)
                }
                CapsLabel(l.name).foregroundStyle(HT.C.ink3)
                if i.status == "stale" { Text("Stale // database changed").ht(.labelSmall).foregroundStyle(HT.C.amber) }
                Spacer(minLength: 0)
                if !l.isMine { Button("→ Mine") { m.adopt([i.id]) }.buttonStyle(.htOutline) }
                Button("✕") { m.discard(layer: l.id, ids: [i.id], note: nil) }.buttonStyle(.htOutline)
            }
            if let p = OverlayEngine.patch(i) { patchTable(p, i) }
            else if i.kind == "view" || i.kind == "saved_query" { Text(OverlayEngine.sql(i)).ht(.dataSmall).foregroundStyle(HT.C.ink2).textSelection(.enabled) }
            else { Text(i.payload).ht(.dataSmall).foregroundStyle(HT.C.ink2).lineLimit(3) }
        }
        .padding(8).background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(i.status == "stale" ? HT.C.amber : HT.C.line, lineWidth: 1))
    }

    private func patchTable(_ p: RowPatch, _ i: OverlayItem) -> some View {
        let now = m.current[i.id]
        let cols = p.op == .update ? p.after.keys.sorted() : (p.op == .delete ? p.before.keys.sorted() : p.after.keys.sorted())
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            GridRow {
                CapsLabel("Column").foregroundStyle(HT.C.ink3)
                CapsLabel(p.op == .insert ? "Database" : "Database // was").foregroundStyle(HT.C.ink3)
                if p.stale { CapsLabel("Database // now").foregroundStyle(HT.C.amber) }
                CapsLabel("Layer").foregroundStyle(HT.C.accent)
            }
            ForEach(cols, id: \.self) { c in
                GridRow {
                    Text(c).ht(.dataSmall)
                    Text(p.op == .insert ? "∅" : (p.before[c]?.display ?? "∅")).ht(.dataSmall).foregroundStyle(HT.C.ink3).strikethrough(p.op != .insert)
                    if p.stale { Text(now?[c]?.display ?? (now == nil ? "row gone" : "∅")).ht(.dataSmall).foregroundStyle(HT.C.amber) }
                    Text(p.op == .delete ? "deleted" : (p.after[c]?.display ?? "∅")).ht(.dataSmall).foregroundStyle(p.op == .delete ? HT.C.alert : HT.C.accent)
                }
            }
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
