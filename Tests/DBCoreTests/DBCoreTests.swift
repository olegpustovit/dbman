import XCTest
@testable import DBCore

final class SQLiteTests: XCTestCase {
    func makeSession(readOnly: Bool = false) async throws -> (DatabaseSession, String) {
        let path = NSTemporaryDirectory() + "dbman-\(UUID().uuidString).sqlite"
        let setup = try SQLiteDriver(path: path, readOnly: false)
        _ = try await setup.execute("""
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, created DATETIME);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id) ON DELETE CASCADE, total REAL);
            CREATE INDEX idx_orders_user ON orders(user_id);
            CREATE VIEW v AS SELECT * FROM users;
            INSERT INTO users VALUES (1,'ann','2024-05-01 10:00:00'),(2,'bob',NULL),(3,'cy','2024-06-01');
            INSERT INTO orders VALUES (1,1,9.5),(2,1,20),(3,2,5);
            """)
        await setup.close()
        let p = ConnectionProfile(name: "t", engine: .sqlite, filePath: path, openReadOnly: readOnly)
        return (try await DatabaseSession.connect(p, password: nil), path)
    }

    func testExecuteAndLimit() async throws {
        let (s, _) = try await makeSession()
        let r = try await s.run("SELECT * FROM users ORDER BY id")
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.rows[0][0], .integer(1))
        guard case .date = r.rows[0][2] else { return XCTFail("expected date") }
        XCTAssertTrue(r.rows[1][2].isNull)
        let l = try await s.run("SELECT * FROM users", limit: 2)
        XCTAssertEqual(l.rows.count, 2); XCTAssertTrue(l.truncated)
        let u = try await s.run("UPDATE users SET name = 'x' WHERE id > 1")
        XCTAssertEqual(u.rowsAffected, 2)
        do { _ = try await s.run("SELEC 1"); XCTFail("should throw") } catch DBError.query {}
    }

    func testStreamPages() async throws {
        let (s, _) = try await makeSession()
        var pages: [RowPage] = []
        for try await p in s.stream("SELECT * FROM users", pageSize: 2) { pages.append(p) }
        XCTAssertEqual(pages.map(\.rows.count), [2, 1])
        XCTAssertEqual(pages.last?.isLast, true)
    }

    func testSchemaAndExplain() async throws {
        let (s, _) = try await makeSession()
        let snap = try await s.schema()
        XCTAssertEqual(snap.tables.map(\.name), ["orders", "users", "v"])
        let o = try XCTUnwrap(snap.table("orders"))
        XCTAssertEqual(o.rowCount, 3)
        XCTAssertEqual(o.columns.first { $0.name == "user_id" }?.foreignKey, ForeignKey(table: "users", column: "id", onDelete: "CASCADE"))
        XCTAssertEqual(o.indexes.first?.columns, ["user_id"])
        XCTAssertEqual(snap.table("users")?.primaryKey, ["id"])
        XCTAssertEqual(snap.table("v")?.kind, .view)
        XCTAssertNotNil(snap.sizeBytes)
        let plan = try await s.explain("SELECT * FROM orders WHERE user_id = 1")
        XCTAssertEqual(plan?.operation, "SEARCH")
        XCTAssertEqual(plan?.relation, "orders")
    }

    func testChangeSetCommitAndReadOnly() async throws {
        let (s, path) = try await makeSession()
        await s.stage(.update(table: "users", key: ["id": .integer(1)], column: "name", old: .text("ann"), new: .text("o'neil")))
        await s.stage(.insert(table: "users", values: ["id": .integer(9), "name": .text("zed")]))
        await s.stage(.delete(table: "orders", key: ["id": .integer(3)]))
        try await s.commit()
        let r = try await s.run("SELECT name FROM users WHERE id IN (1, 9) ORDER BY id")
        XCTAssertEqual(r.rows.map { $0[0] }, [.text("o'neil"), .text("zed")])
        let c = try await s.run("SELECT count(*) FROM orders")
        XCTAssertEqual(c.rows[0][0], .integer(2))

        let ro = ConnectionProfile(name: "ro", engine: .sqlite, filePath: path, openReadOnly: true)
        let rs = try await DatabaseSession.connect(ro, password: nil)
        do { _ = try await rs.run("DELETE FROM users"); XCTFail() } catch DBError.readOnly {}
        // even bypassing the session guard, the connection itself is read-only
        let d = try SQLiteDriver(path: path, readOnly: true)
        do { _ = try await d.execute("DELETE FROM users"); XCTFail() } catch DBError.query {}

        // production opens read-write (so Unlock works) but locked: the engine refuses writes the classifier misses
        let prod = ConnectionProfile(name: "p", engine: .sqlite, filePath: path, environment: .production)
        let ps = try await DatabaseSession.connect(prod, password: nil)
        do { _ = try await ps.run("WITH x AS (SELECT 1) DELETE FROM users"); XCTFail() } catch {}
        await ps.unlockWrites()
        _ = try await ps.run("WITH x AS (SELECT 1) DELETE FROM orders")
    }

    func testColumnStats() async throws {
        let (s, _) = try await makeSession()
        let st = try await s.columnStats(table: "orders")
        let total = try XCTUnwrap(st.first { $0.column == "total" })
        XCTAssertEqual(total.min, "5.00"); XCTAssertEqual(total.histogram.count, 12); XCTAssertEqual(total.distinct, 3)
        let uid = try XCTUnwrap(st.first { $0.column == "user_id" })
        XCTAssertEqual(uid.topValues.first?.value, "1")
    }
}

final class ConnectionURLTests: XCTestCase {
    func testPostgresURL() throws {
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword("postgres://me:s%40cret@db.example.com:6543/shop?sslmode=require"))
        XCTAssertEqual([p.engine, p.host == "db.example.com" ? .postgres : .mysql], [.postgres, .postgres])
        XCTAssertEqual(p.port, 6543); XCTAssertEqual(p.user, "me"); XCTAssertEqual(p.database, "shop")
        XCTAssertEqual(p.sslMode, .require); XCTAssertEqual(pw, "s@cret")
    }
    func testMySQLDefaults() throws {
        let p = try XCTUnwrap(ConnectionURL.parse("mysql://root@localhost/app"))
        XCTAssertEqual(p.engine, .mysql); XCTAssertEqual(p.port, 3306)
        XCTAssertEqual(ConnectionURL.parse("mariadb://u@h/d")?.engine, .mysql)
    }
    func testSQLite() throws {
        XCTAssertEqual(ConnectionURL.parse("sqlite:///tmp/a.db")?.filePath, "/tmp/a.db")
        XCTAssertEqual(ConnectionURL.parse("/tmp/x.sqlite3")?.engine, .sqlite)
        XCTAssertEqual(ConnectionURL.parse("~/data.db")?.filePath, NSHomeDirectory() + "/data.db")
        XCTAssertNil(ConnectionURL.parse("/tmp/readme.txt"))
        XCTAssertNil(ConnectionURL.parse("hello"))
    }
    func testDSNAndPsql() throws {
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword("host=h port=5433 dbname=d user=u password='a b' sslmode=disable"))
        XCTAssertEqual([p.host, p.database, p.user], ["h", "d", "u"]); XCTAssertEqual(p.port, 5433)
        XCTAssertEqual(p.sslMode, .disable); XCTAssertEqual(pw, "a b")
        let q = try XCTUnwrap(ConnectionURL.parse("psql -h myhost -p 5440 -U alice mydb"))
        XCTAssertEqual([q.host, q.user, q.database], ["myhost", "alice", "mydb"]); XCTAssertEqual(q.port, 5440)
    }
    func testFormatRoundTrip() throws {
        let p = try XCTUnwrap(ConnectionURL.parse("postgresql://me@h:5433/db?sslmode=verify-full"))
        XCTAssertEqual(ConnectionURL.format(p), "postgresql://me@h:5433/db?sslmode=verify-full")
        XCTAssertEqual(ConnectionURL.parse(ConnectionURL.format(p))?.port, 5433)
    }
}

final class MiscTests: XCTestCase {
    func testClassifier() {
        XCTAssertTrue(SQLClassifier.isWrite("  -- hi\n /* x */ delete from t"))
        XCTAssertFalse(SQLClassifier.isWrite("SELECT 1"))
        XCTAssertEqual(SQLClassifier.firstKeyword("with x as (select 1) select * from x"), "WITH")
    }
    func testChangeSetCollapseUndoSQL() {
        var cs = ChangeSet()
        let k: [String: Cell] = ["id": .integer(1)]
        cs.add(.update(table: "t", key: k, column: "a", old: .text("x"), new: .text("y")))
        cs.add(.update(table: "t", key: k, column: "a", old: .text("y"), new: .text("z")))
        XCTAssertEqual(cs.count, 1)
        XCTAssertEqual(cs.items[0], .update(table: "t", key: k, column: "a", old: .text("x"), new: .text("z")))
        cs.add(.update(table: "t", key: k, column: "a", old: .text("z"), new: .text("x")))
        XCTAssertTrue(cs.isEmpty) // back to original cancels out
        cs.add(.insert(table: "t", values: ["a": .integer(1)]))
        cs.add(.delete(table: "t", key: k))
        XCTAssertEqual(cs.summary.inserts, 1); XCTAssertEqual(cs.summary.deletes, 1)
        cs.undo(); XCTAssertEqual(cs.count, 1)
        XCTAssertEqual(cs.transactionSQL(engine: .mysql), "START TRANSACTION;\nINSERT INTO `t` (`a`) VALUES (1);\nCOMMIT;")
        XCTAssertEqual(cs.transactionSQL(engine: .postgres).hasPrefix("BEGIN;"), true)
    }
    func testSplitStatements() {
        XCTAssertEqual(splitStatements("select 'a;b'; select $$x;y$$ ; -- c;\nselect 3;"), ["select 'a;b'", "select $$x;y$$", "-- c;\nselect 3"])
        XCTAssertEqual(splitStatements("select 1; -- trailing"), ["select 1"])
    }
}

/// Integration tests: only run when DBMAN_PG_URL / DBMAN_MYSQL_URL are set.
final class ServerIntegrationTests: XCTestCase {
    func roundTrip(_ envKey: String) async throws {
        guard let url = ProcessInfo.processInfo.environment[envKey] else { throw XCTSkip("\(envKey) not set") }
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword(url))
        let s = try await DatabaseSession.connect(p, password: pw)
        let t = "dbman_it_\(Int.random(in: 1000...9999))"
        _ = try await s.run("CREATE TABLE \(t) (id INT PRIMARY KEY, name VARCHAR(20) NOT NULL, score DOUBLE PRECISION)".replacingOccurrences(of: "DOUBLE PRECISION", with: p.engine == .mysql ? "DOUBLE" : "DOUBLE PRECISION"))
        _ = try await s.run("INSERT INTO \(t) VALUES (1,'a',1.5); INSERT INTO \(t) VALUES (2,'b',NULL)")
        let r = try await s.run("SELECT * FROM \(t) ORDER BY id")
        XCTAssertEqual(r.rows.count, 2); XCTAssertEqual(r.rows[0][0], .integer(1)); XCTAssertEqual(r.rows[0][2], .real(1.5))
        var n = 0
        for try await page in s.stream("SELECT * FROM \(t) ORDER BY id", pageSize: 1) { n += page.rows.count }
        XCTAssertEqual(n, 2)
        let snap = try await s.schema()
        XCTAssertEqual(snap.table(t)?.primaryKey, ["id"])
        let plan = try await s.explain("SELECT * FROM \(t)", analyze: false)
        XCTAssertNotNil(plan)
        do { _ = try await s.run("SELEC 1"); XCTFail() } catch DBError.query {}
        _ = try? await s.run("DROP TABLE \(t)")
        await s.close()
    }
    func testPostgres() async throws { try await roundTrip("DBMAN_PG_URL") }
    func testMySQL() async throws { try await roundTrip("DBMAN_MYSQL_URL") }
}

/// Runs against the provisioned "shop" dataset when present (customers/orders/...); updates are restored.
final class ShopDatasetTests: XCTestCase {
    func check(_ envKey: String) async throws {
        guard let url = ProcessInfo.processInfo.environment[envKey] else { throw XCTSkip("\(envKey) not set") }
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword(url))
        let s = try await DatabaseSession.connect(p, password: pw)
        do { try await runShop(s, p, envKey) } catch { await s.close(); throw error }
        await s.close()
    }
    func runShop(_ s: DatabaseSession, _ p: ConnectionProfile, _ envKey: String) async throws {
        let snap = try await s.schema()
        guard let orders = snap.table("orders"), snap.table("customers") != nil else { throw XCTSkip("shop dataset missing") }
        print("[\(envKey)] \(snap.serverVersion) tables=\(snap.tables.count) orders.rows=\(orders.rowCount) fks=\(orders.columns.compactMap(\.foreignKey)) idx=\(orders.indexes.map(\.name)) size=\(snap.sizeBytes ?? -1) view=\(snap.table("revenue_by_month")?.kind.rawValue ?? "none")")
        XCTAssertFalse(orders.primaryKey.isEmpty); XCTAssertFalse(orders.indexes.isEmpty)
        let c = try await s.run("SELECT count(*) FROM orders")
        XCTAssertEqual(c.rows[0][0], .integer(48000))
        var pages = 0, rows = 0
        for try await page in s.stream("SELECT * FROM orders ORDER BY id", pageSize: 5000) { pages += 1; rows += page.rows.count; if pages == 3 { break } }
        XCTAssertEqual(rows, 15000)
        let plan = try await s.explain("SELECT * FROM orders WHERE id = 10432", analyze: p.engine == .postgres)
        print("[\(envKey)] plan: \(plan?.operation ?? "nil") rel=\(plan?.relation ?? "-") detail=\(plan?.detail ?? "-") totalMs=\(String(describing: plan?.totalMs))")
        XCTAssertNotNil(plan)
        let first = try await s.run("SELECT * FROM orders WHERE id = 10432")
        let ci = try XCTUnwrap(first.rows[0].indices.first { first.rows[0][$0].isNumeric && !orders.columns[$0].isPrimaryKey && orders.columns[$0].foreignKey == nil }, "no numeric column")
        let col = orders.columns[ci]
        let old = first.rows[0][ci]
        let bumped: Cell = { if case .integer(let v) = old { return .integer(v + 1) } else if case .real(let v) = old { return .real(v + 1) } else { return old } }()
        await s.stage(.update(table: "orders", key: ["id": .integer(10432)], column: col.name, old: old, new: bumped))
        try await s.commit()
        let after = try await s.run("SELECT \(quoteIdent(col.name, p.engine)) FROM orders WHERE id = 10432")
        XCTAssertEqual(after.rows[0][0], bumped)
        await s.stage(.update(table: "orders", key: ["id": .integer(10432)], column: col.name, old: bumped, new: old))
        try await s.commit()
        let restored = try await s.run("SELECT \(quoteIdent(col.name, p.engine)) FROM orders WHERE id = 10432")
        XCTAssertEqual(restored.rows[0][0], old)
    }
    func testPostgresShop() async throws { try await check("DBMAN_PG_URL") }
    func testMySQLShop() async throws { try await check("DBMAN_MYSQL_URL") }
}

/// Cancel a long statement ~300 ms after it starts; it must end (error or early return) within 2 s.
final class CancelTests: XCTestCase {
    func check(_ s: DatabaseSession, _ sql: String) async throws {
        let t0 = Date()
        let task = Task { try await s.run(sql) }
        try await Task.sleep(for: .milliseconds(300))
        await s.cancel()
        let r = await task.result
        let dt = Date().timeIntervalSince(t0)
        XCTAssertLessThan(dt, 2, "cancel took \(dt)s")
        if case .failure(let e) = r { XCTAssertTrue(e is DBError, "\(e)") } // MariaDB may return early instead of failing
        await s.close()
    }
    func server(_ key: String, _ sql: String) async throws {
        guard let url = ProcessInfo.processInfo.environment[key] else { throw XCTSkip("\(key) not set") }
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword(url))
        try await check(DatabaseSession.connect(p, password: pw), sql)
    }
    func testSQLiteCancel() async throws {
        let path = NSTemporaryDirectory() + "dbman-\(UUID().uuidString).sqlite"
        let s = try await DatabaseSession.connect(ConnectionProfile(name: "t", engine: .sqlite, filePath: path), password: nil)
        try await check(s, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 2000000000) SELECT count(*) FROM c")
    }
    func testPostgresCancel() async throws { try await server("DBMAN_PG_URL", "SELECT pg_sleep(10)") }
    func testMySQLCancel() async throws { try await server("DBMAN_MYSQL_URL", "SELECT SLEEP(10)") }
}

/// sslmode=require against a self-signed server: encrypted, unverified.
final class TLSTests: XCTestCase {
    func connect(_ key: String) async throws -> DatabaseSession {
        guard let url = ProcessInfo.processInfo.environment[key] else { throw XCTSkip("\(key) not set") }
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword(url))
        XCTAssertEqual(p.sslMode, .require)
        return try await DatabaseSession.connect(p, password: pw)
    }
    func testPostgresTLS() async throws {
        let s = try await connect("DBMAN_PG_TLS_URL")
        let r = try await s.run("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        XCTAssertEqual(r.rows.first?.first, .bool(true))
        await s.close()
    }
    func testMySQLTLS() async throws {
        let s = try await connect("DBMAN_MYSQL_TLS_URL")
        let r = try await s.run("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        guard case .text(let cipher)? = r.rows.first?.last else { return XCTFail("no Ssl_cipher row") }
        XCTAssertFalse(cipher.isEmpty, "connection is not encrypted")
        await s.close()
    }
}

/// Password auth (role `secure`/`s3cret` must authenticate) and verify-full against the local CA (testdb/tls/ca.pem).
final class AuthAndCATests: XCTestCase {
    static let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("testdb/tls/ca.pem").path

    /// Builds a profile from an env URL, overriding user/ssl settings.
    func profile(_ key: String, user: String? = nil, mode: SSLMode? = nil, ca: String? = nil) throws -> ConnectionProfile {
        guard let url = ProcessInfo.processInfo.environment[key] else { throw XCTSkip("\(key) not set") }
        var p = try XCTUnwrap(ConnectionURL.parse(url))
        if let user { p.user = user }
        if let mode { p.sslMode = mode }
        p.sslRootCert = ca
        return p
    }
    func fails(_ p: ConnectionProfile, _ pw: String?, _ words: [String], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let s = try await DatabaseSession.connect(p, password: pw); await s.close()
            XCTFail("connected but should have failed", file: file, line: line)
        } catch let e as DBError {
            switch e { case .connection, .query: break; default: XCTFail("wrong error \(e)", file: file, line: line) }
            let m = (e.errorDescription ?? "").lowercased()
            XCTAssertTrue(words.contains { m.contains($0) }, "unexpected message: \(m)", file: file, line: line)
        } catch { XCTFail("not a DBError: \(error)", file: file, line: line) }
    }
    func auth(_ key: String) async throws {
        let p = try profile(key, user: "secure")
        let s = try await DatabaseSession.connect(p, password: "s3cret")
        let r = try await s.run("SELECT 1"); XCTAssertEqual(r.rows.count, 1); await s.close()
        let words = ["authentication", "access denied", "password"]
        await fails(p, "wrong", words)
        await fails(p, "", words)
        await fails(p, nil, words)
    }
    func testPostgresAuth() async throws { try await auth("DBMAN_PG_URL") }
    func testMySQLAuth() async throws { try await auth("DBMAN_MYSQL_URL") }

    func verify(_ key: String) async throws {
        let ok = try profile(key, mode: .verifyFull, ca: Self.ca)
        let s = try await DatabaseSession.connect(ok, password: "app"); await s.close()
        // Hostname verification (DNS SAN), not only the IP SAN.
        var byName = ok; byName.host = "localhost"
        let s3 = try await DatabaseSession.connect(byName, password: "app"); await s3.close()
        await fails(try profile(key, mode: .verifyFull), "app", ["certificate", "tls", "ssl", "verify", "handshake"])
        let r = try profile(key, mode: .require)
        let s2 = try await DatabaseSession.connect(r, password: "app"); await s2.close()
    }
    func testPostgresVerifyFull() async throws { try await verify("DBMAN_PG_TLS_URL") }
    func testMySQLVerifyFull() async throws { try await verify("DBMAN_MYSQL_TLS_URL") }

    func testSSLRootCertURL() throws {
        let p = try XCTUnwrap(ConnectionURL.parse("postgres://u@h/d?sslmode=verify-full&sslrootcert=/tmp/ca.pem"))
        XCTAssertEqual(p.sslMode, .verifyFull); XCTAssertEqual(p.sslRootCert, "/tmp/ca.pem")
        XCTAssertEqual(ConnectionURL.parse(ConnectionURL.format(p))?.sslRootCert, "/tmp/ca.pem")
        XCTAssertEqual(ConnectionURL.parse("host=h dbname=d sslrootcert=/x/ca.pem")?.sslRootCert, "/x/ca.pem")
        XCTAssertNil(ConnectionURL.parse("postgres://u@h/d")?.sslRootCert)
    }
    func testProfileDecodesWithoutRootCert() throws {
        var p = ConnectionProfile(name: "n", engine: .postgres); p.sslRootCert = "/x"
        var j = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: j)).sslRootCert, "/x")
        j["sslRootCert"] = nil
        XCTAssertNil(try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: j)).sslRootCert)
    }
}
