# Exit Code Reference

Canonical table of all non-zero exit codes used by Sharkrite scripts.
Every script that **produces** or **consumes** a meaningful exit code should
reference this file in an inline comment.

---

## Cross-script signal codes

These codes cross script boundaries and must be kept unambiguous.

| Code | Producer | Consumer | Meaning |
|------|----------|----------|---------|
| `2`  | `stale-branch.sh` (`check_stale_branch`) | `workflow-runner.sh` stale-branch handler | Foreign commits detected after push rejection — re-enter Phase 2→3 review cycle |
| `5`  | `claude-workflow.sh`, `create-pr.sh`, `merge-pr.sh`, `stale-branch.sh`, `divergence-handler.sh`, `branch-preflight.sh` | `workflow-runner.sh`, `batch-process-issues.sh` | Usage/token cap reached — abort batch cleanly |
| `6`  | `merge-pr.sh` | `workflow-runner.sh`, `batch-process-issues.sh` | Merge succeeded but worktree/branch cleanup failed — work IS on remote |
| `10` | `batch-process-issues.sh` (exit) | Caller of `rite` batch | Batch completed with at least one blocker-deferred issue |
| `11` | `stale-branch.sh` (`check_stale_branch`) | `workflow-runner.sh` stale-branch handler, `claude-workflow.sh` stale-branch health path | Stale branch: PR closed, branch/worktree cleaned up, restart fresh — caller must reset all resume state variables |
| `12` | `workflow-runner.sh` (`handle_closed_issue` → `run_workflow`) | `batch-process-issues.sh` | Issue was already closed when the batch started — no new dev work done. `handle_closed_issue()` ran its full cleanup and printed the closure summary. `batch-process-issues.sh` skips the post-issue gh stat-gathering calls (pr list / pr view / issue list) and records the issue as `already_closed_at_start`. **Single-issue mode exits 0** (the closure summary was already printed; a non-zero exit would be surprising in `set -e` chains). **Batch mode exits 12** so `batch-process-issues.sh` can distinguish already-closed from active-work issues. |
| `13` | `workflow-runner.sh` (`verify_workflow_produced_work` → `run_workflow`) | `batch-process-issues.sh` | Post-phase invariant violated — all phases returned 0 but no work artifact (commit or PR) was produced. Protects against silent false-positive completions where a sourcing side-effect or phantom exit 0 bypassed real work. Batch and single-issue mode both treat this as a failure. Issue state is preserved; re-run after investigating the root cause. |

> **Why 10 and 11 are separate:**
> `batch-process-issues.sh` uses exit 10 for its own final exit when blocked
> issues exist (line ~852).  Inside the batch loop it also watches for exit 10
> from `workflow-runner.sh` (i.e. the blocker-detected path in
> `workflow-runner.sh` exits 10 back to batch, lines ~597) as a
> "blocker-detected — defer" signal.  `workflow-runner.sh`'s own `run_workflow`
> return table lists only 0/1/5/6 — the exit-10 path is the batch loop's own
> interpretation of the blocker condition, not a separate code emitted by
> `run_workflow` itself.  If `stale-branch.sh` also used 10, a healthy
> stale-branch restart could be mistaken for a blocker abort.  Exit 11 is
> reserved exclusively for the stale-restart signal so the two meanings can
> never collide.

---

## Per-script codes

### `assess-and-resolve.sh`

| Code | Meaning |
|------|---------|
| `0`  | Assessment complete — ready to merge |
| `1`  | Manual intervention needed (CRITICAL findings, unresolvable issues, or follow-up creation failure) |
| `2`  | Loop to fix — ACTIONABLE_NOW items remain, retry |
| `3`  | Review stale — route back to Phase 2 (re-review) |

> **Follow-up creation failure halts the merge.** If `gh issue create` fails during follow-up creation, the script
> saves items to `.rite/orphaned-followup-items.md`, emits an error, and exits `1` — even when no CRITICAL
> review findings exist.  Silently proceeding to merge when tracked items were lost would be a data-loss bug.
> Re-run `rite <issue> --assess-and-fix` after resolving the gh API issue to retry.

### `merge-pr.sh`

| Code | Meaning |
|------|---------|
| `0`  | Merge and cleanup succeeded |
| `1`  | Merge failed |
| `5`  | Usage cap reached during merge |
| `6`  | Merge succeeded but cleanup failed |

### `claude-workflow.sh`

| Code | Meaning |
|------|---------|
| `0`  | Session completed successfully |
| `1`  | Session failed |
| `3`  | Review stale (fix-review mode) |
| `4`  | Session completed but no work produced |
| `5`  | Usage/token cap reached |
| `127`| Provider CLI not found |

### `workflow-runner.sh` (return codes from `run_workflow`)

| Code | Meaning |
|------|---------|
| `0`  | Workflow completed successfully |
| `1`  | Workflow failed (generic) |
| `5`  | Usage cap — batch must abort |
| `6`  | Merge succeeded but cleanup failed |
| `12` | Issue was already closed at start — no new work done (batch should skip stat gathering) |
| `13` | Post-phase invariant violated — all phases returned 0 but no work artifact (commit or PR) was produced. Indicates a silent false-positive: a sourcing side-effect or phantom exit 0 bypassed real work. Batch treats this as a failure. Issue state is preserved for investigation. |

### `batch-process-issues.sh` (final process exit)

| Code | Meaning |
|------|---------|
| `0`  | All issues completed (or no issues run) |
| `1`  | All issues failed, none completed |
| `10` | Batch completed with at least one blocker-deferred issue |

### `stale-branch.sh` (`check_stale_branch` return)

| Code | Meaning |
|------|---------|
| `0`  | Branch current or successfully updated (rebase/merge) — continue |
| `1`  | Stale check failed (user aborted or error) |
| `2`  | Foreign commits detected after push rejection — caller must re-enter Phase 2→3 review cycle |
| `5`  | Usage cap during conflict resolution |
| `11` | PR closed and worktree cleaned up — restart fresh (caller resets resume state) |

### `branch-preflight.sh`

| Code | Meaning |
|------|---------|
| `0`  | Preflight passed |
| `3`  | Branch conflict — needs resolution |
| `4`  | No work produced |
| `5`  | Usage cap |

### `divergence-handler.sh`

| Code | Meaning |
|------|---------|
| `0`  | No divergence or divergence resolved |
| `1`  | Divergence detected (unresolved) |
| `2`  | Foreign commits require re-review (RELATED/UNRELATED classification) |
| `5`  | Usage cap during resolution |

### `review-assessment.sh`

| Code | Meaning |
|------|---------|
| `0`  | Assessment loaded successfully |
| `1`  | No assessment found |
| `3`  | Invalid assessment format |
