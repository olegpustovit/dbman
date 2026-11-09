import DBCore
import DBStore
import Foundation
import MCP

/// The `dbman` MCP server (SPEC §2). One `Server` per client connection; all share this service's backend and schema cache.
public final class MCPService: @unchecked Sendable {
    static let version = "2.0.0"
    let b: Backend
    let schemas = SchemaCache()
    public let live = LiveSessions()
    public init(_ backend: Backend) { b = backend }

    /// The transport of `server` ended.
    func ended(_ server: Server) { live.closed(ObjectIdentifier(server)) }

    /// Starts a server on `transport`; returns when the handshake machinery is up. `initialize.clientInfo` becomes an `agents` row.
    @discardableResult
    public func start(transport: any Transport) async throws -> Server {
        let agent = AgentBox()
        let server = Server(name: "dbman", version: Self.version, title: "DBMan",
                            instructions: "Read-only access to the user's databases through DBMan. Start with connections.list, then schema.tables. Sensitive columns come back as «redacted». You never write to a database.",
                            capabilities: .init(prompts: .init(listChanged: false), resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: Catalogue.tools) }
        await server.withMethodHandler(CallTool.self) { [self] p in await call(p.name, p.arguments ?? [:], agent: agent.id) }
        await server.withMethodHandler(ListResources.self) { [self] _ in
            var r = [Resource(name: "connections", uri: "dbman://connections", description: "Databases you can use", mimeType: "application/json")]
            for c in (try? b.store.agentVisibleConnections()) ?? [] { r.append(Resource(name: "\(c.name) schema", uri: "dbman://\(Self.esc(c.name))/schema", description: "Tables of \(c.name)", mimeType: "application/json")) }
            return .init(resources: r)
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: [.init(uriTemplate: "dbman://{conn}/tables/{t}", name: "table", description: "Columns, keys and indexes of one table", mimeType: "application/json")])
        }
        await server.withMethodHandler(ReadResource.self) { [self] p in
            let (tool, args) = try Self.route(p.uri)
            let r = await call(tool, args, agent: agent.id)
            guard case .text(let text, _, _)? = r.content.first else { throw MCPError.internalError("empty result") }
            if r.isError == true { throw MCPError.invalidParams(text) }
            return .init(contents: [.text(text, uri: p.uri, mimeType: "application/json")])
        }
        await server.withMethodHandler(ListPrompts.self) { _ in .init(prompts: Self.prompts.map(\.0)) }
        await server.withMethodHandler(GetPrompt.self) { p in
            guard let (prompt, body) = Self.prompts.first(where: { $0.0.name == p.name }) else { throw MCPError.invalidParams("unknown prompt \(p.name)") }
            return .init(description: prompt.description, messages: [.user(.text(text: body(p.arguments ?? [:])))])
        }
        try await server.start(transport: transport) { [self] info, _ in
            let id = Self.slug(info.name)
            try b.store.upsertAgent(id: id, name: info.name, version: info.version)
            agent.id = id
            live.opened(ObjectIdentifier(server), name: info.name, version: info.version)
        }
        return server
    }

    // MARK: identity, resources, prompts

    final class AgentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _id = "unknown"
        var id: String { get { lock.lock(); defer { lock.unlock() }; return _id } set { lock.lock(); _id = newValue; lock.unlock() } }
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "unknown" : s
    }
    static func esc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }

    /// `dbman://connections` | `dbman://{conn}/schema` | `dbman://{conn}/tables/{t}` → the tool that serves it.
    static func route(_ uri: String) throws -> (String, [String: Value]) {
        guard uri.hasPrefix("dbman://") else { throw MCPError.invalidParams("unknown resource \(uri)") }
        let parts = uri.dropFirst("dbman://".count).split(separator: "/", omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
        switch parts.count {
        case 1 where parts[0] == "connections": return ("connections.list", [:])
        case 2 where parts[1] == "schema": return ("schema.tables", ["connection": .string(parts[0])])
        case 3 where parts[1] == "tables": return ("schema.describe", ["connection": .string(parts[0]), "table": .string(parts[2])])
        default: throw MCPError.invalidParams("unknown resource \(uri)")
        }
    }

    static let prompts: [(Prompt, @Sendable ([String: String]) -> String)] = [
        (Prompt(name: "explain-schema", description: "Explain what a database models and how its tables relate", arguments: [.init(name: "connection", description: "Connection name", required: true)]),
         { "Explain the data model of the \($0["connection"] ?? "?") database in plain language. Call schema.tables, then schema.graph, then schema.describe on the central tables. Group tables into domains, name the key relationships, and point out anything surprising (isolated tables, missing keys). Do not guess at data: use query.sample only if names are unclear." }),
        (Prompt(name: "investigate-table", description: "Profile a table and report what is notable", arguments: [.init(name: "connection", description: "Connection name", required: true), .init(name: "table", description: "Table name", required: true)]),
         { "Investigate the \($0["table"] ?? "?") table in \($0["connection"] ?? "?"). Call schema.describe, query.sample, and stats.column on the columns that look important. Report row volume, keys, null-heavy or constant columns, suspicious values, and which tables reference it. Keep queries small: production connections are guarded." }),
    ]
}
