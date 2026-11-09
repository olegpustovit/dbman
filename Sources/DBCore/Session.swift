import Foundation

/// One open connection. Owns the driver, the read-only lock and the staged ChangeSet.
public actor DatabaseSession {
    public let profile: ConnectionProfile
    public let driver: any DatabaseDriver
    public private(set) var writesUnlocked: Bool
    public private(set) var changes = ChangeSet()

    public init(profile: ConnectionProfile, driver: any DatabaseDriver) {
        self.profile = profile
        self.driver = driver
        self.writesUnlocked = !profile.startsReadOnly
    }

    /// Opens a session for a profile. Password comes from the caller (Keychain lives in the app).
    public static func connect(_ profile: ConnectionProfile, password: String?) async throws -> DatabaseSession {
        let driver: any DatabaseDriver
        switch profile.engine {
        case .sqlite:
            guard let path = profile.filePath else { throw DBError.connection("No SQLite file path") }
            driver = try SQLiteDriver(path: path, readOnly: profile.openReadOnly) // the session lock guards writes; opening the file read-write lets Unlock work
        case .postgres:
            driver = try await PostgresDriver.connect(profile, password: password)
        case .mysql:
            driver = try await MySQLDriver.connect(profile, password: password)
        }
        let session = DatabaseSession(profile: profile, driver: driver)
        if profile.startsReadOnly { await session.lockWrites() }
        return session
    }

    // MARK: read
    public func schema() async throws -> SchemaSnapshot { try await driver.schema() }

    public func run(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        if !writesUnlocked && SQLClassifier.isWrite(sql) { throw DBError.readOnly }
        return try await driver.execute(sql, limit: limit)
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

    public func close() async { await driver.close() }
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
