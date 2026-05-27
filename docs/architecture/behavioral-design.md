# Sharkrite Behavioral Design

Living document of design decisions, behavioral contracts, and rejected approaches. Updated as behaviors change. If you're modifying any subsystem described here, update this doc in the same change.

---

## Development Phase (claude-workflow.sh)

### Claude Dev Session

Claude runs inside a sandboxed session with `--disallowedTools` blocking git/gh commands and `TodoWrite`. The workflow handles commit, push, and PR creation after the session exits.

**TodoWrite restriction:** Claude uses `TodoWrite` to create "phases" during dev sessions, which leads to performative busy-work (e.g., "Phase 4: Testing & Validation" that doesn't actually run tests). Blocking it forces Claude to just do the work instead of organizing its own work.

**Testing inside dev sessions:** Claude should NOT run the full test suite during development. The test gate runs it automatically after the session with parallel execution (xdist). However, Claude MUST run the specific test files it created or modified — this catches bad test assumptions (wrong expected behavior, incorrect assertions) while Claude still has full context to fix them. The full-suite prohibition prevents the observed problem of Claude running the suite 2-3x "to make sure" (each taking 45s+).

**Why test-during-dev matters:** Issues #377 and #391 both failed because Claude wrote tests with wrong assumptions about code behavior. The post-dev auto-fix session couldn't recover because it lacked the implementation context. Running new tests during the session catches these immediately — Claude knows exactly what it just implemented and can fix the mismatch.

**Exit codes from claude-workflow.sh:**
- 0 = success (work produced)
- 3 = test gate failed
- 4 = session completed but no work produced (empty dev)
- 5 = provider usage cap reached (batch-blocking)

### Exit Code 4: Empty Dev Output

When Claude's dev session produces zero file changes:
- **Standalone mode:** Cleans up empty branch and draft PR, exits 0
- **Orchestrated mode:** Exits 4 so workflow-runner can retry

**Retry behavior:** workflow-runner retries once on exit 4. After retry failure, closes the empty draft PR (checks `additions == 0` before closing) to prevent stale PR loops on next run.

**Why this exists:** Issue #135 failed repeatedly because Claude found similar tests in other domains and concluded "already done." The empty-dev detection + retry + cleanup prevents stale PRs from accumulating.

### Implementation Rigor — False Completion Prevention

The dev session prompt includes an "Implementation Rigor" section that guards against Claude concluding work is "already complete" when it isn't. This was added after repeated failures on tech-debt/from-review issues where Claude found related code from the parent PR and stopped without implementing the actual gap.

**Three enforced behaviors:**
1. **Acceptance Criteria Mapping:** Before any "already complete" conclusion, Claude must produce `[criterion] → [file:line] — [why]` for every criterion. If the mapping is incomplete, work is not complete.
2. **Anti-pattern callouts:** Surface-match trap (code looks related but doesn't satisfy criteria), parent-PR confusion (merged PR is context not solution), zero-change exit (must re-read and map before exiting).
3. **Tech-debt/from-review label awareness:** Explicitly states that existing code is the *starting point* — the issue was filed because something about that code is insufficient.

**Why prompt-level, not just CLAUDE.md:** The dev session Claude doesn't see the project's CLAUDE.md (it sees the target repo's CLAUDE.md). These rules must be in the prompt itself.

### Scope Wall — Cross-Issue Bundling Prevention

The dev session prompt includes a "Scope Wall" section that forbids the worker from implementing another issue's work, even one this issue depends on.

**The failure this prevents:** When the worker for an issue with `After: #M` / `Depends on: #M` reads `main` and finds that #M's code isn't actually present yet, the natural inference is "I'll just do #M while I'm here." The bundled work then lands in this issue's worktree, leaving #M's PR empty or this issue's PR carrying #M's code. Observed in freshup #479/#480 — #480's worker implemented #479's Menu CRUD in #480's worktree, leaving #479's PR with only the placeholder `chore: initialize work` commit.

**Three enforced behaviors:**
1. **Dependency context pre-classification:** Before the scope wall, the prompt lists referenced dependencies under "Dependencies (assume merged in main)". Reframes them as context rather than todos. Generated from `After: #M` / `Depends on: #M` / `Blocked by: #M` patterns in the issue body.
2. **Explicit boundary:** "This session implements issue #N ONLY. Every commit must serve this issue's acceptance criteria." If a dependency's code is missing in main, log it as `missing-dependency` to the encountered-issues scratchpad — do not implement it.
3. **No cross-worktree writes:** "Only modify files under your current working directory." The rite workflow runs each issue in its own worktree; writing to a sibling worktree's files is a bug.

**Why the worktree directory name matters:** A previous design appended `_b<issue-list>` (e.g., `_b473-478-479-480-481`) to the worktree directory in batch mode for human identification. This was visible in the worker's `pwd` and acted as a behavioral cue ("this work area covers multiple issues") that encouraged bundling. The suffix is now recorded in a sidecar at `${RITE_DATA_DIR}/batch-context/<issue>.txt` instead — available to tooling, invisible to the worker.

### Empty PR Hard Merge Gate

`detect_empty_pr` in `lib/utils/blocker-rules.sh` blocks merging any PR with zero file changes or only `chore: initialize work` placeholder commits. Wired into `check_blockers pre-merge`.

**The failure this prevents:** Tests pass on an empty PR (nothing changed → nothing breaks), CI is green, the merge gate happily approves. Combined with the scope wall, this catches:
- Truncated dev sessions (worker hit context cap before committing)
- Sessions that mistakenly concluded "already complete"
- Bundled-into-sibling cases where this PR was left empty

The blocker fires in pre-merge urgency tier `high` (requires CRITICAL-finding-equivalent treatment).

### Sibling-Worktree Write Guard

After the dev session exits and before commit/push, `claude-workflow.sh` scans sibling worktrees in `RITE_WORKTREE_DIR` for files modified after `SESSION_START_EPOCH`. If this worktree has zero source changes but a sibling has files modified during the session window, the script fails with `Cross-worktree write detected` and refuses to create an empty PR.

**Why a runtime check, not just a prompt rule:** The scope-wall prompt is necessary but not sufficient — the LLM may still violate it. The runtime check converts a silent failure (empty PR merged green) into a loud one (workflow exits 1 with the offending sibling listed).

### Empty Dependency PRs Are Unsatisfied Dependencies

`batch-process-issues.sh` dependency check (the `After: #N` / `Depends on: #N` / `Blocked by: #N` parser) treats a closed PR with zero file changes as `dep PR merged empty (zero file changes)` — the same skip path as a still-open dep. Without this, downstream issues inherit upstream's gap and either re-implement upstream's work or fail confusingly.

### Pre-Dev State Assessment

Before launching a worker, workflow-runner runs `assess_issue_completion` (in `lib/utils/issue-assessor.sh`) — an LLM-backed read-only pass that classifies each acceptance criterion in the issue body against `main`'s current state. Output is parsed into four states:

- **FULLY_DONE** — main already satisfies every criterion. Issue is auto-closed with the assessor's evidence; phases are skipped.
- **PARTIALLY_DONE** — some criteria satisfied. The assessor's "completed / pending" lists are rendered into a `## Resume Context` block and exported as `RESUME_CONTEXT_PROMPT`, which `claude-workflow.sh` injects into the dev session prompt. The worker is told what's already on main and what remains.
- **NOT_STARTED** — no prior work; proceed normally.
- **UNKNOWN** — issue body has no parseable criteria; proceed normally.

**Why this exists alongside the verification-commands path:** Verification commands are fast and authoritative when present, but most issues don't have them. The assessor handles the rest. Both run in sequence: verification commands first (cheap), then the assessor for fuzzier cases (one provider call).

### Mid-Session Close Detection — Adopt vs. Pitch

After the dev session exits and before commit/push, `claude-workflow.sh` calls `handle_mid_session_close`. If the issue closed during the session, sharkrite must decide what to do with the in-flight branch's work. The naive answer ("delete the branch") is wrong if the worker added something useful that `main` doesn't have.

**Two-step decision:**

1. **Re-assess criteria on new main.** Run `assess_issue_completion` against the latest `origin/main`. If the result is anything other than `FULLY_DONE`, the close looks premature — abort and leave artifacts for human inspection (return code 1). If `RITE_TEST_CMD` is configured, run it; failures also abort.

2. **Classify the in-flight branch's diff** via `classify_inflight_work` (one LLM call):
   - `EMPTY` — no commits ahead of base, or only `chore: initialize work` placeholder. Cleanup.
   - `REDUNDANT` — branch duplicates what's now on `main`. Cleanup.
   - `CONFLICTING` — branch contradicts main's design. Archive the diff to `.rite/inflight-archive/issue-N-conflicting-<stamp>.patch` for recovery, then cleanup.
   - `ADDITIVE` — branch adds something `main` doesn't have. **Preserve everything** (PR, branch, worktree). Retitle the PR to `[Adopted] <original>`, mark it draft, and post a comment explaining the situation on both the PR and the (now-closed) issue. Return code 4 — the caller exits success but doesn't cleanup.
   - `UNKNOWN` — cannot decide safely. Abort, leave artifacts (return code 1).

The classifier is told to lean `ADDITIVE` over discarding real code, and lean `UNKNOWN` over both when context is thin. The bias is anti-deletion: better to leave a dangling PR for human review than silently lose work.

**Closed by our own PR:** treated as a normal merge — no action.

**Concurrency concern:** the cross-process active-issue check at batch start (in `batch-process-issues.sh`) prevents two sharkrite processes from running over the same issue simultaneously. The mid-session close handler complements that by ensuring sharkrite doesn't run over its own *prior* work that landed on main via a different path (sibling issue, manual merge, parallel batch).

**The failure this prevents:** Observed in freshup `rite 488 473` (2026-05-03). Worker for #473 ran 6m45s while user merged a parallel PR that included #473's work, then closed #473. Sharkrite kept going and tried to push redundant code. With this guard, the worker's exit triggers a re-check, the merged-elsewhere case is detected, the in-flight diff is classified, and either pitched or adopted accordingly.

### Pre-Dev Verification

Before starting a fresh dev session, workflow-runner checks if the issue's `## Verification Commands` (from the issue body) already pass on main. If all commands pass, the issue is closed with an explanatory comment and the workflow skips all remaining phases.

**Why:** Issue #395 burned a full dev session where Claude determined no changes were needed, producing an empty PR that was closed and failed. If verification commands already pass, there's no point starting a session.

**Scope:** Only runs when starting fresh (no existing PR/worktree). Only runs when the issue body contains a `## Verification Commands` section with a fenced code block. Issues without verification commands (manually-written issues) skip this check and proceed normally.

**Caller integration:** `phase_claude_workflow` sets `ISSUE_ALREADY_RESOLVED=true` and returns 0. `run_workflow` checks this flag after Phase 1 and skips Phases 2-5. The batch processor sees exit 0 and counts it as a completed issue.

### Test Gate Auto-Fix

When the post-dev test gate fails in auto mode:
1. Captures test failure output
2. Runs a Claude fix session with failures as context
3. Fix session is told NOT to run the full suite (just fix the code)
4. Test gate re-runs the full suite after the fix
5. If still failing, loops back to step 1 (up to 2 attempts total)
6. If still failing after all attempts, exits 3 (blocker)

Up to 2 attempts. Attempt 2 includes context about the previous fix to help Claude understand cascading failures (e.g., "the source was fixed on attempt 1, now the test assertion is wrong").

**Why 2 attempts:** Issue #391 demonstrated cascading failures — the auto-fix correctly fixed the source code (`yields_raw is not None`) but the test assertion also needed updating (`"ValueError"` → `"ValidationError"`). The re-run revealed the second failure, but there was no second fix attempt. Two attempts cover the common case of source+test needing independent fixes.

**Why not just fail immediately:** In batch mode, failing stops the issue and moves on. A quick fix attempt (30-60s) is cheaper than a full resume cycle. The dev session already did the hard work — test failures are usually small mismatches.

### Test Gate Timeout

The test gate wraps test execution in `timeout $RITE_TEST_TIMEOUT` (default 120s). Exit code 124 from `timeout` is handled as a distinct failure — the test gate prints a diagnostic message and exits 3 (blocker) without attempting auto-fix, since a hanging test won't be fixed by a Claude session.

**Why:** Integration tests that make live HTTP requests (or any test with unbounded I/O) can hang indefinitely. Without a timeout, a single hanging test burns the entire session timeout, causing all subsequent batch issues to fail. Observed in freshup where crawler integration tests blocked for 10+ minutes.

**Config:** `RITE_TEST_TIMEOUT` in `.rite/config` (seconds, default 120, 0 to disable). The timeout applies to both the initial test run and the re-run after auto-fix.

**Note:** The root fix for hanging tests belongs in the project (e.g., `pytest.ini` with `addopts = -m "not integration"`). The timeout is a safety net — it prevents one project misconfiguration from cascading into batch-wide failures.

### Worktree Venv: Bootstrap-Once-In-Main, Symlink-Everywhere

Sharkrite manages Python venvs with one shared venv in the main repo, symlinked into every worktree (same pattern as `node_modules`). This replaces a previous per-worktree auto-create path that silently produced broken venvs.

**Why:** A previous version (commit 8707029, March 2026) auto-created a per-worktree venv when `requirements.txt` existed but no venv was present. The implementation swallowed all errors with `2>/dev/null) || true`, so any failed `pip install` (network, missing wheels, interrupted run) left a broken empty `.venv` on disk. The next run saw `.venv/bin/python` exist and skipped re-install — every subsequent test gate then failed with `No module named pytest`. One incident in invoi failed 7 of 8 batched issues this way; only the frontend-only issue made it through. The auto-create *idea* wasn't wrong — Python projects expect dependency bootstrapping the same way Node projects expect `npm install` — but the *implementation* (silent errors, no validation, per-worktree duplication) was.

**How to apply:** At worktree creation (and via an idempotent repair pass on every invocation):

1. **Bootstrap main's venv if missing.** If `$MAIN/requirements.txt` (or `$MAIN/backend/requirements.txt`) exists and there's no working venv (no `.venv/bin/python`, OR exists but `python -c "import pytest"` fails), run `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt` with **visible output** — no `2>/dev/null`. Also installs `requirements-dev.txt` if present (test deps usually live there). One-time per project.
2. **Symlink into worktrees.** `ln -s "$MAIN/.venv" "$WORKTREE/.venv"` — disk-efficient, deps inherited, `verify_post_merge`'s pip-install path upgrades all worktrees together.
3. **Repair existing broken worktrees.** The repair pass runs every invocation; broken `.venv` directories left over from the old buggy code get removed and replaced with working symlinks.
4. **Test gate trusts the venv.** Single `python -c "import pytest"` health check; on failure, exit with a clear remediation message naming the main repo path. Never silently mutate state inside the test gate.

Opt out with `RITE_AUTO_BOOTSTRAP_VENV=false` in `.rite/config` if a project wants to manage its venv manually.

**Trade-off:** Shared venv means a post-merge dep reinstall in worktree A affects parallel worktree B. Acceptable: requirements.txt rarely changes mid-batch, and the race is far less harmful than the silent broken-venv mode it replaces. If bootstrap fails (no network, missing system Python, etc.), the failure is loud and actionable rather than hidden — and existing broken state from the old code is automatically cleaned up.

### Pytest Auto-Optimization

When sharkrite detects pytest as the test runner:
- **xdist:** If `pytest-xdist` is already installed in the project's environment, adds `-n auto` for parallel execution. Sharkrite never auto-installs dependencies the project didn't declare — injecting packages can cause version incompatibilities.
- **xdist fallback:** If pytest exits 3 (INTERNALERROR) with `-n auto` active, sharkrite strips `-n auto` and retries serially. Known issue: xdist + Python 3.14 triggers `KeyError: <WorkerController gw0>` crashes. Since sharkrite injected `-n auto`, it's responsible for recovering when that injection causes failures.
- **Noise reduction:** Adds `--tb=short -W ignore::DeprecationWarning -q` to suppress verbose tracebacks and deprecation spam.

Applied in both `run_test_gate()` (claude-workflow.sh) and `verify_post_merge()` (post-merge-verify.sh).

### Post-Merge Dependency Reinstall

When merging main into a feature branch, `verify_post_merge()` checks if dependency manifests (requirements.txt, package.json, etc.) changed in the merge diff. If so, it reinstalls dependencies before running tests.

**Why:** Worktree venvs become stale after merging main — new packages from main's requirements.txt aren't installed, causing `ModuleNotFoundError` in tests even though the package is listed. This was discovered when a scraper PR added `defusedxml` to requirements.txt, merged to main, and then every feature branch that merged main failed tests because `defusedxml` wasn't in their venv.

**Detection:** `git diff HEAD~1 --name-only` checked against known dependency file patterns. Only runs the install when files actually changed — no-op on merges that don't touch deps.

### Post-Merge Test Failure Attribution

When tests fail after merge, `verify_post_merge()` diagnoses the cause instead of blindly blaming the merge. Three-step process:

**Step 1 — Main health check (cached):** Checks if `origin/main` is broken via a SHA-keyed cache (`.rite/main-health`). Cache hit avoids redundant testing across batch issues. On cache miss, creates a temporary worktree and tests main, then caches the result.

**Step 2 — Main broken path (return 0):** If main's tests fail, creates a `fix-main` labeled GitHub issue (or finds an existing one) and returns 0 (proceed). The merge stays intact — failing tests are from main, not the feature branch. In batch mode, fix-main issues are auto-prioritized to the front of the queue so the root cause is fixed before other issues waste cycles on the same failure.

**Step 3 — Failure attribution (return 0 vs 1):** If main is healthy, compares failing test file paths against the merge diff (`git diff HEAD^1 HEAD`). If failing tests are only in files the merge didn't touch, they're dev-session bugs — returns 0 (the test gate handles them). If any failing test overlaps with merge-changed files, it's a genuine semantic conflict — returns 1 (only case where callers should revert).

**Exit codes:**
- `0` = safe to proceed (tests pass, dev-session bugs, or main broken)
- `1` = semantic conflict (merge changed files that are now failing; caller should revert)

Only exit 1 triggers a HEAD reset. Dev-session bugs and main-broken both return 0 so callers using the standard `if ! verify_post_merge` pattern never accidentally destroy work. All diagnostic intelligence (attribution, caching, issue creation) is inside the function — callers don't need to handle multiple exit codes.

**Why not test before AND after merge:** Running the test suite twice per issue is expensive. The attribution heuristic achieves the same goal (distinguishing merge damage from pre-existing bugs) with a single test run by comparing failing test paths against the merge diff. In the rare case where a semantic conflict is misattributed as a dev bug (e.g., main renames a function and a new test calls the old name), the test gate's auto-fix handles it gracefully — much better than the old behavior of destroying all work.

**Main health cache:** Stored at `.rite/main-health` with format `SHA=... RESULT=pass|fail TIMESTAMP=... [ISSUE=...]`. Updated on every main health check (live or post-merge success). Amortized cost: first issue in a batch tests main once, all subsequent issues get a free cache hit.

**Cleanup:** Temporary worktrees are removed after checks, even on failure.

### Merge Conflict Resolution (conflict-resolver.sh)

When merging `origin/main` into a feature branch produces content conflicts, sharkrite launches a Claude agentic session to resolve them instead of aborting. The resolver gathers context about what both sides intended and passes it to Claude along with the conflict markers.

**Resolution philosophy: main is ground truth.** The branch is the newcomer — main represents accepted work. The resolver instructs Claude to rebase the branch's *intent* onto main's current state, not to preserve both sides literally. If main changed an API contract or code structure, Claude adopts main's version and re-implements the branch's feature on top. Dual code paths ("detect and route to both implementations") are explicitly prohibited. When uncertain, main's version wins — it is safer to under-apply the branch than to break accepted work.

**Context gathered (degrades gracefully when fields are unavailable):**
- PR title and body (if PR number available)
- Issue title (if issue number available, no PR)
- Branch's diff to conflicting files (`git diff origin/main...HEAD -- <files>`)
- Main's commits that touched conflicting files since divergence (`git log`)
- Main's diff to conflicting files

**Resolution flow:** Record conflicts → abort merge → gather context → re-start merge (so Claude sees markers) → run agentic session → verify (no unmerged files AND no literal `<<<<<<<`/`=======`/`>>>>>>>` markers) → return success/failure.

**Call sites:**
- `claude-workflow.sh` — defensive merge before development starts (Phase 1)
- `stale-branch.sh` — merge-main when branch is behind but below stale threshold
- `merge-pr.sh` — pre-merge validation when PR shows CONFLICTING state (Phase 4)

**Not covered:** Rebase conflicts in `divergence-handler.sh`. Rebase resolves per-commit, requiring `git rebase --continue` between commits — too fragile for agentic resolution. The merge paths cover the common case; rebase conflicts are rare.

**Safety guarantees:**
- On failure: merge is aborted, working tree is clean, callers use existing fallback (exit 1 or user prompt)
- Belt-and-suspenders: checks both `git diff --diff-filter=U` (git's view) AND literal marker grep (catches Claude staging files with unresolved markers)
- Does NOT commit, push, or run tests — callers handle all post-resolution actions
- Diff caps (`RITE_CONFLICT_DIFF_LINES`, default 200) prevent prompt blowup
- Tool restrictions (git commit, git push, gh blocked) enforced by provider layer

---

## Stale Branch: Sync Before Merge (stale-branch.sh)

### Problem: push rejected after merge-main

`_stale_merge_main` merges `origin/main` into the feature branch, then pushes. If a prior run pushed commits to the remote feature branch (e.g., conflict resolution from a failed run), the local branch doesn't have those commits. The merge-main commit creates a divergence from the remote feature branch, and `git push` is rejected. The pull-and-retry fallback can also fail if the divergence produces conflicts.

### Fix: fetch and sync remote feature branch before merging main

Before merging `origin/main`, `_stale_merge_main` now fetches `origin/$branch_name` and fast-forward merges it if local is behind. This ensures the merge-main commit is based on the latest remote state, so the post-merge push succeeds.

If the local and remote feature branches have genuinely diverged (conflict on merge), the function aborts with a message — this is a rare case that needs manual resolution.

---

## Branch Upstream Tracking (claude-workflow.sh)

### Problem: worktree creation sets upstream to main

`git worktree add -b BRANCH . origin/main` creates a branch starting at `origin/main` and — due to git's default `branch.autoSetupMerge=true` — automatically sets the upstream tracking ref to `refs/heads/main`. This means bare `git push` pushes to `origin/main`, not the feature branch.

The first `git push -u origin BRANCH` is supposed to correct this, but on resume paths the initial push may be skipped (branch already exists on remote), leaving the wrong upstream in place.

### Fix: two layers

1. **Explicit refspecs on all push calls.** Every `git push` uses `git push origin BRANCH` or `git push -u origin BRANCH`. No bare `git push` anywhere in the codebase. This is the primary defense — correct behavior regardless of upstream config.

2. **Unset upstream after worktree creation.** `git branch --unset-upstream` runs immediately after `git worktree add -b ... origin/main`. This prevents stale tracking between creation and first push. Belt-and-suspenders with the explicit refspec fix.

**Rejected approach: `--no-track` flag.** `git worktree add` does not support `--no-track`. The flag only works with `git checkout -b` and `git branch`. Unsetting after creation is the workaround.

---

## Resume & Phase Skip (workflow-runner.sh)

### Uncommitted Changes on Resume

When a worktree exists (from a previous run or manual work), uncommitted changes must be handled **before** the phase-skip inspection. The phase-skip logic uses `git diff origin/main...HEAD` to determine if implementation exists — this only sees committed changes. Without committing first, uncommitted work is invisible and the workflow reports "No implementation yet."

**Location:** `run_workflow()`, before the "Inspect PR state" block.

**What it handles:**
- Tracked modifications (`M` in porcelain status)
- Untracked new files (`??` in porcelain status, excluding `.rite`, `__pycache__`, `node_modules`, `.DS_Store`)
- Uses provider classify to determine RELEVANT vs UNRELATED
- RELEVANT → `git add -A` + commit
- UNRELATED → `git stash push -u` (restored after workflow)

**Classifier rules (ordered, first match wins):**
1. File overlap with issue body/Claude Context → RELEVANT
2. Same module/domain as issue target → RELEVANT
3. Prior fix artifacts (bug fix patterns for code the issue introduced) → RELEVANT
4. Different domain, no connection → UNRELATED
5. Default when uncertain → RELEVANT (stashing relevant work is destructive; committing unrelated work is recoverable via rebase)

**Why structured rules:** Issue #391 demonstrated inconsistency — the same changes to `scraper_service.py` (a fix from a previous auto-fix session) were classified RELEVANT in one run and UNRELATED in the next. The LLM was reasoning freely and reaching different conclusions from the same inputs. Ordered rules with a RELEVANT default bias reduce variance. The cost asymmetry justifies the bias: stashing relevant work forces re-implementation; committing unrelated work is a minor `git rebase -i` cleanup.

**Why not inside phase_claude_workflow:** The old location only ran when Phase 1 (development) executed. When resuming to a later phase (create-pr, assess-resolve, merge), Phase 1 is skipped and uncommitted changes were never committed. This caused the push phase to see "branch is up to date" with nothing to push.

**Why git add -A instead of git add -u:** The old handler used `git add -u` which only stages tracked files. New files created by a dev session or manual fix (like `src/utils/sanitize.py`) were missed entirely. `git add -A` stages everything, with a follow-up `git reset HEAD` to unstage common junk patterns.

---

## Batch Processing (batch-process-issues.sh)

### Fix-Main Prioritization

Before processing, the batch checks for open `fix-main` labeled issues and prepends them to the queue. This ensures a broken main branch is fixed before other issues waste cycles hitting the same test failures during post-merge verification.

**How it works:** `gh issue list --label fix-main --state open` finds open fix-main issues. Any not already in the queue are prepended. Combined with the main health cache, this means: first issue discovers main is broken → creates fix-main issue → batch continues → next batch run fixes main first → cache updates → remaining issues proceed normally.

### Closed Issue Cleanup

When batch encounters an already-closed issue (state != OPEN), it runs the same artifact cleanup as single-issue mode in workflow-runner.sh: removes worktree, deletes local/remote branches, removes session state file. Finds the PR branch via `closedByPullRequestsReferences` with fallback to closed-PR body search.

**Why not just skip:** A previous run may have crashed mid-merge or been interrupted, leaving worktrees and branches behind. Batch should clean these up rather than silently skipping, since the user won't run the single-issue command for an already-closed issue.

### Usage Cap Batch Abort

When any phase hits a provider usage cap (account/plan limit), the workflow exits with code 5. This is classified as `usage_cap` blocker type in `blocker-rules.sh`, which is batch-blocking (`is_blocking_batch` returns true). The batch processor stops immediately instead of attempting remaining issues.

**Detection chain (two paths):**

1. **CLI stderr** (plain text output modes): Provider stderr → `claude_provider_detect_error()` → classification → exit 5.
2. **Stream-json error events** (agentic sessions): With `--output-format stream-json`, API errors arrive as `{"type":"error","error":{"type":"...","message":"..."}}` on stdout, NOT stderr. The stream filter (`_claude_stream_filter_colored`) captures these via jq's `stderr` builtin → writes to a stream error file → merged into the main stderr file by `run_agentic_session` → `detect_error()` classifies as usual.

**Pattern matching:** `usage.?cap|over.?capacity|quota.*exceeded|plan.?limit|billing_error|529|overloaded` → `USAGE_CAP`. Also: `rate_limit_error` → `RATE_LIMITED`, `authentication_error|permission_error` → `AUTH_EXPIRED`.

**Coverage:** All provider-calling phases detect and propagate exit 5:
- `claude-workflow.sh` — dev session, fix-review session (auto + supervised), test-fix session
- `local-review.sh` (review generation)
- `assess-review-issues.sh` (assessment)
- `assess-and-resolve.sh` (passthrough from assessment)
- `conflict-resolver.sh` (returns 5 to caller)

**Critical: usage cap checks must run before exit code branching.** Stream-json error events may arrive even when the CLI exits 0 (the session "completes" from the CLI's perspective but the API returned an error mid-stream). All `provider_run_agentic_session` callers check stderr for USAGE_CAP immediately after the session returns, regardless of exit code.

**Critical: every `provider_run_agentic_session` call must capture stderr** (not `/dev/null`) and check for `USAGE_CAP` before continuing. The stderr file must NOT be deleted before this check. Prior bug: the fix-review path deleted stderr immediately and only printed a warning on non-zero exit. Second bug (2026-04-04): stream-json error events were silently discarded by the jq filter — stderr was always empty for agentic sessions, making usage cap detection completely non-functional.

**Exit code 5 must propagate to the batch processor.** `handle_blocker` exits the `workflow-runner.sh` subprocess — the batch processor only sees the subprocess exit code. If `handle_blocker` exits 1 for a usage cap, the batch processor can't distinguish it from a generic failure and continues to the next issue. `handle_blocker` now exits 5 for batch-blocking blockers, and `batch-process-issues.sh` checks for exit 5 and breaks the loop.

**Why not retry:** Usage caps are account-level limits, not transient rate limits. Retrying wastes time and leaves overlapping worktrees. Transient rate limits (`RATE_LIMITED`) are handled separately and do NOT abort the batch.

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
4. Blocks without a `BODY:` section are discarded (prevents title-only stubs from becoming empty GitHub issues)
5. `_dedup_issues` runs after append

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

### Empty Body Guard (create_issues)

`create_issues()` validates that `current_body` is non-empty before calling `gh issue create`. If a `---ISSUE---` block has a TITLE but no BODY content, it's skipped with a warning. This is the last-resort safety net — the primary defense is the `BODY:` validation in `_validate_coverage` which discards bodyless blocks before they reach the issues file.

**Why this exists:** The freshup `rite plan` run produced a phantom-resolved issue with only a title — no acceptance criteria, no scope, no Claude Context. The phantom Claude call emitted the title but no `---ISSUE---` block structure. The block was appended (it had matching markers) but had no `BODY:` section, so `create_issues` created a GitHub issue with an empty description.

### Shared Item Permissions Rule

The plan prompt includes: "If an entity uses a shareability model and shared items are visible in read endpoints, non-destructive operations (consume, purchase) MUST also be accessible to any authenticated user." This prevents the recurring bug where consume endpoints defaulted to owner-only 404 while read endpoints correctly showed shared items.

---

## Review & Assessment (assess-review-issues.sh, assess-and-resolve.sh)

### Follow-up Issue Context

Follow-up issues from ACTIONABLE_LATER findings include:
- Primary finding title in the issue title (e.g., "[tech-debt] Rate limiting applies only at stage level, not per-user (from PR #124)"). Falls back to PR title context if no finding title is extractable.
- `**Location:**` field required for ACTIONABLE_LATER items (not just ACTIONABLE_NOW)
- PR title in the issue body

**Why finding-specific titles:** Generic titles like "review feedback from PR #N" contributed to false-completion failures — Claude saw existing related code matching the vague title and concluded work was done. Specific finding titles make the gap explicit.

**Why:** Issue #135 failed repeatedly because its body said "cross-user tests missing" without specifying which domain. Claude found tests in recipes/inventory and concluded "done." The grocery domain (which had zero tests) was never mentioned.

### Review Comment Filtering (CRITICAL)

All review comment queries MUST filter by body marker (`contains("<!-- sharkrite-local-review")`), NOT by author login. Author-based filtering (`.author.login == "claude"` etc.) picks up non-review comments (assessments, issue notifications) posted by the same authenticated user.

**Phase 2** (workflow-runner.sh `phase_create_pr`) and **Phase 3** (assess-and-resolve.sh) must use the same filter to agree on which comment is "the latest review." Filter mismatch causes Phase 2 to skip review regeneration while Phase 3 detects stale review → infinite reroute loop.

**Timestamp comparison:** Always use epoch seconds (`date "+%s"` with BSD/GNU detection), never bash string comparison (`[[ > ]]`) or jq string comparison. ISO 8601 lexicographic comparison works for identical formats but breaks silently on format differences (fractional seconds, timezone offsets).

**Why:** Freshup issue #231 hit a stale review loop — rerouted 2 times without generating a fresh review. Root cause: Phase 3 used a wider author-based filter that could pick up assessment comments, and Phase 2 used lexicographic string comparison for timestamps.

### LOW Severity Threshold

LOW findings only become ACTIONABLE_LATER if they represent a real functional or security concern. "Consider doing X" and style suggestions are DISMISSED. Added after 5 of 7 tech-debt issues were closed as noise (code aesthetics, hypothetical optimizations, intentional patterns flagged as problems).

### Project Context Calibration (RITE_PROJECT_CONTEXT)

Both the reviewer and assessor receive deployment context (`RITE_PROJECT_CONTEXT`) that describes the project's actual audience, scale, and deployment model. This context drives severity calibration at both stages:

1. **Reviewer** (`local-review.sh`): Injected as a "Deployment Context" section alongside CLAUDE.md project context. The reviewer calibrates severity *at the source* — a missing rate limiter on a localhost app gets LOW instead of HIGH.

2. **Assessor** (`assess-review-issues.sh`): Injected into the PROJECT CONTEXT section. The ACTIONABLE_LATER and DISMISSED criteria explicitly reference deployment context. Findings irrelevant to the project's actual context are DISMISSED with reasoning (e.g., "single-user localhost app — rate limiting adds no value").

**Why this exists:** Invoice-builder (single-user Electron+Flask desktop app) accumulated 6 open tech-debt issues from review assessments in one session — more than the original feature roadmap. Issues like "No Rate Limiting" (#82), "Inline Import" (#86), and "Missing Rate Limit Tests" (#87) were all MEDIUM findings that the assessor classified as ACTIONABLE_LATER because it had no context about the project's deployment model. With deployment context, these become DISMISSED.

**Design choice — context injection vs severity threshold:** Considered `RITE_FOLLOWUP_SEVERITY_THRESHOLD` (blind filter: drop all MEDIUM follow-ups). Rejected because it's imprecise — a MEDIUM finding about missing input validation on a public API is legitimate. The assessor already makes LATER/DISMISSED decisions; it just needs the information to make them well. Giving it deployment context preserves its judgment while eliminating noise.

**Configuration:** Set `RITE_PROJECT_CONTEXT` in `.rite/config`. Free-form text. No structured format required — the LLM interprets it naturally. Examples:
- `"Single-user desktop app (Electron + Flask). One developer. Localhost only."`
- `"Public-facing SaaS API. 50k daily active users. Deployed on AWS ECS. Team of 8."`
- `"Internal CLI tool. Used by 3 engineers on the infra team. No external consumers."`

**What it does NOT do:** This does not suppress findings from the review — it calibrates their severity. A reviewer seeing "single-user localhost app" will still flag missing rate limiting, but as LOW instead of MEDIUM/HIGH. The assessor then DISMISSES LOW items per the existing LOW severity threshold rule.

---

## Provider Agnosticism

### Core Principle

All prompts (review, assessment, planning, dev session) are provider-agnostic plain text. No prompt may contain provider-specific instructions (e.g., Claude's `/exit`, tool_use syntax, `--disallowedTools`). Provider-specific behavior is isolated in `lib/providers/<name>.sh` behind the interface defined in `provider-interface.sh`.

### Rules

- **Prompts are plain Markdown.** No JSON schema, no provider-specific commands, no tool syntax. The provider layer handles invocation format.
- **Provider-specific instructions go in preamble functions.** `provider_dev_session_preamble()` and `provider_exit_instructions()` inject provider-specific text. These are NOT part of the review/assessment prompts.
- **Model names are metadata, not prompt content.** `$EFFECTIVE_MODEL` appears in review metadata sections, never in instructional text.
- **Error patterns are provider-specific.** `provider_detect_error()` maps provider-specific error strings to generic types (RATE_LIMITED, AUTH_EXPIRED, NETWORK_ERROR, PROVIDER_BUG, UNKNOWN).
- **Tool restrictions are provider-specific.** `provider_build_tool_restrictions()` returns provider-native restriction specs. `provider_supports_tool_restrictions()` gates unsupervised mode.
- **Per-phase provider selection.** `RITE_DEV_PROVIDER`, `RITE_REVIEW_PROVIDER`, `RITE_UTILITY_PROVIDER` allow mixing providers across workflow phases.

### Testing a New Provider

1. Implement all 17 functions from `provider-interface.sh`
2. Start with `provider_run_prompt()` (text-in/text-out, simplest to verify)
3. Agentic sessions (`provider_run_agentic_session()`) require tool restriction support for unsupervised mode
4. Error detection patterns must map to the 5 generic error types

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

## Decisions Log

### Removed: Plan Directives System

Directives were persistent per-project rules injected into the plan prompt (e.g., "always use service layer"). Removed because the user preferred fixing sharkrite's generic behavior over per-project config. Replaced by: feedback persistence, service layer filesystem lint, and stronger prompt instructions.

### Rejected: ADR Modification for Deferrals

Considered appending deferrals to the source ADR on plan approval. Rejected because the deferrals log already serves this purpose and modifying ADRs adds noise to source-of-truth documents.

### Rejected: Keyword Matching for Deferral Detection

Tried extracting significant words from feature names and matching against the deferrals log in bash. Failed because natural language phrasing varies ("view" vs "endpoint" vs "query"). Replaced by passing deferrals to the phantom Claude call for semantic matching.

### Rejected: Multi-Exit-Code Interface for verify_post_merge

Initially implemented `verify_post_merge()` with exit codes 0 (pass), 1 (semantic conflict), 2 (dev-session bugs), 3 (main broken). Callers used `case` statements to handle each code differently. This broke immediately: `set -e` interactions, `|| exit=$?` capture failures, and — critically — callers that used the established `if ! verify_post_merge` pattern treated ALL non-zero returns as "merge failed" and reset HEAD, destroying dev work even for exit code 2 (dev bugs).

**Fix:** Collapsed to boolean: 0 = proceed, 1 = semantic conflict. All diagnostic intelligence (attribution, caching, issue creation) runs inside the function. Callers don't need to know why it returned 0.

**Rule:** When a function has an established boolean contract (`if !`), keep the interface boolean. Put complexity inside, not in the return code. A function that returns 4 exit codes is a function where 3 callers will get it wrong.

### Rejected: eval Injection Validation for Test Gate

Thresher (Gemini assistant) flagged `eval "$_test_cmd"` in `run_test_gate()` and `verify_post_merge()` as an injection risk. Evaluated and rejected as a false alarm:

1. **`RITE_TEST_CMD`** comes from `.rite/config` (repo-owner-controlled file, same trust level as `Makefile`) or environment variables.
2. **Auto-detected commands** are hardcoded strings: `"npm test"`, `"$_py_found -m pytest"`, `"make test"`. The only variable is `$_py_found`, which is a filesystem path verified by `[ -f "$_venv_base/bin/python" ]`.
3. **No user input** reaches `eval` — no HTTP requests, no GitHub issue bodies, no PR descriptions are interpolated into the test command.
4. Adding a validation layer would create false security (allowlisting command prefixes) while adding real complexity. The threat model is: someone who can write to `.rite/config` can already run arbitrary code via `Makefile`, `package.json` scripts, or pytest plugins.

**When eval IS dangerous:** When the string contains user-controlled input (form fields, issue bodies, filenames from untrusted sources). None of those apply here.
