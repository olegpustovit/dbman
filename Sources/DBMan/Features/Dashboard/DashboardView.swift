import DBCore
import DBManMCP
import Halftone
import SwiftUI

/// A dashboard route: header with variables, the 12-column grid (view, edit with library + inspector, or proposal review), status strip.
struct DashboardView: View {
    let ws: WorkspaceModel
    let id: String?
    private var m: DashboardModel { ws.dash }
    static let row: CGFloat = 72

    var body: some View {
        VStack(spacing: HT.M.gap) {
            if let spec = m.spec {
                if m.isProposal { ProposalHeader(ws: ws, spec: spec) } else { header(spec) }
                HStack(spacing: HT.M.gap) {
                    if m.edit { Library(ws: ws).frame(width: 210) }
                    if spec.widgets.isEmpty && !m.isProposal && !m.edit { EmptyDashboard(ws: ws) } else { VStack(spacing: HT.M.gap) { DashGridView(ws: ws, spec: spec); if m.isProposal { ProposalSQL(ws: ws) } } }
                    if m.edit { Inspector(ws: ws, spec: spec).frame(width: 300) }
                }
                strip(spec)
            } else {
                StateFrame(title: "Dashboard", tail: nil, message: "NO_DASHBOARD // OPEN ONE FROM THE NAVIGATOR")
            }
        }
        .task(id: id) { await m.open(id, ws) }
        .task(id: m.spec?.refresh) { // auto-refresh; ends when the view goes away
            while let s = m.spec?.refreshSeconds, !Task.isCancelled { try? await Task.sleep(for: .seconds(s)); if !Task.isCancelled && !m.edit { await m.refresh(ws) } }
        }
        .task(id: m.notice) { if m.notice != nil { try? await Task.sleep(for: .seconds(5)); m.notice = nil } }
    }

    // MARK: header

    private func header(_ spec: DashboardSpec) -> some View {
        let e = m.entry
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if m.edit {
                    TextField("Title", text: Binding(get: { spec.title }, set: { m.spec?.title = $0 })).textFieldStyle(.plain).ht(.strong).frame(maxWidth: 320)
                        .htInput()
                } else { Text(spec.title).ht(.strong) }
                Text("// \(ws.profile.name) · \(spec.widgets.count) widgets · layer \((e?.layer ?? "mine").lowercased()) · dbman store").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                Spacer(minLength: 4)
                if let n = m.notice { Text(n).ht(.labelSmall).foregroundStyle(HT.C.accent).lineLimit(1) }
                Button(m.edit ? "DONE // ⌘E" : "EDIT // ⌘E") { m.toggleEdit() }.buttonStyle(m.edit ? .htPrimary : .htOutline)
                Menu("SHARE / EXPORT JSON") {
                    Button("EXPORT JSON…") { m.exportJSON() }
                    Button("IMPORT JSON…") { m.importJSON(ws) }
                    Button("DUPLICATE") { m.duplicate(ws) }
                    Divider()
                    Button("NEW DASHBOARD") { m.create(ws) }
                    Button("DELETE DASHBOARD", role: .destructive) { m.delete(ws) }.disabled(e?.id == m.defaultEntry?.id)
                }.menuStyle(.button).buttonStyle(.htOutline).fixedSize()
            }
            HStack(spacing: 8) {
                ForEach(Array(spec.variables.enumerated()), id: \.offset) { _, v in variable(v) }
                if !spec.variables.isEmpty { Rectangle().fill(HT.C.line).frame(width: 1, height: 14) }
                CapsLabel("refresh", nil).foregroundStyle(HT.C.ink3)
                Menu(spec.refresh == "off" ? "OFF" : spec.refresh.uppercased()) {
                    ForEach(DashboardSpec.refreshes, id: \.self) { r in Button(Self.refreshLabel(r)) { m.setRefresh(r) } }
                }.menuStyle(.button).buttonStyle(.htOutline).fixedSize().accessibilityLabel("Auto-refresh")
                Spacer(minLength: 4)
                if let at = m.updated {
                    let times: [Double] = m.data.values.compactMap { if case .ready(let t, _) = $0 { t.ms } else { nil } }
                    let ms = times.reduce(0, +)
                    Text("updated // \(at.formatted(date: .omitted, time: .standard)) · \(Int(ms)) ms · \(m.data.count) queries").ht(.labelSmall).foregroundStyle(HT.C.ink3)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(HT.C.paper, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
    }

    @ViewBuilder private func variable(_ v: DashVariable) -> some View {
        CapsLabel(v.name, nil).foregroundStyle(HT.C.ink3)
        if v.type == "timeRange" {
            let hours = { (r: String) -> Int in DashSQL.range(r).map { $0.n * ($0.unit == "h" ? 1 : $0.unit == "d" ? 24 : 168) } ?? 0 }
            let opts = Array(Set(["1h", "24h", "7d", "30d", "90d", v.default ?? "30d"])).sorted { hours($0) < hours($1) }
            HTSegmented(selection: Binding(get: { m.values[v.name] ?? v.default ?? "30d" }, set: { m.setValue(v.name, $0, ws) }), options: opts.map { ($0, $0) })
        } else {
            Menu((m.values[v.name] ?? "all").uppercased()) {
                ForEach(m.options[v.name] ?? ["all"], id: \.self) { o in Button(o) { m.setValue(v.name, o, ws) } }
            }.menuStyle(.button).buttonStyle(.htOutline).fixedSize().accessibilityLabel("\(v.name) filter")
        }
    }

    private static func refreshLabel(_ r: String) -> String { r == "off" ? "OFF" : "\(r.dropLast()) \(r.suffix(1))".uppercased() }

    private func strip(_ spec: DashboardSpec) -> some View {
        HStack(spacing: 14) {
            Text("12 COLS · \(spec.widgets.count) WIDGETS").ht(.labelSmall)
            Text(m.edit ? "EDIT // DRAG TO MOVE, CORNER TO RESIZE, SNAPS TO THE GRID" : m.isProposal ? "PROPOSAL // NOTHING IS IN MINE UNTIL YOU ADOPT" : "VIEW // ⌘E EDITS THE LAYOUT").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            Spacer()
            Text("AUTO_REFRESH // \(spec.refresh == "off" ? "OFF" : spec.refresh.uppercased())").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            Text("STORE // LAYER \((m.entry?.layer ?? "MINE").uppercased())").ht(.labelSmall).foregroundStyle(HT.C.ink3)
        }.frame(height: 16).lineLimit(1)
    }
}

// MARK: - the grid

/// Widgets on the 12-column grid. Edit mode adds the dot grid, drag to move, a corner handle to resize and drops from the library.
struct DashGridView: View {
    let ws: WorkspaceModel, spec: DashboardSpec
    @State private var drag: (id: String, dx: CGFloat, dy: CGFloat, resize: Bool)?
    private var m: DashboardModel { ws.dash }
    private let gap = HT.M.gap, row = DashboardView.row

    var body: some View {
        GeometryReader { geo in
            let cw = (geo.size.width - 11 * gap) / 12, rows = max((spec.widgets.map { $0.y + $0.h }.max() ?? 0) + (m.edit ? 2 : 0), 1)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    if m.edit { DotGrid().frame(height: CGFloat(rows) * (row + gap)) }
                    ForEach(spec.widgets) { w in
                        let r = rect(w, cw), d = drag?.id == w.id ? drag : nil
                        card(w)
                            .frame(width: max(r.width + (d?.resize == true ? d!.dx : 0), 40), height: max(r.height + (d?.resize == true ? d!.dy : 0), 40))
                            .overlay { chrome(w, cw) }
                            .offset(x: r.minX + (d?.resize == false ? d!.dx : 0), y: r.minY + (d?.resize == false ? d!.dy : 0))
                            .zIndex(d != nil ? 2 : m.selected == w.id ? 1 : 0)
                            .opacity(d != nil ? 0.9 : 1)
                    }
                    if let d = drag, let w = m.widget(d.id) { // where it will land
                        let t = target(w, d, cw), r = rect(DashWidget(id: "", type: w.type, title: "", x: t.x, y: t.y, w: t.w, h: t.h), cw)
                        RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: CGFloat(rows) * (row + gap), alignment: .topLeading)
                .dropDestination(for: String.self) { types, p in
                    guard m.edit, let t = types.first, DashCatalog.type(t) != nil else { return false }
                    m.add(t, at: (DashGrid.snap(p.x, cell: cw, gap: gap), DashGrid.snap(p.y, cell: row, gap: gap)), ws); return true
                }
            }
        }
    }

    private func rect(_ w: DashWidget, _ cw: CGFloat) -> CGRect {
        CGRect(x: CGFloat(w.x) * (cw + gap), y: CGFloat(w.y) * (row + gap), width: CGFloat(w.w) * cw + CGFloat(w.w - 1) * gap, height: CGFloat(w.h) * row + CGFloat(w.h - 1) * gap)
    }

    /// Snapped cell for a drag in progress: nearest cell for a move, nearest whole cells for a resize.
    private func target(_ w: DashWidget, _ d: (id: String, dx: CGFloat, dy: CGFloat, resize: Bool), _ cw: CGFloat) -> (x: Int, y: Int, w: Int, h: Int) {
        let r = rect(w, cw)
        if d.resize { return (w.x, w.y, Int(((r.width + d.dx + gap) / (cw + gap)).rounded()), Int(((r.height + d.dy + gap) / (row + gap)).rounded())) }
        return (DashGrid.snap(r.minX + d.dx + (cw + gap) / 2, cell: cw, gap: gap), DashGrid.snap(r.minY + d.dy + (row + gap) / 2, cell: row, gap: gap), w.w, w.h)
    }

    @ViewBuilder private func card(_ w: DashWidget) -> some View {
        if m.isProposal {
            let failed = m.failed(w.id), on = m.accepted.contains(w.id) && !failed
            WidgetCard(ws: ws, w: w,
                       lead: AnyView(Button { if on { m.accepted.remove(w.id) } else { m.accepted.insert(w.id) } } label: {
                           Text(on ? "✓" : "").ht(.labelSmall).foregroundStyle(HT.C.paper).frame(width: 14, height: 14)
                               .background(on ? HT.C.accent : .clear, in: RoundedRectangle(cornerRadius: 2))
                               .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(failed ? HT.C.line : HT.C.accent, lineWidth: 1.5))
                       }.buttonStyle(.plain).disabled(failed).accessibilityLabel("Accept \(w.title)").accessibilityValue(on ? "accepted" : "not accepted")),
                       trail: AnyView(cost(w, failed)))
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(failed ? HT.C.alert : m.selected == w.id ? HT.C.accent : HT.C.line, style: StrokeStyle(lineWidth: failed || m.selected == w.id ? 1.5 : 1, dash: failed ? [] : [4, 3])))
                .contentShape(Rectangle()).onTapGesture { m.selected = w.id }
        } else {
            WidgetCard(ws: ws, w: w)
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(m.edit && m.selected == w.id ? HT.C.accent : m.edit ? HT.C.accent.opacity(0.5) : HT.C.line, lineWidth: m.edit && m.selected == w.id ? 1.5 : 1))
        }
    }

    @ViewBuilder private func cost(_ w: DashWidget, _ failed: Bool) -> some View {
        if failed { Text("ALERT").ht(.labelSmall).foregroundStyle(HT.C.alert) }
        else if let c = m.costs[w.id] { Text("COST \(c)").ht(.labelSmall).foregroundStyle(HT.C.ink2).padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HT.C.line, lineWidth: 1)) }
    }

    /// Edit mode: the card is a drag handle, with a resize handle in its corner and a size badge while selected.
    @ViewBuilder private func chrome(_ w: DashWidget, _ cw: CGFloat) -> some View {
        if m.edit {
            ZStack(alignment: .bottomTrailing) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { m.selected = w.id }
                    .gesture(DragGesture(minimumDistance: 4).onChanged { drag = (w.id, $0.translation.width, $0.translation.height, false); m.selected = w.id }
                        .onEnded { commit(w, $0.translation, resize: false, cw) })
                if m.selected == w.id { Text("w\(w.w) · h\(w.h)").ht(.labelSmall).foregroundStyle(HT.C.accent).padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).allowsHitTesting(false) }
                Image(systemName: "arrow.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(HT.C.accent).frame(width: 18, height: 18)
                    .background(HT.C.paper).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { drag = (w.id, $0.translation.width, $0.translation.height, true) }.onEnded { commit(w, $0.translation, resize: true, cw) })
                    .accessibilityLabel("Resize \(w.title)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Move down") { m.place(w.id, x: w.x, y: w.y + 1, w: w.w, h: w.h) }
            .accessibilityAction(named: "Move up") { m.place(w.id, x: w.x, y: w.y - 1, w: w.w, h: w.h) }
            .accessibilityAction(named: "Move right") { m.place(w.id, x: w.x + 1, y: w.y, w: w.w, h: w.h) }
            .accessibilityAction(named: "Move left") { m.place(w.id, x: w.x - 1, y: w.y, w: w.w, h: w.h) }
        }
    }

    private func commit(_ w: DashWidget, _ t: CGSize, resize: Bool, _ cw: CGFloat) {
        let to = target(w, (w.id, t.width, t.height, resize), cw)
        drag = nil
        m.place(w.id, x: to.x, y: to.y, w: to.w, h: to.h)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for x in stride(from: CGFloat(0), to: size.width, by: 8) { for y in stride(from: CGFloat(0), to: size.height, by: 8) { p.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2)) } }
            ctx.fill(p, with: .color(HT.C.fill30))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// MARK: - library drawer

private struct Library: View {
    let ws: WorkspaceModel
    @State private var filter = ""
    private var m: DashboardModel { ws.dash }
    static let icons = ["kpi": "number", "kpi.spark": "chart.line.uptrend.xyaxis", "meter": "gauge", "line": "chart.xyaxis.line", "area.stacked": "chart.line.flattrend.xyaxis", "heatmap.hour_week": "square.grid.3x3",
                        "heatmap.calendar": "calendar", "bars": "chart.bar", "bars.stacked": "chart.bar.fill", "bars.horizontal": "list.number", "radar": "hexagon", "funnel": "line.3.horizontal.decrease",
                        "histogram": "chart.bar.xaxis", "halftone.distribution": "circle.grid.3x3", "scatter": "chart.dots.scatter", "table": "tablecells", "status.feed": "list.bullet",
                        "er.mini": "point.3.connected.trianglepath.dotted", "text": "text.alignleft"]

    var body: some View {
        HTFrame(title: "Component library", tail: "19", accessory: { EmptyView() }) {
            VStack(spacing: 8) {
                HTSearchField(text: $filter, prompt: "Search components")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(DashCatalog.groups, id: \.self) { g in
                            let items = DashCatalog.types.filter { $0.group == g && (filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter)) }
                            if !items.isEmpty {
                                CapsLabel(g, String(format: "%02d", items.count)).foregroundStyle(HT.C.ink3).padding(.top, 8).padding(.bottom, 2)
                                ForEach(items, id: \.id) { t in
                                    let used = m.spec?.widgets.filter { $0.type == t.id }.count ?? 0
                                    HStack(spacing: 8) {
                                        Image(systemName: Self.icons[t.id] ?? "square").frame(width: 24, height: 18).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HT.C.line, lineWidth: 1))
                                            .foregroundStyle(used > 0 ? HT.C.accent : HT.C.ink)
                                        Text(t.id).ht(.dataSmall).lineLimit(1)
                                        Spacer(minLength: 2)
                                        if used > 0 { Text("×\(used)").ht(.dataSmall).foregroundStyle(HT.C.accent) }
                                    }
                                    .frame(height: 26).contentShape(Rectangle())
                                    .onTapGesture { m.add(t.id, ws) }
                                    .draggable(t.id)
                                    .help("\(t.id) · min \(t.minW)×\(t.minH) · \(t.good)")
                                    .accessibilityElement(children: .ignore).accessibilityLabel("Add \(t.id)").accessibilityHint(t.good).accessibilityAddTraits(.isButton)
                                }
                            }
                        }
                    }
                }
                Button("+ GENERATE WITH AGENT") { m.copyBuildPrompt(ws, goal: "", agent: nil) }.buttonStyle(.htPrimary).frame(maxWidth: .infinity)
                Text("Drag onto the grid, or click to drop at the next free row.").ht(.bodySmall).foregroundStyle(HT.C.ink3)
            }.padding(8)
        }
    }
}

// MARK: - empty state

private struct EmptyDashboard: View {
    let ws: WorkspaceModel
    @State private var goal = ""
    private var m: DashboardModel { ws.dash }

    var body: some View {
        HTFrame(title: "New dashboard", tail: "Empty") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("00").font(.system(size: 64, weight: .light)).monospacedDigit().tracking(-2.5)
                    CapsLabel("No widgets yet", nil)
                    Text("A dashboard is a 12-column grid of widgets. Every widget keeps its SQL inspectable, and nothing an agent builds reaches MINE until you adopt it.").ht(.bodySmall).foregroundStyle(HT.C.ink2).frame(maxWidth: 260, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    CapsLabel("01 // Generate with agent", "⌥⌘G").foregroundStyle(HT.C.ink3)
                    TextField("What should it show? e.g. Sales health: revenue, orders, top products", text: $goal).textFieldStyle(.plain).ht(.bodySmall).htInput(stroke: HT.C.accent, weight: 1.5).frame(width: 360)
                    HStack(spacing: 8) {
                        let live = MCPHost.shared.live
                        if live.isEmpty { Button("GENERATE WITH AGENT") { m.copyBuildPrompt(ws, goal: goal, agent: nil) }.buttonStyle(.htPrimary) }
                        else {
                            Menu("GENERATE WITH AGENT") { ForEach(live, id: \.name) { a in Button("\(a.name) // \(a.version)") { m.copyBuildPrompt(ws, goal: goal, agent: a.name) } } }.menuStyle(.button).buttonStyle(.htPrimary).fixedSize()
                            Button("COPY PROMPT") { m.copyBuildPrompt(ws, goal: goal, agent: nil) }.buttonStyle(.htOutline)
                        }
                    }
                    Text(liveNote(MCPHost.shared.live.count)).ht(.labelSmall).foregroundStyle(HT.C.ink3)
                    Text("The prompt is copied; paste it into the agent. The result arrives here as a proposal in its layer.").ht(.bodySmall).foregroundStyle(HT.C.ink3).frame(maxWidth: 360, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    CapsLabel("02 // Start from template", nil).foregroundStyle(HT.C.ink3).padding(.bottom, 4)
                    ForEach(Array(DefaultDashboard.templates.enumerated()), id: \.offset) { i, t in
                        Button { Task { await m.useTemplate(i, ws) } } label: {
                            HStack(spacing: 8) {
                                Canvas { c, _ in for r in t.thumb { c.fill(Path(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])), with: .color(HT.C.ink.opacity(0.55))) } }
                                    .frame(width: 34, height: 24).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HT.C.line, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.name).ht(.strong).lineLimit(1)
                                    Text(t.blurb).ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text("\(t.ids?.count ?? 9) w").ht(.dataSmall).foregroundStyle(HT.C.ink3)
                            }.frame(width: 250, height: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).overlay(alignment: .bottom) { Rectangle().fill(HT.C.line).frame(height: 1) }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    CapsLabel("03 // Add widget", "⌘L").foregroundStyle(HT.C.ink3)
                    Text("19 types in 7 groups. Open the library and drag one onto the grid.").ht(.bodySmall).foregroundStyle(HT.C.ink2).frame(maxWidth: 220, alignment: .leading)
                    Button("+ ADD WIDGET") { m.edit = true }.buttonStyle(.htOutline)
                    Button("IMPORT JSON…") { m.importJSON(ws) }.buttonStyle(.htOutline)
                }
            }.padding(20)
        }
    }
    private func liveNote(_ n: Int) -> String { n == 0 ? "NO AGENT CONNECTED // COPY THE PROMPT INTO ANY AGENT WITH DBMAN MCP" : "\(n) AGENT\(n == 1 ? "" : "S") CONNECTED" }
}

// MARK: - proposal review (F5, G18)

private struct ProposalHeader: View {
    let ws: WorkspaceModel, spec: DashboardSpec
    @State private var asking = false
    @State private var note = ""
    private var m: DashboardModel { ws.dash }

    var body: some View {
        let bad = spec.widgets.filter { m.failed($0.id) }.count, n = spec.widgets.filter { m.accepted.contains($0.id) && !m.failed($0.id) }.count
        let total = m.costs.values.compactMap { Double($0) }.reduce(0, +)
        HStack(spacing: 10) {
            Text(layerMono(m.entry?.layer ?? "")).ht(.labelSmall).frame(width: 26, height: 20).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HT.C.accent, lineWidth: 1)).foregroundStyle(HT.C.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(m.entry?.layer ?? "agent") proposes \(spec.title)").ht(.strong).lineLimit(1)
                Text("\(spec.widgets.count) widgets // every query ran read-only // lives in \(m.entry?.layer ?? "its") layer until adopted").ht(.labelSmall).foregroundStyle(HT.C.ink3).lineLimit(1)
            }
            Spacer(minLength: 4)
            chip("\(spec.widgets.count - bad) VALID"); if bad > 0 { chip("\(bad) ALERT", HT.C.alert) }
            if total > 0 { chip("TOTAL COST // \(total < 1000 ? String(Int(total)) : String(format: "%.1e", total).replacingOccurrences(of: "e+0", with: "e").replacingOccurrences(of: "e+", with: "e"))") }
            if let n = m.notice { Text(n).ht(.labelSmall).foregroundStyle(HT.C.accent) }
            Button("ASK FOR CHANGES") { asking = true }.buttonStyle(.htOutline)
                .popover(isPresented: $asking) {
                    VStack(alignment: .leading, spacing: 8) {
                        CapsLabel("Ask for changes", nil)
                        TextField("What should change?", text: $note, axis: .vertical).textFieldStyle(.plain).ht(.bodySmall).htInput().frame(width: 280)
                        Text("The agent reads this in overlay.status. This proposal is discarded.").ht(.bodySmall).foregroundStyle(HT.C.ink3).frame(width: 280, alignment: .leading)
                        HStack { Spacer(); Button("SEND") { asking = false; m.askForChanges(note, ws) }.buttonStyle(.htPrimary).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty) }
                    }.padding(12)
                }
            Button("ADOPT \(n) OF \(spec.widgets.count) INTO MINE") { m.adopt(ws) }.buttonStyle(.htPrimary).disabled(n == 0).keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(HT.C.paper, in: RoundedRectangle(cornerRadius: HT.M.radius))
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.accent, lineWidth: 1))
    }
    private func chip(_ s: String, _ c: Color = HT.C.ink) -> some View {
        Text(s).ht(.labelSmall).foregroundStyle(c).padding(.horizontal, 6).frame(height: 18).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(c, lineWidth: 1))
    }
}

/// The selected widget's SQL and cost, under the ghost preview.
private struct ProposalSQL: View {
    let ws: WorkspaceModel
    var body: some View {
        let m = ws.dash, w = m.widget(m.selected) ?? m.spec?.widgets.first
        HTFrame(title: w.map { "\($0.id) // \($0.title)" } ?? "SQL", tail: w.map { "\($0.type) · sql" }) {
            HStack(alignment: .top, spacing: 10) {
                ScrollView { Text(w?.query ?? "no query").ht(.dataSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                if let w {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.costs[w.id].map { "EXPLAIN COST \($0)" } ?? "NO COST").ht(.labelSmall)
                        if case .ready(let t, _)? = m.data[w.id] { Text("\(t.rows.count) ROWS // \(Int(t.ms)) MS").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
                        if case .failed(let e)? = m.data[w.id] { Text(e).ht(.dataSmall).foregroundStyle(HT.C.alert) }
                    }.padding(8).frame(width: 220, alignment: .leading)
                }
            }
        }.frame(height: 120)
    }
}

extension DashboardModel {
    func failed(_ id: String) -> Bool { if case .failed? = data[id] { true } else { false } }
}
