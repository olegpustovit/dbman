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
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
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
            resources: [.embedInCode("Migrations/0001_init.sql")],
            swiftSettings: v5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "DBMan", dependencies: ["Halftone", "DBCore", "DBStore"], swiftSettings: v5),
        .testTarget(name: "DBCoreTests", dependencies: ["DBCore"], swiftSettings: v5),
        .testTarget(name: "DBStoreTests", dependencies: ["DBStore"], resources: [.copy("Fixtures")], swiftSettings: v5),
    ]
)
