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

<!-- sharkrite-doc-drift pr:1313 issue:1262 recorded:2026-10-19T23:58:01Z -->
**Changed files**: lib/core/plan-issues.sh, tests/regression/plan-targeted-block-completion.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- docs/configuration.md — "Configuration"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: `CLAUDE.md`'s description of `_dedup_issues` as the deduplification mechanism for near-duplicate plan blocks is now incomplete — the title-guard in `plan-issues.sh` is the actual rejection point for reworded near-duplicates before they reach `_dedup_issues`.
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

<!-- sharkrite-doc-drift pr:1299 issue:1231 recorded:2026-10-20T04:26:42Z -->
**Changed files**: lib/core/docs-command.sh, tests/regression/rite-docs-directed-update.bats
**Implicated docs**:
- docs/architecture/behavioral-design.md — "Sharkrite Behavioral Design"
- CLAUDE.md — "Sharkrite Development Guide"
**Suspected inaccuracy**: not assessed — provider unavailable; verify implicated sections manually
<!-- /sharkrite-doc-drift -->
