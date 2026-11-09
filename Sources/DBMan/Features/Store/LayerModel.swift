import AppKit
import DBCore
import DBManMCP
import DBStore
import Foundation
import Observation

/// The human's side of the overlay store for one workspace: which layers exist and are visible, merged patches, and ADOPT / DISCARD / APPLY / EXPORT.
@MainActor @Observable
final class LayerModel {
    var open = false          // the layers panel is showing
    var compare = false       // the layer diff replaces the page
    var selected: String?     // layer id; nil = DATABASE
    /// SEE AS: nil = you (the layer toggles), "db" = DATABASE alone, a layer id = MINE plus that layer; an agent's view also redacts hidden columns, like its query.run.
    var seeAs: String?
    private(set) var hidden: Set<String> = []
    var notice: String?
    private(set) var layers: [Layer] = []
    private(set) var items: [OverlayItem] = []
    /// Patch item id → the database's current row, for stale items.
    private(set) var current: [String: [String: Cell]] = [:]
    /// Items an APPLY put in the review sheet; marked adopted after COMMIT.
    private var applying: [String] = []
    private var conn = ""
    private var store: Store { AppModel.shared.store }

    // MARK: reading

    func reload(_ ws: WorkspaceModel) {
        conn = ws.storeID
        layers = (try? store.layers(conn)) ?? []
        items = ((try? store.items(conn)) ?? []).sorted { rank($0.layer) < rank($1.layer) }
        hidden = (try? store.hiddenColumns(connection: conn)) ?? []
        if let s = seeAs, s != "db", !layers.contains(where: { $0.id == s }) { seeAs = nil }
        if let s = selected, !layers.contains(where: { $0.id == s }) { selected = nil }
    }
    private func rank(_ layer: String) -> Int { layers.firstIndex { $0.id == layer } ?? 0 }

    var visible: Set<String> {
        guard let s = seeAs else { return Set(layers.filter { $0.visible && !$0.archived }.map(\.id)) }
        return s == "db" ? [] : Set(layers.filter { $0.isMine || $0.id == s }.map(\.id))
    }
    var seeingAsAgent: Bool { layers.first { $0.id == seeAs }.map { !$0.isMine } ?? false }
    /// Layers top first, as the switcher lists them (agents above MINE).
    var stack: [Layer] { layers.reversed() }
    var layer: Layer? { layers.first { $0.id == selected } }
    func items(of layer: String?) -> [OverlayItem] { items.filter { layer == nil || $0.layer == layer } }
    func name(_ layer: String) -> String { layers.first { $0.id == layer }?.name ?? layer }

    /// Row patches of visible layers for a table, lowest layer first (so the top layer wins in the merge).
    func patches(_ table: String) -> [RowPatch] {
        let v = visible
        return items.filter { v.contains($0.layer) && $0.table == table }.compactMap(OverlayEngine.patch)
    }
    func notes(_ table: String) -> [String: String] {
        let v = visible
        return OverlayEngine.notes(items.filter { v.contains($0.layer) && ($0.name == table || ($0.name ?? "").hasPrefix(table + ".")) })
    }
    /// Virtual views of visible layers (a later layer shadows an earlier one of the same name).
    var views: [(name: String, sql: String, layer: String)] {
        let v = visible
        return items.filter { $0.kind == "view" && v.contains($0.layer) }.compactMap { i in i.name.map { ($0, OverlayEngine.sql(i), i.layer) } }
    }
    /// The same expansion `query.run` applies for an agent, for the human's query tabs.
    func expand(_ sql: String, mysql: Bool) -> String {
        guard ["SELECT", "WITH"].contains(SQLClassifier.firstKeyword(sql)) else { return sql }
        return Overlay.expand(sql, views: views.map { ($0.name, $0.sql) }, mysql: mysql).sql
    }

    /// Re-checks patches against the database (stale detection, G19), then reloads.
    func refresh(_ ws: WorkspaceModel) async {
        reload(ws)
        guard let session = ws.session, let schema = ws.schema, !layers.isEmpty else { return }
        if let c = try? await OverlayEngine.check(store, session, schema, connection: conn, layers: layers.map(\.id)) { current = c }
        reload(ws)
    }

    // MARK: actions

    func toggle(_ l: Layer) { try? store.setLayerVisible(l.id, !l.visible) }
    func adopt(_ ids: [String]) {
        do { try store.adopt(ids, connection: conn) } catch { notice = error.localizedDescription }
    }
    func discard(layer: String, ids: [String]? = nil, note: String?) {
        do { try store.discard(layer: layer, ids: ids, note: note) } catch { notice = error.localizedDescription }
    }

    /// Row patches of a layer as v1 staged changes; stale ones are left out (the database moved on, so the human decides in the diff).
    private func changes(_ layer: String) -> (changes: [StagedChange], ids: [String], skipped: Int) {
        let mine = items(of: layer).filter { $0.kind == "row_patch" }
        let live = mine.filter { $0.status != "stale" }
        return (Overlay.changes(live.compactMap(OverlayEngine.patch)), live.map(\.id), mine.count - live.count)
    }

    /// APPLY TO DATABASE: stage the layer's patches and open the v1 review sheet. Human only; nothing is written before COMMIT.
    func apply(_ ws: WorkspaceModel, layer id: String) {
        let c = changes(id)
        guard !c.changes.isEmpty else { notice = "Nothing to apply: no live row patches in \(name(id))."; return }
        c.changes.forEach(ws.stage)
        applying = c.ids
        let others = items(of: id).filter { $0.kind != "row_patch" }.count
        ws.reviewNote = "From layer \(name(id)): \(c.ids.count) row patches."
            + (c.skipped > 0 ? " \(c.skipped) stale skipped: the row changed in the database since." : "")
            + (others > 0 ? " \(others) views, relations and notes stay in the layer (ADOPT them instead)." : "")
        ws.reviewOpen = true
    }
    /// Called after COMMIT succeeded.
    func applied() {
        try? store.setStatus(applying, "adopted")
        applying = []
    }

    /// EXPORT MIGRATION: the same statements as the review sheet, to a .sql file.
    func export(_ ws: WorkspaceModel, layer id: String) {
        let c = changes(id)
        guard !c.changes.isEmpty else { notice = "Nothing to export: no live row patches in \(name(id))."; return }
        var set = ChangeSet(); c.changes.forEach { set.add($0) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name(id))-migration.sql".replacingOccurrences(of: " ", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sql = "-- DBMan migration from layer \(name(id)) (\(ws.profile.name)): \(c.ids.count) row patches\n" + set.transactionSQL(engine: ws.profile.engine) + "\n"
        do { try sql.write(to: url, atomically: true, encoding: .utf8); notice = "Exported \(url.lastPathComponent)" } catch { notice = error.localizedDescription }
    }

    // MARK: DevHooks

    /// DBMAN_LAYER=<agent>[:diff|:seeas]: open the panel on that agent's layer (:seeas = SEE AS that agent).
    func devSelect(_ spec: String, _ ws: WorkspaceModel) {
        reload(ws)
        let parts = spec.split(separator: ":").map(String.init)
        selected = layers.first { $0.agentID == parts[0] || $0.name == parts[0] }?.id
        open = true; compare = parts.contains("diff")
        if parts.contains("seeas") { seeAs = selected ?? "db" }
        Task {
            await refresh(ws)
            if parts.contains("apply"), let id = selected { apply(ws, layer: id) }
        }
    }
}
