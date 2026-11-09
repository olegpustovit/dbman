import AppKit
import DBManMCP
import DBStore
import Halftone
import SwiftUI

/// The Agents window (SPEC §1.2–1.5): platforms to CONNECT, AGENTPACK, PERMISSIONS, ACTIVITY.
struct AgentsWindow: View {
    @Environment(AppModel.self) private var app
    @Bindable private var m = AgentsModel.shared
    private var host: MCPHost { MCPHost.shared }

    var body: some View {
        VStack(spacing: HT.M.seam) {
            HStack(spacing: HT.M.seam) {
                sidebar.frame(width: 250)
                detail
            }
            statusStrip
        }
        .padding(HT.M.windowPadding)
        .background(DotGridBackground())
        .onAppear { m.rescan(); m.reload(app.store); if let s = DevHooks.agentsSection { m.section = Self.section(s) }
            if let c = DevHooks.agentsConnect, let p = AgentPlatform.all.first(where: { $0.id == c }), m.phase[c] == nil { m.connect(p) } }
    }

    static func section(_ s: String) -> AgentsModel.Section {
        switch s { case "perms": .permissions; case "activity": .activity; case "agentpack": .agentpack; case "other": .other; default: .platform(s) }
    }

    // MARK: sidebar

    private var sidebar: some View {
        HTFrame(title: "AGENTS", tail: "\(host.live.count) LIVE") {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        header("PLATFORMS", "\(String(format: "%02d", m.foundCount)) FOUND")
                        ForEach(AgentPlatform.all) { p in
                            let st = m.status(p), on = m.section == .platform(p.id)
                            row(mono: p.mono, name: p.name, sub: scopeLine(p), on: on, dim: st == .notFound) { m.section = .platform(p.id) } chip: { chip(st, onInk: on) }
                        }
                        row(mono: "{}", name: "Other (copy JSON)", sub: "GENERIC · STDIO", on: m.section == .other, dim: false, dashed: true) { m.section = .other } chip: { chip(nil, text: "JSON", onInk: m.section == .other) }
                        header("MANAGE", "03")
                        row(mono: "AP", name: "AGENTPACK", sub: "ONE DEFINITION · EVERY AGENT", on: m.section == .agentpack, dim: m.agentpack == nil) { m.section = .agentpack } chip: {
                            if m.agentpack == nil { chip(.notFound, onInk: m.section == .agentpack) } else { EmptyView() }
                        }
                        row(mono: "PM", name: "PERMISSIONS", sub: "\(m.agents.count) AGENTS × \(m.connections.count) CONNECTIONS", on: m.section == .permissions, dim: false) { m.section = .permissions } chip: { EmptyView() }
                        let blocked = m.activity.filter { ["blocked", "denied"].contains($0.status) }.count
                        row(mono: "AC", name: "ACTIVITY", sub: "\(m.activity.count) CALLS", on: m.section == .activity, dim: false) { m.section = .activity } chip: {
                            if blocked > 0 { chip(nil, text: "\(blocked) BLOCKED", onInk: m.section == .activity, alert: true) } else { EmptyView() }
                        }
                    }.padding(8)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button("RESCAN") { m.rescan(); m.reload(app.store) }.buttonStyle(.htOutline).help("Rescan for agents").fixedSize()
                        Spacer()
                        Text("SCANNED · \(m.scannedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1).fixedSize()
                    }
                    PauseButton()
                }
                .padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
    }

    private func scopeLine(_ p: AgentPlatform) -> String {
        guard m.scope(p) == .project, let u = p.url(.project, home: m.home, project: m.projectURL) else { return "USER · " + display(p.url(.user, home: m.home, project: nil)!) }
        return "PROJECT · " + display(u)
    }
    private func display(_ u: URL) -> String { u.path.replacingOccurrences(of: m.home.path, with: "~") }

    private func header(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).ht(.label); Text("\(v)").ht(.label).foregroundStyle(HT.C.ink3)
            Rectangle().fill(HT.C.line).frame(height: 1)
        }.padding(.top, 6).padding(.bottom, 2)
    }

    private func row<C: View>(mono: String, name: String, sub: String, on: Bool, dim: Bool, dashed: Bool = false, action: @escaping () -> Void, @ViewBuilder chip: () -> C) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(mono).font(.system(size: 9.5, weight: .semibold)).tracking(0.4).frame(width: 22, height: 22)
                    .foregroundStyle(on ? HT.C.paper : HT.C.ink3)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(on ? HT.C.paper.opacity(0.5) : HT.C.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).ht(.label).lineLimit(1)
                    Text(sub).ht(.labelSmall).lineLimit(1).truncationMode(.middle).opacity(on ? 0.7 : 1).foregroundStyle(on ? HT.C.paper : HT.C.ink3)
                }
                Spacer(minLength: 2)
                chip()
            }
            .foregroundStyle(on ? HT.C.paper : (dim ? HT.C.ink3 : HT.C.ink))
            .padding(.horizontal, 6).frame(height: 36)
            .background(on ? HT.C.ink : .clear, in: RoundedRectangle(cornerRadius: HT.M.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Status as a small dot + caps text, no box; only an alert count gets a filled badge.
    @ViewBuilder private func chip(_ s: AgentStatus?, text: String? = nil, onInk: Bool, alert: Bool = false) -> some View {
        if alert {
            Text(text ?? "").font(.system(size: 9, weight: .semibold).width(.condensed)).tracking(0.7)
                .foregroundStyle(HT.C.paper).padding(.horizontal, 4).frame(height: 16)
                .background(HT.C.alert, in: RoundedRectangle(cornerRadius: 2)).fixedSize()
        } else {
            let color: Color = onInk ? HT.C.paper.opacity(0.75) : s == .installed ? HT.C.accent : s == .needsUpdate ? HT.C.amber : HT.C.ink3
            HStack(spacing: 4) {
                if let s {
                    Circle().fill(s == .installed || s == .needsUpdate ? color : .clear)
                        .overlay(Circle().strokeBorder(color, lineWidth: 1)).frame(width: 6, height: 6)
                        .opacity(s == .notFound ? 0.5 : 1)
                }
                Text(text ?? Self.label(s!)).font(.system(size: 9, weight: .medium).width(.condensed)).tracking(0.6)
            }
            .foregroundStyle(color).fixedSize()
        }
    }

    static func label(_ s: AgentStatus) -> String {
        switch s { case .notFound: "NOT FOUND"; case .notInstalled: "NOT CONNECTED"; case .installed: "CONNECTED"; case .needsUpdate: "UPDATE" }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch m.section {
        case .platform(let id): if let p = AgentPlatform.all.first(where: { $0.id == id }) { PlatformPane(m: m, p: p) }
        case .other: OtherPane(m: m)
        case .agentpack: AgentpackPane(m: m, cli: m.agentpack)
        case .permissions: PermissionsPane(m: m)
        case .activity: ActivityPane(m: m)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Group {
                Text("MCP SERVER").foregroundStyle(HT.C.ink); HTDivider()
                Text("LISTENING ON"); Text("mcp.sock").foregroundStyle(HT.C.ink).help(UnixSocket.path(storeDir: app.store.url.deletingLastPathComponent().path)); HTDivider()
                Text("\(host.live.count) CLIENTS LIVE").foregroundStyle(host.live.isEmpty ? HT.C.ink3 : HT.C.accent)
            }
            Spacer()
            Text("PROTOCOL · 2025-06-18 · STDIO")
        }
        .ht(.labelSmall).foregroundStyle(HT.C.ink3)
        .padding(.horizontal, 8).frame(height: HT.M.statusStrip)
    }
}

// MARK: - platform

private struct PlatformPane: View {
    @Bindable var m: AgentsModel
    let p: AgentPlatform
    @State private var copied = false

    var body: some View {
        let st = m.status(p), sc = m.scope(p), plan = m.plan(p), ph = m.phase[p.id] ?? .idle
        let hs: Handshake? = { if case .waiting(let since) = ph { return m.handshake(p, since: since) }; return st == .installed ? m.live(p) : nil }()
        let waiting = hs == nil && { if case .waiting = ph { return true }; return false }()
        let file = (p.url(sc, home: m.home, project: m.projectURL)).map { $0.path.replacingOccurrences(of: m.home.path, with: "~") } ?? "choose a project folder"
        HTFrame(title: p.name.uppercased(), tail: file) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        head(st, file)
                        steps(hs != nil ? 3 : waiting ? 2 : 0)
                        if p.hasProject && st != .notFound || sc == .project { scopeRow(sc) }
                        if p.id == "claude-code" { CopyBlock("COMMAND", "RUN IN A TERMINAL — SAME AS CONNECT", m.claudeCommand(sc)) }
                        diffSection(plan, st)
                        if st != .notFound { verify(hs, waiting, ph) }
                        if let e = m.error { Text(e).ht(.bodySmall).foregroundStyle(HT.C.alert) }
                    }.padding(12)
                }
                footer(st, waiting: waiting, connected: hs != nil, file: file)
            }
        }
    }

    private func head(_ st: AgentStatus, _ file: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(p.mono).font(.system(size: 15, weight: .bold)).frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(st == .notFound ? HT.C.line : HT.C.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) { Text(p.name.uppercased()).ht(.label); Text(AgentsWindow.label(st)).ht(.labelSmall).foregroundStyle(st == .needsUpdate ? HT.C.amber : st == .installed ? HT.C.accent : HT.C.ink3) }
                Text(sentence(st, file)).ht(.bodySmall).foregroundStyle(HT.C.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentence(_ st: AgentStatus, _ file: String) -> String {
        switch st {
        case .notFound: "\(p.name) was not found — DBMan looked for \(file). Install it and RESCAN, or copy the config below into it yourself."
        case .installed: "\(p.name) launches dbman-mcp over stdio; every call it makes shows up in ACTIVITY. DISCONNECT removes only the dbman entry from \(file)."
        case .needsUpdate: "\(p.name) points at a different dbman-mcp than this app's; UPDATE rewrites the dbman entry in \(file)."
        case .notInstalled:
            if case .success(let c) = m.plan(p) { "DBMan will add one dbman entry to \(file) — \(AgentConfig.diff(c.before, c.after).filter { $0.sign == "+" }.count) lines, nothing else changes, and your passwords stay in DBMan." } else { "" }
        }
    }

    private func steps(_ idx: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(["PREVIEW DIFF", "APPLY", "HANDSHAKE", "CONNECTED"].enumerated()), id: \.offset) { i, t in
                let cur = i == idx, done = i < idx
                VStack(alignment: .leading, spacing: 3) {
                    Rectangle().fill(cur ? HT.C.accent : done ? HT.C.ink : HT.C.line).frame(height: 2)
                    Text("0\(i + 1)  \(t)").ht(.labelSmall).foregroundStyle(cur ? HT.C.accent : done ? HT.C.ink : HT.C.ink3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func scopeRow(_ sc: AgentScope) -> some View {
        HStack(spacing: 8) {
            CapsLabel("SCOPE")
            HTSegmented(selection: Binding(get: { sc }, set: { m.scope[p.id] = $0; m.rescan() }), options: [(AgentScope.user, "USER"), (AgentScope.project, "PROJECT")])
            if sc == .project {
                CapsLabel("PATH")
                TextField("~/projects/shop", text: $m.projectPath).ht(.dataSmall).htInput().frame(maxWidth: 260).onSubmit { m.rescan() }
                Button("CHOOSE…") { choose() }.buttonStyle(.htOutline)
            }
            Text(sc == .project ? "GIT REPO · SHARED WITH TEAM" : "EVERY PROJECT ON THIS MAC").ht(.labelSmall).foregroundStyle(HT.C.ink3)
        }
    }

    private func choose() {
        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false
        if o.runModal() == .OK, let u = o.url { m.projectPath = u.path; m.rescan() }
    }

    private func diffSection(_ plan: Result<ConfigChange, ConfigError>, _ st: AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch plan {
            case .failure(let e): Text(e.localizedDescription).ht(.bodySmall).foregroundStyle(HT.C.alert)
            case .success(let c):
                let rows = AgentConfig.diff(c.before, c.after)
                let add = rows.filter { $0.sign == "+" }.count, del = rows.filter { $0.sign == "-" }.count
                HStack {
                    CapsLabel(st == .notFound ? "WOULD ADD" : rows.isEmpty ? "APPLIED" : "DIFF", c.url.path.replacingOccurrences(of: m.home.path, with: "~"))
                    Spacer()
                    Text(rows.isEmpty ? "✓ IN SYNC" : "+\(add) −\(del)").ht(.labelSmall).foregroundStyle(rows.isEmpty ? HT.C.ink3 : HT.C.accent)
                    if add > 0 { CopyButton("COPY ADDED") { rows.filter { $0.sign == "+" }.map(\.text).joined(separator: "\n") } }
                    CopyButton("COPY FILE") { c.after }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((rows.isEmpty ? AgentConfig.diff(nil, c.after) : rows).enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 0) {
                            Text(r.n.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(HT.C.ink3).padding(.trailing, 8)
                            Text(r.sign == "-" ? "−" : r.sign == "+" ? "+" : " ").frame(width: 14)
                            Text(r.text).strikethrough(r.sign == "-").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .ht(.dataSmall)
                        .foregroundStyle(r.sign == "+" ? HT.C.accent : r.sign == "-" ? HT.C.ink3 : HT.C.ink2)
                        .overlay(alignment: .leading) { if r.sign == "+" { Rectangle().fill(HT.C.accent).frame(width: 2) } }
                    }
                }
                .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
            }
        }
    }

    private func verify(_ hs: Handshake?, _ waiting: Bool, _ ph: AgentsModel.Phase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hs {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("CONNECTED").font(.system(size: 20, weight: .light)).foregroundStyle(HT.C.accent)
                    Text("\(hs.name) \(hs.version)").ht(.data)
                }
                Text("Ask \(p.name): 'list my DBMan connections' — the call appears in ACTIVITY.").ht(.bodySmall).foregroundStyle(HT.C.ink2)
            } else if waiting {
                CapsLabel("WAITING FOR HANDSHAKE…", "START A NEW \(p.name.uppercased()) SESSION — IT LAUNCHES dbman-mcp").foregroundStyle(HT.C.accent)
                HStack(spacing: 8) { DotSpinner(tint: HT.C.accent); Text("listening on DBMan's socket").ht(.dataSmall).foregroundStyle(HT.C.ink3) }
            } else {
                CapsLabel("VERIFY", ph == .timedOut ? "NO HANDSHAKE IN 2 MIN — START A NEW SESSION AND TRY AGAIN" : "WAITS FOR THE AGENT'S FIRST INITIALIZE CALL AFTER APPLY")
                    .foregroundStyle(ph == .timedOut ? HT.C.amber : HT.C.ink3)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(hs != nil ? HT.C.accent : HT.C.line, lineWidth: 1))
    }

    private func footer(_ st: AgentStatus, waiting: Bool, connected: Bool, file: String) -> some View {
        HStack(spacing: 8) {
            Text(st == .notFound ? "NOT FOUND · NOTHING WILL BE WRITTEN" : "BACKUP FIRST · \(URL(fileURLWithPath: file).lastPathComponent).DBMAN-BACKUP · CANCEL RESTORES IT").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
            Spacer()
            if waiting {
                Button("CANCEL  ⎋") { m.cancel(p) }.buttonStyle(.htOutline).keyboardShortcut(.cancelAction)
                Button("WAITING…") {}.buttonStyle(.htOutline).disabled(true)
            } else if st == .installed {
                Button("OPEN ACTIVITY") { m.section = .activity }.buttonStyle(.htOutline)
                Button("DISCONNECT") { m.disconnect(p) }.buttonStyle(.htOutline)
            } else {
                Button(copied ? "✓ COPIED" : p.id == "claude-code" ? "COPY COMMAND" : "COPY CONFIG") { copy() }.buttonStyle(.htOutline)
                Button(st == .needsUpdate ? "UPDATE  ⏎" : "CONNECT  ⏎") { m.connect(p) }.buttonStyle(.htPrimary).keyboardShortcut(.defaultAction).disabled(st == .notFound)
            }
        }
        .padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
    }

    private func copy() {
        let text = p.id == "claude-code" ? m.claudeCommand(m.scope(p)) : ((try? AgentConfig.install(p, into: nil, helper: m.helper)) ?? "")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
    }
}

// MARK: - other

private struct OtherPane: View {
    let m: AgentsModel
    @State private var copied: String?

    var body: some View {
        HTFrame(title: "OTHER (COPY JSON)", tail: "GENERIC · STDIO") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Any MCP client that speaks stdio can launch DBMan: paste this entry into its config, or point it at the binary below — credentials never leave DBMan.")
                    .ht(.bodySmall).foregroundStyle(HT.C.ink2)
                CopyBlock("COMMAND", "LAUNCH LINE", "\(AgentsModel.sh(m.helper)) --stdio")
                CopyBlock("JSON", "mcpServers entry", AgentConfig.genericJSON(helper: m.helper))
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(copied == "bin" ? "✓ COPIED" : "COPY BINARY PATH") { copy(m.helper, "bin") }.buttonStyle(.htOutline)
                    Button(copied == "json" ? "✓ COPIED" : "COPY JSON  ⏎") { copy(AgentConfig.genericJSON(helper: m.helper), "json") }.buttonStyle(.htPrimary).keyboardShortcut(.defaultAction)
                }
            }.padding(12)
        }
    }

    private func copy(_ s: String, _ k: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = k
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = nil }
    }
}

// MARK: - agentpack

private struct AgentpackPane: View {
    @Bindable var m: AgentsModel
    let cli: URL?
    @State private var running = false
    @State private var output = ""

    private var project: URL? { m.projectURL }
    private var toml: String? { project.flatMap { try? String(contentsOf: $0.appendingPathComponent("agentpack.toml"), encoding: .utf8) } }

    private var add: [String] { ["mcp", "add", "dbman", "--command", m.helper, "--args", "--stdio"] }
    private var ap: String { m.agentpackName }
    private func line(_ args: [String]) -> String { ([ap] + args.map(AgentsModel.sh)).joined(separator: " ") }
    private var cdLine: String { "cd " + AgentsModel.sh(project.map { $0.path.replacingOccurrences(of: m.home.path, with: "~") } ?? "~/projects/shop").replacingOccurrences(of: "'~", with: "~'") }
    /// Everything RUN does, as one paste-able script.
    private var needsAdd: Bool { toml?.contains("dbman") != true }
    /// What RUN does: init when there is no manifest, add when it lacks dbman, always sync.
    private var steps: [[String]] { (toml == nil ? [["init"]] : []) + (needsAdd ? [add] : []) + [["sync"]] }
    private var script: String { ([cdLine] + steps.map(line)).joined(separator: "\n") }

    var body: some View {
        HTFrame(title: "AGENTPACK", tail: cli.map { $0.path.replacingOccurrences(of: m.home.path, with: "~") } ?? "NOT FOUND ON PATH") {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if cli == nil {
                            VStack(alignment: .leading, spacing: 4) {
                                CapsLabel("AGENTPACK NOT FOUND", "LOOKED IN PATH, HOMEBREW, ~/.local/bin, ~/.cargo/bin, NIX PROFILES").foregroundStyle(HT.C.amber)
                                Text("Neither `ap` nor `agentpack` was found. Install agentpack (github.com/olegpustovit/agentpack) and RESCAN to run these from here — or copy the commands below into a terminal.")
                                    .ht(.bodySmall).foregroundStyle(HT.C.ink2)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.amber, lineWidth: 1))
                        }
                        HStack(spacing: 8) {
                            CapsLabel("PROJECT")
                            TextField("~/projects/shop", text: $m.projectPath).ht(.dataSmall).htInput().frame(maxWidth: 320)
                            if toml != nil { Text("✓ agentpack.toml").ht(.labelSmall).foregroundStyle(HT.C.accent) }
                            Button("CHOOSE…") { choose() }.buttonStyle(.htOutline)
                        }
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, a in
                            step(i + 1, a == ["init"] ? "Create agentpack.toml" : a == ["sync"] ? "Stage it for every agent" : "Add DBMan to agentpack.toml", line(a))
                        }
                        if !needsAdd { Text("✓ DBMAN IS ALREADY IN agentpack.toml · RUN JUST SYNCS").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
                        HStack {
                            Button(running ? "RUNNING…" : steps.count == 1 ? "SYNC  ⌘⏎" : "RUN \(steps.count) STEPS  ⌘⏎") { run() }
                                .buttonStyle(.htPrimary).keyboardShortcut(.return, modifiers: .command)
                                .disabled(running || cli == nil || project == nil)
                            CopyButton("COPY ALL AS SCRIPT") { script }
                            Text("WRITES agentpack.toml + pack.lock").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                        }
                        lock
                        if !output.isEmpty {
                            CapsLabel("OUTPUT", "TAIL")
                            Text(output).ht(.dataSmall).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            CapsLabel("LAUNCH", project.map { "AT \($0.path.replacingOccurrences(of: m.home.path, with: "~").uppercased())" })
                            ForEach(["claude", "codex", "agent", "opencode"], id: \.self) { a in
                                HStack(spacing: 6) {
                                    Text("$ \(cdLine) && \(ap) \(a)").ht(.dataSmall).foregroundStyle(HT.C.ink2).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    CopyButton("COPY") { "\(cdLine) && \(ap) \(a)" }
                                    Button("OPEN IN TERMINAL ↗") { if let project, let cli { AgentsModel.launch(cli: cli, agent: a, in: project) } }.buttonStyle(.htOutline).disabled(project == nil || cli == nil)
                                }
                            }
                        }
                    }.padding(12)
                }
                Text("COMMIT agentpack.toml + pack.lock · TEAMMATES GET DBMAN ON NEXT SYNC").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
        .onAppear { if let p = DevHooks.agentpackRun, m.projectPath.isEmpty { m.projectPath = p; run() } }
    }

    /// A numbered step: title, and its command with a COPY button.
    private func step(_ n: Int, _ title: String, _ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(String(format: "%02d", n)).ht(.labelSmall).foregroundStyle(HT.C.ink3).frame(width: 34, alignment: .leading)
                Text(title).ht(.label)
            }
            HStack(spacing: 6) {
                Text("$ \(cmd)").ht(.dataSmall).foregroundStyle(HT.C.ink2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                CopyButton("COPY") { cmd }
            }.padding(.leading, 34)
        }
    }

    /// Lock line: dbman is a `command` launcher, which pack.lock cannot hash, so it reads `unpinnable`.
    @ViewBuilder private var lock: some View {
        if toml?.contains("dbman") == true {
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel("PACK.LOCK", "dbman · unpinnable")
                Text("unpinnable is expected: dbman is a command launcher for your local DBMan.app, so there is no source for pack.lock to hash. Only the MCP server is staged; its tool descriptions carry the guidance.")
                    .ht(.bodySmall).foregroundStyle(HT.C.ink3)
            }
        }
    }

    private func choose() {
        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false
        if o.runModal() == .OK, let u = o.url { m.projectPath = u.path }
    }

    private func run() {
        guard let cli, let project else { return }
        running = true; output = ""
        let home = ["HOME": m.home.path] // sync touches agent dirs under HOME; DBMAN_AGENT_HOME keeps a dev run off the real ones
        // `mcp add` refuses a project without agentpack.toml (verified against agentpack 0.13.9), so a new project gets `init` first.
        let steps = steps
        Task.detached {
            var log = ""
            for a in steps {
                let r = try? AgentConfig.run(cli, a, cwd: project, env: home)
                log += "$ \(cli.lastPathComponent) \(a.joined(separator: " "))\n" + (r?.output ?? "could not run agentpack\n")
                if r?.status != 0 { log += "exit \(r?.status ?? -1)\n"; break }
            }
            let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).joined(separator: "\n")
            await MainActor.run { output = tail; running = false }
        }
    }
}

// MARK: - copy

/// Caps button that puts `text()` on the pasteboard and flips to ✓ COPIED for a moment.
struct CopyButton: View {
    let label: String
    let text: () -> String
    @State private var done = false
    init(_ label: String = "COPY", text: @escaping () -> String) { self.label = label; self.text = text }

    var body: some View {
        Button(done ? "✓ COPIED" : label) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text(), forType: .string)
            done = true
            Task { try? await Task.sleep(for: .seconds(1.4)); done = false }
        }
        .buttonStyle(.htOutline).fixedSize().help("Copy to clipboard")
    }
}

/// Caption + selectable code block with a COPY button.
struct CopyBlock: View {
    let caption: String, detail: String?, code: String
    init(_ caption: String, _ detail: String? = nil, _ code: String) { self.caption = caption; self.detail = detail; self.code = code }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { CapsLabel(caption, detail); Spacer(); CopyButton { code } }
            Text(code).ht(.dataSmall).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
        }
    }
}
