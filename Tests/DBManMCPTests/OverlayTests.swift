import DBCore
import MCP
import XCTest
@testable import DBManMCP
@testable import DBStore

/// P3 overlay engine through the MCP surface (same fixture as DBManMCPTests: shop.sqlite with customers/orders/events).
extension DBManMCPTests {
    var shop: [String: Value] { ["connection": "shop"] }
    func args(_ more: [String: Value]) -> [String: Value] { shop.merging(more) { $1 } }
    func rowsOf(_ r: [String: Any]) -> [String] { (r["rows"] as! [[Any]]).map { $0.map { "\($0)" }.joined(separator: ":") } }
    /// A write straight into the database file, as another writer would.
    func dbWrite(_ sql: String) async throws {
        let db = try SQLiteDriver(path: dbPath, readOnly: false)
        _ = try await db.execute(sql); await db.close()
    }
    var threeRows: [String: Value] {
        args(["table": "orders", "patches": [["op": "update", "pk": ["id": 1], "values": ["total": 99.5, "customer_id": 2]],
                                              ["op": "insert", "pk": ["id": 10], "values": ["customer_id": 3, "total": 5]],
                                              ["op": "delete", "pk": ["id": 3]]]])
    }

    // MARK: redaction bypass (P1 review)

    func testRedactionBypassesAreClosed() async throws {
        let leaks = ["ada@example.com", "alan@example.com", "grace@example.com"]
        for sql in ["select email as e from customers", "select lower(email) from customers", "select email || '' from customers", "select \"email\" x from customers",
                    "select e from (select email as e from customers)", "with t as (select email e from customers) select e from t", "select c.email e from customers c",
                    "select substr(email, 1) s, city from customers where id = 1", "select email from customers union select 'x'"] {
            let (t, err) = try await call("query.run", args(["sql": .string(sql)]))
            no(err, t)
            for l in leaks { no(t.contains(l), "\(sql) leaked \(l)") }
        }
        // plain non-hidden columns and numbers survive, even next to a hidden reference
        let t = try await golden("query.run", args(["sql": "select id, city from customers where email like 'ada%'"]))
        same(t, #"{"columns":["id","city"],"rows":[[1,"London"]],"truncated":false}"#)
        let agg = try await golden("query.run", args(["sql": "select count(email) c, count(distinct email) d from customers"]))
        yes(agg.contains("[[3,3]]"), agg)
        // a literal or a comment that merely says "email" is not a reference
        yes(try await golden("query.run", args(["sql": "select city, 'email' k from customers where id = 1 -- email"])).contains(#"["London","email"]"#))
        // SELECT * keeps the name match
        yes(try await golden("query.run", args(["sql": "select * from customers where id = 1"])).contains(#"[1,"«redacted»","«redacted»","London"]"#))
        yes(try await golden("query.sample", args(["table": "customers", "n": 1])).contains("«redacted»"))
    }

    func testRulesRedactUnit() {
        let rows: [[Cell]] = [[.integer(1), .text("a@b.c"), .text("x")]]
        let hid: Set = ["email"]
        func r(_ sql: String, _ cols: [String]) -> [[Cell]] { Rules.redact(sql: sql, columns: cols, rows: Array(rows.map { Array($0.prefix(cols.count)) }), hidden: hid) }
        same(r("select id, email, city from t", ["id", "email", "city"])[0], [.integer(1), Rules.redacted, .text("x")])
        same(r("select id, email as e, city from t", ["id", "e", "city"])[0], [.integer(1), Rules.redacted, .text("x")])
        same(r("select id, city from t where email = 'q'", ["id", "city"])[0], [.integer(1), .text("a@b.c")]) // both plain: allowed
        same(r("select length(email) from t", ["length(email)"])[0], [.integer(1)]) // numbers pass
        same(r("select 1 x from t where email is not null", ["x"])[0], [.integer(1)])
        same(r("select * from t", ["id", "email", "city"])[0], [.integer(1), Rules.redacted, .text("x")])
    }

    // MARK: patches: record → merge → stale → permission

    func testPatchThreeRowsAndQueryMerges() async throws {
        let ok = try await json("overlay.patch_rows", threeRows)
        same(ok["patched"] as? Int, 3); same(ok["layer"] as? String, "Test Agent")
        same(try raw("SELECT id, owner, agent_id, name FROM layers WHERE owner = 'agent'").map { $0.map { "\($0!)" } }, [["agent:test-agent:c-shop", "agent", "test-agent", "Test Agent"]])
        same(try raw("SELECT op, table_name, json_extract(pk, '$.id') FROM row_patches ORDER BY rowid").map { "\($0[0]!) \($0[2]!)" }, ["update 1", "insert 10", "delete 3"])
        // merged: update applied (real column), delete hidden, insert appended on the plain end of the table
        let all = try await json("query.run", args(["sql": "select * from orders"]))
        same(rowsOf(all), ["1:2:99.5", "2:1:20", "10:3:5"])
        same(all["overlay"] as? String, "applied (3 patches)")
        // ORDER BY: updates and deletes still apply, inserts are not guessed into an ordered result
        let ordered = try await json("query.run", args(["sql": "select id, total from orders order by id"]))
        same(rowsOf(ordered), ["1:99.5", "2:20"])
        // the database itself never changed
        same(try await dbRows("select id, total from orders order by id"), ["1:10.50", "2:20.00", "3:7.25"])
        // the primary key must be selected, joins are not guessed
        same(try await json("query.run", args(["sql": "select total from orders"]))["overlay"] as? String, "not applied (primary key not selected)")
        same(try await json("query.run", args(["sql": "select o.id, c.city from orders o join customers c on c.id = o.customer_id"]))["overlay"] as? String, "not applied (join)")
        same(try await json("query.run", args(["sql": "select id from customers"]))["overlay"] as? String, nil) // no patches on that table: nothing to say
        // layer narrows: database / mine see no agent patches
        same(rowsOf(try await json("query.run", args(["sql": "select * from orders", "layer": "database"]))).count, 3)
        same(try await call("query.run", args(["sql": "select 1", "layer": "codex"])).text, "INVALID_ARGUMENT (layer must be database or mine)")
        // a second patch of the same row folds into the first (before keeps the original value)
        _ = try await json("overlay.patch_rows", args(["table": "orders", "patches": [["op": "update", "pk": ["id": 1], "values": ["total": 11]]]]))
        let d = try await json("overlay.diff", args(["table": "orders"]))
        let p = (d["patches"] as! [[String: Any]]).first { ($0["pk"] as! [String: Any])["id"] as? Int == 1 }!
        same((p["before"] as! [String: Any])["total"] as? Double, 10.5); same((p["after"] as! [String: Any])["total"] as? Int, 11); same((p["after"] as! [String: Any])["customer_id"] as? Int, 2)
        same(try raw("SELECT count(*) FROM row_patches WHERE json_extract(pk, '$.id') = 1")[0][0] as? Int64, 1)
    }

    func dbRows(_ sql: String) async throws -> [String] {
        let db = try SQLiteDriver(path: dbPath, readOnly: true)
        defer { Task { await db.close() } }
        return try await db.execute(sql).rows.map { $0.map(\.display).joined(separator: ":") }
    }

    func testPatchValidation() async throws {
        func fails(_ patches: Value, _ prefix: String, table: String = "orders") async throws {
            let (t, err) = try await call("overlay.patch_rows", args(["table": .string(table), "patches": patches]))
            yes(err); yes(t.hasPrefix(prefix), t)
        }
        try await fails([["op": "update", "pk": ["id": 99], "values": ["total": 1]]], "NOT_FOUND (patch 0: no row")
        try await fails([["op": "insert", "pk": ["id": 1], "values": ["total": 1]]], "INVALID_ARGUMENT (patch 0: row 1 already exists")
        try await fails([["op": "update", "pk": ["id": 1], "values": ["nope": 1]]], "NOT_FOUND (patch 0: column")
        try await fails([["op": "update", "pk": ["id": 1], "values": ["id": 5]]], "INVALID_ARGUMENT (patch 0: update needs values and cannot change the primary key")
        try await fails([["op": "update", "pk": ["customer_id": 1], "values": ["total": 1]]], "INVALID_ARGUMENT (patch 0: pk must be exactly id")
        try await fails([["op": "drop", "pk": ["id": 1]]], "INVALID_ARGUMENT (patch 0: op must be")
        try await fails([], "INVALID_ARGUMENT (patches must hold")
        same(try raw("SELECT count(*) FROM overlay_items WHERE kind <> 'dashboard'")[0][0] as? Int64, 0) // all-or-nothing is per call: nothing was written
    }

    func testStaleWhenTheDatabaseMovesOn() async throws {
        _ = try await json("overlay.patch_rows", threeRows)
        same(((try await json("overlay.status", shop))["stale"] as! [Any]).count, 0)
        try await dbWrite("UPDATE orders SET total = 500 WHERE id = 1; DELETE FROM orders WHERE id = 3; INSERT INTO orders VALUES (10, 1, 1)")
        let st = try await json("overlay.status", shop)
        same((st["stale"] as! [Any]).count, 3) // updated row changed, deleted row vanished, inserted key now exists
        same(try raw("SELECT status, count(*) FROM overlay_items WHERE kind <> 'dashboard' GROUP BY status").map { "\($0[0]!) \($0[1]!)" }, ["stale 3"])
        let d = try await json("overlay.diff", args(["table": "orders"]))
        let up = (d["patches"] as! [[String: Any]]).first { $0["op"] as? String == "update" }!
        same(up["status"] as? String, "stale")
        same((up["before"] as! [String: Any])["total"] as? Double, 10.5); same((up["after"] as! [String: Any])["total"] as? Double, 99.5) // both values …
        same((up["database_now"] as! [String: Any])["total"] as? Int, 500)                                                            // … and the database's
        yes(((d["patches"] as! [[String: Any]]).first { $0["op"] as? String == "delete" }!["database_now"] as? String)?.contains("no longer exists") == true)
        // the database going back to the base row clears it
        try await dbWrite("UPDATE orders SET total = 10.5 WHERE id = 1")
        _ = try await json("overlay.status", shop)
        same(try raw("SELECT status FROM overlay_items i JOIN row_patches p ON p.item_id = i.id WHERE p.op = 'update'")[0][0] as? String, "active")
    }

    func testOverlayNeedsOverlayPermission() async throws {
        _ = try await call("connections.list")
        try Handle(path: store.url.path).exec("UPDATE permissions SET level = 'read' WHERE connection_id = 'c-shop'")
        for (tool, extra) in [("overlay.patch_rows", threeRows), ("views.create", args(["name": "v", "sql": "select 1"])), ("notes.set", args(["table": "orders", "text": "x"])),
                              ("relations.add", args(["from": "orders.customer_id", "to": "customers.id"])), ("saved.save", args(["name": "q", "sql": "select 1"])), ("overlay.reset", shop)] {
            let (t, err) = try await call(tool, extra)
            yes(err); same(t, "PERMISSION_DENIED (READ on shop; needs OVERLAY)")
        }
        same(try raw("SELECT count(*) FROM layers WHERE owner = 'agent'")[0][0] as? Int64, 0) // a denied call never creates the layer
        for tool in ["overlay.status", "overlay.diff", "views.list", "saved.list"] { no(try await call(tool, shop).isError, tool) }
        same(try raw("SELECT status FROM activity WHERE tool = 'overlay.patch_rows'")[0][0] as? String, "denied")
        // restored to OVERLAY it works, and the activity row says overlay
        try Handle(path: store.url.path).exec("UPDATE permissions SET level = 'overlay' WHERE connection_id = 'c-shop'")
        _ = try await json("overlay.patch_rows", threeRows)
        same(try raw("SELECT status FROM activity WHERE tool = 'overlay.patch_rows' ORDER BY id DESC")[0][0] as? String, "overlay")
        // production defaults to READ: no overlay there
        let (t, _) = try await call("overlay.patch_rows", threeRows.merging(["connection": "analytics"]) { $1 })
        same(t, "PERMISSION_DENIED (READ on analytics; needs OVERLAY)")
    }

    func testDiffMasksHiddenColumns() async throws {
        _ = try await call("schema.tables", shop) // marks name/email hidden
        _ = try await json("overlay.patch_rows", args(["table": "customers", "patches": [["op": "update", "pk": ["id": 1], "values": ["email": "new@x.org", "city": "Paris"]]]]))
        let d = try await call("overlay.diff", shop).text
        no(d.contains("ada@example.com") || d.contains("new@x.org"), d)
        yes(d.contains(#""city":"Paris""#) && d.contains("«redacted»"), d)
        // and the human's merged view of the agent's own patch is redacted too
        no(try await call("query.run", args(["sql": "select * from customers"])).text.contains("new@x.org"))
    }

    // MARK: virtual views

    func testViewsExpandAsCTEs() async throws {
        let ok = try await json("views.create", args(["name": "big_orders", "sql": "select id, total from orders where total > 8"]))
        same(ok["view"] as? String, "big_orders")
        same(try await json("query.run", args(["sql": "select id from big_orders order by id"]))["views"] as? [String], ["big_orders"])
        same(rowsOf(try await json("query.run", args(["sql": "select count(*) from big_orders"]))), ["2"])
        // a view on a view, and an existing WITH of the statement's own
        _ = try await json("views.create", args(["name": "biggest", "sql": "select max(total) m from big_orders"]))
        same(rowsOf(try await json("query.run", args(["sql": "with x as (select 1 one) select m, one from biggest, x"]))), ["20:1"])
        // shadowing: a CTE of the same name wins over the view
        same(rowsOf(try await json("query.run", args(["sql": "with big_orders as (select 7 id, 7 total) select count(*) from big_orders"]))), ["1"])
        // errors: replace/create rules, real table names, bad SQL, writes
        yes(try await call("views.create", args(["name": "big_orders", "sql": "select 1"])).text.hasPrefix("ALREADY_EXISTS"))
        yes(try await call("views.replace", args(["name": "nope", "sql": "select 1"])).text.hasPrefix("NOT_FOUND"))
        same(try await call("views.create", args(["name": "orders", "sql": "select 1"])).text, #"NAME_TAKEN ("orders" is a real table or view in shop; pick another name)"#)
        yes(try await call("views.create", args(["name": "bad", "sql": "select * from nowhere"])).text.hasPrefix("INVALID_VIEW"))
        yes(try await call("views.create", args(["name": "w", "sql": "delete from orders"])).text.hasPrefix("WRITE_REDIRECTED"))
        same(try await call("views.create", args(["name": "1x", "sql": "select 1"])).text, "INVALID_ARGUMENT (name must be a plain identifier)")
        // replace changes the result; list shows layer and ownership; the view is virtual: nothing in the database
        _ = try await json("views.replace", args(["name": "big_orders", "sql": "select id, total from orders where total > 15"]))
        same(rowsOf(try await json("query.run", args(["sql": "select count(*) from big_orders"]))), ["1"])
        let list = try await call("views.list", shop).text
        yes(list.contains(#""layer":"Test Agent""#) && list.contains(#""own":true"#), list)
        same(try await dbRows("select count(*) from sqlite_master where type = 'view'"), ["0"])
        // a view over hidden columns cannot launder them
        _ = try await json("views.create", args(["name": "mails", "sql": "select email as e from customers"]))
        no(try await call("query.run", args(["sql": "select e from mails"])).text.contains("@example.com"))
        // a view whose columns it later loses fails loudly rather than silently; drop removes it
        same(try await json("views.drop", args(["name": "mails"]))["dropped"] as? String, "mails")
        yes(try await call("query.run", args(["sql": "select e from mails"])).isError)
        // MINE views are visible to the agent; the agent's own layer shadows a same-named one in MINE
        let mine = Store.mineID("c-shop")
        try store.addItem(layer: mine, kind: "view", name: "big_orders", payload: OverlayEngine.payload(sql: "select 0 id, 0 total"))
        same(rowsOf(try await json("query.run", args(["sql": "select id from big_orders"]))), ["2"]) // own total > 15 beats MINE's constant row
        try store.addItem(layer: mine, kind: "view", name: "only_mine", payload: OverlayEngine.payload(sql: "select 41 + 1 answer"))
        same(rowsOf(try await json("query.run", args(["sql": "select answer from only_mine"]))), ["42"])
        same(rowsOf(try await json("query.run", args(["sql": "select id from big_orders", "layer": "mine"]))), ["0"]) // narrowing to MINE drops the agent's shadow
    }

    func testRelationsNotesSavedAndStatus() async throws {
        same(try await json("overlay.status", shop)["layer"] is NSNull, true)
        _ = try await json("relations.add", args(["from": "events.n", "to": "customers.id"]))
        yes(try await call("relations.add", args(["from": "events.zip", "to": "customers.id"])).text.hasPrefix("NOT_FOUND"))
        _ = try await json("notes.set", args(["table": "orders", "column": "total", "text": "gross, tax included"]))
        _ = try await json("notes.set", args(["table": "orders", "text": "one row per checkout"]))
        _ = try await json("saved.save", args(["name": "revenue", "sql": "select sum(total) from orders"]))
        same(try store.relations("c-shop").count, 1) // the P5 reader sees an agent's relation (layer visible)
        yes(try store.relations("c-shop")[0].contains(#""from_table":"events""#))
        same(OverlayEngine.notes(try store.items("c-shop", kind: "note")), ["orders.total": "gross, tax included", "orders": "one row per checkout"])
        yes(try await call("saved.list", shop).text.contains(#""name":"revenue""#))
        let st = try await json("overlay.status", shop)
        same(st["layer"] as? String, "Test Agent"); same(st["items"] as? Int, 4)
        same((st["counts"] as! [String: Int])["note"], 2)
        XCTAssertNotNil(st["last_activity"])
        _ = try await json("notes.set", args(["table": "orders", "text": ""])) // empty text removes
        same(OverlayEngine.notes(try store.items("c-shop", kind: "note")).keys.sorted(), ["orders.total"])
        same(try await json("overlay.reset", shop)["discarded"] as? Int, 3)
        same(try await json("overlay.status", shop)["items"] as? Int, 0)
        same(try raw("SELECT count(*) FROM overlay_items WHERE status = 'discarded'")[0][0] as? Int64, 4) // history stays
    }

    // MARK: human actions: adopt, discard (with note)

    func testAdoptAndDiscard() async throws {
        _ = try await json("overlay.patch_rows", threeRows)
        _ = try await json("views.create", args(["name": "v1", "sql": "select 1 one"]))
        let layer = "agent:test-agent:c-shop"
        let items = try store.items("c-shop", layers: [layer])
        let patch = items.first { $0.op == "update" }!, view = items.first { $0.kind == "view" }!
        // adopt one patch and the view: copies into MINE, originals marked adopted, nothing is lost for the agent
        try store.adopt([patch.id, view.id], connection: "c-shop")
        same(try store.items("c-shop", layers: [Store.mineID("c-shop")]).map(\.kind).sorted(), ["row_patch", "view"])
        same(try store.items("c-shop", layers: [layer]).count, 2)
        same(try store.items("c-shop", layers: [layer], statuses: ["adopted"]).count, 2)
        same(rowsOf(try await json("query.run", args(["sql": "select id, total from orders where id = 1"]))), ["1:99.5"])
        same(rowsOf(try await json("query.run", args(["sql": "select * from v1", "layer": "mine"]))), ["1"]) // MINE alone has it now
        // discard the rest with a note: the agent finds it in overlay.status
        try store.discard(layer: layer, note: "too eager: deletes need a ticket")
        let st = try await json("overlay.status", shop)
        same(st["items"] as? Int, 0)
        same((st["discarded"] as! [String: Any])["note"] as? String, "too eager: deletes need a ticket")
        same(rowsOf(try await json("query.run", args(["sql": "select id, total from orders order by id"]))), ["1:99.5", "2:20", "3:7.25"]) // agent's rest is gone, MINE's adopted update stays
        // MINE items are never reachable by the agent's tools: reset only touches its own layer
        _ = try await json("overlay.reset", shop)
        same(try store.items("c-shop", layers: [Store.mineID("c-shop")]).count, 2)
    }

    // MARK: through the stdio helper

    /// Starts the socket listener and the stdio helper against the scratch store, handshakes as `name`, and returns a tool caller. Call `stop` when done.
    func startHelper(agent name: String) throws -> (tool: (String, [String: Any]) throws -> [String: Any], stop: () -> Void) {
        let bundle = Bundle(for: DBManMCPTests.self).bundleURL.deletingLastPathComponent()
        let helper = bundle.appendingPathComponent("dbman-mcp")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "dbman-mcp not built next to the tests")
        let l = MCPListener(service: service, path: UnixSocket.path(storeDir: dir.path))
        try l.start()
        let p = Process(), inp = Pipe(), out = Pipe()
        p.executableURL = helper; p.arguments = ["--stdio"]
        p.environment = ["DBMAN_STORE": store.url.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = inp; p.standardOutput = out
        try p.run()
        func send(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            inp.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data("\n".utf8))
            var buf = Data()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { XCTFail("helper closed"); return [:] }
                buf += chunk
                if let line = buf.split(separator: UInt8(ascii: "\n")).first(where: { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? Int == id }) {
                    return try JSONSerialization.jsonObject(with: line) as! [String: Any]
                }
            }
        }
        _ = try send(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": name, "version": "9"]])
        inp.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n").utf8))
        return ({ tool, a in
            let r = try send(100 + Int.random(in: 0..<9000), "tools/call", ["name": tool, "arguments": a])
            let text = ((r["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? ["text": text]
        }, { p.terminate(); l.stop() })
    }

    func testHelperRoundTripWithScratchStore() async throws {
        let (tool, stop) = try startHelper(agent: "helper-agent"); defer { stop() }
        let patched = try tool("overlay.patch_rows", ["connection": "shop", "table": "orders", "patches": [
            ["op": "update", "pk": ["id": 1], "values": ["total": 1]], ["op": "update", "pk": ["id": 2], "values": ["total": 2]], ["op": "delete", "pk": ["id": 3]]]])
        XCTAssertEqual(patched["patched"] as? Int, 3)
        let r = try tool("query.run", ["connection": "shop", "sql": "select id, total from orders"])
        XCTAssertEqual(rowsOf(r), ["1:1", "2:2"])
        XCTAssertEqual(r["overlay"] as? String, "applied (3 patches)")
        XCTAssertEqual(try raw("SELECT name FROM layers WHERE owner = 'agent'")[0][0] as? String, "helper-agent")
    }
}
