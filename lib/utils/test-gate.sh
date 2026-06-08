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
# Full-suite triggers: when any of these paths appear in the diff, skip test
# selection and run the entire bats suite. Auditable const block — extend here
# when new infrastructure files that affect test selection semantics are added.
# ---------------------------------------------------------------------------
_GATE_FULL_SUITE_TRIGGER_PATTERNS=(
  "lib/utils/test-gate.sh"
  "tools/sharkrite-lint.sh"
  "Makefile"
  "tests/helpers/"
  "tests/fixtures/"
)

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
# parse_test_coverage_header — read the sharkrite-test-covers: header from a
# bats file and return the comma-separated path list.
#
# Convention: the header must appear on a line of the exact form:
#   # sharkrite-test-covers: <paths>
# Glob patterns are allowed in paths (e.g. lib/utils/*.sh).
#
# Args: $1=bats_file_path
# Output: comma-separated covered paths to stdout (empty if no header present)
# Returns: 0 always (missing header is a valid state — conservative fallback)
# ---------------------------------------------------------------------------
parse_test_coverage_header() {
  local bats_file="$1"
  # Only scan the first 10 lines — header must appear near the top.
  # grep -m 1: stop after the first match (fast path for large files).
  local _header_line
  _header_line=$(head -10 "$bats_file" 2>/dev/null | grep -m 1 '^# sharkrite-test-covers:' || true)
  if [ -z "$_header_line" ]; then
    return 0
  fi
  # Strip the leading "# sharkrite-test-covers:" prefix, then trim any leading
  # whitespace — handles both "# sharkrite-test-covers: paths" (space present)
  # and "# sharkrite-test-covers:paths" (no space) without silently dropping the file.
  local _path_list
  _path_list="${_header_line#\# sharkrite-test-covers:}"
  # Trim leading whitespace (portable; no sed/awk required)
  while [ "${_path_list#[[:space:]]}" != "$_path_list" ]; do
    _path_list="${_path_list#[[:space:]]}"
  done
  printf '%s' "$_path_list"
}

# ---------------------------------------------------------------------------
# _gate_path_matches_changed — check if a coverage path (possibly a glob)
# matches any file in the changed_files string.
#
# Args: $1=coverage_path (may contain * glob wildcard)
#       $2=changed_files (newline-separated list of paths from git diff)
# Returns: 0 if any changed file matches, 1 otherwise
#
# Glob semantics: the * wildcard spans path separators (/).
#   "lib/utils/*.sh"  matches  "lib/utils/sub/deep.sh"  (not just top-level .sh files)
# This is intentional and conservative — over-matching means more tests run, never fewer.
# Writers of sharkrite-test-covers: headers should be aware that single-* patterns are
# not restricted to one directory level; use an exact path or a tighter prefix when
# you only want to cover a specific directory depth.
# ---------------------------------------------------------------------------
_gate_path_matches_changed() {
  local cover_path="$1"
  local changed_files="$2"

  # Detect whether the path contains a glob wildcard.
  if echo "$cover_path" | grep -q '\*'; then
    # Glob path: convert to prefix (strip from first *) and match the prefix,
    # then match the suffix pattern after *.
    # Strategy: strip the glob and match what's before it as a path prefix.
    # For "lib/utils/*.sh": prefix="lib/utils/", suffix_pattern=".sh"
    local _prefix _suffix_pattern
    _prefix="${cover_path%%\**}"
    _suffix_pattern="${cover_path##*\*}"
    # A changed file matches if it starts with prefix AND ends with suffix_pattern.
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      # Check prefix match
      case "$_changed" in
        "${_prefix}"*)
          # Check suffix match (suffix_pattern may be empty for "path/*")
          if [ -z "$_suffix_pattern" ]; then
            return 0
          fi
          case "$_changed" in
            *"${_suffix_pattern}") return 0 ;;
          esac
          ;;
      esac
    done <<< "$changed_files"
  else
    # Exact path: check if any changed file exactly matches or starts with this
    # path (handles both file-level and directory-level coverage declarations).
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      if [ "$_changed" = "$cover_path" ]; then
        return 0
      fi
      # Directory prefix match: "lib/core/" matches "lib/core/workflow-runner.sh"
      case "$_changed" in
        "${cover_path}"*) return 0 ;;
      esac
    done <<< "$changed_files"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# select_tests_by_changed_paths — determine which bats files to run based on
# the changed file set and sharkrite-test-covers: headers.
#
# Selection rules:
#   1. Files without a sharkrite-test-covers: header → ALWAYS included (conservative)
#   2. Files WITH a header → included only if any covered path matches changed_files
#   3. Returns full suite list when any file in changed_files matches a
#      full-suite trigger pattern (see _GATE_FULL_SUITE_TRIGGER_PATTERNS above)
#
# Args: $1=changed_files (newline-separated paths from git diff)
#       $2=project_root (directory containing tests/)
# Output: space-separated list of bats file paths to stdout
#         First line may be "FULL_SUITE" to signal caller to run bats -r tests/
# ---------------------------------------------------------------------------
select_tests_by_changed_paths() {
  local changed_files="$1"
  local project_root="$2"

  # --- Check full-suite triggers first ---
  local _trigger_pat
  for _trigger_pat in "${_GATE_FULL_SUITE_TRIGGER_PATTERNS[@]}"; do
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      case "$_changed" in
        "${_trigger_pat}"*)
          echo "FULL_SUITE"
          return 0
          ;;
      esac
    done <<< "$changed_files"
  done

  # --- Build selected set from bats files ---
  # Enumerate ALL bats files under tests/ recursively (excluding helpers/fixtures)
  # so that header-less files in tests/{unit,integration,security,smoke,...} also
  # receive the conservative "always run" fallback — same as regression/lint files.
  local _bats_files _selected_files _total_count _selected_count
  _bats_files=$(find "$project_root/tests" \
    -name "*.bats" \
    -not -path "*/helpers/*" \
    -not -path "*/fixtures/*" \
    2>/dev/null | sort || true)
  _total_count=$(echo "$_bats_files" | grep -c '\.bats$' || true)
  _selected_files=""
  _selected_count=0

  while IFS= read -r _bats_file; do
    [ -z "$_bats_file" ] && continue

    local _covered_paths
    _covered_paths=$(parse_test_coverage_header "$_bats_file")

    if [ -z "$_covered_paths" ]; then
      # No header — always include (conservative fallback)
      _selected_files="${_selected_files:+$_selected_files }$_bats_file"
      _selected_count=$(( _selected_count + 1 ))
      continue
    fi

    # Header present — check if any covered path matches the changed set.
    # Paths are comma-separated; use a while+read loop to split on commas safely
    # without relying on IFS manipulation in the for-loop body.
    local _path_matched=false
    local _cov_path
    # Replace commas with newlines for portable iteration via while read
    while IFS= read -r _cov_path; do
      # Strip leading/trailing whitespace from each path token
      _cov_path="${_cov_path# }"
      _cov_path="${_cov_path% }"
      [ -z "$_cov_path" ] && continue
      if _gate_path_matches_changed "$_cov_path" "$changed_files"; then
        _path_matched=true
        break
      fi
    done <<< "$(printf '%s' "$_covered_paths" | tr ',' '\n')"

    if [ "$_path_matched" = "true" ]; then
      _selected_files="${_selected_files:+$_selected_files }$_bats_file"
      _selected_count=$(( _selected_count + 1 ))
    fi
  done <<< "$_bats_files"

  # Output the selected files list; echo counts on stdout for caller's diag emission.
  # Format: "SELECTED:<N>/<total>" on first line, then space-separated paths.
  echo "SELECTED:${_selected_count}/${_total_count}"
  if [ -n "$_selected_files" ]; then
    echo "$_selected_files"
  fi
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
  # Test selection diag vars (Sharkrite gate only; initialized here for clean scoping)
  local _gate_sel_mode="full"
  local _gate_sel_selected=0
  local _gate_sel_total=0

  if [ "$_is_sharkrite" = "true" ]; then
    # --- Sharkrite: shellcheck + custom lint (run independently so both run even if shellcheck fails) ---
    # Running as two separate invocations ensures custom-lint findings are never masked
    # by a shellcheck failure (make check: shellcheck lint stops make after shellcheck exits non-zero).
    local _shellcheck_exit=0
    local _lint_tool_exit=0
    echo "[test-gate] Running make shellcheck..." >&2
    set +e
    (cd "$project_root" && make shellcheck 2>&1) >> "$_lint_raw_file" || _shellcheck_exit=$?
    echo "[test-gate] Running make lint..." >&2
    (cd "$project_root" && make lint 2>&1) >> "$_lint_raw_file" || _lint_tool_exit=$?
    set -e
    [ "$_shellcheck_exit" -ne 0 ] && _lint_exit=1
    [ "$_lint_tool_exit" -ne 0 ] && _lint_exit=1
    # _lint_count is derived from the JSON array builder below (not a broad grep)

    # --- Sharkrite: bats selection by changed paths ---
    # If lint failed, skip bats entirely and report lint failures immediately.
    # A broken codebase (lint failures) means tests may not even load — running them
    # produces misleading failures that obscure the real issue.
    if [ "$_lint_exit" -ne 0 ]; then
      echo "[test-gate] Lint failed — skipping bats (lint failures take priority)" >&2
      _tests_exit=0
      printf '' > "$_tests_raw_file"
    else
      # Determine changed files relative to the diff base (default: origin/main).
      # RITE_TEST_GATE_DIFF_BASE can be overridden per-project or per-test.
      local _diff_base="${RITE_TEST_GATE_DIFF_BASE:-origin/main}"
      local _changed_files
      _changed_files=$(git -C "$project_root" diff --name-only "${_diff_base}...HEAD" 2>/dev/null || true)

      # Zero-diff is a degenerate case (empty branch, detached HEAD, etc.) — log it
      # and run the full suite conservatively rather than silently skipping bats.
      if [ -z "$_changed_files" ]; then
        echo "[test-gate] No changed files detected vs ${_diff_base} — running full suite (conservative)" >&2
        _gate_sel_mode="full"
        _gate_sel_selected=0
        _gate_sel_total=0
        set +e
        (cd "$project_root" && bats -r tests/ 2>&1) > "$_tests_raw_file" || _tests_exit=$?
        set -e
      else
        # Compute test selection via coverage headers.
        local _sel_output _sel_mode _gate_total _gate_selected _bats_selection
        _sel_output=$(select_tests_by_changed_paths "$_changed_files" "$project_root" 2>/dev/null || true)

        # First line of output: "FULL_SUITE" or "SELECTED:<N>/<total>"
        local _sel_first_line
        _sel_first_line=$(echo "$_sel_output" | head -1 || true)

        if [ "$_sel_first_line" = "FULL_SUITE" ]; then
          # A full-suite trigger fired (verifier/lint/helper changed)
          _sel_mode="full"
          _gate_total=$(find "$project_root/tests" \
            -name "*.bats" \
            -not -path "*/helpers/*" \
            -not -path "*/fixtures/*" \
            2>/dev/null | wc -l | tr -d ' ' || true)
          _gate_selected="$_gate_total"
          echo "[test-gate] full suite (verifier/lint/helper changed)" >&2
          set +e
          (cd "$project_root" && bats -r tests/ 2>&1) > "$_tests_raw_file" || _tests_exit=$?
          set -e
        else
          # Parse "SELECTED:<N>/<total>" from first line
          _sel_mode="targeted"
          _gate_selected=$(echo "$_sel_first_line" | grep -oE 'SELECTED:[0-9]+' | grep -oE '[0-9]+' || true)
          _gate_total=$(echo "$_sel_first_line" | grep -oE '/[0-9]+' | tr -d '/' || true)
          _gate_selected="${_gate_selected:-0}"
          _gate_total="${_gate_total:-0}"

          # Remaining lines are the selected bats file paths (space-separated on one line)
          _bats_selection=$(echo "$_sel_output" | tail -n +2 || true)

          echo "[test-gate] targeted: ${_gate_selected} of ${_gate_total} bats files" >&2

          if [ -z "$_bats_selection" ] || [ "$_gate_selected" -eq 0 ] 2>/dev/null; then
            # No tests selected — log but don't run bats (nothing to test)
            echo "[test-gate] No bats files selected for changed paths — skipping bats" >&2
            _tests_exit=0
            printf '' > "$_tests_raw_file"
          else
            set +e
            # Run the selected bats files directly (not -r which would recurse all dirs)
            # Word-split is intentional: _bats_selection is a space-separated list of paths
            # shellcheck disable=SC2086
            (cd "$project_root" && bats $_bats_selection 2>&1) > "$_tests_raw_file" || _tests_exit=$?
            set -e
          fi
        fi

        _gate_sel_mode="$_sel_mode"
        _gate_sel_selected="${_gate_selected:-0}"
        _gate_sel_total="${_gate_total:-0}"
      fi
    fi
    _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)
  else
    # Non-Sharkrite: best-effort detection (npm test / make test / pytest)
    # For non-Sharkrite repos the gate runs whatever make test does (unchanged behavior)
    if [ -f "$project_root/Makefile" ] && grep -q "^test:" "$project_root/Makefile" 2>/dev/null; then
      echo "[test-gate] Running make test..." >&2
      set +e
      (cd "$project_root" && make test 2>&1) > "$_tests_raw_file" || _tests_exit=$?
      set -e
    elif [ -f "$project_root/package.json" ]; then
      echo "[test-gate] Running npm test..." >&2
      set +e
      (cd "$project_root" && npm test 2>&1) > "$_tests_raw_file" || _tests_exit=$?
      set -e
    elif [ -f "$project_root/pytest.ini" ] || [ -d "$project_root/tests" ]; then
      echo "[test-gate] Running pytest..." >&2
      set +e
      (cd "$project_root" && python3 -m pytest 2>&1) > "$_tests_raw_file" || _tests_exit=$?
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
  # Emit selection diag for health-report aggregation (Sharkrite gate only).
  # mode=full when verifier/trigger changed or diff was empty; mode=targeted otherwise.
  if [ "$_is_sharkrite" = "true" ]; then
    _diag "TEST_GATE_SELECTION mode=${_gate_sel_mode} selected=${_gate_sel_selected} total=${_gate_sel_total} issue=${ISSUE_NUMBER:-${PR_NUMBER:-?}}"
  fi

  _gate_write_json "$output_file" "$_lint_items" "$_tests_items" "$_overall_exit"
  return "$_overall_exit"
}
