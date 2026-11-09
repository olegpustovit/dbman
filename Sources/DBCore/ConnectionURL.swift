import Foundation

/// Parses pasted connection strings (URLs, libpq DSNs, psql commands, SQLite paths) into profiles.
public enum ConnectionURL {
    public static func parse(_ text: String) -> ConnectionProfile? { parseWithPassword(text)?.0 }

    public static func parseWithPassword(_ text: String) -> (ConnectionProfile, String?)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("psql ") { return parsePsql(t) }
        if let r = t.range(of: "://") { return parseURL(t, scheme: t[..<r.lowerBound].lowercased()) }
        if t.contains("=") && !t.hasPrefix("/") && !t.hasPrefix("~") { return parseDSN(t) }
        let exts = ["sqlite", "sqlite3", "db", "db3"]
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("./"), exts.contains((t as NSString).pathExtension.lowercased()) {
            return (sqliteProfile((t as NSString).expandingTildeInPath), nil)
        }
        return nil
    }

    public static func format(_ p: ConnectionProfile) -> String {
        if p.engine == .sqlite { return "sqlite://" + (p.filePath ?? "") }
        var c = URLComponents()
        c.scheme = p.engine == .postgres ? "postgresql" : "mysql"
        c.host = p.host
        if p.port != p.engine.defaultPort { c.port = p.port }
        if !p.user.isEmpty { c.user = p.user }
        c.path = "/" + p.database
        var q: [URLQueryItem] = []
        if p.sslMode != .prefer { q.append(URLQueryItem(name: "sslmode", value: p.sslMode.rawValue)) }
        if let r = p.sslRootCert, !r.isEmpty { q.append(URLQueryItem(name: "sslrootcert", value: r)) }
        if !q.isEmpty { c.queryItems = q }
        return c.string ?? ""
    }

    // MARK: pieces

    private static func sqliteProfile(_ path: String) -> ConnectionProfile {
        ConnectionProfile(name: (path as NSString).lastPathComponent, engine: .sqlite, host: "", filePath: path)
    }

    private static func ssl(_ v: String?) -> SSLMode {
        switch v?.lowercased() {
        case "disable", "disabled", "false": return .disable
        case "require", "required", "true", "verify-ca", "verify_ca", "verify_identity": return v!.lowercased().hasPrefix("verify") ? .verifyFull : .require
        case "verify-full": return .verifyFull
        default: return .prefer
        }
    }

    private static func profile(_ engine: Engine, host: String?, port: Int?, db: String?, user: String?, sslmode: String?, rootCert: String? = nil) -> ConnectionProfile {
        let h = (host?.isEmpty ?? true) ? "localhost" : host!
        let d = db ?? ""
        return ConnectionProfile(name: d.isEmpty ? h : "\(d)@\(h)", engine: engine, host: h, port: port, database: d, user: user ?? "", sslMode: ssl(sslmode), sslRootCert: rootCert.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath })
    }

    private static func parseURL(_ t: String, scheme: String) -> (ConnectionProfile, String?)? {
        if scheme == "sqlite" {
            let path = (String(t.dropFirst("sqlite://".count)).removingPercentEncoding ?? "")
            return path.isEmpty ? nil : (sqliteProfile((path as NSString).expandingTildeInPath), nil)
        }
        let engine: Engine
        switch scheme {
        case "postgres", "postgresql": engine = .postgres
        case "mysql", "mariadb": engine = .mysql
        default: return nil
        }
        guard let c = URLComponents(string: t) else { return nil }
        let q = Dictionary(c.queryItems?.compactMap { i in i.value.map { (i.name.lowercased(), $0) } } ?? [], uniquingKeysWith: { a, _ in a })
        let db = String(c.path.dropFirst()).removingPercentEncoding
        return (profile(engine, host: c.host, port: c.port, db: db, user: c.user, sslmode: q["sslmode"] ?? q["ssl-mode"] ?? q["ssl"], rootCert: q["sslrootcert"] ?? q["ssl-ca"]), c.password)
    }

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, has = false
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "'" || ch == "\"" { quote = ch; has = true }
            else if ch.isWhitespace { if !cur.isEmpty || has { out.append(cur); cur = ""; has = false } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty || has { out.append(cur) }
        return out
    }

    private static func parseDSN(_ t: String) -> (ConnectionProfile, String?)? {
        var kv: [String: String] = [:]
        for tok in tokens(t) {
            guard let i = tok.firstIndex(of: "=") else { return nil }
            kv[String(tok[..<i]).lowercased()] = String(tok[tok.index(after: i)...])
        }
        guard kv["host"] != nil || kv["dbname"] != nil || kv["user"] != nil else { return nil }
        return (profile(.postgres, host: kv["host"], port: kv["port"].flatMap(Int.init), db: kv["dbname"], user: kv["user"], sslmode: kv["sslmode"], rootCert: kv["sslrootcert"]), kv["password"])
    }

    private static func parsePsql(_ t: String) -> (ConnectionProfile, String?)? {
        var host: String?, port: Int?, user: String?, db: String?
        var args = tokens(t).dropFirst()[...]
        while let a = args.popFirst() {
            func val(_ prefix: String) -> String? { a.hasPrefix(prefix) && a.count > prefix.count ? String(a.dropFirst(prefix.count)) : (a == prefix ? args.popFirst() : nil) }
            if a.contains("://") { return parseURL(a, scheme: a.prefix { $0 != ":" }.lowercased()) }
            else if let v = val("-h") ?? val("--host=") { host = v }
            else if let v = val("-p") ?? val("--port=") { port = Int(v) }
            else if let v = val("-U") ?? val("--username=") { user = v }
            else if let v = val("-d") ?? val("--dbname=") { db = v }
            else if !a.hasPrefix("-") { db = a }
        }
        return (profile(.postgres, host: host, port: port, db: db, user: user, sslmode: nil), nil)
    }
}
