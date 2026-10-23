# TablePlus 27.1.0 (build 830): reverse-engineering notes

These notes cover the installed artifact at `/Applications/TablePlus.app`
(main executable sha256 `8e18e7010a4714e8e8e900db2cb9e82f876438b6936d5d7b9fa2db679d895ef7`, universal x86_64 + arm64).
They were produced with REA (static analysis only: nothing in TablePlus was executed) plus `plutil`, `strings`, `otool`.

Evidence types: **observed** = read directly from the shipped artifact; **inferred** = my interpretation.

| Evidence ID | Operation |
|---|---|
| `ev_f570db731e365eee20ac8e25ef2bff074477fbb412bfe56fc432be29cf7bb0d1` | `inspect_plist` Info.plist |
| `ev_2d06289f94745e7e80bf0a9c3ddd3e212fa3b7f0d5f3545daba35457574bd357` | `decode_interface_builder` (64 of 97 nibs decoded, 6 065 nodes, 1 332 target/actions) |
| `ev_fa92988291a976c1d741aa9fd20b3f38e137525a533938ea3542d960a472339f` | `inspect_macho` (81 dylib dependencies, 102 load commands) |

## Architecture (observed)

- Native AppKit app written in Swift (567 `_TtC9TablePlus…` classes) with Interface Builder nibs, one per window or controller.
- One framework per driver: `PostgreSQL`, `MySQL57`, `MySQL97`, `MariaDB`, `SQLite`, `Redis`, `Mongo`, `MongoLegacy`, `MicrosoftSQLServer`,
  `Oracle`, `Cassandra`, `ClickHouse`, `HTTPClickHouse`, `BigQuery`, `Snowflake`, `DynamoDB`, `ElasticSearch`, `CloudflareD1`, `DuDB` (DuckDB), `TBLibSQL`.
- SSH is handled by `SSH011`, `SSH012`, `SSH095`, `SSHProtocol` (several OpenSSH generations). Swift NIO and swift-crypto are bundled too.
- Bundled client binaries: `dump_pg_10.5` through `dump_pg_18.0`, `restore_pg_*`, `dump_ms_5.7/8.0` (backup and restore), plus libpq 5.14 and 5.17.
- Updates go through Sparkle (`SUFeedURL https://tableplus.com/osx/version.xml`), and crash reports through Sentry.
- `MacOS/tableplus-mcp` is a separate executable. It is an MCP bridge to an in-app MCP server (`MCPServerManager`, `MCPService`,
  `MCPTLSManager`, `MCPPairingService`). The tools it exposes include `list_connections`, `list_open_connections`, `execute_query` and `execute_read_query`.
- AI: `AIChatViewController`, `LLMService`, `ClaudeCLIService`, `CodexCLIService`, `ACPAgentService` (Agent Client Protocol),
  `AIQueryApprovalPopover` ("Approve AI Agent Query").

## Persistence (observed on this Mac)

- `~/Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist`: an array of connection dictionaries.
  Keys: `Driver, ConnectionName, DatabaseHost, DatabasePort (string), DatabaseUser, DatabaseName, DatabasePath, Enviroment [sic],
  statusColor, GroupID, tLSMode, isOverSSH, ServerAddress, ServerPort, ServerUser, StartupCommands, SafeModeLevel…`
- `ConnectionGroups.plist`: `{ID, Name}`. `Settings.json` stores closed workspaces and their open tabs and splits.
- Passwords are in the Keychain under service `com.tableplus.TablePlus`, account `<ConnectionID>_database`.
- History lives at `Data/History/<ConnectionID>/<d MMMM yyyy>/<seconds since 2001-01-01>.sql`, one executed statement per file.
- Themes are JSON (`jade-dark.json`, `polaris-dark.json`, …) with keys `name, base, version, author, colors{App…, Editor…, Data…}, icons`.
- Shortcuts are stored in user defaults as `TPShortcut<Action> = {keyCode, modifierFlags}`.

## Feature inventory (observed from nib names, menus and strings)

Connection management: welcome window, groups, tags/colors, environments, import from URL or file, export (encrypted
`.tableplusconnection`), copy as URL, sort by tag/name/driver, passcode lock, Touch ID.

Workspace: left sidebar (items, favorites, history; schema and database switcher ⌘K), tabs and split panes, right sidebar
(row detail and structure), bottom console log, Open Anything ⌘P, back/forward navigation.

Data: paginated grid (`PagingPopover`, `OffsetPopover`, `EstimatedOffsetPopover`), filters (`FilterViewController`, `FilterRuleController`),
quick look and preview popovers, JSON editor (tree and text), date picker, foreign-key popover, dropdown for enums,
pending changes committed with ⌘S, preview with ⌘P, discard with ⇧⌘⌫, add row ⌘I, duplicate row ⌘D, copy and paste cells.

Structure: columns, indexes, triggers, view DDL, sequences, functions. Clone, truncate, delete and create table.

Query editor: syntax highlighting, completion window, query folding, multiple results, appending result mode,
run current ⌘↩, run all ⇧⌘↩, toggle comments ⌘/ ⌥⌘/, case transforms, variables (`VariableWindow`), SQL formatter, SQL viewer.

Tools: process list ⌘. (`ProcessListWindow`), user management (PG and MSSQL), ER diagram, Metrics Board (charts, scoreboards, inputs),
search in database, custom scripts, plugins (`.tableplusplugin`), backup and restore, import CSV/JSON/SQL, export (CSV/JSON/SQL/…).

Safety (observed strings):
- Silent Mode: send queries to the server without any warnings (default).
- Warning Mode: confirm before sending queries.
- Safe Mode 1: prompt for the password before sending queries to the server.
- Safe Mode 2: prompt for the password before sending queries, except SELECT/EXPLAIN/SHOW.

## Main menu and shortcuts (observed, decoded from Base.lproj/Welcome.nib)

An upper-case `NSKeyEquiv` in the nib means ⇧ is part of the shortcut.

| Action | Shortcut | Selector |
|---|---|---|
| New Workspace | ⌘N | `newWorkspace:` |
| Open Anything | ⌘P | `openAnything:` |
| Open a Connection… / Open a Database… | ⇧⌘K / ⌘K | `showConnection:` / `switchDatabase:` |
| New Tab / Close Tab | ⌘T / ⌘W | `newTab:` / `closeTab:` |
| Run Current Query / Run All | ⌘↩ / ⇧⌘↩ | `executeSelectedQuery:` / `executeAllQueries:` |
| Commit / Preview / Discard | ⌘S / ⇧⌘P / ⇧⌘⌫ | `commitChanges:` / `previewChanges:` / `discardChange:` |
| Add Row / Duplicate Rows | ⌘I / ⌘D | `addNewRowMenu:` / `duplicatedRow:` |
| Reload Current Tab / Reload Workspace / Reconnect | ⌥⌘R / ⌘R / ⇧⌘R | `reloadCurrentTabContent:` / `reloadWorkspace:` / `forceReconnect:` |
| Split Pane Right | ⇧⌘D | `__splitPaneHorizontally:` |
| Copy Selected Cells / Paste to Selected Cells | ⇧⌘C / ⇧⌘V | `copyCell:` / `pasteToSelectedCells:` |
| Delete rows | ⌘⌫ | `delete:` |
| Go Back / Forward | ⌃⌘← / ⌃⌘→ | `__goBack:` / `__goForward:` |
| New SQL Viewer / Save As | ⇧⌘O / ⇧⌘S | `openSQLFile:` / `saveAs:` |
| Show Table Data / Structure | ⌃⌘[ / ⌃⌘] | `showTableData:` / `showTableStructure:` |
| Previous / Next Tab | ⌘[ / ⌘] | `previousTab:` / `nextTab:` |
| Previous / Next Workspace | ⇧⌘[ / ⇧⌘] | |
| Toggle Left Sidebar / Query Results | ⌘0 / ⌃\` | |
| Toggle Bottom Sidebar | ⌃⌘C | |
| Process List / cancel query | ⌘. | `cancelRunningQuery:` |
| Disconnect | ⌥⌘. | |
| Export Tables… | ⌘E | `exportTable:` |
| Find Items in Sidebar | ⌘F | |
| Toggle Line / Block Comment | ⌘/ / ⌥⌘/ | |
| Tab 1…9 | ⌘1…⌘9 | `selectTabAtIndex:` |

## How this drives TableExtra (design choices)

The design choices below are mine, not facts about TablePlus:

- TableExtra mirrors the menu structure and shortcuts above so muscle memory carries over.
- The first version goes deep on PostgreSQL (including AWS RDS) and SQLite rather than wide on 20 drivers.
- Safety modes become one per-connection setting, plus a production dry run and a guard on UPDATE/DELETE without WHERE.
- The in-app MCP server becomes a standalone stdio `tableextra-mcp` that Claude Code can launch directly.

## Query result charts (added 2026-10-23)

Evidence `ev_5714563f209ae7b84949d00511e112d9c4d64efba9ba1a45e39e0351a393db14`: `decode_interface_builder` over
`QueryResultController.nib`, `QueryController.nib` and the `Metrics*Chart*` / `MetricsBoardWindow` nibs, from the same
TablePlus executable (sha256 `8e18e701…`). Static analysis only.

Observed:
- The result pane has a segmented control (`resultSegmentControl`, action `changeResultTab:`) whose tabs include
  **Result**, **Message** and **Chart**.
- The chart view is the custom class `QueryResultCharts` (outlet `chartView`). Its controls: a style menu with
  **Bar Chart / Line Chart / Pie Chart** (`choseChartStyle:` / `changeChartStyle:`), an **x-axis** button
  (`pickChartXaxisButton`, `pickChartColumnName:`) and a **y-axis** button (`pickChartYaxisButton`, `pickChartColumnValue:`),
  a **Reset** action (`resetCharts:`), **Add to Metrics Board** (`addToMetricsBoard:`), a `chartLabel` and a
  `chartDetailValueLabel`. The empty state reads "Click y-axis button to add a Chart".
- Charts are drawn with the bundled DGCharts framework (`DGCharts_DGCharts.bundle`).
- The Metrics Board reuses `QueryResultCharts` in bar/line chart widgets configured with a label, a query ("Load data
  to chart with the query below"), x-axis/y-axis pickers and a refresh rate (1 s … 30 min, "Refresh on Event").

Inferred: the chart starts empty until the user picks the axes; `chartDetailValueLabel` shows the value under the pointer.

TableExtra design choices (not TablePlus facts): a Table/Chart switch per result; axes suggested automatically (first
date or text column on x, first measure on y, or a row count); bar, line, area, scatter and pie (Swift Charts); several
y columns, a color-by column and aggregation; hover readout; copy image / save PNG. No Metrics Board yet.

## FluentDB 1.19.1 AI integration (reference for TableExtra's Claude features, 2026-10-23)

Target: `/Applications/FluentDB.app` (`westlabsllc.FluentDB`, executable sha256 `0e8223fd…`). Static analysis only.
Evidence: `ev_9ee9774bb4411b67d7546392a3b6f875f9d9a5b4ed2155efa6def8b57e684c3c` (`inspect_macho`),
`ev_153258d439fc9fbe1d50aa62c9afc6d7a1ba0dfd462f209c5f784c231bd2546c` (`inspect_native_dispatch_metadata`: Swift conformances
and Objective-C class names), plus literal strings read from the same executable (supplementary, not REA Evidence).

Observed:
- Providers conforming to `LLMProvider`: `AnthropicProvider`, `OpenAIProvider`, `OllamaProvider`, `ACPAgentProvider`,
  `LocalAgentProvider` (local coding agents such as Claude Code or Codex: "uses your subscription, no API key").
- Services: `AIService`, `ChatStore`, `LLMLogger`, `LLMSettings`, `SchemaIndexStore`, `DailyUsageReporter`; MCP side:
  `FluentDBMCPServer`, `SharedMCPServer`, `MCPToolbox`, `MCPApprovalCenter`, `AgentControlBridge`, per-connection
  `expose_to_agents` ("Let coding agents control FluentDB").
- UI strings/types: `AIChatView` ("Ask your database", "Ask anything about your data"), `ChatResultPreviewGrid`,
  runnable SQL cards ("Added to FluentDB's chat as a runnable SQL card"), `InlineSuggestionList` ("AI chat & SQL
  autocomplete"), dashboards that can pin an AI chart ("pin an AI chart to this board"), and a consent switch
  "Let the assistant read your data?" / "AI reads results" vs "AI can't see results".
- System prompt (embedded): an agent with tools `list_tables`, `describe_table`, `list_foreign_keys` and a read-only
  `run_sql`; writes must be proposed as ```sql blocks; result rows capped at 50; per-dialect identifier quoting rules;
  current date injected; charts requested as a ```chart JSON block (`type`, `x`, `y`, `title`).
- Bounded negative: no string or type tying AI to the table data or structure screens was found (string search only).

TableExtra design choices inspired by this (not FluentDB facts): one Claude conversation per workspace window opened
from every screen (Insights, table data and structure, query results, EXPLAIN, process list, schema diff, sidebar), a
natural-language filter, per-connection "Claude can read data" (off by default on staging/production), read-only
database tools through `tableextra-mcp` scoped with `TABLEEXTRA_MCP_ONLY`, and — beyond FluentDB — an optional code
repository per connection that Claude reads with Read/Grep/Glob (`--add-dir`, user settings only, no edits).
