import Foundation

// Dashboard spec (SPEC §2): what agents write and the app renders. Pure: no UI, no I/O.

public struct DashError: Error, LocalizedError, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An encoding value: one column name, or several (`y: ["a","b"]`). For `text` and `er.mini` it is a literal, not a column.
public struct DashEnc: Codable, Equatable, Sendable {
    public var values: [String]
    public init(_ v: String...) { values = v }
    public init(_ v: [String]) { values = v }
    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let many = try? c.decode([String].self) { values = many } else { values = [try c.decode(String.self)] }
    }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        if values.count == 1 { try c.encode(values[0]) } else { try c.encode(values) }
    }
    public var first: String? { values.first }
}

public struct DashVariable: Codable, Equatable, Sendable {
    public var name: String
    public var type: String          // timeRange | enum
    public var `default`: String?
    public var sql: String?          // enum options (a SELECT of one column)
    public init(name: String, type: String, default d: String? = nil, sql: String? = nil) { self.name = name; self.type = type; self.default = d; self.sql = sql }
}

public struct DashFormat: Codable, Equatable, Sendable {
    public var unit: String?
    public var compact: Bool?
    public var decimals: Int?
    public init(unit: String? = nil, compact: Bool? = nil, decimals: Int? = nil) { self.unit = unit; self.compact = compact; self.decimals = decimals }
}

public struct DashThreshold: Codable, Equatable, Sendable {
    public var op: String            // < <= > >= ==
    public var value: Double
    public var level: String         // warn | alert
    public init(op: String, value: Double, level: String) { self.op = op; self.value = value; self.level = level }
    public func hit(_ v: Double) -> Bool {
        switch op { case "<": v < value; case "<=": v <= value; case ">": v > value; case ">=": v >= value; default: v == value }
    }
}

public struct DashWidget: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var title: String
    public var x: Int, y: Int, w: Int, h: Int
    public var query: String?
    public var encoding: [String: DashEnc]?
    public var format: DashFormat?
    public var thresholds: [DashThreshold]?
    public var compare: String?      // previous_period | none
    public init(id: String, type: String, title: String, x: Int, y: Int, w: Int, h: Int, query: String? = nil, encoding: [String: DashEnc]? = nil,
                format: DashFormat? = nil, thresholds: [DashThreshold]? = nil, compare: String? = nil) {
        self.id = id; self.type = type; self.title = title; self.x = x; self.y = y; self.w = w; self.h = h
        self.query = query; self.encoding = encoding; self.format = format; self.thresholds = thresholds; self.compare = compare
    }
    public func enc(_ key: String) -> String? { encoding?[key]?.first }
    /// First encoded column the result does not have (schema drift: "column `total` not found"); kpis fall back to a column named `value`.
    public func missingColumn(in columns: [String]) -> String? {
        guard let t = DashCatalog.type(type), t.hasQuery else { return nil }
        let have = Set(columns.map { $0.lowercased() })
        for n in t.needs {
            guard n.key != "bins", n.key != "hops" else { continue } // literals, not columns
            for c in encoding?[n.key]?.values ?? (type.hasPrefix("kpi") && n.key == "value" ? ["value"] : []) where !have.contains(c.lowercased()) { return c }
        }
        return nil
    }
}

public struct DashboardSpec: Codable, Equatable, Sendable {
    public var version: Int
    public var title: String
    public var connection: String?
    public var variables: [DashVariable]
    public var refresh: String       // off | 30s | 1m | 5m
    public var widgets: [DashWidget]
    public init(title: String, connection: String? = nil, variables: [DashVariable] = [], refresh: String = "off", widgets: [DashWidget] = []) {
        version = 1; self.title = title; self.connection = connection; self.variables = variables; self.refresh = refresh; self.widgets = widgets
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decode(String.self, forKey: .title)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        variables = try c.decodeIfPresent([DashVariable].self, forKey: .variables) ?? []
        refresh = try c.decodeIfPresent(String.self, forKey: .refresh) ?? "off"
        widgets = try c.decode([DashWidget].self, forKey: .widgets)
    }
    enum K: String, CodingKey { case version, title, connection, variables, refresh, widgets }

    public static let refreshes = ["off", "30s", "1m", "5m"]
    public var refreshSeconds: Int? { ["30s": 30, "1m": 60, "5m": 300][refresh] }

    /// Decodes JSON text. Decoding errors name the path; raw markup keys are rejected (agents use the catalog, never HTML).
    public static func parse(_ json: String) throws -> DashboardSpec {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DashError(message: "spec must be a JSON object") }
        for case let w as [String: Any] in root["widgets"] as? [Any] ?? [] {
            if let bad = ["html", "script", "style"].first(where: { w[$0] != nil }) { throw DashError(message: "widget \(w["id"] ?? "?"): \"\(bad)\" is not allowed; use components from dashboard.components") }
        }
        do { return try JSONDecoder().decode(DashboardSpec.self, from: data) } catch let e as DecodingError {
            switch e {
            case .keyNotFound(let k, let c): throw DashError(message: "missing \(k.stringValue) at \(Self.path(c.codingPath))")
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): throw DashError(message: "bad value at \(Self.path(c.codingPath)): \(c.debugDescription)")
            @unknown default: throw DashError(message: "invalid spec")
            }
        }
    }
    private static func path(_ p: [CodingKey]) -> String { p.isEmpty ? "root" : p.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined() }

    public func json(pretty: Bool = false) -> String {
        let e = JSONEncoder(); e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

// MARK: catalog

public struct DashType: Sendable {
    public struct Need: Sendable { public var key: String, kind: String, required: Bool }
    public var id: String, group: String, minW: Int, minH: Int, needs: [Need], good: String
    /// `text` and `er.mini` carry no query.
    public var hasQuery: Bool { id != "text" && id != "er.mini" }
    init(_ id: String, _ group: String, _ min: (Int, Int), _ needs: String, _ good: String) {
        self.id = id; self.group = group; minW = min.0; minH = min.1; self.good = good
        self.needs = needs.split(separator: " ").map { tok in
            let p = tok.split(separator: ":", maxSplits: 1).map(String.init), opt = p[0].hasSuffix("?")
            return Need(key: opt ? String(p[0].dropLast()) : p[0], kind: p.count > 1 ? p[1] : "any", required: !opt)
        }
    }
}

public enum DashCatalog {
    public static let cols = 12
    /// The 28 components, in library order (8 groups). Agents read this catalog through `dashboard.components`.
    public static let types: [DashType] = [
        DashType("kpi", "numbers", (2, 2), "value:number", "One headline number and its change against the previous period."),
        DashType("kpi.spark", "numbers", (3, 2), "value:number x:time y:number", "A live count where the shape of the day matters as much as the total."),
        DashType("meter", "numbers", (3, 2), "value:number max:number", "Capacity against a known limit, read in one glance."),
        DashType("kpi.target", "numbers", (3, 2), "value:number target:number", "Progress toward a goal: the number, percent of target and what is left. One row with both columns."),
        DashType("gauge", "numbers", (3, 3), "value:number max:number", "A dial for a bounded rate (utilisation, SLA, error budget). Colour follows `thresholds`."),
        DashType("stat.list", "numbers", (3, 3), "label:text value:number delta?:number", "Several headline numbers in one card, one row each; `delta` is a percent change shown as ▲/▼."),
        DashType("line", "time", (4, 3), "x:time y:number+ series?:category", "Trends over time, up to 4 series, one highlighted in cobalt."),
        DashType("area.stacked", "time", (4, 3), "x:time y:number series:category", "Part-to-whole over time when the total also matters."),
        DashType("heatmap.hour_week", "time", (6, 3), "t:time value:number", "When things happen: staffing, batch windows, campaign timing."),
        DashType("heatmap.calendar", "time", (6, 2), "day:date value:number", "Daily rhythm and one-off anomalies across months."),
        DashType("sparkline.grid", "time", (6, 3), "label:text x:time y:number", "Small multiples: one trend per label (per table, region, customer), each with its latest value."),
        DashType("bars", "compare", (3, 3), "x:time|category y:number", "Discrete periods or categories compared at a glance."),
        DashType("bars.stacked", "compare", (4, 3), "x:time|category y:number series:category", "Composition per period, at most 4 segments."),
        DashType("bars.horizontal", "compare", (3, 3), "label:text value:number", "Top-N rankings with long labels that need to stay readable."),
        DashType("radar", "compare", (3, 3), "axis:text value:number series?:category", "One entity profiled across 3-8 normalised scores."),
        DashType("funnel", "compare", (3, 3), "step:text value:number order?:int", "Ordered conversion steps and where people drop out."),
        DashType("leaderboard", "compare", (3, 3), "label:text value:number delta?:number", "A ranked top list with each entry's share of the total and, with `delta`, its percent change."),
        DashType("donut", "compare", (3, 3), "label:text value:number", "Part-to-whole for up to 6 categories (the rest fold into OTHER), total in the middle."),
        DashType("waffle", "compare", (3, 3), "label:text value:number", "Share drawn as a 10×10 halftone grid: one dot is 1 % of the total. Up to 5 categories."),
        DashType("histogram", "distribution", (4, 3), "value:number bins?:int", "The shape of one numeric column: skew, outliers, median."),
        DashType("halftone.distribution", "distribution", (4, 2), "x:time y:number dot?:number", "Volume over a long range, drawn as the v1 instrument."),
        DashType("scatter", "distribution", (4, 4), "x:number y:number size?:number label?:text", "The relationship between two measures, and its outliers."),
        DashType("table", "records", (4, 3), "columns?:any+", "Exact values and drill-down. All columns unless `columns` lists some."),
        DashType("status.feed", "records", (3, 4), "ts:time title:text status?:text body?:text", "The newest rows as they land, newest on top."),
        DashType("status.grid", "status", (4, 2), "label:text value:number status?:text", "Health tiles: one per row, coloured by `status` (ok / warn / alert) or by the widget's `thresholds`."),
        DashType("progress.list", "status", (3, 3), "label:text value:number max:number", "Items against their own limit (quotas, backfills, migrations), each with a bar and percent."),
        DashType("er.mini", "schema", (4, 3), "table:name hops?:int", "Where a widget's data lives, right next to its numbers. Literal encodings."),
        DashType("text", "notes", (2, 1), "markdown:text", "Context, definitions and the why behind a dashboard. Literal encoding, no query."),
    ]
    public static func type(_ id: String) -> DashType? { types.first { $0.id == id } }
    public static let groups = ["numbers", "time", "compare", "distribution", "records", "status", "schema", "notes"]

    /// JSON Schema of a dashboard spec plus the catalog (what `dashboard.components` returns).
    public static func schema() -> [String: Any] {
        let widget: [String: Any] = [
            "type": "object", "required": ["id", "type", "title", "x", "y", "w", "h"], "additionalProperties": false,
            "properties": [
                "id": ["type": "string", "description": "Unique within the dashboard"],
                "type": ["enum": types.map(\.id)],
                "title": ["type": "string"],
                "x": ["type": "integer", "minimum": 0, "maximum": cols - 1, "description": "Column, 0-11"],
                "y": ["type": "integer", "minimum": 0, "description": "Row (unbounded)"],
                "w": ["type": "integer", "minimum": 1, "maximum": cols, "description": "x + w <= 12"],
                "h": ["type": "integer", "minimum": 1],
                "query": ["type": "string", "description": "One read-only SELECT/WITH. Variables as :name. Not for text and er.mini."],
                "encoding": ["type": "object", "description": "Needs per type (see catalog): key -> result column name, or an array of names. Literals for text and er.mini.",
                             "additionalProperties": ["oneOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]]],
                "format": ["type": "object", "properties": ["unit": ["type": "string"], "compact": ["type": "boolean"], "decimals": ["type": "integer", "minimum": 0, "maximum": 4]]],
                "thresholds": ["type": "array", "items": ["type": "object", "required": ["op", "value", "level"],
                                                          "properties": ["op": ["enum": ["<", "<=", ">", ">=", "=="]], "value": ["type": "number"], "level": ["enum": ["warn", "alert"]]]]],
                "compare": ["enum": ["previous_period", "none"], "description": "kpi: reads a `previous` column, or the second row's value"],
            ],
        ]
        return [
            "$schema": "https://json-schema.org/draft/2020-12/schema", "title": "DBMan dashboard spec",
            "type": "object", "required": ["title", "widgets"],
            "properties": [
                "version": ["const": 1], "title": ["type": "string"], "connection": ["type": "string"],
                "variables": ["type": "array", "items": ["type": "object", "required": ["name", "type"], "properties": [
                    "name": ["type": "string", "pattern": "^[a-z_][a-z0-9_]*$"], "type": ["enum": ["timeRange", "enum"]], "default": ["type": "string"],
                    "sql": ["type": "string", "description": "enum: SELECT of one column giving the options"]]],
                              "description": ":name in a query becomes a safe literal. timeRange (default like 30d; units h, d, w) binds an interval expression for the engine (pg interval '30 days', mysql INTERVAL 30 DAY, sqlite '-30 days' for datetime('now', :range)); enum binds a quoted string ('all' when unset)."],
                "refresh": ["enum": DashboardSpec.refreshes], "widgets": ["type": "array", "items": widget, "maxItems": 48],
            ],
            "grid": ["columns": cols, "rowUnit": "1 row = 72 pt; widgets may not overlap or leave the 12 columns"],
            "catalog": Dictionary(uniqueKeysWithValues: types.map { t in
                (t.id, ["group": t.group, "minSize": [t.minW, t.minH], "query": t.hasQuery,
                        "needs": Dictionary(uniqueKeysWithValues: t.needs.map { ($0.key + ($0.required ? "" : "?"), $0.kind) }), "goodFor": t.good] as [String: Any])
            }),
        ]
    }
    public static func schemaJSON() -> Data { (try? JSONSerialization.data(withJSONObject: schema(), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8) }
}

// MARK: validation

public struct DashIssue: Equatable, Sendable {
    public var widget: String?       // nil = the dashboard itself
    public var message: String
    /// Layout and structure problems reject a spec; per-widget problems (type, encoding, query) arrive in alert state.
    public var fatal: Bool
}

public extension DashboardSpec {
    func validate() -> [DashIssue] {
        var out: [DashIssue] = []
        func top(_ m: String) { out.append(DashIssue(widget: nil, message: m, fatal: true)) }
        func bad(_ w: DashWidget, _ m: String, fatal: Bool = false) { out.append(DashIssue(widget: w.id, message: m, fatal: fatal)) }
        if version != 1 { top("version must be 1") }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { top("title is required") }
        if !Self.refreshes.contains(refresh) { top("refresh must be one of \(Self.refreshes.joined(separator: ", "))") }
        var seen = Set<String>()
        for v in variables {
            if v.name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) == nil { top("variable \"\(v.name)\": name must match [a-z_][a-z0-9_]*") }
            if !seen.insert("var:" + v.name).inserted { top("duplicate variable \"\(v.name)\"") }
            switch v.type {
            case "timeRange": if v.default.map({ DashSQL.range($0) == nil }) ?? false { top("variable \"\(v.name)\": default must look like 24h, 7d, 4w") }
            case "enum": if let s = v.sql, SQLClassifier.firstKeyword(s) != "SELECT" { top("variable \"\(v.name)\": sql must be a SELECT") }
            default: top("variable \"\(v.name)\": type must be timeRange or enum")
            }
        }
        if widgets.count > 48 { top("at most 48 widgets") }
        for (i, w) in widgets.enumerated() {
            if w.id.isEmpty || !seen.insert("w:" + w.id).inserted { top("widget \(i): id must be unique and non-empty") }
            if w.x < 0 || w.y < 0 || w.w < 1 || w.h < 1 || w.x + w.w > DashCatalog.cols { bad(w, "outside the 12-column grid (x \(w.x), y \(w.y), w \(w.w), h \(w.h))", fatal: true) }
            for o in widgets[(i + 1)...] where w.x < o.x + o.w && o.x < w.x + w.w && w.y < o.y + o.h && o.y < w.y + w.h { bad(w, "overlaps \(o.id)", fatal: true) }
            guard let t = DashCatalog.type(w.type) else { bad(w, "unknown type \"\(w.type)\"; see dashboard.components"); continue }
            if w.w < t.minW || w.h < t.minH { bad(w, "\(t.id) needs at least \(t.minW)x\(t.minH)") }
            for n in t.needs where n.required && w.encoding?[n.key] == nil && !(t.id.hasPrefix("kpi") && n.key == "value") { bad(w, "missing encoding \"\(n.key)\" (\(n.kind))") }
            if t.hasQuery {
                if let q = w.query, !DashSource.isValid(q) { bad(w, "query must be a read-only SELECT") }
                if w.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { bad(w, "query is required") }
            }
            if let c = w.compare, !["previous_period", "none"].contains(c) { bad(w, "compare must be previous_period or none") }
            for th in w.thresholds ?? [] where !["<", "<=", ">", ">=", "=="].contains(th.op) || !["warn", "alert"].contains(th.level) { bad(w, "threshold needs op < <= > >= == and level warn|alert") }
        }
        return out
    }
}

// MARK: variables → SQL

public enum DashSQL {
    /// "24h" / "7d" / "4w" → (count, unit); nil if malformed.
    public static func range(_ s: String) -> (n: Int, unit: Character)? {
        guard s.range(of: "^[0-9]{1,4}[hdw]$", options: .regularExpression) != nil, let n = Int(s.dropLast()), n > 0 else { return nil }
        return (n, s.last!)
    }

    /// Replaces `:name` for declared variables with a literal. Strings, quoted identifiers, comments and `::` casts are left alone, and a value can only ever become
    /// a quoted string or a digits-only interval, so it cannot reach an identifier or add a statement.
    public static func bind(_ sql: String, variables: [DashVariable], values: [String: String] = [:], engine: Engine) -> String {
        let lits = Dictionary(variables.map { v in (v.name, literal(v, values[v.name] ?? v.default, engine)) }, uniquingKeysWith: { a, _ in a })
        let c = Array(sql); var out = "", i = 0
        func isName(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        while i < c.count {
            let ch = c[i]
            if ch == "'" || ch == "\"" || ch == "`" {                       // quoted run; a doubled quote stays inside it
                var j = i + 1
                while j < c.count { if c[j] == ch { if j + 1 < c.count, c[j + 1] == ch { j += 2; continue }; break }; j += 1 }
                out += String(c[i..<min(j + 1, c.count)]); i = j + 1
            } else if ch == "-", i + 1 < c.count, c[i + 1] == "-" {
                var j = i; while j < c.count, c[j] != "\n" { j += 1 }
                out += String(c[i..<j]); i = j
            } else if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                var j = i + 2; while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                out += String(c[i..<min(j + 2, c.count)]); i = j + 2
            } else if ch == ":", i + 1 < c.count, c[i + 1] == ":" {
                out += "::"; i += 2
            } else if ch == ":", i + 1 < c.count, isName(c[i + 1]), !(i > 0 && isName(c[i - 1])) {
                var j = i + 1; while j < c.count, isName(c[j]) { j += 1 }
                let name = String(c[(i + 1)..<j])
                out += lits[name] ?? ":" + name; i = j
            } else { out.append(ch); i += 1 }
        }
        return out
    }

    private static func literal(_ v: DashVariable, _ value: String?, _ e: Engine) -> String {
        if v.type == "timeRange" {
            let (n, u) = range(value ?? "") ?? range(v.default ?? "") ?? (30, "d")
            switch (e, u) {
            case (.postgres, _): return "interval '\(n) \(u == "h" ? "hours" : u == "d" ? "days" : "weeks")'"
            case (.mysql, _): return "INTERVAL \(n) \(u == "h" ? "HOUR" : u == "d" ? "DAY" : "WEEK")"
            case (.sqlite, "w"): return "'-\(n * 7) days'"
            case (.sqlite, _): return "'-\(n) \(u == "h" ? "hours" : "days")'"
            }
        }
        return Cell.text((value ?? "all").replacingOccurrences(of: "\0", with: "")).sqlLiteral(e)
    }
}

// MARK: grid

public enum DashGrid {
    static func hit(_ a: DashWidget, _ b: DashWidget) -> Bool { a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h }

    /// Index of the grid cell under `point` (pt from the grid's edge) for cells of `cell` pt with `gap` between them. Used by drag and resize to snap.
    public static func snap(_ point: Double, cell: Double, gap: Double) -> Int { Int((point / (cell + gap)).rounded(.down)) }

    /// Moves or resizes one widget (clamped to the grid and its minimum size) and pushes whatever it hits down, never overlapping. Others keep their order.
    public static func place(_ widgets: [DashWidget], id: String, x: Int, y: Int, w: Int, h: Int) -> [DashWidget] {
        guard var moved = widgets.first(where: { $0.id == id }) else { return widgets }
        let t = DashCatalog.type(moved.type)
        moved.w = min(max(w, t?.minW ?? 1), DashCatalog.cols); moved.h = max(h, t?.minH ?? 1)
        moved.x = min(max(x, 0), DashCatalog.cols - moved.w); moved.y = max(y, 0)
        var placed = [moved]
        for var o in widgets.filter({ $0.id != id }).sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            while let h = placed.first(where: { hit($0, o) }) { o.y = h.y + h.h }
            placed.append(o)
        }
        return widgets.map { w in placed.first { $0.id == w.id }! }
    }

    /// The first free spot for a w x h widget, scanning rows top to bottom.
    public static func nextFree(_ widgets: [DashWidget], w: Int, h: Int) -> (x: Int, y: Int) {
        let probe = DashWidget(id: "", type: "text", title: "", x: 0, y: 0, w: w, h: h)
        for y in 0... {
            for x in 0...(DashCatalog.cols - min(w, DashCatalog.cols)) {
                var p = probe; p.x = x; p.y = y
                if !widgets.contains(where: { hit($0, p) }) { return (x, y) }
            }
        }
        return (0, 0)
    }
}

// MARK: JSON patch (RFC 6902 subset)

public enum JSONPatch {
    /// add / remove / replace on `/a/b/0` paths (`~0`, `~1` escapes, `-` = append for add). Operates on JSONSerialization objects.
    public static func apply(_ ops: [[String: Any]], to doc: Any) throws -> Any {
        var doc = doc
        for (i, op) in ops.enumerated() {
            guard let kind = op["op"] as? String, ["add", "remove", "replace"].contains(kind) else { throw DashError(message: "op \(i): op must be add, remove or replace") }
            guard let path = op["path"] as? String, path.hasPrefix("/") || path.isEmpty else { throw DashError(message: "op \(i): path must be a JSON pointer like /widgets/0/title") }
            if kind != "remove", op["value"] == nil { throw DashError(message: "op \(i): value is required for \(kind)") }
            let keys = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            if keys.isEmpty { guard kind == "replace", let v = op["value"] else { throw DashError(message: "op \(i): only replace may target the root") }; doc = v; continue }
            do { doc = try edit(doc, keys[...], kind, op["value"]) } catch let e as DashError { throw DashError(message: "op \(i) (\(kind) \(path)): \(e.message)") }
        }
        return doc
    }

    private static func edit(_ node: Any, _ path: ArraySlice<String>, _ kind: String, _ value: Any?) throws -> Any {
        let head = path.first!, last = path.count == 1
        if var d = node as? [String: Any] {
            if last {
                if kind == "add" { d[head] = value } else {
                    guard d[head] != nil else { throw DashError(message: "no member \"\(head)\"") }
                    if kind == "replace" { d[head] = value } else { d[head] = nil }
                }
                return d
            }
            guard let child = d[head] else { throw DashError(message: "no member \"\(head)\"") }
            d[head] = try edit(child, path.dropFirst(), kind, value)
            return d
        }
        if var a = node as? [Any] {
            let idx = head == "-" && kind == "add" && last ? a.count : Int(head)
            guard let idx, idx >= 0, kind == "add" && last ? idx <= a.count : idx < a.count else { throw DashError(message: "index \(head) is out of range (\(a.count) items)") }
            if last {
                switch kind { case "add": a.insert(value!, at: idx); case "replace": a[idx] = value!; default: a.remove(at: idx) }
            } else { a[idx] = try edit(a[idx], path.dropFirst(), kind, value) }
            return a
        }
        throw DashError(message: "cannot descend into a scalar at \"\(head)\"")
    }

    /// Applies `ops` to a spec's JSON and validates the result; the caller decides what to do with widget-level issues.
    public static func apply(_ ops: [[String: Any]], toSpec json: String) throws -> DashboardSpec {
        guard let data = json.data(using: .utf8), let doc = try? JSONSerialization.jsonObject(with: data) else { throw DashError(message: "stored spec is not JSON") }
        let out = try apply(ops, to: doc)
        guard JSONSerialization.isValidJSONObject(out), let d = try? JSONSerialization.data(withJSONObject: out) else { throw DashError(message: "patch produced invalid JSON") }
        return try DashboardSpec.parse(String(decoding: d, as: UTF8.self))
    }
}

// MARK: local sources

/// Queries the app answers itself instead of the database: `schema:` (label, rows, bytes per table from the snapshot's estimates, so no COUNT(*)),
/// `schema:NAME` (one table), `schema:*` (rows, bytes totals), `activity:` (ts, title, status, body from this app's console), `insights:` (same columns: v1's Overview insights, computed per refresh),
/// `rate:console` or `rate:SELECT <counter>` (x, y, value: per-second change between refreshes).
public enum DashSource {
    public static func split(_ q: String) -> (kind: String, arg: String)? {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        for k in ["schema", "activity", "insights", "rate"] where t.hasPrefix(k + ":") { return (k, String(t.dropFirst(k.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
    public static func isValid(_ q: String) -> Bool {
        guard let s = split(q) else { return readOnly(q) }
        return s.kind == "rate" && s.arg != "console" ? readOnly(s.arg) : true
    }
    private static func readOnly(_ q: String) -> Bool { ["SELECT", "WITH", "VALUES"].contains(SQLClassifier.firstKeyword(q)) }
}

/// What v1's Overview called Insights, from data the seeding already holds. Pure.
public enum DashInsights {
    public struct Item: Equatable, Sendable { public var title: String, detail: String; public var warn: Bool }
    public static func make(tables: [TableInfo], table: String, column: String, growth: [(value: String, last: Double, prior: Double)],
                            nulls: [(table: String, column: String, fraction: Double)], unusedIndexes: [(table: String, index: String)], attention: (String) -> Bool) -> [Item] {
        var out: [Item] = []
        let total = tables.reduce(Int64(0)) { $0 + $1.rowCount }
        if let top = tables.max(by: { $0.rowCount < $1.rowCount }), total > 0, Double(top.rowCount) / Double(total) >= 0.4 {
            out.append(Item(title: "\(top.name) holds \(Int((Double(top.rowCount) / Double(total) * 100).rounded())) % of rows",
                            detail: "\(top.rowCount.formatted()) of \(total.formatted()) rows live in one table.", warn: false))
        }
        let up = growth.filter { $0.prior > 0 }.map { ($0.value, $0.last / $0.prior - 1) }
        if let g = up.max(by: { $0.1 < $1.1 }), g.1 >= 0.25 {
            out.append(Item(title: "\(column) \(g.0) up \(Int((g.1 * 100).rounded())) %",
                            detail: "\(table) rows with \(column) = \(g.0): last 7 days vs prior 7.", warn: attention(g.0)))
        }
        for n in nulls.sorted(by: { $0.fraction > $1.fraction }).prefix(1) where n.fraction > 0.4 {
            out.append(Item(title: "\(n.table).\(n.column) is \(Int((n.fraction * 100).rounded())) % null", detail: "More than 40% of sampled rows have no value.", warn: true))
        }
        if let u = unusedIndexes.first {
            out.append(Item(title: "\(unusedIndexes.count) unused index\(unusedIndexes.count == 1 ? "" : "es")", detail: "\(u.index) on \(u.table) has never been scanned.", warn: true))
        }
        return Array(out.prefix(4))
    }
}
