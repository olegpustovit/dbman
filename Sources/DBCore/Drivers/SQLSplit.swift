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

/// One lexical token of a statement. Strings and comments are skipped (never tokens); quoted identifiers are tokens with their quotes removed.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Sendable { case word, quoted, number, punct }
    public var kind: Kind
    public var text: String
    public var range: Range<String.Index>
    public var isIdentifier: Bool { kind == .word || kind == .quoted }
    public func isWord(_ w: String) -> Bool { kind == .word && text.caseInsensitiveCompare(w) == .orderedSame }
    public func isPunct(_ p: Character) -> Bool { kind == .punct && text == String(p) }
}

/// Tokenizer for identifier analysis (redaction, view expansion). Same quoting rules as `splitStatements`; string literals,
/// comments and dollar quotes are dropped, `"x"`/`` `x` `` become `.quoted`. shortcut: nested /* */ comments are not nested (an over-read, never a miss).
public func sqlTokens(_ sql: String, mysql: Bool = false) -> [SQLToken] {
    var out: [SQLToken] = []
    var i = sql.startIndex
    let end = sql.endIndex
    func at(_ j: String.Index) -> Character? { j < end ? sql[j] : nil }
    func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
    while i < end {
        let ch = sql[i], start = i, next = sql.index(after: i)
        if ch.isWhitespace { i = next; continue }
        if (ch == "-" && at(next) == "-") || (ch == "#" && mysql) {
            while i < end && sql[i] != "\n" { i = sql.index(after: i) }
        } else if ch == "/" && at(next) == "*" {
            i = sql.index(next, offsetBy: 1, limitedBy: end) ?? end
            while i < end && !(sql[i] == "*" && at(sql.index(after: i)) == "/") { i = sql.index(after: i) }
            i = sql.index(i, offsetBy: 2, limitedBy: end) ?? end
        } else if ch == "'" || ch == "\"" || ch == "`" {
            var text = "", j = next
            while j < end {
                if sql[j] == "\\" && mysql && ch != "`" { j = sql.index(j, offsetBy: 2, limitedBy: end) ?? end; continue }
                if sql[j] == ch {
                    let n = sql.index(after: j)
                    if at(n) == ch { text.append(ch); j = sql.index(after: n); continue }
                    break
                }
                text.append(sql[j]); j = sql.index(after: j)
            }
            i = j < end ? sql.index(after: j) : end
            if ch != "'" { out.append(SQLToken(kind: .quoted, text: text, range: start..<i)) }
        } else if ch == "$" && !mysql, let close = sql[next...].firstIndex(where: { !($0.isLetter || $0.isNumber || $0 == "_") }), at(close) == "$", !(sql[next..<close].first?.isNumber ?? false) {
            let tag = String(sql[start...close])
            let after = sql.index(after: close)
            i = sql.range(of: tag, range: after..<end)?.upperBound ?? end
        } else if ch.isLetter || ch == "_" {
            while i < end && isWordChar(sql[i]) { i = sql.index(after: i) }
            out.append(SQLToken(kind: .word, text: String(sql[start..<i]), range: start..<i))
        } else if ch.isNumber {
            while i < end && (isWordChar(sql[i]) || sql[i] == ".") { i = sql.index(after: i) }
            out.append(SQLToken(kind: .number, text: String(sql[start..<i]), range: start..<i))
        } else {
            i = next
            out.append(SQLToken(kind: .punct, text: String(ch), range: start..<i))
        }
    }
    return out
}
