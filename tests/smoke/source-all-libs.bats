#!/usr/bin/env bats
# sharkrite-test-covers: lib/**
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

    # Skip lib/core orchestrators that have top-level executable program bodies
    # (arg parsing, GitHub API calls, interactive flows) and do NOT implement the
    # RITE_SOURCE_FUNCTIONS_ONLY=1 guard. Plain-sourcing these runs their bodies
    # (Usage exit 1, unbound $1, live PR work, hangs) — they are executables, not
    # pure function libraries, so they are out of scope for this smoke test.
    # The 3 guard-supporting executables (claude-workflow.sh, assess-and-resolve.sh,
    # local-review.sh) stay in coverage and source cleanly under the guard below.
    case "$(basename "$lib_file")" in
      workflow-runner.sh|assess-documentation.sh|bootstrap-docs.sh|batch-process-issues.sh|undo-workflow.sh|assess-review-issues.sh|merge-pr.sh|create-pr.sh) continue ;;
    esac

    # Try to source in a subshell (isolate side effects)
    if ! (
      # setup_test_tmpdir cd's into a throwaway tmp dir that is NOT a git repo.
      # Several pure libs (config.sh and its transitive dependents) intentionally
      # bail with "Not inside a git repository" when sourced outside a project —
      # that guard is real product behavior, not a sourcing bug. Source from the
      # repo root so those libs find a real repo, matching how `rite` runs.
      cd "${RITE_REPO_ROOT}"
      # Set minimal required env vars to prevent unbound variable errors
      export RITE_REPO_ROOT="${RITE_REPO_ROOT}"
      export RITE_ISSUE_NUMBER="${RITE_ISSUE_NUMBER:-999}"
      export RITE_WORKTREE_PATH="${RITE_WORKTREE_PATH:-/tmp/test-worktree}"
      export RITE_LOG_FILE="${RITE_LOG_FILE:-/tmp/test.log}"
      export RITE_LOCK_DIR="${RITE_LOCK_DIR:-/tmp/locks}"
      # Function-library sourcing: guard-supporting executables stop at their
      # function defs and skip running their program body.
      export RITE_SOURCE_FUNCTIONS_ONLY=1

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
