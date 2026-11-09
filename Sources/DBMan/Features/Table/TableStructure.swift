import DBCore
import Halftone
import SwiftUI

/// 02 STRUCTURE: columns and indexes.
struct StructureView: View {
    let info: TableInfo
    /// Notes agents or the human left in store layers: `table` and `table.column` → text.
    var notes: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let n = notes[info.name] { note(n) }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow { ForEach(["Column", "Type", "Null", "Default", "Constraint"], id: \.self) { CapsLabel($0).foregroundStyle(HT.C.ink3) } }
                    ForEach(info.columns) { c in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            name(c)
                            Text(c.type).ht(.dataSmall)
                            Text(c.nullable ? "yes" : "no").ht(.dataSmall).foregroundStyle(c.nullable ? HT.C.ink3 : HT.C.ink)
                            Text(c.defaultValue ?? "").ht(.dataSmall).foregroundStyle(HT.C.ink2).lineLimit(1)
                            Text(constraint(c)).ht(.dataSmall).foregroundStyle(HT.C.ink2)
                        }.frame(minHeight: HT.M.row)
                        if let n = notes["\(info.name).\(c.name)"] { GridRow { note(n).gridCellColumns(5) } }
                    }
                }
                CapsLabel("Indexes", "\(info.indexes.count)").foregroundStyle(HT.C.ink3)
                if info.indexes.isEmpty { Text("No indexes").ht(.bodySmall).foregroundStyle(HT.C.ink3) }
                ForEach(info.indexes) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(i.name).ht(.strong)
                        Text(i.definition).ht(.dataSmall).foregroundStyle(HT.C.ink2).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Text(i.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "").ht(.dataSmall).foregroundStyle(HT.C.ink3)
                    }
                }
            }.padding(12)
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Note //").ht(.labelSmall).foregroundStyle(HT.C.accent)
            Text(text).ht(.bodySmall).foregroundStyle(HT.C.ink2)
        }.padding(.bottom, 4)
    }

    @ViewBuilder private func name(_ c: ColumnInfo) -> some View {
        if c.isPrimaryKey { Text(c.name).ht(.strong).underline() }
        else if c.foreignKey != nil { Text(c.name).ht(.body).underline(pattern: .dot, color: HT.C.accent) }
        else { Text(c.name).ht(.body) }
    }

    private func constraint(_ c: ColumnInfo) -> String {
        var p: [String] = []
        if c.isPrimaryKey { p.append("PK") }
        if let fk = c.foreignKey { p.append("FK → \(fk.table).\(fk.column)" + (fk.onDelete.map { " ON DELETE \($0)" } ?? "")) }
        if info.indexes.contains(where: { $0.unique && $0.columns == [c.name] }) { p.append("UNIQUE") }
        return p.joined(separator: " · ")
    }
}

/// 03 RELATIONS: the table and its FK neighbours; parents on the left, children on the right.
struct RelationsView: View {
    let ws: WorkspaceModel
    let info: TableInfo

    private let boxW: CGFloat = 190, headH: CGFloat = 24, rowH: CGFloat = 18, maxRows = 10, pad: CGFloat = 24, colGap: CGFloat = 100, vGap: CGFloat = 24

    private func table(_ n: String) -> TableInfo? { ws.schema?.table(n) }
    private var parents: [TableInfo] {
        var seen = Set<String>()
        return info.columns.compactMap { $0.foreignKey?.table }.filter { $0 != info.name && seen.insert($0).inserted }.compactMap(table)
    }
    private var kids: [TableInfo] {
        guard let s = ws.schema else { return [] }
        var seen = Set<String>()
        return info.referencedBy(in: s).map(\.table).filter { $0 != info.name && seen.insert($0).inserted }.compactMap(table)
    }
    private func height(_ t: TableInfo) -> CGFloat { headH + CGFloat(min(t.columns.count, maxRows) + (t.columns.count > maxRows ? 1 : 0)) * rowH }

    /// Top-left origin of every box.
    private var origins: [String: CGPoint] {
        let cols = [parents, [info], kids]
        let colH = colHeights
        let total = colH.max() ?? 0
        var o: [String: CGPoint] = [:]
        for (ci, list) in cols.enumerated() {
            var y = pad + (total - colH[ci]) / 2
            for t in list { o[t.name] = CGPoint(x: pad + CGFloat(ci) * (boxW + colGap), y: y); y += height(t) + vGap }
        }
        return o
    }
    private var colHeights: [CGFloat] {
        [parents, [info], kids].map { list -> CGFloat in
            let sum: CGFloat = list.reduce(0) { $0 + height($1) }
            return sum + CGFloat(max(list.count - 1, 0)) * vGap
        }
    }
    private func rowY(_ t: TableInfo, _ col: String, _ o: CGPoint) -> CGFloat {
        let i = min(t.columns.firstIndex { $0.name == col } ?? 0, maxRows - 1)
        return o.y + headH + (CGFloat(i) + 0.5) * rowH
    }

    var body: some View {
        let o = origins
        let size = CGSize(width: pad * 2 + 3 * boxW + 2 * colGap, height: pad * 2 + (colHeights.max() ?? 0))
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    var path = Path()
                    func edge(_ from: (TableInfo, String), _ to: (TableInfo, String)) {
                        guard let a = o[from.0.name], let b = o[to.0.name] else { return }
                        let x1 = a.x + boxW, x2 = b.x, y1 = rowY(from.0, from.1, a), y2 = rowY(to.0, to.1, b), mx = (x1 + x2) / 2
                        path.move(to: .init(x: x1, y: y1)); path.addLine(to: .init(x: mx, y: y1)); path.addLine(to: .init(x: mx, y: y2)); path.addLine(to: .init(x: x2, y: y2))
                        for (txt, p) in [("1", CGPoint(x: x1 + 8, y: y1 - 8)), ("n", CGPoint(x: x2 - 8, y: y2 - 8))] {
                            ctx.draw(Text(txt).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(HT.C.ink), at: p)
                        }
                    }
                    for p in parents { for c in info.columns where c.foreignKey?.table == p.name { edge((p, c.foreignKey!.column), (info, c.name)) } }
                    for k in kids { for c in k.columns where c.foreignKey?.table == info.name { edge((info, c.foreignKey!.column), (k, c.name)) } }
                    ctx.stroke(path, with: .color(HT.C.ink), lineWidth: 1)
                }
                .frame(width: size.width, height: size.height)
                ForEach(parents + [info] + kids, id: \.name) { t in
                    if let p = o[t.name] { box(t).offset(x: p.x, y: p.y) }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                Text("\(parents.count + kids.count + 1) tables // click a box to open it").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                Button("Open in schema map") { ws.map.selection = info.name; ws.map.focusOn = info.name; ws.go(.schemaMap) }.buttonStyle(.htOutline)
            }.padding(8)
        }
    }

    private func box(_ t: TableInfo) -> some View {
        let isSelf = t.name == info.name
        return Button { ws.go(.table(t.name)) } label: {
            VStack(spacing: 0) {
                Text(t.name).ht(.label).foregroundStyle(isSelf ? HT.C.paper : HT.C.ink).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                    .frame(height: headH).background(isSelf ? HT.C.ink : HT.C.paper)
                ForEach(t.columns.prefix(maxRows)) { c in
                    HStack(spacing: 4) {
                        Text(c.isPrimaryKey ? "PK" : (c.foreignKey != nil ? "FK" : "")).ht(.labelSmall).foregroundStyle(HT.C.ink3).frame(width: 16, alignment: .leading)
                        Text(c.name).ht(.dataSmall).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(c.type.lowercased()).ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                    }.padding(.horizontal, 6).frame(height: rowH)
                }
                if t.columns.count > maxRows { Text("+ \(t.columns.count - maxRows) more").ht(.labelSmall).foregroundStyle(HT.C.ink3).frame(height: rowH) }
            }
            .frame(width: boxW, height: height(t), alignment: .top)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(HT.C.ink, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Table \(t.name), \(t.columns.count) columns")
    }
}

/// 04 STATS: one frame per column.
struct StatsView: View {
    let info: TableInfo?
    let stats: [ColumnStats]

    var body: some View {
        if stats.isEmpty {
            Text("Profiling columns…").ht(.bodySmall).foregroundStyle(HT.C.ink3).padding(12)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: HT.M.gap)], spacing: HT.M.gap) {
                    ForEach(stats, id: \.column) { s in
                        HTFrame(title: s.column, tail: info?.columns.first { $0.name == s.column }?.type) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 16) {
                                    Readout(value: s.distinct.map { $0.formatted() } ?? "–", label: "Distinct", size: .s)
                                    Readout(value: s.median ?? "–", label: "Median", size: .s)
                                    Readout(value: "\(Int((s.nullFraction * 100).rounded()))%", label: "Null", size: .s)
                                }
                                if s.histogram.count > 1 { BarSpectrum(values: s.histogram, accessibilityLabel: "Histogram of \(s.column)").frame(height: 36) }
                                ForEach(s.topValues.prefix(3), id: \.value) { t in
                                    HStack { Text(t.value).ht(.dataSmall).lineLimit(1); Spacer(); Text("\(Int((t.share * 100).rounded()))%").ht(.dataSmall).foregroundStyle(HT.C.ink3) }
                                }
                            }.padding(8)
                        }
                        .frame(height: 210)
                    }
                }.padding(HT.M.gap)
            }
        }
    }
}
