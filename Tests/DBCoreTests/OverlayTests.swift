import XCTest
@testable import DBCore

final class OverlayTests: XCTestCase {
    func testTokenizerSkipsStringsAndCommentsKeepsQuotedIdentifiers() {
        let t = sqlTokens(#"select "Em""ail", 'email' /* email */ , `x` from t -- email"#, mysql: true)
        XCTAssertEqual(t.filter(\.isIdentifier).map(\.text), ["select", "Em\"ail", "x", "from", "t"])
        XCTAssertEqual(sqlTokens("select $$ email $$, $1, e$x from t").filter(\.isIdentifier).map(\.text), ["select", "e$x", "from", "t"])
        XCTAssertEqual(sqlTokens("a.b").map(\.text), ["a", ".", "b"])
    }

    let views = [(name: "v", sql: "select id from t where x > 1;"), (name: "w", sql: "select id from v")]

    func testExpandPrependsAndMergesIntoWith() {
        XCTAssertEqual(Overlay.expand("select * from w", views: views).sql, "WITH v AS (select id from t where x > 1), w AS (select id from v) select * from w")
        XCTAssertEqual(Overlay.expand("select * from w", views: views).used, ["v", "w"]) // dependencies first
        XCTAssertEqual(Overlay.expand("WITH a AS (select 1) select * from a, v", views: views).sql, "WITH v AS (select id from t where x > 1), a AS (select 1) select * from a, v")
        XCTAssertEqual(Overlay.expand("with recursive a(n) as (select 1) select * from a join V", views: views).sql, "with recursive v AS (select id from t where x > 1), a(n) as (select 1) select * from a join V")
        XCTAssertEqual(Overlay.expand("select 1", views: views).sql, "select 1")
        XCTAssertEqual(Overlay.expand("select o.v from t o where 'v' = 'v' -- v", views: views).used, []) // column qualifier, string and comment are not references
    }

    func testExpandShadowing() {
        // the statement's own CTE wins; a later layer's view wins over an earlier one
        XCTAssertEqual(Overlay.expand("with v as (select 7) select * from v", views: views).used, [])
        let layered = [(name: "v", sql: "select 1 mine"), (name: "V", sql: "select 2 agent")]
        XCTAssertEqual(Overlay.expand("select * from v", views: layered).sql, "WITH V AS (select 2 agent) select * from v")
        // cycles do not loop
        XCTAssertEqual(Overlay.expand("select * from a", views: [(name: "a", sql: "select * from b"), (name: "b", sql: "select * from a")]).used.sorted(), ["a", "b"])
    }

    func rows() -> [[Cell]] { [[.integer(1), .text("a"), .real(1.5)], [.integer(2), .text("b"), .real(2)], [.integer(3), .text("c"), .real(3)]] }
    let cols = ["id", "name", "price"]

    func testMergeUpdateInsertDeleteAndPrecedence() {
        let mine = RowPatch(table: "t", key: ["id": .integer(1)], op: .update, after: ["name": .text("mine"), "price": .integer(9)])
        let agent = RowPatch(table: "t", key: ["id": .integer(1)], op: .update, after: ["name": .text("agent")]) // top layer last: wins
        let del = RowPatch(table: "t", key: ["id": .integer(2)], op: .delete)
        let ins = RowPatch(table: "t", key: ["id": .integer(7)], op: .insert, after: ["name": .text("new")])
        let m = Overlay.merge(columns: cols, rows: rows(), pk: ["id"], patches: [mine, agent, del, ins], addInserts: true)
        XCTAssertEqual(m.rows, [[.integer(1), .text("agent"), .real(9)], [.integer(3), .text("c"), .real(3)], [.integer(7), .text("new"), .null]]) // 9 coerced to the real column
        XCTAssertEqual(m.source, [0, 2, -1])
        XCTAssertEqual(m.cells[0], [1, 2]); XCTAssertNil(m.cells[1]); XCTAssertEqual(m.cells[2], [0, 1, 2]) // marks follow the rows after the delete
        // inserts only on request; patches for rows outside the page are ignored; no key in the result leaves it alone
        XCTAssertEqual(Overlay.merge(columns: cols, rows: rows(), pk: ["id"], patches: [ins], addInserts: false).rows, rows())
        XCTAssertEqual(Overlay.merge(columns: cols, rows: rows(), pk: ["id"], patches: [RowPatch(table: "t", key: ["id": .integer(99)], op: .update, after: ["name": .text("x")])], addInserts: true).rows, rows())
        XCTAssertEqual(Overlay.merge(columns: ["name"], rows: [[.text("a")]], pk: ["id"], patches: [mine], addInserts: true).rows, [[.text("a")]])
        // delete then a higher layer re-inserts the same key
        XCTAssertEqual(Overlay.merge(columns: cols, rows: rows(), pk: ["id"], patches: [del, RowPatch(table: "t", key: ["id": .integer(2)], op: .insert, after: ["name": .text("back")])], addInserts: false).rows[1][1], .text("back"))
    }

    func testCodecAndStableHash() {
        let v: [String: Cell] = ["a": .integer(1), "b": .real(1.5), "c": .text("x"), "d": .null, "e": .bool(true)]
        XCTAssertEqual(Overlay.values(Overlay.json(v)), v)
        XCTAssertEqual(Overlay.hash(columns: cols, row: rows()[0]), Overlay.hash(columns: cols, row: rows()[0]))
        XCTAssertNotEqual(Overlay.hash(columns: cols, row: rows()[0]), Overlay.hash(columns: cols, row: rows()[1]))
        XCTAssertEqual(Overlay.hash(columns: ["a"], row: [.text("x")]), "ece3ff82c3c0d03a") // FNV-1a, fixed across launches
    }

    func testApplyBuildsChangeSetPerEngine() {
        let ps = [RowPatch(table: "o'rders", key: ["id": .integer(1)], op: .update, before: ["total": .real(10.5)], after: ["total": .real(99.5), "note": .text("it's")]),
                  RowPatch(table: "o'rders", key: ["id": .integer(10)], op: .insert, after: ["total": .integer(5)]),
                  RowPatch(table: "o'rders", key: ["id": .integer(3)], op: .delete)]
        var cs = ChangeSet(); Overlay.changes(ps).forEach { cs.add($0) }
        XCTAssertEqual(cs.summary.updates, 2); XCTAssertEqual(cs.summary.inserts, 1); XCTAssertEqual(cs.summary.deletes, 1)
        XCTAssertEqual(cs.transactionSQL(engine: .postgres), """
            BEGIN;
            UPDATE "o'rders" SET "note" = 'it''s' WHERE "id" = 1;
            UPDATE "o'rders" SET "total" = 99.5 WHERE "id" = 1;
            INSERT INTO "o'rders" ("id", "total") VALUES (10, 5);
            DELETE FROM "o'rders" WHERE "id" = 3;
            COMMIT;
            """)
        XCTAssertEqual(cs.transactionSQL(engine: .mysql).split(separator: "\n").map(String.init), [
            "START TRANSACTION;", "UPDATE `o'rders` SET `note` = 'it''s' WHERE `id` = 1;", "UPDATE `o'rders` SET `total` = 99.5 WHERE `id` = 1;",
            "INSERT INTO `o'rders` (`id`, `total`) VALUES (10, 5);", "DELETE FROM `o'rders` WHERE `id` = 3;", "COMMIT;"])
        XCTAssertTrue(cs.transactionSQL(engine: .sqlite).hasPrefix("BEGIN;\nUPDATE \"o'rders\""))
    }
}
