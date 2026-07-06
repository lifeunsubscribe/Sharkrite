# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 2: git push without explicit refspec (dangerous in automation)
echo "Checking for 'git push' without explicit refspec..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip if it's a comment
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: git push (without branch/refspec)
    # Allow: git push origin <branch>, git push -u, git push --force-with-lease
    if echo "$line_content" | grep -qE 'git\s+push\s*$' || \
       echo "$line_content" | grep -qE 'git\s+push\s+(--[a-z-]+\s*)+$'; then
      # Check if this is NOT followed by a refspec
      if ! echo "$line_content" | grep -qE 'git\s+push.*origin'; then
        print_violation "$file" "$line_num" "GIT_PUSH_NO_REFSPEC" \
          "git push without explicit refspec/branch is dangerous in automation"
      fi
    fi
  done < <(grep -n 'git push' "$file" 2>/dev/null || true)
done

