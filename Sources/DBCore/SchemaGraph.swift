import Foundation

/// One relation on the schema map. `from` is the child (holds the column), `to` the parent.
public struct MapEdge: Hashable, Sendable {
    public enum Kind: String, Sendable { case declared, inferred, virtual }
    public var from: String, fromColumn: String, to: String, toColumn: String
    public var kind: Kind
    /// Child column is nullable → the parent end is "zero or one".
    public var optional = false
    /// Drawn in place of a hidden junction table.
    public var manyToMany = false
    public init(from: String, fromColumn: String, to: String, toColumn: String, kind: Kind, optional: Bool = false, manyToMany: Bool = false) {
        self.from = from; self.fromColumn = fromColumn; self.to = to; self.toColumn = toColumn
        self.kind = kind; self.optional = optional; self.manyToMany = manyToMany
    }
}

/// An accepted relation: stored in the DBMan store (overlay item, kind `relation`), never DDL.
public struct VirtualRelation: Codable, Hashable, Sendable {
    public var fromTable: String, fromColumn: String, toTable: String, toColumn: String
    public init(fromTable: String, fromColumn: String, toTable: String, toColumn: String) {
        self.fromTable = fromTable; self.fromColumn = fromColumn; self.toTable = toTable; self.toColumn = toColumn
    }
    enum CodingKeys: String, CodingKey { case fromTable = "from_table", fromColumn = "from_column", toTable = "to_table", toColumn = "to_column" }
}

public struct JoinPath: Equatable, Sendable {
    public var tables: [String]
    /// `steps[i]` joins `tables[i]` and `tables[i + 1]`.
    public var steps: [MapEdge]
    public var joins: Int { steps.count }
}

/// Tables + relations (declared, inferred, virtual) of one schema snapshot.
public struct SchemaGraph: Sendable {
    public let tables: [TableInfo]
    public let edges: [MapEdge]
    public let junctions: Set<String>
    /// PK columns plus every column that ends a relation: what KEYS detail shows.
    private let keyColumns: [String: Set<String>]
    private let byName: [String: TableInfo]

    public init(schema: SchemaSnapshot, virtual: [VirtualRelation] = []) {
        let ts = schema.tables.filter { $0.kind == .table }
        let by = Dictionary(ts.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var edges: [MapEdge] = []
        var taken = Set<String>()
        for t in ts {
            for c in t.columns {
                guard let fk = c.foreignKey, by[fk.table] != nil else { continue }
                edges.append(MapEdge(from: t.name, fromColumn: c.name, to: fk.table, toColumn: fk.column, kind: .declared, optional: c.nullable))
                taken.insert(t.name + "." + c.name)
            }
        }
        for v in virtual {
            guard let child = by[v.fromTable], let col = child.columns.first(where: { $0.name == v.fromColumn }), let parent = by[v.toTable],
                  parent.columns.contains(where: { $0.name == v.toColumn }), taken.insert(v.fromTable + "." + v.fromColumn).inserted else { continue }
            edges.append(MapEdge(from: v.fromTable, fromColumn: v.fromColumn, to: v.toTable, toColumn: v.toColumn, kind: .virtual, optional: col.nullable))
        }
        edges += Self.inferRelations(ts, skipping: taken)
        let junctions = Set(ts.filter { t in
            let fks = Set(t.columns.filter { $0.foreignKey.map { by[$0.table] != nil } ?? false }.map(\.name))
            return t.primaryKey.count >= 2 && t.primaryKey.allSatisfy(fks.contains)
        }.map(\.name))
        self.init(tables: ts, edges: edges, junctions: junctions)
    }

    private init(tables: [TableInfo], edges: [MapEdge], junctions: Set<String>) {
        self.tables = tables; self.edges = edges; self.junctions = junctions
        byName = Dictionary(tables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var keys: [String: Set<String>] = [:]
        for t in tables { keys[t.name] = Set(t.primaryKey) }
        for e in edges { keys[e.from, default: []].insert(e.fromColumn); keys[e.to, default: []].insert(e.toColumn) }
        keyColumns = keys
    }

    public func table(_ name: String) -> TableInfo? { byName[name] }
    public func neighbors(_ name: String) -> [String] {
        Array(Set(edges.filter { $0.from != $0.to }.compactMap { $0.from == name ? $0.to : $0.to == name ? $0.from : nil })).sorted()
    }
    public var isolated: Set<String> { Set(tables.map(\.name)).subtracting(edges.flatMap { [$0.from, $0.to] }) }

    /// Visible subgraph. Hiding junctions draws a many-to-many edge between their two parents.
    public func filtered(hideJunctions: Bool = false, hideIsolated: Bool = false, showInferred: Bool = true, keep: Set<String>? = nil) -> SchemaGraph {
        var drop = Set(tables.map(\.name)).subtracting(keep ?? Set(tables.map(\.name)))
        var es = edges.filter { showInferred || $0.kind != .inferred }
        if hideJunctions {
            for j in junctions.sorted() {
                let parents = es.filter { $0.from == j && $0.to != j }
                if parents.count == 2, parents[0].to != parents[1].to {
                    es.append(MapEdge(from: parents[0].to, fromColumn: "", to: parents[1].to, toColumn: "", kind: .declared, manyToMany: true))
                }
            }
            drop.formUnion(junctions)
        }
        if hideIsolated { drop.formUnion(SchemaGraph(tables: tables, edges: es, junctions: junctions).isolated) }
        return SchemaGraph(tables: tables.filter { !drop.contains($0.name) },
                           edges: es.filter { !drop.contains($0.from) && !drop.contains($0.to) }, junctions: junctions.subtracting(drop))
    }

    public func shownColumns(_ t: TableInfo, _ detail: MapDetail) -> [ColumnInfo] {
        switch detail {
        case .names: []
        case .keys: t.columns.filter { keyColumns[t.name]?.contains($0.name) ?? false }
        case .all: t.columns
        }
    }

    // MARK: inference

    /// `x_id` → table `x` / `xs` / `xes` / `xies` with an `id` column of a compatible type, when no relation is declared on that column.
    static func inferRelations(_ tables: [TableInfo], skipping taken: Set<String>) -> [MapEdge] {
        let by = Dictionary(tables.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [MapEdge] = []
        for t in tables {
            for c in t.columns where !c.isPrimaryKey && !taken.contains(t.name + "." + c.name) {
                let n = c.name.lowercased()
                guard n.hasSuffix("_id"), n.count > 3 else { continue }
                let stem = String(n.dropLast(3))
                let names = [stem, stem + "s", stem + "es"] + (stem.hasSuffix("y") ? [String(stem.dropLast()) + "ies"] : [])
                guard let target = names.lazy.compactMap({ by[$0] }).first(where: { $0.name != t.name }),
                      let key = target.columns.first(where: { $0.name.lowercased() == "id" }), typeClass(key.type) == typeClass(c.type) else { continue }
                out.append(MapEdge(from: t.name, fromColumn: c.name, to: target.name, toColumn: key.name, kind: .inferred, optional: c.nullable))
            }
        }
        return out
    }

    static func typeClass(_ type: String) -> String {
        let s = type.lowercased()
        if s.hasPrefix("interval") { return "interval" }
        if s.contains("int") || s.contains("serial") { return "int" }
        if s.contains("char") || s.contains("text") { return "text" }
        if s.contains("numeric") || s.contains("decimal") || s.contains("float") || s.contains("double") || s.contains("real") { return "num" }
        return String(s.prefix { $0 != "(" })
    }

    // MARK: path

    /// Shortest join path over declared + virtual relations (inferred ones are suggestions, not joins). Ties break alphabetically.
    public func path(from a: String, to b: String) -> JoinPath? {
        guard byName[a] != nil, byName[b] != nil else { return nil }
        let joins = edges.filter { $0.kind != .inferred && $0.from != $0.to && !$0.manyToMany }
        var prev: [String: (String, MapEdge)] = [:]
        var seen: Set = [a]
        var queue = [a]
        while !queue.isEmpty, !seen.contains(b) {
            let n = queue.removeFirst()
            let next = joins.compactMap { e -> (String, MapEdge)? in e.from == n ? (e.to, e) : e.to == n ? (e.from, e) : nil }
                .sorted { ($0.0, $0.1.fromColumn) < ($1.0, $1.1.fromColumn) }
            for (m, e) in next where seen.insert(m).inserted { prev[m] = (n, e); queue.append(m) }
        }
        guard seen.contains(b) else { return nil }
        var tables = [b], steps: [MapEdge] = []
        while let (p, e) = prev[tables[0]] { tables.insert(p, at: 0); steps.insert(e, at: 0) }
        return JoinPath(tables: tables, steps: steps)
    }

    public func joinSQL(_ p: JoinPath, engine: Engine) -> String {
        var aliases: [String: String] = [:]
        var used = Set<String>()
        for t in p.tables {
            var base = t.split(separator: "_").compactMap(\.first).map { String($0).lowercased() }.joined()
            if ["as", "on", "or", "by", "in", "is", "if", "do", "to", "no", "of", "at"].contains(base) { base += "_" }
            var a = base, i = 1
            while !used.insert(a).inserted { i += 1; a = base + String(i) }
            aliases[t] = a
        }
        func ident(_ s: String) -> String { s.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil ? s : quoteIdent(s, engine) }
        func name(_ t: String) -> String {
            let s = byName[t]?.schema ?? ""
            return engine == .postgres && s != "public" && !s.isEmpty ? ident(s) + "." + ident(t) : ident(t)
        }
        var lines = ["SELECT \(aliases[p.tables[0]]!).*" + (p.tables.count > 1 ? ", \(aliases[p.tables.last!]!).*" : ""),
                     "FROM \(name(p.tables[0])) \(aliases[p.tables[0]]!)"]
        for (i, e) in p.steps.enumerated() {
            let prior = p.tables[i], t = p.tables[i + 1]
            let (tc, pc) = e.from == t ? (e.fromColumn, e.toColumn) : (e.toColumn, e.fromColumn)
            lines.append("JOIN \(name(t)) \(aliases[t]!) ON \(aliases[t]!).\(ident(tc)) = \(aliases[prior]!).\(ident(pc))")
        }
        return lines.joined(separator: "\n") + ";"
    }

    // MARK: filter

    /// Subsequence match ("ordit" finds order_items), case-insensitive.
    public static func fuzzy(_ query: String, _ text: String) -> Bool {
        var it = text.lowercased().makeIterator()
        return query.lowercased().allSatisfy { ch in while let c = it.next() { if c == ch { return true } }; return false }
    }
    /// Tables whose name or any column name matches.
    public func matching(_ query: String) -> Set<String> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Set(tables.map(\.name)) }
        return Set(tables.filter { t in Self.fuzzy(q, t.name) || t.columns.contains { Self.fuzzy(q, $0.name) } }.map(\.name))
    }
}
