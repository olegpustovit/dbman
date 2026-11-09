import DBCore
import MCP
import XCTest
@testable import DBManMCP
@testable import DBStore

/// Opened UI routes, recorded by the fake backend.
actor Opened { var routes: [String] = []; func add(_ s: String) { routes.append(s) } }

final class DBManMCPTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var client: Client!
    var service: MCPService!
    let opened = Opened()
    var dbPath: String { dir.appendingPathComponent("shop.sqlite").path }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbmanmcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDriver(path: dbPath, readOnly: false)
        _ = try await db.execute("""
            CREATE TABLE customers(id INTEGER PRIMARY KEY, name TEXT, email TEXT, city TEXT);
            INSERT INTO customers VALUES (1,'Ada Lovelace','ada@example.com','London'),(2,'Alan Turing','alan@example.com','Wilmslow'),(3,'Grace Hopper','grace@example.com','NYC');
            CREATE TABLE orders(id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total REAL);
            INSERT INTO orders VALUES (1,1,10.5),(2,1,20),(3,2,7.25);
            CREATE INDEX idx_orders_customer ON orders(customer_id);
            CREATE TABLE events(id INTEGER PRIMARY KEY, kind TEXT, n INTEGER);
            WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 1200) INSERT INTO events SELECT i, 'k' || (i % 7), i FROM s;
            """)
        await db.close()
        store = try Store.open(at: dir.appendingPathComponent("dbman.sqlite"))
        for (id, name, env) in [("c-shop", "shop", "local"), ("c-prod", "analytics", "production")] {
            var c = ConnectionRow(id: id, name: name, engine: "sqlite")
            c.filePath = dbPath; c.env = env
            try store.upsert(c)
        }
        let headless = HeadlessSessions { _ in nil }
        let opened = opened
        service = MCPService(Backend(store: store, session: { try await headless.session($0) }, isOpen: { await headless.isOpen($0) },
                                     openUI: { c, route, sel in await opened.add("\(c.name):\(route):\(sel ?? "")") }))
        let (ct, st) = await InMemoryTransport.createConnectedPair()
        MCPService.approvalPollMs = 20
        try await service.start(transport: st)
        client = Client(name: "Test Agent", version: "1.2.3")
        _ = try await client.connect(transport: ct)
    }

    override func tearDown() async throws {
        await client.disconnect()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    // Plain functions (not autoclosures) so assertions can contain `await`.
    func same<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, file: file, line: line) }
    func yes(_ v: Bool, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(v, msg, file: file, line: line) }
    func no(_ v: Bool, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(v, msg, file: file, line: line) }

    func call(_ tool: String, _ args: [String: Value] = [:]) async throws -> (text: String, isError: Bool) {
        let r = try await client.callTool(name: tool, arguments: args)
        guard case .text(let t, _, _)? = r.content.first else { return ("", r.isError == true) }
        return (t, r.isError == true)
    }
    /// JSON text with the volatile `ms` removed, for golden compares.
    func golden(_ tool: String, _ args: [String: Value] = [:]) async throws -> String {
        let (t, err) = try await call(tool, args)
        no(err, t)
        return t.replacingOccurrences(of: #","ms":\d+"#, with: "", options: .regularExpression).replacingOccurrences(of: #""ms":\d+,"#, with: "", options: .regularExpression)
    }
    func json(_ tool: String, _ args: [String: Value] = [:]) async throws -> [String: Any] {
        let (t, err) = try await call(tool, args)
        no(err, t)
        return try JSONSerialization.jsonObject(with: Data(t.utf8)) as! [String: Any]
    }
    func raw(_ sql: String) throws -> [[Any?]] { try Handle(path: store.url.path).query(sql) }

    // MARK: protocol surface

    func testToolsPromptsResources() async throws {
        let names = try await client.listTools().tools.map(\.name)
        same(names, ["connections.list", "connections.add", "connections.update", "connections.test", "connections.remove", "schema.tables", "schema.describe", "schema.graph", "schema.search",
                               "query.run", "query.explain", "query.sample", "stats.column", "overlay.status", "overlay.patch_rows", "overlay.diff", "overlay.reset", "views.list", "views.create",
                     "views.replace", "views.drop", "relations.add", "notes.set", "saved.list", "saved.save", "dashboard.components", "dashboard.list", "dashboard.get", "dashboard.create",
                     "dashboard.update", "ui.open"])
        same(try await client.listPrompts().prompts.map(\.name), ["explain-schema", "investigate-table", "build-dashboard"])
        let uris = try await client.listResources().resources.map(\.uri)
        same(uris, ["dbman://connections", "dbman://shop/schema", "dbman://analytics/schema"]) // never the internal store
        let desc = try await client.readResource(uri: "dbman://shop/tables/orders")
        yes(desc.first?.text?.contains(#""references":"customers.id""#) == true)
        yes(try await client.readResource(uri: "dbman://connections").first?.text?.contains("shop") == true)
        let p = try await client.getPrompt(name: "investigate-table", arguments: ["connection": "shop", "table": "orders"])
        yes(p.messages.count == 1)
    }

    func testAgentRowAndPermissionDefaults() async throws {
        let list = try await golden("connections.list")
        same(list, #"[{"engine":"sqlite","env":"local","id":"c-shop","name":"shop","permission":"OVERLAY","status":"idle"},{"engine":"sqlite","env":"production","id":"c-prod","name":"analytics","permission":"READ","status":"idle"}]"#)
        same(try raw("SELECT id, client_name, version FROM agents").map { $0.map { "\($0 ?? "")" } }, [["test-agent", "Test Agent", "1.2.3"]])
        same(try raw("SELECT connection_id FROM permissions ORDER BY 1").map { $0[0] as! String }, ["c-prod", "c-shop"]) // lazily, and never internal
    }

    // MARK: internal store

    func testInternalStoreInvisibleAndDenied() async throws {
        no(try await call("connections.list").text.contains("internal"))
        for ref in ["internal", "DBMan // internal"] {
            let (t, err) = try await call("query.run", ["connection": .string(ref), "sql": "select * from permissions"])
            yes(err)
            yes(t.hasPrefix("PERMISSION_DENIED ("), t)
        }
        let (t, _) = try await call("schema.tables", ["connection": "internal"])
        yes(t.hasPrefix("PERMISSION_DENIED"))
        same(try raw("SELECT count(*) FROM permissions WHERE connection_id = 'internal'")[0][0] as? Int64, 0)
        same(try raw("SELECT status FROM activity WHERE connection_id = 'internal' GROUP BY status").map { $0[0] as! String }, ["denied"])
    }

    func testOffPermissionDenied() async throws {
        _ = try await call("connections.list") // creates the rows
        try Handle(path: store.url.path).exec("UPDATE permissions SET level = 'off' WHERE connection_id = 'c-shop'")
        let (t, err) = try await call("query.run", ["connection": "shop", "sql": "select 1"])
        yes(err)
        same(t, "PERMISSION_DENIED (OFF on shop; needs READ)")
    }

    // MARK: schema

    func testSchemaTools() async throws {
        let a: [String: Value] = ["connection": "shop"]
        same(try await golden("schema.tables", a),
                       #"[{"columns":4,"kind":"table","name":"customers","rows":3},{"columns":3,"kind":"table","name":"events","rows":1200},{"columns":3,"kind":"table","name":"orders","rows":3}]"#)
        same(try await golden("schema.describe", a.merging(["table": "orders"]) { $1 }),
                       #"{"columns":[{"name":"id","nullable":false,"pk":true,"type":"INTEGER"},{"name":"customer_id","nullable":true,"pk":false,"references":"customers.id","type":"INTEGER"},{"name":"total","nullable":true,"pk":false,"type":"REAL"}],"indexes":[{"columns":["customer_id"],"name":"idx_orders_customer","unique":false}],"kind":"table","referenced_by":[],"row_estimate":3,"table":"orders"}"#)
        same(try await golden("schema.graph", a),
                       #"{"edges":[{"from":"orders.customer_id","kind":"declared","to":"customers.id"}],"nodes":[{"rows":3,"table":"customers"},{"rows":1200,"table":"events"},{"rows":3,"table":"orders"}]}"#)
        same(try await golden("schema.search", a.merging(["text": "CUSTOMER"]) { $1 }),
                       #"[{"table":"customers"},{"column":"customer_id","table":"orders","type":"INTEGER"}]"#)
        let (t, err) = try await call("schema.describe", ["connection": "shop", "table": "nope"])
        yes(err); yes(t.hasPrefix("NOT_FOUND"))
    }

    // MARK: redaction

    func testRedaction() async throws {
        let q: [String: Value] = ["connection": "shop", "sql": "select id, name, email, city from customers order by id"]
        same(try await golden("query.run", q),
                       #"{"columns":["id","name","email","city"],"rows":[[1,"«redacted»","«redacted»","London"],[2,"«redacted»","«redacted»","Wilmslow"],[3,"«redacted»","«redacted»","NYC"]],"truncated":false}"#)
        same(try raw("SELECT table_name, column_name, source FROM sensitive_columns WHERE table_name = 'customers' ORDER BY column_name").map { $0.map { "\($0!)" } },
                       [["customers", "email", "auto"], ["customers", "name", "auto"]])
        yes(try await golden("schema.describe", ["connection": "shop", "table": "customers"]).contains(#""hidden":true,"name":"email""#))
        // a count over a hidden column is fine: the result column is not named like one
        yes(try await golden("query.run", ["connection": "shop", "sql": "select count(distinct email) from customers"]).contains("[[3]]"))
        // the human unmarks one column: visible again, and the first-load scan does not re-mark it
        try Handle(path: store.url.path).exec("UPDATE sensitive_columns SET hidden = 0 WHERE column_name = 'email'")
        _ = try await call("schema.tables", ["connection": "shop"])
        yes(try await golden("query.run", q).contains("ada@example.com"))
        // stats and sample honour it too
        yes(try await golden("query.sample", ["connection": "shop", "table": "customers", "n": 1]).contains("«redacted»"))
        yes(try await golden("stats.column", ["connection": "shop", "table": "customers", "column": "name"]).contains(#""hidden":true"#))
    }

    // MARK: writes

    func testWritesAreRedirectedNeverExecuted() async throws {
        for sql in ["insert into customers(name) values ('x')", "delete from customers", "drop table orders", "update orders set total = 0"] {
            let (t, err) = try await call("query.run", ["connection": "shop", "sql": .string(sql)])
            yes(err); yes(t.hasPrefix("WRITE_REDIRECTED (query.run never writes to shop"), t)
        }
        // classifier gaps are covered by the engine: WITH … DELETE passes the keyword check and dies on query_only
        let (t, err) = try await call("query.run", ["connection": "shop", "sql": "with x as (select 1) delete from customers"])
        yes(err); yes(t.hasPrefix("QUERY_FAILED"), t)
        let (m, merr) = try await call("query.run", ["connection": "shop", "sql": "select 1; delete from customers"])
        yes(merr); same(m, "INVALID_ARGUMENT (one statement per call)")
        yes(try await call("query.run", ["connection": "shop", "sql": "pragma query_only = 0"]).text.hasPrefix("WRITE_REDIRECTED"))
        yes(try await golden("query.run", ["connection": "shop", "sql": "select count(*) c from customers"]).contains("[[3]]"))
        same(try raw("SELECT status FROM activity WHERE tool = 'query.run' AND error LIKE 'WRITE_REDIRECTED%' GROUP BY status")[0][0] as? String, "blocked")
        // the read-only read level adds the hint from the spec
        try Handle(path: store.url.path).exec("UPDATE permissions SET level = 'read' WHERE connection_id = 'c-shop'")
        yes(try await call("query.run", ["connection": "shop", "sql": "delete from orders"]).text.hasSuffix("overlay.patch_rows needs OVERLAY, this agent has READ)"))
    }

    // MARK: row cap + cursor

    func testRowCapAndCursor() async throws {
        try store.setSetting("row_cap", json: "500")
        var r = try await json("query.run", ["connection": "shop", "sql": "select id from events order by id"])
        same((r["rows"] as! [Any]).count, 500)
        same(r["truncated"] as? Bool, true)
        var ids = (r["rows"] as! [[Int]]).map { $0[0] }
        while let cursor = r["cursor"] as? String {
            r = try await json("query.run", ["connection": "shop", "cursor": .string(cursor)])
            ids += (r["rows"] as! [[Int]]).map { $0[0] }
        }
        same(ids, Array(1...1200))
        same(r["truncated"] as? Bool, false)
        // limit may only lower the cap
        r = try await json("query.run", ["connection": "shop", "sql": "select id from events", "limit": 5000])
        same((r["rows"] as! [Any]).count, 500)
        r = try await json("query.run", ["connection": "shop", "sql": "select id from events", "limit": 3])
        same((r["rows"] as! [Any]).count, 3)
        // per-agent cap from the permission row beats the setting
        try Handle(path: store.url.path).exec("UPDATE permissions SET row_cap = 10 WHERE connection_id = 'c-shop'")
        r = try await json("query.run", ["connection": "shop", "sql": "select id from events"])
        same((r["rows"] as! [Any]).count, 10)
        let (t, err) = try await call("query.run", ["connection": "shop", "cursor": "garbage"])
        yes(err); same(t, "INVALID_ARGUMENT (unknown cursor)")
    }

    func testStatementTimeoutCancelsTheDriver() async throws {
        try store.setSetting("timeout_ms", json: "300")
        let t0 = Date()
        let (t, err) = try await call("query.run", ["connection": "shop", "sql": "with recursive s(i) as (select 1 union all select i + 1 from s) select count(*) from s"])
        yes(err); yes(t.hasPrefix("TIMEOUT (statement exceeded 300 ms"), t)
        yes(Date().timeIntervalSince(t0) < 3)
        // the session is still usable afterwards
        yes(try await golden("query.run", ["connection": "shop", "sql": "select 1"]).contains("[[1]]"))
    }

    // MARK: prod guard

    func testProdVerdictThresholds() {
        let schema = SchemaSnapshot(serverVersion: "", databaseName: "", tables: [TableInfo(schema: "public", name: "events", kind: .table, rowCount: 61_532)])
        let seq = PlanNode(operation: "Seq Scan", relation: "events", estimatedRows: 61_532, cost: 2.1e6)
        same(Rules.prodVerdict(seq, schema: schema, maxCost: 1e6, maxRows: 1e6), "seq scan on events, 61,532 rows est. cost 2.1e6") // the SPEC example
        XCTAssertNil(Rules.prodVerdict(PlanNode(operation: "Seq Scan", relation: "events", estimatedRows: 61_532, cost: 9e5), schema: schema, maxCost: 1e6, maxRows: 1e6))
        XCTAssertNotNil(Rules.prodVerdict(PlanNode(operation: "Seq Scan", relation: "events", estimatedRows: 61_532, cost: 9e5), schema: schema, maxCost: 1e6, maxRows: 50_000))
        let idx = PlanNode(operation: "Hash Join", estimatedRows: 10, cost: 3e6, children: [PlanNode(operation: "Index Scan", relation: "events", estimatedRows: 1, cost: 8)])
        same(Rules.prodVerdict(idx, schema: schema, maxCost: 1e6, maxRows: 1e6), "est. cost 3.0e6") // costly without a seq scan
        let limited = PlanNode(operation: "Limit", estimatedRows: 10, cost: 0.5, children: [seq])
        XCTAssertNil(Rules.prodVerdict(limited, schema: schema, maxCost: 1e6, maxRows: 1e4)) // a Limit bounds the scan
        let sorted = PlanNode(operation: "Limit", estimatedRows: 10, cost: 0.5, children: [PlanNode(operation: "Sort", estimatedRows: 61_532, cost: 9, children: [seq])])
        XCTAssertNotNil(Rules.prodVerdict(sorted, schema: schema, maxCost: 1e6, maxRows: 1e4)) // ORDER BY unindexed … LIMIT still reads everything
        let mysql = PlanNode(operation: "Table Scan", relation: "events", estimatedRows: 61_532, cost: 0)
        same(Rules.prodVerdict(mysql, schema: schema, maxCost: 1e6, maxRows: 1e4), "seq scan on events, 61,532 rows")
        let lite = PlanNode(operation: "SCAN", relation: "events", detail: "USING COVERING INDEX x", estimatedRows: 0, cost: 0)
        XCTAssertNil(Rules.prodVerdict(lite, schema: schema, maxCost: 1e6, maxRows: 10))
    }

    func testProdHintNamesIndexedColumns() {
        let ix = IndexInfo(name: "idx_events_created_at", columns: ["created_at"], unique: false, definition: "")
        let schema = SchemaSnapshot(serverVersion: "", databaseName: "", tables: [TableInfo(schema: "public", name: "events", kind: .table, rowCount: 61_532, indexes: [ix]), TableInfo(schema: "public", name: "bare", kind: .table, rowCount: 9)])
        same(Rules.prodHint(PlanNode(operation: "Seq Scan", relation: "events", estimatedRows: 1, cost: 1), schema: schema), "add a WHERE on created_at (idx_events_created_at), or a LIMIT")
        same(Rules.prodHint(PlanNode(operation: "Seq Scan", relation: "bare", estimatedRows: 1, cost: 1), schema: schema), "add a LIMIT")
        same(Rules.prodHint(PlanNode(operation: "Hash Join", estimatedRows: 1, cost: 1), schema: schema), "add a LIMIT or a narrower WHERE")
    }

    func testProdGuardOnSQLite() async throws {
        try store.setSetting("prod_guard_rows", json: "1000")
        let (t, err) = try await call("query.run", ["connection": "analytics", "sql": "select * from events where kind = 'k1'"])
        yes(err); yes(t.hasPrefix("BLOCKED_BY_PROD_GUARD (seq scan on events, 1,200 rows;"), t)
        yes(try await golden("query.run", ["connection": "analytics", "sql": "select * from events where id = 7"]).contains("[[7,"))
        yes(try await golden("query.run", ["connection": "analytics", "sql": "select * from customers"]).contains("«redacted»")) // small table: allowed
        same(try raw("SELECT status FROM activity WHERE error LIKE 'BLOCKED_BY_PROD_GUARD%'")[0][0] as? String, "blocked")
        // the same statement is fine on a non-production connection
        no(try await call("query.run", ["connection": "shop", "sql": "select * from events where kind = 'k1'"]).isError)
    }

    // MARK: explain, sample, stats, test, ui

    func testExplainSampleStatsTestUI() async throws {
        let ex = try await json("query.explain", ["connection": "shop", "sql": "select * from orders where customer_id = 1"])
        yes(String(describing: ex["plan"]!).contains("SEARCH"))
        same(try await json("query.sample", ["connection": "shop", "table": "orders", "n": 2])["rows"] as? [[Double]], [[1, 1, 10.5], [2, 1, 20]])
        let st = try await json("stats.column", ["connection": "shop", "table": "events", "column": "n"])
        same(st["min"] as? String, "1"); same(st["max"] as? String, "1200"); same(st["distinct_in_sample"] as? Int, 1200)
        same(try await json("connections.test", ["connection": "shop"])["ok"] as? Bool, true)
        _ = try await call("ui.open", ["connection": "shop", "route": "table", "selection": "orders"])
        same(await opened.routes, ["shop:table:orders"])
        _ = try await call("ui.open", ["connection": "shop", "route": "dashboard", "selection": "Overview // default"])
        same(await opened.routes, ["shop:table:orders", "shop:dashboard:Overview // default"])
        _ = try await call("ui.open", ["connection": "shop", "route": "schema-map", "selection": "orders"])
        same(await opened.routes.last, "shop:schema-map:orders")
        yes(try await call("ui.open", ["connection": "shop", "route": "chart"]).text.hasPrefix("UNSUPPORTED"))
    }

    // MARK: approvals

    /// Waits for a pending approval of `kind`, then decides it the way the app's sheet does.
    func decide(_ kind: String, _ status: String, merge: String = "{}") async throws {
        for _ in 0..<200 {
            if let a = try store.pendingApprovals().first(where: { $0.kind == kind }) { try store.decideApproval(a.id, status, merge: merge); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("no pending \(kind) approval")
    }
    let addArgs: [String: Value] = ["url": "postgres://app@db.example.com/billing", "name": "billing-replica", "env": "staging"]

    func testAddWaitsForTheHumanAndReturnsTheId() async throws {
        async let r = call("connections.add", addArgs)
        try await decide("credentials", "approved", merge: #"{"connection_id":"c-new"}"#)
        let (t, err) = try await r
        no(err, t); same(t, #"{"id":"c-new","name":"billing-replica"}"#)
        same(try raw("SELECT kind, status, json_extract(payload, '$.host'), json_extract(payload, '$.env') FROM approvals").map { $0.map { "\($0!)" } }, [["credentials", "approved", "db.example.com", "staging"]])
        yes(try await call("connections.add", ["url": "postgres://app:hunter2@db.example.com/billing", "name": "x"]).text.hasPrefix("INVALID_ARGUMENT (passwords are never accepted"))
        yes(try await call("connections.add", ["url": "postgres://app@db.example.com/billing", "name": "Shop"]).text.hasPrefix("INVALID_ARGUMENT (a connection named"))
    }

    func testAddWithSSHPutsTheTunnelInThePayload() async throws {
        async let r = call("connections.add", ["url": "postgres://phenix@127.0.0.1:5455/satellite_launches", "name": "satdb-staging", "env": "staging", "ssh": "ubuntu@cx2-satdb:22"])
        try await decide("credentials", "approved", merge: #"{"connection_id":"c-sat"}"#)
        no(try await r.isError)
        same(try raw("SELECT json_extract(payload, '$.host'), json_extract(payload, '$.port'), json_extract(payload, '$.ssh_host'), json_extract(payload, '$.ssh_user'), json_extract(payload, '$.ssh_port') FROM approvals").map { $0.map { "\($0!)" } },
             [["127.0.0.1", "5455", "cx2-satdb", "ubuntu", "22"]])
        // ?ssh= in the url works too; bad hops and SQLite are refused before any approval
        async let r2 = call("connections.add", ["url": "postgres://u@127.0.0.1/d?ssh=bastion", "name": "via-url"])
        try await decide("credentials", "approved", merge: #"{"connection_id":"c-url"}"#)
        no(try await r2.isError)
        same(try raw("SELECT json_extract(payload, '$.ssh_host') FROM approvals WHERE json_extract(payload, '$.name') = 'via-url'")[0][0] as? String, "bastion")
        yes(try await call("connections.add", ["url": "postgres://u@h/d", "name": "bad", "ssh": "-oProxyCommand=x"]).text.hasPrefix("INVALID_ARGUMENT"))
        yes(try await call("connections.add", ["url": "postgres://u@h/d", "name": "bad", "ssh": "a b"]).text.hasPrefix("INVALID_ARGUMENT"))
        yes(try await call("connections.add", ["url": .string(dir.path + "/x.sqlite"), "name": "bad", "ssh": "b"]).text.hasPrefix("INVALID_ARGUMENT"))
    }

    func testUpdateProposesSettingsForTheSameConnection() async throws {
        var c = ConnectionRow(id: "c-pg", name: "pg", engine: "postgres"); c.host = "127.0.0.1"; c.port = 15455; c.database = "d"; c.user = "u"; c.env = "staging"
        try store.upsert(c)
        async let r = call("connections.update", ["connection": "pg", "url": "postgres://u@127.0.0.1:5455/d", "ssh": "ubuntu@cx2-satdb"])
        try await decide("update", "approved", merge: #"{"name":"pg"}"#)
        let (t, err) = try await r
        no(err, t); same(t, #"{"id":"c-pg","name":"pg","via_ssh":"ubuntu@cx2-satdb"}"#)
        same(try raw("SELECT connection_id, json_extract(payload, '$.connection_id'), json_extract(payload, '$.port'), json_extract(payload, '$.ssh_host'), json_extract(payload, '$.env') FROM approvals WHERE kind = 'update'").map { $0.map { "\($0!)" } },
             [["c-pg", "c-pg", "5455", "cx2-satdb", "staging"]])
        // ssh "none" drops the tunnel; the engine cannot change; rejection carries the note
        async let r2 = call("connections.update", ["connection": "pg", "ssh": "none"])
        try await decide("update", "rejected", merge: #"{"note":"keep it"}"#)
        yes(try await r2.text.hasPrefix("REJECTED (keep it"))
        same(try raw("SELECT json_extract(payload, '$.ssh_host') FROM approvals WHERE kind = 'update' AND status = 'rejected'")[0][0] as? String, nil)
        yes(try await call("connections.update", ["connection": "pg", "url": "mysql://u@h/d"]).text.hasPrefix("INVALID_ARGUMENT (the engine"))
        yes(try await call("connections.update", ["connection": "shop", "ssh": "b"]).text.hasPrefix("INVALID_ARGUMENT"))
    }

    func testListShowsTheSSHHop() async throws {
        var c = ConnectionRow(id: "c-pg", name: "pg", engine: "postgres"); c.host = "127.0.0.1"; c.port = 5455; c.sshHost = "cx2-satdb"; c.sshUser = "ubuntu"
        try store.upsert(c)
        let (t, err) = try await call("connections.list")
        no(err, t); yes(t.contains(#""via_ssh":"ubuntu@cx2-satdb""#), t)
    }

    func testAddRefusesTheStoreFolder() async throws {
        for path in [store.url.path, dir.path + "/other.sqlite", dir.path + "/../" + dir.lastPathComponent + "/dbman.sqlite"] {
            let (t, err) = try await call("connections.add", ["url": .string(path), "name": "sneaky"])
            yes(err); yes(t.hasPrefix("INVALID_ARGUMENT (that file lives in DBMan's own store folder"), t)
        }
        same(try raw("SELECT count(*) FROM approvals")[0][0] as? Int64, 0)
    }

    /// A driver whose EXPLAIN returns no plan (Postgres/MySQL can: unparsable output). Production must then block, not run.
    final class NoPlanDriver: DatabaseDriver, @unchecked Sendable {
        let inner: SQLiteDriver
        init(_ path: String) throws { inner = try SQLiteDriver(path: path, readOnly: true) }
        var engine: Engine { inner.engine }
        func execute(_ sql: String, limit: Int) async throws -> QueryResult { try await inner.execute(sql, limit: limit) }
        func executeReadOnly(_ sql: String, limit: Int) async throws -> QueryResult { try await inner.executeReadOnly(sql, limit: limit) }
        func stream(_ sql: String, pageSize: Int) -> AsyncThrowingStream<RowPage, Error> { inner.stream(sql, pageSize: pageSize) }
        func schema() async throws -> SchemaSnapshot { try await inner.schema() }
        func explain(_ sql: String, analyze: Bool) async throws -> PlanNode? { nil }
        func cancelCurrent() async { await inner.cancelCurrent() }
        func close() async { await inner.close() }
    }

    func testProductionBlocksWhenThereIsNoPlan() async throws {
        let c = try XCTUnwrap(store.connections().first { $0.id == "c-prod" })
        let driver = try NoPlanDriver(dbPath)
        let backend = Backend(store: store, session: { _ in DatabaseSession(profile: c.agentProfile, driver: driver) }, isOpen: { _ in true }, openUI: { _, _, _ in })
        let svc = MCPService(backend)
        let (ct, st) = await InMemoryTransport.createConnectedPair()
        try await svc.start(transport: st)
        let cl = Client(name: "Test Agent", version: "1")
        _ = try await cl.connect(transport: ct)
        let r = try await cl.callTool(name: "query.run", arguments: ["connection": "analytics", "sql": "select 1"])
        let text = r.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
        yes(text.hasPrefix("BLOCKED_BY_PROD_GUARD (no plan"), text)
        await cl.disconnect()
    }

    func testRejectCarriesTheNote() async throws {
        async let r = call("connections.add", addArgs)
        try await decide("credentials", "rejected", merge: #"{"note":"use the replica"}"#)
        let (t, err) = try await r
        yes(err); same(t, "REJECTED (use the replica)")
        same(try raw("SELECT status FROM activity WHERE tool = 'connections.add'")[0][0] as? String, "denied")
    }

    func testUndecidedApprovalExpires() async throws {
        try store.setSetting("approval_ttl_s", json: "1")
        let t0 = Date()
        let (t, err) = try await call("connections.add", addArgs)
        yes(err); same(t, "NEEDS_APPROVAL_TIMEOUT (no decision in DBMan; ask again)")
        yes(Date().timeIntervalSince(t0) >= 1)
        same(try raw("SELECT status FROM approvals")[0][0] as? String, "expired")
        same(try store.pendingApprovals().count, 0)
    }

    func testRemoveWaitsThenRemoves() async throws {
        async let r = call("connections.remove", ["connection": "shop"])
        try await decide("remove", "approved")
        let (t, err) = try await r
        no(err, t); same(t, #"{"removed":"shop"}"#)
        same(try store.connections().map(\.name), ["analytics", "DBMan // internal"])
        same(try raw("SELECT status FROM activity WHERE tool = 'connections.remove'")[0][0] as? String, "ok") // row survives the connection
    }

    func testAllowOnceIsOneRetryOfTheSameStatement() async throws {
        try store.setSetting("prod_guard_rows", json: "1000")
        let sql = "select * from events where kind = 'k1'", other = "select * from events where kind = 'k2'"
        func run(_ s: String) async throws -> (text: String, isError: Bool) { try await call("query.run", ["connection": "analytics", "sql": .string(s)]) }
        let first = try await run(sql)
        yes(first.isError); yes(first.text.hasPrefix("BLOCKED_BY_PROD_GUARD (seq scan on events, 1,200 rows;") && first.text.contains("retry this exact statement"), first.text)
        yes(try await run(sql).isError) // asking again does not add a second row
        same(try store.pendingApprovals().map(\.kind), ["prod_guard"])
        same(try store.pendingApprovals()[0].field("sql"), sql)
        try await decide("prod_guard", "approved", merge: #"{"action":"allow_once"}"#)
        yes(try await run(other).isError) // a different statement is still blocked
        let ok = try await run("select  * from events where kind = 'k1' ;") // same statement, whitespace and ; aside
        no(ok.isError, ok.text); yes(ok.text.contains("\"rows\""))
        yes(try await run(sql).isError) // spent
        same(try raw("SELECT status FROM approvals WHERE json_extract(payload, '$.sql') LIKE '%k1%' ORDER BY created_at").map { $0[0] as? String }, ["consumed", "pending"])
    }

    func testPausedAgentsGetAppLocked() async throws {
        try store.setSetting("agents_paused", json: "true")
        for tool in ["connections.list", "schema.tables"] {
            let (t, err) = try await call(tool, ["connection": "shop"])
            yes(err); same(t, "APP_LOCKED (paused by user)")
        }
        try store.setSetting("agents_paused", json: "false")
        no(try await call("connections.list").isError)
    }

    // MARK: activity

    func testActivityRows() async throws {
        _ = try await call("connections.list")
        _ = try await call("query.run", ["connection": "shop", "sql": "select id from events where id <= 4"])
        _ = try await call("query.run", ["connection": "shop", "sql": "insert into orders values (9,9,9)"])
        _ = try await call("query.run", ["connection": "internal", "sql": "select 1"])
        _ = try await call("query.run", ["connection": "shop", "sql": "select nope from nowhere"])
        _ = try await call("query.run", ["connection": "shop", "sql": .string("select '" + String(repeating: "x", count: 300) + "'")])
        let rows = try raw("SELECT agent_id, connection_id, tool, ms, \"rows\", status, error, length(args_summary) FROM activity ORDER BY id")
        same(rows.map { "\($0[2]!):\($0[5]!)" }, ["connections.list:ok", "query.run:ok", "query.run:blocked", "query.run:denied", "query.run:error", "query.run:ok"])
        same(rows[1][0] as? String, "test-agent"); same(rows[1][1] as? String, "c-shop"); same(rows[1][4] as? Int64, 4)
        XCTAssertNotNil(rows[1][3]); yes((rows[4][6] as! String).hasPrefix("QUERY_FAILED"))
        yes(rows.allSatisfy { ($0[7] as! Int64) <= 120 })
    }

    func testActivityPrune() throws {
        try store.logActivity(agent: nil, connection: nil, tool: "old", args: "", ms: 1, rows: nil, status: "ok", error: nil)
        try Handle(path: store.url.path).exec("UPDATE activity SET ts = ts - 31 * 86400000")
        try store.logActivity(agent: nil, connection: nil, tool: "new", args: "", ms: 1, rows: nil, status: "ok", error: nil)
        try store.pruneActivity()
        same(try raw("SELECT tool FROM activity").map { $0[0] as! String }, ["new"])
    }

    // MARK: socket

    func testSocketPathFallsBackWhenTooLong() {
        same(UnixSocket.path(storeDir: "/Users/a/Library/Application Support/DBMan"), "/Users/a/Library/Application Support/DBMan/mcp.sock")
        let long = "/private/tmp/" + String(repeating: "deep/", count: 30)
        let p = UnixSocket.path(storeDir: long)
        XCTAssertLessThan(p.utf8.count, 104)
        same(p, UnixSocket.path(storeDir: long)) // both sides compute the same path
        XCTAssertNotEqual(p, UnixSocket.path(storeDir: long + "x"))
    }

    func testListenerSpeaksMCPOverTheSocket() async throws {
        let path = UnixSocket.path(storeDir: dir.path)
        let l = MCPListener(service: service, path: path)
        try l.start(); defer { l.stop() }
        XCTAssertThrowsError(try UnixSocket.listen(path)) // a second DBMan must not steal the socket
        let fd = try XCTUnwrap(UnixSocket.connect(path))
        defer { close(fd) }
        let init_ = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"socket-test","version":"0"}}}"# + "\n"
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
        _ = init_.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        yes(String(decoding: buf[..<n], as: UTF8.self).contains(#""name":"dbman""#))
        _ = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.appending("\n").withCString { write(fd, $0, strlen($0)) }
        _ = list.withCString { write(fd, $0, strlen($0)) }
        var all = ""
        while !all.contains("ui.open") { let m = read(fd, &buf, buf.count); if m <= 0 { break }; all += String(decoding: buf[..<m], as: UTF8.self) }
        yes(all.contains("query.run"))
        same(try raw("SELECT id FROM agents WHERE id = 'socket-test'").count, 1)
    }
}
