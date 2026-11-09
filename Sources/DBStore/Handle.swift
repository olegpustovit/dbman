import Foundation
import SQLite3

public struct StoreError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Thin synchronous wrapper over one sqlite3 handle. Own helper (not DBCore's driver): that one is async, queue-bound and lives in a target this one must not depend on.
final class Handle {
    private(set) var db: OpaquePointer?
    init(path: String) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw StoreError(message: "Cannot open store \(path): \(msg)")
        }
        db = h
        sqlite3_busy_timeout(h, 2000) // the app's own SQLiteDriver may write the same file (unlocked internal store)
    }
    deinit { sqlite3_close_v2(db) }

    private var error: StoreError { StoreError(message: String(cString: sqlite3_errmsg(db))) }

    /// Runs one or more statements without bindings.
    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    /// Runs one statement. Args: nil, Int, Int64, Bool, String. Returns all rows as Any? (nil, Int64, Double, String).
    @discardableResult
    func query(_ sql: String, _ args: [Any?] = []) throws -> [[Any?]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw error }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, n)
            case let v as Bool: sqlite3_bind_int64(st, n, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT
            default: throw StoreError(message: "Unsupported bind \(String(describing: a))")
            }
        }
        var out: [[Any?]] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw error }
            out.append((0..<sqlite3_column_count(st)).map { i in
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: return sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: return sqlite3_column_double(st, i)
                case SQLITE_NULL: return nil
                default: return String(cString: sqlite3_column_text(st, i))
                }
            })
        }
    }

    func scalar(_ sql: String, _ args: [Any?] = []) throws -> Any? { try query(sql, args).first?.first ?? nil }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
