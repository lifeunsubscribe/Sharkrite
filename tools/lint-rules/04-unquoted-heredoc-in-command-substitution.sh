# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 4: Unquoted heredoc in command substitution
echo "Checking for unquoted heredoc in command substitution..."
for file in "${SHELL_FILES[@]}"; do
  # Match: $(cat <<EOF or $(... <<EOF without quotes
  # Safe: $(cat <<'EOF' or $(cat << 'EOF' with space before quote
  while IFS=: read -r line_num line_content; do
    # Check for suppression comment on previous line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*UNQUOTED_HEREDOC'; then
      continue
    fi

    if echo "$line_content" | grep -qE '\$\([^)]*<<[^)]*(EOF|END|HEREDOC)' && \
       ! echo "$line_content" | grep -qE "<<\s*'"; then
      print_violation "$file" "$line_num" "UNQUOTED_HEREDOC_CMDSUB" \
        "Unquoted heredoc in command substitution - use <<'EOF' to prevent expansion"
    fi
  done < <(grep -n '<<.*EOF' "$file" 2>/dev/null || true)
done

