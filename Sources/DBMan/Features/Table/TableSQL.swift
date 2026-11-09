import DBCore
import Foundation

/// SQL composition and value parsing for the table browser (pure, so it can self-check).
enum TableSQL {
    struct Sort: Equatable { var column: String; var descending: Bool }

    /// Without an explicit sort, pages are ordered by the primary key so OFFSET paging is stable.
    static func select(table: String, engine: Engine, filter: String = "", sort: Sort? = nil, pk: [String] = [], limit: Int? = nil, offset: Int = 0) -> String {
        var sql = "SELECT * FROM \(quoteIdent(table, engine))"
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { sql += " WHERE \(f)" }
        if let sort { sql += " ORDER BY \(quoteIdent(sort.column, engine)) \(sort.descending ? "DESC" : "ASC")" }
        else if !pk.isEmpty { sql += " ORDER BY " + pk.map { quoteIdent($0, engine) }.joined(separator: ", ") }
        if let limit { sql += " LIMIT \(limit)" + (offset > 0 ? " OFFSET \(offset)" : "") }
        return sql
    }

    /// `col = literal` (or IS NULL) used by quick filters, FK follow and "filter by this value".
    static func equals(_ column: String, _ value: Cell, engine: Engine) -> String {
        let c = quoteIdent(column, engine)
        return value.isNull ? "\(c) IS NULL" : "\(c) = \(value.sqlLiteral)"
    }

    static func and(_ a: String, _ b: String) -> String { a.trimmingCharacters(in: .whitespaces).isEmpty ? b : "\(a) AND \(b)" }

    /// The WHERE text is user SQL; a second statement would bypass the read-only guard of `stream`.
    static func isSingleStatement(_ filter: String) -> Bool { !filter.contains(";") }

    /// Parses edited text into a Cell of the same kind as the old value; nil = not valid for that type.
    static func parse(_ text: String, like old: Cell) -> Cell? {
        switch old {
        case .integer: return Int64(text).map(Cell.integer)
        case .real: return Double(text).map(Cell.real)
        case .bool:
            switch text.lowercased() { case "true", "1": return .bool(true); case "false", "0": return .bool(false); default: return nil }
        case .blob: return nil
        default: return .text(text)
        }
    }

    #if DEBUG
    /// Asserts composition/quoting, then runs a composed query against a live session.
    static func selfCheck(session: DatabaseSession, engine: Engine, table: TableInfo) async {
        assert(select(table: "t", engine: .sqlite) == "SELECT * FROM \"t\"")
        assert(select(table: "a\"b", engine: .postgres, filter: " x > 1 ", sort: .init(column: "c", descending: true), limit: 500, offset: 1000)
               == "SELECT * FROM \"a\"\"b\" WHERE x > 1 ORDER BY \"c\" DESC LIMIT 500 OFFSET 1000")
        assert(select(table: "t", engine: .postgres, pk: ["id"], limit: 5) == "SELECT * FROM \"t\" ORDER BY \"id\" LIMIT 5")
        assert(select(table: "t`", engine: .mysql, sort: .init(column: "c", descending: false), limit: 5) == "SELECT * FROM `t``` ORDER BY `c` ASC LIMIT 5")
        assert(equals("n", .text("o'k"), engine: .sqlite) == "\"n\" = 'o''k'" && equals("n", .null, engine: .sqlite) == "\"n\" IS NULL")
        assert(and("", "a = 1") == "a = 1" && and("a = 1", "b = 2") == "a = 1 AND b = 2")
        assert(parse("x", like: .integer(1)) == nil && parse("7", like: .integer(1)) == .integer(7) && parse("x", like: .null) == .text("x"))
        let sql = select(table: table.name, engine: engine, filter: "1 = 1", sort: table.columns.first.map { .init(column: $0.name, descending: false) }, limit: 3, offset: 1)
        do { _ = try await session.run(sql, limit: 3) } catch { assertionFailure("TableSQL self-check failed: \(sql) -> \(error)") }
    }
    #endif
}
