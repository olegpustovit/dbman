# DBMan v2 — rules for every implementer agent

You are implementing one phase of DBMan v2. Read before coding:
- `docs/v2/SPEC.md` — single source of truth (§1 features, §2 MCP surface, §6 store, §7 plan). Use its names, tool names, numbers and copy verbatim.
- `docs/v2/PONYTAIL.md` — coding rules, level **full**. Mandatory. The reviewer rejects violations.
- `docs/v2/boards/*.dc.html` — the approved UI design (HTML/CSS templates; read the markup + `renderVals()` for copy, layout, states). `canvas.json` maps boards. The design system for SwiftUI already exists in `Sources/Halftone` — use it, never invent styles.
- `README.md` and the code you touch.

## Hard rules
1. **Ponytail:** smallest complete change. Reuse v1 code (SQLiteDriver C API, ChangeSet, ReviewSheet, DataGrid, Halftone instruments, ConnectionURL, SQLSplit, DevHooks). No speculative options/abstractions/protocols-with-one-impl. No new dependency except `modelcontextprotocol/swift-sdk` (P1). Non-trivial logic gets a small test. Known limits get `// shortcut: <limit>, <when to upgrade>`.
2. **Agents never write to a real database.** No WRITE/DDL permission level exists. Agent writes go only to their own overlay layer in the DBMan store.
3. **No Keychain prompts in dev.** DEBUG builds use the existing dev secrets file path (see how v1 does it in AppModel / DevHooks). Never call Keychain APIs from tests.
4. **Never capture the user's screen.** Screenshots only of DBMan's own window: launch in background (`open -g -n dist/DBMan.app` with env vars via `--env` or DevHooks), find the window id via `CGWindowListCopyWindowInfo` (owner "DBMan"), capture with `screencapture -o -x -l <id> out.png`. Never `screencapture` without `-l`. Quit the app afterwards (`pkill -x DBMan`). Put screenshots in the session scratchpad given in your prompt, not in the repo.
5. Do not touch the user's real store/settings: always run the app and tests with `DBMAN_STORE=<scratch path>` once it exists.
6. Build must stay green: `swift build` and `swift test` pass before you finish. Swift 6.4 / macOS 26, language mode v5 like the other targets.
7. Do NOT commit or push. Leave changes in the working tree; the reviewer commits.
8. Final report (≤ 25 lines): files added/changed with line counts, what works (with the test/screenshot evidence), what you skipped and why, risks. No marketing.
