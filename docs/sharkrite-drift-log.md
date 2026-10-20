# Sharkrite Drift Log

**Auto-appended by sharkrite in changelog mode — do not hand-edit entries.**

Each entry records a merge where sharkrite detected that documentation may
need updating. Entries are machine-parseable blocks delimited by
`<!-- sharkrite-doc-drift pr:N ... -->` markers.

**Burn-down semantics:** Remove an entry after you have verified or updated
the implicated documentation. Delete this file when the last entry burns down.
`rite docs` (#1045) can also drive burn-down automatically.

---

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

<!-- sharkrite-doc-drift pr:1316 issue:1241 recorded:2026-10-20T01:16:53Z -->
**Changed files**: tests/regression/gate-block-on-any.bats, tests/regression/gate-notrun-detection.bats, tests/regression/gate-shellcheck-findings.bats, tests/regression/gate-watchdog-collapse.bats, tests/regression/test-gate-node-failure-parsing.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
**Suspected inaccuracy**: `behavioral-design.md` line 417 claims `gate-block-on-any.bats` tests "a failing test in the targeted selection fails the gate (exit 1, reported in `tests[]`, not suppressed) + the `_tap_failure_name` canonicalizer," but after PR #1316 it was converted to test only the pure `_gate_build_verdict` verdict-assembly seam without invoking the real gate runner.
<!-- /sharkrite-doc-drift -->

