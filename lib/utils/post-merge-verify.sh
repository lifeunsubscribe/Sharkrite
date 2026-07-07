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
#   Used as RITE_TEST_GATE_DIFF_BASE for targeted selection.
#   For merge commits: HEAD~1 is the pre-merge feature branch tip.
#   For rebases: pass "origin/main" (issue #854). Passing the pre-rebase HEAD
#   pulls every rebased-in main commit into the selection — after a heavy merge
#   day that is 180+ bats files per resumed branch, re-paid on every restart.
#   The main delta was already gated per-merge (green-main invariant, #707);
#   the rebase-conflict question is answered by the branch's own coverage
#   running against the post-rebase tree (origin/main...HEAD, three-dot).
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

  # No-overlap skip: post-merge verification exists to catch SEMANTIC conflicts
  # where main's rebased-in commits break the branch's work despite a clean
  # textual merge. That can only happen if main's new commits and the branch's
  # own changes touch the SAME files. When they don't overlap, verifying is pure
  # waste — and the wasted minutes let main advance further, so the branch ends
  # up behind again (the treadmill). Compute the overlap and skip when empty.
  #
  # Defensive: skip ONLY on a confidently-computed empty overlap. Any git hiccup
  # (bad ref, shallow clone, empty file set) falls through to verifying — the
  # safe default. merge-base(pre_merge_ref, origin/main) is the divergence point;
  # main's files = changes from there to origin/main; the branch's files = its
  # own footprint on top of current main (origin/main..HEAD, post-rebase).
  local _mb _main_files _branch_files _overlap
  _mb=$(git -C "$worktree_path" merge-base "$pre_merge_ref" origin/main 2>/dev/null || true)
  if [ -n "$_mb" ]; then
    _main_files=$(git -C "$worktree_path" diff --name-only "$_mb" origin/main 2>/dev/null | sort -u || true)
    _branch_files=$(git -C "$worktree_path" diff --name-only origin/main HEAD 2>/dev/null | sort -u || true)
    if [ -n "$_main_files" ] && [ -n "$_branch_files" ]; then
      _overlap=$(comm -12 <(printf '%s\n' "$_main_files") <(printf '%s\n' "$_branch_files") 2>/dev/null || true)
      if [ -z "$_overlap" ]; then
        echo "Post-merge verification skipped — rebase pulled in no files overlapping this branch's changes (no semantic-conflict risk)" >&2
        _diag "POST_MERGE_VERIFY skip=no-overlap pre_ref=${pre_merge_ref} pr=${PR_NUMBER:-?}"
        return 0
      fi
    fi
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
    _pmv_gate_file=$(mktemp "/tmp/rite_pmv_gate_$$_XXXXXX")
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
      # main is kept green (block-on-any gate, Phase 3), so a targeted-gate
      # failure here IS the merge's doing, full stop.
      #
      # We deliberately do NOT re-run the full suite on origin/main to ask "is
      # main broken?" anymore. That check is redundant (green main means any
      # post-merge failure is the merge's) and was the LAST full-suite run in the
      # issue lifecycle — and the source of a flake cascade (a load-flaky
      # concurrency test failed the gate → triggered a silent full-suite
      # main-broken run). The only full-suite run now is the deliberate,
      # scheduled `rite --full-suite` safety net.
      echo "⚠️  Post-merge verification FAILED (exit $_pmv_gate_exit)" >&2
      echo "The merge/rebase succeeded at the git level but introduced test failures" >&2
      echo "(main was green before the merge). Likely a silent semantic conflict." >&2
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
        # npm ci/install through a symlinked node_modules (rite worktree
        # layout) destroys the symlink TARGET — remove the LINK first
        # (plain rm, never rm -rf) so npm builds a worktree-local real dir.
        [ -L node_modules ] && rm node_modules
        [ -L backend/node_modules ] && rm backend/node_modules
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

  # Capture output to a temp file so we can classify missing-deps / no-tests
  # signatures (for pytest-flavored commands) before deciding whether to block.
  # Output is also forwarded to stderr (indented) so the operator sees it live.
  local _pmv_out_file _pmv_exit_file
  _pmv_out_file=$(mktemp "/tmp/rite_pmv_out_$$_XXXXXX")
  _pmv_exit_file=$(mktemp "/tmp/rite_pmv_exit_$$_XXXXXX")
  # Run inside a subshell: source env file, then run the test command.
  # timeout wraps the test command directly (an external binary) rather than
  # a shell function, which external commands cannot exec.
  # Exit is captured via exit-file INSIDE the pipeline (#936 pattern), NOT via
  # `|| test_exit=$?` after it: that form only sees the test command's exit
  # under pipefail, and verify_post_merge is a sourced function — any caller
  # running without pipefail would silently read sed's 0 and pass real
  # failures at the merge gate (live: sweep 2026-07-06, tests pinned below).
  { (
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
  ); echo $? > "$_pmv_exit_file"; } 2>&1 | tee "$_pmv_out_file" | sed 's/^/  /' >&2 || true
  test_exit=$(cat "$_pmv_exit_file" 2>/dev/null || echo 1)
  test_exit=${test_exit:-1}  # empty file = child killed before writing = failure (#936)
  rm -f "$_pmv_exit_file"

  if [ "$test_exit" -eq 124 ]; then
    rm -f "${_pmv_out_file:-}"
    echo "⚠️  Post-merge verification timed out after ${verify_timeout}s — skipping" >&2
    return 0
  fi

  # Missing-deps / no-tests-collected fallback for pytest-flavored test commands.
  # A missing venv or absent pytest installation exits non-zero with a
  # ModuleNotFoundError signature — that's an environment gap, not a semantic
  # conflict introduced by the merge.  Exit 5 (no tests collected) is similarly
  # benign.  Both should be loud skips rather than hard failures so the workflow
  # isn't blocked on a broken dev environment that the merge didn't cause.
  # _classify_pytest_outcome is defined in test-gate.sh (sourced above); the
  # declare -f guard keeps the call safe in test sandboxes that stub run_test_gate
  # without sourcing the full test-gate.sh.
  if [ "$test_exit" -ne 0 ] \
     && echo "$test_cmd" | grep -q "pytest" \
     && declare -f _classify_pytest_outcome >/dev/null 2>&1; then
    local _pmv_raw _pmv_outcome
    _pmv_raw=$(cat "$_pmv_out_file" 2>/dev/null || true)
    _pmv_outcome=$(_classify_pytest_outcome "$test_exit" "$_pmv_raw")
    if [ "$_pmv_outcome" = "skipped:missing_deps" ]; then
      rm -f "${_pmv_out_file:-}"
      echo "[post-merge-verify] WARNING: pytest detected missing dependencies (ModuleNotFoundError)." >&2
      echo "[post-merge-verify] Install test dependencies (e.g. pip install -r requirements-dev.txt) or activate the venv before running rite." >&2
      echo "Post-merge verification skipped — missing test dependencies (environment gap, not a merge conflict)" >&2
      _diag "POST_MERGE_VERIFY skip=missing_deps pr=${PR_NUMBER:-?}"
      return 0
    elif [ "$_pmv_outcome" = "skipped:no_tests" ]; then
      rm -f "${_pmv_out_file:-}"
      echo "[post-merge-verify] WARNING: pytest collected no tests (exit 5)." >&2
      echo "Post-merge verification skipped — no tests collected" >&2
      _diag "POST_MERGE_VERIFY skip=no_tests pr=${PR_NUMBER:-?}"
      return 0
    fi
  fi
  rm -f "${_pmv_out_file:-}"

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
