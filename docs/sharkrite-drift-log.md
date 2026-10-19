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
