import AppKit
import DBCore
import Halftone
import SwiftUI
import UniformTypeIdentifiers

struct DBManCommands: Commands {
    @FocusedValue(\.workspace) private var ws
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Connection") { openWindow(id: "connections") }.keyboardShortcut("n")
            Button("Open SQLite File…") { openSQLite() }.keyboardShortcut("o")
        }
        // Replaces the default Close so ⌘W closes the active tab first.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let ws, ws.route != .overview { ws.closeTab(ws.route) } else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
        }
        CommandMenu("Database") {
            Button("Refresh") { Task { await ws?.refreshSchema() } }.keyboardShortcut("r").disabled(ws == nil)
            Button("Unlock Writes") { ws?.unlockWrites() }.disabled(ws == nil || ws?.writesUnlocked == true)
            Button("Lock Writes") { ws?.lockWrites() }.keyboardShortcut("l").disabled(ws == nil || ws?.writesUnlocked == false)
            Divider()
            Button("Review & Commit…") { ws?.reviewOpen = true }.keyboardShortcut("r", modifiers: [.shift, .command]).disabled(ws?.staged.isEmpty ?? true)
            Divider()
            Button("Disconnect") { ws?.disconnect() }.disabled(ws == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Overview") { ws?.go(.overview) }.keyboardShortcut("0")
            Button("Edit Dashboard") { ws?.dash.toggleEdit() }.keyboardShortcut("e").disabled(ws == nil || { if case .overview = ws?.route { false } else if case .dashboard = ws?.route { false } else { true } }())
            // A table's own rail owns ⌘4 (Stats) while one is open; everywhere else ⌘4 is the schema map.
            Button("Schema Map") { ws?.go(.schemaMap) }.keyboardShortcut("4").disabled(ws == nil || { if case .table = ws?.route { true } else { false } }())
            Button("Toggle Inspector") { ws?.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.option, .command])
            Button("Toggle Console") { ws?.showConsole.toggle() }.keyboardShortcut("j")
            Button("Relative Dates") { ws?.relativeDates.toggle() }.keyboardShortcut("r", modifiers: [.control, .command])
            Button("Command Palette") { ws?.paletteOpen.toggle() }.keyboardShortcut("k")
        }
        CommandMenu("Agents") {
            Button("Connect an Agent…") { openWindow(id: "agents") }.keyboardShortcut("a", modifiers: [.shift, .command])
        }
        CommandMenu("Navigate") {
            Button("Back") { ws?.back() }.keyboardShortcut("[").disabled(ws?.history.isEmpty ?? true)
            Button("Forward") { ws?.goForward() }.keyboardShortcut("]").disabled(ws?.forward.isEmpty ?? true)
        }
        CommandMenu("Query") {
            Button("New Query") { ws?.newQuery() }.keyboardShortcut("t").disabled(ws == nil)
            // Run statement (⌘⏎) is handled by the editor.
        }
    }

    private func openSQLite() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["sqlite", "sqlite3", "db"].compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        AppModel.shared.openFile(url)
    }
}
