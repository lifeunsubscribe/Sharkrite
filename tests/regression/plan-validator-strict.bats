#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-validator-strict.bats
#
# Regression tests for _lint_issues_strict in plan-issues.sh.
#
# This function is the deterministic validator that dissolves the original H5
# LLM self-critique proposal into code. It runs after the other linters in the
# generate_issues pipeline and performs four checks:
#
#   2. Acyclic dependency graph — DFS cycle detection (ERROR: exit 1)
#   3. No dangling #N refs — every dep ref resolves (ERROR: exit 1)
#   4. Verification path sanity — warns if path not in Files to Modify or repo (WARNING: exit 0)
#   5. Deferral citation check — warns if deferral has no evidence citation (WARNING: exit 0)
#
# Suppression markers:
#   <!-- sharkrite-plan-lint disable <rule> - Reason: <text> -->
#   Reason field REQUIRED. Missing Reason → suppression rejected, check runs.
#   Active suppressions are logged visibly to stderr.
#
# Fixtures (per acceptance criteria):
#   A — cyclic dep graph (X Blocked by Y, Y Blocked by X) → ERROR, exit non-zero
#   B — dangling ref #9999 not in batch or existing_issues → ERROR, exit non-zero
#   C — verification command references src/handler.ts not in Files to Modify or repo → WARNING, exit 0
#   D — deferral entry with no citation → WARNING, exit 0
#   E — deferral with "> docs/architecture.md:42 says..." citation → passes silently, exit 0
#   F — issue with <!-- sharkrite-plan-lint disable cycle-check - Reason: ... -->
#         → cycle-check skipped, [suppressed] logged, exits per other checks
#   G — suppression WITHOUT Reason: field → does NOT suppress, warns, runs check
#   H8a — duplicate non-allowlisted verification command → WARNING naming both titles, exit 0
#   H8b — shared allowlisted command (make check only) → no WARNING, exit 0
#   H8c — unique verification commands across issues → no WARNING, exit 0
#   H8d — issue with duplicate-verification suppression → no WARNING, [suppressed] logged, exit 0
#   H8e — distinctive command shared by all 3 issues on a 3-issue slate → WARNING (not silently exempted), exit 0
#   H9a — 2hr estimate without Split rationale line → WARNING naming the issue, exit 0
#   H9b — 2hr estimate with Split rationale line → no WARNING, exit 0
#   H9c — 1hr estimate without Split rationale → no WARNING, exit 0
#   H9d — 2hr with 2hr-split-rationale suppression → no WARNING, [suppressed] logged, exit 0
#   AC1 — unsuppressed overlap → auto-chain INFO + file rewritten, no WARNING, exit 0
#   AC4 — three-way transitive A←B←C → B gets After #1, C gets After #2, exit 0
#   AC5 — spike-prepended slate → auto-chain uses non-spike ordinal in rewrite, exit 0

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract _lint_issues_strict from plan-issues.sh using the same
# awk brace-depth technique as plan-provenance-flag.bats.
# No top-level plan-issues.sh network calls run.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Source canonical marker constants so _lint_issues_strict's suppression regex
  # (e.g. "<!-- ${RITE_MARKER_PLAN_LINT} disable cycle-check ...") interpolates
  # the real marker value. Without this, RITE_MARKER_PLAN_LINT is empty, the
  # regex never matches the fixtures' markers, and suppression silently fails.
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/markers.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Stub print_* functions so output goes cleanly without terminal setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Extract helper functions and _lint_issues_strict from plan-issues.sh.
  # Order matters: _title_is_spike and the two auto-chain helpers must be
  # defined before _lint_issues_strict, which calls all three.
  eval "$(awk '
    /^_title_is_spike[(][)]/ { in_fn=1; depth=0 }
    /^_transform_dep_line[(][)]/ { in_fn=1; depth=0 }
    /^_autochain_rewrite_deps[(][)]/ { in_fn=1; depth=0 }
    /^_autochain_remove_par_annotation[(][)]/ { in_fn=1; depth=0 }
    /^_lint_issues_strict[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Fixture A — cyclic dependency graph
#
# Issue #1 says "Blocked by: #2", Issue #2 says "Blocked by: #1".
# This forms a cycle: 1 → 2 → 1.
# Validator must emit ERROR and exit non-zero.
# ---------------------------------------------------------------------------

@test "Fixture A: cyclic dependency graph — validator emits ERROR and exits non-zero" {
  local issues_file="$RITE_TEST_TMPDIR/issues-a.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha depends on Beta.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: Blocked by: #2
---END---
---ISSUE---
TITLE: Feature Beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta depends on Alpha (cycle!).

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Dependencies**: Blocked by: #1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero (cycle is a hard error)
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for cyclic deps, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a message mentioning "cycle"
  grep -qi "cycle" "$stderr_out" || {
    echo "FAIL: expected 'cycle' in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture B — dangling ref to #9999
#
# Issue #1 declares "After #9999" but #9999 is not in the batch (only 1 issue)
# and not in existing_issues. Validator must emit ERROR and exit non-zero.
# ---------------------------------------------------------------------------

@test "Fixture B: dangling ref to #9999 not in batch or existing — ERROR, exit non-zero" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Standalone Feature
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
This feature depends on a non-existent issue.

**Claude Context**:
Files to Modify:
- src/feature.py

**Acceptance Criteria**:
- [ ] Feature works: `python -m pytest tests/test_feature.py`

**Done Definition**: Done when feature works.

**Dependencies**: After #9999
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero (dangling ref is a hard error)
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for dangling ref, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention the unresolved ref
  grep -q "#9999" "$stderr_out" || {
    echo "FAIL: expected '#9999' mentioned in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture B: dangling ref resolved via existing_issues string — exits 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b-resolved.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Standalone Feature
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
This feature depends on an existing open issue.

**Claude Context**:
Files to Modify:
- src/feature.py

**Acceptance Criteria**:
- [ ] Feature works: `python -m pytest tests/test_feature.py`

**Done Definition**: Done when feature works.

**Dependencies**: After #9999
---END---
FIXTURE

  # Pass existing_issues containing #9999
  local existing="#9999 Some existing issue [backend]"

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "$existing" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (ref is resolved via existing_issues)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 when ref resolved via existing_issues, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture C — verification command references path not in Files to Modify or repo
#
# Issue lists "src/handler.ts" in its Verification Commands but NOT in
# Files to Modify, and the file does not exist in the test tmpdir (repo).
# Validator must emit WARNING (non-fatal) and exit 0.
# ---------------------------------------------------------------------------

@test "Fixture C: verification path not in Files to Modify or repo — WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Add request handler
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Add a request handler.

**Claude Context**:
Files to Modify:
- src/router.py

**Acceptance Criteria**:
- [ ] Handler works

**Verification Commands**:
```bash
grep -q "handle_request" src/handler.ts
```

**Done Definition**: Done when handler is implemented.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (verification path warning is non-fatal)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for verification path warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING mentioning the path
  grep -q "src/handler.ts" "$stderr_out" || {
    echo "FAIL: expected 'src/handler.ts' mentioned in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture C: verification path in Files to Modify — no warning" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c-ok.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Add request handler
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Add a request handler. The file being verified is the same one being modified.

**Claude Context**:
Files to Modify:
- src/handler.ts

**Acceptance Criteria**:
- [ ] Handler works

**Verification Commands**:
```bash
grep -q "handle_request" src/handler.ts
```

**Done Definition**: Done when handler is implemented.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 when verification path is in Files to Modify, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT warn about handler.ts
  grep -q "verification path not produced" "$stderr_out" && {
    echo "FAIL: unexpected verification path warning for file in Files to Modify" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture D — deferral entry with no citation
#
# Coverage checklist has a "- ⏭️" deferral line with no evidence citation.
# Validator must emit WARNING and exit 0.
# ---------------------------------------------------------------------------

@test "Fixture D: deferral entry without citation — WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-d.txt"

  # Coverage checklist with an uncited deferral comes before the first ---ISSUE---
  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

✅ Feature Alpha → Issue "Feature Alpha"
- ⏭️ Feature Beta deferred to Phase 2 because it requires auth subsystem

---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Alpha feature.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (uncited deferral is a warning, not an error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for uncited deferral warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING about uncited deferral
  grep -qi "uncited deferral" "$stderr_out" || {
    echo "FAIL: expected 'uncited deferral' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture E — deferral entry WITH citation (blockquote form)
#
# Coverage checklist has a "- ⏭️" deferral line with a "> file:line says..."
# citation. Validator must pass silently (no WARNING), exit 0.
# ---------------------------------------------------------------------------

@test "Fixture E: deferral with citation passes silently, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-e.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

✅ Feature Alpha → Issue "Feature Alpha"
- ⏭️ Feature Beta deferred to Phase 2 > docs/architecture.md:42 says "Auth subsystem must exist before Beta"

---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Alpha feature.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for cited deferral, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit an uncited deferral warning
  grep -qi "uncited deferral" "$stderr_out" && {
    echo "FAIL: unexpected 'uncited deferral' warning for cited deferral" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture F — suppression marker WITH required Reason: field
#
# Issue #1 has "<!-- sharkrite-plan-lint disable cycle-check - Reason: ... -->"
# and is in a cycle with #2. The cycle-check must be skipped for that issue,
# the suppression must be logged visibly ("[suppressed] cycle-check: <reason>"),
# and the exit code must reflect only other check results (no other errors → exit 0).
# ---------------------------------------------------------------------------

@test "Fixture F: cycle-check suppressed with Reason: — skipped, [suppressed] logged, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-f.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Alpha (suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha with intentional cycle suppression for cross-repo dependency.

<!-- sharkrite-plan-lint disable cycle-check - Reason: Alpha and Beta have a cross-repo cycle that is intentional for bootstrap ordering -->

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: Blocked by: #2
---END---
---ISSUE---
TITLE: Feature Beta (suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta with intentional cycle suppression.

<!-- sharkrite-plan-lint disable cycle-check - Reason: Same cross-repo bootstrap cycle -->

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Dependencies**: Blocked by: #1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (cycle-check suppressed, no other errors)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 with cycle-check suppressed, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must log [suppressed] visibly
  grep -q "\[suppressed\]" "$stderr_out" || {
    echo "FAIL: expected '[suppressed]' in stderr to show suppression was applied" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention the rule that was suppressed
  grep -q "cycle-check" "$stderr_out" || {
    echo "FAIL: expected 'cycle-check' in suppression log" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a cycle error
  grep -qi "cycle detected\|dependency cycle" "$stderr_out" && {
    echo "FAIL: unexpected cycle error despite suppression" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture G — suppression marker WITHOUT Reason: field
#
# Issue has "<!-- sharkrite-plan-lint disable cycle-check -->" (no Reason:).
# The validator MUST NOT suppress the rule, MUST emit a WARNING about the missing
# Reason field, and MUST run the cycle check (finding the cycle → exit non-zero).
# ---------------------------------------------------------------------------

@test "Fixture G: suppression marker missing Reason: — NOT suppressed, WARNING emitted, check runs" {
  local issues_file="$RITE_TEST_TMPDIR/issues-g.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha with malformed suppression (missing Reason:).

<!-- sharkrite-plan-lint disable cycle-check -->

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: Blocked by: #2
---END---
---ISSUE---
TITLE: Feature Beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta that completes the cycle.

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Dependencies**: Blocked by: #1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must emit a warning about missing Reason field
  grep -qi "Reason" "$stderr_out" || {
    echo "FAIL: expected warning about missing Reason: field" >&2
    cat "$stderr_out" >&2
    false
  }

  # The cycle check must STILL run and detect the cycle
  # (Either via cycle error message OR non-zero exit)
  # Accept either: non-zero exit OR cycle mentioned in stderr
  local cycle_detected=false
  [ "$exit_code" -ne 0 ] && cycle_detected=true
  grep -qi "cycle" "$stderr_out" && cycle_detected=true

  [ "$cycle_detected" = "true" ] || {
    echo "FAIL: cycle check did not run despite malformed suppression (exit $exit_code)" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Acceptance criterion: _lint_issues_strict makes zero provider_run calls
# ---------------------------------------------------------------------------

@test "acceptance: _lint_issues_strict contains no provider_run calls (zero LLM calls)" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^_lint_issues_strict[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  local provider_call_count
  provider_call_count=$(echo "$fn_body" | grep -c "provider_run" || true)

  [ "$provider_call_count" -eq 0 ] || {
    echo "FAIL: _lint_issues_strict contains $provider_call_count provider_run call(s)" >&2
    echo "$fn_body" | grep "provider_run" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance criterion: _lint_issues_strict is wired into generate_issues
# ---------------------------------------------------------------------------

@test "acceptance: _lint_issues_strict is called from generate_issues" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  local gen_fn_body
  gen_fn_body=$(awk '
    /^generate_issues[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  echo "$gen_fn_body" | grep -q "_lint_issues_strict" || {
    echo "FAIL: _lint_issues_strict is not called within generate_issues()" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance criterion: no new RITE_* env vars introduced
# ---------------------------------------------------------------------------

@test "acceptance: no new RITE_* env-var flags introduced in _lint_issues_strict" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^_lint_issues_strict[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # The validator should use inline markers, not env-var flags.
  # It may reference RITE_PROJECT_ROOT (path config, not a behavior flag) — that is allowed.
  # Any RITE_* var that looks like a flag (boolean-style: RITE_PLAN_*) is not allowed.
  local new_rite_flags
  new_rite_flags=$(echo "$fn_body" | grep -oE 'RITE_PLAN_[A-Z_]+' | sort -u || true)

  [ -z "$new_rite_flags" ] || {
    echo "FAIL: _lint_issues_strict references RITE_PLAN_* env-var flags (violates no-env-var-escape-hatch policy):" >&2
    echo "$new_rite_flags" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Edge: acyclic graph with valid ordinal deps — exits 0, no errors
# ---------------------------------------------------------------------------

@test "edge: acyclic dep chain 1 -> 2 -> 3 — exits 0, no errors" {
  local issues_file="$RITE_TEST_TMPDIR/issues-chain.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Issue One
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**: First in chain.

**Claude Context**:
Files to Modify:
- src/one.py

**Acceptance Criteria**:
- [ ] One works: `python -m pytest tests/test_one.py`

**Done Definition**: Done when one works.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Issue Two
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**: Second in chain.

**Claude Context**:
Files to Modify:
- src/two.py

**Acceptance Criteria**:
- [ ] Two works: `python -m pytest tests/test_two.py`

**Done Definition**: Done when two works.

**Dependencies**: After #1
---END---
---ISSUE---
TITLE: Issue Three
LABELS: backend,priority-low
TIME: 30min
BODY:
**Description**: Third in chain.

**Claude Context**:
Files to Modify:
- src/three.py

**Acceptance Criteria**:
- [ ] Three works: `python -m pytest tests/test_three.py`

**Done Definition**: Done when three works.

**Dependencies**: After #2
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for acyclic chain, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit any cycle or dangling-ref errors
  grep -qi "cycle\|dangling\|unresolved" "$stderr_out" && {
    echo "FAIL: unexpected error in acyclic chain" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Edge: file with no issues (only coverage checklist) — exits 0
# ---------------------------------------------------------------------------

@test "edge: file with no issue blocks — exits 0 gracefully" {
  local issues_file="$RITE_TEST_TMPDIR/issues-empty.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

No issues to generate.
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for empty issue file, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# PR test 13 — acyclic chain with batch-internal deps (IFS split regression)
#
# Issue #2 depends on #1, Issue #3 depends on #2 (linear chain).
# With the broken IFS= read override, the reverse-adjacency split leaves a
# trailing "|" that flows into arithmetic and crashes Kahn's algorithm.
# This fixture confirms the IFS fix: exits 0 and no errors.
# ---------------------------------------------------------------------------

@test "PR test 13: acyclic batch-internal dep chain — exits 0, Kahn's processes all nodes" {
  local issues_file="$RITE_TEST_TMPDIR/issues-pr13.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Base Issue
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**: Foundation issue with no deps.

**Claude Context**:
Files to Modify:
- src/base.py

**Acceptance Criteria**:
- [ ] Base works: `python -m pytest tests/test_base.py`

**Done Definition**: Done when base works.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Middle Issue
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**: Depends on base.

**Claude Context**:
Files to Modify:
- src/middle.py

**Acceptance Criteria**:
- [ ] Middle works: `python -m pytest tests/test_middle.py`

**Done Definition**: Done when middle works.

**Dependencies**: Blocked by: #1
---END---
---ISSUE---
TITLE: Top Issue
LABELS: backend,priority-low
TIME: 30min
BODY:
**Description**: Depends on middle.

**Claude Context**:
Files to Modify:
- src/top.py

**Acceptance Criteria**:
- [ ] Top works: `python -m pytest tests/test_top.py`

**Done Definition**: Done when top works.

**Dependencies**: Blocked by: #2
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (acyclic chain should pass)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for acyclic batch-internal deps, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit any cycle or error
  grep -qi "cycle\|ERROR" "$stderr_out" && {
    echo "FAIL: unexpected ERROR/cycle in acyclic batch-internal dep chain" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# PR test 13b — diamond DAG: acyclic with two paths to same root
#
# #1 (root) ← #2 (left branch)  ← #4 (merge)
#           ← #3 (right branch) ← #4
# Kahn's should process all 4 nodes; no cycle error.
# ---------------------------------------------------------------------------

@test "PR test 13b: diamond DAG acyclic — exits 0, no cycle error" {
  local issues_file="$RITE_TEST_TMPDIR/issues-diamond.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Root
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**: Root issue, no deps.

**Claude Context**:
Files to Modify:
- src/root.py

**Acceptance Criteria**:
- [ ] Root works: `python -m pytest tests/test_root.py`

**Done Definition**: Done when root works.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Left Branch
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**: Left path from root.

**Claude Context**:
Files to Modify:
- src/left.py

**Acceptance Criteria**:
- [ ] Left works: `python -m pytest tests/test_left.py`

**Done Definition**: Done when left works.

**Dependencies**: Blocked by: #1
---END---
---ISSUE---
TITLE: Right Branch
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**: Right path from root.

**Claude Context**:
Files to Modify:
- src/right.py

**Acceptance Criteria**:
- [ ] Right works: `python -m pytest tests/test_right.py`

**Done Definition**: Done when right works.

**Dependencies**: Blocked by: #1
---END---
---ISSUE---
TITLE: Merge Point
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**: Depends on both left and right branches.

**Claude Context**:
Files to Modify:
- src/merge.py

**Acceptance Criteria**:
- [ ] Merge works: `python -m pytest tests/test_merge.py`

**Done Definition**: Done when merge works.

**Dependencies**: Blocked by: #2
After #3
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 — diamond DAG is acyclic
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for diamond DAG, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a cycle error
  grep -qi "cycle" "$stderr_out" && {
    echo "FAIL: unexpected cycle error for acyclic diamond DAG" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# PR test 14 — zero-issue input (only coverage checklist, no ---ISSUE--- blocks)
#
# When _issue_count=0, seq 1 0 produces descending "1 0" range and drives
# per-issue loops to index empty arrays, crashing under set -u with
# "_titles[0]: parameter not set". This fixture confirms the seq guard fix.
# ---------------------------------------------------------------------------

@test "PR test 14: zero-issue input exits 0 gracefully (seq guard regression)" {
  local issues_file="$RITE_TEST_TMPDIR/issues-zero-pr14.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

✅ All features already implemented in prior batch.
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for zero-issue input, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must not emit any array-index or arithmetic errors
  grep -qi "parameter not set\|unbound variable\|arithmetic" "$stderr_out" && {
    echo "FAIL: array-index crash on zero-issue input" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture K — ADR-decision-ID citations are recognized (not false-positives)
#
# Real incident: finance-glance run 2026-06-09 emitted deferrals citing ADR
# decisions — "(ADR D7, follow-up #4)", "(ADR follow-up #7)" — which are genuine
# citations, but the recognizer only knew blockquote / file:line / quoted-string
# forms, so it flagged all of them as "uncited deferral". Fix adds ADR-decision-ID
# and follow-up patterns. These deferrals must now pass silently.
# ---------------------------------------------------------------------------

@test "Fixture K: ADR-decision-ID and follow-up citations are recognized — no uncited warning" {
  local issues_file="$RITE_TEST_TMPDIR/issues-k.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

✅ Feature Alpha → Issue "Feature Alpha"
- ⏭️ Recurring-vendor label-mapping table → Deferred to Phase 4 (ADR D7, follow-up #4)
- ⏭️ 3D-printed frame → Deferred to Phase 4 (ADR follow-up #7)

---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Alpha feature.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (cited deferrals are not even warnings)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for ADR-cited deferrals, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT flag either ADR-cited deferral as uncited.
  grep -qi "uncited deferral" "$stderr_out" && {
    echo "FAIL: ADR-decision-ID citation falsely flagged as uncited" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H — cyclic dependency graph via #[Title] refs
#
# Issue #1 "Feature Alpha" says "After #[Feature Beta]",
# Issue #2 "Feature Beta" says "After #[Feature Alpha]".
# This is the same 1↔2 cycle as Fixture A but expressed with title refs
# instead of numeric ordinals. Cycle detection must still catch it.
# ---------------------------------------------------------------------------

@test "Fixture H: cyclic deps via title refs #[Title] — validator emits ERROR and exits non-zero" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha depends on Beta (cycle!).

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: After #[Feature Beta]
---END---
---ISSUE---
TITLE: Feature Beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta depends on Alpha (cycle!).

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Dependencies**: After #[Feature Alpha]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero (cycle is a hard error)
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for title-ref cycle, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a message mentioning "cycle"
  grep -qi "cycle" "$stderr_out" || {
    echo "FAIL: expected 'cycle' in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture I — acyclic chain via #[Title] refs
#
# Issue #1 "Schemas" has no deps.
# Issue #2 "CRUD" depends on "After #[Schemas]" (resolves to #1).
# Issue #3 "Filters" depends on "After #[CRUD]" (resolves to #2).
# This is an acyclic chain — validator must exit 0 with no errors.
# ---------------------------------------------------------------------------

@test "Fixture I: acyclic chain via title refs #[Title] — exits 0, no errors" {
  local issues_file="$RITE_TEST_TMPDIR/issues-i.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Schemas
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Schema definitions, no dependencies.

**Claude Context**:
Files to Modify:
- src/models.py

**Acceptance Criteria**:
- [ ] Schemas created: `python -m pytest tests/test_models.py`

**Done Definition**: Done when models created.

**Dependencies**: None
---END---
---ISSUE---
TITLE: CRUD
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
CRUD endpoints, depends on schemas.

**Claude Context**:
Files to Modify:
- src/router.py

**Acceptance Criteria**:
- [ ] CRUD works: `python -m pytest tests/test_router.py`

**Done Definition**: Done when CRUD works.

**Dependencies**: After #[Schemas]
---END---
---ISSUE---
TITLE: Filters
LABELS: backend,priority-low
TIME: 1hr
BODY:
**Description**:
Filter endpoints, depends on CRUD.

**Claude Context**:
Files to Modify:
- src/filters.py

**Acceptance Criteria**:
- [ ] Filters work: `python -m pytest tests/test_filters.py`

**Done Definition**: Done when filters work.

**Dependencies**: After #[CRUD]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (acyclic chain passes)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for acyclic title-ref chain, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit any cycle or unresolved-ref errors
  grep -qiE "cycle|ERROR.*unresolved|unresolved.*ERROR" "$stderr_out" && {
    echo "FAIL: unexpected cycle/error in acyclic title-ref chain" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture J — unresolved #[Title] ref (no matching batch issue)
#
# Issue #1 references "After #[Nonexistent Issue]" — no batch issue has
# that title. Validator must emit a WARNING (not a hard error, since the
# ref may point to an external/pre-existing issue whose title matches).
# Exit code must be 0 (warning-only, not a hard gate).
# ---------------------------------------------------------------------------

@test "Fixture J: unresolved title ref #[Nonexistent] — emits WARNING, exits 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-j.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Gamma
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Depends on a non-existent issue title.

**Claude Context**:
Files to Modify:
- src/gamma.py

**Acceptance Criteria**:
- [ ] Gamma works: `python -m pytest tests/test_gamma.py`

**Done Definition**: Done when gamma works.

**Dependencies**: After #[Nonexistent Issue]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (unresolved title ref is a warning, not a hard error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for unresolved title ref (warning only), got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a warning mentioning the unresolved title
  grep -qi "unresolved title ref\|Nonexistent" "$stderr_out" || {
    echo "FAIL: expected warning about unresolved title ref in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture M — "(can run in parallel with #M, #P)" annotations are NOT edges
#
# The generation prompt mandates "After #N (can run in parallel with #M, #P)"
# for parallel siblings. Those parenthetical mentions are scheduling hints,
# not dependencies — but the extractor used to harvest every #N on the line,
# making parallel siblings mutually "depend" on each other. Kahn's algorithm
# then reported a false cycle and hard-aborted an otherwise valid plan.
# Live failure: finance-glance `rite plan` run, 2026-06-10.
# ---------------------------------------------------------------------------

@test "Fixture M: parallel-with annotations do not create cycle edges — exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-m.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Root Schema
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Root issue all siblings depend on.

**Claude Context**:
Files to Modify:
- src/schema.py

**Acceptance Criteria**:
- [ ] Schema works: `python -m pytest tests/test_schema.py`

**Done Definition**: Done when schema works.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Endpoint Alpha
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
Depends only on the root schema.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: After #1 (can run in parallel with #3, #4)
---END---
---ISSUE---
TITLE: Endpoint Beta
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
Depends only on the root schema.

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Dependencies**: After #1 (can run in parallel with #2, #4)
---END---
---ISSUE---
TITLE: Endpoint Gamma
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
Depends only on the root schema.

**Claude Context**:
Files to Modify:
- src/gamma.py

**Acceptance Criteria**:
- [ ] Gamma works: `python -m pytest tests/test_gamma.py`

**Done Definition**: Done when gamma works.

**Dependencies**: After #1 (can run in parallel with #2, #3)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 — parallel siblings sharing a root are acyclic
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for parallel siblings, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT report a cycle
  grep -qi "cycle" "$stderr_out" && {
    echo "FAIL: false cycle reported for parallel-with annotations" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture N — stripping parallel annotations preserves the real ref
#
# "After #9 (can run in parallel with #2)" in a 2-issue batch: the real ref
# #9 is dangling and must still be harvested (hard error), proving the
# parenthetical stripping does not eat the dependency before the parens.
# ---------------------------------------------------------------------------

@test "Fixture N: real ref before parallel annotation still harvested — dangling #9 errors" {
  local issues_file="$RITE_TEST_TMPDIR/issues-n.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Delta
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
References a dangling dependency plus a parallel annotation.

**Claude Context**:
Files to Modify:
- src/delta.py

**Acceptance Criteria**:
- [ ] Delta works: `python -m pytest tests/test_delta.py`

**Done Definition**: Done when delta works.

**Dependencies**: After #9 (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Feature Epsilon
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Standalone issue.

**Claude Context**:
Files to Modify:
- src/epsilon.py

**Acceptance Criteria**:
- [ ] Epsilon works: `python -m pytest tests/test_epsilon.py`

**Done Definition**: Done when epsilon works.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero — #9 is dangling and must still be detected
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for dangling #9 before parallel annotation, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture O — Check 6: same-file issues with different category labels
#
# Issue #1 is labeled "backend", Issue #2 is labeled "frontend".
# Both modify the same file (src/finance_glance.cpp).
# Validator must emit exactly one terminal WARNING naming both issues,
# the shared path, and both labels. Exit must be 0 (warning is non-fatal).
# ---------------------------------------------------------------------------

@test "Fixture O: same-file different-category labels — one WARNING emitted, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-o.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Backend render pass
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Render pass backend changes.

**Claude Context**:
Files to Modify:
- src/finance_glance.cpp

**Acceptance Criteria**:
- [ ] Tests pass: `make test`

**Done Definition**: Done when tests pass.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Frontend widget draw
LABELS: frontend,priority-medium
TIME: 1hr
BODY:
**Description**:
Frontend widget drawing in the same file.

**Claude Context**:
Files to Modify:
- src/finance_glance.cpp

**Acceptance Criteria**:
- [ ] Widget renders: `make test`

**Done Definition**: Done when widget renders.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (label-consistency warning is non-fatal)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for label-consistency warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING mentioning label-consistency
  grep -q "label-consistency" "$stderr_out" || {
    echo "FAIL: expected 'label-consistency' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention the shared file
  grep -q "src/finance_glance.cpp" "$stderr_out" || {
    echo "FAIL: expected shared file path in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention both category labels
  grep -q "backend" "$stderr_out" || {
    echo "FAIL: expected 'backend' label in stderr" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -q "frontend" "$stderr_out" || {
    echo "FAIL: expected 'frontend' label in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must be exactly one label-consistency warning (one pair → one warning)
  local warning_count
  warning_count=$(grep -c "label-consistency" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 label-consistency warning, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture O2 — Check 6: same-file same-category labels → silent
#
# Both issues modify the same file but both carry "backend" labels.
# No label-consistency warning should be emitted. Exit 0.
# ---------------------------------------------------------------------------

@test "Fixture O2: same-file same-category labels — no WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-o2.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Backend alpha route
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Alpha route implementation.

**Claude Context**:
Files to Modify:
- src/router.py

**Acceptance Criteria**:
- [ ] Tests pass: `make test`

**Done Definition**: Done when tests pass.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Backend beta route
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Beta route implementation in the same file.

**Claude Context**:
Files to Modify:
- src/router.py

**Acceptance Criteria**:
- [ ] Tests pass: `make test`

**Done Definition**: Done when tests pass.

**Dependencies**: After #1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for same-category same-file issues, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a label-consistency warning
  grep -q "label-consistency" "$stderr_out" && {
    echo "FAIL: unexpected label-consistency warning for same-category issues" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture P — Check 7: parallel-claim + overlapping files → visible WARNING
#
# Issue #1 and #2 both modify the same file AND #2 declares itself parallel
# with #1. This should emit a print_warning on stderr and exit 0.
# File-level overlap is not always a conflict (disjoint functions), so it is
# a WARNING not an error — but the human approving the plan must see it.
# ---------------------------------------------------------------------------

@test "Fixture P: parallel-claim + overlapping files — WARNING visible in preview, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-p.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Parse loop alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha parse loop in shared file.

**Claude Context**:
Files to Modify:
- src/parser.cpp

**Acceptance Criteria**:
- [ ] Alpha passes: `make test`

**Done Definition**: Done when alpha passes.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Parse loop beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta parse loop in the same shared file — different function.

**Claude Context**:
Files to Modify:
- src/parser.cpp

**Acceptance Criteria**:
- [ ] Beta passes: `make test`

**Done Definition**: Done when beta passes.

**Dependencies**: After #1 (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (parallel-file-overlap is a warning, never aborts)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for parallel-claim overlap, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a print_warning for parallel-file-overlap
  grep -q "parallel-file-overlap:" "$stderr_out" || {
    echo "FAIL: expected parallel-file-overlap WARNING in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention the shared file
  grep -q "src/parser.cpp" "$stderr_out" || {
    echo "FAIL: expected shared file 'src/parser.cpp' in parallel-file-overlap warning" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention both issue titles
  grep -q "Parse loop alpha" "$stderr_out" || {
    echo "FAIL: expected title 'Parse loop alpha' in parallel-file-overlap warning" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -q "Parse loop beta" "$stderr_out" || {
    echo "FAIL: expected title 'Parse loop beta' in parallel-file-overlap warning" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention "After #" (the suggested fix)
  grep -q "After #" "$stderr_out" || {
    echo "FAIL: expected 'After #N' chain suggestion in parallel-file-overlap warning" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture P2 — Check 6 + 7 interaction: same-file, different category,
# AND declared parallel — WARNING from label-consistency AND WARNING from
# parallel-file-overlap, exit 0.
# ---------------------------------------------------------------------------

@test "Fixture P2: same-file diff-category + parallel — WARNING from label-consistency and parallel-file-overlap, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-p2.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Backend root render
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Backend root renderer.

**Claude Context**:
Files to Modify:
- src/finance_glance.cpp

**Acceptance Criteria**:
- [ ] Render works: `make test`

**Done Definition**: Done when render works.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Frontend overlay draw
LABELS: frontend,priority-medium
TIME: 1hr
BODY:
**Description**:
Frontend overlay — same file, parallel with backend issue.

**Claude Context**:
Files to Modify:
- src/finance_glance.cpp

**Acceptance Criteria**:
- [ ] Overlay works: `make test`

**Done Definition**: Done when overlay works.

**Dependencies**: After #1 (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must have a label-consistency WARNING (different categories)
  grep -q "label-consistency" "$stderr_out" || {
    echo "FAIL: expected label-consistency WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must have a parallel-file-overlap WARNING (parallel + overlapping files)
  grep -q "parallel-file-overlap:" "$stderr_out" || {
    echo "FAIL: expected parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture L — self-referential title ref creates a one-node "cycle"
#
# Issue #1 "Feature Alpha" has a dependency "After #[Feature Alpha]" —
# it references itself by title. This is a one-node self-referential cycle.
# Validator must emit a specific ERROR about self-referential dependency
# and exit non-zero.
# ---------------------------------------------------------------------------

@test "Fixture L: self-referential title ref — ERROR about self-referential dep, exits non-zero" {
  local issues_file="$RITE_TEST_TMPDIR/issues-l.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha depends on itself — self-referential cycle.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Dependencies**: After #[Feature Alpha]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero (self-referential dep is a hard error)
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for self-referential title dep, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit an error message about self-referential dependency
  grep -qi "self-referential" "$stderr_out" || {
    echo "FAIL: expected 'self-referential' in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention the issue title
  grep -q "Feature Alpha" "$stderr_out" || {
    echo "FAIL: expected issue title 'Feature Alpha' mentioned in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture L2 — self-referential title ref with cycle-check suppression
#
# Same self-ref as Fixture L but the issue has a suppression marker for
# cycle-check. The self-referential check runs in Phase 2b (before Kahn's),
# so the suppression does NOT apply here — we still catch it early.
# Suppression is a per-issue cycle-check gate applied in Kahn's, not in
# the title-resolution phase.
# ---------------------------------------------------------------------------

@test "Fixture L2: self-referential title ref is caught before cycle-check suppression — ERROR, exits non-zero" {
  local issues_file="$RITE_TEST_TMPDIR/issues-l2.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Feature Beta (self-ref suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta depends on itself but tries to suppress cycle-check.

<!-- sharkrite-plan-lint disable cycle-check - Reason: Intentional self-bootstrap ordering -->

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Dependencies**: After #[Feature Beta (self-ref suppressed)]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Self-referential deps are caught in Phase 2b, before Kahn's algorithm.
  # The cycle-check suppression only applies to Kahn's, not Phase 2b.
  # So this must still exit non-zero.
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for self-referential dep (cycle-check suppression does not apply to Phase 2b)" >&2
    cat "$stderr_out" >&2
    false
  }

  grep -qi "self-referential" "$stderr_out" || {
    echo "FAIL: expected 'self-referential' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Q — duplicate title matches silently resolve to first ordinal
#
# Two issues share the title "Shared Feature". A third issue has a dependency
# "After #[Shared Feature]". Validator must emit a WARNING about the ambiguous
# title ref and exit 0 (warning is non-fatal; it still resolves to first match).
# ---------------------------------------------------------------------------

@test "Fixture Q: duplicate title matches — WARNING about ambiguous ref, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-q.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Shared Feature
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
First issue with title "Shared Feature".

**Claude Context**:
Files to Modify:
- src/shared_a.py

**Acceptance Criteria**:
- [ ] Works: `python -m pytest tests/test_shared_a.py`

**Done Definition**: Done when tests pass.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Shared Feature
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Second issue with the same title "Shared Feature" — duplicate.

**Claude Context**:
Files to Modify:
- src/shared_b.py

**Acceptance Criteria**:
- [ ] Works: `python -m pytest tests/test_shared_b.py`

**Done Definition**: Done when tests pass.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Downstream Feature
LABELS: backend,priority-low
TIME: 30min
BODY:
**Description**:
Depends on "Shared Feature" — ambiguous because two issues share that title.

**Claude Context**:
Files to Modify:
- src/downstream.py

**Acceptance Criteria**:
- [ ] Works: `python -m pytest tests/test_downstream.py`

**Done Definition**: Done when tests pass.

**Dependencies**: After #[Shared Feature]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (ambiguous title match is a warning, not a hard error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for ambiguous title ref (warning only), got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING about ambiguous title ref
  grep -qi "ambiguous" "$stderr_out" || {
    echo "FAIL: expected 'ambiguous' in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention the duplicate title
  grep -q "Shared Feature" "$stderr_out" || {
    echo "FAIL: expected 'Shared Feature' mentioned in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Q2 — unique titles do NOT trigger duplicate warning
#
# Three issues all have distinct titles. No ambiguous-title warning should
# be emitted even if they all have title ref dependencies. Exit 0.
# ---------------------------------------------------------------------------

@test "Fixture Q2: unique titles — no ambiguous-title WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-q2.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Alpha Step
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
First step.

**Claude Context**:
Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when tests pass.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Beta Step
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Second step, depends on Alpha.

**Claude Context**:
Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when tests pass.

**Dependencies**: After #[Alpha Step]
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for unique titles, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit an ambiguous-title warning
  grep -qi "ambiguous" "$stderr_out" && {
    echo "FAIL: unexpected ambiguous-title WARNING for unique titles" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 1 — parallel-ref in prose body (not in Dependencies section) must NOT
# trigger a parallel-file-overlap WARNING.
#
# Issue #1 has "(can run in parallel with #2)" in its Description body text,
# NOT in its Dependencies section. Issue #2 has no parallel annotation at all.
# Check 7 must not fire because the prose mention is not a scheduling hint
# from the Dependencies section — it's just prose.
# Both issues modify the same file to make the overlap check relevant.
# ---------------------------------------------------------------------------

@test "Fix 1: parallel-ref in prose body (not Dependencies) — no parallel-file-overlap WARNING emitted" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix1.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Parser alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha parse loop. Note: this feature (can run in parallel with #2) conceptually
but is implemented sequentially.

**Claude Context**:
Files to Modify:
- src/parser.cpp

**Acceptance Criteria**:
- [ ] Alpha passes: `make test`

**Done Definition**: Done when alpha passes.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Parser beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta parse loop in the same shared file.

**Claude Context**:
Files to Modify:
- src/parser.cpp

**Acceptance Criteria**:
- [ ] Beta passes: `make test`

**Done Definition**: Done when beta passes.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a parallel-file-overlap WARNING — the parallel annotation lives in
  # the Description body, not in the Dependencies section.
  grep -q "parallel-file-overlap:" "$stderr_out" && {
    echo "FAIL: unexpected parallel-file-overlap WARNING from prose-body parallel mention" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 2 — self-reference guard: issue declaring itself parallel with its own
# ordinal must NOT emit a spurious parallel-file-overlap WARNING.
#
# Issue #1 declares "(can run in parallel with #1)" in its Dependencies line —
# a degenerate annotation. Without the self-reference guard, _pj == _pi == 0,
# the file-overlap check always finds a shared path (the issue's own files),
# and emits a false warning.
# ---------------------------------------------------------------------------

@test "Fix 2: self-referential parallel annotation — no parallel-file-overlap WARNING emitted" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix2.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Solo feature
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Solo feature with a degenerate self-parallel annotation.

**Claude Context**:
Files to Modify:
- src/solo.cpp

**Acceptance Criteria**:
- [ ] Solo passes: `make test`

**Done Definition**: Done when solo passes.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for self-referential parallel annotation, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a parallel-file-overlap WARNING for self-reference
  grep -q "parallel-file-overlap:" "$stderr_out" && {
    echo "FAIL: unexpected parallel-file-overlap WARNING from self-referential parallel annotation" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 3 — bidirectional parallel declarations produce exactly one warning.
#
# Issue #1 declares "(can run in parallel with #2)" and issue #2 declares
# "(can run in parallel with #1)". Both modify the same file. Without the
# ordering guard, Check 7 emits two warnings (one from each side of the pair).
# With the fix, only the lower-ordinal reporter (#1) emits.
# ---------------------------------------------------------------------------

@test "Fix 3: bidirectional parallel declarations — exactly one parallel-file-overlap WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix3.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Draw loop alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha draw loop in shared file.

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Alpha passes: `make test`

**Done Definition**: Done when alpha passes.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Draw loop beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta draw loop in the same shared file.

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Beta passes: `make test`

**Done Definition**: Done when beta passes.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (parallel-file-overlap is informational, never aborts)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for bidirectional parallel, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly ONE parallel-file-overlap WARNING (not two)
  local warn_count
  warn_count=$(grep -c "parallel-file-overlap:" "$stderr_out" || true)
  [ "$warn_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 parallel-file-overlap WARNING, got $warn_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention the shared file
  grep -q "src/renderer.cpp" "$stderr_out" || {
    echo "FAIL: expected 'src/renderer.cpp' mentioned in parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must include the suggested dependency fix ("After #1")
  grep -q "After #1" "$stderr_out" || {
    echo "FAIL: expected 'After #1' in parallel-file-overlap WARNING (ordinal fix)" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 3 (unidirectional) — only the higher-ordinal issue declares parallel.
#
# Issue #2 declares "(can run in parallel with #1)" but issue #1 does NOT
# declare parallel with #2.  The dedup guard must NOT suppress the warning in
# this case — there is no lower-ordinal reporter, so #2 is the sole emitter.
# Exactly one parallel-file-overlap WARNING must appear.
# ---------------------------------------------------------------------------

@test "Fix 3 (unidirectional): higher-ordinal parallel declaration — exactly one parallel-file-overlap WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix3-uni.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Render loop base
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Base render loop in shared file — no parallel annotation here.

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Base passes: `make test`

**Done Definition**: Done when base passes.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Render loop overlay
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Overlay render loop in the same shared file — only this side declares parallel.

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Overlay passes: `make test`

**Done Definition**: Done when overlay passes.

**Dependencies**: After #1 (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (parallel-file-overlap is a warning, never aborts)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for unidirectional parallel, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly ONE parallel-file-overlap WARNING (the higher-ordinal issue #2
  # is the sole reporter — the dedup guard must not suppress unidirectional warnings)
  local warn_count
  warn_count=$(grep -c "parallel-file-overlap:" "$stderr_out" || true)
  [ "$warn_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 parallel-file-overlap WARNING for unidirectional parallel, got $warn_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention the shared file
  grep -q "src/renderer.cpp" "$stderr_out" || {
    echo "FAIL: expected 'src/renderer.cpp' mentioned in parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 3b — suppression on the canonical (lower-ordinal) reporter must not
# silence the diag for the whole pair.
#
# Issue #1 (ordinal 0) has <!-- sharkrite-plan-lint disable parallel-file-overlap -->
# and declares "(can run in parallel with #2)". Issue #2 (ordinal 1) is NOT
# suppressed and also declares "(can run in parallel with #1)". Both modify
# the same file. Without the fix, _pi=0 hits the suppression early-continue,
# then _pi=1 defers to the "lower-ordinal canonical reporter" and also
# continues — no diag is ever emitted. With the fix, _pi=1 detects that
# _pj=0 is suppressed and steps up as the emitter.
# Expected: exactly ONE parallel-file-overlap WARNING, exit 0.
# ---------------------------------------------------------------------------

@test "Fix 3b: suppression on canonical lower-ordinal reporter — higher-ordinal steps up, one WARNING emitted" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix3b.txt"

  cat > "$issues_file" <<FIXTURE
---ISSUE---
TITLE: Render alpha (suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha renderer with parallel-file-overlap suppression.

<!-- ${RITE_MARKER_PLAN_LINT} disable parallel-file-overlap - Reason: alpha's overlap with beta is intentional -->

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Alpha passes: \`make test\`

**Done Definition**: Done when alpha passes.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Render beta (not suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta renderer, no suppression — should still receive the diag for the pair.

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Beta passes: \`make test\`

**Done Definition**: Done when beta passes.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (parallel-file-overlap is informational)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly ONE parallel-file-overlap WARNING.
  # Without the fix: 0 warnings (canonical suppressed, higher deferred — silent).
  # With the fix:    1 warning (higher-ordinal steps up as emitter).
  # grep only for the WARNING: prefix to avoid matching [suppressed] INFO lines.
  local warn_count
  warn_count=$(grep -c "strict-lint: WARNING: parallel-file-overlap:" "$stderr_out" || true)
  [ "$warn_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 parallel-file-overlap WARNING (higher-ordinal steps up), got $warn_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention the shared file
  grep -q "src/renderer.cpp" "$stderr_out" || {
    echo "FAIL: expected 'src/renderer.cpp' in parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 3b (both suppressed) — when BOTH sides have parallel-file-overlap
# suppressed, no diag should be emitted.
#
# Both issues have the suppression marker. No parallel-file-overlap WARNING.
# Exit 0.
# ---------------------------------------------------------------------------

@test "Fix 3b: both sides suppressed — no parallel-file-overlap WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix3b-both.txt"

  cat > "$issues_file" <<FIXTURE
---ISSUE---
TITLE: Render alpha (suppressed both)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha renderer, suppression on both sides.

<!-- ${RITE_MARKER_PLAN_LINT} disable parallel-file-overlap - Reason: overlap is intentional -->

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Alpha passes: \`make test\`

**Done Definition**: Done when alpha passes.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Render beta (suppressed both)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta renderer, also suppressed.

<!-- ${RITE_MARKER_PLAN_LINT} disable parallel-file-overlap - Reason: overlap is intentional -->

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Beta passes: \`make test\`

**Done Definition**: Done when beta passes.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit any parallel-file-overlap WARNING — both sides suppressed
  # grep only for the WARNING: prefix to avoid false-matching [suppressed] INFO lines.
  grep -q "strict-lint: WARNING: parallel-file-overlap:" "$stderr_out" && {
    echo "FAIL: unexpected parallel-file-overlap WARNING when both sides are suppressed" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fix 3b (suppression on higher-ordinal only) — canonical lower-ordinal
# reporter is NOT suppressed, so it emits normally.
#
# Issue #2 (ordinal 1) has suppression, issue #1 (ordinal 0) does NOT.
# The canonical reporter for bidirectional pairs is the lower-ordinal issue.
# Since _pi=0 is not suppressed, it emits. _pi=1 is suppressed → skipped.
# Expected: exactly ONE parallel-file-overlap WARNING, exit 0.
# ---------------------------------------------------------------------------

@test "Fix 3b: suppression on higher-ordinal only — canonical lower-ordinal still emits one WARNING" {
  local issues_file="$RITE_TEST_TMPDIR/issues-fix3b-higher.txt"

  cat > "$issues_file" <<FIXTURE
---ISSUE---
TITLE: Render loop one (not suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Lower-ordinal issue without suppression — canonical reporter.

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] One passes: \`make test\`

**Done Definition**: Done when one passes.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Render loop two (suppressed)
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Higher-ordinal issue with suppression — should not prevent lower-ordinal from emitting.

<!-- ${RITE_MARKER_PLAN_LINT} disable parallel-file-overlap - Reason: overlap with #1 is known -->

**Claude Context**:
Files to Modify:
- src/renderer.cpp

**Acceptance Criteria**:
- [ ] Two passes: \`make test\`

**Done Definition**: Done when two passes.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly ONE parallel-file-overlap WARNING (from the canonical lower-ordinal)
  # grep only for the WARNING: prefix to avoid matching [suppressed] INFO lines.
  local warn_count
  warn_count=$(grep -c "strict-lint: WARNING: parallel-file-overlap:" "$stderr_out" || true)
  [ "$warn_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 parallel-file-overlap WARNING from canonical lower-ordinal, got $warn_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must mention the shared file
  grep -q "src/renderer.cpp" "$stderr_out" || {
    echo "FAIL: expected 'src/renderer.cpp' in parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Non-overlapping parallel — issues that are parallel but modify DIFFERENT
# files must produce no parallel-file-overlap WARNING.
# ---------------------------------------------------------------------------

@test "Non-overlapping parallel issues — no parallel-file-overlap WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-nooverlap.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Widget alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Alpha widget in its own file.

**Claude Context**:
Files to Modify:
- src/widget_alpha.cpp

**Acceptance Criteria**:
- [ ] Alpha passes: `make test`

**Done Definition**: Done when alpha passes.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Widget beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Beta widget in a different file.

**Claude Context**:
Files to Modify:
- src/widget_beta.cpp

**Acceptance Criteria**:
- [ ] Beta passes: `make test`

**Done Definition**: Done when beta passes.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for non-overlapping parallel, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a parallel-file-overlap WARNING (files are disjoint)
  grep -q "parallel-file-overlap:" "$stderr_out" && {
    echo "FAIL: unexpected parallel-file-overlap WARNING for non-overlapping parallel issues" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# AC1 — auto-chain basic: unsuppressed parallel-file-overlap is deterministically
# rewritten (not warned).
#
# Two issues, neither suppressed, both modify src/auth.ts.  Issue #2 declares
# "(can run in parallel with #1)".  Expected:
#   - exit 0
#   - INFO (not WARNING) about parallel-file-overlap for the rewrite
#   - issues_file rewritten: issue #2's Dependencies → "After #1"
#   - no WARNING: parallel-file-overlap line in stderr
# ---------------------------------------------------------------------------

@test "AC1: unsuppressed parallel-file-overlap — auto-chain rewrites file, emits INFO not WARNING" {
  local issues_file="$RITE_TEST_TMPDIR/issues-ac1.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Setup Auth Routes
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Sets up the base auth routes in src/auth.ts.

**Claude Context**:
Files to Modify:
- src/auth.ts

**Acceptance Criteria**:
- [ ] Routes registered: `npm test -- --testPathPattern=auth`

**Done Definition**: Done when routes are registered.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Add Auth Middleware
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Adds middleware to src/auth.ts.

**Claude Context**:
Files to Modify:
- src/auth.ts

**Acceptance Criteria**:
- [ ] Middleware active: `npm test -- --testPathPattern=middleware`

**Done Definition**: Done when middleware is active.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit an INFO (auto-chained) message, not a WARNING for this overlap
  grep -q "parallel-file-overlap" "$stderr_out" || {
    echo "FAIL: expected parallel-file-overlap in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a WARNING for parallel-file-overlap (auto-chain path, not warn-only)
  grep -q "WARNING: parallel-file-overlap" "$stderr_out" && {
    echo "FAIL: unexpected WARNING for parallel-file-overlap (expected auto-chain INFO)" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issues file must have been rewritten: issue #2 now has After #1
  grep -q "After #1" "$issues_file" || {
    echo "FAIL: expected 'After #1' in rewritten issues file" >&2
    cat "$issues_file" >&2
    false
  }

  # The parallel annotation must have been removed from issue #2's Dependencies
  grep "Add Auth Middleware" "$issues_file" || true  # title still present
  sed -n '/^TITLE: Add Auth Middleware/,/^---END---$/p' "$issues_file" | grep -q "can run in parallel with #1" && {
    echo "FAIL: parallel annotation not removed from issue #2's Dependencies" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# AC4 — three-way transitive: A←B←C resolved sequentially.
#
# A (ordinal 1) creates src/a.py.  B (ordinal 2) modifies src/a.py and
# src/b.py, declared parallel with #1.  C (ordinal 3) modifies src/b.py,
# declared parallel with #2.  None have suppression markers.
# Expected after auto-chain:
#   - B's Dependencies → "After #1"
#   - C's Dependencies → "After #2"
#   - Two INFO lines in stderr
#   - exit 0
# ---------------------------------------------------------------------------

@test "AC4: three-way transitive A←B←C — both B and C get chained in sequence" {
  local issues_file="$RITE_TEST_TMPDIR/issues-ac4.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Create Schema A
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Creates src/schema_a.py.

**Claude Context**:
Files to Modify:
- src/schema_a.py

**Acceptance Criteria**:
- [ ] Schema present: `python -m pytest tests/test_schema_a.py`

**Done Definition**: Done when schema A is present.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Extend Schema A with Indexes
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Extends src/schema_a.py with indexes; also creates src/schema_b.py.

**Claude Context**:
Files to Modify:
- src/schema_a.py
- src/schema_b.py

**Acceptance Criteria**:
- [ ] Indexes present: `python -m pytest tests/test_indexes.py`

**Done Definition**: Done when indexes exist.

**Dependencies**: None (can run in parallel with #1)
---END---
---ISSUE---
TITLE: Add Schema B Relations
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Adds foreign-key relations to src/schema_b.py.

**Claude Context**:
Files to Modify:
- src/schema_b.py

**Acceptance Criteria**:
- [ ] Relations present: `python -m pytest tests/test_relations.py`

**Done Definition**: Done when relations exist.

**Dependencies**: None (can run in parallel with #2)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit two INFO auto-chain messages
  local info_count
  info_count=$(grep -c "auto-chained.*parallel-file-overlap" "$stderr_out" || true)
  [ "$info_count" -eq 2 ] || {
    echo "FAIL: expected 2 auto-chain INFO messages, got $info_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # B must be rewritten: After #1
  grep "Extend Schema A with Indexes" "$issues_file" || true
  sed -n '/^TITLE: Extend Schema A with Indexes/,/^---END---$/p' "$issues_file" | grep -q "After #1" || {
    echo "FAIL: expected B (Extend Schema A) to have After #1" >&2
    cat "$issues_file" >&2
    false
  }

  # C must be rewritten: After #2
  grep "Add Schema B Relations" "$issues_file" || true
  sed -n '/^TITLE: Add Schema B Relations/,/^---END---$/p' "$issues_file" | grep -q "After #2" || {
    echo "FAIL: expected C (Add Schema B Relations) to have After #2" >&2
    cat "$issues_file" >&2
    false
  }

  # No parallel-file-overlap WARNING (all auto-chained)
  grep -q "WARNING: parallel-file-overlap" "$stderr_out" && {
    echo "FAIL: unexpected WARNING for parallel-file-overlap (expected auto-chain)" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# AC5 — spike + non-spike ordinal: auto-chain uses non-spike ordinal #N
# when spikes are prepended to the slate.
#
# 1 spike + impl-A (non-spike ordinal 1, modifies src/x.py) + impl-B
# (non-spike ordinal 2, modifies src/x.py, parallel with #1).  Neither
# impl has a suppression marker.
# Expected:
#   - exit 0
#   - impl-B rewritten to "After #1" (non-spike ordinal 1 = impl-A)
#   - INFO names impl-A and impl-B (not the spike)
# ---------------------------------------------------------------------------

@test "AC5: spike-prepended slate — auto-chain uses non-spike ordinal in rewrite" {
  local issues_file="$RITE_TEST_TMPDIR/issues-ac5.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture svc.db sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
References `svc.db`.
## Task
Call `svc.db`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Create DB Schema
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Creates the initial schema in src/db_schema.py.

**Claude Context**:
Files to Modify:
- src/db_schema.py

**Acceptance Criteria**:
- [ ] Schema created: `python -m pytest tests/test_schema.py`

**Done Definition**: Done when schema is created.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Add DB Indexes
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Adds indexes to src/db_schema.py — same file as schema creation.

**Claude Context**:
Files to Modify:
- src/db_schema.py

**Acceptance Criteria**:
- [ ] Indexes added: `python -m pytest tests/test_indexes.py`

**Done Definition**: Done when indexes are added.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit INFO about auto-chain naming the non-spike issues
  grep -q "auto-chained.*parallel-file-overlap" "$stderr_out" || {
    echo "FAIL: expected auto-chain INFO in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # The INFO must mention "After #1" (non-spike ordinal 1 = Create DB Schema)
  grep "auto-chained" "$stderr_out" | grep -q "After #1" || {
    echo "FAIL: expected 'After #1' in auto-chain INFO (non-spike ordinal)" >&2
    cat "$stderr_out" >&2
    false
  }

  # The INFO must NOT name the spike
  grep "auto-chained" "$stderr_out" | grep -q "spike:" && {
    echo "FAIL: auto-chain INFO incorrectly names the spike issue" >&2
    cat "$stderr_out" >&2
    false
  }

  # impl-B (Add DB Indexes) must be rewritten with After #1 in the file
  sed -n '/^TITLE: Add DB Indexes/,/^---END---$/p' "$issues_file" | grep -q "After #1" || {
    echo "FAIL: expected 'Add DB Indexes' to be rewritten with After #1" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Ordinal collision regression: After #12 must not satisfy the After #1 check.
#
# Fixture: issue #12 (ordinal 12) modifies src/x.py.  Issue #13 modifies
# src/x.py and declares parallel with #12.  Issue #13 already has "After #12"
# from a prior chain.  The auto-chain pass should NOT treat "After #12" as
# satisfying the "add After #1" step when ordinal 1 is different from 12.
#
# This tests the word-boundary grep fix: grep -qE "After #N([^0-9]|$)" must
# not match "After #12" when N=1.
# ---------------------------------------------------------------------------

@test "Ordinal collision: After #12 does not satisfy After #1 check — both rewrites distinct" {
  local issues_file="$RITE_TEST_TMPDIR/issues-ordinal-collision.txt"

  # Build a fixture with 12 non-spike issues so ordinals 1 and 12 both exist.
  # Issue 1 (ordinal 1) modifies src/common.py.
  # Issue 12 (ordinal 12) modifies src/common.py — parallel with #1.
  # After auto-chain: issue 12 gets "After #1" (not confused by "After #12" elsewhere).
  local _fixture=""
  _fixture="${_fixture}---ISSUE---
TITLE: Issue Ordinal One
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
First issue.

**Claude Context**:
Files to Modify:
- src/common.py

**Acceptance Criteria**:
- [ ] Done: \`true\`

**Done Definition**: Done when present.

**Dependencies**: None
---END---
"
  # Issues 2-11: placeholders that don't touch src/common.py
  local _i
  for _i in 2 3 4 5 6 7 8 9 10 11; do
    _fixture="${_fixture}---ISSUE---
TITLE: Placeholder Issue ${_i}
LABELS: backend,priority-low
TIME: 30min
BODY:
**Description**:
Placeholder.

**Claude Context**:
Files to Modify:
- src/other_${_i}.py

**Acceptance Criteria**:
- [ ] Done: \`true\`

**Done Definition**: Done.

**Dependencies**: None
---END---
"
  done
  # Issue 12 (ordinal 12): modifies src/common.py, parallel with ordinal #1
  _fixture="${_fixture}---ISSUE---
TITLE: Issue Ordinal Twelve
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Twelfth issue.

**Claude Context**:
Files to Modify:
- src/common.py

**Acceptance Criteria**:
- [ ] Done: \`true\`

**Done Definition**: Done when complete.

**Dependencies**: After #12 (can run in parallel with #1)
---END---
"
  printf '%s' "$_fixture" > "$issues_file"

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit INFO auto-chain naming issue 12 and After #1
  grep -q "auto-chained.*parallel-file-overlap" "$stderr_out" || {
    echo "FAIL: expected auto-chain INFO" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issue Ordinal Twelve must now have After #1 (not a substring match false-positive)
  sed -n '/^TITLE: Issue Ordinal Twelve/,/^---END---$/p' "$issues_file" | grep -q "After #1" || {
    echo "FAIL: expected 'Issue Ordinal Twelve' to have After #1" >&2
    cat "$issues_file" >&2
    false
  }

  # After #1 must be a word-boundary match — not accidentally matching After #12 as After #1
  sed -n '/^TITLE: Issue Ordinal Twelve/,/^---END---$/p' "$issues_file" | grep -qE "After #1([^0-9]|$)" || {
    echo "FAIL: 'After #1' not found as a whole-number ref (word-boundary check)" >&2
    cat "$issues_file" >&2
    false
  }

  # After #12 must survive — the word-boundary guard must not have consumed or removed it
  sed -n '/^TITLE: Issue Ordinal Twelve/,/^---END---$/p' "$issues_file" | grep -qE "After #12([^0-9]|$)" || {
    echo "FAIL: 'After #12' was not preserved after auto-chain rewrite" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# _autochain_remove_par_annotation: earlier issue's parallel annotation removed
# when _pi < _pj (the auto-chain targets the later issue).
#
# Fixture: Issue Alpha (ordinal 1) annotates "(can run in parallel with #2)"
# and both modify src/shared.py.  _pi=1 < _pj=2 path fires:
#   _autochain_rewrite_deps adds After #1 to Issue Beta
#   _autochain_remove_par_annotation removes (can run in parallel with #2) from Issue Alpha
#
# Also asserts second-pass idempotency: re-running _lint_issues_strict on the
# rewritten file exits 0 and emits no additional auto-chain INFO.
# ---------------------------------------------------------------------------

@test "Auto-chain _pi<_pj: earlier-issue parallel annotation removed; second-pass idempotent" {
  local issues_file="$RITE_TEST_TMPDIR/issues-early-annotation.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Issue Alpha
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
First issue.

**Claude Context**:
Files to Modify:
- src/shared.py

**Acceptance Criteria**:
- [ ] Done: `true`

**Done Definition**: Done when present.

**Dependencies**: None (can run in parallel with #2)
---END---
---ISSUE---
TITLE: Issue Beta
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Second issue.

**Claude Context**:
Files to Modify:
- src/shared.py

**Acceptance Criteria**:
- [ ] Done: `true`

**Done Definition**: Done when second.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issue Beta must have been auto-chained with After #1
  sed -n '/^TITLE: Issue Beta/,/^---END---$/p' "$issues_file" | grep -q "After #1" || {
    echo "FAIL: expected 'Issue Beta' to have After #1" >&2
    cat "$issues_file" >&2
    false
  }

  # Issue Alpha's parallel annotation referencing Beta (#2) must have been removed
  sed -n '/^TITLE: Issue Alpha/,/^---END---$/p' "$issues_file" | grep -q "can run in parallel with #2" && {
    echo "FAIL: expected 'Issue Alpha' parallel annotation to be removed" >&2
    cat "$issues_file" >&2
    false
  }

  # Second pass: idempotency — no auto-chain rewrites on re-run
  local stderr_out2
  stderr_out2=$(mktemp)
  local exit_code2=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out2" || exit_code2=$?

  [ "$exit_code2" -eq 0 ] || {
    echo "FAIL: second pass expected exit 0, got $exit_code2" >&2
    cat "$stderr_out2" >&2
    false
  }

  grep -q "auto-chained" "$stderr_out2" && {
    echo "FAIL: second pass should not emit auto-chain INFO" >&2
    cat "$stderr_out2" >&2
    false
  }

  rm -f "$stderr_out" "$stderr_out2"
}

# ---------------------------------------------------------------------------
# Check 8 — duplicate verification commands across issues
#
# Fixture: two issues both carry `grep -rn "aren't live" tests/ returns nothing`
# in their acceptance criteria. Expected: WARNING naming both titles and the
# command; exit 0.
# ---------------------------------------------------------------------------

@test "Check 8: duplicate non-allowlisted verification command — WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-dup-verif.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Remove stale live-check string from screen A
LABELS: frontend,priority-high
TIME: 30min
BODY:
**Description**:
Remove the stale string from screen A.

**Claude Context**:
Files to Modify:
- src/screens/screen_a.py

**Acceptance Criteria**:
- [ ] String removed: `grep -rn "aren't live" tests/ returns nothing`

**Verification Commands**:
```bash
grep -rn "aren't live" tests/ returns nothing
make check
```

**Done Definition**: Done when string is absent.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Remove stale live-check string from screen B
LABELS: frontend,priority-high
TIME: 30min
BODY:
**Description**:
Remove the stale string from screen B.

**Claude Context**:
Files to Modify:
- src/screens/screen_b.py

**Acceptance Criteria**:
- [ ] String removed: `grep -rn "aren't live" tests/ returns nothing`

**Verification Commands**:
```bash
grep -rn "aren't live" tests/ returns nothing
make check
```

**Done Definition**: Done when string is absent.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (WARNING only, not hard error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for duplicate-verification, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a duplicate-verification WARNING
  grep -q "strict-lint: WARNING: duplicate-verification:" "$stderr_out" || {
    echo "FAIL: expected duplicate-verification WARNING in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNING must name both issue titles
  grep -q "Remove stale live-check string from screen A" "$stderr_out" || {
    echo "FAIL: WARNING must name the first issue title" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -q "Remove stale live-check string from screen B" "$stderr_out" || {
    echo "FAIL: WARNING must name the second issue title" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNING must quote the duplicated command
  grep -q "aren't live" "$stderr_out" || {
    echo "FAIL: WARNING must include the duplicated command text" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Check 8 — allowlisted commands (make check) shared by multiple issues
# must NOT produce a duplicate-verification WARNING.
# ---------------------------------------------------------------------------

@test "Check 8: shared allowlisted command (make check) — no WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-allowlist.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Add widget alpha
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Add widget alpha.

**Claude Context**:
Files to Modify:
- src/widget_alpha.py

**Acceptance Criteria**:
- [ ] Lints clean: `make check`

**Verification Commands**:
```bash
make check
```

**Done Definition**: Done when widget alpha is added.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Add widget beta
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Add widget beta.

**Claude Context**:
Files to Modify:
- src/widget_beta.py

**Acceptance Criteria**:
- [ ] Lints clean: `make check`

**Verification Commands**:
```bash
make check
```

**Done Definition**: Done when widget beta is added.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for allowlisted-only shared command, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a duplicate-verification WARNING
  grep -q "duplicate-verification:" "$stderr_out" && {
    echo "FAIL: unexpected duplicate-verification WARNING for allowlisted command" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Check 8 — issues with entirely distinct verification commands must produce
# no duplicate-verification WARNING.
# ---------------------------------------------------------------------------

@test "Check 8: unique verification commands across issues — no WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-unique-verif.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Add login endpoint
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Add a login endpoint.

**Claude Context**:
Files to Modify:
- src/auth/login.py

**Acceptance Criteria**:
- [ ] Login works: `pytest tests/test_login.py -v`

**Verification Commands**:
```bash
pytest tests/test_login.py -v
```

**Done Definition**: Done when login endpoint is added.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Add logout endpoint
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Add a logout endpoint.

**Claude Context**:
Files to Modify:
- src/auth/logout.py

**Acceptance Criteria**:
- [ ] Logout works: `pytest tests/test_logout.py -v`

**Verification Commands**:
```bash
pytest tests/test_logout.py -v
```

**Done Definition**: Done when logout endpoint is added.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for unique verification commands, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a duplicate-verification WARNING
  grep -q "duplicate-verification:" "$stderr_out" && {
    echo "FAIL: unexpected duplicate-verification WARNING for unique commands" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Check 8 — issue with duplicate-verification suppression marker must NOT
# produce a duplicate-verification WARNING; [suppressed] must be logged.
# ---------------------------------------------------------------------------

@test "Check 8 H8d: duplicate-verification suppression — no WARNING, [suppressed] logged, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-dup-verif-suppressed.txt"

  cat > "$issues_file" <<FIXTURE
---ISSUE---
TITLE: Remove stale check from module A (suppressed)
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Remove stale check from module A.

<!-- ${RITE_MARKER_PLAN_LINT} disable duplicate-verification - Reason: modules A and B are verified by the same grep intentionally during the migration window -->

**Claude Context**:
Files to Modify:
- src/module_a.py

**Acceptance Criteria**:
- [ ] Check absent: \`grep -rn "stale-marker" src/ returns nothing\`

**Verification Commands**:
\`\`\`bash
grep -rn "stale-marker" src/
\`\`\`

**Done Definition**: Done when stale-marker is absent from module A.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Remove stale check from module B
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Remove stale check from module B.

**Claude Context**:
Files to Modify:
- src/module_b.py

**Acceptance Criteria**:
- [ ] Check absent: \`grep -rn "stale-marker" src/ returns nothing\`

**Verification Commands**:
\`\`\`bash
grep -rn "stale-marker" src/
\`\`\`

**Done Definition**: Done when stale-marker is absent from module B.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 with duplicate-verification suppressed, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a duplicate-verification WARNING
  grep -q "strict-lint: WARNING: duplicate-verification:" "$stderr_out" && {
    echo "FAIL: unexpected duplicate-verification WARNING despite suppression marker" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must log [suppressed] to show suppression was applied
  grep -q "\[suppressed\]" "$stderr_out" || {
    echo "FAIL: expected '[suppressed]' in stderr to show suppression was applied" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must mention the rule that was suppressed
  grep -q "duplicate-verification" "$stderr_out" || {
    echo "FAIL: expected 'duplicate-verification' in suppression log" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Check 8 — universal gate: a command shared by ≥3 issues is a CI gate, not
# a duplicated deliverable; must produce zero duplicate-verification WARNINGs.
#
# Motivating case: orrery run where 15 of 26 warnings fired on `pnpm typecheck`
# shared across 7 issues.  The hardcoded allowlist does not contain
# `pnpm typecheck`, so without the frequency rule all 21 pairs would warn.
# ---------------------------------------------------------------------------

@test "Check 8: command shared by 7 issues is a universal gate — no WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-universal-gate.txt"

  local _body
  _body=""
  local _i
  for _i in 1 2 3 4 5 6 7; do
    _body="${_body}---ISSUE---
TITLE: Migrate component ${_i} to new type system
LABELS: tech-debt,priority-medium
TIME: 30min
BODY:
**Description**:
Migrate component ${_i} to the new type system.

**Claude Context**:
Files to Modify:
- src/components/comp_${_i}.ts

**Acceptance Criteria**:
- [ ] Types clean: \`pnpm typecheck\`

**Verification Commands**:
\`\`\`bash
pnpm typecheck
\`\`\`

**Done Definition**: Done when component ${_i} passes typecheck.

**Dependencies**: None
---END---
"
  done
  printf '%s' "$_body" > "$issues_file"

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # The shared `pnpm typecheck` is a universal gate — must produce no duplicate-verification warning
  grep -q "duplicate-verification:" "$stderr_out" && {
    echo "FAIL: unexpected duplicate-verification WARNING for universal gate command" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Check 8 — 2-issue distinctive duplicate: a command shared by exactly 2
# issues on a 2-issue slate is NOT a universal gate and must still warn.
# Regression guard for the #1134 motivating case.
# ---------------------------------------------------------------------------

@test "Check 8: distinctive command shared by exactly 2 issues still warns — WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-2issue-distinctive.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Fix caching in module A
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Fix caching in module A.

**Claude Context**:
Files to Modify:
- src/module_a.py

**Acceptance Criteria**:
- [ ] Cache cleared: `redis-cli flushdb`

**Verification Commands**:
```bash
redis-cli flushdb
```

**Done Definition**: Done when cache is cleared in module A.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Fix caching in module B
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Fix caching in module B.

**Claude Context**:
Files to Modify:
- src/module_b.py

**Acceptance Criteria**:
- [ ] Cache cleared: `redis-cli flushdb`

**Verification Commands**:
```bash
redis-cli flushdb
```

**Done Definition**: Done when cache is cleared in module B.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Only 2 issues share this command — below the universal gate threshold — must warn
  grep -q "strict-lint: WARNING: duplicate-verification:" "$stderr_out" || {
    echo "FAIL: expected duplicate-verification WARNING for 2-issue distinctive duplicate" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Check 8 H8e — 3-of-3 distinctive duplicate: a command shared by ALL 3 issues
# on a 3-issue slate reaches freq=3 (== _VERIF_UNIV_THRESHOLD) but must NOT be
# silently exempted.  Without the _VERIF_UNIV_MIN_SLATE=4 floor, the absolute
# threshold fires on the strongest-possible duplicate signal and produces no
# warning — defeating Check 8's purpose for small slates.
# ---------------------------------------------------------------------------

@test "Check 8 H8e: distinctive command shared by all 3 issues on a 3-issue slate — WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-3of3-distinctive.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Migrate widget A to new schema
LABELS: tech-debt,priority-medium
TIME: 30min
BODY:
**Description**:
Migrate widget A to the new database schema.

**Claude Context**:
Files to Modify:
- src/widgets/widget_a.py

**Acceptance Criteria**:
- [ ] Migration passes: `db-migrate --validate widgets`

**Verification Commands**:
```bash
db-migrate --validate widgets
```

**Done Definition**: Done when widget A migration passes validation.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Migrate widget B to new schema
LABELS: tech-debt,priority-medium
TIME: 30min
BODY:
**Description**:
Migrate widget B to the new database schema.

**Claude Context**:
Files to Modify:
- src/widgets/widget_b.py

**Acceptance Criteria**:
- [ ] Migration passes: `db-migrate --validate widgets`

**Verification Commands**:
```bash
db-migrate --validate widgets
```

**Done Definition**: Done when widget B migration passes validation.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Migrate widget C to new schema
LABELS: tech-debt,priority-medium
TIME: 30min
BODY:
**Description**:
Migrate widget C to the new database schema.

**Claude Context**:
Files to Modify:
- src/widgets/widget_c.py

**Acceptance Criteria**:
- [ ] Migration passes: `db-migrate --validate widgets`

**Verification Commands**:
```bash
db-migrate --validate widgets
```

**Done Definition**: Done when widget C migration passes validation.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # All 3 issues share a distinctive command — freq reaches the absolute threshold
  # but the slate is too small for the frequency exemption.  Must warn.
  grep -q "strict-lint: WARNING: duplicate-verification:" "$stderr_out" || {
    echo "FAIL: expected duplicate-verification WARNING for 3-of-3 distinctive duplicate on small slate" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Regression: Check 4 receives single-token backtick paths from acceptance criteria
#
# A single-token backtick entry (no space) in acceptance criteria — e.g.
# `src/handler.ts` — must reach Check 4 and trigger a path warning when the
# file is not in Files to Modify or the repo. Before the fix, `grep ' '` at
# extraction silently dropped these, making Check 4 blind to typo'd paths.
# ---------------------------------------------------------------------------

@test "regression: single-token backtick path in acceptance criteria reaches Check 4 — WARNING emitted" {
  local issues_file="$RITE_TEST_TMPDIR/issues-check4-backtick.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Add handler module
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Add a handler module.

**Claude Context**:
Files to Modify:
- src/router.py

**Acceptance Criteria**:
- [ ] Handler module exists: `src/handler.ts`

**Done Definition**: Done when handler is added.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (Check 4 is a warning, not an error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for Check 4 path warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING mentioning the single-token path
  grep -q "src/handler.ts" "$stderr_out" || {
    echo "FAIL: expected Check 4 WARNING for single-token backtick path 'src/handler.ts'" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "regression: single-token backtick path that exists in Files to Modify — no Check 4 warning" {
  local issues_file="$RITE_TEST_TMPDIR/issues-check4-backtick-ok.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Add handler module
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Add a handler module.

**Claude Context**:
Files to Modify:
- src/handler.ts

**Acceptance Criteria**:
- [ ] Handler module exists: `src/handler.ts`

**Done Definition**: Done when handler is added.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 when single-token backtick path is in Files to Modify, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT warn about handler.ts since it is in Files to Modify
  grep -q "verification path not produced\|not in Files to Modify" "$stderr_out" && {
    echo "FAIL: unexpected Check 4 warning for path that is in Files to Modify" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H9a — 2hr estimate without Split rationale → WARNING, exit 0
# ---------------------------------------------------------------------------

@test "Fixture H9a: 2hr without Split rationale — WARNING naming the issue, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h9a.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: [Phase 1] Implement full CRUD router - users
LABELS: backend,priority-high
TIME: 2hr
BODY:
**Description**:
Add all five CRUD endpoints for the user resource.

**Claude Context**:
Files to Modify:
- src/routers/users.py

**Acceptance Criteria**:
- [ ] All endpoints return correct status codes: `pytest tests/test_users.py`

**Verification Commands**:
```bash
pytest tests/test_users.py
```

**Done Definition**: Done when all 5 endpoints pass their tests and CI is green.

**Scope Boundary**:
- DO: implement user CRUD router
- DO NOT: add auth middleware

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (WARNING, not error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for 2hr-split-rationale warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING mentioning the check name
  grep -q "2hr-split-rationale" "$stderr_out" || {
    echo "FAIL: expected 2hr-split-rationale WARNING in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must name the issue in the warning
  grep -q "Implement full CRUD router" "$stderr_out" || {
    echo "FAIL: expected issue title in 2hr-split-rationale WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H9b — 2hr estimate WITH Split rationale → silent, exit 0
# ---------------------------------------------------------------------------

@test "Fixture H9b: 2hr with Split rationale line — no WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h9b.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: [Phase 1] Implement full CRUD router - users
LABELS: backend,priority-high
TIME: 2hr
BODY:
**Description**:
Add all five CRUD endpoints for the user resource.

Split rationale: GET list + POST share the same schema validation logic; splitting would duplicate that validation across two PRs with no clean seam.

**Claude Context**:
Files to Modify:
- src/routers/users.py

**Acceptance Criteria**:
- [ ] All endpoints return correct status codes: `pytest tests/test_users.py`

**Verification Commands**:
```bash
pytest tests/test_users.py
```

**Done Definition**: Done when all 5 endpoints pass their tests and CI is green.

**Scope Boundary**:
- DO: implement user CRUD router
- DO NOT: add auth middleware

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 when Split rationale is present, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit the 2hr-split-rationale warning
  grep -q "2hr-split-rationale" "$stderr_out" && {
    echo "FAIL: unexpected 2hr-split-rationale WARNING when Split rationale is present" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H9c — 1hr estimate without Split rationale → silent, exit 0
# ---------------------------------------------------------------------------

@test "Fixture H9c: 1hr estimate — no 2hr-split-rationale WARNING, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h9c.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: [Phase 1] Add GET list endpoint - users
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
Add the GET /users list endpoint.

**Claude Context**:
Files to Modify:
- src/routers/users.py

**Acceptance Criteria**:
- [ ] Returns 200 with user list: `pytest tests/test_users.py::test_list`

**Verification Commands**:
```bash
pytest tests/test_users.py::test_list
```

**Done Definition**: Done when test_list passes.

**Scope Boundary**:
- DO: add GET /users endpoint
- DO NOT: add other CRUD endpoints

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for 1hr issue, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit 2hr-split-rationale warning for a 1hr issue
  grep -q "2hr-split-rationale" "$stderr_out" && {
    echo "FAIL: unexpected 2hr-split-rationale WARNING for 1hr issue" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H9d — 2hr with suppression → no WARNING, [suppressed] logged, exit 0
# ---------------------------------------------------------------------------

@test "Fixture H9d: 2hr with 2hr-split-rationale suppression — no WARNING, suppressed logged, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h9d.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: [Phase 1] Implement full CRUD router - users
LABELS: backend,priority-high
TIME: 2hr
BODY:
**Description**:
Add all five CRUD endpoints for the user resource.

<!-- sharkrite-plan-lint disable 2hr-split-rationale - Reason: ADR D3 mandates all user CRUD ships as one atomic PR for the rollback contract -->

**Claude Context**:
Files to Modify:
- src/routers/users.py

**Acceptance Criteria**:
- [ ] All endpoints return correct status codes: `pytest tests/test_users.py`

**Verification Commands**:
```bash
pytest tests/test_users.py
```

**Done Definition**: Done when all 5 endpoints pass their tests and CI is green.

**Scope Boundary**:
- DO: implement user CRUD router
- DO NOT: add auth middleware

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 with suppression, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit the 2hr-split-rationale WARNING
  grep -q "WARNING.*2hr-split-rationale" "$stderr_out" && {
    echo "FAIL: unexpected 2hr-split-rationale WARNING despite suppression" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must log [suppressed] for the rule
  grep -q "\[suppressed\].*2hr-split-rationale" "$stderr_out" || {
    echo "FAIL: expected [suppressed] log for 2hr-split-rationale" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Spi-1 — spike-prepended slate: valid non-spike ordinal dep passes
#
# Two prepended spike blocks shift file positions by 2.  An impl issue that
# says "After #1" means non-spike ordinal 1 (= impl-A, raw pos 3), NOT the
# first spike (raw pos 1).  The linter must interpret the ref in non-spike
# ordinal space and emit no error.
# ---------------------------------------------------------------------------

@test "Fixture Spi-1: 2 spikes + impl issue with After #1 — no error, parallel-overlap names non-spike #1" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spi1.txt"

  # Alpha and Beta both modify src/shared.py.  Beta declares itself parallel with
  # non-spike #1 (= Alpha).  Check 7 must warn "parallel-file-overlap" and name
  # "Implement Feature Alpha" — not the spike — proving #1 resolved in non-spike
  # ordinal space.  (On the pre-fix raw-ordinal code, #1 pointed at the first spike,
  # so the warning would have named that spike instead.)
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture external.api sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background

An emitted issue references `external.api`.

## Task

Make one real call to `external.api`.

**Dependencies**: None
---END---
---ISSUE---
TITLE: spike: capture other.service sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background

An emitted issue references `other.service`.

## Task

Make one real call to `other.service`.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Implement Feature Alpha
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
First implementation task.

**Claude Context**:
Files to Modify:
- src/shared.py

**Acceptance Criteria**:
- [ ] Alpha works: `python -m pytest tests/test_alpha.py`

**Done Definition**: Done when alpha works.

**Scope Boundary**:
**DO**: Implement alpha.
**DO NOT**: Implement beta.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Implement Feature Beta
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Second implementation task, runs concurrently with Alpha on shared.py.

**Claude Context**:
Files to Modify:
- src/shared.py

**Acceptance Criteria**:
- [ ] Beta works: `python -m pytest tests/test_beta.py`

**Done Definition**: Done when beta works.

**Scope Boundary**:
**DO**: Implement beta.
**DO NOT**: Implement alpha.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 — parallel-file-overlap is a WARNING, not an error
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 (parallel-overlap is a warning), got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit any dependency error
  grep -qi "unresolved.*dep\|dangling.*ref\|ERROR.*#1" "$stderr_out" && {
    echo "FAIL: unexpected dependency error for non-spike ordinal ref #1" >&2
    cat "$stderr_out" >&2
    false
  }

  # Check 7 must emit a parallel-file-overlap warning
  grep -q "parallel-file-overlap" "$stderr_out" || {
    echo "FAIL: expected parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must name 'Implement Feature Alpha' (non-spike ordinal 1), not a spike
  grep "parallel-file-overlap" "$stderr_out" | grep -q "Implement Feature Alpha" || {
    echo "FAIL: parallel-file-overlap warning should name 'Implement Feature Alpha' (non-spike ordinal 1)" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must NOT name the spike as the parallel sibling
  grep "parallel-file-overlap" "$stderr_out" | grep -q "spike:" && {
    echo "FAIL: parallel-file-overlap warning incorrectly names a spike issue" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Spi-2 — spike-prepended slate: out-of-range non-spike ordinal is dangling
#
# Two spikes + 2 impl issues → _nonspike_count=2.  A dep ref of #3 is beyond
# the non-spike batch range and not in existing issues → dangling ref ERROR.
# With the old raw-ordinal logic the ref #3 fell inside [1..4] (raw count) and
# was silently treated as valid; new logic correctly rejects it.
# ---------------------------------------------------------------------------

@test "Fixture Spi-2: 2 spikes + dep #3 beyond non-spike count — dangling ref ERROR" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spi2.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture api.host sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
An emitted issue references `api.host`.
## Task
Make one real call to `api.host`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: spike: capture db.host sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
An emitted issue references `db.host`.
## Task
Make one real call to `db.host`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Setup Database
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Sets up the database.

**Claude Context**:
Files to Modify:
- src/db.py

**Acceptance Criteria**:
- [ ] DB runs: `python -m pytest tests/test_db.py`

**Done Definition**: Done when db runs.

**Scope Boundary**:
**DO**: Set up db.
**DO NOT**: Build API.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Build API Layer
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Builds the API, depends on a non-existent issue #3 (only 2 non-spike issues exist).

**Claude Context**:
Files to Modify:
- src/api.py

**Acceptance Criteria**:
- [ ] API runs: `python -m pytest tests/test_api.py`

**Done Definition**: Done when api runs.

**Scope Boundary**:
**DO**: Build api.
**DO NOT**: Build db.

**Dependencies**: After #3
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero — #3 exceeds the non-spike count of 2
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for out-of-range non-spike ordinal #3, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit unresolved ref error mentioning #3
  grep -qi "unresolved.*#3\|#3.*not in batch" "$stderr_out" || {
    echo "FAIL: expected unresolved ref error for #3" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Spi-3 — Check 7: spike-prepended slate, parallel ref resolves correctly
#
# 1 spike + impl-A (modifies src/x.py) + impl-B (modifies src/x.py, parallel #1).
# Non-spike ordinal 1 = impl-A (raw array idx 1 after the spike at idx 0).
# Check 7 must warn about impl-A and impl-B sharing src/x.py — naming impl-A
# (not the spike) as the parallel sibling.
# ---------------------------------------------------------------------------

@test "Fixture Spi-3: Check 7 parallel-overlap names correct non-spike issue when spikes present" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spi3.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture svc.host sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
An emitted issue references `svc.host`.
## Task
Make one real call to `svc.host`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Render Dashboard
LABELS: frontend,priority-high
TIME: 1hr
BODY:
**Description**:
Renders the main dashboard view.

**Claude Context**:
Files to Modify:
- src/dashboard.ts

**Acceptance Criteria**:
- [ ] Dashboard renders: `npm test -- --testPathPattern=dashboard`

**Done Definition**: Done when dashboard renders.

**Scope Boundary**:
**DO**: Render dashboard.
**DO NOT**: Add chart.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Add Chart Widget
LABELS: frontend,priority-high
TIME: 1hr
BODY:
**Description**:
Adds a chart widget. Can run in parallel with dashboard rendering since they
touch disjoint sections, but both need dashboard.ts.

**Claude Context**:
Files to Modify:
- src/dashboard.ts

**Acceptance Criteria**:
- [ ] Widget renders: `npm test -- --testPathPattern=chart`

**Done Definition**: Done when widget renders.

**Scope Boundary**:
**DO**: Add chart widget.
**DO NOT**: Modify render logic.

**Dependencies**: None (can run in parallel with #1)
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (parallel-file-overlap is a WARNING, not an error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, parallel-file-overlap is a warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a parallel-file-overlap WARNING mentioning the correct titles
  grep -q "parallel-file-overlap" "$stderr_out" || {
    echo "FAIL: expected parallel-file-overlap WARNING" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must name 'Render Dashboard' (non-spike ordinal 1), not the spike
  grep "parallel-file-overlap" "$stderr_out" | grep -q "Render Dashboard" || {
    echo "FAIL: parallel-file-overlap warning should name 'Render Dashboard' (non-spike ordinal 1)" >&2
    cat "$stderr_out" >&2
    false
  }

  # The warning must NOT name the spike as the parallel sibling
  grep "parallel-file-overlap" "$stderr_out" | grep -q "spike:" && {
    echo "FAIL: parallel-file-overlap warning incorrectly names a spike issue" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Spi-4 — cycle detection: spike-prepended slate, valid non-spike dep
# passes cycle check (no false cycle)
#
# 2 spikes + A (non-spike #1) + B (non-spike #2) + C (non-spike #3).
# A depends on non-spike #3 (= C).  Non-spike ordinal space: A→C, valid DAG.
# Pre-fix raw-ordinal code mapped #3 to raw idx 2 (= A itself), producing a
# false A→A self-loop that Kahn's reported as a cycle.  New code correctly
# resolves #3 to raw idx 4 (= C) and finds no cycle.
# ---------------------------------------------------------------------------

@test "Fixture Spi-4: 2 spikes + A depends on non-spike #3 — no false cycle (passes cycle check)" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spi4.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture svc.alpha sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
References `svc.alpha`.
## Task
Call `svc.alpha`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: spike: capture svc.beta sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
References `svc.beta`.
## Task
Call `svc.beta`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Build Module A
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Builds module A, depends on module C being ready.

**Claude Context**:
Files to Modify:
- src/module_a.py

**Acceptance Criteria**:
- [ ] Module A works: `python -m pytest tests/test_module_a.py`

**Done Definition**: Done when module A passes tests.

**Scope Boundary**:
**DO**: Build module A.
**DO NOT**: Build module B or C.

**Dependencies**: After #3
---END---
---ISSUE---
TITLE: Build Module B
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Builds module B, independent.

**Claude Context**:
Files to Modify:
- src/module_b.py

**Acceptance Criteria**:
- [ ] Module B works: `python -m pytest tests/test_module_b.py`

**Done Definition**: Done when module B passes tests.

**Scope Boundary**:
**DO**: Build module B.
**DO NOT**: Build module A or C.

**Dependencies**: None
---END---
---ISSUE---
TITLE: Build Module C
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Builds module C, the shared dependency.

**Claude Context**:
Files to Modify:
- src/module_c.py

**Acceptance Criteria**:
- [ ] Module C works: `python -m pytest tests/test_module_c.py`

**Done Definition**: Done when module C passes tests.

**Scope Boundary**:
**DO**: Build module C.
**DO NOT**: Build module A or B.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 — After #3 resolves to Build Module C (non-spike ordinal 3),
  # which is a valid DAG edge A→C with no cycle.
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for valid non-spike ordinal #3 dep (A to C), got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit any cycle or dangling-ref error
  grep -qi "cycle detected\|unresolved.*#3" "$stderr_out" && {
    echo "FAIL: unexpected cycle or dangling-ref error for valid non-spike ordinal #3" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Spi-5 — cycle detection: genuine 2-node cycle detected in non-spike space
#
# 2 spikes + A (non-spike #1, After #2) + B (non-spike #2, After #1).
# A-B and B-A form a genuine cycle in non-spike ordinal space.
# Pre-fix raw-ordinal code mapped A's #2 to raw idx 1 (= spike1) and B's #1
# to raw idx 0 (= spike0) — no cycle in raw space, so it silently passed.
# New code correctly builds edges A-B and B-A and reports the cycle.
# ---------------------------------------------------------------------------

@test "Fixture Spi-5: 2 spikes + genuine A-B cycle in non-spike space — cycle ERROR detected" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spi5.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture api.host sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
References `api.host`.
## Task
Call `api.host`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: spike: capture db.host sample for grounding
LABELS: spike,tech-debt
TIME: 30min
BODY:
## Background
References `db.host`.
## Task
Call `db.host`.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Setup Schema
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Sets up the schema, depends on the API layer being ready.

**Claude Context**:
Files to Modify:
- src/schema.py

**Acceptance Criteria**:
- [ ] Schema works: `python -m pytest tests/test_schema.py`

**Done Definition**: Done when schema passes tests.

**Scope Boundary**:
**DO**: Set up schema.
**DO NOT**: Build API.

**Dependencies**: After #2
---END---
---ISSUE---
TITLE: Build API Layer
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Builds the API layer, depends on the schema being ready.

**Claude Context**:
Files to Modify:
- src/api.py

**Acceptance Criteria**:
- [ ] API works: `python -m pytest tests/test_api.py`

**Done Definition**: Done when API passes tests.

**Scope Boundary**:
**DO**: Build API.
**DO NOT**: Set up schema.

**Dependencies**: After #1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero — Setup Schema (#1) and Build API Layer (#2) form a cycle
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for genuine A-B cycle, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a cycle-detected ERROR
  grep -qi "cycle detected" "$stderr_out" || {
    echo "FAIL: expected 'cycle detected' error for genuine A-B non-spike cycle" >&2
    cat "$stderr_out" >&2
    false
  }

  # The cycle message must name non-spike ordinals (Setup Schema and Build API Layer),
  # not the spikes — confirming cycle detection operates in non-spike ordinal space
  grep -i "cycle detected" "$stderr_out" | grep -qE "Setup Schema|Build API Layer" || {
    echo "FAIL: cycle error should name the impl issues, not the spikes" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}
