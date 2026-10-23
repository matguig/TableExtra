# Contributing to TableExtra

Thanks for your interest in TableExtra! Feature requests, bug reports and pull requests are all welcome.

## Ways to contribute

### Request a feature
Open an [issue](https://github.com/matguig/TableExtra/issues/new) that covers:
- **the problem** you are trying to solve, which matters more than the exact solution;
- **how you work today**, for example with TablePlus, psql or another tool;
- screenshots or mock-ups, if they help.

Please search existing issues first and add a 👍 to ones you care about. Votes help set priorities.

### Report a bug
Include:
- your TableExtra version (**TableExtra → About**) and macOS version;
- the database and its version (PostgreSQL 16, SQLite, AWS RDS/Aurora…);
- steps to reproduce, what you expected, and what happened instead;
- screenshots or logs, if you have them.

**Never paste passwords, connection strings with credentials, AWS keys or production data** into an issue. Redact hostnames if they are sensitive.

### Report a security issue
Do not open a public issue for a vulnerability, such as a way to bypass the read-only or safety guards or a way to leak credentials. Use [GitHub private vulnerability reporting](https://github.com/matguig/TableExtra/security/advisories/new) instead.

## Pull requests

1. **Open an issue first** for anything bigger than a small fix, so we can agree on the approach before you spend time on it.
2. Fork the repository and create a branch from `main`, for example `feat/mysql-driver` or `fix/grid-scroll`.
3. Keep each PR focused on one feature or fix. Small PRs are reviewed faster.
4. Make sure `swift build` and `swift test` pass.
5. Describe **what** changed and **why**. For UI changes, add screenshots in light and dark mode.

### AI-written code is welcome
This project was vibe-coded, and AI-assisted PRs are welcome too. You are still responsible for what you submit:
- read and understand the diff before you open the PR;
- build it and test it by hand in the running app;
- say in the PR description which parts were AI-generated.

## Development setup

```bash
brew install libpq libssh2
swift build
swift test
scripts/build-app.sh && open build/TableExtra.app
```

- Use `TABLEEXTRA_HOME=/some/temp/dir` while testing, so your real connections, history and settings stay untouched.
- Integration tests need a **disposable** PostgreSQL database: `MTP_TEST_PG="host:port:user:password:db" swift test`. Never point them at a database that holds real data.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module layout.

## Code guidelines

- **English everywhere**: code, comments, UI strings, docs, commit messages and issues.
- **Follow the surrounding code.** Match its naming, structure and comment density, and prefer small, readable functions.
- **Use the design system.** Build UI from the tokens and components in `Sources/MTPUIKit/DesignSystem.swift` (`DS`, `Tag`, `Card`, `PaneHeader`, `ToolStrip`…), not hand-rolled styles.
- **Respect the module boundaries.** Feature modules (`Feature*`) depend only on `MTPCore` and `MTPUIKit`, and talk to the app through `WorkspaceContext`.
- **Keep database access off the main thread.** Every query goes through `DBClient`.
- **Do not bypass the safety rules:**
  - every write triggered from the UI must go through `WorkspaceContext.confirmWrite`;
  - the MCP server and the Claude integration must stay read-only;
  - row data is sent to Claude only when the connection allows it.
- **Keep secrets in the Keychain only.** Never write passwords or tokens to disk, logs or the history.
- **Keep AWS access read-only.** Every AWS call goes through the `AWSRDSAPI` protocol (`FeatureInsights/RDS/AWSRDSAPI.swift`), which only has describe / get operations. Never add one that mutates resources, and never read `~/.aws` outside `AWSConfigFolder` (the user grants that folder explicitly).
- **Add tests** for new logic, such as parsers, SQL generation and diffing, in the matching `Tests/` target.

## Commit messages

Use short, imperative summaries, such as `Add MySQL driver` or `Fix grid scroll jump on reload`. Add a body when the *why* is not obvious.

## Code of conduct

Be kind, assume good intent, and keep discussions about the work. Harassment or personal attacks are not tolerated.
