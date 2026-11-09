import Foundation

public struct TopValue: Sendable, Hashable {
    public var value: String
    public var share: Double
    public init(value: String, share: Double) { self.value = value; self.share = share }
}

public struct ColumnStats: Sendable {
    public var column: String
    public var distinct: Int?
    public var nullFraction: Double
    public var min: String?
    public var max: String?
    public var median: String?
    /// 12 normalised bins (0...1) for numeric/date columns; category shares for text with <= 12 distinct values.
    public var histogram: [Double]
    public var topValues: [TopValue]
}

public extension DatabaseSession {
    /// Per-column profile computed client-side from a sample of the table.
    func columnStats(table: String, sampleRows: Int = 5000) async throws -> [ColumnStats] {
        let engine = profile.engine
        let t = quoteIdent(table, engine)
        var sql = "SELECT * FROM \(t) LIMIT \(sampleRows)"
        if engine == .postgres, let info = try await schema().table(table), info.rowCount > 50_000 {
            let pct = Swift.min(100.0, Double(sampleRows) * 100 / Double(info.rowCount) * 1.5)
            sql = "SELECT * FROM \(t) TABLESAMPLE SYSTEM (\(pct)) LIMIT \(sampleRows)"
        }
        let r = try await readOnlyRun(sql, limit: sampleRows)
        return r.columns.enumerated().map { i, name in ColumnStats.compute(name, r.rows.map { $0[i] }) }
    }
}

extension ColumnStats {
    static func compute(_ name: String, _ values: [Cell]) -> ColumnStats {
        let nonNull = values.filter { !$0.isNull }
        let nullFrac = values.isEmpty ? 0 : Double(values.count - nonNull.count) / Double(values.count)
        var counts: [String: Int] = [:]
        for v in nonNull { counts[v.display, default: 0] += 1 }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
            .map { TopValue(value: $0.key, share: Double($0.value) / Double(nonNull.count)) }
        let nums: [Double] = nonNull.compactMap {
            switch $0 {
            case .integer(let i): return Double(i)
            case .real(let d): return d
            case .date(let d): return d.timeIntervalSince1970
            case .bool(let b): return b ? 1 : 0
            default: return nil
            }
        }
        var s = ColumnStats(column: name, distinct: counts.count, nullFraction: nullFrac, min: nil, max: nil, median: nil, histogram: [], topValues: top)
        if !nonNull.isEmpty && nums.count == nonNull.count {
            let sorted = nums.sorted(), lo = sorted[0], hi = sorted[sorted.count - 1]
            let cellFor = { (d: Double) -> String in
                switch nonNull[0] {
                case .integer: return String(Int64(d))
                case .date: return Cell.date(Date(timeIntervalSince1970: d)).display
                case .bool: return d == 0 ? "false" : "true"
                default: return Cell.real(d).display
                }
            }
            s.min = cellFor(lo); s.max = cellFor(hi); s.median = cellFor(sorted[sorted.count / 2])
            var bins = [Double](repeating: 0, count: 12)
            for v in nums { bins[hi == lo ? 0 : Swift.min(11, Int((v - lo) / (hi - lo) * 12))] += 1 }
            let m = bins.max() ?? 1
            s.histogram = bins.map { $0 / m }
        } else if !nonNull.isEmpty {
            let strs = nonNull.map(\.display).sorted()
            s.min = strs.first; s.max = strs.last; s.median = strs[strs.count / 2]
            if counts.count <= 12 { s.histogram = top.map(\.share) + counts.sorted { $0.value > $1.value }.dropFirst(5).map { Double($0.value) / Double(nonNull.count) } }
        }
        return s
    }
}
