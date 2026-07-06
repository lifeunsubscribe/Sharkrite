# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 34: Pre-source function stub overwritten by env-guarded lib (BATS_PRE_SOURCE_STUB_OVERWRITE)
#
# When setup()/setup_file() in a .bats file defines a function stub (e.g.,
# `gh_safe() {`) and then sources a lib file that uses an env-var re-source
# guard (e.g., `_RITE_GH_RETRY_LOADED=true`), the REAL function definition
# from the lib OVERWRITES the pre-source stub.  Function-sentinel guards skip
# by checking `declare -f`; env-var guards skip by checking a shell variable
# — they do NOT check whether the function is already defined in the calling
# shell, so the real implementation always wins on source.
#
# Live failure: a pre-source `gh_safe` stub was silently overwritten after
# `source gh-retry.sh`; the exit-14 test hit live GitHub for two days
# (issue #804, PR #840 pointwise fix, this rule from PR #848).
#
# The rule flags: any .bats setup()/setup_file() that:
#   1. Defines at least one function stub (`NAME() {` line)
#   2. Sources a lib file (path matching lib/... or $RITE_LIB_DIR/.../...)
#   3. Does NOT re-define the stub function after the LAST source line
#
# Heredoc-aware: stub/source lines inside fixture heredocs are content, not
# setup code.
#
# Suppression: place on the line immediately before the flagged source line:
#   # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: <text>
echo "Checking for pre-source function stubs overwritten by env-guarded lib sources..."

_r34_awk=$(mktemp)
# AWK strategy:
#   Track state for each setup()/setup_file() function body.
#   Collect stub function names defined before a source (phase = "pre").
#   When a source line is seen, flip to "post" phase and record the source line.
#   Collect stub re-definitions seen after the source (phase = "post").
#   On closing }, if there are pre-source stubs that have no post-source re-stub,
#   report the source line number (so the user knows which source is the trigger).
#
# BSD AWK compatible: no \s, no + quantifier, no \b, no gensub, no match(,,arr).
# Uses index(), [[:space:]], and [^a-zA-Z0-9_] for word-boundary checks.
#
# Output: FILENAME TAB linenum (tab-separated for paths with colons)
printf '%s\n' \
  'FNR == 1 { in_heredoc = 0; hd_marker = ""; in_setup = 0; phase = "none"; src_line = 0 }' \
  'function array_has(arr, n,    k) { for (k in arr) if (k == n) return 1; return 0 }' \
  '{' \
  '  # ---- heredoc close ----' \
  '  if (in_heredoc) {' \
  '    _c = $0; sub(/^[[:space:]]*/, "", _c)' \
  '    if (_c == hd_marker) in_heredoc = 0' \
  '    next' \
  '  }' \
  '  if ($0 ~ /^[[:space:]]*#/) next' \
  '  # ---- heredoc open ----' \
  '  if (index($0, "<<") > 0) {' \
  '    tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)' \
  '    gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")' \
  '    if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }' \
  '  }' \
  '  # ---- setup()/setup_file() open ----' \
  '  if (!in_setup) {' \
  '    if ($0 ~ /^(setup|setup_file|setup_suite)[[:space:]]*\(\)/) {' \
  '      in_setup = 1; phase = "none"; src_line = 0' \
  '      delete pre_stubs; delete post_stubs' \
  '    }' \
  '    next' \
  '  }' \
  '  # ---- setup() close ----' \
  '  if ($0 ~ /^}[[:space:]]*$/) {' \
  '    # If we saw at least one source and have pre-stubs with no post re-stub, report' \
  '    if (src_line > 0) {' \
  '      for (fn in pre_stubs) {' \
  '        if (!array_has(post_stubs, fn)) {' \
  '          print FILENAME "\t" src_line "\t" fn' \
  '        }' \
  '      }' \
  '    }' \
  '    in_setup = 0; phase = "none"; src_line = 0' \
  '    delete pre_stubs; delete post_stubs' \
  '    next' \
  '  }' \
  '  # ---- function stub definition (NAME() { form) ----' \
  '  # Match:   name() {   or   name ()  {' \
  '  # Require word-start (after whitespace or line-start) and word-end before ().' \
  '  if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ ||' \
  '      $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*$/) {' \
  '    # Extract function name: take the first token before ()' \
  '    fn_tok = $0; sub(/^[[:space:]]*/, "", fn_tok); sub(/[[:space:]]*\(.*/, "", fn_tok)' \
  '    if (length(fn_tok) > 0 && fn_tok ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {' \
  '      if (phase == "none" || phase == "pre") { phase = "pre"; pre_stubs[fn_tok] = FNR }' \
  '      else if (phase == "post") { post_stubs[fn_tok] = FNR }' \
  '    }' \
  '  }' \
  '  # ---- source line ----' \
  '  # Matches: source /path/lib/...  or  . /path/lib/...  or  source "${RITE_LIB_DIR}/...' \
  '  # The same path pattern as Rule 30: lib/ path or config.sh.' \
  '  if (($0 ~ /(^|[^A-Za-z0-9_.])(source|\.)[ \t]+/ &&' \
  '       $0 ~ /(lib|LIB_DIR[}"'"'"']*)\/(core|utils|providers|hooks)\/|config\.sh/) &&' \
  '      index($0, "RITE_SOURCE_FUNCTIONS_ONLY") == 0) {' \
  '    if (phase == "pre") {' \
  '      # Only report the first (or last? use last for the re-stub check to be sound) source.' \
  '      # Use the LAST source line as the report point — the re-stub must follow all sources.' \
  '      src_line = FNR; phase = "post"' \
  '      delete post_stubs' \
  '    } else if (phase == "post") {' \
  '      src_line = FNR; delete post_stubs' \
  '    }' \
  '  }' \
  '}' \
  'END {' \
  '  if (in_setup && src_line > 0) {' \
  '    for (fn in pre_stubs) {' \
  '      if (!array_has(post_stubs, fn)) {' \
  '        print FILENAME "\t" src_line "\t" fn' \
  '      }' \
  '    }' \
  '  }' \
  '}' \
  > "$_r34_awk"

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r34_file_hits=$(awk -f "$_r34_awk" "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r34_file_hits" ] && continue
  while IFS=$'\t' read -r _r34_fname _r34_line _r34_fn; do
    [ -z "$_r34_line" ] && continue
    # Scan backwards past any contiguous comment lines (e.g. # shellcheck source=)
    # to find a suppression comment — codebase convention places # shellcheck
    # directives between the suppression comment and the source line.
    _r34_suppressed=false
    _r34_lookback=$((_r34_line - 1))
    while [ "$_r34_lookback" -gt 0 ]; do
      _prev_line=$(sed -n "${_r34_lookback}p" "$bats_file" 2>/dev/null || true)
      if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BATS_PRE_SOURCE_STUB_OVERWRITE'; then
        _r34_suppressed=true
        break
      fi
      # Keep scanning if this line is a pure comment line (e.g. # shellcheck …)
      if echo "$_prev_line" | grep -qE '^\s*#'; then
        _r34_lookback=$((_r34_lookback - 1))
        continue
      fi
      # Non-comment, non-suppression line — stop scanning
      break
    done
    [ "$_r34_suppressed" = "true" ] && continue
    print_violation "$bats_file" "$_r34_line" "BATS_PRE_SOURCE_STUB_OVERWRITE" \
      "stub '${_r34_fn}()' defined before this lib source is overwritten by the lib's real definition (env-var guards don't check for existing functions); re-define the stub AFTER the last source in setup()"
  done <<< "$_r34_file_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

rm -f "$_r34_awk"
_r34_awk=""

