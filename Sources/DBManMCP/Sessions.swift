import DBCore
import DBStore
import Foundation

/// What the MCP server needs from its host. The app wires these to its models; tests wire fakes.
public struct Backend: Sendable {
    public var store: Store
    /// An open session for the connection (shared with the window when safe, else headless). Never writable by agents' statements.
    public var session: @Sendable (ConnectionRow) async throws -> DatabaseSession
    public var isOpen: @Sendable (ConnectionRow) async -> Bool
    /// Brings DBMan to the front at `route` (`table`, `query`) with `selection` (table name, SQL).
    public var openUI: @Sendable (ConnectionRow, String, String?) async -> Void
    public init(store: Store, session: @escaping @Sendable (ConnectionRow) async throws -> DatabaseSession, isOpen: @escaping @Sendable (ConnectionRow) async -> Bool,
                openUI: @escaping @Sendable (ConnectionRow, String, String?) async -> Void) {
        self.store = store; self.session = session; self.isOpen = isOpen; self.openUI = openUI
    }
}

public extension ConnectionRow {
    /// The one row -> profile mapping (the app adds its internal-store tweaks).
    var profile: ConnectionProfile {
        ConnectionProfile(id: UUID(uuidString: id) ?? UUID(), name: name, engine: Engine(rawValue: engine) ?? .sqlite, host: host, port: port, database: database, user: user,
                          filePath: filePath, sslMode: SSLMode(rawValue: sslMode) ?? .prefer, environment: EnvironmentTag(rawValue: env) ?? .local,
                          openReadOnly: readOnly, stageWrites: stageWrites, lastOpened: lastOpened, sslRootCert: sslRootCert,
                          ssh: sshHost.flatMap { $0.isEmpty ? nil : SSHTunnel(host: $0, user: sshUser, port: sshPort, identityFile: sshIdentity) })
    }
    /// Agent sessions always start locked, so `DatabaseSession` refuses writes even before the engine does.
    var agentProfile: ConnectionProfile { var p = profile; p.openReadOnly = true; return p }
}

/// One cached, engine-level read-only session per connection, for when no window has it open. Passwords come from the host (Keychain / dev secrets).
public actor HeadlessSessions {
    private var open: [String: (row: ConnectionRow, session: DatabaseSession)] = [:]
    private let password: @Sendable (ConnectionRow) -> String?
    public init(password: @escaping @Sendable (ConnectionRow) -> String?) { self.password = password }

    public func isOpen(_ c: ConnectionRow) -> Bool { open[c.id].map { $0.row == c && $0.session.isHealthy } ?? false }

    public func session(_ c: ConnectionRow) async throws -> DatabaseSession {
        if let hit = open[c.id], hit.row == c, hit.session.isHealthy { return hit.session }
        if let old = open[c.id] { open[c.id] = nil; await old.session.close() } // the human edited the connection, or its SSH tunnel dropped
        let profile = c.agentProfile
        let s = try await DatabaseSession.connect(profile, password: password(c))
        open[c.id] = (c, s)
        return s
    }
}
