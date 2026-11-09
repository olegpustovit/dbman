import DBCore
import Halftone
import SwiftUI

/// 20pt caps status line: connection, write state, staged count (click → review), engine + latency.
struct StatusStrip: View {
    let ws: WorkspaceModel

    var body: some View {
        HStack(spacing: 14) {
            if let s = ws.schema { StatusText(label: "Tables", value: "\(s.tables.count)") }
            switch ws.state {
            case .connecting: StatusText(label: "Conn", value: "connecting")
            case .reconnecting: StatusText(label: "Conn", value: "reconnecting", tone: .amber)
            case .failed: StatusText(label: "Conn", value: "failed", tone: .alert)
            case .connected: StatusText(label: "Conn", value: ws.profile.name)
            }
            if ws.writesUnlocked { StatusText(label: "Mode", value: "writes unlocked", tone: .amber) }
            else { StatusText(label: "Mode", value: "read-only") }
            if !ws.staged.isEmpty {
                Button { ws.reviewOpen = true } label: { StatusText(label: "Staged", value: "\(ws.staged.count)", tone: .amber) }
                    .buttonStyle(.plain).help("Review changes")
            }
            Spacer(minLength: 0)
            StatusText(label: ws.profile.engine.displayName, value: latency)
        }
        .padding(.horizontal, 8)
        .frame(height: HT.M.statusStrip)
    }

    private var latency: String {
        if case .connected(let ms) = ws.state { return "\(Int(ms.rounded())) ms" }
        return "—"
    }
}
