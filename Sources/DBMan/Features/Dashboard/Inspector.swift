import DBCore
import Halftone
import SwiftUI

/// Edit-mode inspector: the selected widget (data, encoding, format, thresholds, size) or, with none selected, the dashboard's variables and refresh.
struct Inspector: View {
    let ws: WorkspaceModel, spec: DashboardSpec
    private var m: DashboardModel { ws.dash }

    var body: some View {
        HTFrame(title: m.widget(m.selected).map { "\($0.id) // \($0.type)" } ?? "Dashboard", tail: m.widget(m.selected) == nil ? "Variables" : nil, accessory: {
            if m.selected != nil { Button("DONE ⏎") { m.selected = nil }.buttonStyle(.htPrimary).keyboardShortcut(.return, modifiers: []) }
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let w = m.widget(m.selected) { WidgetInspector(ws: ws, w: w) } else { variables }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var variables: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Variables bind into widget queries as :name. A time range becomes an interval for the engine, an enum a quoted string, never part of an identifier.").ht(.bodySmall).foregroundStyle(HT.C.ink3)
            ForEach(Array(spec.variables.enumerated()), id: \.offset) { i, v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(":").ht(.data).foregroundStyle(HT.C.ink3)
                        TextField("name", text: Binding(get: { v.name }, set: { n in m.updateVariable(i, ws) { $0.name = n.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" } } })).textFieldStyle(.plain).ht(.data).htInput()
                        Text(v.type.uppercased()).ht(.labelSmall).foregroundStyle(HT.C.ink3)
                        Button("×") { m.removeVariable(i) }.buttonStyle(.htOutline).accessibilityLabel("Remove variable \(v.name)")
                    }
                    if v.type == "timeRange" {
                        TextField("default, e.g. 30d", text: Binding(get: { v.default ?? "" }, set: { d in m.updateVariable(i, ws) { $0.default = d } })).textFieldStyle(.plain).ht(.data).htInput()
                    } else {
                        TextField("SELECT of one column", text: Binding(get: { v.sql ?? "" }, set: { s in m.updateVariable(i, ws) { $0.sql = s } }), axis: .vertical).textFieldStyle(.plain).ht(.data).htInput()
                    }
                }
            }
            HStack { Button("+ RANGE") { m.addVariable("timeRange") }.buttonStyle(.htOutline); Button("+ FILTER") { m.addVariable("enum") }.buttonStyle(.htOutline) }
            let bad = spec.validate().filter { $0.widget == nil }
            ForEach(Array(bad.enumerated()), id: \.offset) { _, i in Text(i.message).ht(.bodySmall).foregroundStyle(HT.C.alert) }
        }
    }
}

private struct WidgetInspector: View {
    let ws: WorkspaceModel, w: DashWidget
    @State private var sql = ""
    @State private var mode = "sql"
    @State private var table = ""
    @State private var agg = "count"
    @State private var aggCol = ""
    @State private var group = ""
    private var m: DashboardModel { ws.dash }
    private var type: DashType? { DashCatalog.type(w.type) }
    private var result: WTable? { if case .ready(let t, _)? = m.data[w.id] { t } else { nil } }
    private var tables: [TableInfo] { (ws.schema?.tables ?? []).filter { $0.kind == .table } }

    var body: some View {
        Group {
            section("Title")
            TextField("Title", text: Binding(get: { w.title }, set: { t in m.update(w.id, ws) { $0.title = t } })).textFieldStyle(.plain).ht(.bodySmall).htInput()
            if type?.hasQuery == true { data }
            encoding
            if type?.hasQuery == true { format; thresholds }
            if w.type == "kpi" { section("Comparison"); HTSegmented(selection: Binding(get: { w.compare ?? "none" }, set: { c in m.update(w.id, ws, refetch: true) { $0.compare = c } }), options: [("none", "NONE"), ("previous_period", "PREVIOUS")]) }
            size
            if let t = result { section("VoiceOver summary"); Text("“\(Summary.text(w, t))”").ht(.bodySmall).foregroundStyle(HT.C.ink2) }
            Button("REMOVE WIDGET") { m.remove(w.id) }.buttonStyle(.htDestructive)
        }
        .onAppear { sql = w.query ?? ""; table = tables.first?.name ?? "" }
        .onChange(of: w.id) { sql = w.query ?? ""; mode = "sql" }
    }

    private func section(_ s: String) -> some View {
        HStack(spacing: 6) { CapsLabel(s, nil); Rectangle().fill(HT.C.line).frame(height: 1) }.padding(.top, 6)
    }

    // MARK: data: SQL, or table + aggregation compiled to SQL

    @ViewBuilder private var data: some View {
        section("Data")
        HTSegmented(selection: $mode, options: [("sql", "SQL"), ("table", "TABLE + AGGREGATION")])
        if mode == "sql" {
            TextEditor(text: $sql).ht(.dataSmall).scrollContentBackground(.hidden).frame(height: 120).clipped().htInput().padding(.top, 4)
            HStack {
                Button("RUN ⌘⏎") { m.update(w.id, ws, refetch: true) { $0.query = sql } }.buttonStyle(.htPrimary).keyboardShortcut(.return, modifiers: .command)
                if let t = result { Text("\(t.rows.count) ROWS // \(Int(t.ms)) MS").ht(.labelSmall).foregroundStyle(HT.C.ink3) }
            }
            if case .failed(let e)? = m.data[w.id] { Text(e).ht(.dataSmall).foregroundStyle(HT.C.alert) }
        } else {
            let cols = tables.first { $0.name == table }?.columns.map(\.name) ?? []
            Picker("Table", selection: $table) { ForEach(tables.map(\.name), id: \.self) { Text($0).tag($0) } }
            Picker("Aggregation", selection: $agg) { ForEach(["count", "sum", "avg", "min", "max"], id: \.self) { Text($0.uppercased()).tag($0) } }
            if agg != "count" { Picker("Column", selection: $aggCol) { Text("—").tag(""); ForEach(cols, id: \.self) { Text($0).tag($0) } } }
            Picker("Group by", selection: $group) { Text("none").tag(""); ForEach(cols, id: \.self) { Text($0).tag($0) } }
            Button("APPLY") { apply() }.buttonStyle(.htPrimary).disabled(table.isEmpty || (agg != "count" && aggCol.isEmpty))
        }
    }

    private func apply() {
        let e = ws.profile.engine, a = agg == "count" ? "COUNT(*)" : "\(agg.uppercased())(\(quoteIdent(aggCol, e)))", t = quoteIdent(table, e)
        let q = group.isEmpty ? "SELECT \(a) AS value FROM \(t)" : "SELECT \(quoteIdent(group, e)) AS label, \(a) AS value FROM \(t) GROUP BY 1 ORDER BY 2 DESC LIMIT 20"
        sql = q; mode = "sql"
        m.update(w.id, ws, refetch: true) { d in
            d.query = q
            for n in type?.needs ?? [] where d.encoding?[n.key] == nil {
                if ["x", "label", "step", "axis"].contains(n.key), !group.isEmpty { d.encoding = (d.encoding ?? [:]).merging([n.key: DashEnc("label")]) { $1 } }
                if ["y", "value"].contains(n.key) { d.encoding = (d.encoding ?? [:]).merging([n.key: DashEnc("value")]) { $1 } }
            }
        }
    }

    // MARK: encoding, format, thresholds, size

    @ViewBuilder private var encoding: some View {
        if let t = type, !t.needs.isEmpty {
            section("Encoding")
            ForEach(t.needs, id: \.key) { n in
                HStack(spacing: 6) {
                    Text(n.key + (n.required ? "" : "?")).ht(.dataSmall).frame(width: 64, alignment: .leading)
                    Text(n.kind).ht(.labelSmall).foregroundStyle(HT.C.ink3).frame(width: 52, alignment: .leading)
                    let cur = w.encoding?[n.key]?.values.joined(separator: ", ") ?? ""
                    if t.hasQuery, ![ "bins", "hops"].contains(n.key), let r = result {
                        Picker("", selection: Binding(get: { cur }, set: { v in setEnc(n.key, v) })) {
                            Text("—").tag(""); if !cur.isEmpty && !r.columns.contains(cur) { Text(cur + " ⚠").tag(cur) }
                            ForEach(r.columns, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    } else {
                        TextField(n.required ? "required" : "optional", text: Binding(get: { cur }, set: { setEnc(n.key, $0) }), axis: n.key == "markdown" ? .vertical : .horizontal).textFieldStyle(.plain).ht(.dataSmall).htInput()
                    }
                }
            }
        }
    }
    private func setEnc(_ key: String, _ v: String) {
        let vals = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        m.update(w.id, ws, refetch: type?.hasQuery == true) { d in
            var e = d.encoding ?? [:]
            if vals.isEmpty { e[key] = nil } else { e[key] = DashEnc(vals) }
            d.encoding = e.isEmpty ? nil : e
        }
    }

    @ViewBuilder private var format: some View {
        section("Format")
        HStack(spacing: 6) {
            Text("unit").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            TextField("USD, %, ms", text: Binding(get: { w.format?.unit ?? "" }, set: { u in m.update(w.id, ws) { $0.format = DashFormat(unit: u.isEmpty ? nil : u, compact: $0.format?.compact, decimals: $0.format?.decimals) } })).textFieldStyle(.plain).ht(.dataSmall).htInput().frame(width: 80)
            HTToggleChip("COMPACT", isOn: Binding(get: { w.format?.compact ?? false }, set: { c in m.update(w.id, ws) { $0.format = DashFormat(unit: $0.format?.unit, compact: c, decimals: $0.format?.decimals) } }))
        }
        HStack(spacing: 6) {
            Text("decimals").ht(.labelSmall).foregroundStyle(HT.C.ink3)
            HTSegmented(selection: Binding(get: { w.format?.decimals ?? -1 }, set: { d in m.update(w.id, ws) { $0.format = DashFormat(unit: $0.format?.unit, compact: $0.format?.compact, decimals: d < 0 ? nil : d) } }), options: [(-1, "AUTO"), (0, "0"), (1, "1"), (2, "2")])
        }
    }

    @ViewBuilder private var thresholds: some View {
        section("Thresholds // colour is a signal")
        ForEach(Array((w.thresholds ?? []).enumerated()), id: \.offset) { i, t in
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { t.op }, set: { o in setThreshold(i) { $0.op = o } })) { ForEach(["<", "<=", ">", ">=", "=="], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 56)
                TextField("value", value: Binding(get: { t.value }, set: { v in setThreshold(i) { $0.value = v } }), format: .number).textFieldStyle(.plain).ht(.dataSmall).htInput().frame(width: 70)
                HTSegmented(selection: Binding(get: { t.level }, set: { l in setThreshold(i) { $0.level = l } }), options: [("warn", "WARN"), ("alert", "ALERT")])
                Button("×") { m.update(w.id, ws) { $0.thresholds?.remove(at: i); if $0.thresholds?.isEmpty == true { $0.thresholds = nil } } }.buttonStyle(.htOutline).accessibilityLabel("Remove threshold")
            }
        }
        if (w.thresholds ?? []).isEmpty { Text("No thresholds. Values stay ink.").ht(.bodySmall).foregroundStyle(HT.C.ink3) }
        Button("+ ADD THRESHOLD") { m.update(w.id, ws) { $0.thresholds = ($0.thresholds ?? []) + [DashThreshold(op: ">", value: 0, level: "warn")] } }.buttonStyle(.htOutline)
    }
    private func setThreshold(_ i: Int, _ body: (inout DashThreshold) -> Void) { m.update(w.id, ws) { if $0.thresholds?.indices.contains(i) == true { body(&$0.thresholds![i]) } } }

    @ViewBuilder private var size: some View {
        section("Size // 12 cols · row 72 pt")
        HStack(spacing: 14) {
            stepper("W", w.w) { m.place(w.id, x: w.x, y: w.y, w: $0, h: w.h) }
            stepper("H", w.h) { m.place(w.id, x: w.x, y: w.y, w: w.w, h: $0) }
        }
        Text("Minimum for \(w.type) is \(type?.minW ?? 1)×\(type?.minH ?? 1). Neighbours reflow down, never overlap.").ht(.bodySmall).foregroundStyle(HT.C.ink3)
    }
    private func stepper(_ k: String, _ v: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(k).ht(.labelSmall).foregroundStyle(HT.C.ink3)
            Button("−") { set(v - 1) }.buttonStyle(.htOutline).accessibilityLabel("Decrease \(k)")
            Text("\(v)").ht(.readoutS).frame(minWidth: 24)
            Button("+") { set(v + 1) }.buttonStyle(.htOutline).accessibilityLabel("Increase \(k)")
        }
    }
}
