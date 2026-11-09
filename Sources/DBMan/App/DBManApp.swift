import AppKit
import DBCore
import Halftone
import SwiftUI

@main
struct DBManApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        // Connections window (02 · Connections)
        Window("Connections", id: "connections") {
            ConnectionsView()
                .environment(app)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 620)

        Window("Agents", id: "agents") {
            AgentsWindow()
                .environment(app)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 680)

        // One window per open connection; the value is the profile id.
        WindowGroup("Database", for: UUID.self) { $profileID in
            WorkspaceWindow(profileID: profileID)
                .environment(app)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { DBManCommands() }

        Settings {
            SettingsView().environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !DEBUG
        linkHelperOnLaunch()
        #endif
        MCPHost.shared.start(AppModel.shared)
        ApprovalCenter.shared.start(AppModel.shared)
        DevHooks.launch()
        // G5: a background launch (open -g, by the helper) stays out of the Dock and focus until a window or an approval needs the human.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in AppDelegate.updateActivationPolicy() } }
        }
        AppDelegate.updateActivationPolicy()
    }

    /// Regular (Dock, menu bar) while a window is open or an approval waits; accessory otherwise. ApprovalCenter calls it when pending rows change.
    @MainActor static func updateActivationPolicy() {
        let shown = NSApp.windows.contains { $0.isVisible || $0.isMiniaturized }
        let wanted: NSApplication.ActivationPolicy = shown || !ApprovalCenter.shared.pending.isEmpty ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }
    func applicationWillTerminate(_ notification: Notification) { MCPHost.shared.stop() }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Dropping a .sqlite on the Dock icon opens it.
        Task { @MainActor in for url in urls { AppModel.shared.openFile(url) } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if !DEBUG
/// Keeps ~/.local/bin/dbman-mcp pointing at this app's helper (the path agents are told to use). Replaces only a symlink; a regular file is left alone.
private func linkHelperOnLaunch() {
    let fm = FileManager.default
    let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/dbman-mcp").path
    let link = fm.homeDirectoryForCurrentUser.appending(path: ".local/bin/dbman-mcp").path
    guard fm.fileExists(atPath: helper) else { return }
    let target = try? fm.destinationOfSymbolicLink(atPath: link)
    if target == helper { return }
    if target == nil, fm.fileExists(atPath: link) { return } // a regular file or directory: never overwrite
    try? fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: link) // missing or a stale symlink (dangling links count as missing)
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: helper)
}
#endif
