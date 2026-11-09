import DBCore
import Halftone
import SwiftUI

enum DashFmt {
    static func number(_ v: Double, _ f: DashFormat?) -> String {
        let d = f?.decimals
        let s = f?.compact == true ? v.formatted(.number.notation(.compactName).precision(.fractionLength(0...(d ?? 1))))
                                   : v.formatted(.number.precision(.fractionLength(d ?? (v == v.rounded() ? 0 : 2))).grouping(.automatic))
        switch f?.unit ?? "" {
        case "": return s
        case "B": return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
        case "USD": return "$" + s
        case "EUR": return "€" + s
        case "%", "percent": return s + " %"
        case let u: return s + " " + u
        }
    }
    /// Threshold colour: alert beats warn; no match keeps ink.
    static func tone(_ w: DashWidget, _ v: Double) -> Color? {
        let hit = (w.thresholds ?? []).filter { $0.hit(v) }.map(\.level)
        return hit.contains("alert") ? HT.C.alert : hit.contains("warn") ? HT.C.amber : nil
    }
}

/// A widget in its frame: title, state (loading / empty / error / stale), VIEW AS TABLE, and the chart itself.
struct WidgetCard: View {
    let ws: WorkspaceModel, w: DashWidget
    var lead: AnyView? = nil, trail: AnyView? = nil
    private var m: DashboardModel { ws.dash }
    private var table: Bool { m.asTable.contains(w.id) }
    private var type: DashType? { DashCatalog.type(w.type) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                lead
                Text(DashText.title(w.title)).ht(.labelSmall).lineLimit(1)
                Text("\(w.type)").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                Spacer(minLength: 4)
                if let since = m.inflight[w.id] {
                    // refreshing: the last result stays readable; the header says the query is running and for how long
                    LateReveal { HStack(spacing: 5) { DotSpinner(dot: 3, gap: 1, tint: HT.C.accent); ElapsedText(since: since, tint: HT.C.accent) } }
                        .accessibilityLabel("\(w.title) refreshing")
                }
                trail
                menu
            }
            .padding(.horizontal, 14).frame(height: 32)
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
        }
        .background(HT.C.paper)
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: HT.M.radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(w.title)
    }

    private var menu: some View {
        Menu {
            if type?.hasQuery == true {
                Button(table ? "VIEW AS CHART" : "VIEW AS TABLE") { if table { m.asTable.remove(w.id) } else { m.asTable.insert(w.id) } }
                Button("OPEN AS QUERY") { if let q = w.query { ws.newQuery(sql: DashSQL.bind(q, variables: m.spec?.variables ?? [], values: m.values, engine: ws.profile.engine)) } }
            }
            if m.edit { Button("REMOVE WIDGET", role: .destructive) { m.remove(w.id) } }
        } label: { Text("⋯").ht(.label).foregroundStyle(HT.C.ink3).frame(width: 20, height: 18) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Widget menu")
    }

    @ViewBuilder private var content: some View {
        if type?.hasQuery == false { WidgetBody(ws: ws, w: w, t: WTable(columns: [], rows: [], ms: 0)) }
        else if (w.query ?? "").isEmpty { notice("NO_QUERY", "Open the inspector to add one.") }
        else {
            switch m.data[w.id] {
            case nil, .loading?: WidgetSkeleton(type: w.type, since: m.inflight[w.id] ?? m.refreshStarted ?? Date()).accessibilityLabel("\(w.title), loading")
            case .failed(let msg)?: failure(msg)
            case .ready(let t, let stale)?:
                if t.rows.isEmpty { notice("NO ROWS FOR RANGE", m.values.isEmpty ? "The query returned nothing." : m.values.sorted { $0.key < $1.key }.map { ":\($0.key) = \($0.value)" }.joined(separator: " · ")) }
                else {
                    ZStack(alignment: .bottomTrailing) {
                        if table { TableGrid(t: t, columns: nil) } else { WidgetBody(ws: ws, w: w, t: t).opacity(stale ? 0.55 : 1).accessibilityElement(children: .ignore).accessibilityLabel(Summary.text(w, t)) } // stale: last good result stays, dimmed (Components 04)
                        if stale { Text("STALE · REFRESH FAILED").ht(.labelSmall).foregroundStyle(HT.C.amber).padding(2).background(HT.C.paper) }
                    }
                }
            }
        }
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) { Text(title).ht(.label).foregroundStyle(HT.C.ink3); Text(detail).ht(.bodySmall).foregroundStyle(HT.C.ink3) }
            .accessibilityElement(children: .combine).accessibilityLabel("\(w.title), \(title.lowercased().replacingOccurrences(of: "_", with: " "))")
    }

    private func failure(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(HT.C.alert)
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).ht(.data).foregroundStyle(HT.C.alert).fixedSize(horizontal: false, vertical: true)
                if m.isProposal { Text("VALIDATION FAILED · NOT ADOPTED").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
                else {
                    HStack {
                        Button("ASK AGENT TO FIX") { m.copyFixPrompt(w, error: msg, ws) }.buttonStyle(.htOutline)
                        Button("EDIT SQL") { m.edit = true; m.selected = w.id }.buttonStyle(.htOutline)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine).accessibilityLabel("\(w.title), error: \(msg)")
    }
}

/// Old stored titles used `//` as a separator; show them with the current one.
enum DashText {
    static func title(_ t: String) -> String { t.replacingOccurrences(of: " // ", with: " · ") }
}

/// Loading state (Components 01), shaped like the card it stands in for: a big figure for KPIs, a line for series, bars,
/// or rows for feeds and tables. Silent for 400 ms (Doherty), then the shape plus how long the query has run.
struct WidgetSkeleton: View {
    let type: String
    let since: Date
    var body: some View {
        LateReveal {
            VStack(alignment: .leading, spacing: 8) {
                shape.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                HStack(spacing: 6) { DotSpinner(dot: 3, gap: 1, tint: HT.C.ink3); Text("QUERYING").ht(.labelSmall).foregroundStyle(HT.C.ink3); ElapsedText(since: since) }
            }
        }
    }
    @ViewBuilder private var shape: some View {
        switch type {
        case "kpi", "kpi.spark", "meter", "kpi.target", "gauge":
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBar(fraction: 1, height: 34).frame(width: 170)
                if type != "kpi" { SkeletonBars(count: 20).frame(height: 26).opacity(0.7) }
            }.frame(maxHeight: .infinity, alignment: .top)
        case "line", "area.stacked", "sparkline.grid":
            SkeletonLine()
        case "donut", "waffle":
            HStack(spacing: 12) { Circle().strokeBorder(HT.C.fill12, lineWidth: 12).aspectRatio(1, contentMode: .fit); SkeletonLines(count: 4, keyWidth: 60) }
        case "status.feed", "table", "leaderboard", "stat.list", "progress.list", "status.grid":
            SkeletonLines(count: 6, keyWidth: 70)
        default:
            SkeletonBars(count: 22)
        }
    }
}

/// A gentle wave where a line chart will be.
private struct SkeletonLine: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 0...40 {
                let x = size.width * CGFloat(i) / 40
                let y = size.height * (0.55 - 0.22 * sin(Double(i) / 5) - 0.1 * sin(Double(i) / 2.3))
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(p, with: .color(HT.C.fill30), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 1)); base.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            ctx.stroke(base, with: .color(HT.C.line), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// VoiceOver text for a widget (G15): what it is and what it currently says.
enum Summary {
    static func text(_ w: DashWidget, _ t: WTable) -> String {
        let n = t.rows.count
        switch w.type {
        case "kpi", "kpi.spark", "meter":
            let v = DashData.num(t.rows.first?[t.index(w.enc("value") ?? "value") ?? 0]), s = "\(w.title), \(DashFmt.number(v, w.format))"
            if w.compare == "previous_period", let p = previous(w, t), p != 0 { let d = (v - p) / abs(p) * 100; return s + ", \(d >= 0 ? "up" : "down") \(Int(abs(d).rounded())) %" }
            return s
        case "line", "area.stacked", "bars", "bars.stacked", "halftone.distribution":
            let ys = t.nums(t.index(w.enc("y")))
            return "\(w.title), \(w.type) chart, \(n) points" + (ys.isEmpty ? "" : ", from \(DashFmt.number(ys[0], w.format)) to \(DashFmt.number(ys[ys.count - 1], w.format))")
        case "bars.horizontal", "funnel":
            let l = t.strs(t.index(w.enc("label") ?? w.enc("step"))), v = t.nums(t.index(w.enc("value")))
            return "\(w.title), \(zip(l, v).prefix(5).map { "\($0) \(DashFmt.number($1, w.format))" }.joined(separator: ", "))"
        default: return "\(w.title), \(w.type), \(n) rows"
        }
    }
    /// compare: previous_period reads a `previous` column, or the second row's value.
    static func previous(_ w: DashWidget, _ t: WTable) -> Double? {
        guard w.compare == "previous_period" else { return nil }
        if let p = t.index("previous"), let r = t.rows.first { return DashData.num(r[p]) }
        return t.rows.count > 1 ? DashData.num(t.rows[1][t.index(w.enc("value") ?? "value") ?? 0]) : nil
    }
}

/// Plain grid of a result: VIEW AS TABLE and the `table` type.
struct TableGrid: View {
    let t: WTable, columns: [String]?
    var body: some View {
        let cols = (columns?.compactMap { c in t.index(c) }).flatMap { $0.isEmpty ? nil : $0 } ?? Array(t.columns.indices)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(Array(t.rows.prefix(200).enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 8) { ForEach(cols, id: \.self) { Text(r[$0].display).lineLimit(1).frame(width: 110, alignment: .leading) } }
                            .ht(.dataSmall).frame(height: 20)
                        Rectangle().fill(HT.C.line).frame(height: 1)
                    }
                } header: {
                    HStack(spacing: 8) { ForEach(cols, id: \.self) { Text(t.columns[$0]).lineLimit(1).frame(width: 110, alignment: .leading) } }
                        .ht(.labelSmall).foregroundStyle(HT.C.ink3).frame(height: 20).background(HT.C.paper)
                }
            }
        }
    }
}

/// The 19 catalog types. Instruments from Halftone where one fits; Canvas for the rest.
struct WidgetBody: View {
    let ws: WorkspaceModel, w: DashWidget, t: WTable

    private func col(_ key: String) -> Int? { t.index(w.enc(key)) }
    private var value: Double { DashData.num(t.rows.first?[t.index(w.enc("value") ?? "value") ?? 0]) }
    private func cap(_ s: String, _ color: Color = HT.C.ink3) -> some View { Text(s).ht(.labelSmall).foregroundStyle(color).lineLimit(1) }

    var body: some View {
        switch w.type {
        case "kpi", "kpi.spark": kpi
        case "meter": meter
        case "line": line
        case "area.stacked": Stacked(groups: groups(), area: true)
        case "bars.stacked": Stacked(groups: groups(), area: false)
        case "bars": bars
        case "bars.horizontal": ranked(label: "label", showRank: true)
        case "funnel": ranked(label: "step", showRank: false, relative: true)
        case "histogram": histogram
        case "heatmap.hour_week", "heatmap.calendar": heat
        case "halftone.distribution": distribution
        case "scatter": scatter
        case "table": TableGrid(t: t, columns: w.encoding?["columns"]?.values)
        case "status.feed": feed
        case "radar": radar
        case "text": Text((try? AttributedString(markdown: w.enc("markdown") ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(w.enc("markdown") ?? "")).ht(.body).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case "er.mini": ERMini(ws: ws, table: w.enc("table") ?? "")
        case "kpi.target": KpiTargetCard(d: CardData(w: w, t: t))
        case "gauge": GaugeCard(d: CardData(w: w, t: t))
        case "stat.list": StatListCard(d: CardData(w: w, t: t))
        case "sparkline.grid": SparklineGridCard(d: CardData(w: w, t: t))
        case "leaderboard": LeaderboardCard(d: CardData(w: w, t: t))
        case "donut": DonutCard(d: CardData(w: w, t: t))
        case "waffle": WaffleCard(d: CardData(w: w, t: t))
        case "status.grid": StatusGridCard(d: CardData(w: w, t: t))
        case "progress.list": ProgressListCard(d: CardData(w: w, t: t))
        default: EmptyView()
        }
    }

    // MARK: numbers

    private var kpi: some View {
        let tone = DashFmt.tone(w, value), prev = Summary.previous(w, t)
        return VStack(alignment: .leading, spacing: 4) {
            Text(DashFmt.number(value, w.format)).ht(.readoutL).foregroundStyle(tone ?? HT.C.ink).lineLimit(1).minimumScaleFactor(0.5)
            if let p = prev, p != 0 {
                let d = (value - p) / abs(p) * 100
                cap("\(d >= 0 ? "▲" : "▼") \(Int(abs(d).rounded())) %  VS PREVIOUS · \(DashFmt.number(p, w.format))")
            }
            if w.type == "kpi.spark" {
                Sparkline(values: t.nums(col("y")), style: tone == nil ? .accent : (tone == HT.C.alert ? .solid : .amber), accessibilityLabel: w.title).frame(maxHeight: .infinity)
            } else { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meter: some View {
        let mx = DashData.num(t.rows.first?[col("max") ?? 0]), f = mx > 0 ? value / mx : 0, tone = DashFmt.tone(w, value)
        return VStack(alignment: .leading, spacing: 6) {
            Text(DashFmt.number(value, w.format)).ht(.readoutM).foregroundStyle(tone ?? HT.C.ink)
            SegmentedMeter(value: f, segments: 24, tint: tone == nil ? .solid : (tone == HT.C.alert ? .solid : .amber), accessibilityLabel: w.title, accessibilityValue: "\(DashFmt.number(value, w.format)) of \(DashFmt.number(mx, w.format))")
            cap("OF \(DashFmt.number(mx, w.format)) · \(Int((f * 100).rounded())) %")
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: series

    /// x labels in order of appearance and one value row per series (a `series` column splits rows; several `y` columns are several series).
    private func groups() -> (xs: [String], names: [String], values: [[Double]]) {
        let xi = t.index(w.enc("x")) ?? 0, ys = (w.encoding?["y"]?.values ?? []).compactMap { t.index($0) }
        guard let si = col("series"), let y = ys.first else {
            return (t.strs(xi), ys.map { t.columns[$0] }, ys.map { t.nums($0) })
        }
        var xs: [String] = [], names: [String] = []
        for r in t.rows { let x = r[xi].display, s = r[si].display; if !xs.contains(x) { xs.append(x) }; if !names.contains(s) { names.append(s) } }
        var grid = [[Double]](repeating: [Double](repeating: 0, count: xs.count), count: names.count)
        for r in t.rows { if let a = names.firstIndex(of: r[si].display), let b = xs.firstIndex(of: r[xi].display) { grid[a][b] += DashData.num(r[y]) } }
        return (xs, names, grid)
    }
    static let palette: [LineStyle] = [.accent, .solid, .ink55, .ink30]
    private func styles(_ names: [String]) -> [LineStyle] {
        names.count == 1 ? [.solid] : names.enumerated().map { DefaultDashboard.isAttention($1) ? .amber : Self.palette[min($0, 3)] }
    }

    private var line: some View {
        let g = groups(), st = styles(g.names)
        return VStack(alignment: .leading, spacing: 4) {
            LineChart(series: g.values, styles: st, markers: false, accessibilityLabel: w.title).frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                if g.names.count > 1 { ForEach(Array(g.names.prefix(4).enumerated()), id: \.offset) { i, n in cap(n.uppercased(), st[i].color) } }
                Spacer(minLength: 0)
                if let a = g.xs.first, let b = g.xs.last { cap("\(a) → \(b)") }
            }
        }
    }

    private var bars: some View {
        let ys = t.nums(col("y")), xs = t.strs(col("x"))
        return VStack(alignment: .leading, spacing: 4) {
            BarSpectrum(values: ys, highlight: ys.indices.max { ys[$0] < ys[$1] }, accessibilityLabel: w.title).frame(maxHeight: .infinity)
            HStack { if let a = xs.first { cap(a) }; Spacer(); if let b = xs.last { cap(b) } }
        }
    }

    private func ranked(label key: String, showRank: Bool, relative: Bool = false) -> some View {
        let l = t.strs(col(key)), v = t.nums(col("value")), top = v.first ?? 1, mx = max(v.max() ?? 1, .ulpOfOne)
        return ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(l.enumerated().prefix(20)), id: \.offset) { i, name in
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            if showRank { Text(String(format: "%02d", i + 1)).ht(.dataSmall).foregroundStyle(HT.C.ink3) }
                            Text(name).ht(.dataSmall).lineLimit(1)
                            Spacer()
                            Text(DashFmt.number(v[i], w.format) + (relative && top > 0 ? "  \(Int((v[i] / top * 100).rounded())) %" : "")).ht(.dataSmall).foregroundStyle(HT.C.ink2)
                        }
                        SegmentedMeter(value: relative ? v[i] / max(top, .ulpOfOne) : v[i] / mx, segments: 24, accessibilityLabel: name)
                    }
                }
            }
        }
    }

    // MARK: distributions

    private var histogram: some View {
        let xs = t.nums(col("value")).sorted(), n = Int(w.enc("bins") ?? "") ?? 12
        guard let lo = xs.first, let hi = xs.last else { return AnyView(EmptyView()) }
        var bins = [Double](repeating: 0, count: n)
        for x in xs { bins[min(Int((x - lo) / max(hi - lo, .ulpOfOne) * Double(n)), n - 1)] += 1 }
        let med = xs[xs.count / 2], p95 = xs[min(Int(Double(xs.count) * 0.95), xs.count - 1)]
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            BarSpectrum(values: bins, highlight: bins.indices.max { bins[$0] < bins[$1] }, accessibilityLabel: w.title).frame(maxHeight: .infinity)
            HStack { cap(DashFmt.number(lo, w.format)); Spacer(); cap("MEDIAN \(DashFmt.number(med, w.format)) · P95 \(DashFmt.number(p95, w.format))"); Spacer(); cap(DashFmt.number(hi, w.format)) }
        })
    }

    private var heat: some View {
        let isWeek = w.type == "heatmap.hour_week", ti = t.index(w.enc(isWeek ? "t" : "day")) ?? 0, vi = t.index(w.enc("value")) ?? 0
        let dated = t.rows.compactMap { r in DashData.date(r[ti]).map { ($0, DashData.num(r[vi])) } }
        var sums: [[Double]], peak = "", cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!; cal.firstWeekday = 2
        if isWeek {
            sums = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
            for (d, v) in dated { sums[(cal.component(.weekday, from: d) + 5) % 7][cal.component(.hour, from: d)] += v }
        } else {
            let start = dated.map(\.0).min().map { cal.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0 } ?? Date()
            let weeks = max((dated.map { cal.dateComponents([.weekOfYear], from: start, to: $0.0).weekOfYear ?? 0 }.max() ?? 0) + 1, 1)
            sums = [[Double]](repeating: [Double](repeating: 0, count: weeks), count: 7)
            for (d, v) in dated { sums[(cal.component(.weekday, from: d) + 5) % 7][min(cal.dateComponents([.weekOfYear], from: start, to: d).weekOfYear ?? 0, weeks - 1)] += v }
        }
        let mx = max(sums.flatMap { $0 }.max() ?? 0, .ulpOfOne)
        var hot: (Int, Int)?
        for (r, row) in sums.enumerated() { for (c, v) in row.enumerated() where v == mx && hot == nil { hot = (r, c) } }
        if let (r, c) = hot, isWeek { peak = "PEAK · \(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"][r]) \(String(format: "%02d", c)):00" }
        else if let (r, c) = hot { peak = "PEAK · WEEK \(c + 1) \(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"][r])" }
        let levels = sums.map { $0.map { UInt8($0 <= 0 ? 0 : min(4, max(1, Int(ceil($0 / mx * 4))))) } }
        return VStack(alignment: .leading, spacing: 4) {
            Halftone(levels: levels, highlight: hot, accessibilityLabel: w.title, accessibilityValue: peak).frame(maxHeight: .infinity)
            HStack { cap(isWeek ? "00" : "WEEK 1"); Spacer(); cap(peak, HT.C.accent); Spacer(); cap(isWeek ? "23" : "WEEK \(levels.first?.count ?? 1)") }
        }
    }

    private var distribution: some View {
        let ys = t.nums(col("y")), cols = min(max(ys.count, 1), 48), per = Double(ys.count) / Double(cols)
        let b = (0..<cols).map { c in ys[Int(Double(c) * per)..<max(Int(Double(c + 1) * per), Int(Double(c) * per) + 1)].reduce(0, +) }, mx = max(b.max() ?? 1, .ulpOfOne)
        let levels: [[UInt8]] = (0..<8).map { r in b.map { v in let n = Int((v / mx * 8).rounded()); return (7 - r) < n ? ((7 - r) == n - 1 ? 4 : 2) : 0 } }
        return VStack(alignment: .leading, spacing: 4) {
            Halftone(levels: levels, accessibilityLabel: w.title, accessibilityValue: "\(ys.count) values").frame(maxHeight: .infinity)
            cap("1 DOT ≈ \(DashFmt.number(max(mx / 8, 1), w.format))")
        }
    }

    private var scatter: some View {
        let xs = t.nums(col("x")), ys = t.nums(col("y")), sz = col("size").map { t.nums($0) }
        return Canvas { ctx, size in
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return }
            let s0 = sz?.max() ?? 1
            for i in xs.indices {
                let p = CGPoint(x: 6 + (size.width - 12) * CGFloat((xs[i] - x0) / max(x1 - x0, .ulpOfOne)), y: size.height - 6 - (size.height - 12) * CGFloat((ys[i] - y0) / max(y1 - y0, .ulpOfOne)))
                let r: CGFloat = sz.map { 2 + 4 * CGFloat($0[i] / max(s0, .ulpOfOne)) } ?? 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(ys[i] == y1 ? HT.C.accent : HT.C.ink.opacity(0.7)))
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(w.title), scatter, \(xs.count) points")
    }

    // MARK: records

    private var feed: some View {
        let ts = t.strs(col("ts")), ti = t.strs(col("title")), st = col("status").map { t.strs($0) }, body = col("body").map { t.strs($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ts.enumerated().prefix(30)), id: \.offset) { i, at in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(at).ht(.dataSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ti[i]).ht(.bodySmall).lineLimit(1)
                            if let b = body?[i], !b.isEmpty { Text(b).ht(.bodySmall).foregroundStyle(HT.C.ink3).lineLimit(1) }
                        }
                        Spacer(minLength: 4)
                        if let s = st?[i], !s.isEmpty { Text(s.uppercased()).ht(.labelSmall).foregroundStyle(DefaultDashboard.isAttention(s) ? HT.C.amber : HT.C.ink2) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var radar: some View {
        let axes = t.strs(col("axis")), v = t.nums(col("value")), mx = max(v.max() ?? 1, .ulpOfOne)
        return RadarChart(values: v.map { $0 / mx }, labels: axes, accessibilityLabel: w.title)
    }
}

/// area.stacked and bars.stacked: series stacked per x, at most 4, first one cobalt.
private struct Stacked: View {
    let groups: (xs: [String], names: [String], values: [[Double]]), area: Bool
    var body: some View {
        let n = groups.xs.count, series = Array(groups.values.prefix(4))
        let totals = (0..<n).map { i in series.reduce(0) { $0 + $1[i] } }, mx = max(totals.max() ?? 1, .ulpOfOne)
        let shade: [Color] = [HT.C.accent, HT.C.ink, HT.C.ink.opacity(0.55), HT.C.ink.opacity(0.25)]
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                guard n > 0 else { return }
                var base = [Double](repeating: 0, count: n)
                for (k, s) in series.enumerated() {
                    var path = Path()
                    if area {
                        func x(_ i: Int) -> CGFloat { size.width * CGFloat(i) / CGFloat(max(n - 1, 1)) }
                        func y(_ v: Double) -> CGFloat { size.height - size.height * CGFloat(v / mx) }
                        path.move(to: CGPoint(x: x(0), y: y(base[0] + s[0])))
                        for i in 1..<max(n, 1) { path.addLine(to: CGPoint(x: x(i), y: y(base[i] + s[i]))) }
                        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: CGPoint(x: x(i), y: y(base[i]))) }
                        path.closeSubpath()
                        ctx.fill(path, with: .color(shade[k].opacity(0.35))); ctx.stroke(path, with: .color(shade[k]), lineWidth: 1)
                    } else {
                        let bw = size.width / CGFloat(n)
                        for i in 0..<n {
                            let h = size.height * CGFloat(s[i] / mx), top = size.height - size.height * CGFloat(base[i] / mx) - h
                            path.addRect(CGRect(x: CGFloat(i) * bw + 1, y: top, width: max(bw - 2, 1), height: max(h - 1, 0)))
                        }
                        ctx.fill(path, with: .color(shade[k]))
                    }
                    for i in 0..<n { base[i] += s[i] }
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                ForEach(Array(groups.names.prefix(4).enumerated()), id: \.offset) { i, name in Text(name.uppercased()).ht(.labelSmall).foregroundStyle(shade[i]) }
                Spacer()
                if let a = groups.xs.first, let b = groups.xs.last { Text("\(a) → \(b)").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
            }.lineLimit(1)
        }
    }
}

/// er.mini: the table and its direct foreign-key neighbours (1 hop).
// shortcut: 1 hop only (the catalog's hops: 2 draws the same), upgrade with the schema map's focus layout.
private struct ERMini: View {
    let ws: WorkspaceModel, table: String
    var body: some View {
        let schema = ws.schema, t = schema?.table(table)
        let out = Set(t?.columns.compactMap(\.foreignKey?.table) ?? []), into = Set(schema.flatMap { s in t?.referencedBy(in: s).map(\.table) } ?? [])
        let near = Array(out.union(into).subtracting([table]).sorted().prefix(8))
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), rx = size.width / 2 - 44, ry = size.height / 2 - 14
            func box(_ name: String, _ at: CGPoint, hot: Bool) {
                let r = CGRect(x: at.x - 40, y: at.y - 9, width: 80, height: 18)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(HT.C.paper))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(hot ? HT.C.accent : HT.C.ink), lineWidth: hot ? 1.5 : 1)
                ctx.draw(Text(name).font(HTFont.dataSmall.font).foregroundColor(HT.C.ink), at: at)
            }
            for (i, n) in near.enumerated() {
                let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(max(near.count, 1)), p = CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
                var l = Path(); l.move(to: c); l.addLine(to: p)
                ctx.stroke(l, with: .color(HT.C.ink.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: into.contains(n) && !out.contains(n) ? [3, 3] : []))
                box(n, p, hot: false)
            }
            box(table, c, hot: true)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(table), \(near.count) related tables: \(near.joined(separator: ", "))")
    }
}
