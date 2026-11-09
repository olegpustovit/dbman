import Foundation

/// The stages `DatabaseSession.connect` reports while it works (the app adds schema / dashboard stages of its own).
public enum ConnectStage: String, Sendable { case tunnel, handshake }
public enum ConnectEvent: Sendable, Equatable {
    case started(ConnectStage)
    case finished(ConnectStage, String)
}
/// Called from whatever task runs `connect`; hop to your own actor before touching UI state.
public typealias ConnectProgress = @Sendable (ConnectEvent) -> Void
/// A short human line about the schema read in progress ("88 tables · reading columns (2/5)").
public typealias SchemaProgress = @Sendable (String) -> Void

/// One open connection. Owns the driver, the read-only lock and the staged ChangeSet.
public actor DatabaseSession {
    public let profile: ConnectionProfile
    public let driver: any DatabaseDriver
    public private(set) var writesUnlocked: Bool
    public private(set) var changes = ChangeSet()
    /// The SSH child this session owns when the profile has `ssh`; closed with the session.
    public nonisolated let tunnel: SSHTunnelProcess?

    public init(profile: ConnectionProfile, driver: any DatabaseDriver, tunnel: SSHTunnelProcess? = nil) {
        self.profile = profile
        self.driver = driver
        self.tunnel = tunnel
        self.writesUnlocked = !profile.startsReadOnly
    }

    /// False once the session's SSH tunnel has died (callers reopen the session).
    public nonisolated var isHealthy: Bool { tunnel?.isAlive ?? true }

    /// Opens a session for a profile. Password comes from the caller (Keychain lives in the app).
    /// With `profile.ssh`, an SSH tunnel is opened first and the driver talks to its loopback end.
    public static func connect(_ profile: ConnectionProfile, password: String?, progress: ConnectProgress? = nil) async throws -> DatabaseSession {
        var target = profile
        var tunnel: SSHTunnelProcess?
        var serverName: String?
        if let ssh = profile.ssh {
            guard profile.engine != .sqlite else { throw DBError.unsupported("SSH tunnels are for server databases, not SQLite files") }
            progress?(.started(.tunnel))
            let t = try await SSHTunnelProcess.open(ssh, targetHost: profile.host.isEmpty ? "localhost" : profile.host, targetPort: profile.port)
            tunnel = t
            progress?(.finished(.tunnel, "127.0.0.1:\(t.localPort) ⇄ \(profile.host):\(profile.port) via \(ssh.display)"))
            // TLS still checks the database's own name, not the loopback end
            if !profile.host.isEmpty, !["localhost", "127.0.0.1", "::1"].contains(profile.host), profile.host.first?.isLetter == true { serverName = profile.host }
            target.host = "127.0.0.1"; target.port = t.localPort; target.ssh = nil
        }
        let driver: any DatabaseDriver
        progress?(.started(.handshake))
        do {
            switch profile.engine {
            case .sqlite:
                guard let path = profile.filePath else { throw DBError.connection("No SQLite file path") }
                driver = try SQLiteDriver(path: path, readOnly: profile.openReadOnly) // the session lock guards writes; opening the file read-write lets Unlock work
            case .postgres:
                driver = try await PostgresDriver.connect(target, password: password, serverName: serverName)
            case .mysql:
                driver = try await MySQLDriver.connect(target, password: password, serverName: serverName)
            }
        } catch {
            tunnel?.close()
            if let tunnel, case DBError.connection(let m) = error {
                throw DBError.connection("\(m) (through SSH \(tunnel.tunnel.display) to \(profile.host):\(profile.port))")
            }
            throw error
        }
        progress?(.finished(.handshake, profile.engine == .sqlite ? "opened \((profile.filePath ?? "") as NSString).lastPathComponent)" : "authenticated as \(profile.user.isEmpty ? "default user" : profile.user)"))
        let session = DatabaseSession(profile: profile, driver: driver, tunnel: tunnel)
        if profile.startsReadOnly { await session.lockWrites() }
        return session
    }

    // MARK: read
    public func schema() async throws -> SchemaSnapshot { try await driver.schema() }
    /// Same, reporting each part of the catalogue read where the driver can (Postgres); others report once.
    public func schema(progress: SchemaProgress?) async throws -> SchemaSnapshot {
        if let pg = driver as? PGDriver { return try await pg.schema(progress: progress) }
        progress?("reading catalogue")
        return try await driver.schema()
    }

    public func run(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        if !writesUnlocked && SQLClassifier.isWrite(sql) { throw DBError.readOnly }
        return try await driver.execute(sql, limit: limit)
    }

    /// The one path for agent-authored SQL (MCP reads, dashboard widgets, expanded virtual views): a single statement the engine runs read-only.
    public func readOnlyRun(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        let mysql = profile.engine == .mysql
        guard splitStatements(sql, mysql: mysql).count == 1 else { throw DBError.query("one statement per call") }
        let t = sqlTokens(sql, mysql: mysql)
        // MySQL's read-only transaction still allows SELECT … INTO OUTFILE / DUMPFILE / @var
        if mysql, t.indices.dropLast().contains(where: { t[$0].isWord("INTO") && (t[$0 + 1].isWord("OUTFILE") || t[$0 + 1].isWord("DUMPFILE") || t[$0 + 1].text.hasPrefix("@") || t[$0 + 1].isPunct("@")) }) {
            throw DBError.readOnly
        }
        return try await driver.executeReadOnly(sql, limit: limit)
    }

    public nonisolated func stream(_ sql: String, pageSize: Int = 500) -> AsyncThrowingStream<RowPage, Error> {
        // Streaming is for reads only; writes must go through run(), which enforces the read-only lock.
        if SQLClassifier.isWrite(sql) { return AsyncThrowingStream { $0.finish(throwing: DBError.readOnly) } }
        return driver.stream(sql, pageSize: pageSize)
    }

    public func explain(_ sql: String, analyze: Bool = true) async throws -> PlanNode? {
        try await driver.explain(sql, analyze: analyze && !SQLClassifier.isWrite(sql))
    }

    public func cancel() async { await driver.cancelCurrent() }

    // MARK: writes
    public func unlockWrites() async { writesUnlocked = true; await sqliteQueryOnly(false) }
    public func lockWrites() async { writesUnlocked = false; await sqliteQueryOnly(true) }
    /// SQLite files open read-write so Unlock can work; while locked, the engine itself refuses writes
    /// (the SQLClassifier check alone misses e.g. `WITH … DELETE`).
    private func sqliteQueryOnly(_ on: Bool) async {
        if profile.engine == .sqlite { _ = try? await driver.execute("PRAGMA query_only = \(on ? 1 : 0)", limit: 0) }
    }

    public func stage(_ change: StagedChange) { changes.add(change) }
    public func undoLastChange() { changes.undo() }
    public func discardChanges() { changes = ChangeSet() }

    /// Commits staged changes in one transaction. Throws if the session is read-only.
    public func commit() async throws {
        guard writesUnlocked else { throw DBError.readOnly }
        // Grid cells hold only a blob's byte count, so writing one would store NULL: refuse instead of losing data.
        let writesBlob = changes.items.contains { c in
            switch c {
            case .update(_, _, _, _, .blob): return true
            case .insert(_, let v): return v.values.contains { if case .blob = $0 { return true } else { return false } }
            default: return false
            }
        }
        if writesBlob { throw DBError.query("Binary (blob) values can't be written from DBMan yet; leave that column out of the change.") }
        let sql = changes.transactionSQL(engine: profile.engine)
        guard !changes.isEmpty else { return }
        _ = try await driver.execute(sql, limit: 0)
        changes = ChangeSet()
    }

    public func close() async { await driver.close(); tunnel?.close() }
}

/// Very small SQL classifier (first keyword), enough to guard writes.
public enum SQLClassifier {
    public static func firstKeyword(_ sql: String) -> String {
        var s = Substring(sql)
        while true {
            s = s.drop(while: { $0.isWhitespace })
            if s.hasPrefix("--") { s = s.drop(while: { $0 != "\n" }); continue }
            if s.hasPrefix("/*"), let end = s.range(of: "*/") { s = s[end.upperBound...]; continue }
            break
        }
        return String(s.prefix(while: { $0.isLetter })).uppercased()
    }
    public static func isWrite(_ sql: String) -> Bool {
        ["INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE", "TRUNCATE", "REPLACE", "GRANT", "REVOKE", "VACUUM"].contains(firstKeyword(sql))
    }
}
