# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 26: Non-portable 'sleep infinity' / 'sleep inf' (BSD/macOS /bin/sleep rejects)
#
# GNU coreutils `sleep` accepts the keywords `infinity` and `inf` ("sleep
# forever"), but BSD/macOS /bin/sleep accepts ONLY a numeric duration. Given
# `sleep infinity`, BSD sleep prints `usage: sleep number[unit]` and exits
# immediately (exit 1) — it never sleeps. Any code relying on it to block the
# process forever (mock servers, hang simulators, hold-open patterns) silently
# fails to wait on macOS, producing flaky/wrong behavior with no error trail.
#
# Live fix (this session): tests/helpers/gh-mock.bash + claude-mock.bash used
# `sleep infinity` to simulate a hung subprocess; on macOS they returned
# instantly, defeating the hang. Fixed to a large finite value.
#
# Portable fix: a large finite value that both GNU and BSD accept, e.g.
#   sleep 2147483647   # ~68 years
#
# Same low-FP class as Rule 10 (BARE_BSD_SED_I) / Rule 11 (BARE_BSD_STAT_F):
# a fixed non-portable literal token, not a heuristic.
#
# Suppression: add on the line immediately before the flagged code:
#   # sharkrite-lint disable SLEEP_INFINITY_NOT_PORTABLE - reason: <text>
echo "Checking for non-portable 'sleep infinity' / 'sleep inf' (BSD/macOS rejects)..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments (documentation mentions of the pattern are fine)
    if echo "$line_content" | grep -qE '^[[:space:]]*#'; then
      continue
    fi
    # Check for suppression comment on the preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*SLEEP_INFINITY_NOT_PORTABLE'; then
      continue
    fi
    print_violation "$file" "$line_num" "SLEEP_INFINITY_NOT_PORTABLE" \
      "'sleep infinity'/'sleep inf' is rejected by BSD/macOS /bin/sleep (exits immediately, never sleeps) — use a large finite value like 'sleep 2147483647'"
  done < <(grep -nE '\bsleep[[:space:]]+(-[a-z]+[[:space:]]+)*(inf|infinity)\b' "$file" 2>/dev/null || true)
done

