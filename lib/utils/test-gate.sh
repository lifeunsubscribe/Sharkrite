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

# ---------------------------------------------------------------------------
# _gate_write_json — emit structured gate result JSON
# Args: $1=output_file $2=lint_json_array $3=tests_json_array $4=exit_code
#       $5=skipped(true|false) $6=reason(optional)
# ---------------------------------------------------------------------------
_gate_write_json() {
  local output_file="$1"
  local lint_json="$2"
  local tests_json="$3"
  local exit_code="$4"
  local skipped="${5:-false}"
  local reason="${6:-}"

  if [ "$skipped" = "true" ]; then
    printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"%s"}\n' "$reason" > "$output_file"
  else
    printf '{"lint":%s,"tests":%s,"exit_code":%s}\n' "$lint_json" "$tests_json" "$exit_code" > "$output_file"
  fi
}

# ---------------------------------------------------------------------------
# _parse_shellcheck_line — convert shellcheck/make-check output to JSON fragment
# Input: one output line from make check / shellcheck
# Output: JSON object {"file":"...","line":"...","rule":"...","message":"..."} or ""
# ---------------------------------------------------------------------------
_parse_lint_line() {
  local raw_line="$1"
  # sc output format: path/file.sh:LINE:COL: levelXXXX: message
  # E.g.: lib/foo.sh:42:5: error SC2086: Double quote to prevent globbing
  if echo "$raw_line" | grep -qE '^[^:]+:[0-9]+:[0-9]+:.*SC[0-9]+:'; then
    local file line rule message
    file=$(echo "$raw_line" | cut -d: -f1 || true)
    line=$(echo "$raw_line" | cut -d: -f2 || true)
    rule=$(echo "$raw_line" | grep -oE 'SC[0-9]+' | head -1 || true)
    # Strip ANSI escape sequences and control chars, then escape for JSON.
    # sed: (1) remove ANSI CSI sequences (\x1b[...m and similar), (2) remove
    # remaining ESC bytes, (3) remove other C0 control bytes (tabs OK → keep \t
    # literal, but CR/BEL/BS etc. break JSON parsers).
    # Then escape backslashes and double-quotes for valid JSON.
    message=$(printf '%s' "$raw_line" \
      | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b//g; s/[\x01-\x08\x0b-\x0c\x0e-\x1f\x7f]//g' \
      | sed 's/\\/\\\\/g; s/"/\\"/g' || true)
    # JSON-escape file and line the same way as message to handle unusual paths
    # (backslashes, quotes) that would produce malformed JSON and cause jq to
    # silently yield zero gate items via || true in assess-and-resolve.sh.
    file=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g' || true)
    line=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g' || true)
    printf '{"file":"%s","line":"%s","rule":"%s","message":"%s"}' \
      "$file" "$line" "${rule:-lint}" "$message"
    return 0
  fi
  # custom lint tool format: FILE:LINE: [RULE] message
  # E.g.: lib/bar.sh:88: [BARE_MARKER_GREP] Unanchored marker grep
  if echo "$raw_line" | grep -qE '^[^:]+:[0-9]+:.*\[[A-Z_]+\]'; then
    local file line rule message
    file=$(echo "$raw_line" | cut -d: -f1 || true)
    line=$(echo "$raw_line" | cut -d: -f2 || true)
    rule=$(echo "$raw_line" | grep -oE '\[[A-Z_]+\]' | head -1 | tr -d '[]' || true)
    message=$(printf '%s' "$raw_line" \
      | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b//g; s/[\x01-\x08\x0b-\x0c\x0e-\x1f\x7f]//g' \
      | sed 's/\\/\\\\/g; s/"/\\"/g' || true)
    # JSON-escape file and line the same way as message (same fail-open risk)
    file=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g' || true)
    line=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g' || true)
    printf '{"file":"%s","line":"%s","rule":"%s","message":"%s"}' \
      "$file" "$line" "${rule:-lint}" "$message"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _parse_bats_failure — convert bats failure output to JSON fragment
# Input: bats test failure section text
# Output: JSON objects (one per failure)
# ---------------------------------------------------------------------------
_parse_bats_failure_line() {
  local raw_line="$1"
  # bats failure format: "not ok N test description"
  if echo "$raw_line" | grep -qE '^not ok [0-9]+ '; then
    local test_name _stripped
    # Strip "not ok N " prefix, then ANSI/control bytes, then JSON-escape.
    # Each transformation is a separate variable to satisfy the || true rule:
    # a pipeline inside $() that exits non-zero silently kills the script.
    _stripped=$(echo "$raw_line" | sed 's/^not ok [0-9]* //' || true)
    _stripped=$(printf '%s' "$_stripped" \
      | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b//g' || true)
    # sharkrite-lint disable UNSAFE_PIPE_IN_CMDSUB - Reason: || true on next line; single-sed, no grep/awk
    test_name=$(printf '%s' "$_stripped" \
      | sed 's/[\x01-\x08\x0b-\x0c\x0e-\x1f\x7f]//g; s/\\/\\\\/g; s/"/\\"/g' || true)
    printf '{"file":"bats","test_name":"%s","reason":"assertion failed"}' "$test_name"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Test selection by changed paths (issue #462)
# ---------------------------------------------------------------------------
# Bats files declare coverage via a single-line header:
#   # sharkrite-test-covers: lib/core/foo.sh, lib/utils/bar.sh
# The gate intersects this with the commit's changed-file list and runs only
# the matching subset. Files WITHOUT a header are always included (conservative
# fallback during rollout). Certain "broad-impact" file changes (the gate
# itself, lint rules, Makefile, test helpers, fixtures) force the full suite.
#
# Override the diff base via RITE_TEST_GATE_DIFF_BASE (default: origin/main).
# ---------------------------------------------------------------------------

# Files whose change forces the full suite (verifier internals, lint, helpers).
# Keep this list small and auditable. New entries belong here only when a change
# to the file plausibly affects test correctness across the whole suite.
# Patterns are shell case-statement globs.
_TEST_GATE_FULL_SUITE_TRIGGERS=(
  "lib/utils/test-gate.sh"
  # Match any lint tool by glob to avoid embedding the literal sharkrite-lint
  # filename (would trip the RAW_MARKER_LITERAL rule). This is broader than
  # needed today but reasonable — every tools/*-lint.sh affects test correctness.
  "tools/*-lint.sh"
  "Makefile"
  "tests/helpers/*"
  "tests/fixtures/*"
)

# _parse_test_coverage_header — extract the sharkrite-test-covers paths
# Looks in the first 15 lines for `# sharkrite-test-covers: <paths>`.
# Returns the comma-separated path list, or empty string if no header.
_parse_test_coverage_header() {
  local bats_file="$1"
  local _header
  _header=$(head -15 "$bats_file" 2>/dev/null \
    | grep -E "^# ${RITE_MARKER_TEST_COVERS}:" \
    | head -1 || true)
  if [ -z "$_header" ]; then
    echo ""
    return 0
  fi
  # Strip prefix and trailing whitespace
  echo "$_header" | sed -E "s/^# ${RITE_MARKER_TEST_COVERS}:[[:space:]]*//; s/[[:space:]]*$//" || true
}

# _bats_file_matches_changed — decide if a single bats file should run
# Args: $1=bats_file_path, $2=changed_files (newline-separated)
# Returns: 0 (include) or 1 (skip)
# Headerless files always include (conservative default).
_bats_file_matches_changed() {
  local bats_file="$1"
  local changed_files="$2"
  local _header
  _header=$(_parse_test_coverage_header "$bats_file")
  if [ -z "$_header" ]; then
    return 0
  fi
  # Header is comma-separated; iterate each pattern.
  # set -f disables filesystem glob expansion during the split — without it,
  # a header like `lib/utils/*.sh` would be expanded against the filesystem
  # immediately, replacing the pattern with the list of currently-matching files.
  # The case statement below needs the literal pattern to do glob matching against
  # the (different) changed-file list.
  set -f
  local IFS=','
  # shellcheck disable=SC2086  # word-splitting on $_header is intentional
  set -- $_header
  unset IFS
  set +f
  local _pattern _changed
  for _pattern in "$@"; do
    # Trim surrounding whitespace
    _pattern="${_pattern# }"
    _pattern="${_pattern% }"
    [ -z "$_pattern" ] && continue
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      # shellcheck disable=SC2254  # glob expansion in case is intentional
      case "$_changed" in
        $_pattern) return 0 ;;
      esac
    done <<< "$changed_files"
  done
  return 1
}

# _select_tests_by_changed_paths — produce the bats invocation plan
# Args: $1=changed_files (newline-separated), $2=project_root
# Stdout: one of
#   FORCE_FULL                              — run full suite (trigger fired or no diff)
#   <newline-separated list of bats files>  — targeted subset, relative to project_root
# Returns 0 always (caller handles empty/full).
_select_tests_by_changed_paths() {
  local changed_files="$1"
  local project_root="$2"

  # No diff → run full suite (degenerate but safe; e.g. brand-new branch, no upstream)
  if [ -z "$changed_files" ]; then
    echo "FORCE_FULL"
    return 0
  fi

  # Full-suite trigger: any change to verifier internals / lint / helpers / fixtures
  local _trigger _changed
  while IFS= read -r _changed; do
    [ -z "$_changed" ] && continue
    for _trigger in "${_TEST_GATE_FULL_SUITE_TRIGGERS[@]}"; do
      # shellcheck disable=SC2254  # glob expansion in case is intentional
      case "$_changed" in
        $_trigger)
          echo "FORCE_FULL"
          return 0
          ;;
      esac
    done
  done <<< "$changed_files"

  # Walk every bats file and decide inclusion. Output is relative paths so the
  # caller can `cd "$project_root" && bats <relative-paths>`.
  (cd "$project_root" && find tests -name "*.bats" -type f 2>/dev/null) \
    | while IFS= read -r _rel; do
        if _bats_file_matches_changed "$project_root/$_rel" "$changed_files"; then
          echo "$_rel"
        fi
      done
}

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

  # --- Worktree existence guard ---
  # If project_root was removed between gate launch and execution (e.g. worktree deleted
  # mid-run), skip gracefully rather than silently pass with exit code 0 from a no-op cd.
  if [ ! -d "$project_root" ]; then
    _diag "TEST_GATE outcome=skipped reason=missing_worktree pr=${PR_NUMBER:-?}"
    _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_worktree"
    return 0
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
  _lint_raw_file=$(mktemp "/tmp/rite_gate_lint_${PR_NUMBER:-0}_$$.txt")
  _tests_raw_file=$(mktemp "/tmp/rite_gate_tests_${PR_NUMBER:-0}_$$.txt")
  # Register cleanup for this invocation's specific files (never a glob).
  # Also write a valid-JSON crash sentinel if the function exits non-zero before
  # _gate_write_json runs — an empty/absent output_file causes jq to silently
  # return zero findings (fail-open), defeating the gate's purpose.
  # The sentinel uses skipped:true so assess-and-resolve.sh skips gate injection
  # rather than reading malformed JSON, while still logging the crash via _diag.
  # shellcheck disable=SC2154  # _gate_exit_status assigned inside the trap body via $? at trap execution time
  trap '_gate_exit_status=$?
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_sc_exit_file:-}" "${_lint_exit_file:-}" "${_bats_exit_file:-}" "${_nonsr_exit_file:-}"
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

  if [ "$_is_sharkrite" = "true" ]; then
    # --- Sharkrite: shellcheck + custom lint (run independently so both run even if shellcheck fails) ---
    # Running as two separate invocations ensures custom-lint findings are never masked
    # by a shellcheck failure (make check: shellcheck lint stops make after shellcheck exits non-zero).
    local _shellcheck_exit=0
    local _lint_tool_exit=0
    # Exit-code capture temp files (PID-scoped; one per invocation to prevent glob collision)
    local _sc_exit_file _lint_exit_file _bats_exit_file
    _sc_exit_file=$(mktemp "/tmp/rite_gate_sc_exit_${PR_NUMBER:-0}_$$.txt")
    _lint_exit_file=$(mktemp "/tmp/rite_gate_lint_exit_${PR_NUMBER:-0}_$$.txt")
    _bats_exit_file=$(mktemp "/tmp/rite_gate_bats_exit_${PR_NUMBER:-0}_$$.txt")

    echo "[test-gate] Running make shellcheck..."
    # Capture exit code via a temp file (PIPESTATUS is lost when tee is the last
    # command in the pipeline; the approach used here works under bash 3.2).
    # tee -a to both stdout (captured by the parent's full-transcript tee for the
    # run log) and the lint temp file (parsed for structured JSON findings below).
    # Without the tee, lint violations only appeared in the JSON gate output and
    # were invisible to `tail -f rite-*.log` during a live run.
    { (cd "$project_root" && make shellcheck 2>&1); echo $? > "$_sc_exit_file"; } \
      | tee -a "$_lint_raw_file" || true
    _shellcheck_exit=$(cat "$_sc_exit_file" 2>/dev/null || echo 0)

    echo "[test-gate] Running make lint..."
    { (cd "$project_root" && make lint 2>&1); echo $? > "$_lint_exit_file"; } \
      | tee -a "$_lint_raw_file" || true
    _lint_tool_exit=$(cat "$_lint_exit_file" 2>/dev/null || echo 0)

    [ "$_shellcheck_exit" -ne 0 ] && _lint_exit=1
    [ "$_lint_tool_exit" -ne 0 ] && _lint_exit=1
    # _lint_count is derived from the JSON array builder below (not a broad grep)

    # --- Sharkrite: targeted bats selection (issue #462) ---
    # Determine which bats files to run based on the commit's changed paths.
    # Files declare coverage via `# sharkrite-test-covers: <paths>` headers.
    # Headerless files always run (conservative). Verifier/lint/helper changes
    # force the full suite. See: _select_tests_by_changed_paths above.
    local _diff_base="${RITE_TEST_GATE_DIFF_BASE:-origin/main}"
    local _changed_files _total_bats _selection _selected_count _selection_mode
    _changed_files=$(cd "$project_root" && git diff --name-only "$_diff_base"...HEAD 2>/dev/null || true)
    _total_bats=$(cd "$project_root" && find tests -name "*.bats" -type f 2>/dev/null | wc -l | tr -d ' ')
    _selection=$(_select_tests_by_changed_paths "$_changed_files" "$project_root")

    if [ "$_selection" = "FORCE_FULL" ] || [ -z "$_selection" ]; then
      _selection_mode="full"
      _selected_count="$_total_bats"
      echo "[test-gate] Selection: full suite (${_total_bats} bats files)"
      _diag "TEST_GATE_SELECTION mode=full selected=${_total_bats} total=${_total_bats} pr=${PR_NUMBER:-?}"
      echo "[test-gate] Running bats -r tests/..."
      { (cd "$project_root" && bats -r tests/ 2>&1); echo $? > "$_bats_exit_file"; } \
        | tee "$_tests_raw_file" || true
    else
      _selected_count=$(echo "$_selection" | grep -c '.' || true)
      _selection_mode="targeted"
      echo "[test-gate] Selection: targeted (${_selected_count}/${_total_bats} bats files based on changed paths)"
      _diag "TEST_GATE_SELECTION mode=targeted selected=${_selected_count} total=${_total_bats} pr=${PR_NUMBER:-?}"
      # Build array of selected files for bats invocation
      local _selected_files=()
      while IFS= read -r _bf; do
        [ -n "$_bf" ] && _selected_files+=("$_bf")
      done <<< "$_selection"
      echo "[test-gate] Running bats on ${#_selected_files[@]} selected files..."
      { (cd "$project_root" && bats "${_selected_files[@]}" 2>&1); echo $? > "$_bats_exit_file"; } \
        | tee "$_tests_raw_file" || true
    fi
    _tests_exit=$(cat "$_bats_exit_file" 2>/dev/null || echo 0)

    rm -f "$_sc_exit_file" "$_lint_exit_file" "$_bats_exit_file"
    _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)
  else
    # Non-Sharkrite: best-effort detection (npm test / make test / pytest)
    # For non-Sharkrite repos the gate runs whatever make test does (unchanged behavior)
    local _nonsr_exit_file
    _nonsr_exit_file=$(mktemp "/tmp/rite_gate_nonsr_exit_${PR_NUMBER:-0}_$$.txt")
    if [ -f "$project_root/Makefile" ] && grep -q "^test:" "$project_root/Makefile" 2>/dev/null; then
      echo "[test-gate] Running make test..."
      # tee to stdout for full-transcript log capture; temp file for JSON findings
      { (cd "$project_root" && make test 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 0)
    elif [ -f "$project_root/package.json" ]; then
      echo "[test-gate] Running npm test..."
      { (cd "$project_root" && npm test 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 0)
    elif [ -f "$project_root/pytest.ini" ] || [ -d "$project_root/tests" ]; then
      echo "[test-gate] Running pytest..."
      { (cd "$project_root" && python3 -m pytest 2>&1); echo $? > "$_nonsr_exit_file"; } \
        | tee "$_tests_raw_file" || true
      _tests_exit=$(cat "$_nonsr_exit_file" 2>/dev/null || echo 0)
    else
      # No recognizable test runner — skip gracefully
      _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
      rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}"
      trap - EXIT
      _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
      return 0
    fi
    rm -f "${_nonsr_exit_file:-}"
    _tests_count=$(grep -c "^not ok \|FAILED\|ERROR" "$_tests_raw_file" || true)
  fi

  # --- Build JSON arrays from raw output ---
  local _lint_items="["
  local _first_lint=true
  while IFS= read -r _raw; do
    _item=$(_parse_lint_line "$_raw" 2>/dev/null || true)
    if [ -n "$_item" ]; then
      [ "$_first_lint" = "true" ] || _lint_items+=","
      _lint_items+="$_item"
      _first_lint=false
      _lint_count=$(( _lint_count + 1 ))
    fi
  done < "$_lint_raw_file"
  _lint_items+="]"

  local _tests_items="["
  local _first_test=true
  while IFS= read -r _raw; do
    _item=$(_parse_bats_failure_line "$_raw" 2>/dev/null || true)
    if [ -n "$_item" ]; then
      [ "$_first_test" = "true" ] || _tests_items+=","
      _tests_items+="$_item"
      _first_test=false
    fi
  done < "$_tests_raw_file"
  _tests_items+="]"

  rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}"
  trap - EXIT

  # --- Determine overall exit code and outcome ---
  local _overall_exit=0
  local _outcome="passed"
  if [ "$_lint_exit" -ne 0 ] || [ "$_tests_exit" -ne 0 ]; then
    _overall_exit=1
    _outcome="failed"
  fi

  local _gate_end
  _gate_end=$(date +%s)
  local _duration=$(( _gate_end - _gate_start ))

  _diag "TEST_GATE outcome=${_outcome} lint_count=${_lint_count} test_count=${_tests_count} duration_s=${_duration} pr=${PR_NUMBER:-?}"

  _gate_write_json "$output_file" "$_lint_items" "$_tests_items" "$_overall_exit"
  return "$_overall_exit"
}
