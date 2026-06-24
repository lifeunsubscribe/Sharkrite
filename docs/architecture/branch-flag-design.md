# Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow

**Status:** Design / pre-implementation
**Date:** 2026-06-23
**Provenance:** Generated via a multi-agent design workflow (5 parallel subsystem readers → synthesis). Every `file:line` below was verified against source at authoring time.

---

## 1. Summary

`rite N --branch feature-x` runs issue N through the normal lifecycle but merges its finished PR into **`feature-x`** instead of `main`. Many issues accumulate on `feature-x`; the user later promotes `feature-x` → `main` as one unit (see §8). `rite --status` reflects per-target-branch state.

The feature is mostly a **threading problem**, not a logic problem. The merge endpoint already merges into whatever base the PR was created with (`merge-pr.sh:463` reads `baseRefName` from the live API and `gh api .../merge` honors it). The work is:

1. Parse + propagate a target branch from `bin/rite` to PR creation.
2. Establish **one durable source of truth** for the target that survives a dev→merge time gap and batch mode.
3. Convert the ~30 hardcoded `origin/main` sites to target-aware **only where the semantics demand it**, leaving trunk-health sites pinned to main.

The single biggest risk is **§5 (hardcoded-main)**: the codebase pervasively assumes the integration base is `main`. Getting the BECOMES-TARGET / STAYS-MAIN partition wrong silently corrupts feature-branch worktrees with main's code.

**Cost asymmetry (read this first):** the *accumulation* half (sub-issues → X) is the expensive part — it needs the full §5 sweep because sub-PRs are based on X. The *promotion* half (X → main) is nearly free — that PR has `base=main`, exactly where the existing `origin/main` assumptions are already correct.

**Scope boundary (NOT this feature):**
- Creating `feature-x` if it doesn't exist on the remote (precondition — see §2.4).
- Arbitrary non-main *promotion* targets (X → some-other-branch). The promote path (§8) is scoped to `base=main`.

---

## 2. Source of Truth for the Target Branch

### 2.1 Decision: hybrid — per-issue local state file as the write-once Phase-1 source; PR `baseRefName` as ground truth once a PR exists

Neither alone is sufficient:

| Approach | Fails because |
|---|---|
| **`RITE_TARGET_BRANCH` env var only** | Doesn't survive the dev→later-merge gap (a resumed `rite N` hours later, flag omitted, loses it). In batch mode with two issues targeting different branches, last-writer-wins clobbers. Reject as the *sole* source. |
| **PR `baseRefName` only** | Unavailable during Phase 1 — there is no PR until `create-pr.sh` runs, yet the worktree must branch from `origin/feature-x` *before* the PR exists (`claude-workflow.sh:1914`). |
| **Local state file only** | Goes stale if a user changes the PR base via the GitHub UI. The API value is what GitHub *will actually merge into* — it must win once it exists. |

### 2.2 The resolution order (one helper, used everywhere)

Introduce `resolve_target_branch ISSUE_NUMBER [PR_NUMBER]` — all phases call it. Precedence (first hit wins):

1. **PR `baseRefName` via API** (if a PR exists) — ground truth. **Reuse the existing, validated `_stale_resolve_base_branch()`** (`stale-branch.sh:68-89`), which already queries `gh pr view --json baseRefName`, validates against `^[a-zA-Z0-9_./-]+$`, rejects `..`, and falls back to `main`. Do **not** write a second API reader (Redesign-Before-Patching: the validation invariant is already written).
2. **Local state file** `${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt` — written once in Phase 1. Survives the dev→merge gap and `rite N` re-invocations exactly like `worktree-handoff-N.txt`.
3. **`RITE_TARGET_BRANCH` env var** — set by `bin/rite` for the current process (covers the first Phase-1 write).
4. **`main`** — default.

### 2.3 Why the state file (not env var) is the per-issue carrier

- **Per-issue keying** (`target-branch-N.txt`) eliminates the batch last-writer-wins problem — each issue owns its file.
- **Write site already exists and is proven:** `claude-workflow.sh:2024` already writes `worktree-handoff-N.txt` to `RITE_STATE_DIR` right after worktree creation. Write `target-branch-N.txt` in the same place, same moment. **Must use `RITE_STATE_DIR` (absolute), not a relative path** — cwd changes into the worktree immediately after (`claude-workflow.sh:~2015`).
- **Cleanup obligation:** these files are not proactively cleaned. `--undo`/close **must** `rm -f "${RITE_STATE_DIR}/target-branch-${N}.txt"` or we leak (Chunk 5).

### 2.4 Underspecified / risky — call-outs

- **Branch must pre-exist.** If `origin/feature-x` doesn't exist, `claude-workflow.sh:1914`'s `git rev-parse --verify origin/feature-x` silently falls through to `HEAD`. For a target branch that should be a **hard error** — add a preflight in `bin/rite` (`git ls-remote --exit-code --heads origin "$BRANCH_FILTER"`) that fails fast before any LLM work. (Silent-Recovery-Over-Bailout does *not* apply: we cannot invent the user's intended base — bail loudly, don't auto-create.)
- **PR base mutation after creation.** No mechanism exists to change an existing PR's base. If a resumed run resolves a *different* target than the PR was created with, **the PR's `baseRefName` wins** and we log a WARNING; we do not silently rebase the PR base. Out of scope.
- **Mixed targets in one command** are not supported — all issues in one `--branch` invocation share the value; each then persists its own file. Document it.

---

## 3. Flag Parsing & Propagation

### 3.1 `bin/rite` (the `--label` analog)

`--label` is the exact template — a value-taking flag using `shift 2` at `bin/rite:139-142`:

```bash
--label)
  BATCH_FILTER_ARGS=("--label" "$2")
  shift 2
  ;;
```

**Edits:**

1. **Declare** alongside the filter vars at `bin/rite:59-62`: `BRANCH_FILTER=""`.
2. **Parse** immediately after the `--label)` case:
   ```bash
   --branch)
     BRANCH_FILTER="$2"
     shift 2
     ;;
   ```
3. **Validate + export** (after the parse loop, colocated with the §2.4 preflight): when `BRANCH_FILTER` is non-empty, `git ls-remote --exit-code --heads origin "$BRANCH_FILTER"` then `export RITE_TARGET_BRANCH="$BRANCH_FILTER"`. The env var is only a *default seed*; the per-issue state file is the durable carrier. Leak concern mitigated by name-scoping and by consumers always resolving through `resolve_target_branch`, never reading the env var raw.

### 3.2 Propagation through the three routing exits

`bin/rite` dispatches three ways — **all three** must carry the target:

| Exit | Line | Required |
|---|---|---|
| Single-issue full | `bin/rite:1031/1033` | Append `--base "$BRANCH_FILTER"` (when set). `RITE_TARGET_BRANCH` is also exported, so resume-from-state works. |
| Batch / `--label` | `bin/rite:1020` | **PARITY GAP** — this exec forwards `BATCH_FILTER_ARGS`+`ARGS` only, *not* `WORKFLOW_FLAGS`. **Recommendation: rely on the exported `RITE_TARGET_BRANCH`** (env survives exec); add a regression test asserting the batch path sees the target (§6.1). |
| `--dev-and-pr` standalone | `bin/rite:1039-1041` | Pass `--base "$BRANCH_FILTER"` to the direct `create-pr.sh` call at `:1040` (or rely on the env default in `create-pr.sh:38`). |

### 3.3 `workflow-runner.sh` flag parser

`main()`'s parser at `workflow-runner.sh:2730-2747` errors on unknown flags (`*)` → `exit 1` at :2742). Add a `--base)` case that sets+exports `RITE_TARGET_BRANCH` (mind the loop's trailing bare `shift` — a value-taking flag needs its own extra `shift`). If `--base` is omitted but `target-branch-N.txt` exists, the resolver still recovers it — this closes the resume gap.

---

## 4. Merge Changes (set base at creation, merge into target)

The merge target is fixed **at PR creation**, not at merge time.

### 4.1 Set the PR base at creation

- `create-pr.sh:38` — default `BASE_BRANCH="main"` → `BASE_BRANCH="${RITE_TARGET_BRANCH:-main}"`. The `--base` parser at `create-pr.sh:46-49` already overrides it.
- `workflow-runner.sh:1089` and `:1091` (`phase_create_pr` → `$CREATE_PR`) — append `--base "$(resolve_target_branch "$ISSUE_NUMBER")"`. **Primary hook.**
- **Fix-loop create-pr call** (~`workflow-runner.sh:1325`) and **`--dev-and-pr`** (`bin/rite:1040`) — both must also pass `--base`, or the non-main target is silently dropped. Grep every `$CREATE_PR` / `create-pr.sh` invocation and thread `--base` (or confirm the `:38` env default covers it). Multi-site invariant → lint-enforced (§6.4).

### 4.2 Merge into the target

- `merge-pr.sh:463` — already reads `baseRefName`; the `gh api .../merge` call merges into it. **No change to the merge invocation.**
- `merge-pr.sh:1055-1068` (fast-forward-after-merge) — **hardcodes `main`** three times (worktree scan, `git pull --ff-only origin main`, `git fetch origin main:main`). **Decision: keep the local-`main` fast-forward (STAYS-MAIN) AND additionally fast-forward `$PR_BASE`** when `$PR_BASE != main`, using a cwd-safe `(cd "$path" && …)` subshell (mirror `:1056-1057`). The user cares about `feature-x` currency, not only `main`.

### 4.3 Conflict-resolution paths (BECOMES-TARGET)

`merge-pr.sh:517`, `:798`, `:822` each do `git merge origin/main` recovery. For a non-main target these merge the **wrong upstream**. All three → `git merge "origin/$PR_BASE"` (and paired `fetch origin main` → `fetch origin "$PR_BASE"`). `PR_BASE` is in scope at all three.

---

## 5. The Hardcoded-main Problem (HARDEST PART)

Exhaustive partition. **Getting a STAYS-MAIN site wrong is worse than a BECOMES-TARGET miss** — it injects trunk code into a feature worktree silently.

### 5.1 STAYS-MAIN — pinned to `main` regardless of PR target

| Site | Why it stays main |
|---|---|
| `merge-pr.sh:1055-1068` local-`main` fast-forward | Trunk housekeeping. *(But add a parallel `$PR_BASE` ff per §4.2.)* |
| `post-merge-verify.sh:181`, `:368` `worktree add origin/main` | Tests **the trunk** — the whole point is "did we break main." |
| `repo-status.sh:113-114`, `:169-170` `merge-base HEAD origin/main` | **Display** of how far behind *trunk* each worktree is (see §5.3). |
| `divergence-handler.sh:167` `--not origin/main` in `classify_foreign_commits` | Classifying "what is already on trunk" is inherently main-relative. |
| `undo-workflow.sh:307-311` `push origin/main:refs/heads/$BRANCH` | Undo resets a branch to *trunk HEAD*. ⚠️ For a non-main target this resets the feature branch to main's HEAD — acceptable for v1 **only if** `--undo` also removes the worktree+branch (fresh start re-branches from target). Document. |
| `undo-workflow.sh:429-432` `checkout main` + `merge --ff-only origin/main` | Restores the developer's *shell* to trunk after cleanup. |
| The eventual `feature-x` → `main` promotion | Out of scope by definition — that PR's base *is* main. |

### 5.2 BECOMES-TARGET — must use the resolved base

**PR creation / base:** `create-pr.sh:38`; `create-pr.sh:95` (`== "main"` guard — verify the target should be added to this "don't run on the base branch" check); `claude-workflow.sh:2209` draft PR `--base main`; `trivial-fix-fastpath.sh:228` `gh pr create --base main`.

**Worktree creation (branch point) — HIGH BLAST RADIUS:** `claude-workflow.sh:1914-1919` (`_base_ref="origin/main"`) and `:1936-1940` (retry). If wrong, **every** downstream `origin/main...HEAD` diff is wrong. → `origin/${RITE_TARGET_BRANCH:-main}`. Also `trivial-fix-fastpath.sh:127` (`fetch origin main`), `:133`.

**Defensive pre-dev merge — HIGH BLAST RADIUS:** `claude-workflow.sh:2062-2093` (`fetch origin main` + `merge origin/main` at the start of *every* dev session). For a `release/*` branch this silently mixes `main` in.

**File-change / skip-dev / zero-work diffs (`origin/main...HEAD`):** `workflow-runner.sh:755, :814, :987, :2251, :2383, :2672`; `claude-workflow.sh:1211-1212, :1696-1697, :1773-1774, :2144-2145, :2675-2676, :2703-2704`. Cosmetic/diag ones (`claude-workflow.sh:668-704, :2547-2551, :2936-2939`) are low-risk but convert for consistency.

**No-PR resume update — 3 sites:** `workflow-runner.sh:2304` (`fetch origin main`), `:2306` (`rev-list HEAD..origin/main`), `:2311` (`merge origin/main`). Runs when `PR_NUMBER` is empty, so the API resolver can't help — **must** read the state file / env (§2 tier 2/3).

**Mid-run rebase — entirely unparameterized:** `mid-run-rebase.sh:96, :104, :112, :135, :178-200`. Every check/rebase is against `origin/main` with **no base param**. **Must add a `base_branch` parameter** threaded from the `workflow-runner.sh` caller.

**Conflict resolver default:** `conflict-resolver.sh:86` `_cr_merge_target="origin/main"`. `divergence-handler.sh` callers already pass `--merge-target origin/$branch`, but **`stale-branch.sh` callers use the positional form and never override it** → have them pass `--merge-target "origin/$_STALE_BASE_BRANCH"`.

**Merge recovery paths:** `merge-pr.sh:517, :798, :822` (see §4.3).

**Test-gate diff base:** `test-gate.sh:724` (`RITE_TEST_GATE_DIFF_BASE:-origin/main`); `workflow-runner.sh:2487` overrides it only in the autofix prepass, not the main gate runs. **Set `RITE_TEST_GATE_DIFF_BASE=origin/<target>` before all gate invocations in `run_workflow`.** (`stale-branch.sh:70` cold-start fallback `main` → `${RITE_TARGET_BRANCH:-main}`.)

**Scope checker:** `scope-checker.sh:204-205` `origin/main...HEAD`.

**Already-correct (reuse, no change):** `stale-branch.sh:68-89` + `:100-113` `get_commits_behind_main` (takes `BASE_BRANCH` as `$2`); only the cold-start literal `main` at `:70` → `${RITE_TARGET_BRANCH:-main}`. `workflow-runner.sh:372-374` shrinkage `_revert_base` is already parameterized — just seed `SHRINKAGE_BLOCKER_BASE_BRANCH` from the resolved target.

### 5.3 Nuance: `repo-status.sh` "behind" column

`scan_worktrees` (`:113-114/:169-170`) has no PR data — keep it main-relative (STAYS-MAIN). The target-aware "behind feature-x" number, if wanted, belongs in the worktree-details loop (`:731+`) where `open_prs_json` (now carrying `baseRefName`) resolves the PR base. **v1: keep the single behind-main column and add a `→ feature-x` annotation** rather than a second behind-count.

### 5.4 Threading mechanism

**Recommendation: env-var (`RITE_TARGET_BRANCH`, exported once in `bin/rite`) as the transport, `resolve_target_branch` as the single read-path.** Every BECOMES-TARGET site calls the resolver (or reads a `base_branch` it was passed) — **no site reads `origin/main` literally anymore.** One resolver, lint-enforced (§6.4), instead of N scattered correct-by-inspection edits.

---

## 6. Contracts & Safety

### 6.1 Batch ↔ Single-Issue Parity

The target reaches both paths via one chokepoint (`resolve_target_branch` inside `run_workflow`): single-issue via `--base`/env, batch via the exported `RITE_TARGET_BRANCH` (survives the `bin/rite:1020` exec). The state file is per-issue, so no shared mutable state. **New regression test** in `tests/regression/batch-single-issue-parity.bats`: assert the `--base` reaching `create-pr.sh` is identical in single-issue and batch dispatch. Any batch short-circuit needs the `# Deliberate divergence from single-issue mode:` comment.

### 6.2 cwd-after-worktree-removal

Unaffected: `cd "$MAIN_WORKTREE"` (`merge-pr.sh:1091`) and `cd "$RITE_PROJECT_ROOT"` (`phase_merge_pr`) reference neither `main` nor the target. **One new caution:** the §4.2 added `$PR_BASE` fast-forward must run before worktree removal *or* use a `(cd …)` subshell — never assume cwd is a live worktree.

### 6.3 Re-source Safety

- `resolve_target_branch` (new) lives beside `_stale_resolve_base_branch` in `stale-branch.sh` (or `config.sh`) — gate with the standard `declare -f resolve_target_branch >/dev/null 2>&1 && return 0`.
- `RITE_TARGET_BRANCH` default in `config.sh` uses idempotent `="${RITE_TARGET_BRANCH:-}"` and is exported in the Step-6 block — re-source-safe (no `readonly`).
- `merge-pr.sh:62` `BASE_BRANCH="main"` → idempotent `="${BASE_BRANCH:-main}"` (low priority).
- **No relative paths for the state file** — always `"${RITE_STATE_DIR}/target-branch-${N}.txt"`.

### 6.4 Deterministic backstop — the lint rule

The dangerous failure mode is a *missed* `origin/main` literal that should have been target-aware. Don't rely on review for ~30 sites. **Add `RAW_ORIGIN_MAIN_REF`** to `tools/sharkrite-lint.sh`: flag literal `origin/main` in the BECOMES-TARGET files; require either the resolver call or an inline `# sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: trunk-health, intentionally main` on each STAYS-MAIN exception. This makes "did the engineer remember every site?" a CI gate, and the suppression comments document the partition inline (No-Env-Var-Escape-Hatches: inline marker, not an env toggle).

---

## 7. Phased Breakdown

Six chunks, dependency-ordered, each ≤2hr (runbook cap), each a `rite plan` issue. **TIGHTLY-COUPLED** = same files / shared parity contract; **SEPARABLE** = independently landable.

**Chunk 1 — Flag parsing + resolver + state file** `[FOUNDATION]`
`bin/rite`: declare `BRANCH_FILTER`, parse `--branch`, pre-exist preflight + `export RITE_TARGET_BRANCH`. `config.sh`: default + export. New `resolve_target_branch` (reuses `_stale_resolve_base_branch`); state-file write in `claude-workflow.sh:2024`. `workflow-runner.sh:2730-2747`: `--base` case. Tests: resolver precedence; absolute `RITE_STATE_DIR`; re-source-twice clean. **TIGHTLY-COUPLED** with Chunk 2. **Land first.**

**Chunk 2 — Propagation through all three exits + PR base at creation** `[CORE]`
`bin/rite` threading (`:1031/1033`, `:1020` via env, `:1040`); `create-pr.sh:38` default; `workflow-runner.sh:1089/1091` + fix-loop (~`:1325`) pass `--base`; `claude-workflow.sh:2209` + `trivial-fix-fastpath.sh:228` draft-PR base. Tests: correct `baseRefName` in single+batch+dev-and-pr; **parity test** (§6.1). **TIGHTLY-COUPLED** with Chunk 1. **Follows Chunk 1.**

**Chunk 3 — Hardcoded-main, dev-side** `[HARDCODED-MAIN]`
`claude-workflow.sh` worktree base (`:1914-1919`, `:1936-1940`), pre-dev merge (`:2062-2093`), all `origin/main...HEAD` diffs; `workflow-runner.sh` skip-dev/zero-work diffs + no-PR resume (`:2304-2311`) + test-gate base; `trivial-fix-fastpath.sh:127/133`; `scope-checker.sh:204-205`. **TIGHTLY-COUPLED** with Chunk 4. Depends on Chunk 1.

**Chunk 4 — Hardcoded-main, merge-side** `[HARDCODED-MAIN]`
`merge-pr.sh` conflict merges (`:517, :798, :822`) + fast-forward (`:1055-1068`, add `$PR_BASE` ff) + `:62` idempotent; `mid-run-rebase.sh:96-200` add `base_branch` param threaded from caller; `conflict-resolver.sh` via `stale-branch.sh` callers + cold-start fallback. **TIGHTLY-COUPLED** with Chunk 3. Depends on Chunk 1.

**Chunk 5 — Status reflection + state-file cleanup** `[SEPARABLE]`
`repo-status.sh`: `baseRefName` in PR fetches (`:447`, `:668`); `→ <target>` annotation / `--by-branch` grouping; keep `scan_worktrees` behind-main (§5.3). `--undo`/close: `rm -f target-branch-${N}.txt`. Tests: per-target annotation; cleanup; update `gh pr list` stubs for the new field. **SEPARABLE** — depends only on Chunk 1. Can land in parallel with 3/4.

**Chunk 6 — Lint rule `RAW_ORIGIN_MAIN_REF` + STAYS-MAIN suppressions** `[SEPARABLE, hardening]`
`tools/sharkrite-lint.sh`: new rule + inline suppressions on every STAYS-MAIN site (§5.1). Tests in `tests/lint/` (with #462 coverage header). **Land LAST** — after 3+4 convert the BECOMES-TARGET sites, else CI fails on not-yet-converted sites.

### Dependency graph

```
Chunk 1 (foundation: parse + resolver + state file)
  ├─> Chunk 2 (propagation + PR base)          [TIGHTLY-COUPLED with 1]
  ├─> Chunk 3 (hardcoded-main: dev-side)        [TIGHTLY-COUPLED with 4]
  ├─> Chunk 4 (hardcoded-main: merge-side)      [TIGHTLY-COUPLED with 3]
  └─> Chunk 5 (status + cleanup)                [SEPARABLE]
Chunk 6 (lint backstop)  ── land LAST, after 3+4 ── [SEPARABLE, ordering-sensitive]
```

### Top risks (ranked)

1. **Worktree branch-point (`claude-workflow.sh:1914`) + pre-dev merge (`:2062-2093`)** — wrong base silently mixes `main` into a `release/*` worktree and corrupts every downstream diff. Highest blast radius.
2. **`mid-run-rebase.sh`** — fully unparameterized parallel path; easy to forget.
3. **Three `create-pr.sh` call sites** — miss one and the *PR that matters* targets main. Lint rule (Chunk 6) is the guard.
4. **No-PR resume block (`workflow-runner.sh:2304-2311`)** — runs when no PR exists, so the API resolver can't help; depends entirely on state-file/env resolution.
5. **Batch parity via env** — verify the exported `RITE_TARGET_BRANCH` survives the `bin/rite:1020` exec in a test.
6. **`--undo` resets to `origin/main` (`undo-workflow.sh:307-311`)** — for a non-main target, a re-run after partial `--undo` starts from the wrong base unless the worktree+branch are also removed.
7. **State-file leak** — the `worktree-handoff-N.txt` precedent shows these aren't cleaned; the Chunk 5 cleanup is mandatory.

---

## 8. Promote-to-Main Trigger (X → main)

**Recommendation: Option A — the standing integration PR.** Let a normal X→main PR (`create-pr.sh --base main`, the default) be the signal. Branch X accumulates commits over time; when ready, it merges through the exact path everything else uses (non-draft + no unresolved CRITICAL → `assess-and-resolve.sh` exit 0 → `merge-pr.sh` squash + local-main fast-forward). No new vocabulary, no model judgment — a merged PR is an unambiguous, idempotent fact, inspectable in the GH UI and `rite --status`. The "may carry many commits and could conflict" requirement is already handled by `stale-branch.sh::_stale_resolve_base_branch` (API base resolution) + `divergence-handler.sh`/`conflict-resolver.sh` (Claude-assisted conflict resolution) + `merge-pr.sh`'s three retry paths — the most battle-tested surface in the repo.

**Optional ergonomic layer (if an explicit verb is wanted):** a thin `rite --promote <branch>` (same `shift 2` parsing as `--label`) that does nothing more than (a) ensure the X→main PR exists (`create-pr.sh --base main`, or `gh pr edit --base main` to re-target — a command present in-codebase for `--body`, never yet used for `--base`), then (b) hand off to the Option A path. **Scope strictly to `base=main`:** do NOT generalize to arbitrary non-main promote targets — the ~30 §5 sites are correct only when the base is main; a true arbitrary-target promote is the separate, larger accumulation redesign above.

**Rejected alternatives:**
- **`ready-for-main` label on a tracking issue** — labels are idiomatic and deterministic, but rite's label→work pipeline assumes label-classified *issues rite itself opened* (`Closes #N`), whereas an integration branch is branch-centric and usually issue-less; it also misuses the issue-*classification* axis for a *branch-merge-readiness* meaning, and `batch-process-issues.sh` runs the full dev/review/assess workflow (would need a new "merge-only" lane). Solves only the *signal*, still needs Option A's mechanics underneath.
- **`rite --promote` as a full new orchestrator** (vs the thin shim above) — largest new surface; must replicate the resume/cwd/lock/exit-code contracts; breaks rite's uniform issue-number-keyed identity (locks, session state, status are all keyed by issue number); the signal is ephemeral (no persisted "I asked to promote X" to resume from).
- **`.rite/state/promote-<branch>.flag`** — fits the persistence/determinism conventions, but state files are *rite-authored internal plumbing*, not user-authored inputs; invisible to `rite --status` and the GH UI; edges toward the disfavored escape-hatch pattern; stale-flag leakage could trigger an unwanted re-merge.
