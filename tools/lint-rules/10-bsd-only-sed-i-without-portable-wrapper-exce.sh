# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 10: BSD-only sed -i '' without portable wrapper (except portable-cmds.sh itself)
echo "Checking for bare 'sed -i \"\"' without portable wrapper..."
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
    # Match: sed -i '' (BSD form)
    if echo "$line_content" | grep -qE "sed\s+-i\s+''"; then
      print_violation "$file" "$line_num" "BARE_BSD_SED_I" \
        "Use portable_sed_i() from lib/utils/portable-cmds.sh instead of bare 'sed -i '''"
    fi
  done < <(grep -n "sed -i" "$file" 2>/dev/null || true)
done

