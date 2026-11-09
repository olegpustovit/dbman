import SwiftUI

// Skeletons (Components 01): the shape of what is coming, in fill tones, so the layout does not jump when data lands.
// They breathe slowly (no shimmer sweep: Motion rule 01, no decorative loops) and sit still under Reduce Motion.

/// Slow 0.55 ↔ 1 opacity breath shared by every skeleton piece.
struct SkeletonBreath: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content.opacity(dim ? 0.55 : 1)
            .onAppear { guard !HT.Motion.reduce else { return }; withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true } }
    }
}

/// Stable pseudo-random fraction for (a, b), so skeletons do not reshuffle on redraw.
func skeletonWidth(_ a: Int, _ b: Int, lo: Double = 0.35, hi: Double = 0.9) -> Double {
    var x = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663) &+ 0x9E37_79B9
    x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
    return lo + Double(x % 1000) / 1000 * (hi - lo)
}

/// One grey bar.
public struct SkeletonBar: View {
    let fraction: Double, height: CGFloat
    public init(fraction: Double = 1, height: CGFloat = 8) { self.fraction = fraction; self.height = height }
    public var body: some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 1).fill(HT.C.fill12).frame(width: g.size.width * fraction, height: height)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
    }
}

/// Grid rows in skeleton form: `columns` cells per row, 24 pt rows with hairlines, like DataGrid.
public struct SkeletonRows: View {
    let columns: Int, rows: Int, rowHeight: CGFloat
    public init(columns: Int, rows: Int = 14, rowHeight: CGFloat = HT.M.row) { self.columns = max(1, columns); self.rows = rows; self.rowHeight = rowHeight }
    public var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 14) {
                    ForEach(0..<columns, id: \.self) { c in SkeletonBar(fraction: skeletonWidth(r, c), height: 7) }
                }
                .padding(.horizontal, 10).frame(height: rowHeight)
                .opacity(1 - Double(r) / Double(rows) * 0.6) // fades toward the bottom: "more is coming", not "this is the data"
                .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
        .modifier(SkeletonBreath())
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading rows")
    }
}

/// A histogram-shaped skeleton (BarSpectrum's footprint).
public struct SkeletonBars: View {
    let count: Int
    public init(count: Int = 16) { self.count = count }
    public var body: some View {
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle().fill(HT.C.fill12).frame(height: g.size.height * skeletonWidth(i, 7, lo: 0.2, hi: 1))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .modifier(SkeletonBreath())
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading distribution")
    }
}

/// Key // value lines in skeleton form (inspectors, readouts).
public struct SkeletonLines: View {
    let count: Int, keyWidth: CGFloat
    public init(count: Int = 4, keyWidth: CGFloat = 96) { self.count = count; self.keyWidth = keyWidth }
    public var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 6) {
                    SkeletonBar(fraction: skeletonWidth(i, 3, lo: 0.5, hi: 0.85), height: 7).frame(width: keyWidth)
                    SkeletonBar(fraction: skeletonWidth(i, 11, lo: 0.3, hi: 0.8), height: 7)
                }
                .frame(height: 22)
                .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
        .modifier(SkeletonBreath())
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading")
    }
}

/// Caps label + spinner + elapsed: the header that sits above a skeleton block ("DISTRIBUTION // PROFILING · 1.2 S").
public struct SkeletonHeader: View {
    let title: String, detail: String?, since: Date
    public init(_ title: String, detail: String? = nil, since: Date) { self.title = title; self.detail = detail; self.since = since }
    public var body: some View {
        HStack(spacing: 8) {
            CapsLabel(title, detail).foregroundStyle(HT.C.ink3)
            Spacer(minLength: 6)
            DotSpinner(dot: 3, gap: 1, tint: HT.C.ink3)
            ElapsedText(since: since)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        SkeletonRows(columns: 6, rows: 8)
        SkeletonHeader("Distribution", detail: "profiling", since: .now)
        SkeletonBars().frame(height: 48)
        SkeletonLines()
    }.padding().frame(width: 560).background(HT.C.paper)
}
