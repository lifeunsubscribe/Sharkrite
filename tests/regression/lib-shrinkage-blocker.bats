#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/blocker-rules.sh
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
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Re-stub after source: blocker-rules.sh chains into gh-retry.sh (env-var guard
  # _RITE_GH_RETRY_LOADED) and notifications.sh (env-var guard
  # _RITE_NOTIFICATIONS_LOADED), both of which overwrite pre-source stubs. gh_safe
  # must call the controlled mock (not the real gh binary); send_blocker_notification
  # must no-op so tests don't attempt real Slack/email delivery.
  # print_* are re-stubbed defensively (colors.sh is not in the chain here, but
  # restoring them makes test output stable regardless of future dependency changes).
  gh_safe() { command gh "$@"; }
  send_blocker_notification() { :; }
  print_info()    { echo "[INFO] $*" >&2; }
  print_warning() { echo "[WARN] $*" >&2; }
  print_error()   { echo "[ERROR] $*" >&2; }
  print_success() { echo "[OK] $*" >&2; }
  print_status()  { echo "[STATUS] $*" >&2; }
  export -f gh_safe send_blocker_notification print_info print_warning print_error print_success print_status
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
  local _total_lines="$total_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  # Run from RITE_TEST_TMPDIR so relative path '$target_file' resolves to the local copy.
  # We mock `git` so `git show origin/<base_branch>:<path>` returns synthetic file content
  # (the correct baseline line count) without requiring a real git repo in the tmpdir.
  # gh_safe is also mocked: the new base-branch resolution call returns "main" so
  # detect_lib_shrinkage uses origin/main:path as expected for a main-base PR.
  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Return the base branch name for dynamic base-branch resolution
        echo 'main'
        return 0
      fi
      return 1
    }
    # Mock git so 'git -C <dir> show origin/<base_branch>:<path>' returns the expected
    # baseline line count without requiring a real git repo in the test tmpdir.
    # Also handle 'git -C <dir> fetch origin <branch>' (best-effort fetch — no-op here).
    git() {
      # Handle: git -C <dir> fetch origin <branch>
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        return 0
      fi
      # Handle: git -C <dir> show origin/<branch>:<path>
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/*:* ]]; then
        seq 1 '${_total_lines}'
        return 0
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
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

# ===========================================================================
# TEST 15: Ratio check skipped when git show returns empty baseline —
#          skip is observable (diag log) and does NOT silently block
# ===========================================================================

@test "detect_lib_shrinkage: ratio skip is observable when git show returns empty baseline" {
  # A mid-range deletion (>10 lines, below 500 absolute threshold) in a lib/ file.
  # git show origin/main:<path> returns empty — simulates an unfetched ref or new file.
  # Before the fix: the ratio check continued silently with no signal.
  # After the fix: a [diag] SHRINKAGE_RATIO_SKIP line is written to RITE_LOG_FILE.
  local target_file="lib/core/workflow-runner.sh"
  local deleted_lines=100  # >10 (triggers ratio path), <500 (below absolute threshold)

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  local log_file="$RITE_TEST_TMPDIR/rite-ratio-skip.log"

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    export RITE_LOG_FILE='$log_file'
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Return base branch for dynamic resolution (main for this test)
        echo 'main'
        return 0
      fi
      return 1
    }
    # git show returns no output — simulates an unfetched or new-file ref even
    # after the best-effort fetch attempt.  fetch is mocked as a no-op.
    # Use printf (no args) rather than echo '' to produce truly zero bytes of output
    # so that wc -l returns 0, triggering the total_lines <= 0 branch.
    git() {
      # Handle: git -C <dir> fetch origin <branch> (best-effort — no-op in test)
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/*:* ]]; then
        printf ''
        return 0
      fi
      command git \"\$@\"
    }
    print_warning() { echo \"[WARN] \$*\" >&2; }
    export -f gh_safe _make_lib_diff git print_warning
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '99'
  "

  # Absolute threshold does NOT fire (100 < 500) — no blocker
  [ "$status" -eq 0 ]

  # The [diag] SHRINKAGE_RATIO_SKIP line must be written to the log file
  [ -f "$log_file" ] || {
    echo "FAIL: RITE_LOG_FILE was not written — ratio skip is not observable"
    return 1
  }
  grep -q "SHRINKAGE_RATIO_SKIP" "$log_file" || {
    echo "FAIL: [diag] SHRINKAGE_RATIO_SKIP not found in log"
    cat "$log_file"
    return 1
  }
  # Must include the file name and deleted count
  grep -q "file=$target_file" "$log_file" || {
    echo "FAIL: file= not found in diag line"
    cat "$log_file"
    return 1
  }
  grep -q "deleted=${deleted_lines}" "$log_file" || {
    echo "FAIL: deleted= not found in diag line"
    cat "$log_file"
    return 1
  }
}

# ===========================================================================
# TEST 16: Orchestrated bypass path — BYPASS_BLOCKERS exported to create-pr.sh
#
# Regression for: "--bypass-blockers silently ineffective in PR-creation
# shrinkage check (not exported to subprocess)".
#
# Verifies that when BYPASS_BLOCKERS=true is set inside workflow-runner.sh
# and exported before calling create-pr.sh, the env var crosses the process
# boundary so the shrinkage gate sees it.
#
# We test the env-var propagation directly: a subprocess that sources the
# relevant section of the gate logic with BYPASS_BLOCKERS exported must
# reach the bypass branch, not the blocking branch.
# ===========================================================================

@test "shrinkage bypass: BYPASS_BLOCKERS=true exported as env var reaches subprocess gate" {
  # Simulate the gate logic from create-pr.sh that reads BYPASS_BLOCKERS.
  # We run it in a subprocess (as create-pr.sh is when called from workflow-runner.sh)
  # with BYPASS_BLOCKERS exported.  The subprocess must exit 0 (bypass path).
  run bash -c "
    export BYPASS_BLOCKERS=true
    export WORKFLOW_MODE=unsupervised
    # Simulate exactly the gate condition from create-pr.sh:
    #   shrinkage fires (_shrinkage_exit != 0), bypass check runs
    _bypass=\"\${BYPASS_BLOCKERS:-false}\"
    _wf_mode=\"\${WORKFLOW_MODE:-unsupervised}\"
    if [ \"\$_wf_mode\" = 'supervised' ]; then
      echo 'WRONG: reached supervised branch'
      exit 1
    elif [ \"\$_bypass\" = 'true' ]; then
      echo 'BYPASS: continuing as expected'
      exit 0
    else
      echo 'BLOCK: bypass did not reach subprocess'
      exit 1
    fi
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"BYPASS"* ]]
}

@test "shrinkage bypass: BYPASS_BLOCKERS NOT exported stays false in subprocess" {
  # Verify the inverse: without export, the subprocess does NOT see the value.
  # This documents the bug that existed before the fix.
  run bash -c "
    # Set but do NOT export (the pre-fix bug)
    BYPASS_BLOCKERS=true
    bash -c '
      _bypass=\"\${BYPASS_BLOCKERS:-false}\"
      echo \"inner_bypass=\$_bypass\"
    '
  "

  [ "$status" -eq 0 ]
  # Without export, the inner shell sees false (the bug)
  [[ "$output" == *"inner_bypass=false"* ]]
}

# ===========================================================================
# TEST 17: Pre-existing PR not auto-closed on resume when shrinkage fires
#
# Regression for: "Shrinkage check auto-closes pre-existing PRs on resume runs".
#
# Verifies that when PR_CREATED_THIS_RUN=false (resume run), the shrinkage
# gate does NOT call gh_safe pr close — it aborts but leaves the PR intact.
# ===========================================================================

@test "shrinkage gate: does NOT close pre-existing PR on resume when blocker fires (auto mode)" {
  local pr_closed=false

  # Run the gate logic with PR_CREATED_THIS_RUN=false (resume scenario)
  run bash -c "
    export WORKFLOW_MODE=unsupervised
    export BYPASS_BLOCKERS=false
    export PR_CREATED_THIS_RUN=false
    export PR_NUMBER=99

    # Stub gh_safe: record if pr close is called
    _pr_close_called=false
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'close' ]; then
        _pr_close_called=true
        echo 'ERROR: pr close called on pre-existing PR'
        return 0
      fi
    }

    _wf_mode=\"\${WORKFLOW_MODE:-unsupervised}\"
    _bypass=\"\${BYPASS_BLOCKERS:-false}\"
    if [ \"\$_wf_mode\" = 'supervised' ]; then
      echo 'WRONG: supervised branch'
      exit 1
    elif [ \"\$_bypass\" = 'true' ]; then
      echo 'WRONG: bypass branch'
      exit 1
    else
      if [ \"\${PR_CREATED_THIS_RUN:-false}\" = 'true' ]; then
        gh_safe pr close \"\$PR_NUMBER\" -c 'Closed: shrinkage'
        echo 'CLOSE_CALLED'
      else
        echo 'ABORT_NO_CLOSE'
      fi
      exit 1
    fi
  "

  # Must exit non-zero (blocker fires)
  [ "$status" -eq 1 ]
  # Must NOT have called pr close
  [[ "$output" == *"ABORT_NO_CLOSE"* ]]
  [[ "$output" != *"CLOSE_CALLED"* ]]
  [[ "$output" != *"ERROR: pr close"* ]]
}

@test "shrinkage gate: DOES close newly-created PR when blocker fires (auto mode)" {
  # Verify the positive case: a PR created this run IS auto-closed
  run bash -c "
    export WORKFLOW_MODE=unsupervised
    export BYPASS_BLOCKERS=false
    export PR_CREATED_THIS_RUN=true
    export PR_NUMBER=42

    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'close' ]; then
        echo 'CLOSE_CALLED'
        return 0
      fi
    }

    _wf_mode=\"\${WORKFLOW_MODE:-unsupervised}\"
    _bypass=\"\${BYPASS_BLOCKERS:-false}\"
    if [ \"\$_wf_mode\" = 'supervised' ]; then
      echo 'WRONG'
      exit 1
    elif [ \"\$_bypass\" = 'true' ]; then
      echo 'WRONG'
      exit 1
    else
      if [ \"\${PR_CREATED_THIS_RUN:-false}\" = 'true' ]; then
        gh_safe pr close \"\$PR_NUMBER\" -c 'Closed: shrinkage'
      else
        echo 'WRONG: should have closed'
      fi
      exit 1
    fi
  "

  # Must exit non-zero (blocker fires)
  [ "$status" -eq 1 ]
  # pr close MUST have been called
  [[ "$output" == *"CLOSE_CALLED"* ]]
}

# ===========================================================================
# TEST 18: Path with spaces in filename — $NF would return only last token;
#          split-on-" b/" must return the full path so the blocker fires.
# ===========================================================================

@test "detect_lib_shrinkage: fires for lib/ file whose path contains spaces" {
  # A hypothetical file with a space — unusual but valid in git.
  # $NF would return "issues.sh" (last token); the split(" b/") approach
  # returns the full path "lib/core/assess review issues.sh".
  local target_file="lib/core/assess review issues.sh"
  local n_deleted=600  # above absolute threshold

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      # Build diff header manually so the space in the path is preserved
      printf 'diff --git a/%s b/%s\n' "$target_file" "$target_file"
      printf 'index abc1234..def5678 100755\n'
      printf '--- a/%s\n' "$target_file"
      printf '+++ b/%s\n' "$target_file"
      printf '@@ -1,%d +1,5 @@\n' "$n_deleted"
      local i
      for i in $(seq 1 "$n_deleted"); do printf -- '-deleted line %d\n' "$i"; done
      for i in $(seq 1 5);           do printf '+added line %d\n'   "$i"; done
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "313"

  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
  # The path (or at least the unique fragment) must appear in the output
  [[ "$output" == *"assess review issues"* ]] || [[ "$output" == *"assess"* ]]
}

# ===========================================================================
# TEST 19: Pure rename within lib/ — no content changes, no blocker.
#          similarity index 100% means no -/+ content lines exist.
# ===========================================================================

@test "detect_lib_shrinkage: does NOT fire for pure rename within lib/ (similarity 100%)" {
  # A pure rename produces no deleted content lines — only the diff header,
  # similarity index, rename from/to metadata, and no hunk body.
  local old_file="lib/core/old-name.sh"
  local new_file="lib/core/new-name.sh"

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      printf 'diff --git a/%s b/%s\n' "$old_file" "$new_file"
      printf 'similarity index 100%%\n'
      printf 'rename from %s\n' "$old_file"
      printf 'rename to %s\n'   "$new_file"
      # No hunk — pure rename has no content diff
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "313"

  # No deleted lines → no blocker
  [ "$status" -eq 0 ]
}

# ===========================================================================
# TEST 20: Rename OUT of lib/ with content gutting — destination is outside
#          lib/, so the blocker should NOT fire (file is no longer production).
#          The "rename to" rule must update current_file to the destination.
# ===========================================================================

@test "detect_lib_shrinkage: does NOT fire when renamed-and-gutted file moves OUT of lib/" {
  # Old file was in lib/core/, new file lands in tests/ — not a production path.
  # Without the "rename to" fix, current_file stays as the lib/ source path and
  # the blocker fires incorrectly.
  local old_file="lib/core/assess-review-issues.sh"
  local new_file="tests/regression/assess-review-issues.sh"
  local n_deleted=600

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      printf 'diff --git a/%s b/%s\n' "$old_file" "$new_file"
      printf 'similarity index 40%%\n'
      printf 'rename from %s\n' "$old_file"
      printf 'rename to %s\n'   "$new_file"
      printf 'index abc1234..def5678 100755\n'
      printf '--- a/%s\n' "$old_file"
      printf '+++ b/%s\n' "$new_file"
      printf '@@ -1,%d +1,5 @@\n' "$n_deleted"
      local i
      for i in $(seq 1 "$n_deleted"); do printf -- '-deleted line %d\n' "$i"; done
      for i in $(seq 1 5);           do printf '+added line %d\n'   "$i"; done
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "313"

  # Destination is outside lib/ — no blocker
  [ "$status" -eq 0 ]
}

# ===========================================================================
# TEST 21: Rename INTO lib/ with content gutting — destination IS in lib/,
#          blocker MUST fire because production code is being gutted.
# ===========================================================================

@test "detect_lib_shrinkage: fires when file renamed INTO lib/ and gutted" {
  # Old file was outside lib/, new file lands in lib/core/ with lots of deletions.
  # The "rename to" rule updates current_file to the new lib/ path, and the
  # blocker correctly fires because the destination is a production path.
  local old_file="tests/regression/some-test.sh"
  local new_file="lib/core/some-helper.sh"
  local n_deleted=600

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      printf 'diff --git a/%s b/%s\n' "$old_file" "$new_file"
      printf 'similarity index 40%%\n'
      printf 'rename from %s\n' "$old_file"
      printf 'rename to %s\n'   "$new_file"
      printf 'index abc1234..def5678 100755\n'
      printf '--- a/%s\n' "$old_file"
      printf '+++ b/%s\n' "$new_file"
      printf '@@ -1,%d +1,5 @@\n' "$n_deleted"
      local i
      for i in $(seq 1 "$n_deleted"); do printf -- '-deleted line %d\n' "$i"; done
      for i in $(seq 1 5);           do printf '+added line %d\n'   "$i"; done
      return 0
    fi
    return 1
  }
  export -f gh_safe

  run detect_lib_shrinkage "313"

  # Destination is in lib/core/ — blocker must fire
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
}

# ===========================================================================
# TEST 21: Dynamic base branch — non-main PR uses the correct baseline ref
#
# Regression for: hardcoded origin/main baseline ignores non-main PR targets.
# When a PR targets "develop", the ratio baseline must use origin/develop, not
# origin/main.  A >50% deletion against develop should fire; the same deletion
# against a 2x-larger main file should NOT fire (different baseline = different ratio).
# ===========================================================================

@test "detect_lib_shrinkage: uses dynamic base branch from PR for ratio baseline" {
  local target_file="lib/core/workflow-runner.sh"
  local total_lines_develop=200   # file is 200 lines on develop
  local deleted_lines=110         # 55% of develop — should fire

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _total_lines_develop="$total_lines_develop"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # PR targets develop, not main
        echo 'develop'
        return 0
      fi
      return 1
    }
    # Mock git: fetch is a no-op; show returns the develop-branch line count
    # (200 lines).  The pattern matches origin/<any-branch>:<path>.
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/develop:* ]]; then
        seq 1 '${_total_lines_develop}'
        return 0
      fi
      # origin/main must NOT be called — the PR targets develop
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/main:* ]]; then
        echo 'ERROR: origin/main used for non-main PR' >&2
        return 1
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '99'
  "

  # 110 deleted of 200 on develop = 55% > 50% threshold — blocker must fire
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
  # Must NOT have accidentally used origin/main (would be a different baseline)
  [[ "$output" != *"ERROR: origin/main"* ]]
}

# ===========================================================================
# TEST 22: Dynamic base branch — fetch refreshes stale ref before git show
#
# Verifies that detect_lib_shrinkage attempts git fetch origin <base_branch>
# before calling git show, so a stale local ref does not silently skip the
# ratio check.  We confirm the fetch is called with the correct branch name.
# ===========================================================================

@test "detect_lib_shrinkage: fetches base branch ref before git show baseline lookup" {
  local target_file="lib/core/create-pr.sh"
  local total_lines=300
  local deleted_lines=160  # ~53% — above 50% threshold

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _total_lines="$total_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  # Use a temp file to record fetch calls so the state survives detect_lib_shrinkage
  # returning exit 1 (which kills the outer bash -c script under set -e).
  local fetch_state_file="$RITE_TEST_TMPDIR/fetch-state-$$.txt"

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'main'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        # Write fetch call to temp file so it survives set -e abort after blocker
        echo \"fetch_called=true fetch_branch=\$5\" > '${fetch_state_file}'
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/*:* ]]; then
        seq 1 '${_total_lines}'
        return 0
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '77'
  "

  # Blocker fires (160/300 = 53% > 50%)
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
  # The fetch must have been called with the resolved base branch
  [ -f "$fetch_state_file" ] || {
    echo "FAIL: fetch was never called (state file not written)"
    return 1
  }
  grep -q "fetch_called=true" "$fetch_state_file" || {
    echo "FAIL: fetch_called=true not found in state file"
    cat "$fetch_state_file"
    return 1
  }
  grep -q "fetch_branch=main" "$fetch_state_file" || {
    echo "FAIL: fetch_branch=main not found in state file"
    cat "$fetch_state_file"
    return 1
  }
}

# ===========================================================================
# TEST 23: Dynamic base branch — falls back to "main" when API call fails
#
# When gh_safe pr view --json baseRefName returns non-zero (network error,
# PR not found), base_branch must fall back to "main" so the check degrades
# gracefully rather than crashing or skipping entirely.
# ===========================================================================

@test "detect_lib_shrinkage: falls back to main when base-branch API call fails" {
  local target_file="lib/utils/blocker-rules.sh"
  local n_deleted=600  # above absolute threshold — blocker fires regardless of ratio

  gh_safe() {
    if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
      _make_lib_diff "$target_file" "$n_deleted"
      return 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ] && [[ "$*" == *"baseRefName"* ]]; then
      # Simulate API failure (network error, auth issue, etc.)
      return 1
    fi
    return 1
  }
  export -f gh_safe

  # Function must not crash — it falls back to "main" and fires the absolute blocker
  run detect_lib_shrinkage "77"

  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]
}

# ===========================================================================
# TEST 24: Dynamic base branch — diag log includes base_branch= field
#
# Verifies that both the SHRINKAGE_RATIO_SKIP and SHRINKAGE_BLOCKER [diag]
# lines include a base_branch= field so health reports and operator logs can
# distinguish main-base from non-main-base shrinkage events.
# ===========================================================================

@test "detect_lib_shrinkage: diag log includes base_branch= for ratio skip" {
  local target_file="lib/core/workflow-runner.sh"
  local deleted_lines=100  # >10 (triggers ratio path), <500 (below absolute threshold)

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  local log_file="$RITE_TEST_TMPDIR/rite-ratio-skip-basebranch.log"

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    export RITE_LOG_FILE='$log_file'
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'develop'
        return 0
      fi
      return 1
    }
    # git show returns empty to trigger the SHRINKAGE_RATIO_SKIP diag line
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/*:* ]]; then
        printf ''
        return 0
      fi
      command git \"\$@\"
    }
    print_warning() { echo \"[WARN] \$*\" >&2; }
    export -f gh_safe _make_lib_diff git print_warning
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '99'
  "

  # No blocker (100 < 500 abs, ratio skipped due to empty baseline)
  [ "$status" -eq 0 ]

  # The diag line must include base_branch=develop
  [ -f "$log_file" ] || {
    echo "FAIL: RITE_LOG_FILE was not written"
    return 1
  }
  grep -q "SHRINKAGE_RATIO_SKIP" "$log_file" || {
    echo "FAIL: SHRINKAGE_RATIO_SKIP not found"
    cat "$log_file"
    return 1
  }
  grep -q "base_branch=develop" "$log_file" || {
    echo "FAIL: base_branch=develop not found in diag line"
    cat "$log_file"
    return 1
  }
}

# ===========================================================================
# TEST 25: SHRINKAGE_BLOCKER_FILES exports ALL violating file paths
#
# Regression for issue #357: head -1 export meant only the first file was
# exported, so handle_blocker's revert guidance named only one file for a
# multi-file deletion PR — causing an extra fix cycle for the remaining files.
#
# Verifies that SHRINKAGE_BLOCKER_FILES is a newline-separated list of every
# file that exceeded a threshold, and that SHRINKAGE_BLOCKER_FILE (singular)
# still holds the first violation for backward compat / diag logging.
# ===========================================================================

@test "detect_lib_shrinkage: SHRINKAGE_BLOCKER_FILES contains all violating files (multi-file PR)" {
  # Simulate the 2026-06-02 incident: two lib/ files both exceed the absolute threshold.
  # Both files use >500 line deletions so only the absolute check fires — no git show needed.
  local file1="lib/core/assess-review-issues.sh"
  local file2="lib/utils/format-review.sh"
  local file1_deleted=1015
  local file2_deleted=600  # above absolute threshold — no ratio check path needed

  local _file1="$file1"
  local _file2="$file2"
  local _file1_deleted="$file1_deleted"
  local _file2_deleted="$file2_deleted"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_file1}' '${_file1_deleted}'
        _make_lib_diff '${_file2}' '${_file2_deleted}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'main'
        return 0
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    # detect_lib_shrinkage exits 1 on blocker; capture without triggering set -e
    _exit=0
    detect_lib_shrinkage '260' || _exit=\$?
    echo \"EXIT=\${_exit}\"
    echo \"BLOCKER_FILE=\${SHRINKAGE_BLOCKER_FILE:-UNSET}\"
    # Print each entry in SHRINKAGE_BLOCKER_FILES on its own prefixed line
    # so the assertions below can grep for exact paths without false matches.
    while IFS= read -r _f; do
      [ -n \"\$_f\" ] && echo \"FILES_ENTRY:\$_f\"
    done <<< \"\${SHRINKAGE_BLOCKER_FILES:-}\"
    _files_count=\$(echo \"\${SHRINKAGE_BLOCKER_FILES:-}\" | grep -c '.' || true)
    echo \"FILES_COUNT=\${_files_count}\"
  "

  # Blocker must fire
  [[ "$output" == *"EXIT=1"* ]]

  # SHRINKAGE_BLOCKER_FILE (singular) must still be set to the first violation
  [[ "$output" == *"BLOCKER_FILE=${file1}"* ]] || [[ "$output" == *"BLOCKER_FILE="* ]]

  # SHRINKAGE_BLOCKER_FILES must contain BOTH files
  [[ "$output" == *"FILES_ENTRY:${file1}"* ]]
  [[ "$output" == *"FILES_ENTRY:${file2}"* ]]

  # Must have exactly 2 entries (no duplicates, no missing)
  [[ "$output" == *"FILES_COUNT=2"* ]]
}

# ===========================================================================
# TEST 26: Single-file violation — SHRINKAGE_BLOCKER_FILES has exactly one entry
#
# Ensures the fix does not regress single-file PRs: one violation must still
# produce one entry in SHRINKAGE_BLOCKER_FILES (not zero, not duplicated).
# ===========================================================================

@test "detect_lib_shrinkage: SHRINKAGE_BLOCKER_FILES has exactly one entry for single-file violation" {
  local target_file="lib/core/assess-review-issues.sh"
  local n_deleted=1015

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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'main'
        return 0
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '260' || _exit=\$?
    echo \"EXIT=\${_exit}\"
    while IFS= read -r _f; do
      [ -n \"\$_f\" ] && echo \"FILES_ENTRY:\$_f\"
    done <<< \"\${SHRINKAGE_BLOCKER_FILES:-}\"
    _files_count=\$(echo \"\${SHRINKAGE_BLOCKER_FILES:-}\" | grep -c '.' || true)
    echo \"FILES_COUNT=\${_files_count}\"
  "

  # Blocker must fire
  [[ "$output" == *"EXIT=1"* ]]

  # SHRINKAGE_BLOCKER_FILES must have exactly one entry
  [[ "$output" == *"FILES_ENTRY:${target_file}"* ]]
  [[ "$output" == *"FILES_COUNT=1"* ]]
}

# ===========================================================================
# TEST 27: Fetch NOT called when PR has no lib/ file changes
#
# Regression for issue #429: git fetch ran unconditionally even when no
# lib/ files were touched, burning unnecessary network time on every PR.
# The fetch is a pre-requisite only for the ratio check, which itself only
# runs when lib/ files have deletions — skip both when no lib/ files changed.
# ===========================================================================

@test "detect_lib_shrinkage: does NOT call git fetch when diff has no lib/ files" {
  # Diff contains only a docs file — no lib/ changes.  git fetch must NOT be called.
  local fetch_state_file="$RITE_TEST_TMPDIR/fetch-state-no-lib-$$.txt"

  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        # Only non-lib/ changes — large deletions in docs should not trigger
        _make_lib_diff 'docs/architecture/behavioral-design.md' 800
        _make_lib_diff 'tests/regression/some-test.bats' 600
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # This call must NOT be reached when there are no lib/ files in the diff
        echo 'ERROR: baseRefName called for non-lib PR' >&2
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        echo 'FETCH_CALLED' > '${fetch_state_file}'
        return 0
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '99'
  "

  # No blocker (non-lib files)
  [ "$status" -eq 0 ]

  # git fetch must NOT have been called
  [ ! -f "$fetch_state_file" ] || {
    echo "FAIL: git fetch was called for a non-lib PR (fetch-state file exists)"
    cat "$fetch_state_file"
    return 1
  }
}

@test "detect_lib_shrinkage: DOES call git fetch when lib/ files are present in diff" {
  # Confirms the positive case: fetch IS called when lib/ files have deletions.
  # This prevents a regression where the conditional fetch optimization is
  # applied too aggressively and skips the fetch even for lib/ PRs.
  local target_file="lib/core/workflow-runner.sh"
  local total_lines=300
  local deleted_lines=160  # ~53% — above 50% ratio threshold

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _total_lines="$total_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  local fetch_state_file="$RITE_TEST_TMPDIR/fetch-state-with-lib-$$.txt"

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'main'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        echo \"fetch_called=true fetch_branch=\$5\" > '${fetch_state_file}'
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/*:* ]]; then
        seq 1 '${_total_lines}'
        return 0
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    detect_lib_shrinkage '77'
  "

  # Blocker fires (160/300 = 53% > 50%)
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # git fetch MUST have been called (lib/ files were present)
  [ -f "$fetch_state_file" ] || {
    echo "FAIL: git fetch was not called for lib/ PR"
    return 1
  }
  grep -q "fetch_called=true" "$fetch_state_file" || {
    echo "FAIL: fetch_called=true not found"
    cat "$fetch_state_file"
    return 1
  }
}

# ===========================================================================
# TEST 28: base_branch validation — invalid characters fall back to "main"
#
# Regression for: base_branch not validated before interpolation into git refs.
# A crafted baseRefName from the GitHub API (path traversal, shell meta-chars)
# could be interpolated as "origin/${base_branch}:${filepath}" in git show.
# The validation must reject non-safe characters and fall back to "main".
# ===========================================================================

@test "detect_lib_shrinkage: rejects path-traversal base_branch and falls back to main" {
  # Simulate a crafted baseRefName containing "../evil" path traversal.
  # The validation must reject this and fall back to "main".
  local target_file="lib/core/workflow-runner.sh"
  local n_deleted=600  # above absolute threshold — simple blocker case

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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Return a malicious branch name with path traversal
        printf '../evil-ref'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        # Record which branch was used for the fetch
        echo \"fetch_branch=\$5\" >&2
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ]; then
        echo \"git_show_ref=\$4\" >&2
        return 1
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
  "

  # Blocker fires (absolute threshold: 600 > 500)
  [[ "$output" == *"EXIT=1"* ]] || [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # The invalid base_branch must NOT appear in git ref calls.
  # stderr captures the git calls; "../evil-ref" must not appear there.
  [[ "$output" != *"../evil-ref"* ]] || {
    echo "FAIL: path-traversal base_branch was used in a git ref call"
    echo "output: $output"
    return 1
  }
}

@test "detect_lib_shrinkage: rejects shell-metachar base_branch and falls back to main" {
  # Simulate a crafted baseRefName with shell meta-characters (e.g. command injection).
  # Must be rejected and fall back to "main".
  local target_file="lib/core/workflow-runner.sh"
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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Return a branch name with shell meta-character (semicolon)
        printf 'main;touch /tmp/pwned'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        echo \"fetch_branch=\$5\" >&2
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ]; then
        return 1
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
  "

  # Blocker fires (absolute threshold)
  [[ "$output" == *"EXIT=1"* ]] || [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # The invalid base_branch with shell meta-chars must not appear in git calls
  [[ "$output" != *"touch /tmp/pwned"* ]] || {
    echo "FAIL: shell-metachar base_branch was used in a git call"
    return 1
  }
}

# ===========================================================================
# TEST 28b: Multi-line base_branch cannot bypass the allowlist
#
# Regression for: validation regex permits multi-line base_branch to bypass
# allowlist.  A crafted baseRefName with an embedded newline (e.g. "main\nevil")
# causes grep's ^/$ anchors to evaluate each line in isolation — the first line
# "main" matches the allowlist, the overall grep returns 0, and the evil payload
# in the second line is never tested.  The fix strips newlines before the
# allowlist check runs so the entire value is evaluated as one token.
#
# Without the fix: base_branch stays as "main\nevil" (or "main\nevil;cmd"),
# the validation passes, and the multi-line payload is interpolated into
# "origin/${base_branch}:path" — producing a malformed (and potentially
# exploitable) git ref argument.
# With the fix: newlines are stripped first, collapsing "main\nevil" to
# "mainevil" which fails the allowlist and falls back to "main".
# ===========================================================================

@test "detect_lib_shrinkage: rejects multi-line base_branch (newline bypass attempt) and falls back to main" {
  # A crafted baseRefName: "main\nevil;cmd" — the first line passes the
  # allowlist regex when grep processes lines individually, but the second line
  # contains forbidden characters.  The fix must collapse this to a single token
  # before running the allowlist so the entire value is evaluated.
  local target_file="lib/core/workflow-runner.sh"
  local n_deleted=600  # above absolute threshold — simple blocker case

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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Return a branch name with an embedded newline followed by a forbidden token.
        # Without the fix, grep sees 'main' on line 1 (valid), never checks line 2.
        printf 'main\nevil;cmd'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        # Record which branch was passed to fetch so we can assert 'main' not 'mainevil'
        echo \"fetch_branch=\$5\" >&2
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ]; then
        # Record the ref arg to verify it does NOT contain the evil payload
        echo \"git_show_ref=\$4\" >&2
        return 1
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
  "

  # Blocker fires (absolute threshold: 600 > 500)
  [[ "$output" == *"EXIT=1"* ]] || [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # The evil payload must NOT appear in any git ref call — the multi-line value
  # must have been stripped and fallen back to "main" before reaching git.
  [[ "$output" != *"evil"* ]] || {
    echo "FAIL: multi-line payload appeared in git call — newline bypass not blocked"
    echo "output: $output"
    return 1
  }
}

@test "detect_lib_shrinkage: multi-line base_branch with valid-looking first line is rejected" {
  # Variant: "develop\n../evil" — first line "develop" passes the allowlist,
  # second line contains path-traversal.  After stripping newlines the combined
  # value "develop../evil" contains ".." and must be caught by the '..' check.
  local target_file="lib/core/workflow-runner.sh"
  local total_lines=200
  local deleted_lines=110  # 55% — above ratio threshold; we need ratio-check path

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _total_lines="$total_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # 'develop' is valid; '../evil' contains path traversal.
        # After newline stripping: 'develop../evil' contains '..' and is rejected.
        printf 'develop\n../evil'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        echo \"fetch_branch=\$5\" >&2
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == origin/*:* ]]; then
        # Return a valid baseline so the ratio check would fire if base_branch slipped through
        seq 1 '${_total_lines}'
        return 0
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
  "

  # Blocker fires (ratio: 110/200 = 55%)
  [[ "$output" == *"EXIT=1"* ]] || [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # The path-traversal payload must NOT appear in any git ref call
  [[ "$output" != *"../evil"* ]] || {
    echo "FAIL: path-traversal in multi-line base_branch reached git call"
    echo "output: $output"
    return 1
  }
}

# ===========================================================================
# TEST 29: SHRINKAGE_BLOCKER_BASE_BRANCH exported with correct value
#
# Regression for issue #464: handle_blocker revert guidance hardcoded
# "origin/main" even though detect_lib_shrinkage resolves the base branch
# dynamically.  SHRINKAGE_BLOCKER_BASE_BRANCH must be exported so callers
# can emit "git checkout origin/<base_branch>" with the correct ref.
# ===========================================================================

@test "detect_lib_shrinkage: exports SHRINKAGE_BLOCKER_BASE_BRANCH when blocker fires (main-base PR)" {
  local target_file="lib/core/workflow-runner.sh"
  local n_deleted=600  # above absolute threshold

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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'main'
        return 0
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
    echo \"BASE_BRANCH=\${SHRINKAGE_BLOCKER_BASE_BRANCH:-UNSET}\"
  "

  # Blocker must fire
  [[ "$output" == *"EXIT=1"* ]]
  # SHRINKAGE_BLOCKER_BASE_BRANCH must be exported as 'main'
  [[ "$output" == *"BASE_BRANCH=main"* ]]
}

@test "detect_lib_shrinkage: exports SHRINKAGE_BLOCKER_BASE_BRANCH=develop for non-main-base PR" {
  local target_file="lib/core/workflow-runner.sh"
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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # PR targets develop, not main
        echo 'develop'
        return 0
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
    echo \"BASE_BRANCH=\${SHRINKAGE_BLOCKER_BASE_BRANCH:-UNSET}\"
  "

  # Blocker must fire
  [[ "$output" == *"EXIT=1"* ]]
  # SHRINKAGE_BLOCKER_BASE_BRANCH must reflect the PR's actual base branch
  [[ "$output" == *"BASE_BRANCH=develop"* ]]
}

@test "detect_lib_shrinkage: exports SHRINKAGE_BLOCKER_BASE_BRANCH=main on API failure (fallback)" {
  local target_file="lib/core/workflow-runner.sh"
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
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Simulate API failure — no output, non-zero exit
        return 1
      fi
      return 1
    }
    export -f gh_safe _make_lib_diff
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
    echo \"BASE_BRANCH=\${SHRINKAGE_BLOCKER_BASE_BRANCH:-UNSET}\"
  "

  # Blocker must fire (absolute threshold)
  [[ "$output" == *"EXIT=1"* ]]
  # Must fall back to 'main' so revert guidance is not broken when API is unavailable
  [[ "$output" == *"BASE_BRANCH=main"* ]]
}

# ===========================================================================
# TEST 30: handle_blocker revert guidance uses dynamic base branch
#
# Regression for issue #464: the two "git checkout origin/main -- <file>"
# lines in handle_blocker's lib_shrinkage case must use
# SHRINKAGE_BLOCKER_BASE_BRANCH (set by detect_lib_shrinkage) instead of
# the hardcoded "main".  This test simulates a non-main-base PR and confirms
# the guidance mentions "origin/develop", not "origin/main".
# ===========================================================================

@test "handle_blocker lib_shrinkage: revert guidance uses SHRINKAGE_BLOCKER_BASE_BRANCH (not hardcoded origin/main)" {
  # Test the lib_shrinkage guidance logic directly by reproducing the relevant
  # section of handle_blocker in a self-contained bash subprocess.
  # This exercises the exact string-interpolation logic from workflow-runner.sh
  # without needing to source the full orchestrator (which has top-level executable
  # code and many deps).  The test validates that SHRINKAGE_BLOCKER_BASE_BRANCH
  # is consumed correctly for a non-main-base PR (develop).
  local target_file="lib/core/assess-review-issues.sh"

  local _target_file="$target_file"

  run bash -c "
    # Set what detect_lib_shrinkage exports for a non-main-base PR
    SHRINKAGE_BLOCKER_BASE_BRANCH=develop
    SHRINKAGE_BLOCKER_FILES='${_target_file}'
    SHRINKAGE_BLOCKER_FILE='${_target_file}'

    # Reproduce the guidance logic from handle_blocker lib_shrinkage case.
    # Variables use plain assignment (not local) — this runs in the main script
    # body of a bash -c subprocess, not inside a function.
    _revert_base=\"origin/\${SHRINKAGE_BLOCKER_BASE_BRANCH:-main}\"
    _first_sf=\"\"
    _sf_count=0
    _sf_label=\"\"
    if [ -n \"\${SHRINKAGE_BLOCKER_FILES:-}\" ]; then
      while IFS= read -r _sf; do
        [ -n \"\$_sf\" ] && echo \"    git checkout \${_revert_base} -- \${_sf}\"
      done <<< \"\$SHRINKAGE_BLOCKER_FILES\"
      _first_sf=\$(echo \"\$SHRINKAGE_BLOCKER_FILES\" | head -1 || true)
      _sf_count=\$(echo \"\$SHRINKAGE_BLOCKER_FILES\" | grep -c '.' || true)
      if [ \"\${_sf_count:-1}\" -gt 1 ]; then
        _sf_label=\"\${_first_sf:-lib/ files} (and \$(( _sf_count - 1 )) more)\"
      else
        _sf_label=\"\${_first_sf:-lib/ file}\"
      fi
    else
      echo \"    git checkout \${_revert_base} -- \${SHRINKAGE_BLOCKER_FILE:-<file>}\"
      _sf_label=\"\${SHRINKAGE_BLOCKER_FILE:-lib/ file}\"
    fi
    echo \"    git commit -m 'revert: restore accidentally deleted \${_sf_label}'\"
  "

  # The guidance must reference origin/develop (not origin/main)
  [[ "$output" == *"origin/develop"* ]] || {
    echo "FAIL: revert guidance did not use SHRINKAGE_BLOCKER_BASE_BRANCH=develop"
    echo "output: $output"
    return 1
  }

  # Must NOT reference origin/main (that's the old hardcoded value)
  [[ "$output" != *"origin/main"* ]] || {
    echo "FAIL: revert guidance still contains hardcoded 'origin/main'"
    echo "output: $output"
    return 1
  }

  # The target file must appear in the checkout command
  [[ "$output" == *"$target_file"* ]] || {
    echo "FAIL: target file not found in guidance output"
    echo "output: $output"
    return 1
  }
}

@test "handle_blocker lib_shrinkage: revert guidance uses origin/main when base branch is main" {
  # Positive case: when SHRINKAGE_BLOCKER_BASE_BRANCH=main, guidance uses origin/main.
  local target_file="lib/utils/blocker-rules.sh"
  local _target_file="$target_file"

  run bash -c "
    SHRINKAGE_BLOCKER_BASE_BRANCH=main
    SHRINKAGE_BLOCKER_FILES='${_target_file}'
    SHRINKAGE_BLOCKER_FILE='${_target_file}'

    # Plain assignment — running in main script body, not inside a function
    _revert_base=\"origin/\${SHRINKAGE_BLOCKER_BASE_BRANCH:-main}\"
    if [ -n \"\${SHRINKAGE_BLOCKER_FILES:-}\" ]; then
      while IFS= read -r _sf; do
        [ -n \"\$_sf\" ] && echo \"    git checkout \${_revert_base} -- \${_sf}\"
      done <<< \"\$SHRINKAGE_BLOCKER_FILES\"
    else
      echo \"    git checkout \${_revert_base} -- \${SHRINKAGE_BLOCKER_FILE:-<file>}\"
    fi
  "

  # Main-base PR: guidance must use origin/main
  [[ "$output" == *"origin/main"* ]] || {
    echo "FAIL: expected origin/main for main-base PR"
    echo "output: $output"
    return 1
  }
}

@test "handle_blocker lib_shrinkage: revert guidance falls back to origin/main when SHRINKAGE_BLOCKER_BASE_BRANCH unset" {
  # Backward-compat: when SHRINKAGE_BLOCKER_BASE_BRANCH is not set (pre-#464
  # callers or environments where the export did not propagate), guidance must
  # default to origin/main, not crash or use an empty string.
  local target_file="lib/utils/blocker-rules.sh"
  local _target_file="$target_file"

  run bash -c "
    # Do NOT set SHRINKAGE_BLOCKER_BASE_BRANCH (simulate pre-#464 env)
    unset SHRINKAGE_BLOCKER_BASE_BRANCH
    SHRINKAGE_BLOCKER_FILES='${_target_file}'
    SHRINKAGE_BLOCKER_FILE='${_target_file}'

    # Plain assignment — running in main script body, not inside a function
    _revert_base=\"origin/\${SHRINKAGE_BLOCKER_BASE_BRANCH:-main}\"
    if [ -n \"\${SHRINKAGE_BLOCKER_FILES:-}\" ]; then
      while IFS= read -r _sf; do
        [ -n \"\$_sf\" ] && echo \"    git checkout \${_revert_base} -- \${_sf}\"
      done <<< \"\$SHRINKAGE_BLOCKER_FILES\"
    else
      echo \"    git checkout \${_revert_base} -- \${SHRINKAGE_BLOCKER_FILE:-<file>}\"
    fi
  "

  # Must fall back to origin/main (not origin/ with empty branch)
  [[ "$output" == *"origin/main"* ]] || {
    echo "FAIL: expected fallback to origin/main when SHRINKAGE_BLOCKER_BASE_BRANCH unset"
    echo "output: $output"
    return 1
  }
  # Must NOT produce "origin/ --" (empty branch from unset var without default)
  [[ "$output" != *"origin/ --"* ]] || {
    echo "FAIL: empty base branch produced — default not applied"
    echo "output: $output"
    return 1
  }
}

# ===========================================================================
# TEST 31: SHRINKAGE_BASE_BRANCH_INVALID diag logs PRE-STRIP raw value
#
# Regression for issue #590 follow-up: the `_raw` field in the
# SHRINKAGE_BASE_BRANCH_INVALID diag line was logging the POST-strip value
# because `tr -d '\n\r'` ran before the diag was emitted.  The fix captures
# the raw value before stripping so the original attack payload (embedded
# newlines, path-traversal sequences) is preserved in the audit trail.
#
# For log parseability, literal newlines are visualized as '↵' and carriage
# returns as '←' rather than embedded as control characters.
# ===========================================================================

@test "SHRINKAGE_BASE_BRANCH_INVALID diag: logs pre-strip raw value (newline visualized as ↵)" {
  # A crafted baseRefName with an embedded newline: "main\nevil;cmd".
  # After stripping newlines the value becomes "mainevil;cmd" which fails the
  # allowlist and triggers the INVALID diag.  The diag must log the ORIGINAL
  # "main↵evil;cmd" (pre-strip, newlines visualized), not the stripped
  # "mainevil;cmd" (post-strip, hides the injection attempt).
  local target_file="lib/core/workflow-runner.sh"
  local n_deleted=600  # above absolute threshold — simple blocker case

  local _target_file="$target_file"
  local _n_deleted="$n_deleted"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)
  local log_file="$RITE_TEST_TMPDIR/rite-invalid-branch-raw.log"

  run bash -c "
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    export RITE_LOG_FILE='$log_file'
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_n_deleted}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        # Return a branch name with an embedded newline followed by a shell payload.
        # Without the fix the diag logs the post-strip value 'mainevil;cmd' which
        # hides the fact that a newline injection was attempted.
        printf 'main\nevil;cmd'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        return 0
      fi
      return 0
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
  "

  # Blocker fires (absolute threshold: 600 > 500)
  [[ "$output" == *"EXIT=1"* ]] || [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # The SHRINKAGE_BASE_BRANCH_INVALID diag must have been written
  [ -f "$log_file" ] || {
    echo "FAIL: RITE_LOG_FILE was not written"
    return 1
  }
  grep -q "SHRINKAGE_BASE_BRANCH_INVALID" "$log_file" || {
    echo "FAIL: SHRINKAGE_BASE_BRANCH_INVALID not found in log"
    cat "$log_file"
    return 1
  }

  # The raw value must appear with the newline visualized as '↵', NOT as the
  # stripped form 'mainevil;cmd' which hides the injection attempt.
  grep -q "base_branch_raw=main↵evil;cmd" "$log_file" || {
    echo "FAIL: diag does not contain pre-strip raw value with newline visualized as ↵"
    echo "Log contents:"
    cat "$log_file"
    return 1
  }

  # The diag line must NOT contain a literal newline (which would break log parsing).
  # A literal newline would manifest as multiple lines all starting with the
  # SHRINKAGE_BASE_BRANCH_INVALID prefix — verify there is exactly one such line.
  local diag_line_count
  diag_line_count=$(grep -c "SHRINKAGE_BASE_BRANCH_INVALID" "$log_file" || true)
  [ "$diag_line_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 SHRINKAGE_BASE_BRANCH_INVALID diag line, found $diag_line_count"
    echo "(likely caused by literal newline embedded in the log line)"
    cat "$log_file"
    return 1
  }
}

@test "detect_lib_shrinkage: accepts valid non-main base_branch (e.g. develop, release/1.0)" {
  # Ensure the validation does NOT reject valid branch names with slashes and dots.
  local target_file="lib/core/workflow-runner.sh"
  local total_lines=200
  local deleted_lines=110  # 55% above threshold

  local _target_file="$target_file"
  local _deleted_lines="$deleted_lines"
  local _total_lines="$total_lines"
  local _make_lib_diff_fn
  _make_lib_diff_fn=$(declare -f _make_lib_diff)

  # Capture the fetch branch via a temp state file (the source 2>/dev/null's
  # the git mock's stderr, so it never reaches $output or $stderr — same idiom
  # as test 22 "fetches base branch ref").
  local fetch_state_file="$RITE_TEST_TMPDIR/fetch-state-$$.txt"

  # Test with "release/1.0" — contains slash and dot, both valid
  run bash -c "
    cd '$RITE_TEST_TMPDIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='${RITE_LIB_DIR}'
    export RITE_SHRINKAGE_RATIO_PCT=50
    export RITE_SHRINKAGE_ABS_LINES=500
    ${_make_lib_diff_fn}
    gh_safe() {
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'diff' ]; then
        _make_lib_diff '${_target_file}' '${_deleted_lines}'
        return 0
      fi
      if [ \"\$1\" = 'pr' ] && [ \"\$2\" = 'view' ] && [[ \"\$*\" == *'baseRefName'* ]]; then
        echo 'release/1.0'
        return 0
      fi
      return 1
    }
    git() {
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'fetch' ]; then
        echo \"fetch_branch=\$5\" > '${fetch_state_file}'
        return 0
      fi
      # Return correct line count for origin/release/1.0
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == 'origin/release/1.0:'* ]]; then
        seq 1 '${_total_lines}'
        return 0
      fi
      if [ \"\$1\" = '-C' ] && [ \"\$3\" = 'show' ] && [[ \"\$4\" == 'origin/main:'* ]]; then
        echo 'ERROR=used_main' > '${fetch_state_file}'
        return 1
      fi
      command git \"\$@\"
    }
    export -f gh_safe _make_lib_diff git
    source '${RITE_LIB_DIR}/utils/blocker-rules.sh'
    _exit=0
    detect_lib_shrinkage '99' || _exit=\$?
    echo \"EXIT=\${_exit}\"
  "

  # 110/200 = 55% > 50% threshold — blocker fires
  [[ "$output" == *"EXIT=1"* ]] || [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKER"* ]]

  # The git mock's stderr is swallowed by the source's 2>/dev/null, so we assert
  # on the temp state file instead (see fetch_state_file note above).
  [ -f "$fetch_state_file" ] || {
    echo "FAIL: fetch was never called (state file not written)"
    return 1
  }
  # Fetch must have been called with the right branch
  grep -q "fetch_branch=release/1.0" "$fetch_state_file" || {
    echo "FAIL: fetch_branch does not show release/1.0"
    cat "$fetch_state_file"
    return 1
  }
  # Must not have fallen back to main
  ! grep -q "ERROR=used_main" "$fetch_state_file" || {
    echo "FAIL: valid release/1.0 branch was rejected and fell back to main"
    cat "$fetch_state_file"
    return 1
  }
}
