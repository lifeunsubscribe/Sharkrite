#!/usr/bin/env bash
# Sharkrite custom lint rules
# Catches bash anti-patterns that shellcheck doesn't detect
#
# Exit codes:
#   0 - All checks passed
#   1 - Lint violations found

set -euo pipefail

# Color output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cleanup trap: remove any mktemp AWK program files on exit or interruption
# (prevents leaks if the script is killed before reaching the inline rm -f calls)
_r8_awk=""
_r13_awk=""
_r27_awk=""
_cleanup_awk_tmpfiles() {
  [ -n "$_r8_awk"  ] && rm -f "$_r8_awk"
  [ -n "$_r13_awk" ] && rm -f "$_r13_awk"
  [ -n "$_r27_awk" ] && rm -f "$_r27_awk"
  # Always return 0 — the trap fires on EXIT and a non-zero return here would
  # override the script's intended exit code (e.g. exit 0 → exit 1 when both
  # tmpfile vars are empty and the last `[ -n "" ]` test returns 1).
  return 0
}
trap '_cleanup_awk_tmpfiles' EXIT INT TERM

# Track violations
VIOLATIONS=0

# Print error with file and line number
print_violation() {
  local file=$1
  local line=$2
  local rule=$3
  local message=$4

  echo -e "${RED}✗${NC} $file:$line - $rule: $message"
  VIOLATIONS=$((VIOLATIONS + 1))
}

# Normalize RITE_LINT_FILES entries to CWD-relative form. The targeted gate
# passes git-diff-relative paths, but callers (bats harnesses, operators) may
# pass absolute paths — while the bats-file intersections below compare
# exact-line (grep -Fx) against `find tests` output, which is CWD-relative.
# Without this, an absolute .bats entry silently intersects to EMPTY and
# Rules 34/35 scan nothing (the live 848 failure: rules inert under the test
# harness; early-exit count always 0 for absolute entries).
_normalize_lint_files() {
  [ -z "${RITE_LINT_FILES:-}" ] && return 0
  local _p _stripped
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    _stripped=${_p#"$PWD"/}
    printf '%s\n' "$_stripped"
  done <<< "$RITE_LINT_FILES"
}

# Print warning (informational, doesn't fail build)
print_warning() {
  local file=$1
  local line=$2
  local rule=$3
  local message=$4

  echo -e "${YELLOW}⚠${NC} $file:$line - $rule: $message"
}

echo "Running Sharkrite custom lint rules..."
echo ""

# Find all shell scripts (bin/, lib/, and tools/ including git-hooks without .sh extension)
# Exclude sharkrite-lint.sh itself to prevent false positives: it contains # sharkrite-extract:
# marker patterns in comments and awk strings used to detect those markers in other files —
# scanning it could cause Rule 18 (UNBALANCED_EXTRACT_MARKERS) to fire spuriously if a
# concretely-named example marker were ever added to this file.
#
# Path patterns use "$PROJECT_ROOT/..." anchors (not "*/..." wildcards) to mirror the Makefile's
# relative anchors: `find bin lib tools -path "bin/rite*" -path "tools/git-hooks/*"`.
# When find is given absolute search roots, the -path predicate must include the full absolute
# prefix — bare wildcards like "*/bin/rite*" would also match deeper nested paths accidentally.
# -L follows symlinks so that extra fixture dirs (RITE_LINT_EXTRA_DIRS) are scanned correctly.
# test-fixtures-temp* is excluded: bats tests create a symlink (or similarly-named dir) pointing
# to a live tmp dir during test runs. Scanning it during production lint runs would produce false
# positives from intentionally-invalid fixture files. Fixtures are injected via
# RITE_LINT_EXTRA_DIRS instead.
# DO NOT REMOVE: without this exclusion, production lint scans pick up bats fixture files and
# emit spurious lint failures that have nothing to do with the code being checked.
mapfile -t SHELL_FILES < <(find -L "$PROJECT_ROOT/bin" "$PROJECT_ROOT/lib" "$PROJECT_ROOT/tools" \
  -type f ! -name 'sharkrite-lint.sh' \
  ! -path "*/test-fixtures-temp*/*" ! -path "*/test-fixtures-temp*" \
  \( -name "*.sh" -o -path "$PROJECT_ROOT/bin/rite*" -o -path "$PROJECT_ROOT/tools/git-hooks/*" \) 2>/dev/null)
# ^^^ ! -name 'sharkrite-lint.sh': exclude self — contains # sharkrite-extract: marker patterns
# in comments and awk strings; scanning it could cause Rule 18 (UNBALANCED_EXTRACT_MARKERS)
# to fire spuriously if a concretely-named example marker were ever added to this file.

# RITE_LINT_EXTRA_DIRS: optional colon-separated list of additional directories to scan.
# Used by regression tests to inject fixture directories without creating symlinks in lib/.
# Each directory is scanned for *.sh files and appended to SHELL_FILES.
# This keeps test fixture files out of the production lint scope while allowing the tests
# to exercise lint rules against controlled fixture inputs.
if [ -n "${RITE_LINT_EXTRA_DIRS:-}" ]; then
  IFS=: read -ra _extra_dirs <<< "$RITE_LINT_EXTRA_DIRS"
  for _extra_dir in "${_extra_dirs[@]}"; do
    [ -d "$_extra_dir" ] || continue
    mapfile -t -O "${#SHELL_FILES[@]}" SHELL_FILES < <(find "$_extra_dir" -type f -name "*.sh" 2>/dev/null)
  done
fi

# RITE_LINT_FILES: optional newline-separated list of absolute file paths.
# When set, SHELL_FILES is filtered to the intersection — only the listed files
# get scanned by each rule. Used by test-gate.sh to target lint at the commit's
# changed-file set (parallel to the bats targeted-selection mechanism from #462).
#
# Files in RITE_LINT_FILES that aren't already in SHELL_FILES (e.g. docs, deleted
# files, fixtures, tests/, the lint script's self-exclusion) are silently dropped
# — the intersection is by design. Empty intersection → exit 0 with a notice
# (e.g. docs-only commit). Direct `make lint` (no env var) keeps full-scan
# behavior unchanged.
#
# IMPORTANT: .bats files are NOT in SHELL_FILES (the SHELL_FILES find only covers
# bin/, lib/, tools/). A bats-only commit would produce an empty SHELL_FILES
# intersection and trigger an early exit BEFORE Rules 34/35 (which build their
# own bats scan list) ever run. To prevent this, we pre-compute the bats
# intersection here and skip the early exit when bats files are in scope.
if [ -n "${RITE_LINT_FILES:-}" ]; then
  _lint_targeted_tmp=$(mktemp)
  printf '%s\n' "${SHELL_FILES[@]}" > "$_lint_targeted_tmp"
  mapfile -t SHELL_FILES < <(printf '%s\n' "$RITE_LINT_FILES" | grep -Fxf "$_lint_targeted_tmp" 2>/dev/null || true)
  rm -f "$_lint_targeted_tmp"
  # Pre-compute the bats intersection before the early-exit guard so that a
  # bats-only commit (SHELL_FILES empty but RITE_LINT_FILES has .bats paths)
  # does not exit before Rules 34/35 get a chance to run. Rules 34/35 build
  # their own _bats_scan_list near the bottom of the file; we just need to know
  # here whether there are any in-scope bats files to decide on early exit.
  _lint_bats_count=0
  _lint_bats_all_tmp=$(mktemp)
  find tests -name '*.bats' -type f 2>/dev/null > "$_lint_bats_all_tmp" || true
  _lint_bats_count=$(_normalize_lint_files | grep '\.bats$' | grep -cFxf "$_lint_bats_all_tmp" 2>/dev/null || true)
  rm -f "$_lint_bats_all_tmp"
  if [ "${#SHELL_FILES[@]}" -eq 0 ] && [ "${_lint_bats_count:-0}" -eq 0 ]; then
    echo "Sharkrite custom lint: no in-scope shell files in targeted set — skipping."
    exit 0
  fi
  echo "Sharkrite custom lint: targeted scope (${#SHELL_FILES[@]} file(s))"
fi

# Rule 1: grep -c with || true (produces double zero)
echo "Checking for 'grep -c ... || echo \"0\"' pattern..."
for file in "${SHELL_FILES[@]}"; do
  # Match: grep -c <pattern> || true
  # This is wrong because grep -c always outputs a count
  while IFS=: read -r line_num line_content; do
    if echo "$line_content" | grep -qE 'grep\s+-c.*\|\|\s*echo\s+"0"'; then
      print_violation "$file" "$line_num" "GREP_C_ECHO_ZERO" \
        "grep -c already outputs '0', use || true instead of || echo \"0\""
    fi
  done < <(grep -n 'grep -c' "$file" 2>/dev/null || true)
done

# Rule 2: git push without explicit refspec (dangerous in automation)
echo "Checking for 'git push' without explicit refspec..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip if it's a comment
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: git push (without branch/refspec)
    # Allow: git push origin <branch>, git push -u, git push --force-with-lease
    if echo "$line_content" | grep -qE 'git\s+push\s*$' || \
       echo "$line_content" | grep -qE 'git\s+push\s+(--[a-z-]+\s*)+$'; then
      # Check if this is NOT followed by a refspec
      if ! echo "$line_content" | grep -qE 'git\s+push.*origin'; then
        print_violation "$file" "$line_num" "GIT_PUSH_NO_REFSPEC" \
          "git push without explicit refspec/branch is dangerous in automation"
      fi
    fi
  done < <(grep -n 'git push' "$file" 2>/dev/null || true)
done

# Rule 3: eval with GitHub API data (security risk)
echo "Checking for 'eval' with potentially untrusted data..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: eval with variables that might contain GitHub data
    if echo "$line_content" | grep -qE '\beval\s+.*\$'; then
      # Check if the variable name suggests GitHub/API data
      if echo "$line_content" | grep -qiE '\$(gh|api|response|body|pr_|issue_|json)'; then
        print_warning "$file" "$line_num" "EVAL_UNTRUSTED_DATA" \
          "eval with GitHub API data detected - verify input sanitization"
      fi
    fi
  done < <(grep -n 'eval' "$file" 2>/dev/null || true)
done

# Rule 4: Unquoted heredoc in command substitution
echo "Checking for unquoted heredoc in command substitution..."
for file in "${SHELL_FILES[@]}"; do
  # Match: $(cat <<EOF or $(... <<EOF without quotes
  # Safe: $(cat <<'EOF' or $(cat << 'EOF' with space before quote
  while IFS=: read -r line_num line_content; do
    # Check for suppression comment on previous line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*UNQUOTED_HEREDOC'; then
      continue
    fi

    if echo "$line_content" | grep -qE '\$\([^)]*<<[^)]*(EOF|END|HEREDOC)' && \
       ! echo "$line_content" | grep -qE "<<\s*'"; then
      print_violation "$file" "$line_num" "UNQUOTED_HEREDOC_CMDSUB" \
        "Unquoted heredoc in command substitution - use <<'EOF' to prevent expansion"
    fi
  done < <(grep -n '<<.*EOF' "$file" 2>/dev/null || true)
done

# Rule 5: BSD-only sed -i without GNU fallback
# NOTE: portable-cmds.sh is the only legitimate place for bare sed -i '' (with --version guard).
# For all other files, Rule 10 (BARE_BSD_SED_I) fires first and is more actionable.
# Rule 5 only fires on portable-cmds.sh itself, to ensure the --version guard is present there.
echo "Checking for BSD-only 'sed -i' without GNU fallback..."
for file in "${SHELL_FILES[@]}"; do
  # Rule 10 supersedes Rule 5 for every file except portable-cmds.sh.
  # Avoid double-reporting the same sed -i '' line.
  if [[ "$file" != */portable-cmds.sh ]]; then
    continue
  fi
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: sed -i '' (BSD format)
    if echo "$line_content" | grep -qE "sed\s+-i\s+''"; then
      # Check if there's a GNU fallback in the same file
      if ! grep -q 'sed --version' "$file" 2>/dev/null; then
        print_violation "$file" "$line_num" "BSD_SED_NO_FALLBACK" \
          "BSD sed -i '' detected without GNU fallback check"
      fi
    fi
  done < <(grep -n "sed -i" "$file" 2>/dev/null || true)
done

# Rule 6: PIPESTATUS after || true or non-pipeline
echo "Checking for PIPESTATUS misuse..."
for file in "${SHELL_FILES[@]}"; do
  # Find all PIPESTATUS usages
  while IFS=: read -r line_num line_content; do
    # Get previous line for context
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")

    # Check if previous line has || true (which destroys PIPESTATUS)
    if echo "$prev_line" | grep -qE '\|\|\s*true\s*$'; then
      print_violation "$file" "$line_num" "PIPESTATUS_AFTER_OR_TRUE" \
        "PIPESTATUS used after '|| true' - PIPESTATUS is lost/stale"
    fi

    # Check if PIPESTATUS is used but there's no pipe on the previous line
    # Exception: if it's inside a fallback like ${PIPESTATUS[0]:-$?}
    if ! echo "$line_content" | grep -qE '\$\{PIPESTATUS\[0\]:-'; then
      if ! echo "$prev_line" | grep -qE '\|'; then
        # Could be a false positive if the pipe is 2+ lines up, but flag it
        print_warning "$file" "$line_num" "PIPESTATUS_NO_PIPELINE" \
          "PIPESTATUS referenced but no pipe found on previous line - verify context"
      fi
    fi
  done < <(grep -n 'PIPESTATUS\[' "$file" 2>/dev/null || true)
done

# Rule 7: local keyword outside function (SC2168 - but catch our own)
# Uses AWK for performance — the bash while+grep approach spawned thousands
# of subprocesses per file (one grep per line × 3-5 checks × N lines).
echo "Checking for 'local' outside function scope..."
_r7_hits=$(awk '
FNR == 1 { depth = 0; in_heredoc = 0; hd_marker = "" }
{
  # Heredoc close: when inside heredoc, skip until terminator line.
  # Strip leading whitespace before comparing to support <<-MARKER (tab-indented terminators).
  if (in_heredoc) {
    _close = $0; sub(/^[[:space:]]*/, "", _close)
    if (_close == hd_marker) in_heredoc = 0
    next
  }
  # Heredoc open: detect <<MARKER and <<-MARKER on this line.
  # sub strips everything up to and including <<  and an optional - (for <<-).
  # Intentional fall-through after setting in_heredoc=1: the opener line itself
  # is a shell command (e.g. "cat <<EOF"), not heredoc body, so it must still
  # be checked for local usage and brace depth.
  if (index($0, "<<") > 0) {
    tok = $0
    sub(/.*<<-?[[:space:]]*/, "", tok)
    gsub(/['"'"'"]/, "", tok)
    split(tok, _p, " ")
    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
      hd_marker = _p[1]; in_heredoc = 1
    }
  }
  # Skip comments
  if ($0 ~ /^[[:space:]]*#/) next
  # Count { and } on this line to track nesting depth.
  # gsub returns the replacement count, allowing us to count characters without
  # a per-char loop (fast, BSD AWK compatible, heredoc-safe).
  # Strip string literals before counting so braces inside strings, ${param}
  # expansions, and {a,b} brace-expansions in quoted arguments do not skew depth.
  # Single-quoted strings have no escape sequences in bash, so the regex is exact.
  # Double-quoted strings use a heuristic that misses backslash-escaped quotes --
  # accepted for a lint heuristic; a full parser is out of scope.
  # ${...} parameter expansions are also stripped: their braces always net to zero
  # but stripping them avoids false depth drift on complex default expansions.
  _stripped = $0
  gsub(/'"'"'[^'"'"']*'"'"'/, "", _stripped)
  gsub(/"[^"]*"/, "", _stripped)
  gsub(/\$\{[^}]*\}/, "", _stripped)
  # Use _stripped copies so $0 is not modified (detection check still uses $0).
  _tmp = _stripped; _ob = gsub(/{/, "", _tmp)
  _tmp = _stripped; _cb = gsub(/}/, "", _tmp)
  depth += _ob - _cb
  if (depth < 0) depth = 0
  # Flag: "local" keyword used at depth 0 (outside any function)
  # Use tab as field separator so paths containing colons (e.g. CI matrix job
  # paths like /home/runner/work/my:project/file.sh) parse correctly.
  if (depth == 0 && $0 ~ /^[[:space:]]*local[[:space:]]/) {
    print FILENAME "\t" FNR
  }
}' "${SHELL_FILES[@]}" </dev/null 2>/dev/null || true)

if [ -n "$_r7_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    print_violation "$_hit_file" "$_hit_line" "LOCAL_OUTSIDE_FUNCTION" \
      "'local' keyword used outside function (only works inside functions)"
  done <<< "$_r7_hits"
fi

# Rule 8: Unsafe pipe inside command substitution (silent death under set -euo pipefail)
# Uses AWK for performance — the bash while+grep approach spawned thousands of
# subprocesses per file: grep -n '=\$(' found 1346 matches across 52 files,
# and each match triggered 3–4 more greps + 1 sed (for next-line lookahead),
# totalling ~6000–7000 subprocess calls and 9+ seconds per lint run.
#
# AWK strategy: buffer each triggering line, then scan FORWARD until the
# command substitution resolves: a guard (|| true / || echo / : $?) clears it;
# a line ending in ")" closes the substitution unguarded → violation; a 40-line
# cap reports runaway constructs. The earlier one-line lookahead false-flagged
# multi-line blocks whose guard sits on the closing line, e.g.
#   _body=$(printf '%s' "$x" | awk '
#     ...10 lines of awk program...
#   ' || true)        <- guard here, invisible to a next-line-only check
# (live false positive: #568's _resolve_ordinal_refs_in_body, 2026-06-12).
#
# Two opener kinds are tracked (pending_kind): kind 1 = the tool keyword is on
# the opener line (classic single- or multi-line awk/grep block); kind 2 = the
# opener is a pipe-continuation `VAR=$(... | \` whose tool keyword lands on a
# later line (e.g. `RESULT=$(git worktree list | \` then `  grep ...)`). Kind 2
# fires ONLY when the CLOSING `)` line's terminal pipeline segment is a tool —
# conservative on purpose so a `... | \` continuation that ends in a safe stage
# (tr, jq) is NOT flagged, and so an `=$(...) ||` error-guard (the `||` contains
# a `|`) never starts a kind-2 lookahead. The kind-2 opener regex requires a
# single `|` then `\` at EOL ([^|]\| ... \\$), which excludes `||`.
# BSD AWK compatible: no \s, no + quantifier, no \b — uses index(), [[:space:]]*,
# and [^a-zA-Z0-9_] for word boundaries.
echo "Checking for unsafe VAR=\$(... | grep/awk/sed/head/tail) patterns..."
_r8_awk=$(mktemp)
# Output uses tab as field separator (file\tlinenum) so paths containing
# colons (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh)
# parse correctly — colon-based splitting breaks on such paths.
printf '%s\n' \
  'FNR == 1 {' \
  '  if (pending_line > 0) { if (pending_tool) print pending_fname "\t" pending_line; pending_line = 0; pending_tool = 0; pending_kind = 0 }' \
  '  in_heredoc = 0; hd_marker = ""; pending_fname = ""' \
  '}' \
  '{' \
  '  if (in_heredoc) {' \
  '    _close = $0; sub(/^[[:space:]]*/, "", _close)' \
  '    if (_close == hd_marker) in_heredoc = 0' \
  '    next' \
  '  }' \
  '  if (index($0, "<<") > 0) {' \
  '    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)' \
  '    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")' \
  '    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }' \
  '  }' \
  '  if (FNR > 1 && pending_line > 0) {' \
  '    if (index($0, "|| true") > 0 || index($0, "|| echo") > 0 || index($0, ": $?") > 0) {' \
  '      pending_line = 0; pending_tool = 0; pending_kind = 0' \
  '    } else if ($0 ~ /\)[[:space:]]*$/) {' \
  '      if (pending_kind == 1) {' \
  '        if (pending_tool) print pending_fname "\t" pending_line' \
  '      } else {' \
  '        if ($0 ~ /\|[^|]*(grep|awk|sed|head|tail)[^a-zA-Z0-9_]*\)[[:space:]]*$/ || $0 ~ /^[[:space:]]*(grep|awk|sed|head|tail)[^a-zA-Z0-9_].*\)[[:space:]]*$/) print pending_fname "\t" pending_line' \
  '      }' \
  '      pending_line = 0; pending_tool = 0; pending_kind = 0' \
  '    } else if (FNR - pending_line > 40) {' \
  '      if (pending_tool) print pending_fname "\t" pending_line' \
  '      pending_line = 0; pending_tool = 0; pending_kind = 0' \
  '    }' \
  '  }' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  if (index($0, "=$(") > 0 && $0 ~ /\|[^|]*(grep|awk|sed|head|tail)/) {' \
  '    if (index($0, "|| true") > 0 || index($0, "|| echo") > 0 || index($0, ": $?") > 0) next' \
  '    if ($0 ~ /\)[[:space:]]*$/) { print FILENAME "\t" FNR; next }' \
  '    pending_line = FNR; pending_fname = FILENAME; pending_tool = 1; pending_kind = 1' \
  '  }' \
  '  else if (index($0, "=$(") > 0 && $0 ~ /[^|]\|[[:space:]]*\\[[:space:]]*$/) {' \
  '    if (index($0, "|| true") > 0 || index($0, "|| echo") > 0 || index($0, ": $?") > 0) next' \
  '    pending_line = FNR; pending_fname = FILENAME; pending_tool = 0; pending_kind = 2' \
  '  }' \
  '}' \
  'END { if (pending_line > 0 && pending_tool) print pending_fname "\t" pending_line }' \
  > "$_r8_awk"

_r8_hits=$(awk -f "$_r8_awk" "${SHELL_FILES[@]}" </dev/null 2>/dev/null || true)
rm -f "$_r8_awk"
_r8_awk=""

if [ -n "$_r8_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    print_violation "$_hit_file" "$_hit_line" "UNSAFE_PIPE_IN_CMDSUB" \
      "VAR=\$(... | grep/awk/sed/head/tail) without || true can silently kill script under set -euo pipefail"
  done <<< "$_r8_hits"
fi

# Rule 9: Claude-specific tokens in lib/core/ (Provider Agnosticism)
echo "Checking for Claude-specific tokens in lib/core/ (provider agnosticism)..."
mapfile -t CORE_FILES < <(find "$PROJECT_ROOT/lib/core" -type f -name "*.sh" 2>/dev/null)

# Convert per-file bash while+grep loops to a single AWK pass over all core files.
# AWK processes all files in one invocation, reporting violations as FILE\tLINE\tMSG.
# MSG is a short tag; the outer bash loop maps tags to human messages.
# Tab separator keeps file/line/tag extraction safe for paths containing colons
# (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh).
_r9_hits=$(awk '
FNR == 1 { in_heredoc = 0; hd_marker = "" }
{
  if (in_heredoc) {
    _close = $0; sub(/^[[:space:]]*/, "", _close)
    if (_close == hd_marker) in_heredoc = 0
    next
  }
  # Intentional fall-through after setting in_heredoc=1: the opener line itself
  # is a shell command (e.g. "cmd <<EOF"), not heredoc body, so it must still
  # be checked for provider-specific tokens.
  if (index($0, "<<") > 0) {
    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
      hd_marker = _p[1]; in_heredoc = 1
    }
  }
  if ($0 ~ /^[[:space:]]*#/) next
  if (index($0, "/exit") > 0) print FILENAME "\t" FNR "\tSLASH_EXIT"
  if (index($0, "--print") > 0) print FILENAME "\t" FNR "\tPRINT_FLAG"
  if (index($0, "--dangerously-skip-permissions") > 0) print FILENAME "\t" FNR "\tDANG_SKIP"
  if (index($0, "--disallowedTools") > 0) print FILENAME "\t" FNR "\tDISALLOWED"
  if (index($0, "tool_use") > 0) print FILENAME "\t" FNR "\tTOOL_USE"
  if ($0 ~ /print_(status|info|error|warning)/ && index($0, "Claude CLI") > 0) print FILENAME "\t" FNR "\tHCPROVIDER"
  if ($0 ~ /print_(status|info|error|warning)/ && index($0, "Claude session") > 0) print FILENAME "\t" FNR "\tHCPROVIDER"
}' "${CORE_FILES[@]}" </dev/null 2>/dev/null || true)

if [ -n "$_r9_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum<TAB>tag — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    _hit_tag=$(echo "$_hit" | cut -f3)
    case "$_hit_tag" in
      SLASH_EXIT)  print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific token '/exit' found in lib/core/ - use provider_exit_instructions() instead" ;;
      PRINT_FLAG)  print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific flag '--print' found in lib/core/ - this should be in lib/providers/claude.sh" ;;
      DANG_SKIP)   print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific flag '--dangerously-skip-permissions' found in lib/core/" ;;
      DISALLOWED)  print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific flag '--disallowedTools' found in lib/core/ - use provider_build_tool_restrictions() instead" ;;
      TOOL_USE)    print_violation "$_hit_file" "$_hit_line" "CLAUDE_SPECIFIC_TOKEN" \
        "Provider-specific term 'tool_use' found in lib/core/" ;;
      HCPROVIDER)  print_violation "$_hit_file" "$_hit_line" "HARDCODED_PROVIDER_NAME" \
        "Hardcoded 'Claude CLI/session' in user-facing output - use \$(provider_name) instead" ;;
    esac
  done <<< "$_r9_hits"
fi

# Rule 10: BSD-only sed -i '' without portable wrapper (except portable-cmds.sh itself)
echo "Checking for bare 'sed -i \"\"' without portable wrapper..."
for file in "${SHELL_FILES[@]}"; do
  # portable-cmds.sh is the canonical implementation — skip it
  if [[ "$file" == */portable-cmds.sh ]]; then
    continue
  fi
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: sed -i '' (BSD form)
    if echo "$line_content" | grep -qE "sed\s+-i\s+''"; then
      print_violation "$file" "$line_num" "BARE_BSD_SED_I" \
        "Use portable_sed_i() from lib/utils/portable-cmds.sh instead of bare 'sed -i '''"
    fi
  done < <(grep -n "sed -i" "$file" 2>/dev/null || true)
done

# Rule 11: BSD-only stat -f (mtime) without portable wrapper (except portable-cmds.sh itself)
echo "Checking for bare 'stat -f' (BSD-only)..."
for file in "${SHELL_FILES[@]}"; do
  # portable-cmds.sh is the canonical implementation — skip it
  if [[ "$file" == */portable-cmds.sh ]]; then
    continue
  fi
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    if echo "$line_content" | grep -qE 'stat\s+-f'; then
      print_violation "$file" "$line_num" "BARE_BSD_STAT_F" \
        "Use portable_stat_mtime() or portable_find_max_mtime() from lib/utils/portable-cmds.sh instead of bare 'stat -f'"
    fi
  done < <(grep -n 'stat -f' "$file" 2>/dev/null || true)
done

# Rule 12: find piped to xargs without -0/-print0 pairing
echo "Checking for 'find ... | xargs' without -0 / -print0..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: xargs without -0 flag (lone xargs or xargs with flags but no -0)
    if echo "$line_content" | grep -qE '\bxargs\b' && \
       ! echo "$line_content" | grep -qE 'xargs\s+(-[a-zA-Z]*0|-0)'; then
      # Only flag if this is in a find pipeline context (same line has 'find' or
      # this looks like a continuation of a find pipe)
      if echo "$line_content" | grep -qE '\bfind\b.*\|.*\bxargs\b' || \
         echo "$line_content" | grep -qE '^\s*\|.*\bxargs\b'; then
        print_violation "$file" "$line_num" "XARGS_WITHOUT_NULL" \
          "Use 'find ... -print0 | xargs -0' to handle filenames with spaces"
      fi
    fi
  done < <(grep -n 'xargs' "$file" 2>/dev/null || true)
done

# Rule 13: Raw gh CLI calls not wrapped in gh_safe
# Catches: gh pr ..., gh issue ..., gh api ..., gh repo ..., gh label ..., gh diff ...
# Skips:   gh_safe calls, comment lines, heredoc body lines, gh-retry.sh itself
#
# Heredoc-aware: uses a single-pass AWK program per file to track heredoc open/close
# markers and skip all body lines inside them.  Lines inside a heredoc are not shell
# commands (they may be example scripts, instructional text, or prompt strings passed
# to AI tools) and must not be flagged.
# AWK is used instead of a bash while+grep loop for performance: spawning one grep
# subprocess per line is prohibitively slow on large files (e.g. claude-workflow.sh
# at ~2800 lines would launch ~8000 subprocesses).
echo "Checking for raw 'gh' CLI calls not wrapped in gh_safe..."
_r13_awk=$(mktemp)
# The AWK program is written to a temp file to:
# 1. Avoid shell quoting issues (single-quote literals in AWK regex)
# 2. Ensure BSD AWK (macOS) compatibility: no \< \> word boundaries, no + quantifier,
#    no PATTERN && PATTERN { } compound rules, no !~ operator.
#    All logic uses a single { } action block with if/else and index()/match().
printf '%s\n' \
  '{' \
  '  # Heredoc close: strip leading whitespace before comparing to support' \
  '  # <<-MARKER (tab-indented terminators) — bare terminator exits heredoc mode.' \
  '  if (in_heredoc) {' \
  '    _close = $0; sub(/^[[:space:]]*/, "", _close)' \
  '    if (_close == hd_marker) in_heredoc = 0' \
  '    next' \
  '  }' \
  '  # Heredoc open: detect <<MARKER, <<-MARKER, <<'"'"'MARKER'"'"', <<"MARKER" on this line.' \
  '  # sub strips everything up to << and an optional - (for <<-) so that <<-MARKER' \
  '  # leaves only MARKER in tok (without the leading dash that caused the heredoc' \
  '  # state to be skipped entirely in the old pattern).' \
  '  # Fall through after opening: the line itself is a command, not heredoc body.' \
  '  if (index($0, "<<") > 0) {' \
  '    tok = $0' \
  '    sub(/.*<<-?[[:space:]]*/, "", tok)' \
  '    gsub(/['"'"'"]/, "", tok)' \
  '    split(tok, _p, " ")' \
  '    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {' \
  '      hd_marker = _p[1]; in_heredoc = 1' \
  '    }' \
  '  }' \
  '  # Skip full-line comments' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  # Skip output/print lines (gh in echo/printf is always quoted text, not a call)' \
  '  if ($0 ~ /^[[:space:]]*(echo|printf|print_info|print_status|print_warning|print_error|cat)[[:space:]]/) next' \
  '  # Skip instructional/prose text lines (multi-line prompt bodies, etc.)' \
  '  if ($0 ~ /^[[:space:]]*(Do NOT|Run:|use:|Check if|Example:|example:)/) next' \
  '  # Skip lines with inline (use: ...) markup — these are prompt text, not shell commands' \
  '  if (index($0, "(use:") > 0) next' \
  '  # Flag: gh call for known subcommands not wrapped in gh_safe.' \
  '  # Pattern requires "gh" to be preceded by a command-context character (any whitespace,' \
  '  # (, |, ;, $) or appear at start-of-line after whitespace.  [[:space:]] covers both' \
  '  # spaces and tabs, preventing false negatives for tab-indented gh calls.' \
  '  # Output uses tab as field separator (file\tlinenum) so paths containing colons' \
  '  # (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh) parse correctly.' \
  '  if (index($0, "gh_safe") == 0) {' \
  '    if ($0 ~ /^[[:space:]]*gh[[:space:]][[:space:]]*(pr|issue|api|repo|label|diff)/ ||' \
  '        $0 ~ /[[:space:](|;$]gh[[:space:]][[:space:]]*(pr|issue|api|repo|label|diff)/) {' \
  '      print FILENAME "\t" NR' \
  '    }' \
  '  }' \
  '}' \
  > "$_r13_awk"

for file in "${SHELL_FILES[@]}"; do
  # gh-retry.sh defines gh_safe and intentionally calls raw gh — skip it
  if [[ "$file" == */gh-retry.sh ]]; then
    continue
  fi

  _r13_hits=$(awk -f "$_r13_awk" "$file" 2>/dev/null || true)

  if [ -n "$_r13_hits" ]; then
    while IFS= read -r _hit; do
      # Tab-separated: file<TAB>linenum — safe for paths containing colons
      _hit_file=$(echo "$_hit" | cut -f1)
      _hit_line=$(echo "$_hit" | cut -f2)
      print_violation "$_hit_file" "$_hit_line" "GH_UNSAFE_CALL" \
        "Raw 'gh' call — wrap with gh_safe to get retry/resilience (lib/utils/gh-retry.sh)"
    done <<< "$_r13_hits"
  fi
done
rm -f "$_r13_awk"
_r13_awk=""

# Rule 14: ${VAR:-"{}"} appends a stray '}' to non-empty values
# Bash parses ${VAR:-"{}"} as ${VAR:-{} + literal '}', so when VAR is non-empty
# the result is "$VAR}" — corrupting JSON that already ends in '}'.
# Live bug: every batch crash with "jq: parse error: Unmatched '}'".
# Fix: quote the default — "${VAR:-"{}"}".
echo "Checking for '\${VAR:-\"{}\"}' parameter expansion bug..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    if echo "$line_content" | grep -qE ':-\{\}\}'; then
      print_violation "$file" "$line_num" "JQ_DEFAULT_BRACE" \
        "\${VAR:-\"{}\"} appends stray '}' to non-empty values — use \"\${VAR:-\"{}\"}\" instead"
    fi
  done < <(grep -nE ':-\{\}\}' "$file" 2>/dev/null || true)
done

# Rule 15: Unanchored sharkrite marker grep (bare-prefix guard, silent-death risk)
#
# Pattern: grep -q[E]? "sharkrite-[a-z-]+:" without a format anchor ([0-9]+, etc.)
#
# Exploitation vector: any issue body that DOCUMENTS a marker format with a
# placeholder value (e.g. "sharkrite-parent-pr:N") will match the bare-prefix
# guard. The outer guard triggers, the inner extraction returns empty (because
# the placeholder isn't a real number), and under set -e + pipefail the script
# dies silently with no error output.
#
# Live bug: 2026-05-31 — three batch runs died at Processing Issue #34 because
# #34's body listed "sharkrite-parent-pr:N" as documentation. Fix: commit 206f2be
# added [0-9]+ to the outer guard in batch-process-issues.sh; same fix applied to
# claude-workflow.sh as part of the codebase sweep in issue #90.
#
# Safe anchored patterns:
#   grep -qE "sharkrite-parent-pr:[0-9]+"     # digits required
#   grep -qE "sharkrite-follow-up:[0-9]+"     # digits required
#
# Unsafe bare-prefix patterns:
#   grep -q "sharkrite-parent-pr:"            # matches any text after colon
#   grep -qE "sharkrite-parent-pr:"           # same, with -E flag
echo "Checking for unanchored sharkrite marker grep patterns (bare-prefix guard)..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # Match: grep -q or grep -qE with a bare sharkrite-marker: pattern (colon at end).
    # The outer regex anchors on the closing :"  — so grep -qE "sharkrite-foo:[0-9]+"
    # does NOT match here (colon is followed by [0-9]+ not a closing quote).
    # Belt-and-suspenders: the inner check also verifies no [0-9] anchor is present,
    # guarding against edge cases where the outer regex might still match.
    if echo "$line_content" | grep -qE 'grep\s+-q[E]?\s+"sharkrite-[a-z-]+:"'; then
      # Extra guard: if the line somehow includes a format anchor despite the outer match,
      # skip it — the dev wrote something unusual but intentional.
      if ! echo "$line_content" | grep -qE '\[0-9\]|\[a-zA-Z0-9'; then
        print_violation "$file" "$line_num" "BARE_MARKER_GREP" \
          "Unanchored sharkrite marker grep — add a format anchor like [0-9]+ to prevent silent death when issue bodies document the marker format"
      fi
    fi
  done < <(grep -n 'grep.*sharkrite-' "$file" 2>/dev/null || true)
done

# Rule 16: Missing re-source guard in lib/utils/, lib/providers/, lib/core/ files
#
# Every file in lib/ that is a sourced library (not a standalone executable invoked
# via bash directly) MUST be idempotent on re-source. Without a guard, sourcing a
# file twice under set -euo pipefail can re-execute initialization code and crash
# (e.g., re-assigning readonly vars, re-running program logic, re-printing banners).
#
# Live bugs that resulted from missing or wrong guards:
#   #61: assess-documentation.sh — verbose_info undefined (missing dep source)
#   #69: issue-lock.sh — guard checked wrong variable
#   2267841: stash-manager.sh — readonly crash on re-source
#
# Accepted guard forms (any of these in the first 40 lines is sufficient):
#   - declare -f <fn_name> >/dev/null 2>&1 (canonical — function-based idempotency)
#   - return 0 2>/dev/null               (early-return idiom used with the above)
#   - _RITE_*_LOADED variable guard      (variable-based idempotency for executables)
#   - RITE_SOURCE_FUNCTIONS_ONLY         (test-mode guard for executables with body code)
#
# Files in bin/ and tools/ are excluded — they are run directly, never sourced.
echo "Checking for missing re-source guards in lib/ files..."
mapfile -t LIB_FILES < <(find "$PROJECT_ROOT/lib" -type f -name "*.sh" 2>/dev/null)

for file in "${LIB_FILES[@]}"; do
  # Check only the first 60 lines for the guard (guards must appear near the top;
  # 60 lines accommodates files with longer header comments like issue-lock.sh)
  head40=$(head -60 "$file" 2>/dev/null)

  # Accepted guard patterns:
  #   1. declare -f <name> >/dev/null 2>&1 (canonical function-based guard)
  #   2. return 0 2>/dev/null (idempotent return — used in guard bodies)
  #   3. _RITE_*_LOADED variable guard
  #   4. RITE_SOURCE_FUNCTIONS_ONLY (test-mode early-exit for executables)
  if echo "$head40" | grep -qE \
    'declare -f [a-z_]+ >/dev/null 2>&1|return 0 2>/dev/null|_RITE_[A-Z_]+_LOADED|RITE_SOURCE_FUNCTIONS_ONLY'; then
    continue
  fi

  # No guard found — flag as a violation
  print_violation "$file" "1" "MISSING_RESOURCE_GUARD" \
    "lib file has no re-source guard — add 'if declare -f <fn> >/dev/null 2>&1; then return 0 2>/dev/null || true; fi' near top"
done

# Rule 17: Bare `readonly` declaration at top level in lib/ files
#
# `readonly VAR=value` at the top level of a sourced library file will crash
# with "readonly: VAR: is read-only" when the file is sourced a second time
# under `set -euo pipefail`. This is a silent killer: the script dies with
# no error output, making it extremely hard to diagnose.
#
# Safe alternatives:
#   1. Use a re-source guard (Rule 16) so the declaration never runs twice.
#      The guard alone is sufficient — the readonly line itself need not change.
#   2. Change to: VAR="${VAR:-default_value}"  (idempotent even without a guard)
#   3. Change to: declare -r VAR=value         (still crashes on re-source, but
#      at least the intent is explicit — only OK if a guard is present)
#
# This rule flags files that contain a bare top-level `readonly VAR=` line
# but do NOT have any of the accepted re-source guard patterns. Files that
# already have a guard (checked by Rule 16) are safe and are skipped here.
#
# Suppression: add a comment on the preceding line:
#   # sharkrite-lint disable UNGUARDED_READONLY - Reason: ...
echo "Checking for unguarded readonly declarations in lib/ files..."

for file in "${LIB_FILES[@]}"; do
  # Skip files with no readonly declarations at all (fast path)
  grep -q '^readonly ' "$file" 2>/dev/null || continue

  # Check if this file has an accepted re-source guard in the first 60 lines
  head60=$(head -60 "$file" 2>/dev/null)
  if echo "$head60" | grep -qE \
    'declare -f [a-z_]+ >/dev/null 2>&1|return 0 2>/dev/null|_RITE_[A-Z_]+_LOADED|RITE_SOURCE_FUNCTIONS_ONLY'; then
    # File has a guard — the readonly is protected, skip it
    continue
  fi

  # No guard present — check each `readonly` line (top-level only)
  while IFS=: read -r line_num line_content; do
    # Check for suppression comment on the preceding line
    preceding_line=""
    if [ "$line_num" -gt 1 ] 2>/dev/null; then
      preceding_line=$(sed -n "$((line_num - 1))p" "$file" 2>/dev/null || true)
    fi
    if echo "$preceding_line" | grep -q 'sharkrite-lint disable UNGUARDED_READONLY'; then
      continue
    fi

    print_violation "$file" "$line_num" "UNGUARDED_READONLY" \
      "bare 'readonly' declaration without a re-source guard — will crash with 'readonly: is read-only' on second source; add a guard or use VAR=\${VAR:-default}"
  done < <(grep -n '^readonly ' "$file" 2>/dev/null || true)
done

# Rule 18: Unbalanced or duplicated sharkrite-extract marker pairs
#
# sharkrite-extract markers delimit code blocks for sed range extraction in
# regression tests (pattern: `# sharkrite-extract: <name>-start` / `<name>-end`).
# Two failure modes exist that sed's /start/,/end/p silently mishandles:
#
#   1. Missing marker: sed finds no range boundaries → empty output. Any
#      downstream [ -n "$VAR" ] guard or content-anchor check will fail, but
#      the failure message says nothing about the root cause (marker removal).
#
#   2. Duplicate marker: sed opens the range at the first start marker and
#      closes at the first matching end marker, including everything between
#      multiple loop copies. The extracted code is over-broad and wrong, but
#      the non-empty and content-anchor checks still pass — a silent mis-extraction.
#
# This rule requires exactly-one-of-each: one start and one end per unique
# marker name, with start appearing before end. Non-1 counts are violations.
#
# Scope: source files only (bin/, lib/, tools/) — test files (tests/) are
# intentionally excluded because regression tests legitimately reference marker
# names inside grep patterns and heredoc fixture scripts to validate the
# extraction behavior. Scanning tests/ would produce false positives on those
# intentional multi-occurrence strings. The bats codebase-sweep test in
# tests/regression/marker-sed-extraction-validation.bats independently verifies
# all real source-file markers are balanced.
#
# File list: reuses SHELL_FILES (built above) — same find flags (-L), same
# exclusions (test-fixtures-temp*, sharkrite-lint.sh), and already includes
# any RITE_LINT_EXTRA_DIRS entries. No separate find block needed.
echo "Checking for unbalanced or duplicated sharkrite-extract marker pairs..."

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
  print_warning "tools/sharkrite-lint.sh" "0" "UNBALANCED_EXTRACT_MARKERS" \
    "Rule 18 found no source files to scan — check that bin/, lib/, and tools/ exist under PROJECT_ROOT ($PROJECT_ROOT)"
fi

# Collect all start markers across all files, then verify each has exactly one
# matching end marker in the same file. Use awk to extract (file, marker_name)
# pairs efficiently.
# Guard against empty array explicitly: grep with an empty argument list reads
# from stdin, which would block indefinitely under automation.
# AWK outputs tab-separated "file\tlinenum\tcontent" so that paths containing
# colons (e.g. CI matrix job paths like /home/runner/work/my:project/file.sh)
# parse correctly — colon-based field splitting breaks on such paths.
_r18_starts=""
_r18_ends=""
if [ "${#SHELL_FILES[@]}" -gt 0 ]; then
  _r18_starts=$(awk '/# sharkrite-extract: .*-start/ { print FILENAME "\t" FNR "\t" $0 }' \
    "${SHELL_FILES[@]}" 2>/dev/null || true)
  _r18_ends=$(awk '/# sharkrite-extract: .*-end/ { print FILENAME "\t" FNR "\t" $0 }' \
    "${SHELL_FILES[@]}" 2>/dev/null || true)
fi

# Collect unique (file, marker_name) pairs from start markers.
# For each, verify the count in that file is exactly 1 for both start and end.
declare -A _seen_pairs
while IFS= read -r _hit; do
  [ -z "$_hit" ] && continue
  # Format: file<TAB>linenum<TAB>  # sharkrite-extract: <name>-start
  # Tab-separated: safe for paths containing colons
  _hit_file=$(echo "$_hit" | cut -f1)
  _hit_line=$(echo "$_hit" | cut -f2)
  _hit_name=$(echo "$_hit" | grep -oE 'sharkrite-extract: [a-z0-9_-]+-start' | sed 's/-start$//' | sed 's/sharkrite-extract: //' || true)
  [ -z "$_hit_name" ] && continue

  _pair_key="${_hit_file}::${_hit_name}"
  # Only process each (file, name) pair once
  [ "${_seen_pairs[$_pair_key]+set}" = "set" ] && continue
  _seen_pairs[$_pair_key]=1

  # Count start occurrences in this file
  _start_count=$(grep -c "# sharkrite-extract: ${_hit_name}-start" "$_hit_file" 2>/dev/null || true)
  # Count end occurrences in this file
  _end_count=$(grep -c "# sharkrite-extract: ${_hit_name}-end" "$_hit_file" 2>/dev/null || true)

  if [ "$_start_count" -ne 1 ]; then
    print_violation "$_hit_file" "$_hit_line" "UNBALANCED_EXTRACT_MARKERS" \
      "sharkrite-extract marker '${_hit_name}-start' appears ${_start_count} times (expected 1) — sed range extraction will mis-extract or yield empty output"
  fi
  if [ "$_end_count" -ne 1 ]; then
    print_violation "$_hit_file" "$_hit_line" "UNBALANCED_EXTRACT_MARKERS" \
      "sharkrite-extract marker '${_hit_name}-end' appears ${_end_count} times (expected 1) — sed range extraction will mis-extract or yield empty output"
  fi

  # Verify start appears before end (line ordering)
  if [ "$_start_count" -eq 1 ] && [ "$_end_count" -eq 1 ]; then
    _start_line=$(grep -n "# sharkrite-extract: ${_hit_name}-start" "$_hit_file" 2>/dev/null | cut -d: -f1 || true)
    _end_line=$(grep -n "# sharkrite-extract: ${_hit_name}-end" "$_hit_file" 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$_start_line" ] && [ -n "$_end_line" ] && [ "$_start_line" -ge "$_end_line" ]; then
      print_violation "$_hit_file" "$_start_line" "UNBALANCED_EXTRACT_MARKERS" \
        "sharkrite-extract marker '${_hit_name}-start' (line ${_start_line}) does not precede '${_hit_name}-end' (line ${_end_line}) — sed range extraction will yield empty output"
    fi
  fi
done <<< "$_r18_starts"

# Also flag end markers that have no corresponding start in the same file.
# No (file, name) deduplication here: each occurrence of an orphaned end marker
# is its own violation. If two end markers share a name but no start exists, both
# lines must be reported individually. Pairs already processed by the start-marker
# loop above (i.e., where a start exists) are still skipped via _seen_pairs to
# avoid double-reporting the same (file, name) problem.
while IFS= read -r _hit; do
  [ -z "$_hit" ] && continue
  # Tab-separated: file<TAB>linenum<TAB>content — safe for paths containing colons
  _hit_file=$(echo "$_hit" | cut -f1)
  _hit_line=$(echo "$_hit" | cut -f2)
  _hit_name=$(echo "$_hit" | grep -oE 'sharkrite-extract: [a-z0-9_-]+-end' | sed 's/-end$//' | sed 's/sharkrite-extract: //' || true)
  [ -z "$_hit_name" ] && continue

  _pair_key="${_hit_file}::${_hit_name}"

  # If this (file, name) pair was already processed via starts, skip it.
  # The start-marker loop already reported the imbalance (e.g. end count != 1).
  [ "${_seen_pairs[$_pair_key]+set}" = "set" ] && continue

  # End marker exists but no start marker — orphaned end.
  # Report each occurrence individually: two orphaned ends = two violations.
  _start_count=$(grep -c "# sharkrite-extract: ${_hit_name}-start" "$_hit_file" 2>/dev/null || true)
  if [ "$_start_count" -eq 0 ]; then
    print_violation "$_hit_file" "$_hit_line" "UNBALANCED_EXTRACT_MARKERS" \
      "sharkrite-extract marker '${_hit_name}-end' has no matching '${_hit_name}-start' in the same file — sed range extraction will yield empty output"
  fi
done <<< "$_r18_ends"

# Rule 19: Raw sharkrite-* marker literals in shell source files
#
# All sharkrite-* marker strings must be referenced via the RITE_MARKER_*
# constants defined in lib/utils/markers.sh. Hard-coded literals scattered
# across files make future renames error-prone and inconsistent.
#
# Allowlist (files where literal marker strings are required or expected):
#   - lib/utils/markers.sh        — the canonical source-of-truth definitions
#   - tests/                      — bats tests may grep for/assert on marker strings
#   - tools/sharkrite-lint.sh     — this file; rule definitions contain the pattern
#
# Comment lines (lines where # precedes the marker) are skipped: inline
# documentation and sharkrite-lint disable comments are not functional code.
#
# The grep in jq filter strings that already use $RITE_MARKER_* would not
# produce literal "sharkrite-" strings; this rule catches places that still
# have the string baked in as a literal.
echo "Checking for raw sharkrite-* marker literals (use RITE_MARKER_* constants)..."

for file in "${SHELL_FILES[@]}"; do
  # Allowlist: markers.sh itself (the definitions), and this lint file
  if [[ "$file" == */lib/utils/markers.sh ]] || [[ "$file" == */tools/sharkrite-lint.sh ]]; then
    continue
  fi

  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Skip inline comments: if "sharkrite-" appears only after a # on the same line
    # (i.e., the non-comment portion does not contain sharkrite-), skip it.
    # Strip everything from the first # (that is not inside a string) — heuristic:
    # remove from unquoted # onwards and check if sharkrite- is still present.
    _code_part=$(echo "$line_content" | sed 's/#.*//' || true)
    if ! echo "$_code_part" | grep -qE 'sharkrite-[a-z]'; then
      continue
    fi
    # Code portion still has a literal — flag it
    print_violation "$file" "$line_num" "RAW_MARKER_LITERAL" \
      "literal 'sharkrite-*' marker string — use the RITE_MARKER_* constant from lib/utils/markers.sh instead"
  done < <(grep -n 'sharkrite-[a-z]' "$file" 2>/dev/null || true)
done

# Rule 20: Test stub committed to production path (CRITICAL)
#
# Live incident: PR #260 (2026-06-02) replaced the real 1,018-line
# lib/core/assess-review-issues.sh with a 9-line test stub. The stub
# header read "# Stub assess-review-issues.sh: outputs MOCK_ASSESSMENT_FILE
# content to stdout." and the file referenced MOCK_ASSESSMENT_FILE as the
# data source. The whole production assessment phase was silently broken
# for days — the workflow gracefully fell back to "raw review count" and
# kept merging PRs without proper ACTIONABLE_NOW/LATER classification.
#
# Why it slipped past existing checks:
#   - Shellcheck doesn't know "this file is supposed to be 1000+ lines"
#   - Integration tests INJECT their own stub into a temp dir; the real
#     production file is independent and was never directly tested
#   - PR review was auto-generated (--fix-review mode) and didn't flag
#     the wholesale replacement
#
# The signal: production files (lib/core/, lib/utils/, lib/providers/)
# should never contain stub markers. A "stub" file in production paths
# means someone accidentally committed a test fixture.
#
# Detection patterns:
#   - File header comment starting with "# Stub " in the first 5 lines
#   - References to MOCK_*_FILE environment variables (test-only convention)
#   - "STUB ERROR" string literal (test-stub error message)
echo "Checking for test stubs committed to production paths (lib/)..."

for file in "${SHELL_FILES[@]}"; do
  # Only check production paths
  if [[ "$file" != */lib/core/* ]] && [[ "$file" != */lib/utils/* ]] && [[ "$file" != */lib/providers/* ]]; then
    continue
  fi
  # Skip this lint file itself (we mention the patterns in comments)
  if [[ "$file" == */tools/sharkrite-lint.sh ]]; then
    continue
  fi

  # Signal 1: "# Stub " header comment in first 5 lines
  if head -5 "$file" 2>/dev/null | grep -qE '^#[[:space:]]+Stub[[:space:]]'; then
    print_violation "$file" "1" "TEST_STUB_IN_LIB" \
      "file header starts with '# Stub' — test stubs must not live in lib/. Real implementation may have been overwritten (see Rule 20 in tools/sharkrite-lint.sh for incident context)"
    continue   # one violation per file is enough
  fi

  # Signal 2: MOCK_*_FILE reference in production code
  while IFS=: read -r line_num _; do
    print_violation "$file" "$line_num" "TEST_STUB_IN_LIB" \
      "production file references MOCK_*_FILE (test-only convention) — likely a test stub committed in error"
    break  # one per file
  done < <(grep -nE 'MOCK_[A-Z_]+_FILE' "$file" 2>/dev/null || true)

  # Signal 3: "STUB ERROR" string literal in production code
  while IFS=: read -r line_num _; do
    print_violation "$file" "$line_num" "TEST_STUB_IN_LIB" \
      "production file emits 'STUB ERROR' — likely a test stub committed in error"
    break
  done < <(grep -n 'STUB ERROR' "$file" 2>/dev/null || true)
done

# Rule 21: bash 4+ builtins in #!/bin/bash scripts without a version guard
#
# `mapfile`, `readarray`, and `declare -A` are bash 4.0+ features. Scripts with
# a `#!/bin/bash` shebang run under macOS system bash 3.2 when executed directly
# (e.g., as a CLI entrypoint) and will crash at the bash-4+ line without the
# self-re-exec guard pattern established in batch-process-issues.sh:69-77.
#
# Live crash (2026-06-04): rite --undo <N> with follow-up issues exploded:
#   /bin/bash: line 133: mapfile: command not found
# Root cause: undo-workflow.sh used mapfile for deduplication but lacked the
# bash-version guard present in batch-process-issues.sh. Fixed in issue #327.
#
# A file is EXEMPT when it contains a functional BASH_VERSINFO version-
# comparison guard: BASH_VERSINFO[<index>] used with a comparison operator
# and a version number on the same line. Bare mentions of BASH_VERSINFO in
# comments or diagnostic output do NOT exempt the file.
#
# Canonical guard shapes (from the codebase):
#   [ "${BASH_VERSINFO[0]}" -lt 4 ]   (test builtin numeric comparison)
#   (( BASH_VERSINFO[0] < 4 ))        (arithmetic conditional)
#
# The rule ONLY fires on #!/bin/bash scripts — not #!/usr/bin/env bash ones.
# The latter let the user's PATH pick the bash binary, so Homebrew bash 5.x
# is typically found first. Only #!/bin/bash is pinned to macOS's 3.2 binary.
#
# Suppression: add on the line immediately before the bash-4+ builtin:
#   # sharkrite-lint disable BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT - reason: <text>
echo "Checking for bash 4+ builtins in #!/bin/bash scripts without a version guard..."

for file in "${SHELL_FILES[@]}"; do
  # Only flag files with #!/bin/bash shebang (not #!/usr/bin/env bash)
  first_line=$(head -1 "$file" 2>/dev/null || true)
  if ! echo "$first_line" | grep -qE '^#!/bin/bash'; then
    continue
  fi

  # Exempt: file has a functional BASH_VERSINFO version-comparison guard.
  #
  # Two bugs to avoid in this check:
  #
  #   1. Comment lines must NOT grant exemption: a comment documenting the
  #      guard pattern (e.g. "# if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then")
  #      contains the full pattern and would exempt a file with no real guard
  #      if we scan all lines.  Fix: strip comment lines before matching.
  #
  #   2. Redirects to numeric filenames must NOT grant exemption: the
  #      arithmetic-operator alternative "[<>=!][=]?[[:space:]]*[0-9]" also
  #      matches shell redirect syntax like ">2" (stdout to file named "2").
  #      A diagnostic line such as `echo "${BASH_VERSINFO[0]}" >2` would
  #      incorrectly exempt the file.  Fix: anchor the arithmetic form to a
  #      "(( " prefix so it only matches inside arithmetic conditionals,
  #      where ">" is always a comparison, never a redirect.
  #
  # Two passes — one per canonical guard shape:
  #
  #   Shape 1 (test builtin):   [ "${BASH_VERSINFO[0]}" -lt 4 ]
  #   Shape 2 (arithmetic):     (( BASH_VERSINFO[0] < 4 ))
  #
  # Comment lines (^[[:space:]]*#) are stripped before both passes so that
  # commented-out guards do not trigger the exemption.
  _non_comment_lines=$(grep -v '^[[:space:]]*#' "$file" 2>/dev/null || true)
  # Shape 1: test-builtin numeric comparison (-lt/-gt/-le/-ge/-eq/-ne)
  # No redirect ambiguity: -lt etc. are unambiguous comparison keywords.
  if echo "$_non_comment_lines" | grep -qE 'BASH_VERSINFO\[[0-9]+\][^#]*(-lt|-gt|-le|-ge|-eq|-ne)[[:space:]]+[0-9]'; then
    continue
  fi
  # Shape 2: arithmetic conditional — anchored to "((" so ">" means comparison,
  # not redirect.  Inside "(( ))", "<" and ">" are always arithmetic operators.
  if echo "$_non_comment_lines" | grep -qE '\(\([^)]*BASH_VERSINFO\[[0-9]+\][^)]*[<>][=]?[[:space:]]*[0-9]'; then
    continue
  fi

  # Check each line for bash-4+ builtins: mapfile, readarray, declare -A
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # Check for suppression comment on the preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT'; then
      continue
    fi

    # Detect mapfile or readarray (array-population builtins, bash 4+ only)
    if echo "$line_content" | grep -qE '\b(mapfile|readarray)\b'; then
      print_violation "$file" "$line_num" "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" \
        "'mapfile'/'readarray' is a bash 4+ builtin — crashes on macOS system bash 3.2. Add a BASH_VERSINFO re-exec guard (see batch-process-issues.sh:69-77) or replace with a portable while-read loop"
    fi

    # Detect declare -A / declare -gA / declare -Ar / local -A (associative arrays, bash 4+ only)
    if echo "$line_content" | grep -qE '\bdeclare\s+-[a-zA-Z]*A[a-zA-Z]*\b|\blocal\s+-[a-zA-Z]*A[a-zA-Z]*\b'; then
      print_violation "$file" "$line_num" "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" \
        "'declare/local -A' (associative array) is bash 4+ only — crashes on macOS system bash 3.2. Add a BASH_VERSINFO re-exec guard (see batch-process-issues.sh:69-77)"
    fi
  done < <(grep -nE '(mapfile|readarray|declare\s+-[a-zA-Z]*A|local\s+-[a-zA-Z]*A)' "$file" 2>/dev/null || true)
done

# Rule 22: function-sentinel re-source guard combined with `export -f` (subprocess-stale trap)
#
# When a lib file `export -f`s any function AND guards its top with
# `if declare -f <fn> >/dev/null 2>&1; then return 0; fi`, a subprocess of a
# parent that already sourced an OLDER version of the file inherits the parent's
# exported function set. The function-sentinel guard sees the inherited stale
# function, short-circuits, and never redefines anything — including functions
# added to the file after the parent started. Functions added mid-batch then
# appear undefined in the subprocess despite existing on disk.
#
# Live failure (2026-06-04): PR #350 added detect_lib_shrinkage to
# blocker-rules.sh and merged mid-batch. Subsequent issues exec'd create-pr.sh
# as subprocesses; create-pr.sh called detect_lib_shrinkage; subprocess inherited
# stale exports from batch-process-issues.sh's earlier source; function-sentinel
# guard fired; "detect_lib_shrinkage: command not found" → whole batch failed in
# PR phase. See: tests/regression/blocker-rules-stale-inherited-functions.bats
# and blocker-rules.sh:18-37 for the canonical fix.
#
# Fix: switch the guard to a variable sentinel that is NOT exported, so true
# subprocesses see it unset and re-source against the current on-disk file:
#
#   if [ "${_RITE_<NAME>_LOADED:-}" = "true" ]; then
#     return 0 2>/dev/null || true
#   fi
#   _RITE_<NAME>_LOADED=true   # NO `export` — that defeats the whole point
echo "Checking for function-sentinel guard + export -f combo (subprocess-stale trap)..."

for file in "${SHELL_FILES[@]}"; do
  # Trigger condition: file `export -f`s at least one function at top level.
  # No need to path-filter to lib/ — bin/ and tools/ scripts don't `export -f`
  # in practice, so the trigger condition is the natural filter, and it lets
  # the rule scan fixtures injected via RITE_LINT_EXTRA_DIRS.
  if ! grep -qE '^[[:space:]]*export -f[[:space:]]+[a-zA-Z_]' "$file"; then
    continue
  fi

  # Look in the first 80 lines (some guards live past env-var defaults) for the
  # dangerous pattern: `if declare -f <fn> >/dev/null 2>&1; then` immediately
  # followed within 2 lines by a `return 0` body. That signature is the
  # re-source guard form, not the `if ! declare -f <fn>; then source <dep>; fi`
  # dependency-check form.
  guard_line=$(head -80 "$file" | awk '
    /^if declare -f [a-zA-Z_]+ >\/dev\/null 2>&1; then$/ {
      hit_line = NR; in_block = 1; body_lines = 0; next
    }
    in_block {
      body_lines++
      if (/return 0/) { print hit_line; exit 0 }
      if (body_lines > 2) in_block = 0
    }
  ' || true)

  if [ -n "$guard_line" ]; then
    print_violation "$file" "$guard_line" "FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F" \
      "function-sentinel re-source guard combined with 'export -f' is unsafe — subprocesses of a batch parent inherit stale exported functions, the guard short-circuits, and functions added to this file after the parent started never get defined. Switch to a non-exported variable guard: see lib/utils/blocker-rules.sh:18-38 for the canonical pattern, tests/regression/blocker-rules-stale-inherited-functions.bats for what it must satisfy."
  fi
done

# Rule 23: MISSING_TAG_JUSTIFICATION — tag in convention block not in tag-index.md
#          and not in the same block's new-tags: field
#
# When a <!-- sharkrite-convention --> block declares `tags: foo, bar`, every tag
# must either:
#   (a) already have a `## foo` heading in docs/architecture/tag-index.md, OR
#   (b) appear in the same block's `new-tags:` section with a justification line.
#
# Without this rule, a contributor could introduce a tag that silently fails to
# accumulate pointers because no matching heading exists in the index.  Forcing
# explicit `new-tags:` justification keeps the index coherent and makes drift
# visible at authoring time (rather than silently at merge time).
#
# Tag-index path: derived from PROJECT_ROOT, same location as the write helpers.
# When tag-index.md does not exist, this rule is skipped entirely — a missing
# index is acceptable before the first tagged PR merges.
#
# Override: set RITE_TAG_INDEX_PATH_OVERRIDE to redirect to a temp file.
# This is the test-isolation hook — tests set this variable so the linter reads
# a seeded fixture instead of the real docs/architecture/tag-index.md.
# Without this, any test that seeds tag-index.md must mutate the real file, which
# is a crash-unsafe isolation hazard (backup/restore races in parallel runs).
#
# Files scanned: SHELL_FILES (bin/, lib/, tools/) — the same files already
# processed by other lint rules.  Convention blocks may also appear embedded as
# heredoc strings in PR creation scripts; the file scan catches those.
echo "Checking for missing tag justification in convention blocks..."

_tag_index_path="${RITE_TAG_INDEX_PATH_OVERRIDE:-${PROJECT_ROOT}/docs/architecture/tag-index.md}"

# Only run the check when tag-index.md exists; a missing index means no tags
# have been established yet, so no violation is possible.
if [ -f "$_tag_index_path" ]; then

  # Build a set of known tags from the index — one tag name per line, lowercased.
  # Parse `## tagname` headings.  Use awk for BSD AWK compatibility.
  _known_tags_file=$(mktemp)
  awk '/^## / { tag=substr($0, 4); sub(/^[[:space:]]+/, "", tag); sub(/[[:space:]]+$/, "", tag); print tolower(tag) }' \
    "$_tag_index_path" > "$_known_tags_file" 2>/dev/null || true

  for file in "${SHELL_FILES[@]}"; do
    # Use awk to extract convention blocks and check their tags fields.
    # The awk program:
    #   1. Collects lines between <!-- sharkrite-convention --> markers.
    #   2. On block-end, checks each tag from `tags:` against:
    #      a. The known_tags_file (pre-built tag list).
    #      b. The `new-tags:` section inside the same block.
    #   3. Reports "FILE:LINE:TAGNAME" for each unresolved tag.
    #
    # Variables passed to awk:
    #   open_marker  — the exact opening marker string (via variable to satisfy RAW_MARKER_LITERAL lint)
    #   close_marker — the exact closing marker string
    #   tags_file    — path to the pre-built known tags file
    _r23_violations=$(awk \
      -v open_marker="<!-- sharkrite-convention -->" \
      -v close_marker="<!-- /sharkrite-convention -->" \
      -v tags_file="$_known_tags_file" \
      'BEGIN {
        # Load known tags into associative array
        while ((getline tag_line < tags_file) > 0) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", tag_line)
          if (length(tag_line) > 0) known_tags[tag_line] = 1
        }
        close(tags_file)
        in_block = 0
        block_start_line = 0
        tags_line = ""
        new_tags_block = ""
      }
      $0 == open_marker  { in_block = 1; block_start_line = NR; tags_line = ""; new_tags_block = ""; in_new_tags = 0; in_example = 0; next }
      $0 == close_marker {
        if (!in_block) { next }
        in_block = 0

        # Parse tags: field (comma-separated)
        if (length(tags_line) == 0) { next }

        # Build set of new-tags from new-tags block
        split("", new_tags_set)
        n = split(new_tags_block, nt_lines, "\n")
        for (i = 1; i <= n; i++) {
          line = nt_lines[i]
          gsub(/^[[:space:]]*-[[:space:]]*/, "", line)
          colon = index(line, ":")
          if (colon > 1) {
            nt_name = substr(line, 1, colon - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", nt_name)
            if (length(nt_name) > 0) {
              new_tags_set[tolower(nt_name)] = 1
            }
          }
        }

        # Check each tag
        # Output uses tab as field separator (file\tlinenum\ttag) so paths containing
        # colons (e.g. CI matrix job paths) parse correctly downstream.
        split(tags_line, tag_tokens, ",")
        for (i = 1; i <= length(tag_tokens); i++) {
          tok = tag_tokens[i]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", tok)
          if (length(tok) == 0) continue
          tok_lower = tolower(tok)
          if (!(tok_lower in known_tags) && !(tok_lower in new_tags_set)) {
            print FILENAME "\t" block_start_line "\t" tok
          }
        }
        next
      }
      in_block && /^example:[[:space:]]*\|/ { in_example = 1; in_new_tags = 0; next }
      in_block && in_example && /^(title|rule|why|example|references|tags|new-tags):/ { in_example = 0 }
      in_block && in_example { next }
      in_block && /^tags:/ {
        tags_line = substr($0, 6)
        gsub(/^[[:space:]]+/, "", tags_line)
        in_new_tags = 0
        next
      }
      in_block && /^new-tags:/ { in_new_tags = 1; next }
      in_block && in_new_tags && /^(title|rule|why|example|references|tags):/ { in_new_tags = 0 }
      in_block && in_new_tags { new_tags_block = new_tags_block $0 "\n"; next }
    ' "$file" 2>/dev/null || true)

    if [ -n "$_r23_violations" ]; then
      while IFS= read -r _r23_hit; do
        [ -z "$_r23_hit" ] && continue
        # Tab-separated: file<TAB>linenum<TAB>tag — safe for paths containing colons
        _r23_file=$(echo "$_r23_hit" | cut -f1)
        _r23_line=$(echo "$_r23_hit" | cut -f2)
        _r23_tag=$(echo "$_r23_hit" | cut -f3)
        print_violation "$_r23_file" "$_r23_line" "MISSING_TAG_JUSTIFICATION" \
          "tag '${_r23_tag}' in convention block is not in tag-index.md and has no new-tags: justification — add it to new-tags: with a one-line reason or add a ## ${_r23_tag} heading to docs/architecture/tag-index.md"
      done <<< "$_r23_violations"
    fi
  done

  rm -f "$_known_tags_file"
fi

# Rule 24: Bare $VAR reference for known optional config variables in lib/utils/*.sh
#
# Config variables in the EMAIL_*, SLACK_*, RITE_EMAIL_*, AWS_*, SNS_*, and
# RITE_SNS_* families are optional (not guaranteed to be set by the caller).
# Under `set -u`, a bare `$VAR` reference (without braces or a default) when the
# variable is unset crashes the script immediately with "VAR: unbound variable"
# before any error handling can run.
#
# Live bug (2026-06-06): notifications.sh send_email() crashed with
# "EMAIL_ADDRESS: unbound variable" — wrong variable name AND bare reference.
# This caused PR #302 to be reported as failed even though the merge had already
# succeeded. See issue #313.
#
# SNS_TOPIC_ARN / RITE_SNS_* added in issue #377: send_sms() uses bare
# $SNS_TOPIC_ARN (a module-local alias for RITE_SNS_TOPIC_ARN). Without this
# rule covering the SNS_* family, future bare references bypass detection entirely.
# The existing suppression in notifications.sh remains valid (module-local alias
# initialized safely at load time via SNS_TOPIC_ARN="${RITE_SNS_TOPIC_ARN:-}").
#
# What this rule flags:
#   FLAGGED: $EMAIL_ADDRESS          (no braces — crashes under set -u when unset)
#   FLAGGED: $RITE_EMAIL_FROM        (no braces)
#   FLAGGED: $SLACK_WEBHOOK          (no braces — even if checked in prior guard,
#                                     the bare form is fragile: future moves break it)
#   FLAGGED: $SNS_TOPIC_ARN          (no braces — same crash class as EMAIL_ADDRESS)
#   FLAGGED: $RITE_SNS_TOPIC_ARN     (no braces)
#   PASSES:  ${EMAIL_NOTIFICATION_ADDRESS:-}   (safe: default to empty)
#   PASSES:  ${RITE_EMAIL_FROM:-}              (safe: default to empty)
#   PASSES:  ${AWS_PROFILE:-default}           (safe: explicit default)
#   PASSES:  ${SNS_TOPIC_ARN:-}               (safe: default to empty)
#   PASSES:  ${RITE_SNS_TOPIC_ARN:-}          (safe: default to empty)
#
# Note: ${VAR} without :- is NOT flagged by this rule. While technically unsafe
# under set -u, ${VAR} is also caught by shellcheck SC2168 (used-before-set).
# This rule focuses on the fully-bare $VAR pattern that is the most common
# source of the crash class described in issue #313.
#
# Scope: lib/utils/*.sh only (config-consuming utility layer).
#
# Suppression: place on the line immediately before the flagged code:
#   # sharkrite-lint disable BARE_VAR_REFERENCE - Reason: variable is always set by <caller>
echo "Checking for bare config-var references (EMAIL_*, SLACK_*, RITE_EMAIL_*, AWS_*, SNS_*, RITE_SNS_*) in lib/utils/*.sh..."

# Build the candidate file list from SHELL_FILES filtered to lib/utils/ paths.
# This reuses the RITE_LINT_EXTRA_DIRS expansion already applied to SHELL_FILES,
# so fixture directories injected via that env var are scanned correctly —
# matching the behavior of all other per-subset rules (e.g. Rule 16 LIB_FILES).
# The filter matches any path ending in /lib/utils/*.sh (both project tree and fixtures).
_r24_utils_files=()
for _f in "${SHELL_FILES[@]}"; do
  if [[ "$_f" == */lib/utils/*.sh ]]; then
    _r24_utils_files+=("$_f")
  fi
done

for file in "${_r24_utils_files[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # We flag ONLY bare $VAR (no braces at all) for the config-var families.
    # Pattern: $VARNAME where VARNAME starts with EMAIL_, SLACK_, RITE_EMAIL_, AWS_,
    # SNS_, or RITE_SNS_ and the $ is NOT followed by { (which would indicate a brace
    # expansion like ${VAR:-}).
    # The negative lookahead is simulated by matching $VAR then filtering out ${...} forms.
    #
    # Technique: strip all ${...} brace expansions from the line, then check if
    # any bare $VAR from the config families remains.
    _stripped_line=$(echo "$line_content" | sed 's/\${[^}]*}//g' || true)
    if ! echo "$_stripped_line" | grep -qE '\$(EMAIL_|SLACK_|RITE_EMAIL_|AWS_|SNS_|RITE_SNS_)[A-Z_]+'; then
      continue
    fi

    # Check for suppression comment on preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || true)
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BARE_VAR_REFERENCE'; then
      continue
    fi

    print_violation "$file" "$line_num" "BARE_VAR_REFERENCE" \
      "bare \$VAR reference for optional config variable — use \${VAR:-} to prevent 'unbound variable' crash under set -u (see: issue #313, notifications.sh EMAIL_ADDRESS bug)"
  done < <(grep -nE '\$(EMAIL_|SLACK_|RITE_EMAIL_|AWS_|SNS_|RITE_SNS_)[A-Z_]+' "$file" 2>/dev/null || true)
done

# Rule 25: Bats files must declare test coverage via sharkrite-test-covers header
#
# After #462 (selection logic) and #480 (full backfill), test-gate.sh treats
# headerless bats files as "no coverage signal" — they're SKIPPED from
# targeted runs. Without this lint rule, a new bats file without a header
# would silently never run from targeted gates, defeating its purpose.
#
# Required format in the first 5 lines of every .bats file:
#   # sharkrite-test-covers: <comma-separated paths or globs>
#
# Examples:
#   # sharkrite-test-covers: lib/core/foo.sh
#   # sharkrite-test-covers: lib/utils/*.sh, lib/core/bar.sh
#   # sharkrite-test-covers: lib/**  (intentionally broad, e.g. smoke tests)
#
# Suppression: place on the line immediately before the bats file's shebang
# (rare — typically used for fixture/scaffolding files that aren't tested by gates):
#   # sharkrite-lint disable MISSING_TEST_COVERAGE_HEADER - Reason: <why>
echo "Checking for missing sharkrite-test-covers headers in .bats files..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  # Allow tests/helpers/ and tests/fixtures/ to skip — they're support files
  case "$bats_file" in
    */tests/helpers/*|*/tests/fixtures/*) continue ;;
  esac
  # Check for header in first 5 lines
  if ! head -5 "$bats_file" 2>/dev/null | grep -qE '^# sharkrite-test-covers:'; then
    print_violation "$bats_file" "1" "MISSING_TEST_COVERAGE_HEADER" \
      "bats file missing 'sharkrite-test-covers:' header — required so test_gate's targeted selection (#462) can decide when to run this test. Add a comment on line 2: '# sharkrite-test-covers: lib/path/to/source.sh' listing the source files this test exercises."
  fi
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

# Rule 26: Non-portable 'sleep infinity' / 'sleep inf' (BSD/macOS /bin/sleep rejects)
#
# GNU coreutils `sleep` accepts the keywords `infinity` and `inf` ("sleep
# forever"), but BSD/macOS /bin/sleep accepts ONLY a numeric duration. Given
# `sleep infinity`, BSD sleep prints `usage: sleep number[unit]` and exits
# immediately (exit 1) — it never sleeps. Any code relying on it to block the
# process forever (mock servers, hang simulators, hold-open patterns) silently
# fails to wait on macOS, producing flaky/wrong behavior with no error trail.
#
# Live fix (this session): tests/helpers/gh-mock.bash + claude-mock.bash used
# `sleep infinity` to simulate a hung subprocess; on macOS they returned
# instantly, defeating the hang. Fixed to a large finite value.
#
# Portable fix: a large finite value that both GNU and BSD accept, e.g.
#   sleep 2147483647   # ~68 years
#
# Same low-FP class as Rule 10 (BARE_BSD_SED_I) / Rule 11 (BARE_BSD_STAT_F):
# a fixed non-portable literal token, not a heuristic.
#
# Suppression: add on the line immediately before the flagged code:
#   # sharkrite-lint disable SLEEP_INFINITY_NOT_PORTABLE - reason: <text>
echo "Checking for non-portable 'sleep infinity' / 'sleep inf' (BSD/macOS rejects)..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments (documentation mentions of the pattern are fine)
    if echo "$line_content" | grep -qE '^[[:space:]]*#'; then
      continue
    fi
    # Check for suppression comment on the preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*SLEEP_INFINITY_NOT_PORTABLE'; then
      continue
    fi
    print_violation "$file" "$line_num" "SLEEP_INFINITY_NOT_PORTABLE" \
      "'sleep infinity'/'sleep inf' is rejected by BSD/macOS /bin/sleep (exits immediately, never sleeps) — use a large finite value like 'sleep 2147483647'"
  done < <(grep -nE '\bsleep[[:space:]]+(-[a-z]+[[:space:]]+)*(inf|infinity)\b' "$file" 2>/dev/null || true)
done

# Rule 27: tr with a multibyte UTF-8 replacement/delete char (byte-oriented tr garbles it)
#
# `tr` maps BYTES, not characters. When a tr SET argument contains a multibyte
# UTF-8 character (e.g. '↵', '→', 'é'), tr replaces matched input with only the
# FIRST BYTE of that character — producing mojibake. ASCII-only SETs are fine.
#
# Live bug (fixed): lib/utils/blocker-rules.sh used `tr '\n' '↵'` to visualize
# newlines in a diag log; tr emitted 0xE2 (the first byte of ↵) instead of the
# full glyph. Fix: bash parameter expansion `${var//$'\n'/↵}` (UTF-8-safe).
#
# Detection is QUOTE-AWARE to stay false-positive-free: for each `tr` command
# word on a line, the parser walks forward ONLY through tr's own quoted SET
# operands (stopping at the next unquoted | ; & or )) and flags a non-ASCII byte
# only when it sits inside one of those quoted SETs. This deliberately does NOT
# flag a multibyte byte that appears in:
#   - a trailing comment           (echo $x | tr '\n' ',' # join ≈ x)
#   - an upstream pipeline stage   (echo "café" | tr '[:upper:]' '[:lower:]')
#   - a downstream pipeline stage  (tr '[:upper:]' '[:lower:]' | sed 's/x/→/')
# all three of which are harmless and would otherwise block legitimate code.
#
# Heredoc-aware (mirrors Rules 7/8/9/13): bodies documenting the bug pattern are
# skipped. Runs under LC_ALL=C so awk treats input as raw bytes (required for
# [\200-\377] byte-range matching). BSD-awk compatible: index()/substr()/match()
# only — no \s, no +, no \b, no compound rules.
#
# Suppression: place on the line immediately before the flagged code:
#   # sharkrite-lint disable TR_MULTIBYTE_REPLACEMENT - Reason: <text>
echo "Checking for tr with a multibyte UTF-8 replacement/delete char..."
_r27_awk=$(mktemp)
printf '%s\n' \
  'function check_tr_args(s,   i, c, q, n, mb) {' \
  '  mb = 0; i = 1; n = length(s)' \
  '  while (i <= n) {' \
  '    c = substr(s, i, 1)' \
  '    if (c == "|" || c == ";" || c == "&" || c == ")") break' \
  '    if (c == "\047" || c == "\042") {' \
  '      q = c; i++' \
  '      while (i <= n) { c = substr(s, i, 1); if (c == q) { i++; break }; if (c ~ /[\200-\377]/) mb = 1; i++ }' \
  '      continue' \
  '    }' \
  '    i++' \
  '  }' \
  '  return mb' \
  '}' \
  'FNR == 1 { in_heredoc = 0; hd_marker = "" }' \
  '{' \
  '  if (in_heredoc) {' \
  '    _close = $0; sub(/^[[:space:]]*/, "", _close)' \
  '    if (_close == hd_marker) in_heredoc = 0' \
  '    next' \
  '  }' \
  '  if (index($0, "<<") > 0) {' \
  '    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)' \
  '    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")' \
  '    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }' \
  '  }' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  if ($0 !~ /(^|[ \t|(;&])tr[ \t]/) next' \
  '  rest = $0; found = 0' \
  '  while (match(rest, /(^|[ \t|(;&])tr[ \t]/)) {' \
  '    after = substr(rest, RSTART + RLENGTH)' \
  '    if (check_tr_args(after)) { found = 1; break }' \
  '    rest = after' \
  '  }' \
  '  if (found) print FILENAME "\t" FNR' \
  '}' \
  > "$_r27_awk"

# LC_ALL=C: treat bytes literally so [\200-\377] reliably matches UTF-8 lead/
# continuation bytes regardless of the ambient locale.
_r26_hits=$(LC_ALL=C awk -f "$_r27_awk" "${SHELL_FILES[@]}" </dev/null 2>/dev/null || true)
rm -f "$_r27_awk"
_r27_awk=""

if [ -n "$_r26_hits" ]; then
  while IFS= read -r _hit; do
    # Tab-separated: file<TAB>linenum — safe for paths containing colons
    _hit_file=$(echo "$_hit" | cut -f1)
    _hit_line=$(echo "$_hit" | cut -f2)
    # Suppression: comment on the immediately preceding line
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$_hit_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*TR_MULTIBYTE_REPLACEMENT'; then
      continue
    fi
    print_violation "$_hit_file" "$_hit_line" "TR_MULTIBYTE_REPLACEMENT" \
      "tr maps bytes, not UTF-8 chars — a multibyte replacement/delete char emits only its first byte (garbage); use bash parameter expansion \${var//search/replace} instead"
  done <<< "$_r26_hits"
fi


# Rule 28: BSD `date -jf` parsing a Z/UTC timestamp to epoch WITHOUT `-u`
#
# BSD date (macOS) needs `-u` to interpret the input as UTC. When the input
# format ends in a literal `Z` (the ISO-8601 UTC zone marker) but `-u` is
# missing, BSD date parses the timestamp in the machine's LOCAL timezone and
# the resulting epoch is skewed by the local UTC offset (e.g. -6h in MT).
# The trailing `Z` is treated as a literal, not as "this is UTC".
#
# Live fix (wave 1, this session): lib/utils/date-helpers.sh:35 iso_to_epoch()
# was missing `-u` on its BSD branch. Correct form: `date -u -jf ... +%s`.
# epoch_to_iso() already used `-u`; this keeps the round-trip pair symmetric.
#
# Detection (per `date` invocation segment, split on | ; & so a sibling command
# in a `||` chain cannot mask or falsely trigger this one):
#   FLAGGED when the segment has an -f flag char (input format) AND a -j flag
#   char (BSD no-set parse mode) in ANY clustering/order, a quoted format string
#   containing a literal uppercase `Z`, and `+%s` (epoch) output, and NO -u flag.
#
# Intentionally NOT flagged:
#   - any segment containing `-u` (correct UTC parse) — e.g. -u -jf / -juf / -ujf
#   - `%z` numeric-offset formats (lowercase z; the offset is parsed explicitly)
#   - date-only / no-Z formats (no time-of-day → no local-offset skew possible)
#   - non-epoch output (`+%b ...` display conversions, e.g. deliberate UTC->local)
#
# Suppression: add on the line immediately before the flagged code:
#   # sharkrite-lint disable BSD_DATE_PARSE_Z_WITHOUT_U - Reason: <text>
echo "Checking for BSD 'date -jf' parsing a Z/UTC timestamp to epoch without -u..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Check for suppression comment on the preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BSD_DATE_PARSE_Z_WITHOUT_U'; then
      continue
    fi
    # Examine each `date ...` invocation segment independently (terminated at
    # | ; & or EOL) so a -u on a sibling command in a || chain cannot mask a
    # bad invocation, and a good sibling cannot be flagged by a bad one.
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      # (a) an -f flag char (input format) somewhere in a dash-flag cluster
      echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)' || continue
      # (b) a -j flag char (BSD no-set parse mode) somewhere in a dash-flag cluster
      echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*j[a-zA-Z]*([[:space:]]|$)' || continue
      # (c) a quoted format string containing a literal uppercase Z (UTC marker)
      echo "$seg" | grep -qE '"[^"]*Z[^"]*"|'"'"'[^'"'"']*Z[^'"'"']*'"'" || continue
      # (d) epoch output
      echo "$seg" | grep -qE '\+%s' || continue
      # Safe iff a flag cluster contains -u (interpret input as UTC)
      if echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*u[a-zA-Z]*([[:space:]]|$)'; then
        continue
      fi
      print_violation "$file" "$line_num" "BSD_DATE_PARSE_Z_WITHOUT_U" \
        "BSD 'date -jf' parsing a Z/UTC timestamp to epoch without -u parses in local time, skewing the epoch by the local offset — use 'date -u -jf ...'"
    done < <(echo "$line_content" | grep -oE 'date[^|;&]*' || true)
  done < <(grep -nE 'date[^|;&]*-[a-zA-Z]*j' "$file" 2>/dev/null || true)
done

# Rule 29: trap ... EXIT inside a @test body in a .bats file
#
# bats-core emits each test's result ('ok'/'not ok') from its OWN EXIT trap in
# bats-exec-test. A `trap ... EXIT` (or `trap - EXIT`) inside a @test body
# CLOBBERS that trap: the test's result is never written to the TAP stream,
# bats reports "Executed N instead of expected M tests", and the report.tap
# has no 'not ok' line for the gate to count — the failure is invisible
# (test_count=0 despite exit 1; four blind fix rounds in the 2026-07-01
# not-run incident, tests/regression/batch-locked-issue-in-progress-status.bats:506).
# Cleanup belongs in teardown() — bats runs it for every test, pass or fail.
#
# Heredoc-aware (mirrors Rules 27/28's state tracking): trap lines inside
# heredoc fixture scripts written BY a test are content, not test-shell code.
#
# Suppression: place on the line immediately before the flagged code:
#   # sharkrite-lint disable TRAP_EXIT_IN_BATS_TEST - Reason: <text>
echo "Checking for trap ... EXIT inside @test bodies in .bats files..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r29_file_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; in_test = 0 }
    {
      if (in_heredoc) {
        _close = $0; sub(/^[[:space:]]*/, "", _close)
        if (_close == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      # Heredoc-start detection runs for EVERY non-comment line (not just inside
      # @test bodies): a fixture heredoc at setup/file scope containing literal
      # @test + trap lines must not fool the state machine.
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      if (!in_test) {
        if ($0 ~ /^[[:space:]]*@test[[:space:]]/) {
          # one-liner @test "..." { ...; } never re-opens on the next line
          if ($0 ~ /\{/ && $0 ~ /\}[[:space:]]*$/) next
          in_test = 1
        }
        next
      }
      if ($0 ~ /^}[[:space:]]*$/) { in_test = 0; next }
      if ($0 ~ /^[[:space:]]*trap[[:space:]]/ && $0 ~ /(^|[^A-Za-z_])EXIT([^A-Za-z_]|$)/) print FNR
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r29_file_hits" ] && continue
  while IFS= read -r _hit_line; do
    [ -z "$_hit_line" ] && continue
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*TRAP_EXIT_IN_BATS_TEST'; then
      continue
    fi
    print_violation "$bats_file" "$_hit_line" "TRAP_EXIT_IN_BATS_TEST" \
      "trap ... EXIT inside a @test body clobbers bats' result-emitting EXIT trap — the test's result is silently dropped ('Executed N instead of expected M'); move cleanup into teardown()"
  done <<< "$_r29_file_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

# Rule 30: bats setup()/setup_file() sources a lib file without restoring bats' shell flags
#
# Every lib file (directly or transitively via config.sh/logging.sh) runs
# `set -euo pipefail` at source time, and `source` executes in the CALLER's
# shell — so a setup() that sources a lib file leaks -u and pipefail into the
# bats-exec-test shell for the whole test. bats' native test-time flags are
# ehBET (errexit ON, nounset off, pipefail off). With BATS_TEST_TIMEOUT set
# (exported by test-gate.sh), the leaked flags make bats' timeout-countdown
# cleanup (bats-exec-test:263 `kill` without || true) abort bats-exec-test
# before the 'not ok' line is emitted: a FAILING test is swallowed to
# "not run" and the gate sees exit 1 with zero findings (2026-07-01 incident).
#
# Required guard after the last lib source in the function body:
#   set +u; set +o pipefail  # bats needs its own error handling ...
#
# Do NOT use `set +e` — bats' failure detection relies on errexit; with it
# disabled a failing test reports 'ok' (verified live, worse than the swallow).
#
# Heredoc-aware: source lines inside fixture heredocs are content, not setup
# code. Sources via tests/helpers (load_lib) are out of scope — flag only
# direct lib sources (paths through lib/ or $RITE_LIB_DIR).
#
# Suppression: place on the line immediately before the flagged source line:
#   # sharkrite-lint disable BATS_SETUP_STRICT_LEAK - Reason: <text>
echo "Checking for bats setup() sourcing lib files without a strict-mode guard..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r30_file_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; in_setup = 0; pend = 0; pline = 0 }
    {
      if (in_heredoc) {
        _close = $0; sub(/^[[:space:]]*/, "", _close)
        if (_close == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      # Heredoc-start detection runs for EVERY non-comment line (not just inside
      # setup bodies): a fixture heredoc containing literal setup() + source
      # lines must not fool the state machine.
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      if (!in_setup) {
        if ($0 ~ /^(setup|setup_file|setup_suite)[[:space:]]*\(\)/) { in_setup = 1; pend = 0 }
        else next
      }
      if ($0 ~ /^}[[:space:]]*$/) {
        if (pend) print pline
        in_setup = 0; pend = 0
        next
      }
      # guard seen: set +u / set +o nounset clears any pending source.
      # Deliberately EXCLUDES any form containing +e (set +eu, set +e):
      # disabling errexit in setup() breaks bats failure detection itself
      # (a failing test reports ok) — a strictly worse swallow than the one
      # this rule prevents. Verified empirically 2026-07-02.
      if ($0 ~ /set[[:space:]]+\+[a-df-z]*u[a-df-z]*([[:space:];]|$)/ || $0 ~ /set[[:space:]]+\+o[[:space:]]+nounset/) { pend = 0 }
      if ($0 ~ /(^|[^A-Za-z0-9_.])(source|\.)[ \t]+/ &&
          $0 ~ /(lib|LIB_DIR[}"'"'"']*)\/(core|utils|providers|hooks)\/|config\.sh/) {
        pend = 1; pline = FNR
      }
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r30_file_hits" ] && continue
  while IFS= read -r _hit_line; do
    [ -z "$_hit_line" ] && continue
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BATS_SETUP_STRICT_LEAK'; then
      continue
    fi
    print_violation "$bats_file" "$_hit_line" "BATS_SETUP_STRICT_LEAK" \
      "setup() sources a lib file, leaking set -u/pipefail into the bats test shell — with BATS_TEST_TIMEOUT this swallows failing tests to 'not run'; add \`set +u; set +o pipefail\` after the source (keep -e: bats' failure detection needs it)"
  done <<< "$_r30_file_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

# Rule 33: Unguarded array expansion in #!/bin/bash scripts (bash 3.2 set -u crash)
# (Rule numbers 31/32 are reserved by the in-flight provider-model-role branch.)
#
# On macOS system bash 3.2, expanding an EMPTY array via "${arr[@]}" under
# set -u crashes with "arr[@]: unbound variable". Live class: #266, #327, and
# the 2026-07-04 audit (`rite plan "<instructions>"` and `rite --status
# --by-label` both crashed). Canonical fix is the +idiom:
#   "${arr[@]+"${arr[@]}"}"
# or a ${#arr[@]} count-guard near the expansion.
#
# Heuristics (deliberately simple; suppress residual FPs inline):
#   - only #!/bin/bash files (env-bash files run under homebrew bash 4+)
#   - a line carrying the idiom marker `[@]+` is safe (the idiom's own inner
#     expansion would otherwise self-flag)
#   - an expansion is safe if a ${#name[@]} reference OR a non-empty literal
#     init `name=(x ...)` appears on the same line or within the previous 10
#     code lines (`name+=(...)` deliberately does NOT count — conditional
#     appends leave the array empty on the zero-iteration path)
#   - always-set bash specials excluded (BASH_SOURCE, FUNCNAME, PIPESTATUS, ...)
#   - heredoc bodies skipped (generated-child content is not this file's shell)
#
# Suppress: # sharkrite-lint disable EMPTY_ARRAY_EXPANSION_BASH32 - Reason: <text>
echo "Checking for unguarded empty-array expansions in #!/bin/bash scripts (bash 3.2)..."
for file in "${SHELL_FILES[@]}"; do
  head -1 "$file" 2>/dev/null | grep -q '^#!/bin/bash' || continue
  _r33_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; ml_name = "" }
    {
      if (in_heredoc) {
        _c = $0; sub(/^[[:space:]]*/, "", _c)
        if (_c == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      line = $0
      # Record count-guards: ${#name[@]} anywhere on the line.
      tmp = line
      while (match(tmp, /\$\{#[A-Za-z_][A-Za-z0-9_]*\[@\]\}/)) {
        g = substr(tmp, RSTART + 3, RLENGTH - 7)
        guard[g] = FNR
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      # Record non-empty literal inits: name=(x ...). `+=` never matches this
      # regex (the + is outside [A-Za-z0-9_]), which is deliberate.
      tmp = line
      while (match(tmp, /[A-Za-z_][A-Za-z0-9_]*=\([^)[:space:]]/)) {
        seg = substr(tmp, RSTART, RLENGTH)
        split(seg, _q, /=\(/)
        guard[_q[1]] = FNR
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      # Multi-line literal init: `name=(` at end of line opens a static list
      # (REQUIRED_DIRS=( ... ) style). Nobody writes an EMPTY multi-line
      # literal, so treat it as a non-empty init — and keep the guard anchored
      # to the closing paren of the list by bumping it on every interior line,
      # so the 10-line window starts where the list ends, not where it opens.
      if (ml_name != "") {
        guard[ml_name] = FNR
        if (line ~ /^[[:space:]]*\)[[:space:];]*$/) ml_name = ""
      }
      if (match(line, /[A-Za-z_][A-Za-z0-9_]*=\([[:space:]]*$/)) {
        seg = substr(line, RSTART, RLENGTH)
        split(seg, _q2, /=\(/)
        guard[_q2[1]] = FNR
        ml_name = _q2[1]
      }
      # Lines already using the +idiom are safe as a whole.
      if (index(line, "[@]+") > 0) next
      # Flag plain expansions "${name[@]}" lacking a recent guard.
      tmp = line
      while (match(tmp, /"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"/)) {
        name = substr(tmp, RSTART + 3, RLENGTH - 8)
        tmp = substr(tmp, RSTART + RLENGTH)
        if (name == "BASH_SOURCE" || name == "FUNCNAME" || name == "PIPESTATUS" || \
            name == "BASH_REMATCH" || name == "COMP_WORDS" || name == "BASH_ARGV" || \
            name == "DIRSTACK") continue
        if ((name in guard) && FNR - guard[name] <= 10) continue
        print FNR "\t" name
      }
    }
  ' "$file" </dev/null 2>/dev/null || true)
  [ -z "$_r33_hits" ] && continue
  while IFS=$'\t' read -r _r33_line _r33_name; do
    [ -z "$_r33_line" ] && continue
    _r33_prev=$(sed -n "$((_r33_line - 1))p" "$file" 2>/dev/null || true)
    if echo "$_r33_prev" | grep -q 'sharkrite-lint disable EMPTY_ARRAY_EXPANSION_BASH32'; then
      continue
    fi
    print_violation "$file" "$_r33_line" "EMPTY_ARRAY_EXPANSION_BASH32" \
      "\"\${${_r33_name}[@]}\" without +idiom or nearby \${#${_r33_name}[@]} guard crashes bash 3.2 under set -u when the array is empty — use \"\${${_r33_name}[@]+\"\${${_r33_name}[@]}\"}\""
  done <<< "$_r33_hits"
done

# Rule 34: Pre-source stub overwritten by env-guarded lib (BATS_STUB_OVERWRITE)
#
# Env-guarded libs (those using _RITE_*_LOADED variable guards instead of
# function-sentinel guards) define their real functions unconditionally at
# source time, OVERWRITING any same-named stub defined before the source.
# The canonical example: gh-retry.sh uses _RITE_GH_RETRY_LOADED and defines
# gh_safe() every time it's sourced — so a pre-source `gh_safe() { ... }` stub
# in a bats setup() or harness script is silently replaced by the real gh_safe,
# which then queries live GitHub. This hit production for two days (PR #840).
#
# The practical proxy: a .bats file (at bats shell level, not in a heredoc)
# defines a stub for a known env-guarded function (gh_safe is the canonical
# case) before a source of a lib that transitively loads the env-guarded file,
# and no re-stub appears after the last source.
#
# Known env-guarded functions (env-var guard, not function-sentinel):
#   gh_safe — defined by lib/utils/gh-retry.sh (_RITE_GH_RETRY_LOADED)
#
# Transitive loaders that pull in gh-retry.sh:
#   workflow-runner.sh, batch-process-issues.sh, claude-workflow.sh,
#   assess-and-resolve.sh, create-pr.sh, merge-pr.sh, local-review.sh
#
# Detection strategy (AWK state machine, heredoc-aware):
#   1. Track when we enter/exit a heredoc — lines inside are fixture content.
#   2. At bats shell level, note the line number of the FIRST stub definition
#      for each known function (pre_line[name]).
#   3. Note the line number of the LAST source of a transitive loader
#      (last_source_line).
#   4. Note the line number of the LAST stub re-definition for each name
#      (post_line[name]).
#   5. At END: if pre_line[name] > 0 AND last_source_line > 0 AND
#      pre_line[name] < last_source_line AND post_line[name] <= last_source_line
#      → violation (stub was set before the source, never re-set after).
#
# Suppression: place on the line immediately before the flagged definition:
#   # sharkrite-lint disable BATS_STUB_OVERWRITE - Reason: <text>
echo "Checking for pre-source stubs overwritten by env-guarded libs in .bats files..."

# Build the bats file list for Rules 34/35.
# When RITE_LINT_FILES is set (post-commit targeted gate), restrict to the
# intersection of all .bats files and the targeted changed-file set.
# When unset (plain `make lint`), scan all .bats files as before.
_bats_all_tmp=$(mktemp)
find tests -name '*.bats' -type f 2>/dev/null > "$_bats_all_tmp" || true
if [ -n "${RITE_LINT_FILES:-}" ]; then
  _bats_lint_files=$(mktemp)
  _normalize_lint_files | grep '\.bats$' > "$_bats_lint_files" 2>/dev/null || true
  _bats_scan_list=$(grep -Fxf "$_bats_lint_files" "$_bats_all_tmp" 2>/dev/null || true)
  rm -f "$_bats_lint_files"
else
  _bats_scan_list=$(cat "$_bats_all_tmp" 2>/dev/null || true)
fi
rm -f "$_bats_all_tmp"

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r34_file_hits=$(awk '
    FNR == 1 {
      in_heredoc = 0; hd_marker = ""
      # Track: first pre-source stub line and last post-source stub line per function
      delete pre_line; delete post_line
      last_source_line = 0
      suppress_next = 0
    }
    {
      # Heredoc close
      if (in_heredoc) {
        _close = $0; sub(/^[[:space:]]*/, "", _close)
        if (_close == hd_marker) in_heredoc = 0
        next
      }
      # Suppression comment: flag the next non-comment line
      if ($0 ~ /sharkrite-lint[[:space:]]+disable[[:space:]]+BATS_STUB_OVERWRITE/) {
        suppress_next = 1
        next
      }
      # Skip other comments (but process suppression above first)
      if ($0 ~ /^[[:space:]]*#/) next
      # Heredoc open detection (runs on every non-comment, non-heredoc-body line)
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
          hd_marker = _p[1]; in_heredoc = 1
        }
      }
      # Detect source of a known transitive loader of gh-retry.sh.
      # Matches: source .../workflow-runner.sh, .../batch-process-issues.sh,
      #   .../claude-workflow.sh, .../assess-and-resolve.sh, .../create-pr.sh,
      #   .../merge-pr.sh, .../local-review.sh, .../gh-retry.sh directly.
      # Exception: RITE_SOURCE_FUNCTIONS_ONLY=1 sources never execute the loader
      # body (the env-guarded lib guard skips all definitions), so gh_safe is
      # never overwritten — do NOT update last_source_line for these.
      if ($0 ~ /(source|\.)[[:space:]]/ &&
          ($0 ~ /workflow-runner\.sh/ || $0 ~ /batch-process-issues\.sh/ ||
           $0 ~ /claude-workflow\.sh/ || $0 ~ /assess-and-resolve\.sh/ ||
           $0 ~ /create-pr\.sh/ || $0 ~ /merge-pr\.sh/ ||
           $0 ~ /local-review\.sh/ || $0 ~ /gh-retry\.sh/)) {
        if ($0 ~ /RITE_SOURCE_FUNCTIONS_ONLY=1/) next
        last_source_line = FNR
        next
      }
      # Detect stub/re-stub definition for known env-guarded functions.
      # Pattern: `gh_safe() {` or `gh_safe () {` at any indentation.
      # Known env-guarded functions (env-var guard, not function-sentinel):
      #   gh_safe (from gh-retry.sh / _RITE_GH_RETRY_LOADED)
      if ($0 ~ /^[[:space:]]*(gh_safe)[[:space:]]*\(\)[[:space:]]*\{/) {
        name = "gh_safe"
        if (suppress_next) { suppress_next = 0; next }
        if (last_source_line == 0) {
          # Before any source — record as potential pre-source stub
          if (!(name in pre_line)) pre_line[name] = FNR
        } else {
          # After a source — record as post-source re-stub (update to latest)
          post_line[name] = FNR
        }
        next
      }
      suppress_next = 0
    }
    END {
      for (name in pre_line) {
        if (last_source_line > 0 && pre_line[name] < last_source_line) {
          # Stub was defined before the source; check if re-stubbed after
          if (!(name in post_line) || post_line[name] <= last_source_line) {
            print pre_line[name] "\t" name
          }
        }
      }
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r34_file_hits" ] && continue
  while IFS=$'\t' read -r _hit_line _hit_name; do
    [ -z "$_hit_line" ] && continue
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BATS_STUB_OVERWRITE'; then
      continue
    fi
    print_violation "$bats_file" "$_hit_line" "BATS_STUB_OVERWRITE" \
      "${_hit_name}() stub defined before sourcing an env-guarded lib — the real ${_hit_name} will overwrite it; re-stub ${_hit_name}() after the last source (see PR #840 incident)"
  done <<< "$_r34_file_hits"
done <<< "$_bats_scan_list"

# Rule 35: File-scope assignment reading inherited RITE_* env vars in .bats files
#          (BATS_FILE_SCOPE_ENV_READ)
#
# bats loads each .bats file exactly once and executes file-scope code at parse
# time (before any setup/test). A file-scope assignment that reads an inherited
# env var (like `WORKFLOW_FILE="$RITE_LIB_DIR/..."`) is evaluated at load time,
# when the env var may be unset or stale from a previous test run. The correct
# pattern is to set these in setup() where bats has fully initialized the env.
#
# The `_WORKFLOW_FILE` landmine on the #804 branch was exactly this: a file-scope
# `_WORKFLOW_FILE="..."` that referenced `$RITE_LIB_DIR` before setup() ran,
# producing a path built from the wrong (or unset) RITE_LIB_DIR — RCA fix
# direction (3)(b).
#
# Detection strategy (AWK state machine, heredoc-aware):
#   Track function/test depth. At depth 0 (file scope), flag any assignment
#   whose RHS references `$RITE_` or `${RITE_`.
#   BATS_* vars are exempt (bats-provided at parse time, always correct).
#   Assignments that use only literal values or $BATS_*/$(…) are exempt.
#
# False-positive guards:
#   - Lines inside heredocs are content, not bats shell code.
#   - REPO_ROOT=$(cd "$(dirname "$BATS_TEST_FILENAME")/...") is the standard
#     bats-safe file-scope pattern (uses BATS_TEST_FILENAME, not RITE_*).
#   - Suppression comment for the rare legitimate file-scope RITE_* read.
#
# Suppression: place on the line immediately before the flagged line:
#   # sharkrite-lint disable BATS_FILE_SCOPE_ENV_READ - Reason: <text>
echo "Checking for file-scope RITE_* env var reads in .bats files..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r35_file_hits=$(awk '
    FNR == 1 {
      in_heredoc = 0; hd_marker = ""; depth = 0; suppress_next = 0
      in_sq_string = 0
    }
    {
      # Heredoc close
      if (in_heredoc) {
        _close = $0; sub(/^[[:space:]]*/, "", _close)
        if (_close == hd_marker) in_heredoc = 0
        next
      }
      # Multi-line single-quoted string body: content is data, not shell code.
      # Count single-quotes on the line; odd total means the string closes here.
      # Use \047 (octal for single-quote) in AWK string literals to avoid
      # shell quoting conflicts inside the outer awk single-quoted argument.
      if (in_sq_string) {
        _sq_tmp = $0; _sq_count = gsub(/\047/, "\047", _sq_tmp)
        if (_sq_count % 2 == 1) in_sq_string = 0
        next
      }
      # Suppression comment
      if ($0 ~ /sharkrite-lint[[:space:]]+disable[[:space:]]+BATS_FILE_SCOPE_ENV_READ/) {
        suppress_next = 1
        next
      }
      # Skip other comments
      if ($0 ~ /^[[:space:]]*#/) next
      # Heredoc open (intentional fall-through: opener line is shell code)
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) {
          hd_marker = _p[1]; in_heredoc = 1
        }
      }
      # Detect start of a multi-line single-quoted string assignment.
      # Pattern: VAR=<squote> where the opening single-quote is not closed on
      # the same line — the string body continues on subsequent lines.
      # Only fires at file scope (depth==0) to avoid function-body false
      # positive suppression. Content inside the string is data, not shell code.
      if (depth == 0 && $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\047/) {
        # Count single-quotes after the = to determine open vs closed.
        _rest = $0; sub(/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/, "", _rest)
        _sq_tmp = _rest; _sq_count = gsub(/\047/, "\047", _sq_tmp)
        # Odd count means the string is still open after this line.
        if (_sq_count % 2 == 1) { in_sq_string = 1; next }
      }
      # Track brace depth to detect file-scope vs inside-function/test scope.
      # Strip string literals to avoid braces inside strings skewing depth.
      _stripped = $0
      gsub(/'"'"'[^'"'"']*'"'"'/, "", _stripped)
      gsub(/"[^"]*"/, "", _stripped)
      gsub(/\$\{[^}]*\}/, "", _stripped)
      _tmp = _stripped; _ob = gsub(/{/, "", _tmp)
      _tmp = _stripped; _cb = gsub(/}/, "", _tmp)
      depth += _ob - _cb
      if (depth < 0) depth = 0
      # Only check file-scope lines (depth == 0 means we are not inside a
      # function/test body at the END of this line; we need to check the
      # assignment BEFORE updating depth, so use depth AFTER update but
      # check lines where effective depth is 0).
      # A function opener `foo() {` changes depth from 0 to 1 on the same
      # line — assignment check only applies when we are NOT just entering
      # a new scope. Treat depth == 0 after open-brace accounting as
      # file-scope (the body of the function is depth >= 1 on subsequent lines).
      if (depth > 0) { suppress_next = 0; next }
      # At file scope: flag VAR=... lines whose RHS references $RITE_ or ${RITE_
      # (but not $BATS_* which is bats-provided and always safe at file scope).
      if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ &&
          ($0 ~ /\$RITE_[A-Za-z0-9_]/ || $0 ~ /\$\{RITE_[A-Za-z0-9_]/)) {
        if (suppress_next) { suppress_next = 0; next }
        print FNR
        next
      }
      suppress_next = 0
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r35_file_hits" ] && continue
  while IFS= read -r _hit_line; do
    [ -z "$_hit_line" ] && continue
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BATS_FILE_SCOPE_ENV_READ'; then
      continue
    fi
    print_violation "$bats_file" "$_hit_line" "BATS_FILE_SCOPE_ENV_READ" \
      "file-scope assignment reads \$RITE_* env var — evaluated at bats load time before setup() runs; move into setup() or use \${RITE_VAR:-default} inside a function"
  done <<< "$_r35_file_hits"
done <<< "$_bats_scan_list"

echo ""
echo "----------------------------------------"
if [ "$VIOLATIONS" -eq 0 ]; then
  echo -e "${GREEN}✓${NC} All custom lint checks passed!"
  exit 0
else
  echo -e "${RED}✗${NC} Found $VIOLATIONS violation(s)"
  exit 1
fi
