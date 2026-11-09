import AppKit
import DBCore
import Foundation
import Observation
import SwiftUI

/// Where the main area points.
enum Route: Hashable {
    case overview            // the connection's default dashboard
    case dashboard(String)   // any other dashboard, by overlay item id
    case schemaMap
    case table(String)
    case query(UUID)
}

enum ConnectionState: Equatable {
    case connecting
    case connected(latencyMs: Double)
    case failed(String)
    case reconnecting
}

/// A query tab's text and last result.
@MainActor @Observable
final class QueryTab: Identifiable {
    let id = UUID()
    var title: String
    var sql: String
    var savedSQL: String
    var result: QueryResult?
    var error: String?
    var running = false
    var startedAt: Date?
    var plan: PlanNode?
    init(title: String, sql: String) { self.title = title; self.sql = sql; self.savedSQL = sql }
    var isEdited: Bool { sql != savedSQL }
}

/// One entry in the console / history.
struct ConsoleEntry: Identifiable, Hashable {
    let id = UUID()
    let at: Date
    let sql: String
    let summary: String
    let isError: Bool
}

/// Per-window state for one connection.
@MainActor @Observable
final class WorkspaceModel {
    let profile: ConnectionProfile
    var session: DatabaseSession?
    var state: ConnectionState = .connecting
    var schema: SchemaSnapshot?
    let map = SchemaMapState()

    var route: Route = .overview
    var history: [Route] = []
    var forward: [Route] = []
    var openTabs: [Route] = [.overview]
    var queryTabs: [QueryTab] = []

    var showInspector = true
    var showConsole = true
    var paletteOpen = false
    var reviewOpen = false
    var writesUnlocked = false
    var staged = ChangeSet()
    let layers = LayerModel()
    let dash = DashboardModel()
    /// Shown in the review sheet when the staged changes come from a layer (APPLY TO DATABASE).
    var reviewNote: String?
    var console: [ConsoleEntry] = []
    var relativeDates = false
    /// WHERE clause to apply when a table opens (FK follow, child links).
    var pendingFilter: [String: String] = [:]

    init(profile: ConnectionProfile) {
        self.profile = profile
        self.writesUnlocked = !profile.startsReadOnly
    }

    // MARK: connection
    func connect(password: String?) async {
        state = .connecting
        do {
            let start = Date()
            let s = try await DatabaseSession.connect(profile, password: password)
            if writesUnlocked { await s.unlockWrites() } // unlocked before the session existed (internal store, ⌥-click)
            session = s
            schema = try await s.schema()
            await dash.ensureDefault(self) // needs the schema
            state = .connected(latencyMs: Date().timeIntervalSince(start) * 1000)
            log("connect \(profile.engine.displayName) \(profile.database.isEmpty ? (profile.filePath ?? "") : profile.database)", "ok")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Drops the session; the failed-state view offers Retry.
    func disconnect() {
        let s = session
        session = nil; state = .failed("DISCONNECTED")
        Task { await s?.close() }
    }

    func refreshSchema() async {
        guard let session else { return }
        if let s = try? await session.schema() { schema = s }
    }

    // MARK: navigation (⌘[ ⌘])
    func go(_ r: Route) {
        guard r != route else { return }
        history.append(route); forward.removeAll()
        route = r
        if !openTabs.contains(r) { openTabs.append(r) }
    }
    func back() { guard let r = history.popLast() else { return }; forward.append(route); route = r }
    func goForward() { guard let r = forward.popLast() else { return }; history.append(route); route = r }
    func closeTab(_ r: Route) {
        openTabs.removeAll { $0 == r }
        if route == r { route = openTabs.last ?? .overview }
    }

    @discardableResult
    func newQuery(sql: String = "") -> QueryTab {
        let t = QueryTab(title: "Query \(queryTabs.count + 1)", sql: sql)
        queryTabs.append(t)
        go(.query(t.id))
        return t
    }
    func queryTab(_ id: UUID) -> QueryTab? { queryTabs.first { $0.id == id } }

    // MARK: console
    func log(_ sql: String, _ summary: String, error: Bool = false) {
        console.insert(ConsoleEntry(at: Date(), sql: sql, summary: summary, isError: error), at: 0)
        if console.count > 500 { console.removeLast() }
    }

    // MARK: writes
    func stage(_ c: StagedChange) {
        staged.add(c)
        Task { await session?.stage(c) }
    }
    func undoStaged() { staged.undo(); Task { await session?.undoLastChange() } }
    func discardStaged() { staged = ChangeSet(); reviewNote = nil; Task { await session?.discardChanges() } }
    func unlockWrites() {
        // The internal store unlocks only on a deliberate ⌥-click (UNLOCK INTERNAL STORE).
        if profile.environment == .system && !NSEvent.modifierFlags.contains(.option) {
            log("internal store is read-only: ⌥-click UNLOCK INTERNAL STORE to edit", "locked", error: true); return
        }
        writesUnlocked = true; Task { await session?.unlockWrites() }
    }
    func lockWrites() { writesUnlocked = false; Task { await session?.lockWrites() } }
    func commitStaged() async throws {
        guard let session else { return }
        let sql = staged.transactionSQL(engine: profile.engine)
        try await session.commit()
        log(sql, "committed \(staged.count) changes")
        staged = ChangeSet(); reviewNote = nil
        layers.applied()
        await refreshSchema()
    }
}
