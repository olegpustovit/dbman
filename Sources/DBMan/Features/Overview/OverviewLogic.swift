import DBCore
import Halftone
import Foundation

/// Pure helpers for the dashboard: time buckets, SQL builders, insights. No UI, no I/O.
enum OverviewWindow: Int, CaseIterable {
    case live, h24, d7, d30
    var title: String { ["LIVE", "24H", "7D", "30D"][rawValue] }
    var hourly: Bool { self == .live || self == .h24 }
    var count: Int { [12, 24, 7, 30][rawValue] }
}

struct Insight: Identifiable {
    let id = UUID()
    var title: String, detail: String
    var warn = false
    var table: String?   // OPEN
    var sql: String?     // RESOLVE
}

struct CategoryData {
    var table: String, dateColumn: String, column: String
    var names: [String]
    var daily: [[Double]]    // 14 daily buckets per category
    var hourly: [[Double]]   // 24 hourly buckets per category
}

enum OverviewLogic {
    private static let utc: (String) -> DateFormatter = { f in
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = TimeZone(identifier: "UTC"); d.dateFormat = f; return d
    }

    /// Oldest-first bucket keys: "yyyy-MM-dd" or "yyyy-MM-dd HH", ending at `now`.
    static func keys(now: Date, hourly: Bool, count: Int) -> [String] {
        let f = utc(hourly ? "yyyy-MM-dd HH" : "yyyy-MM-dd"), step: TimeInterval = hourly ? 3600 : 86400
        return (0..<count).reversed().map { f.string(from: now.addingTimeInterval(-Double($0) * step)) }
    }

    /// Missing buckets become 0.
    static func fill(_ rows: [(String, Double)], keys: [String]) -> [Double] {
        let m = Dictionary(rows.map { ($0.0, $0.1) }, uniquingKeysWith: +)
        return keys.map { m[$0] ?? 0 }
    }

    static func cutoff(_ keys: [String], hourly: Bool) -> String { (keys.first ?? "") + (hourly ? ":00:00" : "") }

    static func bucketExpr(_ e: Engine, _ col: String, hourly: Bool) -> String {
        let c = quoteIdent(col, e)
        switch e {
        case .sqlite: return "substr(\(c), 1, \(hourly ? 13 : 10))"
        case .postgres: return "to_char(\(c), '\(hourly ? "YYYY-MM-DD HH24" : "YYYY-MM-DD")')"
        case .mysql: return "DATE_FORMAT(\(c), '\(hourly ? "%Y-%m-%d %H" : "%Y-%m-%d")')"
        }
    }

    /// Newest-looking timestamp column: date/time typed, or `*_at`/`*_date` text (SQLite stores those as TEXT).
    static func dateColumn(_ t: TableInfo) -> String? {
        let c = t.columns.filter { c in
            let ty = c.type.lowercased(), n = c.name.lowercased()
            return ty.contains("date") || ty.contains("time") || n.hasSuffix("_at") || n.hasSuffix("_date")
        }
        return (c.first { $0.name.lowercased().contains("creat") } ?? c.first)?.name
    }

    static func growthSQL(_ e: Engine, table: String, dateCol: String, keys: [String], hourly: Bool) -> String {
        let b = bucketExpr(e, dateCol, hourly: hourly)
        return "SELECT \(b) AS bucket, COUNT(*) AS n FROM \(quoteIdent(table, e)) WHERE \(quoteIdent(dateCol, e)) >= \(Cell.text(cutoff(keys, hourly: hourly)).sqlLiteral) GROUP BY 1"
    }

    static func categorySQL(_ e: Engine, table: String, dateCol: String, catCol: String, names: [String], keys: [String], hourly: Bool) -> String {
        let b = bucketExpr(e, dateCol, hourly: hourly), cat = quoteIdent(catCol, e)
        let inList = names.map { Cell.text($0).sqlLiteral }.joined(separator: ", ")
        return "SELECT \(b) AS bucket, \(cat) AS cat, COUNT(*) AS n FROM \(quoteIdent(table, e)) WHERE \(quoteIdent(dateCol, e)) >= \(Cell.text(cutoff(keys, hourly: hourly)).sqlLiteral) AND \(cat) IN (\(inList)) GROUP BY 1, 2"
    }

    static func isAttention(_ name: String) -> Bool {
        ["pending", "failed", "error", "cancelled", "canceled"].contains(name.lowercased())
    }

    static func num(_ c: Cell?) -> Double {
        switch c {
        case .integer(let v)?: return Double(v)
        case .real(let v)?: return v
        case .text(let s)?: return Double(s) ?? 0
        default: return 0
        }
    }

    /// "2026-11-09", "2026-11-09 14:32:09" or ISO-8601 with T/zone.
    static func parseDate(_ s: String) -> Date? {
        let t = s.replacingOccurrences(of: "T", with: " ")
        for (len, f) in [(19, "yyyy-MM-dd HH:mm:ss"), (10, "yyyy-MM-dd")] where t.count >= len {
            if let d = utc(f).date(from: String(t.prefix(len))) { return d }
        }
        return nil
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(d)))
        if s < 60 { return "\(s)_SEC_AGO" }
        if s < 3600 { return "\(s / 60)_MIN_AGO" }
        return s < 86400 ? "\(s / 3600)_HR_AGO" : "\(s / 86400)_DAY_AGO"
    }

    /// Up to 4 insights from data the dashboard already holds.
    static func insights(tables: [TableInfo], cat: CategoryData?, nulls: [(table: String, column: String, fraction: Double)],
                         unusedIndexes: [(table: String, index: String)], engine: Engine) -> [Insight] {
        var out: [Insight] = []
        let total = tables.reduce(Int64(0)) { $0 + $1.rowCount }
        if let top = tables.max(by: { $0.rowCount < $1.rowCount }), total > 0, Double(top.rowCount) / Double(total) >= 0.4 {
            out.append(Insight(title: "\(top.name.uppercased())_HOLDS_\(Int((Double(top.rowCount) / Double(total) * 100).rounded()))%_OF_ROWS",
                               detail: "\(HTFormat.grouped(top.rowCount)) of \(HTFormat.grouped(total)) rows live in one table.", table: top.name))
        }
        if let cat {
            let growth: [(String, Double)] = zip(cat.names, cat.daily).compactMap { n, s in
                guard s.count >= 14 else { return nil }
                let prior = s[0..<7].reduce(0, +), last = s[7..<14].reduce(0, +)
                return prior > 0 ? (n, last / prior - 1) : nil
            }
            if let g = growth.max(by: { $0.1 < $1.1 }), g.1 >= 0.25 {
                let q = quoteIdent(cat.column, engine)
                out.append(Insight(title: "\(cat.column.uppercased())_\(g.0.uppercased())_UP_\(Int((g.1 * 100).rounded()))%",
                                   detail: "\(cat.table) rows with \(cat.column) = \(g.0): last 7 days vs prior 7.", warn: isAttention(g.0), table: cat.table,
                                   sql: "SELECT * FROM \(quoteIdent(cat.table, engine)) WHERE \(q) = \(Cell.text(g.0).sqlLiteral) ORDER BY \(quoteIdent(cat.dateColumn, engine)) DESC LIMIT 100"))
            }
        }
        for n in nulls.sorted(by: { $0.fraction > $1.fraction }).prefix(1) where n.fraction > 0.4 {
            out.append(Insight(title: "\(n.table.uppercased()).\(n.column.uppercased())_\(Int((n.fraction * 100).rounded()))%_NULL",
                               detail: "More than 40% of sampled rows have no value.", warn: true, table: n.table,
                               sql: "SELECT * FROM \(quoteIdent(n.table, engine)) WHERE \(quoteIdent(n.column, engine)) IS NULL LIMIT 100"))
        }
        if let u = unusedIndexes.first {
            out.append(Insight(title: "\(unusedIndexes.count)_UNUSED_INDEX\(unusedIndexes.count == 1 ? "" : "ES")",
                               detail: "\(u.index) on \(u.table) has never been scanned.", warn: true, table: u.table,
                               sql: "DROP INDEX \(quoteIdent(u.index, engine))"))
        }
        return Array(out.prefix(4))
    }

    #if DEBUG
    static func selfCheck() {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let d = keys(now: now, hourly: false, count: 3), h = keys(now: now, hourly: true, count: 24)
        assert(d.count == 3 && d[2] > d[0] && d[0].count == 10 && h.count == 24 && h[0].count == 13)
        assert(fill([(d[1], 4), (d[1], 1), ("zzz", 9)], keys: d) == [0, 5, 0])
        assert(cutoff(h, hourly: true).count == 19)
        let t = TableInfo(schema: "", name: "orders", kind: .table, rowCount: 700, columns: [ColumnInfo(name: "created_at", type: "TEXT", nullable: false)])
        assert(dateColumn(t) == "created_at")
        let cat = CategoryData(table: "orders", dateColumn: "created_at", column: "status", names: ["pending", "paid"],
                               daily: [[1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2], [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]], hourly: [])
        let o = TableInfo(schema: "", name: "other", kind: .table, rowCount: 300)
        let ins = insights(tables: [t, o], cat: cat, nulls: [("orders", "shipped_at", 0.6)], unusedIndexes: [("orders", "ix")], engine: .sqlite)
        assert(ins.count == 4 && ins[0].title.contains("70%") && ins[1].title.hasSuffix("UP_100%") && ins[1].warn && ins[2].sql?.contains("IS NULL") == true)
        assert(insights(tables: [], cat: nil, nulls: [], unusedIndexes: [], engine: .sqlite).isEmpty)
        assert(parseDate("2026-11-09 14:32:09") != nil && parseDate("2026-11-09T14:32:09Z") != nil && parseDate("nope") == nil)
        assert(HTFormat.compact(48_000).contains("48") && ago(now.addingTimeInterval(-120), now: now) == "2_MIN_AGO")
    }
    #endif
}
