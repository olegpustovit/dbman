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
    private let agentpack = AgentsModel.agentpackCLI(home: AgentsModel.shared.home)

    var body: some View {
        VStack(spacing: HT.M.gap) {
            HStack(spacing: HT.M.gap) {
                sidebar.frame(width: 250)
                detail
            }
            statusStrip
        }
        .padding(HT.M.windowPadding)
        .background(DotGridBackground())
        .onAppear { m.rescan(); m.reload(app.store); if let s = DevHooks.agentsSection { m.section = Self.section(s) } }
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
                        row(mono: "{}", name: "Other (copy JSON)", sub: "GENERIC // STDIO", on: m.section == .other, dim: false, dashed: true) { m.section = .other } chip: { chip(nil, text: "JSON", onInk: m.section == .other) }
                        header("MANAGE", agentpack == nil ? "02" : "03")
                        if agentpack != nil {
                            row(mono: "AP", name: "AGENTPACK", sub: "ONE DEFINITION // EVERY AGENT", on: m.section == .agentpack, dim: false) { m.section = .agentpack } chip: { EmptyView() }
                        }
                        row(mono: "PM", name: "PERMISSIONS", sub: "\(m.agents.count) AGENTS × \(m.connections.count) CONNECTIONS", on: m.section == .permissions, dim: false) { m.section = .permissions } chip: { EmptyView() }
                        let blocked = m.activity.filter { ["blocked", "denied"].contains($0.status) }.count
                        row(mono: "AC", name: "ACTIVITY", sub: "\(m.activity.count) CALLS", on: m.section == .activity, dim: false) { m.section = .activity } chip: {
                            if blocked > 0 { chip(nil, text: "\(blocked) BLOCKED", onInk: m.section == .activity, alert: true) } else { EmptyView() }
                        }
                    }.padding(8)
                }
                HStack(spacing: 6) {
                    Button("RESCAN") { m.rescan(); m.reload(app.store) }.buttonStyle(.htOutline).help("Rescan for agents")
                    PauseButton()
                    Spacer()
                    Text("SCANNED // \(m.scannedAt.formatted(date: .omitted, time: .standard))").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                }
                .padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
    }

    private func scopeLine(_ p: AgentPlatform) -> String {
        guard m.scope(p) == .project, let u = p.url(.project, home: m.home, project: m.projectURL) else { return "USER // " + display(p.url(.user, home: m.home, project: nil)!) }
        return "PROJECT // " + display(u)
    }
    private func display(_ u: URL) -> String { u.path.replacingOccurrences(of: m.home.path, with: "~") }

    private func header(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).ht(.label); Text("// \(v)").ht(.label).foregroundStyle(HT.C.ink3)
            Rectangle().fill(HT.C.line).frame(height: 1)
        }.padding(.top, 6).padding(.bottom, 2)
    }

    private func row<C: View>(mono: String, name: String, sub: String, on: Bool, dim: Bool, dashed: Bool = false, action: @escaping () -> Void, @ViewBuilder chip: () -> C) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(mono).font(.system(size: 9.5, weight: .bold)).tracking(0.4).frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(on ? HT.C.paper : (dim ? HT.C.line : HT.C.ink), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])))
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

    private func chip(_ s: AgentStatus?, text: String? = nil, onInk: Bool, alert: Bool = false) -> some View {
        let t = text ?? s!.rawValue
        let filled = s == .installed || alert
        let color: Color = alert ? HT.C.alert : (s == .needsUpdate ? HT.C.amber : (s == .notFound ? HT.C.ink3 : (onInk ? HT.C.paper : HT.C.ink)))
        return Text(t).font(.system(size: 9, weight: .semibold).width(.condensed)).tracking(0.7)
            .foregroundStyle(filled ? (alert ? HT.C.paper : (onInk ? HT.C.ink : HT.C.paper)) : color)
            .padding(.horizontal, 4).frame(height: 16)
            .background(filled ? (alert ? HT.C.alert : (onInk ? HT.C.paper : HT.C.ink)) : .clear, in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(filled ? .clear : color.opacity(onInk && s != .needsUpdate ? 0.7 : 1), lineWidth: 1))
            .fixedSize()
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch m.section {
        case .platform(let id): if let p = AgentPlatform.all.first(where: { $0.id == id }) { PlatformPane(m: m, p: p) }
        case .other: OtherPane(m: m)
        case .agentpack: AgentpackPane(m: m, cli: agentpack)
        case .permissions: PermissionsPane(m: m)
        case .activity: ActivityPane(m: m)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Group {
                Text("MCP SERVER").foregroundStyle(HT.C.ink); Text("//")
                Text("LISTENING ON"); Text("mcp.sock").foregroundStyle(HT.C.ink).help(UnixSocket.path(storeDir: app.store.url.deletingLastPathComponent().path)); Text("//")
                Text("\(host.live.count) CLIENTS LIVE").foregroundStyle(host.live.isEmpty ? HT.C.ink3 : HT.C.accent)
            }
            Spacer()
            Text("PROTOCOL // 2025-06-18 // STDIO")
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
                HStack(spacing: 8) { Text(p.name.uppercased()).ht(.label); Text(st.rawValue).ht(.labelSmall).foregroundStyle(st == .needsUpdate ? HT.C.amber : st == .installed ? HT.C.accent : HT.C.ink3) }
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
            Text(sc == .project ? "GIT REPO // SHARED WITH TEAM" : "EVERY PROJECT ON THIS MAC").ht(.labelSmall).foregroundStyle(HT.C.ink3)
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
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((rows.isEmpty ? AgentConfig.diff(nil, c.after) : rows).enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 0) {
                            Text(r.n.map(String.init) ?? "").frame(width: 36, alignment: .trailing).foregroundStyle(HT.C.ink3).padding(.trailing, 8)
                            Text(r.sign == "-" ? "−" : r.sign == "+" ? "+" : " ").frame(width: 14)
                            Text(r.text).strikethrough(r.sign == "-").lineLimit(1).truncationMode(.middle)
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
                    Text("// \(hs.name) \(hs.version)").ht(.data)
                }
                Text("Ask \(p.name): 'list my DBMan connections' — the call appears in ACTIVITY.").ht(.bodySmall).foregroundStyle(HT.C.ink2)
            } else if waiting {
                CapsLabel("WAITING FOR HANDSHAKE…", "START A NEW \(p.name.uppercased()) SESSION — IT LAUNCHES dbman-mcp").foregroundStyle(HT.C.accent)
                ProgressView().progressViewStyle(.linear).tint(HT.C.accent)
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
            Text(st == .notFound ? "NOT FOUND // NOTHING WILL BE WRITTEN" : "BACKUP FIRST // \(URL(fileURLWithPath: file).lastPathComponent).DBMAN-BACKUP // CANCEL RESTORES IT").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
            Spacer()
            if waiting {
                Button("CANCEL // ⎋") { m.cancel(p) }.buttonStyle(.htOutline).keyboardShortcut(.cancelAction)
                Button("WAITING…") {}.buttonStyle(.htOutline).disabled(true)
            } else if st == .installed {
                Button("OPEN ACTIVITY") { m.section = .activity }.buttonStyle(.htOutline)
                Button("DISCONNECT") { m.disconnect(p) }.buttonStyle(.htOutline)
            } else {
                Button(copied ? "✓ COPIED" : p.id == "claude-code" ? "COPY COMMAND" : "COPY CONFIG") { copy() }.buttonStyle(.htOutline)
                Button(st == .needsUpdate ? "UPDATE // ⏎" : "CONNECT // ⏎") { m.connect(p) }.buttonStyle(.htPrimary).keyboardShortcut(.defaultAction).disabled(st == .notFound)
            }
        }
        .padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
    }

    private func copy() {
        let text = p.id == "claude-code" ? "claude mcp add dbman -s user -- \(m.helper) --stdio" : ((try? AgentConfig.install(p, into: nil, helper: m.helper)) ?? "")
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
        HTFrame(title: "OTHER (COPY JSON)", tail: "GENERIC // STDIO") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Any MCP client that speaks stdio can launch DBMan: paste this entry into its config, or point it at the binary below — credentials never leave DBMan.")
                    .ht(.bodySmall).foregroundStyle(HT.C.ink2)
                CapsLabel("BINARY", "LAUNCH WITH --stdio")
                Text(m.helper).ht(.dataSmall).textSelection(.enabled)
                CapsLabel("JSON", "mcpServers entry")
                Text(AgentConfig.genericJSON(helper: m.helper)).ht(.dataSmall).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(copied == "bin" ? "✓ COPIED" : "COPY BINARY PATH") { copy(m.helper, "bin") }.buttonStyle(.htOutline)
                    Button(copied == "json" ? "✓ COPIED" : "COPY JSON // ⏎") { copy(AgentConfig.genericJSON(helper: m.helper), "json") }.buttonStyle(.htPrimary).keyboardShortcut(.defaultAction)
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
    @State private var addMCP = true
    @State private var sync = true
    @State private var running = false
    @State private var output = ""

    private var project: URL? { m.projectURL }
    private var toml: String? { project.flatMap { try? String(contentsOf: $0.appendingPathComponent("agentpack.toml"), encoding: .utf8) } }

    var body: some View {
        HTFrame(title: "AGENTPACK", tail: "ONE DEFINITION // EVERY AGENT") {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            CapsLabel("PROJECT")
                            TextField("~/projects/shop", text: $m.projectPath).ht(.dataSmall).htInput().frame(maxWidth: 320)
                            if toml != nil { Text("✓ agentpack.toml").ht(.labelSmall).foregroundStyle(HT.C.accent) }
                            Button("CHOOSE…") { choose() }.buttonStyle(.htOutline)
                        }
                        step("Add DBMan to agentpack.toml", "agentpack mcp add dbman --command \(m.helper) --args --stdio", $addMCP)
                        step("Run agentpack sync", "agentpack sync", $sync)
                        HStack {
                            Button(running ? "RUNNING…" : "RUN \((addMCP ? 1 : 0) + (sync ? 1 : 0)) STEPS // ⌘⏎") { run() }
                                .buttonStyle(.htPrimary).keyboardShortcut(.return, modifiers: .command)
                                .disabled(running || project == nil || (!addMCP && !sync))
                            Text("WRITES agentpack.toml + pack.lock").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                        }
                        lock
                        if !output.isEmpty {
                            CapsLabel("OUTPUT", "TAIL")
                            Text(output).ht(.dataSmall).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            CapsLabel("LAUNCH IN TERMINAL", project.map { "AT \($0.path.replacingOccurrences(of: m.home.path, with: "~").uppercased())" })
                            HStack { ForEach(["claude", "codex", "agent", "opencode"], id: \.self) { a in
                                Button("agentpack \(a) ↗") { if let project { AgentsModel.launch(agent: a, in: project) } }.buttonStyle(.htOutline).disabled(project == nil)
                            } }
                        }
                    }.padding(12)
                }
                Text("COMMIT agentpack.toml + pack.lock // TEAMMATES GET DBMAN ON NEXT SYNC").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
    }

    private func step(_ title: String, _ cmd: String, _ on: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { HTToggleChip(on.wrappedValue ? "✓" : " ", isOn: on).frame(width: 28); Text(title).ht(.label) }
            Text("$ \(cmd)").ht(.dataSmall).foregroundStyle(HT.C.ink2).textSelection(.enabled).padding(.leading, 34)
        }
    }

    /// Lock line: dbman is a `command` launcher, which pack.lock cannot hash, so it reads `unpinnable`.
    @ViewBuilder private var lock: some View {
        if toml?.contains("dbman") == true {
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel("PACK.LOCK", "dbman // unpinnable")
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
        let helper = m.helper, steps = (addMCP ? [["mcp", "add", "dbman", "--command", helper, "--args", "--stdio"]] : []) + (sync ? [["sync"]] : [])
        Task.detached {
            var log = ""
            for a in steps {
                let r = try? AgentConfig.run(cli, a, cwd: project)
                log += "$ agentpack \(a.joined(separator: " "))\n" + (r?.output ?? "could not run agentpack\n")
                if r?.status != 0 { log += "exit \(r?.status ?? -1)\n"; break }
            }
            let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).joined(separator: "\n")
            await MainActor.run { output = tail; running = false }
        }
    }
}
