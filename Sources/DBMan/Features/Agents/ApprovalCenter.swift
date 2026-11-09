import AppKit
import DBStore
import Foundation
import Observation
import SwiftUI
import UserNotifications

extension ApprovalRow {
    var who: String { agent ?? "an agent" }
    var mono: String { // claude-code → CC, codex → CO
        let words = who.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(who.prefix(2))).uppercased()
    }
    var connectionName: String { field("connection_name") ?? field("name") ?? "a connection" }
    /// One line for the banner and the menu.
    var summary: String {
        switch kind {
        case "credentials": "\(who) wants to add \(field("name") ?? "a connection")"
        case "remove": "\(who) wants to remove \(field("name") ?? "a connection")"
        case "update": "\(who) wants to change \(field("name") ?? "a connection")\(field("ssh_host").map { " (via SSH \($0))" } ?? "")"
        default: "\(who) hit the prod guard on \(connectionName) — allow once?"
        }
    }
}

/// Pending approvals as the human meets them (SPEC §1.5, G5, G12): the list, the sheet, a notification per row, the Dock badge.
/// A decision is just a store row; the agent's waiting tool call polls it (MCPService.awaitApproval).
@MainActor @Observable
final class ApprovalCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ApprovalCenter()
    private(set) var pending: [ApprovalRow] = []
    /// The approval whose sheet is up.
    var current: ApprovalRow?
    /// The workspace whose window shows the sheet (the front-most one when the approval was presented); nil = none open, so a small window of its own does.
    private(set) var sheetTarget: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var panel: NSWindow?
    /// shortcut: scratch stores (DBMAN_STORE) never notify, so scripted runs raise no permission prompt; banners need a bundle id too; upgrade with an explicit opt-in setting if scripted runs ever need notifications.
    private var notifications: UNUserNotificationCenter? { Bundle.main.bundleIdentifier != nil && Store.defaultURL == Store.productionURL ? .current() : nil }

    /// Once the app has launched: scenes exist, so a sheet or window may open. Rows expire on the clock even if nothing else touches the store.
    func start(_ app: AppModel) {
        started = true
        notifications?.delegate = self
        notifications?.setNotificationCategories([UNNotificationCategory(identifier: "approval", actions: [
            UNNotificationAction(identifier: "review", title: "Review", options: .foreground), UNNotificationAction(identifier: "later", title: "Later", options: [])], intentIdentifiers: [])])
        refresh(app.store)
        Task { while true { try? await Task.sleep(for: .seconds(5)); refresh(app.store) } }
    }

    func refresh(_ store: Store) {
        guard started else { return }
        let rows = (try? store.pendingApprovals()) ?? []
        if rows != pending { pending = rows; AppDelegate.updateActivationPolicy() }
        NSApp.dockTile.badgeLabel = rows.isEmpty ? nil : String(rows.count)
        let fresh = rows.filter { seen.insert($0.id).inserted }
        notifications?.removeDeliveredNotifications(withIdentifiers: seen.filter { id in !rows.contains { $0.id == id } })
        if let c = current, !rows.contains(where: { $0.id == c.id }) { dismiss() } // decided elsewhere (another window, sqlite3, expiry)
        fresh.forEach(notify)
        if let a = fresh.first {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) } // G5: the helper launched us in the background
            if a.kind != "prod_guard", current == nil { present(a) } // a block waits in the feed; credentials and removals open their sheet
        }
    }

    // MARK: sheet

    func present(_ a: ApprovalRow) {
        current = a
        sheetTarget = AppModel.shared.frontWorkspace
        guard sheetTarget == nil else { return } // WorkspaceView shows it as a sheet
        panel?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: ApprovalDialog(a: a).environment(AppModel.shared)))
        w.title = "DBMan · approval"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
        w.center(); w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in Task { @MainActor in if self?.panel === w { self?.panel = nil; self?.current = nil } } } // the red button = LATER
        panel = w
    }

    func dismiss() { current = nil; panel?.close(); panel = nil }

    /// Menu item / banner: bring the app forward at the oldest pending approval.
    func review(_ id: String? = nil) {
        guard let a = pending.first(where: { id == nil || $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        present(a)
    }

    // MARK: decisions (the sheet and the feed card call these)

    func decide(_ a: ApprovalRow, _ status: String, _ merge: [String: String] = [:]) {
        let store = AppModel.shared.store
        let json = (try? JSONSerialization.data(withJSONObject: merge)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        do { try store.decideApproval(a.id, status, merge: json) } catch { NSLog("DBMan approvals: %@", error.localizedDescription) }
        if current?.id == a.id { dismiss() }
        refresh(store)
    }

    /// ALLOW ONCE: the same agent may re-run exactly this statement once.
    func allowOnce(_ a: ApprovalRow) { decide(a, "approved", ["action": "allow_once"]) }

    /// RAISE TIMEOUT: this agent's statement timeout on that connection becomes 30 s. The statement itself stays blocked.
    func raiseTimeout(_ a: ApprovalRow) {
        let store = AppModel.shared.store
        if let agent = a.agent, let id = a.connection, let c = (try? store.connections())?.first(where: { $0.id == id }), let p = try? store.permission(agent: agent, connection: c) {
            try? store.setPermission(agent: agent, connection: id, level: p.level, timeoutMs: Self.raisedTimeoutMs, rowCap: p.rowCap)
        }
        decide(a, "approved", ["action": "raise_timeout"])
    }
    static let raisedTimeoutMs = 30_000

    /// REMOVE: delete the connection and its secret, then answer the agent.
    func remove(_ a: ApprovalRow) {
        let app = AppModel.shared
        if let id = a.connection.flatMap(UUID.init(uuidString:)), let p = app.profile(id) { Keychain.delete(for: p); app.remove(id) }
        decide(a, "approved")
    }

    // MARK: notifications

    private func notify(_ a: ApprovalRow) {
        guard let center = notifications else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let c = UNMutableNotificationContent()
        c.title = "DBMan"; c.body = a.summary; c.categoryIdentifier = "approval"
        c.subtitle = "Expires in " + Self.countdown(a.expiresAt)
        center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard r.actionIdentifier != "later" else { return }
        let id = r.notification.request.identifier
        await MainActor.run { review(id) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }

    static func countdown(_ to: Date, now: Date = .now) -> String {
        let s = max(0, Int(to.timeIntervalSince(now)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
