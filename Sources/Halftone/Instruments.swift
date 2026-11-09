import SwiftUI

// Canvas-based charts. Values are Equatable so SwiftUI skips redraws when unchanged;
// marks are accumulated into one Path per colour bucket, then painted once.

public enum LineStyle: Equatable, Hashable { case solid, ink55, ink30, amber, accent
    var color: Color {
        switch self {
        case .solid: HT.C.ink
        case .ink55: HT.C.ink.opacity(0.55)
        case .ink30: HT.C.ink.opacity(0.30)
        case .amber: HT.C.amber
        case .accent: HT.C.accent
        }
    }
}

private extension View {
    func a11y(_ label: String, _ value: String) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
    }
}

// MARK: Line chart

public struct LineChart: View, Equatable {
    let series: [[Double]], styles: [LineStyle], markers: Bool, dashedGrid: Bool, highlightIndex: Int?
    let label: String, value: String
    public init(series: [[Double]], styles: [LineStyle] = [], markers: Bool = true, dashedGrid: Bool = true,
                highlightIndex: Int? = nil, accessibilityLabel: String = "Line chart", accessibilityValue: String = "") {
        self.series = series; self.styles = styles; self.markers = markers; self.dashedGrid = dashedGrid
        self.highlightIndex = highlightIndex; label = accessibilityLabel; value = accessibilityValue
    }
    public var body: some View {
        Canvas { ctx, size in
            let all = series.flatMap { $0 }
            guard let lo = all.min(), let hi = all.max(), size.width > 8, size.height > 8 else { return }
            let span = max(hi - lo, .ulpOfOne), pad: CGFloat = 4
            func pts(_ s: [Double]) -> [CGPoint] {
                s.enumerated().map { i, v in
                    CGPoint(x: pad + (size.width - 2 * pad) * CGFloat(i) / CGFloat(max(s.count - 1, 1)),
                            y: size.height - pad - (size.height - 2 * pad) * CGFloat((v - lo) / span))
                }
            }
            if dashedGrid {
                var g = Path()
                for k in 0...3 { let y = pad + (size.height - 2 * pad) * CGFloat(k) / 3; g.move(to: .init(x: 0, y: y)); g.addLine(to: .init(x: size.width, y: y)) }
                ctx.stroke(g, with: .color(HT.C.line), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            var lines: [LineStyle: Path] = [:], dots: [LineStyle: Path] = [:], hot = Path()
            for (n, s) in series.enumerated() {
                let p = pts(s); guard p.count > 1 else { continue }
                let st = n < styles.count ? styles[n] : .solid
                var path = lines[st] ?? Path()
                path.move(to: p[0])
                for i in 0..<(p.count - 1) { // Catmull-Rom -> cubic Bézier
                    let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
                    path.addCurve(to: p2,
                                  control1: .init(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                                  control2: .init(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
                }
                lines[st] = path
                if markers {
                    var d = dots[st] ?? Path()
                    for q in p { d.addEllipse(in: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)) }
                    dots[st] = d
                }
                if let h = highlightIndex, h >= 0, h < p.count { hot.addEllipse(in: CGRect(x: p[h].x - 3.5, y: p[h].y - 3.5, width: 7, height: 7)) }
            }
            if let h = highlightIndex, let n = series.map(\.count).max(), n > 1 {
                let x = pad + (size.width - 2 * pad) * CGFloat(h) / CGFloat(n - 1)
                var v = Path(); v.move(to: .init(x: x, y: 0)); v.addLine(to: .init(x: x, y: size.height))
                ctx.stroke(v, with: .color(HT.C.accent), lineWidth: 1)
            }
            for (st, p) in lines { ctx.stroke(p, with: .color(st.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)) }
            for (st, p) in dots { ctx.fill(p, with: .color(st.color)) }
            ctx.fill(hot, with: .color(HT.C.accent))
        }
        .a11y(label, value)
    }
}

// MARK: Bars

public struct BarSpectrum: View, Equatable {
    let values: [Double], highlight: Int?, label: String, value: String
    public init(values: [Double], highlight: Int? = nil, accessibilityLabel: String = "Bar chart", accessibilityValue: String = "") {
        self.values = values; self.highlight = highlight; label = accessibilityLabel; value = accessibilityValue
    }
    public var body: some View {
        Canvas { ctx, size in
            guard let hi = values.max(), hi > 0, !values.isEmpty else { return }
            let w = size.width / CGFloat(values.count)
            var ink = Path(), hot = Path()
            for (i, v) in values.enumerated() {
                let h = max(1, size.height * CGFloat(max(v, 0) / hi))
                let r = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 1, 0.5), height: h)
                if i == highlight { hot.addRect(r) } else { ink.addRect(r) }
            }
            ctx.fill(ink, with: .color(HT.C.ink)); ctx.fill(hot, with: .color(HT.C.accent))
        }
        .a11y(label, value)
    }
}

// MARK: Meter

public struct SegmentedMeter: View, Equatable {
    let value: Double, segments: Int, tint: LineStyle, label: String, valueText: String
    public init(value: Double, segments: Int = 20, tint: LineStyle = .solid, accessibilityLabel: String = "Meter", accessibilityValue: String? = nil) {
        self.value = value; self.segments = max(segments, 1); self.tint = tint; label = accessibilityLabel
        valueText = accessibilityValue ?? "\(Int((min(max(value, 0), 1) * 100).rounded())) percent"
    }
    public var body: some View {
        Canvas { ctx, size in
            let n = CGFloat(segments), w = (size.width - (n - 1)) / n
            let on = Int((min(max(value, 0), 1) * Double(segments)).rounded())
            var fill = Path(), empty = Path()
            for i in 0..<segments {
                let r = CGRect(x: CGFloat(i) * (w + 1), y: 0, width: max(w, 0.5), height: size.height)
                if i < on { fill.addRect(r) } else { empty.addRect(r) }
            }
            ctx.fill(empty, with: .color(HT.C.fill12)); ctx.fill(fill, with: .color(tint.color))
        }
        .frame(height: 8)
        .a11y(label, valueText)
    }
}

// MARK: Halftone dots

public struct Halftone: View, Equatable {
    public struct Cell: Equatable { public var row: Int, col: Int; public init(row: Int, col: Int) { self.row = row; self.col = col } }
    let levels: [[UInt8]], highlight: Cell?, label: String, value: String
    public init(levels: [[UInt8]], highlight: (row: Int, col: Int)? = nil, accessibilityLabel: String = "Density map", accessibilityValue: String = "") {
        self.levels = levels; self.highlight = highlight.map { Cell(row: $0.row, col: $0.col) }
        label = accessibilityLabel; value = accessibilityValue
    }
    public var body: some View {
        Canvas { ctx, size in
            let rows = levels.count, cols = levels.map(\.count).max() ?? 0
            guard rows > 0, cols > 0 else { return }
            let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows), m = min(cw, ch)
            var buckets = [Path](repeating: Path(), count: 5), hot = Path()
            for (r, row) in levels.enumerated() {
                for (c, lv) in row.enumerated() where lv > 0 || (r == highlight?.row && c == highlight?.col) {
                    let d = m * (0.18 + 0.20 * CGFloat(min(lv, 4)))
                    let rect = CGRect(x: (CGFloat(c) + 0.5) * cw - d / 2, y: (CGFloat(r) + 0.5) * ch - d / 2, width: d, height: d)
                    if r == highlight?.row && c == highlight?.col { hot.addEllipse(in: rect.insetBy(dx: -1, dy: -1)) }
                    else { buckets[Int(min(lv, 4))].addEllipse(in: rect) }
                }
            }
            for lv in 1...4 { ctx.fill(buckets[lv], with: .color(HT.C.ink.opacity(0.25 + 0.75 * Double(lv) / 4))) }
            ctx.fill(hot, with: .color(HT.C.accent))
        }
        .a11y(label, value)
    }
}

// MARK: Radar

public struct RadarChart: View, Equatable {
    let values: [Double], labels: [String], label: String, value: String
    public init(values: [Double], labels: [String], accessibilityLabel: String = "Radar chart", accessibilityValue: String? = nil) {
        self.values = values; self.labels = labels; label = accessibilityLabel
        value = accessibilityValue ?? zip(labels, values).map { "\($0) \(Int(($1 * 100).rounded()))%" }.joined(separator: ", ")
    }
    public var body: some View {
        Canvas { ctx, size in
            let n = values.count; guard n >= 3 else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 16
            func pt(_ i: Int, _ f: CGFloat) -> CGPoint {
                let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(n)
                return CGPoint(x: c.x + cos(a) * r * f, y: c.y + sin(a) * r * f)
            }
            var grid = Path()
            for ring in [CGFloat(1) / 3, CGFloat(2) / 3, CGFloat(1)] { for i in 0..<n { if i == 0 { grid.move(to: pt(i, ring)) } else { grid.addLine(to: pt(i, ring)) } }; grid.closeSubpath() }
            for i in 0..<n { grid.move(to: c); grid.addLine(to: pt(i, 1)) }
            ctx.stroke(grid, with: .color(HT.C.line), lineWidth: 1)
            var poly = Path()
            for i in 0..<n { let p = pt(i, CGFloat(min(max(values[i], 0), 1))); if i == 0 { poly.move(to: p) } else { poly.addLine(to: p) } }
            poly.closeSubpath()
            ctx.fill(poly, with: .color(HT.C.fill12)); ctx.stroke(poly, with: .color(HT.C.ink), lineWidth: 1.5)
            for (i, t) in labels.prefix(n).enumerated() {
                ctx.draw(Text(t.uppercased()).font(HTFont.labelSmall.font).foregroundColor(HT.C.ink3), at: pt(i, 1.0 + 12 / r))
            }
        }
        .a11y(label, value)
    }
}

// MARK: Sparkline

public struct Sparkline: View, Equatable {
    let values: [Double], style: LineStyle, label: String, value: String
    public init(values: [Double], style: LineStyle = .solid, accessibilityLabel: String = "Trend", accessibilityValue: String = "") {
        self.values = values; self.style = style; label = accessibilityLabel; value = accessibilityValue
    }
    public var body: some View {
        Canvas { ctx, size in
            guard let lo = values.min(), let hi = values.max(), values.count > 1 else { return }
            let span = max(hi - lo, .ulpOfOne)
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: 1 + (size.height - 2) * (1 - CGFloat((v - lo) / span)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(style.color), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
        .frame(height: 16)
        .a11y(label, value)
    }
}

#Preview {
    VStack(spacing: 12) {
        LineChart(series: [[3, 5, 4, 8, 6, 9, 7], [2, 3, 3, 4, 5, 4, 6]], styles: [.solid, .ink30], highlightIndex: 5).frame(height: 100)
        BarSpectrum(values: (0..<40).map { Double(($0 * 7) % 13 + 2) }, highlight: 20).frame(height: 40)
        SegmentedMeter(value: 0.62, tint: .amber)
        Halftone(levels: (0..<8).map { r in (0..<24).map { c in UInt8((r * c) % 5) } }, highlight: (3, 10)).frame(height: 70)
        RadarChart(values: [0.8, 0.5, 0.7, 0.4, 0.9], labels: ["A", "B", "C", "D", "E"]).frame(height: 140)
        Sparkline(values: [1, 3, 2, 5, 4, 6]).frame(width: 80)
    }.padding().frame(width: 320).background(HT.C.paper)
}
