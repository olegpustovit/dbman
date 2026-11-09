import XCTest
@testable import DBManMCP
@testable import DBStore

/// Golden before/after per platform. Regenerate with UPDATE_GOLDEN=1 and review the diff.
final class AgentConfigTests: XCTestCase {
    let helper = "/Applications/DBMan.app/Contents/Helpers/dbman-mcp"
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agents")

    private func file(_ p: AgentPlatform, _ name: String) -> (url: URL, ext: String) {
        let ext = p.style == .toml ? "toml" : "json"
        return (fixtures.appendingPathComponent("\(p.id)/\(name).\(ext)"), ext)
    }

    func testGoldenInstallPerPlatform() throws {
        for p in AgentPlatform.all {
            let before = try String(contentsOf: file(p, "before").url, encoding: .utf8)
            let after = try AgentConfig.install(p, into: before, helper: helper)
            if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] != nil { try after.write(to: file(p, "after").url, atomically: true, encoding: .utf8) }
            XCTAssertEqual(after, try String(contentsOf: file(p, "after").url, encoding: .utf8), p.id)
            XCTAssertEqual(AgentConfig.status(p, in: after, helper: helper), .installed, p.id)
            XCTAssertEqual(try AgentConfig.install(p, into: after, helper: helper), after, "idempotent \(p.id)")
        }
    }

    func testUninstallRemovesOnlyDbman() throws {
        for p in AgentPlatform.all {
            let after = try String(contentsOf: file(p, "after").url, encoding: .utf8)
            let gone = try AgentConfig.uninstall(p, from: after)
            XCTAssertEqual(AgentConfig.status(p, in: gone, helper: helper), .notInstalled, p.id)
            if p.id != "codex" { XCTAssertEqual(try AgentConfig.install(p, into: gone, helper: helper), after, "round trip \(p.id)") } // codex fixture has a [mcp_servers.dbman.env] that uninstall rightly drops
        }
        let cursor = AgentPlatform.all.first { $0.id == "cursor" }!
        let gone = try AgentConfig.uninstall(cursor, from: String(contentsOf: file(cursor, "after").url, encoding: .utf8))
        XCTAssertTrue(gone.contains("linear")); XCTAssertFalse(gone.contains("dbman"))
    }

    func testNeedsUpdateWhenPathDiffers() throws {
        let cursor = AgentPlatform.all.first { $0.id == "cursor" }!
        XCTAssertEqual(AgentConfig.status(cursor, in: try String(contentsOf: file(cursor, "before").url, encoding: .utf8), helper: helper), .needsUpdate)
        let codex = AgentPlatform.all.first { $0.id == "codex" }!
        XCTAssertEqual(AgentConfig.status(codex, in: try String(contentsOf: file(codex, "before").url, encoding: .utf8), helper: helper), .needsUpdate)
        XCTAssertEqual(AgentConfig.status(cursor, in: nil, helper: helper), .notInstalled)
    }

    func testTomlInsertAndReplacePreserveOtherTables() {
        let inserted = AgentConfig.tomlInstall("[a]\nx = 1\n", helper: helper)
        XCTAssertEqual(inserted, "[a]\nx = 1\n\n[mcp_servers.dbman]\ncommand = \"\(helper)\"\nargs = [\"--stdio\"]\nstartup_timeout_sec = 20\n")
        let replaced = AgentConfig.tomlInstall("[mcp_servers.dbman]\ncommand = \"old\"\n\n[b]\ny = 2\n", helper: helper)
        XCTAssertTrue(replaced.contains("[b]\ny = 2")); XCTAssertFalse(replaced.contains("old"))
        XCTAssertEqual(AgentConfig.tomlRemove(replaced), "[b]\ny = 2\n")
        XCTAssertEqual(AgentConfig.tomlInstall("", helper: helper).components(separatedBy: "\n").first, "[mcp_servers.dbman]")
    }

    func testCommentedJSONIsRefused() {
        XCTAssertThrowsError(try AgentConfig.install(AgentPlatform.all[6], into: "{ // zed\n}", helper: helper))
    }

    func testDiffShowsOnlyTheChange() throws {
        let p = AgentPlatform.all[3]
        let c = try tempChange(p)
        let rows = AgentConfig.diff(c.before, c.after)
        XCTAssertEqual(rows.filter { $0.sign == "+" }.count, 1) // the command line changes; args stay
        XCTAssertEqual(rows.filter { $0.sign == "-" }.count, 1)
    }

    private func tempChange(_ p: AgentPlatform) throws -> ConfigChange {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agenthome-\(UUID().uuidString)")
        let u = p.url(.user, home: home, project: nil)!
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file(p, "before").url, to: u)
        return try AgentConfig.plan(p, scope: .user, home: home, project: nil, helper: helper)
    }

    func testApplyBacksUpUndoRestoresAndReapplyKeepsBackup() throws {
        let p = AgentPlatform.all[3]
        let c = try tempChange(p)
        let original = try String(contentsOf: c.url, encoding: .utf8)
        try AgentConfig.write(c)
        XCTAssertEqual(try String(contentsOf: AgentConfig.backupURL(c.url), encoding: .utf8), original)
        try AgentConfig.write(c) // re-apply: no change, backup must stay the original
        XCTAssertEqual(try String(contentsOf: AgentConfig.backupURL(c.url), encoding: .utf8), original)
        try AgentConfig.undo(c.url)
        XCTAssertEqual(try String(contentsOf: c.url, encoding: .utf8), original)
    }

    func testNewFileIsCreatedAndUndoRemovesIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agenthome-\(UUID().uuidString)")
        let p = AgentPlatform.all[7]
        let c = try AgentConfig.plan(p, scope: .user, home: home, project: nil, helper: helper)
        XCTAssertNil(c.before)
        try AgentConfig.write(c)
        XCTAssertEqual(AgentConfig.status(p, scope: .user, home: home, project: nil, helper: helper), .installed)
        try AgentConfig.undo(c.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.url.path))
        XCTAssertEqual(AgentConfig.status(p, scope: .user, home: home, project: nil, helper: helper), .notInstalled)
    }

    func testTomlUpdateKeepsSubtables() throws {
        let codex = AgentPlatform.all.first { $0.id == "codex" }!
        let after = try String(contentsOf: file(codex, "after").url, encoding: .utf8)
        XCTAssertTrue(after.contains("[mcp_servers.dbman.env]\nFOO = \"bar\""))
        XCTAssertFalse(after.contains("/old/path"))
    }

    func testClientMatchingAndLiveSessions() {
        XCTAssertTrue(AgentPlatform.all[0].matches(client: "claude-code"))
        XCTAssertTrue(AgentPlatform.all[3].matches(client: "cursor-vscode"))
        XCTAssertFalse(AgentPlatform.all[3].matches(client: "claude-code"))
        let live = LiveSessions(), k = ObjectIdentifier(live)
        live.opened(k, name: "claude-code", version: "2.4.1")
        XCTAssertEqual(live.clients.count, 1)
        live.closed(k)
        XCTAssertEqual(live.clients.count, 0); XCTAssertEqual(live.handshakes.count, 1)
    }

    func testStorePermissionsSensitiveAndActivity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentstore-\(UUID().uuidString)")
        let store = try Store.open(at: dir.appendingPathComponent("dbman.sqlite"))
        var c = ConnectionRow(id: "c1", name: "shop", engine: "sqlite"); c.filePath = "/x.sqlite"
        try store.upsert(c)
        try store.upsertAgent(id: "cc", name: "claude-code", version: "2")
        try store.setPermission(agent: "cc", connection: "c1", level: "read", timeoutMs: 5000, rowCap: 100)
        XCTAssertEqual(try store.permission(agent: "cc", connection: c), Permission(level: "read", timeoutMs: 5000, rowCap: 100))
        try store.autoMarkSensitive(connection: "c1", columns: [("users", "email")])
        try store.setSensitive(connection: "c1", table: "users", column: "email", hidden: false)
        XCTAssertEqual(try store.sensitiveColumns(connection: "c1").first?.hidden, false)
        XCTAssertEqual(try store.hiddenColumns(connection: "c1"), [])
        try store.logActivity(agent: "cc", connection: "c1", tool: "query.run", args: "select 1", ms: 3, rows: 1, status: "ok", error: nil)
        let a = try store.activity(connection: "c1")
        XCTAssertEqual(a.first?.connection, "shop"); XCTAssertEqual(a.first?.tool, "query.run")
        XCTAssertEqual(try store.activity(connection: "other").count, 0)
        XCTAssertEqual(try store.agents().first?.name, "claude-code")
    }
}
