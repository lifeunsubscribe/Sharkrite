#!/usr/bin/env bats
# tests/regression/plan-validator-strict.bats
#
# Regression tests for _lint_issues_strict in plan-issues.sh.
#
# Feature: deterministic validator for the plan pipeline's final linter stage.
# Checks: acyclic dependency graph, no dangling refs, verification path warnings,
# deferral citation requirements, and per-issue inline suppression markers.
#
# No LLM calls are made — all checks are deterministic. Mirrors
# _lint_provenance_flags (PR #367) in structure and setup.
#
# Fixtures:
#   A — cyclic dep graph (X Blocked by Y, Y Blocked by X): exits non-zero,
#       emits "ERROR: dependency cycle"
#   B — dangling ref to #9999 not in batch and not in existing_issues: exits
#       non-zero, emits "ERROR: unresolved Dependencies ref: #9999"
#   B2 — SPIKE-only dep entry (no numeric #N ref): error must name the correct
#        issue title, not a stale value from the previous loop iteration
#   C — verification command references src/handler.ts not in Files to Modify
#       or repo: emits "WARNING: verification path not produced by this issue",
#       exits 0
#   D — deferral entry with no citation: emits "WARNING: uncited deferral",
#       exits 0
#   E — deferral entry with "> docs/architecture.md:42 says ..." citation:
#       passes silently, exits 0
#   F — issue with <!-- sharkrite-plan-lint disable cycle-check - Reason: ... -->:
#       cycle check skipped for that issue, logs "[suppressed] cycle-check: ...",
#       exits 0 (assuming no other errors)
#   G — suppression marker WITHOUT required "Reason: " field: check is NOT
#       suppressed; validator emits WARNING and runs the check anyway

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract _lint_issues_strict from plan-issues.sh using awk
# brace-depth tracking — same technique as plan-provenance-flag.bats.
# No top-level plan-issues.sh code (network calls, prompts) executes.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub print_* functions so output goes cleanly to stderr
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Load marker constants so RITE_MARKER_PLAN_LINT is available to _lint_issues_strict
  # shellcheck disable=SC1090
  source "${RITE_LIB_DIR}/utils/markers.sh"

  # Extract _lint_issues_strict from plan-issues.sh
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

  # Also extract the nested _dfs_visit helper (defined inside _lint_issues_strict)
  # — eval of the outer function already defines the inner function.
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Fixture A — cyclic dependency graph
#
# Issue X has "Dependencies: Blocked by: BATCH-2"
# Issue Y has "Dependencies: Blocked by: BATCH-1"
# This is a cycle: BATCH-1 → BATCH-2 → BATCH-1
#
# Validator must:
#   - emit "ERROR: dependency cycle"
#   - exit non-zero
# ---------------------------------------------------------------------------

@test "Fixture A: cyclic dep graph exits non-zero and emits ERROR: dependency cycle" {
  local issues_file="$RITE_TEST_TMPDIR/issues-a.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature X → Issue "Implement feature X"
- ✅ Feature Y → Issue "Implement feature Y"

---ISSUE---
TITLE: Implement feature X
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
Implements feature X.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_x.py

**Acceptance Criteria**:
- [ ] Feature X works: `pytest tests/test_x.py`

**Verification Commands**:
```bash
pytest tests/test_x.py
```

**Done Definition**: Done when feature X passes tests.

**Scope Boundary**:
- DO: implement feature X
- DO NOT: implement feature Y

**Dependencies**: Blocked by: BATCH-2
---END---

---ISSUE---
TITLE: Implement feature Y
LABELS: backend,priority-medium
TIME: 1hr
BODY:
**Description**:
Implements feature Y.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_y.py

**Acceptance Criteria**:
- [ ] Feature Y works: `pytest tests/test_y.py`

**Verification Commands**:
```bash
pytest tests/test_y.py
```

**Done Definition**: Done when feature Y passes tests.

**Scope Boundary**:
- DO: implement feature Y
- DO NOT: implement feature X

**Dependencies**: Blocked by: BATCH-1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for cyclic dep graph, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit ERROR mentioning dependency cycle
  grep -qi "dependency cycle" "$stderr_out" || {
    echo "FAIL: expected 'dependency cycle' in output, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture B — dangling dependency ref
#
# Issue references "#9999" which is neither in the batch nor in existing_issues.
#
# Validator must:
#   - emit "ERROR: unresolved Dependencies ref: #9999"
#   - exit non-zero
# ---------------------------------------------------------------------------

@test "Fixture B: dangling ref to #9999 exits non-zero and emits ERROR: unresolved Dependencies ref" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature W → Issue "Implement feature W"

---ISSUE---
TITLE: Implement feature W
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Implements feature W.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_w.py

**Acceptance Criteria**:
- [ ] Feature W works: `pytest tests/test_w.py`

**Verification Commands**:
```bash
pytest tests/test_w.py
```

**Done Definition**: Done when feature W passes tests.

**Scope Boundary**:
- DO: implement feature W

**Dependencies**: After #9999
---END---
FIXTURE

  # Pass empty existing_issues so #9999 is not a known open issue
  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for dangling ref, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit ERROR mentioning unresolved Dependencies ref #9999
  grep -q "unresolved Dependencies ref: #9999" "$stderr_out" || {
    echo "FAIL: expected 'unresolved Dependencies ref: #9999' in output, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture B: known existing issue ref is not flagged as dangling" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b-valid.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature W → Issue "Implement feature W"

---ISSUE---
TITLE: Implement feature W
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Implements feature W.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_w.py

**Acceptance Criteria**:
- [ ] Feature W works: `pytest tests/test_w.py`

**Verification Commands**:
```bash
pytest tests/test_w.py
```

**Done Definition**: Done when feature W passes tests.

**Scope Boundary**:
- DO: implement feature W

**Dependencies**: After #42
---END---
FIXTURE

  # Pass #42 as a known existing open issue
  local existing_issues="#42 Some existing issue [backend]"
  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "$existing_issues" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (ref is valid — present in existing_issues)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for known ref #42, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit an ERROR about dangling ref
  grep -q "unresolved Dependencies ref: #42" "$stderr_out" && {
    echo "FAIL: should not flag #42 as dangling when it is in existing_issues" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture B2 — SPIKE-only dangling ref (no numeric #N ref in same dep entry)
#
# This fixture exercises the stale-_did2_title bug fixed in this PR.
# Two issues are present:
#   Issue "Alpha" — has a numeric dangling ref (#9999) so _did2_title gets set
#   Issue "Beta"  — has ONLY a #SPIKE-missing-spike ref (no numeric #N)
#
# Before the fix, the outer loop's _did2_title was declared local inside the
# `if [ -n "$_refs" ]` block.  bash local is function-scoped, so on the
# second iteration (Beta) the variable still held "Alpha" from the first
# iteration — the SPIKE error would wrongly say "issue 'Alpha'" instead of
# "issue 'Beta'".
#
# Validator must:
#   - emit "ERROR: unresolved SPIKE ref: #SPIKE-missing-spike in issue 'Beta'"
#     (not "in issue 'Alpha'")
#   - exit non-zero
# ---------------------------------------------------------------------------

@test "Fixture B2: SPIKE-only dep entry reports the correct issue title (not stale from prior iteration)" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b2.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Alpha feature → Issue "Alpha"
- ✅ Beta feature → Issue "Beta"

---ISSUE---
TITLE: Alpha
LABELS: backend,priority-high
TIME: 30min
BODY:
**Description**:
Implements Alpha.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/alpha.py

**Acceptance Criteria**:
- [ ] Alpha works: `pytest tests/test_alpha.py`

**Verification Commands**:
```bash
pytest tests/test_alpha.py
```

**Done Definition**: Done when Alpha passes tests.

**Scope Boundary**:
- DO: implement Alpha

**Dependencies**: After #9999
---END---

---ISSUE---
TITLE: Beta
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Implements Beta.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/beta.py

**Acceptance Criteria**:
- [ ] Beta works: `pytest tests/test_beta.py`

**Verification Commands**:
```bash
pytest tests/test_beta.py
```

**Done Definition**: Done when Beta passes tests.

**Scope Boundary**:
- DO: implement Beta

**Dependencies**: Blocked by: #SPIKE-missing-spike
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit non-zero (both errors are hard errors)
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # SPIKE error must name the correct issue ("Beta"), not the stale one ("Alpha")
  grep -q "unresolved SPIKE ref: #SPIKE-missing-spike in issue 'Beta'" "$stderr_out" || {
    echo "FAIL: expected error attributing SPIKE ref to 'Beta', got:" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT attribute the SPIKE error to "Alpha" (stale value regression)
  grep -q "unresolved SPIKE ref: #SPIKE-missing-spike in issue 'Alpha'" "$stderr_out" && {
    echo "FAIL: SPIKE error wrongly attributed to 'Alpha' — stale _did2_title bug not fixed" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture C — verification command references unreachable path
#
# Issue has a verification command that references src/handler.ts, which is:
#   - NOT in Files to Modify
#   - NOT in Files to Read
#   - NOT in the repo (RITE_PROJECT_ROOT is a fresh tmp dir)
#
# Validator must:
#   - emit "WARNING: verification path not produced by this issue: src/handler.ts"
#   - exit 0 (warnings are not gates)
# ---------------------------------------------------------------------------

@test "Fixture C: verification path not in Files to Modify or repo emits WARNING, exits 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature Z → Issue "Add endpoint Z"

---ISSUE---
TITLE: Add endpoint Z
LABELS: backend,priority-medium
TIME: 45min
BODY:
**Description**:
Adds endpoint Z.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/routes.py

**Acceptance Criteria**:
- [ ] Endpoint responds: `curl http://localhost/z`

**Verification Commands**:
```bash
grep "endpoint_z" src/handler.ts
```

**Done Definition**: Done when endpoint Z responds.

**Scope Boundary**:
- DO: add endpoint Z

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (WARNING is not a gate)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for verification path warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit WARNING mentioning the unreachable path
  grep -q "verification path not produced by this issue: src/handler.ts" "$stderr_out" || {
    echo "FAIL: expected WARNING about src/handler.ts, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture C: verification path in Files to Modify is not flagged" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c-ok.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature Z → Issue "Add endpoint Z"

---ISSUE---
TITLE: Add endpoint Z
LABELS: backend,priority-medium
TIME: 45min
BODY:
**Description**:
Adds endpoint Z.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/handler.ts

**Acceptance Criteria**:
- [ ] Endpoint responds: `curl http://localhost/z`

**Verification Commands**:
```bash
grep "endpoint_z" src/handler.ts
```

**Done Definition**: Done when endpoint Z responds.

**Scope Boundary**:
- DO: add endpoint Z

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (path is in Files to Modify)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 when path is in Files to Modify, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit a verification path warning
  grep -q "verification path not produced" "$stderr_out" && {
    echo "FAIL: should not warn about path that is in Files to Modify" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture D — uncited deferral
#
# Coverage checklist has a ⏭️ deferral entry with no citation (no quoted phrase,
# no file:line reference, no block-quote).
#
# Validator must:
#   - emit "WARNING: uncited deferral: ..."
#   - exit 0 (warnings are not gates)
# ---------------------------------------------------------------------------

@test "Fixture D: deferral with no citation emits WARNING: uncited deferral, exits 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-d.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature A → Issue "Add feature A"
- ⏭️ Feature B → Deferred to Phase 2 (will be done later)

---ISSUE---
TITLE: Add feature A
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Adds feature A.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_a.py

**Acceptance Criteria**:
- [ ] Feature A works: `pytest tests/test_a.py`

**Verification Commands**:
```bash
pytest tests/test_a.py
```

**Done Definition**: Done when feature A passes tests.

**Scope Boundary**:
- DO: implement feature A

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (uncited deferral is a WARNING, not an ERROR)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for uncited deferral warning, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit WARNING about uncited deferral
  grep -q "uncited deferral" "$stderr_out" || {
    echo "FAIL: expected 'uncited deferral' in output, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture E — deferral with citation passes silently
#
# Coverage checklist has a ⏭️ deferral entry with "> docs/architecture.md:42
# says ..." citation.
#
# Validator must:
#   - pass silently (no WARNING)
#   - exit 0
# ---------------------------------------------------------------------------

@test "Fixture E: deferral with file:line citation passes silently, exits 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-e.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature A → Issue "Add feature A"
- ⏭️ Feature B → Deferred to Phase 2 (docs/architecture.md:42 says "defer B until A is stable")

---ISSUE---
TITLE: Add feature A
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Adds feature A.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_a.py

**Acceptance Criteria**:
- [ ] Feature A works: `pytest tests/test_a.py`

**Verification Commands**:
```bash
pytest tests/test_a.py
```

**Done Definition**: Done when feature A passes tests.

**Scope Boundary**:
- DO: implement feature A

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

  # Must NOT emit an uncited deferral WARNING
  grep -q "uncited deferral" "$stderr_out" && {
    echo "FAIL: should not warn about deferral that has a file:line citation" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture E: deferral with quoted-phrase citation passes silently" {
  local issues_file="$RITE_TEST_TMPDIR/issues-e-quote.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature A → Issue "Add feature A"
- ⏭️ Feature B → Deferred to Phase 2 ("backend-first strategy requires A before B")

---ISSUE---
TITLE: Add feature A
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Adds feature A.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_a.py

**Acceptance Criteria**:
- [ ] Feature A works: `pytest tests/test_a.py`

**Verification Commands**:
```bash
pytest tests/test_a.py
```

**Done Definition**: Done when feature A passes tests.

**Scope Boundary**:
- DO: implement feature A

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for quoted-phrase citation, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  grep -q "uncited deferral" "$stderr_out" && {
    echo "FAIL: should not warn about deferral that has a quoted-phrase citation" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture F — suppression marker with required Reason: field
#
# Issue X contains:
#   <!-- sharkrite-plan-lint disable cycle-check - Reason: intentional cycle for test -->
# Even though X and Y form a cycle, the check for X is suppressed.
#
# Validator must:
#   - log "[suppressed] cycle-check: ..." to stderr
#   - exit 0 when no other errors exist
# ---------------------------------------------------------------------------

@test "Fixture F: suppression marker with Reason: field skips rule and logs [suppressed]" {
  local issues_file="$RITE_TEST_TMPDIR/issues-f.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature X → Issue "Implement feature X"
- ✅ Feature Y → Issue "Implement feature Y"

---ISSUE---
TITLE: Implement feature X
LABELS: backend,priority-medium
TIME: 1hr
BODY:
<!-- sharkrite-plan-lint disable cycle-check - Reason: intentional mutual dependency for test purposes -->

**Description**:
Implements feature X.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_x.py

**Acceptance Criteria**:
- [ ] Feature X works: `pytest tests/test_x.py`

**Verification Commands**:
```bash
pytest tests/test_x.py
```

**Done Definition**: Done when feature X passes tests.

**Scope Boundary**:
- DO: implement feature X

**Dependencies**: Blocked by: BATCH-2
---END---

---ISSUE---
TITLE: Implement feature Y
LABELS: backend,priority-medium
TIME: 1hr
BODY:
<!-- sharkrite-plan-lint disable cycle-check - Reason: intentional mutual dependency for test purposes -->

**Description**:
Implements feature Y.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_y.py

**Acceptance Criteria**:
- [ ] Feature Y works: `pytest tests/test_y.py`

**Verification Commands**:
```bash
pytest tests/test_y.py
```

**Done Definition**: Done when feature Y passes tests.

**Scope Boundary**:
- DO: implement feature Y

**Dependencies**: Blocked by: BATCH-1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (cycle check is suppressed for both issues)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 when cycle-check is suppressed, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must log [suppressed] cycle-check to stderr (visible suppression)
  grep -q "\[suppressed\] cycle-check" "$stderr_out" || {
    echo "FAIL: expected '[suppressed] cycle-check' in stderr output, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture G — suppression marker WITHOUT required Reason: field
#
# Issue has:
#   <!-- sharkrite-plan-lint disable cycle-check -->
# (no "- Reason: " suffix)
#
# Validator must:
#   - NOT suppress the rule
#   - emit WARNING about missing Reason: field
#   - still run the check (cycle should be detected)
# ---------------------------------------------------------------------------

@test "Fixture G: suppression marker without Reason: does not suppress, emits WARNING, runs check" {
  local issues_file="$RITE_TEST_TMPDIR/issues-g.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature X → Issue "Implement feature X"
- ✅ Feature Y → Issue "Implement feature Y"

---ISSUE---
TITLE: Implement feature X
LABELS: backend,priority-medium
TIME: 1hr
BODY:
<!-- sharkrite-plan-lint disable cycle-check -->

**Description**:
Implements feature X (bad suppression — no Reason: field).

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_x.py

**Acceptance Criteria**:
- [ ] Feature X works: `pytest tests/test_x.py`

**Verification Commands**:
```bash
pytest tests/test_x.py
```

**Done Definition**: Done when feature X passes tests.

**Scope Boundary**:
- DO: implement feature X

**Dependencies**: Blocked by: BATCH-2
---END---

---ISSUE---
TITLE: Implement feature Y
LABELS: backend,priority-medium
TIME: 1hr
BODY:
<!-- sharkrite-plan-lint disable cycle-check -->

**Description**:
Implements feature Y (bad suppression — no Reason: field).

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_y.py

**Acceptance Criteria**:
- [ ] Feature Y works: `pytest tests/test_y.py`

**Verification Commands**:
```bash
pytest tests/test_y.py
```

**Done Definition**: Done when feature Y passes tests.

**Scope Boundary**:
- DO: implement feature Y

**Dependencies**: Blocked by: BATCH-1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must emit WARNING about missing Reason: field
  grep -qi "Reason" "$stderr_out" || {
    echo "FAIL: expected WARNING about missing Reason: field, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must still detect the cycle (suppression didn't fire)
  grep -qi "dependency cycle" "$stderr_out" || {
    echo "FAIL: expected cycle to still be detected when Reason: is missing, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must exit non-zero (cycle was detected)
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit when suppression failed and cycle was detected, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Acceptance: _lint_issues_strict makes zero LLM/provider_run calls
# ---------------------------------------------------------------------------

@test "acceptance: _lint_issues_strict contains no provider_run calls" {
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
# Acceptance: _lint_issues_strict is wired into generate_issues
# ---------------------------------------------------------------------------

@test "acceptance: _lint_issues_strict is wired into generate_issues" {
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
# Acceptance: no new RITE_* env vars introduced as escape hatches
# (spot-check: no new RITE_PLAN_STRICT_* vars in the function body)
# ---------------------------------------------------------------------------

@test "acceptance: _lint_issues_strict introduces no RITE_ env-var escape hatches" {
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

  # Check for any RITE_ variable references used as operator-config escape hatches.
  # Allowed: RITE_PROJECT_ROOT (path), RITE_MARKER_PLAN_LINT (marker constant).
  # Disallowed: any RITE_PLAN_STRICT_* or similar feature-flag vars.
  local rite_vars
  rite_vars=$(echo "$fn_body" | grep -oE '\$\{?RITE_[A-Z_]+' | \
    grep -v 'RITE_PROJECT_ROOT' | \
    grep -v 'RITE_MARKER_PLAN_LINT' | \
    sort -u || true)

  [ -z "$rite_vars" ] || {
    echo "FAIL: _lint_issues_strict references unexpected RITE_ env vars (potential escape hatches):" >&2
    echo "$rite_vars" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Edge case: clean issues file (no cycles, no dangling refs, no warnings)
# passes silently with exit 0
# ---------------------------------------------------------------------------

@test "Edge: clean issues file passes silently with exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-clean.txt"

  cat > "$issues_file" <<'FIXTURE'
COVERAGE:
- ✅ Feature A → Issue "Add feature A"
- ✅ Feature B → Issue "Add feature B"
- ⏭️ Feature C → Deferred to Phase 3 ("not in scope for Phase 1 per ADR-001")

---ISSUE---
TITLE: Add feature A
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Adds feature A.

**Claude Context**:
Files to Read:
- src/base.py

Files to Modify:
- src/feature_a.py

**Acceptance Criteria**:
- [ ] Feature A works: `pytest tests/test_a.py`

**Verification Commands**:
```bash
pytest tests/test_a.py
```

**Done Definition**: Done when feature A passes tests.

**Scope Boundary**:
- DO: implement feature A

**Dependencies**: None
---END---

---ISSUE---
TITLE: Add feature B
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Adds feature B, which depends on A.

**Claude Context**:
Files to Read:
- src/feature_a.py

Files to Modify:
- src/feature_b.py

**Acceptance Criteria**:
- [ ] Feature B works: `pytest tests/test_b.py`

**Verification Commands**:
```bash
pytest tests/test_b.py
```

**Done Definition**: Done when feature B passes tests.

**Scope Boundary**:
- DO: implement feature B

**Dependencies**: After BATCH-1
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_strict "$issues_file" "" 2>"$stderr_out" || exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for clean issues file, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit no ERROR lines
  local error_count
  error_count=$(grep -c "^ERROR:" "$stderr_out" || true)
  [ "$error_count" -eq 0 ] || {
    echo "FAIL: expected 0 ERROR lines for clean file, got $error_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}
