# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 11: BSD-only stat -f (mtime) without portable wrapper (except portable-cmds.sh itself)
echo "Checking for bare 'stat -f' (BSD-only)..."
for file in "${SHELL_FILES[@]}"; do
  # portable-cmds.sh is the canonical implementation — skip it
  if [[ "$file" == */portable-cmds.sh ]]; then
    continue
  fi
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    if echo "$line_content" | grep -qE 'stat\s+-f'; then
      print_violation "$file" "$line_num" "BARE_BSD_STAT_F" \
        "Use portable_stat_mtime() or portable_find_max_mtime() from lib/utils/portable-cmds.sh instead of bare 'stat -f'"
    fi
  done < <(grep -n 'stat -f' "$file" 2>/dev/null || true)
done

