# DBMan

Native macOS SQL browser for PostgreSQL, MySQL/MariaDB and SQLite — SwiftUI + AppKit, design system "Halftone 0.7 · inverted FUI".

## Run
```sh
make run        # debug build + launch (ad-hoc signed; dev passwords in a 0600 file, no Keychain prompts)
make install    # release build signed with your code-signing identity → /Applications (or ~/Applications)
make test       # unit tests; integration tests run when DBMAN_PG_URL / DBMAN_MYSQL_URL (+ *_TLS_URL) are set
make db-up      # local PostgreSQL + MariaDB with the `shop` dataset (Nix), `make db-down` to stop
```
`make install` picks the first "Developer ID Application" or "Apple Development" identity from
`security find-identity -v -p codesigning`, or use `SIGN_IDENTITY="…" make install`. Without one it stops and tells you how to create one.
In the app: Connections window → "Try sample database", paste a connection URL, or drop a .sqlite file.
Requires macOS 26 and Xcode 27 / Swift 6.4.

## Layout
- `Sources/DBCore` — models, `DatabaseSession` actor (read-only lock, staged ChangeSet, commit), drivers (SQLite3 C API, PostgresNIO, MySQLNIO), URL/DSN parser, column stats.
- `Sources/Halftone` — tokens, type, frames, controls, readouts, Canvas instruments (line chart, bars, meters, halftone, radar).
- `Sources/DBMan` — app: shell (top strip, navigator, palette ⌘K, commands), Overview, Table (data/structure/ER/stats, inspector, review & commit), Query (editor, results, Explain diagram, chart), Connections, Settings; AppKit `DataGrid` and TextKit 2 `SQLEditor`.

## Local test servers
`testdb/up.sh` starts PostgreSQL (55432) and MariaDB (53306) via Nix with the `shop` dataset; `testdb/down.sh` stops them.

## Dev hooks (DEBUG builds only, `App/DevHooks.swift`)
`DBMAN_OPEN=sample|<path>|<url>`, `DBMAN_ROUTE=table:<name>|query:<sql>`, `DBMAN_VIEW=0-3`, `DBMAN_AUTORUN=1`, plus state hooks for screenshots (select, stage, review, palette, appearance).
