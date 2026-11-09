import DBCore
import Halftone
import SwiftUI

/// 02 · Connections: saved profiles grouped by environment, the editor for the selected one.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("relativeDates") private var relativeDates = false
    @State private var selectedID: UUID?
    @State private var isNew = false
    @State private var newCount = 0          // bumps on every "+" so the editor resets
    @State private var deleteTarget: ConnectionProfile?

    private static let sqliteExts = ["sqlite", "sqlite3", "db", "db3"]
    private static let groups: [EnvironmentTag] = [.production, .staging, .local]

    private var selected: ConnectionProfile? { isNew ? nil : selectedID.flatMap { app.profile($0) } }
    private var editorKey: String { isNew ? "new-\(newCount)" : (selectedID?.uuidString ?? "none") }

    var body: some View {
        HStack(spacing: HT.M.gap) {
            HTFrame(title: "SAVED", tail: String(format: "%02d", app.profiles.count)) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Self.groups, id: \.self) { env in
                                let items = app.profiles.filter { $0.environment == env }
                                HStack(spacing: 6) {
                                    Text(env.rawValue.uppercased()).ht(.label).foregroundStyle(env == .production ? HT.C.amber : HT.C.ink)
                                    Text("// \(String(format: "%02d", items.count))").ht(.label).foregroundStyle(HT.C.ink3)
                                    Rectangle().fill(HT.C.line).frame(height: 1)
                                }
                                .padding(.top, 6)
                                ForEach(items) { row($0) }
                            }
                        }
                        .padding(8)
                    }
                    footer
                }
            }
            .frame(width: 260)

            ConnectionEditor(profile: selected) { id in
                selectedID = id
                isNew = false
            }
            .id(editorKey)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(HT.M.windowPadding)
        .background(DotGridBackground())
        .task { if DevHooks.openSettings { try? await Task.sleep(for: .milliseconds(500)); openSettings() } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { Self.sqliteExts.contains($0.pathExtension.lowercased()) }
            files.forEach { app.openFile($0) }
            return !files.isEmpty
        }
        .confirmationDialog(
            "Remove connection?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { p in
            Button("Remove \(p.name)", role: .destructive) { remove(p) }
        } message: { p in
            Text("Deletes the saved settings and the Keychain password for \(p.name). The database itself is not touched.")
        }
        .onAppear {
            // Model code (openFile) opens windows through this closure; the Connections window must set it too.
            app.openWindow = { openWindow(value: $0) }
            if selectedID == nil { selectedID = app.profiles.first?.id }
        }
    }

    private func row(_ p: ConnectionProfile) -> some View {
        let on = selected?.id == p.id
        return Button {
            selectedID = p.id
            isNew = false
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(p.name).ht(.strong)
                    Spacer(minLength: 4)
                    Text(stamp(p)).ht(.labelSmall)
                        .foregroundStyle(on ? HT.C.paper : (p.environment == .production ? HT.C.amber : HT.C.ink3))
                }
                Text(detail(p)).ht(.dataSmall).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(on ? HT.C.paper.opacity(0.7) : HT.C.ink3)
            }
            .foregroundStyle(on ? HT.C.paper : HT.C.ink)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("+") {
                newCount += 1
                isNew = true
            }
            .buttonStyle(.htOutline)
            .accessibilityLabel("New connection")
            Button("−") {
                if let p = selected { deleteTarget = p } else {
                    // Discarding an unsaved draft.
                    isNew = false
                    selectedID = app.profiles.first?.id
                }
            }
            .buttonStyle(.htOutline)
            .disabled(selected == nil && !isNew)
            .accessibilityLabel("Remove connection")
            Spacer(minLength: 4)
            Button("Try sample database") {
                if let id = app.ensureSampleDatabase() { openWindow(value: id) }
            }
            .buttonStyle(.htOutline)
        }
        .padding(8)
        .overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
    }

    private func remove(_ p: ConnectionProfile) {
        Keychain.delete(for: p)
        app.remove(p.id)
        isNew = false
        selectedID = app.profiles.first?.id
    }

    private func detail(_ p: ConnectionProfile) -> String {
        p.engine == .sqlite
            ? "\(p.filePath ?? "") · SQLite"
            : "\(p.user)@\(p.host):\(p.port) · \(p.engine.displayName)"
    }

    private func stamp(_ p: ConnectionProfile) -> String {
        guard let d = p.lastOpened else { return "NEVER" }
        return relativeDates
            ? d.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)).uppercased()
            : d.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }
}
