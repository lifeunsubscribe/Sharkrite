# RTK (Rust Token Killer) — Sharkrite Compatibility Assessment

**Date:** 2026-03-23
**Version assessed:** rtk 0.31.0
**Repo:** github.com/rtk-ai/rtk (MIT license, 12.4k stars, ~2 months old)

---

## 1. Feasibility: Can rtk be installed via hook mode without changes to Sharkrite?

**Yes, with one important caveat.**

### How the hook works

`rtk init --global` installs a Claude Code `PreToolUse` hook at `~/.claude/hooks/rtk-rewrite.sh`. When Claude Code's Bash tool fires a command, the hook:

1. Reads the tool input JSON from stdin (extracts the command string via `jq`)
2. Calls `rtk rewrite "$CMD"` — a Rust binary that checks its rewrite registry
3. If a rewrite exists (e.g., `git status` → `rtk git status`), returns JSON with `permissionDecision: "allow"` and the rewritten command
4. If no rewrite, exits silently (passthrough)

The shell hook is intentionally thin — all rewrite logic lives in the Rust binary.

### What it affects

**Only Claude Code Bash tool calls.** This is the critical insight for Sharkrite:

- **Phase 1 (Development)** — Claude runs `git`, `grep`, `cat`, test commands, etc. via the Bash tool → **intercepted by rtk** → this is where the token savings happen
- **Phases 2-5 (PR/Review/Merge)** — Sharkrite's bash scripts call `gh`, `git`, `jq` directly (not through Claude's Bash tool) → **NOT intercepted by rtk**

This means rtk's filtering cannot break Sharkrite's review detection, assessment logic, or merge gates. Those run in Sharkrite's own shell, outside rtk's reach.

### The caveat: fix-review mode

In `claude-workflow.sh` fix-review mode, Claude Code runs interactively to fix review issues. Claude may run `gh pr view`, `git diff`, etc. via the Bash tool during this phase. These would be intercepted. However:

- All Sharkrite `gh` calls use `--json` flags, and **rtk passes `--json` through unfiltered**
- Claude's own `gh` calls during fix mode are for understanding the code, not for Sharkrite's state detection

### Stdin piping

rtk's hook only rewrites the command string in Bash tool calls. It does not intercept stdin. Sharkrite's stdin-piped review content to Claude in fix-review mode is unaffected.

### Worktrees

rtk has a dedicated `git worktree` filter (Rust module). Git commands auto-detect worktree context. No compatibility issue.

### Installation

```bash
# Install binary (no Rust toolchain needed)
brew install rtk
# OR
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh

# Install hook (creates ~/.claude/hooks/rtk-rewrite.sh + patches settings.json)
rtk init --global

# Uninstall
rtk init --global --uninstall
```

**Verdict: Yes — zero changes to Sharkrite scripts required.**

---

## 2. Filter Coverage for Sharkrite-Relevant Commands

### Commands with native Rust filters (high compression, semantic understanding)

| Command | Filter behavior | Savings | Risk to Sharkrite |
|---|---|---|---|
| `git status` | Porcelain parser → compact staged/modified/untracked counts | ~70% | None — Claude still sees file lists |
| `git diff` | Stat summary + compacted diff (30 lines/hunk, 500 total) | ~60-80% | **Medium** — large diffs truncated, Claude may miss context |
| `git log` | One-liner per commit (hash, subject, date, author) | ~50% | Low — adequate for Claude's needs |
| `git push` | → `ok main` | ~90% | None |
| `git add/commit` | → `ok abc1234` | ~90% | None |
| `git stash` | Compact subcommand handling | ~70% | None |
| `git branch` | Compact list, remote dedup, cap at 10 remote-only | ~60% | None |
| `git fetch` | → `ok fetched (N new refs)` | ~90% | None |
| `git worktree` | Passthrough for mutations, compact for list | ~50% | None |
| `gh pr view` | JSON parsed, markdown noise stripped (HTML comments, badges, images, HRs) | ~87% | **None for Sharkrite** (scripts use `--json` which bypasses rtk) |
| `gh pr diff` | Reuses `compact_diff` (30 lines/hunk, 500 total) | ~80% | **None for Sharkrite** (only affects Claude's Bash tool) |
| `gh pr list/create/merge/comment` | Compact listings, mutations → `ok` | ~80% | None |
| `gh issue list/view/create` | Compact listings, markdown filtered | ~80% | None |
| `cargo test` / `npm test` / `pytest` | Failures only; all-pass → `ok N passed` | ~90% | Low — failure details preserved |
| `cat`/`head`/`tail` | Rewritten to `rtk read` — strips comments, smart truncation | ~40% | **Medium** — see risk section |
| `ls` | Compact tree, noise dirs filtered | ~60% | Low |
| `find` | Grouped by directory, .gitignore-aware | ~50% | Low |
| `grep`/`rg` | Grouped by file, line-truncated, max 200 results | ~40% | Low |

### Commands with TOML filters (lighter compression)

| Command | Filter behavior | Risk |
|---|---|---|
| `jq` | Strip ANSI/blanks, max 40 lines, truncate at 120 chars | **Medium** — Sharkrite uses jq extensively, but only in its own scripts (not Claude's Bash tool) |
| `shellcheck` | Strip blank lines, max 50 lines | Low |
| `make` | Strip entering/leaving directory messages | Low |

### Commands with NO filter (passthrough)

| Command | Notes |
|---|---|
| `git checkout` | Not in GitCommand enum — passes through unmodified |
| `sed` | No filter |
| `awk` | No filter |

### Gap analysis

The main gap is `git checkout` having no filter, but that's fine — checkout output is already minimal. `sed` and `awk` passthrough is also fine since their output is typically small and contextual.

---

## 3. Risk Rating: The "Strangeness Tax"

### **Overall: LOW for Sharkrite's workflow, MEDIUM for Claude's development quality**

#### Why LOW for Sharkrite's workflow integrity:

1. **Sharkrite's scripts run outside rtk's reach.** The PreToolUse hook only fires for Claude Code's Bash tool. All of Sharkrite's `gh` API calls, review detection (`<!-- sharkrite-local-review` marker parsing), assessment logic, and merge gates run in Sharkrite's own bash scripts — rtk never touches them.

2. **All `gh` calls use `--json` flags.** Every single `gh pr view`, `gh issue list`, etc. in Sharkrite's codebase passes `--json`, which rtk explicitly passes through unfiltered.

3. **stdin unaffected.** Review content piped to Claude in fix-review mode flows through stdin, not through the Bash tool command rewrite path.

#### Why MEDIUM for Claude's development quality during Phase 1:

1. **`git diff` compression (30 lines/hunk, 500 total).** On large changesets, Claude may lose context from compressed diffs. This is the same information Claude uses to understand what it just changed. For Sharkrite's typical single-issue PRs (small-to-medium changesets), this is probably fine. For large refactors, it could degrade Claude's self-awareness of its changes.

2. **`cat` → `rtk read` rewrite.** rtk strips single-line comments and normalizes blank lines by default. If Claude reads a file to understand existing patterns (commenting style, header conventions), it sees a filtered version. This is the highest-risk filter for code quality — Claude may write code that doesn't match the file's actual style because it never saw the comments.

3. **`gh pr diff` compression during fix mode.** When Claude is fixing review issues in Phase 3, it may `gh pr diff` to understand the full changeset. The 500-line cap could hide context for large PRs. However, Claude typically reads specific files rather than the full diff.

#### Why NOT HIGH:

- rtk preserves all error output faithfully. Failed commands show full details.
- rtk has a tee feature (`~/.local/share/rtk/tee/`) that saves raw output on failures for recovery.
- The `--json` passthrough rule protects all structured data queries.
- Commands can be excluded via `~/.config/rtk/config.toml` → `[hooks] exclude_commands`.

---

## 4. Recommendation

### **Install with specific exclusions. Trial during development phase only.**

#### Reasoning

The token savings during Phase 1 (development) are real and significant. A typical Claude dev session runs dozens of `git status`, `git diff`, test runs, `cat`/`grep` calls. Compressing these by 60-90% directly extends how many issues Sharkrite can process before hitting usage caps — which is the stated pain point.

The risks are contained because:
- Sharkrite's own logic is never intercepted
- Failure output is preserved
- Individual commands can be excluded
- Uninstall is one command

#### Recommended exclusions

Add to `~/.config/rtk/config.toml`:

```toml
[hooks]
# Don't rewrite cat/head/tail → rtk read (preserves comment/style context for Claude)
exclude_commands = ["cat", "head", "tail"]
```

The `rtk read` rewrite is the one filter that could silently degrade code quality by hiding commenting patterns. Everything else either has clear benefits or is irrelevant (Sharkrite scripts bypass the hook entirely).

#### Do NOT exclude:
- `git` commands — the compression is well-designed and preserves what matters
- `gh` commands — `--json` already bypasses; non-JSON gh calls from Claude during dev are safely compressible
- Test runners — failures-only is exactly what Claude needs
- `grep`/`find`/`ls` — the compression is sensible and the grouping actually helps Claude parse results

---

## 5. Installation & Trial Plan

### Install

```bash
brew install rtk
rtk init --global
```

### Configure exclusions

Create `~/.config/rtk/config.toml`:
```toml
[hooks]
exclude_commands = ["cat", "head", "tail"]
```

### Test with a single issue

```bash
# Pick a small, well-defined issue
rite 123 --supervised
```

During the session, watch for:
- Claude re-running commands (suggests it didn't get enough info from compressed output)
- Claude asking about file contents it should already know (suggests `rtk read` stripped too much)
- Test failures Claude can't diagnose (suggests test runner filter lost error context)

### Monitor token savings

```bash
# rtk tracks savings in SQLite
rtk stats           # overall savings
rtk stats --detail  # per-command breakdown
```

### If problems arise

```bash
# Quick disable (removes hook, keeps binary)
rtk init --global --uninstall

# Or exclude specific problematic commands
# Edit ~/.config/rtk/config.toml → [hooks] exclude_commands
```

### Trial success criteria

Run 3-5 issues through the full lifecycle. Compare:
1. Number of issues completed per session vs. baseline
2. Fix loop iterations (should not increase — would indicate Claude lost context)
3. Review assessment accuracy (should not degrade)
4. Any Claude confusion visible in supervised mode output

---

## 6. Project Health Assessment

| Factor | Assessment |
|---|---|
| **Activity** | Very active — daily commits, 413 total, 20 contributors |
| **Maturity** | Young (~2 months) but iterating fast. Recent security advisory (SA-2025-RTK-002) for trust boundary in project-local TOML filters shows security awareness |
| **Binary distribution** | Yes — Homebrew + pre-built binaries. No Rust toolchain needed |
| **License** | MIT — fully compatible |
| **Bus factor** | Two primary contributors (150 + 115 commits). Acceptable for a tool this young |
| **Risk of abandonment** | Low in near term (12.4k stars, active development). Medium long-term (VC-backed? "RTK Cloud" at $15/dev/mo suggests commercial backing) |
| **Open issues** | 294 — high for age, but indicates active community engagement rather than neglect |
