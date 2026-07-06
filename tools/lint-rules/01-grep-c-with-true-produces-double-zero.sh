# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

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

