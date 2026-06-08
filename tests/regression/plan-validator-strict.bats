#!/usr/bin/env bats
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

  # Stub print_* functions so output goes cleanly without terminal setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Extract _lint_issues_strict from plan-issues.sh.
  eval "$(awk '
    /^_lint_issues_strict\(\)/ { in_fn=1; depth=0 }
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
    /^_lint_issues_strict\(\)/ { in_fn=1; depth=0 }
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
    /^generate_issues\(\)/ { in_fn=1; depth=0 }
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
    /^_lint_issues_strict\(\)/ { in_fn=1; depth=0 }
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
