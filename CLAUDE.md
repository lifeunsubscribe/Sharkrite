# Sharkrite Development Guide

AI-powered GitHub workflow automation CLI. Pure bash, uses Claude Code for development and review.

**Mako** — the Claude Code assistant for this repo. Named after the fastest shark.

## Claude Code Message Board

**Location:** `~/Dev/CLAUDE-MESSAGE-BOARD.md`

Cross-project communication between Mako (sharkrite), Remora (clearance-screener), and Dace (freshup). Check this at the start of any session involving cross-project concerns — Remora and Dace post sharkrite feedback and feature requests here; Mako posts responses/resolutions.

**When to check:** Any session where you're improving sharkrite behavior, fixing workflow bugs, or when the user mentions feedback from another repo. Also check when starting a new session after a gap — there may be unread messages.

## Behavioral Design

**Reference:** `docs/architecture/behavioral-design.md` — living document of design decisions, behavioral contracts, and rejected approaches. Check before modifying any subsystem. Update when adding or changing behavior.

## Architecture

```
bin/rite                          # CLI entrypoint (arg parsing, dispatch)
lib/core/workflow-runner.sh       # Main orchestrator (phases 1-5, retry loop)
lib/core/claude-workflow.sh       # Claude Code session (dev work + fix mode)
lib/core/create-pr.sh             # PR creation, push, early sensitivity detection
lib/core/local-review.sh          # Generate code review via Claude
lib/core/assess-review-issues.sh  # Three-state assessment (NOW/LATER/DISMISSED)
lib/core/assess-and-resolve.sh    # Review loop driver (calls assess, decides action)
lib/core/merge-pr.sh              # Merge PR, cleanup worktree
lib/core/plan-issues.sh           # Issue generation from architectural docs
lib/providers/provider-interface.sh # Provider abstraction dispatcher
lib/providers/claude.sh           # Claude Code CLI provider (primary)
lib/providers/gemini.sh           # Gemini CLI provider (skeleton)
lib/utils/blocker-rules.sh        # Hard gates + review sensitivity detection
lib/utils/config.sh               # Config loading, path setup, provider variables
lib/utils/divergence-handler.sh   # Branch divergence detection, classification, resolution
lib/utils/pr-detection.sh         # PR/worktree/review state detection utilities
lib/utils/repo-status.sh          # Repo-wide status display (worktrees, phases, issues)
lib/utils/scratchpad-manager.sh   # Scratchpad lifecycle (security findings, encountered issues)
lib/utils/stale-branch.sh        # Stale branch detection, merge-main or close-and-restart
```

### Workflow Phases

1. **Development** — Claude implements the fix in a worktree
2. **Push/PR** — Push commits, create/update PR, detect review sensitivity areas
3. **Review/Assess Loop** — Generate review, assess findings, fix ACTIONABLE_NOW items (up to 3 retries)
4. **Merge** — Hard gate (CRITICAL findings only), then merge PR
5. **Completion** — Notifications, cleanup

### Data Flow

- `assess-review-issues.sh` outputs assessment to **stdout** (pipe-friendly)
- `assess-and-resolve.sh` captures stdout, decides to loop (exit 2) or merge (exit 0)
- `workflow-runner.sh` captures exit codes and stdout to pass review content to fix mode
- **stderr** is used for all user-facing output (print_info, print_warning, etc.)

## Shell Conventions

### grep -c pattern (CRITICAL)

`grep -c` always outputs a count (even "0") but returns exit code 1 when count is 0.

```bash
# BAD: produces "0\n0" (grep outputs "0", then || echo "0" adds another)
COUNT=$(echo "$text" | grep -c "pattern" || echo "0")

# GOOD: grep -c already outputs the count, just suppress the exit code
COUNT=$(echo "$text" | grep -c "pattern" || true)
```

`grep -o` is different — it outputs nothing on no match, so `|| echo "0"` is correct there.

### Structured header matching (CRITICAL)

Assessment output uses `### Title - STATE` format. Always match the structured header, never bare keywords.

```bash
# BAD: matches "ACTIONABLE_NOW" anywhere, including reasoning text like
# "This was the previous ACTIONABLE_NOW item that was fixed"
COUNT=$(echo "$output" | grep -c "ACTIONABLE_NOW" || true)

# GOOD: matches only the structured classification headers
COUNT=$(echo "$output" | grep -c "^### .* - ACTIONABLE_NOW" || true)
```

### Review severity parsing

The review outputs a `Findings: [CRITICAL: N | HIGH: N | ...]` summary line. Parse that instead of broad keyword matching.

```bash
# BAD: "CRITICAL:" matches metadata lines like "Findings: [CRITICAL: 0 | ...]"
COUNT=$(echo "$output" | grep -ciE "CRITICAL:" || true)

# GOOD: parse the structured Findings line
FINDINGS=$(echo "$output" | grep -oE "CRITICAL: [0-9]+ \| HIGH: [0-9]+" | head -1)
```

### Silent death: pipelines inside `$()` (CRITICAL)

Under `set -euo pipefail`, a pipeline inside `$(...)` that exits non-zero kills the script **silently**. When `grep`, `awk`, `sed`, `head`, or `tail` find no match (exit 1), the command substitution returns 1, the assignment "succeeds" syntactically, but the script dies with no error output.

**Live bug:** Issue #34 batch run died mid-stream when `PARENT_PR=$(echo "$BODY" | grep -oE 'pattern' | cut -d: -f2)` found no match.

```bash
# BAD: silently kills script if grep finds no match
VAR=$(echo "$text" | grep "pattern")
VAR=$(git worktree list | grep "branch" | awk '{print $1}')
VAR=$(echo "$data" | sed -n '/start/,/end/p' | head -1)

# GOOD: empty-match is expected, continue gracefully
VAR=$(echo "$text" | grep "pattern" || true)
VAR=$(git worktree list | grep "branch" | awk '{print $1}' || true)
VAR=$(echo "$data" | sed -n '/start/,/end/p' | head -1 || true)

# GOOD: empty-match is an ERROR, fail with clear message
VAR=$(echo "$text" | grep "required-field" || {
  echo "ERROR: required field not found" >&2
  exit 1
})
```

**Enforcement:** The custom lint rule `UNSAFE_PIPE_IN_CMDSUB` in `tools/sharkrite-lint.sh` detects this pattern (invoked by `make check` CI gate). Regression test in `tests/regression/silent-death-grep.bats` verifies both the lint rule and the graceful-fail behavior.

### Unbound variables with `set -u` (CRITICAL)

All scripts use `set -euo pipefail`. Unset variables crash the script before any error handling can run. Three recurring patterns:

```bash
# BAD: crashes if WORKTREE_PATH was never assigned
if [ -z "$WORKTREE_PATH" ]; then

# GOOD: default-value syntax satisfies set -u
if [ -z "${WORKTREE_PATH:-}" ]; then
```

**Never reference a variable before ensuring it's set.** When adding a variable to a file that doesn't currently use it (e.g., `$ISSUE_NUMBER` in a script that only had `$PR_NUMBER`), every reference must use `${VAR:-fallback}` — even in string interpolation. The variable may not be in scope depending on the call path.

```bash
# BAD: crashes when called standalone (ISSUE_NUMBER not exported by caller)
print_header "Review — Issue #$ISSUE_NUMBER"

# GOOD: fallback to another identifier
print_header "Review — Issue #${ISSUE_NUMBER:-$PR_NUMBER}"
```

**PIPESTATUS doesn't survive `$()`**. A pipeline inside a command substitution runs in a subshell — `PIPESTATUS` is lost when the subshell exits.

```bash
# BAD: PIPESTATUS is from the outer shell, not the pipe inside $()
OUTPUT=$(cmd1 | cmd2)
EXIT_CODE=${PIPESTATUS[0]}   # unbound or stale

# GOOD: capture exit code via temp file inside the pipeline
_exit_file=$(mktemp)
OUTPUT=$(cmd1 | { cmd2; echo $? > "$_exit_file"; } | cmd3)
EXIT_CODE=$(cat "$_exit_file")
rm -f "$_exit_file"
```

**`local` only works inside functions.** Several scripts (`batch-process-issues.sh`, `assess-and-resolve.sh`) run logic in the main script body, not inside functions. Using `local` there crashes with `local: can only be used in a function`. Use plain variable assignment with `_` prefix instead.

```bash
# BAD: crashes in main script body
local dep_state=""

# GOOD: plain assignment (prefix with _ to signal local-ish scope)
_dep_state=""
```

**Enforcement:** The custom lint rule `LOCAL_OUTSIDE_FUNCTION` in `tools/sharkrite-lint.sh` detects this pattern (invoked by `make check` CI gate). Regression test in `tests/regression/no-local-outside-function.bats` runs the check against the entire codebase.

**Exported env vars survive subprocesses, function definitions don't.** Don't use an env var as a "skip" guard for `source` if the sourced file defines functions that child processes need.

### .gitignore and symlinks

Use `.rite` (no trailing slash). `.rite/` only matches directories, but in worktrees `.rite` is a symlink (git mode 120000 = file).

## Safety System

Two-tier approach: review sensitivity hints + hard merge gates.

### Review Sensitivity Hints (path-based)

Path-based detectors (infrastructure, migrations, auth, docs, expensive services, protected scripts) inject focused review guidance into the review prompt. They do NOT block merges.

- Detected in `create-pr.sh` early checks (informational)
- Injected into review prompt by `local-review.sh` via `detect_sensitivity_areas()`
- Patterns configured in `.rite/blockers.conf` (same `BLOCKER_*` variables)

### Hard Merge Gates (content-aware)

Only content-aware and practical conditions block merges:

- **CRITICAL review findings** — requires fix or approval
- **Test/build failures** — non-zero exit from test suite
- **Session limits** — token/time limits reached
- **AWS credentials expired** — deployment credentials invalid
- **Supervised mode**: Interactive `read -p` prompt for approval
- **Unsupervised mode**: Stops workflow (unless `--bypass-blockers`)
- Approvals remembered per-issue via `has_approved_blocker()`

### Stale Branch Handling

When resuming an issue with an existing PR, the branch is checked against `origin/main`. Controlled by `RITE_STALE_BRANCH_THRESHOLD` (default: 10 commits).

- **Below threshold**: Merge `origin/main` into the feature branch (like GitHub "Update branch"), push. No force-push needed since history isn't rewritten. The final merge is a squash anyway.
- **At/above threshold (auto)**: Close PR with summary comment, cleanup branch/worktree, continue workflow fresh (no restart needed — falls through to development phase).
- **At/above threshold (supervised)**: Prompt with 4 options (restart recommended, merge, continue, abort).

Check runs in `workflow-runner.sh` after PR/worktree detection, before phase-skip logic. Returns exit code 11 to signal "restarted fresh" — caller resets all resume state variables.

## Phase Commands

Individual workflow phases can be run standalone via flags. All default to auto/unsupervised mode.

```bash
rite 42                    # Full lifecycle (phases 1-5)
rite 42 --status           # Read-only: show workflow state overview for issue
rite --status              # Repo-wide: worktrees, open issues with phases, recently closed
rite --status --by-label   # Repo-wide status grouped by label
rite 42 --dev-and-pr       # Phase 1-2: dev + PR only, skip review/merge
rite 42 --review-latest    # Phase 2 (review only): generate + post review
rite 42 --assess-and-fix   # Phase 3: assess review + fix loop (up to 3 retries)
rite 42 --undo             # Cleanup: close PR, delete branch/worktree
rite plan docs/phases.md   # Generate issues from architectural doc
rite plan "phases 2-4"     # Natural language doc filtering
rite plan --preview        # Preview issues without creating
rite --health-report       # Generate + display operational health report
rite --health-report --latest  # Show most recent report
```

**`--status`** (per-issue) shows issue state, PR stats (files/lines/commits), review currency, assessment counts, follow-up issues, session state, logs, and suggests the next command to run.

**`--status`** (repo-wide, no issue number) shows all worktrees with staleness, open issues with workflow phase (Not started, Dev/PR, Needs review, Review stale, Needs fixes, Ready to merge), and recently closed issues with close dates. Use `--by-label` to group open issues by label.

**`--review-latest`** checks review staleness: no review → generates; stale → regenerates; current → prints existing review and exits (in supervised mode, prompts to re-review).

**`--assess-and-fix`** requires a current review. Handles the full fix loop internally: assess → fix → push → re-review → re-assess. Creates follow-up issues for ACTIONABLE_LATER items.

**`rite plan`** generates GitHub issues from architectural docs. Loads the doc + project CLAUDE.md + the issue runbook (`docs/issue-runbook.md`) and generates well-structured issues via Claude. Interactive feedback loop: preview → approve/adjust → create. Supports natural language instructions for filtering (e.g., `rite plan "phases 2-4 except auth"`). Default doc(s) configured via `RITE_PLAN_DOCS` in `.rite/config`. Issues follow the runbook template: title format, labels (phase + category + priority), time estimates (Fibonacci, capped at 2hr), Claude Context, acceptance criteria with verification commands, done definitions, scope boundaries, and dependency chains.

The full `rite <issue>` resume correctly detects state (via PR comments/commits) and skips completed phases, so running standalone commands then resuming with the full lifecycle works seamlessly.

### PR Detection (`lib/utils/pr-detection.sh`)

Shared utilities used by standalone commands and the orchestrator:

- `detect_pr_for_issue ISSUE_NUMBER` — finds PR by body text search (Closes #N)
- `detect_worktree_for_pr PR_NUMBER` — finds local worktree for PR branch
- `detect_review_state PR_NUMBER [WORKTREE_PATH]` — checks review existence and currency

Uses local git timestamps when worktree is available (avoids GitHub API eventual consistency).

## Follow-up Issue Template

Follow-up issues (tech-debt, review follow-ups) follow the structure in `templates/issue-template.md`:

- **Claude Context**: Changed files from the PR (auto-populated)
- **Acceptance Criteria**: Item-specific from assessment (e.g., `[HIGH] Fix input validation`)
- **Done Definition**: Generated from severity mix
- **Scope Boundary**: Static DO/DO NOT (address findings only)
- **Time Estimate**: Aggregated from Fix Effort metadata in assessment

**Note:** The template is a reference document. `assess-and-resolve.sh` and `assess-review-issues.sh` hardcode the issue body structure inline rather than loading the template file. `rite --init` copies it to `.rite/issue-template.md` but nothing reads it back. Customizing the local copy has no effect yet.

## Linting

Sharkrite uses shellcheck + custom lint rules to catch bash anti-patterns.

```bash
make check              # Run all linters (shellcheck + custom rules)
make shellcheck         # Run shellcheck only
make lint               # Run custom rules only
bats tests/             # Run test suite (requires bats)
```

**Custom lint rules** (in `tools/sharkrite-lint.sh`) catch patterns shellcheck misses:
- `grep -c ... || echo "0"` — produces double zero (use `|| true`)
- `git push` without refspec — dangerous in automation
- `eval` with GitHub API data — security risk
- Unquoted heredoc in command substitution — use `<<'EOF'`
- BSD `sed -i ''` without GNU fallback
- `PIPESTATUS[0]` after `|| true` — value is lost
- `local` outside function — only works inside functions

**Suppressing false positives:**

Some lint rules support inline suppression comments. Place the comment on the line immediately before the flagged code:

```bash
# sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must be expanded
PR_BODY=$(cat <<EOF
Summary: ${ISSUE_TITLE}
EOF
)
```

Supported suppression rules:
- `UNQUOTED_HEREDOC` — for intentional variable expansion in heredocs

**Pre-push hook** (optional):
```bash
cp tools/git-hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

**CI gate**: `.github/workflows/lint.yml` runs `make check` on every PR.

## Testing

```bash
# Install locally for testing
./install.sh

# Symlink for live editing
rm -rf ~/.rite/lib && ln -s $(pwd)/lib ~/.rite/lib

# Dry run
rite --dry-run

# Check issue state before running
rite 42 --status

# Test individual phases
rite 42 --dev-and-pr       # Dev + PR only
rite 42 --review-latest    # Review only
rite 42 --assess-and-fix   # Assess + fix loop

# Test full lifecycle
rite 42 --supervised
```

## Claude Session Prompt Design (CRITICAL)

The prompt passed to Claude Code in `claude-workflow.sh` must include:

1. **Sharkrite identity** — Claude doesn't know what tool invoked it. Without explicit context, it hallucinates names like "forge". The prompt must state: "You are running inside a Sharkrite (`rite`) workflow session."
2. **Git/GH prohibition** — Claude must NOT run `git commit`, `git push`, `gh pr create`, etc. The post-workflow script handles all of this. Enforce via **both** prompt instructions AND `--disallowedTools`. Prompt-only prohibition is insufficient — Claude ignores it. `--disallowedTools` is enforced by the CLI and cannot be bypassed. Both the main dev session and fix-review session must use it.
3. **Explicit exit instructions** — In supervised mode, Claude runs interactively and will sit idle forever after completing work unless told to `/exit`. Auto mode uses `--print` which auto-exits.
   - Supervised: "When all phases are complete, immediately exit with `/exit`"
   - Auto: `--print` handles exit; prompt says "session will end automatically"
4. **No "Ready to start?" or open-ended questions at end** — The prompt should end with a directive ("Begin with Phase 0"), not a question that invites Claude to wait for confirmation.

## Git Commits

- **No co-author lines.** Do not add `Co-Authored-By` to commit messages.

## Common Pitfalls

- **Subshell variable loss**: Variables set inside `while read | pipe` are lost. Use process substitution or temp files.
- **BSD vs GNU date**: macOS uses BSD date. Always handle both with `if date --version` detection.
- **PR comment markers**: Use `contains("<!-- sharkrite-local-review")` (no closing `-->`) because markers include attributes like `model:opus timestamp:...`.
- **Exit codes**: Canonical table lives in `docs/architecture/exit-codes.md`. Key codes:
  - `assess-and-resolve.sh`: exit 0 for "ready to merge", exit 1 for "manual intervention needed", exit 2 for "loop to fix", exit 3 for "review stale — route back to Phase 2"
  - `merge-pr.sh`: exit 0 for "merge and cleanup succeeded", exit 1 for "merge failed", exit 6 for "merge succeeded but cleanup failed"
  - `stale-branch.sh` → `workflow-runner.sh`: exit 11 for "stale branch restarted fresh" (caller resets resume state). **Not 10** — exit 10 is reserved for `batch-process-issues.sh` "blocker detected — defer issue"
- **RITE_ORCHESTRATED**: When `workflow-runner.sh` calls `claude-workflow.sh`, it sets `RITE_ORCHESTRATED=true`. This tells `claude-workflow.sh` to skip its internal PR/review workflow (create-pr.sh call) — those are handled by the orchestrator's Phase 2/3. Without this, reviews get generated twice.
- **Encountered Issues**: When discovering out-of-scope issues during development, follow the protocol in `docs/architecture/encountered-issues-system.md`

## Token Optimization (rtk)

**Status:** Trial (installed 2026-03-24)
**Assessment:** `docs/research/rtk-assessment.md`

[rtk](https://github.com/rtk-ai/rtk) is a CLI proxy that compresses terminal output before Claude Code sees it. Installed as a PreToolUse hook — it rewrites Bash tool commands (e.g., `git status` → `rtk git status`) and returns compressed output.

### What rtk affects

- **Only Claude Code Bash tool calls.** Sharkrite's own scripts (`workflow-runner.sh`, `assess-and-resolve.sh`, etc.) call `git`/`gh`/`jq` directly — rtk never touches them.
- **Phase 1 (development)** is where savings happen: `git status`, `git diff`, test runs, `grep`, `cat`, `ls`, etc.
- **Phases 2-5** are unaffected. All Sharkrite `gh` calls use `--json` which rtk passes through unfiltered.
- **stdin piping** (fix-review mode) is unaffected — the hook only rewrites command strings, not stdin.

### Configuration

```
~/.config/rtk/config.toml     # Global config (exclusions, tracking, limits)
.rtk/filters.toml             # Project-local filter overrides (committable)
~/.claude/hooks/rtk-rewrite.sh # The PreToolUse hook (created by rtk init)
```

**Excluded commands:** `cat`, `head`, `tail` — rtk rewrites these to `rtk read` which strips code comments. This can cause Claude to write code that doesn't match a file's existing commenting style.

### Diagnosing rtk issues

If Claude behaves oddly during development (re-running commands, misinterpreting results, style mismatches):

```bash
# Check what rtk is doing
RTK_TOML_DEBUG=1 rtk git status     # Shows which filter matched

# Check savings stats
rtk stats                            # Overall savings
rtk stats --detail                   # Per-command breakdown

# Temporarily disable (removes hook, keeps binary)
rtk init --global --uninstall

# Re-enable
rtk init --global --hook-only

# Exclude a specific command
# Edit ~/.config/rtk/config.toml → [hooks] exclude_commands = ["cat", "head", "tail", "<cmd>"]
```

### Weekly health report

A launchd job (`com.sharkrite.health-report`) runs every Monday at 9:07 AM and generates `.rite/reports/rite-health-YYYYMMDD.md`. It collects diagnostic log data, rtk stats, recent sharkrite git changes, and previous reports, then pipes everything to Claude for analysis.

The report uses **absolute thresholds** (not before/after comparison):
- Fix iterations avg > 2.0 → WARNING
- Any phase failing > 30% → WARNING
- Phase 1 duration avg > 20 min → WATCH
- rtk savings < 30% → WATCH

Skips entirely if fewer than 3 workflow completions in the past 7 days.

```bash
rite --health-report              # Generate and display now
rite --health-report --latest     # Show most recent without regenerating
```

### Diagnostic logging

Structured `[diag]` lines are logged to `RITE_LOG_FILE` at key workflow points for health report aggregation:

- `WORKFLOW_COMPLETE` — issue number, fix iterations, rtk savings per phase
- `ASSESSMENT` — per-issue assessment counts (NOW/LATER/DISMISSED)
- `REVIEW` — review severity counts (CRITICAL/HIGH/MEDIUM/LOW)
- `PHASE_FAILED` — which phase failed and for which issue
- `SESSION` — Claude session mode and exit code

If rtk causes more token waste (re-runs, confusion) than it saves, uninstall: `rtk init --global --uninstall && brew uninstall rtk`
