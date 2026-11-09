import DBCore
import DBStore
import Foundation
import MCP

/// dashboard.*: specs live in the agent's own layer as `dashboard` overlay items; the human reviews and adopts them (SPEC §1.7).
extension MCPService {
    static func components() throws -> Value { try JSONDecoder().decode(Value.self, from: DashCatalog.schemaJSON()) }

    func dashboardTool(_ name: String, _ a: [String: Value], _ c: ConnectionRow, _ s: DatabaseSession, perm: Permission, agent: String, trace: Trace) async throws -> Value {
        if Catalogue.writers.contains(name), perm.level != "overlay" {
            throw ToolError("PERMISSION_DENIED", "\(perm.level.uppercased()) on \(c.name); needs OVERLAY", status: "denied")
        }
        let store = b.store, mine = Store.mineID(c.id)
        let scope = try OverlayEngine.scope(store, connection: c.id, agent: agent)
        let names = Dictionary(uniqueKeysWithValues: try store.layers(c.id).map { ($0.id, $0.name) })
        func find(_ id: String?) throws -> OverlayItem {
            guard let id, let i = scope.items.first(where: { $0.kind == "dashboard" && $0.id == id }) else { throw ToolError("NOT_FOUND", "no dashboard \"\(id ?? "")\" visible to you; see dashboard.list") }
            return i
        }
        func object(_ v: Value?) throws -> Any {
            guard let v, let d = try? JSONEncoder().encode(v), let o = try? JSONSerialization.jsonObject(with: d) else { throw ToolError("INVALID_ARGUMENT", "valid JSON is required") }
            return o
        }

        switch name {
        case "dashboard.list":
            return .array(scope.items.filter { $0.kind == "dashboard" }.map { i in
                let n = (try? DashboardSpec.parse(i.payload))?.widgets.count ?? 0
                return ["id": .string(i.id), "title": .string(i.name ?? ""), "layer": .string(i.layer == mine ? "MINE" : names[i.layer] ?? ""), "own": .bool(i.layer != mine), "widgets": .int(n)]
            })

        case "dashboard.get":
            let i = try find(a["id"]?.stringValue)
            return ["id": .string(i.id), "layer": .string(i.layer == mine ? "MINE" : names[i.layer] ?? ""), "spec": try JSONDecoder().decode(Value.self, from: Data(i.payload.utf8))]

        case "dashboard.create":
            var raw = a["spec"]
            if case .string(let t)? = raw { raw = try? JSONDecoder().decode(Value.self, from: Data(t.utf8)) } // some clients send the object as text
            guard case .object? = raw else { throw ToolError("INVALID_ARGUMENT", "spec must be a JSON object; see dashboard.components") }
            var spec = try parse(try object(raw))
            spec.connection = c.name
            guard !spec.widgets.isEmpty else { throw ToolError("INVALID_SPEC", "at least one widget is required") }
            let layer = try store.agentLayer(c.id, agent: agent), names = Dictionary(uniqueKeysWithValues: try store.layers(c.id).map { ($0.id, $0.name) })
            trace.status = "overlay"
            let result = try await evaluate(spec, c, s, perm: perm, agent: agent, trace: trace)
            let id = try store.addItem(layer: layer, kind: "dashboard", name: spec.title, payload: spec.json())
            return .object(result.merging(["id": .string(id), "layer": .string(names[layer] ?? agent)]) { $1 })

        case "dashboard.update":
            let i = try find(a["id"]?.stringValue)
            guard i.layer != mine, i.layer == scope.own else { throw ToolError("PERMISSION_DENIED", "only your own dashboards can be changed; MINE belongs to the human", status: "denied") }
            guard case .array(let ops)? = a["ops"], !ops.isEmpty, let list = try object(.array(ops)) as? [[String: Any]] else { throw ToolError("INVALID_ARGUMENT", "ops must be a non-empty array of {op, path, value}") }
            var spec: DashboardSpec
            do { spec = try JSONPatch.apply(list, toSpec: i.payload) } catch let e as DashError { throw ToolError("INVALID_PATCH", e.message) }
            spec.connection = c.name
            try fatal(spec)
            trace.status = "overlay"
            let result = try await evaluate(spec, c, s, perm: perm, agent: agent, trace: trace)
            try store.setPayload(i.id, name: spec.title, spec.json())
            return .object(result.merging(["id": .string(i.id), "layer": .string(names[i.layer] ?? agent)]) { $1 })

        default:
            throw ToolError("UNKNOWN_TOOL", name)
        }
    }

    private func parse(_ o: Any) throws -> DashboardSpec {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { throw ToolError("INVALID_SPEC", "spec is not JSON") }
        let spec: DashboardSpec
        do { spec = try DashboardSpec.parse(String(decoding: d, as: UTF8.self)) } catch let e as DashError { throw ToolError("INVALID_SPEC", e.message) }
        try fatal(spec)
        return spec
    }

    /// Layout and structure problems reject the spec; per-widget problems are reported per widget instead.
    private func fatal(_ spec: DashboardSpec) throws {
        let bad = spec.validate().filter(\.fatal)
        if !bad.isEmpty { throw ToolError("INVALID_SPEC", bad.map { ($0.widget.map { "\($0): " } ?? "") + $0.message }.joined(separator: "; ")) }
    }

    /// Runs every widget query through the same read path as query.run (redaction, prod guard, timeout, cap) with variables at their defaults.
    private func evaluate(_ spec: DashboardSpec, _ c: ConnectionRow, _ s: DatabaseSession, perm: Permission, agent: String, trace: Trace) async throws -> [String: Value] {
        let (cap, timeoutMs) = limits(c, perm), engine = Engine(rawValue: c.engine) ?? .sqlite
        let issues = Dictionary(grouping: spec.validate(), by: { $0.widget ?? "" })
        var out: [Value] = [], failed = 0, rows = 0
        for w in spec.widgets {
            var o: [String: Value] = ["id": .string(w.id)]
            func fail(_ m: String) { o["ok"] = false; o["error"] = .string(m); failed += 1 }
            if let why = issues[w.id]?.first?.message { fail("INVALID_WIDGET (\(why))") }
            else if let q = w.query, DashSource.split(q) == nil { // local sources never reach the database
                let sql = DashSQL.bind(q, variables: spec.variables, engine: engine)
                do {
                    let r = try await query(["sql": .string(sql), "limit": .int(min(cap, 100))], c, s, perm: perm, cap: cap, timeoutMs: timeoutMs, agent: agent, trace: trace)
                    let cols = r.objectValue?["columns"]?.arrayValue?.compactMap(\.stringValue) ?? [], n = r.objectValue?["rows"]?.arrayValue?.count ?? 0
                    // zero rows: Postgres/MySQL report no column names, so nothing can be checked
                    if !cols.isEmpty, let missing = w.missingColumn(in: cols) { fail("QUERY_FAILED (column `\(missing)` not found in the result; it has \(cols.joined(separator: ", ")))") }
                    else { o["ok"] = true; o["rows"] = .int(n); rows += n }
                } catch let e as ToolError { fail(e.message) }
            } else { o["ok"] = true }
            out.append(.object(o))
        }
        trace.rows = rows
        return ["widgets": .array(out), "failed": .int(failed), "ok": .int(spec.widgets.count - failed)]
    }
}
