import DBCore
import Halftone
import SwiftUI

/// The window for one connection: TOP STRIP · navigator · NUMBER RAIL · content · STATUS STRIP.
struct WorkspaceWindow: View {
    let profileID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let id = profileID, let ws = app.workspace(for: id) {
                WorkspaceView(ws: ws)
                    .focusedSceneValue(\.workspace, ws)
                    .navigationTitle(ws.profile.name)
                    .task {
                        app.markOpened(id)
                        if ws.session == nil {
                            // Off the main actor: a Keychain access prompt would otherwise freeze the whole UI.
                            let profile = ws.profile
                            let injected = DevHooks.passwords[id]
                            let pw = injected != nil ? injected : await Task.detached { Keychain.password(for: profile) }.value
                            await ws.connect(password: pw)
                        }
                        await DevHooks.connected(ws)
                    }
            } else {
                Text("No connection").ht(.label).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { app.openWindow = { openWindow(value: $0) } }
    }
}

struct WorkspaceView: View {
    @Bindable var ws: WorkspaceModel

    var body: some View {
        VStack(spacing: HT.M.gap) {
            TopStrip(ws: ws)
            HStack(spacing: HT.M.gap) {
                NavigatorView(ws: ws)
                    .frame(width: HT.M.sidebar)
                content
            }
            StatusStrip(ws: ws)
        }
        .padding(HT.M.windowPadding)
        .background(DotGridBackground())
        .overlay { if ws.paletteOpen { PaletteView(ws: ws) } }
        .sheet(isPresented: $ws.reviewOpen) { ReviewSheet(ws: ws) }
    }

    @ViewBuilder private var content: some View {
        switch ws.state {
        case .connecting:
            StateFrame(title: "CONNECTING", tail: ws.profile.name, message: "Opening \(ws.profile.engine.displayName)…", running: true)
        case .failed(let message):
            ConnectFailedView(ws: ws, message: message)
        default:
            switch ws.route {
            case .overview: OverviewView(ws: ws)
            case .schemaMap: SchemaMapView(ws: ws)
            case .table(let name): TableBrowserView(ws: ws, tableName: name)
            case .query(let id):
                if let tab = ws.queryTab(id) { QueryView(ws: ws, tab: tab) } else { OverviewView(ws: ws) }
            }
        }
    }
}

// MARK: - Focused value so Commands can reach the key window's workspace

struct WorkspaceKey: FocusedValueKey { typealias Value = WorkspaceModel }
extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}
