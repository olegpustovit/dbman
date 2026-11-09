import DBCore
import DBStore
import Foundation
import MCP

/// overlay.*, views.*, relations.add, notes.set, saved.*: everything an agent may write, and all of it lands in its own layer of the store (SPEC §1.10).
extension MCPService {
    func overlayTool(_ name: String, _ a: [String: Value], _ c: ConnectionRow, _ s: DatabaseSession, perm: Permission, agent: String, trace: Trace) async throws -> Value {
        guard Catalogue.tools.contains(where: { $0.name == name }) else { throw ToolError("UNKNOWN_TOOL", name) }
        if Catalogue.writers.contains(name), perm.level != "overlay" {
            throw ToolError("PERMISSION_DENIED", "\(perm.level.uppercased()) on \(c.name); needs OVERLAY", status: "denied")
        }
        let store = b.store, mine = Store.mineID(c.id)
        let scope = try OverlayEngine.scope(store, connection: c.id, agent: agent)
        let layerNames = Dictionary(uniqueKeysWithValues: try store.layers(c.id).map { ($0.id, $0.name) })
        let sc = try await schema(c, s)
        let hidden = try store.hiddenColumns(connection: c.id)
        func own() throws -> String { trace.status = "overlay"; return try store.agentLayer(c.id, agent: agent) }
        func text(_ k: String) throws -> String {
            guard let v = a[k]?.stringValue, !v.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError("INVALID_ARGUMENT", "\(k) is required") }
            return v
        }
        func column(_ t: TableInfo, _ n: String) throws -> String {
            guard let col = t.columns.first(where: { $0.name.lowercased() == n.lowercased() }) else { throw ToolError("NOT_FOUND", "column \"\(n)\" in \(t.name)") }
            return col.name
        }

        switch name {
        case "overlay.status":
            guard let layer = scope.own else {
                return ["layer": .null, "items": 0, "note": "nothing recorded yet; overlay.patch_rows creates your layer"]
            }
            try await OverlayEngine.check(store, s, sc, connection: c.id, layers: [layer])
            let items = try store.items(c.id, layers: [layer])
            var counts: [String: Value] = [:]
            for k in ["row_patch", "view", "relation", "note", "saved_query"] { counts[k] = .int(items.filter { $0.kind == k }.count) }
            var out: [String: Value] = ["layer": .string(layerNames[layer] ?? layer), "items": .int(items.count), "counts": .object(counts),
                                        "stale": .array(items.filter { $0.status == "stale" }.map { ["table": .string($0.table ?? ""), "pk": .string($0.pk ?? "")] })]
            if let last = items.map(\.updated).max() { out["last_activity"] = .string(ISO8601DateFormatter().string(from: last)) }
            if let d = store.discardNote(layer: layer) { out["discarded"] = ["note": .string(d.note), "at": .string(ISO8601DateFormatter().string(from: d.at))] }
            return .object(out)

        case "overlay.patch_rows":
            return try await patchRows(a, c, s, sc, layer: try own(), trace: trace)

        case "overlay.diff":
            guard let layer = scope.own else { return ["patches": [], "other": []] }
            let current = try await OverlayEngine.check(store, s, sc, connection: c.id, layers: [layer])
            let only = a["table"]?.stringValue?.lowercased()
            let items = try store.items(c.id, layers: [layer])
            let patches: [Value] = items.compactMap { i in
                guard let p = OverlayEngine.patch(i), only == nil || p.table.lowercased() == only else { return nil }
                var o: [String: Value] = ["table": .string(p.table), "op": .string(p.op.rawValue), "pk": cells(p.key, hidden: hidden), "status": .string(i.status)]
                if !p.before.isEmpty { o["before"] = cells(p.before, hidden: hidden) }
                if !p.after.isEmpty { o["after"] = cells(p.after, hidden: hidden) }
                if p.stale { o["database_now"] = current[i.id].map { cells($0, hidden: hidden) } ?? .string("row no longer exists") }
                return .object(o)
            }
            let other: [Value] = only != nil ? [] : items.filter { $0.kind != "row_patch" }.map { ["kind": .string($0.kind), "name": .string($0.name ?? "")] }
            trace.rows = patches.count
            return ["patches": .array(patches), "other": .array(other)]

        case "overlay.reset":
            guard let layer = scope.own else { return ["discarded": 0] }
            let n = try store.items(c.id, layers: [layer]).count
            try store.discard(layer: layer, note: nil)
            trace.status = "overlay"
            return ["discarded": .int(n)]

        case "views.list", "saved.list":
            let kind = name == "views.list" ? "view" : "saved_query"
            return .array(scope.items.filter { $0.kind == kind }.map {
                ["name": .string($0.name ?? ""), "sql": .string(OverlayEngine.sql($0)), "layer": .string($0.layer == mine ? "MINE" : layerNames[$0.layer] ?? ""), "own": .bool($0.layer != mine)]
            })

        case "views.create", "views.replace":
            let n = try text("name"), sql = try readStatement(a["sql"]?.stringValue, c, perm)
            guard n.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw ToolError("INVALID_ARGUMENT", "name must be a plain identifier") }
            let layer = try own()
            let have = try store.items(c.id, layers: [layer], kind: "view").contains { $0.name?.lowercased() == n.lowercased() }
            if name == "views.create", have { throw ToolError("ALREADY_EXISTS", "you already have a view \"\(n)\"; use views.replace") }
            if name == "views.replace", !have { throw ToolError("NOT_FOUND", "no view \"\(n)\" in your layer; use views.create") }
            if sc.tables.contains(where: { $0.name.lowercased() == n.lowercased() }) { throw ToolError("NAME_TAKEN", "\"\(n)\" is a real table or view in \(c.name); pick another name") }
            // validate by planning the expanded statement, with this view in place of any earlier one of the same name
            let others = scope.items.filter { $0.kind == "view" && $0.name?.lowercased() != n.lowercased() }
            let probe = Overlay.expand("SELECT * FROM \(n)", views: (others.compactMap { i in i.name.map { ($0, OverlayEngine.sql(i)) } }) + [(n, sql)], mysql: c.engine == "mysql").sql
            do { _ = try await timed(5000, s) { try await s.explain(probe, analyze: false) } } catch let e as ToolError { throw ToolError("INVALID_VIEW", e.detail) }
            try store.addItem(layer: layer, kind: "view", name: n, payload: OverlayEngine.payload(sql: sql))
            return ["view": .string(n), "layer": .string(layerNames[layer] ?? "")]

        case "views.drop":
            let n = try text("name"), layer = try own()
            let ids = try store.items(c.id, layers: [layer], kind: "view").filter { $0.name?.lowercased() == n.lowercased() }.map(\.id)
            guard !ids.isEmpty else { throw ToolError("NOT_FOUND", "no view \"\(n)\" in your layer") }
            try store.setStatus(ids, "discarded")
            return ["dropped": .string(n)]

        case "relations.add":
            func end(_ k: String) throws -> (TableInfo, String) {
                let v = try text(k), dot = v.lastIndex(of: ".")
                guard let dot, let t = sc.tables.first(where: { $0.name.lowercased() == v[..<dot].lowercased() }) else { throw ToolError("INVALID_ARGUMENT", "\(k) must be table.column of an existing table") }
                return (t, try column(t, String(v[v.index(after: dot)...])))
            }
            let (ft, fc) = try end("from"), (tt, tc) = try end("to"), layer = try own()
            let payload = String(decoding: try JSONEncoder().encode(VirtualRelation(fromTable: ft.name, fromColumn: fc, toTable: tt.name, toColumn: tc)), as: UTF8.self)
            try store.addItem(layer: layer, kind: "relation", name: "\(ft.name).\(fc) -> \(tt.name).\(tc)", payload: payload)
            return ["relation": .string("\(ft.name).\(fc) -> \(tt.name).\(tc)")]

        case "notes.set":
            let t = try await table(a, c, s), body = a["text"]?.stringValue ?? ""
            guard body.count <= 2000 else { throw ToolError("INVALID_ARGUMENT", "text is at most 2000 characters") }
            let col = try a["column"]?.stringValue.map { try column(t, $0) }, key = col.map { "\(t.name).\($0)" } ?? t.name, layer = try own()
            let old = try store.items(c.id, layers: [layer], kind: "note").filter { $0.name == key }.map(\.id)
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try store.setStatus(old, "discarded"); return ["removed": .string(key)] }
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["table": t.name, "column": col as Any, "text": body].compactMapValues { $0 }), as: UTF8.self)
            try store.addItem(layer: layer, kind: "note", name: key, payload: payload)
            return ["note": .string(key)]

        case "saved.save":
            let n = try text("name"), sql = try readStatement(a["sql"]?.stringValue, c, perm)
            try store.addItem(layer: try own(), kind: "saved_query", name: n, payload: OverlayEngine.payload(sql: sql))
            return ["saved": .string(n)]

        default:
            throw ToolError("UNKNOWN_TOOL", name)
        }
    }

    /// Cells as JSON, hidden columns masked (before/after/current values can carry the database's hidden values).
    private func cells(_ m: [String: Cell], hidden: Set<String>) -> Value {
        .object(Dictionary(uniqueKeysWithValues: m.map { k, v in (k, hidden.contains(k.lowercased()) ? Self.value(Rules.redacted) : Self.value(v)) }))
    }

    private func patchRows(_ a: [String: Value], _ c: ConnectionRow, _ s: DatabaseSession, _ sc: SchemaSnapshot, layer: String, trace: Trace) async throws -> Value {
        let store = b.store, t = try await table(a, c, s), pk = t.primaryKey
        guard t.kind == .table else { throw ToolError("INVALID_ARGUMENT", "\(t.name) is a view; patch a table") }
        guard !pk.isEmpty else { throw ToolError("INVALID_ARGUMENT", "\(t.name) has no primary key; patches are keyed by primary key") }
        guard case .array(let list)? = a["patches"], !list.isEmpty, list.count <= 200 else { throw ToolError("INVALID_ARGUMENT", "patches must hold 1 to 200 entries") }
        func cell(_ v: Value) throws -> Cell {
            switch v {
            case .null: return .null
            case .bool(let x): return .bool(x)
            case .int(let x): return .integer(Int64(x))
            case .double(let x): return .real(x)
            case .string(let x): return .text(x)
            default: throw ToolError("INVALID_ARGUMENT", "values must be string, number, boolean or null")
            }
        }
        func named(_ v: Value?, _ what: String, _ i: Int) throws -> [String: Cell] {
            guard case .object(let o)? = v ?? .object([:]) else { throw ToolError("INVALID_ARGUMENT", "patch \(i): \(what) must be an object") }
            return try Dictionary(o.map { k, x in
                guard let col = t.columns.first(where: { $0.name.lowercased() == k.lowercased() }) else { throw ToolError("NOT_FOUND", "patch \(i): column \"\(k)\" in \(t.name)") }
                return (col.name, try cell(x))
            }, uniquingKeysWith: { $1 })
        }
        var parsed: [(op: RowPatch.Op, key: [String: Cell], values: [String: Cell])] = []
        for (i, p) in list.enumerated() {
            guard case .object(let o) = p, let op = o["op"]?.stringValue.flatMap(RowPatch.Op.init) else { throw ToolError("INVALID_ARGUMENT", "patch \(i): op must be insert, update or delete") }
            let key = try named(o["pk"], "pk", i), values = try named(o["values"], "values", i)
            guard Set(key.keys) == Set(pk) else { throw ToolError("INVALID_ARGUMENT", "patch \(i): pk must be exactly \(pk.joined(separator: ", "))") }
            if op == .update, values.isEmpty || !Set(values.keys).isDisjoint(with: pk) { throw ToolError("INVALID_ARGUMENT", "patch \(i): update needs values and cannot change the primary key") }
            if op == .delete, !values.isEmpty { throw ToolError("INVALID_ARGUMENT", "patch \(i): delete takes no values") }
            parsed.append((op, key, values))
        }
        let now = try await OverlayEngine.fetch(s, t, keys: parsed.map(\.key))
        let existing = try store.items(c.id, layers: [layer], kind: "row_patch").compactMap { i in OverlayEngine.patch(i).map { (i, $0) } }.filter { $0.1.table == t.name }
        for (i, p) in parsed.enumerated() {
            let k = Overlay.keyString(pk, p.key), cur = now[k]
            var row: [String: Cell] = [:]
            if let cur { row = Dictionary(zip(cur.columns, cur.row), uniquingKeysWith: { a, _ in a }) }
            if p.op == .insert, cur != nil { throw ToolError("INVALID_ARGUMENT", "patch \(i): row \(k) already exists; use update") }
            if p.op != .insert, cur == nil { throw ToolError("NOT_FOUND", "patch \(i): no row with that primary key in \(t.name)") }
            var op = p.op, before = p.op == .update ? row.filter { p.values.keys.contains($0.key) } : (p.op == .delete ? row : [:]), after = p.values
            var base = cur.map { Overlay.hash(columns: $0.columns, row: $0.row) }
            if let (item, old) = existing.first(where: { Overlay.keyString(pk, $0.1.key) == k }) { // fold into the patch this layer already holds for the row
                switch (old.op, p.op) {
                case (.insert, .delete): try store.setStatus([item.id], "discarded"); continue
                case (.insert, .update): op = .insert; after = old.after.merging(p.values) { $1 }; before = [:]; base = nil
                case (.update, .update): before = before.merging(old.before) { $1 }; after = old.after.merging(p.values) { $1 }; base = old.baseHash ?? base
                case (.update, .delete): base = old.baseHash ?? base
                default: break
                }
            }
            try store.putPatch(layer: layer, table: t.name, pk: Overlay.json(p.key), op: op.rawValue, before: before.isEmpty ? nil : Overlay.json(before), after: op == .delete ? nil : Overlay.json(after), baseHash: base)
        }
        trace.rows = parsed.count
        return ["patched": .int(parsed.count), "table": .string(t.name), "layer": .string((try store.layers(c.id).first { $0.id == layer })?.name ?? "")]
    }
}
