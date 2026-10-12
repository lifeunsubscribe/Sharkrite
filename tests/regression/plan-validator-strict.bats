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

  # Extract _lint_issues_strict from plan-issues.sh.
  eval "$(awk '
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
