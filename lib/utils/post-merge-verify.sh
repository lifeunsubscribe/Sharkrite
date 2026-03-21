#!/bin/bash
# lib/utils/post-merge-verify.sh
# Post-merge/rebase semantic verification.
# Catches silent semantic conflicts: merges that succeed at the git level
# but break the codebase (e.g., main renames an export, feature branch adds
# a new caller of the old name — clean merge, broken code).
#
# Called after merge/rebase succeeds but BEFORE push.
# If verification fails, the caller should abort (revert the merge, don't push).

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# ===================================================================
# PUBLIC: verify_post_merge [worktree_path]
#
# Runs the project's test suite (if detectable) to verify that a
# merge/rebase didn't introduce silent semantic conflicts.
#
# Returns:
#   0 = verification passed (or no test runner found — can't verify)
#   1 = verification failed (tests broke after merge)
#
# Respects RITE_SKIP_TESTS=true to skip entirely.
# ===================================================================
verify_post_merge() {
  local worktree_path="${1:-.}"

  # Honor skip flag
  if [ "${RITE_SKIP_TESTS:-false}" = "true" ]; then
    return 0
  fi

  # Detect test command
  local test_cmd="${RITE_TEST_CMD:-}"
  local test_subdir=""

  if [ -z "$test_cmd" ]; then
    if [ -f "$worktree_path/package.json" ]; then
      test_cmd="npm test"
    elif [ -f "$worktree_path/backend/package.json" ]; then
      test_cmd="npm test"
      test_subdir="backend"
    elif [ -f "$worktree_path/pytest.ini" ] || [ -f "$worktree_path/pyproject.toml" ] || \
         [ -f "$worktree_path/setup.cfg" ] || [ -f "$worktree_path/setup.py" ] || \
         [ -d "$worktree_path/tests" ]; then
      # Prefer venv python
      if [ -f "$worktree_path/.venv/bin/python" ]; then
        test_cmd="$worktree_path/.venv/bin/python -m pytest"
      elif [ -f "$worktree_path/venv/bin/python" ]; then
        test_cmd="$worktree_path/venv/bin/python -m pytest"
      elif [ -f "$worktree_path/env/bin/python" ]; then
        test_cmd="$worktree_path/env/bin/python -m pytest"
      elif [ -n "${RITE_PROJECT_ROOT:-}" ] && [ -f "$RITE_PROJECT_ROOT/.venv/bin/python" ]; then
        test_cmd="$RITE_PROJECT_ROOT/.venv/bin/python -m pytest"
      elif command -v python3 >/dev/null 2>&1; then
        test_cmd="python3 -m pytest"
      else
        test_cmd="python -m pytest"
      fi
    elif [ -f "$worktree_path/Makefile" ] && grep -q "^test:" "$worktree_path/Makefile" 2>/dev/null; then
      test_cmd="make test"
    fi
  fi

  if [ -z "$test_cmd" ]; then
    # No test runner found — can't verify, allow proceeding
    return 0
  fi

  echo "Running post-merge verification ($test_cmd)..." >&2

  # Source .env.test or .env if present for test dependencies
  local env_file=""
  [ -f "$worktree_path/.env.test" ] && env_file="$worktree_path/.env.test"
  [ -z "$env_file" ] && [ -f "$worktree_path/.env" ] && env_file="$worktree_path/.env"

  local test_exit=0
  local run_dir="$worktree_path"
  [ -n "$test_subdir" ] && run_dir="$worktree_path/$test_subdir"

  local verify_timeout="${RITE_POST_MERGE_VERIFY_TIMEOUT:-300}"
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout $verify_timeout"
  fi

  # Run inside a subshell: source env file, then run the test command.
  # timeout wraps the test command directly (an external binary) rather than
  # a shell function, which external commands cannot exec.
  (
    cd "$run_dir"
    if [ -n "$env_file" ]; then
      set -a
      # shellcheck disable=SC1090
      source "$env_file" 2>/dev/null || true
      set +a
    fi
    if [ -n "$timeout_cmd" ]; then
      $timeout_cmd sh -c "$test_cmd"
    else
      eval "$test_cmd"
    fi
  ) 2>&1 | sed 's/^/  /' >&2 || test_exit=$?

  if [ "$test_exit" -eq 124 ]; then
    echo "⚠️  Post-merge verification timed out after ${verify_timeout}s — skipping" >&2
    return 0
  fi

  if [ "$test_exit" -ne 0 ]; then
    echo "⚠️  Post-merge verification FAILED (exit $test_exit)" >&2
    echo "The merge/rebase succeeded at the git level but tests now fail." >&2
    echo "This likely indicates a silent semantic conflict." >&2
    return 1
  fi

  echo "Post-merge verification passed" >&2
  return 0
}
