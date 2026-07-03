#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# tests/regression/batch-gate-circuit-breaker.bats
#
# Regression test: batch must trip a circuit breaker when N consecutive issues
# fail their gate with the same failure signature, preventing a doomed
# environment from grinding through all remaining issues.
#
# Issue #823 — "Halt batch on repeated identical gate failures"
#
# Motivation: LeadFlow 2026-06-30–07-01 ran 411 gate failures with 0 passes,
# all sharing the same @leadflow/shared import-resolution signature, while the
# batch kept dispatching issues. +56 net new issues were minted in one day from
# the follow-up issue creation path.
#
# Design:
#   - Signature = sorted unique set of failing test/lint file paths from
#     gate-findings JSON (.tests[].file + .lint[].file, sorted, deduplicated).
#   - N consecutive issues with the same non-empty signature trips the breaker
#     (default N=3, override via RITE_BATCH_GATE_TRIP).
#   - Signature empty (gate skipped, gate crashed) → no contribution to streak.
#   - Any successful issue → streak reset.
#   - Mixed signatures → streak reset on every change.
#   - RITE_BATCH_GATE_TRIP=0 → breaker disabled entirely.
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1. _extract_gate_signature() helper exists in batch-process-issues.sh
#     2. Circuit-breaker state variables initialized
#     3. RITE_BATCH_GATE_TRIP config variable wired up with default
#     4. Breaker trips on RITE_BATCH_GATE_TRIP consecutive matching signatures
#     5. Trip message names the shared signature
#     6. Exit code 16 on circuit-breaker trip
#     7. exit-codes.md documents exit 16 for batch-process-issues.sh
#
#   UNIT (_extract_gate_signature):
#     8. Returns sorted unique file paths from tests[] + lint[] arrays
#     9. Returns empty string for skipped gates
#    10. Returns empty string for missing/nonexistent file
#    11. Bats failures (file="bats") produce signature "bats"
#    12. Mixed tests+lint produces merged sorted signature
#
#   BEHAVIORAL (circuit-breaker logic):
#    13. 3 consecutive same-signature failures trips the breaker (default threshold)
#    14. 2 consecutive same-signature failures does NOT trip (below threshold)
#    15. Mixed signatures do NOT trip (different cause each time)
#    16. Success between identical failures resets the streak
#    17. RITE_BATCH_GATE_TRIP=0 disables the breaker entirely
#    18. Empty signature (gate skipped) does not advance the streak

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$EXIT_CODES_DOC" ] || {
    echo "FATAL: $EXIT_CODES_DOC not found" >&2
    return 1
  }
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify the implementation is in place (static code inspection)
# =============================================================================

@test "structural: _extract_gate_signature() helper exists in batch-process-issues.sh" {
  grep -q '_extract_gate_signature()' "$BATCH_PROCESSOR" || {
    echo "FAIL: _extract_gate_signature() function not found in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: _update_gate_breaker_counter() helper exists in batch-process-issues.sh" {
  grep -q '_update_gate_breaker_counter()' "$BATCH_PROCESSOR" || {
    echo "FAIL: _update_gate_breaker_counter() function not found in batch-process-issues.sh" >&2
    echo "      This function encapsulates the counter-update logic so behavioral tests" >&2
    echo "      can drive it directly rather than re-implementing it." >&2
    return 1
  }
}

@test "structural: circuit-breaker state variables initialized" {
  grep -q '_gate_consec_count=' "$BATCH_PROCESSOR" || {
    echo "FAIL: _gate_consec_count= not found in batch-process-issues.sh" >&2
    return 1
  }
  grep -q '_gate_consec_sig=' "$BATCH_PROCESSOR" || {
    echo "FAIL: _gate_consec_sig= not found in batch-process-issues.sh" >&2
    return 1
  }
  grep -q '_gate_circuit_tripped=' "$BATCH_PROCESSOR" || {
    echo "FAIL: _gate_circuit_tripped= not found in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: RITE_BATCH_GATE_TRIP config var wired with default of 3" {
  grep -qE 'RITE_BATCH_GATE_TRIP.*:-3' "$BATCH_PROCESSOR" || {
    echo "FAIL: RITE_BATCH_GATE_TRIP not initialized with default 3" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh references exit 16 on circuit breaker trip" {
  grep -qE 'exit 16' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'exit 16' not found in batch-process-issues.sh" >&2
    echo "      Circuit breaker trip must exit 16 so callers can detect it" >&2
    return 1
  }
}

@test "structural: trip message names the shared signature" {
  # The trip block must print the signature so operators know what failed.
  # We look for the variable reference in proximity to the trip output.
  grep -qE '_gate_consec_sig' "$BATCH_PROCESSOR" || {
    echo "FAIL: _gate_consec_sig not referenced in batch-process-issues.sh" >&2
    return 1
  }

  # Extract the circuit-breaker trip block (lines around 'Circuit breaker tripped')
  _trip_block=$(grep -A5 'Circuit breaker tripped' "$BATCH_PROCESSOR" || true)
  [ -n "$_trip_block" ] || {
    echo "FAIL: 'Circuit breaker tripped' message not found in batch-process-issues.sh" >&2
    return 1
  }

  # The signature must be printed: either inline or in the following lines
  echo "$_trip_block" | grep -qE '_gate_consec_sig|Shared failure signature' || {
    echo "FAIL: trip message does not reference the shared signature" >&2
    echo "      Found near 'Circuit breaker tripped': $_trip_block" >&2
    return 1
  }
}

@test "structural: exit-codes.md documents exit 16 for batch-process-issues.sh" {
  # The batch-process-issues.sh section of exit-codes.md must document exit 16.
  _batch_section=$(awk '
    /^### `batch-process-issues.sh` \(final process exit\)$/ { in_section=1; next }
    in_section && /^###/ { exit }
    in_section { print $0 }
  ' "$EXIT_CODES_DOC")

  [ -n "$_batch_section" ] || {
    echo "FAIL: Could not find batch-process-issues.sh section in exit-codes.md" >&2
    return 1
  }

  echo "$_batch_section" | grep -q '16' || {
    echo "FAIL: exit 16 not documented in the batch-process-issues.sh section of exit-codes.md" >&2
    return 1
  }
}

# =============================================================================
# UNIT: _extract_gate_signature
# =============================================================================

@test "unit: _extract_gate_signature returns sorted unique file paths from tests+lint" {
  _tmpdir=$(mktemp -d)
  _json_file="$_tmpdir/gate-findings-101.json"

  cat > "$_json_file" <<'EOF'
{
  "lint": [
    {"file": "lib/core/foo.sh", "line": "10", "rule": "SC2086", "message": "word splitting"},
    {"file": "lib/core/foo.sh", "line": "20", "rule": "SC2086", "message": "word splitting again"}
  ],
  "tests": [
    {"file": "tests/unit/bar.bats", "test_name": "test 1", "reason": "assertion failed"},
    {"file": "tests/unit/baz.bats", "test_name": "test 2", "reason": "assertion failed"}
  ],
  "exit_code": 1
}
EOF

  # Source just the function from batch-process-issues.sh
  # Use a subshell to avoid polluting the test environment
  run bash -c "
    RITE_SOURCE_FUNCTIONS_ONLY=1
    # Source only the function definition — not the whole script
    # Extract and eval just the _extract_gate_signature function
    _func_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _extract_gate_signature '${_json_file}'
  "

  [ "$status" -eq 0 ]
  # Expected: lib/core/foo.sh, tests/unit/bar.bats, tests/unit/baz.bats (sorted, deduped)
  [ "$output" = "lib/core/foo.sh,tests/unit/bar.bats,tests/unit/baz.bats" ] || {
    echo "FAIL: expected 'lib/core/foo.sh,tests/unit/bar.bats,tests/unit/baz.bats'" >&2
    echo "       got: '$output'" >&2
    return 1
  }
}

@test "unit: _extract_gate_signature returns empty for skipped gate" {
  _tmpdir=$(mktemp -d)
  _json_file="$_tmpdir/gate-findings-102.json"

  printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"missing_runner"}\n' > "$_json_file"

  run bash -c "
    _func_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _extract_gate_signature '${_json_file}'
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "FAIL: expected empty output for skipped gate, got: '$output'" >&2
    return 1
  }
}

@test "unit: _extract_gate_signature returns empty for nonexistent file" {
  run bash -c "
    _func_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _extract_gate_signature '/nonexistent/path/gate-findings.json'
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "FAIL: expected empty output for missing file, got: '$output'" >&2
    return 1
  }
}

@test "unit: _extract_gate_signature produces 'bats' for bats-only failures" {
  _tmpdir=$(mktemp -d)
  _json_file="$_tmpdir/gate-findings-103.json"

  # bats failures always have file="bats"
  cat > "$_json_file" <<'EOF'
{
  "lint": [],
  "tests": [
    {"file": "bats", "test_name": "some test: should do thing", "reason": "assertion failed"},
    {"file": "bats", "test_name": "another test: should work", "reason": "assertion failed"}
  ],
  "exit_code": 1
}
EOF

  run bash -c "
    _func_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _extract_gate_signature '${_json_file}'
  "

  [ "$status" -eq 0 ]
  # bats failures are identified by file="bats"; dedup produces a single "bats" entry
  [ "$output" = "bats" ] || {
    echo "FAIL: expected 'bats' signature for bats-only failures, got: '$output'" >&2
    return 1
  }
}

@test "unit: _extract_gate_signature merges and deduplicates tests+lint files" {
  _tmpdir=$(mktemp -d)
  _json_file="$_tmpdir/gate-findings-104.json"

  # Same file appears in both lint and tests — should be deduplicated
  cat > "$_json_file" <<'EOF'
{
  "lint": [
    {"file": "lib/core/foo.sh", "line": "5", "rule": "SC2086", "message": "quote"}
  ],
  "tests": [
    {"file": "lib/core/foo.sh", "test_name": "test foo", "reason": "assertion failed"},
    {"file": "lib/utils/bar.sh", "test_name": "test bar", "reason": "assertion failed"}
  ],
  "exit_code": 1
}
EOF

  run bash -c "
    _func_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _extract_gate_signature '${_json_file}'
  "

  [ "$status" -eq 0 ]
  # lib/core/foo.sh appears in both lint and tests — deduplicated to one entry
  [ "$output" = "lib/core/foo.sh,lib/utils/bar.sh" ] || {
    echo "FAIL: expected 'lib/core/foo.sh,lib/utils/bar.sh', got: '$output'" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: circuit-breaker logic (testing the counter update rules)
# These tests exercise the counter update logic extracted from the main script.
# They use a harness that replays the counter logic for a sequence of issues.
# =============================================================================

# Helper: run the circuit-breaker counter logic for a sequence of gate findings.
# Drives the real _update_gate_breaker_counter function extracted from the
# batch processor — not a re-implementation.  This ensures the behavioral tests
# exercise the same code path that the production loop uses, including any
# skip-path handling.
#
# Arguments: threshold, then a list of JSON strings (one per issue, each
#   representing a 'failed' issue with gate findings).
# Outputs: "TRIPPED sig=<sig>" if breaker fires, else "OK count=<n> sig=<sig>".
_run_breaker_sequence() {
  local threshold="$1"
  shift
  local json_args=("$@")

  _tmpdir=$(mktemp -d)

  # Write each JSON arg to a numbered findings file
  local i=0
  for json in "${json_args[@]}"; do
    printf '%s\n' "$json" > "$_tmpdir/gate-findings-$i.json"
    i=$((i + 1))
  done

  # Load both helper functions from the real batch processor and drive them.
  # Using awk to extract each function by name so we don't need to source the
  # entire script (which has top-level executable code that would fail without
  # the full runtime environment).
  run bash -c "
    set -euo pipefail

    # Extract _extract_gate_signature from the real script
    _sig_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_sig_src\"

    # Extract _update_gate_breaker_counter from the real script
    _upd_src=\$(awk '
      /^_update_gate_breaker_counter\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_upd_src\"

    # Circuit-breaker state (mirrors the main loop's variables)
    _gate_consec_count=0
    _gate_consec_sig=''
    _gate_circuit_tripped=false
    RITE_BATCH_GATE_TRIP=${threshold}

    # Process each findings file in sequence, simulating a 'failed' issue.
    # We pass issue_status='failed' so the function treats it as a gate-failure
    # candidate (not a non-failure that would reset the streak).
    for _i in \$(seq 0 $((${#json_args[@]} - 1))); do
      _json='${_tmpdir}/gate-findings-'\${_i}'.json'
      _ret=0
      _update_gate_breaker_counter \"\$_json\" 'failed' || _ret=\$?
      if [ \"\$_ret\" -eq 16 ]; then
        echo \"TRIPPED sig=\${_gate_consec_sig}\"
        exit 0
      fi
    done

    if [ \"\$_gate_circuit_tripped\" = 'false' ]; then
      echo \"OK count=\${_gate_consec_count} sig=\${_gate_consec_sig}\"
    fi
  "
}

@test "behavioral: 3 consecutive same-signature failures trips the breaker (default threshold)" {
  # Three issues, all failing with the same bats signature.
  # Fixture: both issues under a different issue number but same test file failure.
  _tmpdir=$(mktemp -d)

  # All three share the same failing test file
  _same_json='{"lint":[],"tests":[{"file":"tests/unit/shared.bats","test_name":"import fails","reason":"assertion failed"}],"exit_code":1}'

  _run_breaker_sequence 3 "$_same_json" "$_same_json" "$_same_json"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^TRIPPED" || {
    echo "FAIL: expected breaker to trip after 3 consecutive identical signatures" >&2
    echo "      output: $output" >&2
    return 1
  }
  # Trip message must name the signature
  echo "$output" | grep -q "tests/unit/shared.bats" || {
    echo "FAIL: trip output does not mention the failing test file" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "behavioral: 2 consecutive same-signature failures does NOT trip (below threshold=3)" {
  _same_json='{"lint":[],"tests":[{"file":"tests/unit/shared.bats","test_name":"import fails","reason":"assertion failed"}],"exit_code":1}'

  _run_breaker_sequence 3 "$_same_json" "$_same_json"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK" || {
    echo "FAIL: expected OK (no trip) after only 2 consecutive same-signature failures" >&2
    echo "      output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "count=2" || {
    echo "FAIL: expected count=2, got: $output" >&2
    return 1
  }
}

@test "behavioral: mixed signatures do NOT trip the breaker" {
  # Two different failure causes — each resets the other's streak.
  _json_a='{"lint":[],"tests":[{"file":"tests/unit/foo.bats","test_name":"test foo","reason":"assertion failed"}],"exit_code":1}'
  _json_b='{"lint":[],"tests":[{"file":"tests/unit/bar.bats","test_name":"test bar","reason":"assertion failed"}],"exit_code":1}'
  _json_a2='{"lint":[],"tests":[{"file":"tests/unit/foo.bats","test_name":"test foo","reason":"assertion failed"}],"exit_code":1}'

  _run_breaker_sequence 3 "$_json_a" "$_json_b" "$_json_a2"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK" || {
    echo "FAIL: expected OK (no trip) for mixed signatures" >&2
    echo "      output: $output" >&2
    return 1
  }
  # After a→b→a sequence, the current streak is 1 (last was a)
  echo "$output" | grep -q "count=1" || {
    echo "FAIL: expected count=1 after mixed a→b→a sequence, got: $output" >&2
    return 1
  }
}

@test "behavioral: success between identical failures resets the streak" {
  # Pattern: fail(A), success (issue_status=completed → reset), fail(A), fail(A).
  # After the completed-status reset the streak drops to 0, so the two subsequent
  # same-sig failures only reach count=2 — no trip.
  # Drives _update_gate_breaker_counter from the real script directly.
  _tmpdir=$(mktemp -d)
  _same_json='{"lint":[],"tests":[{"file":"tests/unit/shared.bats","test_name":"import fails","reason":"assertion failed"}],"exit_code":1}'

  run bash -c "
    set -euo pipefail

    # Load both helper functions from the real script
    _sig_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_sig_src\"

    _upd_src=\$(awk '
      /^_update_gate_breaker_counter\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_upd_src\"

    _gate_consec_count=0
    _gate_consec_sig=''
    _gate_circuit_tripped=false
    RITE_BATCH_GATE_TRIP=3

    _fail_json='${_tmpdir}/fail.json'
    printf '%s\n' '${_same_json}' > \"\$_fail_json\"

    # Issue 1: fail with same-sig (count=1)
    _ret=0; _update_gate_breaker_counter \"\$_fail_json\" 'failed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED unexpectedly after issue 1'; exit 1; }

    # Issue 2: successful completion → _update_gate_breaker_counter resets streak
    _ret=0; _update_gate_breaker_counter '' 'completed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED unexpectedly after issue 2 (success)'; exit 1; }

    # Issue 3: fail with same-sig again (count=1, not 2 — reset happened)
    _ret=0; _update_gate_breaker_counter \"\$_fail_json\" 'failed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED unexpectedly after issue 3'; exit 1; }

    # Issue 4: fail with same-sig again (count=2 — below threshold of 3)
    _ret=0; _update_gate_breaker_counter \"\$_fail_json\" 'failed' || _ret=\$?
    if [ \"\$_ret\" -eq 16 ]; then
      echo 'TRIPPED'
    else
      echo \"OK count=\${_gate_consec_count}\"
    fi
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK" || {
    echo "FAIL: expected OK (no trip) when success resets streak between same-sig failures" >&2
    echo "      output: $output" >&2
    return 1
  }
  # After reset + 2 same-sig fails, count should be 2
  echo "$output" | grep -q "count=2" || {
    echo "FAIL: expected count=2 after success-reset + 2 same-sig failures, got: $output" >&2
    return 1
  }
}

@test "behavioral: RITE_BATCH_GATE_TRIP=0 disables the breaker entirely" {
  # Even 10 consecutive same-sig failures must not trip when threshold is 0.
  _same_json='{"lint":[],"tests":[{"file":"tests/unit/shared.bats","test_name":"import fails","reason":"assertion failed"}],"exit_code":1}'

  _run_breaker_sequence 0 \
    "$_same_json" "$_same_json" "$_same_json" \
    "$_same_json" "$_same_json" "$_same_json" \
    "$_same_json" "$_same_json" "$_same_json" \
    "$_same_json"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK" || {
    echo "FAIL: expected OK (breaker disabled with RITE_BATCH_GATE_TRIP=0)" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "behavioral: empty signature (gate skipped) does not advance the streak" {
  # A skipped gate produces an empty signature; _update_gate_breaker_counter
  # resets on empty signature (no parseable gate evidence).
  # Sequence: fail(A), skipped(empty sig), fail(A), skipped(empty sig), fail(A)
  # The two skipped entries each reset the streak, so the final count is 1.
  # Drives _update_gate_breaker_counter from the real script directly.
  _same_json='{"lint":[],"tests":[{"file":"tests/unit/shared.bats","test_name":"import fails","reason":"assertion failed"}],"exit_code":1}'
  _skip_json='{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"gate_timeout"}'

  run bash -c "
    set -euo pipefail

    # Load both helper functions from the real script
    _sig_src=\$(awk '
      /^_extract_gate_signature\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_sig_src\"

    _upd_src=\$(awk '
      /^_update_gate_breaker_counter\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH_PROCESSOR}')
    eval \"\$_upd_src\"

    _gate_consec_count=0
    _gate_consec_sig=''
    _gate_circuit_tripped=false
    RITE_BATCH_GATE_TRIP=3

    _tmpdir=\$(mktemp -d)
    printf '%s\n' '${_same_json}' > \"\$_tmpdir/fail.json\"
    printf '%s\n' '${_skip_json}' > \"\$_tmpdir/skip.json\"

    _ret=0
    # Issue 1: fail → count=1, sig=shared.bats
    _update_gate_breaker_counter \"\$_tmpdir/fail.json\" 'failed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED after issue 1'; exit 0; }

    # Issue 2: skipped gate (empty sig) → function resets streak to count=0
    _ret=0; _update_gate_breaker_counter \"\$_tmpdir/skip.json\" 'failed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED after issue 2 (skip)'; exit 0; }

    # Issue 3: fail → count=1 again (not 2 — reset happened)
    _ret=0; _update_gate_breaker_counter \"\$_tmpdir/fail.json\" 'failed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED after issue 3'; exit 0; }

    # Issue 4: skipped gate (empty sig) → reset again
    _ret=0; _update_gate_breaker_counter \"\$_tmpdir/skip.json\" 'failed' || _ret=\$?
    [ \"\$_ret\" -ne 16 ] || { echo 'TRIPPED after issue 4 (skip)'; exit 0; }

    # Issue 5: fail → count=1 once more
    _ret=0; _update_gate_breaker_counter \"\$_tmpdir/fail.json\" 'failed' || _ret=\$?
    if [ \"\$_ret\" -eq 16 ]; then
      echo 'TRIPPED'
    else
      echo \"OK count=\${_gate_consec_count}\"
    fi
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK" || {
    echo "FAIL: expected OK (no trip) — empty signatures reset streak" >&2
    echo "      output: $output" >&2
    return 1
  }
  # After reset-between pattern, count should be 1 (only the last failure counts)
  echo "$output" | grep -q "count=1" || {
    echo "FAIL: expected count=1 after skip-reset pattern, got: $output" >&2
    return 1
  }
}

@test "behavioral: two different issue fixtures with same cause trip the breaker" {
  # Validates spec: "tested with two different-issue/same-cause fixtures"
  # Two different issues both fail because @shared import cannot be resolved —
  # same test files fail in both.
  _issue_a_json='{"lint":[],"tests":[{"file":"packages/api/api.test.ts","test_name":"@shared import fails","reason":"assertion failed"},{"file":"packages/web/web.test.ts","test_name":"@shared import fails","reason":"assertion failed"}],"exit_code":1}'
  _issue_b_json='{"lint":[],"tests":[{"file":"packages/api/api.test.ts","test_name":"@shared import fails","reason":"assertion failed"},{"file":"packages/web/web.test.ts","test_name":"@shared import fails","reason":"assertion failed"}],"exit_code":1}'
  _issue_c_json='{"lint":[],"tests":[{"file":"packages/api/api.test.ts","test_name":"@shared import fails","reason":"assertion failed"},{"file":"packages/web/web.test.ts","test_name":"@shared import fails","reason":"assertion failed"}],"exit_code":1}'

  _run_breaker_sequence 3 "$_issue_a_json" "$_issue_b_json" "$_issue_c_json"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^TRIPPED" || {
    echo "FAIL: expected breaker to trip on 3 same-cause failures from different issues" >&2
    echo "      output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "packages/api/api.test.ts" || {
    echo "FAIL: trip message does not name the shared failing test file" >&2
    echo "      output: $output" >&2
    return 1
  }
}
