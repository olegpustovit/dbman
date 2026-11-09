import Foundation

/// A write the user made in the UI that has not reached the server yet.
public enum StagedChange: Sendable, Hashable {
    case update(table: String, key: [String: Cell], column: String, old: Cell, new: Cell)
    case insert(table: String, values: [String: Cell])
    case delete(table: String, key: [String: Cell])

    public var table: String {
        switch self { case .update(let t, _, _, _, _), .insert(let t, _), .delete(let t, _): return t }
    }

    public func sql(engine: Engine) -> String {
        let q = { quoteIdent($0, engine) }
        func whereClause(_ key: [String: Cell]) -> String {
            key.sorted { $0.key < $1.key }.map { "\(q($0.key)) = \($0.value.sqlLiteral)" }.joined(separator: " AND ")
        }
        switch self {
        case .update(let t, let key, let col, _, let new):
            return "UPDATE \(q(t)) SET \(q(col)) = \(new.sqlLiteral) WHERE \(whereClause(key));"
        case .insert(let t, let values):
            let cols = values.keys.sorted()
            return "INSERT INTO \(q(t)) (\(cols.map(q).joined(separator: ", "))) VALUES (\(cols.map { values[$0]!.sqlLiteral }.joined(separator: ", ")));"
        case .delete(let t, let key):
            return "DELETE FROM \(q(t)) WHERE \(whereClause(key));"
        }
    }
}

/// Ordered, undoable list of staged changes. Updates to the same cell collapse into one.
public struct ChangeSet: Sendable {
    public private(set) var items: [StagedChange] = []
    public init() {}
    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func add(_ change: StagedChange) {
        if case .update(let t, let key, let col, let old, let new) = change,
           let i = items.lastIndex(where: { if case .update(t, key, col, _, _) = $0 { return true } else { return false } }),
           case .update(_, _, _, let firstOld, _) = items[i] {
            if firstOld == new { items.remove(at: i) } else { items[i] = .update(table: t, key: key, column: col, old: firstOld, new: new) }
            _ = old
            return
        }
        items.append(change)
    }
    public mutating func undo() { if !items.isEmpty { items.removeLast() } }

    public var summary: (updates: Int, inserts: Int, deletes: Int) {
        items.reduce(into: (0, 0, 0)) { acc, c in
            switch c { case .update: acc.0 += 1; case .insert: acc.1 += 1; case .delete: acc.2 += 1 }
        }
    }

    public func transactionSQL(engine: Engine) -> String {
        let begin = engine == .mysql ? "START TRANSACTION;" : "BEGIN;"
        return ([begin] + items.map { $0.sql(engine: engine) } + ["COMMIT;"]).joined(separator: "\n")
    }
}
