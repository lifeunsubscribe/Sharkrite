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
# _sanitize_json_value — make an arbitrary string safe inside a JSON string,
# portably across GNU and BSD tooling.
#   1. strip ANSI CSI sequences + lone ESC bytes (sed; \x1b works on both seds)
#   2. delete the C0 control bytes that break JSON parsers — via `tr` octal
#      ranges, NOT a sed `[\x01-\x08...]` hex character class. BSD /usr/bin/sed
#      rejects that range with "RE error: invalid character range" and, under
#      the callers' `|| true`, silently returns EMPTY — which emptied every
#      bats/lint finding name on macOS (the gate's [GATE] findings carried no
#      test name). Tab(011)/LF(012)/CR(015) are preserved by the range gaps.
#   3. escape backslashes then double-quotes for valid JSON.
_sanitize_json_value() {
  printf '%s' "$1" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b//g' \
    | tr -d '\001-\010\013\014\016-\037\177' \
    | sed 's/\\/\\\\/g; s/"/\\"/g'
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
    # Strip ANSI/control bytes, then escape for JSON (portable — see helper).
    message=$(_sanitize_json_value "$raw_line" || true)
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
    message=$(_sanitize_json_value "$raw_line" || true)
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
    # Strip the "not ok N " prefix, then ANSI/control bytes + JSON-escape via the
    # shared helper (portable across BSD/GNU sed — the old inline hex-range sed
    # errored on macOS and emptied the name).
    _stripped=$(echo "$raw_line" | sed 's/^not ok [0-9]* //' || true)
    test_name=$(_sanitize_json_value "$_stripped" || true)
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
# the matching subset. Files WITHOUT a header are SKIPPED (post-#480 backfill;
# the MISSING_TEST_COVERAGE_HEADER lint rule enforces headers on new files).
#
# There are NO bats full-suite trigger paths: selection is always targeted.
# The trigger list (gate/lint/Makefile/helpers/fixtures changes forced all
# ~165 files) was removed 2026-06-12 — a full run costs hours per fix-loop
# iteration and drowned real findings in load-induced flake. The accepted
# coverage trade-off (helpers/fixtures/Makefile changes select few or zero
# bats files) is documented in behavioral-design.md → "Test Selection by
# Changed Paths"; issue #482 tracks the compensating periodic safety net.
# FORCE_FULL survives only for the no-diff degenerate case below.
#
# Override the diff base via RITE_TEST_GATE_DIFF_BASE (default: origin/main).
# ---------------------------------------------------------------------------

# Files whose change forces a full LINT scan (bats selection is never
# escalated — see above; a full lint scan costs seconds, not hours, so the
# escalation is kept here). A change to lib/utils/markers.sh is intentionally
# NOT a trigger —
# adding/renaming a constant doesn't change which existing files violate
# RAW_MARKER_LITERAL (literals live in the same files before and after).
_LINT_GATE_FULL_SUITE_TRIGGERS=(
  "tools/*-lint.sh"
  "Makefile"
)

# _select_lint_by_changed_paths — produce the lint scope plan
# Args: $1=changed_files (newline-separated relative paths), $2=project_root
# Stdout: one of
#   FORCE_FULL  — run lint over the full codebase
#   <newline-separated absolute paths> — targeted subset
#   (empty)     — no shell-source changes; caller should skip lint
# Returns 0 always (caller branches on stdout).
_select_lint_by_changed_paths() {
  local changed_files="$1"
  local project_root="$2"

  # No diff (e.g. brand-new branch with no upstream) → full scan, safer default.
  if [ -z "$changed_files" ]; then
    echo "FORCE_FULL"
    return 0
  fi

  # Full-scan trigger: lint rule change, Makefile change. Suppressed by
  # RITE_TEST_GATE_SKIP_TRIGGERS=true (used by post-merge-verify.sh: rebases
  # past main commits that touched lint rules or the Makefile would otherwise
  # force a full scan for changes main already validated through its own gate).
  if [ "${RITE_TEST_GATE_SKIP_TRIGGERS:-false}" != "true" ]; then
    local _trigger _changed
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      for _trigger in "${_LINT_GATE_FULL_SUITE_TRIGGERS[@]}"; do
        # shellcheck disable=SC2254  # glob expansion in case is intentional
        case "$_changed" in
          $_trigger)
            echo "FORCE_FULL"
            return 0
            ;;
        esac
      done
    done <<< "$changed_files"
  fi

  # Emit absolute paths for changed files that look lint-eligible by path. The
  # final scope filter is the intersection inside sharkrite-lint.sh (it knows
  # exactly which files are in SHELL_FILES, including its own self-exclusion),
  # so this check just keeps the env-var compact and avoids passing obviously
  # irrelevant entries (docs, tests, etc).
  while IFS= read -r _changed; do
    [ -z "$_changed" ] && continue
    case "$_changed" in
      bin/*|lib/*|tools/*)
        [ -f "$project_root/$_changed" ] && echo "$project_root/$_changed"
        ;;
    esac
  done <<< "$changed_files"

  # Explicit return so the function never inherits the [ -f ] exit code from
  # the final iteration — contract is "returns 0 always; caller branches on stdout".
  return 0
}

# ---------------------------------------------------------------------------
# Bats pretty-formatter support detection (issue #484)
# ---------------------------------------------------------------------------
# bats-core 1.5+ supports `--report-formatter <type>` which writes a TAP
# stream to a file while rendering the chosen `--formatter` to stdout.  We use
# this to send pretty output to the terminal (stdout → FIFO-tee captures it in
# the run log too) and keep TAP in the temp file that `_parse_bats_failure_line`
# reads for JSON construction.
#
# Detection: grep the bats libexec core binary for the `--report-formatter`
# flag string.  The entrypoint (e.g. /opt/homebrew/bin/bats) is a thin wrapper
# that exec-delegates to $BATS_ROOT/libexec/bats-core/bats — the flag string
# lives only in the core binary.  Avoids a `bats --help` subprocess (which
# would fail inside tool hooks that deny test-runner invocations) and is stable
# across any bats version that ships the flag.
#
# Returns 0 when pretty+report-formatter is available, 1 otherwise.
_bats_has_report_formatter() {
  local _bats_bin _bats_real _bats_root _bats_core
  _bats_bin=$(command -v bats 2>/dev/null || true)
  [ -z "$_bats_bin" ] && return 1
  # The bats entrypoint at e.g. /opt/homebrew/bin/bats is a thin wrapper that
  # exec-delegates to $BATS_ROOT/libexec/bats-core/bats — only the libexec
  # binary contains the --report-formatter flag string.  Resolve the real path
  # of the entrypoint (following symlinks), strip two path components to get
  # BATS_ROOT (same as bats' own BATS_PATH%/*/* logic), then probe the core
  # binary.  Fall back to grepping the entrypoint itself for non-standard
  # installs where the core binary doesn't exist at the expected path.
  _bats_real=$(readlink -f "$_bats_bin" 2>/dev/null || true)
  [ -z "$_bats_real" ] && _bats_real="$_bats_bin"
  _bats_root="${_bats_real%/*/*}"
  _bats_core="$_bats_root/libexec/bats-core/bats"
  if [ -f "$_bats_core" ]; then
    grep -q -- '--report-formatter' "$_bats_core" 2>/dev/null
  else
    grep -q -- '--report-formatter' "$_bats_bin" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Bats parallelism (--jobs N) — opt-in, gated by GNU parallel availability
# ---------------------------------------------------------------------------
# bats-core natively supports `--jobs N` for file-level parallelism via GNU
# parallel (or shenwei356/rush). Default model: parallel ACROSS .bats files,
# serial WITHIN each file. The within-file serial guarantee means a test that
# touches shared state (e.g. /tmp/sharkrite-config-rce in
# test_config_parser.bats) is safe so long as the *other* parallel files don't
# also touch the same path — which the codebase already avoids via
# BATS_TEST_TMPDIR / BATS_FILE_TMPDIR / setup_test_tmpdir helpers.
#
# Default behavior is auto-detection:
#   - parallel installed → use ncpu (no cap)
#   - parallel missing   → serial (1)
# Override via RITE_BATS_JOBS=N (any positive int wins; set 1 to force serial).
#
# History: capped at 4 in #510 to "keep load reasonable on shared/CI boxes". On
# multi-core dev boxes the cap defeated the optimization. Measured on an 8-core
# MBP, the 9-file post-merge subset took 24s at --jobs 4 vs 18s at --jobs 8
# (25% faster single batch). Two concurrent batches: uncapped was STILL faster
# per batch (33s vs 38s) — under oversubscription the OS keeps all cores busy,
# while the cap leaves cores idle whenever the suite hits a serially-bound
# file. GitHub Actions free runners have ~4 cores so auto-detect there still
# yields 4. Users on truly shared boxes can pin a lower value via
# RITE_BATS_JOBS=N.
_compute_bats_jobs() {
  # Explicit override wins
  if [ -n "${RITE_BATS_JOBS:-}" ]; then
    # Sanitize: must be a positive integer
    if echo "${RITE_BATS_JOBS}" | grep -qE '^[1-9][0-9]*$'; then
      echo "${RITE_BATS_JOBS}"
      return 0
    fi
    # Garbage value → fall through to auto-detection
  fi
  # Auto-detection requires GNU parallel (or rush) on PATH
  if ! command -v parallel >/dev/null 2>&1 && ! command -v rush >/dev/null 2>&1; then
    echo 1
    return 0
  fi
  local _ncpu
  _ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)
  echo "$_ncpu"
}

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
#
# Default behavior changed after the all-files backfill landed (#480):
# headerless files are now SKIPPED, not included. The previous "headerless
# = always include" fallback gave the conservative-safe answer when most
# files lacked headers, but it also defeated the optimization (95%+ of
# files still ran every time). With 100% header coverage as the new
# baseline, missing headers are treated as missing coverage signal —
# enforce via the MISSING_TEST_COVERAGE_HEADER lint rule in sharkrite-lint.sh.
_bats_file_matches_changed() {
  local bats_file="$1"
  local changed_files="$2"
  local _header
  _header=$(_parse_test_coverage_header "$bats_file")
  if [ -z "$_header" ]; then
    # No header → exclude (new default; rule enforces backfill on new files)
    return 1
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
#   FORCE_FULL                              — run full suite (no diff computable ONLY)
#   <newline-separated list of bats files>  — targeted subset, relative to project_root
#   (empty)                                 — diff exists but no covered tests; caller skips bats
# Returns 0 always (caller handles empty/full).
# There are no path-based full-suite triggers — selection is always targeted
# (trigger list removed 2026-06-12; see the section header above).
_select_tests_by_changed_paths() {
  local changed_files="$1"
  local project_root="$2"

  # No diff → run full suite (degenerate but safe; e.g. brand-new branch, no
  # upstream). post-merge-verify.sh's main-broken check deliberately exploits
  # this: it sets RITE_TEST_GATE_DIFF_BASE=HEAD so the diff is empty and the
  # full suite validates main itself. Do not remove without giving that caller
  # an explicit force-full mechanism.
  if [ -z "$changed_files" ]; then
    echo "FORCE_FULL"
    return 0
  fi

  # Walk every bats file and decide inclusion. Output is relative paths so the
  # caller can `cd "$project_root" && bats <relative-paths>`.
  #
  # First rule (obvious-case shortcut): if the file IS itself in the diff, run
  # it. The sharkrite-test-covers header lists SOURCE paths, not test paths —
  # without this check, editing a .bats file would match no header anywhere,
  # the selection would come back empty, and the edited file's own tests
  # would never run for the very change that touched them.
  (cd "$project_root" && find tests -name "*.bats" -type f 2>/dev/null) \
    | while IFS= read -r _rel; do
        if echo "$changed_files" | grep -Fxq "$_rel"; then
          echo "$_rel"
          continue
        fi
        if _bats_file_matches_changed "$project_root/$_rel" "$changed_files"; then
          echo "$_rel"
        fi
      done
}

# ---------------------------------------------------------------------------
# Baseline-diff: new failures vs pre-existing red baseline
# ---------------------------------------------------------------------------
# Classifies each bats failure as NEW (introduced by this change) or
# PRE-EXISTING (already red on the diff base). Only NEW failures block the gate
# and reach the fix loop; pre-existing reds are reported via [diag] but
# suppressed from tests[], so the fix loop never churns on breakage this change
# did not cause. This is what makes the gate block-worthy: without it, ~30
# accumulated red tests on main made every failure look the same, so failing
# tests merged (the "gate-green gap").
#
# Cost model:
#   - GREEN runs pay ZERO (no failures → no baseline work at all).
#   - A FAILING run re-runs only the SELECTED files that actually contain a
#     failing test, at the diff base, in a throwaway detached worktree.
#   - Results are cached per base SHA, so fix-loop retries and later issues
#     against the same origin/main reuse them (no repeat probe).
# Fail-safe: any error (jq/git missing, unresolvable base, worktree failure,
# timeout) falls back to flagging ALL failures — never silently suppresses.
# Operator valve: RITE_GATE_BASELINE_DIFF=false disables it (flag all, as before).

# _tap_failure_name — canonical test name from a TAP "not ok N <name>" line.
# Strips the prefix, ANSI sequences, and trailing whitespace/CR. The branch
# extraction and the baseline comparison BOTH use this so the name sets match.
_tap_failure_name() {
  # printf '%s\n' (not '%s'): BSD sed preserves the absence of a final newline,
  # so feeding a newline-less line would emit a name with no trailing newline —
  # callers in a loop would then concatenate adjacent names. The '\n' guarantees
  # one name per line.
  printf '%s\n' "$1" | sed 's/^not ok [0-9]* //; s/\x1b\[[0-9;]*[a-zA-Z]//g; s/[[:space:]]*$//' || true
}

# _extract_tap_failure_names — newline-separated canonical names of every
# "not ok" line in a TAP file (stdin not used; arg is a file path).
_extract_tap_failure_names() {
  local _tap_file="$1" _line
  [ -f "$_tap_file" ] || return 0
  while IFS= read -r _line; do
    case "$_line" in
      "not ok "*) _tap_failure_name "$_line" ;;
    esac
  done < "$_tap_file"
}

# _json_array_from_lines — newline list (stdin) → JSON string array; drops blanks.
_json_array_from_lines() {
  jq -R . | jq -s 'map(select(length>0))' || echo "[]"
}

# _compute_baseline_red_names — run the given bats files (relpaths, newline) at
# <base_sha> in a throwaway detached worktree; stdout = canonical names of tests
# that are RED at baseline. Returns nonzero on setup failure (caller falls back).
# Overridable in tests (redefine before calling _classify_test_failures).
_compute_baseline_red_names() {
  local _project_root="$1" _base_sha="$2" _files="$3"
  [ -z "$_files" ] && return 0

  # Probe only files that EXIST at the base commit. A file new on the branch has
  # no baseline, so its failures are inherently new — the caller's membership
  # test classifies a name absent from baseline reds as new.
  local _existing=() _f
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    if (cd "$_project_root" && git cat-file -e "${_base_sha}:${_f}" 2>/dev/null); then
      _existing+=("$_f")
    fi
  done <<< "$_files"
  [ "${#_existing[@]}" -eq 0 ] && return 0

  local _wt
  _wt=$(mktemp -d "/tmp/rite_gate_baseline_${PR_NUMBER:-0}_$$_XXXXXX") || return 1
  rm -rf "$_wt"   # `git worktree add` requires a non-existent path
  if ! (cd "$_project_root" && git worktree add --detach --quiet "$_wt" "$_base_sha" 2>/dev/null); then
    rm -rf "$_wt" 2>/dev/null || true
    return 1
  fi

  # Bound the baseline run; on timeout we get partial/empty TAP → fewer
  # suppressions (fail-safe), never a hang.
  local _to_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    _to_cmd=(timeout "${RITE_GATE_BASELINE_TIMEOUT:-600}")
  elif command -v gtimeout >/dev/null 2>&1; then
    _to_cmd=(gtimeout "${RITE_GATE_BASELINE_TIMEOUT:-600}")
  fi

  local _tap
  _tap=$( (cd "$_wt" && "${_to_cmd[@]+"${_to_cmd[@]}"}" bats --formatter tap "${_existing[@]}" 2>/dev/null) || true )

  (cd "$_project_root" && git worktree remove --force "$_wt" 2>/dev/null) || rm -rf "$_wt" 2>/dev/null || true
  (cd "$_project_root" && git worktree prune 2>/dev/null) || true

  local _l
  while IFS= read -r _l; do
    case "$_l" in
      "not ok "*) _tap_failure_name "$_l" ;;
    esac
  done <<< "$_tap"
  return 0
}

# _classify_test_failures — split branch failures into new vs pre-existing.
# Args: $1=branch_tap_file $2=selected_files(newline relpaths)
#       $3=project_root $4=diff_base $5=out_file (NEW failing names written here)
# MUST be called directly (NOT in $()) — it sets the _GATE_* globals below as
# side effects, which a command-substitution subshell would discard. NEW names
# are returned via the out_file, not stdout, precisely so the caller can read
# them without a subshell.
# Sets (caller declares as local so dynamic scope captures them):
#   _GATE_BASELINE_MODE _GATE_BASE_SHA _GATE_TOTAL_FAIL _GATE_NEW_FAIL _GATE_PREEXISTING_FAIL
_classify_test_failures() {
  local _branch_tap="$1" _selected="$2" _project_root="$3" _diff_base="$4" _out_file="$5"
  _GATE_BASELINE_MODE="none"; _GATE_BASE_SHA=""
  _GATE_TOTAL_FAIL=0; _GATE_NEW_FAIL=0; _GATE_PREEXISTING_FAIL=0
  : > "$_out_file"

  local _branch_fails
  _branch_fails=$(_extract_tap_failure_names "$_branch_tap")
  _branch_fails=$(printf '%s\n' "$_branch_fails" | sed '/^$/d' | sort -u || true)
  [ -z "$_branch_fails" ] && return 0
  _GATE_TOTAL_FAIL=$(printf '%s\n' "$_branch_fails" | grep -c . || true)

  # Operator valve: disabled → flag everything (pre-baseline behavior).
  if [ "${RITE_GATE_BASELINE_DIFF:-true}" != "true" ]; then
    _GATE_BASELINE_MODE="disabled"; _GATE_NEW_FAIL="$_GATE_TOTAL_FAIL"
    printf '%s\n' "$_branch_fails" > "$_out_file"; return 0
  fi
  # Tooling missing → cannot diff → fail-safe flag-all.
  if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    _GATE_BASELINE_MODE="fallback"; _GATE_NEW_FAIL="$_GATE_TOTAL_FAIL"
    printf '%s\n' "$_branch_fails" > "$_out_file"; return 0
  fi

  # --verify + ^{commit}: `git rev-parse <bad-ref>` otherwise echoes the literal
  # arg to stdout and exits non-zero, which a non-empty check would wrongly accept.
  _GATE_BASE_SHA=$(cd "$_project_root" && git rev-parse --verify "${_diff_base}^{commit}" 2>/dev/null || true)
  if [ -z "$_GATE_BASE_SHA" ]; then
    _GATE_BASELINE_MODE="fallback"; _GATE_NEW_FAIL="$_GATE_TOTAL_FAIL"
    printf '%s\n' "$_branch_fails" > "$_out_file"; return 0
  fi

  # Attribute failures to files in ONE grep pass: which selected files contain a
  # failing test name. Only those need a baseline probe. Over-attribution (a name
  # also appearing in a comment) only over-probes — it never affects correctness.
  local _sel_arr=() _sf
  while IFS= read -r _sf; do
    [ -n "$_sf" ] && _sel_arr+=("$_project_root/$_sf")
  done <<< "$_selected"
  local _files_with_fails="" _names_tmp _abs
  if [ "${#_sel_arr[@]}" -gt 0 ]; then
    _names_tmp=$(mktemp "/tmp/rite_gate_names_${PR_NUMBER:-0}_$$.txt")
    printf '%s\n' "$_branch_fails" > "$_names_tmp"
    while IFS= read -r _abs; do
      [ -z "$_abs" ] && continue
      _files_with_fails+="${_abs#"$_project_root/"}"$'\n'
    done < <(grep -lF -f "$_names_tmp" -- "${_sel_arr[@]}" 2>/dev/null || true)
    rm -f "$_names_tmp"
  fi
  _files_with_fails=$(printf '%s' "$_files_with_fails" | sed '/^$/d' | sort -u || true)

  # Load per-base-SHA cache.
  local _cache_dir="${RITE_STATE_DIR:-$_project_root/.rite/state}"
  local _cache_file="$_cache_dir/gate-baseline-reds-${_GATE_BASE_SHA}.json"
  local _cached_probed="" _cached_reds=""
  if [ -f "$_cache_file" ]; then
    _cached_probed=$(jq -r '.probed_files[]?' "$_cache_file" 2>/dev/null || true)
    _cached_reds=$(jq -r '.red_names[]?' "$_cache_file" 2>/dev/null || true)
  fi

  # Files still needing a probe (not already cached for this base SHA).
  local _to_probe="" _f
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    if ! printf '%s\n' "$_cached_probed" | grep -Fxq -- "$_f"; then
      _to_probe+="$_f"$'\n'
    fi
  done <<< "$_files_with_fails"
  _to_probe=$(printf '%s' "$_to_probe" | sed '/^$/d' || true)

  local _newly_reds=""
  if [ -n "$_to_probe" ]; then
    _newly_reds=$(_compute_baseline_red_names "$_project_root" "$_GATE_BASE_SHA" "$_to_probe" || true)
    _newly_reds=$(printf '%s\n' "$_newly_reds" | sed '/^$/d' | sort -u || true)
    _GATE_BASELINE_MODE="computed"
    # Persist merged cache atomically (rename on same fs). Concurrent batch
    # writers tolerate this: a corrupt/missing read just triggers a recompute.
    mkdir -p "$_cache_dir" 2>/dev/null || true
    local _merged_probed _merged_reds _cache_tmp
    _merged_probed=$(printf '%s\n%s\n' "$_cached_probed" "$_to_probe" | sed '/^$/d' | sort -u | _json_array_from_lines || echo "[]")
    _merged_reds=$(printf '%s\n%s\n' "$_cached_reds" "$_newly_reds" | sed '/^$/d' | sort -u | _json_array_from_lines || echo "[]")
    _cache_tmp=$(mktemp "${_cache_dir}/.gate-baseline.XXXXXX" 2>/dev/null || true)
    if [ -n "$_cache_tmp" ]; then
      if jq -n --argjson p "$_merged_probed" --argjson r "$_merged_reds" '{probed_files:$p, red_names:$r}' > "$_cache_tmp" 2>/dev/null; then
        mv -f "$_cache_tmp" "$_cache_file" 2>/dev/null || rm -f "$_cache_tmp"
      else
        rm -f "$_cache_tmp"
      fi
    fi
  else
    _GATE_BASELINE_MODE="cached"
  fi

  # Full baseline-red name set = cached ∪ newly probed.
  local _all_reds
  _all_reds=$(printf '%s\n%s\n' "$_cached_reds" "$_newly_reds" | sed '/^$/d' | sort -u || true)

  # NEW = branch failures NOT red at baseline.
  local _new_names="" _name
  while IFS= read -r _name; do
    [ -z "$_name" ] && continue
    if printf '%s\n' "$_all_reds" | grep -Fxq -- "$_name"; then
      _GATE_PREEXISTING_FAIL=$(( _GATE_PREEXISTING_FAIL + 1 ))
    else
      _new_names+="$_name"$'\n'
      _GATE_NEW_FAIL=$(( _GATE_NEW_FAIL + 1 ))
    fi
  done <<< "$_branch_fails"
  printf '%s' "$_new_names" | sed '/^$/d' > "$_out_file" || true
  return 0
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
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_sc_exit_file:-}" "${_lint_exit_file:-}" "${_bats_exit_file:-}" "${_nonsr_exit_file:-}" "${_sc_raw_individual:-}" "${_lint_raw_individual:-}"
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

  # Baseline-diff state (populated by _classify_test_failures on a failing
  # targeted run). _baseline_applied gates the new-vs-pre-existing filtering in
  # the JSON builder and the overall-exit decision below.
  local _baseline_applied=false
  local _baseline_new_names=""
  local _GATE_BASELINE_MODE="" _GATE_BASE_SHA=""
  local _GATE_TOTAL_FAIL=0 _GATE_NEW_FAIL=0 _GATE_PREEXISTING_FAIL=0

  # Raw gate output (concurrent shellcheck+lint + bats pretty) is voluminous and
  # interleaves badly with other phases — the backgrounded review-loop gate
  # streams it concurrent with review generation, and a single failing test can
  # replay a whole nested rite transcript (e.g. source-all-libs.bats). Route it
  # to the run log only; the terminal gets a compact digest at the end (see the
  # summary block before _gate_write_json). This mirrors the established
  # two-channel convention (direct >> "$RITE_LOG_FILE", like [diag] lines). Fall
  # back to stdout when no log is configured (unlogged runs, sandboxed tests) so
  # output is never lost.
  local _gate_raw_sink="${RITE_LOG_FILE:-/dev/stdout}"

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

    # --- Compute changed-file set once for both lint and bats selection ---
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
      echo "[test-gate] Lint: full scan"
      _diag "LINT_GATE_SELECTION mode=full pr=${PR_NUMBER:-?}"
    elif [ -z "$_lint_selection" ]; then
      echo "[test-gate] Lint: no shell-source changes — skipping"
      _diag "LINT_GATE_SELECTION mode=skipped selected=0 pr=${PR_NUMBER:-?}"
    else
      _lint_selected_count=$(echo "$_lint_selection" | grep -c '.' || true)
      echo "[test-gate] Lint: targeted (${_lint_selected_count} changed shell file(s))"
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
    _sc_raw_individual=$(mktemp "/tmp/rite_gate_sc_raw_${PR_NUMBER:-0}_$$.txt")
    _lint_raw_individual=$(mktemp "/tmp/rite_gate_lint_raw_${PR_NUMBER:-0}_$$.txt")

    echo "[test-gate] Running make shellcheck + make lint (concurrent)..."
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
    _shellcheck_exit=$(cat "$_sc_exit_file" 2>/dev/null || echo 0)
    _lint_tool_exit=$(cat "$_lint_exit_file" 2>/dev/null || echo 0)

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
    # Headerless files are skipped. Selection is always targeted — FORCE_FULL
    # is reachable only when no diff is computable (new branch without an
    # upstream, or post-merge-verify's deliberate DIFF_BASE=HEAD main check).
    # See: _select_tests_by_changed_paths above.
    local _total_bats _selection _selected_count
    _total_bats=$(cd "$project_root" && find tests -name "*.bats" -type f 2>/dev/null | wc -l | tr -d ' ')
    _selection=$(_select_tests_by_changed_paths "$_changed_files" "$project_root")

    # --- Bats parallelism (--jobs N) ---
    # Auto-detect: use GNU parallel if installed (capped at 4 procs); serial
    # otherwise. RITE_BATS_JOBS=N overrides. File-level parallel only — within
    # each bats file, tests still run sequentially (bats-core default).
    local _bats_jobs _bats_jobs_args
    _bats_jobs=$(_compute_bats_jobs)
    if [ "$_bats_jobs" -gt 1 ]; then
      _bats_jobs_args=(--jobs "$_bats_jobs")
      echo "[test-gate] bats: parallel (--jobs ${_bats_jobs})"
    else
      _bats_jobs_args=()
      echo "[test-gate] bats: serial (parallel binary not found; install GNU parallel to enable)"
    fi
    _diag "BATS_JOBS jobs=${_bats_jobs} pr=${PR_NUMBER:-?}"

    # bats' pretty formatter shells out to `tput`; with TERM unset (launchd,
    # cron, non-TTY CI) tput errors and bats exits NON-ZERO even when every test
    # passes — the gate would then read that as a failing suite and spuriously
    # block the merge / fail post-merge-verify. Default TERM to a safe value so
    # the run is exit-code-honest in every environment. (Live trigger: any
    # headless invocation — the health-report and full-suite launchd jobs run
    # with no TERM.)
    export TERM="${TERM:-dumb}"

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
    if _bats_has_report_formatter; then
      _bats_use_pretty=true
      _bats_tap_dir=$(mktemp -d "/tmp/rite_gate_tap_${PR_NUMBER:-0}_$$_XXXXXX")
      echo "[test-gate] bats: pretty formatter (terminal) + TAP report (parser)"
    else
      echo "[test-gate] bats: TAP formatter (--report-formatter not available in installed bats)"
    fi

    if [ "$_selection" = "FORCE_FULL" ]; then
      _selected_count="$_total_bats"
      echo "[test-gate] Selection: full suite (${_total_bats} bats files — no diff computable)"
      _diag "TEST_GATE_SELECTION mode=full selected=${_total_bats} total=${_total_bats} pr=${PR_NUMBER:-?}"
      echo "[test-gate] Running bats -r tests/..."
      if [ "$_bats_use_pretty" = "true" ]; then
        { (cd "$project_root" && BATS_REPORT_FILENAME=report.tap \
            bats -F pretty --report-formatter tap --output "$_bats_tap_dir" \
            "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" -r tests/) >> "$_gate_raw_sink" 2>&1; \
          echo $? > "$_bats_exit_file"; } || true
        cp "$_bats_tap_dir/report.tap" "$_tests_raw_file" 2>/dev/null || : > "$_tests_raw_file"
      else
        { (cd "$project_root" && bats "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" -r tests/ 2>&1); echo $? > "$_bats_exit_file"; } \
          | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      fi
    elif [ -z "$_selection" ]; then
      # Diff exists but no bats file covers the changed paths. Run nothing —
      # this replaces the old escalate-to-full fallback (removed 2026-06-12:
      # a Makefile/fixture tweak forced all ~165 files for hours). Honest and
      # loud: the diag records selected=0 so the health report can watch for
      # systematic coverage gaps.
      _selected_count=0
      echo "[test-gate] Selection: targeted (0/${_total_bats} bats files — no covered tests for changed paths, skipping bats)"
      _diag "TEST_GATE_SELECTION mode=targeted selected=0 total=${_total_bats} pr=${PR_NUMBER:-?}"
      echo 0 > "$_bats_exit_file"
      : > "$_tests_raw_file"
    else
      _selected_count=$(echo "$_selection" | grep -c '.' || true)
      echo "[test-gate] Selection: targeted (${_selected_count}/${_total_bats} bats files based on changed paths)"
      _diag "TEST_GATE_SELECTION mode=targeted selected=${_selected_count} total=${_total_bats} pr=${PR_NUMBER:-?}"
      # Build array of selected files for bats invocation
      local _selected_files=()
      while IFS= read -r _bf; do
        [ -n "$_bf" ] && _selected_files+=("$_bf")
      done <<< "$_selection"
      echo "[test-gate] Running bats on ${#_selected_files[@]} selected files..."
      if [ "$_bats_use_pretty" = "true" ]; then
        { (cd "$project_root" && BATS_REPORT_FILENAME=report.tap \
            bats -F pretty --report-formatter tap --output "$_bats_tap_dir" \
            "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" "${_selected_files[@]}") >> "$_gate_raw_sink" 2>&1; \
          echo $? > "$_bats_exit_file"; } || true
        cp "$_bats_tap_dir/report.tap" "$_tests_raw_file" 2>/dev/null || : > "$_tests_raw_file"
      else
        { (cd "$project_root" && bats "${_bats_jobs_args[@]+"${_bats_jobs_args[@]}"}" "${_selected_files[@]}" 2>&1); echo $? > "$_bats_exit_file"; } \
          | tee "$_tests_raw_file" >> "$_gate_raw_sink" || true
      fi
    fi
    _tests_exit=$(cat "$_bats_exit_file" 2>/dev/null || echo 0)

    # Clean up tap dir if used (never a glob — scoped to this invocation's pid-named dir)
    [ -n "${_bats_tap_dir:-}" ] && rm -rf "${_bats_tap_dir:-}"

    rm -f "$_sc_exit_file" "$_lint_exit_file" "$_bats_exit_file"
    _tests_count=$(grep -c "^not ok " "$_tests_raw_file" || true)

    # --- Baseline-diff: classify failures as new vs pre-existing (gate-green gap) ---
    # Only the targeted path with a real selection has a diff base to compare
    # against; FORCE_FULL/no-diff (new branch, post-merge HEAD check) cannot be
    # baselined, so they keep the all-failures-block behavior.
    if [ "$_tests_exit" -ne 0 ] && [ "$_selection" != "FORCE_FULL" ] && [ -n "$_selection" ]; then
      # Direct call (NOT in $()) so _classify's _GATE_* globals survive; NEW
      # names come back via the out-file, not stdout.
      local _new_names_file
      _new_names_file=$(mktemp "/tmp/rite_gate_newnames_${PR_NUMBER:-0}_$$.txt")
      _classify_test_failures "$_tests_raw_file" "$_selection" "$project_root" "$_diff_base" "$_new_names_file"
      _baseline_new_names=$(cat "$_new_names_file" 2>/dev/null || true)
      rm -f "$_new_names_file"
      _baseline_applied=true
      _diag "TEST_GATE_BASELINE base=${_GATE_BASE_SHA:-?} mode=${_GATE_BASELINE_MODE:-?} total_fail=${_GATE_TOTAL_FAIL:-0} new=${_GATE_NEW_FAIL:-0} pre_existing=${_GATE_PREEXISTING_FAIL:-0} pr=${PR_NUMBER:-?}"
      if [ "${_GATE_PREEXISTING_FAIL:-0}" -gt 0 ]; then
        echo "[test-gate] Baseline-diff: ${_GATE_TOTAL_FAIL} failing test(s) → ${_GATE_NEW_FAIL} new (this change), ${_GATE_PREEXISTING_FAIL} pre-existing on ${_diff_base} (suppressed; mode=${_GATE_BASELINE_MODE})"
      fi
      # test_count tracks the BLOCKING count so outcome=passed ⟺ test_count=0.
      # The total/split is preserved in the TEST_GATE_BASELINE diag above.
      _tests_count="${_GATE_NEW_FAIL:-0}"
    fi
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
  local _rawname=""
  while IFS= read -r _raw; do
    # Baseline-diff: when applied, keep only NEW failures (this change's). A
    # "not ok" whose canonical name is not in _baseline_new_names is a
    # pre-existing red on the diff base — suppress it from tests[].
    if [ "$_baseline_applied" = "true" ]; then
      case "$_raw" in
        "not ok "*)
          _rawname=$(_tap_failure_name "$_raw")
          if ! printf '%s\n' "$_baseline_new_names" | grep -Fxq -- "$_rawname"; then
            continue
          fi
          ;;
      esac
    fi
    _item=$(_parse_bats_failure_line "$_raw" 2>/dev/null || true)
    if [ -n "$_item" ]; then
      [ "$_first_test" = "true" ] || _tests_items+=","
      _tests_items+="$_item"
      _first_test=false
    fi
  done < "$_tests_raw_file"
  _tests_items+="]"

  # --- Capture terminal-digest inputs before the raw TAP file is removed ---
  # _bats_pass/_bats_fail_total come from the TAP report; _summary_names are the
  # blocking (new) failures to name on the terminal. With baseline-diff applied
  # the blocking set is _baseline_new_names; otherwise (FORCE_FULL / no diff)
  # every failure blocks, so name them all.
  local _bats_pass=0 _bats_fail_total=0 _summary_names=""
  if [ "$_is_sharkrite" = "true" ]; then
    _bats_pass=$(grep -c "^ok " "$_tests_raw_file" 2>/dev/null || true)
    _bats_fail_total=$(grep -c "^not ok " "$_tests_raw_file" 2>/dev/null || true)
    if [ "$_baseline_applied" = "true" ]; then
      _summary_names="$_baseline_new_names"
    elif [ "$_bats_fail_total" -gt 0 ]; then
      _summary_names=$(_extract_tap_failure_names "$_tests_raw_file")
    fi
  fi

  rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}"
  trap - EXIT

  # --- Determine overall exit code and outcome ---
  # When baseline-diff applied, tests block only on NEW failures (this change's);
  # pre-existing reds on the diff base do not fail the gate. Otherwise (non-
  # sharkrite, FORCE_FULL, no diff) any test failure blocks, as before.
  local _overall_exit=0
  local _outcome="passed"
  local _tests_blocking=0
  if [ "$_baseline_applied" = "true" ]; then
    [ "${_GATE_NEW_FAIL:-0}" -gt 0 ] && _tests_blocking=1
  else
    [ "$_tests_exit" -ne 0 ] && _tests_blocking=1
  fi
  if [ "$_lint_exit" -ne 0 ] || [ "$_tests_blocking" -ne 0 ]; then
    _overall_exit=1
    _outcome="failed"
  fi

  local _gate_end
  _gate_end=$(date +%s)
  local _duration=$(( _gate_end - _gate_start ))

  _diag "TEST_GATE outcome=${_outcome} lint_count=${_lint_count} test_count=${_tests_count} duration_s=${_duration} pr=${PR_NUMBER:-?}"

  # --- Compact terminal digest (Sharkrite bats path) ---
  # The raw bats/lint output went to the run log only (_gate_raw_sink); surface
  # just the high-signal result here so concurrent phases aren't drowned. New
  # (blocking) failures are named; pre-existing/suppressed ones stay in the log.
  if [ "$_is_sharkrite" = "true" ]; then
    if [ "$_lint_count" -gt 0 ]; then
      echo "[test-gate] lint: ${_lint_count} finding(s) blocking — full output in run log"
    fi
    if [ "$_bats_fail_total" -gt 0 ]; then
      if [ "$_baseline_applied" = "true" ] && [ "${_GATE_PREEXISTING_FAIL:-0}" -gt 0 ]; then
        echo "[test-gate] bats: ${_bats_pass} passed, ${_bats_fail_total} failed → ${_GATE_NEW_FAIL:-0} new (blocking), ${_GATE_PREEXISTING_FAIL} pre-existing (suppressed)"
      else
        echo "[test-gate] bats: ${_bats_pass} passed, ${_bats_fail_total} failed (blocking)"
      fi
      if [ -n "$_summary_names" ]; then
        local _ncount
        _ncount=$(printf '%s\n' "$_summary_names" | grep -c '.' || true)
        echo "⚠️  ${_ncount} new test failure(s) blocking the gate:"
        printf '%s\n' "$_summary_names" | while IFS= read -r _n; do
          [ -n "$_n" ] && echo "   • ${_n}"
        done
        [ -n "${RITE_LOG_FILE:-}" ] && echo "   Full bats output: ${RITE_LOG_FILE}"
      fi
    elif [ "$_bats_pass" -gt 0 ]; then
      echo "[test-gate] bats: ${_bats_pass} passed, 0 failed ✅"
    fi
  fi

  _gate_write_json "$output_file" "$_lint_items" "$_tests_items" "$_overall_exit"
  return "$_overall_exit"
}
