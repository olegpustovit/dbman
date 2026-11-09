import AppKit
import DBCore
import DBManMCP
import DBStore
import Foundation
import Observation

/// Hosts the MCP server inside the app: listens on `mcp.sock`, hands agents sessions and routes `ui.open` (SPEC §1.1).
@MainActor @Observable final class MCPHost {
    static let shared = MCPHost()
    @ObservationIgnored private var listener: MCPListener?
    /// MCP clients connected now / every `initialize` since launch (Agents window: "N LIVE", VERIFY).
    private(set) var live: [Handshake] = []
    private(set) var handshakes: [Handshake] = []

    /// Call once after the store is open. A second DBMan on the same store simply doesn't listen.
    func start(_ app: AppModel) {
        let store = app.store
        let headless = HeadlessSessions { Keychain.password(for: $0.agentProfile) }
        let backend = Backend(
            store: store,
            // A window's session is shared only while it is a locked SQLite one (engine-level query_only); servers get their own read-only connection.
            session: { row in
                if row.engine == "sqlite", let id = UUID(uuidString: row.id),
                   let s = await MainActor.run(body: { app.workspaces[id].flatMap { $0.writesUnlocked ? nil : $0.session } }) { return s }
                return try await headless.session(row)
            },
            isOpen: { row in
                if let id = UUID(uuidString: row.id), await MainActor.run(body: { app.workspaces[id]?.session != nil }) { return true }
                return await headless.isOpen(row)
            },
            openUI: { row, route, selection in await MCPHost.open(app, row, route, selection) })
        try? store.pruneActivity()
        try? store.archiveIdleLayers() // SPEC G20: untouched 30 days → archived, never deleted
        let service = MCPService(backend)
        service.live.onChange = { [weak self] in Task { @MainActor in self?.syncLive(service.live) } }
        let l = MCPListener(service: service, path: UnixSocket.path(storeDir: store.url.deletingLastPathComponent().path))
        do { try l.start(); listener = l } catch { NSLog("DBMan MCP: %@", error.localizedDescription) }
    }

    func stop() { listener?.stop() }

    private func syncLive(_ s: LiveSessions) { live = s.clients; handshakes = s.handshakes }

    private static func open(_ app: AppModel, _ row: ConnectionRow, _ route: String, _ selection: String?) async {
        guard let id = UUID(uuidString: row.id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<10 where app.openWindow == nil { try? await Task.sleep(for: .milliseconds(200)) } // launched hidden: scenes install openWindow a moment later
        app.openWindow?(id)
        guard let ws = app.workspace(for: id) else { return }
        switch (route, selection) {
        case ("dashboard", _):
            ws.dash.reload(ws)
            ws.go(ws.dash.entries.first { $0.id == selection || $0.title == selection }.map { .dashboard($0.id) } ?? .overview)
        case ("table", let t?): ws.go(.table(t))
        case (_, let sql?): ws.newQuery(sql: sql)
        default: break
        }
    }
}
