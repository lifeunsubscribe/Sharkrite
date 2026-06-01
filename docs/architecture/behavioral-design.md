# Sharkrite Behavioral Design

Living document of design decisions, behavioral contracts, and rejected approaches. Updated as behaviors change. If you're modifying any subsystem described here, update this doc in the same change.

---

## Development Phase (claude-workflow.sh)

### Claude Dev Session

Claude runs inside a sandboxed session with `--disallowedTools` blocking git/gh commands. The workflow handles commit, push, and PR creation after the session exits.

**Testing inside dev sessions:** Claude should NOT run the full test suite during development. The test gate runs it automatically after the session with parallel execution (xdist). Claude should only verify its new code imports/compiles. Running the full suite inside the session wastes significant time (observed: Claude runs the suite 2-3x "to make sure," each taking 45s+).

**Exit codes from claude-workflow.sh:**
- 0 = success (work produced)
- 3 = test gate failed
- 4 = session completed but no work produced (empty dev)

### Exit Code 4: Empty Dev Output

When Claude's dev session produces zero file changes:
- **Standalone mode:** Cleans up empty branch and draft PR, exits 0
- **Orchestrated mode:** Exits 4 so workflow-runner can retry

**Retry behavior:** workflow-runner retries once on exit 4. After retry failure, closes the empty draft PR (checks `additions == 0` before closing) to prevent stale PR loops on next run.

**Why this exists:** Issue #135 failed repeatedly because Claude found similar tests in other domains and concluded "already done." The empty-dev detection + retry + cleanup prevents stale PRs from accumulating.

### Test Gate Auto-Fix

When the post-dev test gate fails in auto mode:
1. Captures test failure output
2. Runs a quick Claude fix session with failures as context
3. Fix session is told NOT to run the full suite (just fix the code)
4. Test gate re-runs the full suite after the fix
5. If still failing, exits 3 (blocker)

One attempt only. The fix prompt includes the test command and failure summary.

**Why not just fail immediately:** In batch mode, failing stops the issue and moves on. A quick fix attempt (30-60s) is cheaper than a full resume cycle. The dev session already did the hard work — test failures are usually small mismatches.

### Pytest Auto-Optimization

When sharkrite detects pytest as the test runner:
- **xdist:** If `pytest-xdist` is already installed in the project's environment, adds `-n auto` for parallel execution. Sharkrite never auto-installs dependencies the project didn't declare — injecting packages can cause version incompatibilities.
- **Noise reduction:** Adds `--tb=short -W ignore::DeprecationWarning -q` to suppress verbose tracebacks and deprecation spam.

Applied in both `run_test_gate()` (claude-workflow.sh) and `verify_post_merge()` (post-merge-verify.sh).

### Post-Merge Dependency Reinstall

When merging main into a feature branch, `verify_post_merge()` checks if dependency manifests (requirements.txt, package.json, etc.) changed in the merge diff. If so, it reinstalls dependencies before running tests.

**Why:** Worktree venvs become stale after merging main — new packages from main's requirements.txt aren't installed, causing `ModuleNotFoundError` in tests even though the package is listed. This was discovered when a scraper PR added `defusedxml` to requirements.txt, merged to main, and then every feature branch that merged main failed tests because `defusedxml` wasn't in their venv.

**Detection:** `git diff HEAD~1 --name-only` checked against known dependency file patterns. Only runs the install when files actually changed — no-op on merges that don't touch deps.

### Post-Merge Main Poisoning Detection

As a safety net, when tests fail after merge AND after dependency reinstall, `verify_post_merge()` checks whether main itself is broken:

1. Creates a temporary worktree at `origin/main`
2. Runs the same test suite against main's code
3. If main also fails → reports "main is broken" and **allows the workflow to proceed**
4. If main passes → real semantic conflict, blocks as before

**Why:** Defense-in-depth. If main has a genuine bug (not just a stale venv), this prevents it from cascading to every feature branch.

**Cleanup:** The temporary worktree is removed after the check, even on failure.

---

## Batch Processing (batch-process-issues.sh)

### Active Process Filtering

Before processing, the batch checks for already-running rite processes:
1. Snapshots `ps -eo pid,command`
2. Greps for `workflow-runner.sh <issue_num>` or `claude-workflow.sh <issue_num>`
3. Skips issues with active processes

This runs BEFORE session limit truncation so active issues don't waste slots. Runs in the pre-start phase, not the per-issue loop.

### Dependency Detection

Parses issue body for dependency patterns:
- `After: #N`, `After #N` (with or without colon)
- `Depends on #N`, `Blocked by #N`

Checks two conditions:
1. Dependency failed/blocked/skipped in this batch → skip
2. Dependency issue is still OPEN (PR not merged) → skip

**Why check open state:** A dependency's PR may have been created in this batch but not yet merged. Processing the dependent issue before the dependency merges causes failures (missing code/models).

### Session Timer

`init_session` resets the session clock. workflow-runner does NOT call `init_session` when `BATCH_MODE=true` — the batch owns the session timer. Without this, each child workflow-runner resets the clock and the batch summary shows "Duration: 2s."

---

## Plan System (plan-issues.sh)

### Coverage Checklist Validation

After generation, `_validate_coverage` finds checklist ✅ entries with no matching `---ISSUE---` block (phantoms). For each phantom:
1. Passes the title to a Claude call along with existing issues, deferrals log, and accumulated feedback
2. Claude decides: GENERATE (real gap) or SKIP (covered by existing issue or deferral)
3. Only well-formed `---ISSUE---`/`---END---` blocks from the phantom output are appended
4. `_dedup_issues` runs after append

**Why Claude decides instead of bash keyword matching:** Tried keyword matching against deferrals log — failed because feature names vs issue titles use different phrasing ("Snack suggestion view" vs "[Phase 1G] Add snack suggestion endpoint"). Claude does semantic matching reliably.

**Rejected approach: bash keyword extraction.** Extracted top-2 words from feature names and matched against deferrals. Failed on words like "view" that don't appear in the deferral text. Fragile and unmaintainable.

### Feedback Persistence

User feedback accumulates within a session (`accumulated_feedback` variable). On plan approval, feedback is saved to `.rite/plan-feedback.md`. On next session start, this file is loaded as the initial `accumulated_feedback` and passed to the first generation.

**Why this exists:** Fresh runs lost corrections from previous sessions. The iteration run (with feedback context) consistently outperformed the fresh run (without). Persisting feedback bridges sessions.

### Deferral Extraction from Feedback

When user gives feedback containing deferral-like language ("defer X to Phase Y", "drop the snack endpoint"), `_persist_feedback_deferrals` extracts those lines and appends them to `.rite/deferrals.log` immediately — not on plan approval. This ensures deferrals survive even if the user abandons the session.

`_save_deferrals` (on approval) preserves feedback-based deferrals (lines containing "user feedback" marker) when overwriting with the current plan's ⏭️ items.

**Why immediate persistence:** The user gave feedback to defer the snack endpoint 4+ times across sessions. Each fresh run re-generated it because the deferrals log never contained it (no plan was approved with it as ⏭️). Immediate persistence broke the loop.

### Service Layer Lint

Post-generation lint (`_lint_issues`) detects and fixes anti-patterns:

1. **Detection:** Checks the actual filesystem for `*_service.py` files in common service directories (`src/services/`, `services/`, etc.). Does NOT check prompt text or generated output (circular dependency — if Claude omits services, checking the output for services would never trigger).

2. **"DO NOT create service layer" removal:** Deletes scope boundary lines that reject the service pattern.

3. **Service file injection:** For CRUD issues that have a router in "Files to Modify" but no service file, derives the service filename from the router name and injects it. Only looks in the "Files to Modify" section (not "Files to Read" which may reference other routers as patterns).

**Why filesystem detection:** Previous approach checked `project_context` (CLAUDE.md) for service mentions. Freshup's CLAUDE.md didn't mention services, so the lint never fired. The filesystem is authoritative — if `auth_service.py` exists, the project uses services.

### Marker Normalization (jq streaming fix)

The `jq -rj` streaming mode concatenates text chunks without newlines. `---ISSUE---` and `---END---` can end up mid-line: `...text---ISSUE---TITLE: ...`. The normalization forces markers onto their own lines via `sed 's/---ISSUE---/\n---ISSUE---\n/g'`. Applied to both main generation and phantom output.

The phantom path additionally extracts only well-formed blocks via `sed -n '/^---ISSUE---$/,/^---END---$/p'` — Claude commentary before/after blocks is discarded.

### Shared Item Permissions Rule

The plan prompt includes: "If an entity uses a shareability model and shared items are visible in read endpoints, non-destructive operations (consume, purchase) MUST also be accessible to any authenticated user." This prevents the recurring bug where consume endpoints defaulted to owner-only 404 while read endpoints correctly showed shared items.

---

## Review & Assessment (assess-review-issues.sh, assess-and-resolve.sh)

### Follow-up Issue Context

Follow-up issues from ACTIONABLE_LATER findings include:
- PR title in the issue title for domain context (e.g., "[tech-debt] Grocery filtering: review feedback from PR #132")
- `**Location:**` field required for ACTIONABLE_LATER items (not just ACTIONABLE_NOW)
- PR title in the issue body

**Why:** Issue #135 failed repeatedly because its body said "cross-user tests missing" without specifying which domain. Claude found tests in recipes/inventory and concluded "done." The grocery domain (which had zero tests) was never mentioned.

### Review Comment Filtering (CRITICAL)

All review comment queries MUST filter by body marker (`contains("<!-- sharkrite-local-review")`), NOT by author login. Author-based filtering (`.author.login == "claude"` etc.) picks up non-review comments (assessments, issue notifications) posted by the same authenticated user.

**Phase 2** (workflow-runner.sh `phase_create_pr`) and **Phase 3** (assess-and-resolve.sh) must use the same filter to agree on which comment is "the latest review." Filter mismatch causes Phase 2 to skip review regeneration while Phase 3 detects stale review → infinite reroute loop.

**Timestamp comparison:** Always use epoch seconds (`date "+%s"` with BSD/GNU detection), never bash string comparison (`[[ > ]]`) or jq string comparison. ISO 8601 lexicographic comparison works for identical formats but breaks silently on format differences (fractional seconds, timezone offsets).

**Why:** Freshup issue #231 hit a stale review loop — rerouted 2 times without generating a fresh review. Root cause: Phase 3 used a wider author-based filter that could pick up assessment comments, and Phase 2 used lexicographic string comparison for timestamps.

### LOW Severity Threshold

LOW findings only become ACTIONABLE_LATER if they represent a real functional or security concern. "Consider doing X" and style suggestions are DISMISSED. Added after 5 of 7 tech-debt issues were closed as noise (code aesthetics, hypothetical optimizations, intentional patterns flagged as problems).

---

## Diagnostic Timing

`_timer_start` / `_timer_end` in `logging.sh` track wall-clock time for:
- Phase transitions (workflow-runner.sh)
- Claude dev sessions (claude-workflow.sh)
- Test gate runs (claude-workflow.sh)
- Review generation (local-review.sh)
- Assessment (assess-review-issues.sh)
- Fix sessions (claude-workflow.sh)

**Output:** In verbose mode, prints to stderr. In auto mode, writes to log file only. Also drives a live terminal timer (updates every 5s via background process writing to `/dev/tty`).

**Why:** Issue #191 (45min estimate) took 10 hours wall clock. Without timing data, couldn't determine whether the delay was API latency, laptop sleep, or a hanging process.

---

## Locking System (issue-lock.sh, scratchpad-lock.sh, session-tracker.sh)

### PID-Based Stale Reclamation: Same-Host Assumption

All three lock implementations use `kill -0 $PID` to decide whether a lock-holding process is still alive before reclaiming its stale lock. This is an intentional design constraint, not a bug.

**What it means:** `kill -0` sends no signal but checks whether the process exists in the caller's process table. It is only valid within a single host and PID namespace. Two failure modes arise when this assumption is violated:

- **PID recycling across hosts:** If `RITE_LOCK_DIR` or `SCRATCHPAD_FILE`'s lockfile is on shared/network storage (NFS, SMB, EFS, etc.) and two hosts can both access the same lock path, a stale lock from host A will have a PID that refers to an unrelated process on host B. `kill -0` returns 0 (process exists), so the lock is never reclaimed → deadlock.

- **Isolated PID namespaces:** A container or VM with its own PID namespace can have a PID that is valid inside the namespace but refers to something completely different (or nothing) on the host. Same false-positive risk.

**Why this is acceptable:** Sharkrite is designed for single-developer use on a single machine. All lock paths default to project-local directories inside `$RITE_PROJECT_ROOT/.rite/`, which are never on shared storage.

**What to do if you need cross-host locking:** Replace the `kill -0` reclamation with a time-based TTL (e.g., reclaim any lock older than N seconds). TTL-based reclamation requires no process-table access and is safe across hosts at the cost of a minimum stale-lock hold time.

**Affected files and lines:**
- `lib/utils/issue-lock.sh` — `acquire_issue_lock` and `acquire_pr_followup_lock`
- `lib/utils/scratchpad-lock.sh` — portable mkdir path only (the `flock` fast-path on Linux does not use `kill -0`)
- `lib/utils/session-tracker.sh` — `_acquire_session_lock` portable path

### PR Follow-up Lock: Timing Budget

The `acquire_pr_followup_lock` waiter times out after **60 seconds**. Under slow-GitHub conditions the holder can consume significantly more time inside the critical section than the ~5–10s typical case:

**Holder worst-case timing (assess-and-resolve.sh):**

| Step | Time (slow-GitHub) |
|---|---|
| Evidence validation (`gh issue view`) | up to 20s (gh_safe 3×: initial + 5s + 15s) |
| Dedup search loop — up to 4 `gh_safe` calls per iteration:<br>• `gh issue list` (body-marker search)<br>• `gh issue view` (marker verification; only if list found a candidate)<br>• `gh issue list` (title search; only if still no match)<br>• `gh pr view` (PR comment check; only if no match and not last retry) | up to 80s (20s × 4 calls) |
| Dedup index backoff loop (`_dedup_max_retries × RITE_DEDUP_BACKOFF`) | 3 × 5s = 15s (default) |
| **Plausible worst case** | **~115s** (exceeds the 60s waiter budget) |
| **Theoretical worst case** | more calls if loop retries multiple times; per-call cost is bounded at 20s (5s+15s backoff, no trailing sleep) — growth comes from call count, not per-call duration |

**What happens on waiter timeout:**
The waiter sets `_skip_followup_creation=true` and proceeds without the lock. This prevents creation of a duplicate follow-up issue but also prevents creation of *any* follow-up issue for this run. A `[diag] FOLLOWUP_LOCK_TIMEOUT` line is written to `RITE_LOG_FILE`. Recovery: re-run `rite N --assess-and-fix`.

**Why this doesn't cause data corruption:**
The skip-on-timeout is conservative — the follow-up may already have been created by the holder. The dedup guarantee is preserved (no duplicate created); the only loss is a missed creation in a concurrent slow-GitHub scenario.

**Tuning knobs** (set in `.rite/config` or environment):
- `RITE_DEDUP_BACKOFF` (default: 5s) — reduce to shorten holder dedup wait time
- `RITE_GH_MAX_RETRIES` (default: 3) — reduce to shorten gh backoff windows
- To increase the waiter budget: edit `max_attempts` in `acquire_pr_followup_lock` (not currently configurable via env)

---

## Decisions Log

### Removed: Plan Directives System

Directives were persistent per-project rules injected into the plan prompt (e.g., "always use service layer"). Removed because the user preferred fixing sharkrite's generic behavior over per-project config. Replaced by: feedback persistence, service layer filesystem lint, and stronger prompt instructions.

### Rejected: ADR Modification for Deferrals

Considered appending deferrals to the source ADR on plan approval. Rejected because the deferrals log already serves this purpose and modifying ADRs adds noise to source-of-truth documents.

### Rejected: Keyword Matching for Deferral Detection

Tried extracting significant words from feature names and matching against the deferrals log in bash. Failed because natural language phrasing varies ("view" vs "endpoint" vs "query"). Replaced by passing deferrals to the phantom Claude call for semantic matching.

### Rule: No Keyword Matching for Detection — Anywhere in Sharkrite

Generalizes the deferral-detection lesson into a project-wide rule. **Sharkrite must never use keyword/substring matching to decide whether a piece of text qualifies for some downstream behavior.** This pattern has bitten us repeatedly:

- **Deferral detection** (above) — words vary, semantic match needed
- **ADR auto-creation** (`assess-documentation.sh:470-471`) — matched on `"decision\|tradeoff\|alternative"`. Captures issue bodies that mention these words conversationally and misses architectural decisions that don't use the vocabulary
- **Parent-PR marker detection** (`batch-process-issues.sh:327`, fixed in `206f2be`) — matched on `"sharkrite-parent-pr:"` without anchoring on digits. Issue #34's body documented the marker format as an example and tripped the guard, killing the batch silently
- **ADR backfill** (`bootstrap-docs.sh`) — matches commit messages on `"refactor\|feat\|breaking\|migrate"` to decide ADR-worthiness. Same class of false positives and false negatives
- **Severity grep** in review/assessment (`merge-pr.sh:227`, fixed in milestone #28) — matched on bare `"CRITICAL\|HIGH\|MEDIUM"` and got triggered by phrases like "no critical issues found"

**Why keyword matching fails for this tool specifically:**

1. Issue/PR bodies routinely document marker formats, severity vocabulary, and decision keywords as examples. Any naive grep matches the documentation, not the data.
2. Natural language phrasing varies; users describe the same architectural decision in many ways.
3. LLM output is conversational, so even structured greps need careful anchoring (e.g. `^### .* - ACTIONABLE_NOW`, not bare `ACTIONABLE_NOW`).
4. False positives kill workflows silently under `set -euo pipefail`. False negatives drop work into the void.

**Use instead:**

- **Explicit markers with structural format** — `<!-- sharkrite-followup-issue:42 -->` (digits-anchored), `<!-- sharkrite-convention -->` (HTML-comment delimited, opt-in)
- **Structured headers** — `### Title - STATE` always parsed via `^### .* - STATE` (anchor on the whole pattern, not the keyword)
- **Diff-pattern detection** — to detect "this PR introduces a new lint rule", check `git diff --name-only` for `tools/sharkrite-lint.sh` changes, not the PR body text
- **LLM classification** — when the signal genuinely requires semantic understanding, route it through a Claude call with a structured-output prompt (e.g. "Reply ADR_WORTHY or NOT_ADR_WORTHY") rather than a grep

**Enforcement:** Tracked in milestone via `tools/sharkrite-lint.sh` rules that flag bare-prefix grep patterns (see issue #90).

---

## Decision: How Sharkrite Maintains Its Own Docs

Sharkrite maintains three docs in `docs/architecture/`, each with a single purpose and a single update mechanism:

| Doc | Purpose | Updated when | Update mechanism |
|---|---|---|---|
| `behavioral-design.md` (this file) | Narrative source of truth for major design decisions, rejected approaches, behavioral contracts | A major pattern is established or rejected; a subsystem's contract changes | **Manual edit** (or supervised-mode Claude). Rare. Read by every dev session. |
| `conventions.md` (planned) | Append-only catalog of conventions and anti-patterns. Each entry: rule, why, code example, originating PR | A merged PR introduces a new convention or anti-pattern | **Marker-driven auto-append** at merge time. PR body must contain `<!-- sharkrite-convention -->` block with structured fields. NO keyword matching. |
| `encountered-issues.md` (planned) | Catalog of bug classes that recurred during dogfooding (e.g. "local outside function: 4 instances; root cause: defensive sourcing"). For diagnosing similar bugs faster. | Weekly batch refresh, or on demand via `rite --refresh-encountered-issues` | **Label-driven aggregation** from closed issues with `recurring-pattern` label. Renderer scans GitHub for closed issues with the label and emits markdown. |

Existing automation continues unchanged:

- `.rite/docs/changelog.md` — per-PR one-line entries on every merge
- `.rite/docs/architecture.md` — auto-summarized internal architecture overview (different from this file; meant for in-issue context not narrative)
- `.rite/docs/adr/` — ADRs created when a PR opts in via `<!-- sharkrite-adr -->` marker (replaces the current keyword-matching auto-creation)
- `docs/architecture/exit-codes.md` — auto-maintained from script comments

**Loading order at workflow start:** every Claude dev session loads in this order: `CLAUDE.md` → `behavioral-design.md` → `conventions.md` → `encountered-issues.md` → issue-specific context. The first three together constitute "what every Claude session must know about this codebase."

**Rationale:**

1. **Three docs, three triggers, zero ambiguity** about which one to update.
2. **No keyword matching** — markers and labels are content-addressable, deterministic.
3. **Append-only growth** for `conventions.md` keeps merge conflicts trivial; `behavioral-design.md` curated narrative resists drift.
4. **Future agents inherit lessons** — every Claude session loads the conventions catalog automatically. The "rediscover the same lesson every session" failure mode is prevented at the source.

---

## ADR Backfill (bootstrap-docs.sh)

### Backfill Behavior

When `rite --init` runs, bootstrap searches git history for architectural commits (refactor, feat, breaking, migrate, etc.) and generates ADRs for them. This ensures new repos start with decision records for major historical changes, not just future PRs.

**Default:** Backfill up to 5 ADRs from the last 50 commits matching the pattern.

**CLI Flags:**
- `--no-backfill-adrs` — Skip backfill entirely (prints skip message)
- `--backfill-count N` — Generate up to N ADRs (default: 5)

**Environment Variables:**
- `RITE_NO_BACKFILL_ADRS=true` — Skip backfill
- `RITE_BACKFILL_ADR_COUNT=N` — Set backfill limit

### Metadata Format

ADRs generated from commits use `**Commit:** <sha>` metadata instead of `**PR:** #N`.

**Example:**
```markdown
# ADR-001: Provider Abstraction

**Date:** 2026-05-26
**Commit:** bd61485
**Files:** lib/providers/provider-interface.sh, lib/providers/claude.sh
**Context:** ...
**Decision:** ...
**Tradeoffs:** ...
```

### Deduplication

The `generate_adr_for_ref()` function checks for existing ADRs by searching for:
- `PR: #<number>` (for PR-based ADRs)
- `Commit: <sha>` (for commit-based ADRs)

Re-running bootstrap is idempotent — existing ADRs are preserved, only commits without an ADR get one.

### Empty Responses

When Claude judges a commit NOT architecturally significant, it returns empty output. Bootstrap prints:
```
- Skipped <sha> — Claude judged not ADR-worthy
```

No file is created for that commit. This prevents cluttering `.rite/docs/adr/` with trivial decisions.
