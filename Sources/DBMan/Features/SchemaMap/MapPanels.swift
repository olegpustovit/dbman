import AppKit
import DBCore
import Halftone
import SwiftUI
import UniformTypeIdentifiers

// MARK: - inspector

struct MapInspector: View {
    let ws: WorkspaceModel
    let map: SchemaMapState

    var body: some View {
        HTFrame(title: map.selection == nil ? "Schema" : "Table", tail: map.selection == nil ? "\(ws.profile.name) · nothing selected" : "⌥⌘I") {
            if let name = map.selection, let t = map.scene.graph.table(name) ?? map.full?.table(name) { detail(t) } else { overview }
        }
    }

    private var overview: some View {
        let g = map.scene.graph
        return VStack(alignment: .leading, spacing: 10) {
            Readout(value: "\(g.tables.count)", label: "tables", tail: "\(HTFormat.compact(g.tables.reduce(0) { $0 + $1.rowCount })) rows", size: .xl)
            Text("\(g.edges.filter { $0.kind == .declared && !$0.manyToMany }.count) declared fk · \(g.edges.filter { $0.kind == .inferred }.count) inferred · \(g.isolated.count) isolated")
                .ht(.labelSmall).foregroundStyle(HT.C.ink3)
            Text("Click a card to inspect its columns, keys and indexes. Arrow keys walk the selection along edges; Space focuses it; P picks a join path.")
                .ht(.bodySmall).foregroundStyle(HT.C.ink2)
            Spacer(minLength: 0)
        }.padding(10)
    }

    private func detail(_ t: TableInfo) -> some View {
        let g = map.scene.graph
        let rels = g.edges.filter { !$0.manyToMany && $0.from != $0.to && ($0.from == t.name || $0.to == t.name) }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.name).ht(.readoutM).lineLimit(1).minimumScaleFactor(0.5)
                        Spacer(minLength: 0)
                        Button { map.selection = nil } label: { Text("✕") }.buttonStyle(.htOutline).help("Clear selection  Esc")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Readout(value: HTFormat.grouped(t.rowCount), label: "rows", tail: ws.profile.engine == .sqlite ? "exact" : "estimate", size: .s)
                        SegmentedMeter(value: log10(Double(max(t.rowCount, 1))) / 7, segments: 40, accessibilityLabel: "Row count, log scale").frame(height: 6)
                        HStack { ForEach(["10", "1K", "100K", "10M"], id: \.self) { Text($0); if $0 != "10M" { Spacer() } } }.font(.system(size: 10, design: .monospaced)).foregroundStyle(HT.C.ink3)
                    }
                    .padding(8).overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
                    section("columns", t.columns.count)
                    ForEach(t.columns) { c in
                        HStack(spacing: 6) {
                            Image(systemName: c.isPrimaryKey ? "key" : "arrow.right").font(.system(size: 8.5, weight: .semibold)).frame(width: 12)
                                .opacity(c.isPrimaryKey || c.foreignKey != nil ? 1 : 0)
                            Text(c.name).ht(.dataSmall).fontWeight(c.isPrimaryKey ? .bold : .regular).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(c.type.lowercased()).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(HT.C.ink3)
                        }.frame(height: 21)
                        Divider()
                    }
                    section("relations", rels.count)
                    ForEach(rels, id: \.self) { e in relation(e, of: t.name) }
                    ForEach(map.inferredFor, id: \.self) { e in inferred(e) }
                    section("indexes", t.indexes.count)
                    ForEach(t.indexes) { i in
                        HStack { Text(i.name).ht(.dataSmall).lineLimit(1); Spacer(minLength: 8); Text(i.unique ? "unique" : "").ht(.labelSmall).foregroundStyle(HT.C.ink3) }.frame(height: 21)
                        Divider()
                    }
                }.padding(10)
            }
            HStack(spacing: 4) {
                Button("Open table ⏎") { ws.go(.table(t.name)) }.buttonStyle(.htPrimary)
                Button("Focus ⎵") { map.focus(t.name) }.buttonStyle(.htOutline)
                Button("New query") { ws.newQuery(sql: "SELECT * FROM \(quoteIdent(t.name, ws.profile.engine)) LIMIT 100;") }.buttonStyle(.htOutline)
            }.padding(8).overlay(alignment: .top) { Divider() }
        }
    }

    private func section(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 6) { CapsLabel(title, "\(n)").foregroundStyle(HT.C.ink3); Rectangle().fill(HT.C.line).frame(height: 1) }.padding(.top, 4)
    }

    private func relation(_ e: MapEdge, of t: String) -> some View {
        let child = e.from == t, other = child ? e.to : e.from
        return HStack(spacing: 6) {
            Text(child ? "→" : "←").foregroundStyle(HT.C.ink3).frame(width: 14)
            Text(child ? e.fromColumn : e.toColumn).ht(.dataSmall).lineLimit(1)
            Button(other) { map.selection = other }.buttonStyle(.plain).ht(.dataSmall).foregroundStyle(HT.C.accent).lineLimit(1)
            Spacer(minLength: 0)
            Text((e.kind == .declared ? "" : e.kind.rawValue + " ") + (child ? "n:1" : "1:n")).ht(.labelSmall).foregroundStyle(e.kind == .inferred ? HT.C.accent : HT.C.ink3)
        }.frame(height: 21)
    }

    private func inferred(_ e: MapEdge) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("inferred · \(e.from).\(e.fromColumn) → \(e.to).\(e.toColumn)").ht(.labelSmall).foregroundStyle(HT.C.accent)
            Text("name   \(e.fromColumn) ~ \(e.to).\(e.toColumn)   ✓\ntype   \(map.full?.table(e.from)?.columns.first { $0.name == e.fromColumn }?.type.lowercased() ?? "") compatible   ✓")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(HT.C.ink2)
            Button("Accept as relation") { map.accept(e) }.buttonStyle(.htOutline).foregroundStyle(HT.C.accent)
                .help("Stores a virtual relation in your layer (MINE). Never DDL.")
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }
}

// MARK: - path drawer

struct PathDrawer: View {
    let ws: WorkspaceModel
    let map: SchemaMapState
    let path: JoinPath?
    @State private var copied = false

    var body: some View {
        let sql = path.flatMap { map.full?.joinSQL($0, engine: ws.profile.engine) } ?? ""
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("path", path.map { "\($0.joins) joins · shortest" } ?? "none").foregroundStyle(HT.C.ink3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array((path?.tables ?? map.pathPicks).enumerated()), id: \.offset) { i, t in
                            Button { map.selection = t } label: {
                                HStack(spacing: 8) {
                                    Text(String(format: "%02d", i + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(HT.C.paper)
                                        .frame(width: 20, height: 16).background(HT.C.accent, in: RoundedRectangle(cornerRadius: 2))
                                    Text(t).ht(.dataSmall).fontWeight(i == 0 || i == (path?.tables.count ?? 0) - 1 ? .bold : .regular)
                                    Rectangle().fill(HT.C.line).frame(height: 1)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(10).frame(width: 236, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("join sql", "\(ws.profile.engine.rawValue) · aliases from table initials").foregroundStyle(HT.C.ink3)
                ScrollView {
                    Text(path == nil ? "No path over declared or accepted relations between \(map.pathPicks.joined(separator: " and ")).\nAccept an inferred relation to bridge them." : sql)
                        .ht(.dataSmall).foregroundStyle(path == nil ? HT.C.ink3 : HT.C.ink2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                }
                .background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1))
            }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack { CapsLabel("from → to").foregroundStyle(HT.C.ink3); Spacer(); Button("✕") { map.pathMode = false }.buttonStyle(.htOutline).help("Close path  Esc") }
                Text(map.pathPicks.joined(separator: " → ")).ht(.strong).lineLimit(2)
                Spacer(minLength: 0)
                Button(copied ? "Copied ✓ \(sql.split(separator: "\n").count) lines" : "Copy join SQL ⌘C") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sql, forType: .string); copied = true
                }.buttonStyle(.htOutline).disabled(path == nil).keyboardShortcut("c")
                Button("Open as query ⌘⏎") { ws.newQuery(sql: sql) }.buttonStyle(.htPrimary).disabled(path == nil).keyboardShortcut(.return)
            }.padding(10).frame(width: 168, alignment: .topLeading)
        }
        .background(HT.C.paper)
        .overlay(alignment: .top) { Rectangle().fill(HT.C.ink).frame(height: 1) }
        .onChange(of: map.pathPicks) { copied = false }
    }
}

// MARK: - export + explain popovers

private struct PopoverChrome<C: View>: View {
    let width: CGFloat
    @ViewBuilder let content: C
    var body: some View {
        content.frame(width: width)
            .background(HT.C.paper)
            .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.ink, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: HT.M.radius).fill(HT.C.fill12).offset(x: 6, y: 6))
    }
}

struct ExportPopover: View {
    let ws: WorkspaceModel
    let map: SchemaMapState

    private static let notes: [MapExport: String] = [.png: "2× · retina", .svg: "vector · live text", .mermaid: "erDiagram · copy", .dbml: "dbdiagram.io"]

    var body: some View {
        @Bindable var map = map
        let text = map.exportText(map.exportFormat)
        PopoverChrome(width: 300) {
            VStack(alignment: .leading, spacing: 0) {
                CapsLabel("export", "\(map.kind.rawValue) · \(map.scene.graph.tables.count) tables").padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                ForEach(MapExport.allCases, id: \.self) { f in
                    let on = f == map.exportFormat
                    Button { map.exportFormat = f } label: {
                        HStack(spacing: 8) {
                            Text(f.rawValue).ht(.labelSmall).frame(width: 62, alignment: .leading)
                            Text(Self.notes[f] ?? "").ht(.bodySmall).opacity(on ? 0.75 : 1)
                            Spacer()
                        }
                        .foregroundStyle(on ? HT.C.paper : HT.C.ink).padding(.horizontal, 10).frame(height: 26)
                        .background(on ? HT.C.ink : .clear).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
                Text(map.exportFormat == .png ? "\(Int(map.scene.layout.bounds(map.scene.sizes).width + 40)) × \(Int(map.scene.layout.bounds(map.scene.sizes).height + 40)) pt → 2×\n\(map.scene.graph.tables.count) tables" : text.split(separator: "\n").prefix(5).joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(HT.C.ink2).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(HT.C.sunken, in: RoundedRectangle(cornerRadius: HT.M.radius))
                    .overlay(RoundedRectangle(cornerRadius: HT.M.radius).strokeBorder(HT.C.line, lineWidth: 1)).padding(.horizontal, 10).padding(.top, 6)
                HStack(spacing: 4) {
                    Spacer()
                    Button("Copy") { copy() }.buttonStyle(.htOutline)
                    Button("Save… ⌘S") { save() }.buttonStyle(.htPrimary).keyboardShortcut("s")
                }.padding(10)
            }
        }
    }

    private func png() -> Data? {
        let b = map.scene.layout.bounds(map.scene.sizes), size = CGSize(width: b.maxX + 20, height: b.maxY + 20)
        let r = ImageRenderer(content: MapWorld(scene: map.scene, style: MapStyle(), viewport: MapViewport(zoom: 1, origin: .zero)).frame(width: size.width, height: size.height, alignment: .topLeading).background(HT.C.paper))
        r.scale = 2
        guard let tiff = r.nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if map.exportFormat == .png { if let d = png() { pb.setData(d, forType: .png) } } else { pb.setString(map.exportText(map.exportFormat), forType: .string) }
        map.exportOpen = false
    }

    private func save() {
        let f = map.exportFormat, ext = f == .mermaid ? "mmd" : f.rawValue.lowercased()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ws.profile.name)-schema.\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext)].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if f == .png { try png()?.write(to: url) } else { try map.exportText(f).write(to: url, atomically: true, encoding: .utf8) }
            map.exportOpen = false
        } catch { map.notice = error.localizedDescription }
    }
}

struct AgentPopover: View {
    let ws: WorkspaceModel
    let map: SchemaMapState
    @State private var copied = false

    var body: some View {
        let g = map.full ?? map.scene.graph
        PopoverChrome(width: 340) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { CapsLabel("explain this schema"); Spacer(); Text("mcp · dbman").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
                Text("Copies a prompt for your agent: \(g.tables.count) tables, \(g.edges.filter { !$0.manyToMany }.count) relations incl. \(g.edges.filter { $0.kind == .inferred }.count) inferred. It names the schema.graph tool; no row data is included.")
                    .ht(.bodySmall).foregroundStyle(HT.C.ink2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(copied ? "copied · paste it into your agent" : "agents never see row data").ht(.labelSmall).foregroundStyle(copied ? HT.C.accent : HT.C.ink3)
                    Spacer()
                    Button("Close") { map.agentOpen = false }.buttonStyle(.htOutline)
                    Button("Copy prompt") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SchemaExport.agentPrompt(g, connection: ws.profile.name), forType: .string); copied = true
                    }.buttonStyle(.htPrimary)
                }
            }.padding(10)
        }
    }
}
