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
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}"
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
    echo "[test-gate] Running make shellcheck..." >&2
    set +e
    # Stream output to terminal AND capture to temp file via process substitution.
    # Process substitution preserves the subshell exit code at the || site (no PIPESTATUS dance).
    # tee -a appends so shellcheck + lint both accumulate into the same _lint_raw_file for parsing.
    (cd "$project_root" && make shellcheck 2>&1) > >(tee -a "$_lint_raw_file") || _shellcheck_exit=$?
    echo "[test-gate] Running make lint..." >&2
    (cd "$project_root" && make lint 2>&1) > >(tee -a "$_lint_raw_file") || _lint_tool_exit=$?
    set -e
    [ "$_shellcheck_exit" -ne 0 ] && _lint_exit=1
    [ "$_lint_tool_exit" -ne 0 ] && _lint_exit=1
    # _lint_count is derived from the JSON array builder below (not a broad grep)

    # --- Sharkrite: bats -r tests/ (recursive) ---
    echo "[test-gate] Running bats -r tests/..." >&2
    set +e
    # Stream per-test pass/fail lines to terminal in real time, capture to temp file for parsing.
    # tee -a used for consistency with the lint sites (file starts empty here, so -a == > in effect).
    (cd "$project_root" && bats -r tests/ 2>&1) > >(tee -a "$_tests_raw_file") || _tests_exit=$?
    set -e
    _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)
  else
    # Non-Sharkrite: best-effort detection (npm test / make test / pytest)
    # For non-Sharkrite repos the gate runs whatever make test does (unchanged behavior)
    if [ -f "$project_root/Makefile" ] && grep -q "^test:" "$project_root/Makefile" 2>/dev/null; then
      echo "[test-gate] Running make test..." >&2
      set +e
      # Stream output to terminal AND capture to temp file (same tee pattern as Sharkrite paths).
      (cd "$project_root" && make test 2>&1) > >(tee -a "$_tests_raw_file") || _tests_exit=$?
      set -e
    elif [ -f "$project_root/package.json" ]; then
      echo "[test-gate] Running npm test..." >&2
      set +e
      (cd "$project_root" && npm test 2>&1) > >(tee -a "$_tests_raw_file") || _tests_exit=$?
      set -e
    elif [ -f "$project_root/pytest.ini" ] || [ -d "$project_root/tests" ]; then
      echo "[test-gate] Running pytest..." >&2
      set +e
      (cd "$project_root" && python3 -m pytest 2>&1) > >(tee -a "$_tests_raw_file") || _tests_exit=$?
      set -e
    else
      # No recognizable test runner — skip gracefully
      _diag "TEST_GATE outcome=skipped reason=missing_runner pr=${PR_NUMBER:-?}"
      rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}"
      trap - EXIT
      _gate_write_json "$output_file" "[]" "[]" "0" "true" "missing_runner"
      return 0
    fi
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
