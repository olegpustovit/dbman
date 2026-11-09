import XCTest
@testable import DBCore

final class DashboardTests: XCTestCase {
    private func w(_ id: String, _ type: String = "kpi", x: Int = 0, y: Int = 0, w: Int = 3, h: Int = 2, enc: [String: DashEnc]? = nil) -> DashWidget {
        DashWidget(id: id, type: type, title: id, x: x, y: y, w: w, h: h, query: "select 1 as value", encoding: enc)
    }
    private func spec(_ ws: [DashWidget]) -> DashboardSpec { DashboardSpec(title: "T", widgets: ws) }
    private func issues(_ ws: [DashWidget]) -> [String] { spec(ws).validate().map { ($0.widget ?? "-") + ": " + $0.message } }

    func testCatalogHas19TypesIn7Groups() {
        XCTAssertEqual(DashCatalog.types.count, 19)
        XCTAssertEqual(Set(DashCatalog.types.map(\.group)), Set(DashCatalog.groups))
        let json = try! JSONSerialization.jsonObject(with: DashCatalog.schemaJSON()) as! [String: Any]
        XCTAssertEqual((json["catalog"] as! [String: Any]).count, 19)
    }

    func testValidSpecFromTheSpecDocument() throws {
        let json = #"{"version":1,"title":"Revenue","connection":"shop","variables":[{"name":"range","type":"timeRange","default":"30d"},{"name":"status","type":"enum","sql":"select distinct status from orders"}],"refresh":"1m","widgets":[{"id":"w1","type":"kpi","title":"Revenue","x":0,"y":0,"w":3,"h":2,"query":"select sum(total) as value from orders where created_at > now() - :range","format":{"unit":"USD","compact":true},"compare":"previous_period"}]}"#
        let s = try DashboardSpec.parse(json)
        XCTAssertEqual(s.validate(), [])
        XCTAssertEqual(try DashboardSpec.parse(s.json()), s)
    }

    func testTypesAndEncodings() {
        XCTAssertTrue(issues([w("a", "pie")]).contains { $0.contains("unknown type") })
        XCTAssertTrue(issues([w("a", "line", w: 4, h: 3)]).contains { $0.contains("missing encoding \"x\"") && $0.contains("missing encoding") })
        XCTAssertEqual(issues([w("a", "line", w: 4, h: 3, enc: ["x": DashEnc("d"), "y": DashEnc(["a", "b"])])]), [])
        XCTAssertEqual(issues([w("a", "kpi")]), [], "kpi reads a column named value by default")
        XCTAssertTrue(issues([w("a", "kpi", w: 1)]).contains { $0.contains("at least 2x2") })
        var bad = w("a"); bad.query = "delete from orders"
        XCTAssertTrue(issues([bad]).contains { $0.contains("read-only") })
        var noQ = w("a"); noQ.query = nil
        XCTAssertTrue(issues([noQ]).contains { $0.contains("query is required") })
        var text = w("t", "text", w: 2, h: 1, enc: ["markdown": DashEnc("# hi")]); text.query = nil
        XCTAssertEqual(issues([text]), [])
        XCTAssertThrowsError(try DashboardSpec.parse(#"{"title":"x","widgets":[{"id":"a","type":"text","title":"t","x":0,"y":0,"w":2,"h":1,"html":"<b>"}]}"#))
    }

    func testBoundsAndOverlapAreFatal() {
        let all = spec([w("a", x: 10, w: 3), w("b", x: 0), w("c", x: 1, y: 1)]).validate()
        XCTAssertTrue(all.contains { $0.widget == "a" && $0.message.contains("12-column") && $0.fatal })
        XCTAssertTrue(all.contains { $0.widget == "b" && $0.message == "overlaps c" && $0.fatal })
        XCTAssertEqual(issues([w("a", x: 9), w("b", x: 0, y: 2), w("c", x: 3, y: 0)]), [], "touching edges are fine")
        XCTAssertTrue(spec([w("a"), w("a", x: 6)]).validate().contains { $0.message.contains("unique") })
    }

    func testVariableBindingIsSafe() {
        let vars = [DashVariable(name: "range", type: "timeRange", default: "30d"), DashVariable(name: "status", type: "enum")]
        let sql = "select 1 from o where t > now() - :range and s = :status and x::int = 1 and note = ':status' -- :range\n and \":status\" = 2"
        let pg = DashSQL.bind(sql, variables: vars, values: ["range": "24h", "status": "paid"], engine: .postgres)
        XCTAssertEqual(pg, "select 1 from o where t > now() - interval '24 hours' and s = 'paid' and x::int = 1 and note = ':status' -- :range\n and \":status\" = 2")
        XCTAssertTrue(DashSQL.bind("datetime('now', :range)", variables: vars, engine: .sqlite).contains("'-30 days'"))
        XCTAssertTrue(DashSQL.bind("now() - :range", variables: vars, values: ["range": "2w"], engine: .mysql).contains("INTERVAL 2 WEEK"))
        // hostile values become one quoted string, never SQL, never an identifier
        let evil = "x'; DROP TABLE orders; --"
        XCTAssertEqual(DashSQL.bind(":status", variables: vars, values: ["status": evil], engine: .postgres), "'x''; DROP TABLE orders; --'")
        XCTAssertEqual(DashSQL.bind(":status", variables: vars, values: ["status": "a\\' or 1=1 -- "], engine: .mysql), "'a\\\\'' or 1=1 -- '")
        XCTAssertEqual(DashSQL.bind(":range", variables: vars, values: ["range": "1d; drop table x"], engine: .postgres), "interval '30 days'", "a malformed range falls back to the default")
        XCTAssertEqual(DashSQL.bind("select :unknown, a:status", variables: vars, engine: .sqlite), "select :unknown, a:status")
        XCTAssertEqual(DashSQL.bind(":status", variables: vars, engine: .sqlite), "'all'")
    }

    func testJSONPatch() throws {
        let doc: [String: Any] = ["title": "A", "widgets": [["id": "w1", "title": "x"], ["id": "w2", "title": "y"]]]
        let out = try JSONPatch.apply([
            ["op": "replace", "path": "/widgets/0/title", "value": "Revenue"],
            ["op": "add", "path": "/widgets/-", "value": ["id": "w3"]],
            ["op": "add", "path": "/widgets/0/format", "value": ["unit": "USD"]],
            ["op": "remove", "path": "/widgets/1"],
        ], to: doc) as! [String: Any]
        let ws = out["widgets"] as! [[String: Any]]
        XCTAssertEqual(ws.map { $0["id"] as! String }, ["w1", "w3"])
        XCTAssertEqual(ws[0]["title"] as? String, "Revenue")
        XCTAssertEqual((ws[0]["format"] as? [String: String])?["unit"], "USD")
        XCTAssertThrowsError(try JSONPatch.apply([["op": "replace", "path": "/nope", "value": 1]], to: doc))
        XCTAssertThrowsError(try JSONPatch.apply([["op": "remove", "path": "/widgets/9"]], to: doc))
        XCTAssertThrowsError(try JSONPatch.apply([["op": "move", "path": "/a"]], to: doc))
        XCTAssertThrowsError(try JSONPatch.apply([["op": "add", "path": "/widgets/5", "value": 1]], to: doc))
        XCTAssertEqual(try JSONPatch.apply([["op": "add", "path": "/a~1b", "value": 1]], to: [String: Any]()) as? [String: Int], ["a/b": 1])
    }

    func testPatchToSpecRevalidates() throws {
        let s = spec([w("a")])
        let out = try JSONPatch.apply([["op": "replace", "path": "/widgets/0/title", "value": "New"]], toSpec: s.json())
        XCTAssertEqual(out.widgets[0].title, "New")
        XCTAssertThrowsError(try JSONPatch.apply([["op": "remove", "path": "/title"]], toSpec: s.json()))
    }

    func testGridSnapPlaceAndPack() {
        XCTAssertEqual(DashGrid.snap(0, cell: 100, gap: 4), 0)
        XCTAssertEqual(DashGrid.snap(207, cell: 100, gap: 4), 1)
        XCTAssertEqual(DashGrid.snap(208, cell: 100, gap: 4), 2)
        let ws = [w("a", x: 0, y: 0), w("b", x: 3, y: 0), w("c", x: 0, y: 2)]
        // moving c onto a pushes a down; everything stays inside the grid and disjoint
        let moved = DashGrid.place(ws, id: "c", x: 0, y: 0, w: 3, h: 2)
        XCTAssertEqual(moved.first { $0.id == "c" }!.y, 0)
        XCTAssertEqual(moved.first { $0.id == "a" }!.y, 2)
        XCTAssertEqual(spec(moved).validate().filter(\.fatal), [])
        // clamps to the right edge and to the minimum size
        let r = DashGrid.place(ws, id: "b", x: 11, y: 0, w: 1, h: 1)
        XCTAssertEqual(r.first { $0.id == "b" }!.x + r.first { $0.id == "b" }!.w, 12)
        XCTAssertEqual(r.first { $0.id == "b" }!.w, 2, "kpi minimum width")
    }

    func testNextFree() {
        let ws = [w("a", x: 0, y: 0, w: 12, h: 2), w("b", x: 0, y: 2, w: 6, h: 2)]
        XCTAssertTrue(DashGrid.nextFree(ws, w: 6, h: 2) == (6, 2))
        XCTAssertTrue(DashGrid.nextFree(ws, w: 12, h: 1) == (0, 4))
        XCTAssertTrue(DashGrid.nextFree([], w: 3, h: 2) == (0, 0))
    }
}
