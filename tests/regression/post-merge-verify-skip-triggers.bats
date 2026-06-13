#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/post-merge-verify.sh, lib/utils/test-gate.sh
#
# Regression test: post-merge-verify.sh sets RITE_TEST_GATE_SKIP_TRIGGERS=true
# when invoking run_test_gate, suppressing the LINT full-scan trigger list for
# the post-merge verify path. (Bats triggers no longer exist — the bats
# trigger list was removed 2026-06-12, so since then the var affects lint
# selection only.)
#
# Why this matters: post-merge-verify.sh diffs pre_merge_ref...HEAD to catch
# semantic conflicts introduced by main's rebased-in commits. Those commits
# routinely touch lint rules or the Makefile. Main already validated those
# files via its own CI — we only need to verify the feature branch's own
# logic against the post-rebase state, not full-scan lint for every Makefile
# edit on main.

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
  # lint trigger list for the regular post-commit gate too, which is wrong.
  _bad=$(grep -rE '^\s*export\s+RITE_TEST_GATE_SKIP_TRIGGERS' "$PROJECT_ROOT/lib/" 2>/dev/null || true)
  [ -z "$_bad" ] || {
    echo "RITE_TEST_GATE_SKIP_TRIGGERS is being exported globally:" >&2
    echo "$_bad" >&2
    return 1
  }
}

@test "Bats selection ignores the env var entirely: targeted with or without it" {
  # Since the 2026-06-12 bats-trigger removal, the env var must have ZERO
  # effect on bats selection — both invocations below must agree and neither
  # may escalate to FORCE_FULL. Guards against a future refactor quietly
  # re-coupling bats selection to the var.
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  unset RITE_TEST_GATE_SKIP_TRIGGERS
  result_default=$(_select_tests_by_changed_paths "lib/utils/test-gate.sh" "$PROJECT_ROOT")
  result_skipped=$(RITE_TEST_GATE_SKIP_TRIGGERS=true _select_tests_by_changed_paths "lib/utils/test-gate.sh" "$PROJECT_ROOT" || true)
  [ "$result_default" != "FORCE_FULL" ] || {
    echo "regression: bats full-suite escalation re-appeared in default mode" >&2
    return 1
  }
  [ "$result_default" = "$result_skipped" ] || {
    echo "regression: env var changed bats selection (must be lint-only)" >&2
    return 1
  }
}
