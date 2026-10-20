#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_build_verdict, lib/core/assess-and-resolve.sh, lib/utils/test-gate.sh
# Phase 3: the gate blocks on ANY test failure in the targeted selection.
# Issue #718: block-on-any extended to the merge boundary (assess-and-resolve
# retry-cap) — [GATE] ACTIONABLE_NOW findings at 3/3 retries block merge.
#
# Baseline-diff (new-vs-pre-existing suppression) was removed once main went
# green: with a green base, every failure in the targeted selection is this
# change's to fix, so the gate blocks on all of them. This replaces the old
# _classify_test_failures / _compute_baseline_red_names probe machinery
# (deleted), whose only purpose was to tolerate a red baseline on origin/main.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() { rm -rf "${TEST_REPO:-}"; }

@test "_tap_failure_name strips prefix and trailing whitespace" {
  run _tap_failure_name "not ok 12 some descriptive name   "
  [ "$status" -eq 0 ]
  [ "$output" = "some descriptive name" ]
}

@test "block-on-any: a failing test in the targeted selection fails the gate" {
  # Converted (issue #1241): pre-built TAP fixture — no stub runner, no git fixture.
  # TAP from a bats run that emits 1..1 + not ok 1, exits 1.
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw=$(mktemp); _tests_raw=$(mktemp); _out=$(mktemp)
  printf '' > "$_lint_raw"
  printf 'TAP version 13\n1..1\nnot ok 1 deliberately failing test\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  # outcome=failed ⟺ exit_code=1
  run jq -r '.exit_code' "$_out"
  [ "$output" = "1" ]

  # The failure is reported in tests[] (NOT suppressed as 'pre-existing').
  run jq -r '.tests | length' "$_out"
  [ "$output" -ge 1 ]

  rm -f "$_lint_raw" "$_tests_raw" "$_out"
}

# ─── Merge-boundary: [GATE] findings block at retry cap (issue #718) ─────────
#
# These static tests pin the assess-and-resolve.sh retry-cap behavior added in
# #718: a [GATE]-tagged ACTIONABLE_NOW item that survives all 3 fix iterations
# must block the merge (same path as CRITICAL), not defer+merge via tech-debt.
#
# Static approach (grep-based) matches the pattern in
# assess-and-resolve-now-always-loops.bats — no subprocess harness needed because
# the contract is structural: specific variable assignments in specific branches.

@test "merge-boundary: GATE_NOW_COUNT_REMAINING computed at retry cap" {
  # The fix (issue #718) introduces GATE_NOW_COUNT_REMAINING inside the
  # RETRY_COUNT >= 3 branch to count [GATE] ACTIONABLE_NOW headers still
  # present in ASSESSMENT_RESULT.  If this variable disappears the merge
  # boundary check is silently removed.
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  run grep -n "GATE_NOW_COUNT_REMAINING" "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: GATE_NOW_COUNT_REMAINING not found in assess-and-resolve.sh"
    echo "      The [GATE]-at-retry-cap block check (#718) may have been removed."
    false
  }
}

@test "merge-boundary: [GATE] header pattern is anchored at line start" {
  # The grep that counts remaining [GATE] items must be anchored (^### \[GATE\])
  # so it matches only structured headers, not [GATE] in body text.  An
  # unanchored pattern would false-positive on reasoning text that *mentions*
  # [GATE] (the "structured header matching" shell convention in CLAUDE.md).
  #
  # Match the literal source text: grep -c "^### \[GATE\].*- ACTIONABLE_NOW"
  # The pattern below checks for:
  #   grep -c  — the command
  #   "^###    — double-quote then caret-anchor then ### (verifies anchoring is
  #              inside the grep argument, not outside)
  #   GATE     — the [GATE] marker keyword
  #   ACTIONABLE_NOW — the structured classification suffix
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  run grep -n 'grep -c.*"\^###.*GATE.*ACTIONABLE_NOW' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: anchored [GATE] header grep not found in assess-and-resolve.sh"
    echo "      Pattern must be: grep -c \"^### \[GATE\].*- ACTIONABLE_NOW\""
    echo "      (anchored at ^ to avoid matching [GATE] in reasoning/body text)"
    false
  }
}

@test "merge-boundary: [GATE] at retry cap sets CREATE_CRITICAL_FOLLOWUP (not CREATE_SECURITY_DEBT)" {
  # When GATE_NOW_COUNT_REMAINING > 0 at the retry cap the code must set
  # CREATE_CRITICAL_FOLLOWUP=true (blocking path).  If it sets
  # CREATE_SECURITY_DEBT=true instead, the [GATE] finding is filed as tech-debt
  # and the PR merges red — the live regression in PR #712 / issue #649.
  #
  # We verify structural ordering within the [GATE] retry-cap block:
  #   GATE_NOW_COUNT_REMAINING=... (gate block marker — anchors the search)
  #   CREATE_CRITICAL_FOLLOWUP=true  (must appear AFTER the gate marker)
  #   CREATE_SECURITY_DEBT=true      (must appear AFTER CREATE_CRITICAL_FOLLOWUP)
  #
  # Using head -1 on CREATE_SECURITY_DEBT=true would return the pre-existing
  # line in the ACTIONABLE_LATER-only path (~line 1198), which predates the
  # gate block — making the ordering assertion false-fail.  Instead, anchor
  # all line searches to lines AFTER the GATE_NOW_COUNT_REMAINING assignment.
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  # Anchor: the line that introduces the [GATE] count in the retry-cap branch.
  local _gate_marker_line
  _gate_marker_line=$(grep -n "GATE_NOW_COUNT_REMAINING=\$(echo" "$_script" | head -1 | cut -d: -f1 || true)
  [ -n "$_gate_marker_line" ] || {
    echo "FAIL: GATE_NOW_COUNT_REMAINING=\$(echo ...) assignment not found"
    echo "      The [GATE]-at-retry-cap block (#718) may have been removed."
    false
  }

  # Find CREATE_CRITICAL_FOLLOWUP=true and CREATE_SECURITY_DEBT=true lines that
  # come AFTER the gate marker (i.e., inside or after the gate block).
  local _critical_line _debt_line
  _critical_line=$(awk -F: -v anchor="$_gate_marker_line" \
    '$1 > anchor && /CREATE_CRITICAL_FOLLOWUP=true/ { print $1; exit }' \
    <(grep -n "CREATE_CRITICAL_FOLLOWUP=true" "$_script") || true)
  _debt_line=$(awk -F: -v anchor="$_gate_marker_line" \
    '$1 > anchor && /CREATE_SECURITY_DEBT=true/ { print $1; exit }' \
    <(grep -n "CREATE_SECURITY_DEBT=true" "$_script") || true)

  [ -n "$_critical_line" ] || {
    echo "FAIL: CREATE_CRITICAL_FOLLOWUP=true not found after GATE_NOW_COUNT_REMAINING"
    echo "      (gate marker at line $_gate_marker_line)"
    false
  }
  [ -n "$_debt_line" ] || {
    echo "FAIL: CREATE_SECURITY_DEBT=true not found after GATE_NOW_COUNT_REMAINING"
    echo "      Non-gate HIGH findings should still follow the defer+tech-debt path"
    false
  }
  [ "$_critical_line" -lt "$_debt_line" ] || {
    echo "FAIL: CREATE_CRITICAL_FOLLOWUP=true (line $_critical_line) does not appear"
    echo "      before CREATE_SECURITY_DEBT=true (line $_debt_line)"
    echo "      [GATE] block must precede the defer path in the source."
    false
  }
}

@test "merge-boundary: non-gate HIGH still reaches CREATE_SECURITY_DEBT path (no regression)" {
  # The defer+tech-debt path for non-gate HIGH review findings must survive the
  # #718 change.  Verify CREATE_SECURITY_DEBT=true still exists and is reachable
  # via the else arm of the GATE_NOW_COUNT_REMAINING guard.
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  # Both the GATE_NOW_COUNT_REMAINING guard and CREATE_SECURITY_DEBT must coexist.
  run grep -c "CREATE_SECURITY_DEBT=true" "$_script"
  [ "$status" -eq 0 ] || true   # grep -c exits 1 on zero matches
  local _count="$output"
  [ "${_count:-0}" -ge 1 ] || {
    echo "FAIL: CREATE_SECURITY_DEBT=true not found — non-gate HIGH defer path removed"
    false
  }

  # DROP_RETRY_MEDIUM_LOW must also still be set in that path (filters MEDIUM/LOW
  # from tech-debt issue at retry limit — regression guard for defect #5).
  run grep -n "DROP_RETRY_MEDIUM_LOW=true" "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: DROP_RETRY_MEDIUM_LOW=true not found — MEDIUM/LOW filter at retry cap removed"
    false
  }
}

# ─── Behavioral: retry-cap kernel decision logic (issue #718) ─────────────────
#
# These tests exercise the exact decision kernel extracted from the retry-cap
# branch of assess-and-resolve.sh.  The kernel is inlined here (same technique
# as tests 2-4 in assess-no-dismissed-in-rollup.bats for the awk extractor) so
# the behavior can be verified without invoking the full orchestrator (which
# requires live gh/claude calls).
#
# Contract: given ASSESSMENT_RESULT at RETRY_COUNT >= 3 with no CRITICAL items:
#   - [GATE] ACTIONABLE_NOW present  → GATE_NOW_COUNT_REMAINING > 0
#                                    → CREATE_CRITICAL_FOLLOWUP=true  (blocks merge)
#   - No [GATE] items, only HIGH     → GATE_NOW_COUNT_REMAINING = 0
#                                    → CREATE_SECURITY_DEBT=true  (defer, allow merge)

# Helper: run the retry-cap [GATE] kernel with the given assessment content.
# Sets GATE_NOW_COUNT_REMAINING, CREATE_CRITICAL_FOLLOWUP, CREATE_SECURITY_DEBT
# in the calling shell — must be called from within a subshell or bats `run`.
_run_retry_cap_kernel() {
  local _assessment="$1"
  # Exact logic extracted from lib/core/assess-and-resolve.sh retry-cap branch.
  # If this kernel diverges from the source the static tests above will catch it.
  local GATE_NOW_COUNT_REMAINING CREATE_CRITICAL_FOLLOWUP CREATE_SECURITY_DEBT
  GATE_NOW_COUNT_REMAINING=$(echo "$_assessment" | grep -c "^### \[GATE\].*- ACTIONABLE_NOW" || true)
  CREATE_CRITICAL_FOLLOWUP=false
  CREATE_SECURITY_DEBT=false
  if [ "${GATE_NOW_COUNT_REMAINING:-0}" -gt 0 ]; then
    CREATE_CRITICAL_FOLLOWUP=true
  else
    CREATE_SECURITY_DEBT=true
  fi
  # Emit decisions to stdout so `run` can capture them.
  echo "GATE_NOW_COUNT_REMAINING=${GATE_NOW_COUNT_REMAINING}"
  echo "CREATE_CRITICAL_FOLLOWUP=${CREATE_CRITICAL_FOLLOWUP}"
  echo "CREATE_SECURITY_DEBT=${CREATE_SECURITY_DEBT}"
}

@test "behavioral: [GATE] ACTIONABLE_NOW at retry cap sets CREATE_CRITICAL_FOLLOWUP (blocks merge)" {
  # A [GATE]-tagged ACTIONABLE_NOW item surviving all fix iterations must block
  # the merge (CREATE_CRITICAL_FOLLOWUP=true), not file tech-debt and merge.
  # This is the core contract of issue #718.
  local _assessment
  _assessment="### [GATE] bats failure: tests/regression/foo.bats - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** TestFailure
**Reasoning:** Objective test failure injected by post-commit gate.

### Unrelated review finding - ACTIONABLE_LATER
**Severity:** MEDIUM
**Reasoning:** Low-priority style note."

  run _run_retry_cap_kernel "$_assessment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT_REMAINING=1"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT_REMAINING=1, got: $output"
    false
  }
  [[ "$output" == *"CREATE_CRITICAL_FOLLOWUP=true"* ]] || {
    echo "FAIL: expected CREATE_CRITICAL_FOLLOWUP=true (merge block), got: $output"
    false
  }
  [[ "$output" == *"CREATE_SECURITY_DEBT=false"* ]] || {
    echo "FAIL: expected CREATE_SECURITY_DEBT=false (not deferred), got: $output"
    false
  }
}

@test "behavioral: non-gate HIGH at retry cap sets CREATE_SECURITY_DEBT (defers, allows merge)" {
  # A non-gate HIGH review finding at the retry cap must NOT block the merge.
  # It must follow the tech-debt defer path (CREATE_SECURITY_DEBT=true), which
  # files a follow-up issue and allows the merge to proceed.
  # This is the regression guard: #718 must not accidentally block non-gate HIGHs.
  local _assessment
  _assessment="### Code review: missing input validation - ACTIONABLE_NOW
**Severity:** HIGH
**Category:** CodeQuality
**Reasoning:** LLM review finding — not an objective test failure."

  run _run_retry_cap_kernel "$_assessment"
  [ "$status" -eq 0 ]

  [[ "$output" == *"GATE_NOW_COUNT_REMAINING=0"* ]] || {
    echo "FAIL: expected GATE_NOW_COUNT_REMAINING=0 (no [GATE] items), got: $output"
    false
  }
  [[ "$output" == *"CREATE_SECURITY_DEBT=true"* ]] || {
    echo "FAIL: expected CREATE_SECURITY_DEBT=true (defer path), got: $output"
    false
  }
  [[ "$output" == *"CREATE_CRITICAL_FOLLOWUP=false"* ]] || {
    echo "FAIL: expected CREATE_CRITICAL_FOLLOWUP=false (merge not blocked), got: $output"
    false
  }
}
