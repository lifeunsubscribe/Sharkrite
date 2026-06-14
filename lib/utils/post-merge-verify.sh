#!/bin/bash
# lib/utils/post-merge-verify.sh
# Post-merge/rebase semantic verification.
# Catches silent semantic conflicts: merges that succeed at the git level
# but break the codebase (e.g., main renames an export, feature branch adds
# a new caller of the old name — clean merge, broken code).
#
# Called after merge/rebase succeeds but BEFORE push.
# If verification fails, the caller should abort (revert the merge, don't push).
#
# For Sharkrite repos, delegates to run_test_gate (lib/utils/test-gate.sh) so
# the same targeted-selection logic used by the pre-merge gate applies here too.
# This avoids running the full 1400+ test suite after every merge when only a
# handful of bats files actually cover the changed paths.

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

# Source logging for _diag (needed by run_test_gate)
if ! declare -f _diag >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/logging.sh"
fi

# Source marker constants (needed by run_test_gate for RITE_MARKER_TEST_COVERS)
if ! declare -f rite_markers_loaded >/dev/null 2>&1; then
  _pmv_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_pmv_self_dir/markers.sh"
fi

# Source test gate for run_test_gate (targeted selection + structured findings).
# Guard matches the pattern used for _diag and rite_markers_loaded above: only
# source if run_test_gate is not already defined. This keeps the file safe to
# use inside sandboxed tests that stub run_test_gate directly (tests 1-4 in
# post-merge-test-exit-propagation.bats) and prevents a "No such file or
# directory" crash when test-gate.sh is absent from a minimal test sandbox.
# The intermittent multi-file batched-run pass was caused by an earlier bats
# file sourcing test-gate.sh and leaving run_test_gate defined in the shared
# runner process — the unconditional source succeeded via the re-source guard
# in test-gate.sh:28 without needing the file on disk, masking the solo failure.
if ! declare -f run_test_gate >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/test-gate.sh"
fi

# ===================================================================
# PUBLIC: verify_post_merge [worktree_path] [pre_merge_ref]
#
# Runs the project's test suite (if detectable) to verify that a
# merge/rebase didn't introduce silent semantic conflicts.
#
# For Sharkrite repos, delegates to run_test_gate so targeted selection
# applies: only bats files covering changed paths run (not the full 1400+
# test suite). Bats selection is always targeted (the path-based full-suite
# trigger list was removed 2026-06-12); only the no-diff fallback runs the
# full suite, which the main-broken check below exploits deliberately.
#
# pre_merge_ref (optional, default: HEAD~1):
#   The commit SHA or ref representing the state BEFORE the merge/rebase.
#   Used as RITE_TEST_GATE_DIFF_BASE so targeted selection covers the files
#   that actually changed due to the merge — including main-originated files
#   that origin/main...HEAD (three-dot merge-base) would exclude.
#   For merge commits: HEAD~1 is the pre-merge feature branch tip.
#   For rebases: pass the pre-rebase HEAD saved before 'git rebase'.
#
# For non-Sharkrite repos (npm/pytest/make test), the original test
# command construction and execution path is preserved unchanged.
#
# Returns:
#   0 = verification passed (or no test runner found — can't verify)
#   1 = verification failed (tests broke after merge)
#
# Respects RITE_SKIP_TESTS=true to skip entirely.
# ===================================================================
verify_post_merge() {
  local worktree_path="${1:-.}"
  # pre_merge_ref: the commit that was HEAD before the merge/rebase.
  # Defaults to HEAD~1 (parent of current HEAD, i.e. the pre-merge commit).
  # Callers that saved the pre-rebase HEAD should pass it explicitly.
  local pre_merge_ref="${2:-HEAD~1}"

  # Honor skip flag
  if [ "${RITE_SKIP_TESTS:-false}" = "true" ]; then
    return 0
  fi

  # Detect whether this is a Sharkrite repo.
  # Detection: Makefile with both shellcheck: and lint: targets — same
  # check used by run_test_gate so the paths stay in sync.
  local _is_sharkrite=false
  if [ -f "$worktree_path/Makefile" ] \
     && grep -q "^shellcheck:" "$worktree_path/Makefile" 2>/dev/null \
     && grep -q "^lint:" "$worktree_path/Makefile" 2>/dev/null; then
    _is_sharkrite=true
  fi

  if [ "$_is_sharkrite" = "true" ]; then
    # ---------------------------------------------------------------
    # Sharkrite path: delegate to run_test_gate for targeted selection.
    # run_test_gate internally: computes changed paths against the diff
    # base (RITE_TEST_GATE_DIFF_BASE), selects covering bats files, runs
    # make shellcheck + make lint + bats on the subset, emits
    # [diag] TEST_GATE_SELECTION mode=... for health-report aggregation.
    #
    # Diff base for feature-branch run: pre_merge_ref (the commit that was
    # HEAD before the merge/rebase). Using three-dot origin/main...HEAD here
    # would exclude main-originated files via the merge-base shortcut —
    # exactly the files that could cause silent semantic conflicts.
    # pre_merge_ref → HEAD~1 by default → git diff HEAD~1...HEAD shows
    # only what the merge commit itself introduced.
    # ---------------------------------------------------------------
    echo "Running post-merge verification (targeted gate)..." >&2

    local _pmv_gate_file
    _pmv_gate_file=$(mktemp "/tmp/rite_pmv_gate_$$.json")
    local _pmv_gate_exit=0
    # RITE_TEST_GATE_SKIP_TRIGGERS=true — disable the LINT full-scan trigger
    # list for this call (bats triggers no longer exist; since 2026-06-12 the
    # var affects lint selection only). The diff includes main commits the
    # rebase pulled in (the whole point of using pre_merge_ref) — and those
    # main commits routinely touch lint rules or the Makefile. Main already
    # validated them via its own CI; we only need to verify the feature
    # branch's own logic against the post-rebase state.
    RITE_TEST_GATE_DIFF_BASE="$pre_merge_ref" \
    RITE_TEST_GATE_SKIP_TRIGGERS=true \
      run_test_gate "$_pmv_gate_file" "$worktree_path" || _pmv_gate_exit=$?
    rm -f "${_pmv_gate_file:-}"

    if [ "$_pmv_gate_exit" -ne 0 ]; then
      # Before blaming the merge, check if main itself is broken.
      # A broken main will poison every feature branch that merges it.
      # Distinguish so callers block on real semantic conflicts, not
      # pre-existing failures in main.
      #
      # Main-broken check: run the full bats suite on origin/main (no targeted
      # selection — main has no merge commit, so a diff-base would select a
      # different subset than the feature-branch run). Full suite ensures both
      # runs are comparable: if main passes full but feature fails targeted,
      # the merge is the cause; if main fails full, main itself is broken.
      echo "⚠️  Post-merge tests failed — checking if main is the cause..." >&2

      local _main_broken=false
      local _main_test_dir
      _main_test_dir=$(mktemp -d)

      if git -C "$worktree_path" worktree add --quiet "$_main_test_dir" origin/main 2>/dev/null; then
        local _main_gate_file _main_gate_exit
        _main_gate_file=$(mktemp "/tmp/rite_pmv_main_gate_$$.json")
        _main_gate_exit=0
        # Force full suite for the main-broken check: set diff base to HEAD so
        # git diff HEAD...HEAD returns an empty changed-file list, which hits
        # the no-diff FORCE_FULL fallback in _select_tests_by_changed_paths —
        # deliberately the ONE remaining full-suite path after the 2026-06-12
        # trigger removal. This ensures the main run is not scoped to a narrow
        # subset that might produce a false "main passes" when main is broken.
        RITE_TEST_GATE_DIFF_BASE="HEAD" run_test_gate "$_main_gate_file" "$_main_test_dir" >/dev/null 2>&1 || _main_gate_exit=$?
        rm -f "${_main_gate_file:-}"
        git -C "$worktree_path" worktree remove --force "$_main_test_dir" 2>/dev/null \
          || rm -rf "$_main_test_dir"

        if [ "$_main_gate_exit" -ne 0 ]; then
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

      echo "⚠️  Post-merge verification FAILED (exit $_pmv_gate_exit)" >&2
      echo "The merge/rebase succeeded at the git level but tests now fail." >&2
      echo "This likely indicates a silent semantic conflict." >&2
      return 1
    fi

    echo "Post-merge verification passed" >&2
    return 0
  fi

  # ---------------------------------------------------------------
  # Non-Sharkrite path: original test-command detection and execution.
  # Handles npm/pytest/make test for non-Sharkrite projects.
  # ---------------------------------------------------------------

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
    _py_bin=$(echo "$test_cmd" | sed 's/ -m pytest.*//' || true)
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
