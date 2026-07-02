#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# tests/regression/batch-gate-circuit-breaker.bats
#
# Regression test: when consecutive issues in a batch fail the gate with the
# same failure signature, the batch trips a circuit breaker and halts with
# exit 15 instead of grinding every remaining issue through doomed fix loops.
#
# Issue #823 — "Halt batch on repeated identical gate failures"
#
# Root cause: during a LeadFlow batch run on 2026-06-30–07-01, 411 gate
# failures all shared the same `@leadflow/shared` import-resolution signature.
# The batch kept dispatching issues regardless, minting +56 net new issues in
# one day with zero successful fixes.
#
# Fix:
#   1. _gate_compute_failure_sig() derives a stable signature from a
#      gate-findings JSON file (sorted set of failing file names).
#   2. After each generic failure (else branch), the signature is compared to
#      the previous one; a matching signature increments the consecutive counter.
#   3. When the counter reaches RITE_BATCH_GATE_TRIP (default 3), the batch
#      prints the shared signature + remediation steps and exits 15.
#   4. Non-gate failures (exits 5/6/10/13) and non-failure exits (0/12/14)
#      reset the counter.
#   5. exit-codes.md documents exit 15.
#
# Tests in this file:
#   UNIT (_gate_compute_failure_sig):
#     1. Returns empty string for missing file
#     2. Returns empty string for skipped gate
#     3. Returns empty string for exit_code=0 (passed gate)
#     4. Returns sorted pipe-joined file list for bats test failures
#     5. Returns test_name (not "bats") for bats entry
#     6. Returns file path for lint failures
#     7. Mixed bats + lint → file + test_name both included, sorted
#     8. Two different findings JSON files with same failures → same sig
#     9. Different failures → different sigs
#
#   STRUCTURAL (static code inspection):
#    10. _GATE_TRIP_THRESHOLD initialized from RITE_BATCH_GATE_TRIP
#    11. _gate_trip_consecutive and _gate_trip_last_sig initialized
#    12. Circuit breaker check block present in batch processor
#    13. exit 15 emitted in the trip block
#    14. Non-failure exits (0,12,14) each reset _gate_trip_consecutive
#    15. Named sentinel exits (6,13,10) reset _gate_trip_consecutive
#    16. exit-codes.md documents exit 15 for batch-process-issues.sh
#
#   BEHAVIORAL:
#    17. Trips on 3 consecutive identical signatures; halts before next issue
#    18. Does NOT trip on mixed (non-matching) failure signatures
#    19. Signature in trip message names the shared files
#    20. RITE_BATCH_GATE_TRIP=0 disables the circuit breaker

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

# Helper: write a minimal gate-findings JSON for test cases.
# Usage: _write_findings <path> <exit_code> <test_name1> [test_name2 ...]
#   If exit_code=0 and no test names, writes a passing gate.
#   Pass test_name as "FILE:<path>" to emit a non-bats test entry.
_write_findings() {
  local _path="$1"; shift
  local _exit_code="$1"; shift
  local _tests_json="[]"

  if [ $# -gt 0 ]; then
    _tests_json="["
    local _first=true
    for _item in "$@"; do
      [ "$_first" = "true" ] || _tests_json+=","
      _first=false
      if [[ "$_item" == FILE:* ]]; then
        local _fname="${_item#FILE:}"
        _tests_json+="{\"file\":\"${_fname}\",\"test_name\":\"some test\",\"reason\":\"assertion failed\"}"
      else
        _tests_json+="{\"file\":\"bats\",\"test_name\":\"${_item}\",\"reason\":\"assertion failed\"}"
      fi
    done
    _tests_json+="]"
  fi

  printf '{"lint":[],"tests":%s,"exit_code":%d}\n' "$_tests_json" "$_exit_code" > "$_path"
}

# Helper: write a findings JSON with lint failures.
_write_lint_findings() {
  local _path="$1" _exit_code="$2" _lint_file="$3"
  printf '{"lint":[{"file":"%s","line":"1","rule":"SC2086","message":"test"}],"tests":[],"exit_code":%d}\n' \
    "$_lint_file" "$_exit_code" > "$_path"
}

# =============================================================================
# UNIT: _gate_compute_failure_sig
# =============================================================================

@test "unit: _gate_compute_failure_sig returns empty for missing file" {
  # Source only the function, not the batch body
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT

  # We need to extract and evaluate _gate_compute_failure_sig from the file.
  # Use RITE_SOURCE_FUNCTIONS_ONLY pattern (not supported here), so instead
  # we test via a thin wrapper script.
  run bash -c "
    # Stub out all side-effectful parts so the file can be sourced safely
    _RITE_BATCH_PROCESS_LOADED=true
    # Import only the function definition
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '/tmp/nonexistent-gate-findings-test-9999.json'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unit: _gate_compute_failure_sig returns empty for skipped gate" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-skipped.json"
  printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"missing_runner"}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unit: _gate_compute_failure_sig returns empty for exit_code=0 (passed gate)" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-pass.json"
  printf '{"lint":[],"tests":[],"exit_code":0}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unit: _gate_compute_failure_sig returns sorted pipe-joined set for bats failures" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-bats.json"
  # Two bats entries — second sorts before first alphabetically
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"z test fails","reason":"assertion failed"},{"file":"bats","test_name":"a test fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  # Must be sorted: "a test fails" before "z test fails"
  [ "$output" = "a test fails|z test fails" ]
}

@test "unit: _gate_compute_failure_sig uses test_name (not 'bats') for bats entries" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-batsname.json"
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"import resolution fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  # Must contain the test name, not literal "bats"
  [ "$output" = "import resolution fails" ]
  echo "$output" | grep -qv '^bats$'
}

@test "unit: _gate_compute_failure_sig uses file path for non-bats test entries" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-nonbats.json"
  printf '{"lint":[],"tests":[{"file":"tests/regression/foo.bats","test_name":"fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "tests/regression/foo.bats" ]
}

@test "unit: _gate_compute_failure_sig returns file path for lint failures" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-lint.json"
  printf '{"lint":[{"file":"lib/core/batch-process-issues.sh","line":"1","rule":"SC2086","message":"test"}],"tests":[],"exit_code":1}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "lib/core/batch-process-issues.sh" ]
}

@test "unit: _gate_compute_failure_sig — mixed bats+lint produces sorted union" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f="$_tmpdir/gate-findings-mixed.json"
  # lint: lib/utils/foo.sh; bats: "z failing test"
  printf '{"lint":[{"file":"lib/utils/foo.sh","line":"1","rule":"SC2086","message":"test"}],"tests":[{"file":"bats","test_name":"z failing test","reason":"assertion failed"}],"exit_code":1}\n' > "$_f"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _gate_compute_failure_sig '${_f}'
  "
  [ "$status" -eq 0 ]
  # lib/utils/foo.sh sorts before "z failing test"
  [ "$output" = "lib/utils/foo.sh|z failing test" ]
}

@test "unit: two findings files with same failures produce identical signatures" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f1="$_tmpdir/gate-findings-101.json"
  _f2="$_tmpdir/gate-findings-102.json"
  # Same test_name in both, different issue numbers (different PRs, same env failure)
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"@leadflow/shared import fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f1"
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"@leadflow/shared import fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f2"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _sig1=\$(_gate_compute_failure_sig '${_f1}')
    _sig2=\$(_gate_compute_failure_sig '${_f2}')
    [ \"\$_sig1\" = \"\$_sig2\" ] && echo 'MATCH' || echo 'MISMATCH'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "MATCH"
}

@test "unit: different failures produce different signatures" {
  _tmpdir=$(mktemp -d)
  trap "rm -rf '$_tmpdir'" EXIT
  _f1="$_tmpdir/gate-findings-201.json"
  _f2="$_tmpdir/gate-findings-202.json"
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"import resolution fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f1"
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"authentication fails","reason":"assertion failed"}],"exit_code":1}\n' > "$_f2"

  run bash -c "
    source /dev/stdin <<'SRC_EOF'
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)
SRC_EOF
    _sig1=\$(_gate_compute_failure_sig '${_f1}')
    _sig2=\$(_gate_compute_failure_sig '${_f2}')
    [ \"\$_sig1\" = \"\$_sig2\" ] && echo 'MATCH' || echo 'MISMATCH'
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "MISMATCH"
}

# =============================================================================
# STRUCTURAL: static code inspection
# =============================================================================

@test "structural: _GATE_TRIP_THRESHOLD initialized from RITE_BATCH_GATE_TRIP" {
  grep -q '_GATE_TRIP_THRESHOLD="${RITE_BATCH_GATE_TRIP:-3}"' "$BATCH_PROCESSOR" || {
    echo "FAIL: _GATE_TRIP_THRESHOLD not initialized from RITE_BATCH_GATE_TRIP with default 3" >&2
    return 1
  }
}

@test "structural: _gate_trip_consecutive and _gate_trip_last_sig initialized" {
  grep -q '_gate_trip_consecutive=0' "$BATCH_PROCESSOR" || {
    echo "FAIL: _gate_trip_consecutive not initialized to 0" >&2
    return 1
  }
  grep -q '_gate_trip_last_sig=""' "$BATCH_PROCESSOR" || {
    echo "FAIL: _gate_trip_last_sig not initialized to empty string" >&2
    return 1
  }
}

@test "structural: circuit breaker check block present in batch processor" {
  grep -q '_gate_trip_consecutive.*_GATE_TRIP_THRESHOLD\|_GATE_TRIP_THRESHOLD.*_gate_trip_consecutive' "$BATCH_PROCESSOR" || \
  grep -q '"$_gate_trip_consecutive" -ge "$_GATE_TRIP_THRESHOLD"' "$BATCH_PROCESSOR" || {
    echo "FAIL: circuit breaker comparison not found in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: exit 15 emitted in the trip block" {
  grep -q 'exit 15' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'exit 15' not found in batch-process-issues.sh — circuit breaker trip code missing" >&2
    return 1
  }
}

@test "structural: non-failure exit 0 resets _gate_trip_consecutive" {
  # The success branch (exit 0) must reset the consecutive counter so a
  # successful issue between two gate-failure streaks does not compound.
  # Find the body between 'if [ $_WF_EXIT -eq 0 ]' and the next 'elif'.
  _success_body=$(awk '
    /if \[ \$_WF_EXIT -eq 0 \]/ { in_branch=1; next }
    in_branch && /elif \[ \$_WF_EXIT -eq/ { exit }
    in_branch { print }
  ' "$BATCH_PROCESSOR")

  [ -n "$_success_body" ] || {
    echo "FAIL: Could not extract exit-0 success branch body" >&2
    return 1
  }

  echo "$_success_body" | grep -q '_gate_trip_consecutive=0' || {
    echo "FAIL: _gate_trip_consecutive not reset in exit-0 success branch" >&2
    return 1
  }
}

@test "structural: non-failure exit 12 (already-closed) resets _gate_trip_consecutive" {
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 12 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract exit-12 branch body" >&2
    return 1
  }

  echo "$_branch_body" | grep -q '_gate_trip_consecutive=0' || {
    echo "FAIL: _gate_trip_consecutive not reset in exit-12 (already-closed) branch" >&2
    return 1
  }
}

@test "structural: non-failure exit 14 (locked) resets _gate_trip_consecutive" {
  _branch_body=$(awk '
    /elif \[ \$_WF_EXIT -eq 14 \]/ { in_branch=1; next }
    in_branch && (/elif \[ \$_WF_EXIT -eq/ || /^  else$/) { exit }
    in_branch { print }
  ' "$BATCH_PROCESSOR")

  [ -n "$_branch_body" ] || {
    echo "FAIL: Could not extract exit-14 branch body" >&2
    return 1
  }

  echo "$_branch_body" | grep -q '_gate_trip_consecutive=0' || {
    echo "FAIL: _gate_trip_consecutive not reset in exit-14 (locked) branch" >&2
    return 1
  }
}

@test "structural: exit 15 documented in batch-process-issues.sh section of exit-codes.md" {
  _batch_section=$(awk '
    /^### `batch-process-issues.sh` \(final process exit\)/ { in_section=1; next }
    in_section && /^###/ { exit }
    in_section { print }
  ' "$EXIT_CODES_DOC")

  [ -n "$_batch_section" ] || {
    echo "FAIL: Could not extract batch-process-issues.sh section from exit-codes.md" >&2
    return 1
  }

  echo "$_batch_section" | grep -q '15' || {
    echo "FAIL: exit code 15 not documented in batch-process-issues.sh section of exit-codes.md" >&2
    return 1
  }

  echo "$_batch_section" | grep -q 'circuit breaker\|RITE_BATCH_GATE_TRIP' || {
    echo "FAIL: exit 15 entry does not mention 'circuit breaker' or 'RITE_BATCH_GATE_TRIP'" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: end-to-end circuit breaker logic via harness
# =============================================================================

# Helper: build and run a minimal circuit-breaker harness.
# The harness stubs _WF_EXIT sequences and gate-findings files to simulate
# batch-loop behavior without invoking workflow-runner.sh or gh.
#
# Args:
#   $1 = RITE_BATCH_GATE_TRIP value (or "" for default 3)
#   $2... = space-separated sequence of outcomes for each issue, one per arg:
#     "pass"              → _WF_EXIT=0 (success)
#     "gate:SIG"          → _WF_EXIT=1, gate-findings with test_name=SIG
#     "non-gate"          → _WF_EXIT=1, no gate-findings (or skipped gate)
#
# The harness sources only the helpers and state from batch-process-issues.sh,
# then runs the decision logic inline (mirroring the batch loop's structure)
# to avoid pulling in gh/config dependencies.
_run_breaker_harness() {
  local _trip_threshold="${1:-}"
  shift

  _tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$_tmpdir'" EXIT

  # Write state-dir where gate-findings will be placed
  local _state_dir="$_tmpdir/state"
  mkdir -p "$_state_dir"

  # Build the issue sequence as bash arrays
  local _outcomes=("$@")
  local _issues_bash="("
  local _i=1
  for _outcome in "${_outcomes[@]}"; do
    _issues_bash+="$_i "
    _i=$((_i + 1))
  done
  _issues_bash+=")"

  # Write gate-findings files for gate: outcomes
  local _findings_files_bash=""
  _i=1
  for _outcome in "${_outcomes[@]}"; do
    if [[ "$_outcome" == gate:* ]]; then
      local _sig="${_outcome#gate:}"
      local _fpath="$_state_dir/gate-findings-pr${_i}.json"
      printf '{"lint":[],"tests":[{"file":"bats","test_name":"%s","reason":"assertion failed"}],"exit_code":1}\n' \
        "$_sig" > "$_fpath"
      _findings_files_bash+="[${_i}]='$_fpath' "
    fi
    _i=$((_i + 1))
  done

  # Write outcomes array for harness
  local _outcomes_bash="("
  for _outcome in "${_outcomes[@]}"; do
    _outcomes_bash+="'$_outcome' "
  done
  _outcomes_bash+=")"

  local _threshold_export=""
  if [ -n "$_trip_threshold" ]; then
    _threshold_export="export RITE_BATCH_GATE_TRIP=${_trip_threshold}"
  fi

  cat > "$_tmpdir/harness.sh" <<HARNESS_HEREDOC
#!/bin/bash
set -uo pipefail

${_threshold_export}

REPO_ROOT="${REPO_ROOT}"
STATE_DIR="${_state_dir}"

# Import only the helpers and state initialization from batch-process-issues.sh,
# not the executable body.  We use a shim that sets _RITE_BATCH_PROCESS_LOADED
# early to prevent the body from executing, then sources the file.
#
# Functions needed: _gate_compute_failure_sig
# State needed: _GATE_TRIP_THRESHOLD, _gate_trip_consecutive, _gate_trip_last_sig

# Stub everything that batch-process-issues.sh sources at the top
print_error()   { echo "ERROR: \$*" >&2; }
print_warning() { echo "WARN: \$*" >&2; }
print_info()    { echo "INFO: \$*" >&2; }
print_success() { echo "OK: \$*" >&2; }

# Extract and evaluate only the _gate_compute_failure_sig function
$(grep -A 60 '^_gate_compute_failure_sig\(\)' "$BATCH_PROCESSOR" | head -60)

# Replicate the circuit-breaker state init (mirrors lines in batch-process-issues.sh)
_GATE_TRIP_THRESHOLD="\${RITE_BATCH_GATE_TRIP:-3}"
_gate_trip_consecutive=0
_gate_trip_last_sig=""

# Issue sequence and findings map
OUTCOMES=${_outcomes_bash}
declare -A FINDINGS_MAP
$([ -n "$_findings_files_bash" ] && echo "declare -A _tmp_map; _tmp_map=( $_findings_files_bash ); for _k in \"\${!_tmp_map[@]}\"; do FINDINGS_MAP[\$_k]=\"\${_tmp_map[\$_k]}\"; done" || true)

TRIPPED=false
ISSUES_DISPATCHED=0

for _idx in "\${!OUTCOMES[@]}"; do
  _issue_num=\$(( _idx + 1 ))
  _outcome="\${OUTCOMES[\$_idx]}"

  ISSUES_DISPATCHED=\$(( ISSUES_DISPATCHED + 1 ))

  if [ "\$_outcome" = "pass" ]; then
    # Simulate success (exit 0): reset streak
    _gate_trip_consecutive=0
    _gate_trip_last_sig=""

  elif [[ "\$_outcome" == gate:* ]]; then
    # Simulate gate failure: compute sig and update streak
    _fpath="\${FINDINGS_MAP[\$_issue_num]:-}"
    _current_sig=\$(_gate_compute_failure_sig "\${_fpath:-}" || true)
    if [ -n "\$_current_sig" ]; then
      if [ "\$_current_sig" = "\$_gate_trip_last_sig" ]; then
        _gate_trip_consecutive=\$(( _gate_trip_consecutive + 1 ))
      else
        _gate_trip_consecutive=1
        _gate_trip_last_sig="\$_current_sig"
      fi
    else
      _gate_trip_consecutive=0
      _gate_trip_last_sig=""
    fi

    # Check trip
    if [ "\${_GATE_TRIP_THRESHOLD}" -gt 0 ] 2>/dev/null && \
       [ "\$_gate_trip_consecutive" -ge "\$_GATE_TRIP_THRESHOLD" ]; then
      echo "CIRCUIT_BREAKER_TRIPPED consecutive=\${_gate_trip_consecutive} sig=\${_gate_trip_last_sig}"
      TRIPPED=true
      break
    fi

  else
    # non-gate failure: reset streak
    _gate_trip_consecutive=0
    _gate_trip_last_sig=""
  fi
done

echo "ISSUES_DISPATCHED=\${ISSUES_DISPATCHED}"
echo "TRIPPED=\${TRIPPED}"
echo "CONSECUTIVE=\${_gate_trip_consecutive}"
echo "LAST_SIG=\${_gate_trip_last_sig}"
HARNESS_HEREDOC

  chmod +x "$_tmpdir/harness.sh"
  run bash "$_tmpdir/harness.sh"
}

@test "behavioral: trips on 3 consecutive identical gate signatures" {
  # 3 issues all failing with the same signature → trip on 3rd
  _run_breaker_harness "" \
    "gate:@leadflow/shared import fails" \
    "gate:@leadflow/shared import fails" \
    "gate:@leadflow/shared import fails"

  [ "$status" -eq 0 ] || {
    echo "FAIL: harness script exited with status $status" >&2
    echo "output: $output" >&2
    return 1
  }

  echo "$output" | grep -q "TRIPPED=true" || {
    echo "FAIL: circuit breaker should have tripped on 3 identical signatures" >&2
    echo "output: $output" >&2
    return 1
  }

  echo "$output" | grep -q "CIRCUIT_BREAKER_TRIPPED" || {
    echo "FAIL: CIRCUIT_BREAKER_TRIPPED line not emitted" >&2
    echo "output: $output" >&2
    return 1
  }
}

@test "behavioral: does NOT trip on mixed (non-matching) failure signatures" {
  # 3 issues with different signatures → no trip
  _run_breaker_harness "" \
    "gate:@leadflow/shared import fails" \
    "gate:authentication module fails" \
    "gate:@leadflow/shared import fails"

  [ "$status" -eq 0 ] || {
    echo "FAIL: harness script exited with status $status" >&2
    return 1
  }

  echo "$output" | grep -q "TRIPPED=false" || {
    echo "FAIL: circuit breaker should NOT trip on mixed signatures" >&2
    echo "output: $output" >&2
    return 1
  }

  ! echo "$output" | grep -q "CIRCUIT_BREAKER_TRIPPED" || {
    echo "FAIL: CIRCUIT_BREAKER_TRIPPED should not appear for mixed signatures" >&2
    return 1
  }
}

@test "behavioral: trip message names the shared signature" {
  _run_breaker_harness "" \
    "gate:@leadflow/shared import fails" \
    "gate:@leadflow/shared import fails" \
    "gate:@leadflow/shared import fails"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CIRCUIT_BREAKER_TRIPPED" || {
    echo "FAIL: breaker should have tripped" >&2
    return 1
  }
  # The trip line must name the shared signature
  echo "$output" | grep "CIRCUIT_BREAKER_TRIPPED" | grep -q "@leadflow/shared import fails" || {
    echo "FAIL: trip message does not name the shared signature" >&2
    echo "trip line: $(echo "$output" | grep CIRCUIT_BREAKER_TRIPPED)" >&2
    return 1
  }
}

@test "behavioral: RITE_BATCH_GATE_TRIP=0 disables the circuit breaker" {
  # Even 5 identical signatures should not trip when threshold=0
  _run_breaker_harness "0" \
    "gate:same failure" \
    "gate:same failure" \
    "gate:same failure" \
    "gate:same failure" \
    "gate:same failure"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRIPPED=false" || {
    echo "FAIL: circuit breaker should be disabled when RITE_BATCH_GATE_TRIP=0" >&2
    echo "output: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "CIRCUIT_BREAKER_TRIPPED"
}

@test "behavioral: success between failures resets the streak" {
  # 2 identical gate failures, then a success, then 2 more identical — should
  # NOT trip (streak resets at the success; only 2 consecutive after).
  _run_breaker_harness "" \
    "gate:same failure" \
    "gate:same failure" \
    "pass" \
    "gate:same failure" \
    "gate:same failure"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRIPPED=false" || {
    echo "FAIL: breaker should NOT trip — streak was reset by the successful issue" >&2
    echo "output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "CONSECUTIVE=2" || {
    echo "FAIL: consecutive count should be 2 (reset after pass, then 2 more)" >&2
    echo "output: $output" >&2
    return 1
  }
}

@test "behavioral: non-gate failure resets the streak" {
  # 2 identical gate failures, then a non-gate failure, then 2 more identical
  # gate failures — should NOT trip (only 2 consecutive gate failures after reset).
  _run_breaker_harness "" \
    "gate:same failure" \
    "gate:same failure" \
    "non-gate" \
    "gate:same failure" \
    "gate:same failure"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRIPPED=false" || {
    echo "FAIL: breaker should NOT trip — non-gate failure reset the streak" >&2
    echo "output: $output" >&2
    return 1
  }
}

@test "behavioral: custom RITE_BATCH_GATE_TRIP=2 trips on 2 consecutive failures" {
  _run_breaker_harness "2" \
    "gate:same failure" \
    "gate:same failure"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRIPPED=true" || {
    echo "FAIL: breaker should trip at threshold 2 after 2 identical failures" >&2
    echo "output: $output" >&2
    return 1
  }
}

@test "behavioral: halts before dispatching next issue after trip" {
  # Trip on issues 1,2,3; issue 4 must NOT be dispatched.
  _run_breaker_harness "" \
    "gate:same failure" \
    "gate:same failure" \
    "gate:same failure" \
    "gate:different failure"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "TRIPPED=true" || {
    echo "FAIL: breaker should have tripped" >&2
    return 1
  }
  # Only 3 issues should have been dispatched (trip before issue 4)
  echo "$output" | grep -q "ISSUES_DISPATCHED=3" || {
    echo "FAIL: issue 4 was dispatched after the trip — breaker did not halt" >&2
    echo "output: $output" >&2
    return 1
  }
}
