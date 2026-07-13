#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/utils/test-gate.sh
# Regression guard for issue #799: a gate result with a non-zero exit_code and
# zero parseable lint/test items must NOT silently merge — it must synthesize a
# non-deferrable [GATE] ACTIONABLE_NOW block item.
#
# Live failure: LeadFlow PR #400 (issue #331, 2026-06-30). Jest 127 × 3 retries
# produced {"lint":[],"tests":[],"exit_code":1} — assessment saw 0 GATE items,
# reported "ready to merge", and squash-merged without the suite ever passing.
#
# Five contracts tested:
#   1. Empty-findings JSON (exit_code≠0) → ≥1 [GATE] ACTIONABLE_NOW item synthesized
#   2. Synthetic item is non-deferrable at retry cap (≥3): routes to
#      CREATE_CRITICAL_FOLLOWUP=true, not CREATE_SECURITY_DEBT (merge)
#   3. Empty-lint variant (non-zero exit, empty lint array): also blocked
#   4. test-gate.sh writes "reason":"runner_unavailable" in the 127-path JSON
#   5. (#1014) skipped:true sentinels whose reason means verification never
#      concluded (gate_timeout / gate_crashed) synthesize a blocking item;
#      environmental skips (missing_deps/missing_runner/missing_worktree/
#      no_tests) keep the documented non-blocking pass-through

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  # Stub _diag so sourcing assess-and-resolve.sh / test-gate.sh doesn't require
  # the full logging stack.
  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

# ---------------------------------------------------------------------------
# Helper: run the gate-consumption kernel from assess-and-resolve.sh with a
# given gate JSON file.  Returns the GATE_PREPEND_ITEMS and GATE_NOW_COUNT
# values so the caller can assert on them.
#
# This extracts the same logic used in assess-and-resolve.sh lines 1008-1100:
# read the JSON, iterate lint/tests arrays, and synthesize a fallback item when
# both loops yield zero items but exit_code is non-zero.  We inline the kernel
# here (matching the static-test pattern in gate-block-on-any.bats) so there is
# no subprocess dependency on jq being available in PATH inside the bats runner.
#
# Outputs:
#   GATE_NOW_COUNT=N   — number of [GATE] ACTIONABLE_NOW items synthesized
#   GATE_HAS_SYNTHETIC=true|false — whether the synthetic fallback item fired
# ---------------------------------------------------------------------------
_run_gate_consumption_kernel() {
  local _gate_file="$1"

  # Require jq — the kernel in assess-and-resolve.sh is guarded the same way.
  command -v jq >/dev/null 2>&1 || { echo "jq unavailable — skip"; return 1; }

  local _gate_skipped _gate_exit_code _gate_now_count=0 _gate_has_synthetic=false

  _gate_skipped=$(jq -r '.skipped // false' "$_gate_file" 2>/dev/null || echo "false")
  _gate_exit_code=$(jq -r '.exit_code // 0' "$_gate_file" 2>/dev/null || echo "0")
  case "$_gate_exit_code" in
    ''|*[!0-9]*) _gate_exit_code=0 ;;
  esac

  if [ "$_gate_skipped" != "true" ] && [ "$_gate_exit_code" -ne 0 ]; then
    # Lint loop
    while IFS= read -r _lint_item; do
      _lint_msg=$(echo "$_lint_item" | jq -r '.message // ""' 2>/dev/null || true)
      [ -n "$_lint_msg" ] && _gate_now_count=$(( _gate_now_count + 1 ))
    done < <(jq -c '.lint[]' "$_gate_file" 2>/dev/null || true)

    # Tests loop
    while IFS= read -r _test_item; do
      _test_name=$(echo "$_test_item" | jq -r '.test_name // ""' 2>/dev/null || true)
      [ -n "$_test_name" ] && _gate_now_count=$(( _gate_now_count + 1 ))
    done < <(jq -c '.tests[]' "$_gate_file" 2>/dev/null || true)

    # Synthetic fallback — mirrors assess-and-resolve.sh:1071-1088
    if [ "$_gate_now_count" -eq 0 ]; then
      _gate_now_count=$(( _gate_now_count + 1 ))
      _gate_has_synthetic=true
    fi
  elif [ "$_gate_skipped" = "true" ]; then
    # Unverified-skip blocking (#1014) — mirrors the production elif: a skip
    # whose reason means "verification started but never concluded" blocks;
    # environmental skips (missing_deps/missing_runner/missing_worktree/
    # no_tests) stay non-blocking.
    local _gate_skip_reason
    _gate_skip_reason=$(jq -r '.reason // ""' "$_gate_file" 2>/dev/null || true)
    case "$_gate_skip_reason" in
      gate_timeout|gate_crashed)
        _gate_now_count=$(( _gate_now_count + 1 ))
        _gate_has_synthetic=true
        ;;
    esac
  fi

  echo "GATE_NOW_COUNT=${_gate_now_count}"
  echo "GATE_HAS_SYNTHETIC=${_gate_has_synthetic}"
}

# ---------------------------------------------------------------------------
# Helper: run the retry-cap [GATE] kernel from assess-and-resolve.sh.
# Given a GATE_NOW_COUNT > 0 and assessment text containing [GATE] headers,
# returns whether CREATE_CRITICAL_FOLLOWUP or CREATE_SECURITY_DEBT is chosen.
# Mirrors gate-block-on-any.bats::_run_retry_cap_kernel.
# ---------------------------------------------------------------------------
_run_retry_cap_kernel_for_gate() {
  local _assessment="$1"
  local GATE_NOW_COUNT_REMAINING CREATE_CRITICAL_FOLLOWUP CREATE_SECURITY_DEBT
  GATE_NOW_COUNT_REMAINING=$(echo "$_assessment" | grep -c "^### \[GATE\].*- ACTIONABLE_NOW" || true)
  CREATE_CRITICAL_FOLLOWUP=false
  CREATE_SECURITY_DEBT=false
  if [ "${GATE_NOW_COUNT_REMAINING:-0}" -gt 0 ]; then
    CREATE_CRITICAL_FOLLOWUP=true
  else
    CREATE_SECURITY_DEBT=true
  fi
  echo "GATE_NOW_COUNT_REMAINING=${GATE_NOW_COUNT_REMAINING}"
  echo "CREATE_CRITICAL_FOLLOWUP=${CREATE_CRITICAL_FOLLOWUP}"
  echo "CREATE_SECURITY_DEBT=${CREATE_SECURITY_DEBT}"
}

# ===========================================================================
# Contract 1: empty-tests JSON produces ≥1 [GATE] ACTIONABLE_NOW item
# ===========================================================================

@test "empty-findings gate (exit_code=1) synthesizes ≥1 blocking GATE item" {
  # This is the exact JSON that LeadFlow PR #400 produced on every retry:
  # jest 127 → no TAP output → empty lint and tests arrays.
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[],"exit_code":1}\n' > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  # Skip if jq is unavailable in this environment (not an error).
  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT=1"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT=1 (synthetic item), got: $output"
    echo "      A gate exit_code=1 with empty lint+tests must produce a blocking item."
    false
  }
  [[ "$output" == *"GATE_HAS_SYNTHETIC=true"* ]] || {
    echo "FAIL: expected GATE_HAS_SYNTHETIC=true, got: $output"
    echo "      The synthetic fallback path was not taken."
    false
  }
}

@test "empty-findings gate with runner_unavailable reason: item count=1 and synthetic=true" {
  # The runner_unavailable path (jest 127) writes a reason field into the JSON.
  # Verify the consumption kernel still synthesizes exactly one blocking item.
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[],"exit_code":1,"reason":"runner_unavailable"}\n' > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT=1"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT=1, got: $output"
    false
  }
  [[ "$output" == *"GATE_HAS_SYNTHETIC=true"* ]] || {
    echo "FAIL: expected GATE_HAS_SYNTHETIC=true, got: $output"
    false
  }
}

@test "gate with parseable items: synthetic fallback NOT triggered (no regression)" {
  # When the arrays are non-empty the synthetic block must not fire — it would
  # double-count the failure.
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[{"file":"bats","test_name":"some test","reason":"assertion failed"}],"exit_code":1}\n' \
    > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_HAS_SYNTHETIC=false"* ]] || {
    echo "FAIL: expected GATE_HAS_SYNTHETIC=false (parseable item present), got: $output"
    echo "      Synthetic fallback must not fire when items already parsed from arrays."
    false
  }
}

@test "gate skipped=true: no synthetic item (skip means intentional pass-through)" {
  # A skipped gate (missing_runner with exit_code=0) must not produce a blocking
  # item — the skip contract is "proceed with review findings only" (CLAUDE.md).
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"missing_runner"}\n' > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT=0"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT=0 for a skipped gate, got: $output"
    echo "      A skipped gate (missing_runner, exit_code=0) must not block the merge."
    false
  }
}

# ===========================================================================
# Contract 5 (#1014): unverified skips (gate_timeout / gate_crashed) BLOCK;
# environmental skips stay non-blocking.
#
# Live escape: PR #998 (issue #930, 2026-07-06) — the gate's bats run was
# watchdog-killed at 1800s (TEST_GATE_WATCHDOG_KILL, the #993 deadlock),
# workflow-runner wrote the gate_timeout sentinel, assessment saw now=0, and
# the lap merged 40 minutes after the gate started, having verified nothing.
# ===========================================================================

@test "gate_timeout skip synthesizes a blocking item (#1014)" {
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"gate_timeout"}\n' > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT=1"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT=1 for a gate_timeout skip, got: $output"
    echo "      A watchdog-killed gate verified nothing — it must block, not pass."
    false
  }
}

@test "gate_crashed skip synthesizes a blocking item (#1014)" {
  # The crash trap's own comment says it exists to prevent fail-open — but the
  # sentinel previously yielded zero blocking items, the same hole.
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"gate_crashed"}\n' > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT=1"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT=1 for a gate_crashed skip, got: $output"
    false
  }
}

@test "environmental skips stay non-blocking: missing_deps / missing_worktree / no_tests (#1014)" {
  local _gate_file _reason
  for _reason in missing_deps missing_worktree no_tests; do
    _gate_file=$(mktemp)
    printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"%s"}\n' "$_reason" > "$_gate_file"
    run _run_gate_consumption_kernel "$_gate_file"
    rm -f "$_gate_file"
    [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
    [[ "$output" == *"GATE_NOW_COUNT=0"* ]] || {
      echo "FAIL: environmental skip '$_reason' must stay non-blocking, got: $output"
      false
    }
  done
}

@test "behavioral (#1014): REAL consumption block blocks gate_timeout, passes missing_runner" {
  # Runs the PRODUCTION gate-consumption block — sed-extracted from
  # assess-and-resolve.sh and eval'd with print_* stubbed — against both a
  # gate_timeout sentinel (expect 1 blocking item mentioning the reason) and a
  # missing_runner sentinel (expect 0). Guards against the replica kernel
  # above drifting from the real code (the #983 vacuous-replica lesson).
  command -v jq >/dev/null 2>&1 || skip "jq not available in this environment"
  _driver="$BATS_TEST_TMPDIR/consumption-driver.sh"
  cat > "$_driver" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -euo pipefail
SRC="$1"; REASON="$2"
print_warning() { echo "WARN: $*" >&2; }
print_status()  { :; }
print_success() { :; }
CURRENT_HEAD_SHA=""
_GATE_FINDINGS_FILE=$(mktemp)
printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"%s"}\n' "$REASON" > "$_GATE_FINDINGS_FILE"

# Extract the production block: from the GATE_PREPEND_ITEMS reset to the
# column-0 fi that closes the findings-file guard. Anchor drift fails loudly.
_block=$(sed -n '/^GATE_PREPEND_ITEMS=""$/,/^fi$/p' "$SRC")
[ -n "$_block" ] || { echo "FAIL: could not extract consumption block" >&2; exit 1; }
eval "$_block"

echo "COUNT=${GATE_NOW_COUNT}"
printf '%s' "$GATE_PREPEND_ITEMS" | head -1
DRIVER_EOF

  _src="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  run bash "$_driver" "$_src" "gate_timeout"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=1"* ]] || {
    echo "FAIL: real consumption block did not block gate_timeout. Output: $output"
    false
  }
  [[ "$output" == *"gate_timeout"* ]] && [[ "$output" == *"ACTIONABLE_NOW"* ]] || {
    echo "FAIL: synthesized item missing reason/structured header. Output: $output"
    false
  }

  run bash "$_driver" "$_src" "missing_runner"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COUNT=0"* ]] || {
    echo "FAIL: real consumption block must not block missing_runner. Output: $output"
    false
  }
}

@test "source (#1014): production case arm covers exactly gate_timeout|gate_crashed" {
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  run grep -n 'gate_timeout|gate_crashed)' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: unverified-skip case arm (gate_timeout|gate_crashed) not found"
    false
  }
}

# ===========================================================================
# Contract 2: synthetic item is non-deferrable at retry cap (≥3 retries)
#
# When GATE_NOW_COUNT > 0 and a [GATE] ACTIONABLE_NOW item is in the
# assessment result at retry 3, the retry-cap branch must set
# CREATE_CRITICAL_FOLLOWUP=true (blocks merge), not CREATE_SECURITY_DEBT.
# ===========================================================================

@test "retry-cap ≥3: synthetic [GATE] item routes to CREATE_CRITICAL_FOLLOWUP (blocks merge)" {
  # Simulate an assessment result that contains the synthetic item the fix
  # would inject for an empty-findings gate failure.
  local _assessment
  _assessment="### [GATE] gate failure: runner_unavailable (exit_code=1) - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** Gate failure (objective — no LLM categorization needed)
**Fix Effort:** Medium (investigate why the test runner produced no parseable output)
**Reasoning:** Gate exited non-zero with empty findings — verification did not complete.

"
  run _run_retry_cap_kernel_for_gate "$_assessment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT_REMAINING=1"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT_REMAINING=1, got: $output"
    false
  }
  [[ "$output" == *"CREATE_CRITICAL_FOLLOWUP=true"* ]] || {
    echo "FAIL: expected CREATE_CRITICAL_FOLLOWUP=true (merge block), got: $output"
    echo "      A synthetic [GATE] item at the retry cap must block the merge."
    false
  }
  [[ "$output" == *"CREATE_SECURITY_DEBT=false"* ]] || {
    echo "FAIL: expected CREATE_SECURITY_DEBT=false (not deferred), got: $output"
    false
  }
}

@test "retry-cap ≥3: synthetic [GATE] item — generic exit code variant also blocks" {
  # Variant without a named reason (just exit_code in the description).
  local _assessment
  _assessment="### [GATE] gate failure: non-zero exit (exit_code=2) with no parseable findings - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** Gate failure (objective — no LLM categorization needed)
**Reasoning:** Gate exited non-zero with empty findings — verification did not complete.

"
  run _run_retry_cap_kernel_for_gate "$_assessment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"CREATE_CRITICAL_FOLLOWUP=true"* ]] || {
    echo "FAIL: expected CREATE_CRITICAL_FOLLOWUP=true, got: $output"
    echo "      A generic-exit [GATE] item must also block the merge at retry cap."
    false
  }
}

# ===========================================================================
# Contract 3: empty-lint variant — non-zero exit with empty lint also blocks
# (covers the lint-trigger sibling instance identified in Bug Class §3)
# ===========================================================================

@test "empty-lint gate (exit_code=1, empty lint, no tests): synthetic item fires" {
  # make check exits non-zero but _parse_lint_line parses nothing.
  # The lint trigger is structurally identical to the tests trigger — same
  # GATE_NOW_COUNT=0 postcondition → same synthetic block.
  local _gate_file
  _gate_file=$(mktemp)
  printf '{"lint":[],"tests":[],"exit_code":1}\n' > "$_gate_file"

  run _run_gate_consumption_kernel "$_gate_file"
  rm -f "$_gate_file"

  [[ "$output" == *"jq unavailable"* ]] && skip "jq not available in this environment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT=1"* ]] || {
    echo "FAIL: empty-lint gate (exit_code=1) did not produce a blocking item."
    echo "      The lint-trigger sibling instance must also be covered."
    echo "      Got: $output"
    false
  }
  [[ "$output" == *"GATE_HAS_SYNTHETIC=true"* ]] || {
    echo "FAIL: GATE_HAS_SYNTHETIC not true for empty-lint gate."
    echo "      Got: $output"
    false
  }
}

# ===========================================================================
# Contract 4: test-gate.sh writes "reason" field on the runner_unavailable path
# (structural check — no subprocess gate invocation needed)
# ===========================================================================

@test "test-gate.sh: reason=runner_unavailable is stored in _gate_reason variable" {
  # The fix adds: _gate_reason="runner_unavailable" inside the 127-detection
  # block of run_test_gate.  Assert the assignment exists adjacent to the
  # _diag "TEST_GATE outcome=failed reason=runner_unavailable ..." line so
  # the variable is always set when that diag fires.
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"

  # Check _gate_reason="runner_unavailable" appears in the file.
  run grep -n '_gate_reason="runner_unavailable"' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _gate_reason=\"runner_unavailable\" assignment not found in test-gate.sh"
    echo "      The reason field must be set in the 127-detection block so"
    echo "      _gate_write_json can include it in the output JSON."
    false
  }

  # Confirm the assignment is within a few lines of the _diag that fires it.
  local _diag_line _reason_line
  _diag_line=$(grep -n 'reason=runner_unavailable' "$_script" | grep '_diag' | head -1 | cut -d: -f1 || true)
  _reason_line=$(grep -n '_gate_reason="runner_unavailable"' "$_script" | head -1 | cut -d: -f1 || true)
  [ -n "$_diag_line" ] && [ -n "$_reason_line" ] || {
    echo "FAIL: could not locate _diag line or _gate_reason line for proximity check"
    false
  }
  local _diff=$(( _reason_line - _diag_line ))
  [ "${_diff#-}" -le 10 ] || {
    echo "FAIL: _gate_reason assignment (line $_reason_line) is more than 10 lines"
    echo "      from the _diag call (line $_diag_line)."
    echo "      They should be co-located in the same 127-detection if-block."
    false
  }
}

@test "test-gate.sh: _gate_write_json includes reason field in non-skipped failure path" {
  # The updated _gate_write_json must emit the reason field in the JSON output
  # when reason is non-empty and skipped=false.  Assert the elif branch exists.
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"

  # Look for the elif branch that handles the non-skipped+reason case.
  run grep -n 'elif \[ -n "\$reason" \]' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'elif [ -n \"\$reason\" ]' branch not found in _gate_write_json"
    echo "      The function must include a non-skipped+reason path that emits"
    echo "      the reason field into the JSON for assess-and-resolve.sh to read."
    false
  }
}

@test "test-gate.sh: _gate_write_json called with _gate_reason at end of run_test_gate" {
  # The _gate_write_json call at the end of run_test_gate must pass _gate_reason
  # as the 6th argument so the reason field reaches the JSON file.
  local _script="${BATS_TEST_DIRNAME}/../../lib/utils/test-gate.sh"

  run grep -n '_gate_write_json.*_gate_reason' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: _gate_write_json call with _gate_reason not found in test-gate.sh"
    echo "      The final _gate_write_json call must pass \"\$_gate_reason\" (or"
    echo "      the variable) as the 6th argument so the reason propagates to JSON."
    false
  }
}

# ===========================================================================
# Contract 4b: assess-and-resolve.sh reads the reason field to name the cause
# ===========================================================================

@test "assess-and-resolve.sh: synthetic item reads reason field from gate JSON" {
  # The synthesis block in assess-and-resolve.sh must read .reason from the
  # gate JSON and include it in the synthetic item's title.
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  # Check that jq reads the reason field in the synthesis block.
  run grep -n "jq.*reason" "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: jq .reason read not found in assess-and-resolve.sh"
    echo "      The synthesis block must read the reason field from the gate JSON"
    echo "      to name the cause in the [GATE] item title."
    false
  }
}

@test "assess-and-resolve.sh: synthetic item uses structured [GATE] header (anchored)" {
  # The synthesized item must use the exact header format that the retry-cap
  # grep pattern (^### \[GATE\].*- ACTIONABLE_NOW) will match.
  # Structural check: the GATE_PREPEND_ITEMS append in the synthesis block
  # must contain the literal string "### [GATE]" and "- ACTIONABLE_NOW".
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  # Look for the synthetic item's header in the GATE_PREPEND_ITEMS append.
  # The synthesis block appends a heredoc-style string starting with ### [GATE].
  run grep -n '### \[GATE\].*_gate_failure_desc.*ACTIONABLE_NOW\|GATE_PREPEND_ITEMS.*\[GATE\]' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: GATE_PREPEND_ITEMS append with [GATE]...ACTIONABLE_NOW not found"
    echo "      The synthetic item must use the structured header so the retry-cap"
    echo "      grep (^### \[GATE\].*- ACTIONABLE_NOW) can detect it."
    false
  }
}
