import AppKit
import DBCore
import Foundation
import Halftone
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

    /// What CONNECTING shows: one step per stage, each with its own timing (States 01 / Motion 05).
    var connectSteps: [HTStep] = []
    var connectStarted = Date()
    /// Bumped by every connect and by cancel, so a late result from an abandoned attempt is closed, not shown.
    @ObservationIgnored private var connectGen = 0

    private func plannedSteps() -> [HTStep] {
        let p = profile
        var out: [HTStep] = []
        if let t = p.ssh { out.append(HTStep(id: ConnectStage.tunnel.rawValue, title: "SSH tunnel", detail: "ssh \(t.display) → forward to \(p.host):\(p.port)")) }
        let target = p.engine == .sqlite ? ((p.filePath ?? "") as NSString).abbreviatingWithTildeInPath
            : "\(p.ssh == nil ? "\(p.host):\(p.port)" : "through tunnel") · \(p.user.isEmpty ? "" : p.user + "@")\(p.database) · TLS \(p.sslMode.rawValue)"
        out.append(HTStep(id: ConnectStage.handshake.rawValue, title: p.engine == .sqlite ? "Open file" : "Connect + authenticate", detail: target))
        out.append(HTStep(id: "schema", title: "Read schema", detail: "tables, columns, keys and indexes"))
        return out
    }

    private func step(_ id: String, _ change: (inout HTStep) -> Void) {
        guard let i = connectSteps.firstIndex(where: { $0.id == id }) else { return }
        change(&connectSteps[i])
    }
    private func begin(_ id: String) { step(id) { if case .pending = $0.state { $0.state = .active(since: Date()) } } }
    private func end(_ id: String, _ detail: String? = nil) {
        step(id) { s in
            guard case .active(let since) = s.state else { return }
            s.state = .done(ms: Int(Date().timeIntervalSince(since) * 1000))
            if let detail { s.detail = detail }
        }
    }
    /// Marks the running step failed (or the first unfinished one) and leaves the rest pending.
    private func failActive(_ note: String) {
        guard let i = connectSteps.firstIndex(where: { $0.state.isActive }) ?? connectSteps.firstIndex(where: { $0.state == .pending }) else { return }
        let since: Date = { if case .active(let d) = connectSteps[i].state { return d } else { return Date() } }()
        connectSteps[i].state = .failed(ms: Int(Date().timeIntervalSince(since) * 1000))
        connectSteps[i].detail = note
    }

    func connect(password: String?) async {
        connectGen += 1
        let gen = connectGen
        state = .connecting
        connectStarted = Date()
        connectSteps = plannedSteps()
        let progress: ConnectProgress = { [weak self] ev in
            Task { @MainActor in
                guard let self, self.connectGen == gen else { return }
                switch ev {
                case .started(let st): self.begin(st.rawValue)
                case .finished(let st, let detail): self.end(st.rawValue, detail)
                }
            }
        }
        do {
            let start = Date()
            let s = try await DatabaseSession.connect(profile, password: password, progress: progress)
            guard gen == connectGen else { await s.close(); return } // cancelled meanwhile
            for st in [ConnectStage.tunnel, .handshake] { begin(st.rawValue); end(st.rawValue) } // progress hops may still be queued; never leave a stage spinning
            if writesUnlocked { await s.unlockWrites() } // unlocked before the session existed (internal store, ⌥-click)
            begin("schema")
            let sc = try await s.schema(progress: { [weak self] line in
                Task { @MainActor in
                    guard let self, self.connectGen == gen else { return }
                    self.step("schema") { if $0.state.isActive { $0.detail = line } }
                }
            })
            guard gen == connectGen else { await s.close(); return }
            let cols = sc.tables.reduce(0) { $0 + $1.columns.count }
            end("schema", "\(sc.tables.count.formatted()) tables · \(cols.formatted()) columns" + (sc.serverVersion.isEmpty ? "" : " · \(sc.serverVersion.prefix(40))"))
            session = s
            schema = sc
            state = .connected(latencyMs: Date().timeIntervalSince(start) * 1000)
            log("connect \(profile.engine.displayName) \(profile.database.isEmpty ? (profile.filePath ?? "") : profile.database)", "ok")
            // the default overview probes the data (time columns, growth): build it after the window is usable, with its own skeleton
            Task { await dash.prepareDefault(self) } // detached: connect() returns as soon as the window is usable
        } catch {
            guard gen == connectGen else { return }
            failActive(error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    /// CANCEL // ⌘. while connecting: the attempt is abandoned (its session, if it still arrives, is closed) and Retry is offered.
    func cancelConnect() {
        guard state == .connecting else { return }
        connectGen += 1
        let where_ = connectSteps.first(where: { $0.state.isActive })?.title.lowercased() ?? "connecting"
        failActive("cancelled by you")
        state = .failed("Cancelled during \(where_)")
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
    /// Navigator ▸ right-click ▸ Delete: the tab, its open tab chip and any history entries pointing at it.
    func deleteQuery(_ id: UUID) {
        let r = Route.query(id)
        queryTabs.removeAll { $0.id == id }
        history.removeAll { $0 == r }; forward.removeAll { $0 == r }
        closeTab(r)
    }
    func duplicateQuery(_ id: UUID) {
        guard let t = queryTab(id) else { return }
        let n = newQuery(sql: t.sql); n.title = t.title + " copy"
    }

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
