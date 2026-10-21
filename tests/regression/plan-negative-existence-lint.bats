#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh::_lint_negative_existence_claims
#
# Regression tests for _lint_negative_existence_claims in plan-issues.sh.
#
# Two live orrery blocking instances motivate this lint:
#   Round 3: "no adult_confirmed_at migration" — column existed at init.sql:17
#   Round 6: "there is no find_profile_by_username function yet" — function at init.sql:363
#
# Fixtures:
#   R3 — round-3 shape: snake_case ident on "no migration" line; fixture .sql has column
#        → Stage 1 hits, Stage 2 returns CONTRADICTED → WARNING emitted
#   R6 — round-6 shape: "there is no X yet"; fixture .sql has function
#        → Stage 1 hits, Stage 2 returns CONTRADICTED → WARNING emitted
#   SC — scoped-consistent: claim about an integration layer; ident exists in fixture .sql
#        but triage returns CONSISTENT → no warning (dropped silently)
#   CL — clean plan: no negative-existence phrases → no git grep, no provider call
#   SU — suppression with Reason: field → no warning, [suppressed] logged
#   SU2 — suppression without Reason: field → warning "missing Reason", rule runs
#   UV — triage provider unavailable (returns non-zero) → (unvalidated) warning emitted

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract _lint_negative_existence_claims from plan-issues.sh.
# Uses the same awk brace-depth technique as plan-validator-strict.bats.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/repo"

  # Source canonical marker constants so suppression regex interpolates correctly
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/markers.sh"
  set +u; set +o pipefail

  # Stub print_* functions
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Default provider stubs — tests override these per-scenario
  provider_resolve_model() { echo "stub-haiku"; }
  provider_run_prompt()    { echo "CONTRADICTED"; return 0; }

  # Extract _lint_negative_existence_claims from plan-issues.sh
  eval "$(awk '
    /^_lint_negative_existence_claims[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

  # Initialize a real git repo with fixture SQL files so git grep works.
  # Git config is only set for tests — never touches the user's global config.
  mkdir -p "$RITE_TEST_TMPDIR/repo/sql"
  git -C "$RITE_TEST_TMPDIR/repo" init -q
  git -C "$RITE_TEST_TMPDIR/repo" config user.email "test@example.com"
  git -C "$RITE_TEST_TMPDIR/repo" config user.name "Test"
  # Round-3 fixture: adult_confirmed_at as a column in schema
  cat > "$RITE_TEST_TMPDIR/repo/sql/init.sql" <<'SQL_EOF'
-- users table
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  adult_confirmed_at TIMESTAMP NOT NULL,
  username TEXT NOT NULL
);

-- find profile by username
CREATE OR REPLACE FUNCTION find_profile_by_username(p_username TEXT)
RETURNS TABLE (id INT, username TEXT) AS $$
BEGIN
  RETURN QUERY SELECT id, username FROM users WHERE username = p_username;
END;
$$ LANGUAGE plpgsql;
SQL_EOF
  git -C "$RITE_TEST_TMPDIR/repo" add sql/init.sql
  git -C "$RITE_TEST_TMPDIR/repo" commit -q -m "init schema"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a minimal valid issue block to a file
# ---------------------------------------------------------------------------
_write_issue_file() {
  local outfile="$1"
  local body="$2"
  cat > "$outfile" <<ISSUE_EOF
---ISSUE---
TITLE: Test Issue
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
${body}

**Done Definition**: Done when complete.

**Dependencies**: None
---END---
ISSUE_EOF
}

# ---------------------------------------------------------------------------
# Fixture R3 — round-3 shape: "no adult_confirmed_at migration"
# ---------------------------------------------------------------------------

@test "R3: 'no adult_confirmed_at migration' line — warns CONTRADICTED with file:line" {
  local issues_file="$RITE_TEST_TMPDIR/issues-r3.txt"
  _write_issue_file "$issues_file" \
    "There is no adult_confirmed_at migration needed since this is a new schema."

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  # Must exit 0 (warn-only, never fatal)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # Must emit a WARNING containing 'adult_confirmed_at'
  grep -q "adult_confirmed_at" "$stderr_out" || {
    echo "FAIL: expected WARNING for adult_confirmed_at, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # WARNING must include a file:line reference (e.g. sql/init.sql:4)
  grep -qE "sql/init\.sql:[0-9]+" "$stderr_out" || {
    echo "FAIL: expected file:line reference in warning, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Fixture R6 — round-6 shape: "there is no find_profile_by_username function yet"
# ---------------------------------------------------------------------------

@test "R6: 'there is no find_profile_by_username function yet' — warns CONTRADICTED with file:line" {
  local issues_file="$RITE_TEST_TMPDIR/issues-r6.txt"
  _write_issue_file "$issues_file" \
    "There is no find_profile_by_username function yet so we need to add it."

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  grep -q "find_profile_by_username" "$stderr_out" || {
    echo "FAIL: expected WARNING for find_profile_by_username, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }

  grep -qE "sql/init\.sql:[0-9]+" "$stderr_out" || {
    echo "FAIL: expected file:line reference in warning, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Fixture SC — scoped-consistent: triage returns CONSISTENT → no warning
# ---------------------------------------------------------------------------

@test "SC: scoped-consistent claim — triage returns CONSISTENT, no warning emitted" {
  # Override provider stub: return CONSISTENT for this test
  provider_run_prompt() { echo "CONSISTENT"; return 0; }

  local issues_file="$RITE_TEST_TMPDIR/issues-sc.txt"
  _write_issue_file "$issues_file" \
    "There is no find_profile_by_username API endpoint yet at the HTTP layer."

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # No WARNING should be emitted for CONSISTENT verdicts
  if grep -q "WARNING:.*negative-existence" "$stderr_out"; then
    echo "FAIL: expected no WARNING for CONSISTENT verdict, got:" >&2
    cat "$stderr_out" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Fixture CL — clean plan: no negative-existence phrases → zero provider calls
# ---------------------------------------------------------------------------

@test "CL: clean plan with no negative-existence phrases — zero provider calls, no warnings" {
  # Track provider calls
  local _call_count=0
  provider_run_prompt() { _call_count=$((_call_count + 1)); echo "CONTRADICTED"; return 0; }

  local issues_file="$RITE_TEST_TMPDIR/issues-cl.txt"
  _write_issue_file "$issues_file" \
    "This issue adds authentication middleware to the existing handler pipeline."

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # Zero Stage 2 calls (Stage 1 found nothing to check)
  [ "$_call_count" -eq 0 ] || {
    echo "FAIL: expected 0 provider calls, got $_call_count" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # No warnings
  if grep -q "WARNING:.*negative-existence" "$stderr_out"; then
    echo "FAIL: expected no WARNING for clean plan, got:" >&2
    cat "$stderr_out" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Fixture SU — suppression with Reason: field → no warning, [suppressed] logged
# ---------------------------------------------------------------------------

@test "SU: suppression with Reason field — no warning emitted, [suppressed] logged" {
  local issues_file="$RITE_TEST_TMPDIR/issues-su.txt"
  cat > "$issues_file" <<'ISSUE_EOF'
---ISSUE---
TITLE: Suppressed Issue
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
There is no adult_confirmed_at migration needed.
<!-- sharkrite-plan-lint disable negative-existence - Reason: claim is about a separate migration batch -->

**Done Definition**: Done when complete.

**Dependencies**: None
---END---
ISSUE_EOF

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # No WARNING for the suppressed issue
  if grep -q "WARNING:.*negative-existence" "$stderr_out"; then
    echo "FAIL: expected no WARNING for suppressed issue, got:" >&2
    cat "$stderr_out" >&2
    return 1
  fi

  # [suppressed] info must be logged
  grep -q "\[suppressed\]" "$stderr_out" || {
    echo "FAIL: expected [suppressed] log line, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Fixture SU2 — suppression without Reason: → warns "missing Reason", rule runs
# ---------------------------------------------------------------------------

@test "SU2: suppression without Reason field — warning about missing Reason, rule still runs" {
  local issues_file="$RITE_TEST_TMPDIR/issues-su2.txt"
  cat > "$issues_file" <<'ISSUE_EOF'
---ISSUE---
TITLE: Bad Suppression Issue
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
There is no adult_confirmed_at migration needed.
<!-- sharkrite-plan-lint disable negative-existence -->

**Done Definition**: Done when complete.

**Dependencies**: None
---END---
ISSUE_EOF

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # Must warn about missing Reason field
  grep -q "missing required Reason" "$stderr_out" || {
    echo "FAIL: expected 'missing required Reason' warning, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # Rule must still run: adult_confirmed_at hits → WARNING
  grep -q "adult_confirmed_at" "$stderr_out" || {
    echo "FAIL: expected rule to run and warn about adult_confirmed_at, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Fixture UV — provider unavailable → (unvalidated) tag in warning
# ---------------------------------------------------------------------------

@test "UV: triage provider unavailable — (unvalidated) tag in warning, exit 0" {
  # Override provider stub: fail to simulate unavailable provider
  provider_run_prompt() { return 1; }

  local issues_file="$RITE_TEST_TMPDIR/issues-uv.txt"
  _write_issue_file "$issues_file" \
    "There is no adult_confirmed_at migration needed since the schema is new."

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_negative_existence_claims "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # Must still emit a WARNING (degraded, not silent)
  grep -q "adult_confirmed_at" "$stderr_out" || {
    echo "FAIL: expected WARNING for adult_confirmed_at, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }

  # WARNING must include the (unvalidated) tag
  grep -q "(unvalidated)" "$stderr_out" || {
    echo "FAIL: expected '(unvalidated)' tag in warning, got:" >&2
    cat "$stderr_out" >&2
    return 1
  }
}
