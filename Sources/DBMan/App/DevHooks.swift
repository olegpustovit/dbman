import AppKit
import DBCore
import SwiftUI

/// Dev/CI hooks for scripted screenshots and smoke tests. Env vars, DEBUG builds only (release gets inert stubs).
///   DBMAN_STORE=<path> (use this store file, not the real one)   DBMAN_OPEN=internal|sample|/path.sqlite|postgres://…|mysql://…   DBMAN_ENV=production|staging  (tags the opened profile)
///   DBMAN_ROUTE=table:<name>|query:<sql>   DBMAN_VIEW=<rail index>   DBMAN_AUTORUN=1   DBMAN_SELECT=<row>
///   DBMAN_STAGE=<table>.<column>=<value> (stages an update of the first row by id)   DBMAN_REVIEW=1   DBMAN_COMMIT=1   DBMAN_PALETTE=1
///   DBMAN_APPEARANCE=dark   DBMAN_WINDOW=settings|min (min: resize the database window to its 1100x700 minimum)
///   DBMAN_CONNECT_TEST=<url> (Connections editor: fill the URL and press TEST)
@MainActor enum DevHooks {
    /// Passwords from DBMAN_OPEN URLs, so scripted runs never touch the Keychain (a rebuilt binary triggers an access prompt).
    static var passwords: [UUID: String] = [:]
    #if DEBUG
    private static func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
    static var view: Int { env("DBMAN_VIEW").flatMap(Int.init) ?? 0 }
    static var autorun: Bool { env("DBMAN_AUTORUN") != nil }
    static var select: Int? { env("DBMAN_SELECT").flatMap(Int.init) }
    static var connectURL: String? { env("DBMAN_CONNECT_TEST") }
    static var openSettings: Bool { env("DBMAN_WINDOW") == "settings" }

    /// Called once at launch.
    static func launch() {
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

    /// Called after the workspace connects.
    static func connected(_ ws: WorkspaceModel) async {
        if let r = env("DBMAN_ROUTE"), let i = r.firstIndex(of: ":") {
            let arg = String(r[r.index(after: i)...])
            if r.hasPrefix("table:") { ws.go(.table(arg)) } else if r.hasPrefix("query:") { ws.newQuery(sql: arg) }
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
    }
    #else
    static var view: Int { 0 }
    static var autorun: Bool { false }
    static var select: Int? { nil }
    static var connectURL: String? { nil }
    static var openSettings: Bool { false }
    static func launch() {}
    static func connected(_ ws: WorkspaceModel) async {}
    #endif
}
