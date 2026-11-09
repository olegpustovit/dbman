import DBCore
import DBStore
import Foundation
import MCP

/// Tool catalogue. Names, arguments and error strings follow SPEC §2; `connection` (name or id) is on every tool except `connections.*`.
enum Catalogue {
    static func tool(_ name: String, _ desc: String, _ props: [(String, String, String)] = [], required: [String] = [], connection: Bool = true) -> Tool {
        var p: [String: Value] = [:]
        if connection { p["connection"] = ["type": "string", "description": "Connection name or id (see connections.list)"] }
        for (k, type, d) in props { p[k] = ["type": .string(type), "description": .string(d)] }
        let req = (connection ? ["connection"] : []) + required
        return Tool(name: name, description: desc, inputSchema: ["type": "object", "properties": .object(p), "required": .array(req.map { .string($0) })],
                    annotations: .init(readOnlyHint: !name.hasSuffix(".add") && !name.hasSuffix(".remove") && name != "ui.open" && !writers.contains(name)))
    }

    /// Tools that write into the agent's own overlay layer (never the database); they need OVERLAY.
    static let writers: Set = ["overlay.patch_rows", "overlay.reset", "views.create", "views.replace", "views.drop", "relations.add", "notes.set", "saved.save", "dashboard.create", "dashboard.update"]

    static let tools: [Tool] = [
        tool("connections.list", "List the databases DBMan lets you use: name, engine, env tag (production is guarded), status and YOUR permission level on each.", connection: false),
        tool("connections.add", "Ask the human to add a database. Never pass a password: DBMan shows a secure credential sheet and the call returns NEEDS_APPROVAL until they finish.",
             [("url", "string", "postgres://user@host:5432/db, mysql://… or a path to a .sqlite file (no password)"), ("name", "string", "Display name"),
              ("env", "string", "local | staging | production")], required: ["name"], connection: false),
        tool("connections.test", "Open the connection and run SELECT 1; returns ok and latency."),
        tool("connections.remove", "Ask the human to remove a connection (needs approval in DBMan).", connection: true),
        tool("schema.tables", "List tables and views with estimated row counts and column counts. Start here."),
        tool("schema.describe", "Columns (type, nullability, PK, FK), indexes, row estimate and referencing tables of one table. Columns marked hidden return «redacted» in query results.",
             [("table", "string", "Table name")], required: ["table"]),
        tool("schema.graph", "Tables as nodes and declared foreign keys as edges."),
        tool("schema.search", "Find tables and columns whose name contains the text.", [("text", "string", "Case-insensitive substring")], required: ["text"]),
        tool("query.run", "Run ONE read-only statement (SELECT/WITH/VALUES/TABLE/SHOW). Writes are never executed (WRITE_REDIRECTED; record changes with overlay.patch_rows). Your virtual views can be used by name and your row patches are merged into the result. Results are capped; when truncated is true pass the returned cursor to get the next page. Production queries are EXPLAINed first and may be BLOCKED_BY_PROD_GUARD: add a filter on an indexed column.",
             [("sql", "string", "A single statement"), ("limit", "integer", "Rows to return, at most the row cap"), ("cursor", "string", "From a previous truncated result; sql may then be omitted"),
              ("layer", "string", "Optional: \"database\" = raw database only, \"mine\" = database + the human's layer. Default: database + MINE + your own layer")]),
        tool("query.explain", "Estimated plan (no execution) as a tree with estimated rows and cost.", [("sql", "string", "A single read statement")], required: ["sql"]),
        tool("query.sample", "First rows of a table (SELECT * … LIMIT n).", [("table", "string", "Table name"), ("n", "integer", "Rows, default 10")], required: ["table"]),
        tool("stats.column", "Profile of one column from a sample: distinct count, null fraction, min/max/median, histogram, top values (not for hidden columns).",
             [("table", "string", "Table name"), ("column", "string", "Column name")], required: ["table", "column"]),
        tool("overlay.status", "Your overlay layer on this connection: item counts, stale patches, and the note if the human discarded something."),
        Tool(name: "overlay.patch_rows", description: "Record row changes in YOUR layer (the database is never written; the human reviews them and may adopt or apply them). Rows are keyed by primary key. Needs OVERLAY.",
             inputSchema: ["type": "object", "required": ["connection", "table", "patches"], "properties": [
                "connection": ["type": "string", "description": "Connection name or id"], "table": ["type": "string", "description": "Table name"],
                "patches": ["type": "array", "description": "At most 200", "items": ["type": "object", "required": ["op", "pk"], "properties": [
                    "op": ["type": "string", "enum": ["insert", "update", "delete"]],
                    "pk": ["type": "object", "description": "Primary key column → value"],
                    "values": ["type": "object", "description": "Column → new value (insert, update)"]]]]]],
             annotations: .init(readOnlyHint: false)),
        tool("overlay.diff", "Your layer compared with the database: per patched row the before/after values, and both values when the row changed in the database since (stale).",
             [("table", "string", "Only this table")]),
        tool("overlay.reset", "Discard everything in your layer (history stays in the store)."),
        tool("views.list", "Virtual views visible to you (the human's and yours). Use them by name in query.run; they are expanded as CTEs, no DDL."),
        tool("views.create", "Create a virtual view in your layer from a SELECT. Validated with EXPLAIN. The name must not be a real table or view.", [("name", "string", "Identifier"), ("sql", "string", "A single SELECT")], required: ["name", "sql"]),
        tool("views.replace", "Replace the SQL of one of your own virtual views.", [("name", "string", "Identifier"), ("sql", "string", "A single SELECT")], required: ["name", "sql"]),
        tool("views.drop", "Remove one of your own virtual views.", [("name", "string", "Identifier")], required: ["name"]),
        tool("relations.add", "Record a virtual foreign key in your layer (never DDL).", [("from", "string", "table.column"), ("to", "string", "table.column")], required: ["from", "to"]),
        tool("notes.set", "Describe a table or column for the human (shown in the table structure). Empty text removes the note.",
             [("table", "string", "Table name"), ("column", "string", "Optional column"), ("text", "string", "The note")], required: ["table", "text"]),
        tool("saved.list", "Saved queries visible to you."),
        tool("saved.save", "Save a query by name in your layer.", [("name", "string", "Name"), ("sql", "string", "A single read statement")], required: ["name", "sql"]),
        tool("dashboard.components", "The dashboard component catalog (19 types, required encodings, minimum sizes) and the JSON Schema of a dashboard spec. Read it before dashboard.create.", connection: false),
        tool("dashboard.list", "Dashboards visible to you on this connection: the human's (MINE) and your own."),
        tool("dashboard.get", "One dashboard's spec. `connection` may be omitted.", [("id", "string", "Dashboard id from dashboard.list")], required: ["id"]),
        Tool(name: "dashboard.create", description: "Propose a dashboard. It lands in YOUR layer as NEW; the human reviews it widget by widget and adopts it into MINE. Every widget query is validated and run read-only (redaction and the prod guard apply); the reply lists per-widget errors, which the human also sees. Needs OVERLAY. A dashboard with the same title in your layer is replaced.",
             inputSchema: ["type": "object", "required": ["connection", "spec"], "properties": [
                "connection": ["type": "string", "description": "Connection name or id"],
                "spec": ["type": "object", "description": "Dashboard spec; schema and component catalog from dashboard.components"]]],
             annotations: .init(readOnlyHint: false)),
        Tool(name: "dashboard.update", description: "Change one of your own dashboards with a JSON patch (RFC 6902 subset: add, remove, replace). The result is validated and re-run like dashboard.create. Needs OVERLAY.",
             inputSchema: ["type": "object", "required": ["id", "ops"], "properties": [
                "connection": ["type": "string", "description": "Connection name or id (optional)"], "id": ["type": "string", "description": "Dashboard id"],
                "ops": ["type": "array", "description": "e.g. [{\"op\":\"replace\",\"path\":\"/widgets/0/query\",\"value\":\"select ...\"}]",
                        "items": ["type": "object", "required": ["op", "path"], "properties": ["op": ["enum": ["add", "remove", "replace"]], "path": ["type": "string"], "value": [:]]]]]],
             annotations: .init(readOnlyHint: false)),
        tool("ui.open", "Show the human something in DBMan: brings the app to front at a table, a query or a dashboard.",
             [("route", "string", "table | query | dashboard"), ("selection", "string", "Table name for table, SQL text for query, id or title for dashboard (none: the default Overview)")], required: ["route"]),
    ]
}

/// Per-call bookkeeping for the activity row.
final class Trace { var connection: String?; var rows: Int?; var status: String? }

extension MCPService {
    // MARK: call pipeline: resolve → gate → run → activity

    func call(_ name: String, _ args: [String: Value], agent: String) async -> CallTool.Result {
        let t0 = Date(), trace = Trace()
        var status = "ok", failure: String?
        if agent == "unknown" { try? b.store.upsertAgent(id: agent, name: agent, version: nil) } // no initialize seen: still keep the activity row's FK valid
        var out: Value = .null
        do {
            guard Catalogue.tools.contains(where: { $0.name == name }) else { throw ToolError("UNKNOWN_TOOL", name) }
            out = try await run(name, args, agent: agent, trace: trace)
        } catch let e as ToolError {
            status = e.status; failure = e.message
        } catch {
            status = "error"; failure = ToolError("ERROR", error.localizedDescription).message
        }
        if failure == nil, let s = trace.status { status = s }
        let summary = (try? String(decoding: Self.encoder.encode(args), as: UTF8.self)) ?? ""
        try? b.store.logActivity(agent: agent, connection: trace.connection, tool: name, args: summary, ms: Int(Date().timeIntervalSince(t0) * 1000), rows: trace.rows, status: status, error: failure)
        if let failure { return .init(content: [.text(text: failure, annotations: nil, _meta: nil)], isError: true) }
        return .init(content: [.text(text: (try? String(decoding: Self.encoder.encode(out), as: UTF8.self)) ?? "null", annotations: nil, _meta: nil)])
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }()

    private func resolve(_ a: [String: Value]) throws -> ConnectionRow {
        guard let ref = a["connection"]?.stringValue else { throw ToolError("INVALID_ARGUMENT", "connection is required; see connections.list") }
        let all = try b.store.connections()
        guard let c = all.first(where: { $0.id == ref }) ?? all.first(where: { $0.name.lowercased() == ref.lowercased() }) else {
            throw ToolError("NOT_FOUND", "no connection \"\(ref)\"; see connections.list")
        }
        return c
    }

    /// The permission gate. The internal store holds the permission table itself, so no agent ever passes (SPEC §6, G21).
    private func gate(_ c: ConnectionRow, agent: String) throws -> Permission {
        if c.env == "system" { throw ToolError("PERMISSION_DENIED", "the DBMan internal store is not available to agents", status: "denied") }
        let p = try b.store.permission(agent: agent, connection: c)
        if p.level == "off" { throw ToolError("PERMISSION_DENIED", "OFF on \(c.name); needs READ", status: "denied") }
        return p
    }

    /// Row cap and statement timeout for this agent on this connection.
    func limits(_ c: ConnectionRow, _ perm: Permission) -> (cap: Int, timeoutMs: Int) {
        (perm.rowCap ?? b.store.setting("row_cap").flatMap(Int.init) ?? 500,
         perm.timeoutMs ?? (c.env == "production" ? 5000 : b.store.setting("timeout_ms").flatMap(Int.init) ?? 15000)) // shortcut: prod 5 s is a constant, make it a setting when asked
    }

    private func run(_ name: String, _ a: [String: Value], agent: String, trace: Trace) async throws -> Value {
        if name.hasPrefix("connections."), name != "connections.test", name != "connections.remove" {
            return name == "connections.list" ? try await list(agent) : try add(a, agent: agent)
        }
        if name == "dashboard.components" { return try Self.components() }
        var a = a
        if ["dashboard.get", "dashboard.update"].contains(name), a["connection"] == nil, let id = a["id"]?.stringValue, let hit = try b.store.item(id) { a["connection"] = .string(hit.connection) }
        let c = try resolve(a)
        trace.connection = c.id
        let perm = try gate(c, agent: agent)
        let (cap, timeoutMs) = limits(c, perm)

        switch name {
        case "connections.remove":
            _ = try b.store.addApproval(kind: "apply", agent: agent, connection: c.id, payload: #"{"action":"remove_connection"}"#) // kind 'apply': the table has no 'remove' kind, P6 adds the sheet
            throw ToolError("NEEDS_APPROVAL", "pending in DBMan", status: "blocked")
        case "ui.open":
            guard let route = a["route"]?.stringValue else { throw ToolError("INVALID_ARGUMENT", "route is required") }
            guard ["table", "query", "dashboard"].contains(route) else { throw ToolError("UNSUPPORTED", "route \(route) is not available; use table, query or dashboard") }
            await b.openUI(c, route, a["selection"]?.stringValue)
            return ["opened": true]
        default: break
        }

        let s = try await open(c)
        if name != "connections.test" { _ = try await schema(c, s) } // first load marks sensitive columns before any row can leave
        switch name {
        case "connections.test":
            let t0 = Date()
            _ = try await timed(timeoutMs, s) { try await s.run("SELECT 1", limit: 1) }
            return ["ok": true, "ms": .int(Int(Date().timeIntervalSince(t0) * 1000))]
        case "schema.tables":
            let sc = try await schema(c, s)
            return .array(sc.tables.map { ["name": .string($0.name), "kind": .string($0.kind.rawValue), "rows": .int(Int($0.rowCount)), "columns": .int($0.columns.count)] })
        case "schema.describe":
            return try await describe(try table(a, c, s), c, s)
        case "schema.graph":
            let sc = try await schema(c, s)
            // shortcut: declared foreign keys only; inferred edges arrive with the schema map (P5)
            return ["nodes": .array(sc.tables.map { ["table": .string($0.name), "rows": .int(Int($0.rowCount))] }),
                    "edges": .array(sc.tables.flatMap { t in t.columns.compactMap { col in col.foreignKey.map { ["from": .string("\(t.name).\(col.name)"), "to": .string("\($0.table).\($0.column)"), "declared": true] } } })]
        case "schema.search":
            let q = (a["text"]?.stringValue ?? "").lowercased()
            guard !q.isEmpty else { throw ToolError("INVALID_ARGUMENT", "text is required") }
            let sc = try await schema(c, s)
            var hits: [Value] = []
            for t in sc.tables {
                if t.name.lowercased().contains(q) { hits.append(["table": .string(t.name)]) }
                for col in t.columns where col.name.lowercased().contains(q) { hits.append(["table": .string(t.name), "column": .string(col.name), "type": .string(col.type)]) }
            }
            return .array(Array(hits.prefix(50)))
        case "query.run":
            return try await query(a, c, s, perm: perm, cap: cap, timeoutMs: timeoutMs, agent: agent, trace: trace)
        case "query.explain":
            let stmt = try expanded(try readStatement(a["sql"]?.stringValue, c, perm), try overlayScope(a, c, agent)).sql
            guard let plan = try await timed(timeoutMs, s, { try await s.explain(stmt, analyze: false) }) else { throw ToolError("UNSUPPORTED", "\(c.engine) returned no plan") }
            return ["plan": Self.tree(plan), "total_cost": .double(plan.cost)]
        case "query.sample":
            let t = try await table(a, c, s)
            let n = min(max(a["n"]?.intValue ?? 10, 1), cap)
            // shortcut: unguarded on production on purpose, the statement is a bare LIMIT scan; EXPLAIN-first applies to query.run
            let r = try await timed(timeoutMs, s) { try await s.run("SELECT * FROM \(quoteIdent(t.name, s.profile.engine)) LIMIT \(n)", limit: n) }
            return try await rows(r.columns, r.rows, truncated: false, cursor: nil, ms: r.elapsedMs, sql: "SELECT * FROM \(quoteIdent(t.name, s.profile.engine))", c, trace)
        case "stats.column":
            let t = try await table(a, c, s)
            guard let col = a["column"]?.stringValue, t.columns.contains(where: { $0.name == col }) else { throw ToolError("NOT_FOUND", "column \"\(a["column"]?.stringValue ?? "")\" in \(t.name)") }
            let all = try await timed(timeoutMs, s) { try await s.columnStats(table: t.name) }
            guard let st = all.first(where: { $0.column == col }) else { throw ToolError("NOT_FOUND", "no stats for \(col)") }
            let hidden = try b.store.hiddenColumns(connection: c.id).contains(col.lowercased())
            var out: [String: Value] = ["column": .string(col), "distinct_in_sample": st.distinct.map { .int($0) } ?? .null, "null_fraction": .double(st.nullFraction)]
            if hidden { out["hidden"] = true; return .object(out) } // values would leak the redacted cells
            out["min"] = st.min.map { .string($0) } ?? .null; out["max"] = st.max.map { .string($0) } ?? .null; out["median"] = st.median.map { .string($0) } ?? .null
            out["histogram"] = .array(st.histogram.map { .double($0) })
            out["top_values"] = .array(st.topValues.map { ["value": .string($0.value), "share": .double($0.share)] })
            return .object(out)
        default:
            if name.hasPrefix("dashboard.") { return try await dashboardTool(name, a, c, s, perm: perm, agent: agent, trace: trace) }
            return try await overlayTool(name, a, c, s, perm: perm, agent: agent, trace: trace)
        }
    }

    // MARK: connections.*

    private func list(_ agent: String) async throws -> Value {
        var out: [Value] = []
        for c in try b.store.agentVisibleConnections() {
            let p = try b.store.permission(agent: agent, connection: c)
            out.append(["name": .string(c.name), "id": .string(c.id), "engine": .string(c.engine), "env": .string(c.env),
                        "status": await b.isOpen(c) ? "open" : "idle", "permission": .string(p.level.uppercased())])
        }
        return .array(out)
    }

    private func add(_ a: [String: Value], agent: String) throws -> Value {
        guard let name = a["name"]?.stringValue, !name.isEmpty else { throw ToolError("INVALID_ARGUMENT", "name is required") }
        guard let url = a["url"]?.stringValue, let (p, password) = ConnectionURL.parseWithPassword(url) else { throw ToolError("INVALID_ARGUMENT", "url is required (postgres://user@host/db, mysql://…, or a .sqlite path)") }
        guard password == nil else { throw ToolError("INVALID_ARGUMENT", "passwords are never accepted over MCP; DBMan asks the human for it") }
        let env = a["env"]?.stringValue ?? "local"
        guard ["local", "staging", "production"].contains(env) else { throw ToolError("INVALID_ARGUMENT", "env must be local, staging or production") }
        let payload = Value.object(["name": .string(name), "engine": .string(p.engine.rawValue), "host": .string(p.host), "port": .int(p.port), "database": .string(p.database),
                                    "user": .string(p.user), "file_path": p.filePath.map { .string($0) } ?? .null, "env": .string(env)])
        // P6 builds the credential sheet; until then the request just waits in `approvals`.
        _ = try b.store.addApproval(kind: "credentials", agent: agent, connection: nil, payload: String(decoding: Self.encoder.encode(payload), as: UTF8.self))
        throw ToolError("NEEDS_APPROVAL", "pending in DBMan", status: "blocked")
    }

    // MARK: schema

    private func open(_ c: ConnectionRow) async throws -> DatabaseSession {
        do { return try await b.session(c) } catch { throw ToolError("CONNECTION_FAILED", error.localizedDescription) }
    }

    /// Cached 30 s. The first load of a connection also auto-marks sensitive columns (SPEC §1.4).
    func schema(_ c: ConnectionRow, _ s: DatabaseSession) async throws -> SchemaSnapshot {
        if let hit = await schemas.get(c.id) { return hit }
        let sc: SchemaSnapshot
        do { sc = try await s.schema() } catch { throw ToolError("QUERY_FAILED", error.localizedDescription) }
        let patterns = (b.store.setting("redaction_patterns").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? []
        try? b.store.autoMarkSensitive(connection: c.id, columns: Rules.sensitive(sc, patterns: patterns))
        await schemas.put(c.id, sc)
        return sc
    }

    func table(_ a: [String: Value], _ c: ConnectionRow, _ s: DatabaseSession) async throws -> TableInfo {
        guard let n = a["table"]?.stringValue else { throw ToolError("INVALID_ARGUMENT", "table is required") }
        let sc = try await schema(c, s)
        guard let t = sc.table(n) ?? sc.tables.first(where: { $0.name.lowercased() == n.lowercased() }) else { throw ToolError("NOT_FOUND", "table \"\(n)\" in \(c.name); see schema.tables") }
        return t
    }

    private func describe(_ t: TableInfo, _ c: ConnectionRow, _ s: DatabaseSession) async throws -> Value {
        let sc = try await schema(c, s), hidden = try b.store.hiddenColumns(connection: c.id)
        return ["table": .string(t.name), "kind": .string(t.kind.rawValue), "row_estimate": .int(Int(t.rowCount)),
                "columns": .array(t.columns.map { col in
                    var o: [String: Value] = ["name": .string(col.name), "type": .string(col.type), "nullable": .bool(col.nullable), "pk": .bool(col.isPrimaryKey)]
                    if let d = col.defaultValue { o["default"] = .string(d) }
                    if let f = col.foreignKey { o["references"] = .string("\(f.table).\(f.column)") }
                    if hidden.contains(col.name.lowercased()) { o["hidden"] = true }
                    return .object(o)
                }),
                "indexes": .array(t.indexes.map { ["name": .string($0.name), "columns": .array($0.columns.map { .string($0) }), "unique": .bool($0.unique)] }),
                "referenced_by": .array(t.referencedBy(in: sc).map { .string("\($0.table).\($0.column)") })]
    }

    // MARK: query

    /// One statement, read-only. The engine-level read-only session is the real guard; this gives agents the typed error.
    func readStatement(_ sql: String?, _ c: ConnectionRow, _ perm: Permission) throws -> String {
        guard let sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("INVALID_ARGUMENT", "sql is required") }
        let stmts = splitStatements(sql, mysql: c.engine == "mysql")
        guard stmts.count == 1 else { throw ToolError("INVALID_ARGUMENT", "one statement per call") }
        switch Rules.classify(stmts[0]) {
        case .read: return stmts[0]
        case .write:
            let need = perm.level == "read" ? "; overlay.patch_rows needs OVERLAY, this agent has READ" : ""
            throw ToolError("WRITE_REDIRECTED", "query.run never writes to \(c.name); use overlay.patch_rows to record the change in your own layer\(need)", status: "blocked")
        case .other:
            throw ToolError("UNSUPPORTED_STATEMENT", "query.run accepts SELECT, WITH, VALUES, TABLE, SHOW; use query.explain for plans")
        }
    }

    func query(_ a: [String: Value], _ c: ConnectionRow, _ s: DatabaseSession, perm: Permission, cap: Int, timeoutMs: Int, agent: String, trace: Trace) async throws -> Value {
        var sql = a["sql"]?.stringValue, start = 0
        if let tok = a["cursor"]?.stringValue {
            guard let cur = Cursor(token: tok) else { throw ToolError("INVALID_ARGUMENT", "unknown cursor") }
            sql = cur.sql; start = cur.offset
        }
        let asked = try readStatement(sql, c, perm), offset = start
        let scope = try overlayScope(a, c, agent)
        let (stmt, views) = expanded(asked, scope)
        if c.env == "production" {
            let sc = try await schema(c, s)
            if let plan = try await timed(timeoutMs, s, { try await s.explain(stmt, analyze: false) }),
               let why = Rules.prodVerdict(plan, schema: sc, maxCost: Double(b.store.setting("prod_guard_cost") ?? "") ?? 1e6, maxRows: Double(b.store.setting("prod_guard_rows") ?? "") ?? 1e6) {
                throw ToolError("BLOCKED_BY_PROD_GUARD", why, status: "blocked")
            }
        }
        let n = min(max(a["limit"]?.intValue ?? cap, 1), cap)
        let r = try await timed(timeoutMs, s) { try await s.run(stmt, limit: offset + n + 1) }
        let rest = r.rows.dropFirst(offset), more = rest.count > n
        var page = Array(rest.prefix(n)), extra: [String: Value] = [:]
        let patches = scope.compactMap(OverlayEngine.patch)
        if !patches.isEmpty {
            let m = OverlayEngine.merge(sql: asked, mysql: c.engine == "mysql", schema: try await schema(c, s), columns: r.columns, rows: page, patches: patches, lastPage: !more)
            page = m.rows
            if let note = m.note { extra["overlay"] = .string(note) }
        }
        if !views.isEmpty { extra["views"] = .array(views.map { .string($0) }) }
        return try await rows(r.columns, page, truncated: more, cursor: more ? Cursor(sql: asked, offset: offset + n).token : nil, ms: r.elapsedMs, sql: stmt, c, trace, extra: extra)
    }

    /// The layers this read sees (SPEC §1.10): DATABASE + MINE + own. `layer` may only narrow that.
    func overlayScope(_ a: [String: Value], _ c: ConnectionRow, _ agent: String) throws -> [OverlayItem] {
        switch a["layer"]?.stringValue?.lowercased() {
        case nil, agent, "own": return try OverlayEngine.scope(b.store, connection: c.id, agent: agent).items
        case "mine": return try OverlayEngine.scope(b.store, connection: c.id, agent: agent, mineOnly: true).items
        case "database": return []
        default: throw ToolError("INVALID_ARGUMENT", "layer must be database or mine")
        }
    }

    /// Virtual views named in `sql`, expanded as CTEs (plain SELECT/WITH only).
    func expanded(_ sql: String, _ items: [OverlayItem]) -> (sql: String, used: [String]) {
        guard ["SELECT", "WITH"].contains(SQLClassifier.firstKeyword(sql)) else { return (sql, []) }
        return Overlay.expand(sql, views: items.filter { $0.kind == "view" }.compactMap { i in i.name.map { ($0, OverlayEngine.sql(i)) } })
    }

    private func rows(_ columns: [String], _ rows: [[Cell]], truncated: Bool, cursor: String?, ms: Double, sql: String, _ c: ConnectionRow, _ trace: Trace, extra: [String: Value] = [:]) async throws -> Value {
        let safe = Rules.redact(sql: sql, mysql: c.engine == "mysql", columns: columns, rows: rows, hidden: try b.store.hiddenColumns(connection: c.id))
        trace.rows = safe.count
        var out = extra
        out["columns"] = .array(columns.map { .string($0) }); out["rows"] = .array(safe.map { .array($0.map(Self.value)) }); out["truncated"] = .bool(truncated); out["ms"] = .int(Int(ms))
        if let cursor { out["cursor"] = .string(cursor) }
        return .object(out)
    }

    static func value(_ c: Cell) -> Value {
        switch c {
        case .null: return .null
        case .integer(let v): return .int(Int(v))
        case .real(let v): return .double(v)
        case .bool(let v): return .bool(v)
        default: return .string(c.display)
        }
    }

    static func tree(_ n: PlanNode) -> Value {
        var o: [String: Value] = ["operation": .string(n.operation), "estimated_rows": .double(n.estimatedRows), "cost": .double(n.cost)]
        if let r = n.relation { o["relation"] = .string(r) }
        if let d = n.detail { o["detail"] = .string(d) }
        if !n.children.isEmpty { o["children"] = .array(n.children.map(tree)) }
        return .object(o)
    }

    /// Statement timeout: cancelling the task (client went away) or the clock cancels the driver too.
    func timed<T: Sendable>(_ ms: Int, _ s: DatabaseSession, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        var timedOut = false
        let r: T? = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T?.self) { g in
                g.addTask { try await op() }
                g.addTask { try await Task.sleep(for: .milliseconds(ms)); await s.cancel(); return nil }
                var result: T?
                do {
                    while let next = try await g.next() {
                        if let v = next { result = v; g.cancelAll(); break }
                        timedOut = true
                    }
                } catch { if timedOut { return nil }; throw (error as? ToolError) ?? ToolError("QUERY_FAILED", error.localizedDescription) }
                return result
            }
        } onCancel: { Task { await s.cancel() } }
        guard let r else { throw ToolError("TIMEOUT", "statement exceeded \(ms >= 1000 ? "\(ms / 1000) s" : "\(ms) ms"); add a filter or a LIMIT") }
        return r
    }
}

/// 30 s schema cache per connection.
actor SchemaCache {
    private var items: [String: (SchemaSnapshot, Date)] = [:]
    func get(_ id: String) -> SchemaSnapshot? { items[id].flatMap { Date().timeIntervalSince($0.1) < 30 ? $0.0 : nil } }
    func put(_ id: String, _ s: SchemaSnapshot) { items[id] = (s, Date()) }
}
