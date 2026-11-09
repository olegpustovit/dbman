import AppKit
import DBCore
import DBStore
import Foundation
import Observation
import SwiftUI

enum MapLayoutKind: String, CaseIterable { case layered, clusters, focus, free }
enum MapExport: String, CaseIterable { case png = "PNG", svg = "SVG", mermaid = "MERMAID", dbml = "DBML" }

/// Zoom + where the world's origin sits in the viewport. nil = fit.
struct MapViewport: Equatable { var zoom: CGFloat; var origin: CGPoint }

extension WorkspaceModel {
    /// The id this connection has in the DBMan store (the internal one is not a UUID there).
    var storeID: String { profile.environment == .system ? Store.internalID : profile.id.uuidString }
}

/// Everything the schema map remembers while its window is open (it survives route changes).
@MainActor @Observable
final class SchemaMapState {
    var kind: MapLayoutKind = .layered { didSet { if kind != oldValue { viewport = nil; rebuild() } } }
    var detail: MapDetail = .keys { didSet { if detail != oldValue { viewport = nil; rebuild() } } }
    var hops = 2 { didSet { if hops != oldValue { viewport = nil; rebuild() } } }
    var hideJunctions = false { didSet { if hideJunctions != oldValue { viewport = nil; rebuild() } } }
    var hideIsolated = false { didSet { if hideIsolated != oldValue { viewport = nil; rebuild() } } }
    var showInferred = true { didSet { if showInferred != oldValue { rebuild() } } }
    var selection: String?
    var focusOn: String? { didSet { if kind == .focus, focusOn != oldValue { viewport = nil; rebuild() } } }
    var filter = ""
    var filterOpen = false
    var pathMode = false { didSet { if !pathMode { pathPicks = [] } } }
    var pathPicks: [String] = []
    var viewport: MapViewport?
    var exportOpen = false { didSet { if exportOpen { agentOpen = false } } }
    var exportFormat: MapExport = .mermaid
    var agentOpen = false { didSet { if agentOpen { exportOpen = false } } }
    var notice: String?
    /// Clusters the user opened (past MapLayouts.collapseAbove tables they start collapsed) and the names they gave (keyed by the automatic name, saved in map_layouts).
    private(set) var expanded: Set<String> = []
    private(set) var clusterNames: [String: String] = [:]
    var renaming: String?

    private(set) var scene = MapScene(graph: SchemaGraph(schema: SchemaSnapshot(serverVersion: "", databaseName: "", tables: [])), detail: .keys, layout: MapLayout())
    private(set) var full: SchemaGraph?
    private var virtual: [VirtualRelation] = []
    private var free: [String: CGPoint] = [:]
    private var schema: SchemaSnapshot?
    private var connectionID = ""
    private var store: Store?
    private var loaded = ""

    // MARK: inputs

    /// Called whenever the window's schema or store may have changed.
    func attach(_ ws: WorkspaceModel, store: Store) {
        guard let s = ws.schema else { return }
        self.store = store; connectionID = ws.storeID
        if loaded != connectionID {
            loaded = connectionID
            let saved = store.mapLayout(connectionID, "free").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: [CGFloat]].self, from: $0) } ?? [:]
            free = saved.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            clusterNames = store.mapLayout(connectionID, "clusters").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            expanded = []
            if s.tables.count > MapLayouts.collapseAbove { kind = .clusters } // G17: the layered map is unusable here
        }
        schema = s
        // relations of the visible layers (the layer toggles and SEE AS decide), each tagged with its agent layer
        let layers = ws.layers, vis = layers.visible
        virtual = layers.items(of: nil).filter { $0.kind == "relation" && vis.contains($0.layer) && ["active", "stale"].contains($0.status) }.compactMap { i in
            guard var v = i.payload.data(using: .utf8).flatMap({ try? JSONDecoder().decode(VirtualRelation.self, from: $0) }) else { return nil }
            if layers.layers.first(where: { $0.id == i.layer })?.isMine == false { v.layer = layers.name(i.layer) }
            return v
        }
        full = SchemaGraph(schema: s, virtual: virtual)
        if selection.map({ full?.table($0) == nil }) ?? false { selection = nil }
        rebuild()
    }

    func rebuild() {
        guard let full else { return }
        var g = full.filtered(hideJunctions: hideJunctions, hideIsolated: hideIsolated, showInferred: showInferred)
        let sizes = g.sizes(detail)
        var layout: MapLayout
        switch kind {
        case .layered: layout = MapLayouts.layered(g, sizes)
        case .clusters: layout = MapLayouts.clusters(g, sizes, expanded: expanded)
        case .focus:
            let center = [focusOn, selection].compactMap { $0 }.first { g.table($0) != nil } ?? g.tables.max { $0.rowCount < $1.rowCount }?.name ?? ""
            layout = MapLayouts.focus(g, sizes, center: center, hops: hops)
            g = g.filtered(keep: Set(layout.origins.keys))
        case .free:
            layout = MapLayouts.layered(g, sizes)
            for (n, p) in free where layout.origins[n] != nil { layout.origins[n] = p }
        }
        scene = MapScene(graph: g, detail: detail, layout: layout)
    }

    // MARK: derived

    var path: JoinPath? { pathPicks.count == 2 ? full?.path(from: pathPicks[0], to: pathPicks[1]) : nil }
    var matches: Set<String> { scene.graph.matching(filter) }
    func dimmed(_ t: String) -> Bool {
        (pathPicks.count == 2 && !(path?.tables.contains(t) ?? false)) || (!filter.isEmpty && !matches.contains(t))
    }
    func onPath(_ e: MapEdge) -> Bool { path?.steps.contains { $0.from == e.from && $0.fromColumn == e.fromColumn && $0.to == e.to } ?? false }
    var inferredFor: [MapEdge] { selection.map { s in scene.graph.edges.filter { $0.kind == .inferred && ($0.from == s || $0.to == s) } } ?? [] }

    // MARK: actions

    func tap(_ t: String) {
        if pathMode {
            pathPicks = pathPicks.count == 1 && pathPicks[0] != t ? pathPicks + [t] : [t]
            selection = t
        } else { selection = selection == t ? nil : t }
    }
    func focus(_ t: String?) {
        guard let t = t ?? selection else { return }
        selection = t; focusOn = t; kind = .focus
    }

    /// Arrow keys: step the selection to the neighbour lying most in that direction.
    func walk(dx: CGFloat, dy: CGFloat) {
        guard let s = selection, let a = scene.rect(s) else { selection = scene.graph.tables.first?.name; return }
        let best = scene.graph.neighbors(s).compactMap { n -> (String, CGFloat)? in
            guard let r = scene.rect(n) else { return nil }
            let vx = r.midX - a.midX, vy = r.midY - a.midY, len = max(hypot(vx, vy), 1)
            let dot = (vx * dx + vy * dy) / len
            return dot > 0.3 ? (n, dot) : nil
        }.max { $0.1 < $1.1 }
        if let best { selection = best.0 }
    }

    func move(_ t: String, to p: CGPoint) { scene.layout.origins[t] = p }
    /// Drag finished in FREE: pin every card where it is and save per connection.
    func pinAll() {
        guard kind == .free else { return }
        free.merge(scene.layout.origins) { $1 }
        let json = (try? JSONEncoder().encode(free.mapValues { [$0.x, $0.y] })).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try? store?.setMapLayout(connectionID, "free", positions: json)
    }

    /// ACCEPT AS RELATION: an overlay item in MINE, drawn as virtual from now on. Never DDL.
    func accept(_ e: MapEdge) {
        let v = VirtualRelation(fromTable: e.from, fromColumn: e.fromColumn, toTable: e.to, toColumn: e.toColumn)
        guard let data = try? JSONEncoder().encode(v), let payload = String(data: data, encoding: .utf8) else { return }
        do { try store?.addRelation(connectionID, name: "\(e.from).\(e.fromColumn) -> \(e.to).\(e.toColumn)", payload: payload) } catch { notice = error.localizedDescription; return }
        virtual.append(v)
        full = schema.map { SchemaGraph(schema: $0, virtual: virtual) }
        rebuild()
    }

    func clusterName(_ key: String) -> String { clusterNames[key] ?? key }
    func toggleCluster(_ key: String) {
        if !expanded.insert(key).inserted { expanded.remove(key) }
        viewport = nil; rebuild()
    }
    /// An empty name restores the automatic one.
    func rename(_ key: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        clusterNames[key] = n.isEmpty ? nil : n
        let json = (try? JSONEncoder().encode(clusterNames)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try? store?.setMapLayout(connectionID, "clusters", positions: json)
    }

    // MARK: viewport

    func fit(in size: CGSize) -> MapViewport {
        let b = scene.layout.bounds(scene.sizes)
        guard b.width > 0, b.height > 0 else { return MapViewport(zoom: 1, origin: .zero) }
        let z = min(1.1, (size.width - 24) / (b.width + 20), (size.height - 56) / (b.height + 20)).clamped(0.25, 4)
        return MapViewport(zoom: z, origin: CGPoint(x: (size.width - b.width * z) / 2 - b.minX * z, y: 34 + (size.height - 46 - b.height * z) / 2 - b.minY * z))
    }
    func zoom(by f: CGFloat, in size: CGSize, anchor: CGPoint? = nil) {
        let v = viewport ?? fit(in: size), z = (v.zoom * f).clamped(0.25, 4), a = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        viewport = MapViewport(zoom: z, origin: CGPoint(x: a.x - (a.x - v.origin.x) * z / v.zoom, y: a.y - (a.y - v.origin.y) * z / v.zoom))
    }

    // MARK: export

    func exportText(_ f: MapExport) -> String {
        switch f {
        case .mermaid: SchemaExport.mermaid(scene.graph)
        case .dbml: SchemaExport.dbml(scene.graph)
        case .svg: SchemaExport.svg(scene)
        case .png: ""
        }
    }

    #if DEBUG
    /// DBMAN_MAP=<layout>[:<table>[:<hops>]]  DBMAN_MAP_PATH=a>b  DBMAN_MAP_DETAIL=names|keys|all
    func applyDevHook() {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["DBMAN_MAP"] {
            let p = spec.split(separator: ":").map(String.init)
            if let t = p.dropFirst().first { selection = t; focusOn = t }
            if let h = p.dropFirst(2).first.flatMap(Int.init) { hops = h }
            if let k = p.first.flatMap(MapLayoutKind.init) { kind = k }
        }
        if let d = env["DBMAN_MAP_DETAIL"].flatMap(MapDetail.init) { detail = d }
        if let ab = env["DBMAN_MAP_PATH"]?.split(separator: ">").map(String.init), ab.count == 2 { pathMode = true; pathPicks = ab; selection = ab[1] }
    }
    #endif
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}
