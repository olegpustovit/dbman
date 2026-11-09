// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DBMan",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "DBMan", targets: ["DBMan"]),
        .library(name: "Halftone", targets: ["Halftone"]),
        .library(name: "DBCore", targets: ["DBCore"]),
        .library(name: "DBStore", targets: ["DBStore"]),
        .library(name: "DBManMCP", targets: ["DBManMCP"]),
        .executable(name: "dbman-mcp", targets: ["dbman-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
    ],
    targets: [
        // Design system: tokens, type, frames, instruments. No app knowledge.
        .target(name: "Halftone", swiftSettings: v5),
        // Data layer: models, drivers, sessions, staged writes.
        .target(
            name: "DBCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            swiftSettings: v5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // DBMan's own SQLite store (settings, connections, layers…). Only sqlite3; migrations are embedded in code.
        .target(
            name: "DBStore",
            resources: [.embedInCode("Migrations/0001_init.sql"), .embedInCode("Migrations/0002_approvals.sql")],
            swiftSettings: v5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // MCP server: tool handlers, permission gate, redaction, prod guard. The app hosts it on a Unix socket (MCPHost).
        .target(
            name: "DBManMCP",
            dependencies: ["DBCore", "DBStore", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: v5
        ),
        // stdio <-> Unix socket byte pipe that agents spawn; holds no credentials.
        .executableTarget(name: "dbman-mcp", dependencies: ["DBStore"], swiftSettings: v5),
        .executableTarget(name: "DBMan", dependencies: ["Halftone", "DBCore", "DBStore", "DBManMCP"], swiftSettings: v5),
        .testTarget(name: "DBCoreTests", dependencies: ["DBCore"], swiftSettings: v5),
        .testTarget(name: "DBManMCPTests", dependencies: ["DBManMCP", "DBCore", "DBStore", "dbman-mcp"], swiftSettings: v5),
        .testTarget(name: "DBStoreTests", dependencies: ["DBStore"], resources: [.copy("Fixtures")], swiftSettings: v5),
    ]
)
