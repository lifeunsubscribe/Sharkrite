# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 5: BSD-only sed -i without GNU fallback
# NOTE: portable-cmds.sh is the only legitimate place for bare sed -i '' (with --version guard).
# For all other files, Rule 10 (BARE_BSD_SED_I) fires first and is more actionable.
# Rule 5 only fires on portable-cmds.sh itself, to ensure the --version guard is present there.
echo "Checking for BSD-only 'sed -i' without GNU fallback..."
for file in "${SHELL_FILES[@]}"; do
  # Rule 10 supersedes Rule 5 for every file except portable-cmds.sh.
  # Avoid double-reporting the same sed -i '' line.
  if [[ "$file" != */portable-cmds.sh ]]; then
    continue
  fi
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: sed -i '' (BSD format)
    if echo "$line_content" | grep -qE "sed\s+-i\s+''"; then
      # Check if there's a GNU fallback in the same file
      if ! grep -q 'sed --version' "$file" 2>/dev/null; then
        print_violation "$file" "$line_num" "BSD_SED_NO_FALLBACK" \
          "BSD sed -i '' detected without GNU fallback check"
      fi
    fi
  done < <(grep -n "sed -i" "$file" 2>/dev/null || true)
done

