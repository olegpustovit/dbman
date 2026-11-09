import AppKit
import DBCore
import DBStore
import Halftone
import SwiftUI

/// Two-letter agent tile (SPEC §5: monograms, never vendor marks).
struct Monogram: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).tracking(0.4).frame(width: 22, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HT.C.ink, lineWidth: 1))
    }
}

/// What the sheet shows for an approval: the credential form, or the card for a block / removal.
struct ApprovalDialog: View {
    let a: ApprovalRow
    var body: some View {
        if a.kind == "credentials" { CredentialSheet(a: a) } else {
            VStack(alignment: .leading, spacing: 10) {
                ApprovalCard(a: a)
                HStack { Spacer(); Button("Later // esc") { ApprovalCenter.shared.dismiss() }.buttonStyle(.htOutline).keyboardShortcut(.cancelAction) }
            }.padding(14).frame(width: 520).background(HT.C.paper)
        }
    }
}

/// F2: "<agent> wants to add <name>". Fields come from the agent's request; the password is typed here, goes to the Keychain
/// (dev: secrets file) and never back to the agent, which only gets the new connection's id.
struct CredentialSheet: View {
    let a: ApprovalRow
    @Environment(AppModel.self) private var app
    @State private var env: EnvironmentTag
    @State private var password = ""
    @State private var reached: String?
    @State private var problem: String?
    @State private var testing = false
    @State private var note = ""

    init(a: ApprovalRow) { self.a = a; _env = State(initialValue: EnvironmentTag(rawValue: a.field("env") ?? "") ?? .local) }

    private var engine: Engine { Engine(rawValue: a.field("engine") ?? "") ?? .postgres }
    private var name: String { a.field("name") ?? "connection" }
    private var profile: ConnectionProfile {
        ConnectionProfile(name: name, engine: engine, host: a.field("host") ?? "", port: a.field("port").flatMap(Int.init), database: a.field("database") ?? "", user: a.field("user") ?? "",
                          filePath: a.field("file_path"), sslMode: SSLMode(rawValue: a.field("ssl_mode") ?? "") ?? .prefer, environment: env)
    }
    private var envOptions: [(value: EnvironmentTag, title: String)] { EnvironmentTag.allCases.filter { $0 != .system }.map { (value: $0, title: $0.rawValue.uppercased()) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { Monogram(text: a.mono); CapsLabel("\(a.who) wants to add a connection") }
                .padding(.horizontal, 12).frame(height: HT.M.frameHeader + 6)
            Rectangle().fill(HT.C.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.system(size: 15, weight: .semibold))
                    Text("// \(engine.displayName.uppercased()) // FROM THE AGENT").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                }
                Text(ConnectionURL.format(profile)).ht(.dataSmall).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 8).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                    .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    if engine == .sqlite {
                        row("FILE", profile.filePath ?? "")
                    } else {
                        row("HOST", profile.host, "PORT", String(profile.port))
                        row("DATABASE", profile.database, "USER", profile.user)
                    }
                    GridRow { CapsLabel("TAG").foregroundStyle(HT.C.ink3); HTSegmented(selection: $env, options: envOptions).gridCellColumns(3) }
                    if engine != .sqlite {
                        GridRow {
                            CapsLabel("PASSWORD").foregroundStyle(HT.C.ink3)
                            HStack(spacing: 8) {
                                SecureField("typed here, stored in Keychain", text: $password).textFieldStyle(.plain).ht(.bodySmall).accessibilityLabel("Password for \(profile.user)")
                                Text("→ KEYCHAIN").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                            }
                            .padding(.horizontal, 8).frame(height: 26)
                            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.accent, lineWidth: 1.5)).gridCellColumns(3)
                        }
                    }
                }
                Text("\(a.who) never sees this password: it goes straight to the Keychain and the agent only receives an id.").ht(.bodySmall).foregroundStyle(HT.C.ink2)
                TextField("Note to \(a.who) if you reject (optional)", text: $note).textFieldStyle(.plain).ht(.bodySmall)
                    .padding(.horizontal, 8).frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                HStack(spacing: 8) {
                    Button(testing ? "Testing…" : "Test") { test() }.buttonStyle(.htOutline).keyboardShortcut(.return, modifiers: [.option, .command]).disabled(testing)
                    if let reached { StatusText(label: "REACHED", value: reached) }
                    if let problem { StatusText(label: "ERROR", value: problem, tone: .alert) }
                }.frame(minHeight: 26)
            }.padding(12)
            Rectangle().fill(HT.C.line).frame(height: 1)
            HStack(spacing: 8) {
                Text("SAVED TO // \(env.rawValue.uppercased())").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                Spacer()
                Button("Later // esc") { ApprovalCenter.shared.dismiss() }.buttonStyle(.htOutline).keyboardShortcut(.cancelAction)
                Button("Reject") { ApprovalCenter.shared.decide(a, "rejected", note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [:] : ["note": note.trimmingCharacters(in: .whitespacesAndNewlines)]) }.buttonStyle(.htDestructive)
                Button("Save // ⌘S") { save() }.buttonStyle(.htPrimary).keyboardShortcut("s")
            }.padding(.horizontal, 12).frame(height: 44)
        }
        .frame(width: 460).background(HT.C.paper)
    }

    private func row(_ l1: String, _ v1: String, _ l2: String? = nil, _ v2: String? = nil) -> some View {
        GridRow {
            CapsLabel(l1).foregroundStyle(HT.C.ink3)
            readOnly(v1).gridCellColumns(l2 == nil ? 3 : 1)
            if let l2, let v2 { CapsLabel(l2).foregroundStyle(HT.C.ink3); readOnly(v2) }
        }
    }
    private func readOnly(_ v: String) -> some View {
        Text(v).ht(.dataSmall).lineLimit(1).truncationMode(.middle).padding(.horizontal, 8).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
            .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
    }

    private func test() {
        let p = profile, pw = password.isEmpty ? nil : password
        testing = true; reached = nil; problem = nil
        Task {
            defer { testing = false }
            do { reached = try await ConnectionTest.run(p, password: pw) } catch { problem = "Connection failed: \(error.localizedDescription)" }
        }
    }

    private func save() {
        let p = profile
        app.upsert(p)
        if !password.isEmpty { Keychain.save(password, for: p) }
        ApprovalCenter.shared.decide(a, "approved", ["connection_id": p.id.uuidString, "name": p.name])
    }
}

/// F4 and removals: the outlined item that needs a human. In the feed it is pinned above the log (board 05).
struct ApprovalCard: View {
    let a: ApprovalRow
    private let center = ApprovalCenter.shared

    var body: some View {
        let block = a.kind == "prod_guard"
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Monogram(text: a.mono)
                CapsLabel(block ? "Prod guard override" : a.kind == "remove" ? "Remove connection" : "Add connection").foregroundStyle(block ? HT.C.amber : HT.C.accent)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { c in Text("EXPIRES IN \(ApprovalCenter.countdown(a.expiresAt, now: c.date))").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
            }
            if block {
                HStack(spacing: 8) {
                    Text("BLOCKED_BY_PROD_GUARD").ht(.labelSmall).foregroundStyle(HT.C.alert)
                    Text("// \(a.who) · \(a.connectionName) · \(a.field("reason") ?? "")").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(2)
                }
                Text(a.field("sql") ?? "").ht(.dataSmall).textSelection(.enabled).lineLimit(6).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                HStack(spacing: 6) {
                    Button("Allow once") { center.allowOnce(a) }.buttonStyle(.htOutline).foregroundStyle(HT.C.amber).help("Let \(a.who) run this one statement once")
                    Button("Raise timeout // \(a.field("timeout_ms").flatMap(Int.init).map { $0 / 1000 } ?? 5) s → \(ApprovalCenter.raisedTimeoutMs / 1000) s") { center.raiseTimeout(a) }
                        .buttonStyle(.htOutline).help("Raise the statement timeout for this agent on \(a.connectionName)")
                    Spacer()
                    Button("Keep blocked") { center.decide(a, "rejected") }.buttonStyle(.htPrimary)
                }
            } else {
                HStack(spacing: 6) {
                    Text(a.summary).ht(.bodySmall).foregroundStyle(HT.C.ink2).lineLimit(2)
                    Spacer()
                    if a.kind == "remove" {
                        Button("Keep") { center.decide(a, "rejected") }.buttonStyle(.htOutline)
                        Button("Remove") { center.remove(a) }.buttonStyle(.htDestructive)
                    } else {
                        Button("Review") { center.review(a.id) }.buttonStyle(.htPrimary)
                    }
                }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(block ? HT.C.alert : HT.C.accent, lineWidth: 1.5))
        .accessibilityElement(children: .contain).accessibilityLabel(a.summary)
    }
}

/// PAUSE ALL AGENTS: while on, every tool call returns APP_LOCKED (persisted in settings).
struct PauseButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Button(app.agentsPaused ? "▶ Resume" : "‖ Pause agents") { app.agentsPaused.toggle() }
            .buttonStyle(.htOutline).foregroundStyle(app.agentsPaused ? HT.C.amber : HT.C.ink).fixedSize().lineLimit(1)
            .help("Pause all agents: every call returns APP_LOCKED until resumed")
    }
}
