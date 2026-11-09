import DBStore
import Halftone
import SwiftUI

// MARK: - permissions

/// Agent × connection matrix (OFF / READ / OVERLAY), per-cell limits, and the sensitive-columns list.
struct PermissionsPane: View {
    @Environment(AppModel.self) private var app
    let m: AgentsModel
    @State private var sensConn: String?
    @State private var sens: [SensitiveColumn] = []

    private var conn: ConnectionRow? { m.connections.first { $0.id == sensConn } ?? m.connections.first }

    var body: some View {
        HTFrame(title: "PERMISSIONS", tail: "\(m.agents.count) AGENTS × \(m.connections.count) CONNECTIONS") {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            CapsLabel("RULE", "")
                            Text("Agents never write to a database. OVERLAY = their own layer in the DBMan store.").ht(.bodySmall).foregroundStyle(HT.C.ink2)
                            Spacer()
                            Text("ONLY YOU APPLY TO DATABASE").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                        }
                        if m.agents.isEmpty || m.connections.isEmpty {
                            Text(m.agents.isEmpty ? "NO AGENTS YET · CONNECT ONE UNDER PLATFORMS — IT APPEARS HERE AFTER ITS FIRST CALL" : "NO CONNECTIONS YET").ht(.label).foregroundStyle(HT.C.ink3).padding(.vertical, 16)
                        } else { matrix }
                        sensitive
                    }.padding(12)
                }
                HStack {
                    Text("APPLIES TO THE NEXT CALL · AGENTS SEE THEIR LEVEL IN connections.list").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    Spacer()
                    Text("PRODUCTION DEFAULTS TO READ · OVERLAY IS OPT-IN").ht(.labelSmall).foregroundStyle(HT.C.amber)
                }
                .padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
        .task(id: m.connections.map(\.id)) { loadSens() }
    }

    private var matrix: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                CapsLabel("AGENT ↓ · CONNECTION →").foregroundStyle(HT.C.ink3)
                ForEach(m.connections, id: \.id) { c in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) { Text(c.name).ht(.label); Text(c.env.uppercased()).ht(.labelSmall).foregroundStyle(c.env == "production" ? HT.C.amber : HT.C.ink3) }
                        Text(c.env == "production" ? "READ · OVERLAY OPT-IN" : "DEFAULT OVERLAY").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    }
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(m.agents, id: \.id) { a in
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.id).ht(.label)
                        Text(a.version.map { "v\($0)" } ?? "").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    }
                    ForEach(m.connections, id: \.id) { c in cell(a, c) }
                }
            }
        }
    }

    private func cell(_ a: AgentRow, _ c: ConnectionRow) -> some View {
        let p = m.permissions["\(a.id)|\(c.id)"] ?? Permission(level: "off")
        return VStack(alignment: .leading, spacing: 4) {
            HTSegmented(selection: Binding(get: { p.level }, set: { set(a, c, level: $0, p) }),
                        options: [("off", "OFF"), ("read", "READ"), ("overlay", "OVERLAY")])
            HStack(spacing: 4) {
                Text("T").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                limit(p.timeoutMs.map { String($0 / 1000) } ?? "", c.env == "production" ? "5" : "15") { v in set(a, c, level: p.level, p, timeoutMs: v.flatMap(Int.init).map { $0 * 1000 }) }
                Text("S").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                Text("ROWS").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                limit(p.rowCap.map(String.init) ?? "", "500") { v in set(a, c, level: p.level, p, rowCap: v.flatMap(Int.init)) }
            }
        }
    }

    /// Empty field = the default (shown as placeholder).
    private func limit(_ value: String, _ placeholder: String, commit: @escaping (String?) -> Void) -> some View {
        LimitField(value: value, placeholder: placeholder, commit: commit)
    }

    private func set(_ a: AgentRow, _ c: ConnectionRow, level: String, _ old: Permission, timeoutMs: Int?? = nil, rowCap: Int?? = nil) {
        try? app.store.setPermission(agent: a.id, connection: c.id, level: level, timeoutMs: timeoutMs ?? old.timeoutMs, rowCap: rowCap ?? old.rowCap)
        m.reload(app.store)
    }

    // MARK: sensitive columns

    private var sensitive: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CapsLabel("SENSITIVE COLUMNS", "AUTO · \(sens.filter(\.hidden).count) COLUMNS HIDDEN")
                Spacer()
                if m.connections.count > 1 {
                    HTSegmented(selection: Binding(get: { conn?.id ?? "" }, set: { sensConn = $0; loadSens() }), options: m.connections.map { (value: $0.id, title: $0.name.uppercased()) })
                } else if let c = conn { Text(c.name.uppercased()).ht(.labelSmall).foregroundStyle(HT.C.ink3) }
            }
            if sens.isEmpty {
                Text("NONE YET · COLUMNS MATCHING email, phone, ssn, address, name, token, password, iban, dob ARE MARKED ON THE FIRST SCHEMA LOAD").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            }
            ForEach(sens) { s in sensRow(s) }
            Text("Agents get «redacted» (COUNT and other numeric aggregates still work). Unmark per column; redaction happens in DBMan before rows leave the socket.").ht(.bodySmall).foregroundStyle(HT.C.ink3)
        }
    }

    private func sensRow(_ s: SensitiveColumn) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { s.hidden }, set: { v in
                guard let c = conn else { return }
                try? app.store.setSensitive(connection: c.id, table: s.table, column: s.column, hidden: v)
                loadSens()
            })).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            Text("\(s.table).\(s.column)").ht(.dataSmall)
            Text(s.source == "auto" ? "AUTO" : "YOU").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            Spacer()
            Text(s.hidden ? "«redacted»" : "VISIBLE").ht(.dataSmall).foregroundStyle(s.hidden ? HT.C.ink3 : HT.C.amber)
        }
        .padding(.vertical, 2).overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
    }

    private func loadSens() { sens = conn.flatMap { try? app.store.sensitiveColumns(connection: $0.id) } ?? [] }
}

private struct LimitField: View {
    let value: String, placeholder: String
    let commit: (String?) -> Void
    @State private var text = ""
    var body: some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).ht(.dataSmall).multilineTextAlignment(.trailing)
            .frame(width: 40).padding(.horizontal, 4).frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HT.C.line, lineWidth: 1))
            .onAppear { text = value }
            .onSubmit { commit(text.isEmpty ? nil : text) }
            .accessibilityLabel("Limit")
    }
}

// MARK: - activity

struct ActivityPane: View {
    @Environment(AppModel.self) private var app
    let m: AgentsModel
    @State private var client: String?
    @State private var open: Int64?

    private var rows: [ActivityRow] { m.activity.filter { client == nil || $0.agent == client } }

    var body: some View {
        HTFrame(title: "ACTIVITY", tail: "\(m.activity.count) CALLS") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    CapsLabel("CLIENT")
                    HTSegmented(selection: $client, options: [(String?.none, "ALL")] + m.agents.map { (value: String?.some($0.id), title: $0.id.uppercased()) })
                    Spacer()
                    Text("LIVE · REFRESHES ON EVERY CALL").ht(.labelSmall).foregroundStyle(HT.C.accent)
                }.padding(8)
                ActivityFeed(rows: rows, approvals: ApprovalCenter.shared.pending.filter { client == nil || $0.agent == client }, showConnection: true, open: $open)
                HStack(spacing: 14) {
                    ForEach(["ok", "overlay", "blocked", "denied", "error"], id: \.self) { s in
                        let n = rows.filter { $0.status == s }.count
                        Text("\(s.uppercased()) · \(n)").ht(.labelSmall).foregroundStyle(n > 0 && ["blocked", "denied", "error"].contains(s) ? HT.C.alert : HT.C.ink3)
                    }
                    Spacer()
                }
                .padding(8).overlay(alignment: .top) { Rectangle().fill(HT.C.line).frame(height: 1) }
            }
        }
    }
}

/// The feed rows shared by the window and the inspector tab: time · client · tool · args · ms · rows · status; blocked/denied/error in alert.
struct ActivityFeed: View {
    let rows: [ActivityRow]
    var approvals: [ApprovalRow] = [] // pending, pinned above the log
    var showConnection = false
    @Binding var open: Int64?

    var body: some View {
        if rows.isEmpty && approvals.isEmpty {
            Text("NO AGENT CALLS YET").ht(.label).foregroundStyle(HT.C.ink3).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(approvals) { ApprovalCard(a: $0).padding(8) }
                    ForEach(rows) { r in line(r) }
                }
            }
        }
    }

    private func line(_ r: ActivityRow) -> some View {
        let bad = ["blocked", "denied", "error"].contains(r.status)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(r.ts.formatted(date: .omitted, time: .standard)).ht(.dataSmall).foregroundStyle(HT.C.ink3).frame(width: 66, alignment: .leading)
                Text(r.agent ?? "—").ht(.labelSmall).frame(width: 90, alignment: .leading).lineLimit(1)
                if showConnection { Text(r.connection ?? "—").ht(.labelSmall).foregroundStyle(HT.C.ink3).frame(width: 70, alignment: .leading).lineLimit(1) }
                Text(r.tool).ht(.dataSmall).frame(width: 110, alignment: .leading).lineLimit(1)
                Text(r.args).ht(.dataSmall).foregroundStyle(HT.C.ink2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(r.ms.map { "\($0) MS" } ?? "").ht(.dataSmall).foregroundStyle(HT.C.ink3).frame(width: 52, alignment: .trailing)
                Text(r.rows.map { "\($0) ROWS" } ?? "").ht(.dataSmall).foregroundStyle(HT.C.ink3).frame(width: 64, alignment: .trailing)
                Text(r.status.uppercased()).ht(.labelSmall).foregroundStyle(bad ? HT.C.alert : r.status == "overlay" ? HT.C.accent : HT.C.ink)
                    .padding(.horizontal, 4).frame(height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(bad ? HT.C.alert : HT.C.line, lineWidth: 1))
            }
            if open == r.id {
                Text(r.args).ht(.dataSmall).textSelection(.enabled)
                if let e = r.error { Text(e).ht(.bodySmall).foregroundStyle(HT.C.alert) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(bad ? HT.C.alert.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { open = open == r.id ? nil : r.id }
    }
}

// MARK: - workspace

/// Right-inspector wrapper: ROW (the existing inspector) | AGENTS (feed filtered to this connection).
struct AgentsInspector<Row: View>: View {
    let ws: WorkspaceModel
    @ViewBuilder let row: Row
    @State private var tab = ApprovalCenter.shared.pending.isEmpty ? 0 : 1 // something waits for a human: open on it
    @State private var open: Int64?

    var body: some View {
        VStack(spacing: HT.M.seam) {
            // the switcher is the panel's own header strip: same paper, flush, one shared hairline with the panel below
            HStack {
                HTSegmented(selection: $tab, options: [(0, "ROW"), (1, "AGENTS")])
                Spacer()
                if tab == 1 { PauseButton() }
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(HT.C.paper)
            .overlay(Rectangle().strokeBorder(HT.C.line, lineWidth: HT.M.hairline))
            if tab == 0 { row } else {
                let rows = AgentsModel.shared.activity.filter { $0.connectionId == ws.profile.id.uuidString } // shortcut: newest 200 calls overall, page per connection if a busy agent pushes this one out
                let waiting = ApprovalCenter.shared.pending.filter { $0.connection == nil || $0.connection == ws.profile.id.uuidString }
                HTFrame(title: "Agents", tail: "\(rows.count) CALLS") { ActivityFeed(rows: rows, approvals: waiting, open: $open) }
            }
        }
    }
}

/// Toolbar chip: AGENTS // N LIVE, opens the Agents window.
struct AgentsChip: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let n = MCPHost.shared.live.count
        Button { openWindow(id: "agents") } label: {
            HStack(spacing: 5) { Text("Agents"); HTDivider(); Text("\(n) live").foregroundStyle(n > 0 ? HT.C.accent : HT.C.ink3) }
                .ht(.labelSmall).padding(.horizontal, 8).frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(n > 0 ? HT.C.accent : HT.C.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Agents, \(n) live")
    }
}
