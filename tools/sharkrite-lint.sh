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
_r34_awk=""
_cleanup_awk_tmpfiles() {
  [ -n "$_r8_awk"  ] && rm -f "$_r8_awk"
  [ -n "$_r13_awk" ] && rm -f "$_r13_awk"
  [ -n "$_r27_awk" ] && rm -f "$_r27_awk"
  [ -n "$_r34_awk" ] && rm -f "$_r34_awk"
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
  -type f ! -name 'sharkrite-lint.sh' ! -path "*/lint-rules/*" \
  ! -path "*/test-fixtures-temp*/*" ! -path "*/test-fixtures-temp*" \
  \( -name "*.sh" -o -path "$PROJECT_ROOT/bin/rite*" -o -path "$PROJECT_ROOT/tools/git-hooks/*" \) 2>/dev/null)
# ^^^ ! -name 'sharkrite-lint.sh': exclude self — contains # sharkrite-extract: marker patterns
# in comments and awk strings; scanning it could cause Rule 18 (UNBALANCED_EXTRACT_MARKERS)
# to fire spuriously if a concretely-named example marker were ever added to this file.
# ^^^ ! -path "*/lint-rules/*": same self-exemption for the per-rule fragments (#919) —
# every rule body is pattern-fixture-laden, exactly why the monolith excluded itself.

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
# files, fixtures, the lint script's self-exclusion) are silently dropped from the
# shell-file scan — the intersection is by design. Empty shell-file intersection
# → exit 0 with a notice (e.g. docs-only commit), UNLESS some entries are .bats
# files — in that case execution falls through to the rule loop so Rules 34/35
# (which use their own `find tests` scan) can run against the changed bats files.
# Direct `make lint` (no env var) keeps full-scan behavior unchanged.
if [ -n "${RITE_LINT_FILES:-}" ]; then
  _lint_targeted_tmp=$(mktemp)
  printf '%s\n' "${SHELL_FILES[@]}" > "$_lint_targeted_tmp"
  mapfile -t SHELL_FILES < <(printf '%s\n' "$RITE_LINT_FILES" | grep -Fxf "$_lint_targeted_tmp" 2>/dev/null || true)
  rm -f "$_lint_targeted_tmp"
  if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
    # No shell files (bin/lib/tools) in the targeted set. Before exiting,
    # check whether any changed files are .bats files — if so, Rules 34/35
    # (BATS_PRE_SOURCE_STUB_OVERWRITE and BATS_FILE_SCOPE_ENV_READ) must still
    # run, because they scan tests/*.bats independently of SHELL_FILES.
    # Letting execution fall through to the rule loop is safe: SHELL_FILES is
    # empty so all SHELL_FILES-iterating rules are no-ops; only rules with
    # their own find loop (Rules 34/35) do real work.
    if printf '%s\n' "$RITE_LINT_FILES" | grep -qE '\.bats$'; then
      echo "Sharkrite custom lint: targeted scope (bats-only — running Rules 34/35)"
    else
      echo "Sharkrite custom lint: no in-scope shell files in targeted set — skipping."
      exit 0
    fi
  else
    echo "Sharkrite custom lint: targeted scope (${#SHELL_FILES[@]} file(s))"
  fi
fi

# ---------------------------------------------------------------------------
# Rule execution — each rule lives in tools/lint-rules/NN-slug.sh and is
# sourced here IN SORTED ORDER, sharing this shell (SHELL_FILES, VIOLATIONS,
# print_violation, colors). Adding a rule = dropping in a new NN-slug.sh —
# no driver edit (#919: a one-rule change stops selecting every lint test).
# Keep rule messages/names unchanged on extraction; NN prefix = canonical
# rule number from the old monolith.
# ---------------------------------------------------------------------------
_LINT_RULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lint-rules"
if [ ! -d "$_LINT_RULES_DIR" ]; then
  echo "ERROR: rule directory not found: $_LINT_RULES_DIR" >&2
  exit 1
fi

# Fragment-number uniqueness guard (#1023): the loop below sources
# lint-rules/*.sh in sort order — nothing dedups the NN- prefix, so two
# fragments sharing a number BOTH load silently (their helper/awk-tmp vars can
# clobber each other, and a duplicate RULE_NAME makes suppression ambiguous).
# This is not hypothetical: #1029's rule 36 and a new covers rule collided.
# Fail loudly here so a duplicate number can never ship unnoticed — a branch
# that adds a colliding fragment goes red on its own `make lint`/gate.
_lint_dup_nums=$(ls "$_LINT_RULES_DIR"/*.sh 2>/dev/null \
  | sed -E 's#.*/([0-9]+)-.*#\1#' | sort | uniq -d)
if [ -n "$_lint_dup_nums" ]; then
  echo "ERROR: duplicate lint-rule fragment number(s): $(echo $_lint_dup_nums)" >&2
  echo "       Each tools/lint-rules/NN-*.sh must use a unique NN prefix. Offenders:" >&2
  for _n in $_lint_dup_nums; do
    ls "$_LINT_RULES_DIR/${_n}-"*.sh 2>/dev/null | sed 's#^#         #' >&2
  done
  exit 1
fi

# SHARKRITE_LINT_ONLY (test-only fast path): comma-separated rule NUMBERS (the
# NN- filename prefix, e.g. "15" or "34,35"). When set, only the named rule
# fragments are sourced — a rule's own regression test then runs JUST its rule
# instead of all 36. This cuts a full-codebase custom-lint pass from ~70s to
# ~2s. It matters because the lint-rule bats tests each shell out to the full
# linter (some 3-17x per file) and NONE are serial-marked: under the gate's
# `bats --jobs 8`, ~8 concurrent full-lint scans starve the CPU, each blows the
# 120s BATS_TEST_TIMEOUT, and the gate drags to its 1800s watchdog (live: the
# 2026-07-18 batch ran 15-42min gates on this alone). Unset = all rules, so the
# production/gate lint path is unchanged.
if [ -n "${SHARKRITE_LINT_ONLY:-}" ]; then
  # Membership string: ",15,34," so a case-glob can test exact number match.
  _lint_only_set=",${SHARKRITE_LINT_ONLY//[[:space:]]/},"
  # Fail loudly if a requested number has no fragment. Otherwise a stale/typo'd
  # number would source ZERO rules, the driver would exit 0, and a test that
  # asserts "no violation" would pass spuriously (silent coverage loss).
  _lint_only_check="${SHARKRITE_LINT_ONLY//[[:space:]]/}"
  while [ -n "$_lint_only_check" ]; do
    _lint_only_n="${_lint_only_check%%,*}"
    if [ "$_lint_only_check" = "$_lint_only_n" ]; then
      _lint_only_check=""
    else
      _lint_only_check="${_lint_only_check#*,}"
    fi
    [ -z "$_lint_only_n" ] && continue
    if ! ls "$_LINT_RULES_DIR/${_lint_only_n}-"*.sh >/dev/null 2>&1; then
      echo "ERROR: SHARKRITE_LINT_ONLY names rule '$_lint_only_n' but no tools/lint-rules/${_lint_only_n}-*.sh exists" >&2
      exit 1
    fi
  done
fi

for _rule_file in "$_LINT_RULES_DIR"/*.sh; do
  [ -f "$_rule_file" ] || continue
  if [ -n "${_lint_only_set:-}" ]; then
    # Extract the NN- prefix and skip fragments not in the requested set.
    _rule_num=$(basename "$_rule_file" | sed -E 's/^([0-9]+)-.*/\1/')
    case "$_lint_only_set" in
      *",${_rule_num},"*) ;;   # requested — source it
      *) continue ;;           # not requested — skip
    esac
  fi
  # shellcheck source=/dev/null
  source "$_rule_file"
done

echo ""
echo "----------------------------------------"
if [ "$VIOLATIONS" -eq 0 ]; then
  echo -e "${GREEN}✓${NC} All custom lint checks passed!"
  exit 0
else
  echo -e "${RED}✗${NC} Found $VIOLATIONS violation(s)"
  exit 1
fi
