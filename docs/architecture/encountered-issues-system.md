# Encountered Issues System

## Purpose

Captures out-of-scope issues discovered during development without blocking the current workflow. Issues are automatically triaged into tech-debt GitHub issues at merge time, before the scratchpad context is cleared.

## Scratchpad Section

### Location
Between "## Current Work" and "## Recent Security Findings" in `.claude/scratch.md`

### Entry Format
```
- **YYYY-MM-DD** | `file:line` | Category | Description | Affects: [feature/behavior] | Fix: [intended fix] | Done: [acceptance criteria]
```

### Categories
- `test-failure` - Failing tests unrelated to current work
- `security` - Security concerns noticed but out of scope
- `code-smell` - Code quality issues worth addressing
- `missing-docs` - Documentation gaps discovered
- `deprecation` - Deprecated APIs or patterns in use
- `performance` - Performance issues observed

## Functions (scratchpad-manager.sh)

### `log_encountered_issue()`
Appends issue to scratchpad. Deduplicates by file:line. Caps at 50 entries (FIFO).

Parameters: `file_path`, `line` (optional), `category`, `description`, `affects`, `fix`, `done_criteria`

### `create_tech_debt_issues()`
Reads encountered issues, creates GitHub issues with `tech-debt` and `automated` labels. Checks for duplicates before creating. Returns count of issues created.

### `clear_encountered_issues()`
Removes entries after processing. Preserves section header.

## Lifecycle

1. **During work**: Claude discovers out-of-scope issue -> logs to scratchpad
2. **Pre-merge**: `merge-pr.sh` calls `create_tech_debt_issues()` -> GitHub issues created
3. **Post-create**: `clear_encountered_issues()` cleans the section
4. **Next workflow**: Fresh section ready for new discoveries

## Tech-Debt Issue Template

Issues are created with:
- **Title**: `[tech-debt] Category: Brief description`
- **Labels**: `tech-debt`, `automated`
- **Body**: Description, location, impact, intended fix, done criteria, origin tracing

## Origin Tracing

Each tech-debt issue includes:
- First observed date and originating issue/PR
- List of other issues where the same problem was encountered (if logged multiple times)

This creates traceability from tech-debt back to the work that discovered it.
