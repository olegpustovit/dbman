import Foundation

/// Splits a script on top-level semicolons, ignoring quotes, comments and (Postgres) dollar quotes.
public func splitStatements(_ sql: String, mysql: Bool = false) -> [String] {
    let c = Array(sql.unicodeScalars)
    var out: [String] = [], start = 0, i = 0
    func flush(_ end: Int) {
        let s = String(String.UnicodeScalarView(c[start..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
        // comment-only chunks are not statements
        if !s.isEmpty && !(SQLClassifier.firstKeyword(s).isEmpty && (s.hasPrefix("--") || s.hasPrefix("/*"))) { out.append(s) }
    }
    while i < c.count {
        let ch = c[i]
        switch ch {
        case "'", "\"", "`":
            if ch == "`" && !mysql { i += 1; continue }
            i += 1
            while i < c.count {
                if c[i] == "\\" && mysql && ch != "`" { i += 2; continue }
                if c[i] == ch { if i + 1 < c.count && c[i + 1] == ch { i += 2; continue }; break }
                i += 1
            }
        case "-" where i + 1 < c.count && c[i + 1] == "-", "#" where mysql:
            while i < c.count && c[i] != "\n" { i += 1 }
        case "/" where i + 1 < c.count && c[i + 1] == "*":
            i += 2
            while i + 1 < c.count && !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
            i += 1
        case "$" where !mysql:
            var j = i + 1
            while j < c.count && (c[j].properties.isAlphabetic || c[j] == "_" || (c[j].value >= 48 && c[j].value <= 57)) { j += 1 }
            if j < c.count && c[j] == "$" {
                let tag = Array(c[i...j]); var k = j + 1
                while k + tag.count <= c.count && Array(c[k..<k + tag.count]) != tag { k += 1 }
                i = min(k + tag.count - 1, c.count - 1)
            }
        case ";":
            flush(i); start = i + 1
        default: break
        }
        i += 1
    }
    flush(c.count)
    return out
}
