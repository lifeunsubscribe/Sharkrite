# Exit Code Reference

Canonical table of all non-zero exit codes used by Sharkrite scripts.
Every script that **produces** or **consumes** a meaningful exit code should
reference this file in an inline comment.

---

## Cross-script signal codes

These codes cross script boundaries and must be kept unambiguous.

| Code | Producer | Consumer | Meaning |
|------|----------|----------|---------|
| `5`  | `claude-workflow.sh`, `create-pr.sh`, `merge-pr.sh`, `stale-branch.sh`, `divergence-handler.sh`, `branch-preflight.sh` | `workflow-runner.sh`, `batch-process-issues.sh` | Usage/token cap reached — abort batch cleanly |
| `6`  | `merge-pr.sh` | `workflow-runner.sh`, `batch-process-issues.sh` | Merge succeeded but worktree/branch cleanup failed — work IS on remote |
| `10` | `batch-process-issues.sh` (exit) | Caller of `rite` batch | Batch completed with at least one blocker-deferred issue |
| `11` | `stale-branch.sh` (`check_stale_branch`) | `workflow-runner.sh` stale-branch handler, `claude-workflow.sh` stale-branch health path | Stale branch: PR closed, branch/worktree cleaned up, restart fresh — caller must reset all resume state variables |

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
| `1`  | Manual intervention needed (CRITICAL findings, unresolvable issues) |
| `2`  | Loop to fix — ACTIONABLE_NOW items remain, retry |
| `3`  | Review stale — route back to Phase 2 (re-review) |

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
| `5`  | Usage cap during resolution |

### `review-assessment.sh`

| Code | Meaning |
|------|---------|
| `0`  | Assessment loaded successfully |
| `1`  | No assessment found |
| `3`  | Invalid assessment format |
