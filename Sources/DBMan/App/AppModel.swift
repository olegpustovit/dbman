import AppKit
import DBCore
import Foundation
import Observation
import SwiftUI

/// App-wide state: saved connections and the open workspaces.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var profiles: [ConnectionProfile] = []
    /// Open workspaces keyed by profile id (one window each).
    var workspaces: [UUID: WorkspaceModel] = [:]
    /// Set by the UI layer so model code can open windows.
    var openWindow: ((UUID) -> Void)?

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DBMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    init() { load() }

    func load() {
        if let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            profiles = list
        }
    }
    func save() {
        if let data = try? JSONEncoder().encode(profiles) { try? data.write(to: storeURL, options: .atomic) }
    }

    func upsert(_ p: ConnectionProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        save()
    }
    func remove(_ id: UUID) { profiles.removeAll { $0.id == id }; save() }
    func profile(_ id: UUID) -> ConnectionProfile? { profiles.first { $0.id == id } }

    /// Returns (creating if needed) the workspace for a profile.
    func workspace(for id: UUID) -> WorkspaceModel? {
        if let w = workspaces[id] { return w }
        guard let p = profile(id) else { return nil }
        let w = WorkspaceModel(profile: p)
        workspaces[id] = w
        return w
    }

    func markOpened(_ id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].lastOpened = Date(); save()
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
