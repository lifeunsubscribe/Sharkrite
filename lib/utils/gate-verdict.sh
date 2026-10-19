#!/bin/bash
# lib/utils/gate-verdict.sh — Gate JSON output, lint/test parsers, TAP analysis
#
# Extracted from lib/utils/test-gate.sh (issue #1236). Contains verdict/output
# and parsing helpers. Sourced by test-gate.sh before run_test_gate.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f _gate_write_json >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Compute self_dir unconditionally — needed for gate-runners.sh below, which is a
# co-located new file that may not be in RITE_LIB_DIR on un-reinstalled dev worktrees.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_self_dir/config.sh"
fi

source "$RITE_LIB_DIR/utils/logging.sh"
source "$_self_dir/gate-runners.sh"

# ---------------------------------------------------------------------------
# _gate_write_json — emit structured gate result JSON
# Args: $1=output_file $2=lint_json_array $3=tests_json_array $4=exit_code
#       $5=skipped(true|false) $6=reason(optional) $7=head_sha(optional)
#
# When skipped=true the reason explains why (e.g. "missing_runner").
# When skipped=false and reason is non-empty (e.g. "runner_unavailable") the
# reason field is included in the non-skipped JSON so assess-and-resolve.sh
# can name the cause when synthesizing a blocking [GATE] item for a failure
# that produced no parseable lint/test array entries.
#
# head_sha (arg 7): the HEAD SHA of the worktree at gate-run time, embedded so
# assess-and-resolve.sh can verify the verdict covers the current HEAD before
# consuming it (issue #986 — gate verdict SHA pinning). Only populated for the
# final PASS/FAIL verdict write (not for skipped sentinel writes).
# ---------------------------------------------------------------------------
_gate_write_json() {
  local output_file="$1"
  local lint_json="$2"
  local tests_json="$3"
  local exit_code="$4"
  local skipped="${5:-false}"
  local reason="${6:-}"
  local head_sha="${7:-}"

  if [ "$skipped" = "true" ]; then
    printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"%s"}\n' "$reason" > "$output_file"
  elif [ -n "$reason" ] && [ -n "$head_sha" ]; then
    # Non-skipped failure with a named reason and SHA.
    printf '{"lint":%s,"tests":%s,"exit_code":%s,"reason":"%s","head_sha":"%s"}\n' \
      "$lint_json" "$tests_json" "$exit_code" "$reason" "$head_sha" > "$output_file"
  elif [ -n "$reason" ]; then
    # Non-skipped failure with a named reason (e.g. runner_unavailable).
    # Include the reason field so assess-and-resolve.sh can synthesize a
    # descriptive blocking [GATE] item even when lint[] and tests[] are empty.
    printf '{"lint":%s,"tests":%s,"exit_code":%s,"reason":"%s"}\n' \
      "$lint_json" "$tests_json" "$exit_code" "$reason" > "$output_file"
  elif [ -n "$head_sha" ]; then
    printf '{"lint":%s,"tests":%s,"exit_code":%s,"head_sha":"%s"}\n' \
      "$lint_json" "$tests_json" "$exit_code" "$head_sha" > "$output_file"
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
  # gcc format (-f gcc): path/file.sh:LINE:COL: level: message [SCnnnn]
  # E.g.: lib/foo.sh:42:5: warning: Double quote to prevent globbing. [SC2086]
  if echo "$raw_line" | grep -qE '^[^:]+:[0-9]+:[0-9]+:.*\[SC[0-9]+\]'; then
    local file line rule message
    file=$(echo "$raw_line" | cut -d: -f1 || true)
    line=$(echo "$raw_line" | cut -d: -f2 || true)
    rule=$(echo "$raw_line" | grep -oE '\[SC[0-9]+\]' | tail -1 | tr -d '[]' || true)
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
# _gate_flake_retry_pass RAW_FILE PROJECT_ROOT — one bounded serial retry of
# failing bats FILES (#938). A load-flake blocks a merge exactly like a real
# failure (live 2026-07-05: three merges blocked by failures that passed 3x in
# isolation minutes later). Contract:
#   - Extract failing test names from RAW_FILE's TAP; map them to files by
#     grepping the selection (dynamic-scoped _parallel_files/_serial_files —
#     targeted path only; the full-suite path has no selection and skips).
#   - 1..RITE_GATE_FLAKE_RETRY_MAX_FILES (default 5) failing files → re-run
#     JUST those files once, serially (no --jobs). More = real breakage, no
#     retry (logged). RITE_GATE_FLAKE_RETRY=false disables entirely.
#   - Tests passing on the quiet re-run are load-flakes: their `not ok N name`
#     lines are FLIPPED to `ok N name` in RAW_FILE (numbering preserved so the
#     #804 plan-deficit detector's math is untouched), and they are named
#     LOUDLY (health reports must keep seeing recurring flakes — cleared, not
#     silently absorbed). Failures persisting on the re-run keep blocking
#     exactly as before (block-on-any preserved for real reds).
# Echoes the recomputed tests-exit (0 when no `not ok` remains, else 1).
# Never called after a watchdog kill (caller guards) — a timeout is not a flake.
# ---------------------------------------------------------------------------
_gate_flake_retry_pass() {
  local _fr_raw="$1" _fr_root="$2"
  local _fr_max="${RITE_GATE_FLAKE_RETRY_MAX_FILES:-5}"

  # Failing test names from TAP (skip #804 synthetics — "never ran" entries
  # were not executed, there is nothing to retry; they indicate a swallow).
  local _fr_names
  _fr_names=$(grep -E '^not ok [0-9]+ ' "$_fr_raw" 2>/dev/null \
    | sed -E 's/^not ok [0-9]+ //' | grep -v '^\[tests_not_run\]' || true)
  [ -z "$_fr_names" ] && { echo 1; return 0; }

  # Map names -> files across the selection (targeted path only).
  # _parallel_files/_serial_files/_bats_sandbox are dynamically scoped from
  # run_test_gate (caller sets them as locals; bash dynamic scoping passes them).
  # shellcheck disable=SC2154
  local _fr_selection=()
  # shellcheck disable=SC2154
  _fr_selection+=("${_parallel_files[@]+"${_parallel_files[@]}"}")
  # shellcheck disable=SC2154
  _fr_selection+=("${_serial_files[@]+"${_serial_files[@]}"}")
  if [ "${#_fr_selection[@]}" -eq 0 ]; then
    echo 1; return 0
  fi
  local _fr_files="" _fr_name _fr_hit
  while IFS= read -r _fr_name; do
    [ -z "$_fr_name" ] && continue
    # Strip a trailing " # timeout after Ns"-style TAP directive before matching.
    _fr_name="${_fr_name%% # *}"
    _fr_hit=$(grep -lF "$_fr_name" "${_fr_selection[@]+"${_fr_selection[@]}"}" 2>/dev/null | head -1 || true)
    [ -n "$_fr_hit" ] && _fr_files="${_fr_files}${_fr_hit}"$'\n'
  done <<< "$_fr_names"
  _fr_files=$(printf '%s' "$_fr_files" | sort -u | grep -v '^$' || true)
  local _fr_file_count
  _fr_file_count=$(printf '%s\n' "$_fr_files" | grep -c . || true)

  if [ "${_fr_file_count:-0}" -lt 1 ]; then
    echo 1; return 0   # names unmappable (fixture-generated?) — no retry
  fi
  if [ "$_fr_file_count" -gt "$_fr_max" ]; then
    _gate_status "[test-gate] ${_fr_file_count} files failing (> ${_fr_max}) — skipping flake retry, treating as real breakage"
    echo 1; return 0
  fi

  _gate_status "[test-gate] Flake retry: re-running ${_fr_file_count} failing file(s) once, serially..."
  local _fr_retry_raw _fr_retry_exit=0
  _fr_retry_raw=$(mktemp "/tmp/rite_gate_flake_retry_${PR_NUMBER:-0}_$$_XXXXXX")
  local _fr_file_arr=()
  while IFS= read -r _fr_hit; do
    [ -n "$_fr_hit" ] && _fr_file_arr+=("$_fr_hit")
  done <<< "$_fr_files"
  # shellcheck disable=SC2154
  { (cd "$_fr_root" && "${_bats_sandbox[@]+"${_bats_sandbox[@]}"}" \
      bats "${_fr_file_arr[@]+"${_fr_file_arr[@]}"}" < /dev/null 2>&1); \
    echo $? > "${_fr_retry_raw}.exit"; } >> "$_fr_retry_raw" || true
  _fr_retry_exit=$(cat "${_fr_retry_raw}.exit" 2>/dev/null || echo 1)
  _fr_retry_exit=${_fr_retry_exit:-1}
  rm -f "${_fr_retry_raw}.exit"

  # Which of the original failures STILL fail on the quiet run?
  local _fr_persist
  _fr_persist=$(grep -E '^not ok [0-9]+ ' "$_fr_retry_raw" 2>/dev/null \
    | sed -E 's/^not ok [0-9]+ //' | sed 's/ # .*//' || true)
  rm -f "$_fr_retry_raw"

  # Flip cleared failures to ok IN PLACE (numbering preserved for #804 math).
  local _fr_cleared=0 _fr_persisted=0 _fr_cleared_names=""
  while IFS= read -r _fr_name; do
    [ -z "$_fr_name" ] && continue
    local _fr_clean="${_fr_name%% # *}"
    if printf '%s\n' "$_fr_persist" | grep -qxF "$_fr_clean"; then
      _fr_persisted=$((_fr_persisted + 1))
      continue
    fi
    # awk exact-line flip (sed would need escaping the arbitrary test name)
    awk -v tgt="not ok" -v name="$_fr_name" '
      index($0, "not ok ") == 1 && substr($0, index($0, " " name)) == " " name {
        n = $3; print "ok " n " " name; next
      }
      { print }
    ' FS=' ' "$_fr_raw" > "${_fr_raw}.flip" && mv "${_fr_raw}.flip" "$_fr_raw"
    _fr_cleared=$((_fr_cleared + 1))
    _fr_cleared_names="${_fr_cleared_names}${_fr_clean}; "
  done <<< "$_fr_names"

  if [ "$_fr_cleared" -gt 0 ]; then
    _gate_status "[test-gate] ${_fr_cleared} failure(s) cleared on serial re-run (load flake): ${_fr_cleared_names%??}"
  fi
  _diag "TEST_GATE_FLAKE_RETRY cleared=${_fr_cleared} persisted=${_fr_persisted} files=${_fr_file_count} retry_exit=${_fr_retry_exit} pr=${PR_NUMBER:-?}"

  if grep -qE '^not ok [0-9]+ ' "$_fr_raw" 2>/dev/null; then
    echo 1
  else
    echo 0
  fi
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
    local test_name _stripped _reason
    # Strip the "not ok N " prefix, then ANSI/control bytes + JSON-escape via the
    # shared helper (portable across BSD/GNU sed — the old inline hex-range sed
    # errored on macOS and emptied the name).
    _stripped=$(echo "$raw_line" | sed 's/^not ok [0-9]* //' || true)
    test_name=$(_sanitize_json_value "$_stripped" || true)
    # Synthetic not-run findings (issue #804) carry a [tests_not_run] marker so
    # the per-item reason names the real cause instead of "assertion failed".
    _reason="assertion failed"
    case "$_stripped" in
      "[tests_not_run]"*) _reason="tests_not_run" ;;
    esac
    printf '{"file":"bats","test_name":"%s","reason":"%s"}' "$test_name" "$_reason"
    return 0
  fi
  return 1
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
# TAP failure-name helpers — extract canonical test names for the gate digest.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Not-run detection helpers (issue #804)
# ---------------------------------------------------------------------------
# bats-core 1.13 exits non-zero when fewer tests execute than the 1..N plan
# even with 0 reported failures, and a test killed before emitting its result
# writes NOTHING to report.tap. Without detection the gate reports exit_code=1
# with test_count=0 and the fix loop gets zero nameable findings (four blind
# rounds on PR #828).
# ---------------------------------------------------------------------------

# _tap_plan_deficit — total "planned but never reported" test count across a
# (possibly concatenated) TAP report file. Each bats invocation appended to
# the file starts its own section with a `1..N` plan line; result lines are
# `ok N ...` / `not ok N ...`. Deficit = sum over sections of plan - results.
# Args: $1=tap_file  Stdout: non-negative integer (0 = no mismatch).
_tap_plan_deficit() {
  local _tap_file="$1"
  [ -f "$_tap_file" ] || { echo 0; return 0; }
  awk '
    /^1\.\.[0-9]+$/ {
      if (plan > run) deficit += plan - run
      plan = substr($0, 4) + 0
      run = 0
      next
    }
    /^ok / { run++; next }
    /^not ok / { run++; next }
    END {
      if (plan > run) deficit += plan - run
      print deficit + 0
    }
  ' "$_tap_file" 2>/dev/null || echo 0
}

# _extract_notrun_test_names — names of planned tests that never reported a
# result. Set difference: planned test descriptions (parsed from the SELECTED
# .bats files' @test lines) minus descriptions appearing in the TAP report's
# result lines.
#
# The pre-#862 implementation drew names from the captured pretty stream,
# whose begin fragments the formatter TRUNCATES at terminal width with `...`
# — truncated begins never exact-matched full result names, yielding 130
# phantom findings for a deficit of 1 (PR #852 gate, 2026-07-03; every
# phantom name in that log carries a `...` suffix). The TAP report is the
# authoritative record: every test that reported a result has an `ok N desc`
# / `not ok N desc` line there; a swallowed test has none. Names here come
# only from TAP + on-disk sources, never from the display stream, and the
# caller caps emission at the bats-reported deficit — so ANY residual
# corruption mechanism is bounded.
#
# Description matching mirrors bats-preprocess (BATS_TEST_PATTERN): the
# description is the raw @test-line text up to the LAST blank+`{`, with ONE
# leading and ONE trailing quote char stripped. bats DOES shell-evaluate
# double-quoted descriptions when sourcing the preprocessed file (verified on
# bats 1.13.0 via report.tap bytes and BATS_TEST_DESCRIPTION): `\"` `\$`
# `` \` `` `\\` collapse to the bare character. Planned descriptions from
# double-quoted @test lines are therefore unescaped the same way before the
# set difference; single-quoted descriptions stay literal. TAP directives the
# formatter appends (` # skip[ reason]`, ` # timeout after Ns`, ` # in N ms`
# with --timing) are stripped from result lines before comparison.
#
# Known imprecision: @test lines embedded in heredocs (test files that
# generate fixture .bats files) inflate the planned set. That makes the
# missing count disagree with the TAP deficit, which routes the caller to the
# capped file-level fallback — degraded naming, never phantom names.
#
# Args: $1=tap_results_file  $2=selected-files list (one .bats path per line,
#       relative to $3)  $3=project_root
# Stdout: one `<file>\t<description>` line per planned-but-unreported test
#         (multiset difference — a description shared by K planned tests with
#         only J<K results yields K-J missing lines). May be empty.
_extract_notrun_test_names() {
  local _tap_file="$1" _files_list="$2" _root="$3"
  [ -s "$_files_list" ] || return 0
  local _planned _executed _bf _raw _desc
  _planned=$(mktemp "/tmp/rite_gate_notrun_p_${PR_NUMBER:-0}_$$_XXXXXX")
  _executed=$(mktemp "/tmp/rite_gate_notrun_x_${PR_NUMBER:-0}_$$_XXXXXX")
  while IFS= read -r _bf; do
    [ -z "$_bf" ] && continue
    [ -f "$_root/$_bf" ] || continue
    # Greedy BRE mirrors bats' greedy ERE: the capture extends to the LAST
    # blank+`{` on the line, so descriptions containing `{` survive.
    while IFS= read -r _raw; do
      # Strip one leading + one trailing quote char (what bats-preprocess
      # does), then mirror bats' shell evaluation of the description text:
      # double-quoted descriptions collapse \" \$ \` \\ to the bare char
      # (single-pass, left-to-right — matches double-quote semantics);
      # single-quoted descriptions are literal.
      case "$_raw" in
        \"*)
          _desc="${_raw#\"}"
          _desc="${_desc%\"}"
          case "$_desc" in
            *\\*) _desc=$(printf '%s\n' "$_desc" | sed 's/\\\([\\"$`]\)/\1/g' || true) ;;
          esac
          ;;
        \'*)
          _desc="${_raw#\'}"
          _desc="${_desc%\'}"
          ;;
        *)
          _desc="$_raw"
          ;;
      esac
      [ -z "$_desc" ] && continue
      printf '%s\t%s\n' "$_bf" "$_desc" >> "$_planned"
    done < <(sed -n 's/^[[:blank:]]*@test[[:blank:]]\{1,\}\(.*[^[:blank:]]\)[[:blank:]]\{1,\}{.*$/\1/p' "$_root/$_bf" || true)
  done < "$_files_list"
  if [ -f "$_tap_file" ]; then
    awk '
      {
        line = $0
        if (line ~ /^not ok [0-9]+ /) sub(/^not ok [0-9]+ /, "", line)
        else if (line ~ /^ok [0-9]+ /) sub(/^ok [0-9]+ /, "", line)
        else next
        sub(/ # skip( .*)?$/, "", line)
        sub(/ # timeout after [0-9]+s$/, "", line)
        sub(/ # in [0-9]+ ms$/, "", line)
        print line
      }
    ' "$_tap_file" >> "$_executed" 2>/dev/null || true
  fi
  # Multiset difference: consume one executed slot per matching planned
  # description; whatever cannot be consumed never reported a result.
  # FILENAME==ARGV[1] (not NR==FNR) — correct even when executed is empty.
  awk '
    FILENAME == ARGV[1] { execd[$0]++; next }
    {
      d = $0
      sub(/^[^\t]*\t/, "", d)
      if (execd[d] > 0) { execd[d]--; next }
      print
    }
  ' "$_executed" "$_planned" || true
  rm -f "$_planned" "$_executed"
  return 0
}

# _synthesize_notrun_findings — append synthetic `not ok N [tests_not_run] ...`
# lines to the raw TAP results file, CAPPED at the bats-reported deficit.
#
# Cap contract (#862): the finding count can never exceed the deficit. When
# the set difference resolves exactly deficit-many names, each finding names
# its test. Any disagreement (dynamic/unparseable descriptions, heredoc
# inflation, cross-file duplicates) is ambiguous — emit deficit-many findings
# naming the affected FILE(s) instead. Never phantom test names.
#
# Args: $1=tests_raw_file (TAP results; findings APPENDED in place)
#       $2=selected-files list file (one .bats path per line, relative to $4)
#       $3=deficit (integer >= 0 from _tap_plan_deficit)
#       $4=project_root
#       $5=bats warning text ("Executed X instead of expected Y tests"; may be "")
# Stdout: one `named=<n> emitted=<m>` summary line for the caller's diag/log.
_synthesize_notrun_findings() {
  local _raw_file="$1" _files_list="$2" _deficit="$3" _root="$4" _warning="${5:-}"
  local _eff="$_deficit" _names="" _missing_count=0 _emitted=0 _named=0 _nn _name
  # Effective deficit: TAP plan arithmetic first; else derive it from the bats
  # warning ("Executed X instead of expected Y tests" → Y-X); floor 1 — this
  # function only runs after bats reported a mismatch, so at least one test is
  # unaccounted for.
  if [ "${_eff:-0}" -le 0 ] && [ -n "$_warning" ]; then
    _eff=$(echo "$_warning" | awk '{ d = $6 - $2; print (d > 0 ? d : 0) }' || true)
  fi
  [ -z "$_eff" ] && _eff=0
  [ "$_eff" -le 0 ] && _eff=1
  _names=$(_extract_notrun_test_names "$_raw_file" "$_files_list" "$_root")
  if [ -n "$_names" ]; then
    _missing_count=$(printf '%s\n' "$_names" | grep -c '.' || true)
  fi
  if [ "$_missing_count" -gt 0 ] && [ "$_missing_count" -eq "$_eff" ]; then
    # Unambiguous: planned-minus-reported resolves exactly deficit-many names.
    while IFS= read -r _nn; do
      [ -z "$_nn" ] && continue
      _name="${_nn#*$'\t'}"
      _emitted=$(( _emitted + 1 ))
      printf 'not ok %s [tests_not_run] %s — planned but never reported a result (bats plan/executed mismatch; killed before reporting)\n' \
        "$_emitted" "$_name" >> "$_raw_file"
    done <<< "$_names"
    _named=$_emitted
  else
    # Ambiguous — emit deficit-many findings naming the affected file(s).
    local _files_label
    _files_label=$(printf '%s\n' "$_names" | cut -f1 | grep -v '^$' | sort -u | paste -sd, - || true)
    [ -z "$_files_label" ] && _files_label="selected bats file(s)"
    while [ "$_emitted" -lt "$_eff" ]; do
      _emitted=$(( _emitted + 1 ))
      printf 'not ok %s [tests_not_run] planned test in %s never reported a result (%s) — test name unresolvable; check the run log\n' \
        "$_emitted" "$_files_label" "${_warning:-bats plan/executed mismatch}" >> "$_raw_file"
    done
  fi
  printf 'named=%s emitted=%s\n' "$_named" "$_emitted"
  return 0
}
