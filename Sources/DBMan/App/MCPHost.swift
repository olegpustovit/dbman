import AppKit
import DBCore
import DBManMCP
import DBStore
import Foundation

/// Hosts the MCP server inside the app: listens on `mcp.sock`, hands agents sessions and routes `ui.open` (SPEC §1.1).
@MainActor final class MCPHost {
    static let shared = MCPHost()
    private var listener: MCPListener?

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
        let l = MCPListener(service: MCPService(backend), path: UnixSocket.path(storeDir: store.url.deletingLastPathComponent().path))
        do { try l.start(); listener = l } catch { NSLog("DBMan MCP: %@", error.localizedDescription) }
    }

    func stop() { listener?.stop() }

    private static func open(_ app: AppModel, _ row: ConnectionRow, _ route: String, _ selection: String?) async {
        guard let id = UUID(uuidString: row.id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<10 where app.openWindow == nil { try? await Task.sleep(for: .milliseconds(200)) } // launched hidden: scenes install openWindow a moment later
        app.openWindow?(id)
        guard let ws = app.workspace(for: id), let selection else { return }
        if route == "table" { ws.go(.table(selection)) } else { ws.newQuery(sql: selection) }
    }
}
