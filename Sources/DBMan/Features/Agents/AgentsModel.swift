import AppKit
import DBManMCP
import DBStore
import Foundation
import Observation

/// State of the Agents window: platform detection, the CONNECT flow, and a cache of what the store holds about agents.
@MainActor @Observable
final class AgentsModel {
    static let shared = AgentsModel()

    enum Section: Hashable { case platform(String), other, agentpack, permissions, activity }
    enum Phase: Equatable { case idle, waiting(Date), timedOut }

    var section: Section = .platform("claude-code")
    var scope: [String: AgentScope] = [:]
    var projectPath = ""
    var phase: [String: Phase] = [:]
    var error: String?
    var scannedAt = Date()
    private(set) var statuses: [String: AgentStatus] = [:]

    // store cache (reload())
    var agents: [AgentRow] = []
    var connections: [ConnectionRow] = []
    var permissions: [String: Permission] = [:] // "agent|connection"
    var activity: [ActivityRow] = []

    let home: URL
    let helper: String

    init() {
        #if DEBUG
        // Screenshots and tests point detection at a fake HOME so real agent configs are never read or written.
        home = ProcessInfo.processInfo.environment["DBMAN_AGENT_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        #else
        home = FileManager.default.homeDirectoryForCurrentUser
        #endif
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dbman-mcp")
        helper = FileManager.default.fileExists(atPath: helperURL.path) ? helperURL.path
            : (Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("dbman-mcp").path ?? helperURL.path) // swift run: the helper sits beside the app binary
        rescan()
    }

    var projectURL: URL? { projectPath.isEmpty ? nil : URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath) }
    func scope(_ p: AgentPlatform) -> AgentScope { p.hasProject ? (scope[p.id] ?? .user) : .user }
    func status(_ p: AgentPlatform) -> AgentStatus { statuses[p.id] ?? .notFound }
    var foundCount: Int { statuses.values.filter { $0 != .notFound }.count }

    func rescan() {
        for p in AgentPlatform.all { statuses[p.id] = AgentConfig.status(p, scope: scope(p), home: home, project: projectURL, helper: helper) }
        scannedAt = Date()
    }

    // MARK: connect flow

    /// The before/after of the native file for CONNECT (or DISCONNECT).
    func plan(_ p: AgentPlatform, remove: Bool = false) -> Result<ConfigChange, ConfigError> {
        do { return .success(try AgentConfig.plan(p, scope: scope(p), home: home, project: projectURL, helper: helper, remove: remove)) }
        catch { return .failure(ConfigError(errorDescription: error.localizedDescription)) }
    }

    func connect(_ p: AgentPlatform) {
        error = nil
        guard case .success(let c) = plan(p) else { if case .failure(let e) = plan(p) { error = e.localizedDescription }; return }
        do { try AgentConfig.apply(c, p, scope: scope(p), home: home, helper: helper) } catch { self.error = error.localizedDescription; return }
        rescan()
        let since = Date()
        phase[p.id] = .waiting(since)
        Task { // VERIFY gives up after 2 minutes
            try? await Task.sleep(for: .seconds(120))
            if phase[p.id] == .waiting(since), handshake(p, since: since) == nil { phase[p.id] = .timedOut }
        }
    }

    func cancel(_ p: AgentPlatform) {
        phase[p.id] = .idle
        if let u = p.url(scope(p), home: home, project: projectURL) { do { try AgentConfig.undo(u) } catch { self.error = error.localizedDescription } }
        rescan()
    }

    func disconnect(_ p: AgentPlatform) {
        error = nil
        do {
            guard case .success(let c) = plan(p, remove: true) else { return }
            try AgentConfig.write(c)
        } catch { self.error = error.localizedDescription }
        phase[p.id] = .idle
        rescan()
    }

    /// The first `initialize` from this platform's client after `since`.
    func handshake(_ p: AgentPlatform, since: Date) -> Handshake? {
        MCPHost.shared.handshakes.first { $0.at >= since && p.matches(client: $0.name) }
    }
    /// A matching client connected right now.
    func live(_ p: AgentPlatform) -> Handshake? { MCPHost.shared.live.last { p.matches(client: $0.name) } }

    // MARK: store

    func reload(_ store: Store) {
        agents = (try? store.agents()) ?? []
        connections = ((try? store.connections()) ?? []).filter { $0.env != "system" } // the internal store never appears (SPEC §6)
        var perms: [String: Permission] = [:]
        for a in agents { for c in connections { perms["\(a.id)|\(c.id)"] = try? store.permission(agent: a.id, connection: c) } }
        permissions = perms
        activity = (try? store.activity(limit: 200)) ?? []
    }

    // MARK: agentpack

    /// `agentpack` from PATH or the usual install dirs.
    static func agentpackCLI(home: URL) -> URL? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".cargo/bin").path]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("agentpack") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Opens Terminal at the project running `agentpack <agent>` (a .command file: no Apple Events permission needed).
    static func launch(agent: String, in project: URL) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("dbman-agentpack-\(agent).command")
        let q = "'" + project.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try? "#!/bin/zsh\ncd \(q) && agentpack \(agent)\n".write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        NSWorkspace.shared.open(f)
    }
}
