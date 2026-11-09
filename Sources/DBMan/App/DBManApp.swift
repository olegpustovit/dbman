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
        // SPM executables start as accessory apps; make it a regular Dock app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DevHooks.launch()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Dropping a .sqlite on the Dock icon opens it.
        Task { @MainActor in for url in urls { AppModel.shared.openFile(url) } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
