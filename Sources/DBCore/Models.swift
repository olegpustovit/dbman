import Foundation

// MARK: - Values

/// One cell value, engine-neutral.
public enum Cell: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case bool(Bool)
    case date(Date)
    case blob(Int) // byte count

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var isNumeric: Bool {
        switch self { case .integer, .real: return true; default: return false }
    }
    /// Display string used by grids (formatting of numbers/dates is a view concern; this is the raw form).
    public var display: String {
        switch self {
        case .null: return "null"
        case .integer(let v): return String(v)
        case .real(let v): return abs(v) < 1e15 && (v * 100).rounded() == v * 100 ? String(format: "%.2f", v) : String(v)
        case .text(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return Cell.dateFormatter.string(from: d)
        case .blob(let n): return "<\(n) bytes>"
        }
    }
    public var sqlLiteral: String {
        switch self {
        case .null: return "NULL"
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .text(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .date(let d): return "'" + Cell.dateFormatter.string(from: d) + "'"
        case .blob: return "NULL"
        }
    }
    nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

public struct RowPage: Sendable {
    public var columns: [String]
    public var rows: [[Cell]]
    public var isLast: Bool
    public init(columns: [String], rows: [[Cell]], isLast: Bool) {
        self.columns = columns; self.rows = rows; self.isLast = isLast
    }
}

public struct QueryResult: Sendable {
    public var columns: [String]
    public var rows: [[Cell]]
    public var rowsAffected: Int
    public var elapsedMs: Double
    public var truncated: Bool
    public init(columns: [String] = [], rows: [[Cell]] = [], rowsAffected: Int = 0, elapsedMs: Double = 0, truncated: Bool = false) {
        self.columns = columns; self.rows = rows; self.rowsAffected = rowsAffected; self.elapsedMs = elapsedMs; self.truncated = truncated
    }
}

// MARK: - Schema

public struct ColumnInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var nullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var foreignKey: ForeignKey?
    public init(name: String, type: String, nullable: Bool, defaultValue: String? = nil, isPrimaryKey: Bool = false, foreignKey: ForeignKey? = nil) {
        self.name = name; self.type = type; self.nullable = nullable; self.defaultValue = defaultValue; self.isPrimaryKey = isPrimaryKey; self.foreignKey = foreignKey
    }
}

public struct ForeignKey: Hashable, Sendable {
    public var table: String
    public var column: String
    public var onDelete: String?
    public init(table: String, column: String, onDelete: String? = nil) { self.table = table; self.column = column; self.onDelete = onDelete }
}

public struct IndexInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var columns: [String]
    public var unique: Bool
    public var definition: String
    public var sizeBytes: Int64?
    public init(name: String, columns: [String], unique: Bool, definition: String, sizeBytes: Int64? = nil) {
        self.name = name; self.columns = columns; self.unique = unique; self.definition = definition; self.sizeBytes = sizeBytes
    }
}

public enum TableKind: String, Sendable { case table, view }

public struct TableInfo: Hashable, Sendable, Identifiable {
    public var id: String { schema + "." + name }
    public var schema: String
    public var name: String
    public var kind: TableKind
    public var rowCount: Int64          // exact for SQLite, estimate (reltuples) for Postgres/MySQL
    public var sizeBytes: Int64?
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public init(schema: String, name: String, kind: TableKind, rowCount: Int64, sizeBytes: Int64? = nil, columns: [ColumnInfo] = [], indexes: [IndexInfo] = []) {
        self.schema = schema; self.name = name; self.kind = kind; self.rowCount = rowCount; self.sizeBytes = sizeBytes; self.columns = columns; self.indexes = indexes
    }
    public var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
    /// Tables whose foreign keys point at this one.
    public func referencedBy(in schema: SchemaSnapshot) -> [(table: String, column: String)] {
        schema.tables.flatMap { t in t.columns.compactMap { c in c.foreignKey?.table == name ? (t.name, c.name) : nil } }
    }
}

public struct SchemaSnapshot: Sendable {
    public var serverVersion: String
    public var databaseName: String
    public var tables: [TableInfo]
    public var sizeBytes: Int64?
    public init(serverVersion: String, databaseName: String, tables: [TableInfo], sizeBytes: Int64? = nil) {
        self.serverVersion = serverVersion; self.databaseName = databaseName; self.tables = tables; self.sizeBytes = sizeBytes
    }
    public var totalRows: Int64 { tables.reduce(0) { $0 + $1.rowCount } }
    public func table(_ name: String) -> TableInfo? { tables.first { $0.name == name } }
}

// MARK: - Explain

public struct PlanNode: Sendable, Identifiable, Hashable {
    public let id: UUID
    public var operation: String        // "Hash Join", "Index Scan"
    public var relation: String?        // "orders"
    public var detail: String?          // "using idx_orders_created"
    public var estimatedRows: Double
    public var actualRows: Double?
    public var totalMs: Double?         // inclusive time
    public var selfMs: Double?          // exclusive time
    public var cost: Double
    public var children: [PlanNode]
    public init(operation: String, relation: String? = nil, detail: String? = nil, estimatedRows: Double, actualRows: Double? = nil, totalMs: Double? = nil, selfMs: Double? = nil, cost: Double, children: [PlanNode] = []) {
        self.id = UUID(); self.operation = operation; self.relation = relation; self.detail = detail; self.estimatedRows = estimatedRows; self.actualRows = actualRows; self.totalMs = totalMs; self.selfMs = selfMs; self.cost = cost; self.children = children
    }
}

// MARK: - Connections

public enum Engine: String, Codable, Sendable, CaseIterable {
    case postgres, mysql, sqlite
    public var displayName: String {
        switch self { case .postgres: "PostgreSQL"; case .mysql: "MySQL"; case .sqlite: "SQLite" }
    }
    public var defaultPort: Int { switch self { case .postgres: 5432; case .mysql: 3306; case .sqlite: 0 } }
}

public enum SSLMode: String, Codable, Sendable, CaseIterable { case disable, prefer, require, verifyFull = "verify-full" }

/// `system` is only ever DBMan's own store ("DBMan // internal"); the editor does not offer it.
public enum EnvironmentTag: String, Codable, Sendable, CaseIterable { case local, staging, production, system }

public struct ConnectionProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var engine: Engine
    public var host: String
    public var port: Int
    public var database: String
    public var user: String
    public var filePath: String?          // SQLite
    public var sslMode: SSLMode
    public var sslRootCert: String?       // CA bundle path (libpq sslrootcert)
    public var environment: EnvironmentTag
    public var openReadOnly: Bool
    public var stageWrites: Bool
    public var lastOpened: Date?
    public init(id: UUID = UUID(), name: String, engine: Engine, host: String = "localhost", port: Int? = nil, database: String = "", user: String = "", filePath: String? = nil, sslMode: SSLMode = .prefer, environment: EnvironmentTag = .local, openReadOnly: Bool = false, stageWrites: Bool = true, lastOpened: Date? = nil, sslRootCert: String? = nil) {
        self.id = id; self.name = name; self.engine = engine; self.host = host; self.port = port ?? engine.defaultPort; self.database = database; self.user = user; self.filePath = filePath; self.sslMode = sslMode; self.environment = environment; self.openReadOnly = openReadOnly; self.stageWrites = stageWrites; self.lastOpened = lastOpened; self.sslRootCert = sslRootCert
    }
    /// DBMan's own store (a fixed id, so the window and its workspace survive relaunches).
    public static let internalID = UUID(uuidString: "00000000-0000-0000-0000-00000000DB01")!
    /// Production and the internal store always open read-only until unlocked for the session.
    public var startsReadOnly: Bool { openReadOnly || environment == .production || environment == .system }
}

public enum DBError: LocalizedError, Sendable {
    case connection(String)
    case query(String, code: String? = nil)
    case readOnly
    case cancelled
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .connection(let m): return m
        case .query(let m, let code): return code.map { "\(m) (\($0))" } ?? m
        case .readOnly: return "This session is read-only. Unlock writes for this session first."
        case .cancelled: return "Cancelled"
        case .unsupported(let m): return m
        }
    }
}
