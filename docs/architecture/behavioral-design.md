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

### Pytest Loud-Skip on Missing Dependencies (#744)

**2026-06-27.** When `pytest` is the test runner and the environment is missing the runner itself (or a direct project dependency), the gate previously silently passed with `outcome=skipped`. This masked genuine env issues in worktrees with stale venvs — the fix loop never fired because the gate never reported a problem.

**The fix:** `_classify_pytest_outcome` in `lib/utils/test-gate.sh` detects the missing-dep signature and routes to `skipped:missing_deps` rather than `passed`. `run_test_gate` then emits a `[test-gate] WARNING: pytest detected missing dependencies` message to stderr and includes an actionable hint (check/rebuild venv), mirrors the existing `missing_runner` loud-skip for cargo/go. JSON outcome is `skipped:true` with `reason=missing_deps`. The gate does **not** block (the env issue is not this PR's failure); the warning ensures the problem is visible rather than silent.

**Detection signature (`_classify_pytest_outcome` step 4):** `^E[[:space:]]+(ModuleNotFoundError|.*No module named)` — requires the `^E` pytest error-line prefix (column 0, E, then whitespace), which pytest emits for exception lines. This anchor excludes `ModuleNotFoundError` that appears in docstrings, log messages, or arbitrary text reproduced in tracebacks.

**Accepted limitation — runner vs. code-under-test conflation:** The `^E\s+` anchor correctly catches the missing-runner case (`E  ModuleNotFoundError: No module named 'pytest'`), but it also catches a runtime import error in the code under test (e.g. `E  ModuleNotFoundError: No module named 'mymodule'` when the code-under-test has a broken import). In the latter case the PR introduced the import error, so the gate should block — but `_classify_pytest_outcome` routes it to `skipped:missing_deps` instead. This is a residual false-skip and is why the issue scope boundary explicitly says "DO NOT grep ModuleNotFoundError unanchored / anywhere" (the v1 rejection). The `^E\s+` anchor is narrower than bare grep but still conflates these two cases because both produce identically-prefixed output lines.

**Why accepted:** Distinguishing the two cases requires knowing whether the missing module is a declared project dependency (code-under-test error → should block) or the test runner itself (env issue → skip). That distinction requires parsing requirements/pyproject metadata and is significantly more complex. The current approach is correct for the primary use case (missing pytest/missing top-level dep stale-venv scenario) and the false-skip is bounded: it only fires when the code under test has an un-FAILED/un-AssertionError import error in an `E`-prefixed line — a narrow signature. The conservative default (step 5: unknown non-zero → `failed`) catches everything else. If the conflation causes a live false-skip, restrict the `missing_deps` path to `No module named 'pytest'` (runner-only) as the stricter fix.

**`skipped:no_tests` outcome (reason=no_tests):** When pytest exits with code 5 (no tests collected) and no collection-error signature is present, `_classify_pytest_outcome` returns `skipped:no_tests`. `run_test_gate` emits `[test-gate] WARNING: pytest collected no tests` to stderr with an actionable hint (check test path / pytest configuration) and writes JSON with `skipped:true, reason=no_tests`. This is non-blocking — a missing test suite is an env/config issue, not a PR regression. Mirrors the `missing_deps` loud-skip shape.

**Enforcement:** `tests/regression/gate-missing-deps-skip.bats` — 13 tests covering the functional skip paths, WARNING stderr emission, JSON output, collection-error blocking, clean-pass regression guard, and the no-test-collection path.

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
| `live-lock-deferred` | Dep issue *or* parent issue holds a live lock in a concurrent batch session — defer-to-end rather than skip immediately. Applies to both the `DEP_ISSUES=` guard (dep path) and the `PARENT_IN_QUEUE=false` guard (parent-PR path). Requires local lock-dir inspection (`RITE_LOCK_DIR`), which is batch-orchestrator context. Single-issue mode has no queue to defer into. |
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
2. Dependency issue is still OPEN (PR not merged) → defer or skip (see below)

**Open dependency handling — three-tier decision:**
When a dep issue is OPEN, `batch-process-issues.sh` tries each option in order:
1. **Queue-later defer**: dep appears after the current position in `ISSUE_LIST` → re-append the dependent to the end of the queue (`deferred_for_dep` status; bounded by `_DEFER_COUNT` anti-cycle cap).
2. **Live-lock defer**: dep holds a live issue-lock (`${RITE_LOCK_DIR}/issue-N.lock/pid` exists + `kill -0` succeeds + not this process's own PID) → same re-append, same cap. The foreign session is actively working on the dep and will likely merge before this batch drains. Local filesystem check only; no network calls. Starts a `RITE_LIVE_LOCK_DEFER_WAIT`-second (default: 30) background sleep at defer time; other queued issues run concurrently. The deferred issue joins the sleep before the dep is re-checked, so the foreign session has had wall-clock time to merge. The live-lock defer cap is `RITE_LIVE_LOCK_MAX_DEFERS` (default: 10), independent of batch size — a 2-issue batch gets the same 10 × 30s budget as a large one.
3. **Skip**: neither condition holds (dep not in queue, no live lock, or cap exhausted) → `dep_failed` skip, same as today.

**Anti-cycle cap:** Both defer paths share `_DEFER_COUNT[ISSUE_NUM]` as the cycle counter, but use **different bounds**: the queue-later path is bounded by `_UNIQUE_ISSUE_COUNT` (frozen operator-supplied issue count); the live-lock path is bounded by `RITE_LIVE_LOCK_MAX_DEFERS` (default 10), independent of batch size — a 2-issue batch gets the same cap as a large one. A dep whose foreign session stalls and never merges cannot defer the dependent more than `RITE_LIVE_LOCK_MAX_DEFERS` times.

**Why check open state:** A dependency's PR may have been created in this batch but not yet merged. Processing the dependent issue before the dependency merges causes failures (missing code/models).

**Parent-PR live-lock path (follow-up issues):** The same live-lock defer logic applies to the `PARENT_IN_QUEUE=false` branch. When a follow-up issue's parent PR is still open and the parent issue is not in this batch, `batch-process-issues.sh` checks whether the parent issue holds a live lock before skipping. If the parent holds a live lock, the follow-up is deferred to end of queue (`deferred_for_parent` status) with the same `RITE_LIVE_LOCK_DEFER_WAIT` background sleep and `RITE_LIVE_LOCK_MAX_DEFERS` cap. The `_PARENT_LIVE_LOCK_WAIT_PID` join runs on re-entry before the parent PR state is re-checked. Without this, concurrent batches where one batch owns the parent issue silently skip the follow-up even though the parent is actively merging.

### Cross-Batch File Overlap: Warn and Reorder

Before each issue slot runs its workflow, `batch-process-issues.sh` compares the issue's declared `Files to Modify:` paths against the changed files of every other in-flight worktree. On intersection, the issue is re-appended to the end of the queue (warn-and-reorder, never skip).

**Invariants (warn-only contract):**
- An issue is **never skipped** or blocked by this check. Cap exhausted → run in place with the warning only.
- The check is **local git only** — `git worktree list` + `git -C <wt> diff --name-only <base>...HEAD`. No network calls, no `gh` invocations.
- A missing or empty `Files to Modify:` section is a **silent no-op**.

**Overlap detection — `_ftm_file_overlap ISSUE_BODY`:**
1. Parse the `Files to Modify:` section from the issue body (first backtick-quoted path per list item; falls back to first whitespace-delimited word). Entries without `/` or `.` are filtered as prose.
2. Enumerate all worktrees via `git worktree list`, skipping the main checkout and current directory.
3. For each other worktree, resolve a diff base (`merge-base HEAD origin/main` → `merge-base HEAD main` → `rev-list --max-parents=0`). Skip silently if none resolves.
4. Run `git -C <wt> diff --name-only <base>...HEAD` to get the worktree's changed files.
5. Match each declared path against changed files: exact match, directory-prefix match (`declared/` prefix), or glob match (`*`/`?` in declared path).
6. First intersection wins — records `_OVERLAP_FILES` (comma-joined matches) and `_OVERLAP_WT` (worktree path).

**Deferral — shared `_DEFER_COUNT` cap:**
The same `_DEFER_COUNT[ISSUE_NUM]` counter and `_UNIQUE_ISSUE_COUNT` bound used by the dep-defer path also gate the overlap defer. This prevents an issue from cycling forever when the overlapping worktree never clears. Cap exhausted → the issue runs in place after printing the warning; it is NOT skipped or blocked.

**Dep-chain cohesion (free):** A deferred issue's position moves to the end of the queue. Any in-batch children whose dep is this issue will self-defer via `_check_dep_queued_later` — no extra code needed.

**Deliberate batch-only divergence:** Single-issue mode has no queue to defer into, so `_ftm_file_overlap` is only called from the per-slot batch loop.

**Skipped for CLOSED issues:** The guard is not run when `ISSUE_STATE=CLOSED`. Closed-issue processing is cleanup-only (worktree removal, branch deletion) and touches no source files, so it cannot conflict with another worktree's diff. Deferring a closed issue would only delay that cleanup while burning the defer cap. The parity contract (`batch-process-issues.sh` "do NOT short-circuit here" comment, referencing this doc) owns closed-issue handling via `run_workflow()` → `handle_closed_issue()`.

**Diag line:** `[diag] OVERLAP_DEFER issue=N files=... worktree=...` emitted on each deferral (and on cap-exhausted in-place runs with `cap_exhausted=true`).

**Motivation (live incident, 2026-10-11):** Batches for issues #916/#975 and #1125/#1130 both touched `test-gate.sh`. The concurrent worktrees caused rebase churn and extra fix rounds on the second batch. This check catches the overlap before Phase 1 starts, deferring until the first batch has cleared its worktrees.

**Verification:** `grep -n "OVERLAP_DEFER" docs/architecture/behavioral-design.md` returns this paragraph.

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

### Closed-Issue Cleanup Fallback Chain

`handle_closed_issue()` discovers `pr_branch` (the branch to clean up) via a three-tier fallback chain. Each tier fires only when the previous tier returned nothing.

**Tier 1 — closedByPullRequestsReferences (GitHub graph):**
`gh issue view` returns a `closedByPullRequestsReferences` array. When it's non-empty, the first entry gives the PR number directly, and `gh pr view` fetches the `headRefName` branch. This is the fast path: zero extra network calls, always accurate for normal PR-merged-closes-issue flows.

**Tier 2 — PR-body search up to 1000:**
When `closedByPullRequestsReferences` is empty (issue was manually closed via `gh issue close`, or closed by a PR that itself was later closed without merge), Tier 1 yields nothing. Tier 2 searches all closed PRs for "Closes #N" / "Fixes #N" / "Resolves #N" in their body, up to the last 1000 results. The limit was 50 before issue #319 — at Sharkrite's dogfooding pace (78 closed PRs in 3 days), even a 2-day-old PR could fall off the window. 1000 is gh's max page size and covers months of history on any normally-active repo.

**Tier 3 — Local worktree association (last resort):**
When no PR can be found via the API (manual close with no matching PR body, or the closing PR never used a GitHub closing keyword), Tier 3 inspects local `git worktree list` for worktrees whose directory name encodes the issue number. Two sub-strategies are tried in order:

- **Sub-strategy A — Batch suffix whole-token match:** Sharkrite's batch mode appends `_b<N1>-<N2>-...` to the worktree directory name. A worktree with suffix `_b201` or `_b199-201-203` belongs to a batch that included issue #201. The whole-token regex prevents substring collisions: `_b2010` does NOT match issue #201.
- **Sub-strategy B — Title-slug match:** The issue title is normalized to a branch slug using the same rules as `claude-workflow.sh` (lowercase, spaces→dashes, strip non-alnum-dash, cut to 50 chars). If a worktree's basename contains that slug, it's a candidate. This covers single-issue non-batch orphans (e.g., #201's worktree `ft-rebase-pr-172-onto-main-and-resolve-conflicts` matches the issue title "Rebase PR 172 onto main and resolve conflicts").

**Conservative contract:** Tier 3 is intentionally conservative. If either sub-strategy returns multiple candidates (ambiguous batch), cleanup is skipped and a warning is logged. The risk of deleting the wrong worktree is higher than the cost of leaving an orphan — the user can clean up manually. Only when exactly one candidate exists does Tier 3 proceed.

**Why Tier 3 is last-resort:** It cannot know PR state (merged/closed/never-existed), so it cannot set `pr_state`, which affects the network-call gate in step 3 (remote branch deletion). When Tier 3 fires, `pr_state` stays empty, which means `pr_state != "MERGED"` is true, which allows the remote-branch check. The `found_local_orphans` gate still applies — the remote call only fires if a local worktree or branch was actually removed in steps 1–2.

**Regression test:** `tests/regression/closed-issue-cleanup-no-pr.bats` — behavioral tests covering: manually-closed issue with orphan worktree (Tier 3 title-slug path), PR beyond the original 50-result window (Tier 2 bumped limit), ambiguous batch suffix (conservative skip), and substring collision guard.

**Bug history:**
- Issue #319 (2026-06-04) — `--limit 50` dropped PR #206 off the window for issue #201 (78 closed PRs in 3 days). Issue #201 had no `closedByPullRequestsReferences` (manually closed). The orphan worktree `ft-rebase-pr-172-onto-main-and-resolve-conflicts` persisted across multiple cleanup runs. Fixed: Tier 2 bumped to `--limit 1000`, Tier 3 local-state fallback added.

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

### Fix-loop policy: NOW means fixed, LATER means deferred

**Honest-classification contract (introduced #717, 2026-06):** `ACTIONABLE_NOW` is a *scope* judgment, not a severity filter. The assessor labels a finding NOW only when it (a) logically completes the issue's work, or (b) falls within the issue's scope/diff and is completable in this PR. Anything deferrable must be classified `ACTIONABLE_LATER` or `DISMISSED` by the assessor. A finding that reaches `assess-and-resolve.sh` with a NOW label is always serviced in the fix loop — there is no post-classification "skip the loop and defer" path.

**Routing:**
- `ACTIONABLE_NOW` present, retry count < 3 → exit 2 (fix loop, regardless of severity)
- `ACTIONABLE_NOW` present, retry count ≥ 3 → retry-cap handling (see below)
- Only `ACTIONABLE_LATER` items → exit 0, create tech-debt follow-up issues
- Only `DISMISSED` items → exit 0, no follow-up

**Why the previous "defer-when-shippable" rule was removed:** The old rule entered the fix loop only when at least one NOW item had Severity CRITICAL or HIGH; MEDIUM/LOW NOW items were reclassified to a follow-up and merged with `fix_iterations=0`. This caused observed regressions: finance-glance #60 (1px overlap introduced by the PR) and #63 (NaN passthrough to `(int)(NaN*100)`, UB) were both labeled MEDIUM, both deferred+merged, both regressions introduced by the PR itself. sharkrite #649 showed the opposite failure: doc-consistency NOW items churned through 3 fix iterations before hitting the cap. The root fix is honest assessment: out-of-scope or low-priority items must be classified LATER/DISMISSED by the assessor, not classified NOW and silently deferred by the resolver.

**Implementation:** [assess-and-resolve.sh](../../lib/core/assess-and-resolve.sh) — the `ACTIONABLE_NOW_COUNT > 0` branch dispatches: retry count ≥ 3 → retry-cap handling; otherwise → Normal loop (echo assessment to fd 3, exit 2).

**Coverage:** `tests/regression/assess-and-resolve-now-always-loops.bats` — five static grep checks: no `SHIPPABLE_DEFER` references remain in `lib/`, no "Deferring.*NOW item" or "PR is shippable" messages in `assess-and-resolve.sh`, the "Normal loop" comment (the surviving fix-loop else branch) is present, and `CRITICAL_NOW_COUNT`/`HIGH_NOW_COUNT` are still computed. Runtime exit-2 routing is asserted by `tests/integration/assess-and-resolve-dedup.bats` test 5 (HIGH-severity NOW item enters fix loop).

### Verification Out of Fix Session

**Issue #448, 2026-06-07.** Verification (`make check` + `bats -r tests/`) was moved OUT of the fix session and into a parallel post-commit gate.

**Before (broken):**
```
fix_session (Claude, LLM $$)
  ├── read findings, make edits
  ├── make check  ← full-codebase shellcheck ON LLM WALLET CLOCK
  ├── bats tests/ ← non-recursive: found 0 tests (broken gate)
  └── declare done
outer test gate: bats tests/ → 1..0 (zero tests, non-recursive bug)
```

**After (correct):**
```
fix_session (Claude, editing only)
  ├── read findings, make edits
  ├── bash -n <files>  ← syntax-check only, fast
  └── commit

[PARALLEL, after commit]
make check + bats -r tests/ ───┐  run_test_gate() in background (CPU)
review generation ─────────────┤  phase_create_pr() in foreground (LLM)
assessment ────────────────────┘  waits for both, merges findings
```

**Three structural changes:**

1. **Fix prompt** (`claude-workflow.sh`): step 5 replaced with `bash -n` syntax-check only. Claude is explicitly told NOT to run `make check`, `bats`, or `pytest` — those run automatically after commit. Fix timeout lowered proportionally: `300 + 240 * ACTIONABLE_NOW_COUNT`, capped at 1800s.

2. **Test gate** (`lib/utils/test-gate.sh`): new utility that runs `make shellcheck` + `make lint` (independently, so custom-lint findings are never masked by shellcheck failures) + `bats -r tests/` (recursive) for Sharkrite repos. Emits structured JSON: `{lint, tests, exit_code}`. Runs in background, parallel with review generation. Exits 0 with `skipped=true` when `make`/`bats` are absent.

**Gate coverage boundary — fix-loop commits vs. initial dev commit:**

The parallel gate (`run_test_gate` in `test-gate.sh`) runs **after every fix-loop commit** (workflow-runner.sh, Phase 3). It does NOT run after the initial dev commit from Phase 1.

The initial dev commit is covered by the dev-phase gate in `claude-workflow.sh::run_test_gate()` (line ~2619). That gate auto-detects the test runner: for Sharkrite repos it resolves to `make test` (via `_test_cmd="make test"` at line ~494), which calls the Makefile `test:` target — this runs `bats tests/` (non-recursive). The recursive `bats -r tests/` form is used **only** by the post-commit parallel gate (`test-gate.sh`). This is intentional: the dev-phase gate uses the project's standard `make test` command (non-recursive, same as `make test` in CI); the parallel gate uses `bats -r tests/` to fix the exact non-recursive bug (PR #432) that motivated this PR.

3. **Assessment** (`assess-and-resolve.sh`): reads gate findings from `RITE_GATE_FINDINGS` env var (or `.rite/state/gate-findings-N.json` fallback). Gate findings are prepended to the fix-mode list as `[GATE] ACTIONABLE_NOW` items — no LLM categorization needed (objective failures). The zero-findings early-exit is guarded: if gate found failures, assessment MUST run the fix loop regardless of review verdict.

**Why the old "defense-in-depth" argument no longer applies:**

The old section argued that having Claude run tests INSIDE the session is defense-in-depth (catches issues before the gate). The live data disproved this: the PR #432 run spent the full 1800s on `make check` thrash (Claude ran it multiple times), then the outer gate ran `bats tests/` non-recursively and found zero tests. Both windows were broken simultaneously. Defense-in-depth only works when both layers are functional.

**Proportional fix timeout:**
- 1 finding → 300 + 240 = 540s (~9 min)
- 3 findings → 300 + 720 = 1020s (~17 min)
- 6 findings → 300 + 1440 = 1740s (~29 min)
- 10+ findings → capped at 1800s (30 min)
- `RITE_FIX_TIMEOUT` env var overrides (operator escape hatch)
- **Single retry on no-commit timeout (issue #1172):** when a fix session times out with zero commits *and* the budget is below 1800s, the session is retried exactly once at `min(2 × budget, 1800s)`; a `FIX_TIMEOUT_RETRY` diag line is emitted. A second no-commit timeout, a timeout with commits present, and budgets already at 1800s all follow today's behavior unchanged.

**Implementation:** `tests/regression/fix-prompt-no-verification.bats`, `tests/regression/test-gate-parallel.bats`, `tests/regression/fix-timeout-proportional.bats`, `tests/regression/fix-timeout-retry.bats`.

### Test Selection by Changed Paths

**Issue #462, 2026-06-08.** The post-commit `test_gate` now selects a subset of bats files based on the commit's changed paths instead of running the full 140+ file suite every iteration.

**Convention:** bats files declare which source paths they cover via a single-line header (the `sharkrite-test-covers:` marker, defined in `markers.sh`):

```bash
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh, lib/utils/bar.sh
@test "..." { ... }
```

**Selection rules** (in `lib/utils/test-gate.sh::_select_tests_by_changed_paths`):

1. **No full-suite triggers — selection is always targeted.** The original #462 design escalated to the full suite when the commit touched `lib/utils/test-gate.sh`, `tools/*-lint.sh`, `Makefile`, `tests/helpers/*`, or `tests/fixtures/*`. That trigger list was **removed 2026-06-12**: a full run costs hours per fix-loop iteration, drowns real findings in load-induced flake (live failure: issue #484 died mid-loop to a 165-file gate run), and fired on exactly the issues that maintain the gate/lint tooling. **Accepted trade-off:** changes to `Makefile`/`tests/fixtures/*` currently select zero bats files, and `tests/helpers/*` selects only the few files whose headers name helpers despite helpers being sourced everywhere — this gap is deliberate until a focused mechanism exists (issue #482 tracks the compensating periodic full-suite safety net). Re-adding a trigger list requires consciously deleting the pinning tests in `test-gate-targeted-selection.bats`. The lint-side full-scan triggers (`_LINT_GATE_FULL_SUITE_TRIGGERS`) are NOT removed — a full lint scan costs seconds.
2. **Headerless files are skipped** (post-#480 backfill flipped the default in #481; the `MISSING_TEST_COVERAGE_HEADER` lint rule enforces headers on new files). A *directly changed* `.bats` file always runs itself regardless of headers.
3. **Header match.** For files with a header, the comma-separated path list is intersected with the commit's changed-file set via shell case-statement glob matching. Globs (`lib/utils/*.sh`) supported; note `*` doesn't match `/` per standard bash glob rules.

**Empty diff no longer auto-runs the full suite.** Since the FORCE_FULL-opt-in hardening (see "Full-suite is OPT-IN" below), an empty/errored diff against the default base → run ZERO bats (or skip on an unresolvable base), NOT the full suite. The full suite is reachable only via the explicit `RITE_GATE_FORCE_FULL=1` / deliberate `DIFF_BASE=HEAD` signals. **Empty selection** (diff exists, no covered tests) skips bats entirely with `mode=targeted selected=0`.

**Diag emission:** every gate run logs `[diag] TEST_GATE_SELECTION mode=targeted|full selected=N total=N pr=N`. Since the trigger removal, `mode=full` means only "no diff computable". The health report aggregates these into a "Test Selection" sub-section under Test Gate, with a WATCH threshold at avg selected/total > 50% (indicates header adoption is lagging).

**Override the diff base** via `RITE_TEST_GATE_DIFF_BASE` (default: `origin/main`). Useful for CI or local debugging.

**Glob expansion hazard.** The selection function calls `set -f` (noglob) before splitting comma-separated patterns, then `set +f` after. Without `set -f`, a header like `lib/utils/*.sh` would be expanded against the filesystem at parse time, replacing the pattern with the list of currently-matching files — breaking the case-statement match against changed paths.

**Implementation:** `tests/regression/test-gate-targeted-selection.bats` (parser, file matching, glob handling, targeted-only pinning tests, edge cases).

### Fix-Loop Gate: Incremental Selection (#724)

**2026-06-26.** During the Phase-3 fix loop, the post-fix gate selects bats files against the **pre-fix HEAD**, not `origin/main` — so each iteration re-runs only the tests covering what *that* fix changed, not the full cumulative targeted set.

**The waste it fixes:** the cumulative `origin/main...HEAD` diff always includes the issue's main change, so the gate re-selected and re-ran the *same* targeted set (including the slow `lib-resource-safety.bats`, which covers `lib/**/*.sh`) on **every** iteration — even when a fix only touched docs. Live: #724 ran the identical 17-file gate **4 times** (~17 min) finding the same 3 failures. With incremental selection a doc-only fix selects ~0 bats and the gate is near-instant.

**Mechanism** (`workflow-runner.sh::run_workflow`): capture `_pre_fix_head=$(git rev-parse HEAD)` before the fix session, then run the loop gate with `RITE_TEST_GATE_DIFF_BASE="$_pre_fix_head"`. The initial Phase-2 gate still runs full (against `origin/main`); only the per-iteration re-runs are incremental.

**Correctness:** each change is gated when introduced (its own coverage), relying on accurate `sharkrite-test-covers` headers (the green-main Phase-2 tightening + the `MISSING_TEST_COVERAGE_HEADER` lint). `post-merge-verify` re-runs the gate on the merged state as the cumulative backstop. **Enforcement:** `tests/regression/gate-incremental-fix-loop-selection.bats`.

### Gate Block-on-Any (CRITICAL)

**2026-06-25 (Phase 3).** The post-commit gate blocks/feeds the fix loop on **any** test failure in the targeted selection: **`outcome=passed ⟺ zero failures`**. There is no new-vs-pre-existing classification — a failure in a selected file fails the gate, full stop.

**Why this is sound now (and wasn't before):** `main` is kept **green** (the green-main work, #707 — Phases 1/2 fixed the ~30 accumulated reds and added lint rules + coverage headers so it stays green). With a green base, every failure in the targeted selection is *this change's* to fix, so blocking on all of them is correct and can't wall off unrelated PRs.

**History — the "gate-green gap" and the baseline-diff interlude:** before main was green, ~30 tests were red on it. The gate ran them, reported `outcome=failed`, but with new and accumulated-pre-existing failures indistinguishable, runs either merged red anyway or churned the fix loop on breakage the change never caused. The interim fix (#699, "baseline-diff") classified each failure as new vs pre-existing by re-running the failing files at the diff base in a throwaway worktree and suppressing pre-existing reds, so only *new* failures blocked. That machinery (`_classify_test_failures`, `_compute_baseline_red_names`, the per-base-SHA cache, the probed-file cap, `RITE_GATE_BASELINE_DIFF`) existed **only to tolerate the red baseline**. Once green-main eliminated the baseline, Phase 3 **deleted all of it** (~200 lines) — block-on-any needs no probe, no cache, no worktree, no operator valve. Both green and failing runs pay zero baseline cost because there is no baseline step.

**Mechanism** (`lib/utils/test-gate.sh::run_test_gate`): the targeted bats run's exit code drives the outcome directly — `_tests_exit != 0 → _tests_blocking=1 → outcome=failed`. The findings JSON `tests[]` contains every `not ok` (parsed from the TAP report), and the digest names them via `_extract_tap_failure_names` → `_tap_failure_name` (the two TAP-name helpers retained from the baseline era). `FORCE_FULL` and the no-diff post-merge path always blocked on any failure; the targeted path now matches them — one rule everywhere.

**Three-stage gate shape (#1240).** `run_test_gate` has three distinct stages: (1) **plan/select** — compute changed paths and select bats files (`gate-selection.sh`); (2) **execute** — run make shellcheck + make lint + bats, handle watchdog kills, flake retry, and not-run synthesis (`gate-runners.sh`, inline in `run_test_gate`); (3) **assemble** — parse raw output files and write the findings JSON. Stage 3 is **pure**: `_gate_build_verdict` (`gate-verdict.sh`) reads `_lint_raw_file` + `_tests_raw_file` + exit codes and writes the JSON via `_gate_write_json`, with no bats/make/git invocations. All watchdog/notrun synthesis is done in stage 2 before the call; `_gate_build_verdict` sees only the final `not ok` lines. Callable in isolation for unit-testing the JSON shape without a real test runner.

**Diag:** `[diag] TEST_GATE outcome=passed|failed lint_count=N test_count=N duration_s=N pr=N` — `test_count` is the failing-test count (= the blocking count, since all failures block).

**Gotcha (retained helper, pinned by tests):** `_tap_failure_name` must `printf '%s\n'` (not `'%s'`) — BSD `sed` preserves the absence of a trailing newline, so a newline-less line yields a name with no newline and a loop concatenates adjacent names.

**Enforcement:** `tests/regression/gate-block-on-any.bats` — a failing test in the targeted selection fails the gate (exit 1, reported in `tests[]`, not suppressed) + the `_tap_failure_name` canonicalizer. The selection logic (FORCE_FULL opt-in, targeted-by-changed-paths) is pinned separately by `gate-force-full-optin.bats` and `test-gate-targeted-selection.bats`.

**Merge boundary (#718).** Block-on-any now extends to the **merge boundary** as well as the fix loop. Gate findings are injected into the assessment as `### [GATE] … - ACTIONABLE_NOW` items (structured header prefix). At the 3/3 retry cap, `assess-and-resolve.sh` distinguishes `[GATE]`-tagged items (objective test/lint failures) from LLM-severity HIGH review findings: gate-origin items that survive all retries are treated as non-deferrable — they block the merge (`exit 1`, same path as CRITICAL) rather than being filed as tech-debt and merged. Non-gate HIGH review findings continue to follow the existing retry-cap defer+tech-debt path. Live regression: issue #649 — 2 gate failures, loop hit 3/3, HIGH `[GATE]` deferred to #714, PR #712 merged red.

**RETIRED 2026-10-13 — layer 1 removed.** The batch preflight below ran the full unfiltered suite before every batch (10–25 min of fixed cost) and halted the batch on any failure. Because it ran the suite through the gate's `bats --jobs 8` parallel group, the `tests/concurrency/` files — which spawn competing processes by design — starved past the 120s `BATS_TEST_TIMEOUT` and reported a healthy main as red, halting two batches (2026-10-12, 2026-10-13; 26 of 29 "failures" carried `# timeout after 120 s`). Standing rule: **a full suite never runs inside a sharkrite workflow — only in the overnight `rite --full-suite` pipeline.** Layer 2 (attribution subtraction) remains in the code but is dormant: nothing writes the baseline file now. If the red-main problem needs solving again, do it lazily — on an actual gate failure, re-run only the failing tests against main and subtract the ones that fail there too — never with an upfront full suite.

**Red-Main Degradation Contract (#1149).** The block-on-any soundness argument has a precondition: **main must be green**. In target repos that invariant may not hold. Live failure (LeadFlow 2026-07-05, batch rite 401 128 383 340 113 435 431): main had 18+ failing dashboard tests; 51 main-inherited failures fed into `ACTIONABLE_NOW` for issue #401; the fix loop began a capped 30-min attempt to repair the repo's red main inside one issue's PR — and projected the same churn across all 7 batch issues.

The fix is a two-layer defense:

1. **Batch preflight** (`lib/core/batch-process-issues.sh`): before processing any issue, the batch runs the full gate once against a detached `origin/main` worktree (`RITE_GATE_FORCE_FULL=1`). If main is red:
   - **Without `RITE_ACCEPT_RED_MAIN=1`**: halt immediately (exit 20) with the failing test/lint list and explicit options — fix main, or re-run with `RITE_ACCEPT_RED_MAIN=1` to proceed with attribution.
   - **With `RITE_ACCEPT_RED_MAIN=1`**: save the baseline gate findings as `${RITE_STATE_DIR}/gate-main-baseline.json`, export `RITE_MAIN_BASELINE_FILE`, and proceed with the attribution path.

2. **Attribution subtraction** (`lib/core/assess-and-resolve.sh`): when `RITE_ACCEPT_RED_MAIN=1` and `RITE_MAIN_BASELINE_FILE` exists, per-issue gate findings are split:
   - Failures also present in the baseline (`test_name` exact match for tests; `file+rule` match for lint, line-number-agnostic) → `INFO_ONLY` (not counted toward `GATE_NOW_COUNT`, not entered in the fix loop, visible in the assessment but not blocking).
   - Branch-only failures → `ACTIONABLE_NOW` as usual.
   - When ALL failures are inherited, the synthetic empty-findings block is suppressed (no phantom "gate exited non-zero but no findings" item fires).

**Green-main repos:** zero behavior change. The preflight is one additional targeted gate run; it exits 0 fast and the rest of the batch proceeds normally.

**Why not delete baseline-diff machinery again?** The deleted baseline-diff (`_compute_baseline_red_names`, #699→Phase 3) was a per-issue per-gate-round probe — it re-ran failing files at the diff base every fix loop iteration to suppress pre-existing reds. The attribution here is a single preflight + one baseline comparison per issue assessment: no per-round probe, no worktree per issue, no per-SHA cache. The cost is one full-suite run per batch start on `origin/main` — paid once, not per-issue, and only when main is actually red.

**Enforcement:** `tests/regression/batch-preflight-green-main.bats`.

### Full-suite is OPT-IN; the probe is capped (CRITICAL — the "full suite every time" fix)

**2026-06-24.** A 10-agent audit traced the recurring "the full/near-full bats suite runs every time" complaint to **two independent escalations**, both now bounded. The recurrence pattern was always the same: a fix closed one path, a *different* path stayed open, so it "regressed."

**1. `FORCE_FULL` is opt-in only.** `_select_tests_by_changed_paths` emits `FORCE_FULL` (run all ~181 files) on an **empty changed-file set**, and `run_test_gate`'s `_changed_files=$(git diff --name-only "$base"...HEAD 2>/dev/null || true)` **launders a git-diff error into the same empty string** as "no commits". So a transient `origin/main` resolution hiccup — or any caller reaching the gate without an upstream non-empty-diff guarantee — silently ran the whole suite. The dispatch in `run_test_gate` now decides explicitly:
- `RITE_GATE_FORCE_FULL=1` **or** a deliberately-`HEAD` diff base → `FORCE_FULL`. After the changes below, the only full-suite run anywhere is the **deliberate, scheduled `rite --full-suite` safety net** (plus full-run tests) — **never** part of an issue lifecycle. (post-merge-verify's main-broken full-suite check was removed — see "No full suite in the issue lifecycle" below.)
- diff base unresolvable → skip bats with a loud `TEST_GATE_SELECTION mode=skipped reason=unresolvable_diff_base` diag — **never** a silent full run.
- base resolves but zero changed files → run **zero** bats (no commits), not 181.
- non-empty diff → normal targeted selection (`_select_tests_by_changed_paths` is only ever called with non-empty input now, so it can no longer return `FORCE_FULL` on the hot path).

A normal `rite <N>` run never sets the opt-in or a HEAD base, so a transient empty diff can no longer escalate it.

### No full suite in the issue lifecycle (CRITICAL)

**2026-06-24.** Two more changes ensure the full bats suite **never runs during an issue run** — the only full-suite run is now the deliberate, scheduled `rite --full-suite`.

1. **Concurrency tests are excluded from the gate's targeted selection** (`_select_tests_by_changed_paths` skips `tests/concurrency/*`). They spawn processes that rendezvous at file-based barriers; under the gate's `bats --jobs` the box is oversubscribed and the barriers throw **false timeouts** — verified: the suite passes serially (exit 0) but produces ~77 `Barrier timeout` failures under `--jobs 8`. Those false failures used to **cascade**: fail the gate → trigger post-merge-verify's main-broken full-suite check → flake again (a *silent* full suite). Real coverage of these race tests comes from a serial context (`bats tests/concurrency/` directly), not the parallel gate.

2. **post-merge-verify's main-broken full-suite check was REMOVED.** It used to re-run the *entire* suite on `origin/main` when the post-merge gate failed, to ask "is main broken vs. did this merge break it?" That is now **redundant**: `main` is kept green, so a post-merge gate failure IS the merge's doing → `return 1` directly. (Originally justified via baseline-diff's per-failure classification, #699; Phase 3 removed baseline-diff but the conclusion is unchanged — green main makes any post-merge failure the merge's.) It was also the **last full-suite run in the lifecycle** and the source of the flake cascade. The caller already handles `return 1` (revert), so removal is contained.

**Enforcement:** `test-gate-targeted-selection.bats` (a concurrency test covering a changed source is NOT selected); `post-merge-test-exit-propagation.bats` (gate failure → `return 1`, gate runs exactly once, no full-suite main-broken pass).

**2. The baseline probe was deleted (Phase 3).** While the red baseline existed, `_compute_baseline_red_names` re-ran failing files at the diff base; on a red main it ballooned into a near-full SECOND suite, so it was bounded with a probed-file cap, `--jobs` parallelism, and `</dev/null`. Phase 3 removed the whole probe along with baseline-diff (see "Gate Block-on-Any") once green main left it nothing to tolerate — so there is no second suite to bound anymore.

**Enforcement:** `tests/regression/gate-force-full-optin.bats` (real mock-gate: empty `origin/main` diff → NOT full; `RITE_GATE_FORCE_FULL=1` and `DIFF_BASE=HEAD` → full).

### Serial Gate Hint (`sharkrite-gate-serial`) (#724)

**2026-06-26.** Some bats files are load-sensitive — they spawn many subprocesses, mass-source the full lib tree, or are otherwise flaky when other bats workers are running concurrently under `bats --jobs N`. Under block-on-any, a single spurious flake from such a file blocks the gate and feeds the fix loop, burning retry iterations on a phantom failure (#649: `lib-resource-safety.bats` reported 2 `MISSING_RESOURCE_GUARD` tests as `not ok` under `--jobs 8`; both passed cleanly in isolation). *(2026-07-05 correction: a large share of what looked like `lib-resource-safety` load-flake was actually `validate-setup.sh` running its validation program at source time — an environment dependence fixed in #899/#902. The load-sensitivity mechanism described here remains real for genuinely subprocess-heavy files, but attribute a failure to load only after ruling out env dependence.)*

**Why not exclusion?** Concurrency tests (`tests/concurrency/*`) are **excluded** from the gate entirely because their failure mode (file-based barrier timeouts) is inherent to parallelism and provides no useful signal under `bats --jobs`. `lib-resource-safety.bats` is different: the tests are sound, the coverage is necessary (every lib-touching issue selects it via `lib/**/*.sh`), and the failures are load-induced rather than semantically parallel. Excluding it would silently drop valid coverage from the targeted gate.

**The fix: per-file serial hint.** A bats file that declares `# sharkrite-gate-serial` in its first 15 lines runs without `--jobs` (serial) while the rest of the selected files still run in parallel. The hint never affects selection — the file is still included whenever its covers header matches changed paths. It only changes the job-level of the invocation.

**Mechanism (`lib/utils/test-gate.sh::run_test_gate`):**
1. `_bats_file_is_serial <path>` — reads first 15 lines, returns 0 if `# sharkrite-gate-serial` is present.
2. After selection, the targeted path splits `_selection` into `_parallel_files[]` and `_serial_files[]` arrays.
3. Parallel batch runs with `_bats_jobs_args` (`--jobs N`) as before; serial batch runs without `--jobs` (sequential).
4. Both runs append TAP output to `_tests_raw_file`; exit codes are OR'd — any failure in either batch blocks the gate (block-on-any preserved).
5. A `BATS_SERIAL_SPLIT parallel=N serial=M pr=P` diag line is emitted when serial files are present.

**Marker constant:** `RITE_MARKER_GATE_SERIAL="sharkrite-gate-serial"` in `lib/utils/markers.sh`.

**Files with the hint:** `tests/regression/lib-resource-safety.bats` (sources every lib file twice; parallel-unsafe under load).

**Enforcement:** `tests/regression/test-gate-targeted-selection.bats` — serial-hinted file is split from parallel batch; non-serial file is not affected; block-on-any is preserved across both batches.

### Bats Parallelism: Census-Scaled `--jobs` (#1165)

**2026-10-12.** Under 3+ concurrent batch runs, each gate's bats invocation spawned `--jobs ncpu`, oversubscribing the box and starving timing-sensitive tests past `BATS_TEST_TIMEOUT` (live: supervised-ux batch 20261011-231056, `_stale_resolve_base_branch` fallback tests failing only under three-batch load).

**The fix: gate census.** Each gate registers its `$BASHPID` (subshell PID — `$$` is the parent orchestrator's PID and is wrong when `run_test_gate` is backgrounded with `&`) under `${RITE_LOCK_DIR}/gate-census/<pid>` at the start of the sharkrite bats section in `run_test_gate`. `_census_live_gate_count` counts entries whose PID passes `kill -0`, reaping dead entries in the same pass. `_compute_bats_jobs` receives the live count and applies: `jobs = ncpu` when `count ≤ 2`, else `max(2, floor(ncpu / count))`. The census entry is removed on normal exit and on crash via the existing crash-sentinel EXIT trap — each gate removes only its own PID-named file (no globs, #345 class).

**Carve-out for ≤2 gates (preserves #510).** The cap of 4 was removed in #510 because uncapped measured faster even with two concurrent batches (33s vs 38s): OS scheduling keeps all cores busy while the cap leaves some idle. That result holds at any count ≤ 2. Scaling kicks in only at count ≥ 3 (≥ 2 *other* active gates).

**`RITE_BATS_JOBS` still wins unconditionally.** An explicit env override bypasses the census formula entirely — the override branch returns before the census count is consulted.

**Diag:** `BATS_JOBS jobs=N census=M pr=P` (extended from the pre-#1165 `jobs=N pr=P` format).

**Enforcement:** `tests/regression/gate-bats-job-census.bats`.

### Gate Per-Test Timeout (`BATS_TEST_TIMEOUT`)

**2026-06-26.** The gate had only an *outer* timeout — `RITE_GATE_WAIT_TIMEOUT` (#654), ~30 min for the whole run. A single hung test therefore stalled the entire gate until that backstop fired. Live trigger: a developer machine's `python3` was a self-exec'ing wrapper (infinite loop); `venv-bootstrap-failure-loud.bats` invoked it and hung, wedging the gate for 30 min on one test.

**The fix:** `run_test_gate` exports `BATS_TEST_TIMEOUT="${RITE_BATS_TEST_TIMEOUT:-120}"` once, before the full/parallel/serial bats invocations (right after `export TERM`), so all three subshells inherit it. bats kills any test exceeding the limit and emits `not ok N # timeout after Ns` — which block-on-any then treats as a failure (correct: a hung test *is* a failure). A wedged test now costs ≤120s, not 30 min.

**Why this works on macOS:** bats' per-test timeout uses a `pkill`/`ps` countdown (`bats-exec-test::bats_start_timeout_countdown`), **not** the GNU `timeout` command — so no coreutils shim is needed. Verified against bats-core 1.13.0.

**Layering:** this is per-*test*; `RITE_GATE_WAIT_TIMEOUT` remains the per-*run* backstop for pathologies bats can't self-interrupt (e.g. a wedged `make check`). The two are complementary, not redundant.

**Enforcement:** `tests/regression/gate-per-test-timeout.bats` — asserts the export exists with the RITE override, precedes the first bats invocation, and that bats actually honors the timeout on this host.

### Gate Output Routing: live in foreground, log-only when concurrent (CRITICAL)

**2026-06-24.** The post-commit gate's raw output (concurrent `make shellcheck` + `make lint`, plus bats `-F pretty`) is voluminous. Two failure modes argued for routing it off the terminal: (1) the review-loop gate runs **backgrounded, concurrent with review generation** (`workflow-runner.sh` Phase 2/3), so its live stream interleaved mid-phase with unrelated output; (2) a single failing bats test replays its **entire captured stdout** — for whole-session tests (e.g. `tests/smoke/source-all-libs.bats`) that's a nested-transcript wall.

**But routing it to the log UNCONDITIONALLY made foreground gates look like a hang** (live regression — user report 2026-06-24): a foreground gate (post-merge-verify, fastpath, standalone) running a multi-minute bats suite with NOTHING else printing reads as a freeze. With no concurrent output to protect, a silent gap is strictly worse than the "test spam" it avoids. So routing is now **conditional**:

- **`RITE_GATE_BACKGROUND=1`** (set by the two concurrent `run_test_gate &` launches in `workflow-runner.sh` Phase 2/3) → `_gate_raw_sink="${RITE_LOG_FILE:-/dev/stdout}"`: raw to the log only, terminal gets the digest. No interleave with the concurrent review stream.
- **default / foreground** → `_gate_raw_sink="/dev/stdout"`: raw streams **live** to the terminal so progress is visible (the bin/rite nested-procsub tee still captures it into the log). The digest still prints as a recap.

The rule: **only suppress the live stream when something else is competing for the terminal.** Any new `run_test_gate` caller that runs concurrent with other terminal output must set `RITE_GATE_BACKGROUND=1`; foreground callers must not.

**Digest (both modes):** a **compact digest** is emitted just before `_gate_write_json`:
- `[test-gate] bats: N passed, M failed (blocking)`
- the **names** of the blocking (new) failures, one per line, plus `Full bats output: <log>`
- lint finding count when non-zero; a one-line green confirmation when all pass

**Why log-only is safe:** the JSON findings the assessment consumes are parsed from the TAP report file (`report.tap` → `_tests_raw_file`), never from the terminal stream — so removing the stream from stdout loses nothing the workflow depends on. The digest's blocking-failure names come from `_extract_tap_failure_names`.

**Fallback:** when `RITE_LOG_FILE` is unset (unlogged runs, sandboxed tests), `_gate_raw_sink` is `/dev/stdout` — raw output keeps its old destination so nothing is lost.

**TERM must be set for the pretty formatter (exit-code honesty).** `bats -F pretty` shells out to `tput`; with `TERM` **unset** (launchd, cron, non-TTY CI) tput errors and bats exits **non-zero even when every test passes** — the gate would read that as a failing suite and spuriously block the merge / fail `post-merge-verify`. The gate defaults `export TERM="${TERM:-dumb}"` before invoking bats so the run is exit-code-honest in every environment (directly relevant to the headless launchd jobs — health-report, full-suite). Tests that drive the real gate must NOT use the `cmd; _exit=$?` idiom to capture the gate's exit: sourcing `test-gate.sh` enables `set -e`, so a non-zero gate aborts the script before `$?` is read — use `cmd || _exit=$?`.

**Enforcement:** `tests/regression/test-gate-output-routing.bats` — asserts raw output lands in the log (not stdout), the digest + named blocking failure appear on stdout, and the no-log fallback preserves raw output on stdout.

**Portability landmine in the JSON parsers (do not revert):** `_parse_lint_line` and `_parse_bats_failure_line` sanitize finding text via `_sanitize_json_value`, which strips C0 control bytes with **`tr -d '\001-\010\013\014\016-\037\177'`**, NOT a sed `[\x01-\x08…\x7f]` hex-range character class. BSD `/usr/bin/sed` (every stock macOS) rejects that range with `RE error: invalid character range`; under the callers' `|| true` the whole sed silently returns **empty**, so every `[GATE]` finding fed to the assessment carried an empty `test_name`/`message` on macOS (the bug was masked because GNU sed on Linux CI accepts the range). The ANSI-escape strip (`s/\x1b…//`) stays in sed — BSD sed handles single `\x1b` fine; only hex *ranges* break. Regression guard: `bats-pretty-terminal.bats` test 11 + the behavioral pipeline tests assert non-empty parsed names on the host's own sed.

### Fix-review prompt: syntax-check before declaring done

Step 5 of the [claude-workflow.sh](../../lib/core/claude-workflow.sh) fix-review prompt now requires Claude to run `bash -n <file>` on every shell file it touched before declaring done. This is a fast, in-session check that catches broken syntax before commit. Full lint and test verification runs post-commit via the parallel gate (see "Verification Out of Fix Session" above).

**`bash -n` is prompt-level only — not enforced by the workflow.** The fix-review session is editing-only: it does not call the dev-phase `run_test_gate()` and does not return exit 3. If Claude skips the `bash -n` check and commits a syntax error, the parallel gate's `make check` (which includes shellcheck) will catch it in the next cycle as a `[GATE] ACTIONABLE_NOW` item. There is no in-workflow enforcement of the `bash -n` step.

**Why not full test/lint in-session:** PR #432's fix loop burned the full 1800s budget on `make check` thrash (full-codebase shellcheck on files the fix never touched), then the outer gate ran `bats tests/` non-recursively and found zero tests — both verification windows were simultaneously broken. Moving verification out of the fix session lets it run: (a) after commit so it reflects the actual committed state, (b) in parallel with review generation (no extra wall-clock time), and (c) recursively (`bats -r tests/` instead of the old non-recursive `bats tests/`).

### Dev-session Phase 4: framing must match the prohibition (not just the body)

The dev-session prompt is assembled from a provider preamble (`claude_provider_dev_session_preamble` in `lib/providers/claude.sh`) plus the Workflow Instructions body in `claude-workflow.sh`. The preamble tells the model to build a TodoWrite list from a fixed phase skeleton; the body then details each phase.

**The contradiction (live regression, dogfood run 2026-06-09, batch issue #495):** #466 moved verification out of the dev session — it added the `--disallowedTools` block for `make`/`bats`/`pytest` and a body prohibition (Phase 4 step 3). But it left Phase 4 *framed* as run-the-suite in three other places: the preamble todo (`Phase 4: Testing & Validation - Running tests and verifying correctness`), the heading (`Testing & Validation`), and a Phase 1 cross-ref (`Skip to Phase 4 (Testing) to verify everything works`). The model builds its todo list from the preamble first, so it committed to a "Running tests" todo and ran `bats -r tests/` in the background, polling `BashOutput` hundreds of times — the exact timeout-burn #466 was meant to kill.

**Contract:** Phase 4 is **Test Authoring & Syntax Check & Lint**, not "Testing & Validation". Its in-session work is (1) write/update unit tests, (2) `bash -n` syntax-check, and (3) run `tools/sharkrite-lint.sh` on changed files (deterministic static analysis, not a test runner — bounded 3 passes). `tools/sharkrite-lint.sh` is the only project check tool permitted in-session; `make check`, `bats`, and `pytest` remain denied by the PreToolUse hook. Every place that *names or references* Phase 4 — preamble skeleton, heading, cross-refs — must use framing that does not invite running the suite. A prohibition in the body is necessary but not sufficient: a contradicting title/todo overrides it because the model acts on the todo it was told to create. When you reword one location, reword all of them.

**Collateral fix:** the preamble skeleton previously listed only Phases 0–5, omitting Phase 6 (Verify Scope Boundary, marked REQUIRED in the body). The model's tracked todos therefore never included the scope check. The skeleton now lists Phase 6, and the exit note says "After Phase 6".

**Enforcement:** `tests/regression/dev-prompt-no-suite-runs.bats` renders the actual preamble and asserts (a) no "Running tests"/"verifying correctness" framing, (b) the renamed heading, (c) no "verify everything works" cross-ref, (d) the write-tests + `bash -n` work is retained, (e) the `make`/`bats`/`pytest` prohibition is retained, (f) Phase 6 is in the skeleton.

**Deterministic backstop is broken — `--disallowedTools` is silently inert under `--output-format stream-json` (root-caused 2026-06-10, CLI 2.0.24):** the #495 live bypass is now reproduced. Sharkrite's dev/fix sessions invoke `claude --print --verbose --dangerously-skip-permissions --disallowedTools <list> --output-format stream-json` ([claude.sh](../../lib/providers/claude.sh) `claude_provider_run_agentic_session`). The CLI honors `--disallowedTools` in the default text output format but **ignores it entirely when `--output-format stream-json` is set** — verified deterministically with a sentinel-file Makefile target: text format never executes `make check`, the stream-json form always does. Because every real session uses stream-json, the *entire* deny list (git commit/push, gh, `rm -rf`, ssh, `/etc`, network) has never actually been enforced in production runs. The only thing preventing self-commits etc. has been prompt compliance, not the CLI block — which is why the code comment calling `--disallowedTools` "the primary safety mechanism" is incorrect.

**Fix direction (confirmed working):** a **PreToolUse hook** (passed via `--settings`) *is* enforced under stream-json — verified: a hook returning `permissionDecision: deny` for `make`/`bats`/`pytest` blocks the command in the same stream-json invocation where `--disallowedTools` fails. Migrating the deny list to a sharkrite-managed PreToolUse hook restores a real deterministic backstop. The Phase 4 prompt-framing fix above removes the *invitation* to run the suite; the hook would restore *enforcement*. Until the hook lands, treat the prompt framing as the only active control.

### Supervised commit/push is a single prompt (2026-10-11, issue #1128)

The supervised dev-flow previously asked five sequential questions: "Run tests before committing?", "Create commit?", "Accept this message?", "Push to remote?", and a separate pre-exit salvage pair. These are now consolidated to one: **"Commit and push N file(s)? [y/n/e]"** (plus the salvage equivalent on the interrupt path). `e` shows the message for edit then re-asks; `n` aborts as the old "Create commit? → n" path did. The "Run tests before committing?" prompt is deleted outright — `_run_dev_test_gate` runs the gate unconditionally for all non-orchestrated runs (auto and supervised standalone alike); the prompt duplicated machinery and invited the #495 framing regression. Auto mode is unchanged.

**Enforcement:** `tests/regression/supervised-commit-push-prompt.bats` — structural: old prompts absent, new prompt present, y/n/e case structure verified, `read -re` on e-path (backslash-clean); behavioral y/n/e contracts for the main flow via `_supervised_commit_push` (extracted issue #1368). Behavioral y/n/e for salvage path: `tests/regression/interrupt-trap-wip-safety.bats`. The `RITE_GATE_FINDINGS` builder (`_build_gate_prepend_items`) behavioral tests: `tests/regression/test-gate-parallel.bats`.

### Supervised standalone full-suite carve-out (2026-10-20, issue #1273)

**The situation:** `_run_dev_test_gate` now runs unconditionally for all non-orchestrated standalone runs (auto and supervised alike). In the sharkrite repo itself (dogfood), this triggers runner fallthrough to `make test` (full bats suite) — directly violating the CRITICAL "no full suite in an interactive path" doctrine.

**Why it is accepted:** Standalone supervised has no Phase 2/3 targeted gate to fall back on; `_run_dev_test_gate` is its only pre-commit verification. For non-sharkrite target repos (the normal case), the runner selects only the test framework relevant to the project's changed files, so the full-bats-suite problem is sharkrite-specific.

**Mitigation for sharkrite dogfood runs:** Set `RITE_SKIP_TESTS=true` when running supervised standalone in the sharkrite repo to skip the full suite and rely solely on the post-commit targeted gate from whatever orchestration context calls it next. The `RITE_SKIP_TESTS` path is already the canonical operator escape hatch and is honored before any runner is reached.

**Future fix direction:** Add sharkrite-specific targeted-selection logic to `_run_dev_test_gate` so standalone runs use `gate-selection.sh` rather than the full runner. That is a larger refactor tracked separately; this note is the acknowledgment required by the reword-all-locations contract.

### Dev test gate is skipped under orchestration (CRITICAL)

**2026-06-24.** `_run_dev_test_gate` in [claude-workflow.sh](../../lib/core/claude-workflow.sh) — the dev/initial-commit test runner — now returns immediately when `RITE_ORCHESTRATED=true`.

**The bug it fixes (live: issue 649 dev session wedged 78 minutes):** `_run_dev_test_gate` was called unconditionally before the orchestrated-skip block lower in the file, so on every `rite <issue>` run (always orchestrated — workflow-runner sets `RITE_ORCHESTRATED=true` at all call sites) the dev session ran the **full** test suite (`bats -r tests/` for sharkrite) and, on failure, spawned a **second** auto-fix Claude session. That is wrong on three axes: (1) **redundant** — the post-commit structured gate (`run_test_gate`, Phase 2/3) is the designated verification, with targeted selection + block-on-any + a bounded wait + a single fix loop; (2) **untargeted** — the full parallel suite produces load-induced flake (e.g. `Barrier timeout waiting for N processes`) that the duplicate fix session then churns on as if real; (3) **unbounded** — `_run_dev_test_gate` has no per-test timeout, so a test that blocks on stdin hangs the whole run (issue 649: the lint suite's `sharkrite-lint.sh` deadlocked on a tty stdin read, fd 0 = `/dev/ttys003`, 65 min and counting).

**Contract:** verification in orchestrated runs is the orchestrator's job (post-commit structured gate), never the dev session. Standalone `claude-workflow.sh` runs (no orchestrator) keep `_run_dev_test_gate` as their only pre-commit verification. History: #454 ("Move verification out of fix session") moved it out of the *fix* session but left the *dev* gate ungated.

**Enforcement:** `tests/regression/dev-gate-skip-when-orchestrated.bats` — `_run_dev_test_gate` runs no test command under `RITE_ORCHESTRATED=true` (probe: `RITE_TEST_CMD="touch <sentinel>"`), and the guard structurally precedes the `eval "$_test_cmd"`.

### Interrupt handler never auto-pushes WIP to a shared branch (CRITICAL)

**2026-06-24.** `cleanup_on_interrupt` (the `INT`/`TERM`/`HUP` trap in [claude-workflow.sh](../../lib/core/claude-workflow.sh)) auto-commits and pushes work-in-progress when a run is interrupted. Two guards now bound it:

1. **Feature branches only — never `main`/`master`/detached HEAD.** `_wip_commit_allowed <branch>` gates the commit+push; on a default branch the handler leaves changes *uncommitted* (preserved in the working tree) and says so. WIP preservation is for feature-branch worktrees; pushing unfinished work to a shared default branch is destructive.
2. **The trap is armed only for real execution**, inside a `RITE_SOURCE_FUNCTIONS_ONLY != 1` guard. A process that merely *sources* the file for its functions (tests) must not get a commit/push side effect when it is later killed.

**Live incident (what drove both guards):** a regression test sourced `claude-workflow.sh` under `RITE_SOURCE_FUNCTIONS_ONLY=1`; the trap armed unconditionally (it sat above the functions-only guard); `gtimeout` then killed the hung subshell while cwd was the primary checkout on `main`; the trap ran `git add -A && git commit -m "WIP: interrupted work on main" && git push -u origin main` — pushing unfinished work (and unrelated in-flight files) straight to `origin/main`. Either guard alone prevents recurrence; both together are defense-in-depth.

**Enforcement:** `tests/regression/interrupt-trap-wip-safety.bats` — `_wip_commit_allowed` denies `main`/`master`/empty and allows feature branches; the trap is not armed when sourced functions-only; and `cleanup_on_interrupt` checks `_wip_commit_allowed` before any `git commit`.

### Spend-cap detection in the dev session aborts the whole batch

When `claude --print` hits the user's spending cap mid-session, it emits a message like `Spending cap reached resets 11:20pm` (variations: `usage limit reached`, `[N]-hour limit reached`) and exits non-zero. Sharkrite's claude provider ([lib/providers/claude.sh](../../lib/providers/claude.sh)) `tee`s stdout to a temp file and greps both stdout and stderr after the session exits. If the cap pattern matches, the provider returns exit code 5 — which propagates through [claude-workflow.sh](../../lib/core/claude-workflow.sh) (both dev and fix paths) → workflow-runner.sh → batch-process-issues.sh's exit-5 handler → batch aborts.

**Why this matters — 2026-06-04:** the spend cap fired at the start of issue #321 in a batch of 8. Six subsequent issues (#321, #324, #328, #330, #331, #333) each cascaded through ~35-50s of dev-session startup before hitting the cap and failing. That's ~4 minutes of wasted dev-startup time + 6 false "failed" entries in the batch summary. The cap was already wired in 9 other paths (conflict resolver, divergence handler, fix-review push divergence, merge-time divergence, stale-branch handler) — the plain dev-session path was the gap.

### A file that is both a library and a script needs a mode guard

`assess-documentation.sh` is a script with top-level executable code (it parses `$1` as `PR_NUMBER`, calls `gh pr view`, runs the whole assessment, and ends with `exit 0`). Anything that sources it runs that entire flow as a side effect — and the `exit 0` terminates the *parent* shell.

**Live regression — 2026-06-04, finance-glance batch `rite 1 2 3 4 5 6 7`:** `bootstrap-docs.sh` used to `source assess-documentation.sh` just to use `generate_adr_for_ref`. On a fresh repo (no PRs), the sourced top-level called `gh pr view $1` (with `$1`= issue number), got back JSON missing `.files` and `.commits`, hit `jq: error (at <stdin>:1): Cannot iterate over null (null)`, continued into the post-merge documentation summary, then hit `exit 0`. That terminated workflow-runner.sh with status 0. The batch reporter saw exit 0 and logged `✅ Issue #1 → PR #1 (167s)` — except issue #1 was still open, no branch existed, no PR existed.

**Pattern lesson:** Same class of bug as [Test stubs MUST NOT live in production paths](#test-stubs-must-not-live-in-production-paths-critical) below: a file that's BOTH a library (defines functions other code wants) AND a script (runs top-level code on source/execute) without a guard separating the two modes. Sharkrite's options for handling this:

1. **Extract the function** to its own file in `lib/utils/` (or another helpers location). The library file has no top-level executable code. *This is what was done for `generate_adr_for_ref` (since retired with the internal-docs layer, 2026-10-21).*
2. Use `RITE_SOURCE_FUNCTIONS_ONLY=1` guard pattern (see `lib/core/local-review.sh` as the in-repo example) — caller sets the env var before sourcing; the script's executable body checks it and returns early.

Option 1 is preferred when the function is reusable. Option 2 fits when the script is dominated by a single workflow that doesn't decompose cleanly.

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

### Stale Review Loop — SHA-Based Staleness Detection

**The canonical staleness check is SHA-based, not timestamp-based.** The 2-reroute guard in `workflow-runner.sh::phase_assess_and_resolve` is defense-in-depth; with correct SHA detection it should rarely fire.

**Every staleness/currency decision in the orchestrated fix loop uses the SHA oracle.** There are two sites in the orchestrated fix loop (`detect_review_state` in `lib/utils/pr-detection.sh` is the standalone-path site — timestamp-only, tracked for migration in issue #1305):
1. `workflow-runner.sh::phase_create_pr` — decides whether to skip the push/review phase (review already current)
2. `assess-and-resolve.sh` — decides whether a review is stale and must reroute back to Phase 2

Both orchestrated-loop sites extract the `commit:<sha>` attribute from the review marker and compare it to the current branch HEAD. Using the same oracle at both sites prevents the deadlock described in issue #1303: Phase 2 declares the review "current" while Phase 3 declares it "stale", producing an infinite reroute with no progress (live: issue #1231, batch `20261014-184054`, 7h23m wasted after correct dev work).

**Primary check (SHA-based):** `local-review.sh` embeds the HEAD SHA at review generation time into the review marker:
```
<!-- sharkrite-local-review model:X timestamp:Y commit:<sha> -->
```
Both orchestrated-loop sites use `extract_review_sha` (defined in `lib/utils/review-helper.sh`) to parse the embedded SHA:
- `review_sha == HEAD_sha` → review covers HEAD, no reroute / skip is valid
- `review_sha` is ancestor of HEAD → review is genuinely stale (fix commits were pushed after review), do not skip / reroute to Phase 2
- `review_sha` not in ancestry chain → likely a force-push, treat as stale
- No `review_sha` (pre-#354 review) → fall back to timestamp comparison

**Fallback check (timestamp-based):** For reviews generated before issue #354 (no `commit:` attribute), the old epoch-seconds comparison is used as fallback. This path is preserved for backward compatibility at both orchestrated-loop sites.

**Why timestamps alone are insufficient (issue #354):**
Timestamps are racy: the review's `createdAt` from the GitHub API can lag behind the local git commit timestamp by seconds to minutes (API eventual consistency). In a fix-loop iteration, a fix commit pushed at T+1 and a new review generated at T+2 can still appear "stale" if the API returns T+1 as the review timestamp but the local commit time reads T+2. SHAs are deterministic: the review either covers this commit or it doesn't.

**Live false-positive (2026-06-04, issue #354 / PR #342):** Finding counts changed across iterations (MEDIUM/LOW counts fluctuated), proving the review was being regenerated. Yet the staleness detector still flagged each fresh review as stale — the 2-reroute guard fired, the workflow exited 1, and a clean/mergeable PR was abandoned. Fix: embed SHA in review marker, compare SHAs instead of timestamps.

**Live deadlock (2026-10-14, issue #1303 / PR #1304):** Phase 2's timestamp-based "current" check and Phase 3's SHA-based "stale" check disagreed. Phase 3 rerouted to Phase 2; Phase 2 declined to regenerate. Hard-fail after 7h23m on a correct, clean PR. Fix: align Phase 2's skip decision to the same SHA oracle as Phase 3.

**Standalone-path deadlock risk (`detect_review_state`, issue #1305).** `detect_review_state` in `lib/utils/pr-detection.sh` uses timestamp-only comparison (the same racy check that caused the #354 false-positive). The standalone `--review-latest` path calls it to decide whether to skip regeneration; `--status` calls it to display review currency. When GitHub API `createdAt` post-dates the local commit time but the review's embedded SHA mismatches HEAD, both `--review-latest` and `--status` incorrectly report "current": `--review-latest` refuses to regenerate and `--status` shows a false "Current" verdict. `--assess-and-fix` is not deadlocked by this (its `assess-and-resolve.sh` SHA oracle detects the stale review, returns exit 3, and the standalone fix loop triggers a fresh review), but `--review-latest` and `--status` in isolation will mislead the user. This is the same oracle-disagreement class as #1303, reproduced via the manual path.

**Do NOT replace SHA comparison with timestamp comparison** at either orchestrated-loop site. Timestamps are racy (GitHub API eventual consistency lag). `assess-and-resolve.sh` has carried this note since #354; `workflow-runner.sh::phase_create_pr` now carries it too.

**Do NOT remove timestamp comparison.** It's still used for display (`--status` timestamp output) and as a backward-compat fallback for pre-#354 reviews. Only remove it from the *primary staleness decision* path.

**Do NOT increase the reroute cap from 2.** The guard isn't the bug; the detection is. Bumping the cap delays failure without addressing root cause.

**Accepted head-resolution divergence between Phase 2 and Phase 3 (issue #1306).** Both orchestrated-loop sites use the same SHA oracle (`extract_review_sha`) to _compare_ a review's embedded SHA against the branch HEAD. However, they resolve what "HEAD" means through different authorities:

- **Phase 2** (`workflow-runner.sh::phase_create_pr`): uses `git rev-parse HEAD` (local git). It only enters the currency check when `local_head == remote_head` (confirmed-equal tracking refs), so local git is sufficient for the common case.
- **Phase 3** (`assess-and-resolve.sh`): uses `resolve_pr_head_sha`, which queries the GitHub API (`headRefOid`) first and falls back to local git only when the API is unavailable and the local branch name matches.

The residual deadlock window: an external force-push to the PR branch followed by a stale local tracking ref (git fetch not yet run) can leave both `git rev-parse HEAD` and `git rev-parse origin/<branch>` pointing at the pre-force-push SHA. Phase 2 enters the currency check, compares the review SHA against the stale local SHA, sees a match ("current"), and skips the push/review phase. Phase 3 then calls the GitHub API, sees the post-force-push SHA, and declares the review stale — rerouting back to Phase 2, which again skips, producing a deadlock.

This window is narrow in practice (requires an external force-push — rare in a single-operator workflow) and is partially protected by the issue lock (concurrent external pushes are uncommon). The full fix — calling `resolve_pr_head_sha` in Phase 2 too — exceeds the time budget of the issue that introduced the SHA oracle alignment (#1303); issue #1306 documented the divergence and added the sentinel, but the Phase 2 migration itself needs a new follow-on issue.

The structural sentinel test `"phase_create_pr HEAD resolution: uses git rev-parse (not resolve_pr_head_sha) — accepted divergence from Phase 3"` in `tests/regression/stale-review-detection-sha-based.bats` documents this accepted condition and will fire when the Phase 2 migration lands.

### LOW Severity Threshold

LOW findings only become ACTIONABLE_LATER if they represent a real functional or security concern. "Consider doing X" and style suggestions are DISMISSED. Added after 5 of 7 tech-debt issues were closed as noise (code aesthetics, hypothetical optimizations, intentional patterns flagged as problems).

### Follow-up Defer Filter: Necessity Bar

The assessment prompt's old tie-break biased uncertain findings toward `ACTIONABLE_LATER` over `DISMISSED`, which generated nitpick follow-up issues (a recent run produced ~6 follow-ups, several pure cosmetic). The prompt in `lib/core/assess-review-issues.sh` now flips that bias for non-essential findings and adds a necessity bar: `ACTIONABLE_LATER` requires the assessor to state, in one phrase, what concretely breaks or regresses if the work is never done — a real defect, correctness/security risk, or broken contract. If no concrete regression can be stated, the finding is `DISMISSED`, not deferred. Cosmetic/style/naming preferences, speculative "could improve" / "might be nice", redundant-but-harmless code, and nice-to-have test coverage with no concrete regression risk are explicitly DISMISSED.

### Assessment May Not Defer the Issue's Own Acceptance Criteria

The necessity bar governs *non-essential* findings; the **SCOPE BAR** (added #791) governs the opposite hazard — deferring work the issue exists to do. A feature can otherwise merge "done" while its own core acceptance criteria are punted to follow-ups, shipping non-functional: LeadFlow's #46 CloudWatch-alarm feature merged while deferring its producer token (the event it must emit), its SNS subscription, and the alarm itself into follow-ups. The gate only blocks on TEST failures (Gate Block-on-Any), and those deferred ACs had no tests, so the unmet-AC feature merged clean. The rule, in the `ASSESSMENT_PROMPT` classification criteria of `lib/core/assess-review-issues.sh`, leans on the injected `ORIGINAL ISSUE SCOPE` section (`$ISSUE_DETAILS`): a finding identifying an UNMET acceptance criterion or core deliverable of the issue under assessment is `ACTIONABLE_NOW` and MUST NOT be deferred to `ACTIONABLE_LATER` — only findings OUTSIDE the issue's stated scope are deferral-eligible. This is the tractable prompt-level fix; the stronger deterministic follow-on (a merge gate that runs the issue's own AC verification commands, so an unmet, untested AC cannot pass) is noted future work.

---

## Doc Assessment (assess-documentation.sh, workflow-runner.sh)

`workflow-runner.sh` spawns `assess-documentation.sh` in the background during
the fix loop (`phase_spawn_doc_assessment`) and waits for it before merge
(`phase_wait_doc_assessment`). Two layers:

1. **Catalog maintenance (always)** — `update_conventions_from_marker`,
   `reconcile_tag_index`, `commit_catalog_files`. Deterministic, except the
   tag-dedup similarity/coverage checks in `reconcile_tag_index`, which call the
   `doc_assessment` model only when a PR declares new tags.
2. **Drift recording (opt-in)** — when doc consent is recorded
   (`RITE_DOC_MODE=sync|changelog`), one drift-log entry per merge. Never edits
   the user's docs. Unset or `off` records nothing; unattended runs never opt a
   repo in (`ensure_doc_mode` only asks in supervised interactive runs).

**Retired 2026-10-21:** the internal `.rite/docs/` layer — four parallel
sub-assessments (changelog/security/architecture/api) plus keyword-triggered
ADRs, a reconcile pass, cross-doc validation, and the `bootstrap-docs.sh`
first-run bootstrap. Nothing read its output, and it cost ~5 min and ~100k
tokens per merge plus a 5–6 min bootstrap on a repo's first issue.

**Retired 2026-10-21, same day:** the per-merge doc-sync rewrite
(`.rite/doc-sync.md`). It edited the user's docs on every merge with no approval
step, and saved the model's full response — stderr included — as the file. In
orrery (PRs #14/#15/#17) that put Claude CLI permission warnings with local
paths, the model's narration and a wrapping ```` ```markdown ```` fence into the
README on main. Also gone with it: the `gh pr diff` fetch (its only consumer)
and the per-merge `provider_validate_cli` health prompt. And the unattended
fallback that defaulted an unconsented repo to changelog mode — it had recorded
74 unreviewed entries, each with a model call, in sharkrite's own drift log.

See "Documentation Drift: Detect Per-Merge, Correct Per-Promote, Align On
Demand" below.

### Model Selection Per Task

Each workflow task uses the model that fits its nature — not the adjacent role's model.

| Task | Nature | Model | Why |
|------|--------|-------|-----|
| Code review (`local-review.sh`) | Catching subtle bugs, security issues, bash idiom edge cases | `RITE_REVIEW_MODEL` (default: `claude-opus-4-8`) | Deep reasoning, broad context retention — opus catches the corner cases that matter |
| Finding assessment (`assess-review-issues.sh`) | Classifying each review finding into ACTIONABLE_NOW / ACTIONABLE_LATER / DISMISSED | `RITE_ASSESSMENT_MODEL` (default: `claude-sonnet-4-6`) | Three-state classification of already-structured findings — not the reasoning that generated them. Before #1187 it inherited the review model from the review marker, so pinning review to fable-5 silently ran every assessment (the highest-count LLM call in the loop) on fable too |
| Issue planning (`plan-issues.sh`) | Generating GitHub issues from ADRs / architectural docs | `RITE_PLAN_MODEL` (default: `claude-opus-4-8`) | Highest-stakes reasoning stage — it must honor ADRs and never hallucinate fixtures. Kept on opus, but with its OWN var so it can't silently ride (or downgrade with) review |
| Doc assessment (`assess-documentation.sh` drift entries, `rite docs`, tag dedup) | "Did this diff change what doc X says? Propose the edit." | `RITE_DOC_ASSESSMENT_MODEL` (default: `claude-sonnet-4-6`) | Pattern matching, structured comparison, summarization — sonnet's sweet spot |
| Development (`claude-workflow.sh`) | Implementing code changes | `RITE_CLAUDE_MODEL` (default: `claude-sonnet-4-6`) | General dev work |
| Triage / classify (`triage-classify.sh`, doc auto-discovery in `bin/rite`) | Trivial-vs-substantive diff; doc categorization | `RITE_TRIAGE_MODEL` (default: `claude-haiku-4-5`) | Narrow bucket classification — haiku's job, not opus's |

**Principle: the model fits the task, not the adjacent role.** Before this was explicit, `assess-documentation.sh` had no model var and fell through to `resolve_model "review"` → `RITE_REVIEW_MODEL`. This created silent coupling: setting `RITE_REVIEW_MODEL=opus` for quality-critical review silently promoted doc assessment to opus too, inflating wall-clock from ~90-120s to 3-6 minutes and regularly firing the 180s watchdog. The **same trap** later bit planning: `plan-issues.sh` (and doc auto-discovery in `bin/rite`) passed `""` and rode the review model invisibly — the highest-stakes stage coupled to the one var most likely to be tuned. Fixed by giving planning its own `plan` role (default opus) and classification an explicit `triage` role, then enforcing "no bare `""`" in lint (Rule 31, `PROVIDER_MODEL_FALLTHROUGH`).

**Independence contract:** each role's var is fully independent. Changing one does not affect the others. The resolver dispatches by role:

```bash
claude_provider_resolve_model() {
  case "$1" in
    review)         echo "${RITE_REVIEW_MODEL:-claude-opus-4-8}" ;;
    assessment)     echo "${RITE_ASSESSMENT_MODEL:-claude-sonnet-4-6}" ;;
    plan)           echo "${RITE_PLAN_MODEL:-claude-opus-4-8}" ;;
    doc_assessment) echo "${RITE_DOC_ASSESSMENT_MODEL:-claude-sonnet-4-6}" ;;
    triage)         echo "${RITE_TRIAGE_MODEL:-claude-haiku-4-5}" ;;
    dev)            echo "${RITE_CLAUDE_MODEL:-claude-sonnet-4-6}" ;;
  esac
}
```

Note `plan` defaults to the same model as `review` (opus) *today*, but the point of the separate var is that this equality is not load-bearing: moving `RITE_REVIEW_MODEL` off opus must not drag planning down with it.

**New tasks must pick a role explicitly.** Never pass `""` as the model arg to `provider_run_prompt`, `provider_run_prompt_with_timeout`, or `provider_run_streaming_prompt` and rely on provider defaults — defaults may change, and an empty model silently resolves to the `review` model. Use the provider-agnostic **`provider_resolve_model <role>`** — code in `lib/core`/`lib/utils` must not call the claude-prefixed `claude_provider_resolve_model` directly (enforced by Rule 32, `DIRECT_PROVIDER_CALL`). Pick the role by nature: doc-like (pattern matching, summarization) → `doc_assessment`; bug-detection or nuanced reasoning → `review`; classifying review findings (NOW/LATER/DISMISSED or similar structured verdicts on existing findings) → `assessment`; issue generation → `plan`; bucket classification → `triage`.

### Wait timeout

`phase_wait_doc_assessment` bounds the wait with `RITE_DOC_ASSESSMENT_TIMEOUT`
(default 300s): a watchdog sends SIGTERM, the workflow warns and continues.
Doc assessment is never a merge blocker.

### DO NOT skip the assessment based on diff content

An earlier approach was rejected: checking whether the PR diff touched any `.md` files and skipping the assessment if not. This was wrong because the entire purpose of the assessment is to surface what docs should change based on dev work — even when the dev work only touched `.sh` or `.ts` files. A new security pattern, a new CLI flag, or a new architectural approach all warrant doc updates regardless of whether the dev session touched docs.

### Directed-Update Proposal Guards (#1208)

The per-proposal preview loop in `docs-command.sh::_docs_update_engine` enforces three safety guards before showing the preview. `_docs_update_engine` serves both directed (`rite docs "<instructions>"`) and reconcile (`docs_reconcile_drift`) call paths — the guards apply in both modes:

- **EDIT on a file not in the model's context (absent from docs map or excluded by 15KB cap)** — the context assembly loop in `_docs_update_engine` caps the total doc context at 15KB. Files that would push the total over the cap are skipped via `continue` (prospective-total check) and never sent to the model; files absent from the docs-map inventory are also never loaded. The guard tracks which paths entered `_ue_ctx_files` (a newline-delimited string built alongside `_ue_doc_ctx`). After context assembly, `_ue_map_content` is set to `_ue_ctx_files` (the advertise-only list) so the model's "Documentation files in model context" prompt section contains only in-context paths — the model will not propose EDIT for a cap-excluded file it was never told about. If it does propose one anyway, the guard catches it: a proposed EDIT targeting a path absent from `_ue_ctx_files` is auto-skipped with a warning. When `_ue_ctx_files` is empty (docs map absent or empty), the membership check is skipped entirely to avoid blocking all EDIT proposals wholesale. Files excluded by the cap also trigger a deterministic pre-call warning so the user is informed immediately rather than discovering a silent no-op after the LLM run.
- **EDIT on a large file** — a proposal to EDIT a file larger than 2,000 bytes is auto-skipped with a warning (the model only saw the first 2,000-byte excerpt, so applying the proposal would truncate the unseen content). This check fires only for files that passed the context-membership check above.
- **CREATE for a path that already exists** — a proposal to CREATE a file that already exists locally (`${RITE_PROJECT_ROOT}/${file}`) or on `origin/<target>` (checked via `git cat-file -e` after a fresh `git fetch origin <target>`) is auto-skipped with a warning (the model authored content without reading the original, so applying would overwrite it wholesale with unreviewed content). Genuinely new paths are unaffected.

The `git fetch origin <target>` before the proposal loop ensures the `origin/<target>` ref is current at guard check time — a file pushed to origin between the last fetch and the guard check would otherwise bypass the CREATE guard. **Apply-site defense-in-depth (#1232):** `_docs_apply_approved` mirrors this guard: after forking the worktree from `origin/<target>` (with its own `git fetch` at ~line 206), it re-checks `[ -f "$_aa_target_file" ]` before writing any CREATE proposal. A file pushed to origin during the interactive preview session will be present in the worktree (the fetch pulled it) and the apply-site guard refuses the write with a warning. This shrinks the window from the full preview session to the fetch-to-write interval, provided the apply-site fetch succeeds (the fetch is `|| true`; on network failure the worktree may not contain the newest origin files, so the residual window degrades back to the full preview session (the last successfully fetched origin/<target> state)).

### Proposal Format: Per-Generation End Token (#1233)

The proposal wire format uses a delimiter line to mark the end of each proposal's content block. A fixed delimiter like `---END---` is unsafe: any proposal whose content contains the `---END---` string (and future content documenting the format verbatim would place it on its own line) is silently truncated at parse time — self-referential risk since `docs/architecture/behavioral-design.md` (this file) and bats test fixtures both reference the `---END---` string.

**Fix:** `_docs_update_engine` generates a per-call unique end token before the feedback loop:

```bash
local _ue_end_token="---END-${RANDOM}${RANDOM}---"
```

The token is injected into the `DOC_UPDATE_EOF` prompt heredoc so the LLM knows which string to use as the end marker, and into the case pattern that detects the end-of-proposal during parsing. Because bash case patterns expand variables, `"${_ue_end_token}"` matches the generated string at runtime.

**Why this approach over escaping:** An escaping scheme (e.g. replace `---END---` in content with `\---END---`, unescape on parse) requires the LLM to reliably apply the escaping rule — which it may not do when the content contains `---END---` in a code block or diff output. The per-generation token approach eliminates the collision opportunity entirely: the token is never in any existing document, so content cannot accidentally match it.

**Scope:** only the `_docs_update_engine` LLM-output parser and its prompt. The saved proposal files (written by the parser, read by `_docs_apply_approved`) use EOF as their implicit delimiter and are unaffected.

### Mid-Run Drift: Decide on Conflict, Not Distance (#433/#439 incident)

`mid-run-rebase.sh::check_and_rebase_against_main()` runs at the start of Phase 3 to catch the case where main moved during the run. The decision is driven by **whether the branch actually conflicts with main**, computed with `git merge-tree --write-tree` (a pure in-memory merge — no working tree, commit, force-push, or test-gate re-run):

- **No conflict** → do **nothing**. A behind-but-clean branch merges fine in Phase 4 (`merge-pr.sh` calls `gh pr merge`, and only updates the branch if GitHub itself reports it unmergeable). Rebasing it would only churn history and re-trigger the post-commit test gate for no benefit.
- **Conflict** → try Claude-assisted resolution; if unresolved, abort with a clear message **before** the review session, so no Claude review time is wasted on an unmergeable PR.
- **merge-tree error** (old git, unexpected) → fail open (skip), consistent with the fetch-failure path.

**Rejected approach — commit-distance threshold (`RITE_MID_RUN_REBASE_THRESHOLD`, default 5):** The original #290 design aborted when the branch was more than N commits behind, *without attempting a rebase*, on the assumption that far-behind ⇒ likely-to-conflict. Commit distance is a poor proxy: a branch 50 commits behind that touches isolated files merges instantly; a branch 2 commits behind editing the same lines conflicts hard. On 2026-06-09 this falsely aborted PRs #522 (issue #433, 12 behind) and #525 (issue #439, 11 behind) — both had **zero** conflicting files and would have merged clean — *after* each had already spent a full LLM review. The threshold guarded nothing expensive (a clean rebase is sub-second git regardless of N; only conflict resolution is costly, and that path is reached only on a real conflict). The env var was deleted: distance no longer determines anything. Real protection from #290 (surfacing genuine conflicts before review time) is preserved and *strengthened* — clean far-behind PRs now proceed instead of falsely aborting.

Tests: `tests/regression/mid-run-rebase.bats` (clean drift → no-op, including the 12-behind #433/#439 regression) and `mid-run-rebase-conflict.bats` (real conflict → resolve-or-abort; the resolver is stubbed to fail so the abort contract is deterministic rather than dependent on live Claude availability).

**Resume path — same ruling extended (#1137):** The original `check_stale_branch` (stale-branch.sh) used `RITE_STALE_BRANCH_THRESHOLD` (default: 10) to decide in auto mode whether to attempt a rebase or close-and-restart: branches at/above the threshold were closed immediately without a rebase attempt. Issue #1045 (2026-10-11, batch 135719 slot): a finished, cleanly-rebasable PR sat at exactly 10 commits behind after an evening of unrelated merges — auto-closed, and the entire feature was re-implemented from scratch (~19 min dev + full review cycle) — then that rerun died for separate reasons. The distance-as-proxy flaw is identical: a 10-behind clean branch rebases in sub-second git; a 2-behind conflicted branch is what actually needs the resolver. The ruling is extended: **auto mode always attempts rebase first, regardless of distance. Close-and-restart fires only when the rebase conflicts AND the resolver fails** (or post-rebase verification fails). `RITE_STALE_BRANCH_THRESHOLD` is retained for supervised mode's 5-option prompt threshold. An absurd-divergence guard (`RITE_STALE_BRANCH_HARD_RESTART_THRESHOLD`, default: 100) caps the rebase-first path for truly enormous histories that signal an abandoned branch rather than normal drift.

Tests: `tests/regression/stale-branch-rebase.bats` (clean branch at 2× threshold → rebased, no restart; conflict → resolver → fallback path preserved; hard-restart threshold → exit 11 without rebase attempt).

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

### The mkdir-then-deferred-pid Reclaim Race (issue #706)

All three locks share a second race, **distinct from the same-host assumption above**: acquisition is non-atomic. Each wins exclusion with `mkdir "$lock_dir"`, then writes its PID in a *separate, later* step. Between the mkdir and the PID write there is a window where the lock directory exists with **no `pid` file**. A concurrent acquirer whose "no-PID grace period" expires inside that window runs `rm -rf "$lock_dir"` to reclaim what looks like an abandoned lock — **deleting the live holder's freshly-acquired lock**. Both processes then run the critical section concurrently:

- **issue-lock.sh** — double-hold: two processes each believe they hold the lock (~6% of concurrent-reclaim trials, reproduced deterministically).
- **scratchpad-lock.sh** — data loss: the read-file → write-temp → mv critical section in `log_encountered_issue` drops an entry (~5/25 trials).
- **session-tracker.sh** — lost increments / JSON corruption in the session-completion counter under heavy concurrent load (~5/10 trials).

**Status:**
- `issue-lock.sh` **fixed inline** (commit `0deefb8`) via `_atomic_steal_stale_lock`: reclaim by renaming (`mv`) the stale dir to a unique per-process path before removing it — only one racer's `mv` succeeds, serialising the steal; the existing `mkdir` gate then admits exactly one acquirer. 0/200 overlaps post-fix.
- `scratchpad-lock.sh` and `session-tracker.sh` have the same class but are **deferred to #706** rather than accreting three different ad-hoc patches. Their two data-loss tests are concurrency (gate-excluded), so they don't block the gate.

**Do NOT "fix" the deferred two with another bespoke patch** — that's the trap #706 exists to avoid. The correct fix is to **unify all three locks onto one primitive** and migrate together.

**Resolution (#706): `lib/utils/lock.sh` — one atomic primitive.** A single shared lock replaces the bespoke implementations. It is an `ln(1)` hard-link lock whose file content is a unique `<pid>.<nonce>` token, written into a private temp file *before* the link — so the lock carries its identity atomically the instant it exists. There is **no create→PID-write window** (the root cause above). Each property below was pinned by a finding during bring-up:
- **`ln` gate** — `link(2)` is atomic and fails if the target exists; exactly one of N racers wins (verified: 1 winner of 50 concurrent linkers).
- **Token = pid + nonce** — the pid drives `kill -0` liveness; the nonce makes every acquisition unique so reclaim can't be fooled by **PID reuse** (a recycled pid re-acquiring gets a different token). Without the nonce, content-verify passed falsely and double-held.
- **Empty read ⇒ retry, never steal** — an empty `cat` means the file *vanished* (a holder released), not that it's stealable; stealing there raced the re-acquirer (the dominant double-hold in bring-up).
- **Content-verified, pre-checked steal** — reclaim re-reads the token immediately before the destructive `mv` and proceeds only if it still equals the observed dead token; after the move it re-verifies, restoring the lock untouched if a concurrent re-acquire slipped in. This keeps a **clean release→re-acquire** from being mistaken for a stale lock (the last residual overlap).

Validated: 50-process × 10-round distinct-PID stress → **0 lost / 0 overlaps**; SIGKILL'd holder → reclaimed every round. Tests: `tests/concurrency/lock-primitive.bats` (mutual exclusion + crash recovery) and `session-state-race.bats` (the acceptance — 6/6).

**Platform seam.** `lock.sh` is the single place the OS concurrency model lives (atomic create-exclusive, process liveness, atomic rename — all POSIX, uniform on macOS + Linux; macOS has no `flock(1)`, so the `ln` path carries correctness). A future **Windows** backend swaps exactly the three public functions (`lock_acquire`/`lock_release`/`lock_held_pid`) over `CreateFile CREATE_NEW` / `OpenProcess` / `MoveFileEx` — nothing outside `lock.sh` encodes the assumptions. See the file header for the contract.

**Adoption.** `session-tracker.sh` is migrated onto `lock.sh` (this fixes the named lost-increment bug; `session-state-race.bats` passes under load). `scratchpad-lock.sh` and `issue-lock.sh` are follow-up adopters: scratchpad is a clean swap pending its strategy-specific test updates; `issue-lock.sh` additionally stores `cwd`/`backfill` metadata **inside** its lock dir (read by `repo-status.sh` + `backfill_worktree_locks`), so it needs a metadata-layout migration and keeps its working `_atomic_steal_stale_lock` (#707) until then. Neither is buggy in normal single-host use.

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

### Per-Finding GitHub API Call Cap

**Problem:** The one-issue-per-finding loop in `assess-and-resolve.sh` runs full dedup machinery per finding — `gh issue list` (body-marker search) + `gh issue view` (marker verification) + `gh issue list` (title search) + `gh pr view` (PR comment check) + up to 3 retry iterations with backoff sleeps — plus `gh issue create` + `gh pr comment` per new creation. This scales **N×** with no upper bound. A review with 50 ACTIONABLE_NOW or ACTIONABLE_LATER findings produces 50 full dedup cycles — potentially hundreds of GitHub API calls — which can exhaust GitHub secondary rate limits and extend lock hold times well beyond the 60s waiter budget.

**Solution:** `RITE_MAX_FINDINGS_PER_RUN` (default: 20) caps the number of findings processed per assess run. When the cap is hit:

1. Remaining findings are skipped (via `continue` in the per-finding loop)
2. A `print_warning` is emitted to stderr with the processed/skipped/cap counts
3. A `[diag] FOLLOWUP_CAP_HIT` line is written to `RITE_LOG_FILE` for health-report aggregation

**Why skip (not abort):** Processing findings 1..N before hitting the cap is better than aborting the whole batch. Findings are iterated in document order (no severity sort is applied here); lower-priority items at the end of the review are more likely to hit the cap, but ordering is not enforced. Operators can re-run `rite N --assess-and-fix` with a higher cap to process the rest — the dedup machinery prevents duplicates.

**Disable the cap:** Set `RITE_MAX_FINDINGS_PER_RUN=0` in `.rite/config` to restore the original unbounded behavior. This is appropriate for one-off full-scan reviews where completeness matters more than API budget.

**Why 20 as the default:** Typical PRs produce 3-10 ACTIONABLE_NOW and ACTIONABLE_LATER items combined. 20 is generous enough not to surprise users in normal usage while bounding the worst case (scan-heavy PR with 100+ findings) to ~40-80 API calls for dedup + ~20 for creation — well within GitHub's rate limits.

**API cost model (for tuning):**
- Per finding (dedup only, best case — all cached): 1 API call
- Per finding (dedup, typical): 2-3 API calls (list + title search)
- Per finding (dedup, worst case — index lag + retries): up to 13 API calls (3 retries × 4 sources + 1 initial)
- Per finding (creation): 2 API calls (issue create + PR comment)
- **Total at cap=20, typical:** ~100 API calls per assess run

**Observability:** `[diag] FOLLOWUP_CAP_HIT issue=N pr=N processed=N skipped=N cap=N` in `RITE_LOG_FILE`. The health report surfaces any `FOLLOWUP_CAP_HIT` event as a WATCH item with the skip count.

**Implementation:** `lib/core/assess-and-resolve.sh` — LOW-severity findings are skipped before `_finding_index` is incremented and before the cap guard runs. `_finding_index` counts **all non-LOW findings including ACTIONABLE_NOW** (not ACTIONABLE_LATER only) — the loop iterates over `^### .* - ACTIONABLE_(NOW|LATER)` headers (line 2079), so ACTIONABLE_NOW findings consume cap budget on the same footing as ACTIONABLE_LATER. The increment fires at line 1733 (`_finding_index=$((_finding_index + 1))`); the cap check fires at line 1743 (`[ "$_finding_index" -gt "$_findings_cap_validated" ]`). This means the cap only fires against findings that would actually make GitHub API calls. The post-loop report shows processed vs. total API-eligible findings.

**Coverage:** `tests/regression/followup-finding-cap.bats`

---

### Lock Release Before exec (CRITICAL)

**Contract:** Any code path that calls `exec` to restart the script (replacing the process image) MUST release any lock acquired via `trap "release_issue_lock ..." EXIT` **before** the `exec` call.

**Why:** `exec` replaces the process image without running EXIT traps (bash documented behavior: "If the command is supplied, it replaces the shell. No new process is created."). The lock directory is left on disk with the current PID written to the `pid` file. The re-exec'd process is the **same PID** (`$$` is unchanged). When it attempts `acquire_issue_lock`, it finds the lock directory already exists, reads its own PID, runs `kill -0 $$` — which succeeds (the process is alive) — and concludes the lock is held by a live process. It prints the "already being processed" error, waits 30 seconds, and times out with exit 1.

**Live failure:** Issue #343, batch run `rite-338-340-343-345-20260606-092031.log:1012`. The empty-branch auto-recovery path exited and re-exec'd without releasing the lock:
```
✅ Empty branch cleanup complete — ready to restart fresh
Restarting workflow after empty branch cleanup...
🦈 Initializing Sharkrite workflow...
❌ Issue #343 is already being processed by PID 88811
   Refusing to start. Wait for it to finish, or run 'rite 343 --undo' if it crashed.
❌ Lock timeout after 30 seconds
❌ Development workflow failed
```

**Fix pattern (Option A — primary):** Release explicitly before each `exec`:
```bash
# Release lock before exec: exec replaces the process image without firing EXIT traps,
# so the trap "release_issue_lock" registered above would never run. Release explicitly.
release_issue_lock "$ISSUE_NUMBER"
exec "$SCRIPT_PATH" "$ISSUE_NUMBER" --auto
```

**Defense-in-depth (Option B):** `acquire_issue_lock` also detects `lock_pid == $$` and self-reclaims with a warning. This catches exec sites that forget Option A:
```
⚠️  Reclaiming self-held lock (post-exec restart) for issue #N
```

**Known exec sites in `claude-workflow.sh` (all fixed, all require Option A):**
- Stale-branch restart (auto mode and supervised) — lines after `_stale_exit -eq 11`
- Empty/divergent branch auto-recovery restart (auto mode) — after `preflight_auto_recover_empty`
- Supervised cleanup restart (option 1 in the prompt) — after `preflight_auto_recover_empty`

**Enforcement:** `tests/regression/claude-workflow-lock-survives-exec.bats` asserts that the release call precedes each exec and that the re-exec'd process acquires the lock without the "already being processed" error.

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

### gh_safe transient-retry regex: under-retry > over-retry (green-main cleanup)

The bare-code arm of the transient-retry regex in `gh-retry.sh` retries on a bare HTTP status code followed by a space (e.g. "503 Service Temporarily Unavailable", "curl: ... error: 503") — raw gh/curl output that frames codes without "HTTP" or parens. A green-main test (`gh-safe-adoption.bats` test 17) wanted it to NOT retry on a coincidental "Processed 500 records". These are structurally identical (code + space + word); a trailing-char/phrase anchor cannot distinguish them.

**Decision (kept the original regex; fixed the test):** under-retry is worse than over-retry — a missed transient turns into a spurious workflow failure, whereas a wasted retry on a coincidental number just burns a little budget and then surfaces the real error. Bare-code transient coverage is preserved; test 17 is a documented `skip` recording the accepted space-form false-positive. Re-enable if `gh-retry.sh` gains phrase-vs-word-count disambiguation. (An adversarial review confirmed the irreducibility; recorded here so it isn't re-litigated.)

**Transport-error arm (added #1188):** `gh_safe` now also retries transport-level failures — TCP/TLS errors and DNS failures — with the same backoff as 429/5xx. The same "under-retry > over-retry" ruling applies. The transport pattern strings are sourced from **gh's printed user-facing output**, not from Go internal error types (`net.DNSError`, etc.): DNS failures print `error connecting to <host>` and `check your internet connection`; TCP/TLS timeouts print `operation timed out`, `i/o timeout`, `connection reset by peer`, `TLS handshake timeout`, and transport-layer `dial tcp ...: <error>` forms; mid-response connection closes print `: EOF`; client-side timeouts print `context deadline exceeded`. Resolver-layer OS internals (`temporary failure in name resolution`, `dial tcp ... no such host`) are not printed verbatim by `gh` (which wraps them in its own message) and must not be added as their own regex arms; transport-layer forms where `dial tcp` is a prefix (`dial tcp ...: i/o timeout`, `dial tcp ...: connection reset by peer`, etc.) ARE printed verbatim by `gh` and appear in the pattern — the broad `dial tcp` token in the regex deliberately matches these transport forms and may also match resolver-shaped strings as an accepted under-retry > over-retry trade-off. The authoritative string source is always what `gh` actually prints to stderr — verify against the installed `gh` version when updating.

### Removed: Plan Directives System

Directives were persistent per-project rules injected into the plan prompt (e.g., "always use service layer"). Removed because the user preferred fixing sharkrite's generic behavior over per-project config. Replaced by: feedback persistence, service layer filesystem lint, and stronger prompt instructions.

### Rejected: ADR Modification for Deferrals

Considered appending deferrals to the source ADR on plan approval. Rejected because the deferrals log already serves this purpose and modifying ADRs adds noise to source-of-truth documents.

### Rejected: Keyword Matching for Deferral Detection

Tried extracting significant words from feature names and matching against the deferrals log in bash. Failed because natural language phrasing varies ("view" vs "endpoint" vs "query"). Replaced by passing deferrals to the phantom Claude call for semantic matching.

### Rule: No Keyword Matching for Detection — Anywhere in Sharkrite

Generalizes the deferral-detection lesson into a project-wide rule. **Sharkrite must never use keyword/substring matching to decide whether a piece of text qualifies for some downstream behavior.** This pattern has bitten us repeatedly:

- **Deferral detection** (above) — words vary, semantic match needed
- **ADR auto-creation** (`assess-documentation.sh`, retired 2026-10-21) — matched on `"decision\|tradeoff\|alternative"`. Captures issue bodies that mention these words conversationally and misses architectural decisions that don't use the vocabulary
- **Parent-PR marker detection** (`batch-process-issues.sh:327`, fixed in `206f2be`) — matched on `"sharkrite-parent-pr:"` without anchoring on digits. Issue #34's body documented the marker format as an example and tripped the guard, killing the batch silently
- **ADR backfill** (`bootstrap-docs.sh`, retired 2026-10-21) — matched commit messages on `"refactor\|feat\|breaking\|migrate\|switch\|drop"` to decide ADR-worthiness. Same class of false positives and false negatives (last live case: orrery's first batch turned "Rename the switch and tab" — a UI toggle — into an ADR)
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

- `docs/architecture/exit-codes.md` — auto-maintained from script comments

**Loading order at workflow start:** every Claude dev session loads in this order: `CLAUDE.md` → `behavioral-design.md` → `conventions.md` → `encountered-issues.md` → issue-specific context. The first three together constitute "what every Claude session must know about this codebase."

**Rationale:**

1. **Three docs, three triggers, zero ambiguity** about which one to update.
2. **No keyword matching** — markers and labels are content-addressable, deterministic.
3. **Append-only growth** for `conventions.md` keeps merge conflicts trivial; `behavioral-design.md` curated narrative resists drift.
4. **Future agents inherit lessons** — every Claude session loads the conventions catalog automatically. The "rediscover the same lesson every session" failure mode is prevented at the source.

### Conventions Catalog: Accumulate-in-Place Contract

Each convention title is **canonical** — there is exactly one entry per unique title in `conventions.md`. When multiple PRs surface or refine the same convention, their PR numbers accumulate in that single entry's `**References:**` line.

**Three cases handled by `update_conventions_from_marker()`:**

| Situation | Action |
|---|---|
| Title absent | Append a new rendered entry (rule, why, example, references) |
| Title present, PR# already in its References line | No-op (idempotent — already recorded) |
| Title present, PR# NOT yet in its References line | Accumulate in place: append `, #PR_NUMBER` to the existing entry's References line |

**Why accumulate in place rather than append duplicate headings:**

The catalog's prose contract describes it as "append-only" meaning entries are never deleted or overwritten — not that a new heading is blindly inserted for every PR that touches a convention. Having two `## no-keyword-matching` headings in the catalog is confusing; having one heading with `References: #34, #74, #90, #92` clearly shows the convention's provenance.

The existing seed entries (e.g., `**References:** 206f2be, #34, #74, #90, #92`) already express the intended semantics: one entry, multiple references. The accumulate-in-place behavior makes this consistent for PRs processed after the initial entry was added.

**Implementation:** `assess-documentation.sh::update_conventions_from_marker()` — the `_title_exists` gate (added in issue #320) routes to an awk rewrite that appends `, #PR_NUMBER` to the matching References line without touching any other content.

**Regression tests:** `tests/regression/conventions-marker-append.bats` — Tests 6 and 7 cover the accumulate-in-place path and its idempotency.

---

## macOS/BSD Portability Bug Class (CI Can't Catch)

CI runs on GNU/Linux; Sharkrite RUNS on the developer's macOS (BSD userland). A whole class of bugs passes CI but fails locally because BSD tools differ from GNU — and **CI structurally cannot catch them.** The green-main sweep found 9 such bugs; the durable defense is deterministic lint rules (the local `make check` gate sees them) plus conventions-catalog entries for patterns too context-dependent to lint without false positives.

**Shipped as lint rules (zero false positives validated against the whole tree):**
- **Rule 26 SLEEP_INFINITY_NOT_PORTABLE** — `sleep infinity`/`sleep inf`; BSD /bin/sleep rejects non-numeric durations and exits immediately (never sleeps).
- **Rule 27 TR_MULTIBYTE_REPLACEMENT** — `tr` maps bytes, not UTF-8 chars; a multibyte replacement emits only its first byte (garbage). Quote/heredoc/pipeline-aware awk to stay FP-free.
- **Rule 28 BSD_DATE_PARSE_Z_WITHOUT_U** — BSD `date -jf "...Z" +%s` without `-u` parses local time, skewing the epoch by the local UTC offset.

**Routed to conventions-only (FP-prone — NOT shipped as rules):**
- Unescaped `/` in an awk regex character class (`[^/]`) — needs awk-literal context a line-grep can't establish (3 FPs on the tree).
- Bare `$RITE_INSTALL_DIR` and similar unguarded core RITE_* path vars under `set -u` — too broad to enforce cleanly (17 FPs).

**Principle:** validate behavior in the environment the gate actually runs in (macOS/BSD), not just CI. A green CI is necessary but not sufficient. These rules are "Deterministic over Model-Policing-Model" in action — checkable invariants pushed into the linter, not advisory docs.

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

## Deterministic over Model-Policing-Model

**Principle:** When a workflow step is a deterministic check expressible as a comparison or lookup, implement it deterministically. Do not use an LLM to "police" another LLM's output.

**Why:** LLMs policing LLMs introduce non-determinism where none is needed:
- The policing model can regenerate what the original model already produced (phantom-dupe scenario)
- Non-determinism makes reconciliation results unpredictable across runs
- Failures are silent or ambiguous — a network timeout silently skips the step
- Token cost and latency for a pass that a simple string comparison handles equally well

**First application — coverage reconciliation (issue #348, 2026-06-04):**

`_validate_coverage` in `lib/core/plan-issues.sh` originally called the provider to resolve "phantom" checklist entries (✅ lines referencing titles not present in any emitted `---ISSUE---` block). The LLM was asked to GENERATE or SKIP each phantom.

In two finance-glance planning runs, the phantom resolver regenerated issues already emitted under slightly different titles (e.g., `"implement budget tracking"` in the checklist vs `"Implement Budget Tracking"` in the block). `_dedup_issues` caught the case-folded duplicate, but only after an unnecessary round-trip and occasionally after the duplicate was counted in a user-visible "Added N issues" message that later corrected to N-1.

**The fix:** `_validate_coverage` now builds a canonical-title index from emitted issues (lowercase + whitespace-trimmed, matching `_dedup_issues` normalization) and does a deterministic lookup. Matched titles pass through unchanged. Unmatched titles emit a `WARNING:` line to stderr and the orphaned checklist entry is stripped. No LLM call. `_dedup_issues` remains the single source of truth for deduplication after reconciliation.

**Rule of thumb:** If the question is "does X appear in set Y?" — use a set lookup. Only reach for a model when the question genuinely requires language understanding (e.g., "does this PR description accurately reflect the diff?").

**Second application — deterministic integration check (issue #351, 2026-06-05):**

`_detect_unverified_integrations` in `lib/core/plan-issues.sh` checks whether external hostnames and package/SDK names referenced in issue bodies are grounded in the project's fixture directories or dependency manifests. Issues that reference un-grounded dependencies get a spike-issue prerequisite prepended (no LLM call). This is a deterministic lookup: "is this hostname/package in the project's known-good set?" is a set membership test, not a language-understanding question.

**Never-external host exclusion (issue #1370, 2026-10-20):** Before reaching the fixture/SDK grounded-set check, each extracted host candidate is filtered against a categorical never-external set. Hosts in this set cannot be real external integrations regardless of what the issue body says, so they are silently skipped — no spike, no warning. The never-external set covers: loopback names (`localhost`, `127.0.0.1`, `0.0.0.0`), `.local` and `.localhost` suffixes (mDNS/link-local), and RFC 2606 documentation names (`example.com`, `example.net`, `example.org`, and any subdomain thereof, plus `*.test`, `*.example`, `*.invalid`). IPv6 loopback (`[::1]`) cannot reach this check — the host-char class `[a-zA-Z0-9.-]` excludes `[` and `:` — so it is inert by construction. Private IP ranges (10.x, 192.168.x) are not excluded here; no IP parsing is performed beyond the IPv4 loopback literal. Live failure that motivated this fix: orrery 2026-10-20 — `http://localhost:54324` (Inbucket) in a verification command produced a "Capture localhost sample - fixtures" spike and put `Blocked by: #SPIKE-localhost` on the magic-link issue.
**Verify:** `grep -n 'never-external\|loopback' docs/architecture/behavioral-design.md`

**SDK-grounded host suppression (issue #1155, 2026-10-14):** A host candidate that passes the fixture check is additionally checked against the manifest's grounded packages before being spiked. The vendor token — the first label of the registrable domain (e.g. `supabase` from `supabase.co`) — is matched at word boundaries (`[@/-]` separators) against each grounded package name (e.g. `@supabase/supabase-js`). When matched, the session contract comes from a typed SDK already in the manifest; the host is not an unverified external feed, so no spike is emitted. An INFO line names the grounding package. The suppression check requires the package to be grounded (present in the manifest), not merely mentioned in issue bodies.

**Why `.` is excluded from the separator class:** Fixture AD exercises a `go.mod` containing `github.com/stretchr/testify`. The vendor token extracted from the `github.com` host is `github` (first label of the registrable domain). If `.` were included in the separator class alongside `@`, `/`, and `-`, the boundary regex `(^|[@/.-])github([@/.-]|$)` would match `github.com/stretchr/testify` — `github` sits at the start of the string, bounded on the right by `.` — causing the `github.com` host to be wrongly suppressed. The grounding mechanism is host-prefix self-grounding: the vendor token must match a package that is an SDK for that host (e.g., `@supabase/supabase-js` grounds `supabase.co`). A Go module path whose first domain label happens to equal the vendor token is not such an SDK. Excluding `.` confines the suppression to genuine SDK packages while rejecting coincidental Go module path matches. The accepted trade-off: a package name that uses `.` as a word-boundary separator (present in Go module paths by construction) would not ground a host even if it were the intended SDK. The `-` separator is retained because real SDK packages use it as a token boundary: `google-auth` grounds `*.google.com`, `stripe-python` grounds `*.stripe.com`.

**Host-normalization contract — `_normalize_host_to_registrable_domain` (issue #1293, 2026-10-19):**

`_normalize_host_to_registrable_domain` maps an extracted hostname to its registrable domain so that subdomain variants (`api.foo.co`, `auth.foo.co`) collapse to one key (`foo.co`) for fixture-grounding and spike-dedup purposes.  The function is **fail-closed**: when the suffix structure is unknown, it returns the host unchanged rather than producing a bare public suffix.  This guard substantially reduces the risk of a missing list entry silently collapsing a distinct service onto a public-suffix key, though it covers only the SLD keywords explicitly listed in the guard regex — suffixes outside that set still fall through to the two-label rule.

Four specific behaviors are guaranteed:

1. **Trailing dot stripped before any other processing.** FQDN form `api.authsvc.io.` normalizes identically to `api.authsvc.io`.  Without this, a sentence-final URL yields two spike keys for one service.
2. **IP literals returned unchanged.** A host whose dot-separated labels are all numeric (e.g. `10.0.0.5`) is returned as-is — no registrable-domain concept applies to an IP.
3. **Known multi-part suffixes handled explicitly.** A hardcoded list covers ccSLD patterns (`co.uk`, `co.in`, …) and common hosting suffixes (`vercel.app`, `herokuapp.com`, …).  For a host ending in one of these suffixes the registrable domain is `<registrar-label>.<suffix>`.
4. **Unknown ccSLD-like patterns return the host unchanged.** After the multi-part list, the last-two-labels rule is applied.  If the result matches `^(co|com|net|org|gov|edu|ac|sch|go|or|ne|gob|mil|govt)\.[a-z]{2}$` — a known SLD keyword followed by a 2-letter ccTLD that is not in the hardcoded list — the function returns the original host rather than emitting a bare public suffix.  This is the fail-closed guard for patterns the list does not yet cover; SLD keywords outside this alternation still fall through to the two-label rule.

The unverified-integration warning names **both** the normalized domain and the originating hostname (e.g. `unverified external integration: payments.io (from: api.payments.io)`), so an operator can locate the reference in the planning doc without cross-referencing subdomains.

**Verify:** `grep -n 'registrable domain' docs/architecture/behavioral-design.md`

**Lint and creation share non-spike ordinal space (issue #1150, 2026-10-13):**

When `_detect_unverified_integrations` prepends spike issues, all subsequent `#N` dependency references inside a plan file operate in **non-spike ordinal space**: `#1` means the first non-spike issue, not the first raw issue in the file. Both the strict linter (`_lint_issues_strict`) and the creation-side issue loop (in `create_issues`) must interpret `#N` the same way; a mismatch causes the linter to approve ordinals the creation side rejects (or vice versa).

**Contract:** `_lint_issues_strict` builds `_nonspike_to_arr` (non-spike ordinal → raw array index) and `_arr_to_nonspike` (raw array index → non-spike ordinal) at parse time. Dangling-ref Check 3 range-checks each `#N` against `[1.._nonspike_count]` without indexing the maps. Cycle-detection and parallel-file-overlap Check 7 resolve `#N` through `_nonspike_to_arr[N-1]` to obtain the raw index, then use `_arr_to_nonspike` to translate back for user-visible messages. The creation side independently builds an `ordinal_map_file` that maps non-spike ordinals to real GitHub issue numbers — same convention. Both sides classify a spike via the shared `_title_is_spike` predicate (`^Capture .+ sample - fixtures$`; the legacy form `^spike: capture .+ sample for grounding$` is also accepted for backward compatibility with pre-#1151 issues).

**SPIKE_KEY carrier (issue #1152, 2026-10-14):** The spike title is truncated to keep it within the ≤50-char runbook limit when the candidate name is longer than 24 characters. A truncated title cannot be round-tripped back to the full canonical key, breaking the `#SPIKE-<key>` placeholder resolution and the `Blocked by:` dependency injection for long package names like `@opentelemetry/instrumentation-http`. To decouple key identity from the display title, `_detect_unverified_integrations` writes a `SPIKE_KEY: <full-sanitized-key>` block-header field (between `TIME:` and `BODY:`). The creation side reads `SPIKE_KEY:` preferentially; when the field is absent (pre-#1152 spike blocks or manually authored spikes), it falls back to deriving the key from the title via `_sanitize_spike_key`. The section-completeness linter (`_lint_issues_sections`) re-injects `SPIKE_KEY:` after TITLE if a regen pass drops it, since LLMs are unaware of this sharkrite-specific header field.

**Verification:** `grep -n '_title_is_spike\|_nonspike_to_arr\|_nonspike_count' lib/core/plan-issues.sh`

**Third application — flag-first provenance + deterministic low-signal gate (issue #367, 2026-06-06):**

`_lint_provenance_flags` in `lib/core/plan-issues.sh` checks whether a `**Field provenance:**` section documents fields whose source is already listed in "Files to Read" (obvious-source, low-signal). The check is: "does any filename from Files to Read appear in the source segment of each provenance entry?" — a string-containment check. If the count of obvious-source entries exceeds the threshold, the run is rejected. This dissolved the cargo-cult "every data issue must have a provenance table" pattern into "model flags non-obvious fields; deterministic linter rejects obvious-source entries as low-signal."

**Fourth application — dissolution of the H5 LLM critique pass (issue #353, 2026-06-07):**

The original H5 planning proposal called for a self-critique LLM pass after issue generation: the model would validate its own draft against a five-point checklist (coverage 1:1, acyclic DAG, no dangling deps, verification commands reference real files, deferral reasoning consistent with docs) and revise. Same-model self-critique is famously weak at catching same-model errors. Every item on that checklist is a deterministic check expressed in natural language.

`_lint_issues_strict` in `lib/core/plan-issues.sh` implements the remaining three checks that #348/#351/#367 hadn't yet covered:

| Check | What it tests | Severity |
|---|---|---|
| Acyclic dependency graph | DFS cycle detection on `Dependencies:` lines | ERROR (exit 1) |
| No dangling `#N` refs | Every dep ref resolves to a batch issue or existing open issue | ERROR (exit 1) |
| Verification path sanity | Verification commands reference paths in Files to Modify or the repo | WARNING (exit 0) |
| Deferral citation | Each `⏭️` deferral entry cites evidence (`> text`, `file:line`, or quoted phrase) | WARNING (exit 0) |
| Concurrent file overlap (Check 7) | Derived-concurrent pairs sharing Files to Modify are auto-chained or warned | WARNING (exit 0) + auto-rewrite |

**Check 7 Auto-Chain Contract (issue #1388, 2026-10-21):** Two issues are *derived-concurrent* when neither is reachable from the other via the `_rev_adj` adjacency already built by Check 2's Kahn pass — no parallel annotation is required for detection. For each derived-concurrent pair sharing a file in `Files to Modify`, Check 7 either auto-chains the later issue (lower non-spike ordinal → `After #N` added to the later issue's `Dependencies` line, both-way parallel annotations stripped) or warns when either side carries a `parallel-file-overlap` suppression marker (disjoint-functions escape hatch). The loop runs to fixpoint: after each auto-chain, `_rev_adj` is updated in memory and reachability is recomputed — this avoids re-chaining pairs already covered by earlier rewrites (e.g. once A→B and B→C are both in `_rev_adj`, A→C is transitively covered, so a direct A→C edge is not added if the pair is seen as sequential before it fires). Annotations in `_parallel_with` are consumed only for annotation-stripping, never for detection.

The complete linter chain (in call order within `generate_issues`):
1. `_detect_unverified_integrations` — external dependency grounding (#351)
2. `_dedup_issues` — title deduplication
3. `_validate_coverage` — coverage checklist 1:1 invariant (#348)
4. `_lint_issues` — service-layer anti-patterns
5. `_lint_provenance_flags` — provenance table signal quality (#367)
6. `_lint_issues_strict` — graph checks, dangling refs, verification paths, deferral citations (#353); **zero-LLM contract**
7. `_lint_negative_existence_claims` — two-stage negative-existence check (#1390); see below

**Fifth application — two-stage negative-existence claim lint (#1390, 2026-10):**

Two orrery planning rounds were blocked by the planner asserting repo-state negatives that were false: round 3 ("no `adult_confirmed_at` migration" while the column existed at `init.sql:17`) and round 6 ("there is no `find_profile_by_username` function yet" while the function was defined at `init.sql:363`). Both were caught only by human review.

`_lint_negative_existence_claims` in `lib/core/plan-issues.sh` addresses this with a two-stage design:

**Stage 1 — deterministic gate (zero LLM):** for each body line matching a negative-existence phrase (`no <X> yet`, `does not exist` / `doesn't exist`, `no migration`, `no schema change`, `not in the schema`, `missing`), extract identifier-shaped tokens (backtick-quoted, snake_case, camelCase) and run `git grep -nw <ident> -- ':!*.md'` from `RITE_PROJECT_ROOT`. No hit → silent pass, no LLM call. This gate ensures the LLM is only invoked for raw hits — cost is zero on the common clean-plan path.

**Stage 2 — triage validation (haiku, narrow binary):** each Stage 1 hit is classified by `provider_resolve_model triage` (the haiku role — narrow binary classification, not deep reasoning). The prompt gives the claim line, identifier, and the first hit's `file:line` context, and asks: `CONTRADICTED` or `CONSISTENT`?

| Stage 2 verdict | Action |
|---|---|
| `CONTRADICTED` | `negex-lint: WARNING: negative-existence: '<ident>' claimed absent in '<title>' but defined at <file:line>` |
| `CONSISTENT` | Drop silently (claim is scoped to a different layer/component) |
| Provider unavailable / no parseable verdict | `negex-lint: WARNING: … (unvalidated)` — findings degrade, never disappear |

The function is **separate from `_lint_issues_strict`** so its triage model call does not violate that function's zero-LLM contract. It is also **non-fatal** (always exits 0, warn-only) — the preview feedback loop owns the fix.

**Suppression (per issue):**
```
<!-- sharkrite-plan-lint disable negative-existence - Reason: ... -->
```
`Reason:` field is required; a marker without `Reason:` is rejected and the check runs anyway.

**If you find yourself wanting to add an LLM critique pass to the planning pipeline:** list the items on the checklist, then pull each into code first. The pattern is: parse the relevant section from the issue block, run a deterministic comparison or lookup, emit `WARNING:` or `ERROR:` to stderr. No model call required. The only time a model is justified is when the question genuinely requires language understanding that cannot be reduced to a membership test or structural match. The two-stage design above (`_lint_negative_existence_claims`) is the canonical example: Stage 1 is fully deterministic and gates LLM cost to the non-common case; Stage 2 uses only the triage role (haiku) for a narrow binary classification.

**Suppression markers (inline per item, not env-var flags):**

Per-item overrides use HTML comment markers. Scope depends on the check:

- `cycle-check`, `dangling-ref`, `verification-path` — marker embedded in the **issue body** (suppresses the check for that issue only):
  ```
  <!-- sharkrite-plan-lint disable cycle-check - Reason: ... -->
  <!-- sharkrite-plan-lint disable dangling-ref - Reason: ... -->
  <!-- sharkrite-plan-lint disable verification-path - Reason: ... -->
  ```

- `deferral-citation` — marker appended to the **deferral line itself** in the coverage checklist (suppresses the citation check for that line only). A stray marker in an issue body does NOT suppress deferral-citation checks for any line:
  ```
  - ⏭️ Feature Beta deferred to Phase 2 <!-- sharkrite-plan-lint disable deferral-citation - Reason: internal decision, no public doc yet -->
  ```

The `Reason:` field is required. A marker without `Reason:` is rejected with a WARNING and the check runs anyway — this prevents silent permanent suppressions that decay into ignored noise. All active suppressions are logged visibly to stderr: `[suppressed] <rule>: <reason>`.

**Important:** Suppression is strictly per-item. A single marker on one issue or deferral line does NOT silence the same check for any other item in the batch.

This mirrors the `# sharkrite-lint disable RULE - Reason: ...` pattern in `tools/sharkrite-lint.sh` and the design principle in `memory/feedback_no_env_var_escape_hatches.md`: env vars are for global operator config (model selection, timeouts, paths), not per-issue dynamic overrides.

---

## Temp File Conventions

### Per-Invocation Isolation (PID Scoping)

Temp files that are written by one code path and read by another within the same script must be **per-invocation unique**. The pattern:

```bash
REVIEW_FILE="/tmp/pr_review_${PR_NUMBER}.txt"   # BAD: shared across concurrent runs
REVIEW_FILE="/tmp/pr_review_${PR_NUMBER}_$$.txt" # GOOD: PID-scoped, per-invocation unique
```

`$$` is bash's current PID. It is stable within a script and inherited by child processes (subshells, `$()`, sourced files), so a file written by the parent and read by a subprocess using `$REVIEW_FILE` sees the same path. Concurrent sibling invocations have different PIDs, so their files are isolated.

### Trap Handlers Must Not Use Globs

A cleanup trap (`trap cleanup EXIT INT TERM`) fires from every exit path — including those in subshells created by process substitution (`2> >(tee ...)`) if they are explicitly set or the file is sourced in tests. **Never use a glob in a cleanup trap:**

```bash
# BAD: wipes every peer invocation's file in /tmp
rm -f /tmp/pr_review_*.txt 2>/dev/null || true

# GOOD: wipes only the file this invocation owns
rm -f "${REVIEW_FILE:-}" 2>/dev/null || true
```

The `${REVIEW_FILE:-}` expansion is required (not `$REVIEW_FILE`) because `REVIEW_FILE` may be unset if EXIT fires before the assignment line is reached (e.g., early `exit 1` due to argument validation). Under `set -u`, referencing an unset variable crashes the script; the `:-` guard evaluates to empty string, making `rm -f ""` a no-op.

### Live Failures

| Date | File | Root cause | Issue |
|---|---|---|---|
| 2026-06-06 | `assess-and-resolve.sh` | Glob in cleanup trap wiped peer PR's `/tmp/pr_review_N.txt` between write and read; `format-review.sh` reported "Review file not found". Concurrent context: batch run with 4 issues | #345 / fixed in #422 |

### Regression Test

`tests/regression/assess-and-resolve-temp-file-isolation.bats` — asserts glob is absent, PID suffix is present, and cleanup does not remove peer files.

---

## Fixes That Don't Fully Fix (Anti-Pattern)

### The Pattern

A bug fix is correct and narrow — it addresses the observed failure mode precisely. An adjacent failure mode exists that shares the same root cause. The fix never considers it. The sibling surfaces as a new bug within hours or days, requiring its own fix cycle.

This is a **development-process failure**, not a detection failure. Sharkrite's review loop caught every one of the regressions below within hours of landing. The regressions kept arising because the fix cycle started with the observed symptom and ended when that symptom was gone, without asking "what is the BUG CLASS this symptom is an instance of?"

### Live Evidence (2026-06-06 through 2026-06-08)

| Bug | Fix PR | Subsequent regression | Why the fix missed |
|-----|--------|-----------------------|--------------------|
| #16 (dedup race) | #127 (per-PR lock + retry) | #478 (source-marker variant uncovered) | Retry condition required "recent comment exists" signal that doesn't fire on follow-up-issue creation |
| #432 (resolver wired but unshipped) | PR #435 (ship + commit-after-resolve) | #457 (unconditional commit fails when tree is clean) | Fix assumed dirty tree post-resolution; missed the noop case |
| #457 (skip-when-clean) | PR #458 (guarded commit) | Live obs 2026-06-08: CONFLICT_RESOLVER fires 8 times in 8 seconds | Guard prevented one failure; orchestration loop never investigated for sibling races |
| #448 (move verification out of fix session) | PR #451 | #469 (multi-dev-session leak) + #471 (silent exit between phases) | Parallel orchestration introduced subshell hazards; tests covered happy path, not orchestration boundaries |
| #462 (targeted test selection) | PR #475 | PR #480 (backfill required) + PR #481 (default-flip required) | "Conservative-default" choice silently defeated the optimization; regression test asserted infrastructure, not outcome |

### Root Causes

**1. Issue scope is too narrow.** Most bug-fix issues read: "Fix the specific failure mode observed in `<log>`." Nobody asks: "What's the bug class this is an instance of? What sibling instances exist?" The narrowness is in the issue, which then produces a narrow fix, which then produces a narrow test.

**2. Regression tests assert the fix, not the absence of the class.** PR #127's test stubbed `gh issue create` to return success and asserted one create. It did not stub `gh issue list` to return stale data (the actual GitHub API lag mode) and assert dedup STILL works. So real GitHub did exactly that — the test passed, production failed.

**3. Review prompt didn't ask "what could this miss?"** The review asked "what's wrong here?" It did not ask "what sibling cases exist that this diff doesn't touch?" or "what assumptions does this fix make about callers?" This was fixed in the review template update that landed with this PR (see `templates/github/claude-code/pr-review-instructions.md` § "Sibling-Failure-Mode Check").

### How This Was Fixed (Process Layers)

**Layer 1 — Issue template requires bug-class enumeration** (`docs/issue-runbook.md` § "Bug Class Analysis"):

Before writing the fix, the issue author must list: the specific failure mode, the general bug class, 2-3 sibling instances, and a scope decision for each sibling (in-scope or explicit out-of-scope with reason). This runs at issue-creation time, before any code is written — the cheapest possible point to catch sibling scope.

**Layer 2 — Review prompt requires sibling-failure-mode check** (`templates/github/claude-code/pr-review-instructions.md` § "Sibling-Failure-Mode Check"):

For every fix in a bug-fix PR diff, the reviewer must answer: What assumptions does this fix make? What failure classes share the root cause? What edge cases are uncovered? If a sibling is found: flag ACTIONABLE_NOW at the parent bug's severity. If no sibling: state explicitly "no siblings found — [reason]."

This is a catch layer for when Layer 1 was skipped (issue filed without Bug Class Analysis) or when the fix session surfaced new information about siblings that wasn't visible at issue-creation time.

**Layer 3 — Test template (deferred):** Standardized test scaffolding that explicitly requires: (1) assert specific bug doesn't happen, (2) assert sibling variant also doesn't happen, (3) assert hostile-environment conditions produce the right outcome. Not implemented in this PR — deferred until Layers 1+2 prove value.

### What "Done" Looks Like for Bug-Fix Issues

A bug-fix issue is complete when:
1. The specific failure mode is fixed (always done)
2. The Bug Class Analysis section is filled in (new requirement)
3. At least one sibling instance was considered, and either fixed or explicitly deferred with a follow-up issue number
4. The review's sibling-failure-mode check section has an entry — even "no siblings found, here's why" counts

The goal is not to always widen scope. It is to always make the decision consciously.

### Anti-patterns This Replaces

**"The fix is correct" as the only merge criterion.** A fix can be locally correct while leaving the codebase in a class-of-bugs-still-present state. Correctness of the specific fix is necessary but not sufficient.

**Omitting the bug class from the issue title.** "Fix issue in batch cleanup" tells nobody what class the bug is. "Fix unconditional network call in handle_closed_issue (lazy-network-state class)" is searchable, grep-able, and makes future authors aware that the lazy-network-state contract exists.

**Regression tests that only confirm the symptom is gone.** PR #127's test is passing. Issue #478 exists. Both are true simultaneously because the test only confirmed one trigger of the race, not the class.

### Cross-Reference

- Issue template runbook: `docs/issue-runbook.md` § "Bug Class Analysis"
- Review prompt: `templates/github/claude-code/pr-review-instructions.md` § "Sibling-Failure-Mode Check"
- Conventions catalog: `docs/architecture/conventions.md` (when populated) will accumulate per-PR convention entries from PRs that exhibit this pattern

## Trivial-Fix Fast-Path + Initial Phase 2/3 Parallelism (issue #531)

Two complementary changes to cut the per-issue runtime floor (~7–8 min, ~95% of
it orchestration overhead for surgical fixes).

### Change 1 — Initial Phase 2/3 parallelism (`workflow-runner.sh`)

The fix loop already overlaps the post-commit gate with review generation. The
**initial** Phase 2→3 transition did not: `phase_create_pr` (foreground LLM
review) ran, *then* `phase_assess_and_resolve` ran — and the gate fired only
*inside* the fix loop, so the first assessment never saw `[GATE]` findings at
all (a latent gap).

`run_workflow`'s Phase 2 block now fires `run_test_gate` in the background
concurrent with the initial `phase_create_pr`, then does a **bounded** wait
(`wait_pid_with_timeout` + `kill_process_tree` on timeout — the #654 backstop,
verbatim), persists findings to `gate-findings-<PR>.json`, and exports
`RITE_GATE_FINDINGS`. `phase_assess_and_resolve` consumes + deletes that file as
it already does, so there is **no double-fire**: the initial gate runs once in
`run_workflow`; the in-fix-loop gate runs once per retry. Wall-clock for a
no-fix-loop run drops by `min(gate_duration, review_duration)`. On a resume
(`skip_to_phase` set), Phase 2 is skipped and so is the parallel gate — same as
before. Pinned by `tests/regression/test-gate-parallel.bats` (`#531:` tests).

### Change 2 — Trivial-fix fast-path (`lib/utils/trivial-fix-fastpath.sh`)

For issues that carry a **concrete, deterministic patch**, skip the Phase-1
Claude dev session AND the full opus review entirely.

**Why a deterministic applier (not an LLM):** a natural-language fix ("add a
`${VAR:-}` guard") can't be applied without an LLM — the very cost the fast-path
exists to avoid. So eligibility requires the issue body to carry a fenced
` ```diff ` block under a `<!-- sharkrite-fastpath -->` marker (`RITE_MARKER_FASTPATH`).
`git apply --check` is the applier: it handles multi-line edits, verifies the
patch applies exactly once, and **fails safely** (→ fall back) if the file has
drifted. Issues without the marker/patch are ineligible and fall through with
zero side effects — so the fast-path is **inert until issues adopt the format**.

**Safety model (chosen: "gate + cheap triage review"):** four checks, ALL run on
the worktree **before any commit/push/PR**, so any failure is a side-effect-free
fall-back to the normal Phase 1→4 flow:
1. `git apply --check` + apply — patch must apply cleanly.
2. `bash -n` — touched shell files must parse.
3. `triage_classify_diff` — Layer-1 deterministic guards + cheap haiku
   classifier; must return `trivial` (Layer 1 forces `substantive` on any
   dangerous category, so a wrong classifier can only false-escalate, never
   false-skip).
4. `run_test_gate` — `make check` + `bats -r tests/` must pass.

Only when all four pass does the fast-path commit, push, open a PR, and signal
the caller (via `try_trivial_fix_fastpath` returning 0 + setting `PR_NUMBER`/
`WORKTREE_PATH`). The dispatcher in `run_workflow` then sets `skip_to_phase=merge`,
reusing the normal Phase 4 (merge) + Phase 5 (completion) path — no duplicated
merge/cleanup orchestration. `merge-pr.sh` treats the Sharkrite review as "not
required", so a fast-path PR with no review merges cleanly.

**Triage factored into `lib/utils/triage-classify.sh`:** the classifier
(`triage_classify_diff`) is now shared by `_triage_emit_shadow` (the #651
calibration logging) and the fast-path gate. `local-review.sh` sources it via a
`BASH_SOURCE`-derived path (defined before the `FUNCTIONS_ONLY` guard so the
shadow test loads it). The fast-path module sources same-checkout siblings via a
`BASH_SOURCE`-derived path too — `config.sh` sets `RITE_LIB_DIR` to the
*installed* tree, which can lag a worktree, so a brand-new sibling would not be
found there.

**No env-var gate:** per the issue, eligible issues always take the fast-path
and ineligible ones always fall through — there is no on/off flag. The eligibility
marker is the opt-in. `workflow-runner.sh`'s source of the new module is guarded
with `[ -f ]` (live-lib-lag): if absent, the dispatch's `declare -f` guard simply
disables the fast-path rather than crashing the orchestrator.

Pinned by `tests/regression/trivial-fix-fastpath.bats` — the acceptance contract
is "an eligible issue runs ZERO dev sessions and exactly ONE gate", plus
side-effect-free fall-back on every failure mode.

**Validation note:** the live end-to-end path (worktree → apply → push → PR →
merge) was validated by unit tests with stubbed git/gh/gate/triage; a supervised
`rite <N>` run against a crafted fast-path-eligible issue should confirm the real
path before relying on it in unsupervised batches.

## Post-Rebase Verification Scope (#854)

Rebase-path `verify_post_merge` call sites (stale-branch trivial/standard rebase,
divergence-handler) pass `origin/main` as the diff base, NOT the pre-rebase HEAD.
Three-dot selection then covers branch-only files. Rationale: the rebased-in main
delta was already gated per-merge (green-main invariant), so re-verifying its full
coverage union (observed: 181/229 bats files for a 2-commit branch, two consecutive
days, .rite/logs/rite-821-*-20260703-051808.log) is redundant — a rebase-introduced
semantic conflict manifests in tests covering the BRANCH's files, which now run
against the post-rebase tree. Merge-commit call sites keep `HEAD~1` (cheap, correct),
and the no-diff full-suite fallback exploited by the main-broken check is untouched.
Rejected: keeping the union behind an opt-in (no known consumer; revisit if a
main-side interaction ever escapes branch coverage).

## Undo Never Closes the Issue Being Undone (#887)

**2026-07-04.** `rite --undo N` exists to put issue N back in a
runnable-from-scratch state. The follow-up-cleanup loop closes every issue in
`FOLLOWUP_ISSUES`; a self-referential marker (or over-broad marker search) can
sweep the main issue into that set, and the section-3.8 reopen only fires when
the issue was already closed at undo-start — so an open issue the loop closed
stayed closed. Live incident: `rite --undo 821` closed #821; the next batch
skipped it as already-done. Contract: `ISSUE_NUMBER` is filtered out of
`FOLLOWUP_ISSUES` after population (bash-3.2-safe), unconditionally. Any future
follow-up discovery method must preserve this self-exclusion. Test:
`tests/regression/undo-lock-and-branch-cleanup.bats`.

## Worktree Cleanup Skips Detached HEAD (#889)

**2026-07-04.** `git branch --show-current` returns an EMPTY string on detached
HEAD — the normal state mid-rebase/mid-bisect. The deep-clean (merge-pr.sh) and
cleanup-worktrees.sh stale-decision coerced empty to "unknown" → "branch
deleted/merged" → `git worktree remove --force`, destroying in-progress rebase
state; the batch-sibling protection keys on the branch name, so an empty name
bypassed it too. Contract: an empty `WT_BRANCH` means detached HEAD — skip the
worktree entirely, never judge it stale. Applies to BOTH cleanup sites; any new
worktree sweep must carry the same guard. Test:
`tests/regression/worktree-detached-head-not-stale.bats`.

## Divergence "Reviewed" Verdict Compares Epochs (#896)

**2026-07-04.** The RELATED-divergence auto-rebase decision compared the
assessment comment's `createdAt` (API, always `Z`-UTC) against `git log
--format=%aI` (numeric-offset local time) with a lexicographic `[[ > ]]` — a
meaningless verdict across renderings; a false "reviewed" auto-rebased
UNREVIEWED foreign commits past the auto-mode block. Contract (repo-wide, this
was the one missed site): timestamps are compared as EPOCH SECONDS only. Git
times are taken natively via `%at` (no parsing); API times go through
`iso_to_epoch` (Z-UTC is its contract); parse failure (0) falls through to the
safe UNREVIEWED path. Test: `tests/regression/orchestrator-integrity-fixes.bats`.

## Force Push Is Lease-Only — No Blind Fallback (#896)

**2026-07-04.** The diverged-branch initial push escalated any
`--force-with-lease` refusal to an unconditional `--force`, which can overwrite
real foreign commits on a name-collision branch (and the pre-push fetch had
already weakened the lease to "whatever was there a moment ago"). Contract:
sharkrite never runs a bare `git push --force`. The diverged-branch path
prints the remote tip it is about to replace, pushes with `--force-with-lease`
only, and FAILS LOUD if the lease refuses (remote moved in the fetch→push
window) — surfacing to the operator instead of escalating. Test pin in
`tests/regression/orchestrator-integrity-fixes.bats`.

## validate-setup.sh Is Functions-Only Under Sourcing (#899)

**2026-07-05.** `validate-setup.sh` ran its entire validation program (gh-auth
probe, `.rite` checks) at SOURCE time and exited 1 in any clean environment —
which is why `source-all-libs.bats`/`lib-resource-safety.bats` failed in CI
while passing on a configured dev machine. The long-standing "fails spuriously
in agent shells" explanation was wrong; it was this env dependence. Contract:
executables that are also sourced honor `RITE_SOURCE_FUNCTIONS_ONLY=1`
(local-review.sh pattern) — sourcing loads definitions only; direct execution
is unchanged. Any new lib executable with a program body needs the same guard.

## ensure_timeout_cmd Never Blocks or Crashes on Non-TTY (#900)

**2026-07-05.** With no timeout binary on Darwin+brew in supervised mode,
`ensure_timeout_cmd` prompted via `read -p`; on non-TTY stdin (CI, cron,
launchd, pipes) `read` hits EOF, returns non-zero, and `set -e` killed the
ENTIRE config.sh source chain (config sources it at load time) — the graceful
`RITE_TIMEOUT_CMD=""` fallback was unreachable. Contract: interactive prompts
in load-time code paths must branch on `[ -t 0 ]` and degrade to the
non-interactive fallback; the TTY read is hardened with `|| REPLY=n`. This is
the load-time sibling of the "explicit exit instructions" session rules.

## Worktree Creation No Longer Symlinks node_modules (#844)

**2026-07-05.** Removed the `ln -s "$MAIN_WORKTREE/node_modules" node_modules`
block from `claude-workflow.sh`'s worktree-setup path. The symlink was created
"to save disk space" (initial-commit vintage). Three reasons for removal:

1. **Root cause of PR #835.** `npm ci`/`npm install` resolves THROUGH a
   symlinked `node_modules`: its pre-reify step readdirs the target and
   recursively deletes each entry — destroying the main checkout's
   `node_modules` — before replacing the link with a real dir. PR #835 patched
   the destruction with a de-symlink guard, but patching the symptom is worse
   than removing the cause.

2. **Disk-space benefit was illusory.** The gate bootstrap
   (`test-gate.sh::_node_desymlink_node_modules`) and `post-merge-verify.sh`
   both de-symlink before every `npm ci`/`npm install`. Any worktree that runs
   a bootstrap immediately replaces the symlink with a per-worktree real dir,
   so the shared-disk benefit only existed until the first install.

3. **Per-worktree node_modules is normal.** `npm ci` is fast and the disk
   overhead of isolated installs is acceptable; the shared-symlink complexity
   is not.

**What stays:** The de-symlink defenses in `test-gate.sh` and
`post-merge-verify.sh` are intentionally preserved as belt-and-suspenders for
pre-existing worktrees created before this change (they still carry the symlink
until their first bootstrap). The defenses are no-ops for real dirs and absent
paths, so they are safe to keep indefinitely.

**`.gitignore` treatment:** `node_modules` and `backend/node_modules` remain in
the `.gitignore` patterns written by `ensure_symlinks_gitignored` — belt-and-
suspenders against accidental commits if npm installs locally in a worktree or
a pre-existing symlink survives. The staging-cleanup blocks (git mode 120000
checks before commit) are also kept for the same reason.

**Files changed:** `lib/core/claude-workflow.sh` (creation removed),
`lib/utils/test-gate.sh` (comment updated),
`tests/regression/gate-desymlink-node-modules.bats` (header updated, creation-
side assertion added).

## Gate Flake-Retry: One Bounded Serial Re-Run (#938)

**2026-07-05.** Block-on-any treats a load-flake exactly like a real failure;
three merges were blocked in one day by failures that passed 3× in isolation
minutes later (SIGINT pair twice, a symlink assert once), each burning fix-loop
iterations on phantoms. Contract amendment to Block-on-Any: when the targeted
bats run fails (and was NOT watchdog-killed — a timeout is not a flake), the
gate re-runs JUST the failing files once, serially (no --jobs). Tests passing
the quiet run are load-flakes: their `not ok N name` TAP lines are flipped to
`ok N name` IN PLACE (numbering preserved so the #804 plan-deficit math is
untouched) and they are named LOUDLY (`cleared on serial re-run (load flake)`
+ `[diag] TEST_GATE_FLAKE_RETRY cleared= persisted=`) so health reports keep
seeing recurring flakes rather than silently absorbing them. Failures that
persist on the quiet run block exactly as before. Bounds: targeted-selection
path only; 1..RITE_GATE_FLAKE_RETRY_MAX_FILES (default 5) failing files (more
is real breakage); `[tests_not_run]` synthetics never retry (a swallow is not
a flake); RITE_GATE_FLAKE_RETRY=false is the operator off-switch. Rejected:
per-test quarantine lists (rot silently; the serial re-run is evidence-based
per occurrence) and N>1 retries (a test needing two quiet runs isn't flaking,
it's broken). Test: tests/regression/gate-flake-retry.bats.

## Pass-Type Detector Threshold Reconciliation (#937)

`assess-review-issues.sh` detects whether an assessment is a "fixreview pass"
(a retry after at least one prior review exists) by counting sharkrite review
markers in the PR. Two call paths reach the assessor with different marker
counts, requiring different thresholds:

**Post-post path** (orchestrated fix loop — `assess-and-resolve.sh` calls
`local-review.sh` which posts a new marker, then calls `assess-review-issues.sh`):
`RITE_REVIEW_JUST_POSTED=true`. The freshly-posted marker inflates the count by 1;
count=1 means only the current-run review exists — no prior pass ran.
Threshold: **≥2** (one existing + one just-posted = first fixreview pass).

**Consume-not-post path** (standalone `--assess-and-fix` after `--review-latest`,
or any resumed path where the review was consumed from the PR without
re-posting): `RITE_REVIEW_JUST_POSTED=false` (or unset). count=1 already means
exactly one prior review exists — this IS a fixreview pass.
Threshold: **≥1**.

`assess-and-resolve.sh` exports `RITE_REVIEW_JUST_POSTED` before calling the
assessor. The assessor reads it at startup and sets `_fixreview_threshold`
accordingly, then uses `-ge "$_fixreview_threshold"` for the comparison.

Without this reconciliation, standalone `--assess-and-fix` always behaved as if
it were the first pass (RETRY_COUNT stayed 0, convergence rules never engaged),
causing the fix loop to diverge on resumed workflows — the original issue #937
symptom.

**Contract invariants (pinned by `tests/regression/fixreview-assessment-convergence.bats`):**
- Both threshold branches (`_fixreview_threshold=2`, `_fixreview_threshold=1`) exist in the assessor.
- The comparison uses `-ge "$_fixreview_threshold"` (variable, not a hardcoded literal).
- `assess-and-resolve.sh` exports `RITE_REVIEW_JUST_POSTED` before calling the assessor.

## Settled Findings Reach the Reviewer, Not Just the Assessor

**2026-10-24.** The assessor has inherited prior decisions since #910:
`build_prior_decisions_ledger` collects every DISMISSED / ACTIONABLE_LATER
finding on the PR with its reasoning (newest classification wins) and the
assessment prompt says to inherit them unless a concrete change touched the
specific area. The reviewer never saw that ledger — its fix-review pass got the
prior review body and the fix-commit diff only — so it could re-raise a settled
finding every round and the assessor re-dismissed it each time. That converges,
but it costs a review mention and an assessment per round, and a re-raised item
can come back at a higher severity.

Now `local-review.sh` injects the same ledger into the fix-review prompt as
"Prior Assessment Decisions (settled — do not re-raise)" with the same rule: do
not re-raise unless the fix-commit diff changes the code the finding concerns,
and say what changed if you do. First-pass reviews are untouched (no prior
review → no ledger fetch). The function moved to `lib/utils/review-helper.sh`
(exported, both callers source it); `assess-review-issues.sh` is a script with
a top-level body and cannot be sourced for one function — the same reason
`generate_adr_for_ref` was extracted in 2026-06.

**Enforcement:** `tests/regression/prior-decisions-ledger.bats` (ledger
contents, newest-wins dedup, marker filtering, home + export) and the three
"prior-decisions" cases in `tests/regression/fixreview-verification-prompt.bats`
(fetched only inside the fix-review block; section wording; empty when no ledger).

## Gate Verdict Persistence: Empty Re-Selection Cannot Pass Vacuously (#944)

**2026-07-06.** The fix-loop re-gate deliberately narrows its diff base to the
fix commit (workflow-runner passes `_pre_fix_head`) so a fix round re-runs only
what the fix touched. The hole: a fix touching only uncovered paths computed an
EMPTY selection and the round reported outcome=passed having verified NOTHING —
overwriting the prior failing verdict. Live escape: PR #931 (`selected=15 →
failed`, then `selected=0 → passed`), which merged #855 red; repaired in #943.
Contract: on a FAILED outcome the gate persists the failing FILES per PR
(`.rite/state/gate-prior-failing-pr<PR>.list`, `[tests_not_run]` synthetics
excluded — a swallow is not a re-runnable failure); every subsequent run for
that PR UNIONS those files into its selection (`reselected_prior=true` diag +
loud line), so `selected=0` is only reachable when no prior failure exists; a
PASSED outcome clears the state, keeping genuine zero-selection runs
(docs-only diffs) skipped. Rejected: re-running the full prior selection every
fix round (restores the pre-narrowing cost the narrowing exists to avoid —
failing files are the sufficient invariant).

## Parent-PR Attachment Contract (#1007/#1008)

**2026-07-13.** Follow-up issues (review findings, tech-debt) carry a
`<!-- sharkrite-parent-pr:N -->` marker in their body referencing the PR that
produced the work they must address. Without a resolver, running `rite <follow-up>`
re-discovers no PR (the follow-up has no own PR yet), launches a new dev session,
and creates a fresh PR — producing a phantom review of the follow-up's empty
branch followed by a phase-fail (issue #967).

### Single Resolver in `workflow-runner.sh::run_workflow`

The resolver runs ONCE per workflow start, BEFORE the phase-skip block, and is
the authoritative source for the orchestrator's `PR_NUMBER` and `WORKTREE_PATH`.
All other parent-pr lookups (batch deferral in `batch-process-issues.sh`, the
`find_worktree_for_task` helper in `claude-workflow.sh`) operate at different
scopes and are parallel paths — they do not replace this resolver.

**Implementation:** `detect_parent_pr_attachment` (`lib/utils/pr-detection.sh`)
parses the issue body, extracts the parent PR number, queries GitHub for the
PR's state, and returns one of three modes:

| `PARENT_ATTACHMENT_MODE` | Condition | Orchestrator action |
|---|---|---|
| `adopt` | Parent PR is `OPEN` | Set `PR_NUMBER = PARENT_PR_NUMBER`; resolve `WORKTREE_PATH` from parent branch |
| `ignore` | Parent PR is `MERGED` or `CLOSED` | Log traceability note; run fresh branch from main (normal workflow) |
| `none` | No marker in body | Fall through to normal workflow |

API failure (GitHub unavailable, PR not found) → `ignore` (safe fail-open: run
fresh rather than blocking on a missing verdict).

### WORKTREE_PATH Resolution

The adopt arm resolves `WORKTREE_PATH` directly from `PARENT_PR_BRANCH` (already
populated by `detect_parent_pr_attachment`, no extra API call). Two sub-cases:

**Local worktree found:** `WORKTREE_PATH` is set, `RESUME_MODE=true`. The
phase-skip block (`if PR_NUMBER && WORKTREE_PATH && is-dir`) fires and the
follow-up's run resumes from wherever the parent PR left off (review, assess, or
merge).

**Local worktree not found** (cross-machine / worktree removed): `WORKTREE_PATH`
stays unset. The generic worktree-detection block below also finds nothing. Phase 1
runs and creates a NEW worktree on the PARENT BRANCH (not a follow-up-scoped fresh
branch), so the dev session and subsequent review still target the parent PR — the
phantom-review-then-phase-fail shape is avoided.

### Guard: Only Resolve When PR_NUMBER Is Unknown

The attachment resolver only runs when `PR_NUMBER` is empty or `null` at the time
of the check. If an earlier `detect_pr_for_issue` call found a `Closes-#N` PR
(e.g., a re-run where the follow-up already has its own PR), that PR wins — the
follow-up is no longer a fresh follow-up and attachment is not needed.

### Regression

`tests/regression/batch-single-issue-parity.bats` — fixtures: follow-up with OPEN
parent (adopt path), follow-up with MERGED parent (ignore path), and #967's
phantom-review shape (no local worktree, verifies Phase 1 targets parent branch).

Direct unit tests for `detect_parent_pr_attachment` outcomes:
`tests/regression/parent-pr-attachment.bats`.

## Hermetic Bats Env: Session-Behavioral Var Scrub (#1186)

**2026-10-12.** Bats tests inherit the workflow session's environment, so tests
that pass in isolation can fail inside a gate when an exported session var flips
a code path. Three incidents on 2026-10-12:

- `RITE_TEST_GATE_SKIP_TRIGGERS=true` (from `post-merge-verify`): broke 3
  lint-selection tests across 5 slots (#1182).
- `RITE_TARGET_BRANCH=supervised-ux` (from a `--branch` session): broke both
  `_docs_apply_approved` tests across 3 retries (#1049, PR #1179).

A lint rule cannot catch this class — the broken tests contain zero references
to the triggering variable. Prevention is a runtime boundary at the one choke
point where the gate spawns bats.

**Fix:** `_bats_sandbox` in `run_test_gate` (`lib/utils/test-gate.sh`) was
extended with a deny-list of session-behavioral RITE_* vars removed via `env -u`
from every bats child. The deny-list is located via the `_GATE_BATS_SCRUB_VARS`
comment anchor in `test-gate.sh` (not a shell variable — grep for it to find the
exact `env -u` args):

```
_GATE_BATS_SCRUB_VARS: RITE_TARGET_BRANCH  RITE_TEST_GATE_SKIP_TRIGGERS
  RITE_STALE_BRANCH_THRESHOLD  RITE_STALE_BRANCH_HARD_RESTART_THRESHOLD
  RITE_ACCEPT_RED_MAIN
```

**Structural vars that are NOT scrubbed:** `RITE_REPO_ROOT`, `RITE_LIB_DIR`,
`RITE_PROJECT_ROOT`, `BATS_TEST_TIMEOUT` (the gate sets this itself; scrubbing
it would break per-test timeouts). Rule 35 suppressions and `setup.bash` loaders
inside tests depend on the structural RITE_* vars passing through.

**Coverage:** Both the main bats invocations (6 sites: full/parallel/serial ×
pretty/TAP) and the flake-retry invocation in `_gate_flake_retry_pass` use
`_bats_sandbox` — the flake-retry function accesses it via bash dynamic scoping
(called from within `run_test_gate` where the local is defined).

**Regression:** `tests/regression/gate-session-env-scrub.bats` — structural
checks that every deny-listed var appears in `_bats_sandbox`, that structural
RITE_* vars are absent from the scrub list, that all 7 invocation sites use the
sandbox, and behavioral probes that extract the deny-list from `_bats_sandbox`
via sed and run a nested bats invocation through the same `env -u` chain,
confirming `RITE_TARGET_BRANCH` is unset and `RITE_REPO_ROOT` passes through.

**Note on `RITE_TEST_GATE_SKIP_TRIGGERS`:** this var is consumed by the gate's
own selection phase (before bats is spawned), so scrubbing it from the child
environment does not alter gate-selection behavior — it only prevents tests from
seeing it and potentially altering their own behavior.

---

## `--sync` Typed Dispatch: Grammar, Rail Ordering, and Exit-Code Composability (#1041/#1048)

`rite --sync` resolves to one of three verbs based on its argument type. Dispatch lives in `bin/rite` after the logging setup (the `if [ "$MODE" = "sync" ]` block), with all three functions implemented in `lib/utils/integration-sync.sh`.

| Form | Args | Verb | Implementation |
|------|------|------|----------------|
| Branch form | one non-numeric arg | merge `origin/main` into integration branch | `sync_integration_branch` |
| Issue form | one or more numeric args | rebase each feature branch onto its resolver-determined base | `sync_issue_branch` |
| Bare form | zero args | sweep all ledger branches then all in-flight worktrees | `sync_all_repos` |

Mixed args (e.g., a branch name plus an issue number) are rejected as a usage error (exit 1). A bare-word alias `rite sync [args]` mirrors `rite --sync [args]` exactly.

### Branch Form — `sync_integration_branch`

Fetches `origin/main` and `origin/<branch>`, checks currency, and if behind: merges `origin/main` into the branch in a temporary detached worktree, then pushes. `rite --sync main` is refused immediately with exit 1 (merging main into itself is meaningless and potentially destructive); pinned by `sync-integration-branch.bats:69`. Three invariants are permanent:

- **Never rebases.** Integration branches are shared and long-lived; live worktrees fork from them, and their SHAs are recorded in the integration ledger. Rebasing would rewrite those SHAs and break in-flight worktrees.
- **Never force-pushes.** A merge adds commits without rewriting history, so plain `git push` is correct. Force variants are explicitly prohibited.
- **Never called automatically.** Only an explicit `rite --sync <branch>` triggers this. No workflow phase, batch slot, or other verb may call it.

**Conflict path** mirrors `stale-branch.sh`. If `attempt_claude_merge_resolution` is available (guarded with `declare -f`), it is called inside a subshell that `cd`s into the sync worktree — matching the `stale-branch.sh` pattern exactly. On resolution: `commit_resolved_conflicts` → `verify_post_merge` → push. If the resolver is unavailable or fails, `git merge --abort` cleans up, the temp worktree is removed, and manual instructions are printed.

**Exit codes:**
- `0` — already current (no-op), merge+push succeeded, or conflict resolved and pushed
- `1` — `main` passed as branch arg (refused), fetch failed, remote branch not found, worktree creation failed, commit of resolved conflicts failed, post-resolution verification failed (`verify_post_merge`), unresolvable conflict, or push failed. See `integration-sync.sh:103` and `tests/regression/sync-integration-branch.bats:69` for the `main`-refusal pin.

**Diagnostic:** `INTEGRATION_SYNC branch=<b> outcome=current|merged|resolved|conflict|push_failed`

`push_failed` is a distinct outcome from `conflict`. A push rejection after a successful merge is a network/infrastructure failure, not a merge conflict — the distinction matters for health-report aggregation.

`outcome=conflict` covers two distinct failure modes: (1) the resolver was unavailable or returned non-zero (genuine unresolvable conflict), and (2) `verify_post_merge` failed after the git-level resolution succeeded (tests fail on the resolved state). Both are reported as `conflict` because both leave the branch unsynced and require manual intervention. The two failure modes are currently indistinguishable in the diag stream: `commit_resolved_conflicts` emits no separate `_diag` event, and `outcome=resolved` is only emitted on the success path. A future health-report improvement would need a distinct `outcome=verify_failed` to separate them.

### Issue Form — `sync_issue_branch` and Its Four Skip-Rails

Rebases the feature branch for an issue onto its resolver-determined base and force-pushes with `--force-with-lease`. Four skip-rails are checked in order. Rails 1 and 2 run before any network calls — Rail 1 inspects lock file state only; Rail 2 inspects local working-tree state only (`git diff`). A `not-found` early-exit fires between Rails 1 and 2 when no worktree path is found for the issue — there is no branch to rebase, so Rails 2–4 are bypassed (→ `not-found`, exit 0). Rails 3–4 run after discovery (gh API lookups that locate the PR and its worktree), base resolution (`resolve_target_branch` — a separate step with its own fallback chain, defaulting to `main`), and the `git_fetch_safe` that refreshes remote refs, because both require `COMMITS_BEHIND_MAIN`:

1. **Live lock** (Rail 1, cheapest) — `get_locked_issue_numbers` uses kill-0 liveness, so backfill locks (which have no `pid` file) are never returned. If the issue holds a live lock, the session is actively running. Never push under a live session. → `skipped-lock`, exit 0.
2. **Dirty worktree** (Rail 2) — `git diff --quiet` + `git diff --cached --quiet`. Never stash or touch uncommitted work; only the owner should manage WIP. → `skipped-dirty`, exit 0.
3. **Staleness threshold** (Rail 3) — `get_commits_behind_main` ≥ `RITE_STALE_BRANCH_THRESHOLD` (default: 10). A branch this far behind is likely to produce conflicts on rebase, and the resulting stale-review rewrite would be expensive. The correct path is the workflow's own stale-branch handler, which is conflict-based (post-#1137): it attempts a rebase first and falls back to close-and-restart only if conflicts are unresolvable. Deferring here avoids a shallow sync attempt on what the workflow's resolver is better equipped to handle. → `skipped-threshold`, exit 0.
4. **Already current** (Rail 4) — `COMMITS_BEHIND_MAIN == 0`. No rebase needed. → `current`, exit 0.

If all rails pass, the function rebases onto `origin/<base>`. On rebase conflict: abort, exit 0 (informational skip). On push rejection after a successful rebase: exit 1 (operational failure).

`sync_issue_branch` does not invoke Claude conflict resolution or `verify_post_merge`. These workflow-level tools belong to the issue lifecycle, not the lightweight sync path. The issue form is intentionally shallower than the branch form.

**Diagnostic:** `SYNC_ISSUE issue=<N> outcome=skipped-lock|skipped-dirty|skipped-threshold|current|not-found|conflict|synced|push_failed|fetch_failed`

### Exit-Code Composability Contract

The asymmetry between `conflict=exit 0` and `push_failed=exit 1` is intentional:

- **`exit 0` for skips and conflicts** — a conflict or rail-triggered skip is informational; the sync verb's infrastructure is not broken. `sync_all_repos` uses this to continue processing remaining issues without falsely aborting.
- **`exit 1` for operational failures** — a fetch or push failure is a network/infrastructure error the operator must investigate. `sync_all_repos` propagates these to its overall return code.

**Why conflicts must be exit 0:** both `bin/rite`'s issue-form dispatch and `sync_all_repos`'s Phase B call `sync_issue_branch` with `|| _rc=$?` — the non-zero exit is captured, not propagated. The issue is not loop-abort but reporting: both loops fold per-item status into their respective accumulators (`_sync_overall_rc` in `bin/rite`'s issue-form dispatch, `_overall_rc` in `sync_all_repos`), and a conflict returning exit 1 would surface a normal, expected skip as an operational failure in the sweep's result. Skips and conflicts are expected outcomes, not infrastructure failures; only fetch and push failures (which indicate a broken network or remote state) warrant the `_overall_rc=1` path.

### Bare Sweep Form — `sync_all_repos`

Runs two phases in sequence. Integration branches are synced first so that feature branch rebases in Phase B target already-current bases within the same sweep.

**Phase A — integration branches:** recursively enumerates via `find -type f -name '*.log'` inside `${RITE_STATE_DIR}/integration-branches/` (absent-safe via `[ -d ]` guard). Branch name is derived from the ledger-relative path by stripping the `.log` suffix — NOT via `basename`, which would truncate slash-containing names like `release/1.2`. Before calling `sync_integration_branch`, each branch is preflight-checked with `git ls-remote --exit-code --heads origin <branch>`:

- Exit 2 → branch gone on remote (promoted and deleted) — lifecycle complete, not an error. → `skipped-gone`, loop continues.
- Non-zero non-2 → transport error → `_overall_rc=1`, loop continues.
- Exit 0 → branch exists → call `sync_integration_branch`.

`sync_integration_branch` is invoked with `</dev/null`: the conflict resolver reads from stdin, and without this redirect it would consume the `find` pipe stream that drives the loop, silently skipping all remaining ledger entries after the first conflict.

The skipped-gone preflight exists because ledger files are never pruned after promotion; a gone remote is the expected end-state for a promoted integration branch, not a failure. Without this check, `sync_all_repos` would treat a promoted branch as a fetch failure and report the sweep as failed.

**Phase B — in-flight worktrees:** calls `backfill_worktree_locks` (best-effort to establish the worktree→issue mapping for legacy worktrees), then walks `${RITE_LOCK_DIR}/issue-*.lock/cwd` entries. Each entry goes through `sync_issue_branch` with all four rails applied.

**Overall exit code:** 0 if all items synced/current/skipped-by-rail; 1 if any operational failure (fetch/push error) occurred.

**Regression tests:** `tests/regression/sync-integration-branch.bats` — dry-run dispatch for all three forms, design-contract greps (no rebase in `sync_integration_branch`, no stash anywhere, `--force-with-lease` in `sync_issue_branch` only, resolver availability-guarded), and behavioral rail tests (live-lock, dirty-worktree, staleness threshold, conflict-exits-0). **Not yet pinned:** the already-current (Rail 4) exit-0 path and the Phase A skipped-gone preflight behavioral test.

## A Timeout Without SIGKILL Escalation Is Advisory (#1301)

`timeout N cmd` sends SIGTERM at the deadline and then **waits for cmd to
exit**. A process that ignores SIGTERM — or that is blocked writing to a pipe
whose reader is gone — never exits, and `timeout` waits with it indefinitely.
The deadline silently becomes a suggestion, and the symptom in the logs is
indistinguishable from a slow call.

Every LLM session routes through `run_with_timeout`, and `claude` is a node
process that does not reliably die on SIGTERM. Batch `20261014-184054`:

| Session | Deadline | Actual |
|---|---|---|
| `claude_fix_session` | 1800s | 2h 39m 38s |
| `review_generation` | 600s | 4h 25m 35s |
| `claude_dev_session` | 1800s | 10h 58m 3s |

Issue #1231 ran 7h38m and #1262 ran 11h08m on the back of that.

**The caps did not help, and could not have.** `RITE_MAX_ISSUE_HOURS` (4h) and
`RITE_MAX_SESSION_HOURS` (12h) are evaluated at phase boundaries. A single
unbounded call never reaches a boundary, so no cap is ever consulted. Bounding
the individual call is therefore the only place this can be fixed; the caps
are a backstop for *accumulated* work, not a watchdog.

**`test-gate.sh` had it right the whole time.** Its bats watchdog uses
`gtimeout -k 30` (`test-gate.sh:2433`), which is exactly why the gate reliably
dies at its 1800s deadline while every LLM call could hang. It was the only
`-k` in the codebase. `run_with_timeout` now carries the same contract: TERM at
the deadline, KILL `RITE_TIMEOUT_KILL_AFTER` (default 30) seconds later. GNU
`timeout`/`gtimeout` both support `-k`, and `ensure_timeout_cmd` only ever
resolves to one of those two, so the flag is always available when
`RITE_TIMEOUT_CMD` is set.

**Unbounded is survivable; silent unbounded is not.** When no timeout command
exists at all, the helper now warns once per process instead of quietly
dropping the bound. An 11-hour run must not be able to look like a slow call.

**Rule:** any deadline enforced with `timeout` carries `-k`. A bare
`"$RITE_TIMEOUT_CMD" "$secs"` outside `timeout.sh` reintroduces the defect and
is rejected by a structural test in
`tests/regression/claude-timeout.bats`.
## Promotion Review Is Assessed, Not Just Captured (#1278)

The promotion review is a **fresh audit**, and that is not a bug — it is the
only review that ever sees every constituent issue integrated together, so
cross-issue findings appear nowhere else. But the freshness has a cost that
showed up the first time promote filed its findings (#1273 carried 12 items for
`supervised-ux`): the promotion PR has no prior review, so `local-review.sh`
emits no `FIXREVIEW_CONTEXT_SECTION`, and the reviewer re-raises findings each
constituent issue's own review loop had already judged.

**Why already-reviewed code produces findings again.** Four distinct causes,
only the last of which was fixable here:

1. **Different diff.** A per-issue review audits one issue against its base.
   The promotion review audits all of them integrated against `main`.
2. **Convergence never meant "clean."** A slot converges when zero
   ACTIONABLE_NOW items remain. DISMISSED and ACTIONABLE_LATER findings were
   *deliberately* not fixed — the code still reads the same way, so a fresh
   reviewer finds them again. Dismissed is not fixed.
3. **Fix commits are new code.** Later rounds legitimately review what earlier
   rounds produced.
4. **No memory of prior judgment.** The promotion review had no record of the
   per-issue assessments, and nothing downstream applied that judgment either.

**The contract.** Phase 5b runs the standard `assess-review-issues.sh` on the
promotion review after the CRITICAL hard gate and before the merge:

| Classification | Disposition |
|---|---|
| ACTIONABLE_NOW | one aggregated issue (`Promotion review ACTIONABLE_NOW findings: <branch>`), deduped |
| ACTIONABLE_LATER | per-item issues filed by the assessor, deduped |
| DISMISSED | dropped |

**Both actionable paths dedup, by different routes.** The assessor's own dedup
lives inside its ACTIONABLE_LATER loop, so NOW items reached the aggregate
unchecked — and the first live run proved that mattered: promoting
`plan-quality` re-filed a finding already tracked as #1253, and a second item
duplicated #1260. `_promote_title_matches_open_issue` now filters the NOW set
against every open `from-review`/`tech-debt` issue before the aggregate is
built, and `_promote_strip_tracked_now_blocks` removes the matched blocks from
the body. When every NOW finding is already tracked, nothing is filed at all.

That filter deliberately reuses the assessor's Stage-1 heuristic — lowercase,
split on non-alphanumerics, count tokens longer than three characters that
appear as whole words in an existing title, two or more means the same finding.
A second, differently-tuned matcher would make the two paths disagree about
what a duplicate *is*, which is worse than either rule alone. The comparison
set is every open review/tech-debt issue rather than this PR's, because the
duplicates a promotion must avoid were filed under the **constituent** issues.

The dedup is best-effort like everything else in Phase 5b: an issue-list fetch
that fails yields an empty set, nothing is filtered, and the aggregate is filed
whole — the pre-dedup behaviour, which over-reports rather than losing a
finding.

Two properties make this the right reuse rather than a parallel classifier:

- **`RITE_ISSUE_NUMBER` is deliberately empty.** That empty value is what
  widens the assessor's Stage-2 dedup search from "same source issue" to "any
  open follow-up" — exactly the scope a promotion needs, because the duplicates
  it must avoid were filed under the *constituent* issues, not under this PR.
  This is the mechanism that stops cause 4 above from re-filing work already
  tracked.
- **Still classify-only, never a fix loop.** Fixing on the integration branch
  would land code on `main` that skipped the per-issue review cycle. Promote is
  a gate; it files issues.

**Degradation is one-directional.** The assessment is best-effort — promotion
has already passed every gate by then, so nothing in Phase 5b may block, retry,
or fail the merge. Assessor missing, non-zero exit, empty output, or the
`ALL_ITEMS` sentinel (which means the provider declined to classify) all fall
through to the pre-existing deterministic raw-review capture (#1209). A broken
assessor therefore degrades to "captures more than needed", never to "loses
findings". Treating `ALL_ITEMS` as a successful assessment would invert that,
which is why it is tested explicitly.

`RITE_ASSESSMENT_TIMEOUT` defaults to 600s on this path rather than the
per-issue 300s: a promotion review spans every constituent issue and carries
several times the findings. An operator override still wins.

**Regression:** `tests/regression/promote-review-followup.bats` Group 6 pins the
three-way outcome (assessed-with-NOW / assessed-with-nothing / not-assessed),
the env contract passed to the assessor, and the no-bare-`exit` best-effort
property of the region.

## The Resolver's Success Contract Is the Working Tree, Not the Index (#1317)

`attempt_claude_merge_resolution` returns 0 for "conflicts resolved **in the
working tree**". It cannot stage: the session prompt says "do NOT run git add",
and the caller stages via `commit_resolved_conflicts` afterwards. So at
verification time every known conflict path is still unmerged in the index, by
design.

Step-6 Check 1 asserted the opposite — `git diff --diff-filter=U` must be
empty — which is only true if something staged, which only the session could
have done, which the prompt forbids. **The check could only pass when the
session disobeyed.**

Check 1 came from #435. #932 moved staging out of the session and added the
no-git-add instruction, but left the assertion behind. Once sessions actually
complied, every Claude conflict resolution failed immediately after producing a
correct one — live: #1231 (PR #1299) and #1143 (PR #1312), both 2026-10-19,
both correctly merging append-only drift-log entries and independent bats
tests, both discarded with "Unresolved files remain after Claude session".

**The corrected split of responsibility:**

| Check | Question | Oracle |
|---|---|---|
| 1 | Is every unmerged path one the session was given? | index vs `_cr_conflict_files` |
| 2 | Is every given path marker-free? | working-tree content |

Together those are the real contract. Check 1 still catches a conflict that
appeared after the path list was captured, or one the session introduced; Check
2 catches a resolution that left markers behind. Neither tests staging, because
staging is a later step's job.

**Rule:** a verification step asserts only what the steps before it were
responsible for establishing. Asserting a postcondition that a *later* step
owns means the check is reading the wrong stage of the pipeline, and a check
that can only pass by accident is worse than no check — it fails closed on
correct work. The prompt text and Check 1's premise are coupled, so
`tests/regression/conflict-resolver-unstaged-resolution.bats` pins both.

## Deterministic Conflict Mergers Read Stage Blobs, Not the Conflicted File (#1319)

Some merge conflicts have exactly one correct resolution and need no judgment.
The drift log is the clearest case: append-only, each entry a self-delimited
block with its own `recorded:` ISO8601 timestamp, entries mutually
independent, burn-down removing whole blocks. The resolution is the union of
both sides ordered by timestamp — computable, so no provider call is justified.
Two of three conflicts in dogfooding logs were this file (#1231 pr:1299 at
274s, #1143 pr:1312 at 60s), both sessions arriving at exactly that answer.

`attempt_claude_merge_resolution` now runs a deterministic pre-pass before
building its prompt, and skips the session entirely when nothing is left for
it.

**Entries come from git's stage blobs, never from the conflicted file.** This
is the correctness argument, and it was learned by getting it wrong. When both
sides append at the same spot, git emits a line-level hunk and **deduplicates
the shared closing delimiter**:

```
<<<<<<< HEAD
<!-- sharkrite-doc-drift pr:1304 ... -->
**Changed files**: ...
=======
<!-- sharkrite-doc-drift pr:1312 ... -->
**Changed files**: ...
>>>>>>> side
<!-- /sharkrite-doc-drift -->      ← ONE closer for TWO entries
```

Strip the markers and you have two openers and one closer — structurally
damaged. The first implementation did that and **silently dropped the first
entry**. For an append-only log, losing an entry is the worst outcome
available: it is indistinguishable from burn-down, so nobody notices.
`git show :2:<path>` (ours) and `:3:<path>` (theirs) each return a complete,
well-formed log, which is what the merger parses.

The general principle: a conflicted file is a *presentation* of two versions,
not a container of both. Anything that needs the versions must ask git for the
versions.

**Every deterministic merger must fail closed.** If it cannot prove the
conflict is the shape it understands — no conflict stages, an unreadable
stage, zero entries found (so the conflict is in header prose) — it returns
non-zero and the path stays in the LLM list with the file untouched. A
deterministic merge may only replace judgment where there is no judgment to
make.

**Not every accumulating doc qualifies.** `docs/architecture/conventions.md`
looks similar but is accumulate-**in-place**: one entry per convention title,
with later PR numbers appended to that entry's References line. A naive union
would duplicate titles. It needs its own design and deliberately has no merger.

## Output Sanitization: stripping operator-local commands from generated artifacts

**Root cause.** `claude --print` (the provider call used for issue planning, review generation, assessment follow-ups, and promotion PR bodies) loads the operator's user-global `~/.claude/CLAUDE.md`. That file carries RTK hook instructions, so the model authors `rtk grep`, `rtk proxy git status`, etc. into generated text. Those commands are unrunnable for any human or CI without the operator's personal rtk hook installed — they leak into published GitHub issue bodies and PR comments.

**Why input-side suppression is wrong.** Suppressing `~/.claude/CLAUDE.md` at the provider-call level (via a hypothetical `--no-user-config` flag) is not available and would also lose auth context. Output-side sanitization at the seam where LLM output becomes a GitHub artifact is the correct fix.

**The helper: `sanitize_generated_commands`** (`lib/utils/sanitize-output.sh`).

Strips `rtk proxy <cmd>` → `<cmd>` and `rtk <cmd>` → `<cmd>` at command positions:
line-start, after `` ` ``, `$(`, `| `, `&& `. Prose mentions of "rtk" not at a command
position are untouched. Emits one `print_info` line to stderr reporting the count when
anything is rewritten.

**Grounded exception.** When `git grep -qlw rtk` in the project root succeeds, the
target repo genuinely ships rtk commands — sanitization is skipped. This prevents
sharkrite from mangling its own generated bodies (sharkrite's `CLAUDE.md` documents
rtk and the project's tracked files reference it).

**Applied seams — the four highest-leak GitHub-write sites** (each is a one-line call immediately before the GitHub write; additional write sites remain unsanitized — see issue #1360 ACTIONABLE_LATER findings):
- `lib/core/plan-issues.sh` — issue body before `gh issue create --body-file`
- `lib/core/assess-review-issues.sh` — follow-up issue body before `gh issue create --body-file`
- `lib/core/local-review.sh` — review output before the PR comment `--body-file`
- `lib/utils/promotion-composer.sh` — LLM narrative before `printf` emits it to stdout

**Extension point.** The helper is intentionally rtk-specific (rtk is the live failure class; a generic "unknown tool" detector is unbounded). To handle another operator-local tool, add a parallel check inside `sanitize_generated_commands` — see the comment in `lib/utils/sanitize-output.sh`.


## Documentation Drift: Detect Per-Merge, Correct Per-Promote, Align On Demand

**Status:** design locked 2026-10-21, amended 2026-10-22 (on/off via
`align-docs`, `rite docs` as the `main` path, code-first promote, editing
rules, per-type rubrics, docs map as a committed navigation document);
implementation planned as an issue set.
The retirement landed first (2026-10-21): the internal `.rite/docs/` layer and
its first-run bootstrap are gone, and "Doc Assessment" above now describes only
what remains.

**What this replaces, and the evidence.** The merge-phase documentation
assessment (`assess-documentation.sh`) maintained four sharkrite-internal files
under `.rite/docs/` — `architecture.md`, `api.md`, `security.md`,
`changelog.md` — and never touched the repo's own `docs/`. Measured on
2026-10-20: `phase4_merge` clustered at 4m39s–5m54s against the assessment's
own 300s cap, on nearly every merge. The dominant cost was `reconcile_internal_doc`,
which embeds the *entire* current file in its prompt (~42k tokens for
`architecture.md`) and refuses to write back unless the model folds **every**
accumulated `## PR #` section into the baseline and emits zero of them. The
files held 133, 121 and 82 such sections against a reconcile threshold of 3 —
proof it had fired ~130 times and written back ~0, each run leaving the input
larger and the next success less likely. A ratchet. And nothing read the output:
the only consumer of those files was an existence check in
`phase_pre_start_checks`. Roughly five minutes and ~100k tokens per merge to
maintain prose with no reader.

**The principle.** Documentation is a human management responsibility. AI
generates and proposes; a human approves, at a cadence the human chose, against
assertions the human wrote, enforced by tests the human named. Every mechanism
below is that principle applied, and every rejected approach is a way of
violating it.

### Units

- **The branch is the feature.** An integration branch (`rite --branch X`) is a
  related issue set and the unit of documentation correction. Individual issues
  are never associated with a feature doc — that is how a doc bloats with
  one-off entries from pigeon-holed issues filling a documentation quota.
- **Work that goes straight to `main` has no branch.** Its drift entries carry
  `branch=main` and are corrected through `rite docs`, which runs the same
  Tier 2 pass promote runs. This is the common case: all of the last 40 merged
  sharkrite PRs targeted `main` (measured 2026-10-22), so promote alone would
  almost never fire.
- **Feature doc association is declared, never inferred.** `--branch X --doc
  docs/features/foo.md` (or an equivalent plan-log line) names the doc.
  Absence is a warning, not a block. Inference is the fuzzy-targeting failure
  the test gate already taught us.
- **The ADR→feature-doc map is parsed from the ADR's own links**, which is
  deterministic, and used for the *just-in-case* pass (below). The ADR is
  never the declared doc of a branch.
- **Tests are the bridge for everything else.** A feature doc declares the
  tests that enforce it (`<!-- sharkrite-enforced-by: tests/regression/a.bats,
  tests/regression/b.bats -->`; the existing `Enforcement:` lines in this file
  are the informal precedent). The doc declares its tests, not the reverse: the
  doc is the human artifact, and the human decides what counts as enforcement.
  This is `sharkrite-test-covers` pointed the other way.

### On, off, and what each state does

`rite align-docs` is the switch. It replaces the consent prompts in
`rite docs`, `rite --init` and supervised runs.

- **First run** (never enabled): asks whether to turn doc tracking on, and says
  plainly that the audit runs either way. Then runs the restructure assessment
  and the assertion audit — there are no drift entries yet. When the repo has no
  clear doc structure, it offers to scaffold one; the scaffolder is the
  separately designed ground-up bootstrap (test suites → feature docs → ADR).
  Until that exists the offer is omitted, not improvised.
- **`rite align-docs --disable`** turns tracking off. The next plain run asks
  again, as on the first run.
- **On:** Tier 1 records entries on every merge; promote and `rite docs`
  correct them.
- **Off or never enabled:** nothing is recorded and nothing runs
  automatically — so nothing piles up. `rite align-docs` and directed
  `rite docs "<instructions>"` still work: they check docs against the code
  directly and need no entries.
- **Unattended runs never turn tracking on.** (Before 2026-10-21 they silently
  did: 74 unreviewed entries, each with a model call, in sharkrite's own log.)

### Tier 1 — detection, per merge, deterministic, zero model calls

Runs on every PR merge while tracking is on, whether or not the issue is on a
branch.

Triggers: the PR's changed files intersect a feature doc's enforcing test set,
or intersect code those tests exercise, or the PR is on a branch with a
declared doc. A one-off fix that touches no enforcing test creates nothing.

Records a **drift entry**, per doc and per branch (not one global file), with
fields — prose is for human review, fields are for consolidation:

| field | meaning |
|---|---|
| `doc` | the feature doc implicated |
| `branch` | integration branch, or `main` |
| `pr`, `issue` | provenance (a list, see below) |
| `assertion` | the doc assertion whose referenced code/test changed, when identifiable |
| `kind` | `addition` \| `refinement` \| `contradiction` \| `test-scope` \| `reference-missing` |
| `evidence` | changed paths, test names, the grep that fired |
| `recorded` | timestamp |

What Tier 1 may assert is exactly what a grep can answer: a referenced flag,
function, file or test still exists; an enforcing test still exists and still
names the asserted scope; the PR added or refined something in the doc's
territory. **Whether an assertion is still *true* is a judgement and belongs to
Tier 2.** Letting "still true" into Tier 1 reintroduces a model call per merge,
which is the failure mode this design exists to end.

Entries stay bounded:

- **Accumulate in place.** One entry per (doc, assertion); a repeat hit appends
  its PR to that entry — the conventions catalog's rule. Volume tracks affected
  assertions, not merges.
- **Consumed or cleared.** Tier 2 consumes the entries it corrects;
  `align-docs` clears every entry for a doc it audits, because it just
  re-verified that doc against the code.
- **Visible.** A batch that leaves entries ends with one line —
  `N drift entries pending across M docs — run 'rite docs'` — and never waits.

### Tier 2 — correction: one bounded model pass, human-approved

One pass, two entry points:

- **Promote** (`rite --promote`). Everything up to and including the merge runs
  automatically — review, gate, assessment, merge. **The code merges first.**
  Then the doc pass runs and waits for the operator: accept / reject /
  feedback. With no terminal attached it saves the proposal and prints the
  exact resume command (`rite docs --resume <branch>`). Docs never gate the
  merge, and no doc change lands without a human.
- **`rite docs`** for work on `main`: the same pass over `branch=main` entries.

Both use the loop `rite docs` already has for directed updates (propose →
preview → approve → dedicated docs PR); there is no second doc-editing UX.

**Bounded input:** the declared feature doc's affected sections (located
through the docs map, read by anchor), the ADR section that references the
doc, the entries, and a diff summary. **Output:** a narrative of what changed
and why the doc should change, *and* the explicit list of proposed edits. Both
are required; narrative alone is not reviewable and a diff alone is not
readable.

Contract:

- **Propose, never write.** Accepted edits land through the docs-PR path.
- **Doc rejection never blocks anything.** The code already merged. On reject,
  the entries persist and `align-docs` sees them later.
- **One update per branch promotion.** The feature doc changes at most once per
  promote. Accepted entries are **folded into the docs PR body**, the permanent
  record of why the doc changed, then removed from the entry store. Entries are
  consumed, not deleted into nothing.
- **Just-in-case pass.** The diff is intersected with every *other* feature
  doc's enforcing tests and referenced files (set intersection first; model only
  for the residue). Hits produce drift entries for those docs — never edits.
- **Nondeterministic assertions are flagged, not fixed.** When the pass cannot
  verify an assertion deterministically ("the sync experience is smooth"), it
  records a `refinement` entry proposing enforceable wording. Each accepted
  rewording makes the next pass cheaper.

### Editing rules — every pass that proposes doc text

- **Model.** A dedicated `doc_update` role (`RITE_DOC_UPDATE_MODEL`), defaulting
  to the deepest-reasoning model (fable where available). It is separate from
  `doc_assessment`, which stays classification-grade for tag dedup and audit
  triage — a doc edit is read by a human as the product's description; a tag
  merge is not.
- **Length-neutral by default.** Improving prose must not grow the section.
  Each proposed edit carries its computed size change; an edit that grows a
  section past a threshold (order of 15%) must state why in the preview — new
  behavior, new constraint, a real addition. Computed, not trusted to the model.
- **Only the shipped product.** No deadlines, temporary setbacks, company
  decisions, people, or anything else that stops being true without the code
  changing. A prompt rule, plus a flag-only check that highlights dates and git
  committer names in proposed text. The human decides; the check never
  auto-rejects (keyword matching may flag, never decide).

### Rubrics — every doc is checked twice

1. **Accuracy, every doc including the ADR:** each assertion matches the code.
2. **Role, by doc type:**
   - *Feature doc* — stays within one feature; every assertion names an
     enforcing test or is flagged; no overlap with sibling feature docs.
   - *ADR* — links every feature doc; no feature doc contradicts it; no area of
     the code is covered by zero feature docs; its decisions still hold.

Sharkrite ships a default rubric per type; a repo overrides it in the docs
map. The ADR is audited no less than any other doc — its role check is simply
the one that compares *across* docs.

### The ADR: never edited at promote

Promote sees one branch's slice; the ADR describes the whole product, so an
ADR edit needs the whole picture, which only `align-docs` has. Promote's
observations about the ADR — a feature that contradicts it, a reference it
lacks, scope it no longer matches — go to a **separate ADR drift log**. A wrong
feature-doc edit is a bad paragraph; a wrong ADR edit is a wrong product.

### `rite align-docs` — the full audit, on demand

There is no cheap mode: the per-change path is Tier 2.

- **Scope.** `rite align-docs [doc ...]` takes doc names with or without the
  extension (`behavioral-design`, `behavioral-design.md`). No names → every doc.
- **Restructure assessment first.** Should any doc split, merge, or
  consolidate? An oversized doc can split into an ADR plus feature docs (this
  file, at the time of writing: ~2,550 lines and 37 top-level sections, the ADR
  and every feature doc concatenated), and the result can be consolidated with
  an existing ADR and feature docs — merging overlapping sections,
  de-duplicating assertions, re-linking the ADR, re-pointing
  `sharkrite-enforced-by` markers. Few comprehensive docs beat many thin ones.
  **Stable by rule:** every restructure decision, accepted or rejected, goes in
  the approval history, and the same proposal returns only if the doc has grown
  materially since (order of +25%).
- **Assertion audit.** Every assertion in every in-scope doc against the code,
  plus each doc's role rubric. Chunked by docs-map section: one call per
  section, reading that section and the code it references. Before running it
  shows the section and call count and asks.
- **ADR drift log reconcile**, with an **approval history** (question,
  decision, date, rationale; human-editable) injected so the same architectural
  question is never asked twice.
- **Apply** through the same propose/approve loop, narrative and explicit.
  Then clear drift entries for the audited docs and rebuild the docs map.

Quality-of-vision judgements (philosophy, budget vs scale, security posture,
complexity vs reliability) are out of scope: a contradiction may be surfaced, a
resolution may not be proposed. A separate, curated analysis command is their
home and is a later design.

### The docs map — sharkrite's navigation document

A sharkrite-maintained file, **committed** to the repo (the team uses it, and
its tags and notes cost model calls to regenerate). It is the index every pass
queries — Tier 1, Tier 2, `align-docs`, `rite plan`:

- **Every doc and section, with a per-section content fingerprint.** Sections
  without headings are addressed by content fingerprint, not line numbers
  (which shift on every edit). Users' docs never need headers or markers added.
- **Tags and short notes per section** — the context that would be clutter in
  the docs themselves. It absorbs the tag index (`tag-index.md`): one
  navigation file, not two.
- **Doc type (ADR / feature doc) and rubric overrides.**
- **Self-checking on every doc edit.** Structure — files, sections,
  fingerprints — refreshes deterministically; tags and notes regenerate only
  for sections whose fingerprint changed.

No pass reads a whole document to learn whether something is in it: it
consults the map, then reads only the sections it needs, by anchor. A byte cap
bounds *content loaded per pass*, never *what is discoverable* — `rite plan`'s
50 KB auto-discovery cap applying to discovery itself (a 240 KB design doc
loaded whole or not seen) is the oversight this corrects. Today's
`.rite/state/docs-map.tsv` (headings + one per-file SHA, rebuilt only by
`rite docs`, measured 64 commits stale) is the starting point.

### Keeping it lean over time

- **Every model pass emits a diag**: `[diag] DOC_PASS kind=promote|docs|align
  doc=<path> duration_s=N input_bytes=N outcome=accepted|rejected|feedback`.
  The retired layer rotted for ~130 runs because nothing measured it.
- **Oversized docs split.** When a pass's measured duration exceeds a
  configured threshold (order of a minute or two), the workflow suggests
  `rite align-docs <doc>`, whose restructure assessment proposes the split. The
  trigger is the diag, never a feeling.

### Retirement and migration

- **Done 2026-10-21:** `assess-documentation.sh`'s internal layer,
  `bootstrap-docs.sh`, `lib/utils/adr-generator.sh` and the `--no-backfill-adrs`
  / `--backfill-count` flags are deleted; nothing writes `.rite/docs/` any more.
  Existing `.rite/docs/` directories are inert and can be deleted by hand.
  The interim `RITE_DOC_ASSESSMENT_TIMEOUT=1` did not stop the work — it killed
  only the parent script, and the backgrounded sub-assessments kept running and
  spending tokens — which is why retirement went first.
- **Done 2026-10-21:** the per-merge doc-sync rewrite (`.rite/doc-sync.md`,
  `templates/doc-sync.md.example`) is deleted; `RITE_DOC_MODE` no longer depends
  on that file and gains `off`. No-consent now records nothing. Interim meaning
  until `align-docs` owns enable/disable: `sync` = record drift per merge and
  reconcile through `rite docs`; `changelog` = legacy, record only.
- `docs/sharkrite-drift-log.md` (global, free-form) converts to per-doc,
  per-branch entries with the schema above on the first `align-docs`.

### Rejected approaches

- **Per-merge model reconcile over the whole doc** — the ratchet described
  above. Unbounded input, all-or-nothing write-back, no reader.
- **Per-merge edits to user docs** — the retired doc-sync rewrite committed raw
  model output into orrery's README (CLI warnings with local paths, narration,
  a wrapping fence). Detection may be automatic; edits never are.
- **Inferring which doc a branch or issue relates to** — fuzzy targeting; the
  test gate's lesson, relearned. Declared or nothing.
- **Tests declaring their doc** — scatters doc references across test files
  and moves the enforcement decision away from the human artifact.
- **Auto-writing accepted docs** — violates propose-never-write; the human
  approves a diff, not a fait accompli.
- **Docs as a merge gate** — gets accepted to unblock. That includes making
  promote wait for doc feedback *before* merging: the code merges first.
- **Unsupervised doc correction** — promote and `rite docs` are where the human
  reads the feature's story; removing the human removes the point.
- **Unattended runs opting a repo in** — consent recorded by default is not
  consent; it produced 74 unreviewed entries.
- **A cheap mode for `align-docs`** — the cheap path is Tier 2. Two cheap paths
  drift apart.
- **Associating individual issues with feature docs** — quota-driven bloat.
- **An open-ended "review the architecture" prompt inside `align-docs`** —
  the unbounded input in a new costume. The rubric is per doc type, in the map.
- **Whole-document loading under a byte cap as the discovery mechanism** —
  what the cap should bound is content read, not content findable. Query the
  map; read by anchor.
- **Line-number section anchors** — they move on every edit above them.

**Enforcement:** to be pinned per issue as the set lands. Planned:
`doc-drift-entry-schema.bats` (fields, per-doc/per-branch layout,
accumulate-in-place), `doc-drift-tier1-deterministic.bats` (no provider call on
the merge path — structural grep plus a stubbed-provider run that must make zero
calls), `doc-tracking-off-records-nothing.bats`,
`promote-docs-after-merge.bats` (the code merges before the doc prompt; no TTY
saves the proposal and prints the resume command; reject never blocks;
accepted entries fold into the docs PR body), `rite-docs-main-entries.bats`,
`doc-edit-length-delta.bats`, `doc-update-model-role.bats`,
`align-docs-scope-by-name.bats`, `align-docs-restructure-stability.bats`,
`align-docs-approval-history.bats`, `align-docs-restructure-proposes-not-writes.bats`,
the `DOC_PASS` diag presence check, and `sharkrite-enforced-by` marker parsing.
Docs map: `docs-map-section-fingerprints.bats` (headingless sections addressed
by fingerprint; tags regenerate only for changed sections),
`docs-map-rebuild-on-doc-change.bats`, and `plan-reads-docs-map.bats` (`rite
plan` consults the map before loading any content; a section past the byte cap
is still discoverable).
