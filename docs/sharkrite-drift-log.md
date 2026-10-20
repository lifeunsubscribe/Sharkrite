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

<!-- sharkrite-doc-drift pr:1311 issue:1240 recorded:2026-10-20T00:04:39Z -->
**Changed files**: lib/utils/gate-verdict.sh, lib/utils/test-gate.sh, tests/regression/gate-failure-empty-items-blocks-merge.bats, tests/regression/gate-verdict-seam.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/architecture/branch-flag-design.md — "Design Doc: `rite N --branch <name>` — Target-Branch Merge Workflow"
- docs/test-authoring-runbook.md — "Test Authoring Runbook"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
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
