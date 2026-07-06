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
#
# When skipped=true the reason explains why (e.g. "missing_runner").
# When skipped=false and reason is non-empty (e.g. "runner_unavailable") the
# reason field is included in the non-skipped JSON so assess-and-resolve.sh
# can name the cause when synthesizing a blocking [GATE] item for a failure
# that produced no parseable lint/test array entries.
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
  elif [ -n "$reason" ]; then
    # Non-skipped failure with a named reason (e.g. runner_unavailable).
    # Include the reason field so assess-and-resolve.sh can synthesize a
    # descriptive blocking [GATE] item even when lint[] and tests[] are empty.
    printf '{"lint":%s,"tests":%s,"exit_code":%s,"reason":"%s"}\n' \
      "$lint_json" "$tests_json" "$exit_code" "$reason" > "$output_file"
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
  local _fr_selection=()
  _fr_selection+=("${_parallel_files[@]+"${_parallel_files[@]}"}")
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
# _normalize_node_test_output — synthesize TAP "not ok" lines from jest/vitest
# failure output.
#
# The gate's failure plumbing is TAP-only: the test_count diag greps "^not ok "
# and the tests[] JSON loop feeds _parse_bats_failure_line (^not ok N ). Jest
# and vitest never emit TAP, so a real node test failure yielded test_count=0
# and an empty tests[] array — assess-and-resolve.sh then fired only the
# generic "no parseable findings" item and the fix session investigated blind
# (LeadFlow PR #587: 53+ real failures, test_count=0).
#
# Rather than teach every consumer a second format, append deduped synthetic
# "not ok N - <workspace>: <file>: <test>" lines to the raw output file — the
# same trick the workspace-build failure path uses — so all existing ^not ok
# plumbing picks the failures up unchanged. Forcing jest --json/reporters is
# not viable: rite only controls the root `npm test`; per-workspace runner
# flags live in each target repo's package.json (LeadFlow mixes jest+vitest).
#
# Patterns (ANSI-stripped first):
#   jest suite     : "FAIL <path>[ (N.N s)]" at column 0
#   jest per-test  : "  ● <suite> › <test>" — the › separator is required
#                    (jest also emits bullet noise without it, e.g.
#                    "● Cannot log after tests are done.")
#   vitest suite   : " FAIL  <path> [ <path> ]" (leading whitespace)
#   vitest per-test: " FAIL  <path> > <suite> > <test>"
#   fallback       : a "Tests/Test Files/Test Suites: N failed" summary when
#                    no per-line pattern matched (fully-silenced reporters)
# Workspace attribution: "> pkg@ver test" banners name the block; a trailing
# "npm error location <abs>" upgrades the prefix to the project-relative dir.
# A suite entry is dropped when per-test entries exist for the same file.
#
# Args: $1 = raw tests output file (synthetic lines APPENDED in place;
#            numbering continues after any existing "not ok" lines)
#       $2 = project_root (optional — relativizes npm error location paths)
# Returns 0 always; leaves the file untouched when nothing matched (the
# assess-side no-findings synthetic block remains the final backstop).
# ---------------------------------------------------------------------------
_normalize_node_test_output() {
  local raw_file="$1"
  local norm_root="${2:-}"
  [ -s "$raw_file" ] || return 0

  local _norm_cap=50
  local _norm_stripped _norm_extracted
  _norm_stripped=$(mktemp "/tmp/rite_gate_norm_strip_$$_XXXXXX")
  _norm_extracted=$(mktemp "/tmp/rite_gate_norm_desc_$$_XXXXXX")
  # ANSI-strip first (same expression as _sanitize_json_value): npm piped
  # output is normally plain, but some reporters force color.
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b//g' "$raw_file" > "$_norm_stripped" || true

  awk -v root="$norm_root" '
    function flush(   i, pfx, out) {
      pfx = (wsdir != "") ? wsdir : wsname
      for (i = 1; i <= n; i++) {
        if (typ[i] == "suite" && hasdetail[fil[i]]) continue
        out = (pfx != "") ? pfx ": " buf[i] : buf[i]
        if (!(out in seen)) { seen[out] = 1; print out }
      }
      n = 0; wsdir = ""
      for (i in hasdetail) delete hasdetail[i]
    }
    # workspace banner: "> pkg@version test" — starts a new attribution block
    /^> [^ ]+@[^ ]+ test$/ {
      flush()
      wsname = $2; sub(/@[^@]*$/, "", wsname)
      cursuite = ""
      next
    }
    # npm error location — closes the failing workspace block; prefer the
    # project-relative directory over the package name when derivable
    /^npm error location / {
      if (root != "" && index($4, root "/") == 1)
        wsdir = substr($4, length(root) + 2)
      flush()
      next
    }
    # jest suite failure at column 0; path guard rejects the bare word FAIL
    # in code snippets (real paths contain "/" or .test./.spec.)
    substr($0, 1, 5) == "FAIL " {
      p = $2
      if (p ~ /\// || p ~ /\.(test|spec)\./) {
        cursuite = p
        n++; buf[n] = p ": test suite failed"; typ[n] = "suite"; fil[n] = p
      }
      next
    }
    # jest per-test bullet — file comes from the preceding suite FAIL line
    /^[[:space:]]*● / && / › / {
      t = $0
      sub(/^[[:space:]]*● /, "", t)
      n++; typ[n] = "test"
      if (cursuite != "") { buf[n] = cursuite ": " t; hasdetail[cursuite] = 1 }
      else buf[n] = t
      next
    }
    # vitest lines: leading whitespace + FAIL + path, then "[" (suite) or ">"
    # (per-test — the description already carries the file)
    /^[[:space:]]+FAIL[[:space:]]/ {
      p = $2
      if (p ~ /\// || p ~ /\.(test|spec)\./) {
        if ($3 == ">") {
          t = $0
          sub(/^[[:space:]]+FAIL[[:space:]]+/, "", t)
          n++; buf[n] = t; typ[n] = "test"; hasdetail[p] = 1
        } else if ($3 == "[") {
          n++; buf[n] = p ": test suite failed"; typ[n] = "suite"; fil[n] = p
        }
      }
      next
    }
    END { flush() }
  ' "$_norm_stripped" > "$_norm_extracted" || true

  # Fallback: fully-silenced reporters fail with only a summary line — carry
  # it so the finding at least names the failure counts. Requires >=1 failed
  # (a passing "N passed" summary never matches).
  if [ ! -s "$_norm_extracted" ]; then
    grep -E '^[[:space:]]*(Test Suites|Test Files|Tests):?[[:space:]]+[1-9][0-9]* failed' "$_norm_stripped" \
      | sed 's/^[[:space:]]*//' | tr -s ' ' > "$_norm_extracted" || true
  fi

  local _norm_total _norm_n _norm_desc
  _norm_total=$(grep -c "" "$_norm_extracted" || true)
  if [ "$_norm_total" -gt 0 ]; then
    # Numbering continues after existing not-ok lines (e.g. the synthetic
    # workspace-build failure line appended above the npm test run).
    _norm_n=$(grep -c "^not ok " "$raw_file" || true)
    while IFS= read -r _norm_desc; do
      [ -n "$_norm_desc" ] || continue
      _norm_n=$(( _norm_n + 1 ))
      printf 'not ok %d - %s\n' "$_norm_n" "$_norm_desc" >> "$raw_file"
    done < <(head -n "$_norm_cap" "$_norm_extracted")
    # Cap bounds the assessment prompt size; note the overflow explicitly.
    if [ "$_norm_total" -gt "$_norm_cap" ]; then
      _norm_n=$(( _norm_n + 1 ))
      printf 'not ok %d - ... and %d more test failure(s) truncated — see the gate log for full output\n' \
        "$_norm_n" $(( _norm_total - _norm_cap )) >> "$raw_file"
    fi
    echo "[test-gate] normalized ${_norm_total} jest/vitest failure(s) into TAP findings"
  fi
  rm -f "${_norm_stripped:-}" "${_norm_extracted:-}"
  return 0
}

# ---------------------------------------------------------------------------
# _node_flavored_test_context — true when a RITE_TEST_COMMAND run is expected
# to produce jest/vitest output (node runner named in the command, or the
# repo is an npm package).
# Args: $1 = project_root, $2 = test command string
# ---------------------------------------------------------------------------
_node_flavored_test_context() {
  local ctx_root="$1"
  local ctx_cmd="${2:-}"
  case "$ctx_cmd" in
    # *npm* also covers pnpm; *node* also covers nodemon
    *npm*|*npx*|*yarn*|*jest*|*vitest*|*node*) return 0 ;;
  esac
  [ -f "$ctx_root/package.json" ]
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
      for _trigger in "${_LINT_GATE_FULL_SUITE_TRIGGERS[@]+"${_LINT_GATE_FULL_SUITE_TRIGGERS[@]}"}"; do
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
  # irrelevant entries (docs, etc).
  #
  # tests/**/*.bats are included so that Rules 34/35 (BATS_PRE_SOURCE_STUB_OVERWRITE
  # and BATS_FILE_SCOPE_ENV_READ) run against changed bats files. Those rules
  # use `find tests -name '*.bats'` independently of SHELL_FILES, so they need
  # lint to actually be invoked — a bats-only diff that produces an empty
  # selection causes lint to be skipped entirely, making the rules inert.
  while IFS= read -r _changed; do
    [ -z "$_changed" ] && continue
    case "$_changed" in
      bin/*|lib/*|tools/*)
        [ -f "$project_root/$_changed" ] && echo "$project_root/$_changed"
        ;;
      tests/*.bats|tests/*/*.bats|tests/*/*/*.bats)
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

# _bats_file_is_serial — return 0 if the file carries the sharkrite-gate-serial hint
# Looks in the first 15 lines for `# sharkrite-gate-serial` (no value, presence-only).
# Files with this hint run without --jobs (sequential) while the rest of the selection
# runs in parallel. Hint is a scheduling signal, not an exclusion — selected files always run.
# Returns: 0 (serial hint present) or 1 (run in parallel / no hint)
_bats_file_is_serial() {
  local bats_file="$1"
  head -15 "$bats_file" 2>/dev/null \
    | grep -qE "^# ${RITE_MARKER_GATE_SERIAL}([[:space:]]|$)"
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
        # Exclude concurrency tests from the (parallel) gate. They spawn processes
        # that rendezvous at file-based barriers; under `bats --jobs` the box is
        # oversubscribed and the barriers throw false timeouts (verified: the suite
        # passes serially, exit 0, but produces ~77 "Barrier timeout" failures under
        # --jobs 8). They give the parallel gate NO reliable signal — and a flaky
        # failure here cascades: it fails the gate → triggers the post-merge
        # main-broken FULL-suite check → which flakes again. Real coverage of these
        # race tests comes from a serial context (the full-suite safety net /
        # running `bats tests/concurrency/` directly), not the parallel gate.
        case "$_rel" in tests/concurrency/*) continue ;; esac
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

# ---------------------------------------------------------------------------
# _classify_pytest_outcome — classify a pytest run into one of four outcomes.
#
# Args: $1=exit_code  $2=raw_output (the captured stdout+stderr of the run)
# Stdout: one of
#   passed             — exit 0, tests ran and all passed
#   failed             — real failure: a test failed, assertion error, or collection error
#   skipped:no_tests   — exit 5 with no collection-error signature
#   skipped:missing_deps — anchored ModuleNotFoundError with no FAILED/AssertionError
#
# Precedence (guards stated explicitly to prevent the v1 false-skip bug):
#   1. Collection errors → failed  (exit 2 OR error-signature in output)
#      A collection-breaking regression must never be silenced.
#   2. Real test failure present → failed
#      A traceback that mentions ModuleNotFoundError is still a real failure if
#      FAILED/AssertionError appears anywhere — the loose-grep bug from v1.
#   3. Missing-dep signature AND no FAILED/AssertionError → skipped:missing_deps
#      Two sub-cases (both must be absent of FAILED/AssertionError to reach here):
#      3a. Pytest-formatted error: `^E\s+` prefix — e.g. "E  ModuleNotFoundError: No module named 'mymodule'"
#          The anchor matches only pytest's error-line prefix, not arbitrary body text.
#      3b. Python-interpreter error — `python3 -m pytest` with pytest uninstalled exits 1 and prints:
#            "/usr/bin/python3: No module named pytest"
#          No `^E` prefix. Matched by bare "No module named '?pytest'?" pattern.
#   4. Exit 5 (no tests collected) → skipped:no_tests
#   5. Default → failed  (conservative: unknown non-zero exit is a real problem)
# ---------------------------------------------------------------------------
_classify_pytest_outcome() {
  local _exit_code="$1"
  local _output="$2"

  # 1. Passed cleanly.
  if [ "$_exit_code" -eq 0 ]; then
    echo "passed"
    return 0
  fi

  # 2. Collection-breaking error: exit 2 OR output signature.
  # Exit 2 = "interrupted / collection error" in pytest's exit-code table.
  # The output signature covers cases where pytest prints the collection error
  # but exits with a code other than 2 (e.g. some plugin wrappers).
  if [ "$_exit_code" -eq 2 ] \
     || echo "$_output" | grep -qE '(errors during collection|ERROR collecting)'; then
    echo "failed"
    return 0
  fi

  # 3. Real test failure present (FAILED line or AssertionError).
  # Must be checked BEFORE the missing-dep check: a traceback that mentions
  # ModuleNotFoundError inside a test that also raises AssertionError is still
  # a real failure and must NOT be silently skipped (the v1 false-skip bug).
  if echo "$_output" | grep -qE '(^FAILED |AssertionError)'; then
    echo "failed"
    return 0
  fi

  # 4. Missing-dep signature — two sub-cases.
  #
  # 4a. Pytest-formatted error lines (`^E\s+` prefix).
  # `^E\s+` matches only pytest's error-prefix column (pytest prints error lines
  # as "E  <exception>").  This excludes ModuleNotFoundError buried in arbitrary
  # body text (docstrings, logging, comments reproduced in tracebacks).
  # "No module named" on a pytest error line covers both:
  #   E  ModuleNotFoundError: No module named 'pytest'
  #   E  ImportError: No module named 'mymodule'
  if echo "$_output" | grep -qE '^E[[:space:]]+(ModuleNotFoundError|.*No module named)'; then
    echo "skipped:missing_deps"
    return 0
  fi

  # 4b. Python-interpreter "no module named pytest" — missing-runner case.
  # When pytest itself is not installed, `python3 -m pytest` never reaches pytest
  # and the interpreter prints a bare line (no ^E prefix):
  #   /usr/bin/python3: No module named pytest
  # This is NOT formatted by pytest, so 4a's ^E anchor never matches.
  # The pattern is: a line of the form "<word>: No module named '?pytest'?"
  # We anchor on "No module named" followed by optional-quote "pytest" optional-quote
  # (covers both `pytest` and `pytest.__main__` variants).  The preceding checks
  # (collection-error, FAILED, AssertionError) guarantee we only reach here when
  # there is no real test failure — so matching this narrow pattern is safe.
  if echo "$_output" | grep -qE "No module named '?pytest'?"; then
    echo "skipped:missing_deps"
    return 0
  fi

  # 5. No tests collected — pytest exit code 5.
  if [ "$_exit_code" -eq 5 ]; then
    echo "skipped:no_tests"
    return 0
  fi

  # Default: conservative — treat unknown non-zero exit as a real failure so
  # we never silently hide an unrecognised problem.
  echo "failed"
}

# ---------------------------------------------------------------------------
# _resolve_node_test_runner — extract the test runner binary name (issue #807)
# Args: $1=project_root
# Echoes the first executable token of package.json's .scripts.test, resolving
# one level of `npm run <X>` / `npm test` delegation. Echoes "" when no runner
# name can be extracted (caller then falls back to the .bin-non-empty heuristic).
#
# Examples:
#   "jest --ci"            -> jest
#   "mocha tests/"         -> mocha
#   "vitest run"           -> vitest
#   "npm run test:unit"    -> (resolves .scripts."test:unit"'s first token)
#   "node ./run.js && jest"-> node   (first token; conservative)
# ---------------------------------------------------------------------------
_resolve_node_test_runner() {
  local _pr="$1"
  local _pkg="$_pr/package.json"
  [ -f "$_pkg" ] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }

  local _script
  _script=$(jq -r '.scripts.test // ""' "$_pkg" 2>/dev/null || echo "")
  [ -n "$_script" ] || { echo ""; return 0; }

  # First whitespace-delimited token of the test script.
  local _first
  _first=$(printf '%s\n' "$_script" | awk '{print $1}' || echo "")
  [ -n "$_first" ] || { echo ""; return 0; }

  # Delegation: `npm run <X>` / `npm test` / `npm run-script <X>` — resolve one
  # level by reading the delegated script's first token. Cheap, single-pass; if
  # it delegates again we just return that token (no deeper recursion).
  if [ "$_first" = "npm" ]; then
    local _second _target _delegated _dtok
    _second=$(printf '%s\n' "$_script" | awk '{print $2}' || echo "")
    if [ "$_second" = "test" ]; then
      # `npm test` inside the test script — recursion would loop; bail to heuristic.
      echo ""
      return 0
    fi
    if [ "$_second" = "run" ] || [ "$_second" = "run-script" ]; then
      _target=$(printf '%s\n' "$_script" | awk '{print $3}' || echo "")
    else
      _target="$_second"
    fi
    if [ -n "$_target" ]; then
      _delegated=$(jq -r --arg k "$_target" '.scripts[$k] // ""' "$_pkg" 2>/dev/null || echo "")
      _dtok=$(printf '%s\n' "$_delegated" | awk '{print $1}' || echo "")
      # Avoid re-emitting another npm delegation token (keep it cheap / one-level).
      if [ -n "$_dtok" ] && [ "$_dtok" != "npm" ]; then
        echo "$_dtok"
        return 0
      fi
    fi
    # Could not cheaply resolve the delegation — fall back to heuristic.
    echo ""
    return 0
  fi

  echo "$_first"
}

# ---------------------------------------------------------------------------
# _node_runner_resolvable — is the node test runner present? (issue #807)
# Args: $1=project_root $2=runner_name (may be empty)
# Returns 0 (resolvable) / 1 (not resolvable).
#
# Resolvable when:
#   - runner_name is known AND ( node_modules/.bin/<runner> is executable
#     OR `command -v <runner>` succeeds on PATH ); OR
#   - runner_name is unknown (extraction failed) AND node_modules/.bin exists
#     and is non-empty (heuristic fallback).
# ---------------------------------------------------------------------------
_node_runner_resolvable() {
  local _pr="$1"
  local _runner="${2:-}"
  local _bindir="$_pr/node_modules/.bin"

  if [ -n "$_runner" ]; then
    if [ -x "$_bindir/$_runner" ]; then
      return 0
    fi
    if command -v "$_runner" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  # Unknown runner — heuristic: .bin exists and is non-empty.
  if [ -d "$_bindir" ] && [ -n "$(ls -A "$_bindir" 2>/dev/null || true)" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _node_desymlink_node_modules — remove node_modules symlinks before install
# Args: $1=project_root
#
# Belt-and-suspenders defense kept for pre-existing worktrees. Worktree
# creation no longer symlinks node_modules (#844), but older worktrees may
# still carry the link. npm ci resolves THROUGH a symlink: its pre-reify rm
# step readdirs the target and recursively deletes each entry — destroying the
# symlink's target — then replaces the link with a real dir (npm install
# reifies the same way). Removing the LINK first (plain `rm` on the link path
# — never rm -rf, never a trailing slash) makes npm build a worktree-local
# real dir and leaves the target intact.
#
# Called ONLY inside the bootstrap branch: repos whose runners already
# resolve never install, so any surviving symlink's disk-space benefit is
# preserved.  Real dirs and absent paths are no-ops; dangling symlinks are
# removed the same way ([ -L ] is true for them, plain rm succeeds).
# ---------------------------------------------------------------------------
_node_desymlink_node_modules() {
  local _pr="$1"
  local _sink="${_gate_raw_sink:-/dev/null}"
  local _nm
  for _nm in "$_pr/node_modules" "$_pr/backend/node_modules"; do
    if [ -L "$_nm" ]; then
      echo "[test-gate] $_nm is a symlink — removing the link before install so npm cannot destroy its target" >> "$_sink"
      rm "$_nm"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# _node_is_workspaces_monorepo — is this an npm-workspaces monorepo? (issue #818)
# Args: $1=project_root
# Returns 0 (yes) / 1 (no).
#
# Detection (either signal is sufficient):
#   - root package.json has a non-empty `.workspaces` (array OR {packages:[...]}
#     object form) via jq; OR
#   - the root `.scripts.test` contains `--workspaces` (e.g.
#     `npm run test --workspaces --if-present`).
#
# Conservative: with no jq or no package.json it returns 1 (not a workspaces
# monorepo) so the single-package #807 path is preserved unchanged.
# ---------------------------------------------------------------------------
_node_is_workspaces_monorepo() {
  local _pr="$1"
  local _pkg="$_pr/package.json"
  [ -f "$_pkg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Non-empty .workspaces — accept both the array form and the object form
  # ({"packages":[...]}). `values` normalises both to a list; length>0 confirms.
  local _ws_count
  _ws_count=$(jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then ($w | length)
      elif ($w | type) == "object" then (($w.packages // []) | length)
      else 0 end
  ' "$_pkg" 2>/dev/null || echo 0)
  [ -n "$_ws_count" ] || _ws_count=0
  if [ "$_ws_count" -gt 0 ] 2>/dev/null; then
    return 0
  fi

  # Fallback signal: the root test script delegates across workspaces.
  local _script
  _script=$(jq -r '.scripts.test // ""' "$_pkg" 2>/dev/null || echo "")
  case "$_script" in
    *--workspaces*) return 0 ;;
  esac

  return 1
}

# ---------------------------------------------------------------------------
# _node_workspace_runners_resolvable — do ALL workspace test runners resolve?
# Args: $1=project_root  (issue #818)
# Returns 0 (every workspace runner resolves) / 1 (at least one is unresolvable,
# OR we could not positively confirm — bootstrap when in doubt).
#
# For each workspace directory (expanded from the root .workspaces globs) that
# has a package.json with a .scripts.test runner, the runner is considered
# resolvable when it is executable in ANY of:
#   - the workspace's own node_modules/.bin/<runner>
#   - the hoisted root node_modules/.bin/<runner>  (npm hoists shared bins)
#   - on PATH (`command -v <runner>`)
#
# Deliberately strict: a workspace whose runner cannot be positively confirmed
# makes the whole set unresolvable → caller bootstraps (correctness over a
# redundant install). Object-form `.workspaces` ({"packages":[...]}) is
# supported. If no workspace globs or no jq, returns 1 (bootstrap).
# ---------------------------------------------------------------------------
_node_workspace_runners_resolvable() {
  local _pr="$1"
  local _root_pkg="$_pr/package.json"
  [ -f "$_root_pkg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local _root_bin="$_pr/node_modules/.bin"

  # Expand the workspace glob patterns to concrete directories. jq emits one
  # pattern per line (array or object form); the shell expands each glob.
  local _patterns
  _patterns=$(jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then $w[]
      elif ($w | type) == "object" then (($w.packages // [])[])
      else empty end
  ' "$_root_pkg" 2>/dev/null || echo "")
  [ -n "$_patterns" ] || return 1

  local _saw_any_ws=false
  local _pattern _dir _pkg _runner _ws_bin
  while IFS= read -r _pattern; do
    [ -n "$_pattern" ] || continue
    # Expand the glob relative to the project root. `set -f` is NOT used here;
    # patterns like `packages/*` must expand. A non-matching glob yields the
    # literal pattern, which we filter out with the `-d` test below.
    for _dir in "$_pr/"$_pattern; do
      [ -d "$_dir" ] || continue
      _pkg="$_dir/package.json"
      [ -f "$_pkg" ] || continue
      _saw_any_ws=true
      _runner=$(_resolve_node_test_runner "$_dir")
      # Unknown workspace runner (no test script, or unresolvable extraction) —
      # we cannot positively confirm it. Treat as unresolvable → bootstrap.
      [ -n "$_runner" ] || return 1
      _ws_bin="$_dir/node_modules/.bin"
      if [ -x "$_ws_bin/$_runner" ]; then
        continue
      fi
      if [ -x "$_root_bin/$_runner" ]; then
        continue
      fi
      if command -v "$_runner" >/dev/null 2>&1; then
        continue
      fi
      # This workspace's runner is not resolvable anywhere → bootstrap.
      return 1
    done
  done <<EOF
$_patterns
EOF

  # If no workspace package.json was found at all, we cannot confirm anything —
  # bootstrap rather than assume (correctness over a redundant install).
  [ "$_saw_any_ws" = "true" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _node_workspace_has_missing_entry_points — does any workspace package have a
# compiled entry point that does not yet exist on disk? (issue #822)
# Args: $1=project_root
# Returns 0 (at least one package has a missing entry point AND a build script)
#         1 (all entry points present, or no buildable packages found)
#
# Checks the `main` and `exports` (string form) fields of each workspace
# package.json.  If the resolved path does not exist on disk AND the package
# defines a `.scripts.build`, the workspace needs a build step before tests.
#
# This is the root cause of the LeadFlow 2026-06-30→07-01 outage:
#   shared/package.json → "main": "./dist/index.js"
#   shared/dist/ is gitignored and was never built in the worktree
#   → every test that imports @leadflow/shared failed with "Failed to resolve import"
# ---------------------------------------------------------------------------
_node_workspace_has_missing_entry_points() {
  local _pr="$1"
  local _root_pkg="$_pr/package.json"
  [ -f "$_root_pkg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local _patterns
  _patterns=$(jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then $w[]
      elif ($w | type) == "object" then (($w.packages // [])[])
      else empty end
  ' "$_root_pkg" 2>/dev/null || echo "")
  [ -n "$_patterns" ] || return 1

  local _found_missing=false
  local _pattern _dir _pkg _entry _build_script
  while IFS= read -r _pattern; do
    [ -n "$_pattern" ] || continue
    for _dir in "$_pr/"$_pattern; do
      [ -d "$_dir" ] || continue
      _pkg="$_dir/package.json"
      [ -f "$_pkg" ] || continue

      # Only care about packages that define a build script.
      _build_script=$(jq -r '.scripts.build // ""' "$_pkg" 2>/dev/null || echo "")
      [ -n "$_build_script" ] || continue

      # Check main field first.
      _entry=$(jq -r '.main // ""' "$_pkg" 2>/dev/null || echo "")
      if [ -n "$_entry" ] && [ ! -e "$_dir/$_entry" ]; then
        _found_missing=true
        break 2
      fi

      # Check exports field (string form only — object/array forms are more
      # complex; treat them as "unknown" and skip rather than mis-parse).
      _entry=$(jq -r 'if (.exports | type) == "string" then .exports else "" end' "$_pkg" 2>/dev/null || echo "")
      if [ -n "$_entry" ] && [ ! -e "$_dir/$_entry" ]; then
        _found_missing=true
        break 2
      fi
    done
  done <<EOF
$_patterns
EOF

  [ "$_found_missing" = "true" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _node_build_workspace_packages — build workspace packages whose compiled
# entry points are missing.  (issue #822)
# Args: $1=project_root  $2=gate_raw_sink (log file path)
# Returns 0 (all needed builds succeeded or nothing to build)
#         1 (at least one build failed — caller must surface as blocking)
#
# For each workspace package whose entry point is absent:
#   1. Remove stale tsconfig.tsbuildinfo (incremental state can make `tsc
#      --build` a no-op when dist/ is deleted but the buildinfo remains).
#   2. Run `npm run build -w <pkg-name>` so only the affected package is built.
#      Output goes to the gate raw sink; failures are loud (non-zero return).
# ---------------------------------------------------------------------------
_node_build_workspace_packages() {
  local _pr="$1"
  local _sink="${2:-/dev/stdout}"
  local _root_pkg="$_pr/package.json"
  [ -f "$_root_pkg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local _patterns
  _patterns=$(jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then $w[]
      elif ($w | type) == "object" then (($w.packages // [])[])
      else empty end
  ' "$_root_pkg" 2>/dev/null || echo "")
  [ -n "$_patterns" ] || return 0

  local _any_failed=false
  local _pattern _dir _pkg _entry _build_script _pkg_name _entry_exports
  while IFS= read -r _pattern; do
    [ -n "$_pattern" ] || continue
    for _dir in "$_pr/"$_pattern; do
      [ -d "$_dir" ] || continue
      _pkg="$_dir/package.json"
      [ -f "$_pkg" ] || continue

      _build_script=$(jq -r '.scripts.build // ""' "$_pkg" 2>/dev/null || echo "")
      [ -n "$_build_script" ] || continue

      _entry=$(jq -r '.main // ""' "$_pkg" 2>/dev/null || echo "")
      _entry_exports=$(jq -r 'if (.exports | type) == "string" then .exports else "" end' "$_pkg" 2>/dev/null || echo "")

      # Determine if this package needs a build: either the main or string-form
      # exports entry point is absent.
      local _needs_build=false
      if [ -n "$_entry" ] && [ ! -e "$_dir/$_entry" ]; then
        _needs_build=true
      elif [ -n "$_entry_exports" ] && [ ! -e "$_dir/$_entry_exports" ]; then
        _needs_build=true
      fi
      [ "$_needs_build" = "true" ] || continue

      _pkg_name=$(jq -r '.name // ""' "$_pkg" 2>/dev/null || echo "")
      if [ -z "$_pkg_name" ]; then
        echo "[test-gate] WARNING: workspace package at '$_dir' has no 'name' field — cannot run targeted build; skipping" >> "$_sink"
        continue
      fi

      # Remove stale tsconfig.tsbuildinfo to prevent tsc --build from treating
      # a deleted dist/ as "already up to date" and producing a no-op build.
      local _buildinfo="$_dir/tsconfig.tsbuildinfo"
      if [ -f "$_buildinfo" ]; then
        echo "[test-gate] Removing stale $(_dir_rel "$_pr" "$_buildinfo") to prevent tsc --build no-op" >> "$_sink"
        rm -f "$_buildinfo" || true
      fi
      # Also remove root-level tsconfig.tsbuildinfo that may reference the package.
      local _root_buildinfo="$_pr/tsconfig.tsbuildinfo"
      if [ -f "$_root_buildinfo" ]; then
        echo "[test-gate] Removing stale root tsconfig.tsbuildinfo to prevent tsc --build no-op" >> "$_sink"
        rm -f "$_root_buildinfo" || true
      fi

      echo "[test-gate] Building workspace package '$_pkg_name' (entry point missing: ${_entry:-$_entry_exports})..." >> "$_sink"
      local _build_exit_file _build_exit
      _build_exit_file=$(mktemp "/tmp/rite_gate_build_exit_${PR_NUMBER:-0}_$$_XXXXXX")
      { (cd "$_pr" && npm run build -w "$_pkg_name" 2>&1); echo $? > "$_build_exit_file"; } >> "$_sink" || true
      _build_exit=$(cat "$_build_exit_file" 2>/dev/null || echo "1")
      rm -f "$_build_exit_file"
      if [ "$_build_exit" -ne 0 ]; then
        echo "[test-gate] ERROR: build of workspace package '$_pkg_name' failed (exit $_build_exit)" >> "$_sink"
        _any_failed=true
      else
        echo "[test-gate] workspace package '$_pkg_name' built successfully" >> "$_sink"
      fi
    done
  done <<EOF
$_patterns
EOF

  [ "$_any_failed" = "false" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _dir_rel — emit a path relative to a base, or the original if outside base.
# Used for terse log messages.
# ---------------------------------------------------------------------------
_dir_rel() {
  local _base="$1" _path="$2"
  echo "${_path#"$_base/"}"
}

# ---------------------------------------------------------------------------
# _gate_status — emit a [test-gate] progress line, routed by _gate_raw_sink.
#
# Reads the caller's `_gate_raw_sink` (bash dynamic scope):
#   - Summary mode (default): sink is RITE_LOG_FILE — progress lines buffer
#     there and only the compact digest reaches the terminal.
#   - Verbose + background: sink is RITE_LOG_FILE — avoids interleaving with
#     the concurrent review stream.
#   - Verbose + foreground: sink is /dev/stdout — live progress visible on the
#     terminal.
# The `:-/dev/stdout` default keeps it safe if ever called before the sink is
# set (e.g. in early-exit paths above run_test_gate).
# ---------------------------------------------------------------------------
_gate_status() {
  echo "$@" >> "${_gate_raw_sink:-/dev/stdout}"
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
  #       and the run doesn't look frozen. FIFO-tee still captures it.
  local _gate_raw_sink
  if [ "$_gate_verbose" = "false" ]; then
    # Summary mode: direct-append to log; NOT through the FIFO tee.
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
  # Register cleanup for this invocation's specific files (never a glob).
  # Also write a valid-JSON crash sentinel if the function exits non-zero before
  # _gate_write_json runs — an empty/absent output_file causes jq to silently
  # return zero findings (fail-open), defeating the gate's purpose.
  # The sentinel uses skipped:true so assess-and-resolve.sh skips gate injection
  # rather than reading malformed JSON, while still logging the crash via _diag.
  # shellcheck disable=SC2154  # _gate_exit_status assigned inside the trap body via $? at trap execution time
  trap '_gate_exit_status=$?
        rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_sc_exit_file:-}" "${_lint_exit_file:-}" "${_bats_exit_file:-}" "${_nonsr_exit_file:-}" "${_sc_raw_individual:-}" "${_lint_raw_individual:-}" "${_bats_pretty_capture:-}"
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

    # --- Bats parallelism (--jobs N) ---
    # Auto-detect: use GNU parallel if installed (capped at 4 procs); serial
    # otherwise. RITE_BATS_JOBS=N overrides. File-level parallel only — within
    # each bats file, tests still run sequentially (bats-core default).
    local _bats_jobs _bats_jobs_args
    _bats_jobs=$(_compute_bats_jobs)
    if [ "$_bats_jobs" -gt 1 ]; then
      _bats_jobs_args=(--jobs "$_bats_jobs")
      _gate_status "[test-gate] bats: parallel (--jobs ${_bats_jobs})"
    else
      _bats_jobs_args=()
      _gate_status "[test-gate] bats: serial (parallel binary not found; install GNU parallel to enable)"
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
    local _bats_sandbox=(env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER)
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
        fi
      fi

      # Merge exit codes: any non-zero fails the gate (block-on-any preserved)
      if [ "$_par_exit" -ne 0 ] || [ "$_ser_exit" -ne 0 ]; then
        echo 1 > "$_bats_exit_file"
      else
        echo 0 > "$_bats_exit_file"
      fi
    fi
    _tests_exit=$(cat "$_bats_exit_file" 2>/dev/null || echo 1)
    _tests_exit=${_tests_exit:-1}  # empty = killed before writing = failure (#935)
    # Watchdog kill on the full-suite path (par/ser groups note it above and
    # merge their exits to 0/1, so 124/137 here can only come from full-suite).
    if [ "$_tests_exit" = "124" ] || [ "$_tests_exit" = "137" ]; then
      _gate_status "[test-gate] bats (full suite) killed by whole-run watchdog after ${_gate_bats_timeout}s (RITE_GATE_BATS_TIMEOUT)"
      _diag "TEST_GATE_WATCHDOG_KILL group=full timeout_s=${_gate_bats_timeout} pr=${PR_NUMBER:-?}"
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
      if [ "$_notrun_deficit" -gt 0 ] || [ -n "$_notrun_warning" ]; then
        # Not-run names come from a set difference of planned @test
        # descriptions (from the SELECTED bats files) minus TAP result lines —
        # never from the pretty stream, whose width-truncated begin lines
        # produced the 130-phantom event (PR #852) and which interleaves under
        # --jobs and mismatched begin/result pairs (130 phantom findings for a
        # deficit of 1 on PR #852; issue #862). Finding count is capped at the
        # bats-reported deficit inside _synthesize_notrun_findings.
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
  else
    # Non-Sharkrite: best-effort detection (npm test / make test / pytest / cargo / go)
    # For non-Sharkrite repos the gate runs whatever the manifest implies.
    local _nonsr_exit_file
    _nonsr_exit_file=$(mktemp "/tmp/rite_gate_nonsr_exit_${PR_NUMBER:-0}_$$_XXXXXX")

    # Detect whether this PR touched source files for use in loud-skip below.
    # Source = any non-docs/non-config change. A simple heuristic: any changed
    # path that isn't docs/, README, LICENSE, *.md, *.txt, *.conf, .gitignore.
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
        if [ -f "$project_root/package-lock.json" ]; then
          (cd "$project_root" && npm ci --silent) >> "$_gate_raw_sink" 2>&1 || true
        else
          (cd "$project_root" && npm install --silent) >> "$_gate_raw_sink" 2>&1 || true
        fi
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
    elif [ -f "$project_root/pytest.ini" ] || [ -d "$project_root/tests" ]; then
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

  # --- Capture terminal-digest inputs before the raw TAP file is removed ---
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

  rm -f "${_lint_raw_file:-}" "${_tests_raw_file:-}" "${_bats_pretty_capture:-}"
  trap - EXIT

  # --- Determine overall exit code and outcome ---
  # Block-on-any: the targeted suite is green on main, so ANY failure in the
  # selection is this change's to fix. (FORCE_FULL / no-diff always blocked on
  # any failure; the targeted path now matches — no new-vs-pre-existing split.)
  local _overall_exit=0
  local _outcome="passed"
  local _tests_blocking=0
  [ "$_tests_exit" -ne 0 ] && _tests_blocking=1
  if [ "$_lint_exit" -ne 0 ] || [ "$_tests_blocking" -ne 0 ]; then
    _overall_exit=1
    _outcome="failed"
  fi

  local _gate_end
  _gate_end=$(date +%s)
  local _duration=$(( _gate_end - _gate_start ))

  _diag "TEST_GATE outcome=${_outcome} lint_count=${_lint_count} test_count=${_tests_count} duration_s=${_duration} pr=${PR_NUMBER:-?}"

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

  # Pass _gate_reason (may be empty) so _gate_write_json can include it in the
  # JSON when a named failure reason was recorded (e.g. runner_unavailable).
  _gate_write_json "$output_file" "$_lint_items" "$_tests_items" "$_overall_exit" "false" "$_gate_reason"
  return "$_overall_exit"
}
