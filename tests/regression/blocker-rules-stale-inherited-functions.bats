#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/blocker-rules.sh
# Regression test: blocker-rules.sh resilience against stale inherited functions
#
# Live failure (2026-06-04): #323/PR #350 added detect_lib_shrinkage to
# blocker-rules.sh and merged mid-batch. The batch parent (bin/rite →
# batch-process-issues.sh) had sourced the OLD blocker-rules.sh at batch start,
# exporting its function set. After #323 merged, subsequent issues' subprocesses
# inherited the parent's STALE exported functions. When create-pr.sh sourced
# the current (new) blocker-rules.sh, its function-sentinel re-source guard
# (`declare -f detect_infrastructure_changes`) saw the inherited stale sentinel
# and short-circuited — never defining detect_lib_shrinkage in the subprocess.
# Result: #351 and #352 failed at create-pr.sh with "detect_lib_shrinkage:
# command not found", even though the function existed in the file on disk.
#
# Fix: variable-based guard (_RITE_BLOCKER_RULES_LOADED) that is NOT exported,
# so subshells see it unset and run the full source.
#
# This test class — "stale inherited function set" — is NOT covered by
# lib-resource-safety.bats, which only tests double-source within one shell.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  BLOCKER_RULES="$RITE_LIB_DIR/utils/blocker-rules.sh"
}

@test "blocker-rules sources successfully when a stale sentinel is already defined" {
  # Simulate the production failure: a stale exported function is already in
  # scope when the file is sourced. The guard must NOT short-circuit on it.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    # Pretend the parent shell had an old blocker-rules.sh sourced, exporting
    # an older detect_infrastructure_changes that lacked detect_lib_shrinkage.
    detect_infrastructure_changes() { return 0; }
    export -f detect_infrastructure_changes
    # Now source the current file. With the old function-sentinel guard, this
    # short-circuited and detect_lib_shrinkage stayed undefined. With the
    # variable guard, the full file loads.
    source "'"$BLOCKER_RULES"'"
    declare -f detect_lib_shrinkage >/dev/null 2>&1
  '
  [ "$status" -eq 0 ]
}

@test "blocker-rules subshell picks up new functions despite stale parent exports" {
  # End-to-end reproduction of the #351/#352 failure:
  # parent shell has stale exports → subshell inherits them → subshell sources
  # the file → subshell must still get the full current function set.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    # Simulate batch parent with stale exported functions
    detect_infrastructure_changes() { return 0; }
    detect_critical_issues() { return 0; }
    export -f detect_infrastructure_changes detect_critical_issues
    # detect_lib_shrinkage is NOT exported here — the stale parent never had it
    # Subshell — analogous to create-pr.sh running as a child of batch-process
    (
      set -euo pipefail
      # Subshell does NOT inherit detect_lib_shrinkage
      ! declare -f detect_lib_shrinkage >/dev/null 2>&1 || exit 80
      source "'"$BLOCKER_RULES"'"
      # After sourcing, the function MUST be defined
      declare -f detect_lib_shrinkage >/dev/null 2>&1 || exit 81
      # And callable (sanity: the function should at least parse and exist)
      type detect_lib_shrinkage >/dev/null 2>&1 || exit 82
    )
  '
  [ "$status" -eq 0 ]
}

@test "blocker-rules variable guard prevents redundant re-source within one shell" {
  # The variable guard must still do its job for double-source within a single
  # shell (the case lib-resource-safety.bats covers). This is a sanity check
  # that the variable guard works as a guard, not just a no-op.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    source "'"$BLOCKER_RULES"'"
    # Second source must exit 0 and must not crash (no readonly re-assignment,
    # no re-execution of any one-time initialization)
    source "'"$BLOCKER_RULES"'"
    # Variable guard is set
    [ "${_RITE_BLOCKER_RULES_LOADED:-}" = "true" ]
  '
  [ "$status" -eq 0 ]
}

@test "_RITE_BLOCKER_RULES_LOADED is not exported (subshells must re-source)" {
  # The whole fix relies on the variable NOT crossing the subshell boundary.
  # If someone later "helpfully" adds `export _RITE_BLOCKER_RULES_LOADED`,
  # this test fails — exactly when we want to catch the regression.
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"$RITE_LIB_DIR"'"
    source "'"$BLOCKER_RULES"'"
    # Confirm parent has it set
    [ "${_RITE_BLOCKER_RULES_LOADED:-}" = "true" ] || exit 90
    # In a subshell (via env -i to fully clear, then restore minimum), the var
    # MUST be unset. Use `bash -c` because (...) inherits everything including
    # non-exported vars; we need a true child process.
    bash -c "[ -z \"\${_RITE_BLOCKER_RULES_LOADED:-}\" ]" || exit 91
  '
  [ "$status" -eq 0 ]
}
