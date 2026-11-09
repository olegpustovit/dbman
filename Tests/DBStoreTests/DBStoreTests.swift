import SQLite3
import XCTest
@testable import DBStore

final class DBStoreTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("dbman.sqlite") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Raw second connection, as the sqlite3 CLI would be.
    func raw(_ sql: String) throws -> [[Any?]] {
        let h = try Handle(path: url.path)
        return try h.query(sql)
    }

    func testMigrateEmptyToLatest() throws {
        let s = try Store.open(at: url)
        _ = s
        XCTAssertEqual(try raw("PRAGMA user_version")[0][0] as? Int64, 1)
        XCTAssertEqual(try raw("PRAGMA application_id")[0][0] as? Int64, 0x44424D4E)
        XCTAssertEqual(try raw("PRAGMA journal_mode")[0][0] as? String, "wal")
        let names = Set(try raw("SELECT name FROM sqlite_master WHERE type IN ('table','view')").map { $0[0] as! String })
        let want = ["meta", "settings", "connections", "agents", "permissions", "sensitive_columns", "layers", "overlay_items", "row_patches",
                    "activity", "approvals", "query_history", "schema_cache", "map_layouts",
                    "v_agent_activity_daily", "v_layer_summary", "v_pending_approvals", "v_dashboard_widgets"]
        XCTAssertTrue(Set(want).isSubset(of: names), "missing \(Set(want).subtracting(names))")
        XCTAssertTrue(try raw("PRAGMA table_list").filter { want.prefix(14).contains($0[1] as! String) }.allSatisfy { ($0[5] as? Int64) == 1 }, "STRICT")
        for v in want.suffix(4) { XCTAssertNoThrow(try raw("SELECT * FROM \(v)")) }
    }

    func testBootstrapSpeedAndSeed() throws {
        let t0 = Date()
        let s = try Store.open(at: url)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("bootstrap empty store: \(ms) ms")
        XCTAssertLessThan(ms, 50)
        XCTAssertEqual(s.setting("page_size"), "500")
        XCTAssertEqual(s.setting("relative_dates"), "false")
        XCTAssertEqual(s.setting("redaction_patterns")?.contains("iban"), true)
        let c = try s.connections()
        XCTAssertEqual(c.map(\.id), ["internal"])
        XCTAssertEqual(c[0].name, "DBMan // internal"); XCTAssertEqual(c[0].env, "system"); XCTAssertEqual(c[0].filePath, url.path)
        XCTAssertTrue(try s.agentVisibleConnections().isEmpty)
        // reopening is idempotent
        let s2 = try Store.open(at: url)
        XCTAssertEqual(try s2.connections().count, 1)
    }

    func testV1ImportAndDefaults() throws {
        let fixture = Bundle.module.url(forResource: "connections", withExtension: "json", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: fixture, to: dir.appendingPathComponent("connections.json"))
        let ud = UserDefaults(suiteName: "dbstore-test-\(UUID().uuidString)")!
        ud.set(1000, forKey: "pageSize"); ud.set(true, forKey: "relativeDates")
        let s = try Store.open(at: url, v1Dir: dir, defaults: ud)
        let c = try s.connections()
        XCTAssertEqual(c.map(\.name), ["prod", "notes.sqlite", "DBMan // internal"])
        XCTAssertEqual(c[0].env, "production"); XCTAssertEqual(c[0].port, 5432); XCTAssertEqual(c[0].sslMode, "verify-full")
        XCTAssertEqual(c[0].secretRef, "keychain:" + c[0].id)
        XCTAssertNil(c[1].secretRef); XCTAssertTrue(c[1].readOnly); XCTAssertNotNil(c[0].lastOpened)
        XCTAssertEqual(s.setting("page_size"), "1000"); XCTAssertEqual(s.setting("relative_dates"), "true")
        XCTAssertEqual(s.setting("row_cap"), "500") // defaults still seeded
        XCTAssertEqual(try raw("SELECT count(*) FROM layers WHERE name = 'MINE'")[0][0] as? Int64, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("connections.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("connections.json.v1-backup").path))
        XCTAssertEqual(try raw("SELECT value FROM meta WHERE key = 'migrated_from'")[0][0] as? String, "v1")
    }

    func testCorruptFileIsMovedAndRecreated() throws {
        try Data("this is not a database, just bytes".utf8).write(to: url)
        let s = try Store.open(at: url)
        XCTAssertEqual(s.setting("page_size"), "500")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("dbman.corrupt-") && $0.hasSuffix(".sqlite") }, "\(files)")
    }

    func testChecksRejectBadValues() throws {
        let s = try Store.open(at: url)
        _ = s
        XCTAssertThrowsError(try raw("INSERT INTO connections(id, name, engine, env) VALUES ('x','x','sqlite','bogus')"))
        XCTAssertThrowsError(try raw("INSERT INTO connections(id, name, engine, env) VALUES ('x','x','sqlite','system')"), "system env only for internal")
        try raw("INSERT INTO connections(id, name, engine) VALUES ('x','x','sqlite')")
        try raw("INSERT INTO agents(id, client_name) VALUES ('a','claude-code')")
        XCTAssertThrowsError(try raw("INSERT INTO permissions(agent_id, connection_id, level) VALUES ('a','x','write')"))
        try raw("INSERT INTO permissions(agent_id, connection_id, level) VALUES ('a','x','overlay')")
        XCTAssertThrowsError(try raw("INSERT INTO settings(key, value) VALUES ('k', 'not json')"))
    }

    func testPermissionForInternalIsRejected() throws {
        _ = try Store.open(at: url)
        try raw("INSERT INTO agents(id, client_name) VALUES ('a','claude-code')")
        XCTAssertThrowsError(try raw("INSERT INTO permissions(agent_id, connection_id, level) VALUES ('a','internal','read')")) {
            XCTAssertTrue("\($0)".contains("permissions_not_internal"), "\($0)")
        }
    }

    func testInternalCannotBeEditedOrRemoved() throws {
        let s = try Store.open(at: url)
        XCTAssertThrowsError(try s.remove("internal"))
        XCTAssertThrowsError(try s.upsert(ConnectionRow(id: "internal", name: "x", engine: "sqlite")))
    }

    func testConnectionCRUDAndSettings() throws {
        let s = try Store.open(at: url)
        var c = ConnectionRow(id: "A", name: "a", engine: "postgres"); c.host = "h"; c.port = 5432
        try s.upsert(c); c.name = "b"; try s.upsert(c)
        XCTAssertEqual(try s.connections().map(\.name), ["b", "DBMan // internal"])
        XCTAssertEqual(try raw("SELECT count(*) FROM layers WHERE connection_id = 'A'")[0][0] as? Int64, 1)
        try s.setSetting("page_size", json: "700"); XCTAssertEqual(s.setting("page_size"), "700")
        XCTAssertThrowsError(try s.setSetting("page_size", json: "{bad"))
        try s.remove("A")
        XCTAssertEqual(try raw("SELECT count(*) FROM layers WHERE connection_id = 'A'")[0][0] as? Int64, 0)
    }

    func testBackupKeepsSeven() throws {
        let s = try Store.open(at: url)
        let backups = dir.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for d in 1...9 { FileManager.default.createFile(atPath: backups.appendingPathComponent(String(format: "dbman-2026-01-%02d.sqlite", d)).path, contents: Data()) }
        try s.backupIfNeeded(today: Date())
        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left.count, 7)
        XCTAssertTrue(left.contains("dbman-2026-01-09.sqlite"))
        XCTAssertFalse(left.contains("dbman-2026-01-01.sqlite"))
        let today = left.last!
        XCTAssertEqual(try Handle(path: backups.appendingPathComponent(today).path).scalar("PRAGMA application_id") as? Int64, 0x44424D4E)
    }

    func testExternalEditNotifies() throws {
        let s = try Store.open(at: url)
        let fired = expectation(description: "onChange")
        fired.assertForOverFulfill = false
        s.onChange = { fired.fulfill() }
        _ = try raw("UPDATE settings SET value = '900' WHERE key = 'page_size'")
        wait(for: [fired], timeout: 3)
        XCTAssertEqual(s.setting("page_size"), "900")
    }
}
