import Foundation
import SQLite3

public struct ConnectionRow: Equatable, Sendable {
    public var id: String
    public var name: String
    public var engine: String          // postgres | mysql | sqlite
    public var host = ""
    public var port = 0
    public var database = ""
    public var user = ""
    public var sslMode = "prefer"
    public var sslRootCert: String?
    public var env = "local"           // local | staging | production | system
    public var filePath: String?
    public var readOnly = false
    public var stageWrites = true
    public var lastOpened: Date?
    /// SSH hop (nil host = direct). DBMan runs the system ssh, so the host may be a ~/.ssh/config alias.
    public var sshHost: String?
    public var sshUser: String?
    public var sshPort: Int?
    public var sshIdentity: String?
    /// Where the password lives (Keychain item / dev secrets file, both keyed by id). Never the password itself.
    public var secretRef: String? { engine == "sqlite" ? nil : "keychain:" + id }
    public init(id: String, name: String, engine: String) { self.id = id; self.name = name; self.engine = engine }
}

/// DBMan's own SQLite file: settings, connections, layers… (SPEC §6). Synchronous; safe to call from any thread.
public final class Store: @unchecked Sendable {
    public static let internalID = "internal"
    public static let internalName = "DBMan // internal"
    public static let applicationID: Int32 = 0x44424D4E
    /// Called (on the main queue, coalesced) after any change to the file: our own writes or an external sqlite3.
    public var onChange: (@Sendable () -> Void)?
    public let url: URL

    let h: Handle
    let lock = NSLock()
    private let pendingLock = NSLock() // separate: the update hook fires while `lock` is held
    private var pending = false
    private var watchers: [DispatchSourceFileSystemObject] = []

    private static let migrations: [String] = [PackageResources._001_init_sql, PackageResources._002_approvals_sql, PackageResources._003_ssh_sql].map { String(decoding: $0, as: UTF8.self) } // shortcut: migrations are listed by hand (embedInCode mangles the file name), upgrade: generate the list once there are many

    public static let productionURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DBMan/dbman.sqlite")
    /// `DBMAN_STORE` (DEBUG only) or `productionURL`.
    public static var defaultURL: URL {
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["DBMAN_STORE"] { return URL(fileURLWithPath: p) }
        #endif
        return productionURL
    }

    // MARK: bootstrap

    /// open/create → quick_check → migrate → import v1 → seed. `v1Dir`/`defaults` are where v1 data lives (nil: skip).
    public static func open(at url: URL, v1Dir: URL? = nil, defaults: UserDefaults? = nil) throws -> Store {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let h: Handle
        do { h = try openChecked(url) } catch let e as StoreError where !e.message.hasPrefix("Store schema") {
            quarantine(url)
            h = try openChecked(url)
        }
        try migrate(h)
        let s = Store(h, url)
        try s.importV1(dir: v1Dir, defaults: defaults)
        try s.seed()
        s.watch()
        return s
    }

    private static func openChecked(_ url: URL) throws -> Handle {
        let h = try Handle(path: url.path)
        try h.exec("PRAGMA foreign_keys = ON")
        _ = try h.query("PRAGMA journal_mode = WAL")
        try h.exec("PRAGMA synchronous = NORMAL")
        guard try h.scalar("PRAGMA quick_check") as? String == "ok" else { throw StoreError(message: "quick_check failed") }
        let appID = try h.scalar("PRAGMA application_id") as? Int64 ?? 0
        guard appID == 0 || appID == Int64(applicationID) else { throw StoreError(message: "not a DBMan store") }
        return h
    }

    /// Moves a corrupt file (and its WAL/SHM) aside so nothing is lost, then the caller recreates.
    private static func quarantine(_ url: URL) {
        let fm = FileManager.default
        let dest = url.deletingLastPathComponent().appendingPathComponent("dbman.corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
        try? fm.moveItem(at: url, to: dest)
        for ext in ["-wal", "-shm"] { try? fm.moveItem(atPath: url.path + ext, toPath: dest.path + ext) }
    }

    private static func migrate(_ h: Handle) throws {
        let have = Int(try h.scalar("PRAGMA user_version") as? Int64 ?? 0)
        guard have <= migrations.count else { throw StoreError(message: "Store schema v\(have) is newer than this DBMan (v\(migrations.count)). Update DBMan.") }
        for (i, sql) in migrations.enumerated() where i >= have {
            try h.transaction {
                try h.exec(sql)
                try h.exec("PRAGMA user_version = \(i + 1)")
            }
        }
    }

    private init(_ h: Handle, _ url: URL) {
        self.h = h; self.url = url
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_update_hook(h.db, { ctx, _, _, _, _ in Unmanaged<Store>.fromOpaque(ctx!).takeUnretainedValue().notify() }, ctx)
    }

    deinit { watchers.forEach { $0.cancel() } }

    // MARK: v1 import

    private struct V1Connection: Decodable {
        var id: UUID, name: String, engine: String
        var host: String?, port: Int?, database: String?, user: String?, filePath: String?
        var sslMode: String?, sslRootCert: String?, environment: String?
        var openReadOnly: Bool?, stageWrites: Bool?, lastOpened: Date?
    }

    /// Once per store: connections.json (renamed to .v1-backup afterwards) and the `pageSize`/`relativeDates` UserDefaults keys.
    private func importV1(dir: URL?, defaults: UserDefaults?) throws {
        guard try meta("migrated_from") == nil else { return }
        let json = dir?.appendingPathComponent("connections.json")
        let list = json.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([V1Connection].self, from: $0) } ?? []
        try transaction {
            for v in list {
                var c = ConnectionRow(id: v.id.uuidString, name: v.name, engine: v.engine)
                c.host = v.host ?? ""; c.port = v.port ?? 0; c.database = v.database ?? ""; c.user = v.user ?? ""
                c.sslMode = v.sslMode ?? "prefer"; c.sslRootCert = v.sslRootCert; c.env = v.environment ?? "local"
                c.filePath = v.filePath; c.readOnly = v.openReadOnly ?? false; c.stageWrites = v.stageWrites ?? true; c.lastOpened = v.lastOpened
                try? upsertLocked(c) // a row violating a CHECK is skipped, not fatal
            }
            if let n = defaults?.object(forKey: "pageSize") as? Int { try setSettingLocked("page_size", json: String(n)) }
            if let b = defaults?.object(forKey: "relativeDates") as? Bool { try setSettingLocked("relative_dates", json: String(b)) }
            try h.query("INSERT INTO meta(key, value) VALUES ('migrated_from', ?)", [list.isEmpty && json == nil ? "none" : "v1"])
        }
        if let json, !list.isEmpty { try? FileManager.default.moveItem(at: json, to: json.appendingPathExtension("v1-backup")) }
    }

    // MARK: seed

    private static let defaultSettings: [(String, String)] = [
        ("appearance", "\"system\""), ("density", "\"compact\""), ("page_size", "500"), ("relative_dates", "false"),
        ("prod_guard_cost", "1000000"), ("prod_guard_rows", "1000000"), ("timeout_ms", "15000"), ("row_cap", "500"), ("approval_ttl_s", "600"),
        ("redaction_patterns", #"["email","phone","ssn","address","name","token","password","iban","dob"]"#),
    ]

    private func seed() throws {
        try transaction {
            for (k, v) in Self.defaultSettings { try h.query("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)", [k, v]) }
            for c in try connectionsLocked() where c.env != "system" { try ensureMine(c.id) }
            try h.query("""
                INSERT INTO connections(id, name, engine, env, file_path, read_only) VALUES (?, ?, 'sqlite', 'system', ?, 1)
                ON CONFLICT(id) DO UPDATE SET file_path = excluded.file_path WHERE file_path IS NOT excluded.file_path
                """, [Self.internalID, Self.internalName, url.path])
            try ensureMine(Self.internalID)
            if try h.scalar("SELECT 1 FROM overlay_items WHERE layer_id = ? AND kind = 'dashboard'", ["mine:" + Self.internalID]) == nil { // once: a deleted default stays deleted
                try h.query("INSERT INTO overlay_items(id, layer_id, kind, name, payload) VALUES (?, ?, 'dashboard', ?, ?)", [UUID().uuidString, "mine:" + Self.internalID, Seeds.agentActivityTitle, Seeds.agentActivity])
            }
        }
    }

    // MARK: backups

    /// `VACUUM INTO backups/dbman-YYYY-MM-DD.sqlite` once a day, keeping the newest 7. Call off the main thread after launch.
    public func backupIfNeeded(today: Date = Date()) throws {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("dbman-\(f.string(from: today)).sqlite")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try locked { try h.query("VACUUM INTO ?", [dest.path]) }
        }
        let old = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("dbman-") && $0.hasSuffix(".sqlite") }.sorted().dropLast(7)
        for name in old { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    // MARK: access

    @discardableResult func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func transaction(_ body: () throws -> Void) throws { try locked { try h.transaction(body) } }
    private func meta(_ key: String) throws -> String? { try locked { try h.scalar("SELECT value FROM meta WHERE key = ?", [key]) as? String } }

    public func setting(_ key: String) -> String? { locked { (try? h.scalar("SELECT value FROM settings WHERE key = ?", [key])) as? String } }
    /// `json` must be valid JSON text (`500`, `true`, `"dark"`); the table's CHECK rejects anything else.
    public func setSetting(_ key: String, json: String) throws { try transaction { try setSettingLocked(key, json: json) } }
    private func setSettingLocked(_ key: String, json: String) throws {
        try h.query("""
            INSERT INTO settings(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
                WHERE value IS NOT excluded.value
            """, [key, json])
    }

    public func connections() throws -> [ConnectionRow] { try locked { try connectionsLocked() } }
    /// What MCP may list: everything except the internal store (SPEC §6, G21).
    public func agentVisibleConnections() throws -> [ConnectionRow] { try connections().filter { $0.env != "system" } }

    private func connectionsLocked() throws -> [ConnectionRow] {
        try h.query("""
            SELECT id, name, engine, host, port, "database", "user", ssl_mode, ssl_root_cert, env, file_path, read_only, stage_writes, last_opened_at,
              ssh_host, ssh_user, ssh_port, ssh_identity
            FROM connections ORDER BY env = 'system', rowid
            """).map { r in
            var c = ConnectionRow(id: r.s(0), name: r.s(1), engine: r.s(2))
            c.host = r.s(3); c.port = Int(r.n(4)); c.database = r.s(5); c.user = r.s(6)
            c.sslMode = r.s(7); c.sslRootCert = r[8] as? String; c.env = r.s(9); c.filePath = r[10] as? String
            c.readOnly = r.n(11) == 1; c.stageWrites = r.n(12) == 1
            c.lastOpened = (r[13] as? Int64).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            c.sshHost = r[14] as? String; c.sshUser = r[15] as? String; c.sshPort = (r[16] as? Int64).map(Int.init); c.sshIdentity = r[17] as? String
            return c
        }
    }

    /// Insert or update a user connection (never the internal one) and make sure it has its MINE layer.
    public func upsert(_ c: ConnectionRow) throws {
        guard c.id != Self.internalID, c.env != "system" else { throw StoreError(message: "The internal connection cannot be edited") }
        try transaction { try upsertLocked(c) }
    }
    private func upsertLocked(_ c: ConnectionRow) throws {
        try h.query("""
            INSERT INTO connections(id, name, engine, host, port, "database", "user", ssl_mode, ssl_root_cert, env, file_path, secret_ref, read_only, stage_writes, last_opened_at,
              ssh_host, ssh_user, ssh_port, ssh_identity)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, engine=excluded.engine, host=excluded.host, port=excluded.port, "database"=excluded."database",
              "user"=excluded."user", ssl_mode=excluded.ssl_mode, ssl_root_cert=excluded.ssl_root_cert, env=excluded.env, file_path=excluded.file_path,
              secret_ref=excluded.secret_ref, read_only=excluded.read_only, stage_writes=excluded.stage_writes, last_opened_at=excluded.last_opened_at,
              ssh_host=excluded.ssh_host, ssh_user=excluded.ssh_user, ssh_port=excluded.ssh_port, ssh_identity=excluded.ssh_identity,
              updated_at=CAST(unixepoch('subsec') * 1000 AS INTEGER)
            """, [c.id, c.name, c.engine, c.host, c.port, c.database, c.user, c.sslMode, c.sslRootCert, c.env, c.filePath, c.secretRef,
                  c.readOnly, c.stageWrites, c.lastOpened.map { Int64($0.timeIntervalSince1970 * 1000) },
                  c.sshHost, c.sshUser, c.sshPort, c.sshIdentity])
        try ensureMine(c.id)
    }

    public func remove(_ id: String) throws {
        guard id != Self.internalID else { throw StoreError(message: "The internal connection cannot be removed") }
        try transaction { try h.query("DELETE FROM connections WHERE id = ?", [id]) }
    }

    /// The human's base layer ("MINE"); one per connection, created on demand.
    public func ensureMineLayer(_ connectionID: String) throws { try transaction { try ensureMine(connectionID) } }
    private func ensureMine(_ connectionID: String) throws {
        try h.query("INSERT OR IGNORE INTO layers(id, connection_id, owner, name) VALUES (?, ?, 'human', 'MINE')", ["mine:" + connectionID, connectionID])
    }

    // MARK: schema map

    /// Saved FREE-layout positions (JSON text) for a connection.
    public func mapLayout(_ connectionID: String, _ layout: String) -> String? {
        locked { (try? h.scalar("SELECT positions FROM map_layouts WHERE connection_id = ? AND layout = ?", [connectionID, layout])) as? String }
    }
    public func setMapLayout(_ connectionID: String, _ layout: String, positions: String) throws {
        try transaction {
            try h.query("""
                INSERT INTO map_layouts(connection_id, layout, positions) VALUES (?, ?, ?)
                ON CONFLICT(connection_id, layout) DO UPDATE SET positions = excluded.positions, updated_at = CAST(unixepoch('subsec') * 1000 AS INTEGER)
                """, [connectionID, layout, positions])
        }
    }

    /// An accepted inferred relation: a `relation` item in the connection's MINE layer (agents add theirs with `addItem` into their own layer).
    public func addRelation(_ connectionID: String, name: String, payload: String) throws {
        try ensureMineLayer(connectionID)
        try addItem(layer: Self.mineID(connectionID), kind: "relation", name: name, payload: payload)
    }
    /// Payloads of the connection's live relation items, oldest first.
    public func relations(_ connectionID: String) -> [String] {
        let rows = locked {
            (try? h.query("""
                SELECT i.payload FROM overlay_items i JOIN layers l ON l.id = i.layer_id
                WHERE l.connection_id = ? AND l.visible = 1 AND i.kind = 'relation' AND i.status IN ('active', 'stale') ORDER BY i.rowid
                """, [connectionID])) ?? []
        }
        return rows.compactMap { $0[0] as? String }
    }

    // MARK: change notification

    private func notify() {
        pendingLock.lock(); let first = !pending; pending = true; pendingLock.unlock()
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.pendingLock.lock(); self.pending = false; self.pendingLock.unlock()
            self.onChange?()
        }
    }

    /// File events catch writers we don't see through the update hook (sqlite3 CLI, another process).
    private func watch() {
        for path in [url.path + "-wal", url.path] {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .global(qos: .utility))
            src.setEventHandler { [weak self] in self?.notify() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }
}
