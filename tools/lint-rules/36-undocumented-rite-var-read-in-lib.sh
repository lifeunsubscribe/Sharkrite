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
# LC_ALL=C: pin byte-exact ordering so macOS CI locale never collapses entries.
_r36_conf_example="$_r36_project_root/config/project.conf.example"
_r36_rite_conf_example="$_r36_project_root/config/rite.conf.example"
_r36_documented_set=$(LC_ALL=C grep -hoE 'RITE_[A-Z0-9_]+' "$_r36_conf_example" "$_r36_rite_conf_example" 2>/dev/null | LC_ALL=C sort -u || true)

# Build the exemption set: union of documented set + ledger entries.
# Ledger lines starting with # are comments; blank lines are skipped.
_r36_ledger_entries=$(LC_ALL=C grep -vE '^[[:space:]]*(#|$)' "$_r36_ledger" 2>/dev/null | LC_ALL=C sort -u || true)

# Combine documented + ledger into one sorted allowlist.
_r36_allowed_set=$(printf '%s\n%s\n' "$_r36_documented_set" "$_r36_ledger_entries" | LC_ALL=C sort -u | LC_ALL=C grep -vE '^[[:space:]]*$' || true)

# Guard: an empty allowlist means the ledger or sort pipeline failed silently.
# Every ledgered var would fire as a false positive, which is worse than failing.
if [ -z "$_r36_allowed_set" ]; then
  echo "ERROR: Rule 36 allowlist is empty after combining config examples and ledger." >&2
  echo "ERROR: Ledger has content but the pipeline produced nothing — environment issue." >&2
  exit 1
fi

# Diagnostics on the FIRST violation only (issue #1633). This rule fired on
# macOS CI for vars that ARE in the allowlist (five different vars: #1605,
# PR #1625, main run 42505835752, PR #1636 twice), passed on ubuntu for the
# same commit, and never reproduced on a dev box. Root cause: the membership
# check below was `printf '%s\n' "$allowed" | grep -qxF`, a SIGPIPE race under
# pipefail (see the comment at the check). Kept as the verification instrument:
# if a miss ever recurs, this records the environment, the size of each
# allowlist input, whether the flagged var is present in each, and the full
# combined list. Stderr only, nothing on a clean run, verdicts untouched.
#
# Membership here uses `grep -cxF ... <<<` — a here-string and a COUNT, so grep
# reads all of its input and there is no producer process to take SIGPIPE.
_r36_diag_printed=false
_r36_print_diag() {
  local _v="$1" _t _tv
  {
    printf '# rule36-diag: begin (first violation: %s)\n' "$_v"
    printf '# rule36-diag: bash=%s  uname=%s\n' "${BASH_VERSION:-unknown}" "$(uname -srm 2>/dev/null || true)"
    printf '# rule36-diag: LANG=%s LC_ALL=%s LC_CTYPE=%s\n' "${LANG:-unset}" "${LC_ALL:-unset}" "${LC_CTYPE:-unset}"
    printf '# rule36-diag: PATH=%s\n' "${PATH:-unset}"
    for _t in grep sed sort awk; do
      _tv=$("$_t" --version 2>/dev/null | head -1 || true)
      printf '# rule36-diag: tool %s=%s version=%s\n' "$_t" "$(command -v "$_t" || true)" "${_tv:-(none: BSD prints no --version)}"
    done
    printf '# rule36-diag: documented_set entries=%s  ledger_entries entries=%s  allowed_set entries=%s bytes=%s cksum=%s\n' \
      "$(grep -c . <<< "$_r36_documented_set" || true)" \
      "$(grep -c . <<< "$_r36_ledger_entries" || true)" \
      "$(grep -c . <<< "$_r36_allowed_set" || true)" \
      "$(printf '%s\n' "$_r36_allowed_set" | wc -c | tr -d ' ' || true)" \
      "$(printf '%s\n' "$_r36_allowed_set" | cksum | cut -d' ' -f1 || true)"
    printf '# rule36-diag: var %s in documented_set=%s ledger_entries=%s allowed_set=%s\n' "$_v" \
      "$(grep -cxF "$_v" <<< "$_r36_documented_set" || true)" \
      "$(grep -cxF "$_v" <<< "$_r36_ledger_entries" || true)" \
      "$(grep -cxF "$_v" <<< "$_r36_allowed_set" || true)"
    printf '# rule36-diag: allowed_set dump follows\n'
    printf '%s\n' "$_r36_allowed_set"
    printf '# rule36-diag: end\n'
  } >&2
}

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
    if echo "$_r36_line_content" | grep -qE '^[[:space:]]*#'; then
      continue
    fi

    # Extract all variable names from the line — a single line can reference
    # multiple RITE_* vars (e.g. string interpolation, export lists, comparisons).
    # head -1 would silently ignore every match after the first; iterate instead.
    # Pattern matches $RITE_VAR or ${RITE_VAR... (with optional braces).
    # _RITE_ prefix is excluded by the regex anchor (RITE_ not preceded by _).

    # Fetch suppression state once per line (shared by all vars on this line).
    _r36_prev_num=$((_r36_line_num - 1))
    _r36_prev_line=$(sed -n "${_r36_prev_num}p" "$_r36_file" 2>/dev/null || true)
    _r36_suppressed=false
    if echo "$_r36_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*UNDOCUMENTED_RITE_VAR'; then
      _r36_suppressed=true
    fi

    # Collect all distinct RITE_* var names from this line.
    _r36_vars_on_line=$(echo "$_r36_line_content" | grep -oE '\$\{?RITE_[A-Z0-9_]+' | sed 's/\$[{]*//' | LC_ALL=C sort -u || true)
    [ -n "$_r36_vars_on_line" ] || continue

    while IFS= read -r _r36_var_name; do
      [ -n "$_r36_var_name" ] || continue

      # Check if var is in the allowlist (documented set ∪ ledger).
      # Here-string, NOT `printf '%s\n' "$set" | grep -q`: the driver runs under
      # pipefail, and bash's printf builtin emits a 3 KB allowlist as several
      # write()s on macOS (1 KB stdio buffers; Linux writes it in one). When
      # grep -q matched in an early chunk and exited before the last write,
      # printf took SIGPIPE, the pipeline returned 141, and an allowlisted var
      # was reported undocumented — one random var per run, macOS CI only
      # (#1605, #1633). A here-string has no producer process to kill.
      if grep -qxF "$_r36_var_name" <<< "$_r36_allowed_set"; then
        continue
      fi

      # Check for suppression comment on preceding line.
      if [ "$_r36_suppressed" = "true" ]; then
        continue
      fi

      # First violation in this run: capture the evidence before reporting it.
      if [ "$_r36_diag_printed" = false ]; then
        _r36_print_diag "$_r36_var_name"
        _r36_diag_printed=true
      fi

      print_violation "$_r36_file" "$_r36_line_num" "UNDOCUMENTED_RITE_VAR" \
        "\$${_r36_var_name} is not documented in config/project.conf.example or config/rite.conf.example — add a commented-out option entry to one of the config examples, add to the ledger (pre-existing only), or suppress inline with a Reason if this is a genuinely internal var (consider using _RITE_ prefix instead)"
    done <<< "$_r36_vars_on_line"
  done < <(grep -nE '\$\{?RITE_[A-Z0-9_]+' "$_r36_file" 2>/dev/null || true)
done
