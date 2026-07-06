# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 6: PIPESTATUS after || true or non-pipeline
echo "Checking for PIPESTATUS misuse..."
for file in "${SHELL_FILES[@]}"; do
  # Find all PIPESTATUS usages
  while IFS=: read -r line_num line_content; do
    # Get previous line for context
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")

    # Check if previous line has || true (which destroys PIPESTATUS)
    if echo "$prev_line" | grep -qE '\|\|\s*true\s*$'; then
      print_violation "$file" "$line_num" "PIPESTATUS_AFTER_OR_TRUE" \
        "PIPESTATUS used after '|| true' - PIPESTATUS is lost/stale"
    fi

    # Check if PIPESTATUS is used but there's no pipe on the previous line
    # Exception: if it's inside a fallback like ${PIPESTATUS[0]:-$?}
    if ! echo "$line_content" | grep -qE '\$\{PIPESTATUS\[0\]:-'; then
      if ! echo "$prev_line" | grep -qE '\|'; then
        # Could be a false positive if the pipe is 2+ lines up, but flag it
        print_warning "$file" "$line_num" "PIPESTATUS_NO_PIPELINE" \
          "PIPESTATUS referenced but no pipe found on previous line - verify context"
      fi
    fi
  done < <(grep -n 'PIPESTATUS\[' "$file" 2>/dev/null || true)
done

