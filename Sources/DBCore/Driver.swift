import Foundation

/// Engine adapter. Implementations: SQLiteDriver, PostgresDriver, MySQLDriver (in Drivers/).
/// All methods may be called from any task; implementations serialise access internally.
public protocol DatabaseDriver: AnyObject, Sendable {
    var engine: Engine { get }
    /// Runs one or more statements; returns the result of the last statement that produced rows (or rowsAffected).
    func execute(_ sql: String, limit: Int) async throws -> QueryResult
    /// Streams the rows of a single SELECT in pages. The stream ends after a page with `isLast == true`.
    func stream(_ sql: String, pageSize: Int) -> AsyncThrowingStream<RowPage, Error>
    /// Full schema introspection for the current database/schema.
    func schema() async throws -> SchemaSnapshot
    /// EXPLAIN (ANALYZE where supported) as a tree; nil if the engine cannot.
    func explain(_ sql: String, analyze: Bool) async throws -> PlanNode?
    /// Cancels the statement currently running (best effort).
    func cancelCurrent() async
    func close() async
}

public extension DatabaseDriver {
    func execute(_ sql: String) async throws -> QueryResult { try await execute(sql, limit: 10_000) }
}

/// Quote an identifier for the given engine.
public func quoteIdent(_ name: String, _ engine: Engine) -> String {
    switch engine {
    case .mysql: return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    default: return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
