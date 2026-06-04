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

### Batch ↔ Single-Issue Parity Contract

**Principle:** `rite N1 N2 N3` must produce identical per-issue side effects for each Ni as `rite Ni` invoked separately. If running an issue solo prints a summary, removes a worktree, or removes session state, the batch run must do the same.

**Enforcement mechanism:** The batch is a thin orchestrator that loops over issues and delegates per-issue work to `workflow-runner.sh::run_workflow()`. For any per-issue terminal state (closed, failed, complete), the batch must call `run_workflow()` rather than short-circuiting with a truncated one-liner.

**Shared helper:** Closed-issue handling is extracted into `handle_closed_issue(issue_number, issue_data)` in `workflow-runner.sh` (above `run_workflow()`). Both `run_workflow()` and any future caller share this function — no duplicated cleanup logic.

**Allowed divergences:** An orchestrator-level short-circuit is acceptable when:
1. The decision requires batch-local state (e.g., the `ISSUE_STATUS` map tracking which sibling issues failed in this run), AND
2. The divergence is explicitly documented inline with a `# Deliberate divergence from single-issue mode: <reason>` comment, AND
3. A regression test in `tests/regression/batch-single-issue-parity.bats` pins the documented behavior (so future changes can't silently collapse a documented divergence into an undocumented one).

**Current documented divergences in `batch-process-issues.sh`:**

| Short-circuit | Why it's acceptable |
|---|---|
| `parent-PR-deferred` | Requires knowledge of the full batch queue (`ISSUE_LIST`). `run_workflow()` processes one issue at a time. Single-issue mode has no guard because the user is presumed to know ordering constraints. |
| `dep-failed` | Requires the accumulated `ISSUE_STATUS` map from earlier in the same batch. `run_workflow()` cannot see sibling results. |
| `active-process` | Safety guard against two batch sessions racing on the same issue. Single-issue direct invocation allows this intentionally. |
| `in-current-branch` | Prevents git checkout conflicts during batch execution. Single-issue mode allows because the user is interactive. |

**What is NOT an allowed divergence:**
- Closed-issue cleanup (the bug this section was written to fix). `run_workflow()` already returns exit 0 for closed issues, so removing the batch short-circuit is zero-risk.
- Any per-issue cleanup that `run_workflow()` performs at exit (session state, worktrees, branches).

**Batch-level reporting is allowed to differ based on work context (not a parity violation):**

The parity contract covers **per-issue side effects**: cleanup, artifact removal, closure summary output. It does NOT require the batch-level reporting layer to treat all successful `run_workflow()` returns identically.

Specifically: after a closed-issue run (exit 12), the batch may — and should — skip the post-issue gh API calls (pr list, pr view, issue list) that gather PR stats for the batch summary. Those calls are only meaningful after an active dev session produced new work. Skipping them for an issue that was already closed when the batch started is not a parity violation; the closure summary (the per-issue side effect) was already produced identically by `handle_closed_issue()`.

This is the "reporting layer differentiation" principle: parity is about **what happened to the issue**; reporting is about **what to surface to the user**.

Concrete implementation: `handle_closed_issue()` returns exit code 12 (sentinel). `batch-process-issues.sh` captures this before any `if/then` test (`_WF_EXIT=0; cmd || _WF_EXIT=$?`) and routes exit 12 to a skip path that adds the issue to `ALREADY_CLOSED_AT_START_ISSUES`, records status `already_closed_at_start`, and proceeds to the next issue without firing any gh API calls. See `docs/architecture/exit-codes.md` — exit code 12.

**Regression tests:**
- `tests/regression/batch-single-issue-parity.bats` — parity contract (structural + behavioral)
- `tests/regression/batch-closed-issue-skip-stats.bats` — exit 12 sentinel + stat-gathering skip

**Bug history:**
- Issue #274 — bare `continue` for closed issues bypassed all cleanup. Fixed by extracting `handle_closed_issue()`.
- Issue #316 — batch's post-issue gh calls fired even for already-closed issues (exit-12 path missing). Fixed by sentinel exit code + batch routing.

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

### Cleanup Operations Are Lazy About Network State

**Principle:** Cleanup operations check local state first. Network calls are only made when local checks found actual work to do. If steps 1–2 (worktree removal, local branch deletion) found nothing, any surviving remote orphan is cosmetic — the periodic deep-clean sweep in `merge-pr.sh` catches survivors. Skipping the network call avoids 0.3s–30s+ latency and prevents TCP-reset kills on unreliable connections.

**Primary gate — `found_local_orphans`:** `handle_closed_issue()` tracks whether local steps 1–2 actually removed something. Step 3 (remote branch deletion, network) only runs when `found_local_orphans=true OR pr_state != MERGED`. This is the stronger signal because it applies to all PR states: a closed-not-merged PR with no local artifacts is as safe to skip as a merged one.

**Why orphan remote branches are cosmetic:** An orphan remote branch with no local trace has no functional impact on the current workflow. It cannot block future runs, pollute worktree detection, or affect issue state. The deep-clean sweep in `merge-pr.sh` prunes these periodically.

**Live failure this principle prevents (2026-06-04):** Issue #201 cleanup trace:
```
✅ Issue #201 is already closed!
...
Nothing to do - issue already complete! 🎉
Post "https://api.github.com/graphql": read tcp ... read: connection reset by peer
```
Local checks found nothing. The pre-`found_local_orphans` implementation still made the network call (because `pr_state != MERGED`), and a TCP reset killed the process mid-call, leaving a stale worktree. With the `found_local_orphans` gate, no network call fires when local checks find nothing.

**Do not reintroduce unconditional network calls here:** Any future contributor adding remote-branch cleanup for closed issues must check `found_local_orphans` first. The guard must be: `[ "$found_local_orphans" = "true" ] || [ "${pr_state:-}" != "MERGED" ]`.

---

### Network Calls During Closed-Issue Cleanup

**Contract with merge-pr.sh:** When a PR is merged via `gh pr merge --delete-branch`, the merge handler deletes the remote branch as part of the merge operation. `handle_closed_issue()` in `workflow-runner.sh` relies on this contract: when `pr_state == "MERGED"` AND `found_local_orphans=false`, step 3 of cleanup (remote branch deletion) is skipped entirely. There is no need to check `git ls-remote` — the branch is already gone.

**Why this matters:** Without the short-circuit, every closed merged-PR issue made a `git ls-remote --heads origin <branch>` round-trip — a network call that costs 0.3s on fast networks and 30s+ on slow or congested ones. On a hung network it blocks indefinitely. A batch of 10 closed merged issues previously compounded this to 3s–5min of unnecessary blocking.

**Timeout policy (Layer 2):** When the gate fires (network call is needed), the remote check is wrapped in `run_with_timeout 5`. Failure is non-fatal — a warning is logged and cleanup continues to step 4 (session state removal). Orphan remote branches are cosmetic, not functional.

**Session-level prefetch (Layer 3, batch only):** `batch-process-issues.sh` runs `timeout 10 git fetch --prune origin` once at session start. When this succeeds (`_BATCH_FETCH_PRUNE_DONE=true`), `handle_closed_issue` uses `git show-ref --verify --quiet refs/remotes/origin/<branch>` (local, instant) instead of `git ls-remote` (network) for the not-merged check. This eliminates compounding network latency for large batches with multiple closed-not-merged issues. Failure of the prefetch is non-fatal — per-issue cleanup falls back to the network check.

**Do not reintroduce the unconditional remote check:** The original `git ls-remote` call at the top of step 3 (pre-fix) was the source of multi-minute batch hangs. Any future contributor adding remote-branch cleanup for closed issues must either: (a) check `found_local_orphans` first (primary gate), OR (b) check `pr_state` for MERGED (secondary gate), OR (c) use `git show-ref` with a prior fetch guarantee. Neither `git ls-remote` nor `git push --delete` should be called unconditionally in this code path.

**Regression test:** `tests/regression/closed-issue-cleanup-no-hang.bats` — static source checks that verify the short-circuit, timeout wrappers, `found_local_orphans` gate, and local-ref fallback are all present.

**Bug history:**
- Issue #287 — observed 30s+ hangs per issue in a batch of closed merged PRs. The `git ls-remote` call at workflow-runner.sh:1710 (pre-fix) ran for every issue even though the branch was confirmed gone.
- Issue #301 — closed-not-merged PR with no local orphans still made the network call (pre-`found_local_orphans`). A TCP reset on the #201 cleanup run left a stale worktree. The `found_local_orphans` gate eliminates this path.

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

### Test stubs MUST NOT live in production paths (CRITICAL)

`lib/core/assess-review-issues.sh` is the real, 1,000+ line, Claude-driven assessment runner. `lib/utils/format-review.sh` is the real, 200+ line review formatter. **Neither file may be replaced with the simpler test-stub form used by integration tests.** Integration tests inject their own stubs into a temp `MOCK_LIB_DIR` and override `RITE_LIB_DIR` for the duration of the test; the production files at `lib/core/` and `lib/utils/` stay untouched.

**Live incident — 2026-06-02:** The integration test `tests/integration/assess-and-resolve-dedup.bats` had a fatal bug in its setup. The test:

1. Symlinks every file under `lib/utils/` and `lib/core/` from production into a temp directory: `ln -sf "$RITE_REPO_ROOT/lib/core/X.sh" "$MOCK_LIB_DIR/core/X.sh"`
2. Then writes the test stub directly to the symlink path: `cat > "$MOCK_LIB_DIR/core/assess-review-issues.sh" << 'STUB' …`

Bash output redirection on a symlink **follows the symlink** and writes to the target. So the `cat > ...` overwrote the *real* `lib/core/assess-review-issues.sh` at `$RITE_REPO_ROOT/lib/core/`, replacing 1,018 lines of production code with the 9-line test stub. Same for `lib/utils/format-review.sh` (238 lines → 3 lines).

PR #260 was the first PR after this test was authored, so it was the first to commit the damaged tree to main. PR #260's diff "intent" was a separate small fix; the test self-corruption rode along invisibly. Any contributor running `bats tests/integration/assess-and-resolve-dedup.bats` locally would have observed the same damage in their working tree.

**Impact, undetected for 2+ days:** Every production batch run from 2026-06-02 to 2026-06-04 emitted `STUB ERROR: MOCK_ASSESSMENT_FILE not set or missing`, then fell back to "raw review count for decision." The intelligent assessment phase (ACTIONABLE_NOW / ACTIONABLE_LATER / DISMISSED classification) was silently disabled. Follow-up issues for LATER items were not created. Today's batch of issues #182, #287, #200, #203 was the first one diagnosed.

**Why existing checks didn't catch it:**
- Shellcheck has no concept of "this file should be 1,000+ lines"
- The integration test itself passed (it relies on the stubs being where it just wrote them — even if "there" turned out to be production)
- PR #260 was processed via `rite --fix-review` (auto-generated commits); the auto-review didn't flag the -1,015-line collateral diff
- No CI smoke test exercises the real `assess-review-issues.sh` end-to-end (deliberately — it costs LLM tokens per run)
- Branch protection on `main` was disabled, so the failing CI Lint run didn't block the merge

**Prevention layer 1 — the test itself (`tests/integration/assess-and-resolve-dedup.bats`):** Before each override `cat >`, do `rm -f` to break the symlink. The override now lands as a regular file in `$MOCK_LIB_DIR/`, not a write-through to production. Explicit `# CRITICAL` comment in the test marks the contract.

**Prevention layer 2 — sharkrite-lint Rule 20 (`TEST_STUB_IN_LIB`):** Any file under `lib/core/`, `lib/utils/`, or `lib/providers/` is rejected if it (a) begins with `# Stub ` in the first 5 lines, (b) references a `MOCK_*_FILE` env var, or (c) contains the literal `STUB ERROR`. Catches the same pattern from any future source, not just this one test.

**Prevention layer 3 — review guidance (open):** Any PR that removes more than ~30% of an existing production file in `lib/` should require explicit human confirmation that the deletion is intentional, even when `--fix-review` is processing review feedback. Not yet encoded as an automated PR check; tracked in follow-up.

**If you see this fail in CI:** `git log -S "Stub <filename>" -- lib/<path>` finds when the stub was introduced. Restore with `git checkout <commit-before>~1 -- lib/<path>`. Also audit the most recently changed integration test for a `cat > "$LIB_DIR/X.sh"` pattern over a symlink.

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

## Doc Assessment Fan-out / Fan-in (assess-documentation.sh, merge-pr.sh)

Post-merge doc assessment runs as a background subprocess launched by `merge-pr.sh`. Within that subprocess, `assess-documentation.sh` makes multiple Claude provider calls. The sub-assessments are structured as a fan-out / fan-in: four calls run in parallel, then dependent calls run sequentially.

### Independent sub-assessments (fan-out)

These four sub-assessments each evaluate the **same diff** against a **different internal doc**. They have no data dependency on each other:

| Sub-assessment | Output doc | What it captures |
|---|---|---|
| `assess_internal_security` | `.rite/docs/security.md` | Auth, credential, infra changes in the diff |
| `assess_internal_architecture` | `.rite/docs/architecture.md` | New/removed files, config vars, entry points |
| `assess_internal_api` | `.rite/docs/api.md` | CLI flag, config var, exit code changes |
| `assess_internal_adr` | `.rite/docs/adr/*.md` | Architectural decisions worth recording |

Implementation: all four are launched via `&` and collected into `_assess_pids`. A `wait` loop then collects exit codes individually — a failing sub-assessment logs a warning but does NOT prevent the others from completing or the reconcile step from running.

### Dependent steps (fan-in / sequential)

These run after the fan-out wait completes, because they consume the sub-assessment outputs:

1. **Reconcile** (`reconcile_internal_doc`) — when a doc accumulates 3+ PR delta sections, merges incremental deltas back into the baseline. Runs in parallel per-doc (each doc is independent), but after the fan-out wait. Each reconcile call is one Claude provider call.
2. **Cross-doc consistency validation** (`_validate_cross_doc_consistency`) — only fires when a reconciliation actually happened. Makes one Claude provider call to find contradictions across security/arch/api docs, then one provider call per file that needs a correction.
3. **Layer 2 (user project docs)** — if `.rite/doc-sync.md` exists, runs one assessment call then one update call per doc needing changes. Sequential because the assessment's output drives the update calls.

### Wall-clock impact

Before parallelization (if it were sequential): `t_sec + t_arch + t_api + t_adr + t_reconcile` ≈ 80-120s with Sonnet.

After parallelization: `max(t_sec, t_arch, t_api, t_adr) + t_reconcile` ≈ 20-30s + 20-30s ≈ 40-60s.

### Merge-tail timeout watchdog

`merge-pr.sh` starts the doc assessment background subprocess before cleanup, then waits for it after cleanup. The wait is bounded by `RITE_DOC_ASSESSMENT_TIMEOUT` (default 180s):

```
( sleep $timeout && kill -TERM $DOC_PID ) &   # watchdog
watchdog_pid=$!

wait $DOC_PID || doc_exit=$?

kill -TERM $watchdog_pid                        # cancel watchdog if doc finished first
wait $watchdog_pid

if doc_exit == 143 (SIGTERM) or 137 (SIGKILL):
    print warning, continue (exit 0 from merge-pr.sh)
```

On timeout: warning logged to stderr, workflow exits 0. Doc assessment results are not a merge blocker — stale or missing doc updates are caught on the next run.

**Why 180s default:** The fan-out wall-clock is ~25-35s (limited by the slowest of the four parallel calls). Reconcile adds another ~25-35s. Layer 2 varies. 180s leaves 3× headroom for API latency spikes without making the merge tail feel hung.

### DO NOT skip the assessment based on diff content

An earlier approach was rejected: checking whether the PR diff touched any `.md` files and skipping the assessment if not. This was wrong because the entire purpose of the assessment is to surface what docs should change based on dev work — even when the dev work only touched `.sh` or `.ts` files. A new security pattern, a new CLI flag, or a new architectural approach all warrant doc updates regardless of whether the dev session touched docs.

---

## Session Limit Design: Why Wall-Clock Age Is the Wrong Metric (issue #283)

### Problem

The original `session_limit` blocker in `blocker-rules.sh` compared `(now - start_time)` against `RITE_MAX_SESSION_HOURS`. `start_time` came from the session state JSON file, which `init_session()` only wrote once and never reset.

**Zombie file scenario:** A batch run (`rite 10 20 30`) crashes at 11 PM. The state file in `/tmp` has `start_time = 11 PM`. The next day at 3 PM, `rite 274` runs, calls `init_session()`, finds the file already exists, skips it — and inherits `start_time = 11 PM` (16h ago). The session-check immediately fires `BLOCKER: Approaching session time limit (16 hours elapsed)`. The only recovery was `rm /tmp/rite-session-state-*.json`.

### Root cause (two compounding bugs)

1. **`init_session()` never reset `start_time`** when the file existed (old UPSERT semantics). The comment said "preserving counters and cross-run state" — true for `issues_completed` and `approved_blockers`, but `start_time` is a per-invocation clock, not cross-run state.

2. **`session_limit` measured file age, not work**. Wall-clock since `start_time` conflates three different things: time since the JSON was written, time the user has been driving rite, and cumulative LLM/token cost. Only the last one is what the blocker is supposed to protect against.

### Fix

**Option 2 — Reset `start_time` on fresh invocations** (`init_session` in `session-tracker.sh`):
- Fresh call (no `RITE_RESUMING=true`): reset `start_time = now`, clear `current_issue`/`worktree_path`, preserve `approved_blockers`/`sent_notifications`.
- Resume mode (`RITE_RESUMING=true`): keep file untouched — inherit `start_time` and `cumulative_work_seconds` from the prior run.
- `workflow-runner.sh` sets `RITE_RESUMING=true` before `init_session` when `RESUME_MODE=true`.

**Option 1 — Track per-issue duration, not file age** (`start_issue_tracking`/`end_issue_tracking` in `session-tracker.sh`):
- New fields: `current_issue_started_at` (epoch, set by `start_issue_tracking`) and `cumulative_work_seconds` (running total, updated by `end_issue_tracking`).
- `detect_session_limit` reads `cumulative_work_seconds / 3600`, not `(now - start_time) / 3600`.
- New `detect_issue_duration_limit` fires if `(now - current_issue_started_at) > RITE_MAX_ISSUE_HOURS * 3600`.
- Both batch path and single-issue path call `start_issue_tracking` / `end_issue_tracking`.

### What the limits now mean

| Limit | What it measures | Fires when |
|-------|-----------------|------------|
| `RITE_MAX_ISSUE_HOURS` (default: 4h) | Time one issue has been actively running | Single issue > 4h — likely stuck |
| `RITE_MAX_SESSION_HOURS` (default: 12h) | Sum of per-issue durations in this invocation | Cumulative active work > 12h |

A 40-hour-old zombie file with 0 issues run → 0h cumulative → no limit fires.

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

The `acquire_pr_followup_lock` waiter times out after **~60s** (60 × 1s sleeps plus per-iteration overhead — actual wall-clock slightly exceeds 60s). Under slow-GitHub conditions the holder can consume significantly more time inside the critical section than the ~5–10s typical case:

**Holder worst-case timing (assess-and-resolve.sh):**

| Step | Time (slow-GitHub) |
|---|---|
| Evidence validation (`gh issue view`) | up to 20s backoff-sleep (gh_safe 3×: 5s + 15s); gh round-trip latency is additional |
| Dedup search loop — up to 4 `gh_safe` calls per iteration:<br>• `gh issue list` (body-marker search)<br>• `gh issue view` (marker verification; only if list found a candidate)<br>• `gh issue list` (title search; only if still no match)<br>• `gh pr view` (PR comment check; only if no match and not last retry) | up to 80s backoff-sleep (20s × 4 calls); gh round-trip latency adds to each call |
| Dedup index backoff loop (`_dedup_max_retries × RITE_DEDUP_BACKOFF`) | 3 × 5s = 15s (default) |
| **Plausible worst case** | **~115s backoff-sleep** (exceeds the ~60s waiter budget); actual wall-clock is higher once gh request latency is included |
| **Theoretical worst case** | more calls if loop retries multiple times; per-call cost is bounded at 20s backoff-sleep (5s+15s, no trailing sleep) — growth comes from call count, not per-call duration |

**What happens on waiter timeout:**
`acquire_pr_followup_lock` returns 1. The caller (`assess-and-resolve.sh`) sets `_skip_followup_creation=true` in its `else` branch and proceeds without the lock. This prevents creation of a duplicate follow-up issue but also prevents creation of *any* follow-up issue for this run. A `[diag] FOLLOWUP_LOCK_TIMEOUT` line is written to `RITE_LOG_FILE`. Recovery: re-run `rite N --assess-and-fix`.

**Why this doesn't cause data corruption:**
The skip-on-timeout is conservative — the follow-up may already have been created by the holder. The dedup guarantee is preserved (no duplicate created); the only loss is a missed creation in a concurrent slow-GitHub scenario.

**Tuning knobs** (set in `.rite/config` or environment):
- `RITE_DEDUP_BACKOFF` (default: 5s) — reduce to shorten holder dedup wait time
- `RITE_GH_MAX_RETRIES` (default: 3) — reduce to shorten gh backoff windows
- To increase the waiter budget: edit `max_attempts` in `acquire_pr_followup_lock` (not currently configurable via env)

---

## Phase Handoff cwd Invariants (workflow-runner.sh)

### The Problem: Deleted-Directory cwd

`workflow-runner.sh::run_workflow()` changes into the feature-branch worktree early in the workflow (`cd "$WORKTREE_PATH"`). When Phase 4 (`phase_merge_pr`) completes, `merge-pr.sh` has deleted that worktree directory. Control returns to `workflow-runner.sh`, which still has the deleted directory as its cwd. Any subsequent shell built-in or subprocess that probes cwd will fail:

```
fatal: Unable to read current working directory: No such file or directory
```

This produces false failures — the PR was successfully merged, but the cleanup phase (`phase_completion`) is reported as failed because its `gh` calls trigger git's internal cwd probe.

**Bug history:**
- **Issue #161** (fixed by PR #211) — `merge-pr.sh` itself cd'd to `$MAIN_WORKTREE` before removing the worktree, fixing cwd for operations *inside* merge-pr.sh.
- **Issue #235** (fixed by PR #295) — the *caller's* cwd in `workflow-runner.sh` was never restored. `phase_completion`'s `gh_safe pr view` calls triggered the fatal error.

### The Contract

**At every phase boundary in `workflow-runner.sh`, cwd must be `$RITE_PROJECT_ROOT`.**

More specifically:
- Phases that need the worktree (dev, push/PR, assess) are responsible for cd-ing into it themselves, not for leaving it set.
- **`phase_merge_pr` MUST restore cwd to `$RITE_PROJECT_ROOT` before returning.** It removes the worktree (indirectly, via `merge-pr.sh`) and is therefore responsible for leaving the process in a safe directory.
- **`phase_completion` (and any phase that follows merge) MUST start with a defensive `cd "$RITE_PROJECT_ROOT"`** as defense-in-depth — protecting against any other caller path that might leave cwd in a bad state.

### Implementation

**Option A (architectural fix) — `phase_merge_pr` restores cwd at the end:**

```bash
# At the end of phase_merge_pr(), after the STASHED_UNRELATED_WORK block:
# Restore cwd so downstream phases (phase_completion, etc.) start in a valid dir.
cd "$RITE_PROJECT_ROOT" 2>/dev/null || cd "$(git -C "$RITE_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || true
return 0
```

The fallback chain `2>/dev/null || git -C ... || true` makes this robust: if `$RITE_PROJECT_ROOT` is somehow unset, the fallback uses git's own root detection; if both fail, the `|| true` prevents crashing under `set -e`.

**Option B (defense-in-depth) — `phase_completion` restores cwd defensively:**

```bash
phase_completion() {
  # Defensive: ensure we're at the repo root before any gh/git calls.
  cd "$RITE_PROJECT_ROOT" 2>/dev/null || true
  ...
}
```

Both are implemented. The pattern of recurring cwd bugs in this area justifies defense-in-depth.

### STASHED_UNRELATED_WORK Exception

The `STASHED_UNRELATED_WORK` branch inside `phase_merge_pr` cd's into `$WORKTREE_PATH` to run `git stash pop`. This is intentional — it must happen while the worktree exists. The cwd-restore to `$RITE_PROJECT_ROOT` happens **after** this block, so the exception does not conflict with the contract.

### Regression Test

`tests/regression/post-merge-cwd-restored.bats` pins the contract:
1. Static: `phase_merge_pr` contains `cd "$RITE_PROJECT_ROOT"` before `return 0`
2. Static: `phase_completion` contains defensive `cd "$RITE_PROJECT_ROOT"` before first `gh_safe` call
3. Static: the Option A restore cd is **after** the `STASHED_UNRELATED_WORK` block
4. Behavioral: a subprocess launched from a removed directory that mirrors the fix succeeds
5. Behavioral: the same subprocess without the fix reproduces the fatal cwd error

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

## macOS bash 3.2 Compatibility

### Background

macOS ships `/bin/bash` at version 3.2.57 (2007). Sharkrite scripts use `#!/bin/bash` as the deliberate shebang for `lib/`, `bin/`, and `tools/` scripts — this pins the executor to the system shell and avoids PATH-dependent behavior. The tradeoff is that any bash 4.0+ feature used in these scripts will crash on macOS unless an explicit version guard is in place.

### Known bash 4.0+ features that must not appear unguarded in #!/bin/bash scripts

| Feature | Bash version | Portable alternative |
|---|---|---|
| `mapfile -t ARR < <(cmd)` | 4.0+ | `while IFS= read -r _line; do ARR+=("$_line"); done < <(cmd)` |
| `readarray -t ARR < <(cmd)` | 4.0+ | Same while-read pattern |
| `declare -A ASSOC` | 4.0+ | Pass data as delimited strings or temp files |

### The re-exec pattern (batch-process-issues.sh:69-77)

Scripts that need multiple bash 4+ features use the self-re-exec pattern to transparently upgrade to a newer bash when available:

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

When only a single bash 4+ feature is used, it is simpler and more portable to replace the feature rather than add the re-exec block.

### Live incidents

| Date | File | Root cause | Fix |
|---|---|---|---|
| 2026-06-04 | `lib/core/undo-workflow.sh:133` | `mapfile` used for follow-up issue dedup; crashes when `/bin/bash` 3.2 is the executor (issue #327) | Replaced with portable while-read loop + `"${arr[@]+"${arr[@]}"}"` empty-array guard (PR #266 pattern) |
| (prior) | `lib/core/batch-process-issues.sh` | `declare -A` associative array (issue #266) | Added self-re-exec guard at top |

### Lint enforcement

Rule 21 (`BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT`) in `tools/sharkrite-lint.sh` scans all `#!/bin/bash` scripts in `lib/`, `bin/`, and `tools/` for `mapfile`, `readarray`, and `declare -A` without a `BASH_VERSINFO` guard. The rule fires on the first violation line and points to the portable alternatives. Suppression is available via `# sharkrite-lint disable BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT - reason: <text>` on the preceding line.

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
