#!/bin/bash
# lib/utils/post-merge-verify.sh
# Post-merge/rebase semantic verification.
# Catches silent semantic conflicts: merges that succeed at the git level
# but break the codebase (e.g., main renames an export, feature branch adds
# a new caller of the old name — clean merge, broken code).
#
# Called after merge/rebase succeeds but BEFORE push.
# If verification fails, the caller should act based on the exit code.

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# ===================================================================
# INTERNAL: Main health cache
#
# Caches test results for origin/main by SHA. Avoids redundant testing
# when multiple issues merge main in the same batch. Cache file lives
# in the project's .rite dir so it's per-repo.
#
# Format:
#   SHA=<commit hash>
#   RESULT=pass|fail
#   TIMESTAMP=<ISO 8601>
#   ISSUE=<number>       (only when RESULT=fail)
# ===================================================================

_main_health_file() {
  echo "${RITE_PROJECT_ROOT:-.}/${RITE_DATA_DIR:-.rite}/main-health"
}

# Sets _CACHED_RESULT (pass|fail|"") and _CACHED_ISSUE
_read_main_health() {
  local sha="$1"
  local cache_file
  cache_file=$(_main_health_file)
  _CACHED_RESULT=""
  _CACHED_ISSUE=""
  if [ -f "$cache_file" ]; then
    local cached_sha
    cached_sha=$(awk -F= '/^SHA=/{print $2}' "$cache_file" 2>/dev/null || true)
    if [ "$cached_sha" = "$sha" ]; then
      _CACHED_RESULT=$(awk -F= '/^RESULT=/{print $2}' "$cache_file" 2>/dev/null || true)
      _CACHED_ISSUE=$(awk -F= '/^ISSUE=/{print $2}' "$cache_file" 2>/dev/null || true)
    fi
  fi
}

_write_main_health() {
  local sha="$1" result="$2" issue="${3:-}"
  local cache_file
  cache_file=$(_main_health_file)
  mkdir -p "$(dirname "$cache_file")"
  {
    echo "SHA=$sha"
    echo "RESULT=$result"
    echo "TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    [ -n "$issue" ] && echo "ISSUE=$issue"
  } > "$cache_file"
}

# ===================================================================
# INTERNAL: Parse failing test file paths from test output
#
# Extracts unique file paths from common test runner output formats.
# Returns one path per line on stdout.
# ===================================================================
_parse_failing_test_files() {
  local output_file="$1"

  {
    # pytest: "FAILED tests/foo/test_bar.py::test_name - ..."
    grep -oE 'FAILED [^ :]+' "$output_file" 2>/dev/null | sed 's/FAILED //' | sed 's/::.*//'

    # pytest short summary: "tests/foo/test_bar.py::test_name"
    # Also handles collection errors: "ERROR tests/foo/test_bar.py" (no :: suffix)
    grep -E '^\s*(FAILED|ERROR)\s' "$output_file" 2>/dev/null | grep -oE '\S+\.py(::|\s|$)' | sed 's/[:[:space:]]*$//'

    # npm/jest: "FAIL src/foo.test.js"
    grep -oE '^\s*FAIL\s+\S+' "$output_file" 2>/dev/null | awk '{print $2}'
  } | sort -u
}

# ===================================================================
# INTERNAL: Create or find a fix-main GitHub issue
#
# Checks for an existing open fix-main issue first (avoids duplicates).
# Returns the issue number on stdout.
# ===================================================================
_create_fix_main_issue() {
  local test_output_file="$1"
  local worktree_path="${2:-.}"

  # Check for existing open fix-main issue
  local existing_issue
  existing_issue=$(gh issue list --label "fix-main" --state open --json number --jq '.[0].number' 2>/dev/null || true)
  if [ -n "$existing_issue" ] && [ "$existing_issue" != "null" ]; then
    echo "$existing_issue"
    return 0
  fi

  # Ensure label exists
  gh label create "fix-main" --color "B60205" --description "Test suite failures on main branch" 2>/dev/null || true

  local main_sha
  main_sha=$(git -C "$worktree_path" rev-parse origin/main 2>/dev/null | head -c 10)

  # Truncate output for GitHub body limits
  local truncated_output
  truncated_output=$(tail -60 "$test_output_file")

  local issue_body
  issue_body=$(cat <<EOF
## Problem

Tests are failing on the \`main\` branch at commit \`$main_sha\`. This blocks all feature branches from merging \`main\` for post-merge verification.

Auto-detected by sharkrite post-merge verification.

## Test Output

\`\`\`
$truncated_output
\`\`\`

## Claude Context

- Run the test suite on \`main\` to reproduce
- Fix the failing tests or the code they test
- Once tests pass on \`main\`, feature branches can resume merging

## Acceptance Criteria

- [ ] All tests pass on \`main\`

## Done Definition

Test suite passes. No workarounds or skipped tests.

## Scope Boundary

- **DO:** Fix the failing tests or the source code causing failures
- **DO NOT:** Add new features or refactor unrelated code
EOF
)

  local issue_num
  issue_num=$(gh issue create \
    --title "[fix-main] Test suite failures on main ($main_sha)" \
    --label "fix-main" \
    --body "$issue_body" \
    --json number --jq '.number' 2>/dev/null || true)

  echo "${issue_num:-}"
}

# ===================================================================
# PUBLIC: verify_post_merge [worktree_path]
#
# Runs the project's test suite (if detectable) to verify that a
# merge/rebase didn't introduce silent semantic conflicts.
#
# Returns:
#   0 = safe to proceed. Covers:
#       - tests pass
#       - dev-session bugs (failures in files the merge didn't touch;
#         test gate will catch them)
#       - main is broken (fix-main issue created; merge left intact,
#         test gate will catch main's failures)
#   1 = semantic conflict (tests fail in files the merge changed;
#       main is healthy — genuine merge-caused breakage)
#
# Callers can safely use `if ! verify_post_merge`. Non-failure cases
# (dev bugs, main broken) return 0 so callers never reset HEAD for them.
#
# Respects RITE_SKIP_TESTS=true to skip entirely.
# ===================================================================
verify_post_merge() {
  local worktree_path="${1:-.}"

  # Honor skip flag
  if [ "${RITE_SKIP_TESTS:-false}" = "true" ]; then
    return 0
  fi

  # Batch fast-test mode: the end-of-batch verification phase in
  # batch-process-issues.sh runs the full suite once after all issues finish
  # and launches a fix loop if it fails. Per-issue post-merge verification
  # becomes redundant — skip it to avoid running the full suite N times.
  if [ "${BATCH_MODE:-false}" = "true" ] \
     && [ "${RITE_BATCH_FAST_TESTS:-true}" != "false" ]; then
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
      # Find a venv with pytest. Check worktree, project root, and main worktree.
      # NEVER fall back to system python — it almost certainly lacks pytest,
      # and "No module named pytest" gets misread as a test failure, triggering
      # a false "semantic conflict" that reverts the merge.
      local _py_found=""
      for _venv_base in \
        "$worktree_path/.venv" \
        "$worktree_path/venv" \
        "$worktree_path/env" \
        "${RITE_PROJECT_ROOT:+$RITE_PROJECT_ROOT/.venv}" \
        "${RITE_PROJECT_ROOT:+$RITE_PROJECT_ROOT/venv}" \
        "$(git -C "$worktree_path" worktree list 2>/dev/null | head -1 | awk '{print $1}')/.venv"; do
        if [ -n "$_venv_base" ] && [ -f "$_venv_base/bin/python" ]; then
          # Verify this python actually has pytest before committing
          if "$_venv_base/bin/python" -c "import pytest" 2>/dev/null; then
            _py_found="$_venv_base/bin/python"
            break
          fi
        fi
      done
      if [ -n "$_py_found" ]; then
        test_cmd="$_py_found -m pytest"
      else
        # No venv with pytest found — can't verify, allow proceeding
        echo "No Python venv with pytest found — skipping post-merge verification" >&2
        return 0
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
    # Parallel execution via xdist (auto-install if missing)
    if ! echo "$test_cmd" | grep -qE "\-n "; then
      if ! $_py_bin -c "import xdist" 2>/dev/null; then
        local _pip_bin
        _pip_bin="$(dirname "$_py_bin")/pip"
        if [ -f "$_pip_bin" ]; then
          echo "Installing pytest-xdist for parallel test execution..." >&2
          "$_pip_bin" install -q pytest-xdist 2>/dev/null || true
        fi
      fi
      if $_py_bin -c "import xdist" 2>/dev/null; then
        test_cmd="$test_cmd -n auto"
      fi
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
      # Python: pip install into existing venv (derive pip from the python we found)
      if [ -f "requirements.txt" ] && [ -n "${_py_found:-}" ]; then
        _pip="$(dirname "$_py_found")/pip"
        if [ -f "$_pip" ]; then
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

  # Capture test output for failure attribution
  local _test_output_file
  _test_output_file=$(mktemp)

  # Run inside a subshell: source env file, then run the test command.
  # tee captures output for later analysis while still displaying to stderr.
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
  ) 2>&1 | tee "$_test_output_file" | sed 's/^/  /' >&2 || test_exit=$?

  if [ "$test_exit" -eq 124 ]; then
    echo "⚠️  Post-merge verification timed out after ${verify_timeout}s — skipping" >&2
    rm -f "$_test_output_file"
    return 0
  fi

  # xdist fallback: INTERNALERROR (exit 3) with -n auto → retry serial
  if [ "$test_exit" -eq 3 ] && echo "$test_cmd" | grep -q "\-n auto"; then
    echo "⚠️  pytest-xdist crashed — retrying without parallelization" >&2
    test_cmd=$(echo "$test_cmd" | sed 's/ -n auto//')
    test_exit=0
    : > "$_test_output_file"
    (
      cd "$run_dir"
      if [ -n "$env_file" ]; then
        set -a; source "$env_file" 2>/dev/null || true; set +a
      fi
      if [ -n "$timeout_cmd" ]; then
        $timeout_cmd sh -c "$test_cmd"
      else
        eval "$test_cmd"
      fi
    ) 2>&1 | tee "$_test_output_file" | sed 's/^/  /' >&2 || test_exit=$?
  fi

  if [ "$test_exit" -eq 0 ]; then
    echo "Post-merge verification passed" >&2
    # Update main health cache — main is healthy (we just merged it successfully)
    local _main_sha
    _main_sha=$(git -C "$worktree_path" rev-parse origin/main 2>/dev/null || true)
    if [ -n "$_main_sha" ]; then
      _write_main_health "$_main_sha" "pass"
    fi
    rm -f "$_test_output_file"
    return 0
  fi

  # ===================================================================
  # Tests failed after merge. Determine the cause:
  #   1. Main itself is broken → return 0 (create fix-main issue, proceed)
  #   2. Dev-session bugs → return 0 (test gate will handle)
  #   3. Genuine semantic conflict → return 1 (caller should revert)
  #
  # Only return 1 for genuine semantic conflicts. Everything else
  # returns 0 so callers using `if ! verify_post_merge` don't
  # accidentally reset HEAD for non-merge failures.
  # ===================================================================

  echo "⚠️  Post-merge tests failed (exit $test_exit) — diagnosing cause..." >&2

  # --- Step 1: Check if main is broken (cached or live) ---

  local _main_sha
  _main_sha=$(git -C "$worktree_path" rev-parse origin/main 2>/dev/null || true)
  local _main_broken=false

  if [ -n "$_main_sha" ]; then
    _read_main_health "$_main_sha"

    if [ "$_CACHED_RESULT" = "pass" ]; then
      # Cache says main is healthy — skip the expensive worktree test
      :
    elif [ "$_CACHED_RESULT" = "fail" ]; then
      # Cache says main is broken — skip test, use cached result
      _main_broken=true
      echo "🔴 Main is known-broken (cached, fix-main issue #${_CACHED_ISSUE:-unknown})" >&2
    else
      # Cache miss — test main and update cache
      echo "Checking if main itself has test failures..." >&2
      local _main_test_dir
      _main_test_dir=$(mktemp -d)

      if git -C "$worktree_path" worktree add --quiet "$_main_test_dir" origin/main 2>/dev/null; then
        local _main_exit=0
        local _main_env=""
        [ -f "$_main_test_dir/.env.test" ] && _main_env="$_main_test_dir/.env.test"
        [ -z "$_main_env" ] && [ -f "$_main_test_dir/.env" ] && _main_env="$_main_test_dir/.env"

        # Reinstall deps in main worktree if needed
        if [ -n "${_py_found:-}" ] && [ -f "$_main_test_dir/requirements.txt" ]; then
          local _main_pip
          _main_pip="$(dirname "$_py_found")/pip"
          [ -f "$_main_pip" ] && "$_main_pip" install -q -r "$_main_test_dir/requirements.txt" 2>/dev/null || true
        fi

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
          _write_main_health "$_main_sha" "fail"
        else
          _write_main_health "$_main_sha" "pass"
        fi
      else
        # Can't create worktree — skip the check
        rm -rf "$_main_test_dir"
      fi
    fi
  fi

  if [ "$_main_broken" = true ]; then
    echo "🔴 Tests fail on main too — main branch is broken" >&2

    # Create or find fix-main issue
    local _fix_issue
    _fix_issue=$(_create_fix_main_issue "$_test_output_file" "$worktree_path")
    if [ -n "$_fix_issue" ]; then
      echo "📋 fix-main issue: #$_fix_issue (will be prioritized in batch mode)" >&2
      # Update cache with issue number
      _write_main_health "$_main_sha" "fail" "$_fix_issue"
    fi

    echo "Allowing workflow to proceed — test gate will catch remaining failures" >&2
    rm -f "$_test_output_file"
    return 0
  fi

  # --- Step 2: Main is healthy. Attribute failures. ---
  #
  # Compare failing test file paths against the merge diff.
  # If the merge didn't change any of the failing test files, the failures
  # were pre-existing (dev-session bugs). The test gate + auto-fix handles
  # those — no need to destroy work by resetting HEAD.
  #
  # If the merge DID change a failing test file, it's a genuine semantic
  # conflict that needs manual resolution.

  local _failing_tests
  _failing_tests=$(_parse_failing_test_files "$_test_output_file")

  if [ -z "$_failing_tests" ]; then
    # Can't parse which specific tests failed. Check if the failures are
    # import/collection errors (environment issues, not semantic conflicts).
    if grep -qiE 'ModuleNotFoundError|ImportError|No module named|CollectionError' "$_test_output_file" 2>/dev/null; then
      echo "Test failures appear to be import/collection errors (missing dependencies), not semantic conflicts" >&2
      echo "Continuing to test gate for auto-fix..." >&2
      rm -f "$_test_output_file"
      return 0
    fi
    # Genuinely can't determine what failed — fall back to semantic conflict
    echo "⚠️  Could not determine which tests failed — treating as semantic conflict" >&2
    rm -f "$_test_output_file"
    return 1
  fi

  # Get files the merge changed (diff between pre-merge branch tip and post-merge result).
  # For a merge commit: HEAD^1 is our branch, HEAD is the merge result.
  # If HEAD is not a merge commit (fast-forward), the merge didn't change anything
  # structurally, so all failures are dev bugs.
  local _merge_changed_files=""
  if git -C "$worktree_path" rev-parse HEAD^2 >/dev/null 2>&1; then
    _merge_changed_files=$(git -C "$worktree_path" diff --name-only HEAD^1 HEAD 2>/dev/null || true)
  fi

  if [ -z "$_merge_changed_files" ]; then
    # Merge brought in no file changes (or fast-forward) — failures are dev bugs
    echo "Merge brought no file changes — test failures are from dev session, not the merge" >&2
    echo "Continuing to test gate for auto-fix..." >&2
    rm -f "$_test_output_file"
    return 0
  fi

  # Check if any failing test files overlap with merge-changed files
  local _has_merge_overlap=false
  while IFS= read -r _fail_file; do
    [ -z "$_fail_file" ] && continue
    if echo "$_merge_changed_files" | grep -qF "$_fail_file"; then
      _has_merge_overlap=true
      echo "  Merge changed failing test: $_fail_file" >&2
    fi
  done <<< "$_failing_tests"

  rm -f "$_test_output_file"

  if [ "$_has_merge_overlap" = true ]; then
    echo "⚠️  Post-merge verification FAILED — merge changed files that are now failing" >&2
    echo "This likely indicates a silent semantic conflict." >&2
    return 1
  fi

  # All failing tests are in files the merge didn't touch — dev-session bugs.
  # Don't reset HEAD. The test gate will catch these and attempt auto-fix.
  echo "Test failures are in files not changed by the merge — dev-session bugs, not merge damage" >&2
  echo "Continuing to test gate for auto-fix..." >&2
  return 0
}
