# Sharkrite Drift Log

**Auto-appended by sharkrite in changelog mode — do not hand-edit entries.**

Each entry records a merge where sharkrite detected that documentation may
need updating. Entries are machine-parseable blocks delimited by
`<!-- sharkrite-doc-drift pr:N ... -->` markers.

**Burn-down semantics:** Remove an entry after you have verified or updated
the implicated documentation. Delete this file when the last entry burns down.
`rite docs` (#1045) can also drive burn-down automatically.

---

<!-- sharkrite-doc-drift pr:1299 issue:1231 recorded:2026-10-15T12:31:37Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: Based on my analysis, the `behavioral-design.md` was updated in this same PR (the 2-line diff I saw). The key behavioural change is that the EDIT guard now emits a **pre-call warning** for cap-excluded files (before the LLM runs) rather than only silently auto-skipping proposals post-LLM. The `behavioral-design.md` now correctly documents this. CLAUDE.md's `rite docs "<instructions>"` description doesn't mention this behaviour — but it never did, so that's not a new inaccuracy introduced by this PR.

The most concrete inaccuracy is: `behavioral-design.md` previously described files being dropped via `break` (first-over-cap stops processing) and now they're skipped via `continue` (prospective check, continues to next file). The doc was updated but the CLAUDE.md description of `rite docs` still doesn't note the new pre-call cap warning — however the more concrete stale claim visible from the diff is the old two-guards vs three-guards count that `behavioral-design.md` itself fixed.

Since `behavioral-design.md` was already corrected in the PR, the remaining risk is any claim in CLAUDE.md about the behaviour that is now stale — specifically, CLAUDE.md's `rite docs` entry says nothing about the cap-skipped-files warning, but doesn't contradict it either.

The most likely documentation inaccuracy introduced by PR #1299 and **not yet corrected** would be if CLAUDE.md still implies that the EDIT guard's only mechanism is post-proposal auto-skip (silent), when the PR added a deterministic pre-call warning for cap-excluded files.

`CLAUDE.md`'s `rite docs "<instructions>"` description omits the new pre-call warning that fires when docs are excluded by the 15KB context budget, leaving the behaviour appearing silent when files are cap-skipped.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1304 issue:1303 recorded:2026-10-18T20:55:12Z -->
**Changed files**: lib/core/workflow-runner.sh, tests/regression/stale-review-detection-sha-based.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md states "SHA match → review covers HEAD, assess it (no reroute)" and "No SHA in review → fallback to epoch-seconds timestamp comparison (backward compat for pre-#354 reviews)" as the staleness contract, but attributes it only to `assess-and-resolve.sh` — the PR extended this same SHA-based oracle to `workflow-runner.sh`'s Phase 2 skip-review check, which CLAUDE.md still describes as using only timestamp comparison.

CLAUDE.md's Phase 3 staleness contract now applies to Phase 2's skip-review decision too, but the doc only credits `assess-and-resolve.sh` for the SHA oracle.

`workflow-runner.sh`'s Phase 2 skip-review check previously used timestamp-only comparison but now uses the SHA oracle (matching `assess-and-resolve.sh`), while CLAUDE.md still describes the Phase 2 check as timestamp-based.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1304 issue:1303 recorded:2026-10-18T21:00:06Z -->
**Changed files**: lib/core/workflow-runner.sh, tests/regression/stale-review-detection-sha-based.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md's "Phase 3 — Review Staleness Contract" section says staleness detection is SHA-based in `assess-and-resolve.sh`, but now Phase 2's skip-review check in `workflow-runner.sh` also uses SHA-based detection — the doc doesn't mention this extension to Phase 2's currency check.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1304 issue:1303 recorded:2026-10-18T21:04:54Z -->
**Changed files**: lib/core/workflow-runner.sh, tests/regression/stale-review-detection-sha-based.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The CLAUDE.md Phase 3 staleness contract section says staleness detection is only in `assess-and-resolve.sh`, but PR #1304 also added SHA-based detection to `workflow-runner.sh`'s Phase 2 skip logic. The CLAUDE.md section at line 89-100 only documents this for Phase 3 / `assess-and-resolve.sh`, making no mention that `workflow-runner.sh` now uses the same SHA oracle in its Phase 2 review-skip check.

CLAUDE.md's "Phase 3 — Review Staleness Contract" section claims staleness detection is in `assess-and-resolve.sh` only, but PR #1304 also added SHA-based staleness detection to `workflow-runner.sh`'s Phase 2 review-skip check.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1307 issue:1232 recorded:2026-10-18T21:21:58Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `rite docs "<instructions>"` documentation claims CREATE proposals are applied unconditionally, but PR #1307 added a TOCTOU guard that skips CREATE when the target file already exists in the worktree.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1307 issue:1232 recorded:2026-10-18T21:26:40Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s `rite docs "<instructions>"` description says directed updates "Can CREATE new docs" without mentioning that CREATE is silently skipped when the file already exists (use EDIT instead).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1307 issue:1232 recorded:2026-10-18T21:31:12Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `_docs_apply_approved` now checks `_aa_action` and refuses CREATE when the file already exists — but CLAUDE.md's `rite docs` description says the apply-path writes unconditionally with no mention of this guard.

`rite docs` directed-update description in CLAUDE.md omits the apply-site CREATE guard that now skips writes when the target file already exists.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1276 issue:1236 recorded:2026-10-19T21:14:47Z -->
**Changed files**: CLAUDE.md, lib/utils/gate-runners.sh, lib/utils/gate-selection.sh, lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/bats-pretty-terminal.bats, tests/regression/gate-bats-job-census.bats, tests/regression/gate-desymlink-node-modules.bats, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-flake-retry.bats, tests/regression/gate-force-full-optin.bats, tests/regression/gate-function-scoped-selection.bats, tests/regression/gate-missing-deps-skip.bats, tests/regression/gate-node-workspaces.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-session-env-scrub.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-tiered-scoped-cycles.bats, tests/regression/gate-verdict-persistence.bats, tests/regression/gate-workspace-build-entrypoint.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `_compute_bats_jobs`, `_bats_file_is_serial`, and `_select_tests_by_changed_paths` all moved to `gate-selection.sh`, but `docs/test-authoring-runbook.md:80` still shows the example header as `lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial`.

The example function-scoped header in `docs/test-authoring-runbook.md` cites `lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial`, but both functions now live in `gate-selection.sh`.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1276 issue:1236 recorded:2026-10-19T21:33:29Z -->
**Changed files**: CLAUDE.md, lib/utils/gate-runners.sh, lib/utils/gate-selection.sh, lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/assessment-sha-pin.bats, tests/regression/bats-pretty-terminal.bats, tests/regression/gate-bats-job-census.bats, tests/regression/gate-block-on-any.bats, tests/regression/gate-desymlink-node-modules.bats, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-flake-retry.bats, tests/regression/gate-force-full-optin.bats, tests/regression/gate-function-scoped-selection.bats, tests/regression/gate-missing-deps-skip.bats, tests/regression/gate-node-workspaces.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-session-env-scrub.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-tiered-scoped-cycles.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md line 740 claims `test-gate.sh` was ~2,900 lines / 34 functions with 29 bats files before the #1236 split, but after the split `test-gate.sh` is now ~1,500 lines — the "29 bats files declaring it" count is still accurate, but the ~2,900-line / 34-function description now refers to the pre-split size, not the current state, making the motivating example stale (the split already happened, so the "Adopt it where the ratio is bad" example cites a file that no longer has that problem).

CLAUDE.md's function-scoped-headers example cites `test-gate.sh` as "~2,900 lines / 34 functions with 29 bats files" but the split in PR #1236 already reduced `test-gate.sh` to ~1,500 lines, making that motivating example describe a resolved state.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1276 issue:1236 recorded:2026-10-19T21:36:12Z -->
**Changed files**: CLAUDE.md, lib/utils/gate-runners.sh, lib/utils/gate-selection.sh, lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/assessment-sha-pin.bats, tests/regression/bats-pretty-terminal.bats, tests/regression/gate-bats-job-census.bats, tests/regression/gate-block-on-any.bats, tests/regression/gate-desymlink-node-modules.bats, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-flake-retry.bats, tests/regression/gate-force-full-optin.bats, tests/regression/gate-function-scoped-selection.bats, tests/regression/gate-missing-deps-skip.bats, tests/regression/gate-node-workspaces.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-session-env-scrub.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-tiered-scoped-cycles.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `_compute_bats_jobs` and `_bats_file_is_serial` are now defined in `lib/utils/gate-selection.sh`, but CLAUDE.md's function-scoped headers example still references `lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial`.

CLAUDE.md's example `# sharkrite-test-covers: lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial` points to the wrong file — both functions were extracted to `lib/utils/gate-selection.sh` by PR #1276.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1311 issue:1240 recorded:2026-10-19T23:57:41Z -->
**Changed files**: lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-verdict-seam.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The CLAUDE.md architecture table description for `gate-verdict.sh` does not mention `_gate_build_verdict`, which was added to that file in issue #1240 (this PR). The file itself was correctly extracted from test-gate.sh in issue #1236; only the description is incomplete.

`gate-verdict.sh` description in CLAUDE.md should additionally mention `_gate_build_verdict` added in #1240.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1313 issue:1262 recorded:2026-10-19T23:58:01Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-targeted-block-completion.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s description of `_dedup_issues` as the deduplification mechanism for near-duplicate plan blocks is now incomplete — the title-guard in `plan-issues.sh` is the actual rejection point for reworded near-duplicates before they reach `_dedup_issues`.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1312 issue:1143 recorded:2026-10-20T00:02:31Z -->
**Changed files**: CLAUDE.md, config/rite.conf.example, lib/core/batch-process-issues.sh, lib/utils/cap-resume.sh, tests/regression/cap-autoresume.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The CLAUDE.md says "holds the machine awake (macOS AC only, via `caffeinate`)" but the actual code in `cap-resume.sh` also **re-invokes the batch** on battery — it only skips the caffeinate hold, not the entire resume. The resume still happens on battery, just without keeping the machine awake.

`CLAUDE.md:497` says "holds the machine awake (macOS AC only, via `caffeinate`) and re-invokes the remaining batch" — this implies the entire feature is AC-only, but the code skips only the caffeinate hold on battery while still waiting and re-invoking on any platform.

`CLAUDE.md:497` says the feature is "macOS AC only" but cap-resume.sh re-invokes the batch on battery too — only the caffeinate hold is skipped on battery/non-macOS.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1311 issue:1240 recorded:2026-10-20T00:04:39Z -->
**Changed files**: lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-verdict-seam.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1312 issue:1143 recorded:2026-10-20T00:07:15Z -->
**Changed files**: CLAUDE.md, config/rite.conf.example, lib/core/batch-process-issues.sh, lib/utils/cap-resume.sh, tests/regression/cap-autoresume.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md:497` says the auto-resume feature is "macOS AC only" but `cap-resume.sh` re-invokes the batch on battery too — only the `caffeinate` hold is skipped on battery/non-macOS.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1311 issue:1240 recorded:2026-10-20T00:09:53Z -->
**Changed files**: lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-verdict-seam.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The functions `_compute_bats_jobs` and `_bats_file_is_serial` were already in `gate-selection.sh` (extracted by an earlier issue #1236). The `test-authoring-runbook.md` example still says `lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial` but those functions now live in `lib/utils/gate-selection.sh`.

`CLAUDE.md` line 740 also repeats this stale reference. But the most concrete inaccuracy introduced by PR #1311 specifically relates to what it changed: the architecture table entry for `gate-verdict.sh`.

The CLAUDE.md says `gate-verdict.sh` was "extracted from test-gate.sh, issue #1236" — but looking at the branch name `b1236-1240-1241`, gate-verdict.sh is the third extraction and corresponds to issue #1241, not #1236.

`CLAUDE.md` line 56: `lib/utils/gate-verdict.sh        # Gate JSON output, TAP parsing, notrun synthesis (extracted from test-gate.sh, issue #1236)`

The issue number `#1236` in the gate-verdict.sh architecture entry is wrong — this file was extracted by PR #1311 for issue #1241, not #1236.

`CLAUDE.md` line 56 attributes `gate-verdict.sh` extraction to issue #1236, but it was extracted by PR #1311 for issue #1241 (the third in the batch `b1236-1240-1241`).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1315 issue:1293 recorded:2026-10-20T00:34:37Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-unverified-integration.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` previously had no section for `_normalize_host_to_registrable_domain`. PR #1315 added the "Host-normalization contract" entry (item 3 "Known multi-part suffixes handled explicitly") documenting `co.uk`, `co.in`, `vercel.app`, `herokuapp.com`, and related suffixes. No prior doc content existed for this function — no inaccuracy to reconcile; doc is current.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1315 issue:1293 recorded:2026-10-20T00:45:30Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-unverified-integration.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md states the multi-part TLD list covers only `co.uk com.au co.jp com.br`, but PR #1315 expanded it to also include `co.in`, `co.nz`, `co.za`, `net.au`, `org.au`, `org.uk`, `vercel.app`, `herokuapp.com`, `github.io`, and `netlify.app`.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1315 issue:1293 recorded:2026-10-20T00:50:28Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-unverified-integration.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1316 issue:1241 recorded:2026-10-20T01:16:53Z -->
**Changed files**: tests/regression/gate-block-on-any.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-watchdog-collapse.bats, tests/regression/test-gate-node-failure-parsing.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` line 417 claims `gate-block-on-any.bats` tests "a failing test in the targeted selection fails the gate (exit 1, reported in `tests[]`, not suppressed) + the `_tap_failure_name` canonicalizer," but after PR #1316 it was converted to test only the pure `_gate_build_verdict` verdict-assembly seam without invoking the real gate runner.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1316 issue:1241 recorded:2026-10-20T01:39:56Z -->
**Changed files**: tests/regression/gate-block-on-any.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-watchdog-collapse.bats, tests/regression/test-gate-node-failure-parsing.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` line 417 claims `gate-block-on-any.bats` tests "a failing test in the targeted selection fails the gate (exit 1, reported in `tests[]`, not suppressed) + the `_tap_failure_name` canonicalizer," but after PR #1316 the test was converted to call only `_gate_build_verdict` directly without invoking the real gate runner or targeted selection.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1316 issue:1241 recorded:2026-10-20T01:42:58Z -->
**Changed files**: tests/regression/gate-block-on-any.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-watchdog-collapse.bats, tests/regression/test-gate-node-failure-parsing.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md:417` says `gate-block-on-any.bats` pins the full `run_test_gate` targeted-selection path, but the test was converted to call `_gate_build_verdict` directly with pre-built TAP fixtures, no longer exercising the selection or stub-runner path.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1299 issue:1231 recorded:2026-10-20T04:26:42Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1312 issue:1143 recorded:2026-10-20T04:27:30Z -->
**Changed files**: CLAUDE.md, config/rite.conf.example, lib/core/batch-process-issues.sh, lib/utils/cap-resume.sh, tests/regression/cap-autoresume.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: Now I have a clear picture. The config example (lines 43-44) says "On battery or non-macOS: skips the hold but still waits and resumes." The CLAUDE.md line 497 says "macOS AC only, via `caffeinate`" — implying it only runs on macOS AC power. But the actual behavior is that it resumes on battery too (just without the caffeinate hold). The CLAUDE.md description "macOS AC only" is the inaccuracy — the feature works on non-AC/non-macOS too, just without caffeinate.

CLAUDE.md's "macOS AC only" description of cap auto-resume is incorrect — the feature waits and re-invokes on battery and non-macOS too, skipping only the `caffeinate` hold.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1312 issue:1143 recorded:2026-10-20T04:31:48Z -->
**Changed files**: CLAUDE.md, config/rite.conf.example, lib/core/batch-process-issues.sh, lib/utils/cap-resume.sh, tests/regression/cap-autoresume.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `README.md:147` shows `RITE_MAX_SESSION_HOURS` default as `4`, while the actual default in `config.sh` and all documentation is `12`. This is the inaccuracy.

`README.md` documents `RITE_MAX_SESSION_HOURS` default as `4` but the actual default is `12` (set in `config.sh`, `blocker-rules.sh`, `batch-process-issues.sh`, and `configuration.md`).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1323 issue:1127 recorded:2026-10-20T05:11:37Z -->
**Changed files**: lib/utils/gate-runners.sh, lib/utils/test-gate.sh, tests/regression/gate-pytest-testmon-bootstrap.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The runbook at line 114 says pytest-testmon requires the user to wire it manually ("or at minimum path-scoped selection"), but the PR now auto-provisions pytest-testmon into the venv when `RITE_GATE_NATIVE_SCOPING` is enabled — the runbook no longer reflects that sharkrite handles the installation automatically.

`docs/test-authoring-runbook.md:114` says pytest repos must wire `pytest-testmon` themselves, but the gate now auto-provisions it into the venv when `RITE_GATE_NATIVE_SCOPING` is enabled (default: `true`).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1323 issue:1127 recorded:2026-10-20T05:16:09Z -->
**Changed files**: lib/utils/gate-runners.sh, lib/utils/test-gate.sh, tests/regression/gate-pytest-testmon-bootstrap.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `docs/test-authoring-runbook.md:114` says pytest repos must wire `pytest-testmon` themselves, but the gate now auto-provisions it into the venv when `RITE_GATE_NATIVE_SCOPING` is enabled (default: `true`).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1329 issue:1306 recorded:2026-10-20T05:36:11Z -->
**Changed files**: lib/core/workflow-runner.sh, tests/regression/stale-review-detection-sha-based.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md states Phase 3 uses SHA-based staleness detection via `extract_review_sha` compared to current HEAD, but the PR documents that Phase 3 actually resolves HEAD via `resolve_pr_head_sha` (GitHub API first), while Phase 2 uses `git rev-parse HEAD` — meaning CLAUDE.md's description "SHA match → review covers HEAD, assess it" omits that Phase 3 and Phase 2 use different HEAD oracles, which can diverge and deadlock.

CLAUDE.md's Phase 3 staleness description says "SHA match → review covers HEAD" without noting Phase 3 resolves HEAD via the GitHub API (`resolve_pr_head_sha`) rather than local git, diverging from Phase 2's `git rev-parse HEAD`.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1329 issue:1306 recorded:2026-10-20T05:39:43Z -->
**Changed files**: lib/core/workflow-runner.sh, tests/regression/stale-review-detection-sha-based.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The behavioral-design.md at line 708 quotes the sentinel test name as `"...— accepted divergence from Phase 3"` but the actual test name in the bats file is `"...— divergence from Phase 3 (issue #1306)"` — the word "accepted" is dropped and `(issue #1306)` is appended.

`behavioral-design.md:708` quotes the sentinel test name as `"…— accepted divergence from Phase 3"` but the actual bats test name ends `"— divergence from Phase 3 (issue #1306)"`.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1327 issue:1051 recorded:2026-10-20T05:58:18Z -->
**Changed files**: CLAUDE.md, bin/rite, lib/core/promote-branch.sh, tests/regression/promote-branch.bats, tests/regression/promote-single-issue-cherry-pick.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/encountered-issues-system.md — "Encountered Issues System"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/architecture/tag-index.md — "Tag Index"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/configuration.md — "Configuration"
**Suspected inaccuracy**: `branch-flag-design.md:276` documents the command as `rite --promote <branch> --cherry-pick <issue>`, but the shipped implementation uses the positional form `rite --promote <branch> <issue>` with no `--cherry-pick` flag.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1330 issue:1168 recorded:2026-10-20T06:09:51Z -->
**Changed files**: lib/core/batch-process-issues.sh, tests/regression/batch-cross-batch-overlap.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The CLAUDE.md diagnostic logging section at lines 950-956 lists the diag line types but does NOT include `OVERLAP_DEFER` — the new diag line added by this PR. That's the documentation inaccuracy.

CLAUDE.md's "Diagnostic logging" section omits `OVERLAP_DEFER` from its list of structured `[diag]` line types emitted by the batch.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1331 issue:1203 recorded:2026-10-20T06:10:31Z -->
**Changed files**: lib/core/claude-workflow.sh, tests/regression/fix-timeout-retry.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/research/rtk-assessment.md — "RTK (Rust Token Killer) — Sharkrite Compatibility Assessment"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md states the fix timeout is `300 + 240 × ACTIONABLE_NOW_COUNT` seconds, but the retry adds a dev-session retry at double the original `CLAUDE_TIMEOUT` budget (capped at 14400s), which is a new behaviour not documented there.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1330 issue:1168 recorded:2026-10-20T06:14:44Z -->
**Changed files**: lib/core/batch-process-issues.sh, tests/regression/batch-cross-batch-overlap.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The CLAUDE.md diagnostic logging section lists known `[diag]` line types but does not include `OVERLAP_DEFER`, which was added by this PR.

CLAUDE.md's diagnostic logging list (lines 950-956) omits the new `OVERLAP_DEFER` diag line introduced by PR #1330.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1331 issue:1203 recorded:2026-10-20T06:15:52Z -->
**Changed files**: lib/core/claude-workflow.sh, lib/utils/config.sh, tests/regression/fix-timeout-retry.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/research/rtk-assessment.md — "RTK (Rust Token Killer) — Sharkrite Compatibility Assessment"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The PR introduced a retry path where a timed-out dev session with no commits retries at double the budget (capped at 14400s), which means a single issue can now consume up to 2× `RITE_CLAUDE_TIMEOUT` of active time. The config.sh comment warns that this can silently trip the 4h `RITE_MAX_ISSUE_HOURS` default — but CLAUDE.md and docs still describe the per-issue cap as simply "fires when a single issue runs too long" without mentioning this interaction.

`RITE_MAX_ISSUE_HOURS` default of 4h may now be silently tripped by the no-commit timeout retry path, which adds up to 4h of extra issue time before any work is committed.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1331 issue:1203 recorded:2026-10-20T06:19:06Z -->
**Changed files**: lib/core/claude-workflow.sh, lib/utils/config.sh, tests/regression/fix-timeout-retry.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/research/rtk-assessment.md — "RTK (Rust Token Killer) — Sharkrite Compatibility Assessment"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md documents the fix-timeout retry at `300 + 240 × ACTIONABLE_NOW_COUNT` seconds (capped 1800s), but PR #1331 added a parallel no-commit retry path for the **dev session** that retries at `2×RITE_CLAUDE_TIMEOUT` (default 7200s), capped at 14400s — a distinct retry mechanism not mentioned in any documentation.

CLAUDE.md's fix-session timeout formula (`300 + 240 × ACTIONABLE_NOW_COUNT` seconds, capped 1800s) no longer covers the full retry picture: dev sessions now also retry once at double budget (up to 14400s) on no-commit timeout.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1327 issue:1051 recorded:2026-10-20T06:21:10Z -->
**Changed files**: CLAUDE.md, bin/rite, lib/core/promote-branch.sh, tests/regression/promote-branch.bats, tests/regression/promote-single-issue-cherry-pick.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/encountered-issues-system.md — "Encountered Issues System"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/architecture/tag-index.md — "Tag Index"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/configuration.md — "Configuration"
**Suspected inaccuracy**: The drift log already identifies the inaccuracy: `branch-flag-design.md:276` documents the command as `rite --promote <branch> --cherry-pick <issue>`, but the shipped implementation uses the positional form `rite --promote <branch> <issue>` with no `--cherry-pick` flag.

`branch-flag-design.md:276` documents single-issue promote as `rite --promote <branch> --cherry-pick <issue>`, but the shipped command uses positional form `rite --promote <branch> <issue>` with no `--cherry-pick` flag.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1327 issue:1051 recorded:2026-10-20T06:29:28Z -->
**Changed files**: CLAUDE.md, bin/rite, lib/core/promote-branch.sh, tests/regression/promote-branch.bats, tests/regression/promote-single-issue-cherry-pick.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/encountered-issues-system.md — "Encountered Issues System"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/architecture/tag-index.md — "Tag Index"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/configuration.md — "Configuration"
**Suspected inaccuracy**: `branch-flag-design.md:276` documents single-issue promote as `rite --promote <branch> --cherry-pick <issue>`, but the shipped command uses the positional form `rite --promote <branch> <issue>` with no `--cherry-pick` flag.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1334 issue:1169 recorded:2026-10-20T06:31:59Z -->
**Changed files**: tests/regression/supervised-commit-push-prompt.bats, tests/regression/test-gate-parallel.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` says behavioral y/n/e main-flow tests are "deferred to #1169" but PR #1334 removed that issue citation, replacing it with "file a tracking issue" (no issue number).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1334 issue:1169 recorded:2026-10-20T06:41:18Z -->
**Changed files**: tests/regression/supervised-commit-push-prompt.bats, tests/regression/test-gate-parallel.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md:599` says behavioral tests for the main-flow commit+push prompt are "deferred" pending extraction of `claude-workflow.sh:3747` into a callable function, but the PR updated `supervised-commit-push-prompt.bats` to cite line 3747 as the specific inline location — meaning the doc now accurately describes the defer but may misstate whether a tracking issue already exists or remains unfiled.

The doc at line 599 still says "operator must file tracking issue" and "consolidate with the `assess-and-resolve.sh` RITE_GATE_FINDINGS builder extraction deferred in `tests/regression/test-gate-parallel.bats`" — but the PR added that RITE_GATE_FINDINGS deferral comment to `test-gate-parallel.bats` for the first time, meaning the doc referenced a deferral in that file before the file actually contained it.

`behavioral-design.md:599` cross-references a deferral in `tests/regression/test-gate-parallel.bats` that did not exist until this PR added it, so the doc pre-dated and drove the test comment rather than describing existing test state.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1331 issue:1203 recorded:2026-10-20T14:14:15Z -->
**Changed files**: lib/core/claude-workflow.sh, lib/utils/config.sh, tests/regression/fix-timeout-retry.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/research/rtk-assessment.md — "RTK (Rust Token Killer) — Sharkrite Compatibility Assessment"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `RITE_MAX_ISSUE_HOURS` (default 4h) may now silently stall an otherwise-successful dev session, since the new no-commit timeout retry can itself consume up to 14400s (4h) before the merge gate fires.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1341 issue:1233 recorded:2026-10-20T15:09:11Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1341 issue:1233 recorded:2026-10-20T15:21:34Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `---END---` as a proposal terminator is documented nowhere, but the proposal format now uses a per-generation unique end token (`---END-RANDOMRANDOM---`) instead of the hardcoded `---END---`, so any doc or CLAUDE.md section describing the directed-update proposal format with `---END---` as the block terminator is now inaccurate.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1344 issue:1213 recorded:2026-10-20T15:51:57Z -->
**Changed files**: lib/utils/gate-runners.sh, tests/regression/gate-tiered-scoped-cycles.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s gate architecture section describes `_changed_files_to_workspace_dirs` glob expansion as "Single-level glob, e.g. `packages/*` → direct subdirs only" with `maxdepth 1`, but the code now computes depth dynamically for multi-segment patterns like `packages/*/*`.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1345 issue:1250 recorded:2026-10-20T16:00:00Z -->
**Changed files**: lib/core/assess-and-resolve.sh, lib/core/local-review.sh, lib/core/promote-branch.sh, lib/utils/format-review.sh, tests/helpers/promote-stubs.bash, tests/integration/assess-and-resolve-dedup.bats, tests/regression/assess-fallback-posts-comment.bats, tests/regression/format-review-pretty.bats, tests/regression/promote-review-followup.bats, tests/regression/promote-single-issue-cherry-pick.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/review-system.md — "Review System"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The behavioral-design.md claims `lib/utils/format-review.sh` is "238 lines" (and elsewhere "200+ line review formatter"), but after PR #1345 added `parse_review_severity_counts`, it is now 329 lines.

`behavioral-design.md` calls `lib/utils/format-review.sh` "238 lines" and "200+ line review formatter," but it is now 329 lines after the shared `parse_review_severity_counts` function was added.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1345 issue:1250 recorded:2026-10-20T16:05:20Z -->
**Changed files**: lib/core/assess-and-resolve.sh, lib/core/local-review.sh, lib/core/promote-branch.sh, lib/utils/format-review.sh, tests/helpers/promote-stubs.bash, tests/integration/assess-and-resolve-dedup.bats, tests/regression/assess-fallback-posts-comment.bats, tests/regression/format-review-pretty.bats, tests/regression/promote-review-followup.bats, tests/regression/promote-single-issue-cherry-pick.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/review-system.md — "Review System"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s "Review severity parsing" convention says the canonical approach is to grep the Findings summary line, but the new shared `parse_review_severity_counts()` in `format-review.sh` (3-tier: JSON block → Findings line → item markers) is now the required call site.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1344 issue:1213 recorded:2026-10-20T16:12:13Z -->
**Changed files**: lib/utils/gate-runners.sh, tests/regression/gate-tiered-scoped-cycles.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The diff shows the PR replaced shell glob expansion (`for _dir in "$_pr/"$_pattern`) with `find`-based expansion so that `**` patterns and mid-segment globs resolve correctly, and added `!exclusion` pattern support. The CLAUDE.md architecture comment for `gate-runners.sh` describes its functions as "node/pytest detection, workspace bootstrap, _gate_status" — it says nothing about glob/find-based expansion or `!exclusion` patterns. But more concretely, the old code had an inline comment saying "`set -f` is NOT used here; patterns like `packages/*` must expand. A non-matching glob yields the literal pattern, which we filter out with the `-d` test" — that behavior is now gone (replaced by `find`).

CLAUDE.md line 55 says `gate-runners.sh` handles "workspace bootstrap" via shell glob expansion, but the PR replaced shell glob expansion with `find`-based directory traversal that also supports `**` depth-traversal and `!`-prefixed exclusion patterns.

`gate-runners.sh`'s workspace pattern expansion now uses `find`-based traversal supporting `**` and `!exclusion` patterns, not shell glob expansion that falls back to the literal pattern on no-match.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1331 issue:1203 recorded:2026-10-20T16:25:20Z -->
**Changed files**: lib/core/claude-workflow.sh, lib/utils/config.sh, tests/regression/fix-timeout-retry.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/architecture/tag-index-system.md — "Tag Index System (PROPOSAL)"
- docs/research/rtk-assessment.md — "RTK (Rust Token Killer) — Sharkrite Compatibility Assessment"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: Based on the diff, PR #1331 added a retry loop to the dev-session no-commit timeout path with a cap of 14400s, but `behavioral-design.md` line 389 describes the no-commit retry as applying only to fix sessions with `min(2 × budget, 1800s)`.

`behavioral-design.md` line 389 claims the no-commit timeout retry applies only to "fix session" capped at `min(2×budget, 1800s)`, but dev sessions now also retry with a cap of 14400s.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1344 issue:1213 recorded:2026-10-20T16:33:55Z -->
**Changed files**: lib/utils/gate-runners.sh, tests/regression/gate-tiered-scoped-cycles.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `gate-runners.sh`'s workspace pattern expansion now uses `find`-based traversal supporting `**` and `!exclusion` patterns, not shell glob expansion that falls back to the literal pattern on no-match.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1344 issue:1213 recorded:2026-10-20T16:40:34Z -->
**Changed files**: lib/utils/gate-runners.sh, tests/regression/gate-tiered-scoped-cycles.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md` states `gate-runners.sh` handles "workspace bootstrap" via shell glob expansion that falls back to the literal pattern on no-match, but PR #1344 changed it to `find`-based traversal supporting `**` and `!exclusion` patterns.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1352 issue:1223 recorded:2026-10-20T17:01:23Z -->
**Changed files**: lib/core/batch-process-issues.sh, lib/providers/claude.sh, tests/regression/cap-resume-manifest.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1334 issue:1169 recorded:2026-10-20T19:31:14Z -->
**Changed files**: tests/regression/supervised-commit-push-prompt.bats, tests/regression/test-gate-parallel.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` cites the inline prompt location as `claude-workflow.sh:3775` but the prior recorded line was `3747`, which may now be stale if the file shifted.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1334 issue:1169 recorded:2026-10-20T19:37:50Z -->
**Changed files**: tests/regression/supervised-commit-push-prompt.bats, tests/regression/test-gate-parallel.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` claims behavioral main-flow y/n/e tests are "deferred to a future refactoring issue," but PR #1334 updated this to cite issue #1169 specifically.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1361 issue:1359 recorded:2026-10-20T19:57:05Z -->
**Changed files**: lib/core/plan-issues.sh, lib/utils/gate-runners.sh, tests/regression/plan-validator-strict.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md's bash 3.2 guidance omits `gate-runners.sh` as a sourced library requiring bash 4+; `gate-runners.sh` now enforces this with a `BASH_VERSINFO` guard using `return 1` — a third pattern not described in CLAUDE.md's documented options (the documented options are: self-re-exec guard for directly-executed scripts, and `BASH_SOURCE[0] != $0` + loud failure for sourced libraries).
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1361 issue:1359 recorded:2026-10-20T20:10:04Z -->
**Changed files**: lib/core/plan-issues.sh, lib/utils/gate-runners.sh, tests/regression/plan-validator-strict.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md` documents the `parallel-file-overlap` detector as warn-only, but PR #1361 changed it to auto-rewrite the later issue's `Dependencies` line when neither side carries a suppress marker.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1361 issue:1359 recorded:2026-10-20T20:19:40Z -->
**Changed files**: lib/core/plan-issues.sh, lib/utils/gate-runners.sh, tests/regression/plan-validator-strict.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md's description of `_lint_issues_strict` says it emits a warning for parallel-file-overlap; PR #1361 changed it to auto-chain the later issue instead of warning when neither side is suppressed.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1361 issue:1359 recorded:2026-10-20T20:23:11Z -->
**Changed files**: lib/core/plan-issues.sh, lib/utils/gate-runners.sh, tests/regression/plan-validator-strict.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md documents that when a parallel-file-overlap is detected, the behavior is to emit a `print_warning` — but PR #1361 changed this to auto-chain the later issue (rewrite its Dependencies line) when neither side carries a suppress marker, with a warning only when a suppress marker exists.

`CLAUDE.md` states `parallel-file-overlap` triggers a warning only; it now auto-chains the later issue's `**Dependencies**` line when neither issue carries a `plan-lint suppress` marker.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1364 issue:1360 recorded:2026-10-20T20:55:11Z -->
**Changed files**: CLAUDE.md, lib/core/assess-review-issues.sh, lib/core/local-review.sh, lib/core/plan-issues.sh, lib/utils/promotion-composer.sh, lib/utils/sanitize-output.sh, tests/regression/lib-resource-safety.bats, tests/regression/pipestatus-after-substitution.bats, tests/regression/sanitize-rtk-wrappers.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/review-system.md — "Review System"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1364 issue:1360 recorded:2026-10-20T20:58:43Z -->
**Changed files**: CLAUDE.md, lib/core/assess-review-issues.sh, lib/core/local-review.sh, lib/core/plan-issues.sh, lib/utils/promotion-composer.sh, lib/utils/sanitize-output.sh, tests/regression/lib-resource-safety.bats, tests/regression/pipestatus-after-substitution.bats, tests/regression/sanitize-rtk-wrappers.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/architecture/encountered-issues.md — "Encountered Issues — Recurring Bug Pattern Catalog"
- docs/audit-2026-06-02-dropped-followups.md — "Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/review-system.md — "Review System"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The CLAUDE.md says sanitization covers "four highest-leak GitHub-write seams (issue bodies, follow-up issue bodies, review PR comments, promotion PR bodies)" but the actual call sites are: `local-review.sh` (review output), `assess-review-issues.sh` (follow-up issue body), `plan-issues.sh` (plan issue body), and `promotion-composer.sh` (promotion PR body). That's 4 seams but the CLAUDE.md description doesn't accurately list them — it says "review PR comments" but `local-review.sh` sanitizes the review output itself (not comments), and it doesn't mention plan issues.

CLAUDE.md says the four seams are "issue bodies, follow-up issue bodies, review PR comments, promotion PR bodies" but the actual seams include `plan-issues.sh` (plan issue bodies) instead of or in addition to "issue bodies," and `local-review.sh` sanitizes the review output (not PR comments).

`CLAUDE.md` lists "review PR comments" as one of the four sanitized seams, but `local-review.sh` sanitizes the raw review output before it is posted, not the PR comment itself.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1358 issue:1277 recorded:2026-10-20T21:31:07Z -->
**Changed files**: CLAUDE.md, lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/promote-sync-logging.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `docs/architecture/behavioral-design.md` may still describe the log-capture mechanism as a FIFO-based tee rather than the nested-procsub pattern that CLAUDE.md now documents.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1358 issue:1277 recorded:2026-10-20T21:35:40Z -->
**Changed files**: CLAUDE.md, lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/promote-sync-logging.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `behavioral-design.md` still describes `bin/rite` as using a FIFO-based tee, but PR #1358 changed the implementation to a nested process-substitution pattern (`exec > >(tee >(strip_ansi >> FILE))`).

`behavioral-design.md` claims `bin/rite` uses a FIFO-based tee to prevent tail-truncation, but the implementation was changed to nested process-substitution with a known truncation race.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1376 issue:1370 recorded:2026-10-20T22:02:36Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-unverified-integration.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `behavioral-design.md`'s never-external paragraph contains a stray `**Verify:**` grep line accidentally committed from the issue's Documentation Impact section, not behavioral documentation.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1358 issue:1277 recorded:2026-10-20T22:04:25Z -->
**Changed files**: CLAUDE.md, lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/promote-sync-logging.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The test file exists and covers `bin/rite-full-suite` — so CLAUDE.md's reference to it for the "prior attempt at a FIFO+explicit-`wait` pattern in `bin/rite-full-suite` caused a deadlock" claim appears plausible. 

Now I have enough context. The PR changed the log-capture description from "FIFO-based (implemented)" to "nested-procsub (FIFO not implemented, has tail-truncation race)". CLAUDE.md now says FIFO was "not implemented" and still mentions a deadlock test in `full-suite-subcommand.bats`. That test actually covers `bin/rite-full-suite` safety-net behavior, not the FIFO deadlock — so CLAUDE.md's claim that `tests/regression/full-suite-subcommand.bats` documents the FIFO+wait deadlock is the most likely inaccuracy introduced by this PR.

`CLAUDE.md`'s "Log capture pattern" section claims `tests/regression/full-suite-subcommand.bats` documents the FIFO+explicit-`wait` deadlock, but that file covers the full-suite safety-net behavior, not the FIFO deadlock.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1376 issue:1370 recorded:2026-10-20T22:07:24Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-unverified-integration.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: The behavioral-design.md at line 1386 describes `_detect_unverified_integrations` as checking whether hostnames "are grounded in the project's fixture directories or dependency manifests" — but PR #1376 added a categorical never-external exclusion step that happens *before* the grounded-set check. The documentation doesn't mention this loopback/RFC-2606 exclusion layer.

`_detect_unverified_integrations` docs say grounding is a set-membership fixture/manifest check, but PR #1376 added a never-external exclusion (`localhost`, `127.0.0.1`, `example.com`, etc.) that filters candidates before the grounded-set check runs.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1334 issue:1169 recorded:2026-10-20T22:31:46Z -->
**Changed files**: tests/regression/supervised-commit-push-prompt.bats, tests/regression/test-gate-parallel.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: Now I have the full picture. The PR #1334 changed the `behavioral-design.md` Enforcement line to say the behavioral main-flow tests are "tracked by issue #1368" — but the bats comment was also updated to reference `lib/core/claude-workflow.sh:3775` as the concrete inline location. The behavioral-design.md does NOT include this line number — it only says "extracting the inline commit+push body into a callable function."

The most likely documentation inaccuracy: the `behavioral-design.md` Enforcement line says the deferral is "tracked by issue #1368" but previously the bats comment said `~line 3668` for the location; the updated bats comment now says line `3775`. The doc itself doesn't specify the line number, but the prior PR body said `~line 3668`. This is a minor inconsistency between the doc's claim and reality.

More significantly: the `behavioral-design.md` line at ~549 was also changed from "FIFO-tee" to "nested-procsub tee" — and CLAUDE.md documents the log capture as using "nested-procsub tee" (`exec > >(tee >(strip_ansi >> FILE))`). So that was actually fixing an inaccuracy.

The most directly introduced inaccuracy would be: the `behavioral-design.md` Enforcement line now says "tracked by issue #1368" — if issue #1368 was never actually filed or has different scope, the doc would be claiming something false. But the commit message says "Cite issue #1368 at the three deferral sites" suggesting it WAS filed.

The real remaining inaccuracy is the old bats comment said the inline body is at `~line 3668` (from the PR description) but the updated comment says `3775`. Since `behavioral-design.md` references the test files but doesn't include the line number, the doc is fine. The doc itself has no line-number claim.

Looking at the diff again more carefully — the behavioral-design.md Enforcement line changed from open deferral to "tracked by issue #1368." The most likely inaccuracy introduced is that the doc now asserts the RITE_GATE_FINDINGS builder extraction is also covered by issue #1368, when the original deferred issue was specifically about the supervised commit+push prompt extraction. The doc bundles two distinct concerns under one issue number.

`behavioral-design.md §"Supervised commit/push"` Enforcement line claims issue #1368 "also covers the `RITE_GATE_FINDINGS` builder extraction deferred in `test-gate-parallel.bats`" — this might be inaccurate if #1368's scope is narrower.

`behavioral-design.md §"Supervised commit/push"` Enforcement now claims issue #1368 covers the `RITE_GATE_FINDINGS` builder extraction, but #1368 may only track the commit+push body extraction.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1312 issue:1143 recorded:2026-10-20T22:43:49Z -->
**Changed files**: CLAUDE.md, config/rite.conf.example, lib/core/batch-process-issues.sh, lib/utils/cap-resume.sh, tests/regression/cap-autoresume.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s "macOS AC only" description of `RITE_CAP_AUTORESUME` is wrong — `cap-resume.sh` waits and re-invokes the batch on battery and non-macOS too, skipping only the `caffeinate` hold.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1312 issue:1143 recorded:2026-10-20T22:48:10Z -->
**Changed files**: CLAUDE.md, config/rite.conf.example, lib/core/batch-process-issues.sh, lib/utils/cap-resume.sh, tests/regression/cap-autoresume.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/conventions.md — "Sharkrite Conventions Catalog"
- docs/architecture/exit-codes.md — "Exit Code Reference"
- docs/configuration.md — "Configuration"
- docs/issue-runbook.md — "Issue Generation Runbook"
- docs/ROADMAP.md — "Sharkrite Roadmap"
- README.md — "🦈 Sharkrite"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s "macOS AC only" qualifier on `RITE_CAP_AUTORESUME` is wrong — `cap-resume.sh` waits and re-invokes the batch on battery and non-macOS too, skipping only the `caffeinate` hold.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1383 issue:1372 recorded:2026-10-21T15:23:05Z -->
**Changed files**: lib/utils/sanitize-output.sh, tests/regression/sanitize-rtk-wrappers.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: CLAUDE.md says `sanitize_generated_commands` "strips these" — but the PR change makes it preserve (not strip) rtk meta-commands like `gain`, `discover`, `stats`, `init`, `read`. The documented behavior claims the function strips all rtk-wrapped commands at the four seams, but it now selectively preserves meta-commands through unchanged.

`sanitize_generated_commands` is documented as stripping rtk-wrapped commands, but it now preserves meta-commands (`gain`, `discover`, `stats`, `init`, `read`) intact rather than stripping them.
<!-- /sharkrite-doc-drift -->

<!-- sharkrite-doc-drift pr:1389 issue:1386 recorded:2026-10-21T20:01:57Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-validator-strict.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: Check 7 now derives concurrency from the dep graph (catching unannotated concurrent pairs) instead of relying solely on explicit `(can run in parallel with #N)` annotations.

`CLAUDE.md` says Check 7 fires on issues that "declare themselves parallel via `(can run in parallel with #N)` annotations" — but it now fires on any dep-graph-concurrent pair regardless of annotation.
<!-- /sharkrite-doc-drift -->
