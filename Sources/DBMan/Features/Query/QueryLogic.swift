import DBCore
import Foundation

/// Tree layout for the plan diagram: x = depth, y = row (leaves take consecutive rows, parents centre on children).
struct PlanLayout {
    struct Item { let node: PlanNode; let depth: Int; var row: Double; var share: Double }
    var items: [Item] = []
    var edges: [(from: Int, to: Int)] = []
    var hotspot: Int?
    var depth = 0
    var rows = 0

    init(_ root: PlanNode) {
        var nextRow = 0.0
        @discardableResult func place(_ n: PlanNode, _ d: Int, parent: Int?) -> Double {
            let idx = items.count
            items.append(Item(node: n, depth: d, row: 0, share: 0))
            if let parent { edges.append((parent, idx)) }
            depth = max(depth, d)
            let ys = n.children.map { place($0, d + 1, parent: idx) }
            let y = ys.isEmpty ? nextRow : (ys.first! + ys.last!) / 2
            if ys.isEmpty { nextRow += 1 }
            items[idx].row = y
            return y
        }
        place(root, 0, parent: nil)
        rows = max(Int(nextRow), 1)
        // Time share by selfMs when the engine reported timings, else by cost.
        let timed = items.contains { $0.node.selfMs != nil }
        let weight: (PlanNode) -> Double = { timed ? max($0.selfMs ?? 0, 0) : max($0.cost, 0) }
        let total = items.reduce(0) { $0 + weight($1.node) }
        guard total > 0 else { return }
        for i in items.indices { items[i].share = weight(items[i].node) / total }
        hotspot = items.indices.max { items[$0].share < items[$1].share }
    }
}

/// What the CHART view can draw for a result.
enum ChartSpec: Equatable {
    case bars(label: String, value: String, labels: [String], values: [Double])
    case line(label: String, names: [String], series: [[Double]], first: String, last: String)

    /// 1 text column + ≥1 numeric → bars (first numeric); date/time column + ≥1 numeric → lines. Otherwise nil.
    static func detect(_ r: QueryResult) -> ChartSpec? {
        enum Kind { case num, date, text, empty }
        let kinds: [Kind] = r.columns.indices.map { c in
            let cells = r.rows.compactMap { $0.indices.contains(c) && !$0[c].isNull ? $0[c] : nil }
            if cells.isEmpty { return .empty }
            if cells.allSatisfy(\.isNumeric) { return .num }
            if cells.allSatisfy({ if case .date = $0 { true } else { false } }) { return .date }
            return .text
        }
        let nums = kinds.indices.filter { kinds[$0] == .num }
        guard !nums.isEmpty, let l = kinds.firstIndex(where: { $0 == .text || $0 == .date }) else { return nil }
        func v(_ row: [Cell], _ c: Int) -> Double {
            switch row[c] { case .integer(let i): Double(i); case .real(let d): d; default: 0 }
        }
        if kinds[l] == .text {
            return .bars(label: r.columns[l], value: r.columns[nums[0]], labels: r.rows.map { $0[l].display }, values: r.rows.map { v($0, nums[0]) })
        }
        let sorted = r.rows.filter { if case .date = $0[l] { true } else { false } }
            .sorted { a, b in if case .date(let x) = a[l], case .date(let y) = b[l] { x < y } else { false } }
        guard sorted.count > 1 else { return nil }
        return .line(label: r.columns[l], names: nums.map { r.columns[$0] }, series: nums.map { c in sorted.map { v($0, c) } },
                     first: sorted.first![l].display, last: sorted.last![l].display)
    }
}

#if DEBUG
enum QueryLogicCheck {
    static let once: Void = {
        let leaf = { (op: String, ms: Double) in PlanNode(operation: op, estimatedRows: 1, selfMs: ms, cost: 1) }
        let root = PlanNode(operation: "Join", estimatedRows: 1, selfMs: 1, cost: 1, children: [
            PlanNode(operation: "Sort", estimatedRows: 1, selfMs: 2, cost: 1, children: [leaf("Scan a", 7)]), leaf("Scan b", 0)])
        let l = PlanLayout(root)
        assert(l.items.count == 4 && l.depth == 2 && l.rows == 2 && l.edges.count == 3)
        assert(l.items[2].row == 0 && l.items[1].row == 0 && l.items[3].row == 1 && l.items[0].row == 0.5)
        assert(l.hotspot == 2 && abs(l.items[2].share - 0.7) < 1e-9)
        let r = QueryResult(columns: ["name", "n", "id"], rows: [[.text("a"), .integer(3), .integer(1)], [.text("b"), .real(5), .integer(2)]])
        assert(ChartSpec.detect(r) == .bars(label: "name", value: "n", labels: ["a", "b"], values: [3, 5]))
        let t = QueryResult(columns: ["d", "n"], rows: [[.date(Date(timeIntervalSince1970: 100)), .integer(1)], [.date(Date(timeIntervalSince1970: 0)), .integer(2)]])
        if case .line(_, _, let s, _, _)? = ChartSpec.detect(t) { assert(s == [[2, 1]]) } else { assertionFailure("line") }
        assert(ChartSpec.detect(QueryResult(columns: ["a", "b"], rows: [[.text("x"), .text("y")]])) == nil)
    }()
}
#endif
