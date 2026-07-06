# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 15: Unanchored sharkrite marker grep (bare-prefix guard, silent-death risk)
#
# Pattern: grep -q[E]? "sharkrite-[a-z-]+:" without a format anchor ([0-9]+, etc.)
#
# Exploitation vector: any issue body that DOCUMENTS a marker format with a
# placeholder value (e.g. "sharkrite-parent-pr:N") will match the bare-prefix
# guard. The outer guard triggers, the inner extraction returns empty (because
# the placeholder isn't a real number), and under set -e + pipefail the script
# dies silently with no error output.
#
# Live bug: 2026-05-31 — three batch runs died at Processing Issue #34 because
# #34's body listed "sharkrite-parent-pr:N" as documentation. Fix: commit 206f2be
# added [0-9]+ to the outer guard in batch-process-issues.sh; same fix applied to
# claude-workflow.sh as part of the codebase sweep in issue #90.
#
# Safe anchored patterns:
#   grep -qE "sharkrite-parent-pr:[0-9]+"     # digits required
#   grep -qE "sharkrite-follow-up:[0-9]+"     # digits required
#
# Unsafe bare-prefix patterns:
#   grep -q "sharkrite-parent-pr:"            # matches any text after colon
#   grep -qE "sharkrite-parent-pr:"           # same, with -E flag
echo "Checking for unanchored sharkrite marker grep patterns (bare-prefix guard)..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # Match: grep -q or grep -qE with a bare sharkrite-marker: pattern (colon at end).
    # The outer regex anchors on the closing :"  — so grep -qE "sharkrite-foo:[0-9]+"
    # does NOT match here (colon is followed by [0-9]+ not a closing quote).
    # Belt-and-suspenders: the inner check also verifies no [0-9] anchor is present,
    # guarding against edge cases where the outer regex might still match.
    if echo "$line_content" | grep -qE 'grep\s+-q[E]?\s+"sharkrite-[a-z-]+:"'; then
      # Extra guard: if the line somehow includes a format anchor despite the outer match,
      # skip it — the dev wrote something unusual but intentional.
      if ! echo "$line_content" | grep -qE '\[0-9\]|\[a-zA-Z0-9'; then
        print_violation "$file" "$line_num" "BARE_MARKER_GREP" \
          "Unanchored sharkrite marker grep — add a format anchor like [0-9]+ to prevent silent death when issue bodies document the marker format"
      fi
    fi
  done < <(grep -n 'grep.*sharkrite-' "$file" 2>/dev/null || true)
done

