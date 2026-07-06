# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

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

