#!/bin/bash
# lib/utils/post-merge-verify.sh
# Post-merge/rebase semantic verification.
# Catches silent semantic conflicts: merges that succeed at the git level
# but break the codebase (e.g., main renames an export, feature branch adds
# a new caller of the old name — clean merge, broken code).
#
# Called after merge/rebase succeeds but BEFORE push.
# If verification fails, the caller should abort (revert the merge, don't push).

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f verify_post_merge >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

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

  # Optimize pytest: parallelize if xdist available, suppress noise
  if echo "$test_cmd" | grep -q "pytest"; then
    local _py_bin
    _py_bin=$(echo "$test_cmd" | sed 's/ -m pytest.*//')
    # Parallel execution
    if ! echo "$test_cmd" | grep -qE "\-n " && $_py_bin -c "import xdist" 2>/dev/null; then
      test_cmd="$test_cmd -n auto"
    fi
    # Short tracebacks, suppress deprecation warnings, quiet output
    test_cmd="$test_cmd --tb=short -W ignore::DeprecationWarning -q"
  fi

  # Reinstall dependencies if the merge changed dependency manifests.
  # Without this, worktree venvs become stale after merging main — new
  # dependencies from main aren't installed, causing ModuleNotFoundError
  # in tests even though the package is in requirements.txt.
  local _deps_changed=false
  if git -C "$worktree_path" diff HEAD~1 --name-only 2>/dev/null | \
     grep -qE '^(requirements\.txt|pyproject\.toml|package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|go\.mod|go\.sum)$'; then
    _deps_changed=true
  fi

  if [ "$_deps_changed" = true ]; then
    echo "Dependency files changed in merge — reinstalling before tests..." >&2
    (
      cd "$worktree_path"
      # Python: pip install into existing venv
      if [ -f "requirements.txt" ]; then
        _pip=""
        if [ -f ".venv/bin/pip" ]; then _pip=".venv/bin/pip"
        elif [ -f "venv/bin/pip" ]; then _pip="venv/bin/pip"
        elif [ -f "env/bin/pip" ]; then _pip="env/bin/pip"
        elif [ -n "${RITE_PROJECT_ROOT:-}" ] && [ -f "$RITE_PROJECT_ROOT/.venv/bin/pip" ]; then
          _pip="$RITE_PROJECT_ROOT/.venv/bin/pip"
        fi
        if [ -n "$_pip" ]; then
          $_pip install -q -r requirements.txt 2>&1 | tail -3 | sed 's/^/  /' >&2 || true
        fi
      fi
      # Node: npm ci or npm install
      if [ -f "package-lock.json" ] || [ -f "package.json" ]; then
        if [ -f "package-lock.json" ]; then
          npm ci --silent 2>&1 | tail -3 | sed 's/^/  /' >&2 || true
        else
          npm install --silent 2>&1 | tail -3 | sed 's/^/  /' >&2 || true
        fi
      fi
    ) || echo "Warning: dependency reinstall had errors (continuing with tests)" >&2
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
  # With pipefail, $? captures the test command's exit, not sed's (which is always 0).
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
    # Before blaming the merge, check if main itself is broken.
    # A broken main (e.g., missing dependency merged without tests catching it)
    # will poison every feature branch that merges it. Distinguish the two cases
    # so callers can report actionable errors instead of blocking on a phantom
    # "semantic conflict."
    echo "⚠️  Post-merge tests failed (exit $test_exit) — checking if main is the cause..." >&2

    local _main_broken=false
    local _main_test_dir
    _main_test_dir=$(mktemp -d)

    if git -C "$worktree_path" worktree add --quiet "$_main_test_dir" origin/main 2>/dev/null; then
      local _main_exit=0
      local _main_env=""
      [ -f "$_main_test_dir/.env.test" ] && _main_env="$_main_test_dir/.env.test"
      [ -z "$_main_env" ] && [ -f "$_main_test_dir/.env" ] && _main_env="$_main_test_dir/.env"
      (
        cd "$_main_test_dir"
        if [ -n "$_main_env" ]; then
          set -a; source "$_main_env" 2>/dev/null || true; set +a
        fi
        if [ -n "$timeout_cmd" ]; then
          $timeout_cmd sh -c "$test_cmd"
        else
          eval "$test_cmd"
        fi
      ) >/dev/null 2>&1 || _main_exit=$?

      git -C "$worktree_path" worktree remove --force "$_main_test_dir" 2>/dev/null || rm -rf "$_main_test_dir"

      if [ "$_main_exit" -ne 0 ] && [ "$_main_exit" -ne 124 ]; then
        _main_broken=true
      fi
    else
      # Can't create worktree (maybe origin/main not fetched) — skip the check
      rm -rf "$_main_test_dir"
    fi

    if [ "$_main_broken" = true ]; then
      echo "🔴 Tests fail on main too — main branch is broken (not a merge conflict)" >&2
      echo "Fix main first, then retry. Allowing workflow to proceed." >&2
      # Return success: the failure isn't from this branch's merge.
      # Callers would otherwise revert the merge and block the workflow,
      # but the feature branch isn't at fault.
      return 0
    fi

    echo "⚠️  Post-merge verification FAILED (exit $test_exit)" >&2
    echo "The merge/rebase succeeded at the git level but tests now fail." >&2
    echo "This likely indicates a silent semantic conflict." >&2
    return 1
  fi

  echo "Post-merge verification passed" >&2
  return 0
}
