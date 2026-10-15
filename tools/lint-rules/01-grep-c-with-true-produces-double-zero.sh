# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 1: guaranteed-output-counter paired with || echo "0" produces double zero.
# Producers covered: grep -c, wc -l (as final pipeline stage), awk with END block (as final stage).
# NOT flagged (output-or-nothing producers): grep -o, grep -oE — these legitimately pair with
# || true because they produce no output on no match (see CLAUDE.md "grep -c pattern").
echo "Checking for guaranteed-output-counter with '|| echo \"0\"' pattern..."

# Returns 0 if the content line has any of the three echo-zero forms ("0", '0', bare 0)
_echo_zero_on_line() {
  local content="$1"
  echo "$content" | grep -qE '\|\|\s*echo\s+"0"' && return 0
  echo "$content" | grep -qE $'\|\|\s*echo\s+\'0\'' && return 0
  echo "$content" | grep -qE '\|\|\s*echo\s+0([^0-9]|$)' && return 0
  return 1
}

for file in "${SHELL_FILES[@]}"; do
  # grep -c always outputs a count (even "0") — use || true instead of || true
  while IFS=: read -r line_num line_content; do
    echo "$line_content" | grep -qE '^\s*#' && continue  # skip comment-only lines
    if _echo_zero_on_line "$line_content"; then
      print_violation "$file" "$line_num" "GREP_C_ECHO_ZERO" \
        "grep -c already outputs '0'; use || true instead of || echo \"0\""
    fi
  done < <(grep -n 'grep -c' "$file" 2>/dev/null || true)

  # wc -l as the FINAL pipeline stage always outputs a count — use || true
  # [^|]* ensures no pipe between wc -l and ||, i.e. wc -l is the final stage
  # (wc -l | tr -d ' ' || echo "0" is NOT flagged — tr is the final stage there)
  while IFS=: read -r line_num line_content; do
    echo "$line_content" | grep -qE '^\s*#' && continue  # skip comment-only lines
    if echo "$line_content" | grep -qE 'wc\s+-l[^|]*\|\|\s*echo\s+"0"' ||
       echo "$line_content" | grep -qE $'wc\s+-l[^|]*\|\|\s*echo\s+\'0\'' ||
       echo "$line_content" | grep -qE 'wc\s+-l[^|]*\|\|\s*echo\s+0([^0-9]|$)'; then
      print_violation "$file" "$line_num" "GREP_C_ECHO_ZERO" \
        "wc -l always outputs a count; use || true instead of || echo \"0\""
    fi
  done < <(grep -n 'wc -l' "$file" 2>/dev/null || true)

  # awk with END block as the FINAL pipeline stage — END always runs and prints
  # [^|]* after awk...END ensures no pipe between awk and ||, i.e. awk is the final stage
  # Conservative: requires literal END token in the awk program on the same line
  while IFS=: read -r line_num line_content; do
    echo "$line_content" | grep -qE '^\s*#' && continue  # skip comment-only lines
    if echo "$line_content" | grep -qE 'awk\s+[^|]*END[^|]*\|\|\s*echo\s+"0"' ||
       echo "$line_content" | grep -qE $'awk\s+[^|]*END[^|]*\|\|\s*echo\s+\'0\'' ||
       echo "$line_content" | grep -qE 'awk\s+[^|]*END[^|]*\|\|\s*echo\s+0([^0-9]|$)'; then
      print_violation "$file" "$line_num" "GREP_C_ECHO_ZERO" \
        "awk END block always runs and prints; use || true instead of || echo \"0\""
    fi
  done < <(grep -n 'awk.*END' "$file" 2>/dev/null || true)
done
