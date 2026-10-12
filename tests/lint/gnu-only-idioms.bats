#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/39-gnu-only-idioms.sh, tools/sharkrite-lint.sh
# Tests for Rule 39: GNU_ONLY_IDIOM
#
# Covers all seven sub-checks (A–G), plus suppression and the codebase sweep.
# Uses SHARKRITE_LINT_ONLY=39 so each run invokes only Rule 39 (~1s vs ~85s).

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/gnu-only-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
  export SHARKRITE_LINT_ONLY=39
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
  unset SHARKRITE_LINT_ONLY
}

_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ===========================================================================
# A. sed BRE alternation (\|)
# ===========================================================================

@test "39A fires: sed with BRE alternation (backslash-pipe) in pattern" {
  _run_lint_with_fixture "bad-sed-bre-alt" '#!/usr/bin/env bash
set -euo pipefail
result=$(echo "commit conventions" | sed -n '"'"'/Commit Conventions\|Git Conventions/p'"'"')
echo "$result"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39A fires: sed -n with BRE alternation in range address" {
  _run_lint_with_fixture "bad-sed-range-alt" '#!/usr/bin/env bash
set -euo pipefail
body=$(echo "$block" | sed -n '"'"'/Files to Modify/,/^\*\*\|^##\|^Related\|^$/p'"'"')
echo "$body"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39A passes: sed -E uses ERE alternation (unescaped pipe)" {
  _run_lint_with_fixture "good-sed-ere-alt" '#!/usr/bin/env bash
set -euo pipefail
result=$(echo "commit conventions" | sed -nE '"'"'/Commit Conventions|Git Conventions/p'"'"')
echo "$result"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-sed-ere-alt"* ]]
}

@test "39A passes: sed -nE with range address using unescaped pipe" {
  _run_lint_with_fixture "good-sed-nE-range" '#!/usr/bin/env bash
set -euo pipefail
body=$(echo "$block" | sed -nE '"'"'/Files to Modify/,/^\*\*|^##|^Related|^$/p'"'"')
echo "$body"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-sed-nE-range"* ]]
}

@test "39A passes: non-sed backslash-pipe (awk, grep) not flagged" {
  _run_lint_with_fixture "good-no-sed-backslash-pipe" '#!/usr/bin/env bash
set -euo pipefail
# awk using \| in a print context — not a sed BRE issue
result=$(echo "foo|bar" | awk '"'"'/foo/{print "found"}'"'"')
echo "$result"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-no-sed-backslash-pipe"* ]]
}

# ===========================================================================
# B. sed case-conversion (\u \l \U \L)
# ===========================================================================

@test "39B fires: sed with \\u title-case in replacement" {
  _run_lint_with_fixture "bad-sed-title-case" '#!/usr/bin/env bash
set -euo pipefail
title=$(echo "foo bar" | tr '"'"'-'"'"' '"'"' '"'"' | sed '"'"'s/\b\(.\)/\u\1/g'"'"')
echo "$title"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39B fires: sed with \\U uppercase-all in replacement" {
  _run_lint_with_fixture "bad-sed-upper-all" '#!/usr/bin/env bash
set -euo pipefail
upper=$(echo "hello" | sed '"'"'s/.*/\U&/'"'"')
echo "$upper"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39B passes: awk toupper() as portable replacement" {
  _run_lint_with_fixture "good-awk-toupper" '#!/usr/bin/env bash
set -euo pipefail
title=$(echo "foo bar" | tr '"'"'-'"'"' '"'"' '"'"' | awk '"'"'{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) substr($i,2)}1'"'"')
echo "$title"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-awk-toupper"* ]]
}

# ===========================================================================
# C. date -d without BSD fallback
# ===========================================================================

@test "39C fires: bare date -d with no fallback" {
  _run_lint_with_fixture "bad-date-d-bare" '#!/usr/bin/env bash
set -euo pipefail
cutoff=$(date -d "30 days ago" +%Y-%m-%d)
echo "$cutoff"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39C passes: date -d with same-line BSD date -v fallback" {
  _run_lint_with_fixture "good-date-d-bsd-v" '#!/usr/bin/env bash
set -euo pipefail
cutoff=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null)
echo "$cutoff"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-date-d-bsd-v"* ]]
}

@test "39C passes: date -d with same-line BSD date -j fallback" {
  _run_lint_with_fixture "good-date-d-bsd-j" '#!/usr/bin/env bash
set -euo pipefail
epoch=$(date -d "$ISO_TS" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ISO_TS" +%s 2>/dev/null || echo 0)
echo "$epoch"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-date-d-bsd-j"* ]]
}

@test "39C passes: date -d inside a date --version guard block" {
  _run_lint_with_fixture "good-date-d-version-guard" '#!/usr/bin/env bash
set -euo pipefail
if date --version >/dev/null 2>&1; then
  result=$(date -d "$TS" "+%s" 2>/dev/null || echo "0")
else
  result=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$TS" "+%s" 2>/dev/null || echo "0")
fi
echo "$result"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-date-d-version-guard"* ]]
}

# ===========================================================================
# D. grep -P / --perl-regexp
# ===========================================================================

@test "39D fires: grep -P for PCRE matching" {
  _run_lint_with_fixture "bad-grep-P" '#!/usr/bin/env bash
set -euo pipefail
result=$(echo "foo123bar" | grep -P '"'"'\d+'"'"')
echo "$result"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39D fires: grep -nP combined flags" {
  _run_lint_with_fixture "bad-grep-nP" '#!/usr/bin/env bash
set -euo pipefail
result=$(grep -nP '"'"'\d+'"'"' file.txt || true)
echo "$result"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39D fires: grep --perl-regexp long form" {
  _run_lint_with_fixture "bad-grep-perl-regexp" '#!/usr/bin/env bash
set -euo pipefail
result=$(grep --perl-regexp '"'"'\d+'"'"' file.txt || true)
echo "$result"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39D passes: grep -E (ERE) is portable" {
  _run_lint_with_fixture "good-grep-E" '#!/usr/bin/env bash
set -euo pipefail
result=$(echo "foo123bar" | grep -E '"'"'[0-9]+'"'"')
echo "$result"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-grep-E"* ]]
}

@test "39D passes: pgrep -P (parent PID flag, unrelated to grep -P)" {
  _run_lint_with_fixture "good-pgrep-P" '#!/usr/bin/env bash
set -euo pipefail
# pgrep -P lists children of a PID — completely different from grep -P
children=$(pgrep -P "$$" 2>/dev/null || true)
echo "$children"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-pgrep-P"* ]]
}

# ===========================================================================
# E. stat -c without stat --version guard
# ===========================================================================

@test "39E fires: bare stat -c without stat --version guard" {
  _run_lint_with_fixture "bad-stat-c-bare" '#!/usr/bin/env bash
set -euo pipefail
mtime=$(stat -c "%Y" "$file")
echo "$mtime"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39E passes: stat -c inside a stat --version guard block" {
  _run_lint_with_fixture "good-stat-c-guarded" '#!/usr/bin/env bash
set -euo pipefail
if stat --version >/dev/null 2>&1; then
  mtime=$(stat -c "%Y" "$file" 2>/dev/null || echo "0")
else
  mtime=$(stat -f "%m" "$file" 2>/dev/null || echo "0")
fi
echo "$mtime"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-stat-c-guarded"* ]]
}

@test "39E passes: portable_stat_mtime wrapper (no direct stat -c in caller)" {
  _run_lint_with_fixture "good-portable-stat-mtime" '#!/usr/bin/env bash
set -euo pipefail
source "${RITE_LIB_DIR}/utils/portable-cmds.sh"
mtime=$(portable_stat_mtime "$file")
echo "$mtime"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-portable-stat-mtime"* ]]
}

# ===========================================================================
# F. Bare timeout without command -v guard
# ===========================================================================

@test "39F fires: bare timeout invocation without command -v guard" {
  _run_lint_with_fixture "bad-timeout-bare" '#!/usr/bin/env bash
set -euo pipefail
if timeout 10 git fetch --prune origin >/dev/null 2>&1; then
  echo "fetched"
fi'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39F fires: timeout with -k flag, no guard" {
  _run_lint_with_fixture "bad-timeout-k" '#!/usr/bin/env bash
set -euo pipefail
result=$(timeout -k 5 30 some_cmd || true)
echo "$result"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39F passes: run_with_timeout (portable wrapper)" {
  _run_lint_with_fixture "good-run-with-timeout" '#!/usr/bin/env bash
set -euo pipefail
if run_with_timeout 10 git fetch --prune origin >/dev/null 2>&1; then
  echo "fetched"
fi'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-run-with-timeout"* ]]
}

@test "39F passes: timeout inside command -v timeout guard" {
  _run_lint_with_fixture "good-timeout-guarded" '#!/usr/bin/env bash
set -euo pipefail
if command -v timeout >/dev/null 2>&1; then
  result=$(timeout 30 long_cmd)
fi
echo "$result"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-timeout-guarded"* ]]
}

@test "39F passes: gtimeout fallback chain with elif command -v timeout" {
  _run_lint_with_fixture "good-timeout-elif-guarded" '#!/usr/bin/env bash
set -euo pipefail
_watchdog=()
if command -v gtimeout >/dev/null 2>&1; then
  _watchdog=(gtimeout -k 30 1800)
elif command -v timeout >/dev/null 2>&1; then
  _watchdog=(timeout -k 30 1800)
fi'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-timeout-elif-guarded"* ]]
}

# ===========================================================================
# G. Non-terminal mktemp XXXXXX
# ===========================================================================

@test "39G fires: mktemp template with .txt suffix after XXXXXX" {
  _run_lint_with_fixture "bad-mktemp-suffix" '#!/usr/bin/env bash
set -euo pipefail
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite_log_$$_XXXXXX.txt")
echo "log" >> "$tmpfile"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39G fires: mktemp template with extension after XXXXXX" {
  _run_lint_with_fixture "bad-mktemp-ext" '#!/usr/bin/env bash
set -euo pipefail
raw=$(mktemp "${TMPDIR:-/tmp}/rite_lint_stripped_$$_XXXXXX.txt")
echo "raw" >> "$raw"'
  [[ "$output" == *"GNU_ONLY_IDIOM"* ]]
}

@test "39G passes: mktemp with terminal XXXXXX (no suffix)" {
  _run_lint_with_fixture "good-mktemp-terminal" '#!/usr/bin/env bash
set -euo pipefail
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite_log_$$_XXXXXX")
echo "log" >> "$tmpfile"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-mktemp-terminal"* ]]
}

@test "39G passes: mktemp without a template argument (plain mktemp)" {
  _run_lint_with_fixture "good-mktemp-no-template" '#!/usr/bin/env bash
set -euo pipefail
tmpfile=$(mktemp)
echo "data" > "$tmpfile"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-mktemp-no-template"* ]]
}

@test "39G passes: mktemp -d (directory, no XXXXXX suffix)" {
  _run_lint_with_fixture "good-mktemp-d" '#!/usr/bin/env bash
set -euo pipefail
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/rite_work_$$_XXXXXX")
echo "work dir: $tmpdir"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"good-mktemp-d"* ]]
}

# ===========================================================================
# Suppression (applies to all sub-checks via GNU_ONLY_IDIOM)
# ===========================================================================

@test "suppression: sharkrite-lint disable GNU_ONLY_IDIOM suppresses sed BRE alternation" {
  _run_lint_with_fixture "suppressed-sed-bre" '#!/usr/bin/env bash
set -euo pipefail
# sharkrite-lint disable GNU_ONLY_IDIOM - Reason: pinned test fixture — intentional BRE
result=$(echo "foo" | sed -n '"'"'/foo\|bar/p'"'"')
echo "$result"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"suppressed-sed-bre"* ]]
}

@test "suppression: sharkrite-lint disable GNU_ONLY_IDIOM suppresses bare date -d" {
  _run_lint_with_fixture "suppressed-date-d" '#!/usr/bin/env bash
set -euo pipefail
# sharkrite-lint disable GNU_ONLY_IDIOM - Reason: runs in Linux-only CI context
cutoff=$(date -d "30 days ago" +%Y-%m-%d)
echo "$cutoff"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"suppressed-date-d"* ]]
}

@test "suppression: sharkrite-lint disable GNU_ONLY_IDIOM suppresses bare timeout" {
  _run_lint_with_fixture "suppressed-timeout" '#!/usr/bin/env bash
set -euo pipefail
# sharkrite-lint disable GNU_ONLY_IDIOM - Reason: only runs in Docker with coreutils
timeout 30 some_cmd
echo "done"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"suppressed-timeout"* ]]
}

@test "suppression: 2-line look-back handles multi-line pipeline continuation" {
  # Covers the pipeline-continuation case: comment on line N-2, assignment on
  # N-1 (\-continuation), flagged sed on N — suppression must fire across 2 lines.
  _run_lint_with_fixture "suppressed-pipeline-2line" '#!/usr/bin/env bash
set -euo pipefail
# sharkrite-lint disable GNU_ONLY_IDIOM - Reason: \|...|p uses | as delimiter for markers containing /
_raw=$(echo "$body" \
  | sed -n "\|${open}|,\|${close}|p" \
  | grep "^key:" || true)
echo "$_raw"'
  local r39
  r39=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  [[ "$r39" != *"suppressed-pipeline-2line"* ]]
}

# ===========================================================================
# Codebase sweep: no GNU_ONLY_IDIOM violations in current main
# ===========================================================================

@test "codebase: no GNU_ONLY_IDIOM violations in lib/ bin/ tools/" {
  unset RITE_LINT_EXTRA_DIRS
  run bash "$LINT_SCRIPT"
  local r39_violations
  r39_violations=$(echo "$output" | grep "GNU_ONLY_IDIOM" || true)
  if [ -n "$r39_violations" ]; then
    echo "GNU_ONLY_IDIOM violations found:" >&3
    echo "$r39_violations" >&3
    false
  fi
}
