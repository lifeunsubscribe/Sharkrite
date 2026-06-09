#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/post-merge-verify.sh, lib/utils/test-gate.sh
#
# Regression test: post-merge-verify.sh sets RITE_TEST_GATE_SKIP_TRIGGERS=true
# when invoking run_test_gate, so the bats / lint full-suite trigger lists are
# bypassed for the post-merge verify path.
#
# Why this matters: post-merge-verify.sh diffs pre_merge_ref...HEAD to catch
# semantic conflicts introduced by main's rebased-in commits. Those commits
# routinely touch trigger files (lib/utils/test-gate.sh, Makefile, tools/
# lint scripts). Main already validated those files via its own CI — we only
# need to verify the feature branch's own logic against the post-rebase
# state, not re-run 1500 tests for every test-gate.sh edit on main.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "post-merge-verify.sh sets RITE_TEST_GATE_SKIP_TRIGGERS=true on the run_test_gate call" {
  # The env var must be set in the SAME invocation that calls run_test_gate,
  # not just exported globally — global export would leak into other gate
  # paths (regular post-commit gate) that DO want trigger semantics.
  #
  # Match either form:
  #   RITE_TEST_GATE_SKIP_TRIGGERS=true run_test_gate ...
  # or the multi-line variant with backslash continuations.
  _hit=$(grep -B1 "run_test_gate" "$PROJECT_ROOT/lib/utils/post-merge-verify.sh" \
    | grep -c "RITE_TEST_GATE_SKIP_TRIGGERS=true" || true)
  [ "$_hit" -ge 1 ] || {
    echo "post-merge-verify.sh does not set RITE_TEST_GATE_SKIP_TRIGGERS before run_test_gate" >&2
    grep -nC 2 "run_test_gate" "$PROJECT_ROOT/lib/utils/post-merge-verify.sh" >&2
    return 1
  }
}

@test "RITE_TEST_GATE_SKIP_TRIGGERS is NOT a global export anywhere in lib/" {
  # Defensive: must remain a per-call env var. A global export
  # (export RITE_TEST_GATE_SKIP_TRIGGERS=true) would silently disable the
  # trigger list for the regular post-commit gate too, which is wrong.
  _bad=$(grep -rE '^\s*export\s+RITE_TEST_GATE_SKIP_TRIGGERS' "$PROJECT_ROOT/lib/" 2>/dev/null || true)
  [ -z "$_bad" ] || {
    echo "RITE_TEST_GATE_SKIP_TRIGGERS is being exported globally:" >&2
    echo "$_bad" >&2
    return 1
  }
}

@test "Default behavior unchanged: env var unset → triggers fire as before" {
  # Sanity check from the test-gate side: with the env var unset, the
  # trigger list applies. This guards against accidentally inverting the
  # default in a future refactor.
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  unset RITE_TEST_GATE_SKIP_TRIGGERS
  result=$(_select_tests_by_changed_paths "lib/utils/test-gate.sh" "$PROJECT_ROOT")
  [ "$result" = "FORCE_FULL" ] || {
    echo "regression: default mode does not force full suite on test-gate.sh change" >&2
    return 1
  }
}
