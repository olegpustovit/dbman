import DBCore
import Halftone
import SwiftUI

/// States 03 · CONNECT_FAILED: message, parsed details, password re-entry, Retry / Edit connection.
struct ConnectFailedView: View {
    let ws: WorkspaceModel
    let message: String
    @Environment(\.openWindow) private var openWindow
    @State private var password = ""
    @State private var save = true

    private var details: [(String, String)] {
        let p = ws.profile
        if p.engine == .sqlite { return [("FILE", p.filePath ?? "—")] }
        return [("HOST", p.host), ("PORT", String(p.port)), ("USER", p.user.isEmpty ? "—" : p.user), ("SSL", p.sslMode.rawValue)]
    }

    var body: some View {
        HTFrame(title: "CONNECT_FAILED", tail: ws.profile.name) {
            VStack(alignment: .leading, spacing: 14) {
                Text(message.uppercased()).ht(.label).foregroundStyle(HT.C.alert).textSelection(.enabled)
                HStack(spacing: 18) { ForEach(details, id: \.0) { StatusText(label: $0.0, value: $0.1) } }
                if ws.profile.engine != .sqlite {
                    SecureField("Password", text: $password).textFieldStyle(.plain).ht(.bodySmall)
                        .padding(.horizontal, 6).frame(height: 22).frame(maxWidth: 320)
                        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                        .onSubmit(retry)
                    HTToggleChip("Save to Keychain", isOn: $save).fixedSize()
                }
                HStack(spacing: 8) {
                    Button("Retry // ⏎", action: retry).buttonStyle(.htPrimary).keyboardShortcut(.defaultAction)
                    Button("Edit connection") { openWindow(id: "connections") }.buttonStyle(.htOutline)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func retry() {
        let entered = password.isEmpty ? nil : password
        if let entered, save { Keychain.save(entered, for: ws.profile) }
        Task { await ws.connect(password: entered ?? Keychain.password(for: ws.profile)) }
    }
}
