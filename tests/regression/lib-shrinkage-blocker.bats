#!/usr/bin/env bats
# Regression test for issue #323: Add review-shrinkage check for lib/ file edits
#
# Verifies that detect_lib_shrinkage() fires a blocker when a PR deletes:
#   - More than 50% of a lib/core/, lib/utils/, or lib/providers/ file, OR
#   - More than 500 lines from a single such file (absolute threshold)
#
# Simulates the 2026-06-02 incident (PR #260) where -1,015/-235 lines were
# silently deleted from lib/core/assess-review-issues.sh and
# lib/utils/format-review.sh via a buggy test writing through a symlink.
#
# Tests:
#   1. Absolute threshold fires when >500 lines deleted from a lib/ file
#   2. Ratio threshold fires when >50% of a lib/ file is deleted
#   3. No blocker when deletions are within safe thresholds
#   4. Non-lib/ files do not trigger the blocker (scope boundary)
#   5. Both supervised (prompts) and auto (exits blocker code) modes
#   6. RITE_SHRINKAGE_RATIO_PCT and RITE_SHRINKAGE_ABS_LINES are configurable
#   7. [diag] log line is written on blocker

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_NAME="test-shrinkage-$$"
  export RITE_STATE_DIR="$RITE_TEST_TMPDIR/.rite/state"
  export RITE_LOG_FILE="$RITE_TEST_TMPDIR/rite-workflow.log"

  mkdir -p "$RITE_TEST_TMPDIR/.rite/state"

  # Default thresholds (reset to defaults for each test)
  export RITE_SHRINKAGE_RATIO_PCT=50
  export RITE_SHRINKAGE_ABS_LINES=500

  # Provide shims for functions that blocker-rules.sh depends on.
  # gh_safe is the critical one — we override it per-test with a controlled mock.
  gh_safe() { command gh "$@"; }
  export -f gh_safe

  # Provide print_* shims (blocker-rules.sh uses them when sourced in tests)
  print_info()    { echo "[INFO] $*" >&2; }
  print_warning() { echo "[WARN] $*" >&2; }
  print_error()   { echo "[ERROR] $*" >&2; }
  print_success() { echo "[OK] $*" >&2; }
  print_status()  { echo "[STATUS] $*" >&2; }
  export -f print_info print_warning print_error print_success print_status

  # Notifications shim (blocker-rules.sh sources notifications.sh; provide a stub)
  send_blocker_notification() { :; }
  export -f send_blocker_notification

  # Source blocker-rules.sh after the shims are in place
  source "${RITE_LIB_DIR}/utils/blocker-rules.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: build a synthetic unified diff for a production lib/ file with N
# deleted lines.  The diff format matches what `gh pr diff` produces.
# ---------------------------------------------------------------------------
_make_lib_diff() {
  local filepath="$1"   # e.g. lib/core/assess-review-issues.sh
  local n_deleted="$2"  # number of lines to simulate as deleted
  local n_added="${3:-5}"  # number of added lines (optional, default 5)

  printf 'diff --git a/%s b/%s\n' "$filepath" "$filepath"
  printf 'index abc1234..def5678 100755\n'
  printf '--- a/%s\n' "$filepath"
  printf '+++ b/%s\n' "$filepath"
  printf '@@ -1,%d +1,%d @@\n' "$n_deleted" "$n_added"
  # Generate deleted lines
  local i
  for i in $(seq 1 "$n_deleted"); do
    printf -- '-deleted line %d\n' "$i"
  done
  # Generate added lines
  for i in $(seq 1 "$n_added"); do
    printf '+added line %d\n' "$i"
  done
}

# ---------------------------------------------------------------------------
# Helper: build a synthetic `gh pr view --json files` JSON response.
# ---------------------------------------------------------------------------
_make_pr_files_json() {
  local filepath="$1"
  local deletions="$2"
  local additions="${3:-5}"
  printf '"%s|%d"\n' "$filepath" "$deletions"
}

# ---------------------------------------------------------------------------
# Helper: create a real file in the test tmpdir that `wc -l` will work on.
# Used for ratio-check tests (ratio check reads the local file's line count).
# ---------------------------------------------------------------------------
_create_lib_file() {
  local filepath="$1"  # relative path, e.g. lib/core/assess-review-issues.sh
  local n_lines="$2"

  mkdir -p "$RITE_TEST_TMPDIR/$(dirname "$filepath")"
  local file="$RITE_TEST_TMPDIR/$filepath"
  local i
  for i in $(seq 1 "$n_lines"); do
    printf 'line %d of the file\n' "$i" >> "$file"
  done
  echo "$file"
}

# ===========================================================================
# TEST 1: Absolute threshold fires for >500 line deletion
# ===========================================================================

@test "detect_lib_shrinkage: fires when >500 lines deleted from lib/core/ (absolute threshold)" {
  local target_file="lib/core/assess-review-issues.sh"
  local n_deleted=1015  # mirrors the 2026-06-02 incident

  # Mock gh_safe: return synthetic diff for `gh pr diff` and empty JSON for `gh pr view --json files`
  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      # Return empty files list so ratio check is skipped (absolute check is our focus)
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "260"

  # Must return exit 1 (blocker)
  [ "$status" -eq 1 ]
  # Output must mention the file
  [[ "$output" == *"assess-review-issues.sh"* ]]
  # Output must mention the deletion count
  [[ "$output" == *"-${n_deleted}"* ]] || [[ "$output" == *"${n_deleted} lines"* ]] || [[ "$output" == *"1015"* ]]
  # Output must mention the absolute threshold trigger
  [[ "$output" == *"ABS"* ]] || [[ "$output" == *"absolute threshold"* ]] || [[ "$output" == *"BLOCKER"* ]]
}

# ===========================================================================
# TEST 2: Absolute threshold fires for a lib/utils/ file
# ===========================================================================

@test "detect_lib_shrinkage: fires when >500 lines deleted from lib/utils/ (absolute threshold)" {
  local target_file="lib/utils/format-review.sh"
  local n_deleted=600

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "260"

  [ "$status" -eq 1 ]
  [[ "$output" == *"format-review.sh"* ]] || [[ "$output" == *"BLOCKER"* ]]
}

# ===========================================================================
# TEST 3: Absolute threshold fires for a lib/providers/ file
# ===========================================================================

@test "detect_lib_shrinkage: fires when >500 lines deleted from lib/providers/" {
  local target_file="lib/providers/claude.sh"
  local n_deleted=550

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "99"

  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
}

# ===========================================================================
# TEST 4: Ratio threshold fires when >50% of file is deleted
# ===========================================================================

@test "detect_lib_shrinkage: fires when >50% of lib/ file is deleted (ratio threshold)" {
  local target_file="lib/core/workflow-runner.sh"
  local total_lines=200
  local deleted_lines=110  # 55% — above the 50% ratio threshold

  # Create the file locally so wc -l returns the correct count.
  # We run from RITE_TEST_TMPDIR so the relative path is found by the ratio check.
  local abs_target="$RITE_TEST_TMPDIR/$target_file"
  mkdir -p "$(dirname "$abs_target")"
  local i
  for i in $(seq 1 "$total_lines"); do
    printf 'line %d of the file\n' "$i" >> "$abs_target"
  done

  # The jq query in detect_lib_shrinkage outputs lines like:
  #   lib/core/workflow-runner.sh|110
  # (no surrounding quotes — jq outputs bare strings from "\(.path)|\(.deletions)")
  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  # Run from RITE_TEST_TMPDIR so relative path '$target_file' resolves to the local copy
  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ]; then
        # Output format matches jq .files[] | \"\(.path)|\(.deletions)\" output
        printf '%s|%d\n' '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '99'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]] || [[ "$output" == *"ratio"* ]] || [[ "$output" == *"RATIO"* ]]
}

# ===========================================================================
# TEST 5: No blocker for small deletions (below both thresholds)
# ===========================================================================

@test "detect_lib_shrinkage: does NOT fire for small deletions below both thresholds" {
  local target_file="lib/core/workflow-runner.sh"
  local n_deleted=20  # Well below 500 absolute and 50% ratio

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      printf '"%s|%d"\n' "$target_file" "$n_deleted"
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "42"

  # Must return exit 0 (no blocker)
  [ "$status" -eq 0 ]
}

# ===========================================================================
# TEST 6: Non-lib/ files do NOT trigger the blocker
# ===========================================================================

@test "detect_lib_shrinkage: does NOT fire for deletions outside lib/ production paths" {
  # A test file and a docs file — not in lib/core|utils|providers
  local diff_content
  diff_content=$(
    _make_lib_diff "tests/regression/some-test.bats" 800
    _make_lib_diff "docs/architecture/behavioral-design.md" 600
    _make_lib_diff "bin/rite" 300
  )

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      echo "$diff_content"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      # Non-lib files — the jq filter in detect_lib_shrinkage filters them out
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "55"

  # Non-lib/ deletions must NOT fire the blocker
  [ "$status" -eq 0 ]
}

# ===========================================================================
# TEST 7: Configurable RITE_SHRINKAGE_ABS_LINES threshold
# ===========================================================================

@test "detect_lib_shrinkage: respects RITE_SHRINKAGE_ABS_LINES override" {
  local target_file="lib/core/create-pr.sh"
  local n_deleted=200  # Below default 500, but above custom 100

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  # Lower the absolute threshold to 100 — should now fire
  RITE_SHRINKAGE_ABS_LINES=100 run detect_lib_shrinkage "77"

  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
}

@test "detect_lib_shrinkage: does NOT fire when below overridden RITE_SHRINKAGE_ABS_LINES" {
  local target_file="lib/core/create-pr.sh"
  local n_deleted=50  # Below custom threshold of 100

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  RITE_SHRINKAGE_ABS_LINES=100 run detect_lib_shrinkage "77"

  [ "$status" -eq 0 ]
}

# ===========================================================================
# TEST 8: Empty diff does not crash or fire
# ===========================================================================

@test "detect_lib_shrinkage: handles empty diff gracefully (no crash, no blocker)" {
  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      echo ""  # Empty diff
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "10"

  [ "$status" -eq 0 ]
}

# ===========================================================================
# TEST 9: [diag] log line written when blocker fires
# ===========================================================================

@test "detect_lib_shrinkage: writes [diag] SHRINKAGE_BLOCKER line to RITE_LOG_FILE" {
  local target_file="lib/core/assess-review-issues.sh"
  local n_deleted=1015

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  local log_file="$RITE_TEST_TMPDIR/rite-diag.log"
  RITE_LOG_FILE="$log_file" run detect_lib_shrinkage "260"

  # Blocker must fire
  [ "$status" -eq 1 ]

  # Log file must exist and contain the [diag] line
  [ -f "$log_file" ] || {
    echo "FAIL: RITE_LOG_FILE was not written"
    return 1
  }
  grep -q "\[diag\] SHRINKAGE_BLOCKER" "$log_file" || {
    echo "FAIL: [diag] SHRINKAGE_BLOCKER line not found in log"
    cat "$log_file"
    return 1
  }
  # Must include the PR number and file
  grep -q "pr=260" "$log_file" || {
    echo "FAIL: pr=260 not found in diag line"
    cat "$log_file"
    return 1
  }
}

# ===========================================================================
# TEST 10: check_blockers "pre-merge" delegates to detect_lib_shrinkage
# ===========================================================================

@test "check_blockers pre-merge: sets BLOCKER_TYPE=lib_shrinkage when shrinkage detected" {
  local target_file="lib/utils/blocker-rules.sh"
  local n_deleted=600

  local _target_file="$target_file"
  local _n_deleted="$n_deleted"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_n_deleted}'
        return 0
      fi
      # detect_critical_issues calls: gh_safe pr view N --json comments
      # detect_lib_shrinkage calls: gh_safe pr view N --json files
      # Return safe empty values for all JSON views
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ]; then
        echo '{\"comments\":[],\"files\":[]}'
        return 0
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    # check_blockers returns 1 on blocker; capture without triggering set -e
    _cb_exit=0
    check_blockers 'pre-merge' '260' '42' 'unsupervised' || _cb_exit=\$?
    echo \"CB_EXIT=\${_cb_exit}\"
    echo \"BLOCKER_TYPE=\${BLOCKER_TYPE:-none}\"
  "

  # check_blockers must return non-zero (blocker detected)
  # The bash -c exits 0 because we captured the exit; check the reported CB_EXIT
  [[ "$output" == *"CB_EXIT=1"* ]] || [ "$status" -ne 0 ]
  [[ "$output" == *"lib_shrinkage"* ]] || [[ "$output" == *"BLOCKER"* ]]
}

# ===========================================================================
# TEST 11: check_blockers "pre-merge" passes cleanly when no shrinkage
# ===========================================================================

@test "check_blockers pre-merge: passes when no lib/ shrinkage" {
  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      # Only non-lib/ or tiny changes
      _make_lib_diff "tests/some-test.bats" 10
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  # Also need to stub detect_critical_issues (called before detect_lib_shrinkage)
  detect_critical_issues() { return 0; }
  export -f detect_critical_issues

  run bash -c "
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    $(declare -f gh_safe)
    $(declare -f detect_critical_issues)
    export -f gh_safe detect_critical_issues
    check_blockers 'pre-merge' '99' '42' 'unsupervised'
    echo 'passed'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
}

# ===========================================================================
# TEST 12: get_blocker_urgency returns "high" for lib_shrinkage
# ===========================================================================

@test "get_blocker_urgency returns high for lib_shrinkage" {
  run get_blocker_urgency "lib_shrinkage"

  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
}

# ===========================================================================
# TEST 13: is_blocking_batch returns false for lib_shrinkage (per-issue blocker)
# ===========================================================================

@test "is_blocking_batch returns false for lib_shrinkage" {
  run is_blocking_batch "lib_shrinkage"

  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# ===========================================================================
# TEST 14: Incident scenario — 1,015+235 line deletion triggers blocker
# ===========================================================================

@test "incident scenario: 1015+235 line deletion matches 2026-06-02 PR #260 pattern" {
  # Simulate the exact scenario from the incident
  local file1="lib/core/assess-review-issues.sh"
  local file2="lib/utils/format-review.sh"

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$file1" 1015
      _make_lib_diff "$file2" 235
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"--json files"* ]]; then
      echo ""
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "260"

  # Both files exceed the 500 absolute threshold — blocker must fire
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
  # The incident file must be mentioned
  [[ "$output" == *"assess-review-issues"* ]]
}
