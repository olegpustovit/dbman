import DBCore
import Halftone
import SwiftUI

/// What the world draws besides the scene itself, as plain data (so the cards layer can be compared and skipped).
/// Defaults give the static look used by PNG export.
struct MapStyle: Equatable {
    var selection: String?
    var dimmed: Set<String> = []
    var onPath: Set<String> = []          // SchemaMapState.key(edge)
    var pathIndex: [String: Int] = [:]
    var neighbors: Set<String> = []
    var isolated: Set<String>? = nil      // nil = compute from the graph (export)
    var interactive: SchemaMapState?
    static func == (a: MapStyle, b: MapStyle) -> Bool {
        a.selection == b.selection && a.dimmed == b.dimmed && a.onPath == b.onPath && a.pathIndex == b.pathIndex && a.neighbors == b.neighbors
            && a.isolated == b.isolated && a.interactive === b.interactive
    }
}

/// Edges (one GPU-backed Canvas in viewport space, so lines stay crisp at any zoom) under the cards (SwiftUI, world space).
/// A pan or zoom frame only re-strokes cached curves and re-applies one transform to the cards; the cards are not rebuilt.
struct MapWorld: View {
    let scene: MapScene
    let style: MapStyle
    let viewport: MapViewport
    var routes: [SchemaMapState.EdgeGeo]? = nil
    var sceneRev = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapEdgesCanvas(scene: scene, routes: routes ?? SchemaMapState.geometry(scene), style: style, viewport: viewport)
            MapCardsLayer(scene: scene, style: style, sceneRev: sceneRev)
                .equatable()
                .scaleEffect(viewport.zoom, anchor: .topLeading)
                .offset(x: viewport.origin.x, y: viewport.origin.y)
        }
    }
}

/// Every card, cluster frame and edge pill in world space. Equal while the scene, selection, filter and path are unchanged,
/// so SwiftUI skips its body during pans and zooms.
struct MapCardsLayer: View, Equatable {
    let scene: MapScene
    let style: MapStyle
    let sceneRev: Int
    static func == (a: Self, b: Self) -> Bool { a.sceneRev == b.sceneRev && a.style == b.style && (a.sceneRev != 0 || b.sceneRev != 0) }

    var body: some View {
        let isolated = style.isolated ?? scene.graph.isolated
        ZStack(alignment: .topLeading) {
            ForEach(scene.layout.boxes, id: \.name) { b in
                let rows = b.members.reduce(Int64(0)) { $0 + (scene.graph.table($1)?.rowCount ?? 0) }
                let name = style.interactive?.clusterName(b.name) ?? b.name
                // a collapsed cluster is one frame: name + table count; click opens it, right-click renames
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text((b.collapsed ? "▸ " : "") + name).foregroundStyle(HT.C.ink)
                        if !b.collapsed { Text("\(b.members.count) · \(HTFormat.compact(rows)) rows").foregroundStyle(HT.C.ink3) }
                    }
                    if b.collapsed { Text("\(b.members.count) tables · \(HTFormat.compact(rows)) rows").foregroundStyle(HT.C.ink3) }
                }
                .ht(.labelSmall).padding(.top, 8).padding(.leading, 10).frame(width: b.collapsed ? b.rect.width : nil, height: b.collapsed ? b.rect.height : nil, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { if b.collapsed { style.interactive?.toggleCluster(b.name) } }
                .contextMenu {
                    Button(b.collapsed ? "Expand" : "Collapse") { style.interactive?.toggleCluster(b.name) }
                    Button("Rename cluster…") { style.interactive?.renaming = b.name }
                }
                .offset(x: b.rect.minX, y: b.rect.minY)
            }
            ForEach(scene.graph.tables, id: \.name) { t in
                if let o = scene.layout.origins[t.name] {
                    MapCard(scene: scene, table: t, style: style, isolated: isolated.contains(t.name), rev: sceneRev,
                            selected: style.selection == t.name, neighbor: style.neighbors.contains(t.name), dimmed: style.dimmed.contains(t.name), pathIndex: style.pathIndex[t.name])
                        .equatable().offset(x: o.x, y: o.y)
                }
            }
            ForEach(scene.graph.edges.filter { $0.kind == .inferred || $0.kind == .virtual || $0.manyToMany }, id: \.self) { e in
                if let r = scene.route(e) { pill(e).position(r.point(at: 0.5)).opacity(style.dimmed.contains(e.from) || style.dimmed.contains(e.to) ? 0.25 : 1) }
            }
        }
    }

    @ViewBuilder private func pill(_ e: MapEdge) -> some View {
        let inferred = e.kind == .inferred
        let label = inferred ? "ACCEPT AS RELATION" : e.manyToMany ? "M:N" : e.layer.map(layerMono) ?? "MINE"
        let help = inferred ? "\(e.from).\(e.fromColumn) → \(e.to).\(e.toColumn): name and type match. Accepting stores a virtual relation in your layer (MINE). Never DDL."
            : e.manyToMany ? "Junction table hidden: drawn as many-to-many" : "VIRTUAL · \(e.layer?.uppercased() ?? "MINE"): \(e.layer == nil ? "accepted relation" : "added by the agent in its own layer"), lives only in DBMan. Never DDL."
        Button { style.interactive?.accept(e) } label: {
            Text(label).ht(.labelSmall).foregroundStyle(e.manyToMany ? HT.C.ink3 : HT.C.accent)
                .padding(.horizontal, 6).frame(height: 18)
                .background(HT.C.paper, in: RoundedRectangle(cornerRadius: inferred ? 9 : HT.M.radius))
                .overlay(RoundedRectangle(cornerRadius: inferred ? 9 : HT.M.radius).strokeBorder(e.manyToMany ? HT.C.line : HT.C.accent, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!inferred || style.interactive == nil)
        .help(help)
    }
}

/// Cluster frames, focus rings and every edge, stroked from cached geometry. Rendered through Metal (drawingGroup).
struct MapEdgesCanvas: View {
    let scene: MapScene
    let routes: [SchemaMapState.EdgeGeo]
    let style: MapStyle
    let viewport: MapViewport

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size) }
            .drawingGroup(opaque: false)
            .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        ctx.translateBy(x: viewport.origin.x, y: viewport.origin.y)
        ctx.scaleBy(x: viewport.zoom, y: viewport.zoom)
        let hair = 1 / min(viewport.zoom, 1)
        for b in scene.layout.boxes { ctx.stroke(Path(roundedRect: b.rect, cornerRadius: 3), with: .color(HT.C.ink3), style: StrokeStyle(lineWidth: hair, dash: [4 * hair, 3 * hair])) }
        if let c = scene.layout.hops.first(where: { $0.value == 0 })?.key, let cr = scene.rect(c) {
            for k in 1...max(1, scene.layout.hops.values.max() ?? 1) {
                let ds = scene.layout.hops.filter { $0.value == k }.compactMap { scene.rect($0.key) }.map { hypot($0.midX - cr.midX, $0.midY - cr.midY) }
                guard !ds.isEmpty else { continue }
                let r = ds.reduce(0, +) / CGFloat(ds.count)
                ctx.stroke(Path(ellipseIn: CGRect(x: cr.midX - r, y: cr.midY - r, width: 2 * r, height: 2 * r)), with: .color(HT.C.ink3.opacity(0.7)), style: StrokeStyle(lineWidth: hair, dash: [2 * hair, 4 * hair]))
            }
        }
        // only what is on screen (plus a margin) is stroked
        let visible = CGRect(x: -viewport.origin.x / viewport.zoom, y: -viewport.origin.y / viewport.zoom, width: size.width / viewport.zoom, height: size.height / viewport.zoom).insetBy(dx: -40, dy: -40)
        let pathMode = !style.pathIndex.isEmpty
        for g in routes {
            let e = g.edge, r = g.route
            let bounds = CGRect(x: min(r.p0.x, r.p1.x, r.c1.x, r.c2.x), y: min(r.p0.y, r.p1.y, r.c1.y, r.c2.y), width: 0, height: 0)
                .union(CGRect(x: max(r.p0.x, r.p1.x, r.c1.x, r.c2.x), y: max(r.p0.y, r.p1.y, r.c1.y, r.c2.y), width: 0, height: 0))
            guard bounds.insetBy(dx: -10, dy: -10).intersects(visible) else { continue }
            let onPath = style.onPath.contains(SchemaMapState.key(e))
            let touches = style.selection.map { e.from == $0 || e.to == $0 } ?? false
            let dim = style.dimmed.contains(e.from) || style.dimmed.contains(e.to) || (pathMode && !onPath)
            let color = onPath || e.kind == .inferred ? HT.C.accent : HT.C.ink
            let lw = (onPath ? 2.2 : touches ? 1.8 : 1.1) * hair
            let dash: [CGFloat] = e.kind == .inferred ? [5, 4] : e.kind == .virtual ? [7, 3, 1.5, 3] : e.manyToMany ? [1.5, 3] : []
            var c = ctx
            c.opacity = dim ? 0.18 : (style.selection != nil && !touches && !pathMode ? 0.38 : 1)
            var line = Path(); line.move(to: r.p0); line.addCurve(to: r.p1, control1: r.c1, control2: r.c2)
            c.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: dash.map { $0 * hair }))
            var marks = Path()
            for (p, q) in g.lines { marks.move(to: p); marks.addLine(to: q) }
            c.stroke(marks, with: .color(color), lineWidth: max(1.2, lw * 0.85 / hair) * hair)
            for p in g.rings {
                let ring = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                c.fill(ring, with: .color(HT.C.paper)); c.stroke(ring, with: .color(color), lineWidth: 1.2 * hair)
            }
        }
    }
}

/// One table: header, shown columns, footer with the row-count halftone bar.
/// Equatable on what it draws, so a selection change redraws only the cards whose state changed.
struct MapCard: View, Equatable {
    let scene: MapScene
    let table: TableInfo
    let style: MapStyle
    let isolated: Bool
    var rev = 0
    let selected: Bool
    let neighbor: Bool
    let dimmed: Bool
    let pathIndex: Int?
    @State private var dragStart: CGPoint?
    static func == (a: Self, b: Self) -> Bool {
        a.rev == b.rev && a.rev != 0 && a.table.name == b.table.name && a.selected == b.selected && a.neighbor == b.neighbor
            && a.dimmed == b.dimmed && a.pathIndex == b.pathIndex && a.isolated == b.isolated && a.style.interactive === b.style.interactive
    }

    private var cols: [ColumnInfo] { scene.graph.shownColumns(table, scene.detail) }
    private var size: CGSize { scene.sizes[table.name] ?? .zero }
    private var inferredCols: Set<String> { Set(scene.graph.edges.filter { $0.from == table.name && $0.kind != .declared }.map(\.fromColumn)) }
    private var tag: String {
        if let i = pathIndex { return String(format: "%02d", i + 1) }
        if scene.graph.junctions.contains(table.name) { return "junction" }
        if isolated { return "isolated" }
        if let h = scene.layout.hops[table.name], h > 0 { return "\(h) hop" }
        return ""
    }

    var body: some View {
        let onPath = pathIndex != nil
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(table.name).ht(.label).lineLimit(1).fixedSize().layoutPriority(1)
                Spacer(minLength: 0)
                Text(tag).ht(.labelSmall).lineLimit(1).opacity(selected ? 0.7 : 1).foregroundStyle(onPath && !selected ? HT.C.accent : selected ? HT.C.paper : HT.C.ink3)
            }
            .foregroundStyle(selected ? HT.C.paper : HT.C.ink)
            .padding(.horizontal, 8).frame(height: MapMetrics.head)
            .background(selected ? HT.C.ink : .clear)
            if !cols.isEmpty { Divider().overlay(selected ? HT.C.ink : HT.C.line) }
            ForEach(cols) { c in column(c) }
            Spacer(minLength: 0)
            if !cols.isEmpty { Divider() }
            HStack(spacing: 6) {
                SegmentedMeter(value: log10(Double(max(table.rowCount, 1))) / 7, segments: 12, accessibilityLabel: "Row count").frame(width: 47, height: 6)
                Spacer(minLength: 0)
                if scene.detail == .keys, table.columns.count > cols.count { Text("+\(table.columns.count - cols.count) cols").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
                Text(HTFormat.compact(table.rowCount)).font(.system(size: 10, design: .monospaced)).foregroundStyle(HT.C.ink2)
            }
            .padding(.horizontal, 8).frame(height: MapMetrics.foot)
        }
        .frame(width: size.width, height: size.height)
        .background(HT.C.paper)
        .clipShape(RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(
            onPath ? HT.C.accent : selected || neighbor ? HT.C.ink : HT.C.ink3,
            style: StrokeStyle(lineWidth: onPath ? 1.5 : 1, dash: isolated ? [3, 2] : [])))
        .background(RoundedRectangle(cornerRadius: HT.M.radius).fill(selected ? HT.C.fill12 : .clear).offset(x: 5, y: 5))
        .opacity(dimmed ? 0.28 : 1)
        .contentShape(Rectangle())
        // one tap recognizer: a second click within 0.3 s is a double-click (focus). Two recognizers would hold every single click until the double-click timeout.
        .onTapGesture { style.interactive?.click(table.name) }
        .gesture(drag)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(table.name), \(table.rowCount.formatted()) rows\(scene.graph.junctions.contains(table.name) ? ", junction table" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .help("\(table.name) · \(table.rowCount.formatted()) rows · \(table.columns.count) columns")
    }

    private func column(_ c: ColumnInfo) -> some View {
        let fk = c.foreignKey != nil, soft = inferredCols.contains(c.name)
        return HStack(spacing: 6) {
            Image(systemName: c.isPrimaryKey ? "key" : "arrow.right").font(.system(size: 8.5, weight: .semibold))
                .opacity(c.isPrimaryKey || fk || soft ? 1 : 0).foregroundStyle(soft && !fk ? HT.C.accent : HT.C.ink).frame(width: 12)
            Group {
                if c.isPrimaryKey { Text(c.name).bold() }
                else if fk || soft { Text(c.name).underline(pattern: .dot, color: soft && !fk ? HT.C.accent : HT.C.ink) }
                else { Text(c.name) }
            }.ht(.dataSmall).foregroundStyle(soft && !fk ? HT.C.accent : HT.C.ink).lineLimit(1)
            Spacer(minLength: 0)
            Text(c.type.lowercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(HT.C.ink3).lineLimit(1)
        }
        .padding(.horizontal, 7).frame(height: MapMetrics.row)
    }

    /// Cards move only in FREE; elsewhere the drag falls through to panning the canvas.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 4).onChanged { g in
            guard let s = style.interactive, s.kind == .free else { return }
            let o = dragStart ?? s.scene.layout.origins[table.name] ?? .zero
            dragStart = o
            s.move(table.name, to: CGPoint(x: o.x + g.translation.width / s.liveZoom, y: o.y + g.translation.height / s.liveZoom))
        }.onEnded { _ in dragStart = nil; style.interactive?.pinAll() }
    }
}
