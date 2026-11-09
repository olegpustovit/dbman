import AppKit
import DBCore
import Halftone
import SwiftUI

/// SCHEMA MAP: toolbar · canvas (cards, edges, minimap, path drawer, popovers) · inspector · status line.
struct SchemaMapView: View {
    let ws: WorkspaceModel
    @Environment(AppModel.self) private var app
    @FocusState private var canvasFocus: Bool
    @FocusState private var filterFocus: Bool
    @State private var clusterName = ""

    private var map: SchemaMapState { ws.map }
    private var stamp: String { "\(ws.schema.map { $0.tables.count * 100_000 + $0.tables.reduce(0) { $0 + $1.columns.count } } ?? 0) \(ws.layers.items.count) \(ws.layers.visible.sorted())" }

    var body: some View {
        @Bindable var map = ws.map
        HStack(spacing: HT.M.seam) {
            VStack(spacing: HT.M.seam) {
                HTFrame(title: "Schema map", tail: caption, accessory: { header(map) }) {
                    VStack(spacing: 0) {
                        options(map)
                        Divider()
                        viewportView
                    }
                }
                statusLine
            }
            if ws.showInspector { MapInspector(ws: ws, map: map).frame(width: 288) }
        }
        .alert("Rename cluster", isPresented: Binding(get: { map.renaming != nil }, set: { if !$0 { map.renaming = nil } })) {
            TextField(map.renaming ?? "", text: $clusterName)
            Button("Rename") { if let k = map.renaming { map.rename(k, to: clusterName) }; clusterName = ""; map.renaming = nil }
            Button("Cancel", role: .cancel) { clusterName = ""; map.renaming = nil }
        } message: { Text("Saved with this connection. Empty restores the automatic name.") }
        .task(id: stamp) { map.attach(ws, store: app.store) }
    }

    // MARK: toolbar

    private var caption: String {
        let g = map.scene.graph
        if map.pathMode { return map.path.map { "path · \($0.joins) joins" } ?? "path · pick two tables" }
        switch map.kind {
        case .layered: return "layered · fk direction · parents left"
        case .clusters: return "clusters · \(map.scene.layout.boxes.count) groups"
        case .focus: return "focus · \(map.focusOn ?? map.selection ?? "") · \(map.hops) \(map.hops == 1 ? "hop" : "hops") · \(g.tables.count) of \(map.full?.tables.count ?? 0) in range"
        case .free: return "free · pinned positions · saved per connection"
        }
    }

    private func header(_ map: SchemaMapState) -> some View {
        @Bindable var map = map
        return HStack(spacing: 6) {
            HTSegmented(selection: $map.kind, options: MapLayoutKind.allCases.enumerated().map { ($1, "\($0 + 1) \($1.rawValue)") })
            HTSegmented(selection: $map.detail, options: MapDetail.allCases.map { ($0, $0 == .all ? "ALL COLUMNS" : $0.rawValue) })
            Button { map.exportOpen.toggle() } label: { Text("Export ▾") }.buttonStyle(.htOutline).keyboardShortcut("e", modifiers: [.command, .shift]).help("Export map  ⇧⌘E")
            Button { map.agentOpen.toggle() } label: { Text("Explain") }.buttonStyle(.htOutline).help("Explain this schema: copies a prompt for your agent")
        }
    }

    private func options(_ map: SchemaMapState) -> some View {
        @Bindable var map = map
        return HStack(spacing: 6) {
            Button { map.filterOpen = true; filterFocus = true } label: { EmptyView() }.keyboardShortcut("f").frame(width: 0).opacity(0).accessibilityHidden(true)
            HTSearchField(text: $map.filter, prompt: "Filter tables, columns", shortcut: "⌘F").focused($filterFocus).frame(minWidth: 90, maxWidth: 160)
                .onKeyPress(.escape) { map.filter = ""; filterFocus = false; canvasFocus = true; return .handled }
            HTToggleChip("hide junctions", isOn: $map.hideJunctions)
            HTToggleChip("hide isolated", isOn: $map.hideIsolated)
            HTToggleChip("show inferred", isOn: $map.showInferred)
            HTToggleChip("path", isOn: $map.pathMode).help("Pick two tables, get the join  P")
            if map.kind == .focus {
                HStack(spacing: 4) {
                    CapsLabel("hops").foregroundStyle(HT.C.ink3)
                    HTSegmented(selection: $map.hops, options: [(1, "1"), (2, "2"), (3, "3")]).fixedSize()
                }
            }
            Spacer(minLength: 0)
            layerToggles.fixedSize()
            Button("−") { map.zoom(by: 1 / 1.25, in: map.canvasSize) }.buttonStyle(.htOutline).keyboardShortcut("-").help("Zoom out  ⌘−")
            ZoomReadout(map: map).ht(.dataSmall).frame(minWidth: 44)
            Button("+") { map.zoom(by: 1.25, in: map.canvasSize) }.buttonStyle(.htOutline).keyboardShortcut("=").help("Zoom in  ⌘+")
            Button("Fit F") { map.viewport = nil }.buttonStyle(.htOutline).help("Fit to window  F")
        }
        .padding(.horizontal, 10).frame(height: 32)
    }

    /// DATABASE is always on; MINE and each agent layer can be hidden (the same visibility as the Store panel; SEE AS locks it).
    private var layerToggles: some View {
        HStack(spacing: 4) {
            CapsLabel("layers //").foregroundStyle(HT.C.ink3)
            Text("DB ✓").ht(.labelSmall).padding(.horizontal, 6).frame(height: 18).overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink3, lineWidth: 1)).help("DATABASE is always visible and read-only")
            ForEach(ws.layers.stack.filter { !$0.archived }) { l in
                let on = ws.layers.visible.contains(l.id)
                HTToggleChip((l.isMine ? "MINE" : layerMono(l.name)) + (on ? " ✓" : " –"), isOn: Binding(get: { on }, set: { _ in ws.layers.toggle(l) }))
                    .disabled(ws.layers.seeAs != nil).help((on ? "Hide " : "Show ") + l.name + " layer: its virtual relations on the map")
            }
        }
    }

    // MARK: viewport

    /// The canvas lives in its own view: only it (and the two zoom readouts) observe `viewport`, so a pan frame does not re-render the toolbar or inspector.
    private var viewportView: some View {
        MapCanvasView(ws: ws, map: map, onBackgroundTap: { canvasFocus = true })
            .focusable().focused($canvasFocus).focusEffectDisabled()
            .onAppear { canvasFocus = true }
            .onKeyPress(phases: .down) { press in key(press) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Schema map, \(map.scene.graph.tables.count) tables")
    }

    private func key(_ p: KeyPress) -> KeyPress.Result {
        guard !p.modifiers.contains(.command) else { return .ignored }
        switch p.key {
        case .leftArrow: map.walk(dx: -1, dy: 0)
        case .rightArrow: map.walk(dx: 1, dy: 0)
        case .upArrow: map.walk(dx: 0, dy: -1)
        case .downArrow: map.walk(dx: 0, dy: 1)
        case .space: map.focus(nil)
        case .return: if let s = map.selection { ws.go(.table(s)) }
        case .escape:
            if map.exportOpen || map.agentOpen { map.exportOpen = false; map.agentOpen = false }
            else if map.pathMode { map.pathMode = false } else { map.selection = nil }
        default:
            switch p.characters.lowercased() {
            case "f": map.viewport = nil
            case "p": map.pathMode.toggle()
            case "1", "2", "3", "4": map.kind = MapLayoutKind.allCases[Int(p.characters)! - 1]
            default: return .ignored
            }
        }
        return .handled
    }

    // MARK: status

    private var statusLine: some View {
        let g = map.scene.graph, total = map.full?.tables.count ?? 0
        let declared = g.edges.filter { $0.kind == .declared && !$0.manyToMany }.count, inferred = g.edges.filter { $0.kind == .inferred }.count
        let virtual = g.edges.filter { $0.kind == .virtual }.count
        return HStack(spacing: 14) {
            Text("\(g.tables.count == total ? "\(total)" : "\(g.tables.count) of \(total)") tables · \(declared + virtual) relations · \(inferred) inferred" + (virtual > 0 ? " · \(virtual) virtual · mine" : "")).ht(.labelSmall)
            HStack(spacing: 0) {
                Text("\(map.kind.rawValue) · \(map.detail.rawValue) · ")
                ZoomReadout(map: map)
                Text(map.selection.map { " · selected \($0)" } ?? "")
            }.ht(.labelSmall).foregroundStyle(HT.C.ink3)
            legend
            Spacer(minLength: 0)
            if let n = map.notice { Text(n).ht(.labelSmall).foregroundStyle(HT.C.alert) }
            Text("←→ walk · ⎵ focus · F fit · 1–4 layout · ⌘F filter").ht(.labelSmall).foregroundStyle(HT.C.ink3)
        }
        .lineLimit(1).frame(height: HT.M.statusStrip).padding(.horizontal, 4)
    }

    private var legend: some View {
        func swatch(_ label: String, _ dash: [CGFloat], _ color: Color) -> some View {
            HStack(spacing: 5) {
                Canvas { ctx, size in
                    var p = Path(); p.move(to: CGPoint(x: 1, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.2, dash: dash))
                }.frame(width: 22, height: 10)
                Text(label).ht(.labelSmall).foregroundStyle(HT.C.ink3)
            }
        }
        return HStack(spacing: 12) { swatch("declared", [], HT.C.ink); swatch("inferred", [3, 2], HT.C.accent); swatch("virtual", [6, 2, 1.5, 2], HT.C.ink) }.accessibilityHidden(true)
    }
}

/// `74 %`: the only toolbar piece that follows the viewport.
private struct ZoomReadout: View {
    let map: SchemaMapState
    var body: some View { Text("\(Int(((map.viewport ?? map.fit(in: map.canvasSize)).zoom * 100).rounded())) %").monospacedDigit() }
}

/// Dot grid + edges + cards + minimap + overlays. Pan and zoom write `map.viewport`; everything heavy underneath is cached or equatable.
private struct MapCanvasView: View {
    let ws: WorkspaceModel
    let map: SchemaMapState
    let onBackgroundTap: () -> Void
    @State private var panStart: MapViewport?
    @State private var zoomStart: MapViewport?

    var body: some View {
        GeometryReader { geo in
            let vp = map.viewport ?? map.fit(in: geo.size)
            let path = map.path
            let style = MapStyle(selection: map.selection, dimmed: map.dimmedSet, onPath: map.pathEdgeKeys,
                                 pathIndex: Dictionary(uniqueKeysWithValues: (path?.tables ?? []).enumerated().map { ($1, $0) }).merging(
                                    path == nil ? Dictionary(uniqueKeysWithValues: map.pathPicks.enumerated().map { ($1, $0) }) : [:]) { a, _ in a },
                                 neighbors: map.neighborsOfSelection, isolated: map.isolatedSet, interactive: map)
            let _ = { map.liveZoom = vp.zoom }()
            ZStack(alignment: .bottomTrailing) {
                DotGrid(viewport: vp)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { g in
                        let s = panStart ?? vp; panStart = s
                        map.viewport = MapViewport(zoom: s.zoom, origin: CGPoint(x: s.origin.x + g.translation.width, y: s.origin.y + g.translation.height))
                    }.onEnded { _ in panStart = nil })
                    .onTapGesture { map.selection = nil; onBackgroundTap() }
                MapWorld(scene: map.scene, style: style, viewport: vp, routes: map.routes, sceneRev: map.sceneRev)
                if map.scene.graph.tables.isEmpty { Text("No tables match").ht(.label).foregroundStyle(HT.C.ink3).frame(maxWidth: .infinity, maxHeight: .infinity) }
                MiniMap(map: map, viewport: vp, size: geo.size).padding(10).padding(.bottom, map.pathMode && map.pathPicks.count == 2 ? 172 : 0)
                WheelCatcher { dx, dy, cmd, at in
                    if cmd { map.zoom(by: exp(dy * 0.01), in: geo.size, anchor: at) }
                    else { let v = map.viewport ?? map.fit(in: geo.size); map.viewport = MapViewport(zoom: v.zoom, origin: CGPoint(x: v.origin.x + dx, y: v.origin.y + dy)) }
                }.allowsHitTesting(false)
                if map.pathMode && map.pathPicks.count == 2 { PathDrawer(ws: ws, map: map, path: path).frame(height: 172).frame(maxHeight: .infinity, alignment: .bottom) }
                if map.exportOpen { ExportPopover(ws: ws, map: map).padding(.top, 4).padding(.trailing, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                if map.agentOpen { AgentPopover(ws: ws, map: map).padding(.top, 4).padding(.trailing, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            }
            .clipped()
            .onAppear { map.canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in map.canvasSize = s }
            .gesture(MagnifyGesture().onChanged { v in
                // pinch zooms around the point under the fingers: that world point stays put on screen
                let s = zoomStart ?? vp; zoomStart = s
                let z = (s.zoom * v.magnification).clamped(0.25, 4), a = v.startLocation
                map.viewport = MapViewport(zoom: z, origin: CGPoint(x: a.x - (a.x - s.origin.x) * z / s.zoom, y: a.y - (a.y - s.origin.y) * z / s.zoom))
            }.onEnded { _ in zoomStart = nil })
        }
    }
}

/// 16 pt dot grid that moves with the world: one tiled image, not thousands of rects.
private struct DotGrid: View {
    let viewport: MapViewport
    /// One 16×16 tile with a dot in the corner; drawn lazily so it follows light/dark.
    private static let tile: Image = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            HT.NS.fill30.setFill(); NSRect(x: 0, y: 0, width: 0.8, height: 0.8).fill(); return true
        }
        return Image(nsImage: img)
    }()
    var body: some View {
        Canvas { ctx, size in
            let g = 16 * viewport.zoom
            guard g > 6 else { return }
            let o = CGPoint(x: viewport.origin.x.truncatingRemainder(dividingBy: g) - 0.4, y: viewport.origin.y.truncatingRemainder(dividingBy: g) - 0.4)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(Self.tile, origin: o, scale: viewport.zoom))
        }
    }
}

/// Bottom-right overview of the whole map with the visible window outlined; click to recentre.
private struct MiniMap: View {
    let map: SchemaMapState
    let viewport: MapViewport
    let size: CGSize

    var body: some View {
        let b = map.scene.layout.bounds(map.scene.sizes).insetBy(dx: -20, dy: -20)
        let w: CGFloat = 168, k = w / max(b.width, 1), h = min(96, b.height * k)
        let s = min(k, h / max(b.height, 1))
        VStack(spacing: 0) {
            HStack { CapsLabel("map").foregroundStyle(HT.C.ink3).font(.system(size: 9)); Spacer() }.padding(.horizontal, 6).frame(height: 16)
            Divider()
            Canvas { ctx, _ in
                for bx in map.scene.layout.boxes where bx.collapsed { ctx.fill(Path(CGRect(x: (bx.rect.minX - b.minX) * s, y: (bx.rect.minY - b.minY) * s, width: bx.rect.width * s, height: bx.rect.height * s)), with: .color(HT.C.ink3.opacity(0.6))) }
                for t in map.scene.graph.tables {
                    guard let r = map.scene.rect(t.name) else { continue }
                    let q = CGRect(x: (r.minX - b.minX) * s, y: (r.minY - b.minY) * s, width: r.width * s, height: r.height * s)
                    ctx.fill(Path(q), with: .color(t.name == map.selection ? HT.C.accent : HT.C.ink3.opacity(0.6)))
                }
                let v = CGRect(x: (-viewport.origin.x / viewport.zoom - b.minX) * s, y: (-viewport.origin.y / viewport.zoom - b.minY) * s, width: size.width / viewport.zoom * s, height: size.height / viewport.zoom * s)
                ctx.stroke(Path(v), with: .color(HT.C.accent), lineWidth: 1)
            }
            .frame(width: b.width * s, height: b.height * s).clipped()
            .contentShape(Rectangle())
            .onTapGesture { p in // SpatialTapGesture would be nicer; a tap recentres on the tapped spot
                let wx = p.x / s + b.minX, wy = p.y / s + b.minY
                map.viewport = MapViewport(zoom: viewport.zoom, origin: CGPoint(x: size.width / 2 - wx * viewport.zoom, y: size.height / 2 - wy * viewport.zoom))
            }
        }
        .frame(width: b.width * s)
        .background(HT.C.paper)
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
        .accessibilityElement(children: .ignore).accessibilityLabel("Minimap of \(map.scene.graph.tables.count) tables")
    }
}

/// Trackpad / wheel scrolling over the canvas pans; ⌘ + scroll zooms. Clicks pass through.
private struct WheelCatcher: NSViewRepresentable {
    let onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ command: Bool, _ at: CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak c = context.coordinator] e in
            guard let c, let v = c.view, v.window === e.window else { return e }
            let p = v.convert(e.locationInWindow, from: nil)
            guard v.bounds.contains(p) else { return e }
            c.onScroll(e.scrollingDeltaX, e.scrollingDeltaY, e.modifierFlags.contains(.command), CGPoint(x: p.x, y: v.bounds.height - p.y))
            return nil
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }
    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { if let m = coordinator.monitor { NSEvent.removeMonitor(m) } }

    final class Coordinator {
        var onScroll: (CGFloat, CGFloat, Bool, CGPoint) -> Void
        var monitor: Any?
        weak var view: NSView?
        init(onScroll: @escaping (CGFloat, CGFloat, Bool, CGPoint) -> Void) { self.onScroll = onScroll }
    }
}
