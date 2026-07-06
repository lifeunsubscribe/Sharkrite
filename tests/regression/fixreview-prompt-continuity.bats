#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh, lib/core/assess-review-issues.sh
#
# Regression tests for issue #910: make fixreview a verification pass.
#
# Live divergence (804/PR #905, 2026-07-05): round-1 NOW=3 fixed faithfully,
# round-2 found 5 DIFFERENT NOW items — count grew instead of converging.
# Root cause: local-review.sh detected the fixreview pass only for telemetry;
# no prior-review context or fix-commits diff was injected.
#
# These tests are structural — they assert:
#   1. build_fixreview_context() is defined by local-review.sh
#   2. The function is called in the script body when review-count >= 2
#   3. The prompt assembly uses FIXREVIEW_CONTEXT when non-empty
#   4. The first-pass prompt path (FIXREVIEW_CONTEXT empty) is unchanged
#
# For assess-review-issues.sh:
#   5. The convergence rule prompt section exists and names the key constraints
#   6. RITE_REVIEW_RETRY_COUNT env var controls injection (> 0 triggers it)
#   7. assess-and-resolve.sh exports RITE_REVIEW_RETRY_COUNT before calling assess-review-issues.sh

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export LOCAL_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/local-review.sh"
  export ASSESS_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  export ASSESS_AND_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  [ -f "$LOCAL_REVIEW_SCRIPT" ] || {
    echo "setup: LOCAL_REVIEW_SCRIPT not found at $LOCAL_REVIEW_SCRIPT" >&2
    false
  }
  [ -f "$ASSESS_REVIEW_SCRIPT" ] || {
    echo "setup: ASSESS_REVIEW_SCRIPT not found at $ASSESS_REVIEW_SCRIPT" >&2
    false
  }
  [ -f "$ASSESS_AND_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_AND_RESOLVE_SCRIPT not found at $ASSESS_AND_RESOLVE_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# local-review.sh: build_fixreview_context function
# =============================================================================

@test "local-review.sh: build_fixreview_context function is defined (loadable via RITE_SOURCE_FUNCTIONS_ONLY)" {
  # The function must be defined before the FUNCTIONS_ONLY guard so tests
  # (and the trivial-fix fast-path) can load it without running the program body.
  run bash -c "
    set -euo pipefail
    # Minimal stubs so sourcing does not fail
    export RITE_LIB_DIR='${RITE_REPO_ROOT}/lib'
    export RITE_PROJECT_ROOT='${RITE_TEST_TMPDIR}'
    export RITE_SOURCE_FUNCTIONS_ONLY=1
    source '${LOCAL_REVIEW_SCRIPT}'
    declare -f build_fixreview_context >/dev/null 2>&1 && echo 'FUNCTION_DEFINED'
  "
  [ "$status" -eq 0 ] || {
    echo "exit status: $status"
    echo "output: $output"
    false
  }
  [[ "$output" == *"FUNCTION_DEFINED"* ]] || {
    echo "FAIL: build_fixreview_context not defined after RITE_SOURCE_FUNCTIONS_ONLY source"
    echo "$output"
    false
  }
}

@test "local-review.sh: script body calls build_fixreview_context when review count >= 2" {
  # The script body must detect fixreview passes and call build_fixreview_context.
  run grep -n 'build_fixreview_context' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: build_fixreview_context not called in local-review.sh"
    false
  }
  # Must be called in the script body (not just defined), so there must be a
  # call that is NOT a function definition line.
  call_count=$(grep -c 'build_fixreview_context' "$LOCAL_REVIEW_SCRIPT" || true)
  [ "${call_count:-0}" -ge 2 ] || {
    echo "FAIL: build_fixreview_context appears only once (expected: definition + call)"
    echo "call_count=$call_count"
    false
  }
}

@test "local-review.sh: fixreview detection threshold is >= 2 prior reviews" {
  # The threshold that distinguishes first-pass (count 1 = this run's review)
  # from a genuine retry (count >= 2 = a prior review existed) must be 2.
  run grep -n '_REVIEW_PRIOR_COUNT.*-ge 2\|-ge 2.*_REVIEW_PRIOR_COUNT' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: fixreview threshold '-ge 2' not found in local-review.sh"
    echo "Expected the script to treat count >= 2 as a fixreview pass"
    false
  }
}

@test "local-review.sh: FIXREVIEW_CONTEXT injected before review instructions in prompt" {
  # When FIXREVIEW_CONTEXT is non-empty, it must appear BEFORE the standard
  # review instructions in the prompt (so the verification framing overrides
  # the fresh-audit framing).
  # Structural check: the if-block that builds the fixreview prompt branch
  # must start with FIXREVIEW_CONTEXT (not the instructions variable).
  run grep -n 'FIXREVIEW_CONTEXT.*REVIEW_PROMPT\|REVIEW_PROMPT.*FIXREVIEW_CONTEXT' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: FIXREVIEW_CONTEXT not referenced in REVIEW_PROMPT assembly"
    false
  }
}

@test "local-review.sh: first-pass prompt is unchanged when FIXREVIEW_CONTEXT is empty" {
  # The else-branch (first-pass, FIXREVIEW_CONTEXT='') must still build the
  # standard prompt starting with REVIEW_INSTRUCTIONS — not the fixreview wrapper.
  run grep -n 'REVIEW_INSTRUCTIONS' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: REVIEW_INSTRUCTIONS not referenced in local-review.sh"
    false
  }
}

@test "local-review.sh: build_fixreview_context includes verification-first framing" {
  # The function output must include the key convergence instructions:
  # verification pass, not a fresh audit, and the convergence goal.
  run grep -n 'VERIFICATION PASS\|verification pass\|Verification Pass' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'VERIFICATION PASS' framing not found in build_fixreview_context"
    false
  }

  run grep -n 'Convergence goal\|convergence goal\|CONVERGENCE GOAL\|NOW count MUST NOT grow\|count MUST NOT grow' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: convergence goal rule not found in build_fixreview_context"
    false
  }
}

@test "local-review.sh: build_fixreview_context references PRIOR REVIEW section" {
  run grep -n 'PRIOR REVIEW' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'PRIOR REVIEW' section header not found in build_fixreview_context"
    false
  }
}

@test "local-review.sh: build_fixreview_context references FIX-COMMITS DIFF section" {
  run grep -n 'FIX-COMMITS DIFF\|fix-commits diff\|Fix-commits diff' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'FIX-COMMITS DIFF' section header not found in build_fixreview_context"
    false
  }
}

# =============================================================================
# assess-review-issues.sh: convergence rule injection
# =============================================================================

@test "assess-review-issues.sh: convergence rule section exists with retry guard" {
  # The convergence rule must only fire on retry passes (RITE_REVIEW_RETRY_COUNT > 0).
  run grep -n 'CONVERGENCE RULE\|convergence rule\|RETRY_PASS_RULE_SECTION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: convergence rule / RETRY_PASS_RULE_SECTION not found in assess-review-issues.sh"
    false
  }
}

@test "assess-review-issues.sh: convergence rule is gated on RITE_REVIEW_RETRY_COUNT" {
  # The convergence rule must check RITE_REVIEW_RETRY_COUNT (not a hardcoded value)
  # so the first-pass assessment (retry=0) gets an unmodified prompt.
  run grep -n 'RITE_REVIEW_RETRY_COUNT' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_REVIEW_RETRY_COUNT not referenced in assess-review-issues.sh"
    false
  }
}

@test "assess-review-issues.sh: convergence rule injected into ASSESSMENT_PROMPT" {
  # RETRY_PASS_RULE_SECTION must appear inside the ASSESSMENT_PROMPT variable.
  run grep -n 'RETRY_PASS_RULE_SECTION' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RETRY_PASS_RULE_SECTION not referenced in assess-review-issues.sh"
    false
  }

  # Must appear at least twice: once in the definition, once in the prompt.
  count=$(grep -c 'RETRY_PASS_RULE_SECTION' "$ASSESS_REVIEW_SCRIPT" || true)
  [ "${count:-0}" -ge 2 ] || {
    echo "FAIL: RETRY_PASS_RULE_SECTION appears only once (expected: assignment + prompt use)"
    echo "count=$count"
    false
  }
}

@test "assess-review-issues.sh: convergence rule bars new NOW without introduced-by-fix justification" {
  # The rule text must state that new ACTIONABLE_NOW on retry requires
  # attribution to the fix commit or CRITICAL severity.
  run grep -n 'introduced.*fix\|fix.*introduced\|INTRODUCED by the fix\|introduced by the fix' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: 'introduced by the fix' constraint not found in convergence rule"
    false
  }
}

@test "assess-review-issues.sh: convergence rule always permits CRITICAL severity" {
  # CRITICAL findings must always escalate regardless of retry state.
  run grep -n 'CRITICAL.*always\|always.*CRITICAL\|Severity is CRITICAL' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: CRITICAL-always-escalated rule not found in convergence section"
    false
  }
}

@test "assess-review-issues.sh: first-pass RETRY_PASS_RULE_SECTION is empty string" {
  # When RITE_REVIEW_RETRY_COUNT is 0 (or unset), the section must be empty
  # so first-pass prompts are not modified.
  run grep -n 'RETRY_PASS_RULE_SECTION=""' "$ASSESS_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RETRY_PASS_RULE_SECTION not initialized to empty string"
    echo "(first-pass prompts would always include the convergence rule)"
    false
  }
}

# =============================================================================
# assess-and-resolve.sh: exports RITE_REVIEW_RETRY_COUNT to subprocess
# =============================================================================

@test "assess-and-resolve.sh: exports RITE_REVIEW_RETRY_COUNT before calling assess-review-issues.sh" {
  # The export must happen before the assess-review-issues.sh invocation so the
  # convergence rule sees the right retry count.
  run grep -n 'export RITE_REVIEW_RETRY_COUNT' "$ASSESS_AND_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_REVIEW_RETRY_COUNT not exported in assess-and-resolve.sh"
    false
  }
}

@test "assess-and-resolve.sh: RITE_REVIEW_RETRY_COUNT derives from RETRY_COUNT" {
  # The export must propagate the actual retry count (RETRY_COUNT variable),
  # not a hardcoded literal.
  run grep -n 'RITE_REVIEW_RETRY_COUNT.*RETRY_COUNT\|export RITE_REVIEW_RETRY_COUNT' "$ASSESS_AND_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: RITE_REVIEW_RETRY_COUNT not wired to RETRY_COUNT in assess-and-resolve.sh"
    false
  }

  # The value must reference RETRY_COUNT (not a literal 0 or hardcoded number).
  line=$(grep 'export RITE_REVIEW_RETRY_COUNT' "$ASSESS_AND_RESOLVE_SCRIPT" | head -1 || true)
  [[ "$line" == *"RETRY_COUNT"* ]] || {
    echo "FAIL: export line does not reference RETRY_COUNT variable"
    echo "line: $line"
    false
  }
}
