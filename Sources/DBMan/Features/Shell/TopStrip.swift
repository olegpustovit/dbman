import DBCore
import Halftone
import SwiftUI

extension WorkspaceModel {
    func title(of r: Route) -> String {
        switch r {
        case .overview: "Overview"
        case .table(let n): n
        case .query(let id): queryTab(id)?.title ?? "Query"
        }
    }
}

/// 30pt strip: section buttons · open tabs · SESSION readout · JUMP_TO.
struct TopStrip: View {
    let ws: WorkspaceModel

    private var currentQuery: QueryTab? { if case .query(let id) = ws.route { ws.queryTab(id) } else { nil } }
    private var isTable: Bool { if case .table = ws.route { true } else { false } }

    var body: some View {
        HStack(spacing: 6) {
            HTNavButton("Overview", systemImage: "square.grid.2x2", isActive: ws.route == .overview) { ws.go(.overview) }
            HTNavButton("Tables", systemImage: "tablecells", isActive: isTable, action: openTables)
            HTNavButton("Query", systemImage: "terminal", isActive: currentQuery != nil && currentQuery?.plan == nil, action: openQuery)
            HTNavButton("Explain", systemImage: "point.3.connected.trianglepath.dotted", isActive: currentQuery?.plan != nil, action: openExplain)
            HTNavButton("Activity", systemImage: "waveform.path.ecg", isActive: false) { ws.go(.overview) }
            Divider().frame(height: 14)
            ScrollView(.horizontal) {
                HStack(spacing: 2) { ForEach(ws.openTabs, id: \.self) { tab($0) } }
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
            readout
            Button { ws.paletteOpen = true } label: {
                HStack(spacing: 5) { Text("Jump_to"); Text("⌘K").foregroundStyle(HT.C.ink3) }
                    .ht(.labelSmall).padding(.horizontal, 8).frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Jump to")
        }
        .padding(.horizontal, 8)
        .frame(height: HT.M.topStrip)
        .background(HT.C.paper, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
    }

    private func tab(_ r: Route) -> some View {
        let on = ws.route == r
        return HStack(spacing: 4) {
            Button { ws.go(r) } label: { Text(ws.title(of: r)).ht(.labelSmall).lineLimit(1) }.buttonStyle(.plain)
            if r != .overview {
                Button { ws.closeTab(r) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("Close \(ws.title(of: r))")
            }
        }
        .foregroundStyle(on ? HT.C.accent : HT.C.ink2)
        .padding(.horizontal, 6).frame(height: 22)
        .overlay(alignment: .bottom) { if on { Rectangle().fill(HT.C.accent).frame(height: 1) } }
    }

    private var readout: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let ver = ws.schema?.serverVersion ?? ""
            var parts = ["SESSION // \(ws.profile.name)"]
            if !ver.isEmpty { parts.append(ver) }
            if case .connected(let ms) = ws.state { parts.append("\(Int(ms.rounded())) MS") }
            parts.append(ctx.date.formatted(date: .omitted, time: .standard))
            return Text(parts.joined(separator: " · ")).ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
        }
    }

    private func openTables() {
        let last = ws.openTabs.last { if case .table = $0 { true } else { false } }
        if let last { return ws.go(last) }
        if let big = ws.schema?.tables.filter({ $0.kind == .table }).max(by: { $0.rowCount < $1.rowCount }) { ws.go(.table(big.name)) }
    }
    private func openQuery() {
        if let t = ws.queryTabs.last { ws.go(.query(t.id)) } else { ws.newQuery() }
    }
    private func openExplain() {
        if let t = currentQuery, t.plan != nil { return }
        if let t = ws.queryTabs.last(where: { $0.plan != nil }) { ws.go(.query(t.id)) } else { openQuery() }
    }
}
