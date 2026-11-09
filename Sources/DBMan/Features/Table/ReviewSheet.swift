import AppKit
import DBCore
import Halftone
import SwiftUI

/// Staged writes as a diff + the exact SQL; one transaction. Production needs the database name typed.
struct ReviewSheet: View {
    let ws: WorkspaceModel
    @State private var typed = ""
    @State private var error: String?
    @State private var committing = false

    private var engine: Engine { ws.profile.engine }
    private var dbName: String { ws.schema?.databaseName ?? ws.profile.database }
    private var isProd: Bool { ws.profile.environment == .production }
    private var confirmed: Bool { !isProd || typed == dbName }
    private var sql: String { ws.staged.transactionSQL(engine: engine) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel("Review // commit_\(ws.staged.count)_changes", isProd ? "production // \(dbName)" : dbName)
            Text("One transaction. If any statement fails, nothing is written.").ht(.bodySmall).foregroundStyle(HT.C.ink3)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) { ForEach(Array(ws.staged.items.enumerated()), id: \.offset) { diff($1) } }
                    ForEach(cascades, id: \.self) { Text($0).ht(.bodySmall).foregroundStyle(HT.C.amber) }
                    Text(sql).ht(.dataSmall).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                }
            }
            if isProd {
                HStack(spacing: 8) {
                    CapsLabel("Type", dbName).foregroundStyle(HT.C.ink3)
                    TextField(dbName, text: $typed).textFieldStyle(.plain).ht(.data).padding(.horizontal, 6).frame(height: 22).frame(maxWidth: 220)
                        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
                    Text(confirmed ? "✓ match" : "to confirm a production write").ht(.labelSmall).foregroundStyle(confirmed ? HT.C.ink : HT.C.ink3)
                }
            }
            if let error { Text(error).ht(.bodySmall).foregroundStyle(HT.C.alert).textSelection(.enabled) }
            HStack {
                Button("Copy_SQL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sql, forType: .string) }.buttonStyle(.htOutline)
                Spacer()
                Button("Cancel // esc") { ws.reviewOpen = false }.buttonStyle(.htOutline).keyboardShortcut(.cancelAction)
                if ws.writesUnlocked {
                    Button("Commit_\(ws.staged.count)_changes ⌘⏎") { commit() }.buttonStyle(.htPrimary)
                        .keyboardShortcut(.return, modifiers: .command).disabled(!confirmed || committing || ws.staged.isEmpty)
                } else {
                    Button("Unlock for this session") { ws.unlockWrites() }.buttonStyle(.htPrimary)
                }
            }
        }
        .padding(16).frame(width: 680, height: 520)
    }

    private func diff(_ c: StagedChange) -> some View {
        func key(_ k: [String: Cell]) -> String { k.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.display)" }.joined(separator: ", ") }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch c {
            case .update(let t, let k, let col, let old, let new):
                tag("Update", t); Text(key(k)).ht(.dataSmall).foregroundStyle(HT.C.ink3); Text(col).ht(.dataSmall)
                Text(old.display).ht(.dataSmall).strikethrough().foregroundStyle(HT.C.ink3); Text("→").foregroundStyle(HT.C.ink3)
                Text(new.display).ht(.dataSmall).foregroundStyle(HT.C.amber)
            case .insert(let t, let v):
                tag("Insert", t); Text(v.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.display)" }.joined(separator: ", ")).ht(.dataSmall).lineLimit(2)
            case .delete(let t, let k):
                tag("Delete", t); Text(key(k)).ht(.dataSmall).foregroundStyle(HT.C.alert)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
    }

    private func tag(_ op: String, _ table: String) -> some View {
        HStack(spacing: 4) { Text(op).foregroundStyle(op == "Delete" ? HT.C.alert : HT.C.ink); Text(table).foregroundStyle(HT.C.ink3) }.ht(.labelSmall).frame(width: 130, alignment: .leading)
    }

    /// Child tables whose FKs would cascade or null out when staged deletes commit.
    private var cascades: [String] {
        guard let schema = ws.schema else { return [] }
        let deleted = Set(ws.staged.items.compactMap { c -> String? in if case .delete(let t, _) = c { return t } else { return nil } })
        return deleted.sorted().flatMap { t in
            schema.tables.flatMap { child in
                child.columns.compactMap { col -> String? in
                    guard let fk = col.foreignKey, fk.table == t, let rule = fk.onDelete?.uppercased(), rule.contains("CASCADE") || rule.contains("SET") else { return nil }
                    return "Deleting from \(t) \(rule.contains("CASCADE") ? "cascades into" : "sets NULL/default on") \(child.name).\(col.name) (ON DELETE \(rule))"
                }
            }
        }
    }

    private func commit() {
        committing = true; error = nil
        Task {
            do { try await ws.commitStaged(); ws.reviewOpen = false }
            catch { self.error = error.localizedDescription; ws.log(sql, error.localizedDescription, error: true) }
            committing = false
        }
    }
}
