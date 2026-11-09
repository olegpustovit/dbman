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
- `Sources/DBStore` — DBMan's own SQLite store (connections, settings, approvals, agent layers); only sqlite3, migrations embedded in code.
- `Sources/DBManMCP` — MCP tool handlers, permission gate, redaction, prod guard; hosted by the app on a Unix socket.
- `Sources/dbman-mcp` — stdio shim agents spawn (`Contents/Helpers/dbman-mcp`); it holds no credentials and forwards to the app.

## v2: MCP, Agents, store
Agents reach DBMan through MCP. Agents never write to a real database: their writes land in their own overlay layer in the DBMan store.
- `make mcp` builds the helper; `make mcp-inspect` lists its tools with the MCP Inspector; `make mcp-smoke` runs a Claude Code round trip with a temporary config.
- Helper path: `/Applications/DBMan.app/Contents/Helpers/dbman-mcp` (the app also keeps `~/.local/bin/dbman-mcp` pointing at it on launch). Add it to Claude Code with:
  `claude mcp add dbman -s user -- /Applications/DBMan.app/Contents/Helpers/dbman-mcp --stdio`
- Agents window (Agents toolbar chip): detected agents and their scope, permissions per agent × connection, the activity feed, approvals (credential requests, prod-guard blocks, removals), and PAUSE AGENTS. The app runs in the background (no Dock icon) until a window is open or an approval waits.
- Store: `DBMAN_STORE=<path>` (DEBUG builds) points the app at a scratch store file instead of `~/Library/Application Support/DBMan/dbman.sqlite`. `make store-open` opens the app on the store's internal connection, `make store-sql` opens the store with sqlite3, `make store-reset` backs it up and deletes it.

## Local test servers
`testdb/up.sh` starts PostgreSQL (55432) and MariaDB (53306) via Nix with the `shop` dataset; `testdb/down.sh` stops them.

## Dev hooks (DEBUG builds only, `App/DevHooks.swift`)
`DBMAN_OPEN=sample|internal|<path>|<url>`, `DBMAN_ROUTE=table:<name>|query:<sql>|schema-map|dashboard:<id or title>[:edit[:<widget>]]`, `DBMAN_VIEW=0-3`, `DBMAN_AUTORUN=1`, plus state hooks for screenshots (select, stage, review, palette, appearance).
v2 hooks: `DBMAN_OPEN=internal` opens the store's own connection; `DBMAN_LAYER=<agent>[:diff|:apply]` opens the Store panel on that agent's layer; `DBMAN_AGENTS=<platform id>|perms|activity|agentpack|other` opens the Agents window on that section, with `DBMAN_AGENT_HOME=<dir>` as the fake HOME for agent detection; `DBMAN_SNAPSHOT=<png>` (with optional `DBMAN_SNAPSHOT_WINDOW=<title>`) writes the window's own pixels after 6 s, with no screen capture.
