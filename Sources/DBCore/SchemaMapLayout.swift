import CoreGraphics
import Foundation

public enum MapDetail: String, CaseIterable, Sendable {
    case names, keys, all
    public var cardWidth: CGFloat { switch self { case .names: 140; case .keys: 176; case .all: 200 } }
}

public enum MapMetrics {
    public static let head: CGFloat = 24, row: CGFloat = 18, foot: CGFloat = 16
    public static let boxHead: CGFloat = 26, boxPad: CGFloat = 12
}

public extension SchemaGraph {
    /// Wide enough for the whole name (11 pt condensed caps ≈ 7.2 pt a glyph) plus a hop / JUNCTION tag: names never truncate.
    func size(_ t: TableInfo, _ detail: MapDetail) -> CGSize {
        let named = (CGFloat(t.name.count) * 7.2 + 16 + 74).rounded(.up)
        return CGSize(width: max(detail.cardWidth, (named / 10).rounded(.up) * 10), height: MapMetrics.head + CGFloat(shownColumns(t, detail).count) * MapMetrics.row + MapMetrics.foot)
    }
    func sizes(_ detail: MapDetail) -> [String: CGSize] { Dictionary(uniqueKeysWithValues: tables.map { ($0.name, size($0, detail)) }) }
}

/// Where every card goes. Origins are top-left; boxes are cluster frames; hops only for FOCUS.
public struct MapLayout: Sendable {
    /// A collapsed box is one small frame (name + table count); its members get no origin.
    public struct Box: Sendable { public var name: String; public var rect: CGRect; public var members: [String]; public var collapsed = false }
    public var origins: [String: CGPoint] = [:]
    public var boxes: [Box] = []
    public var hops: [String: Int] = [:]
    public init() {}

    public func bounds(_ sizes: [String: CGSize]) -> CGRect {
        var r = CGRect.null
        for (n, o) in origins { r = r.union(CGRect(origin: o, size: sizes[n] ?? .zero)) }
        for b in boxes { r = r.union(b.rect) }
        return r.isNull ? .zero : r
    }

    /// Shifts everything so the top-left corner sits at (pad, pad).
    func normalized(_ sizes: [String: CGSize], pad: CGFloat = 20) -> MapLayout {
        let b = bounds(sizes)
        let dx = pad - b.minX, dy = pad - b.minY
        var l = self
        l.origins = origins.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        l.boxes = boxes.map { Box(name: $0.name, rect: $0.rect.offsetBy(dx: dx, dy: dy), members: $0.members, collapsed: $0.collapsed) }
        return l
    }
}

public enum MapLayouts {
    static let gapX: CGFloat = 60, gapY: CGFloat = 24

    // MARK: layered

    /// Parents (referenced tables) left, children right: rank = longest FK chain; barycenter sweeps order each rank.
    public static func layered(_ g: SchemaGraph, _ sizes: [String: CGSize]) -> MapLayout {
        let names = g.tables.map(\.name)
        let real = g.edges.filter { $0.from != $0.to }
        var rank = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        for _ in 0..<min(names.count, 16) { // shortcut: FK cycles stop stretching after 16 ranks, when cyclic schemas matter: break cycles first
            var changed = false
            for e in real where rank[e.from]! < rank[e.to]! + 1 { rank[e.from] = rank[e.to]! + 1; changed = true }
            if !changed { break }
        }
        let linked = Set(real.flatMap { [$0.from, $0.to] })
        if !linked.isEmpty { let last = (rank.values.max() ?? 0) + 1; for n in names where !linked.contains(n) { rank[n] = last } }

        var order: [[String]] = (0...(rank.values.max() ?? 0)).map { r in names.filter { rank[$0] == r }.sorted() }
        let nbrs = Dictionary(uniqueKeysWithValues: names.map { ($0, g.neighbors($0)) })
        func sweep(down: Bool) {
            var pos: [String: Double] = [:]
            func refresh(_ r: Int) { for (i, n) in order[r].enumerated() { pos[n] = (Double(i) + 0.5) / Double(order[r].count) } }
            order.indices.forEach(refresh)
            for r in down ? Array(order.indices.dropFirst()) : Array(order.indices.dropLast().reversed()) {
                let keyed = order[r].map { n -> (String, Double) in
                    let ns = nbrs[n]!.filter { down ? rank[$0]! < r : rank[$0]! > r }
                    return (n, ns.isEmpty ? pos[n]! : ns.map { pos[$0]! }.reduce(0, +) / Double(ns.count))
                }
                order[r] = keyed.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
                refresh(r)
            }
        }
        for _ in 0..<4 { sweep(down: true); sweep(down: false) }

        let heights = order.map { col in col.reduce(CGFloat(0)) { $0 + sizes[$1]!.height } + CGFloat(max(col.count - 1, 0)) * gapY }
        let tallest = heights.max() ?? 0
        var l = MapLayout()
        var x: CGFloat = 0
        for (r, col) in order.enumerated() {
            var y = (tallest - heights[r]) / 2
            for n in col { l.origins[n] = CGPoint(x: x, y: y); y += sizes[n]!.height + gapY }
            x += (col.map { sizes[$0]!.width }.max() ?? 0) + gapX
        }
        return l.normalized(sizes)
    }

    // MARK: clusters

    /// Above this many tables the clusters start collapsed (G17).
    public static let collapseAbove = 200
    static let collapsedSize = CGSize(width: 220, height: 64)

    /// One frame per schema; a single-schema database groups by connected component (isolated tables share one frame).
    /// Past `collapseAbove` tables every cluster not in `expanded` is a small frame with its name and table count.
    public static func clusters(_ g: SchemaGraph, _ sizes: [String: CGSize], expanded: Set<String> = []) -> MapLayout {
        let flow = layered(g, sizes)
        var groups: [(name: String, members: [String])] = []
        if Set(g.tables.map(\.schema)).count > 1 {
            groups = Dictionary(grouping: g.tables.map(\.name)) { g.table($0)!.schema }.map { ($0.key, $0.value) }
        } else {
            var seen = Set<String>(), loners: [String] = []
            for t in g.tables.map(\.name) where !seen.contains(t) {
                var comp = [t], queue = [t]
                seen.insert(t)
                while let n = queue.popLast() { for m in g.neighbors(n) where seen.insert(m).inserted { comp.append(m); queue.append(m) } }
                if comp.count == 1 { loners += comp } else {
                    let hub = comp.sorted().max { g.neighbors($0).count < g.neighbors($1).count }!
                    groups.append((hub, comp))
                }
            }
            if !loners.isEmpty { groups.append(("isolated", loners)) }
        }
        groups.sort { ($1.members.count, $0.name) < ($0.members.count, $1.name) }

        struct Packed { var name: String; var members: [String]; var cells: [String: CGPoint]; var size: CGSize; var collapsed = false }
        let pad = MapMetrics.boxPad
        let packed: [Packed] = groups.map { grp in
            if g.tables.count > collapseAbove, !expanded.contains(grp.name) { return Packed(name: grp.name, members: grp.members.sorted(), cells: [:], size: collapsedSize, collapsed: true) }
            let ms = grp.members.sorted { (flow.origins[$0]!.x, flow.origins[$0]!.y, $0) < (flow.origins[$1]!.x, flow.origins[$1]!.y, $1) }
            let cols = Int(Double(ms.count).squareRoot().rounded(.up))
            var colW = [CGFloat](repeating: 0, count: cols), rowH = [CGFloat](repeating: 0, count: (ms.count + cols - 1) / cols)
            for (i, n) in ms.enumerated() { colW[i % cols] = max(colW[i % cols], sizes[n]!.width); rowH[i / cols] = max(rowH[i / cols], sizes[n]!.height) }
            var cells: [String: CGPoint] = [:]
            for (i, n) in ms.enumerated() {
                cells[n] = CGPoint(x: pad + colW[..<(i % cols)].reduce(0, +) + CGFloat(i % cols) * 32,
                                   y: MapMetrics.boxHead + pad + rowH[..<(i / cols)].reduce(0, +) + CGFloat(i / cols) * 20)
            }
            let w = colW.reduce(0, +) + CGFloat(cols - 1) * 32 + 2 * pad, h = MapMetrics.boxHead + 2 * pad + rowH.reduce(0, +) + CGFloat(rowH.count - 1) * 20
            return Packed(name: grp.name, members: ms, cells: cells, size: CGSize(width: w, height: h))
        }
        let area = packed.reduce(0) { $0 + $1.size.width * $1.size.height }
        let target = max(packed.map(\.size.width).max() ?? 0, area.squareRoot() * 1.3)
        var l = MapLayout()
        var x: CGFloat = 0, y: CGFloat = 0, shelf: CGFloat = 0
        for p in packed {
            if x > 0, x + p.size.width > target { x = 0; y += shelf + 32; shelf = 0 }
            l.boxes.append(.init(name: p.name, rect: CGRect(origin: CGPoint(x: x, y: y), size: p.size), members: p.members, collapsed: p.collapsed))
            for (n, c) in p.cells { l.origins[n] = CGPoint(x: x + c.x, y: y + c.y) }
            x += p.size.width + 32; shelf = max(shelf, p.size.height)
        }
        return l.normalized(sizes)
    }

    // MARK: focus

    /// `center` in the middle, BFS rings for 1…`hops`; only tables in range are placed. Ring radius guarantees no overlap:
    /// every card fits a circle of radius diag/2, and neighbours on a ring or on adjacent rings are ≥ diag + gap apart.
    public static func focus(_ g: SchemaGraph, _ sizes: [String: CGSize], center: String, hops: Int) -> MapLayout {
        guard g.table(center) != nil else { return layered(g, sizes) }
        var hop = [center: 0]
        var queue = [center]
        while !queue.isEmpty {
            let n = queue.removeFirst()
            guard hop[n]! < hops else { continue }
            for m in g.neighbors(n) where hop[m] == nil { hop[m] = hop[n]! + 1; queue.append(m) }
        }
        let diag = hop.keys.map { hypot(sizes[$0]!.width, sizes[$0]!.height) }.max()! + 28
        var l = MapLayout()
        l.hops = hop
        var angle: [String: Double] = [center: 0]
        var radius: CGFloat = 0
        func place(_ n: String, _ a: Double, _ r: CGFloat) {
            let s = sizes[n]!
            l.origins[n] = CGPoint(x: r * CGFloat(cos(a)) - s.width / 2, y: r * CGFloat(sin(a)) - s.height / 2)
        }
        place(center, 0, 0)
        for k in stride(from: 1, through: hops, by: 1) {
            let ring = hop.filter { $0.value == k }.keys.sorted { a, b in // children sit near their parents' angle
                func mean(_ n: String) -> Double {
                    let ps = g.neighbors(n).filter { hop[$0] == k - 1 }.compactMap { angle[$0] }
                    return atan2(ps.map(sin).reduce(0, +), ps.map(cos).reduce(0, +))
                }
                return (mean(a), a) < (mean(b), b)
            }
            guard !ring.isEmpty else { break }
            let need = ring.count > 1 ? diag / (2 * CGFloat(sin(Double.pi / Double(ring.count)))) : 0
            radius = max(radius + diag, need)
            for (i, n) in ring.enumerated() {
                let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(ring.count)
                angle[n] = a; place(n, a, radius)
            }
        }
        return l.normalized(sizes)
    }
}

// MARK: - scene + edge routing

public struct EdgeRoute: Sendable {
    public var p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint
    /// Unit outward normals at each end (the direction the edge leaves its card).
    public var n0: CGVector, n1: CGVector

    public func point(at u: CGFloat) -> CGPoint {
        let v = 1 - u
        return CGPoint(x: v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p1.x,
                       y: v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p1.y)
    }

    /// Crow's-foot cardinality: child end = many (foot + ring: zero-or-many), parent end = one (double bar, or bar + ring when optional).
    public func marks(_ e: MapEdge) -> (lines: [(CGPoint, CGPoint)], rings: [CGPoint]) {
        func at(_ p: CGPoint, _ n: CGVector, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: p.x + n.dx * along - n.dy * across, y: p.y + n.dy * along + n.dx * across)
        }
        func crow(_ p: CGPoint, _ n: CGVector) -> [(CGPoint, CGPoint)] { [(at(p, n, 11, 0), at(p, n, 0, 5.5)), (at(p, n, 11, 0), at(p, n, 0, -5.5))] }
        func bar(_ p: CGPoint, _ n: CGVector, _ s: CGFloat) -> (CGPoint, CGPoint) { (at(p, n, s, 5), at(p, n, s, -5)) }
        var lines = crow(p0, n0), rings = [at(p0, n0, 17, 0)]
        if e.manyToMany { lines += crow(p1, n1); rings.append(at(p1, n1, 17, 0)) }
        else if e.optional { lines.append(bar(p1, n1, 6)); rings.append(at(p1, n1, 13, 0)) }
        else { lines += [bar(p1, n1, 6), bar(p1, n1, 10)] }
        return (lines, rings)
    }
}

/// A graph + where its cards are + which columns they show: everything needed to draw (SwiftUI or SVG).
public struct MapScene: Sendable {
    public let graph: SchemaGraph
    public let detail: MapDetail
    public var layout: MapLayout
    public let sizes: [String: CGSize]

    public init(graph: SchemaGraph, detail: MapDetail, layout: MapLayout) {
        self.graph = graph; self.detail = detail; self.layout = layout; sizes = graph.sizes(detail)
    }

    public func rect(_ t: String) -> CGRect? { layout.origins[t].map { CGRect(origin: $0, size: sizes[t] ?? .zero) } }

    /// y of a column's row inside its card, nil when the column isn't shown.
    public func rowY(_ t: String, _ column: String) -> CGFloat? {
        guard let r = rect(t), let tbl = graph.table(t), let i = graph.shownColumns(tbl, detail).firstIndex(where: { $0.name == column }) else { return nil }
        return r.minY + MapMetrics.head + (CGFloat(i) + 0.5) * MapMetrics.row
    }

    // shortcut: routes ignore cards in the way (no obstacle avoidance), when dense maps look tangled: score candidate sides like the board does
    public func route(_ e: MapEdge) -> EdgeRoute? {
        guard let a = rect(e.from), let b = rect(e.to) else { return nil }
        func clampY(_ y: CGFloat?, _ r: CGRect, _ other: CGRect) -> CGFloat {
            min(max(y ?? (r.midY + (other.midY - r.midY) * 0.12), r.minY + 8), r.maxY - 8)
        }
        if e.from == e.to {
            let y0 = clampY(rowY(e.from, e.fromColumn), a, a), y1 = clampY(rowY(e.to, e.toColumn) ?? a.minY + 12, a, a)
            let p0 = CGPoint(x: a.maxX, y: y0), p1 = CGPoint(x: a.maxX, y: y1)
            return EdgeRoute(p0: p0, c1: CGPoint(x: p0.x + 42, y: p0.y + 6), c2: CGPoint(x: p1.x + 42, y: p1.y - 6), p1: p1, n0: .init(dx: 1, dy: 0), n1: .init(dx: 1, dy: 0))
        }
        let (n0, n1): (CGVector, CGVector)
        let p0: CGPoint, p1: CGPoint
        if a.maxX + 8 <= b.minX || b.maxX + 8 <= a.minX {
            let right = a.maxX + 8 <= b.minX
            n0 = .init(dx: right ? 1 : -1, dy: 0); n1 = .init(dx: right ? -1 : 1, dy: 0)
            p0 = CGPoint(x: right ? a.maxX : a.minX, y: clampY(rowY(e.from, e.fromColumn), a, b))
            p1 = CGPoint(x: right ? b.minX : b.maxX, y: clampY(rowY(e.to, e.toColumn), b, a))
        } else {
            let down = a.maxY <= b.minY
            n0 = .init(dx: 0, dy: down ? 1 : -1); n1 = .init(dx: 0, dy: down ? -1 : 1)
            p0 = CGPoint(x: min(max(a.midX + (b.midX - a.midX) * 0.3, a.minX + 16), a.maxX - 16), y: down ? a.maxY : a.minY)
            p1 = CGPoint(x: min(max(b.midX + (a.midX - b.midX) * 0.3, b.minX + 16), b.maxX - 16), y: down ? b.minY : b.maxY)
        }
        let k = min(max(hypot(p1.x - p0.x, p1.y - p0.y) * 0.42, 24), 150)
        return EdgeRoute(p0: p0, c1: CGPoint(x: p0.x + n0.dx * k, y: p0.y + n0.dy * k), c2: CGPoint(x: p1.x + n1.dx * k, y: p1.y + n1.dy * k), p1: p1, n0: n0, n1: n1)
    }
}
