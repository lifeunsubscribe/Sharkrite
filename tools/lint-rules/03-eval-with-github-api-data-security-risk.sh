# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

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

