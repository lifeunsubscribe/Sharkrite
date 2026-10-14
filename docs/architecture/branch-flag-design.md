# Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow

**Status:** Final — design closed per 2026-07 rulings. The `--branch` / `--promote` / `--sync` cluster (#1031–#1052) is implemented; cherry-pick promote (#1051) is designed but not yet shipped (promote orchestrator shipped in #1047/#1050). See the [phase-integration-branches issue list](https://github.com/lifeunsubscribe/Sharkrite/issues?q=is%3Aissue+label%3Aphase-integration-branches) for open cleanup items.
**Date:** 2026-06-23 (design) / 2026-07-07 (rulings finalized)
**Provenance:** Generated via a multi-agent design workflow (5 parallel subsystem readers → synthesis). Every `file:line` below was re-verified against source at ruling time (2026-07-07) and again at worktree creation (2026-10-11).

---

## 1. Summary

`rite N --branch feature-x` runs issue N through the normal lifecycle but merges its finished PR into **`feature-x`** instead of `main`. Many issues accumulate on `feature-x`; the user later promotes `feature-x` → `main` as one unit (see §8). `rite --status` reflects per-target-branch state including a dedicated **Integration branches** section (§5.3, #1046).

The feature is mostly a **threading problem**, not a logic problem. The merge endpoint already merges into whatever base the PR was created with (`merge-pr.sh:624` reads `baseRefName` from the live API via `gh pr view` and `merge-pr.sh:641` assigns it to `PR_BASE`; the `gh api .../merge` call honors it). The work is:

1. Parse + propagate a target branch from `bin/rite` to PR creation.
2. Establish **one durable source of truth** for the target that survives a dev→merge time gap and batch mode.
3. Convert the ~30 hardcoded `origin/main` sites to target-aware **only where the semantics demand it**, leaving trunk-health sites pinned to main.

The single biggest risk is **§5 (hardcoded-main)**: the codebase pervasively assumes the integration base is `main`. Getting the BECOMES-TARGET / STAYS-MAIN partition wrong silently corrupts feature-branch worktrees with main's code.

**Cost asymmetry (read this first):** the *accumulation* half (sub-issues → X) is the expensive part — it needs the full §5 sweep because sub-PRs are based on X. The *promotion* half (X → main) is nearly free — that PR has `base=main`, exactly where the existing `origin/main` assumptions are already correct.

**Scope boundary (NOT this feature):**
- Arbitrary non-main *promotion* targets (X → some-other-branch). The promote path (§8) is scoped to `base=main`.

---

## 2. Source of Truth for the Target Branch

### 2.1 Decision: hybrid — per-issue local state file as the write-once Phase-1 source; PR `baseRefName` as ground truth once a PR exists

Neither alone is sufficient:

| Approach | Fails because |
|---|---|
| **`RITE_TARGET_BRANCH` env var only** | Doesn't survive the dev→later-merge gap (a resumed `rite N` hours later, flag omitted, loses it). In batch mode with two issues targeting different branches, last-writer-wins clobbers. Reject as the *sole* source. |
| **PR `baseRefName` only** | Unavailable during Phase 1 — there is no PR until `create-pr.sh` runs, yet the worktree must branch from `origin/feature-x` *before* the PR exists (`claude-workflow.sh:2638`). |
| **Local state file only** | Goes stale if a user changes the PR base via the GitHub UI. The API value is what GitHub *will actually merge into* — it must win once it exists. |

### 2.2 The resolution order (one helper, used everywhere)

Introduce `resolve_target_branch ISSUE_NUMBER [PR_NUMBER]` (`stale-branch.sh:186`) — all phases call it. Precedence (first hit wins):

1. **PR `baseRefName` via API** (if a PR exists) — ground truth. **Reuse the existing, validated `_stale_resolve_base_branch()`** (`stale-branch.sh:116`), which already queries `gh pr view --json baseRefName`, validates against `^[a-zA-Z0-9_./-]+$`, rejects `..`, and falls back to `main`. Do **not** write a second API reader (Redesign-Before-Patching: the validation invariant is already written).
2. **Local state file** `${RITE_STATE_DIR}/target-branch-${ISSUE_NUMBER}.txt` — written once in Phase 1 (`claude-workflow.sh:2756`). Survives the dev→merge gap and `rite N` re-invocations exactly like `worktree-handoff-N.txt`.
3. **`RITE_TARGET_BRANCH` env var** — set by `bin/rite` for the current process (covers the first Phase-1 write).
4. **`main`** — default.

### 2.3 Why the state file (not env var) is the per-issue carrier

- **Per-issue keying** (`target-branch-N.txt`) eliminates the batch last-writer-wins problem — each issue owns its file.
- **Write site already exists and is proven:** `claude-workflow.sh:2748` already writes `worktree-handoff-N.txt` to `RITE_STATE_DIR` right after worktree creation. `target-branch-N.txt` is written in the same block (`claude-workflow.sh:2756`). **Must use `RITE_STATE_DIR` (absolute), not a relative path** — cwd changes into the worktree immediately after.
- **Cleanup obligation:** these files are not proactively cleaned. `--undo`/close **must** `rm -f "${RITE_STATE_DIR}/target-branch-${N}.txt"` or we leak (Chunk 5).

### 2.4 Underspecified / risky — call-outs

- **Branch pre-existence — RESOLVED (2026-07-07 ruling).** A branch missing on `origin` is **auto-created from `origin/main`** with a single `print_info` line. The preflight (`bin/rite:1682` → `ensure_target_branch_exists`) handles this: if `git ls-remote --heads origin "$BRANCH"` returns nothing, it pushes a fresh branch from `origin/main` and prints one informational line. Silent-Recovery-Over-Bailout applies here because we *can* invent the correct base (it is always `origin/main` for a brand-new integration branch). The exit-19 mismatch block described next is scoped to **issue↔branch mismatch ONLY — never to branch non-existence.**

- **PR base mismatch — RESOLVED (2026-07-07 ruling, implemented by #1044).** If a resumed run resolves a *different* target than the PR was created with, this is a **hard stop** (exit code 19). `workflow-runner.sh::handle_branch_mismatch` prints a verbose block that includes the exact corrected command (`rite N --branch <correct-branch>`) and exits 19. In batch mode, the issue is recorded with a `branch_mismatch` SKIPPED class and the batch continues. Exit 19 is not yet documented in `docs/architecture/exit-codes.md` — the row is missing and tracked separately.

- **Mixed targets in one command** are not supported — all issues in one `--branch` invocation share the value; each then persists its own file. Document it.

---

## 3. Flag Parsing & Propagation

### 3.1 `bin/rite` (the `--label` analog)

`--label` is the exact template — a value-taking flag using `shift 2` at `bin/rite:155-159`:

```bash
--label)
  BATCH_FILTER_ARGS=("--label" "$2")
  shift 2
  ;;
```

**Shipped implementation (as of #1033):**

1. **Parse** the `--branch)` case (around `bin/rite:184`): validates `$2` non-empty and no whitespace, then `export RITE_TARGET_BRANCH="$2"` and `WORKFLOW_FLAGS+=("--base" "$2")`.
   ```bash
   --branch)
     export RITE_TARGET_BRANCH="$2"
     WORKFLOW_FLAGS+=("--base" "$2")
     shift 2
     ;;
   ```
2. **Validate + auto-create** (after the dispatch key is determined, `bin/rite:1682`): when `RITE_TARGET_BRANCH` is non-main, `ensure_target_branch_exists "$RITE_TARGET_BRANCH"` auto-creates the branch from `origin/main` with a `print_info` if absent. The env var is only a *default seed*; the per-issue state file is the durable carrier. Leak concern mitigated by name-scoping and by consumers always resolving through `resolve_target_branch`, never reading the env var raw.

### 3.2 Propagation through the three routing exits

`bin/rite` dispatches three ways — **all three** must carry the target:

| Exit | Required |
|---|---|
| Single-issue full | `WORKFLOW_FLAGS` includes `--base "$RITE_TARGET_BRANCH"`. `RITE_TARGET_BRANCH` is also exported, so resume-from-state works. |
| Batch / `--label` | Relies on the exported `RITE_TARGET_BRANCH` (env survives exec); regression test asserts the batch path sees the target (§6.1). |
| `--dev-and-pr` standalone | Pass `--base "$RITE_TARGET_BRANCH"` to the direct `create-pr.sh` call (or rely on the env default in `create-pr.sh:38`). |

### 3.3 `workflow-runner.sh` flag parser

`main()`'s parser errors on unknown flags. A `--base)` case sets+exports `RITE_TARGET_BRANCH` (mind the loop's trailing bare `shift` — a value-taking flag needs its own extra `shift`). If `--base` is omitted but `target-branch-N.txt` exists, the resolver still recovers it — this closes the resume gap.

---

## 4. Merge Changes (set base at creation, merge into target)

The merge target is fixed **at PR creation**, not at merge time.

### 4.1 Set the PR base at creation

- `create-pr.sh:38` — `BASE_BRANCH=""` (empty sentinel); the resolver fills it after the arg loop when not set by `--base`.
- `workflow-runner.sh` `phase_create_pr` call — appends `--base "$(resolve_target_branch "$ISSUE_NUMBER")"`. **Primary hook.**
- **Fix-loop create-pr call** and **`--dev-and-pr`** — both must also pass `--base`, or the non-main target is silently dropped. Grep every `$CREATE_PR` / `create-pr.sh` invocation and thread `--base` (or confirm the `:38` env default covers it). Multi-site invariant → lint-enforced (§6.4).

### 4.2 Merge into the target

- `merge-pr.sh:624` / `:641` — `gh pr view --json ... baseRefName` and `PR_BASE=$(... .baseRefName)`. The `gh api .../merge` call merges into it. **No change to the merge invocation.**
- `merge-pr.sh:1332-1355` (STAYS-MAIN local-`main` fast-forward) — **keep as trunk housekeeping.** The STAYS-MAIN comment block at `:1332-1337` documents this invariant inline.
- `merge-pr.sh:1357+` (BECOMES-TARGET parallel fast-forward) — when `$PR_BASE != main`, also fast-forward `$PR_BASE` locally so the user's checkout of the integration branch reflects the merge without a manual pull. Uses a cwd-safe `(cd …)` subshell.

### 4.3 Conflict-resolution paths (BECOMES-TARGET)

`merge-pr.sh:727`, `:1008`, `:1032` each do `git merge "origin/$PR_BASE"` recovery (already target-parameterized). `PR_BASE` is in scope at all three. Paired `fetch origin main` → `fetch origin "$PR_BASE"` at the same sites.

---

## 5. The Hardcoded-main Problem (HARDEST PART)

Exhaustive partition. **Getting a STAYS-MAIN site wrong is worse than a BECOMES-TARGET miss** — it injects trunk code into a feature worktree silently.

### 5.1 STAYS-MAIN — pinned to `main` regardless of PR target

| Site | Why it stays main |
|---|---|
| `merge-pr.sh:1332-1355` local-`main` fast-forward | Trunk housekeeping. *(But add a parallel `$PR_BASE` ff per §4.2 at `:1357+`.)* |
| `post-merge-verify.sh` `worktree add origin/main` | Tests **the trunk** — the whole point is "did we break main." |
| `repo-status.sh` `behind_main_count` helper | **Display** of how far behind *trunk* each worktree is (see §5.3). `behind_main_count` is the single authoritative copy of the behind-main math; replaces two former inline copies in `scan_worktrees`. |
| `divergence-handler.sh:173` `--not origin/main` in `classify_foreign_commits` | Classifying "what is already on trunk" is inherently main-relative. |
| `undo-workflow.sh` `push origin/main:refs/heads/$BRANCH` | Undo resets a branch to *trunk HEAD*. ⚠️ For a non-main target this resets the feature branch to main's HEAD — acceptable for v1 **only if** `--undo` also removes the worktree+branch (fresh start re-branches from target). Documented. |
| `undo-workflow.sh` `checkout main` + `merge --ff-only origin/main` | Restores the developer's *shell* to trunk after cleanup. |
| The eventual `feature-x` → `main` promotion | Out of scope by definition — that PR's base *is* main. |

### 5.2 BECOMES-TARGET — must use the resolved base

**PR creation / base:** `create-pr.sh:38` (empty sentinel, resolver fills it); `trivial-fix-fastpath.sh` draft-PR `--base "$_fastpath_target"` (parameterized via `resolve_target_branch` call at `:127`).

**Worktree creation (branch point) — HIGH BLAST RADIUS:** `claude-workflow.sh:2512` (`_target=$(resolve_target_branch...)`) and `:2638` (`_base_ref="origin/${_target}"`). If wrong, **every** downstream `origin/main...HEAD` diff is wrong.

**Defensive pre-dev merge — HIGH BLAST RADIUS:** `claude-workflow.sh:2806-2838` — fetch + merge `origin/${_target}` at the start of every dev session (already target-parameterized). For a `release/*` branch, the old `origin/main` merge would have silently mixed trunk code in.

**File-change / skip-dev / zero-work diffs (`origin/main...HEAD`):** Numerous sites in `workflow-runner.sh` and `claude-workflow.sh` use the resolved target (via `RITE_TEST_GATE_DIFF_BASE` or explicit `resolve_target_branch`).

**No-PR resume update — 3 sites:** `workflow-runner.sh` fetch/rev-list/merge sites run when `PR_NUMBER` is empty, so the API resolver can't help — **must** read the state file / env (§2 tier 2/3).

**Mid-run rebase — fully parameterized:** `mid-run-rebase.sh` takes a `base_branch` parameter throughout (lines 98–207+ area); every check/rebase is against `origin/$base_branch`. The parameter is threaded from `workflow-runner.sh`.

**Conflict resolver default:** `conflict-resolver.sh:190` `_cr_merge_target="origin/main"`. `divergence-handler.sh` callers already pass `--merge-target origin/$branch_name` (`divergence-handler.sh:550`). `stale-branch.sh` callers pass `--merge-target "origin/$_STALE_BASE_BRANCH"`.

**Merge recovery paths:** `merge-pr.sh:727, :1008, :1032` (see §4.3, already target-parameterized).

**Test-gate diff base:** `test-gate.sh:1857` (`RITE_TEST_GATE_DIFF_BASE:-origin/main`). Set `RITE_TEST_GATE_DIFF_BASE=origin/<target>` before all gate invocations in `run_workflow`.

**Scope checker:** `scope-checker.sh:222` `base_ref="${3:-origin/main}"` (default); actual diff at `:296` (`${base_ref}...HEAD`). Pass the resolved target as the third argument.

**Already-correct (reuse, no change):** `stale-branch.sh:116` + `:186` `resolve_target_branch` / `_stale_resolve_base_branch` already handle the API → state-file → env → default chain.

### 5.3 `rite --status` Integration branches section

**v1 annotation approach superseded (#1046).** The original plan was a `→ feature-x` suffix annotation in the existing worktree-details loop. This was replaced by a dedicated **Integration branches** section in `rite --status` output, driven entirely by ledger files (§9).

**Binding constraints (still in effect — do not change these):**

- `scan_worktrees` (in `repo-status.sh`) uses `behind_main_count` — **STAYS-MAIN**. The "behind main" column reflects trunk health, not integration-branch currency. Do not replace or augment it with a per-worktree network call.
- **No per-branch network calls** in the status path. Branch discovery is via ledger files (`.rite/state/integration-branches/<branch>.log`), not via `git ls-remote` or `gh api`. A missing ledger file means no integration-branch section — not an error.
- The **Integration branches section** appears only when `integration_ledger_entries` finds at least one ledger file. It is absent on repos without the feature, not an empty section.
- Per-branch content: header line with behind-main drift (`git rev-list --count origin/$BRANCH..origin/main`), indented in-flight worktrees whose open PR targets that branch, merged-awaiting-promotion issues from the ledger (issue #, PR #, short SHA), and a suggested next command (`rite --sync <branch>` when behind, `rite --promote <branch>` when at parity with unpromoted entries).

### 5.4 Threading mechanism

**Recommendation: env-var (`RITE_TARGET_BRANCH`, exported once in `bin/rite`) as the transport, `resolve_target_branch` as the single read-path.** Every BECOMES-TARGET site calls the resolver (or reads a `base_branch` it was passed) — **no site reads `origin/main` literally anymore.** One resolver, lint-enforced (§6.4), instead of N scattered correct-by-inspection edits.

---

## 6. Contracts & Safety

### 6.1 Batch ↔ Single-Issue Parity

The target reaches both paths via one chokepoint (`resolve_target_branch` inside `run_workflow`): single-issue via `--base`/env, batch via the exported `RITE_TARGET_BRANCH` (survives the `bin/rite` exec). The state file is per-issue, so no shared mutable state. **New regression test** in `tests/regression/batch-single-issue-parity.bats`: assert the `--base` reaching `create-pr.sh` is identical in single-issue and batch dispatch. Any batch short-circuit needs the `# Deliberate divergence from single-issue mode:` comment.

### 6.2 cwd-after-worktree-removal

Unaffected: `cd "$MAIN_WORKTREE"` (merge-pr.sh) and `cd "$RITE_PROJECT_ROOT"` (`phase_merge_pr`) reference neither `main` nor the target. **One new caution:** the §4.2 added `$PR_BASE` fast-forward must run before worktree removal *or* use a `(cd …)` subshell — never assume cwd is a live worktree.

### 6.3 Re-source Safety

- `resolve_target_branch` (new) lives beside `_stale_resolve_base_branch` in `stale-branch.sh` — gate with the standard `declare -f resolve_target_branch >/dev/null 2>&1 && return 0`.
- `RITE_TARGET_BRANCH` default in `config.sh` uses idempotent `="${RITE_TARGET_BRANCH:-}"` and is exported in the Step-6 block — re-source-safe (no `readonly`).
- `merge-pr.sh` `BASE_BRANCH` uses idempotent assignment.
- **No relative paths for the state file** — always `"${RITE_STATE_DIR}/target-branch-${N}.txt"`.

### 6.4 Deterministic backstop — the lint rule

The dangerous failure mode is a *missed* `origin/main` literal that should have been target-aware. Don't rely on review for ~30 sites. **Add `RAW_ORIGIN_MAIN_REF`** to `tools/sharkrite-lint.sh`: flag literal `origin/main` in the BECOMES-TARGET files; require either the resolver call or an inline `# sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: trunk-health, intentionally main` on each STAYS-MAIN exception. This makes "did the engineer remember every site?" a CI gate, and the suppression comments document the partition inline (No-Env-Var-Escape-Hatches: inline marker, not an env toggle).

---

## 7. Phased Breakdown

Six chunks, dependency-ordered, each ≤2hr (runbook cap), each a `rite plan` issue. **TIGHTLY-COUPLED** = same files / shared parity contract; **SEPARABLE** = independently landable.

**Chunk 1 — Flag parsing + resolver + state file** `[FOUNDATION]`
`bin/rite`: parse `--branch` (exports `RITE_TARGET_BRANCH`; threads `--base` via `WORKFLOW_FLAGS`), pre-exist preflight at `:1682` + `ensure_target_branch_exists`. `config.sh`: default + export. New `resolve_target_branch` (reuses `_stale_resolve_base_branch`); state-file write in `claude-workflow.sh:2756`. `workflow-runner.sh`: `--base` case. Tests: resolver precedence; absolute `RITE_STATE_DIR`; re-source-twice clean. **TIGHTLY-COUPLED** with Chunk 2. **Land first.**

**Chunk 2 — Propagation through all three exits + PR base at creation** `[CORE]`
`bin/rite` threading; `create-pr.sh:38` default (empty sentinel, resolver fills); `workflow-runner.sh` `phase_create_pr` pass `--base`; `claude-workflow.sh:2638` + `trivial-fix-fastpath.sh:127` worktree base. Tests: correct `baseRefName` in single+batch+dev-and-pr; **parity test** (§6.1). **TIGHTLY-COUPLED** with Chunk 1. **Follows Chunk 1.**

**Chunk 3 — Hardcoded-main, dev-side** `[HARDCODED-MAIN]`
`claude-workflow.sh` worktree base (`:2512`, `:2638`), pre-dev merge (`:2806-2838`), all `origin/main...HEAD` diffs; `workflow-runner.sh` skip-dev/zero-work diffs + no-PR resume + test-gate base; `trivial-fix-fastpath.sh`; `scope-checker.sh:222`. **TIGHTLY-COUPLED** with Chunk 4. Depends on Chunk 1.

**Chunk 4 — Hardcoded-main, merge-side** `[HARDCODED-MAIN]`
`merge-pr.sh` conflict merges (`:727, :1008, :1032`) + fast-forward (`:1332-1355`, add `$PR_BASE` ff at `:1357+`); `mid-run-rebase.sh` `base_branch` param threaded from caller; `conflict-resolver.sh:190` via `stale-branch.sh` callers. **TIGHTLY-COUPLED** with Chunk 3. Depends on Chunk 1.

**Chunk 5 — Status reflection + state-file cleanup** `[SEPARABLE]`
`repo-status.sh`: Integration branches section (§5.3, #1046); keep `behind_main_count` main-relative. `--undo`/close: `rm -f target-branch-${N}.txt`. Tests: per-target annotation; cleanup. **SEPARABLE** — depends only on Chunk 1. Can land in parallel with 3/4.

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

1. **Worktree branch-point (`claude-workflow.sh:2638`) + pre-dev merge (`:2806-2838`)** — wrong base silently mixes `main` into a `release/*` worktree and corrupts every downstream diff. Highest blast radius.
2. **`mid-run-rebase.sh`** — fully parameterized in implementation; ensure threaded correctly from every caller.
3. **Three `create-pr.sh` call sites** — miss one and the *PR that matters* targets main. Lint rule (Chunk 6) is the guard.
4. **No-PR resume block (`workflow-runner.sh`)** — runs when no PR exists, so the API resolver can't help; depends entirely on state-file/env resolution.
5. **Batch parity via env** — verify the exported `RITE_TARGET_BRANCH` survives the `bin/rite` exec in a test.
6. **`--undo` resets to `origin/main`** — for a non-main target, a re-run after partial `--undo` starts from the wrong base unless the worktree+branch are also removed.
7. **State-file leak** — the `worktree-handoff-N.txt` precedent shows these aren't cleaned; the Chunk 5 cleanup is mandatory.

---

## 8. Promote-to-Main Trigger (X → main)

**Implemented: `rite --promote <branch>` is a dedicated orchestrator (`lib/core/promote-branch.sh`).** The original Option A recommendation is reversed — see decision log below.

### 8.1 Implemented design

`run_promote <branch>` in `lib/core/promote-branch.sh` executes in seven phases:

1. **Preflight** — fetch `origin/main` + `origin/<branch>`; verify ledger has ≥1 `promoted=false` entry; assert the branch is not behind main (never auto-syncs — sync is explicit via `rite --sync <branch>`).
2. **Promotion PR** — compose a narrative PR body via `RITE_PROMOTE_MODEL` (default `claude-opus-4-8`; own var, decoupled from `RITE_REVIEW_MODEL`); create or refresh a `head=<branch> base=main` PR.
3. **Review** — `local-review.sh` generates and posts a review on the promotion PR.
4. **Targeted gate** — `run_test_gate` runs `make check` + targeted `bats` selection (the same targeted gate used by the per-issue workflow, scoped to what the integration branch changed relative to `origin/main`) inside a temporary worktree on `origin/<branch>`. Failure exits 1 with a remediation command. The gate writes a JSON verdict to `<worktree>/.rite-promote-gate.json`; on failure, if that file is non-empty, `promote-branch.sh` copies it to `.rite/state/promote-gate-<branch>.json` and prints the failing items before removing the worktree, so the operator can recover details after cleanup (#1210, #1244).
5. **CRITICAL hard gate** — `detect_critical_issues` blocks on any CRITICAL review finding.
6. **Capture non-CRITICAL follow-ups** — After the CRITICAL gate passes, parse the promotion review's findings summary (JSON block or Findings line; no LLM call). If HIGH + MEDIUM + LOW > 0, create one aggregated GitHub issue titled `Promotion review follow-ups: <branch>`, labelled `from-review` + `needs-re-triage`, with the full review in the body so operators can triage without fetching the PR. **Never blocks the merge** — `gh issue create` failure is surfaced as a warning and the merge proceeds (`|| true` throughout). Zero non-CRITICAL findings → no issue, no output change (#1209).
7. **SHA-verified squash merge** — `gh api repos/…/pulls/N/merge -f merge_method=squash -f sha=<expected_head>`. A 409/SHA-mismatch means a mid-promote push — abort, never auto-resolve. **This is its own merge path — never routed through `merge-pr.sh`** (see §8.2 rationale).

**Post-merge (phase 7):**
- Mark all `promoted=false` ledger entries `promoted=true` **first** (before branch deletion — a crash after marking leaves a benign orphaned branch; a crash after deletion leaves stale ledger entries that wedge re-runs).
- Delete integration branch (remote + local). **Ephemeral lifecycle**: the branch is recreated fresh from `origin/main` the next time `rite --branch <name> <issue>` is run.
- Post `Promoted to main in PR #N` comments on each constituent issue (best-effort, `gh issue comment`).

**Aggregated `Closes #N` block** — the promotion PR body lists all constituent issues from the ledger (§9), not extracted from the squash commit subject (which only carries the PR title). See §9 for the rationale.

**Single-issue cherry-pick promote** — `rite --promote <branch> --cherry-pick <issue>` promotes one issue from the integration branch by cherry-picking its squash SHA from the ledger onto a temporary branch targeting `main`, then running the full promote pipeline on that temp branch. Conflicts abort (never auto-resolved). Designed; not yet implemented — tracked in #1051 (promote orchestrator shipped in #1047/#1050).

### 8.2 Why not `merge-pr.sh`

`merge-pr.sh`'s post-merge cleanup extracts the "Closes #N" issue number from the single-issue PR body. A promotion PR carries many `Closes #N` references; the single-issue extractor would misfire. The dedicated path reads the issue list from the ledger (§9), which was designed for exactly this purpose.

### 8.3 Decision log — reversal of Option A (standing integration PR)

*The following reasoning was current as of 2026-06-23 design session and is preserved as prior art. It was superseded by the 2026-07-07 ruling.*

> **Original recommendation: Option A — the standing integration PR.** Let a normal X→main PR (`create-pr.sh --base main`, the default) be the signal. Branch X accumulates commits over time; when ready, it merges through the exact path everything else uses (non-draft + no unresolved CRITICAL → `assess-and-resolve.sh` exit 0 → `merge-pr.sh` squash + local-main fast-forward). No new vocabulary, no model judgment — a merged PR is an unambiguous, idempotent fact, inspectable in the GH UI and `rite --status`.
>
> **Optional ergonomic layer (if an explicit verb is wanted):** a thin `rite --promote <branch>` that does nothing more than (a) ensure the X→main PR exists, then (b) hand off to the Option A path. **Scope strictly to `base=main`.**
>
> **Rejected alternatives at that time:**
> - **`ready-for-main` label on a tracking issue** — labels are idiomatic and deterministic, but rite's label→work pipeline assumes label-classified *issues rite itself opened* (`Closes #N`), whereas an integration branch is branch-centric and usually issue-less; it also misuses the issue-*classification* axis for a *branch-merge-readiness* meaning. Solves only the *signal*, still needs Option A's mechanics underneath.
> - **`rite --promote` as a full new orchestrator** — largest new surface; must replicate the resume/cwd/lock/exit-code contracts; breaks rite's uniform issue-number-keyed identity.
> - **`.rite/state/promote-<branch>.flag`** — fits the persistence/determinism conventions, but state files are *rite-authored internal plumbing*, not user-authored inputs; invisible to `rite --status` and the GH UI.

**Why Option A was reversed (2026-07-07):**

The "thin shim" framing understated the coupling. Two forced constraints made a dedicated orchestrator necessary:

1. **Ephemeral branch lifecycle.** `rite --promote` squash-merges to `main` and **deletes the integration branch**. A standing X→main PR cannot survive head-branch deletion — GitHub closes it automatically when the branch is deleted. The promote verb *is* the deletion event; there is no pre-existing PR to merge "through."

2. **Own `Closes #N` extraction.** Squash-merge commit subjects carry only the PR title (`Promote 'feature-x' to main (#N)`), not the constituent issue numbers. The only reliable source of the full issue list is the merge ledger (§9). `merge-pr.sh`'s single-issue extraction logic (`Closes #N` from the PR body at a fixed site) cannot replace this without a destabilizing rewrite. A dedicated promote path reads the ledger directly — no single-issue coupling.

Additionally: the full-suite gate and CRITICAL hard gate before a production merge have different scope than the per-issue gate. Running the standing PR through `assess-and-resolve.sh` would mis-categorize integration-branch findings. A dedicated path has its own reviewers and gates sized for the promotion audience.

---

## 9. Merge Ledger + Close Semantics

*Implemented by #1043.*

### 9.1 Ledger format

Each staging merge (i.e., `rite N --branch feature-x` completing its workflow) appends one line to `.rite/state/integration-branches/<branch>.log`:

```
issue=42	pr=97	sha=<40-hex>	merged_at=2026-07-07T04:12:33Z	promoted=false
```

Fields are tab-separated key=value pairs (greppable, forward-compatible). The ledger file is created on demand; the parent directory (which may be nested for `release/1.2`-style branch names) is created with `mkdir -p`. All mutations use `lock_acquire` / `lock_release` from `lib/utils/lock.sh` (portable `flock(1)` equivalent for macOS) to prevent concurrent batch-slot races.

**Public API** (`lib/utils/integration-ledger.sh`):
- `integration_ledger_append <branch> <issue_num> <pr_num> <sha>` — called by `merge-pr.sh` after a successful staging merge
- `integration_ledger_entries <branch>` — emits all ledger lines to stdout; used by `promote-branch.sh` and `repo-status.sh`
- `integration_ledger_mark_promoted <branch> <issue_num>` — rewrites `promoted=false` → `promoted=true` for the named issue

### 9.2 Close semantics — issues close at staging merge time

When an issue's PR merges into the integration branch (not into `main`), the issue is closed with an **annotated close comment**:

> Closed by PR #97 — merged to integration branch 'feature-x'; pending promotion to main.

**Rationale:** the issue is *done* — its work landed. The annotation prevents confusion ("wait, why is this closed if the branch wasn't promoted yet?"). The `rite --status` Integration branches section shows it as "merged, awaiting promotion," consistent with the ledger's `promoted=false` state.

### 9.3 Why the ledger, not `git log`

Squash commit subjects on the integration branch carry the PR title (e.g., `Fix auth bug (#97)`), not the originating issue number. To compose the promotion PR's `Closes #42` list and to post post-promotion comments, `promote-branch.sh` needs the issue number — which only the ledger records durably. `git log --grep` would require scraping PR body text from the GitHub API for each commit, and would break for PRs whose bodies changed after creation. The ledger is the single source of truth for this mapping.

---

## 10. `rite --sync <branch>` — Syncing Integration Branches

*Implemented by #1041 (`lib/utils/integration-sync.sh`).*

### 10.1 Purpose

Integration branches accumulate drift as `main` receives new commits. `rite --sync <branch>` merges `origin/main` INTO the integration branch, keeping it current before promotion.

### 10.2 Design invariants

- **NEVER rebase.** The integration branch is shared and long-lived; other in-flight worktrees fork from it. Rebasing would rewrite SHAs recorded in the integration ledger and invalidate all in-flight branches. Merge-only preserves published history.
- **NEVER force-push.** A merge adds commits without rewriting history — plain `git push` is correct.
- **NEVER called automatically.** No workflow phase, batch slot, or `rite --promote` may invoke sync. Only an explicit `rite --sync <branch>` triggers it. This is by design: automatic syncs would cause silent history-rewriting risk if a future refactor accidentally changed the transport.
- **Conflict path.** If `git merge origin/main` conflicts: `attempt_claude_merge_resolution` is invoked when available; if it fails or is unavailable, `git merge --abort`, remove temp worktree, print manual instructions, exit 1.

### 10.3 `rite --promote` integration

`run_promote` checks `origin/<branch>` against `origin/main` at preflight. If behind:
- **Auto mode:** exit 1 with `rite --sync <branch>` instruction.
- **Supervised mode:** prompt to run `rite --sync <branch>` now (yes → calls `sync_integration_branch`, re-checks; no → exit 1).

Promote never auto-syncs — the sync decision is always operator-driven.

---
