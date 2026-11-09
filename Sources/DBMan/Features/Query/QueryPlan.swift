import DBCore
import Halftone
import SwiftUI

/// Ink node diagram of an EXPLAIN tree, left → right, with orthogonal connectors. Scrolls both ways.
struct PlanDiagram: View {
    private let layout: PlanLayout
    private let boxW: CGFloat = 220, boxH: CGFloat = 88, gapX: CGFloat = 44, gapY: CGFloat = 14

    init(root: PlanNode) { layout = PlanLayout(root) }

    private func origin(_ i: Int) -> CGPoint {
        let it = layout.items[i]
        return CGPoint(x: 12 + CGFloat(it.depth) * (boxW + gapX), y: 12 + CGFloat(it.row) * (boxH + gapY))
    }

    var body: some View {
        let size = CGSize(width: 24 + CGFloat(layout.depth + 1) * (boxW + gapX) - gapX, height: 24 + CGFloat(layout.rows) * (boxH + gapY) - gapY)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    var p = Path()
                    for e in layout.edges {
                        let a = origin(e.from), b = origin(e.to)
                        let x0 = a.x + boxW, y0 = a.y + boxH / 2, x1 = b.x, y1 = b.y + boxH / 2, mid = x0 + gapX / 2
                        p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: mid, y: y0))
                        p.addLine(to: CGPoint(x: mid, y: y1)); p.addLine(to: CGPoint(x: x1, y: y1))
                    }
                    ctx.stroke(p, with: .color(HT.C.ink.opacity(0.55)), lineWidth: 1)
                }
                .frame(width: size.width, height: size.height)
                ForEach(layout.items.indices, id: \.self) { i in
                    node(layout.items[i], hot: i == layout.hotspot).frame(width: boxW, height: boxH)
                        .offset(x: origin(i).x, y: origin(i).y)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .accessibilityLabel("Query plan, \(layout.items.count) nodes")
    }

    private func node(_ it: PlanLayout.Item, hot: Bool) -> some View {
        let n = it.node
        let fg = hot ? HT.C.paper : HT.C.ink, dim = hot ? HT.C.paper.opacity(0.7) : HT.C.ink3
        let rel = [n.relation, n.detail].compactMap { $0 }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(n.operation).ht(.label).lineLimit(1)
                Spacer(minLength: 0)
                if hot { Text("HOTSPOT · \(Int((it.share * 100).rounded()))%").ht(.labelSmall).foregroundStyle(HT.C.amber) }
            }
            Text(rel.isEmpty ? " " : rel).ht(.dataSmall).foregroundStyle(dim).lineLimit(1)
            Text("EST \(Int(n.estimatedRows))" + (n.actualRows.map { " · ACT \(Int($0))" } ?? "") + (n.selfMs.map { " · \(String(format: "%.1f", $0)) MS" } ?? ""))
                .ht(.labelSmall).foregroundStyle(dim).lineLimit(1)
            Spacer(minLength: 0)
            SegmentedMeter(value: it.share, segments: 20, tint: hot ? .amber : .solid, accessibilityLabel: "Time share")
        }
        .foregroundStyle(fg)
        .padding(8)
        .background(hot ? HT.C.ink : HT.C.paper, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
