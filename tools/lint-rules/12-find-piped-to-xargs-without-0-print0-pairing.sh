# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

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

