# DBMan — phase 2 brief (feature agents)

Native macOS SQL browser. SwiftPM at /Users/snowbear/projects/dbman, macOS 26, Swift language mode v5.
Design = v7 "Inverted FUI": white paper, monochrome ink frames, caps `TITLE // meta` labels, top strip, number rail,
tracker grid, huge light readouts, one cobalt signal (live/now/selected), amber/alert only for attention.
Spec: /private/tmp/claude-501/-Users-snowbear-projects/6dab5d5e-b5e1-4822-9a9e-4e1bc764dce5/scratchpad/v7-spec.md
Artboards (exact look, inline CSS): /private/tmp/claude-501/-Users-snowbear-projects/6dab5d5e-b5e1-4822-9a9e-4e1bc764dce5/scratchpad/dbman-canvas/project/*.dc.html

## Rules (ponytail, full) — read /private/tmp/claude-501/-Users-snowbear-projects/6dab5d5e-b5e1-4822-9a9e-4e1bc764dce5/scratchpad/ponytail/SKILL.md
- NO DUPLICATION. Compose from what exists. Never re-implement a frame, button style, label, readout, chart, meter,
  halftone, rail, segmented control, grid or editor. If something generic is missing, use the closest existing one;
  screen-specific bits stay `private` in your file.
- Smallest complete change; no options nobody asked for; one small self-check for non-trivial logic;
  `// shortcut: <limit>, <when to upgrade>` for known limits. Never cut validation, data-loss handling, security, a11y.
- Only edit files you own (table below). Delete your `Features/_Placeholder_<Type>.swift` file(s) and implement the
  type with the SAME name and init in your own file(s).
- Build with a private scratch path: `swift build --scratch-path .build-<yourname>`. If errors are ONLY in files
  you do not own (another agent mid-edit), wait and retry; never edit them.
- End your reply with: files, what works, 1–2 ponytail lines (skipped / risks).

## Ownership
| Agent | Owns (create under Sources/DBMan/Features/<Folder>/) | Replaces placeholders |
|---|---|---|
| shell (sonnet) | Shell/: TopStrip, StatusStrip, NavigatorView, PaletteView, StateFrame, ConnectFailedView, DBManCommands | those 7 |
| table (sonnet) | Table/: TableBrowserView (+ inspector, console, structure, ER relations, stats), ReviewSheet | TableBrowserView, ReviewSheet |
| query (sonnet) | Query/: QueryView (editor, results, Explain plan diagram, chart) | QueryView |
| overview (sonnet) | Overview/: OverviewView (dashboard) | OverviewView |
| connect (haiku) | Connect/: ConnectionsView ; Settings/: SettingsView | ConnectionsView, SettingsView |
Shared files (App/*.swift, Grid/, Editor/, Support/, Halftone/, DBCore/) are owned by the integrator. If you need a
new property on WorkspaceModel, do NOT edit it: keep the state local (@State) in your view, and list what you'd add.

## Available APIs
DBCore: `Cell`, `QueryResult`, `RowPage`, `TableInfo/ColumnInfo/IndexInfo/ForeignKey`, `SchemaSnapshot`, `PlanNode`,
`ConnectionProfile`, `Engine`, `SSLMode`, `EnvironmentTag`, `DBError`, `quoteIdent(_:_:)`, `SQLClassifier`,
`StagedChange`, `ChangeSet` (summary, transactionSQL), `DatabaseSession` (actor: schema(), run(_:limit:), stream(_:pageSize:)
nonisolated, explain(_:analyze:), cancel(), unlockWrites/lockWrites, stage/undo/discard/commit, columnStats(table:sampleRows:)
→ [ColumnStats{column, distinct, nullFraction, min, max, median, histogram[12], topValues[TopValue{value, share}]}]),
`ConnectionURL.parse / parseWithPassword / format`.

App (Sources/DBMan/App): `AppModel.shared` (@Observable: profiles, upsert, remove, profile(id), workspace(for:), openFile(url),
ensureSampleDatabase(), openWindow closure). `WorkspaceModel` (@Observable: profile, session, state(.connecting/.connected(latencyMs)/.failed/.reconnecting),
schema, route(.overview/.table(name)/.query(id)), go/back/goForward, openTabs, closeTab, queryTabs, newQuery(sql:),
queryTab(id), showInspector, showConsole, paletteOpen, reviewOpen, writesUnlocked, staged: ChangeSet, stage(_:),
undoStaged, discardStaged, unlockWrites, lockWrites, commitStaged(), console:[ConsoleEntry], log(_:_:error:),
relativeDates, refreshSchema()). `QueryTab` (@Observable: title, sql, savedSQL, result, error, running, startedAt, plan, isEdited).
Window layout is in App/WorkspaceWindow.swift: VStack(TopStrip, HStack(NavigatorView 220pt, content), StatusStrip)
on DotGridBackground with 6pt padding and 4pt gaps; palette overlay; review sheet.

Grid/Editor/Support: `DataGrid(columns: [GridColumn], rows: [[Cell]], selection: Binding<Int?>, focusedColumn: Binding<Int>,
sparklines: [String:[Double]], onSort:, onEdit:(row,col), onFilterValue:(column,Cell), onFollowFK:(row,col), onReachEnd:, tableName:)`;
`GridColumn(name:type:isPrimaryKey:isForeignKey:alignRight:)`; `SQLEditor(text:completions:onRunStatement:onRunAll:)`,
`SQLEditor.statement(at:in:)`; `Keychain.password(for:)/save(_:for:)/delete(for:)`; `SampleDatabase.ensure()`.

Halftone (import Halftone): tokens `HT.C.*` (backdrop, paper, sunken, ink, ink2, ink3, line, fill12, fill30, accent,
accentSoft, amber, alert), `HT.M.*` metrics, `HT.Motion.snap/glide/enter/roll`; text `.ht(.body/.bodySmall/.strong/.label/
.labelSmall/.readoutS/M/L/XL/.data/.dataSmall/.code)`, `CapsLabel(title, tail)`; `HTFrame(title:tail:accessory:content:)`,
`DotGridBackground()`; button styles `.htOutline/.htPrimary/.htDestructive`; `HTNavButton(_:systemImage:isActive:action:)`,
`HTSegmented(selection:options:)`, `HTSearchField(text:prompt:shortcut:)`, `HTToggleChip(_:isOn:)`;
`NumberRail(items:selection:)` (⌘1–⌘9); `Readout(value:label:tail:size:)`; `HTTone`, `StatusText(label:value:tone:)`;
`ActivityItem(icon:title:detail:time:tone:)`, `OptionTile(title:subtitle:isSelected:action:)`;
instruments (give them a frame height): `LineChart(series:styles:markers:dashedGrid:highlightIndex:accessibilityLabel:)`,
`BarSpectrum(values:highlight:...)`, `SegmentedMeter(value:segments:tint:...)`, `Halftone(levels:[[UInt8]] highlight:...)`,
`RadarChart(values:labels:...)`, `Sparkline(values:style:...)`, `LineStyle(.solid/.ink55/.ink30/.amber/.accent)`.
Note: inside module `Halftone` the struct `Halftone` shadows the module name — don't qualify with `Halftone.`.

Test data: sample SQLite via `AppModel.shared.ensureSampleDatabase()`; Postgres `postgres://app:app@127.0.0.1:55432/shop?sslmode=disable`,
MariaDB `mysql://app:app@127.0.0.1:53306/shop` (running locally).
