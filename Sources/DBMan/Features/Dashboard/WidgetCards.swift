import DBCore
import Halftone
import SwiftUI

// The extended component library (catalog entries in DBCore/Dashboard.swift): typical dashboard cards drawn in the Halftone language.
// Ink and one cobalt signal; amber / alert only when `thresholds` or a status column says so.

/// Shared column access for the cards below.
struct CardData {
    let w: DashWidget, t: WTable
    func col(_ key: String) -> Int? { t.index(w.enc(key)) }
    func strs(_ key: String) -> [String] { col(key).map { t.strs($0) } ?? [] }
    func nums(_ key: String) -> [Double] { col(key).map { t.nums($0) } ?? [] }
    /// First row's value of `key`; kpis fall back to a column named `value`.
    func first(_ key: String) -> Double { DashData.num(t.rows.first?[(col(key) ?? (key == "value" ? t.index("value") : nil)) ?? 0]) }
    func fmt(_ v: Double) -> String { DashFmt.number(v, w.format) }
    /// Ink tones for categories, cobalt first (the biggest / the one that matters).
    static let tones: [Color] = [HT.C.accent, HT.C.ink, HT.C.ink.opacity(0.55), HT.C.ink.opacity(0.32), HT.C.ink.opacity(0.18), HT.C.fill12]
}

private func cap(_ s: String, _ c: Color = HT.C.ink3) -> some View { Text(s).ht(.labelSmall).foregroundStyle(c).lineLimit(1) }
private func delta(_ d: Double) -> some View {
    Text("\(d >= 0 ? "▲" : "▼") \(abs(d) < 10 ? String(format: "%.1f", abs(d)) : String(Int(abs(d).rounded()))) %")
        .ht(.labelSmall).foregroundStyle(d >= 0 ? HT.C.ink2 : HT.C.amber).monospacedDigit()
}

// MARK: numbers

/// kpi.target: value, percent of target, a 24-segment bar and what is left.
struct KpiTargetCard: View {
    let d: CardData
    var body: some View {
        let v = d.first("value"), target = d.first("target"), f = target > 0 ? v / target : 0, tone = DashFmt.tone(d.w, v)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(d.fmt(v)).ht(.readoutL).foregroundStyle(tone ?? HT.C.ink).lineLimit(1).minimumScaleFactor(0.5)
                Text(f >= 10 ? "\(Int(f.rounded()))×" : "\(Int((f * 100).rounded())) %").ht(.readoutS).foregroundStyle(f >= 1 ? HT.C.accent : HT.C.ink3)
            }
            SegmentedMeter(value: min(f, 1), segments: 24, tint: f >= 1 ? .accent : .solid, accessibilityLabel: d.w.title, accessibilityValue: "\(Int((f * 100).rounded())) percent of target")
            cap(f >= 1 ? "TARGET \(d.fmt(target)) · REACHED" : "TARGET \(d.fmt(target)) · \(d.fmt(max(0, target - v))) TO GO")
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// gauge: a 240° dial, threshold-coloured, value in the middle.
struct GaugeCard: View {
    let d: CardData
    var body: some View {
        let v = d.first("value"), mx = d.first("max"), f = mx > 0 ? min(max(v / mx, 0), 1) : 0, tone = DashFmt.tone(d.w, v) ?? HT.C.ink
        GeometryReader { g in
            let side = min(g.size.width, g.size.height * 1.15)
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height * 0.56), r = min(size.width, size.height * 1.15) / 2 - 8
                    let start = Angle.degrees(150), sweep = 240.0
                    var track = Path(); track.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(150 + sweep), clockwise: false)
                    ctx.stroke(track, with: .color(HT.C.fill12), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    var arc = Path(); arc.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(150 + sweep * f), clockwise: false)
                    ctx.stroke(arc, with: .color(tone), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    for k in 0...10 { // ticks every 10 %
                        let a = (150 + sweep * Double(k) / 10) * .pi / 180, r0 = r - 9, r1 = r - (k % 5 == 0 ? 16 : 12)
                        var t = Path(); t.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0)); t.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                        ctx.stroke(t, with: .color(HT.C.ink3), lineWidth: 1)
                    }
                }
                VStack(spacing: 2) {
                    Text(d.fmt(v)).ht(.readoutM).foregroundStyle(tone).lineLimit(1).minimumScaleFactor(0.5)
                    cap("\(Int((f * 100).rounded())) % OF \(d.fmt(mx))")
                }.offset(y: side * 0.06)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(d.w.title).accessibilityValue("\(d.fmt(v)) of \(d.fmt(mx))")
    }
}

/// stat.list: label · value · delta, one row each, hairlines between.
struct StatListCard: View {
    let d: CardData
    var body: some View {
        let l = d.strs("label"), v = d.nums("value"), dl = d.col("delta") != nil ? d.nums("delta") : []
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(l.enumerated().prefix(12)), id: \.offset) { i, name in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).ht(.bodySmall).foregroundStyle(HT.C.ink2).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(i < v.count ? d.fmt(v[i]) : "–").ht(.readoutS).foregroundStyle(i < v.count ? DashFmt.tone(d.w, v[i]) ?? HT.C.ink : HT.C.ink).lineLimit(1).minimumScaleFactor(0.6)
                        if i < dl.count { delta(dl[i]).frame(width: 58, alignment: .trailing) }
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
                }
            }
        }
    }
}

// MARK: time

/// sparkline.grid: one small trend per label, latest value beside it.
struct SparklineGridCard: View {
    let d: CardData
    private var series: [(name: String, ys: [Double])] {
        guard let li = d.col("label"), let yi = d.col("y") else { return [] }
        var order: [String] = [], map: [String: [Double]] = [:]
        for r in d.t.rows { let k = r[li].display; if map[k] == nil { order.append(k) }; map[k, default: []].append(DashData.num(r[yi])) }
        return order.prefix(24).map { ($0, map[$0] ?? []) }
    }
    var body: some View {
        let s = series
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(Array(s.enumerated()), id: \.offset) { i, e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            cap(e.name.uppercased(), HT.C.ink2)
                            Spacer(minLength: 4)
                            Text(e.ys.last.map(d.fmt) ?? "–").ht(.dataSmall).foregroundStyle(HT.C.ink)
                        }
                        Sparkline(values: e.ys, style: i == 0 ? .accent : .solid, accessibilityLabel: e.name, accessibilityValue: e.ys.last.map(d.fmt) ?? "").frame(height: 26)
                    }
                    .padding(6).overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                }
            }
        }
    }
}

// MARK: compare

/// leaderboard: rank · label · value, a share bar of the total, optional ▲/▼ delta.
struct LeaderboardCard: View {
    let d: CardData
    var body: some View {
        let l = d.strs("label"), v = d.nums("value"), dl = d.col("delta") != nil ? d.nums("delta") : [], total = max(v.reduce(0, +), .ulpOfOne)
        let order = v.indices.sorted { v[$0] > v[$1] }
        ScrollView {
            VStack(spacing: 7) {
                ForEach(Array(order.prefix(15).enumerated()), id: \.offset) { rank, i in
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Text(String(format: "%02d", rank + 1)).ht(.dataSmall).foregroundStyle(rank == 0 ? HT.C.accent : HT.C.ink3)
                            Text(i < l.count ? l[i] : "").ht(.dataSmall).lineLimit(1)
                            Spacer(minLength: 4)
                            if i < dl.count { delta(dl[i]) }
                            Text(d.fmt(v[i])).ht(.dataSmall).foregroundStyle(HT.C.ink).frame(minWidth: 50, alignment: .trailing)
                            Text("\(Int((v[i] / total * 100).rounded())) %").ht(.dataSmall).foregroundStyle(HT.C.ink3).frame(width: 38, alignment: .trailing)
                        }
                        SegmentedMeter(value: v[i] / max(v[order[0]], .ulpOfOne), segments: 30, tint: rank == 0 ? .accent : .solid, accessibilityLabel: i < l.count ? l[i] : "")
                    }
                }
            }
        }
    }
}

/// Up to `limit` categories, the rest folded into OTHER.
private func folded(_ d: CardData, limit: Int) -> [(name: String, v: Double)] {
    let l = d.strs("label"), v = d.nums("value")
    let all = zip(l, v).map { ($0, max($1, 0)) }.sorted { $0.1 > $1.1 }
    guard all.count > limit else { return all }
    return Array(all.prefix(limit - 1)) + [("OTHER", all.dropFirst(limit - 1).reduce(0) { $0 + $1.1 })]
}

/// donut: ring segments with hairline gaps, total in the middle, legend beside.
struct DonutCard: View {
    let d: CardData
    var body: some View {
        let parts = folded(d, limit: 6), total = max(parts.reduce(0) { $0 + $1.v }, .ulpOfOne)
        HStack(spacing: 14) {
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 7
                    var a = -90.0
                    for (i, p) in parts.enumerated() {
                        let sweep = p.v / total * 360, gap = parts.count > 1 ? 1.2 : 0
                        var seg = Path(); seg.addArc(center: c, radius: r, startAngle: .degrees(a + gap / 2), endAngle: .degrees(a + max(sweep - gap / 2, gap / 2)), clockwise: false)
                        ctx.stroke(seg, with: .color(CardData.tones[min(i, CardData.tones.count - 1)]), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                        a += sweep
                    }
                }
                VStack(spacing: 0) { Text(d.fmt(total)).ht(.readoutS).lineLimit(1).minimumScaleFactor(0.5); cap("TOTAL") }.padding(18)
            }
            .aspectRatio(1, contentMode: .fit)
            legend(parts, total)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(d.w.title)
        .accessibilityValue(parts.map { "\($0.name) \(Int(($0.v / total * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

private func legend(_ parts: [(name: String, v: Double)], _ total: Double) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
            HStack(spacing: 6) {
                Rectangle().fill(CardData.tones[min(i, CardData.tones.count - 1)]).frame(width: 8, height: 8)
                Text(p.name).ht(.dataSmall).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int((p.v / total * 100).rounded())) %").ht(.dataSmall).foregroundStyle(HT.C.ink3)
            }
        }
    }.frame(maxWidth: .infinity, alignment: .leading)
}

/// waffle: 100 dots, each 1 % of the total, filled in category order (largest first, cobalt).
struct WaffleCard: View {
    let d: CardData
    var body: some View {
        let parts = folded(d, limit: 5), total = max(parts.reduce(0) { $0 + $1.v }, .ulpOfOne)
        // largest-remainder rounding so the dots add up to exactly 100
        let raw = parts.map { $0.v / total * 100 }
        var counts = raw.map { Int($0) }
        for i in raw.indices.sorted(by: { raw[$0] - Double(Int(raw[$0])) > raw[$1] - Double(Int(raw[$1])) }).prefix(max(0, 100 - counts.reduce(0, +))) { counts[i] += 1 }
        let owner: [Int] = counts.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) }
        return HStack(spacing: 14) {
            Canvas { ctx, size in
                let cell = min(size.width, size.height) / 10, dot = cell * 0.72
                for k in 0..<100 {
                    let r = k / 10, c = k % 10
                    let rect = CGRect(x: CGFloat(c) * cell + (cell - dot) / 2, y: CGFloat(r) * cell + (cell - dot) / 2, width: dot, height: dot)
                    let color = k < owner.count ? CardData.tones[min(owner[k], CardData.tones.count - 1)] : HT.C.fill12
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            legend(parts, total)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(d.w.title)
        .accessibilityValue(parts.map { "\($0.name) \(Int(($0.v / total * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

// MARK: status

/// status.grid: health tiles. `status` text (ok / warn / alert / error / fail…) wins; otherwise the widget's thresholds decide.
struct StatusGridCard: View {
    let d: CardData
    private func level(_ i: Int, _ v: Double, _ st: [String]) -> Color {
        if i < st.count, !st[i].isEmpty {
            let s = st[i].lowercased()
            if ["alert", "error", "fail", "failed", "down", "critical", "red"].contains(where: s.contains) { return HT.C.alert }
            if ["warn", "degraded", "slow", "amber", "yellow", "pending"].contains(where: s.contains) { return HT.C.amber }
            return HT.C.ink
        }
        return DashFmt.tone(d.w, v) ?? HT.C.ink
    }
    var body: some View {
        let l = d.strs("label"), v = d.nums("value"), st = d.col("status") != nil ? d.strs("status") : []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                ForEach(Array(l.enumerated().prefix(24)), id: \.offset) { i, name in
                    let val = i < v.count ? v[i] : 0, c = level(i, val, st), bad = c != HT.C.ink
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Rectangle().fill(bad ? c : HT.C.accent).frame(width: 6, height: 6)
                            cap(name.uppercased(), HT.C.ink2)
                        }
                        Text(d.fmt(val)).ht(.readoutS).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.6)
                        cap(i < st.count && !st[i].isEmpty ? st[i].uppercased() : (bad ? "OUT OF RANGE" : "OK"), bad ? c : HT.C.ink3)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(bad ? c : HT.C.line, lineWidth: bad ? 1.5 : 1))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// progress.list: each item against its own max.
struct ProgressListCard: View {
    let d: CardData
    var body: some View {
        let l = d.strs("label"), v = d.nums("value"), mx = d.nums("max")
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(l.enumerated().prefix(20)), id: \.offset) { i, name in
                    let val = i < v.count ? v[i] : 0, m = i < mx.count ? mx[i] : 0, f = m > 0 ? val / m : 0, tone = DashFmt.tone(d.w, f * 100)
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            Text(name).ht(.dataSmall).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(d.fmt(val)) / \(d.fmt(m))").ht(.dataSmall).foregroundStyle(HT.C.ink3)
                            Text("\(Int((f * 100).rounded())) %").ht(.dataSmall).foregroundStyle(f >= 1 ? HT.C.accent : tone ?? HT.C.ink).frame(width: 40, alignment: .trailing)
                        }
                        SegmentedMeter(value: min(f, 1), segments: 30, tint: f >= 1 ? .accent : .solid, accessibilityLabel: name, accessibilityValue: "\(Int((f * 100).rounded())) percent")
                    }
                }
            }
        }
    }
}
