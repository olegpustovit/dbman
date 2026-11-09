import DBCore
import MCP
import XCTest
@testable import DBManMCP
@testable import DBStore

/// P4 through the MCP surface: dashboard.* on the shop.sqlite fixture.
extension DBManMCPTests {
    func widget(_ id: String, _ type: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ q: String, _ enc: Value? = nil) -> Value {
        var o: [String: Value] = ["id": .string(id), "type": .string(type), "title": .string(id.capitalized), "x": .int(x), "y": .int(y), "w": .int(w), "h": .int(h), "query": .string(q)]
        if let enc { o["encoding"] = enc }
        return .object(o)
    }
    /// 8 widgets; "w7" selects a column that does not exist.
    var eightWidgets: Value {
        ["version": 1, "title": "Sales health", "variables": [["name": "status", "type": "enum", "sql": "select distinct kind from events"]],
         "widgets": [
            widget("w1", "kpi", 0, 0, 3, 2, "select sum(total) as value from orders"),
            widget("w2", "kpi", 3, 0, 3, 2, "select count(*) as value from orders"),
            widget("w3", "kpi.spark", 6, 0, 3, 2, "select id as x, total as y, 1 as value from orders", ["x": "x", "y": "y"]),
            widget("w4", "bars.horizontal", 9, 0, 3, 3, "select city as label, count(*) as value from customers group by 1", ["label": "label", "value": "value"]),
            widget("w5", "line", 0, 2, 6, 3, "select id as d, total as t from orders order by 1", ["x": "d", "y": "t"]),
            widget("w6", "table", 6, 3, 6, 3, "select * from orders where :status = 'all' or 1"),
            widget("w7", "kpi", 0, 5, 3, 2, "select sum(total_cents) as value from orders"),
            widget("w8", "status.feed", 3, 5, 3, 4, "select id as ts, kind as title from events limit 5", ["ts": "ts", "title": "title"]),
         ]]
    }

    func testComponentsCatalog() async throws {
        let r = try await json("dashboard.components")
        same((r["catalog"] as! [String: Any]).count, 28)
        for id in ["kpi.target", "gauge", "stat.list", "sparkline.grid", "leaderboard", "donut", "waffle", "status.grid", "progress.list"] {
            yes((r["catalog"] as! [String: Any])[id] != nil, "\(id) is listed for agents")
        }
        yes(String(describing: r["properties"]!).contains("widgets"))
    }

    /// The extended library through MCP: an agent builds a dashboard from every new card; each validates and runs against the fixture.
    func testCreateWithTheExtendedLibrary() async throws {
        let spec: Value = ["version": 1, "title": "Ops board", "widgets": [
            widget("t", "kpi.target", 0, 0, 3, 3, "select sum(total) as value, 100 as target from orders", ["value": "value", "target": "target"]),
            widget("g", "gauge", 3, 0, 3, 3, "select count(*) as value, 10 as max from orders", ["value": "value", "max": "max"]),
            widget("s", "stat.list", 6, 0, 3, 3, "select city as label, count(*) as value, 5.0 as delta from customers group by 1", ["label": "label", "value": "value", "delta": "delta"]),
            widget("l", "leaderboard", 9, 0, 3, 3, "select city as label, count(*) as value from customers group by 1", ["label": "label", "value": "value"]),
            widget("k", "sparkline.grid", 0, 3, 6, 3, "select kind as label, id as x, n as y from events where id < 50", ["label": "label", "x": "x", "y": "y"]),
            widget("d", "donut", 6, 3, 3, 3, "select kind as label, count(*) as value from events group by 1", ["label": "label", "value": "value"]),
            widget("w", "waffle", 9, 3, 3, 3, "select kind as label, count(*) as value from events group by 1", ["label": "label", "value": "value"]),
            widget("h", "status.grid", 0, 6, 4, 3, "select kind as label, count(*) as value, 'ok' as status from events group by 1", ["label": "label", "value": "value", "status": "status"]),
            widget("p", "progress.list", 4, 6, 3, 3, "select city as label, count(*) as value, 3 as max from customers group by 1", ["label": "label", "value": "value", "max": "max"]),
        ]]
        let r = try await json("dashboard.create", args(["spec": spec]))
        same(r["ok"] as? Int, 9); same(r["failed"] as? Int, 0)
        // a missing required encoding is caught for the new types too
        var broken = spec.objectValue!; var ws = broken["widgets"]!.arrayValue!
        ws[1] = widget("g", "gauge", 3, 0, 3, 3, "select count(*) as value from orders", ["value": "value"])
        broken["widgets"] = .array(ws)
        let bad = try await call("dashboard.create", args(["spec": .object(broken)]))
        yes(bad.text.contains("max"), bad.text)
    }

    func testCreateWithOneFailingWidgetThenAdopt() async throws {
        let r = try await json("dashboard.create", args(["spec": eightWidgets]))
        same(r["ok"] as? Int, 7); same(r["failed"] as? Int, 1)
        let ws = r["widgets"] as! [[String: Any]]
        let bad = ws.filter { $0["ok"] as? Bool == false }
        same(bad.map { $0["id"] as! String }, ["w7"])
        yes((bad[0]["error"] as! String).contains("total_cents"), "\(bad[0])")
        same(r["layer"] as? String, "Test Agent")
        // it sits in the agent's layer as an active item; nothing in MINE
        let id = r["id"] as! String
        same(try raw("SELECT l.owner, i.kind, i.status FROM overlay_items i JOIN layers l ON l.id = i.layer_id WHERE i.id = '\(id)'").map { $0.map { "\($0!)" } }[0], ["agent", "dashboard", "active"])
        same(try store.items("c-shop", layers: ["mine:c-shop"], kind: "dashboard").count, 0)
        // readable by the agent: list, get, resource
        same((try await json("dashboard.get", ["id": .string(id)])["spec"] as! [String: Any])["connection"] as? String, "shop") // no connection argument needed
        let list = try await call("dashboard.list", shop)
        yes(list.text.contains(id) && list.text.contains(#""own":true"#))
        yes(try await client.readResource(uri: "dbman://dashboards/\(id)").first?.text?.contains("Sales health") == true)
        // the human adopts 7 of 8 into MINE; the proposal is marked adopted
        var spec = try DashboardSpec.parse(try store.items("c-shop", kind: "dashboard")[0].payload)
        spec.widgets.removeAll { $0.id == "w7" }
        try store.addItem(layer: "mine:c-shop", kind: "dashboard", name: spec.title, payload: spec.json())
        try store.setStatus([id], "adopted")
        let mineItems = try store.items("c-shop", layers: ["mine:c-shop"], kind: "dashboard")
        same(mineItems.count, 1)
        same(try DashboardSpec.parse(mineItems[0].payload).widgets.count, 7)
        same(try store.items("c-shop", layers: [], kind: "dashboard").filter { $0.layer != "mine:c-shop" }.count, 0)
        same(try raw("SELECT count(*) FROM v_dashboard_widgets WHERE dashboard_id = '\(mineItems[0].id)'")[0][0] as? Int64, 7)
        // the agent now sees the human's dashboard, read-only
        let denied = try await call("dashboard.update", ["id": .string(mineItems[0].id), "ops": [["op": "replace", "path": "/title", "value": "x"]]])
        yes(denied.isError && denied.text.hasPrefix("PERMISSION_DENIED"), denied.text)
    }

    func testRedactionAndProdGuardApplyToWidgetQueries() async throws {
        // hidden column values never leave: the widget runs but the tool reply carries no rows at all
        let spec: Value = ["title": "t", "widgets": [widget("a", "table", 0, 0, 4, 3, "select email from customers")]]
        let r = try await json("dashboard.create", args(["spec": spec]))
        same(r["ok"] as? Int, 1)
        yes(!String(describing: r).contains("ada@example.com"))
        // production is READ for agents: creating there needs OVERLAY
        let t = try await call("dashboard.create", ["connection": "analytics", "spec": spec])
        yes(t.isError && t.text.hasPrefix("PERMISSION_DENIED"), t.text)
        // the prod guard blocks a seq scan widget (rows threshold lowered) when the human opted the agent into OVERLAY on production
        try store.setPermission(agent: "test-agent", connection: "c-prod", level: "overlay")
        try store.setSetting("prod_guard_rows", json: "1000")
        let big: Value = ["title": "t", "widgets": [widget("a", "table", 0, 0, 4, 3, "select * from events where kind = 'k1'")]]
        let g = try await json("dashboard.create", ["connection": "analytics", "spec": big])
        same(g["failed"] as? Int, 1)
        yes(String(describing: g["widgets"]!).contains("BLOCKED_BY_PROD_GUARD"), "\(g)")
    }

    func testRejectsBadSpecsAndUpdatesWithPatch() async throws {
        func create(_ s: Value) async throws -> (text: String, isError: Bool) { try await call("dashboard.create", args(["spec": s])) }
        let overlap: Value = ["title": "t", "widgets": [widget("a", "kpi", 0, 0, 3, 2, "select 1 as value"), widget("b", "kpi", 2, 1, 3, 2, "select 1 as value")]]
        var t = try await create(overlap); yes(t.isError && t.text.contains("overlaps b"), t.text)
        let wide: Value = ["title": "t", "widgets": [widget("a", "kpi", 10, 0, 4, 2, "select 1 as value")]]
        t = try await create(wide); yes(t.isError && t.text.contains("12-column"), t.text)
        t = try await create(["title": "t", "widgets": [["id": "a", "type": "text", "title": "x", "x": 0, "y": 0, "w": 2, "h": 1, "html": "<b/>"]]]); yes(t.isError && t.text.hasPrefix("INVALID_SPEC"), t.text)
        t = try await create(["title": "t", "widgets": []]); yes(t.isError, t.text)
        same(try store.items("c-shop", kind: "dashboard").count, 0)
        // per-widget problems are not fatal: they arrive in alert state
        let soft: Value = ["title": "t", "widgets": [widget("a", "pie", 0, 0, 3, 3, "select 1"), widget("b", "line", 3, 0, 4, 3, "select 1 as a")]]
        let r = try await json("dashboard.create", args(["spec": soft]))
        same(r["failed"] as? Int, 2)
        yes(String(describing: r["widgets"]!).contains("unknown type") && String(describing: r["widgets"]!).contains("missing encoding"))
        // update by JSON patch re-validates and re-runs; the id stays
        let id = r["id"] as! String
        let u = try await json("dashboard.update", ["id": .string(id), "ops": [["op": "remove", "path": "/widgets/0"],
                                                                          ["op": "add", "path": "/widgets/0/encoding", "value": ["x": "a", "y": "a"]]]])
        same(u["id"] as? String, id); same(u["failed"] as? Int, 0)
        same(try store.items("c-shop", kind: "dashboard").count, 1)
        let bad = try await call("dashboard.update", ["id": .string(id), "ops": [["op": "replace", "path": "/widgets/0/x", "value": 11]]])
        yes(bad.isError && bad.text.contains("12-column"), bad.text)
        same(try DashboardSpec.parse(try store.items("c-shop", kind: "dashboard")[0].payload).widgets[0].x, 3) // a rejected patch changes nothing
        let gone = try await call("dashboard.update", ["id": .string(id), "ops": [["op": "move", "path": "/x"]]]); yes(gone.isError && gone.text.hasPrefix("INVALID_PATCH"), gone.text)
    }

    /// The whole path an agent takes: stdio helper -> socket -> service -> store; 8 widgets, one fails on a drifted column.
    func testDashboardCreateThroughTheHelper() async throws {
        let (tool, stop) = try startHelper(agent: "helper-agent"); defer { stop() }
        let cat = try tool("dashboard.components", [:])
        XCTAssertEqual((cat["catalog"] as? [String: Any])?.count, 28)
        let spec = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(eightWidgets))
        let r = try tool("dashboard.create", ["connection": "shop", "spec": spec])
        XCTAssertEqual(r["ok"] as? Int, 7); XCTAssertEqual(r["failed"] as? Int, 1)
        let bad = (r["widgets"] as! [[String: Any]]).filter { $0["ok"] as? Bool == false }
        XCTAssertEqual(bad.map { $0["id"] as? String }, ["w7"])
        XCTAssertTrue((bad[0]["error"] as? String ?? "").contains("total_cents"))
        XCTAssertEqual(try raw("SELECT l.name, i.status FROM overlay_items i JOIN layers l ON l.id = i.layer_id WHERE i.kind = 'dashboard' AND l.owner = 'agent'").map { $0.map { "\($0!)" } }, [["helper-agent", "active"]])
        let fixed = try tool("dashboard.update", ["id": r["id"]!, "ops": [["op": "replace", "path": "/widgets/6/query", "value": "select sum(total) as value from orders"]]])
        XCTAssertEqual(fixed["failed"] as? Int, 0)
    }

    func testInternalStoreSeedsAgentActivity() throws {
        let items = try store.items(Store.internalID, kind: "dashboard")
        same(items.map(\.name), ["Agent activity"])
        let spec = try DashboardSpec.parse(items[0].payload)
        same(spec.widgets.count, 8)
        same(spec.validate(), [])
        same(try raw("SELECT count(*) FROM v_dashboard_widgets WHERE dashboard = 'Agent activity'")[0][0] as? Int64, 8)
        same(try store.agentVisibleConnections().map(\.name), ["shop", "analytics"]) // still invisible to agents
        // every widget query runs against the store file
        let h = try Handle(path: store.url.path)
        for w in spec.widgets {
            let sql = DashSQL.bind(w.query!, variables: spec.variables, engine: .sqlite)
            do { _ = try h.query(sql) } catch { XCTFail("\(w.id): \(error)") }
        }
    }
}
