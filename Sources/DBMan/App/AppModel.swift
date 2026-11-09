import AppKit
import DBCore
import DBStore
import Foundation
import Observation
import SwiftUI

/// App-wide state: saved connections and the open workspaces.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    /// All connections from the store, the internal one last.
    private(set) var profiles: [ConnectionProfile] = []
    /// Bumped on every store change (own writes, agents over MCP, sqlite3): views that read layers re-load on it.
    private(set) var storeRev = 0
    /// App-wide settings, backed by the store's `settings` table (Settings window, table pages, dates).
    var pageSize = 500 { didSet { if pageSize != oldValue && !reloading { save("page_size", String(pageSize)) } } }
    var relativeDates = false { didSet { if relativeDates != oldValue && !reloading { save("relative_dates", String(relativeDates)) } } }
    /// PAUSE ALL AGENTS: every MCP call returns APP_LOCKED (the tool service reads the same setting).
    var agentsPaused = false { didSet { if agentsPaused != oldValue && !reloading { save("agents_paused", String(agentsPaused)) } } }
    /// Open workspaces keyed by profile id (one window each).
    var workspaces: [UUID: WorkspaceModel] = [:]
    /// Set by the UI layer so model code can open windows.
    var openWindow: ((UUID) -> Void)?

    let store: Store
    private var reloading = false

    init() {
        let url = Store.defaultURL
        do {
            // v1 data (connections.json, UserDefaults) is imported only into the real store, never into a DBMAN_STORE scratch file.
            store = try Store.open(at: url, v1Dir: url == Store.productionURL ? url.deletingLastPathComponent() : nil,
                                   defaults: url == Store.productionURL ? .standard : nil)
        } catch {
            fatalError("DBMan store unavailable: \(error.localizedDescription)") // shortcut: no degraded mode, upgrade when a "run without store" fallback is wanted
        }
        reload()
        store.onChange = { [weak self] in Task { @MainActor in self?.reload() } } // own writes and external edits (sqlite3 CLI)
        let s = store
        Task.detached { try? s.backupIfNeeded() }
    }

    func reload() {
        reloading = true; defer { reloading = false }
        storeRev += 1
        profiles = ((try? store.connections()) ?? []).map(Self.profile)
        pageSize = store.setting("page_size").flatMap(Int.init) ?? 500
        relativeDates = store.setting("relative_dates") == "true"
        agentsPaused = store.setting("agents_paused") == "true"
        ApprovalCenter.shared.refresh(store)
        AgentsModel.shared.reload(store) // activity, permissions and the roster live in the same file
    }

    private func save(_ key: String, _ json: String) { write { try store.setSetting(key, json: json) } }
    private func write(_ body: () throws -> Void) {
        do { try body() } catch { NSLog("DBMan store: %@", error.localizedDescription) }
        reload()
    }

    func upsert(_ p: ConnectionProfile) { write { try store.upsert(Self.row(p)) } }
    func remove(_ id: UUID) { write { try store.remove(id.uuidString) } }
    func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    private static func profile(_ r: ConnectionRow) -> ConnectionProfile {
        let internalStore = r.id == Store.internalID
        return ConnectionProfile(
            id: internalStore ? ConnectionProfile.internalID : UUID(uuidString: r.id) ?? UUID(), name: r.name, engine: Engine(rawValue: r.engine) ?? .sqlite,
            host: r.host, port: r.port, database: r.database, user: r.user, filePath: r.filePath, sslMode: SSLMode(rawValue: r.sslMode) ?? .prefer,
            environment: EnvironmentTag(rawValue: r.env) ?? .local, openReadOnly: r.readOnly && !internalStore, // internal: locked via .system, unlockable
            stageWrites: r.stageWrites, lastOpened: r.lastOpened, sslRootCert: r.sslRootCert)
    }
    private static func row(_ p: ConnectionProfile) -> ConnectionRow {
        var r = ConnectionRow(id: p.id.uuidString, name: p.name, engine: p.engine.rawValue)
        r.host = p.host; r.port = p.port; r.database = p.database; r.user = p.user; r.sslMode = p.sslMode.rawValue; r.sslRootCert = p.sslRootCert
        r.env = p.environment.rawValue; r.filePath = p.filePath; r.readOnly = p.openReadOnly; r.stageWrites = p.stageWrites; r.lastOpened = p.lastOpened
        return r
    }

    /// Returns (creating if needed) the workspace for a profile.
    func workspace(for id: UUID) -> WorkspaceModel? {
        if let w = workspaces[id] { return w }
        guard let p = profile(id) else { return nil }
        let w = WorkspaceModel(profile: p)
        workspaces[id] = w
        return w
    }

    func markOpened(_ id: UUID) {
        guard var p = profile(id), p.environment != .system else { return }
        p.lastOpened = Date(); upsert(p)
    }

    /// Opens a SQLite file: creates (or reuses) a profile and opens its window.
    func openFile(_ url: URL) {
        let path = url.path
        let p = profiles.first { $0.filePath == path } ?? ConnectionProfile(name: url.lastPathComponent, engine: .sqlite, filePath: path)
        upsert(p)
        openWindow?(p.id)
    }

    /// Creates the bundled sample database on first use and returns its profile id.
    func ensureSampleDatabase() -> UUID? {
        guard let url = try? SampleDatabase.ensure() else { return nil }
        let p = profiles.first { $0.filePath == url.path } ?? ConnectionProfile(name: "sample.sqlite", engine: .sqlite, filePath: url.path)
        upsert(p)
        return p.id
    }
}
