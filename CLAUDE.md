# Sharkrite Development Guide

AI-powered GitHub workflow automation CLI. Pure bash, uses Claude Code for development and review.

**Mako** — the Claude Code assistant for this repo. Named after the fastest shark.

## Claude Code Message Board

**Location:** `~/Dev/CLAUDE-MESSAGE-BOARD.md`

Cross-project communication between Mako (sharkrite), Remora (clearance-screener), and Dace (freshup). Check this at the start of any session involving cross-project concerns — Remora and Dace post sharkrite feedback and feature requests here; Mako posts responses/resolutions.

**When to check:** Any session where you're improving sharkrite behavior, fixing workflow bugs, or when the user mentions feedback from another repo. Also check when starting a new session after a gap — there may be unread messages.

## Behavioral Design

**Reference:** `docs/architecture/behavioral-design.md` — living document of design decisions, behavioral contracts, and rejected approaches. Check before modifying any subsystem. Update when adding or changing behavior.

**Conventions catalog:** `docs/architecture/conventions.md` — append-only catalog of shell conventions and anti-patterns. Auto-populated on merge via `<!-- sharkrite-convention -->` blocks in PR bodies. Load order: `CLAUDE.md` → `behavioral-design.md` → `conventions.md` → issue-specific context. Each title is canonical — one entry per convention; multiple PRs accumulate their numbers in that entry's References line (see `behavioral-design.md` → "Conventions Catalog: Accumulate-in-Place Contract").

## Recurring Bug Pattern Catalog

**Reference:** `docs/architecture/encountered-issues.md` — auto-generated catalog of bug classes that recurred 2+ times during dogfooding. Check this when diagnosing a failure that looks familiar — it lists the variant signatures and fixes for each known pattern. Refreshed on demand via `rite --refresh-encountered-issues` (fetches closed issues labeled `recurring-pattern` from GitHub). Do not hand-edit; add patterns by labeling the originating closed issue.

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
lib/utils/adr-generator.sh        # generate_adr_for_ref helper (shared by bootstrap-docs.sh + assess-documentation.sh)
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

### Batch ↔ Single-Issue Parity Contract

`rite N1 N2 N3` must produce identical per-issue side effects as `rite Ni` for each issue. The batch is a thin orchestrator — per-issue work is delegated to `workflow-runner.sh::run_workflow()`. Closed-issue handling uses the shared `handle_closed_issue()` helper (defined in `workflow-runner.sh` above `run_workflow()`).

Any short-circuit that bypasses `run_workflow()` must be documented with `# Deliberate divergence from single-issue mode: <reason>` and covered by `tests/regression/batch-single-issue-parity.bats`. See full contract: `docs/architecture/behavioral-design.md` → "Batch ↔ Single-Issue Parity Contract".

**Closed-issue remote-branch cleanup — local-first contract:** `handle_closed_issue()` tracks `found_local_orphans` (true when steps 1–2 removed a worktree or local branch). Step 3 (remote branch deletion, network) only fires when `found_local_orphans=true OR pr_state != MERGED`. If local checks found nothing, any remote orphan is cosmetic — the periodic deep-clean in `merge-pr.sh` catches survivors. This prevents TCP-reset kills when the network call is a guaranteed no-op (live failure: issue #201, 2026-06-04). The MERGED gate is preserved as a secondary defense. In batch mode, `batch-process-issues.sh` prefetches remote refs so per-issue cleanup uses `git show-ref` (local) instead of `git ls-remote` (network). See: `docs/architecture/behavioral-design.md` → "Cleanup Operations Are Lazy About Network State" and "Network Calls During Closed-Issue Cleanup".

**Closed-issue cleanup fallback chain — how `pr_branch` is discovered:** `handle_closed_issue()` uses a three-tier fallback to find the branch name for artifact cleanup: (1) `closedByPullRequestsReferences` from the GitHub graph (fast path, most issues), (2) PR-body search across the last 1000 closed PRs for "Closes #N" keywords (covers high-churn repos where PRs fall off the old 50-result window), (3) local `git worktree list` scan matching by `_b<N>` batch suffix (whole-token, prevents substring collisions) or by issue title slug (covers non-batch orphans). Tier 3 is conservative: multiple candidates → skip cleanup rather than guess. See: `docs/architecture/behavioral-design.md` → "Closed-Issue Cleanup Fallback Chain".

### Data Flow

- `assess-review-issues.sh` outputs assessment to **stdout** (pipe-friendly)
- `assess-and-resolve.sh` captures stdout, decides to loop (exit 2) or merge (exit 0)
- `workflow-runner.sh` captures exit codes and stdout to pass review content to fix mode
- **stderr** is used for all user-facing output (print_info, print_warning, etc.)

### Phase 3 — Review Staleness Contract (CRITICAL)

**Staleness detection is SHA-based, not timestamp-based** (issue #354). `local-review.sh` embeds the HEAD SHA in the review marker at generation time:
```
<!-- sharkrite-local-review model:X timestamp:Y commit:<sha> -->
```
`assess-and-resolve.sh` extracts this SHA and compares it to the current HEAD:
- SHA match → review covers HEAD, assess it (no reroute)
- SHA is ancestor → genuinely stale, reroute to Phase 2
- No SHA in review → fallback to epoch-seconds timestamp comparison (backward compat for pre-#354 reviews)

**Do NOT replace SHA comparison with timestamp comparison.** Timestamps are racy (GitHub API eventual consistency lag). See `docs/architecture/behavioral-design.md` → "Stale Review Loop — SHA-Based Staleness Detection".

### Model Selection Per Task

Each task uses the model that fits its nature. Three independent model vars — changing one does not affect the others:

| Task | Var | Default | Why |
|------|-----|---------|-----|
| Code review | `RITE_REVIEW_MODEL` | `claude-opus-4-8` | Deep reasoning, broad context — catches edge cases that matter |
| Doc assessment | `RITE_DOC_ASSESSMENT_MODEL` | `claude-sonnet-4-6` | Structured pattern matching and comparison — sonnet's sweet spot |
| Development | `RITE_CLAUDE_MODEL` | `claude-sonnet-4-6` | General implementation work |

**Never pass `""` as the model arg** to `provider_run_prompt_with_timeout` and rely on defaults — use an explicit role via `claude_provider_resolve_model`. See: `docs/architecture/behavioral-design.md` → "Model Selection Per Task".

## Shell Conventions

### CWD after worktree removal (CRITICAL)

When `merge-pr.sh` finishes a successful merge it removes the feature-branch worktree. The shell that called `merge-pr.sh` is still cd'd inside that now-deleted directory. **Any subsequent `gh` or `git` call from that shell will fail** with `fatal: Unable to read current working directory: No such file or directory`.

- `git -C "$RITE_PROJECT_ROOT" ...` works around it for direct `git` calls.
- `gh` does **not** honor `-C`; it always shells out to `git` in the current directory for repo detection. Adding `-C` to `gh` is not an option.
- The canonical fix is to `cd "$RITE_PROJECT_ROOT" || cd /` immediately after `merge-pr.sh` returns, before any subsequent `gh`/`git` call.

Live regression history:
- **2026-06-01** — Issue #161, PR #211 fixed this for `assess-documentation.sh` (a background subprocess spawned during merge cleanup).
- **2026-06-04** — Same bug pattern resurfaced in `workflow-runner.sh::phase_merge_pr` because PR #211's regression test only covered `assess-documentation.sh`. Issues #182 and #287 ran to successful merge (PRs #289, #291 landed in main), but `phase_merge_pr`'s `gh_safe pr view` for branch cleanup crashed afterward, causing the batch reporter to mark both as `failed`. Fixed in this PR.

**Enforcement:** Tests in `tests/regression/cleanup-cwd-after-worktree-removal.bats` assert the cd guard exists in both `assess-documentation.sh` and `phase_merge_pr`. Any new code path that runs `gh`/`git` after a worktree removal must add a similar test.

### Shell style (CRITICAL)

The project has a deliberate shell style that disagrees with shellcheck's defaults. **Do not "fix" code to match shellcheck's defaults if it follows the project style.** The policy is encoded in `.shellcheckrc` and enforced via `make check`.

| Element | Project style | Shellcheck rule | Why |
|---|---|---|---|
| Variable references | bare `$VAR` | SC2250 disabled | Codebase ratio is 2514 unbraced : 397 braced. Braces are required only when next char would extend the var name (e.g. `"${VAR}suffix"`); shellcheck still catches those as parse errors. |
| Test brackets | POSIX `[ "$x" = "y" ]` | SC2292 disabled | Codebase ratio is 1391 `[ ]` : 100 `[[ ]]`. Both work when properly quoted. |
| Quoting | existing patterns | SC2248 disabled | Over-broad; existing pattern is "quote when expansion could split or glob"; SC2248 wants quotes on every variable always. |
| Negation | `[ -n "$x" ]` over `[ ! -z "$x" ]` | SC2236 disabled | Readability preference; both work. |
| sed replacement | `echo "$x" \| sed 's/.../.../''` | SC2001 disabled | Parameter expansion is preferred for trivial cases but sed is fine here. |
| Group redirects | per-line `>> file` | SC2129 disabled | Code clarity preference. |

**Rules that ARE enforced (real bug risk):**
- SC2155: declare and assign separately (`local foo=$(cmd)` masks cmd's exit code under `set -e`) — currently disabled with a 125-occurrence ledger; new violations must be addressed.
- SC2034: unused variables — currently disabled with a 49-occurrence ledger; new violations must be addressed.
- SC2086: word splitting / globbing — fix or quote.
- SC2168: `local` outside function — covered by both shellcheck and our `LOCAL_OUTSIDE_FUNCTION` custom rule.
- All shellcheck errors and remaining warnings.

**Severity filter:** Set in `Makefile` via `--severity=warning` (shellcheck 0.11.0's rcfile `severity=` directive is silently ignored — known shellcheck quirk; see `.shellcheckrc` for the inline note).

**Why CI was red for 100+ runs before this PR:** there was no `.shellcheckrc` declaring the project style, so every style preference fired. Branch protection wasn't enforcing the Lint check (PRs merged red anyway), so the broken-window problem compounded — new code was added without anyone running `make check` locally, then merged through red CI, then nobody felt motivated to clean up.

### Re-source safety (CRITICAL)

Every file in `lib/` MUST be safe to source multiple times under `set -euo pipefail`. Without a guard, sourcing a file twice can crash via readonly re-assignment, re-run interactive logic, or re-execute initialization code.

**Live failures that resulted from missing or wrong guards:**

| Date | File | Root cause |
|---|---|---|
| 2026-05-31 | `assess-documentation.sh` | `verbose_info` undefined — missing dep source (#61) |
| 2026-05-31 | `issue-lock.sh` | Guard checked `RITE_LIB_DIR` instead of `RITE_LOCK_DIR` (#69) |
| 2026-06-01 | `stash-manager.sh` | `readonly` crash on re-source (commit 2267841) |
| 2026-06-01 | `claude.sh` | Source-path construction bug (commit 93c7ddd) |

**Canonical guard pattern — function libraries:**

```bash
# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f <canonical_function_name> >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi
```

Place this block immediately after `set -euo pipefail`, before any `source` calls or variable assignments. Pick any function that is stable and defined only by this file as the sentinel.

```bash
# Example: lib/utils/timeout.sh
set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f ensure_timeout_cmd >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ... function definitions and initialization follow
ensure_timeout_cmd() { ... }
```

**Dependency-load pattern:**

Source dependencies using absolute paths derived from `BASH_SOURCE[0]`, not from guessed env vars:

```bash
# GOOD: absolute path from this file's location
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_self_dir/../utils/colors.sh"

# ALSO GOOD: use RITE_LIB_DIR if config.sh bootstrapped it
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_self_dir/config.sh"
fi
source "$RITE_LIB_DIR/utils/colors.sh"
```

**Pattern for executable files that are also sourced by tests:**

Executables that define helper functions AND run a program body should use `RITE_SOURCE_FUNCTIONS_ONLY=1` to separate the function definitions from the executable body (see `local-review.sh` as reference):

```bash
# Function defs here (no top-level side effects)
my_helper_function() { ... }

# Guard: when sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, stop here
# so tests can load only function definitions without running the program.
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# Executable body follows (git commands, network calls, interactive prompts)
```

**Canonical guard pattern — standalone scripts (orchestrators with top-level executable code):**

Use an env-var guard when the file has top-level executable code (network calls, interactive prompts, `git` commands) that cannot be function-wrapped:

```bash
# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_FOO_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_FOO_LOADED=true

# ... rest of file follows
```

The `_RITE_*_LOADED` naming convention is consistent across all orchestrators:
- `_RITE_ASSESS_AND_RESOLVE_LOADED` — `lib/core/assess-and-resolve.sh`
- `_RITE_BATCH_PROCESS_LOADED` — `lib/core/batch-process-issues.sh`
- `_RITE_CLAUDE_WORKFLOW_LOADED` — `lib/core/claude-workflow.sh`
- `_RITE_CREATE_PR_LOADED` — `lib/core/create-pr.sh`
- `_RITE_MERGE_PR_LOADED` — `lib/core/merge-pr.sh`
- `_RITE_UNDO_WORKFLOW_LOADED` — `lib/core/undo-workflow.sh`
- `_RITE_WORKFLOW_RUNNER_LOADED` — `lib/core/workflow-runner.sh`
- `_RITE_CLEANUP_WORKTREES_LOADED` — `lib/utils/cleanup-worktrees.sh`
- `_RITE_FORMAT_REVIEW_LOADED` — `lib/utils/format-review.sh`
- `_RITE_VALIDATE_SETUP_LOADED` — `lib/utils/validate-setup.sh`

**`readonly` declarations (CRITICAL):**

`readonly VAR=value` at the top level of a sourced file **crashes** with "readonly: VAR: is read-only" when the file is sourced a second time under `set -euo pipefail`. Fix in priority order:

1. **Add a re-source guard** (preferred) — the `declare -f` or `_RITE_*_LOADED` guard prevents the `readonly` line from executing a second time.
2. **Change to idempotent assignment** — `VAR="${VAR:-default_value}"` works even without a guard.

```bash
# BAD: crashes on second source
readonly SHARKRITE_STASH_MARKER="sharkrite-stash:"

# GOOD option 1: guard prevents re-execution (readonly line unchanged)
if declare -f create_sharkrite_stash >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi
readonly SHARKRITE_STASH_MARKER="sharkrite-stash:"   # only runs once

# GOOD option 2: idempotent assignment (no guard required)
SHARKRITE_STASH_MARKER="${SHARKRITE_STASH_MARKER:-sharkrite-stash:}"
```

**Enforcement:** Lint rules `MISSING_RESOURCE_GUARD` (Rule 16) and `UNGUARDED_READONLY` (Rule 17) in `tools/sharkrite-lint.sh` (invoked by `make check`). Regression test in `tests/regression/lib-resource-safety.bats` sources every lib file twice and asserts both sources exit 0.

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

### Unanchored marker grep (bare-prefix guard, CRITICAL)

When greping for a sharkrite marker in issue body text, the outer guard **must** require a format anchor. Without one, any issue body that *documents* the marker format (e.g. `sharkrite-parent-pr:N` as a placeholder) will match, the inner extraction will return empty, and under `set -e + pipefail` the script dies silently.

**Live bug (2026-05-31):** Three `rite --label testing` batch runs died silently at Processing Issue #34. Root cause: `grep -q "sharkrite-parent-pr:"` matched #34's body, which listed the marker as a documentation example. Inner extraction with `[0-9]+` returned nothing, `pipefail` propagated exit-1 up, `set -e` killed the batch silently. Emergency fix: commit `206f2be`. Codebase sweep + regression test added in issue #90.

```bash
# BAD: outer guard without format anchor — matches documentation placeholders
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  # If ISSUE_BODY contains "sharkrite-parent-pr:N" (a docs example), inner grep
  # returns empty, pipefail kills the script silently
fi

# GOOD: outer guard requires digits — rejects all placeholder text
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
  # Only enters branch when body has a real numeric marker value
fi
```

**Rule:** Any `grep -q` or `grep -qE` against `"sharkrite-[marker-name]:"` must include `[0-9]+` (or equivalent format anchor) in the same pattern. Never use bare-prefix guards for structured markers.

**Enforcement:** Custom lint rule `BARE_MARKER_GREP` in `tools/sharkrite-lint.sh` (invoked by `make check` CI gate). Regression test in `tests/regression/bare-prefix-grep-silent-death.bats`.

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

### macOS bash 3.2 compatibility (CRITICAL)

Scripts with a `#!/bin/bash` shebang are executed by macOS system bash 3.2 when invoked directly (e.g., from `bin/rite`). Bash 3.2 does **not** have the following bash 4.0+ features:

- `mapfile` / `readarray` (array-population builtins)
- `declare -A` (associative arrays)

**Live crash (2026-06-04):** `rite --undo <N>` with follow-up issues exploded with `mapfile: command not found` when run without Homebrew bash on PATH (issue #327). Same class of bug as issue #266 (`TEMP_FILES[@]` empty-array under bash 3.2).

**Fix options (in priority order):**

1. **Replace with portable equivalent** (preferred for isolated usages) — replace `mapfile -t ARR < <(cmd)` with a `while IFS= read -r` loop:

   ```bash
   # Portable dedup that works on bash 3.2 (no mapfile builtin).
   _tmp_unique=()
   while IFS= read -r _line; do
     _tmp_unique+=("$_line")
   done < <(printf '%s\n' "${ARR[@]}" | sort -un)
   ARR=("${_tmp_unique[@]+"${_tmp_unique[@]}"}")
   ```

   The `"${arr[@]+"${arr[@]}"}"` idiom prevents the bash 3.2 "unbound variable" failure for empty arrays under `set -u` (PR #266 pattern).

2. **Self-re-exec guard** (preferred when a script needs multiple bash 4+ features) — add at the top, matching the established pattern in `batch-process-issues.sh:69-77`:

   ```bash
   if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
     for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
       if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "$BASH" ]; then
         exec "$_newer_bash" "$0" "$@"
       fi
     done
     echo "Error: requires bash 4+. Install via: brew install bash" >&2
     exit 1
   fi
   ```

**Do NOT** change shebangs to `#!/usr/bin/env bash` — the `/bin/bash` shebang is the deliberate Sharkrite choice for scripts in `lib/`, `bin/`, and `tools/`. Write portable code instead.

**Enforcement:** Lint rule `BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT` (Rule 21) in `tools/sharkrite-lint.sh` flags `mapfile`, `readarray`, and `declare -A` in `#!/bin/bash` scripts without a `BASH_VERSINFO` guard. Regression tests: `tests/regression/undo-workflow-bash-3-2-compat.bats` and `tests/lint/bash-4-builtin-detection.bats`.

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
- **Session limits** — dual-cap model (issue #283):
  - **Per-issue cap** (`RITE_MAX_ISSUE_HOURS`, default 4h): fires when a single issue runs too long (fix-loop / yak-shave protection)
  - **Cumulative session cap** (`RITE_MAX_SESSION_HOURS`, default 12h): fires when total active work time across all issues in this session exceeds the threshold. Measures actual work, not wall-clock age of the state file — a zombie file from a prior crash contributes 0h.
- **AWS credentials expired** — deployment credentials invalid
- **Supervised mode**: Interactive `read -p` prompt for approval
- **Unsupervised mode**: Stops workflow (unless `--bypass-blockers`)
- Approvals remembered per-issue via `has_approved_blocker()`

### Stale Branch Handling

When resuming an issue with an existing PR, the branch is checked against `origin/main`. Controlled by `RITE_STALE_BRANCH_THRESHOLD` (default: 10 commits).

- **Below threshold**: Rebase the feature branch onto `origin/main` (replays branch commits on top of fresh main), then force-push with `--force-with-lease`. Rebase avoids the false conflicts a merge would surface when main has added files since branch creation. If the rebase conflicts, `attempt_claude_merge_resolution` is invoked when available; otherwise auto mode bails and supervised mode prompts.
- **At/above threshold (auto)**: Close PR with summary comment, cleanup branch/worktree, continue workflow fresh (no restart needed — falls through to development phase).
- **At/above threshold (supervised)**: Prompt with 5 options (close+restart recommended, rebase onto main, merge main into branch [legacy], continue, abort). The legacy merge path is kept opt-in for cases where rewriting history is unacceptable.

Check runs in `workflow-runner.sh` after PR/worktree detection, before phase-skip logic. Returns exit code 11 to signal "restarted fresh" — caller resets all resume state variables.

### Assessment Timeout

Phase 3 (assess-and-resolve) calls Claude to classify each review finding. Controlled by `RITE_ASSESSMENT_TIMEOUT` (default: 300s). Exit code 124 on timeout → falls back to creating a follow-up issue with all items.

If you see `⚠️ Assessment timed out after 300s`, bump to 600s:
```bash
export RITE_ASSESSMENT_TIMEOUT=600
```
Or set it per-project in `.rite/config`. See `config/project.conf.example` for the commented option.

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

Auto-discovery injects grounding context beyond the explicit doc path: ADRs (`docs/**/*adr*.md`), root `README.md`, and remaining `docs/**/*.md` up to `RITE_PLAN_DOC_BYTE_CAP` bytes (default 50 KB). ADRs and README always load in full; other docs are dropped alphabetically when the cap is hit. Set `RITE_PLAN_DOC_BYTE_CAP=0` to disable entirely. Set `RITE_PLAN_INCLUDE_README=false` to skip README injection without disabling other auto-discovery. Doc block headers use project-relative paths (e.g., `--- docs/architecture/adr-001.md ---`) to prevent identical-label collisions when multiple files share the same basename.

The full `rite <issue>` resume correctly detects state (via PR comments/commits) and skips completed phases, so running standalone commands then resuming with the full lifecycle works seamlessly.

### PR Detection (`lib/utils/pr-detection.sh`)

Shared utilities used by standalone commands and the orchestrator:

- `detect_pr_for_issue ISSUE_NUMBER` — finds PR by body text search (Closes #N)
- `detect_worktree_for_pr PR_NUMBER` — finds local worktree for PR branch
- `detect_review_state PR_NUMBER [WORKTREE_PATH]` — checks review existence and currency

Uses local git timestamps when worktree is available (avoids GitHub API eventual consistency).

### Worktree → Issue Mapping (`lib/utils/issue-lock.sh`)

The lock file is the **source of truth** for the worktree → issue association displayed by `rite --status`. When `acquire_issue_lock` runs, it writes:
- `${RITE_LOCK_DIR}/issue-N.lock/pid` — the holding process PID (required for live locks)
- `${RITE_LOCK_DIR}/issue-N.lock/cwd` — the worktree path (used by `repo-status.sh` for mapping)

Worktrees created before the lock infrastructure (PR #67, commit eb714e6) — or worktrees that bypassed the lock — have no lock file, so `rite --status` cannot associate them with an issue. The `backfill_worktree_locks()` function in `issue-lock.sh` fixes this retroactively: it walks `git worktree list`, queries each branch's open PR for a "Closes #N" reference, and writes a minimal lock dir (cwd + backfill sentinel, no pid) for legacy worktrees. `repo-status.sh` calls this automatically at the top of `repo_wide_status()`.

**One-time cleanup** for pre-existing installs: `rite --backfill-locks`

**Backfill lock format** — distinguished from a live lock by the absence of a `pid` file and the presence of a `backfill` sentinel file:
```
${RITE_LOCK_DIR}/issue-N.lock/
  cwd          ← worktree path (same as live lock)
  backfill     ← sentinel: identifies this as a backfill, not a live process lock
  # NO pid file — so get_locked_issue_numbers() skips it, acquire_issue_lock can reclaim it
```

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
make test               # Run test suite (requires bats)
bats tests/             # Run test suite directly (bypasses make wrapper)
```

**Custom lint rules** (in `tools/sharkrite-lint.sh`) catch patterns shellcheck misses:
- `grep -c ... || echo "0"` — produces double zero (use `|| true`)
- `git push` without refspec — dangerous in automation
- `eval` with GitHub API data — security risk
- Unquoted heredoc in command substitution — use `<<'EOF'`
- BSD `sed -i ''` without GNU fallback
- `PIPESTATUS[0]` after `|| true` — value is lost
- `local` outside function — only works inside functions
- Test stub committed to production path (`TEST_STUB_IN_LIB`) — files in `lib/core/`, `lib/utils/`, `lib/providers/` must never start with `# Stub `, reference `MOCK_*_FILE` env vars, or contain the literal `STUB ERROR`. These are integration-test fixtures and indicate an accidental wholesale overwrite of real code.
- `BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT` (Rule 21) — `mapfile`, `readarray`, or `declare -A` in a `#!/bin/bash` script without a `BASH_VERSINFO` re-exec guard. Crashes on macOS system bash 3.2. Add a self-re-exec guard (see `batch-process-issues.sh:69-77`) or replace with a portable while-read loop.

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
- `BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT` — for scripts that are guaranteed to run under bash 4+ through another mechanism (document the reason clearly)

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
  - `workflow-runner.sh` (`handle_closed_issue`): exit 12 for "issue was already closed at start, no new work done". **Single-issue mode exits 0** (surprising non-zero would break `set -e` chains in nightly automation). **Batch mode exits 12** — `batch-process-issues.sh` uses this sentinel to skip the post-issue gh API calls (pr list / pr view x3 / issue list) that are only meaningful after active dev work. Batch capture pattern: `_WF_EXIT=0; cmd || _WF_EXIT=$?` (never bare `if cmd; then` when exit 12 must be distinguished from exit 0). See `docs/architecture/exit-codes.md`.
- **RITE_ORCHESTRATED**: When `workflow-runner.sh` calls `claude-workflow.sh`, it sets `RITE_ORCHESTRATED=true`. This tells `claude-workflow.sh` to skip its internal PR/review workflow (create-pr.sh call) — those are handled by the orchestrator's Phase 2/3. Without this, reviews get generated twice.
- **Encountered Issues**: When discovering out-of-scope issues during development, follow the protocol in `docs/architecture/encountered-issues-system.md`
- **Phase handoff cwd contract**: When `phase_merge_pr` returns, cwd is always `$RITE_PROJECT_ROOT` — it restores cwd after removing the worktree. Any phase that runs after merge (e.g. `phase_completion`) must also start with `cd "$RITE_PROJECT_ROOT" 2>/dev/null || true` as defense-in-depth. Violating this causes `fatal: Unable to read current working directory` from `gh`'s internal git probe. See `docs/architecture/behavioral-design.md` → "Phase Handoff cwd Invariants" and `tests/regression/post-merge-cwd-restored.bats`.
- **`exec` does NOT fire EXIT traps**: Releasing a lock-trap-protected resource via an EXIT trap does NOT work across `exec`. When a script execs itself to restart (e.g., after stale-branch or empty-branch auto-recovery), the process image is replaced and all registered traps are cleared. Any resource held via `trap "release ..." EXIT` must be released **explicitly before the `exec` call**. Live failure: issue #343 batch run 2026-06-06. See `docs/architecture/behavioral-design.md` → "Lock Release Before exec".
- **Temp file cleanup globs in trap handlers**: Never use a glob (`rm -f /tmp/prefix_*.txt`) in a cleanup trap. Under concurrent runs (e.g. a batch retry overlapping with a manual `--assess-and-fix`, or two batch slots hitting the same phase), a glob in one invocation's EXIT trap wipes peer files mid-run. Use `rm -f "${MY_FILE:-}"` (scoped to the specific variable this invocation set) and name files with a PID suffix (`/tmp/prefix_${KEY}_$$.txt`) so each invocation owns a distinct path. Live failure: issue #345 batch run 2026-06-06 — `assess-and-resolve.sh` glob wiped a peer PR's review file between write and read. See `tests/regression/assess-and-resolve-temp-file-isolation.bats`.

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
