# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 35: File-scope RITE_* / inherited env-var reads in .bats files (BATS_FILE_SCOPE_ENV_READ)
#
# Assignments at the TRUE file scope of a .bats file (outside any function or
# @test block) that reference $RITE_* environment variables are unsafe.  They
# execute when bats parses and loads the file — before setup() runs — at which
# point the env vars may not yet be set (especially RITE_REPO_ROOT and
# RITE_TEST_TMPDIR, which are set by tests/helpers/setup.bash inside setup()).
#
# Live failure class: `_WORKFLOW_FILE="${RITE_LIB_DIR}/core/workflow-runner.sh"`
# at file scope (on the #804 branch) expanded to an empty path because
# RITE_LIB_DIR was not exported before the file was parsed — tests then failed
# to source the lib and bats reported "Executed 0 instead of expected N".
#
# Safe patterns NOT flagged:
#   - Assignments derived from BATS_TEST_FILENAME / BATS_TEST_DIRNAME /
#     BATS_TEST_TMPDIR — these are bats builtins always set before parsing.
#   - Assignments inside any function (setup, setup_file, @test, helpers).
#   - Assignments inside heredoc bodies.
#
# Suppression: place on the line immediately before the flagged assignment:
#   # sharkrite-lint disable BATS_FILE_SCOPE_ENV_READ - Reason: <text>
echo "Checking for file-scope RITE_* env-var reads in .bats files..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r35_file_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; depth = 0; in_squote_ml = 0 }
    {
      # ---- multi-line single-quoted string close ----
      # A file-scope VAR='"'"'...'"'"' assignment can span multiple lines.
      # Lines inside it look like normal code but must not be flagged.
      if (in_squote_ml) {
        # The string ends at the first bare single-quote at end-of-line (no escape in single quotes).
        if ($0 ~ /'"'"'[[:space:]]*$/) in_squote_ml = 0
        next
      }
      # ---- heredoc close ----
      if (in_heredoc) {
        _c = $0; sub(/^[[:space:]]*/, "", _c)
        if (_c == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      # ---- heredoc open ----
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      # ---- detect multi-line single-quoted assignment at file scope ----
      # Pattern:  VAR='"'"'  (line ends after opening single quote, no closing quote)
      # This is the pattern used for inline shell-script variables like:
      #   _script_body='"'"'
      #     ... code with ${RITE_*} ...
      #   '"'"'
      if (depth == 0 && $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*='"'"'/ && $0 !~ /'"'"'.*'"'"'[[:space:]]*$/) {
        # Odd number of single quotes → opens a multi-line block
        _sq_count = 0; _tmp_sq = $0
        while (index(_tmp_sq, "'"'"'") > 0) { _sq_count++; sub(/'"'"'/, "", _tmp_sq) }
        if (_sq_count % 2 == 1) { in_squote_ml = 1; next }
      }
      # ---- track brace depth (to detect file-scope vs inside-function) ----
      # Strip string literals and ${} expansions to avoid counting braces inside them.
      _stripped = $0
      gsub(/'"'"'[^'"'"']*'"'"'/, "", _stripped)
      gsub(/"[^"]*"/, "", _stripped)
      gsub(/\$\{[^}]*\}/, "", _stripped)
      _tmp = _stripped; _ob = gsub(/{/, "", _tmp)
      _tmp = _stripped; _cb = gsub(/}/, "", _tmp)
      depth += _ob - _cb
      if (depth < 0) depth = 0
      # ---- only flag at file scope (depth == 0) ----
      if (depth > 0) next
      # ---- detect: VAR=... referencing $RITE_* on a bare assignment line ----
      # The assignment must:
      #   - Be a plain variable assignment (not inside a function/test/if body)
      #   - Reference $RITE_* (with or without braces)
      #   - NOT be purely derived from BATS builtins (BATS_TEST_FILENAME, etc.)
      #
      # Pattern: line matches  VAR=...${RITE_...  or  VAR=...$RITE_...
      # And the RHS contains \$RITE_ (not just \$BATS_TEST_* or \$BATS_TEST_DIRNAME)
      if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ &&
          ($0 ~ /\$\{RITE_[A-Z_]/ || $0 ~ /\$RITE_[A-Z_]/)) {
        # Skip if the only RITE_ reference is inside a BATS_TEST_FILENAME/DIRNAME
        # derivation (those are always set). Heuristic: if the line also has
        # BATS_TEST_FILENAME or BATS_TEST_DIRNAME, assume it is the safe pattern.
        if (index($0, "BATS_TEST_FILENAME") > 0 || index($0, "BATS_TEST_DIRNAME") > 0) next
        print FNR
      }
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r35_file_hits" ] && continue
  while IFS= read -r _r35_line; do
    [ -z "$_r35_line" ] && continue
    # Scan backwards past any contiguous comment lines (e.g. # shellcheck source=)
    # to find a suppression comment — same convention as Rule 34.
    _r35_suppressed=false
    _r35_lookback=$((_r35_line - 1))
    while [ "$_r35_lookback" -gt 0 ]; do
      _prev_line=$(sed -n "${_r35_lookback}p" "$bats_file" 2>/dev/null || true)
      if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BATS_FILE_SCOPE_ENV_READ'; then
        _r35_suppressed=true
        break
      fi
      # Keep scanning if this line is a pure comment line
      if echo "$_prev_line" | grep -qE '^\s*#'; then
        _r35_lookback=$((_r35_lookback - 1))
        continue
      fi
      # Non-comment, non-suppression line — stop scanning
      break
    done
    [ "$_r35_suppressed" = "true" ] && continue
    print_violation "$bats_file" "$_r35_line" "BATS_FILE_SCOPE_ENV_READ" \
      "file-scope assignment reads \$RITE_* env var before setup() runs — RITE_* vars may not be set at parse time; move this assignment into setup() or suppress if the variable is guaranteed to be exported before bats parses the file"
  done <<< "$_r35_file_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

