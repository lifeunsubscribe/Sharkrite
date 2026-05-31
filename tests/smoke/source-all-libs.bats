#!/usr/bin/env bats
# Smoke test: ensure all library files can be sourced without errors
#
# This is a pure helper test pattern - no external dependencies, just syntax validation

load '../helpers/setup'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# Test that every .sh file in lib/ can be sourced without error
@test "all lib files source without errors" {
  local lib_dir="${RITE_REPO_ROOT}/lib"
  local failed_files=()

  # Find all .sh files in lib/
  while IFS= read -r lib_file; do
    # Skip if file doesn't exist (shouldn't happen, but be safe)
    [ -f "$lib_file" ] || continue

    # Try to source in a subshell (isolate side effects)
    if ! (
      # Set minimal required env vars to prevent unbound variable errors
      export RITE_REPO_ROOT="${RITE_REPO_ROOT}"
      export RITE_ISSUE_NUMBER="${RITE_ISSUE_NUMBER:-999}"
      export RITE_WORKTREE_PATH="${RITE_WORKTREE_PATH:-/tmp/test-worktree}"
      export RITE_LOG_FILE="${RITE_LOG_FILE:-/tmp/test.log}"
      export RITE_LOCK_DIR="${RITE_LOCK_DIR:-/tmp/locks}"

      # Disable set -u temporarily to allow sourcing files that may reference
      # unset vars in their global scope
      set +u
      # shellcheck disable=SC1090
      source "$lib_file"
    ) 2>/dev/null; then
      failed_files+=("$lib_file")
    fi
  done < <(find "$lib_dir" -type f -name "*.sh")

  # Report failures
  if [ ${#failed_files[@]} -gt 0 ]; then
    echo "Failed to source the following files:" >&2
    printf '  %s\n' "${failed_files[@]}" >&2
    return 1
  fi
}

# Test that bin/rite is executable and has valid shebang
@test "bin/rite is executable with valid shebang" {
  local rite_bin="${RITE_REPO_ROOT}/bin/rite"

  [ -f "$rite_bin" ]
  [ -x "$rite_bin" ]

  # Check shebang
  local shebang
  shebang=$(head -1 "$rite_bin")
  [[ "$shebang" =~ ^#!/ ]]
}

# Test that all helper files can be sourced
@test "all helper files source without errors" {
  local helpers_dir="${RITE_REPO_ROOT}/tests/helpers"

  while IFS= read -r helper_file; do
    # Skip setup.bash (it's loaded via 'load' directive above)
    [[ "$helper_file" == *"/setup.bash" ]] && continue

    # Source the helper
    # shellcheck disable=SC1090
    run source "$helper_file"
    [ "$status" -eq 0 ]
  done < <(find "$helpers_dir" -type f -name "*.bash")
}
