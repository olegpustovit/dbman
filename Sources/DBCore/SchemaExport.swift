import CoreGraphics
import Foundation

/// String builders for the map's export formats. Inferred relations are comments (they are suggestions, not schema).
public enum SchemaExport {
    private static func word(_ s: String) -> String { s.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }.map(String.init).joined() }

    public static func mermaid(_ g: SchemaGraph) -> String {
        var out = ["erDiagram"]
        for e in g.edges {
            let (a, b) = (word(e.to), word(e.from))
            if e.kind == .inferred { out.append("  %% inferred: \(e.from).\(e.fromColumn) -> \(e.to).\(e.toColumn)"); continue }
            out.append(e.manyToMany ? "  \(word(e.from)) }o--o{ \(word(e.to)) : \"many-to-many\""
                                    : "  \(a) \(e.optional ? "|o" : "||")--o{ \(b) : \(word(e.fromColumn))")
        }
        for t in g.tables {
            let fks = Set(g.edges.filter { $0.from == t.name && $0.kind != .inferred }.map(\.fromColumn))
            out.append("  \(word(t.name)) {")
            for c in t.columns {
                let keys = [c.isPrimaryKey ? "PK" : nil, fks.contains(c.name) ? "FK" : nil].compactMap { $0 }.joined(separator: ", ")
                out.append("    \(word(c.type.isEmpty ? "unknown" : c.type)) \(word(c.name))" + (keys.isEmpty ? "" : " \(keys)"))
            }
            out.append("  }")
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func dbml(_ g: SchemaGraph) -> String {
        func ty(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : (s.isEmpty ? "unknown" : s) }
        var out: [String] = []
        for t in g.tables {
            out.append("Table \(t.name) {")
            for c in t.columns {
                let attrs = [c.isPrimaryKey ? "pk" : nil, c.nullable || c.isPrimaryKey ? nil : "not null"].compactMap { $0 }
                out.append("  \(c.name) \(ty(c.type))" + (attrs.isEmpty ? "" : " [\(attrs.joined(separator: ", "))]"))
            }
            out += ["}", ""]
        }
        for e in g.edges {
            if e.manyToMany { out.append("// many-to-many: \(e.from) <> \(e.to)"); continue }
            out.append((e.kind == .inferred ? "// inferred: " : "") + "Ref: \(e.from).\(e.fromColumn) > \(e.to).\(e.toColumn)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Light theme, live text, one `<g id="table">` per card.
    public static func svg(_ s: MapScene) -> String {
        func esc(_ t: String) -> String { t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        let b = s.layout.bounds(s.sizes), ink = "#0B0B0C", accent = "#2F2FE4", mute = "#6A6A70"
        var o = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(b.maxX + 20))\" height=\"\(Int(b.maxY + 20))\" font-family=\"-apple-system, Helvetica, sans-serif\" font-size=\"11\">"]
        for box in s.layout.boxes {
            o.append("<g id=\"cluster-\(esc(box.name))\"><rect x=\"\(f(box.rect.minX))\" y=\"\(f(box.rect.minY))\" width=\"\(f(box.rect.width))\" height=\"\(f(box.rect.height))\" rx=\"3\" fill=\"none\" stroke=\"\(mute)\" stroke-dasharray=\"4 3\"/>"
                     + "<text x=\"\(f(box.rect.minX + 10))\" y=\"\(f(box.rect.minY + 17))\" fill=\"\(ink)\" font-weight=\"600\">\(esc(box.name.uppercased()))</text></g>")
        }
        for e in s.graph.edges {
            guard let r = s.route(e) else { continue }
            let col = e.kind == .inferred ? accent : ink
            let dash = e.kind == .inferred ? " stroke-dasharray=\"5 4\"" : e.kind == .virtual ? " stroke-dasharray=\"7 3 1.5 3\"" : e.manyToMany ? " stroke-dasharray=\"1.5 3\"" : ""
            var d = "M\(f(r.p0.x)) \(f(r.p0.y))C\(f(r.c1.x)) \(f(r.c1.y)) \(f(r.c2.x)) \(f(r.c2.y)) \(f(r.p1.x)) \(f(r.p1.y))"
            let m = r.marks(e)
            for (p, q) in m.lines { d += "M\(f(p.x)) \(f(p.y))L\(f(q.x)) \(f(q.y))" }
            o.append("<path class=\"fk\" d=\"\(d)\" fill=\"none\" stroke=\"\(col)\" stroke-width=\"1.1\"\(dash)/>")
            for c in m.rings { o.append("<circle cx=\"\(f(c.x))\" cy=\"\(f(c.y))\" r=\"3\" fill=\"#FFFFFF\" stroke=\"\(col)\" stroke-width=\"1.1\"/>") }
        }
        for t in s.graph.tables {
            guard let r = s.rect(t.name) else { continue }
            o.append("<g id=\"\(esc(t.name))\"><rect x=\"\(f(r.minX))\" y=\"\(f(r.minY))\" width=\"\(f(r.width))\" height=\"\(f(r.height))\" rx=\"3\" fill=\"#FFFFFF\" stroke=\"\(ink)\"/>"
                     + "<text x=\"\(f(r.minX + 8))\" y=\"\(f(r.minY + 16))\" fill=\"\(ink)\" font-weight=\"600\">\(esc(t.name.uppercased()))</text>"
                     + "<text x=\"\(f(r.maxX - 8))\" y=\"\(f(r.maxY - 5))\" fill=\"\(mute)\" text-anchor=\"end\" font-family=\"Menlo, monospace\" font-size=\"10\">\(t.rowCount)</text>")
            for (i, c) in s.graph.shownColumns(t, s.detail).enumerated() {
                let y = r.minY + MapMetrics.head + (CGFloat(i) + 0.5) * MapMetrics.row + 4
                o.append("<text x=\"\(f(r.minX + 8))\" y=\"\(f(y))\" font-family=\"Menlo, monospace\" font-size=\"11\" fill=\"\(ink)\"\(c.isPrimaryKey ? " font-weight=\"700\"" : "")>\(esc(c.name))</text>"
                         + "<text x=\"\(f(r.maxX - 8))\" y=\"\(f(y))\" text-anchor=\"end\" font-family=\"Menlo, monospace\" font-size=\"10\" fill=\"\(mute)\">\(esc(c.type.lowercased()))</text>")
            }
            o.append("</g>")
        }
        o.append("</svg>")
        return o.joined(separator: "\n") + "\n"
    }

    /// What "Explain this schema" puts on the clipboard: the graph, no row data.
    public static func agentPrompt(_ g: SchemaGraph, connection: String) -> String {
        let rels = g.edges.filter { !$0.manyToMany }.map { "- \($0.from).\($0.fromColumn) -> \($0.to).\($0.toColumn)" + ($0.kind == .declared ? "" : " (\($0.kind.rawValue))") }
        return """
        Explain the schema of the DBMan connection "\(connection)": what each table is for, the main business entities, how they relate, and anything odd \
        (missing foreign keys, isolated tables, junction tables). Use the dbman MCP tools schema.graph and schema.describe; do not query row data.

        \(g.tables.count) tables, \(rels.count) relations:
        \(g.tables.map { "- \($0.name) (\($0.columns.count) columns, ~\($0.rowCount) rows)" }.joined(separator: "\n"))
        Relations:
        \(rels.joined(separator: "\n"))
        """
    }
}
