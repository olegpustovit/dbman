import XCTest
@testable import DBCore

final class SchemaMapTests: XCTestCase {
    typealias Col = (name: String, type: String, pk: Bool, fk: String?, nullable: Bool)

    func table(_ name: String, rows: Int64 = 10, schema: String = "public", _ cols: [Col]) -> TableInfo {
        TableInfo(schema: schema, name: name, kind: .table, rowCount: rows, columns: cols.map {
            ColumnInfo(name: $0.name, type: $0.type, nullable: $0.nullable, isPrimaryKey: $0.pk, foreignKey: $0.fk.map { ForeignKey(table: $0, column: "id") })
        })
    }
    func id(_ type: String = "int8") -> Col { ("id", type, true, nil, false) }
    func fk(_ name: String, _ to: String, null: Bool = false) -> Col { (name, "int8", false, to, null) }
    func plain(_ name: String, _ type: String = "text") -> Col { (name, type, false, nil, false) }

    func snapshot(_ tables: [TableInfo]) -> SchemaSnapshot { SchemaSnapshot(serverVersion: "", databaseName: "shop", tables: tables) }

    /// The SPEC `shop` schema; events.customer_id is deliberately undeclared.
    var shop: SchemaGraph {
        SchemaGraph(schema: snapshot([
            table("customers", [id(), plain("email")]),
            table("categories", [id("int4")]),
            table("products", [id(), (name: "category_id", type: "int4", pk: false, fk: "categories", nullable: false)]),
            table("orders", [id(), fk("customer_id", "customers")]),
            table("order_items", [id(), fk("order_id", "orders"), fk("product_id", "products")]),
            table("invoices", [id(), fk("order_id", "orders"), fk("customer_ref", "customers", null: true)]),
            table("refunds", [id(), fk("invoice_id", "invoices")]),
            table("coupons", [id("int4")]),
            table("order_coupons", [(name: "order_id", type: "int8", pk: true, fk: "orders", nullable: false), (name: "coupon_id", type: "int4", pk: true, fk: "coupons", nullable: false)]),
            table("events", [id(), plain("customer_id", "bigint")]),
            table("audit_log", [id(), plain("action")]),
        ]))
    }

    // MARK: inference

    func testInferredRelations() {
        let inferred = shop.edges.filter { $0.kind == .inferred }
        XCTAssertEqual(inferred.map { "\($0.from).\($0.fromColumn)->\($0.to).\($0.toColumn)" }, ["events.customer_id->customers.id"])
        XCTAssertEqual(shop.edges.filter { $0.kind == .declared }.count, 9) // declared columns are never re-inferred
    }

    func testInferenceRules() {
        let g = SchemaGraph(schema: snapshot([
            table("categories", [id("integer")]),
            table("people", [id("uuid")]),
            table("things", [id(), plain("category_id", "INTEGER"), plain("person_id", "int8"), plain("parent_id", "int8"), plain("thing_id", "int8")]),
        ]))
        // category_id -> categories (ies plural, integer ~ integer); person_id -> people no (not x/xs/xes); parent_id no table; thing_id never points at itself
        XCTAssertEqual(g.edges.map { "\($0.from).\($0.fromColumn)->\($0.to)" }, ["things.category_id->categories"])
        let mismatch = SchemaGraph(schema: snapshot([table("users", [id()]), table("posts", [id(), plain("user_id", "varchar(36)")])]))
        XCTAssertTrue(mismatch.edges.isEmpty, "text FK column must not match an int key")
    }

    func testAcceptedRelationBecomesVirtual() {
        let v = VirtualRelation(fromTable: "events", fromColumn: "customer_id", toTable: "customers", toColumn: "id")
        let g = SchemaGraph(schema: snapshot(shop.tables), virtual: [v])
        XCTAssertEqual(g.edges.filter { $0.kind == .virtual }.count, 1)
        XCTAssertTrue(g.edges.filter { $0.kind == .inferred }.isEmpty)
    }

    // MARK: path

    func testPath() {
        let p = shop.path(from: "customers", to: "products")
        XCTAssertEqual(p?.tables, ["customers", "orders", "order_items", "products"])
        XCTAssertEqual(p?.joins, 3)
        XCTAssertEqual(shop.path(from: "refunds", to: "customers")?.joins, 2) // refunds → invoices → customers (customer_ref)
        XCTAssertNil(shop.path(from: "audit_log", to: "orders"))
        XCTAssertNil(shop.path(from: "events", to: "orders"), "inferred relations are not joins until accepted")
        let v = VirtualRelation(fromTable: "events", fromColumn: "customer_id", toTable: "customers", toColumn: "id")
        XCTAssertEqual(SchemaGraph(schema: snapshot(shop.tables), virtual: [v]).path(from: "events", to: "orders")?.tables, ["events", "customers", "orders"])
        XCTAssertEqual(shop.path(from: "orders", to: "orders")?.tables, ["orders"])
    }

    func testJoinSQL() {
        let sql = shop.joinSQL(shop.path(from: "customers", to: "products")!, engine: .postgres)
        XCTAssertEqual(sql, """
            SELECT c.*, p.*
            FROM customers c
            JOIN orders o ON o.customer_id = c.id
            JOIN order_items oi ON oi.order_id = o.id
            JOIN products p ON p.id = oi.product_id;
            """)
    }

    // MARK: filter, junctions

    func testFuzzy() {
        XCTAssertTrue(SchemaGraph.fuzzy("ordit", "order_items"))
        XCTAssertFalse(SchemaGraph.fuzzy("zz", "order_items"))
        XCTAssertEqual(shop.matching("cust"), Set(["customers", "orders", "invoices", "events"])) // column matches count too
    }

    func testHideJunctionsDrawsManyToMany() {
        let g = shop.filtered(hideJunctions: true, hideIsolated: true)
        XCTAssertFalse(g.tables.contains { $0.name == "order_coupons" || $0.name == "audit_log" })
        let mn = g.edges.filter(\.manyToMany)
        XCTAssertEqual(mn.map { "\($0.from)-\($0.to)" }, ["orders-coupons"])
    }

    // MARK: exporters

    var tiny: SchemaGraph {
        SchemaGraph(schema: snapshot([
            table("customers", [id(), plain("email")]),
            table("orders", [id(), fk("customer_id", "customers")]),
            table("events", [id(), plain("customer_id", "int8")]),
        ]))
    }

    func testMermaidGolden() {
        XCTAssertEqual(SchemaExport.mermaid(tiny), """
            erDiagram
              customers ||--o{ orders : customer_id
              %% inferred: events.customer_id -> customers.id
              customers {
                int8 id PK
                text email
              }
              orders {
                int8 id PK
                int8 customer_id FK
              }
              events {
                int8 id PK
                int8 customer_id
              }

            """)
    }

    func testDBMLGolden() {
        XCTAssertEqual(SchemaExport.dbml(tiny), """
            Table customers {
              id int8 [pk]
              email text [not null]
            }

            Table orders {
              id int8 [pk]
              customer_id int8 [not null]
            }

            Table events {
              id int8 [pk]
              customer_id int8 [not null]
            }

            Ref: orders.customer_id > customers.id
            // inferred: Ref: events.customer_id > customers.id

            """)
    }

    func testSVGHasEveryTable() {
        let g = shop
        let svg = SchemaExport.svg(MapScene(graph: g, detail: .keys, layout: MapLayouts.layered(g, g.sizes(.keys))))
        for t in g.tables { XCTAssertTrue(svg.contains("<g id=\"\(t.name)\">"), t.name) }
        XCTAssertTrue(svg.hasPrefix("<svg") && svg.hasSuffix("</svg>\n"))
    }

    // MARK: layouts

    /// Seeded generator: `n` tables, FKs to earlier tables (a few to later ones to make cycles), some isolated, two schemas.
    func generated(_ n: Int) -> SchemaGraph {
        var seed: UInt64 = 42
        func rnd(_ m: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(m)) }
        let ts = (0..<n).map { i -> TableInfo in
            var cols = [id()]
            if i > 3 && i % 7 != 0 { for k in 0..<(1 + rnd(3)) { cols.append(fk("p\(k)_id", "t\(rnd(i))")) } }
            if i % 11 == 0 { cols.append(fk("back_id", "t\(rnd(n))")) }
            for k in 0..<rnd(8) { cols.append(plain("c\(k)")) }
            return table("t\(i)", rows: Int64(rnd(1_000_000)), schema: i % 2 == 0 ? "a" : "b", cols)
        }
        return SchemaGraph(schema: snapshot(ts))
    }

    func assertNoOverlap(_ l: MapLayout, _ sizes: [String: CGSize], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let rects = l.origins.map { ($0.key, CGRect(origin: $0.value, size: sizes[$0.key]!)) }
        for i in rects.indices { for j in rects.indices where j > i && rects[i].1.intersects(rects[j].1) {
            XCTFail("\(what): \(rects[i].0) overlaps \(rects[j].0)", file: file, line: line); return
        } }
    }

    func testLayoutsNeverOverlap() {
        for n in [60, 90, 150] {
            let g = generated(n)
            XCTAssertGreaterThanOrEqual(g.edges.count, n / 2)
            for d in MapDetail.allCases {
                let s = g.sizes(d)
                let layered = MapLayouts.layered(g, s), clusters = MapLayouts.clusters(g, s)
                XCTAssertEqual(layered.origins.count, n); XCTAssertEqual(clusters.origins.count, n)
                assertNoOverlap(layered, s, "layered \(n) \(d)")
                assertNoOverlap(clusters, s, "clusters \(n) \(d)")
                for b in clusters.boxes { for m in b.members { XCTAssertTrue(b.rect.contains(CGRect(origin: clusters.origins[m]!, size: s[m]!)), "\(m) outside box \(b.name)") } }
                for c in ["t0", "t5", "t17", "t\(n - 1)"] { for h in 1...3 {
                    let f = MapLayouts.focus(g, s, center: c, hops: h)
                    assertNoOverlap(f, s, "focus \(c) \(h) \(n) \(d)")
                    XCTAssertEqual(f.hops[c], 0)
                    XCTAssertTrue(f.hops.values.allSatisfy { $0 <= h })
                } }
            }
        }
    }

    func testLayeredPutsParentsLeft() {
        let g = shop, l = MapLayouts.layered(g, g.sizes(.keys))
        for e in g.edges where e.kind == .declared && e.from != e.to { XCTAssertLessThan(l.origins[e.to]!.x, l.origins[e.from]!.x, "\(e.to) must be left of \(e.from)") }
    }

    func testClustersSingleSchemaUsesComponents() {
        let c = MapLayouts.clusters(shop, shop.sizes(.keys))
        XCTAssertEqual(c.boxes.count, 2) // one connected component + the isolated audit_log
        XCTAssertEqual(c.boxes.first { $0.name == "isolated" }?.members, ["audit_log"])
    }

    func testFocusInRange() {
        let g = shop, f = MapLayouts.focus(g, g.sizes(.keys), center: "orders", hops: 1)
        XCTAssertEqual(Set(f.origins.keys), ["orders", "customers", "order_items", "invoices", "order_coupons"])
    }

    func testRoutesLeaveCardsAlongNormals() {
        let g = shop, s = MapScene(graph: g, detail: .keys, layout: MapLayouts.layered(g, g.sizes(.keys)))
        for e in g.edges { XCTAssertNotNil(s.route(e), "\(e.from)→\(e.to)") }
    }
}

