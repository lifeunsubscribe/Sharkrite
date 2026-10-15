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
