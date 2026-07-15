# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 36: UNDOCUMENTED_RITE_VAR — any RITE_* variable read in lib/ must
# appear in the documented set: the UNION of config/project.conf.example
# and config/rite.conf.example. Pre-existing undocumented vars are exempted
# via tools/lint-rules/36-undocumented-rite-var.ledger (one-time seed,
# count frozen 2026-07-14 — DO NOT add new entries; see ledger header).
#
# Rationale: makes config documentation-by-construction — new RITE_* vars
# introduced without a config-example entry are flagged immediately in CI
# rather than caught (or missed) during code review.
#
# Scope: lib/ files only. bin/ and tools/ are excluded — lib/ is the
# config-consuming layer; bin/ scripts and tools have different conventions.
#
# Detection: reads only — per-line grep for ${RITE_VAR} or $RITE_VAR.
# Deliberately excludes:
#   _RITE_*  — re-source guards (internal implementation detail, not config)
#   Bare assignments RITE_FOO=... (no $) — definitions, not reads
#   Full-line comments (lines where the first non-whitespace char is #)
#
# Documented set: union of both config examples. A var mentioned in
# config/rite.conf.example (global operator vars such as RITE_REVIEW_MODEL,
# RITE_CLAUDE_MODEL, RITE_TEST_GATE_DIFF_BASE) counts as documented even
# if absent from config/project.conf.example — ledgering them as debt would
# be semantically false.
#
# Ledger: tools/lint-rules/36-undocumented-rite-var.ledger exempts the
# ~101 vars that existed before this rule was introduced. New vars must be
# documented or suppressed inline with a Reason.
#
# Suppression: preceding-line comment (mirrors Rule 24):
#   # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: ...
#
# New genuinely-internal (non-config) vars should use the _RITE_ prefix
# convention, which falls outside this rule's pattern by construction.
# Suppressions are for the rare internal var that must keep a bare RITE_ name.

echo "Checking for undocumented RITE_* variable reads in lib/..."

# Resolve paths from this fragment's location (same shell as driver, but
# BASH_SOURCE[0] still refers to the fragment file being sourced).
_r36_rules_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_r36_project_root="$(cd "$_r36_rules_dir/../.." && pwd)"

# Ledger path — missing ledger is a hard error, never a silent pass.
_r36_ledger="$_r36_rules_dir/36-undocumented-rite-var.ledger"
if [ ! -f "$_r36_ledger" ]; then
  echo "ERROR: Rule 36 ledger not found: $_r36_ledger" >&2
  echo "ERROR: The ledger must exist (seed with the command in the issue runbook)." >&2
  exit 1
fi

# Build the documented set: union of both config examples.
# Any mention of RITE_VARNAME (including commented-out option lines) counts.
_r36_conf_example="$_r36_project_root/config/project.conf.example"
_r36_rite_conf_example="$_r36_project_root/config/rite.conf.example"
_r36_documented_set=$(grep -hoE 'RITE_[A-Z0-9_]+' "$_r36_conf_example" "$_r36_rite_conf_example" 2>/dev/null | sort -u || true)

# Build the exemption set: union of documented set + ledger entries.
# Ledger lines starting with # are comments; blank lines are skipped.
_r36_ledger_entries=$(grep -vE '^\s*(#|$)' "$_r36_ledger" 2>/dev/null | sort -u || true)

# Combine documented + ledger into one sorted allowlist.
_r36_allowed_set=$(printf '%s\n%s\n' "$_r36_documented_set" "$_r36_ledger_entries" | sort -u | grep -vE '^\s*$' || true)

# Build the candidate file list from SHELL_FILES filtered to lib/ paths.
# Matches project tree AND fixture dirs injected via RITE_LINT_EXTRA_DIRS
# when the fixture path contains /lib/ (same technique as Rule 24).
_r36_lib_files=()
for _f in "${SHELL_FILES[@]}"; do
  if [[ "$_f" == */lib/*.sh ]]; then
    _r36_lib_files+=("$_f")
  fi
done

for _r36_file in "${_r36_lib_files[@]}"; do
  while IFS=: read -r _r36_line_num _r36_line_content; do
    # Skip full-line comments (first non-whitespace char is #).
    if echo "$_r36_line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # Extract the variable name from the match.
    # Pattern matches $RITE_VAR or ${RITE_VAR... (with optional braces).
    # _RITE_ prefix is excluded by the regex anchor (RITE_ not preceded by _).
    _r36_var_name=$(echo "$_r36_line_content" | grep -oE '\$\{?RITE_[A-Z0-9_]+' | head -1 | sed 's/\$[{]*//' || true)
    [ -n "$_r36_var_name" ] || continue

    # Check if var is in the allowlist (documented set ∪ ledger).
    if printf '%s\n' "$_r36_allowed_set" | grep -qxF "$_r36_var_name"; then
      continue
    fi

    # Check for suppression comment on preceding line.
    _r36_prev_num=$((_r36_line_num - 1))
    _r36_prev_line=$(sed -n "${_r36_prev_num}p" "$_r36_file" 2>/dev/null || true)
    if echo "$_r36_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*UNDOCUMENTED_RITE_VAR'; then
      continue
    fi

    print_violation "$_r36_file" "$_r36_line_num" "UNDOCUMENTED_RITE_VAR" \
      "\$${_r36_var_name} is not documented in config/project.conf.example or config/rite.conf.example — add a commented-out option entry to one of the config examples, add to the ledger (pre-existing only), or suppress inline with a Reason if this is a genuinely internal var (consider using _RITE_ prefix instead)"
  done < <(grep -nE '\$\{?RITE_[A-Z0-9_]+' "$_r36_file" 2>/dev/null || true)
done
