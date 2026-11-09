import DBCore
import Halftone
import SwiftUI

/// ROW // <pk> panel: key//value list, related child counts, distribution of the focused column.
struct TableInspector: View {
    let ws: WorkspaceModel
    let info: TableInfo?
    let columns: [String]
    let row: [Cell]?
    @Binding var focused: Int
    let stats: [ColumnStats]
    var statsLoading = false
    var statsStarted = Date()
    let staged: [StagedChange]
    let onFollow: (Int) -> Void

    @State private var children: [(table: String, column: String, count: Int, filter: String)] = []
    @State private var childrenLoading = false
    @State private var childrenStarted = Date()
    @State private var childrenTotal = 0
    @State private var childrenDone = 0

    private var pkLabel: String { info?.primaryKey.joined(separator: ",") ?? "" }
    private func value(_ name: String) -> Cell? { columns.firstIndex(of: name).flatMap { i in row.map { $0[i] } } }
    private var pkValue: String { info?.primaryKey.compactMap { value($0)?.display }.joined(separator: "·") ?? "" }

    var body: some View {
        HTFrame(title: "Row", tail: pkLabel.isEmpty ? nil : pkLabel) {
            if let row {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Readout(value: pkValue.isEmpty ? "—" : pkValue, label: pkLabel.isEmpty ? "no key" : pkLabel, size: .l)
                        fields(row)
                        if childrenLoading { relatedSkeleton } else if !children.isEmpty { related }
                        distribution(row)
                    }.padding(8)
                }
                .task(id: "\(info?.name ?? "")|\(pkValue)|\(columns.count)") { await loadChildren() }
            } else {
                Text("Select a row").ht(.bodySmall).foregroundStyle(HT.C.ink3).padding(8)
            }
        }
    }

    private func fields(_ row: [Cell]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { i, name in
                let c = info?.columns.first { $0.name == name }, v = row[i]
                let isStaged = staged.contains { if case .update(_, let k, name, _, _) = $0 { return k.allSatisfy { value($0.key) == $0.value } } else { return false } }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).ht(.labelSmall).foregroundStyle(i == focused ? HT.C.accent : HT.C.ink3).frame(width: 96, alignment: .leading).lineLimit(1)
                    if v.isNull {
                        Text("null").font(.system(size: 12, design: .serif)).italic().foregroundStyle(HT.C.ink3)
                    } else if c?.foreignKey != nil {
                        Text(v.display).ht(.dataSmall).underline(pattern: .dot, color: HT.C.accent)
                    } else {
                        Text(v.display).ht(.dataSmall).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    if isStaged { Text("staged").ht(.labelSmall).foregroundStyle(HT.C.amber) }
                    if c?.foreignKey != nil, !v.isNull {
                        Button { onFollow(i) } label: { Image(systemName: "arrow.right") }.buttonStyle(.plain)
                            .help("Follow to \(c?.foreignKey?.table ?? "")").accessibilityLabel("Follow foreign key")
                    }
                }
                .padding(.vertical, 3).contentShape(Rectangle()).onTapGesture { focused = i }
                .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
    }

    private var related: some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsLabel("Related", "\(children.count) tables").foregroundStyle(HT.C.ink3)
            Halftone(levels: children.map { c in (0..<8).map { $0 < min(8, 1 + Int(log2(Double(c.count + 1)))) && c.count > 0 ? 3 : 0 } },
                     accessibilityLabel: "Child row counts").frame(height: CGFloat(children.count) * 12)
            ForEach(children, id: \.table) { c in
                Button {
                    ws.pendingFilter[c.table] = c.filter
                    ws.go(.table(c.table))
                } label: {
                    HStack { Text("\(c.table).\(c.column)").ht(.dataSmall); Spacer(); Text(c.count.formatted()).ht(.dataSmall).foregroundStyle(HT.C.accent) }
                }.buttonStyle(.plain)
            }
        }
    }

    /// While child tables are counted: which one we are on, out of how many.
    private var relatedSkeleton: some View {
        LateReveal {
            VStack(alignment: .leading, spacing: 6) {
                SkeletonHeader("Related", detail: childrenTotal > 0 ? "counting \(min(childrenDone + 1, childrenTotal))/\(childrenTotal)" : "counting", since: childrenStarted)
                SkeletonLines(count: max(1, min(childrenTotal, 4)), keyWidth: 150)
            }
        }
    }

    @ViewBuilder private func distribution(_ row: [Cell]) -> some View {
        if statsLoading, columns.indices.contains(focused), !stats.contains(where: { $0.column == columns[focused] }) {
            LateReveal {
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonHeader("Distribution", detail: "profiling \(columns[focused]) · 5,000-row sample", since: statsStarted)
                    SkeletonBars().frame(height: 48)
                    HStack { SkeletonBar(fraction: 0.6, height: 6).frame(width: 50); Spacer(); SkeletonBar(fraction: 0.6, height: 6).frame(width: 70); Spacer(); SkeletonBar(fraction: 0.6, height: 6).frame(width: 50) }
                }
            }
        } else if columns.indices.contains(focused), let s = stats.first(where: { $0.column == columns[focused] }), s.histogram.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel("Distribution", columns[focused]).foregroundStyle(HT.C.ink3)
                BarSpectrum(values: s.histogram, highlight: Self.bin(of: row[focused], in: s), accessibilityLabel: "Distribution of \(columns[focused])").frame(height: 48)
                HStack { Text(s.min ?? "").lineLimit(1); Spacer(); Text("median \(s.median ?? "–")").lineLimit(1); Spacer(); Text(s.max ?? "").lineLimit(1) }
                    .ht(.dataSmall).foregroundStyle(HT.C.ink3)
            }
        }
    }

    /// Which histogram bar holds this value (numeric: by range, categorical: by rank in topValues).
    static func bin(of cell: Cell, in s: ColumnStats) -> Int? {
        if let i = s.topValues.firstIndex(where: { $0.value == cell.display }), !(cell.isNumeric) { return i }
        guard cell.isNumeric, let lo = s.min.flatMap(Double.init), let hi = s.max.flatMap(Double.init) else { return nil }
        let v: Double = { if case .integer(let i) = cell { return Double(i) } else if case .real(let d) = cell { return d } else { return 0 } }()
        return hi == lo ? 0 : max(0, min(s.histogram.count - 1, Int((v - lo) / (hi - lo) * Double(s.histogram.count))))
    }

    private func loadChildren() async {
        children = []
        guard let session = ws.session, let info, let schema = ws.schema, row != nil else { return }
        var out: [(String, String, Int, String)] = []
        let refs = info.referencedBy(in: schema).filter { $0.0 != info.name }
        childrenTotal = refs.count; childrenDone = 0; childrenStarted = Date(); childrenLoading = !refs.isEmpty
        defer { childrenLoading = false }
        for (t, col) in refs {
            if Task.isCancelled { return }
            defer { childrenDone += 1 }
            guard let refCol = schema.table(t)?.columns.first(where: { $0.name == col })?.foreignKey?.column, let v = value(refCol), !v.isNull else { continue }
            let clause = TableSQL.equals(col, v, engine: ws.profile.engine)
            let sql = "SELECT COUNT(*) FROM \(quoteIdent(t, ws.profile.engine)) WHERE \(clause)"
            do {
                let r = try await session.run(sql, limit: 1)
                ws.log(sql, "count")
                if case .integer(let n)? = r.rows.first?.first, n > 0 { out.append((t, col, Int(n), clause)) }
            } catch { ws.log(sql, error.localizedDescription, error: true) }
        }
        children = out
    }
}

/// CONSOLE // n — recent statements, newest first.
struct ConsolePanel: View {
    let ws: WorkspaceModel
    var body: some View {
        HTFrame(title: "Console", tail: "\(ws.console.count)", accessory: { Text("⌘J").ht(.labelSmall).foregroundStyle(HT.C.ink3) }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ws.console) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(e.at.formatted(date: .omitted, time: .standard)).ht(.dataSmall).foregroundStyle(HT.C.ink3)
                            Text(e.sql).ht(.dataSmall).lineLimit(2).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(e.summary).ht(.dataSmall).foregroundStyle(e.isError ? HT.C.alert : HT.C.ink3).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
                    }
                }
            }
        }
    }
}
