<p align="center">
  <img src="Resources/AppIcon-source.png" width="128" alt="TableExtra icon">
</p>

<h1 align="center">TableExtra</h1>

<p align="center">
  A native macOS client for PostgreSQL and SQLite, inspired by TablePlus, with built-in Claude AI and AWS RDS monitoring.
</p>

---

## Why this project

I use [TablePlus](https://tableplus.com) every day and love how fast and focused it is. I wanted the same feel, plus a few things I kept missing:

- an AI assistant that understands the database I am looking at;
- insights into what the server is doing (slow queries, bloat, unused indexes, locks);
- AWS RDS monitoring next to the data, without opening the AWS console;
- schema tools such as a schema diff, an ER diagram and TypeScript types.

So I built my own. TableExtra is a native Swift/SwiftUI app with no Electron and no web view. It focuses on the two databases I use: **PostgreSQL** (local, self-hosted or AWS RDS/Aurora) and **SQLite**.

## Built entirely with AI ("vibe-coded")

This repository is **100% vibe-coded**: every line of code, test and doc was written by an AI coding agent ([Claude Code](https://claude.com/claude-code)), steered by prompts, reviews and manual testing. TablePlus was used only as a design reference, by studying its public interface. No TablePlus code is included.

So:

- the code works and is covered by tests, but it has not been audited line by line;
- expect rough edges, and please report them;
- it is also a real-world experiment in how far an AI agent can go building a full desktop app.

## Features

### Database client
- PostgreSQL (through libpq, with TLS and SSH tunnels) and SQLite.
- Welcome window with saved connections, environment tags (DEV / STAGING / PROD) and recent connections.
- Sidebar with pinned objects, search, and automatic grouping of tables by name prefix and date series.
- Fast AppKit data grid: inline editing, filters (`WHERE` builder or natural language), sorting and pagination.
- Table structure view: columns, indexes, constraints, triggers and DDL.
- SQL editor with syntax highlighting, autocompletion, formatter, multiple statements, transactions, query history and favorites.
- Charts from query results (bar, line, area, scatter, pie) with PNG export.
- Open Anything palette (⌘P) for tables, queries and tools.
- Production safety: per-connection safety levels, write confirmation, Touch ID, read-only mode, dry run on production and a guard on `UPDATE`/`DELETE` without `WHERE`.

### Insights and schema tools
- PostgreSQL insights dashboard: table and index sizes, bloat, unused indexes, cache hit ratio, slow queries (`pg_stat_statements`).
- Live process list with cancel and terminate.
- Visual `EXPLAIN` plans.
- Schema diff between two connections, with generated migration SQL.
- ER diagram.
- TypeScript, Kysely and Zod type generation.

### Data transfer
- Export to CSV, TSV, JSON, SQL and Markdown.
- CSV import with encoding detection and type inference.
- `pg_dump` / `pg_restore` backup and restore.
- One-click import of your TablePlus connections.

### Claude AI everywhere
- A Claude assistant in every workspace. It uses your local [Claude Code](https://claude.com/claude-code) CLI, so it uses your own account and there are no API keys to manage.
- "Ask Claude" menus on tables, query results, `EXPLAIN` plans, insights, the process list, the schema diff and RDS metrics.
- Write SQL from plain English, explain or optimize queries, and describe filters in natural language.
- Per connection, you choose whether Claude may read row data. This is off by default for staging and production; otherwise Claude only sees the schema.
- Optionally point a connection at your code repository so Claude can read it (read-only) when answering.
- Claude never runs write statements.
- `tableextra-mcp`: a standalone, read-only stdio [MCP](https://modelcontextprotocol.io) server that gives Claude Code (or any MCP client) access to your saved connections.

### AWS RDS monitoring
- Per-connection AWS settings (profile, region, instance or cluster). The region and identifier are detected from the RDS hostname.
- Dashboard with instance details, CloudWatch charts (CPU, connections, memory, storage, IOPS, latency, network), Performance Insights top SQL and waits, RDS events and pending maintenance.
- Warnings, for example low free storage without autoscaling, or a publicly accessible instance.
- It runs through your local `aws` CLI with a strict allowlist of read-only commands. A minimal read-only IAM policy is enough.

## Requirements

- macOS 14 (Sonoma) or later, on Apple Silicon.
- Xcode 16 or the Swift 6 toolchain.
- Homebrew `libpq`: `brew install libpq`.
- Optional:
  - [Claude Code](https://claude.com/claude-code) (`claude` on your `PATH`) for the AI features;
  - the AWS CLI v2 for RDS monitoring;
  - `pg_dump` / `pg_restore` for backups.

## Build and run

```bash
git clone https://github.com/matguig/TableExtra.git
cd TableExtra
scripts/build-app.sh            # builds build/TableExtra.app (libpq bundled inside)
open build/TableExtra.app

scripts/build-app.sh --install  # optional: also copies the app to /Applications
```

The script signs the app with your first "Developer ID Application" or "Apple Development" certificate, if you have one. Otherwise it uses an ad-hoc signature. Override this with `CODESIGN_IDENTITY="…"`.

During development you can also use:

```bash
swift build
swift run TableExtra
```

## Tests

```bash
swift test
```

Integration tests need a disposable PostgreSQL database, and they are skipped without one:

```bash
MTP_TEST_PG="127.0.0.1:5432:user:password:dbname" swift test
```

Never point the tests at a database that holds real data.

## Where data lives

- Connections, history and favorites: `~/Library/Application Support/TableExtra`. Override the location with `TABLEEXTRA_HOME`.
- Passwords: the macOS Keychain only.

## Project layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module layout and the coding rules. [docs/REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md) records how TablePlus's interface was studied to guide the design.

## Roadmap

More features are coming, including:

- Metrics Board (dashboards built from saved queries);
- streaming Claude responses;
- signed and notarized releases;
- partition-aware sidebar;
- more drivers, depending on demand.

## Contributing

Ideas, bug reports and pull requests are very welcome:

- **Want a feature?** [Open an issue](https://github.com/matguig/TableExtra/issues/new) and describe your use case.
- **Found a bug?** Open an issue with steps to reproduce it and your macOS and database versions.
- **Want to build it yourself?** Pull requests are welcome, whether they are written by hand or with an AI agent.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Disclaimer

TableExtra is an independent project. It is not affiliated with or endorsed by TablePlus, Anthropic or Amazon Web Services. Use it on production databases at your own risk, and keep the safety features enabled.
