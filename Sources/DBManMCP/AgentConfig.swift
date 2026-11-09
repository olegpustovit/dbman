import Foundation

public enum AgentScope: String, Sendable { case user, project }
public enum AgentStatus: String, Sendable { case notFound = "NOT_FOUND", notInstalled = "NOT_INSTALLED", installed = "INSTALLED", needsUpdate = "NEEDS_UPDATE" }

/// One agent platform: where its native MCP config lives and how a `dbman` entry looks there (SPEC §1.2).
public struct AgentPlatform: Identifiable, Sendable {
    enum Style { case plain, typed, claudeCode, zed, opencode, toml }
    public let id: String, name: String, mono: String
    /// Config path relative to the home folder / the project folder (nil: no project scope).
    let user: String, project: String?
    let key: String        // JSON object holding the servers (unused for TOML, whose table is [mcp_servers.dbman])
    let style: Style
    /// Lower-case fragments of `initialize.clientInfo.name` that identify this client (VERIFY step).
    let clients: [String]

    public var hasProject: Bool { project != nil }
    public func url(_ scope: AgentScope, home: URL, project dir: URL?) -> URL? {
        if scope == .project { return dir.flatMap { d in project.map { d.appendingPathComponent($0) } } }
        return home.appendingPathComponent(user)
    }
    public func matches(client name: String) -> Bool { let n = name.lowercased(); return clients.contains { n.contains($0) } }

    // shortcut: client names, Grok/Windsurf/Antigravity paths are from public docs, not verified on a machine with each app; upgrade: correct the entry here when a VERIFY never completes.
    public static let all: [AgentPlatform] = [
        .init(id: "claude-code", name: "Claude Code", mono: "CC", user: ".claude.json", project: ".mcp.json", key: "mcpServers", style: .claudeCode, clients: ["claude-code"]),
        .init(id: "claude-desktop", name: "Claude Desktop", mono: "CD", user: "Library/Application Support/Claude/claude_desktop_config.json", project: nil, key: "mcpServers", style: .plain, clients: ["claude-ai", "claude-desktop"]),
        .init(id: "codex", name: "Codex", mono: "CX", user: ".codex/config.toml", project: ".codex/config.toml", key: "", style: .toml, clients: ["codex"]),
        .init(id: "cursor", name: "Cursor", mono: "CU", user: ".cursor/mcp.json", project: ".cursor/mcp.json", key: "mcpServers", style: .plain, clients: ["cursor"]),
        .init(id: "opencode", name: "OpenCode", mono: "OC", user: ".config/opencode/opencode.json", project: "opencode.json", key: "mcp", style: .opencode, clients: ["opencode"]),
        .init(id: "vscode", name: "VS Code (Copilot)", mono: "VS", user: "Library/Application Support/Code/User/mcp.json", project: ".vscode/mcp.json", key: "servers", style: .typed, clients: ["visual studio code", "vscode", "copilot"]),
        .init(id: "zed", name: "Zed", mono: "ZD", user: ".config/zed/settings.json", project: nil, key: "context_servers", style: .zed, clients: ["zed"]),
        .init(id: "grok", name: "Grok", mono: "GK", user: ".grok/config.toml", project: ".grok/config.toml", key: "", style: .toml, clients: ["grok"]),
        .init(id: "antigravity", name: "Antigravity", mono: "AG", user: ".gemini/antigravity/mcp_config.json", project: nil, key: "mcpServers", style: .plain, clients: ["antigravity"]),
        .init(id: "windsurf", name: "Windsurf", mono: "WS", user: ".codeium/windsurf/mcp_config.json", project: nil, key: "mcpServers", style: .plain, clients: ["windsurf", "codeium"]),
    ]
}

public struct ConfigChange: Sendable {
    public var url: URL, before: String?, after: String
    /// The file's text when the change was planned; `write` refuses if the file no longer holds it (nil: the file did not exist).
    public var raw: String?
    public init(url: URL, before: String?, after: String, raw: String? = nil) { self.url = url; self.before = before; self.after = after; self.raw = raw }
}
public struct DiffRow: Equatable, Sendable {
    public var n: Int?
    public var sign: Character
    public var text: String
}
public struct ConfigError: LocalizedError, Sendable {
    public var errorDescription: String?
    public init(errorDescription: String?) { self.errorDescription = errorDescription }
}

/// Pure text transforms (testable with fixtures) plus the file/CLI plumbing around them. Nothing here knows the real home: callers pass it.
public enum AgentConfig {
    public static let table = "dbman"

    // MARK: entries

    static func entry(_ p: AgentPlatform, helper: String) -> [String: Any] {
        switch p.style {
        case .plain, .toml: ["command": helper, "args": ["--stdio"]]
        case .typed: ["type": "stdio", "command": helper, "args": ["--stdio"]]
        case .claudeCode: ["type": "stdio", "command": helper, "args": ["--stdio"], "env": [String: String]()]
        case .zed: ["source": "custom", "command": helper, "args": ["--stdio"]]
        case .opencode: ["type": "local", "command": [helper, "--stdio"], "enabled": true]
        }
    }

    /// "Other (copy JSON)".
    public static func genericJSON(helper: String) -> String {
        (try? json(["mcpServers": ["dbman": entry(AgentPlatform.all[0], helper: helper)]])) ?? ""
    }

    // MARK: install / uninstall / status (text in, text out)

    public static func install(_ p: AgentPlatform, into text: String?, helper: String) throws -> String {
        if p.style == .toml { try tomlGuard(text ?? ""); return tomlInstall(text ?? "", helper: helper) }
        var root = try parse(text)
        var servers = root[p.key] as? [String: Any] ?? [:]
        servers[table] = entry(p, helper: helper)
        root[p.key] = servers
        return try json(root)
    }

    public static func uninstall(_ p: AgentPlatform, from text: String) throws -> String {
        if p.style == .toml { try tomlGuard(text); return tomlRemove(text) }
        var root = try parse(text)
        guard var servers = root[p.key] as? [String: Any], servers.removeValue(forKey: table) != nil else { return try json(root) }
        root[p.key] = servers
        return try json(root)
    }

    /// The launcher path currently registered as `dbman`, nil if none.
    public static func command(_ p: AgentPlatform, in text: String?) -> String? {
        guard let text else { return nil }
        if p.style == .toml {
            let lines = text.components(separatedBy: "\n")
            guard let r = tomlRange(lines) else { return nil }
            return lines[r].lazy.compactMap { l -> String? in
                let t = l.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("command"), let a = t.firstIndex(of: "\""), let b = t.lastIndex(of: "\""), a < b else { return nil }
                return String(t[t.index(after: a)..<b]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }.first ?? ""
        }
        guard let e = (try? parse(text))?[p.key] as? [String: Any], let d = e[table] as? [String: Any] else { return nil }
        return (d["command"] as? String) ?? (d["command"] as? [String])?.first ?? ""
    }

    public static func status(_ p: AgentPlatform, in text: String?, helper: String) -> AgentStatus {
        guard let c = command(p, in: text) else { return .notInstalled }
        return c == helper ? .installed : .needsUpdate
    }

    // MARK: JSON

    static func parse(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        // shortcut: strict JSON only (a config with comments is refused, not rewritten), key order is normalised on write; upgrade to a text-level patch if users hit it.
        guard let d = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ConfigError(errorDescription: "The config is not plain JSON (comments or a syntax error). Fix it, or use COPY JSON and paste the entry yourself.")
        }
        return d
    }

    static func json(_ o: [String: Any]) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let s = String(decoding: d, as: UTF8.self)
        return s.replacingOccurrences(of: #"(?m)^(\s*"(?:[^"\\]|\\.)*") : "#, with: "$1: ", options: .regularExpression)
            .replacingOccurrences(of: #"([\[{])\n\s*\n\s*([\]}])"#, with: "$1$2", options: .regularExpression) + "\n" // Foundation prints empty containers over three lines
    }

    // MARK: TOML (one table, hand-rolled: [mcp_servers.dbman] and its sub-tables)

    static func tomlBlock(helper: String) -> [String] {
        ["[mcp_servers.dbman]", "command = \"\(helper.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"", "args = [\"--stdio\"]", "startup_timeout_sec = 20"]
    }

    /// Line range of the dbman table: header up to (not including) the next header, trailing blank lines excluded.
    /// `subtables`: also swallow `[mcp_servers.dbman.*]` (uninstall); an update keeps them, so the user's env survives.
    static func tomlRange(_ lines: [String], subtables: Bool = false) -> Range<Int>? {
        let head = "[mcp_servers.dbman]", sub = subtables ? "[mcp_servers.dbman." : "\u{0}"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == head }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), !t.hasPrefix(sub) { break }
            end += 1
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return start..<end
    }

    /// A `dbman` server defined any way but our own `[mcp_servers.dbman]` table (inline `mcp_servers = { dbman = … }`, dotted keys, a quoted header)
    /// would end up twice, which is invalid TOML. shortcut: line-based, so multi-line inline tables are only caught on their `dbman` line; upgrade with a real TOML parser.
    static func tomlGuard(_ text: String) throws {
        var inServers = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.isEmpty { continue }
            if t.hasPrefix("[") { inServers = t == "[mcp_servers]" }
            let ours = t == "[mcp_servers.dbman]" || t.hasPrefix("[mcp_servers.dbman.")
            let defines = t.hasPrefix("mcp_servers") ? t.contains("dbman")
                : t.hasPrefix("[") ? t.hasPrefix("[mcp_servers.") && t.contains("dbman") && !ours
                : inServers && t.range(of: #"^["']?dbman["']?\s*[.=]"#, options: .regularExpression) != nil
            if defines { throw ConfigError(errorDescription: "This config already defines dbman in a form DBMan won't rewrite (inline or dotted TOML). Edit it by hand, or use COPY CONFIG and paste the entry yourself.") }
        }
    }

    static func tomlInstall(_ text: String, helper: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if let r = tomlRange(lines) { lines.replaceSubrange(r, with: tomlBlock(helper: helper)) }
        else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += tomlBlock(helper: helper)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func tomlRemove(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard var r = tomlRange(lines, subtables: true) else { return text }
        if r.lowerBound > 0, lines[r.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty { r = (r.lowerBound - 1)..<r.upperBound }
        lines.removeSubrange(r)
        if r.lowerBound == 0, let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() } // block was first: no leading blank line
        return lines.joined(separator: "\n")
    }

    // MARK: diff

    /// Unified-style rows with 3 lines of context; skipped stretches become one `⋯` row. Line numbers are the new file's (old file's for removals).
    public static func diff(_ before: String?, _ after: String, context: Int = 3) -> [DiffRow] {
        func split(_ s: String) -> [String] { var l = s.components(separatedBy: "\n"); if l.last == "" { l.removeLast() }; return l }
        let a = split(before ?? ""), b = split(after)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in b.difference(from: a) { switch c { case .remove(let o, _, _): removed.insert(o); case .insert(let o, _, _): inserted.insert(o) } }
        var rows: [DiffRow] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { rows.append(.init(n: i + 1, sign: "-", text: a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { rows.append(.init(n: j + 1, sign: "+", text: b[j])); j += 1 }
            else { rows.append(.init(n: j + 1, sign: " ", text: b[j])); i += 1; j += 1 }
        }
        let changed = rows.indices.filter { rows[$0].sign != " " }
        guard !changed.isEmpty else { return [] }
        var out: [DiffRow] = [], last = -1
        for k in rows.indices where changed.contains(where: { abs($0 - k) <= context }) {
            if k != last + 1 { out.append(.init(n: nil, sign: " ", text: "⋯")) }
            out.append(rows[k]); last = k
        }
        if last != rows.count - 1 { out.append(.init(n: nil, sign: " ", text: "⋯")) }
        return out
    }

    // MARK: files

    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    public static func status(_ p: AgentPlatform, scope: AgentScope, home: URL, project: URL?, helper: String) -> AgentStatus {
        guard let u = p.url(scope, home: home, project: project) else { return .notFound }
        let text = read(u)
        if text == nil, !FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path) { return .notFound }
        return status(p, in: text, helper: helper)
    }

    /// Before/after of the native file. The `before` shown is the canonical re-serialisation, so the diff holds only the real change.
    public static func plan(_ p: AgentPlatform, scope: AgentScope, home: URL, project: URL?, helper: String, remove: Bool = false) throws -> ConfigChange {
        guard let u = p.url(scope, home: home, project: project) else { throw ConfigError(errorDescription: "Choose a project folder first.") }
        let text = read(u)
        let after = remove ? try uninstall(p, from: text ?? "") : try install(p, into: text, helper: helper)
        let before: String? = text.map { p.style == .toml ? $0 : ((try? parse($0)).flatMap { try? json($0) } ?? $0) }
        return ConfigChange(url: u, before: before, after: after, raw: text)
    }

    /// Next to the real file: a dotfile manager's symlink is never replaced by a copy.
    public static func backupURL(_ u: URL) -> URL { URL(fileURLWithPath: u.resolvingSymlinksInPath().path + ".dbman-backup") }

    /// Keeps the first backup (the user's original, whatever later applies do) and never overwrites it. shortcut: one backup, so undo goes back to the original; upgrade to timestamped backups.
    private static func backUp(_ u: URL) throws {
        let fm = FileManager.default, b = backupURL(u)
        if read(u) != nil, !fm.fileExists(atPath: b.path) { try fm.copyItem(at: u.resolvingSymlinksInPath(), to: b) }
    }

    /// Backs the file up, then writes in place through a symlink. Refuses if the file changed since the preview (its app may have rewritten it).
    public static func write(_ c: ConfigChange) throws {
        let current = read(c.url)
        guard current != c.after else { return }
        guard current == c.raw else { throw ConfigError(errorDescription: "\(c.url.lastPathComponent) changed since the preview. Nothing was written; look at the new diff and try again.") }
        let real = c.url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backUp(c.url)
        try c.after.write(to: real, atomically: true, encoding: .utf8)
    }

    /// Restores the backup; with none (we created the file) removes the file.
    public static func undo(_ u: URL) throws {
        let fm = FileManager.default, b = backupURL(u), real = u.resolvingSymlinksInPath()
        if fm.fileExists(atPath: b.path) { _ = try fm.replaceItemAt(real, withItemAt: b) } else { try? fm.removeItem(at: real) }
    }

    // MARK: Claude Code CLI

    /// `claude` from the usual install spots (an app has no login-shell PATH).
    public static func claudeCLI(home: URL) -> URL? {
        let dirs = [".claude/local", ".local/bin", ".npm-global/bin"].map { home.appendingPathComponent($0).path } + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Writes the change. Claude Code user scope on the real home goes through `claude mcp add` (it owns ~/.claude.json); anything else, or a CLI failure, merges JSON.
    public static func apply(_ c: ConfigChange, _ p: AgentPlatform, scope: AgentScope, home: URL, helper: String) throws {
        if p.id == "claude-code", scope == .user, home.path == NSHomeDirectory(), let cli = claudeCLI(home: home) {
            try backUp(c.url)
            _ = try? run(cli, ["mcp", "remove", table, "-s", "user"]) // an update re-adds
            if (try? run(cli, ["mcp", "add", table, "-s", "user", "--", helper, "--stdio"]))?.status == 0 { return }
        }
        try write(c)
    }

    @discardableResult
    public static func run(_ exe: URL, _ args: [String], cwd: URL? = nil) throws -> (status: Int32, output: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = exe; p.arguments = args; p.currentDirectoryURL = cwd
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }
}
