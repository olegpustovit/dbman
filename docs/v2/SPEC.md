# DBMan v2 — Agents, MCP, configurable dashboards, schema map, icon

Single source of truth for every v2 board. Use these names, tool names, numbers and copy verbatim so boards agree.
The dataset everywhere is the `shop` Postgres DB (customers 2,400 · products 240 · orders 48,000 · order_items 168,214 · invoices 9,812 · events 61,532),
plus `analytics` (PROD, read-only) and `notes.sqlite`. FKs: orders.customer_id→customers.id, order_items.order_id→orders.id,
order_items.product_id→products.id, invoices.order_id→orders.id, events.customer_id→customers.id (events has NO declared FK in `analytics` → shown as INFERRED).
Add for the schema map: `categories` (18) products.category_id→categories.id, `addresses` (3,120) addresses.customer_id→customers.id,
`refunds` (412) refunds.invoice_id→invoices.id, `coupons` (64) and junction `order_coupons` (order_id, coupon_id), `audit_log` (1.2M, no FKs, isolated).

## 1. What v2 adds
1. **DBMan MCP server (stdio).** Bundled binary `DBMan.app/Contents/Helpers/dbman-mcp`. Agents launch it over stdio.
   The shim does not hold credentials: it connects to the running app over a Unix socket
   (`~/Library/Application Support/DBMan/mcp.sock`), and launches DBMan in the background (`open -g -j`) if it isn't running.
   So: passwords stay in DBMan's Keychain/file store, every call is visible in the app, and approvals happen in the app UI.
2. **Agents window** (menu bar: `Agents ▸ Connect an Agent…` ⌘⇧A, plus a toolbar "AGENTS // 2 LIVE" chip).
   Platforms: Claude Code, Claude Desktop, Codex, Cursor, OpenCode, VS Code (Copilot), Zed, Grok, Antigravity, Windsurf, "Other (copy JSON)".
   Each row: detected? (found `~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json`, …) · INSTALLED / NOT_INSTALLED / NEEDS_UPDATE · scope (User / Project …path) · CONNECT button.
   CONNECT writes the platform's native config (Claude Code runs `claude mcp add dbman -s user -- <path> --stdio`), shows a diff preview first, then a
   "VERIFY" step that waits for the agent's first `initialize` handshake (live: "WAITING FOR HANDSHAKE… → CONNECTED // claude-code 2.4.1").
3. **Agentpack integration** (github.com/olegpustovit/agentpack — pins skills, plugins and MCP servers per project in `agentpack.toml` + `pack.lock`
   and stages them for Claude Code, Cursor, OpenCode, Codex, Grok, Antigravity). If `agentpack` is on PATH, the Agents window shows an
   **AGENTPACK** section: pick a project folder → "Add DBMan to agentpack.toml" (runs `agentpack mcp add dbman --command <path> --args --stdio`)
   → `agentpack sync` (MCP only — no skill; the MCP tool descriptions carry the guidance) → one definition reaches every agent; lock status shown
   (`command` launcher → `unpinnable`, that's expected, explain it in one line). Launch buttons: `agentpack claude`, `agentpack codex`, … open in Terminal at that project.
4. **Agents never write to a database. Ever.** (user decision) Permissions per agent × connection have three levels only:
   `OFF` · `READ` (SELECT/EXPLAIN/schema/stats) · `OVERLAY` (READ + may write into its own layer of the DBMan store, see §1.10).
   Defaults: every connection → OVERLAY, PRODUCTION → READ (OVERLAY opt-in). There is no WRITE or DDL level for agents; only a human
   can promote overlay items to the real database (APPLY TO DATABASE → the v1 Review sheet → COMMIT ⌘↩), or export them as a migration .sql.
   **Sensitive columns are hidden from agents by default** (user decision): columns matching email/phone/ssn/address/name/token/password/iban/dob
   are auto-marked on first schema load, agents get `«redacted»` (COUNT and other numeric aggregates still work), the human can unmark per column;
   the Permissions pane lists them as "AUTO // 7 COLUMNS HIDDEN". statement timeout (default 15 s; PROD 5 s), row cap (default 500 rows per call, cursor for more),
   and a prod guard: on PRODUCTION every agent query is EXPLAINed first; estimated cost > 1e6 or seq scan on >1M rows → blocked with reason.
5. **Agent activity** — a live feed inside the workspace (right inspector tab "AGENTS") and in the Agents window: every tool call with
   client name, tool, args summary, duration, rows, status. Pending approvals (credentials, prod-guard overrides) raise a sheet in the relevant workspace window + a notification + Dock badge.
6. **Configurable dashboards.** The fixed Overview becomes the default dashboard ("Overview // default"). Any dashboard is a 12-column grid of widgets.
   Edit mode (⌘E): drag/resize on an 8 pt grid, component library drawer, widget inspector (data: SQL or table+aggregation, encoding, format, thresholds),
   dashboard variables (time range, filters bound to `:range`, `:status`), auto-refresh (off / 30 s / 1 m / 5 m), duplicate, export JSON.
   Dashboards live in the DBMan store (§1.10), not in a project folder: each agent's dashboards sit in that agent's layer; the human's in the BASE layer
   ("MINE"). Export/import JSON stays as a file action.
7. **AI-built dashboards.** Two entry points: (a) in-app "GENERATE WITH AGENT" in the empty/new-dashboard state → picks a connected agent
   (or copies a prompt to the clipboard) ; (b) the agent calls `dashboard.create` itself. Either way the result arrives as a **proposal**: a ghost
   preview with every widget's SQL inspectable, per-widget accept/reject checkboxes, "ACCEPT 7 OF 8", "ASK FOR CHANGES". Widgets whose query fails
   validation are shown in alert state before accept. Agents only use the component catalog (`dashboard.components` returns the JSON schema), never raw HTML.
8. **Schema map** (new route `SCHEMA MAP` ⌘4 in the navigator, also "Open in schema map" from any table). Flexible ER canvas:
   - layouts: **LAYERED** (FK direction, parents left), **CLUSTERS** (grouped by schema/domain box, user-named), **FOCUS** (selected table centre, N hops: 1/2/3), **FREE** (manual, pinned positions saved per connection);
   - detail: NAMES / KEYS (PK+FK columns) / ALL COLUMNS, and row-count halftone bar on each card;
   - edges: crow's-foot cardinality, declared = solid ink, INFERRED (name match `customer_id`→`customers.id`, type match) = dashed cobalt with "ACCEPT AS RELATION" (stored as virtual FK, never DDL);
   - **PATH**: pick two tables → highlight the join path and offer "COPY JOIN SQL" / "OPEN AS QUERY";
   - filter field (fuzzy), hide junction tables, hide isolated tables, minimap, zoom 25–400 %, keyboard: arrows move selection along edges, Space = focus, ⌘F filter, F = fit, 1–4 layouts;
   - export: PNG, SVG, Mermaid, DBML; "Explain this schema" sends `schema.graph` to the agent.
10. **DBMan store — per-agent overlays** (user decision: "dbman needs its own store with overlayed stuff… per agent store").
   DBMan keeps its own local store (`~/Library/Application Support/DBMan/store.sqlite`, one per connection namespace). It is a stack of layers over the
   read-only database, like transparent sheets:
   `DATABASE (read-only, never touched by agents)` ← `MINE (the human's layer)` ← `claude-code` layer ← `codex` layer ← …
   What a layer holds (all "overlay objects"): virtual views (named SELECTs DBMan expands as CTEs when a query references them),
   virtual relations (accepted inferred FKs), row patches (UPDATE/INSERT/DELETE recorded by primary key, shown merged over real rows in the grid
   with a cobalt layer mark, never sent to the DB), computed columns, column notes/descriptions, saved queries, dashboards.
   Each agent writes ONLY to its own layer and reads DATABASE + MINE + its own layer. The human sees a **layer switcher** (like Figma pages / git
   branches): toggle visibility of each layer, compare a layer to the database (diff), **ADOPT** items into MINE (per item or all), **DISCARD**
   a layer, **APPLY TO DATABASE** (human only → review sheet with generated SQL), **EXPORT MIGRATION**. Conflicts: if a patched row changed in the
   database since the patch, the patch shows STALE with both values.
   Because agents can't harm the database, overlay writes need no approval sheet — approvals are only for: adding a connection (credentials),
   prod-guard overrides, and human promotion to the database.
9. **App icon** (v1 had none). macOS 26 icon: layered (Icon Composer: background, mid, foreground) so it works in Default, Dark, Clear and Tinted modes.

## 2. MCP surface (server name `dbman`, protocol 2025-06-18, stdio)
Tools (namespaced by dot; every tool takes `connection` = name or id, except `connections.*`):
- `connections.list` → name, engine, env tag, status, permission for *this* agent
- `connections.add` {url | fields, name, env} → never accepts a password inline: DBMan shows a **secure credential sheet** to the human ("claude-code wants to add `billing-replica` — enter password"), returns id when done
- `connections.test` · `connections.remove` (approval)
- `schema.tables` · `schema.describe` {table} (columns, types, PK, FKs, indexes, row estimate) · `schema.graph` (nodes+edges incl. inferred) · `schema.search` {text}
- `query.run` {sql, params, limit≤cap, cursor, layer?} → columns, rows, truncated, cursor, ms. Always read-only against the DB; virtual views and the agent's row patches are applied on top. A write statement returns `WRITE_REDIRECTED` with a hint to use overlay.*
- `query.explain` {sql} → plan tree + cost · `query.sample` {table, n} · `stats.column` {table, column} (distinct, nulls, histogram)
- `overlay.status` (my layer: counts, stale items) · `overlay.patch_rows` {table, patches by PK} · `overlay.diff` {table?} · `overlay.reset`
- `views.list` · `views.create` / `views.replace` {name, sql} / `views.drop` → virtual views in the agent's layer, no DDL, no approval
- `relations.add` {from, to} → virtual relation in the agent's layer · `notes.set` {table, column?, text}
- `saved.list` / `saved.save` {name, sql} — saved queries, in the agent's layer
- `dashboard.components` (catalog + JSON schema) · `dashboard.list` · `dashboard.get` · `dashboard.create` {spec} · `dashboard.update` {id, ops: JSON-patch} → written to the agent's layer; the human sees it as NEW in that layer and ADOPTs it into MINE
- `ui.open` {route: table/query/dashboard/schema-map, selection} → brings DBMan to front at that place ("show me")
Resources: `dbman://connections`, `dbman://{conn}/schema`, `dbman://{conn}/tables/{t}`, `dbman://dashboards/{id}`.
Prompts: `build-dashboard`, `explain-schema`, `investigate-table`, `write-migration-review`.
Errors are typed and human-readable: `PERMISSION_DENIED (READ on analytics; needs OVERLAY)`, `BLOCKED_BY_PROD_GUARD (seq scan on events, 61,532 rows est. cost 2.1e6)`, `NEEDS_APPROVAL (pending in DBMan)`, `APP_LOCKED`.

### Dashboard spec (what agents write)
```json
{"version":1,"title":"Revenue // last 30 d","connection":"shop",
 "variables":[{"name":"range","type":"timeRange","default":"30d"},{"name":"status","type":"enum","sql":"select distinct status from orders"}],
 "refresh":"1m",
 "widgets":[{"id":"w1","type":"kpi","title":"Revenue","x":0,"y":0,"w":3,"h":2,
   "query":"select sum(total) as value from orders where created_at > now() - :range",
   "format":{"unit":"USD","compact":true},"compare":"previous_period"}]}
```
Component catalog (type ids): `kpi`, `kpi.spark`, `line`, `area.stacked`, `bars`, `bars.stacked`, `bars.horizontal` (top-N), `histogram`,
`heatmap.hour_week`, `heatmap.calendar`, `scatter`, `funnel`, `meter` (segmented, v1 style), `halftone.distribution` (v1 instrument), `table`,
`status.feed` (latest rows, live), `radar`, `text` (markdown note), `er.mini` (schema neighbourhood). Each has required encodings (e.g. line: x time, y numeric, series optional).

## 3. Flows to show (each must be ≤ 3 decisions; Hick, Fitts, Tesler, Doherty < 400 ms feedback)
F1 Connect Claude Code: ⌘⇧A → row "Claude Code // DETECTED" → CONNECT → diff preview → APPLY → "WAITING FOR HANDSHAKE" → CONNECTED.
F2 Agent adds a connection: agent calls connections.add → DBMan secure credential sheet → human types password → TEST → SAVE → agent gets id.
F3 Agent patches 3 rows in its layer of `shop`: grid shows them merged with a CC layer mark → human opens layer diff → ADOPT into MINE, or APPLY TO DATABASE (review sheet, COMMIT ⌘↩), or DISCARD with a note the agent receives.
F4 Agent blocked on PROD: feed row in alert, reason, "ALLOW ONCE" / "RAISE TIMEOUT" / "KEEP BLOCKED".
F5 Generate dashboard: empty dashboard → GENERATE WITH AGENT → proposal → accept 7 of 8 → edit one widget → ADOPT into MINE.
F6 Explore relations: Schema map → FOCUS orders, 2 hops → PATH customers→products → OPEN AS QUERY.
F7 Agentpack: Agents ▸ Agentpack → choose ~/projects/shop → ADD → SYNC → 6 agents staged.

## 4. Gap audit (v1 → v2), to list on the brief board with fix + where it's designed
G1 No whole-schema relational view (only per-table Relations tab) → Schema map.
G2 Overview is fixed; no user dashboards → configurable dashboards + library.
G3 No icon → icon board.
G4 Agent sees credentials? → never; secure credential sheet, socket bridge.
G5 App not running when agent calls → shim launches it hidden; tray-less, shows in Dock only while an approval is pending.
G6 Multiple agents at once → each MCP client is a named session (clientInfo), its own row in the feed, own permission row.
G7 Runaway queries on PROD → timeout, row cap, EXPLAIN guard.
G8 PII leakage to model providers → sensitive columns hidden from agents BY DEFAULT (auto-marked by name), human can unmark per column.
G9 Databases without FKs (SQLite, legacy MySQL) → inferred relations, accept as virtual FK.
G10 Dashboards break on schema drift → widget error state "column `total` not found" + "ASK AGENT TO FIX" (sends dashboard.get + error).
G11 Agent output scattered/unattributed → per-agent layers in the DBMan store; adopt, diff, discard; dashboards export/import as JSON.
G12 Approvals missed when window is background → notification + Dock badge + menu bar item count; approvals expire after 10 min (agent gets NEEDS_APPROVAL_TIMEOUT).
G13 Large results blow agent context → row cap + cursor + `truncated:true`, column projection hint.
G14 Agent undo → nothing to undo in the database: agents only write overlay layers; DISCARD LAYER or per-item revert; the layer keeps history.
G15 Charts inaccessible → every widget has "VIEW AS TABLE" and VoiceOver summary ("Revenue, 30 days, up 12 %").
G16 First-run doesn't mention agents → Connections window gets a third first-run card "CONNECT AN AGENT".
G17 Schema map unusable at 200+ tables → clusters collapsed by default, filter, focus mode, minimap, lazy column loading.
G18 Agent-written SQL quality → every proposal shows SQL + EXPLAIN cost badge before accept.

## 5. Design system (do not invent new styles — reuse the canvas's Halftone 0.7 "inverted FUI")
Read `project/Connect.dc.html`, `project/Overview.dc.html`, `project/Table.dc.html` (interactive state pattern: `this.state`, `this.setState`, `onClick="{{fn}}"`) and `project/UIKit.dc.html` before writing.
Copy the token block (L/D objects, themeVars, CAPS, cap, capDim, box, boxL, boxPrimary, field) exactly. White paper, ink, ONE cobalt accent
`#2F2FE4` (dark `#8A8AFF`), amber = production/caution, alert red = errors only. `//` caps labels, huge light readouts, mono only for data/SQL,
3 px corners, 1 px lines, 8 px dot-grid backdrop, desktop density (row height 22–24 px, 11–13 px text). No crosshairs/brackets, no gradients, no
online dots, no emoji, no new colours. Windows have macOS traffic lights as in Connect.dc.html. Every board supports the `dark` prop.
Charts drawn with inline SVG in the Halftone style (thin ink lines, cobalt for the one highlighted series, halftone dot fills, tabular numbers).
Agent platform marks: do NOT draw vendor logos; use a 2-letter monogram tile in ink outline (CC, CD, CX, CU, OC, VS, ZD, GK, AG, WS).

G19 Overlay drift → a row patch whose base row changed in the DB shows STALE with both values; dashboards/views referencing dropped columns show error state.
G20 Agent layers piling up → layer list shows last activity, size; auto-archive layers untouched for 30 days (never auto-delete).

## 6. DBMan's own data lives in one SQLite file — and DBMan can open it (user request)
"DBMan's data surface gets bootstrapped from a SQLite db — all settings and everything — and we can introspect it with DBMan too."
- File: `~/Library/Application Support/DBMan/dbman.sqlite` (WAL, `PRAGMA user_version` = schema version, `application_id` = 0x44424D4E "DBMN").
  Replaces v1's `connections.json` + `@AppStorage` (migrated once on first v2 launch, originals renamed `*.v1-backup`).
- **Never in the file:** passwords. `connections.secret_ref` points at the Keychain item (release) or the dev secrets file (DEBUG).
- Schema (STRICT tables, FKs on; every table has `created_at`/`updated_at` unix ms):
  - `meta(key PK, value)` — install_id, app_version, migrated_from
  - `settings(key PK, value JSON, updated_at)` — appearance, density, page_size, relative_dates, prod_guard_cost, prod_guard_rows, timeout_ms, row_cap, approval_ttl_s, redaction_patterns
  - `connections(id PK, name, engine, host, port, database, user, ssl_mode, ssl_root_cert, env CHECK in local/staging/production/system, file_path, secret_ref, last_opened_at)`
  - `agents(id PK, client_name, platform, version, config_path, installed_via CHECK in native/agentpack/manual, first_seen, last_seen)`
  - `permissions(agent_id → agents, connection_id → connections, level CHECK in ('off','read','overlay'), timeout_ms, row_cap, PK(agent_id, connection_id))`
  - `sensitive_columns(connection_id, table_name, column_name, source CHECK in auto/user, hidden, PK(...))`
  - `layers(id PK, connection_id, owner CHECK in human/agent, agent_id NULL, name, visible, position, archived_at)`
  - `overlay_items(id PK, layer_id → layers, kind CHECK in view/relation/row_patch/note/saved_query/dashboard/computed_column, name, payload JSON, base_hash, status CHECK in active/stale/adopted/discarded)`
  - `row_patches(item_id → overlay_items, table_name, pk JSON, op CHECK in insert/update/delete, before JSON, after JSON)`
  - `activity(id PK, ts, agent_id, connection_id, tool, args_summary, ms, rows, status CHECK in ok/overlay/blocked/denied/error, error)` — append-only, 30-day retention
  - `approvals(id PK, kind CHECK in credentials/prod_guard/apply, agent_id, connection_id, payload JSON, status CHECK in pending/approved/rejected/expired, expires_at, decided_at)`
  - `query_history(id PK, connection_id, source CHECK in human/agent, agent_id, sql, ms, rows, ts)`
  - `schema_cache(connection_id PK, snapshot JSON, fetched_at)` · `map_layouts(connection_id, layout, positions JSON)`
  - Views for humans: `v_agent_activity_daily`, `v_layer_summary`, `v_pending_approvals`, `v_dashboard_widgets` (json_each over dashboard specs).
- **Bootstrap sequence** (app launch, < 50 ms budget): open/create → `quick_check` → run embedded migrations (`Resources/Migrations/NNNN_name.sql`, each in a transaction, bump user_version) → import v1 files if present → seed defaults (settings rows, one MINE layer per connection, the internal connection row, "Agent activity" dashboard) → load into `@Observable AppStore` → start MCP socket. Corrupt file → move to `dbman.corrupt-<ts>.sqlite`, recreate, offer restore from backup. Daily `VACUUM INTO backups/dbman-YYYY-MM-DD.sqlite`, keep 7.
- **Introspection:** the Connections window always lists **DBMan // internal** (env tag SYSTEM, ink-outlined, pinned at the bottom). Opening it gives the normal workspace on dbman.sqlite: Table browser, Query editor, Schema map of DBMan's own schema, and its own default dashboard "Agent activity" (calls/hour, blocked by agent, layer sizes, pending approvals) — built from the same component library. Dogfooding by construction.
  Read-only by default; "UNLOCK INTERNAL STORE" (advanced, ⌥ click) allows edits through the normal review sheet. The app watches the file (sqlite update hook in-process, `DispatchSource` file events for external edits by sqlite3/another tool) and reloads affected state live — you can change a setting with SQL and the UI updates.
- **Agents can never see it.** The internal connection is not listed by `connections.list`, can't get a permission row (CHECK + code), and `query.run` on it returns PERMISSION_DENIED. Reason: it holds the permission table — an agent must not be able to read or grant its own rights (gap G21).
- Dev hooks: `DBMAN_STORE=/tmp/x.sqlite` (throwaway store), `DBMAN_OPEN=internal`. Make: `make store-open` (opens internal in DBMan), `make store-sql` (`sqlite3` shell on it), `make store-reset` (backup + recreate).

G21 Agent privilege escalation via DBMan's own store → internal connection invisible to MCP, no permission rows possible, enforced in code and by CHECK.
G22 Settings scattered (UserDefaults + JSON) and not inspectable → one SQLite store, introspectable in DBMan, migrations, daily backups.

## 7. Implementation plan (v2) — build order, files, tools, tests
Principles (ponytail): reuse v1 (SQLiteDriver C API, ChangeSet, ReviewSheet, DataGrid, Halftone instruments); no new dependency unless it removes more code than it adds.
Only new dependency: `modelcontextprotocol/swift-sdk` (official MCP Swift SDK, Server + stdio/custom transports) — saves writing JSON-RPC + protocol lifecycle by hand.
New targets: `DBStore` (library: schema, migrations, typed repos, AppStore observable glue stays in app), `DBManMCP` (library: tool handlers, permission gate, redaction, prod guard — pure, testable), `dbman-mcp` (executable, ~150 lines: stdio ⇄ Unix socket pipe + background app launch), tests `DBStoreTests`, `DBManMCPTests`.
Phases (each ends with tests green + screenshots via DevHooks):
- **P0 Store** (DBStore): migrations runner, schema 0001, repos, v1 import, backups, file watcher, internal connection + read-only lock, AppModel/Settings switched from JSON/@AppStorage to store. Tests: migrate empty → v_latest, v1 import fixtures, corrupt-file recovery, CHECK constraints, agents-can't-see-internal.
- **P1 MCP core** (DBManMCP + dbman-mcp): socket server in app (`MCPHost` actor), session per client (clientInfo → agents row), tools connections.*/schema.*/query.*/stats.column/ui.open, permission gate, redaction, row cap + cursor, timeouts, prod guard (EXPLAIN cost parse per engine), activity rows. Tests: golden tool I/O per tool, redaction, guard thresholds; conformance with `npx @modelcontextprotocol/inspector --cli`; live smoke: `claude mcp add dbman -- …/dbman-mcp --stdio` then `claude -p "list my dbman connections"`.
- **P2 Agents window**: platform detectors + config writers (JSON merge: Claude Code via `claude mcp add`, Claude Desktop, Cursor, VS Code, Zed, Windsurf, Antigravity; TOML: Codex, Grok; OpenCode JSON), diff preview, backup + undo, handshake verify; agentpack panel shelling out to `agentpack mcp add` / `agentpack sync` / launchers; Permissions + Activity panes on store tables. Tests: golden config files per platform (before/after), idempotent re-apply, uninstall.
- **P3 Overlay engine**: layers + overlay_items repos, row-patch merge into DataGrid pages (by PK), virtual views expanded as CTEs (name resolution via SQL tokenizer from SQLSplit), virtual relations merged into SchemaSnapshot, stale detection (base_hash of row), adopt/discard/apply (→ ChangeSet → v1 ReviewSheet), export migration. Tools overlay.*/views.*/relations.add/notes.set/saved.*. Tests: merge correctness, CTE expansion incl. shadowing, stale, apply SQL per engine.
- **P4 Dashboards**: DashboardSpec Codable + JSON schema (served by dashboard.components), 19 widget views in Halftone (Canvas), grid editor (drag/resize snap), inspector, variables + refresh, proposal review, drift errors. Tools dashboard.*. Tests: spec validation, widget encoding validation, grid packing.
- **P5 Schema map**: layout engines (layered by FK depth with crossing reduction, clusters, focus BFS hops, free + saved positions in map_layouts), Canvas renderer with crow's feet, path finder (BFS on FK graph), inferred relations (name/type match), export SVG/PNG/Mermaid/DBML. Tests: layout no-overlap property tests, path finder, exporters golden.
- **P6 Approvals & notifications**: credential sheet (connections.add), prod-guard override, approvals table + expiry, UNUserNotification + Dock badge + Agents menu, PAUSE ALL AGENTS.
- **P7 Icon & packaging**: Icon Composer `.icon` from icon-dbman.svg layers (actool → Assets.car), fallback `.icns` via iconutil; bundle.sh copies `dbman-mcp` into Contents/Helpers and signs it (inside-out codesign); symlink ~/.local/bin/dbman-mcp maintained on launch.
Tooling: make targets `mcp` (build helper), `mcp-inspect` (MCP Inspector against helper), `mcp-smoke` (Claude Code CLI round-trip), `store-open`, `store-sql`, `store-reset`, `icon`. DevHooks additions: DBMAN_STORE, DBMAN_OPEN=internal, DBMAN_ROUTE=schema-map|dashboard:<id>|agents, DBMAN_LAYER=<agent>.
Agents to build it: Sonnet for P0, P1, P3, P4, P5 (logic-heavy); Haiku for config writers + golden fixtures (P2), migrations SQL, icon pipeline, make targets; one Sonnet QA pass per phase with screenshots. Order: P0 → P1 → (P2 ∥ P3) → (P4 ∥ P5) → P6 → P7. Estimated size: ~9–11k lines Swift incl. tests.
