# TableExtra — architecture

Native macOS app (Swift 6 toolchain, Swift 5 language mode, macOS 14+), built with SwiftPM, no Xcode project.

```
Sources/
  CLibPQ/              system module for Homebrew libpq (bundled into the .app by scripts/build-app.sh)
  CLibSSH2/            system module for Homebrew libssh2 (bundled the same way; shares libpq's OpenSSL)
  MTPCore/             no UI. Drivers (PostgreSQL via libpq, SQLite), DBClient (async + serial queue),
                       introspection, SQL tokenizer/splitter/classifier/formatter, filters, change sets,
                       stores (connections.json, Keychain, history.sqlite, favorites.json), TablePlus importer,
                       SSH/: built-in SSH tunnel (libssh2: keys, agent, password, ~/.ssh/config, known hosts)
  MTPUIKit/            shared UI: WorkspaceContext protocol, DataGridView (AppKit grid), ResultTableView,
                       CodeView + SQLHighlighter, colors, formatting, file panels,
                       DesignSystem.swift (DS tokens, Tag, Card, PaneHeader, ToolStrip/ToolButton, StatusBar, EmptyState, Banner, KeyCap)
  FeatureInsights/     PostgreSQL insights dashboard, process list, EXPLAIN visualiser,
                       AWS RDS dashboard (AWS SDK for Swift: RDS, CloudWatch, Performance Insights, STS)
  FeatureSchemaTools/  schema diff + migration SQL, Kysely/TypeScript/Zod codegen, ER diagram
  FeatureDataTransfer/ export (CSV/TSV/JSON/SQL/Markdown), CSV import, pg_dump backup/restore, TablePlus import UI.
                       pg_dump, pg_restore and psql ship in Contents/Helpers (scripts/build-pg-tools.sh: PostgreSQL
                       source, no readline, one patch for older servers); .sql.gz is decompressed in-process
  FeatureAI/           Claude assistant (via the local `claude` CLI), MCP settings
  TableExtra/         the app: menus, welcome window, workspace window, sidebar, tabs, data/structure/query tabs
  tableextra-mcp/     stdio MCP server exposing saved connections to Claude Code (read-only by default)
```

Rules:
- UI uses the `DS` tokens and shared components from `MTPUIKit/DesignSystem.swift`; no hand-rolled badges, cards or toolbars.
- The app was renamed from MyTablePlus: data folder, Keychain items and settings migrate automatically on first launch (`AppPaths`, `Keychain.legacyService`, `AppDelegate.migrateLegacyDefaults`).
- Features depend only on MTPCore + MTPUIKit and talk to the app through `WorkspaceContext`.
- Every DB access goes through `DBClient` (never touch a driver from the main thread).
- Writes coming from the UI call `WorkspaceContext.confirmWrite` first (safety levels, Touch ID, read-only).
- Secrets only in the Keychain (service `fr.koa-dev.TableExtra`).
- No external processes for core features: the SSH tunnel runs in-process (`SSHTunnel`), never `/usr/bin/ssh`, and AWS goes
  through the AWS SDK (`AWSRDSAPI`, read-only operations only), never the `aws` CLI.
- ~/.aws is read only after the user picks it (`AWSConfigFolder`, a security-scoped bookmark in the data folder).
- SSH host keys: ~/.ssh/known_hosts when readable, otherwise trust on first use in `known_hosts.json`; a changed key is refused.
- Data lives in `~/Library/Application Support/TableExtra` (override with `TABLEEXTRA_HOME`).

Tests: `MTP_TEST_PG="127.0.0.1:55432:mtp:mtp_pass:shop" swift test` (integration tests skip without the env var).
SSH tunnel tests also need a disposable sshd that can reach that database: `MTP_TEST_SSH="host:port:user:/keys/dir"`
(see `Tests/MTPCoreTests/SSHTests.swift` for the expected key files), plus optionally `MTP_TEST_SSH_PASSWORD` and
`MTP_TEST_SSHD_PID`.
