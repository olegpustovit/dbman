import DBCore
import Halftone
import SwiftUI

/// The window for one connection: TOP STRIP · navigator · NUMBER RAIL · content · STATUS STRIP.
struct WorkspaceWindow: View {
    let profileID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var active

    var body: some View {
        Group {
            if let id = profileID, let ws = app.workspace(for: id) {
                WorkspaceView(ws: ws)
                    .windowChrome(ws.profile.name, subtitle: ws.profile.environment.rawValue)
                    .focusedSceneValue(\.workspace, ws)
                    .navigationTitle(ws.profile.name)
                    .onChange(of: active, initial: true) { _, a in if a == .key { app.frontWorkspace = id } }
                    .onDisappear { if app.frontWorkspace == id { app.frontWorkspace = nil } }
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
        VStack(spacing: HT.M.seam) {
            TopStrip(ws: ws)
            if ws.profile.environment == .system, ws.writesUnlocked {
                HStack(spacing: 10) {
                    CapsLabel("Unlocked · internal store").foregroundStyle(HT.C.amber)
                    Text("You are editing DBMan itself: permissions, layers and settings. Edits go through the review sheet and apply live to every window.").ht(.bodySmall).foregroundStyle(HT.C.ink2).lineLimit(1)
                    Spacer()
                    CapsLabel("Agents still see nothing").foregroundStyle(HT.C.ink3)
                    Button("RELOCK") { ws.lockWrites() }.buttonStyle(.htOutline)
                }
                .padding(.horizontal, 10).frame(height: 28).overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.amber, lineWidth: 1))
            }
            HStack(spacing: HT.M.seam) {
                NavigatorView(ws: ws)
                    .frame(width: HT.M.sidebar)
                if ws.layers.compare && ws.layers.open { LayerDiffView(ws: ws) } else { content }
                if ws.layers.open { LayersPanel(ws: ws).frame(width: HT.M.inspector) }
            }
            StatusStrip(ws: ws)
        }
        .padding(HT.M.windowPadding)
        .background(DotGridBackground())
        .overlay { if ws.paletteOpen { PaletteView(ws: ws) } }
        .sheet(isPresented: $ws.reviewOpen) { ReviewSheet(ws: ws) }
        .sheet(item: Binding(get: { ApprovalCenter.shared.sheetTarget == ws.profile.id ? ApprovalCenter.shared.current : nil }, set: { if $0 == nil { ApprovalCenter.shared.current = nil } })) { ApprovalDialog(a: $0) }
        .task(id: AppModel.shared.storeRev) { ws.layers.reload(ws); ws.dash.reload(ws) } // own writes, agents over MCP, sqlite3
        .background(Button("") { ws.layers.open.toggle(); if !ws.layers.open { ws.layers.compare = false } }.keyboardShortcut("l", modifiers: [.option, .command]).opacity(0).accessibilityHidden(true))
    }

    @ViewBuilder private var content: some View {
        switch ws.state {
        case .connecting:
            ConnectingView(ws: ws)
        case .failed(let message):
            ConnectFailedView(ws: ws, message: message)
        default:
            switch ws.route {
            case .overview: DashboardView(ws: ws, id: nil)
            case .dashboard(let id): DashboardView(ws: ws, id: id)
            case .schemaMap: SchemaMapView(ws: ws)
            case .table(let name): TableBrowserView(ws: ws, tableName: name)
            case .query(let id):
                if let tab = ws.queryTab(id) { QueryView(ws: ws, tab: tab) } else { DashboardView(ws: ws, id: nil) }
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
