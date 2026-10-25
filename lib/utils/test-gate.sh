#!/bin/bash
# lib/utils/test-gate.sh — Post-commit structured verification gate
#
# Runs make shellcheck + make lint (independently) + bats -r tests/ (recursive bats suite) for
# Sharkrite repos (detected by shellcheck: and lint: Makefile targets), or the project's
# detected test runner for non-Sharkrite projects.
# Emits a structured JSON findings file consumed by assess-and-resolve.sh.
#
# Contract:
#   run_test_gate <output_file> [project_root]
#     Writes structured JSON to <output_file>:
#       { "lint": [{file, line, rule, message}, ...],
#         "tests": [{file, test_name, reason}, ...],
#         "exit_code": N }
#     Returns 0 = all passed, 1 = failures recorded.
#
# If make or bats are missing the gate writes:
#   { "lint": [], "tests": [], "exit_code": 0, "skipped": true, "reason": "missing_runner" }
# and returns 0 so assessment proceeds with review findings only.
#
# Usage:
#   source "$RITE_LIB_DIR/utils/test-gate.sh"
#   run_test_gate "$gate_output_file"

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f run_test_gate >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_self_dir/config.sh"
fi

source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/markers.sh"

source "$RITE_LIB_DIR/utils/gate-selection.sh"
source "$RITE_LIB_DIR/utils/gate-runners.sh"
source "$RITE_LIB_DIR/utils/gate-verdict.sh"

# ---------------------------------------------------------------------------
# run_test_gate — main entry point
# Args: $1=output_file [required] $2=project_root [optional, defaults to cwd]
# ---------------------------------------------------------------------------
run_test_gate() {
  local output_file="$1"
  local project_root="${2:-$(pwd)}"

  local _gate_start
  _gate_start=$(date +%s)

  # Determine if this is a Sharkrite repo.
  # Detection: Makefile must have both shellcheck: and lint: targets — those are the two
  # commands the gate actually runs (make shellcheck + make lint, independently).
  # Checking check: alone is insufficient: a non-Sharkrite project could have check: without
  # the shellcheck: and lint: sub-targets, causing "no rule to make target" errors.
  # Sharkrite gate path: make shellcheck + make lint (independently) + bats -r tests/
  # Other repos: run make test / npm test / pytest as usual (best-effort)
  local _is_sharkrite=false
  if [ -f "$project_root/Makefile" ] \
     && grep -q "^shellcheck:" "$project_root/Makefile" 2>/dev/null \
     && grep -q "^lint:" "$project_root/Makefile" 2>/dev/null; then
    _is_sharkrite=true
  fi
  # Set to true when the per-cycle workspace path ran — suppresses the
  # unscoped-suite warning (#975: scoped cycling IS the solution the warning recommends).
  local _ran_scoped_cycle=false

  # --- Worktree existence guard ---
  # If project_root was removed between gate launch and execution (e.g. worktree deleted
  # mid-run), skip gracefully rather than silently pass with exit code 0 from a no-op cd.
  if [ ! -d "$project_root" ]; then
    _diag "TEST_GATE outcome=skipped reason=missing_worktree pr=${PR_NUMBER:-?}"
    _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_worktree"
    return 0
  fi

  # --- Summary mode vs verbose mode ---
  # In summary mode (the default), raw test-runner output is routed directly to
  # RITE_LOG_FILE (the two-channel direct-append path, like [diag] lines) so the
  # console only sees the per-workspace summary + named failures + [test-gate]/
  # TEST_GATE lines. This caps console output at ~30 lines per gate run regardless
  # of how many workspaces / raw npm trailers the runner produces.
  #
  # Verbose mode (RITE_VERBOSE=true or RITE_GATE_VERBOSE=true) restores raw
  # streaming to the terminal — useful for debugging a failing gate locally.
  #
  # The existing BACKGROUND gate flag is preserved: it controls whether the gate
  # runs concurrently with review generation. In summary mode, both foreground and
  # background paths use the log-only channel; the background flag only matters for
  # the verbose fallback path.
  local _gate_verbose=false
  if [ "${RITE_VERBOSE:-}" = "true" ] || [ "${RITE_GATE_VERBOSE:-}" = "true" ]; then
    _gate_verbose=true
  fi

  # Raw gate output routing — established once here and used by every runner path:
  #
  #   SUMMARY mode (default, _gate_verbose=false):
  #     Raw output → RITE_LOG_FILE via direct-append (two-channel convention,
  #     same channel as [diag] lines). Console gets the compact digest only.
  #     Falls back to /dev/null when no log configured (digest still reaches
  #     stdout; nothing is lost from the assessment's point of view).
  #
  #   VERBOSE mode (_gate_verbose=true):
  #     BACKGROUND gate (RITE_GATE_BACKGROUND=1): raw output → log file to
  #       avoid interleaving with the concurrent review stream.
  #     FOREGROUND gate: raw output → /dev/stdout so live progress is visible
  #       and the run doesn't look frozen. Nested-procsub tee still captures it.
  local _gate_raw_sink
  if [ "$_gate_verbose" = "false" ]; then
    # Summary mode: direct-append to log; NOT through the nested-procsub tee.
    _gate_raw_sink="${RITE_LOG_FILE:-/dev/null}"
  elif [ "${RITE_GATE_BACKGROUND:-}" = "1" ]; then
    # Verbose + background: route to log to avoid interleaving.
    _gate_raw_sink="${RITE_LOG_FILE:-/dev/stdout}"
  else
    # Verbose + foreground: live to terminal.
    _gate_raw_sink="/dev/stdout"
  fi

  # --- RITE_TEST_COMMAND override ---
  # When set, use this command verbatim as the test runner for non-Sharkrite repos
  # instead of manifest detection. Checked before the manifest ladder so projects
  # can name any runner (e.g. RITE_TEST_COMMAND="./run-tests.sh").
  # Sharkrite repos always use make shellcheck + make lint + bats (ignore override).
  if [ -n "${RITE_TEST_COMMAND:-}" ] && [ "$_is_sharkrite" = "false" ]; then
    echo "[test-gate] Using RITE_TEST_COMMAND: ${RITE_TEST_COMMAND}"
    local _nonsr_exit_file_cmd _tests_raw_file_cmd
    _nonsr_exit_file_cmd=$(mktemp "/tmp/rite_gate_nonsr_exit_${PR_NUMBER:-0}_$$_XXXXXX")
    _tests_raw_file_cmd=$(mktemp "/tmp/rite_gate_tests_${PR_NUMBER:-0}_$$_XXXXXX")
    # Register crash-sentinel trap: if this branch exits non-zero before
    # _gate_write_json runs, write a valid-JSON sentinel (skipped:true) so
    # assess-and-resolve.sh never reads an empty/absent file as zero findings
    # (fail-open). Mirrors the sentinel logic on the main path (lines 565–573).
    # shellcheck disable=SC2154  # _gate_exit_status assigned inside the trap body via $? at trap execution time
    trap '_gate_exit_status=$?
          rm -f "${_nonsr_exit_file_cmd:-}" "${_tests_raw_file_cmd:-}"
          if [ "$_gate_exit_status" -ne 0 ]; then
            if [ ! -s "${output_file:-}" ] || ! jq empty "${output_file:-}" 2>/dev/null; then
              printf '"'"'{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"gate_crashed"}'"'"' > "${output_file:-/dev/null}"
              echo "[test-gate] WARNING: gate crashed (exit $_gate_exit_status) — wrote sentinel JSON to prevent fail-open" >&2
            fi
          fi' EXIT
    # Use sh -c to support multi-word commands (e.g. "cargo test --features integration")
    # without eval. RITE_TEST_COMMAND is operator-configured in .rite/config, not
    # derived from external input.
    # Capture to the raw file for JSON parsing AND append to the sink (summary →
    # log only; verbose → live terminal or log). The tee writes the raw file in
    # real time while the sink gets the unfiltered stream for full fidelity.
    { (cd "$project_root" && sh -c "${RITE_TEST_COMMAND}" 2>&1); echo $? > "$_nonsr_exit_file_cmd"; } \
      | tee "$_tests_raw_file_cmd" >> "$_gate_raw_sink" || true
    local _cmd_tests_exit
    _cmd_tests_exit=$(cat "$_nonsr_exit_file_cmd" 2>/dev/null || echo 1)
    _cmd_tests_exit=${_cmd_tests_exit:-1}  # empty file = child killed before writing = failure (#935)
    # Same TAP-only hole as the npm branch: a node-flavored custom command
    # (jest/vitest) would otherwise report test_count=0 on real failures.
    if [ "$_cmd_tests_exit" -ne 0 ] \
       && _node_flavored_test_context "$project_root" "${RITE_TEST_COMMAND}"; then
      _normalize_node_test_output "$_tests_raw_file_cmd" "$project_root"
    fi
    # Missing-deps / no-tests-collected fallback: mirrors the pytest-direct branch.
    # When RITE_TEST_COMMAND wraps a Python runner (e.g. "python -m pytest"), a
    # missing venv exits non-zero with a ModuleNotFoundError signature — that's an
    # environment gap, not a test failure.  Exit 5 (no tests collected) is also a
    # loud skip.  Both are caught by _classify_pytest_outcome before the hard-fail
    # path below, so the gate doesn't block the merge on an environment issue.
    if [ "$_cmd_tests_exit" -ne 0 ]; then
      local _cmd_raw _cmd_py_outcome
      _cmd_raw=$(cat "$_tests_raw_file_cmd" 2>/dev/null || true)
      _cmd_py_outcome=$(_classify_pytest_outcome "$_cmd_tests_exit" "$_cmd_raw")
      if [ "$_cmd_py_outcome" = "skipped:missing_deps" ]; then
        echo "[test-gate] WARNING: RITE_TEST_COMMAND output indicates missing dependencies (ModuleNotFoundError)." >&2
        echo "[test-gate] Install the project's test dependencies or update RITE_TEST_COMMAND to activate the venv." >&2
        _diag "TEST_GATE outcome=skipped reason=missing_deps pr=${PR_NUMBER:-?}"
        rm -f "${_nonsr_exit_file_cmd:-}" "${_tests_raw_file_cmd:-}"
        trap - EXIT
        _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_deps"
        return 0
      elif [ "$_cmd_py_outcome" = "skipped:no_tests" ]; then
        echo "[test-gate] WARNING: RITE_TEST_COMMAND collected no tests (exit 5)." >&2
        echo "[test-gate] Add test files or update RITE_TEST_COMMAND to point at your test runner." >&2
        _diag "TEST_GATE outcome=skipped reason=no_tests pr=${PR_NUMBER:-?}"
        rm -f "${_nonsr_exit_file_cmd:-}" "${_tests_raw_file_cmd:-}"
        trap - EXIT
        _gate_write_json "$output_file" "[]" "[]" "0" "true" "no_tests"
        return 0
      fi
    fi
    local _cmd_tests_count
    _cmd_tests_count=$(grep -c "^not ok " "$_tests_raw_file_cmd" || true)
    local _cmd_overall_exit=0
    [ "$_cmd_tests_exit" -ne 0 ] && _cmd_overall_exit=1
    # Build tests[] JSON from the (possibly normalizer-augmented) raw file —
    # same loop as the main path (lines ~2191-2201). Previously this was
    # hardcoded to "[]", so a failing RITE_TEST_COMMAND reported a nonzero
    # test_count in the diag but gave the fix loop zero named findings
    # (diag/JSON inconsistency, PR #838 review finding, issue #846).
    local _cmd_tests_items="["
    local _cmd_first_test=true
    while IFS= read -r _raw; do
      _item=$(_parse_bats_failure_line "$_raw" 2>/dev/null || true)
      if [ -n "$_item" ]; then
        [ "$_cmd_first_test" = "true" ] || _cmd_tests_items+=","
        _cmd_tests_items+="$_item"
        _cmd_first_test=false
      fi
    done < "$_tests_raw_file_cmd"
    _cmd_tests_items+="]"
    local _gate_end_cmd _duration_cmd
    _gate_end_cmd=$(date +%s)
    _duration_cmd=$(( _gate_end_cmd - _gate_start ))
    local _outcome_cmd="passed"
    [ "$_cmd_overall_exit" -ne 0 ] && _outcome_cmd="failed"
    _diag "TEST_GATE outcome=${_outcome_cmd} lint_count=0 test_count=${_cmd_tests_count} duration_s=${_duration_cmd} pr=${PR_NUMBER:-?}"
    _maybe_warn_unscoped_suite "$_duration_cmd" "${RITE_GATE_SCOPE_WARN_SECONDS:-300}" "false"
    # Console digest for the RITE_TEST_COMMAND path (summary mode hides raw output above).
    if [ "$_cmd_overall_exit" -ne 0 ]; then
      echo "[test-gate] RITE_TEST_COMMAND: ${_cmd_tests_count} failure(s) — full output in ${RITE_LOG_FILE:-run log}"
      if [ "$_cmd_tests_count" -gt 0 ]; then
        local _cmd_fail_names
        _cmd_fail_names=$(_extract_tap_failure_names "$_tests_raw_file_cmd")
        if [ -n "$_cmd_fail_names" ]; then
          local _cmd_ncount
          _cmd_ncount=$(printf '%s\n' "$_cmd_fail_names" | grep -c '.' || true)
          echo "⚠️  ${_cmd_ncount} test failure(s) blocking the gate:"
          printf '%s\n' "$_cmd_fail_names" | while IFS= read -r _n; do
            [ -n "$_n" ] && echo "   • ${_n}"
          done
        fi
      fi
    else
      echo "[test-gate] RITE_TEST_COMMAND: passed ✅"
    fi
    _gate_write_json "$output_file" "[]" "$_cmd_tests_items" "$_cmd_overall_exit"
    rm -f "${_nonsr_exit_file_cmd:-}" "${_tests_raw_file_cmd:-}"
    trap - EXIT
    return "$_cmd_overall_exit"
  fi

  # --- Missing-runner check ---
  if [ "$_is_sharkrite" = "true" ]; then
    if ! command -v make >/dev/null 2>&1; then
      _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
      _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
      return 0
    fi
    if ! command -v bats >/dev/null 2>&1; then
      _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
      _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
      return 0
    fi
  fi

  # Temp files for capturing raw output (PID-scoped to prevent glob collision)
  local _lint_raw_file _tests_raw_file
  _lint_raw_file=$(mktemp "/tmp/rite_gate_lint_${PR_NUMBER:-0}_$$_XXXXXX")
  _tests_raw_file=$(mktemp "/tmp/rite_gate_tests_${PR_NUMBER:-0}_$$_XXXXXX")
  # Census entry: populated inside the sharkrite path just before _compute_bats_jobs;
  # initialised empty here so the trap's rm -f is a no-op for non-sharkrite paths.
  local _gate_census_file=""
  # Register cleanup for this invocation's specific files (never a glob).
  # Also write a valid-JSON crash sentinel if the function exits non-zero before
  # _gate_write_json runs — an empty/absent output_file causes jq to silently
  # return zero findings (fail-open), defeating the gate's purpose.
  # The sentinel uses skipped:true so assess-and-resolve.sh skips gate injection
  # rather than reading malformed JSON, while still logging the crash via _diag.
  # shellcheck disable=SC2154  # _gate_exit_status assigned inside the trap body via $? at trap execution time
  trap '_gate_exit_status=$?
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_sc_exit_file:-}" "${_lint_exit_file:-}" "${_bats_exit_file:-}" "${_nonsr_exit_file:-}" "${_sc_raw_individual:-}" "${_lint_raw_individual:-}" "${_bats_pretty_capture:-}"
        rm -f "${_gate_census_file:-}"
        [ -n "${_bats_tap_dir:-}" ] && rm -rf "${_bats_tap_dir:-}"
        if [ "$_gate_exit_status" -ne 0 ]; then
          if [ ! -s "${output_file:-}" ] || ! jq empty "${output_file:-}" 2>/dev/null; then
            printf '"'"'{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"gate_crashed"}'"'"' > "${output_file:-/dev/null}"
            echo "[test-gate] WARNING: gate crashed (exit $_gate_exit_status) — wrote sentinel JSON to prevent fail-open" >&2
          fi
        fi' EXIT

  local _lint_exit=0
  local _tests_exit=0
  local _lint_count=0
  local _tests_count=0
  # Reason for a non-skipped gate failure that produces no parseable items
  # (e.g. runner_unavailable when the test runner binary is missing).
  # Propagated to the gate JSON so assess-and-resolve.sh can name the cause
  # in its synthetic blocking [GATE] item.  Empty string = no named reason.
  local _gate_reason=""
  local _fr_watchdog=false
  local _watchdog_group=""

  # _gate_verbose and _gate_raw_sink are resolved above (before RITE_TEST_COMMAND
  # early-return) so the same sink is used by every runner path uniformly.

  if [ "$_is_sharkrite" = "true" ]; then
    # --- Sharkrite: shellcheck + custom lint (run independently so both run even if shellcheck fails) ---
    # Running as two separate invocations ensures custom-lint findings are never masked
    # by a shellcheck failure (make check: shellcheck lint stops make after shellcheck exits non-zero).
    local _shellcheck_exit=0
    local _lint_tool_exit=0
    # Exit-code capture temp files (PID-scoped; one per invocation to prevent glob collision)
    local _sc_exit_file _lint_exit_file _bats_exit_file
    _sc_exit_file=$(mktemp "/tmp/rite_gate_sc_exit_${PR_NUMBER:-0}_$$_XXXXXX")
    _lint_exit_file=$(mktemp "/tmp/rite_gate_lint_exit_${PR_NUMBER:-0}_$$_XXXXXX")
    _bats_exit_file=$(mktemp "/tmp/rite_gate_bats_exit_${PR_NUMBER:-0}_$$_XXXXXX")

    # --- Compute changed-file set once for both lint and bats selection ---
    # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: cold-start default for direct/CI invocation; run_workflow seeds origin/<target> per #1037, operator env (RITE_TEST_GATE_DIFF_BASE) still wins
    local _diff_base="${RITE_TEST_GATE_DIFF_BASE:-origin/main}"
    local _changed_files
    _changed_files=$(cd "$project_root" && git diff --name-only "$_diff_base"...HEAD 2>/dev/null || true)

    # --- Targeted custom-lint selection (parallel to bats #462) ---
    # Apply the same changed-paths optimization to `make lint`. Trigger files
    # (lint rule itself, Makefile) force a full scan. Otherwise pass the list
    # of changed shell-source paths via RITE_LINT_FILES; the lint script
    # intersects it with SHELL_FILES to bound the scan.
    local _lint_selection _lint_selected_count
    _lint_selection=$(_select_lint_by_changed_paths "$_changed_files" "$project_root")

    if [ "$_lint_selection" = "FORCE_FULL" ]; then
      _gate_status "[test-gate] Lint: full scan"
      _diag "LINT_GATE_SELECTION mode=full pr=${PR_NUMBER:-?}"
    elif [ -z "$_lint_selection" ]; then
      _gate_status "[test-gate] Lint: no shell-source changes — skipping"
      _diag "LINT_GATE_SELECTION mode=skipped selected=0 pr=${PR_NUMBER:-?}"
    else
      _lint_selected_count=$(echo "$_lint_selection" | grep -c '.' || true)
      _gate_status "[test-gate] Lint: targeted (${_lint_selected_count} changed shell file(s))"
      _diag "LINT_GATE_SELECTION mode=targeted selected=${_lint_selected_count} pr=${PR_NUMBER:-?}"
    fi

    # --- Run shellcheck + custom lint CONCURRENTLY ---
    # Both scan read-only source files — no shared mutable state between them,
    # so they can race safely. Each writes its raw output to a per-invocation
    # temp file (PID-scoped, never globbed) and we merge into _lint_raw_file
    # after wait so the JSON parser sees clean input. Live progress during the
    # gate's shellcheck+lint phase is sacrificed in exchange for the speedup —
    # both finish within a few seconds and the merged output is then written to
    # the run log only (_gate_raw_sink), not the terminal.
    local _sc_raw_individual _lint_raw_individual
    _sc_raw_individual=$(mktemp "/tmp/rite_gate_sc_raw_${PR_NUMBER:-0}_$$_XXXXXX")
    _lint_raw_individual=$(mktemp "/tmp/rite_gate_lint_raw_${PR_NUMBER:-0}_$$_XXXXXX")

    _gate_status "[test-gate] Running make shellcheck + make lint (concurrent)..."
    { (cd "$project_root" && make shellcheck) > "$_sc_raw_individual" 2>&1; echo $? > "$_sc_exit_file"; } &
    local _sc_pid=$!

    local _lint_pid=""
    if [ "$_lint_selection" = "FORCE_FULL" ]; then
      { (cd "$project_root" && make lint) > "$_lint_raw_individual" 2>&1; echo $? > "$_lint_exit_file"; } &
      _lint_pid=$!
    elif [ -z "$_lint_selection" ]; then
      # Skipped — no lint process launched, treat as clean.
      echo 0 > "$_lint_exit_file"
    else
      # Targeted — pass RITE_LINT_FILES via inline env assignment.
      { (cd "$project_root" && RITE_LINT_FILES="$_lint_selection" make lint) > "$_lint_raw_individual" 2>&1; echo $? > "$_lint_exit_file"; } &
      _lint_pid=$!
    fi

    wait "$_sc_pid" 2>/dev/null || true
    [ -n "$_lint_pid" ] && { wait "$_lint_pid" 2>/dev/null || true; }
    _shellcheck_exit=$(cat "$_sc_exit_file" 2>/dev/null || echo 1)
    _shellcheck_exit=${_shellcheck_exit:-1}  # empty = killed before writing = failure (#935)
    _lint_tool_exit=$(cat "$_lint_exit_file" 2>/dev/null || echo 1)
    _lint_tool_exit=${_lint_tool_exit:-1}  # empty = killed before writing = failure (#935)

    # Merge into the JSON parser's input AND append to the run log (not the
    # terminal). Order: shellcheck first, then lint (matches the previous
    # sequential output layout that downstream readers may pattern-match on).
    {
      [ -s "$_sc_raw_individual" ] && cat "$_sc_raw_individual"
      [ -s "$_lint_raw_individual" ] && cat "$_lint_raw_individual"
    } | tee -a "$_lint_raw_file" >> "$_gate_raw_sink" || true
    rm -f "$_sc_raw_individual" "$_lint_raw_individual"

    [ "$_shellcheck_exit" -ne 0 ] && _lint_exit=1
    [ "$_lint_tool_exit" -ne 0 ] && _lint_exit=1
    # _lint_count is derived from the JSON array builder below (not a broad grep)

    # --- Sharkrite: targeted bats selection (issue #462) ---
    # Determine which bats files to run based on the commit's changed paths.
    # Files declare coverage via `# sharkrite-test-covers: <paths>` headers.
    # Headerless files are skipped. Selection is always targeted; FORCE_FULL (the
    # whole ~181-file suite) is OPT-IN ONLY (see the dispatch below).
    # See: _select_tests_by_changed_paths above.
    local _total_bats _selection _selected_count
    _total_bats=$(cd "$project_root" && find tests -name "*.bats" -type f 2>/dev/null | wc -l | tr -d ' ')

    # No-bats-suite guard: if no *.bats files exist (no tests/ dir, or tests/ has
    # no .bats files), skip bats entirely — nothing to verify, not a failure.
    # Mirrors the missing_runner/missing_deps skip shape. The gate still records
    # lint findings; only the bats step is bypassed.
    local _bats_skip=false
    if [ "${_total_bats:-0}" -eq 0 ]; then
      echo "[test-gate] bats: skipped (no bats suite)" >&2
      _diag "TEST_GATE_SELECTION mode=targeted selected=0 total=0 pr=${PR_NUMBER:-?}"
      _diag "TEST_GATE_BATS outcome=skipped reason=no_bats_suite pr=${PR_NUMBER:-?}"
      echo 0 > "$_bats_exit_file"
      : > "$_tests_raw_file"
      _bats_skip=true
    fi

    if [ "$_bats_skip" = "false" ]; then
    # FORCE_FULL gate: an empty changed-file set conflates several causes — no
    # commits yet, a git-diff error laundered to "" by `2>/dev/null || true`, or a
    # deliberate DIFF_BASE=HEAD — and silently mapping ALL of them to "run
    # everything" was the recurring full-suite regression. Decide explicitly so a
    # transient empty diff can never escalate a normal run to all ~181 files:
    if [ "${RITE_GATE_FORCE_FULL:-}" = "1" ] || [ "$_diff_base" = "HEAD" ]; then
      # Explicit full-suite signals only: the opt-in env var, or a deliberately
      # HEAD diff base (post-merge-verify's main-broken check; full-run tests). A
      # normal run never sets either — it defaults to origin/main — so a transient
      # empty/errored origin/main diff can no longer escalate to the full suite.
      _selection="FORCE_FULL"
    elif ! (cd "$project_root" && git rev-parse --verify "${_diff_base}^{commit}" >/dev/null 2>&1); then
      # Base unresolvable → skip bats with a loud diag, never a silent full run.
      # A normal run never hits this (worktree creation hard-fetches origin/main).
      echo "[test-gate] diff base '${_diff_base}' unresolvable — skipping bats (set RITE_GATE_FORCE_FULL=1 to force a full run)" >> "$_gate_raw_sink"
      _diag "TEST_GATE_SELECTION mode=skipped reason=unresolvable_diff_base base=${_diff_base} pr=${PR_NUMBER:-?}"
      _selection=""
    elif [ -z "$_changed_files" ]; then
      _selection=""                                 # base resolves, zero changed files → run ZERO bats, not 181
    else
      _selection=$(_select_tests_by_changed_paths "$_changed_files" "$project_root")
    fi

    # --- Verdict persistence (#944): union in previously-failing files -------
    # A prior gate run for this PR that FAILED leaves its failing FILES in a
    # state file. The next run's selection must include them: fix-loop re-gates
    # deliberately narrow the diff base to the fix commit (workflow-runner
    # passes _pre_fix_head), so a fix touching only uncovered paths computed an
    # EMPTY selection and the round reported outcome=passed having verified
    # NOTHING — a vacuous pass that merged red (live escape: PR #931/#855,
    # selected=15/failed → selected=0/passed → red main, repaired in #943).
    # With the union, selected can only be 0 when there is no prior failure.
    local _prior_fail_file="${RITE_STATE_DIR:-$project_root/.rite/state}/gate-prior-failing-pr${PR_NUMBER:-0}.list"
    if [ -s "$_prior_fail_file" ]; then
      local _prior_injected=0 _pf
      while IFS= read -r _pf; do
        [ -z "$_pf" ] && continue
        [ -f "$project_root/$_pf" ] || continue
        if ! printf '%s\n' "$_selection" | grep -qxF "$_pf"; then
          _selection="${_selection:+$_selection
}$_pf"
          _prior_injected=$((_prior_injected + 1))
        fi
      done < "$_prior_fail_file"
      if [ "$_prior_injected" -gt 0 ]; then
        _gate_status "[test-gate] Re-verifying ${_prior_injected} previously-failing file(s) from the last gate round (verdict persistence, #944)"
        _diag "TEST_GATE_SELECTION reselected_prior=true injected=${_prior_injected} pr=${PR_NUMBER:-?}"
      fi
    fi

    # --- Gate census registration (#1165) ---
    # Register this gate's BASHPID so _compute_bats_jobs can count concurrent
    # peers and scale --jobs down when ≥3 gates are active. $$ is the parent
    # orchestrator's PID (wrong when run_test_gate is backgrounded with &);
    # $BASHPID is always the current subshell's own PID. Only sharkrite gates
    # (which run bats) register — the non-sharkrite path never calls
    # _compute_bats_jobs. Cleanup is via the crash-sentinel EXIT trap (rm -f on
    # the specific PID file) and the explicit rm before trap - EXIT at the end.
    if [ -n "${RITE_LOCK_DIR:-}" ]; then
      mkdir -p "${RITE_LOCK_DIR}/gate-census" 2>/dev/null || true
      # ${BASHPID:-$$}: BASHPID is bash 4+ only, so a bare reference is UNBOUND
      # under set -u on macOS system bash 3.2 and crashes the gate (live:
      # issue #1167's slot, 2026-10-13). $$ is a correct fallback here — the
      # census only needs a stable per-process identity to count concurrent
      # gates and to remove its own entry.
      _gate_census_file="${RITE_LOCK_DIR}/gate-census/${BASHPID:-$$}"
      touch "$_gate_census_file" 2>/dev/null || _gate_census_file=""
    fi

    # --- Bats parallelism (--jobs N) ---
    # Auto-detect: use GNU parallel if installed; scale by census count (#1165).
    # RITE_BATS_JOBS=N overrides. File-level parallel only — within each bats
    # file, tests still run sequentially (bats-core default).
    local _bats_jobs _bats_jobs_args _bats_census
    _bats_census=$(_census_live_gate_count)
    _bats_jobs=$(_compute_bats_jobs "$_bats_census")
    if [ "$_bats_jobs" -gt 1 ]; then
      _bats_jobs_args=(--jobs "$_bats_jobs")
      _gate_status "[test-gate] bats: parallel (--jobs ${_bats_jobs})"
    else
      _bats_jobs_args=()
      _gate_status "[test-gate] bats: serial (parallel binary not found; install GNU parallel to enable)"
    fi
    _diag "BATS_JOBS jobs=${_bats_jobs} census=${_bats_census} pr=${PR_NUMBER:-?}"

    # bats' pretty formatter shells out to `tput`; with TERM unset (launchd,
    # cron, non-TTY CI) tput errors and bats exits NON-ZERO even when every test
    # passes — the gate would then read that as a failing suite and spuriously
    # block the merge / fail post-merge-verify. Default TERM to a safe value so
    # the run is exit-code-honest in every environment. (Live trigger: any
    # headless invocation — the health-report and full-suite launchd jobs run
    # with no TERM.)
    export TERM="${TERM:-dumb}"

    # Per-test timeout: a single hung test must not stall the whole gate until the
    # outer backstop (RITE_GATE_WAIT_TIMEOUT, ~30 min) fires. bats' BATS_TEST_TIMEOUT
    # kills any test exceeding it via a pkill/ps countdown — no GNU `timeout` command
    # needed, so it works on macOS too. Exported here so all three bats invocations
    # below (full / parallel / serial) inherit it in their subshells.
    # Live trigger (2026-06-26): a self-exec'ing python3 wrapper made
    # venv-bootstrap-failure-loud.bats hang, stalling the gate ~30 min on a single
    # test. Default 120s/test (ample for load-sensitive serial tests); override via
    # RITE_BATS_TEST_TIMEOUT.
    export BATS_TEST_TIMEOUT="${RITE_BATS_TEST_TIMEOUT:-120}"

    # --- Bats sandbox: stdin, env scrub, whole-run watchdog ---
    # Live freeze (2026-07-01, rite 804): the gate's bats run inherited the
    # workflow's terminal stdin and live environment. A regression test executed
    # the real bin/rite, which (a) appended its log header and diag lines to the
    # REAL run log via inherited RITE_LOG_FILE, (b) spawned lib/core/create-pr.sh
    # carrying the real PR_NUMBER — that orphan ran a second full gate and real
    # review generations against the live PR — and (c) read from the tty as a
    # background job → SIGTTIN stopped the whole bats process group, including
    # bats' own per-test-timeout watchdogs (BATS_TEST_TIMEOUT cannot fire from
    # inside a stopped group). The gate hung ~3.5h until manually killed.
    #
    # Three independent defenses, applied to every bats invocation below:
    #   1. stdin < /dev/null — no test child can ever read the workflow's tty.
    #   2. env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER — tests must not
    #      inherit the live workflow's identity; anything they spawn cannot
    #      mistake itself for the real run or write to its log.
    #   3. Whole-run watchdog (gtimeout/timeout when available) as the
    #      last-resort bound — unlike BATS_TEST_TIMEOUT it lives OUTSIDE the
    #      bats process group, so even a stopped group gets killed. Default
    #      1800s; override via RITE_GATE_BATS_TIMEOUT (0 disables). Detection
    #      is deliberately prompt-free: never call ensure_timeout_cmd here —
    #      its supervised-mode install prompt would itself read stdin mid-gate.
    # BATS_* scrub: when the gate's own bats run selects a test that spawns
    # inner bats (gate-flake-retry.bats exercising _gate_flake_retry_pass),
    # inherited BATS_RUN_TMPDIR/BATS_ROOT_PID etc. collide with the inner
    # runner's IPC — deterministic 120s deadlock (#993, live in #976's gate).
    # Var list is the union of #991's empirically-needed set (its fix-loop hit
    # the same deadlock and scrubbed the test side only) and #993's — EXCEPT
    # BATS_TEST_TIMEOUT: the gate exports its own per-test watchdog value
    # above, and env -u here would strip that export from the bats it wraps,
    # disabling the timeout and breaking swallowed-test detection (the
    # gate-flake-retry.bats setup mirror DOES scrub it — there the leak is
    # the OUTER runner's value, not a gate-owned export).
    #
    # _GATE_BATS_SCRUB_VARS — session-behavioral RITE_* vars that must not
    # bleed into bats tests. Tests that pass in isolation can fail inside a
    # gate when an exported session var flips a code path; the lint rule cannot
    # catch this class (the broken tests contain zero references to the var).
    # Structural vars (RITE_REPO_ROOT, RITE_LIB_DIR, RITE_PROJECT_ROOT) stay —
    # Rule 35 suppressions and setup.bash loaders depend on them.
    # Incidents: RITE_TEST_GATE_SKIP_TRIGGERS=true (#1182, 3 tests × 5 slots);
    # RITE_TARGET_BRANCH=supervised-ux (#1049/PR #1179, 2 tests × 3 retries);
    # RITE_TEST_GATE_DIFF_BASE=origin/main...SHA (#975 workspace tests, 3 tests):
    #   workflow-runner.sh passes RITE_TEST_GATE_DIFF_BASE inline when launching
    #   the gate (e.g. origin/main...pre_fix_head); not in the unset list → leaked
    #   into bats → inner _run_gate_with_env subprocess used it as the diff base →
    #   git diff silently failed → _nonsr_changed_files empty → no workspace tests
    #   ran → positive workspace assertions failed.
    # Note: RITE_TEST_GATE_SKIP_TRIGGERS is consumed by the gate itself BEFORE
    # the bats invocation (selection phase); scrubbing it from the child env
    # does not change gate-selection behavior.
    # Batch session identity (SESSION_STATE_FILE, RITE_BATCH_ID, BATCH_MODE,
    # SESSION_START_TIME) is scrubbed too: a test that runs batch-process-issues.sh
    # inherited the live batch's RITE_BATCH_ID, re-derived the live session file,
    # reset it in init_session, and deleted it in the _cleanup_batch_session EXIT
    # trap. Live: batch 1338 (2026-10-24) — #1333's gate ran the batch tests and
    # the batch's overall clock restarted mid-run ("Duration: 3s", mode flipped
    # to supervised, ~26 min of cumulative work lost from the session-hours cap).
    # Applied by _bats_sandbox below; also dynamic-scoped into _gate_flake_retry_pass.
    local _bats_sandbox=(env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
      -u SESSION_STATE_FILE -u RITE_BATCH_ID -u BATCH_MODE -u SESSION_START_TIME \
      -u RITE_TARGET_BRANCH -u RITE_TEST_GATE_SKIP_TRIGGERS \
      -u RITE_STALE_BRANCH_THRESHOLD -u RITE_STALE_BRANCH_HARD_RESTART_THRESHOLD \
      -u RITE_ACCEPT_RED_MAIN \
      -u RITE_TEST_GATE_DIFF_BASE \
      -u BATS_RUN_TMPDIR -u BATS_SUITE_TMPDIR -u BATS_FILE_TMPDIR \
      -u BATS_TEST_TMPDIR -u BATS_ROOT_PID -u BATS_LIBEXEC_DIR \
      -u BATS_TMPDIR -u BATS_SUITE_TEST_NUMBER)
    local _bats_watchdog=()
    local _gate_bats_timeout="${RITE_GATE_BATS_TIMEOUT:-1800}"
    if [ "$_gate_bats_timeout" != "0" ]; then
      if command -v gtimeout >/dev/null 2>&1; then
        _bats_watchdog=(gtimeout -k 30 "$_gate_bats_timeout")
      elif command -v timeout >/dev/null 2>&1; then
        _bats_watchdog=(timeout -k 30 "$_gate_bats_timeout")
      fi
    fi

    # --- Bats output format: pretty for the run log, TAP for JSON parser ---
    # When bats supports --report-formatter (bats-core >= 1.5), we run with
    # `-F pretty` for readable output, while TAP is written to a temp dir via
    # `--report-formatter tap`.  The TAP file replaces the old tee-to-raw-file
    # pattern so _parse_bats_failure_line still reads `^not ok N` lines.  The
    # pretty stream is routed to the run log only (_gate_raw_sink), NOT the
    # terminal — the terminal gets the compact digest emitted before
    # _gate_write_json.  This keeps failing-test transcripts out of concurrent
    # phase output.
    #
    # Fallback: older bats without --report-formatter → original TAP-via-tee,
    # also routed to the run log via _gate_raw_sink.
    local _bats_use_pretty=false
    local _bats_tap_dir=""
    local _bats_pretty_capture=""
    if _bats_has_report_formatter; then
      _bats_use_pretty=true
      _bats_tap_dir=$(mktemp -d "/tmp/rite_gate_tap_${PR_NUMBER:-0}_$$_XXXXXX")
      # Pretty stream is ALSO tee'd into this capture file (streaming to
      # _gate_raw_sink is preserved — tee writes through) so the not-run
      # detector below can spot the literal `bats warning: Executed X instead
      # of expected Y tests` line (issue #804) — a detection TRIGGER only.
      # Not-run NAMES are resolved from planned-@test-vs-TAP set difference,
      # never from this stream: the pretty formatter truncates begin lines
      # at terminal width (the 130-phantom mechanism, PR #852) and it
      # interleaves across workers under --jobs
      # and begin/result pairing produced 130 phantom findings for a deficit
      # of 1 (issue #862).
      _bats_pretty_capture=$(mktemp "/tmp/rite_gate_pretty_${PR_NUMBER:-0}_$$_XXXXXX")
      _gate_status "[test-gate] bats: pretty formatter (terminal) + TAP report (parser)"
    else
      _gate_status "[test-gate] bats: TAP formatter (--report-formatter not available in installed bats)"
    fi

    if [ "$_selection" = "FORCE_FULL" ]; then
      _selected_count="$_total_bats"
      _gate_status "[test-gate] Selection: full suite (${_total_bats} bats files — RITE_GATE_FORCE_FULL opt-in)"
      _diag "TEST_GATE_SELECTION mode=full selected=${_total_bats} total=${_total_bats} pr=${PR_NUMBER:-?}"
      _gate_status "[test-gate] Running bats -r tests/..."
      if [ "$_bats_use_pretty" = "true" ]; then
        # tee into _bats_pretty_capture (not-run detection, #804) while still
        # streaming to the sink — same exit-capture shape as the TAP fallback.
        { (cd "$project_root" && BATS_REPORT_FILENAME=report.tap \
            "${_bats_sandbox[@]}" "${_bats_watchdog[@]+"${_bats_watchdog[@]}"}" \
            bats -F pretty --report-formatter tap --output "$_bats_tap_dir" \
            "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" -r tests/) \
            < /dev/null 2>&1; \
          echo $? > "$_bats_exit_file"; } \
          | tee -a "$_bats_pretty_capture" >> "$_gate_raw_sink" || true
        cp "$_bats_tap_dir/report.tap" "$_tests_raw_file" 2>/dev/null || : > "$_tests_raw_file"
      else
        { (cd "$project_root" && "${_bats_sandbox[@]}" "${_bats_watchdog[@]+"${_bats_watchdog[@]}"}" \
            bats "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" -r tests/ < /dev/null 2>&1); echo $? > "$_bats_exit_file"; } \
          | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      fi
    elif [ -z "$_selection" ]; then
      # Diff exists but no bats file covers the changed paths. Run nothing —
      # this replaces the old escalate-to-full fallback (removed 2026-06-12:
      # a Makefile/fixture tweak forced all ~165 files for hours). Honest and
      # loud: the diag records selected=0 so the health report can watch for
      # systematic coverage gaps.
      _selected_count=0
      _gate_status "[test-gate] Selection: targeted (0/${_total_bats} bats files — no covered tests for changed paths, skipping bats)"
      _diag "TEST_GATE_SELECTION mode=targeted selected=0 total=${_total_bats} pr=${PR_NUMBER:-?}"
      echo 0 > "$_bats_exit_file"
      : > "$_tests_raw_file"
    else
      _selected_count=$(echo "$_selection" | grep -c '.' || true)
      _gate_status "[test-gate] Selection: targeted (${_selected_count}/${_total_bats} bats files based on changed paths)"
      _diag "TEST_GATE_SELECTION mode=targeted selected=${_selected_count} total=${_total_bats} pr=${PR_NUMBER:-?}"
      # Split selected files into parallel and serial groups.
      # Files carrying the sharkrite-gate-serial hint (load-sensitive or subprocess-heavy
      # tests that flake under bats --jobs N) are collected into _serial_files[].
      # All others go into _parallel_files[]. Both groups must pass — exit codes are OR'd.
      # This preserves the block-on-any guarantee: any failure in either group blocks.
      local _parallel_files=()
      local _serial_files=()
      while IFS= read -r _bf; do
        [ -z "$_bf" ] && continue
        if _bats_file_is_serial "$project_root/$_bf"; then
          _serial_files+=("$_bf")
        else
          _parallel_files+=("$_bf")
        fi
      done <<< "$_selection"

      local _serial_count=${#_serial_files[@]}
      local _parallel_count=${#_parallel_files[@]}
      if [ "$_serial_count" -gt 0 ]; then
        _gate_status "[test-gate] bats split: ${_parallel_count} parallel, ${_serial_count} serial (load-sensitive)"
        _diag "BATS_SERIAL_SPLIT parallel=${_parallel_count} serial=${_serial_count} pr=${PR_NUMBER:-?}"
      fi

      # Run parallel batch (if any)
      local _par_exit=0
      if [ "$_parallel_count" -gt 0 ]; then
        _gate_status "[test-gate] Running bats on ${_parallel_count} parallel file(s)..."
        if [ "$_bats_use_pretty" = "true" ]; then
          local _par_tap_dir
          _par_tap_dir=$(mktemp -d "/tmp/rite_gate_par_tap_${PR_NUMBER:-0}_$$_XXXXXX")
          { (cd "$project_root" && BATS_REPORT_FILENAME=report.tap \
              "${_bats_sandbox[@]}" "${_bats_watchdog[@]+"${_bats_watchdog[@]}"}" \
              bats -F pretty --report-formatter tap --output "$_par_tap_dir" \
              "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" "${_parallel_files[@]}") \
              < /dev/null 2>&1; \
            echo $? > "$_bats_exit_file"; } \
            | tee -a "$_bats_pretty_capture" >> "$_gate_raw_sink" || true
          cat "$_par_tap_dir/report.tap" >> "$_tests_raw_file" 2>/dev/null || true
          rm -rf "$_par_tap_dir"
        else
          { (cd "$project_root" && "${_bats_sandbox[@]}" "${_bats_watchdog[@]+"${_bats_watchdog[@]}"}" \
              bats "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" "${_parallel_files[@]}" < /dev/null 2>&1); echo $? > "$_bats_exit_file"; } \
            | tee -a "$_tests_raw_file" >> "$_gate_raw_sink" || true
        fi
        _par_exit=$(cat "$_bats_exit_file" 2>/dev/null || echo 1)
        _par_exit=${_par_exit:-1}  # empty = killed before writing = failure (#935)
        if [ "$_par_exit" = "124" ] || [ "$_par_exit" = "137" ]; then
          _gate_status "[test-gate] bats (parallel group) killed by whole-run watchdog after ${_gate_bats_timeout}s (RITE_GATE_BATS_TIMEOUT)"
          _diag "TEST_GATE_WATCHDOG_KILL group=parallel timeout_s=${_gate_bats_timeout} pr=${PR_NUMBER:-?}"
          _fr_watchdog=true
          _watchdog_group="${_watchdog_group:+${_watchdog_group}+}parallel"
        fi
        echo 0 > "$_bats_exit_file"
      fi

      # Run serial batch after parallel batch completes, regardless of parallel outcome.
      # No --jobs flag: runs each file's tests sequentially. Ensures load-sensitive tests
      # are not starved of CPU/IO by other concurrent bats workers. bats does not require
      # GNU parallel for single-file sequential execution.
      local _ser_exit=0
      if [ "$_serial_count" -gt 0 ]; then
        _gate_status "[test-gate] Running bats on ${_serial_count} serial file(s) (no --jobs, load-sensitive)..."
        if [ "$_bats_use_pretty" = "true" ]; then
          local _ser_tap_dir
          _ser_tap_dir=$(mktemp -d "/tmp/rite_gate_ser_tap_${PR_NUMBER:-0}_$$_XXXXXX")
          { (cd "$project_root" && BATS_REPORT_FILENAME=report.tap \
              "${_bats_sandbox[@]}" "${_bats_watchdog[@]+"${_bats_watchdog[@]}"}" \
              bats -F pretty --report-formatter tap --output "$_ser_tap_dir" \
              "${_serial_files[@]+"${_serial_files[@]}"}") \
              < /dev/null 2>&1; \
            echo $? > "$_bats_exit_file"; } \
            | tee -a "$_bats_pretty_capture" >> "$_gate_raw_sink" || true
          cat "$_ser_tap_dir/report.tap" >> "$_tests_raw_file" 2>/dev/null || true
          rm -rf "$_ser_tap_dir"
        else
          { (cd "$project_root" && "${_bats_sandbox[@]}" "${_bats_watchdog[@]+"${_bats_watchdog[@]}"}" \
              bats "${_serial_files[@]+"${_serial_files[@]}"}" < /dev/null 2>&1); echo $? > "$_bats_exit_file"; } \
            | tee -a "$_tests_raw_file" >> "$_gate_raw_sink" || true
        fi
        _ser_exit=$(cat "$_bats_exit_file" 2>/dev/null || echo 1)
        _ser_exit=${_ser_exit:-1}  # empty = killed before writing = failure (#935)
        if [ "$_ser_exit" = "124" ] || [ "$_ser_exit" = "137" ]; then
          _gate_status "[test-gate] bats (serial group) killed by whole-run watchdog after ${_gate_bats_timeout}s (RITE_GATE_BATS_TIMEOUT)"
          _diag "TEST_GATE_WATCHDOG_KILL group=serial timeout_s=${_gate_bats_timeout} pr=${PR_NUMBER:-?}"
          _fr_watchdog=true
          _watchdog_group="${_watchdog_group:+${_watchdog_group}+}serial"
        fi
      fi

      # Merge exit codes: any non-zero fails the gate (block-on-any preserved)
      if [ "$_par_exit" -ne 0 ] || [ "$_ser_exit" -ne 0 ]; then
        echo 1 > "$_bats_exit_file"
      else
        echo 0 > "$_bats_exit_file"
      fi
    fi
    fi  # end _bats_skip guard
    _tests_exit=$(cat "$_bats_exit_file" 2>/dev/null || echo 1)
    _tests_exit=${_tests_exit:-1}  # empty = killed before writing = failure (#935)
    # Watchdog kill on the full-suite path (par/ser groups note it above and
    # merge their exits to 0/1, so 124/137 here can only come from full-suite).
    if [ "$_tests_exit" = "124" ] || [ "$_tests_exit" = "137" ]; then
      _gate_status "[test-gate] bats (full suite) killed by whole-run watchdog after ${_gate_bats_timeout}s (RITE_GATE_BATS_TIMEOUT)"
      _diag "TEST_GATE_WATCHDOG_KILL group=full timeout_s=${_gate_bats_timeout} pr=${PR_NUMBER:-?}"
      _fr_watchdog=true
      _watchdog_group="full"
      _tests_exit=1
    fi

    # --- Flake retry (#938): one bounded serial re-run of failing files ------
    # Guards: real failure only (not watchdog kills — a timeout is not a flake),
    # targeted-selection path only (the function skips when no selection), and
    # RITE_GATE_FLAKE_RETRY=false as the operator off-switch.
    if [ "${_tests_exit:-1}" -ne 0 ] \
       && [ "$_tests_exit" != "124" ] && [ "$_tests_exit" != "137" ] \
       && [ "${_fr_watchdog:-false}" != "true" ] \
       && [ "${RITE_GATE_FLAKE_RETRY:-true}" = "true" ]; then
      _tests_exit=$(_gate_flake_retry_pass "$_tests_raw_file" "$project_root")
      _tests_exit=${_tests_exit:-1}
    fi

    # Clean up tap dir if used (never a glob — scoped to this invocation's pid-named dir)
    [ -n "${_bats_tap_dir:-}" ] && rm -rf "${_bats_tap_dir:-}"

    rm -f "$_sc_exit_file" "$_lint_exit_file" "$_bats_exit_file"
    _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)

    # --- Plan-vs-executed mismatch: synthesize not-run findings (issue #804) ---
    # bats-core 1.13 exits non-zero when fewer tests execute than the 1..N plan
    # even with 0 reported failures, and not-run tests write NOTHING to
    # report.tap — so a swallowed test yields exit_code=1 with test_count=0 and
    # the fix loop gets zero nameable findings (four blind rounds on PR #828).
    # Detect the mismatch (TAP plan deficit and/or the literal bats warning in
    # the captured pretty stream) and emit synthetic not-ok findings, following
    # the synthetic-TAP precedent (workspace_build_failed below).
    #
    # Run deficit detection for ANY non-zero bats exit — not only when
    # _tests_count=0 (issue #847). A run with both real `not ok` findings AND a
    # swallowed test has _tests_count>0, so the old `&& [ _tests_count -eq 0 ]`
    # guard silently skipped deficit detection and left the swallowed names
    # invisible to the fix loop. The inner guard (`_notrun_deficit -gt 0 ||
    # -n _notrun_warning`) already ensures we only synthesize findings when a
    # real plan/executed mismatch exists — the outer count gate is redundant and
    # incorrect in the mixed case.
    if [ "$_tests_exit" -ne 0 ]; then
      local _notrun_deficit _notrun_warning="" _notrun_named=0 _notrun_emitted=0
      _notrun_deficit=$(_tap_plan_deficit "$_tests_raw_file")
      if [ -n "${_bats_pretty_capture:-}" ] && [ -s "${_bats_pretty_capture:-}" ]; then
        _notrun_warning=$(grep -oE 'Executed [0-9]+ instead of expected [0-9]+ tests' \
          "$_bats_pretty_capture" | head -1 || true)
      fi
      if [ "$_notrun_deficit" -gt 0 ] || [ -n "$_notrun_warning" ] || [ "${_fr_watchdog:-false}" = "true" ]; then
        if [ "${_fr_watchdog:-false}" = "true" ]; then
          # Watchdog kill: collapse all not-run tests into ONE finding.
          # Genuinely failed tests from completed bats sections keep their
          # per-test findings (already in _tests_raw_file). The N not-run
          # tests become a single item so the fix session's proportional
          # timeout math (300+240×count) sees the real actionable count,
          # not a synthetic flood (issue #1130, live: batch 20261011-174713
          # slot #1021 — 690 not-run findings buried 5 real ones).
          local _wdog_n _eff_deficit
          _wdog_n=$(grep -c "^not ok " "$_tests_raw_file" || true)
          _wdog_n=$(( _wdog_n + 1 ))
          _eff_deficit="${_notrun_deficit:-0}"
          [ "$_eff_deficit" -le 0 ] && _eff_deficit=1
          printf 'not ok %s [tests_not_run] watchdog killed %s group after %ss — %s tests not run; root cause is gate runtime, not the tests (reduce selection cost: add # sharkrite-gate-serial to load-heavy files, or scope lint rules with SHARKRITE_LINT_ONLY=N)\n' \
            "$_wdog_n" "${_watchdog_group:-bats}" "$_gate_bats_timeout" "$_eff_deficit" \
            >> "$_tests_raw_file"
          _gate_status "[test-gate] bats: watchdog killed ${_watchdog_group:-bats} group after ${_gate_bats_timeout}s — ${_eff_deficit} not-run tests collapsed into 1 [GATE] finding (root cause: gate timeout, not the tests)"
          _gate_reason="tests_not_run"
          _diag "TEST_GATE_NOTRUN deficit=${_notrun_deficit} named=0 emitted=1 pr=${PR_NUMBER:-?}"
          _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)
        else
          # Normal not-run path: names come from a set difference of planned
          # @test descriptions (from the SELECTED bats files) minus TAP result
          # lines — never from the pretty stream, whose width-truncated begin
          # lines produced the 130-phantom event (PR #852) and which interleaves
          # under --jobs and mismatched begin/result pairs (130 phantom findings
          # for a deficit of 1 on PR #852; issue #862). Finding count is capped
          # at the bats-reported deficit inside _synthesize_notrun_findings.
          local _notrun_files_list _notrun_summary
          _notrun_files_list=$(mktemp "/tmp/rite_gate_notrun_f_${PR_NUMBER:-0}_$$_XXXXXX")
          if [ "$_selection" = "FORCE_FULL" ]; then
            # Mirror `bats -r tests/`: every .bats file under tests/ was planned.
            (cd "$project_root" && find tests -name '*.bats' -type f 2>/dev/null | sort) \
              > "$_notrun_files_list" || true
          else
            printf '%s\n' "$_selection" > "$_notrun_files_list"
          fi
          _notrun_summary=$(_synthesize_notrun_findings "$_tests_raw_file" \
            "$_notrun_files_list" "$_notrun_deficit" "$project_root" "$_notrun_warning")
          rm -f "$_notrun_files_list"
          _notrun_named=$(echo "$_notrun_summary" | grep -oE 'named=[0-9]+' | cut -d= -f2 || true)
          _notrun_emitted=$(echo "$_notrun_summary" | grep -oE 'emitted=[0-9]+' | cut -d= -f2 || true)
          if [ "${_notrun_named:-0}" -gt 0 ]; then
            _gate_status "[test-gate] bats: ${_notrun_named} planned test(s) never ran (${_notrun_warning:-plan/executed mismatch}) — emitting synthetic tests_not_run finding(s)"
          else
            _gate_status "[test-gate] bats: plan/executed mismatch with unresolvable test names — emitting ${_notrun_emitted:-0} synthetic tests_not_run finding(s) capped at the reported deficit"
          fi
          _gate_reason="tests_not_run"
          _diag "TEST_GATE_NOTRUN deficit=${_notrun_deficit} named=${_notrun_named:-0} emitted=${_notrun_emitted:-0} pr=${PR_NUMBER:-?}"
          _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)
        fi
      fi
    fi
  else
    # Non-Sharkrite: best-effort detection (npm test / make test / pytest / cargo / go)
    # For non-Sharkrite repos the gate runs whatever the manifest implies.
    local _nonsr_exit_file
    _nonsr_exit_file=$(mktemp "/tmp/rite_gate_nonsr_exit_${PR_NUMBER:-0}_$$_XXXXXX")

    # Detect whether this PR touched source files for use in loud-skip below.
    # Source = any non-docs/non-config change. A simple heuristic: any changed
    # path that isn't docs/, README, LICENSE, *.md, *.txt, *.conf, .gitignore.
    # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: cold-start default for direct/CI invocation; run_workflow seeds origin/<target> per #1037, operator env (RITE_TEST_GATE_DIFF_BASE) still wins
    local _nonsr_diff_base="${RITE_TEST_GATE_DIFF_BASE:-origin/main}"
    local _nonsr_changed_files _nonsr_source_touched=false
    _nonsr_changed_files=$(cd "$project_root" && git diff --name-only "$_nonsr_diff_base"...HEAD 2>/dev/null || true)
    if [ -n "$_nonsr_changed_files" ]; then
      # If any changed file does not match docs/*, *.md, *.txt, *.conf, README*, LICENSE*
      # then source was touched. Use grep -v to filter out non-source paths.
      local _nonsr_src
      _nonsr_src=$(printf '%s\n' "$_nonsr_changed_files" \
        | grep -vE '(^docs/|\.md$|\.txt$|\.conf$|^README|^LICENSE|\.(gitignore|yml|yaml)$)' || true)
      [ -n "$_nonsr_src" ] && _nonsr_source_touched=true
    fi

    if [ -f "$project_root/Makefile" ] && grep -q "^test:" "$project_root/Makefile" 2>/dev/null; then
      echo "[test-gate] Running make test..."
      # Capture to raw file for JSON parsing AND append to sink (summary → log;
      # verbose → live terminal). Two-channel convention: raw appended directly.
      { (cd "$project_root" && make test 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 1)
      _tests_exit=${_tests_exit:-1}  # empty = child killed before writing = failure (#935; LeadFlow Terminated-15 crash)
      # Missing-deps / no-tests-collected fallback for Makefile-wrapped pytest.
      # When make test delegates to python3 -m pytest, a missing venv exits
      # non-zero with ModuleNotFoundError — that's an env gap, not a test failure.
      # Exit 5 (no tests collected) from a wrapped pytest also bubbles through
      # make as a non-zero exit and should be a loud skip rather than a hard block.
      #
      # Pytest-context guard: only apply _classify_pytest_outcome when the make
      # test recipe actually delegates to pytest/python.  Without this guard, a
      # non-pytest make target whose failure happens to contain a "No module named"
      # string (e.g. a missing app dependency imported at startup) would be
      # misclassified as skipped:missing_deps and pass the gate green — a
      # false-skip that lets a broken merge through.
      #
      # Two signals (either is sufficient):
      #   1. The test: recipe references python/pytest (cheap; checked first).
      #   2. The captured output contains a pytest session banner (covers
      #      multi-step recipes that call pytest indirectly).
      local _make_is_pytest_context=false
      local _make_recipe
      _make_recipe=$(awk '/^test:/{found=1;next} found && /^\t/{print;next} found{exit}' \
        "$project_root/Makefile" 2>/dev/null || true)
      if echo "$_make_recipe" | grep -qiE '(pytest|python3?[[:space:]]+-m[[:space:]]+pytest|python3?)'; then
        _make_is_pytest_context=true
      elif [ -f "$_tests_raw_file" ] && \
           grep -qE '(=====.*test session starts|platform .* pytest|collected [0-9]+ item)' \
           "$_tests_raw_file" 2>/dev/null; then
        _make_is_pytest_context=true
      fi
      if [ "$_tests_exit" -ne 0 ] && [ "$_make_is_pytest_context" = "true" ]; then
        local _make_raw _make_outcome
        _make_raw=$(cat "$_tests_raw_file" 2>/dev/null || true)
        # Unwrap make's exit before classifying: make maps ANY failing recipe
        # to its own exit 2, which _classify_pytest_outcome (correctly, per
        # pytest's exit-code table) reads as "collection error → failed" —
        # so a wrapped missing-venv (pytest exit 1) or no-tests (exit 5) was
        # never classified as a skip. The recipe's real exit is in make's
        # "*** [target] Error N" line; fall back to make's exit when absent.
        local _make_inner_exit
        _make_inner_exit=$(printf '%s\n' "$_make_raw" \
          | grep -oE '\*\*\* \[[^]]*\] Error [0-9]+' | head -1 \
          | grep -oE '[0-9]+$' || true)
        _make_outcome=$(_classify_pytest_outcome "${_make_inner_exit:-$_tests_exit}" "$_make_raw")
        if [ "$_make_outcome" = "skipped:missing_deps" ]; then
          echo "[test-gate] WARNING: make test detected missing dependencies (ModuleNotFoundError)." >&2
          echo "[test-gate] Install the project's test dependencies (e.g. pip install -r requirements-dev.txt) or set RITE_TEST_COMMAND to a wrapper that activates the venv." >&2
          _diag "TEST_GATE outcome=skipped reason=missing_deps pr=${PR_NUMBER:-?}"
          rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
          trap - EXIT
          _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_deps"
          return 0
        elif [ "$_make_outcome" = "skipped:no_tests" ]; then
          echo "[test-gate] WARNING: make test collected no tests (exit 5)." >&2
          echo "[test-gate] Add test files or set RITE_TEST_COMMAND to skip this check." >&2
          _diag "TEST_GATE outcome=skipped reason=no_tests pr=${PR_NUMBER:-?}"
          rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
          trap - EXIT
          _gate_write_json "$output_file" "[]" "[]" "0" "true" "no_tests"
          return 0
        fi
      fi
    elif [ -f "$project_root/package.json" ]; then
      # node_modules bootstrap (issue #784, #807): rite worktrees never get a real
      # node_modules of their own — claude-workflow.sh symlinks the worktree's
      # node_modules to main's. Without the test runner present, `npm test` invokes
      # a missing jest/mocha and exits 127 — which the gate would otherwise record
      # as a real test failure for tests that never ran. Bootstrap deps first,
      # mirroring post-merge-verify.sh's npm ci/install pattern.
      #
      # #807: gate the bootstrap on RUNNER RESOLVABILITY, not node_modules
      # existence. The old `[ ! -d node_modules ]` guard was satisfied by the
      # worktree→main symlink (it follows the link), so the bootstrap SKIPPED even
      # when main's node_modules lacked the devDep runner — flooding the gate with
      # runner_unavailable (exit 127) on every node issue. Install when the runner
      # is NOT resolvable, even if node_modules "exists" (symlink); skip when it
      # already resolves (no redundant work).
      #
      # Best-effort (|| true): a bootstrap FAILURE is caught by the 127 hard-block
      # below, not by aborting here. Output goes to the run log (_gate_raw_sink),
      # not the findings file — it is not a test result.
      #
      # #818: the root-runner resolvability check above is WRONG-GRANULARITY for
      # an npm-WORKSPACES monorepo. Its root test script is a delegator
      # (`npm run test --workspaces --if-present`), so _resolve_node_test_runner
      # yields `npm`/bails and _node_runner_resolvable falls to the "root .bin
      # non-empty → resolvable" heuristic — SKIPPING the bootstrap while the
      # WORKSPACE packages' runners (jest/vitest per sub-package) are never
      # installed → `jest: command not found` (127). For a workspaces monorepo we
      # do NOT trust the root-.bin heuristic: we bootstrap unless we can
      # positively confirm every workspace runner already resolves. `npm ci`
      # installs all workspace devDeps and hoists shared bins to root/.bin, which
      # is what the per-workspace test scripts need.
      local _node_runner _node_needs_bootstrap=false
      _node_runner=$(_resolve_node_test_runner "$project_root")
      if _node_is_workspaces_monorepo "$project_root"; then
        # #818: bootstrap when workspace runners are not resolvable.
        # #822: ALSO bootstrap when runners resolve but a workspace package's
        # compiled entry point (main/exports → dist/) is absent — the runner
        # existing does not prove that imports resolve (one level deeper proxy).
        # This was the false-negative that let stale worktrees skip bootstrap
        # forever: node_modules/.bin/jest ✓, @leadflow/shared/dist/ ✗.
        if _node_workspace_runners_resolvable "$project_root" \
           && ! _node_workspace_has_missing_entry_points "$project_root"; then
          echo "[test-gate] workspaces monorepo: all workspace runners resolvable and entry points present — skipping bootstrap" >> "$_gate_raw_sink"
        elif ! _node_workspace_runners_resolvable "$project_root"; then
          echo "[test-gate] workspaces monorepo: a workspace test runner is not resolvable (or could not be confirmed) — bootstrapping all workspace dependencies before npm test..." >> "$_gate_raw_sink"
          _node_needs_bootstrap=true
        else
          # Runners resolvable but a compiled entry point is missing — need
          # install + build, not install alone (build step follows below).
          echo "[test-gate] workspaces monorepo: workspace runners resolvable but a compiled entry point is missing — bootstrapping and building before npm test..." >> "$_gate_raw_sink"
          _node_needs_bootstrap=true
        fi
      elif ! _node_runner_resolvable "$project_root" "$_node_runner"; then
        # Single-package #807 path — unchanged.
        echo "[test-gate] test runner '${_node_runner:-unknown}' not resolvable — bootstrapping dependencies before npm test..." >> "$_gate_raw_sink"
        _node_needs_bootstrap=true
      fi
      if [ "$_node_needs_bootstrap" = "true" ]; then
        # De-symlink BEFORE either install path: npm ci/install through a
        # symlinked node_modules destroys the symlink TARGET (main's
        # node_modules) before reifying a real dir in its place.
        _node_desymlink_node_modules "$project_root"
        # Package-manager-aware install (issue #1097): pnpm repos get
        # `pnpm install --frozen-lockfile` (never npm — it ignores
        # pnpm-workspace.yaml and writes a stray package-lock.json);
        # npm repos keep the historical ci/install split.
        _node_install_deps "$project_root" "$_gate_raw_sink"
        # Re-check after the bootstrap (informational). If still unresolvable we do
        # nothing special here — `npm test` runs below and the existing 127
        # hard-block fires, blocking the merge. No new block path is added. For a
        # workspaces monorepo the per-workspace re-check is the meaningful one; the
        # root-runner re-check is retained only for the single-package path.
        if _node_is_workspaces_monorepo "$project_root"; then
          if ! _node_workspace_runners_resolvable "$project_root"; then
            echo "[test-gate] a workspace test runner is still not resolvable after bootstrap — npm test will run and the 127 hard-block will fire if it is genuinely missing" >> "$_gate_raw_sink"
          fi
        elif ! _node_runner_resolvable "$project_root" "$_node_runner"; then
          echo "[test-gate] test runner '${_node_runner:-unknown}' still not resolvable after bootstrap — npm test will run and the 127 hard-block will fire if it is genuinely missing" >> "$_gate_raw_sink"
        fi
      fi
      # #822: after install (or even without it, when runners were already
      # resolvable but entry points were missing), build any workspace package
      # whose compiled entry point is still absent.  This is the fix for the
      # LeadFlow outage: dist/ must exist before `npm test` delegates to the
      # per-workspace test scripts that import compiled artifacts.
      #
      # Build failures are loud and blocking — surfaced as a [GATE] finding
      # so assess-and-resolve.sh creates an ACTIONABLE_NOW item.  Never a
      # silent fall-through.
      if _node_is_workspaces_monorepo "$project_root" \
         && _node_workspace_has_missing_entry_points "$project_root"; then
        echo "[test-gate] workspaces monorepo: building workspace packages with missing compiled entry points..." >> "$_gate_raw_sink"
        if ! _node_build_workspace_packages "$project_root" "$_gate_raw_sink"; then
          echo "[test-gate] ERROR: one or more workspace package builds failed — blocking gate" >&2
          _diag "TEST_GATE outcome=failed reason=workspace_build_failed pr=${PR_NUMBER:-?}"
          # Emit a TAP not-ok line so the JSON tests[] array carries the item
          # and assess-and-resolve.sh synthesises an ACTIONABLE_NOW finding.
          printf 'not ok 1 - workspace package build failed (entry point missing after build)\n' \
            >> "$_tests_raw_file"
          _tests_exit=1
          _gate_reason="workspace_build_failed"
        else
          echo "[test-gate] workspaces monorepo: all workspace builds succeeded" >> "$_gate_raw_sink"
        fi
      fi
      # #975: Per-cycle scoped gating for workspaces monorepos — only changed
      # workspaces, with framework-native diff scoping (jest --findRelatedTests
      # / vitest related).  There is deliberately NO "merge tier" that falls back
      # to the full root suite: a full unfiltered suite never runs inside a
      # workflow (CLAUDE.md standing rule); the overnight pipeline owns that.
      local _skip_root_npm_test=false
      if [ "${RITE_GATE_FORCE_FULL:-}" != "1" ] \
         && _node_is_workspaces_monorepo "$project_root" \
         && [ "${_gate_reason:-}" != "workspace_build_failed" ]; then
        local _ws_pm
        _ws_pm=$(_node_pkg_manager "$project_root")
        local _ws_affected
        _ws_affected=$(_changed_files_to_workspace_dirs "$project_root" "$_nonsr_changed_files")
        if [ -z "$_ws_affected" ]; then
          echo "[test-gate] per-cycle: no workspace source changed — skipping workspace tests" >> "$_gate_raw_sink"
          # _skip_root_npm_test remains false — root npm test still runs for non-workspace changes
        else
          _skip_root_npm_test=true
          _ran_scoped_cycle=true
          local _ws_any_fail=false _ws_item
          while IFS= read -r _ws_item; do
            [ -n "$_ws_item" ] || continue
            local _ws_rel="$_ws_item"
            local _ws_dir="$project_root/$_ws_rel"
            [ -d "$_ws_dir" ] || continue
            local _ws_rel_files
            _ws_rel_files=$(printf '%s\n' "$_nonsr_changed_files" | grep "^${_ws_rel}/" | grep -v '^$' || true)
            local _ws_runner
            _ws_runner=$(_detect_workspace_runner "$_ws_dir")
            local _ws_exit_f _ws_raw_f
            _ws_exit_f=$(mktemp "/tmp/rite_gate_wsex_${PR_NUMBER:-0}_$$_XXXXXX")
            _ws_raw_f=$(mktemp "/tmp/rite_gate_wsraw_${PR_NUMBER:-0}_$$_XXXXXX")
            local _ws_test_exit=0
            if [ "${RITE_GATE_NATIVE_SCOPING:-true}" != "false" ] && [ "$_ws_runner" != "unknown" ]; then
              case "$_ws_runner" in
                jest)
                  echo "[test-gate] per-cycle: jest --findRelatedTests for workspace '$_ws_rel'" >> "$_gate_raw_sink"
                  local _ws_abs_files="" _wfa
                  while IFS= read -r _wfa; do
                    [ -n "$_wfa" ] || continue
                    _ws_abs_files="${_ws_abs_files} ${project_root}/${_wfa}"
                  done < <(printf '%s\n' "$_ws_rel_files")
                  _ws_abs_files="${_ws_abs_files## }"
                  if [ "$_ws_pm" = "pnpm" ]; then
                    # shellcheck disable=SC2086
                    { (cd "$project_root" && pnpm --filter="./${_ws_rel}" test -- --findRelatedTests $_ws_abs_files --passWithNoTests 2>&1); echo $? > "$_ws_exit_f"; } \
                      | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                  else
                    # shellcheck disable=SC2086
                    { (cd "$project_root" && npm test --workspace="$_ws_rel" -- --findRelatedTests $_ws_abs_files --passWithNoTests 2>&1); echo $? > "$_ws_exit_f"; } \
                      | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                  fi
                  _ws_test_exit=$(cat "$_ws_exit_f" 2>/dev/null || echo 1)
                  _ws_test_exit=${_ws_test_exit:-1}
                  # Sanity valve: 0 tests selected with non-test source → workspace full suite.
                  if [ "$_ws_test_exit" -eq 0 ] && _node_scope_zero_tests "$_ws_raw_f"; then
                    local _ws_nts
                    _ws_nts=$(printf '%s\n' "$_ws_rel_files" \
                      | grep -vE '(\.(test|spec)\.(ts|tsx|js|jsx)$|/__tests__/|/tests?/)' \
                      | grep -v '^$' || true)
                    if [ -n "$_ws_nts" ]; then
                      echo "[test-gate] per-cycle: jest selected 0 tests with non-test source — falling back to workspace full suite" >> "$_gate_raw_sink"
                      : > "$_ws_raw_f"
                      if [ "$_ws_pm" = "pnpm" ]; then
                        { (cd "$project_root" && pnpm --filter="./${_ws_rel}" test 2>&1); echo $? > "$_ws_exit_f"; } \
                          | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                      else
                        { (cd "$project_root" && npm test --workspace="$_ws_rel" 2>&1); echo $? > "$_ws_exit_f"; } \
                          | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                      fi
                      _ws_test_exit=$(cat "$_ws_exit_f" 2>/dev/null || echo 1)
                      _ws_test_exit=${_ws_test_exit:-1}
                    fi
                  fi
                  ;;
                vitest)
                  echo "[test-gate] per-cycle: vitest related for workspace '$_ws_rel'" >> "$_gate_raw_sink"
                  local _ws_vf_files="" _wfv
                  while IFS= read -r _wfv; do
                    [ -n "$_wfv" ] || continue
                    _ws_vf_files="${_ws_vf_files} ${_wfv#"${_ws_rel}/"}"
                  done < <(printf '%s\n' "$_ws_rel_files")
                  _ws_vf_files="${_ws_vf_files## }"
                  # shellcheck disable=SC2086
                  { (cd "$_ws_dir" && npx vitest related $_ws_vf_files --run 2>&1); echo $? > "$_ws_exit_f"; } \
                    | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                  _ws_test_exit=$(cat "$_ws_exit_f" 2>/dev/null || echo 1)
                  _ws_test_exit=${_ws_test_exit:-1}
                  # Sanity valve
                  if [ "$_ws_test_exit" -eq 0 ] && _node_scope_zero_tests "$_ws_raw_f"; then
                    local _ws_nts2
                    _ws_nts2=$(printf '%s\n' "$_ws_rel_files" \
                      | grep -vE '(\.(test|spec)\.(ts|tsx|js|jsx)$|/__tests__/|/tests?/)' \
                      | grep -v '^$' || true)
                    if [ -n "$_ws_nts2" ]; then
                      echo "[test-gate] per-cycle: vitest selected 0 tests with non-test source — falling back to workspace full suite" >> "$_gate_raw_sink"
                      : > "$_ws_raw_f"
                      if [ "$_ws_pm" = "pnpm" ]; then
                        { (cd "$project_root" && pnpm --filter="./${_ws_rel}" test 2>&1); echo $? > "$_ws_exit_f"; } \
                          | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                      else
                        { (cd "$project_root" && npm test --workspace="$_ws_rel" 2>&1); echo $? > "$_ws_exit_f"; } \
                          | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
                      fi
                      _ws_test_exit=$(cat "$_ws_exit_f" 2>/dev/null || echo 1)
                      _ws_test_exit=${_ws_test_exit:-1}
                    fi
                  fi
                  ;;
              esac
            else
              # Unknown runner or native scoping disabled — workspace full suite.
              echo "[test-gate] per-cycle: workspace '$_ws_rel' full suite (runner: ${_ws_runner}, native-scoping: ${RITE_GATE_NATIVE_SCOPING:-true})" >> "$_gate_raw_sink"
              if [ "$_ws_pm" = "pnpm" ]; then
                { (cd "$project_root" && pnpm --filter="./${_ws_rel}" test 2>&1); echo $? > "$_ws_exit_f"; } \
                  | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
              else
                { (cd "$project_root" && npm test --workspace="$_ws_rel" 2>&1); echo $? > "$_ws_exit_f"; } \
                  | tee -a "$_ws_raw_f" >> "$_gate_raw_sink" || true
              fi
              _ws_test_exit=$(cat "$_ws_exit_f" 2>/dev/null || echo 1)
              _ws_test_exit=${_ws_test_exit:-1}
            fi
            rm -f "$_ws_exit_f"
            if [ "$_ws_test_exit" -ne 0 ]; then
              _normalize_node_test_output "$_ws_raw_f" "$project_root"
            fi
            cat "$_ws_raw_f" >> "$_tests_raw_file"
            rm -f "$_ws_raw_f"
            [ "$_ws_test_exit" -ne 0 ] && _ws_any_fail=true
          done < <(printf '%s\n' "$_ws_affected")
          [ "$_ws_any_fail" = "true" ] && _tests_exit=1
        fi
      fi
      if [ "$_skip_root_npm_test" = "false" ]; then
        echo "[test-gate] Running npm test..."
        # Preserve any non-zero _tests_exit from the workspace build step above:
        # merge rather than overwrite so both build failures and test failures block.
        local _npm_test_prior_exit="$_tests_exit"
        { (cd "$project_root" && npm test 2>&1); echo $? > "$_nonsr_exit_file"; } \
          | tee -a "$_tests_raw_file" >> "$_gate_raw_sink" || true
        _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 1)
        _tests_exit=${_tests_exit:-1}  # empty = child killed before writing = failure (#935; LeadFlow Terminated-15 crash)
        [ "$_npm_test_prior_exit" -eq 0 ] || _tests_exit=1
        # jest/vitest never emit TAP: without normalization a real failure
        # yields test_count=0 and an empty tests[] array, so the fix session
        # gets no failing test names (LeadFlow PR #587). Synthesize not-ok
        # lines so the ^not ok count and JSON loop below see the failures.
        if [ "$_tests_exit" -ne 0 ]; then
          _normalize_node_test_output "$_tests_raw_file" "$project_root"
        fi
      fi
    elif [ -f "$project_root/pytest.ini" ] || [ -d "$project_root/tests" ]; then
      # Provision pytest-testmon for per-cycle scoped gating (#1127 / #975).
      # Only when native scoping is enabled; failure degrades to unscoped (#1125).
      if [ "${RITE_GATE_NATIVE_SCOPING:-true}" != "false" ]; then
        if ! _provision_pytest_testmon "$project_root" "$_gate_raw_sink"; then
          print_warning "[test-gate] pytest-testmon unavailable — running unscoped (see sharkrite #975 / #1125)"
        fi
      fi
      echo "[test-gate] Running pytest..."
      { (cd "$project_root" && python3 -m pytest 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 1)
      _tests_exit=${_tests_exit:-1}  # empty = child killed before writing = failure (#935; LeadFlow Terminated-15 crash)
      # Classify the pytest run to distinguish env failures from real failures.
      # A missing dep or no-tests-collected result is a loud skip, not a failure.
      # Real failures (including ones whose tracebacks mention ModuleNotFoundError)
      # leave _tests_exit non-zero so the gate blocks as normal.
      local _pytest_raw _pytest_outcome
      _pytest_raw=$(cat "$_tests_raw_file" 2>/dev/null || true)
      _pytest_outcome=$(_classify_pytest_outcome "$_tests_exit" "$_pytest_raw")
      if [ "$_pytest_outcome" = "skipped:missing_deps" ]; then
        echo "[test-gate] WARNING: pytest detected missing dependencies (ModuleNotFoundError)." >&2
        echo "[test-gate] Install the project's test dependencies (e.g. pip install -r requirements-dev.txt) or set RITE_TEST_COMMAND to a wrapper that activates the venv." >&2
        _diag "TEST_GATE outcome=skipped reason=missing_deps pr=${PR_NUMBER:-?}"
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
        trap - EXIT
        _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_deps"
        return 0
      elif [ "$_pytest_outcome" = "skipped:no_tests" ]; then
        echo "[test-gate] WARNING: pytest collected no tests (exit 5)." >&2
        echo "[test-gate] Add test files or set RITE_TEST_COMMAND to skip this check." >&2
        _diag "TEST_GATE outcome=skipped reason=no_tests pr=${PR_NUMBER:-?}"
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
        trap - EXIT
        _gate_write_json "$output_file" "[]" "[]" "0" "true" "no_tests"
        return 0
      fi
      # outcome=passed or outcome=failed — leave _tests_exit as captured above.
    elif [ -f "$project_root/Cargo.toml" ]; then
      if ! command -v cargo >/dev/null 2>&1; then
        # cargo not installed — loud skip with toolchain hint (missing runner, not a failure)
        echo "[test-gate] WARNING: Cargo.toml detected but 'cargo' is not installed." >&2
        echo "[test-gate] Install the Rust toolchain (https://rustup.rs) or set RITE_TEST_COMMAND to a wrapper script." >&2
        _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
        trap - EXIT
        _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
        return 0
      fi
      echo "[test-gate] Running cargo test..."
      { (cd "$project_root" && cargo test 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 1)
      _tests_exit=${_tests_exit:-1}  # empty = child killed before writing = failure (#935; LeadFlow Terminated-15 crash)
    elif [ -f "$project_root/go.mod" ]; then
      if ! command -v go >/dev/null 2>&1; then
        # go not installed — loud skip with toolchain hint (missing runner, not a failure)
        echo "[test-gate] WARNING: go.mod detected but 'go' is not installed." >&2
        echo "[test-gate] Install the Go toolchain (https://go.dev/dl) or set RITE_TEST_COMMAND to a wrapper script." >&2
        _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
        trap - EXIT
        _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
        return 0
      fi
      echo "[test-gate] Running go test ./..."
      { (cd "$project_root" && go test ./... 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 1)
      _tests_exit=${_tests_exit:-1}  # empty = child killed before writing = failure (#935; LeadFlow Terminated-15 crash)
    elif (cd "$project_root" && _has_ino=false; for _f in ./*.ino; do [ -e "$_f" ] && { _has_ino=true; break; }; done; [ "$_has_ino" = true ]); then
      # Arduino sketch detected — arduino-cli/pio requires board config; skip with hint.
      # This is a loud skip: we know source exists but cannot run verification
      # without target board configuration. Set RITE_TEST_COMMAND to use pio/arduino-cli.
      echo "[test-gate] WARNING: Arduino sketch detected (.ino) but no test runner configured." >&2
      echo "[test-gate] Set RITE_TEST_COMMAND=\"pio test\" or RITE_TEST_COMMAND=\"arduino-cli compile --fqbn <board>\" to enable verification." >&2
      _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
      rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
      trap - EXIT
      _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
      return 0
    else
      # No recognizable test runner — skip, but warn loudly if source was touched.
      _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
      if [ "$_nonsr_source_touched" = "true" ]; then
        echo "[test-gate] WARNING: No test runner detected and this PR touches source files." >&2
        echo "[test-gate] Set RITE_TEST_COMMAND in .rite/config (e.g. RITE_TEST_COMMAND=\"./run-tests.sh\") to enable verification." >&2
        echo "[test-gate] Gate skipped — merge proceeds with review findings only. This is a fake-green." >&2
      fi
      rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_nonsr_exit_file:-}"
      trap - EXIT
      _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
      return 0
    fi
    rm -f "${_nonsr_exit_file:-}"

    # --- 127 = runner-unavailable HARD BLOCK (issue #784) ---
    # Shared guard for the non-Sharkrite runner branches that actually ran a
    # command (make/npm/cargo/go/pytest fall through to here; the skip branches
    # above all return 0 first). Exit 127 — or a "command not found" signature
    # in the captured output — means the test runner itself was unavailable
    # (e.g. node_modules bootstrap failed and jest is missing). The gate could
    # NOT verify, so this MUST BLOCK the merge — never a skip, never a pass.
    # A skip-that-passes ships breaks (Pilot's correction on #784). Force
    # _tests_exit non-zero so block-on-any blocks downstream.
    if [ "${_tests_exit:-0}" -eq 127 ] \
       || grep -qE '(command not found|: not found)' "$_tests_raw_file" 2>/dev/null; then
      echo "[test-gate] ERROR: node test runner unavailable (exit ${_tests_exit:-127}) after node_modules bootstrap — the gate could NOT verify; blocking the merge" >&2
      _diag "TEST_GATE outcome=failed reason=runner_unavailable pr=${PR_NUMBER:-?}"
      # Ensure a non-zero exit so the block-on-any logic below blocks.
      [ "${_tests_exit:-0}" -eq 0 ] && _tests_exit=127
      # Record the named reason so the gate JSON includes it; assess-and-resolve.sh
      # uses this to synthesize a descriptive [GATE] blocking item when the TAP
      # parser yields an empty tests[] array (no ^not ok lines to parse).
      # Only set reason if not already classified (e.g. workspace_build_failed
      # set it above; a "not found" in npm output must not clobber that label).
      [ -n "${_gate_reason:-}" ] || _gate_reason="runner_unavailable"
    fi

    _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)
  fi

  # --- Capture terminal-digest inputs before raw files are removed ---
  # Block-on-any: every failure blocks, so name them all.
  local _bats_pass=0 _bats_fail_total=0 _summary_names=""
  local _nonsr_fail_count=0 _nonsr_fail_names=""
  if [ "$_is_sharkrite" = "true" ]; then
    _bats_pass=$(grep -c "^ok " "$_tests_raw_file" 2>/dev/null || true)
    _bats_fail_total=$(grep -c "^not ok " "$_tests_raw_file" 2>/dev/null || true)
    if [ "$_bats_fail_total" -gt 0 ]; then
      _summary_names=$(_extract_tap_failure_names "$_tests_raw_file")
    fi
  else
    # Non-Sharkrite: capture TAP failure names before the file is deleted below.
    _nonsr_fail_count=$(grep -c "^not ok " "$_tests_raw_file" 2>/dev/null || true)
    if [ "$_nonsr_fail_count" -gt 0 ]; then
      _nonsr_fail_names=$(_extract_tap_failure_names "$_tests_raw_file")
    fi
  fi

  # Capture HEAD SHA for verdict SHA-pinning (#986) before raw file cleanup.
  # Readers (assess-and-resolve.sh) verify this SHA against the PR's current
  # HEAD before consuming a passing verdict — a PASS from a superseded commit
  # must not authorize a merge or phase-skip at a later SHA.
  local _gate_head_sha
  _gate_head_sha=$(git -C "$project_root" rev-parse HEAD 2>/dev/null || true)
  _gate_head_sha="${_gate_head_sha:-}"

  # --- Pure assembly: raw runner output → findings JSON (#1240) ---
  # Delegates the JSON-array build + overall-exit determination + write to
  # _gate_build_verdict (gate-verdict.sh) — a pure function of (raw file
  # contents, exit codes). No bats/make/git inside; callable in isolation.
  # _gbv_lint_count is set as a side-output by _gate_build_verdict so the
  # terminal digest below can report how many lint findings were found.
  # Initialize before the call so shellcheck can see the assignment (SC2154
  # cannot trace the cross-file side-output); _gate_build_verdict overwrites it.
  local _overall_exit=0
  _gbv_lint_count=0
  _gate_build_verdict "$_lint_raw_file" "$_tests_raw_file" \
    "$_lint_exit" "$_tests_exit" "$output_file" "${_gate_reason:-}" "$_gate_head_sha" \
    || _overall_exit=$?
  _lint_count=$_gbv_lint_count

  rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_bats_pretty_capture:-}"
  rm -f "${_gate_census_file:-}"
  trap - EXIT

  # --- Outcome label from assembly result ---
  # Block-on-any: the targeted suite is green on main, so ANY failure in the
  # selection is this change's to fix. (FORCE_FULL / no-diff always blocked on
  # any failure; the targeted path now matches — no new-vs-pre-existing split.)
  local _outcome="passed"
  [ "$_overall_exit" -ne 0 ] && _outcome="failed"

  local _gate_end
  _gate_end=$(date +%s)
  local _duration=$(( _gate_end - _gate_start ))

  # --- Verdict persistence (#944): record failing FILES / clear on pass -----
  # Failing test names from the TAP are mapped to their bats files via the
  # selection (same approach as the #945 flake-retry); the list feeds the next
  # run's selection union above. A passing outcome clears the state so genuine
  # zero-selection runs (docs-only diffs, no prior failure) stay skipped.
  local _vp_state_file="${RITE_STATE_DIR:-$project_root/.rite/state}/gate-prior-failing-pr${PR_NUMBER:-0}.list"
  if [ "$_outcome" = "passed" ]; then
    rm -f "$_vp_state_file" 2>/dev/null || true
  elif [ "$_outcome" = "failed" ] && [ -f "${_tests_raw_file:-/nonexistent}" ]; then
    local _vp_names _vp_name _vp_hit _vp_out=""
    _vp_names=$(grep -E '^not ok [0-9]+ ' "$_tests_raw_file" 2>/dev/null \
      | sed -E 's/^not ok [0-9]+ //' | sed 's/ # .*//' | grep -v '^\[tests_not_run\]' || true)
    if [ -n "$_vp_names" ] && [ -n "${_selection:-}" ]; then
      local _vp_sel_arr=()
      while IFS= read -r _vp_hit; do
        [ -n "$_vp_hit" ] && _vp_sel_arr+=("$project_root/$_vp_hit")
      done <<< "$_selection"
      while IFS= read -r _vp_name; do
        [ -z "$_vp_name" ] && continue
        _vp_hit=$(grep -lF "$_vp_name" "${_vp_sel_arr[@]+"${_vp_sel_arr[@]}"}" 2>/dev/null | head -1 || true)
        [ -n "$_vp_hit" ] && _vp_out="${_vp_out}${_vp_hit#"$project_root"/}"$'\n'
      done <<< "$_vp_names"
      _vp_out=$(printf '%s' "$_vp_out" | sort -u | grep -v '^$' || true)
      # #983: gather failures (e.g. "not ok 1 bats-gather-tests") produce a TAP
      # name that matches no file content — the loop above yields an empty
      # _vp_out even though the run failed.  Persisting nothing means the next
      # round's selection is empty and the gate reports outcome=passed having
      # verified nothing (vacuous pass; live escape: #964/#965/#977).
      # Conservative fallback: persist the ENTIRE current selection so the next
      # round re-verifies every file that was running when the failure occurred.
      if [ -z "$_vp_out" ]; then
        _vp_out=$(printf '%s\n' "$_selection" | grep -v '^$' || true)
      fi
      if [ -n "$_vp_out" ]; then
        mkdir -p "$(dirname "$_vp_state_file")" 2>/dev/null || true
        printf '%s\n' "$_vp_out" > "$_vp_state_file"
      fi
    fi
  fi

  _diag "TEST_GATE outcome=${_outcome} lint_count=${_lint_count} test_count=${_tests_count} duration_s=${_duration} pr=${PR_NUMBER:-?}"

  # --- Unscoped suite warning (target repos only) ---
  # Sharkrite's own runs always use targeted selection and are exempt by construction
  # (TEST_GATE_SELECTION mode=targeted is only emitted from the _is_sharkrite path).
  # For target repos there is no scoped runner today; this signals when the full
  # suite cost is becoming measurable so the operator can act before it hurts.
  # Suppress when the #975 per-cycle path ran — scoped cycling IS the solution.
  [ "${_ran_scoped_cycle:-false}" = "false" ] && \
    _maybe_warn_unscoped_suite "$_duration" "${RITE_GATE_SCOPE_WARN_SECONDS:-300}" "$_is_sharkrite"

  # --- Compact terminal digest ---
  # Raw runner output went to _gate_raw_sink (summary mode → log only; verbose →
  # live terminal). Surface the high-signal result here so concurrent phases
  # aren't drowned. Named failures appear once; full transcript is in the log.
  if [ "$_is_sharkrite" = "true" ]; then
    if [ "$_lint_count" -gt 0 ]; then
      echo "[test-gate] lint: ${_lint_count} finding(s) blocking — full output in run log"
    fi
    if [ "$_bats_fail_total" -gt 0 ]; then
      echo "[test-gate] bats: ${_bats_pass} passed, ${_bats_fail_total} failed (blocking)"
      if [ -n "$_summary_names" ]; then
        local _ncount
        _ncount=$(printf '%s\n' "$_summary_names" | grep -c '.' || true)
        echo "⚠️  ${_ncount} test failure(s) blocking the gate:"
        printf '%s\n' "$_summary_names" | while IFS= read -r _n; do
          [ -n "$_n" ] && echo "   • ${_n}"
        done
        [ -n "${RITE_LOG_FILE:-}" ] && echo "   Full bats output: ${RITE_LOG_FILE}"
      fi
    elif [ "$_bats_pass" -gt 0 ]; then
      if [ "$_gate_verbose" = "false" ]; then
        echo "[test-gate] bats: ${_bats_pass} passed, 0 failed ✅"
      fi
    fi
    # In summary mode, hint where the raw output can be found (only when we
    # suppressed it — i.e., verbose=false and a log file is configured).
    if [ "$_gate_verbose" = "false" ] && [ -n "${RITE_LOG_FILE:-}" ] \
       && [ "$_lint_count" -eq 0 ] && [ "$_bats_fail_total" -eq 0 ]; then
      : # All passed — the ✅ line above is sufficient, no log hint needed.
    elif [ "$_gate_verbose" = "false" ] && [ -n "${RITE_LOG_FILE:-}" ]; then
      echo "[test-gate] (raw runner output suppressed; use RITE_GATE_VERBOSE=true to stream — full output in ${RITE_LOG_FILE})"
    fi
  else
    # Non-Sharkrite runners: emit a one-line outcome summary since raw output
    # went to the sink (log or verbose stream) rather than the terminal.
    if [ "$_tests_exit" -ne 0 ]; then
      if [ "${_nonsr_fail_count:-0}" -gt 0 ]; then
        echo "[test-gate] tests: ${_nonsr_fail_count} failure(s) (blocking)"
        if [ -n "$_nonsr_fail_names" ]; then
          printf '%s\n' "$_nonsr_fail_names" | while IFS= read -r _n; do
            [ -n "$_n" ] && echo "   • ${_n}"
          done
        fi
      else
        echo "[test-gate] tests: FAILED (no parseable findings — see ${RITE_LOG_FILE:-run log})"
      fi
      [ -n "${RITE_LOG_FILE:-}" ] && echo "   Full output: ${RITE_LOG_FILE}"
    fi
  fi

  return "$_overall_exit"
}
