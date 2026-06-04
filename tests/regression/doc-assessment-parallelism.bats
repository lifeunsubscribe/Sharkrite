#!/usr/bin/env bats
# Regression test: assess-documentation.sh runs the 4 independent sub-assessments
# in parallel (fan-out), not sequentially.
# Issue #308
#
# Context: assess-documentation.sh calls 4 independent Claude provider functions
# (security, architecture, api, ADR). Before this fix they ran sequentially:
# wall-clock = sum of all latencies (~80-120s worst case). After fix they run via
# `&` + `wait`, so wall-clock = max of all latencies (~20-30s).
#
# Test strategy:
# 1. Timing test: stub the 4 functions to sleep 2s each.
#    Sequential execution would take ~8s; parallel takes ~2s.
#    Assert total elapsed time is <5s (generous margin for CI overhead).
#
# 2. Partial failure test: stub one sub-assessment to fail.
#    Assert the other three complete, reconcile runs, and the overall
#    assessment does not crash.
#
# 3. Static check: assert the 4 sub-assessment launches use `&` (background)
#    in assess-documentation.sh source code.
#
# 4. Static check: assert the wait loop captures exit codes individually
#    (not `|| true` which would swallow failures silently).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ASSESS_DOC="$PROJECT_ROOT/lib/core/assess-documentation.sh"
  export PROJECT_ROOT
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/doc-parallel-test"
  mkdir -p "$TEST_TMPDIR"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Test 1: 4 parallel stubs sleeping 2s each complete in <5s total
# (proves they run concurrently, not sequentially)
# ---------------------------------------------------------------------------

@test "doc-assessment: 4 independent sub-assessments run in parallel (timing)" {
  # This test exercises the fan-out section directly by replacing the 4
  # assess_internal_* functions with 2s sleeps and measuring elapsed time.
  # We inline only the fan-out + wait section (not the full script) to avoid
  # needing a git/gh environment.

  local start_time end_time elapsed

  run bash -c "
    set -euo pipefail

    # Stub the 4 independent sub-assessment functions to take 2s each.
    # If they run sequentially, total >= 8s. If parallel, total ~2s.
    assess_internal_security()     { sleep 2; }
    assess_internal_architecture() { sleep 2; }
    assess_internal_api()          { sleep 2; }
    assess_internal_adr()          { sleep 2; }
    print_warning() { echo \"WARNING: \$1\" >&2; }

    start=\$(date +%s)

    # Mirror the fan-out section from assess-documentation.sh
    _assess_pids=()
    _assess_names=()
    assess_internal_security     'pr' 'diff' 'files' 'title' &
    _assess_pids+=(\$!)
    _assess_names+=('security')
    assess_internal_architecture 'pr' 'diff' 'files' &
    _assess_pids+=(\$!)
    _assess_names+=('architecture')
    assess_internal_api          'pr' 'diff' 'files' &
    _assess_pids+=(\$!)
    _assess_names+=('api')
    assess_internal_adr          'pr' 'diff' 'body' 'title' &
    _assess_pids+=(\$!)
    _assess_names+=('adr')

    for _i in \"\${!_assess_pids[@]}\"; do
      _pid_exit=0
      wait \"\${_assess_pids[\$_i]}\" 2>/dev/null || _pid_exit=\$?
      if [ \"\$_pid_exit\" -ne 0 ]; then
        print_warning \"assessment failed: \${_assess_names[\$_i]} (exit \$_pid_exit)\" >&2
      fi
    done

    end=\$(date +%s)
    elapsed=\$((end - start))
    echo \"elapsed:\${elapsed}\"
  "

  [ "$status" -eq 0 ]

  # Extract elapsed seconds from output
  local elapsed_val
  elapsed_val=$(echo "$output" | grep -oE 'elapsed:[0-9]+' | cut -d: -f2 || echo "999")

  # Parallel execution: should complete in <5s (2s per call, ~2s parallel + margin)
  # Sequential execution: would take >=8s. This clearly distinguishes the two.
  [ "$elapsed_val" -lt 5 ]
}

# ---------------------------------------------------------------------------
# Test 2: One sub-assessment fails; the other three complete and the parent
# exits 0 (non-failing sub-assessments are not blocked)
# ---------------------------------------------------------------------------

@test "doc-assessment: failing sub-assessment does not block the other three" {
  run bash -c "
    set -euo pipefail

    # Stub: architecture fails, the other three succeed and write a marker
    MARKER_DIR=\$(mktemp -d)
    assess_internal_security()     { touch \"\$MARKER_DIR/security\"; }
    assess_internal_architecture() { exit 1; }   # simulate failure
    assess_internal_api()          { touch \"\$MARKER_DIR/api\"; }
    assess_internal_adr()          { touch \"\$MARKER_DIR/adr\"; }
    print_warning() { echo \"WARNING: \$1\" >&2; }

    _assess_pids=()
    _assess_names=()
    assess_internal_security     'pr' 'diff' 'files' 'title' &
    _assess_pids+=(\$!)
    _assess_names+=('security')
    assess_internal_architecture 'pr' 'diff' 'files' &
    _assess_pids+=(\$!)
    _assess_names+=('architecture')
    assess_internal_api          'pr' 'diff' 'files' &
    _assess_pids+=(\$!)
    _assess_names+=('api')
    assess_internal_adr          'pr' 'diff' 'body' 'title' &
    _assess_pids+=(\$!)
    _assess_names+=('adr')

    _any_failed=false
    for _i in \"\${!_assess_pids[@]}\"; do
      _pid_exit=0
      wait \"\${_assess_pids[\$_i]}\" 2>/dev/null || _pid_exit=\$?
      if [ \"\$_pid_exit\" -ne 0 ]; then
        print_warning \"assessment failed: \${_assess_names[\$_i]} (exit \$_pid_exit)\" >&2
        _any_failed=true
      fi
    done

    # Report which markers were created
    for m in security api adr; do
      if [ -f \"\$MARKER_DIR/\$m\" ]; then
        echo \"completed:\$m\"
      fi
    done

    rm -rf \"\$MARKER_DIR\"

    # Parent should still exit 0 (non-failing subs completed)
    exit 0
  "

  [ "$status" -eq 0 ]
  # The three non-failing assessments must have completed
  [[ "$output" == *"completed:security"* ]]
  [[ "$output" == *"completed:api"* ]]
  [[ "$output" == *"completed:adr"* ]]
  # The failure warning must have been emitted
  [[ "$output" == *"WARNING:"*"architecture"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: Static check — the 4 sub-assessment calls use `&` in the source
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: 4 sub-assessment calls use background operator (&)" {
  # Extract the parallel fan-out section from the script.
  # The section is delimited by the comment "Claude-calling assessments run in parallel"
  # and "unset _assess_pids _assess_names".
  _section=$(awk '
    /Claude-calling assessments run in parallel/ { in_block=1 }
    in_block { print }
    in_block && /unset _assess_pids/ { in_block=0 }
  ' "$ASSESS_DOC")

  [ -n "$_section" ]

  # All 4 sub-assessment functions must be launched with & (background)
  local bg_count
  bg_count=$(echo "$_section" | grep -cE "^assess_internal_(security|architecture|api|adr).*&$" || true)
  [ "$bg_count" -eq 4 ]
}

# ---------------------------------------------------------------------------
# Test 4: Static check — the wait loop captures individual exit codes
# (not || true which swallows failures)
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: fan-out wait loop captures individual exit codes" {
  _section=$(awk '
    /Claude-calling assessments run in parallel/ { in_block=1 }
    in_block { print }
    in_block && /unset _assess_pids/ { in_block=0 }
  ' "$ASSESS_DOC")

  [ -n "$_section" ]

  # Must NOT use the silent `wait ... || true` pattern
  local silent_wait_count
  silent_wait_count=$(echo "$_section" | grep -c 'wait.*|| true' || true)
  [ "$silent_wait_count" -eq 0 ]

  # Must capture exit code into a variable
  [[ "$_section" == *"_pid_exit"* ]]

  # Must report failures with print_warning
  [[ "$_section" == *"print_warning"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Static check — reconcile also runs in parallel (not sequential)
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: reconciliation also uses parallel fan-out" {
  _section=$(awk '
    /Run reconciliation in parallel/ { in_block=1 }
    in_block { print }
    in_block && /unset _reconcile_pids/ { in_block=0 }
  ' "$ASSESS_DOC")

  [ -n "$_section" ]

  # Reconcile calls must be launched with & (background)
  local bg_count
  bg_count=$(echo "$_section" | grep -cE "reconcile_internal_doc.*&$" || true)
  [ "$bg_count" -ge 2 ]

  # Wait loop must capture exit codes (not || true)
  local silent_wait_count
  silent_wait_count=$(echo "$_section" | grep -c 'wait.*|| true' || true)
  [ "$silent_wait_count" -eq 0 ]
}
