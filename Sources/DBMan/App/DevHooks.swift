import AppKit
import DBCore
import SwiftUI

/// Dev/CI hooks for scripted screenshots and smoke tests. Env vars, DEBUG builds only (release gets inert stubs).
///   DBMAN_STORE=<path> (use this store file, not the real one)   DBMAN_OPEN=internal|sample|/path.sqlite|postgres://…|mysql://…   DBMAN_ENV=production|staging  (tags the opened profile)
///   DBMAN_ROUTE=table:<name>|query:<sql>|dashboard:<id or title part>[:edit[:<widget id>]]|schema-map (+ DBMAN_MAP=<layout>[:<table>[:<hops>]] DBMAN_MAP_PATH=a>b DBMAN_MAP_DETAIL=names|keys|all)   DBMAN_VIEW=<rail index>   DBMAN_AUTORUN=1   DBMAN_SELECT=<row>
///   DBMAN_STAGE=<table>.<column>=<value> (stages an update of the first row by id)   DBMAN_REVIEW=1   DBMAN_COMMIT=1   DBMAN_PALETTE=1
///   DBMAN_APPEARANCE=dark   DBMAN_WINDOW=settings|min (min: resize the database window to its 1100x700 minimum)
///   DBMAN_LAYER=<agent>[:diff|:apply|:seeas] (open the Store panel on that agent's layer; :diff = compare view, :apply = the review sheet)   DBMAN_SNAPSHOT=<png>[+DBMAN_SNAPSHOT_WINDOW=<title>] (render the key window's own view to a file after 6 s; used where screencapture is not permitted)
///   DBMAN_UNLOCK=1 (unlock writes on the opened connection)
///   DBMAN_CONNECT_TEST=<url> (Connections editor: fill the URL and press TEST)
@MainActor enum DevHooks {
    /// Passwords from DBMAN_OPEN URLs, so scripted runs never touch the Keychain (a rebuilt binary triggers an access prompt).
    nonisolated(unsafe) static var passwords: [UUID: String] = [:] // read by the MCP headless sessions too; written once at launch
    #if DEBUG
    private static func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
    static var view: Int { env("DBMAN_VIEW").flatMap(Int.init) ?? 0 }
    static var autorun: Bool { env("DBMAN_AUTORUN") != nil }
    static var select: Int? { env("DBMAN_SELECT").flatMap(Int.init) }
    static var connectURL: String? { env("DBMAN_CONNECT_TEST") }
    static var openSettings: Bool { env("DBMAN_WINDOW") == "settings" }
    /// DBMAN_AGENTS=<platform id>|perms|activity|agentpack|other opens the Agents window there. DBMAN_AGENT_HOME=<dir> is the fake HOME for detection (AgentsModel).
    static var agentsSection: String? { env("DBMAN_AGENTS") }
    /// DBMAN_AGENTPACK_RUN=<project dir> fills the AGENTPACK panel's project and presses RUN.
    static var agentpackRun: String? { env("DBMAN_AGENTPACK_RUN") }
    /// DBMAN_AGENTS_CONNECT=<platform id> runs CONNECT for it when the Agents window appears (VERIFY then waits for a real client).
    static var agentsConnect: String? { env("DBMAN_AGENTS_CONNECT") }

    /// DBMAN_SNAPSHOT=<png>: after 6 s (DBMAN_SNAPSHOT_DELAY=<s>) write the key window's own pixels (DBMAN_SNAPSHOT_WINDOW=<title> picks another, e.g. Agents). In-process, so no screen capture is involved.
    /// A sheet on that window is composited on top, since it is a separate window.
    private static func snapshot() {
        guard let path = env("DBMAN_SNAPSHOT") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(env("DBMAN_SNAPSHOT_DELAY").flatMap(Double.init) ?? 6))
            let title = env("DBMAN_SNAPSHOT_WINDOW")
            let idle = ["", "Connections", "Database"] // a restored workspace window without a connection is titled "Database"
            let win = NSApp.windows.first { title != nil ? $0.title == title : ($0 == NSApp.keyWindow && !idle.contains($0.title)) }
                ?? NSApp.windows.first { title == nil && $0.isVisible && !idle.contains($0.title) }
            guard let v = win?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.addRepresentation(rep)
            if let s = win?.sheets.first?.contentView, let srep = s.bitmapImageRepForCachingDisplay(in: s.bounds) {
                s.cacheDisplay(in: s.bounds, to: srep)
                img.lockFocus(); NSGraphicsContext.current?.cgContext.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                NSRect(origin: .zero, size: v.bounds.size).fill(using: .sourceOver)
                srep.draw(in: NSRect(x: (v.bounds.width - s.bounds.width) / 2, y: v.bounds.height - s.bounds.height - 30, width: s.bounds.width, height: s.bounds.height)); img.unlockFocus()
            }
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        }
    }

    /// Called once at launch.
    static func launch() {
        snapshot()
        if env("DBMAN_APPEARANCE") == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300)) // let the scene install openWindow
            guard let target = env("DBMAN_OPEN") else { return }
            let app = AppModel.shared
            var id: UUID?
            if target == "sample" { id = app.ensureSampleDatabase() }
            else if target == "internal" { id = ConnectionProfile.internalID }
            else if let (p, pw) = ConnectionURL.parseWithPassword(target) {
                let profile = app.profiles.first { $0.engine == p.engine && $0.host == p.host && $0.port == p.port && $0.database == p.database && $0.filePath == p.filePath } ?? p
                app.upsert(profile)
                passwords[profile.id] = pw
                id = profile.id
            }
            guard let id, var p = app.profile(id) else { return }
            if let tag = env("DBMAN_ENV").flatMap(EnvironmentTag.init) { p.environment = tag; app.upsert(p) }
            app.openWindow?(id)
        }
    }

    /// Waits (an agent may still be creating it) for the dashboard whose id or title matches, opens it, optionally in edit mode with a widget selected.
    private static func dashboard(_ ws: WorkspaceModel, _ arg: String) async {
        let p = arg.split(separator: ":").map(String.init)
        for _ in 0..<30 {
            ws.dash.reload(ws)
            if let e = ws.dash.entries.first(where: { $0.id == p[0] || $0.title.localizedCaseInsensitiveContains(p[0]) }) {
                ws.go(e.id == ws.dash.defaultEntry?.id ? .overview : .dashboard(e.id))
                if p.count > 1, p[1] == "edit" {
                    while ws.dash.itemID != e.id { try? await Task.sleep(for: .milliseconds(100)) }
                    ws.dash.edit = true; ws.dash.selected = p.count > 2 ? p[2] : nil
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Called after the workspace connects.
    static func connected(_ ws: WorkspaceModel) async {
        if env("DBMAN_ROUTE") == "schema-map" { ws.go(.schemaMap); ws.map.applyDevHook() }
        if let r = env("DBMAN_ROUTE"), let i = r.firstIndex(of: ":") {
            let arg = String(r[r.index(after: i)...])
            if r.hasPrefix("table:") { ws.go(.table(arg)) } else if r.hasPrefix("query:") { ws.newQuery(sql: arg) } else if r.hasPrefix("dashboard:") { await dashboard(ws, arg) }
        }
        if let s = env("DBMAN_STAGE"), let session = ws.session, let dot = s.firstIndex(of: "."), let eq = s.firstIndex(of: "=") {
            let table = String(s[..<dot]), col = String(s[s.index(after: dot)..<eq]), new = String(s[s.index(after: eq)...])
            let sql = "SELECT id, \(quoteIdent(col, ws.profile.engine)) FROM \(quoteIdent(table, ws.profile.engine)) ORDER BY id LIMIT 1"
            if let row = try? await session.run(sql).rows.first { ws.stage(.update(table: table, key: ["id": row[0]], column: col, old: row[1], new: .text(new))) }
        }
        if env("DBMAN_COMMIT") != nil { try? await Task.sleep(for: .milliseconds(300)); try? await ws.commitStaged() } // stage() reaches the session asynchronously
        if env("DBMAN_REVIEW") != nil { ws.reviewOpen = true }
        if env("DBMAN_WINDOW") == "min" { NSApp.windows.first { $0.title == ws.profile.name }?.setContentSize(NSSize(width: 1100, height: 700)) }
        if env("DBMAN_PALETTE") != nil { ws.paletteOpen = true }
        if env("DBMAN_UNLOCK") != nil { ws.writesUnlocked = true; await ws.session?.unlockWrites() } // the ⌥-click UNLOCK INTERNAL STORE path, scripted
        if let l = env("DBMAN_LAYER") { ws.layers.devSelect(l, ws) }
    }
    #else
    static var view: Int { 0 }
    static var autorun: Bool { false }
    static var select: Int? { nil }
    static var connectURL: String? { nil }
    static var openSettings: Bool { false }
    static var agentsSection: String? { nil }
    static var agentsConnect: String? { nil }
    static var agentpackRun: String? { nil }
    static func launch() {}
    static func connected(_ ws: WorkspaceModel) async {}
    #endif
}
