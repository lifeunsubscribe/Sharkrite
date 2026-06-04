# Audit: 11 PRs with Dropped Follow-ups (2026-06-02 Outage)

**Audit date:** 2026-06-04
**Issue:** #325
**Trigger:** PR #260 introduced a 9-line stub in place of `lib/core/assess-review-issues.sh`, disabling ACTIONABLE_LATER follow-up creation for all workflow runs from 2026-06-02 18:49 UTC until PR #322 hot-fixed it on 2026-06-04 20:26 UTC.

**Effect:** 11 PRs were merged with review findings but no follow-up issues filed. Total dropped findings: 26 (11 MEDIUM + 15 LOW; no HIGH or CRITICAL — those would have been ACTIONABLE_NOW and blocked the merge).

**Audit methodology:** For each PR merged in the window, parsed the latest `sharkrite-local-review` PR comment's `**Findings:**` line for severity counts; counted distinct `sharkrite-followup-issue:N` markers in PR comments. A "gap" = PR with any HIGH/MEDIUM/LOW finding but zero follow-up markers.

**Excluded from audit:** PR #260 (the test-bug damage PR), PR #322 (the hot-fix PR), PRs without sharkrite reviews (#293, #311, #314).

---

## Triage Results

### PR #278 — Retry GitHub 5xx in doc assessment
**Findings:** LOW: 1
**Item:** Test comment slightly misleading about `$?` after `if !` (cosmetic; no behavioral impact)
**Decision:** **DISMISSED** — Comment-only clarification on a passing test; already merged; zero code impact.

---

### PR #281 — Deduplicate closing-issue regex across files
**Findings:** MEDIUM: 1, LOW: 1

**MEDIUM — First-use grep fragility in closing-issue-regex-constants.bats**
The "first use" search in regression tests uses `grep -n | head -1` which matches comment lines and `source` lines, potentially causing false pass/fail when a comment referencing the constant appears above the real first usage.
**Decision:** **FILED as issue #328**

**LOW — `&&/||` ternary idiom in Test 9 min-selection**
Common bash anti-pattern (cosmetic); variable assignment is the `&&` branch so the risk is negligible.
**Decision:** **DISMISSED** — Risk is negligible; `if/else` refactor is a style preference only.

---

### PR #286 — Clean LINT_FIXTURE_DIR in teardown
**Findings:** LOW: 1
**Item:** `rm -rf "$LINT_FIXTURE_DIR"` in `teardown()` is redundant since `BATS_TEST_TMPDIR` is the parent and BATS removes it automatically.
**Decision:** **DISMISSED** — Harmless redundancy; belt-and-suspenders teardown is acceptable project style; no correctness risk.

---

### PR #300 — Deduplicate rebase+push logic in cases a and b
**Findings:** MEDIUM: 1, LOW: 2

**MEDIUM — Spurious `git rebase --abort` in push-failure path**
After a successful rebase, if the push fails, the extracted helper calls `git rebase --abort` even though no rebase is in-progress. Currently a no-op, but semantically misleading and a future maintainability hazard.
**Decision:** **FILED as issue #329**

**LOW — `return $?` redundant after helper call** (informational — no action needed)
**LOW — Success message interpolation preserved** (informational — no action needed)
**Decision:** Both LOWs **DISMISSED** — explicitly informational in the review; no action required.

---

### PR #302 — Refine cleanup gating: skip network
**Findings:** MEDIUM: 2, LOW: 2

**MEDIUM 1 — Test 13 only validates step 1 `found_local_orphans` assignment, misses step 2**
The test uses `head -1` to find only the first `found_local_orphans=true` assignment (step 1: worktree removal). Step 2 (branch deletion) has no corresponding test. A regression removing the step 2 assignment would not be caught.
**Decision:** **FILED as issue #330**

**MEDIUM 2 — Doc cross-reference casing inconsistency**
`workflow-runner.sh` inline comments reference the `behavioral-design.md` section with sentence case; actual heading uses title case. Grep friction and future dead-link risk.
**Decision:** **FILED as issue #331**

**LOW — Gate comment verbose relative to surrounding style** (5-6 line trim preferred)
**LOW — Test 14 ls-remote-absent fallback could mask gate removal**
**Decision:** Both LOWs **DISMISSED** — minor style and low-probability coverage gap; tests 12/13 independently cover the flag.

---

### PR #304 — Use portable dead-process PID detection
**Findings:** MEDIUM: 1, LOW: 2

**MEDIUM — Inline `get_dead_pid` duplicate in consistent-lock-strategy.bats**
All other test files call the `get_dead_pid()` helper from `setup.bash`, but `consistent-lock-strategy.bats` inlines the equivalent logic directly (due to heredoc subshell context). The inline copy will silently fall out of sync if the helper changes.
**Decision:** **FILED as issue #333**

**LOW — Docstring example variable name mismatch** (cosmetic)
**LOW — Theoretical PID-reuse race window** (unmeasurably narrow; no fix required)
**Decision:** Both LOWs **DISMISSED** — explicitly cosmetic and "no fix required" in the review.

---

### PR #305 — Add backward-compat alias for _gh_mock_init_state
**Findings:** MEDIUM: 2 (from two separate review runs), LOW: 2+2

**MEDIUM 1 — Missing negative test / existence+behavior complementarity comment**
Tests check alias existence via `declare -f` but there's no note that existence and behavior tests are complementary. A no-op stub passes the existence check; the behavior test fails with an opaque message.
**Decision:** **FILED as issue #334**

**MEDIUM 2 — `setup_gh_mock_state` load-order risk + `$(cat ...)` in `[ ]` fragility**
`setup()` calls `setup_gh_mock_state` but the function's source is not confirmed by the load directives. Also, `$(cat "$file")` inside `[ ]` dies opaquely if the file is absent.
**Decision:** **FILED as issue #335**

**LOWs** — `cat` in test assertions, no negative-path test for misconfigured state dir, section numbering cosmetics.
**Decision:** All LOWs **DISMISSED** — cosmetic or out of scope for a backward-compat regression file.

---

### PR #306 — Index-based arg walk has fragile double-increment
**Findings:** MEDIUM: 2, LOW: 1

**MEDIUM 1 — Missing `--method GET` read-op test**
The test suite covers `--method PUT/DELETE` (write ops) but has no test for `--method GET` (long-form read path). A regression breaking this branch would silently pass.
**Decision:** **FILED as issue #336**

**MEDIUM 2 — `_walk` array shift is O(n²)**
Each loop iteration creates a full array copy. Informational — negligible for typical `gh` arg counts (<20); the review itself notes "no fix needed given current arg counts."
**Decision:** **DISMISSED** — explicitly informational; current approach is the right trade-off.

**LOW — No test for `--method` after positional URL**
**Decision:** **DISMISSED** — optional documentation value only.

---

### PR #307 — Add RITE_LINT_EXTRA_DIRS to single find block
**Findings:** MEDIUM: 1, LOW: 1

**MEDIUM — Rule 18 self-scan risk: sharkrite-lint.sh may not be excluded from SHELL_FILES**
The old `ALL_EXTRACT_FILES` find block explicitly excluded `sharkrite-lint.sh`. The replacement `SHELL_FILES` array needs confirmation that it carries the same exclusion. Without it, Rule 18 scans the lint script's own marker-detection patterns and produces false-positive lint failures.
**Decision:** **FILED as issue #337**

**LOW — Comment assertion about RITE_LINT_EXTRA_DIRS has no test backing**
**Decision:** **DISMISSED** — optional extension of existing coverage; low regression risk.

---

### PR #310 — Add issue-not-found error handling to binary
**Findings:** LOW: 1
**Item:** Comment in `assess-and-resolve-dedup.bats` references test numbers ("test 6", "tests 11-12") that may become stale as tests are added/reordered.
**Decision:** **DISMISSED** — cosmetic; comment is accurate today and the test file is stable; test-number references are a common documentation pattern.

---

### PR #315 — Tighten transient regex to HTTP status framing
**Findings:** MEDIUM: 1, LOW: 1

**MEDIUM — Trailing colon anchor not applied to HTTP-prefix arms**
The fix added `([^0-9:]|$)` to the bare-number arm but not to the `HTTP (429|5xx)` and `\(HTTP (429|5xx)\)` arms. The comment's stated rationale is not uniformly applied; a message like "HTTP 503:" would still match and trigger a spurious retry.
**Decision:** **FILED as issue #338**

**LOW — Comment already correctly says "non-digit, non-colon"**
The review itself noted on second look that the comment was already correct — no action needed.
**Decision:** **DISMISSED** — explicitly "no action needed" in the review.

---

## Summary

| PR | Title | Findings | Filed Issues | Dismissed |
|---|---|---|---|---|
| #278 | Retry GitHub 5xx in doc assessment | 0M 1L | — | 1L cosmetic |
| #281 | Deduplicate closing-issue regex | 1M 1L | #328 | 1L cosmetic |
| #286 | Clean LINT_FIXTURE_DIR in teardown | 0M 1L | — | 1L harmless |
| #300 | Deduplicate rebase+push logic | 1M 2L | #329 | 2L informational |
| #302 | Refine cleanup gating: skip network | 2M 2L | #330, #331 | 2L minor |
| #304 | Portable dead-process PID detection | 1M 2L | #333 | 2L cosmetic/negligible |
| #305 | Backward-compat alias _gh_mock_init_state | 2M 2L | #334, #335 | 2L cosmetic |
| #306 | Fix arg walk double-increment | 2M 1L | #336 | 1M informational; 1L optional |
| #307 | RITE_LINT_EXTRA_DIRS to single find | 1M 1L | #337 | 1L minor |
| #310 | Issue-not-found error handling | 0M 1L | — | 1L cosmetic |
| #315 | Tighten transient regex | 1M 1L | #338 | 1L no-action-needed |

**Total findings triaged:** 11 MEDIUM + 15 LOW = 26
**Filed as issues:** 9 issues (#328–#338, with #332 unused)
**Dismissed with reason:** 17 items (11 LOWs cosmetic/harmless, 4 LOWs informational/no-action, 1 MEDIUM informational, 1 LOW explicitly flagged as no-action-needed by reviewer)

---

## Audit Script

`tools/audit-dropped-followups.sh` — reusable script to re-run this audit against a future outage window. Pass `--window-start` and `--window-end` to scope to the outage period, or `--pr-list` for a specific set of PRs.
