# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 28: BSD `date -jf` parsing a Z/UTC timestamp to epoch WITHOUT `-u`
#
# BSD date (macOS) needs `-u` to interpret the input as UTC. When the input
# format ends in a literal `Z` (the ISO-8601 UTC zone marker) but `-u` is
# missing, BSD date parses the timestamp in the machine's LOCAL timezone and
# the resulting epoch is skewed by the local UTC offset (e.g. -6h in MT).
# The trailing `Z` is treated as a literal, not as "this is UTC".
#
# Live fix (wave 1, this session): lib/utils/date-helpers.sh:35 iso_to_epoch()
# was missing `-u` on its BSD branch. Correct form: `date -u -jf ... +%s`.
# epoch_to_iso() already used `-u`; this keeps the round-trip pair symmetric.
#
# Detection (per `date` invocation segment, split on | ; & so a sibling command
# in a `||` chain cannot mask or falsely trigger this one):
#   FLAGGED when the segment has an -f flag char (input format) AND a -j flag
#   char (BSD no-set parse mode) in ANY clustering/order, a quoted format string
#   containing a literal uppercase `Z`, and `+%s` (epoch) output, and NO -u flag.
#
# Intentionally NOT flagged:
#   - any segment containing `-u` (correct UTC parse) — e.g. -u -jf / -juf / -ujf
#   - `%z` numeric-offset formats (lowercase z; the offset is parsed explicitly)
#   - date-only / no-Z formats (no time-of-day → no local-offset skew possible)
#   - non-epoch output (`+%b ...` display conversions, e.g. deliberate UTC->local)
#
# Suppression: add on the line immediately before the flagged code:
#   # sharkrite-lint disable BSD_DATE_PARSE_Z_WITHOUT_U - Reason: <text>
echo "Checking for BSD 'date -jf' parsing a Z/UTC timestamp to epoch without -u..."
for file in "${SHELL_FILES[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Check for suppression comment on the preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BSD_DATE_PARSE_Z_WITHOUT_U'; then
      continue
    fi
    # Examine each `date ...` invocation segment independently (terminated at
    # | ; & or EOL) so a -u on a sibling command in a || chain cannot mask a
    # bad invocation, and a good sibling cannot be flagged by a bad one.
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      # (a) an -f flag char (input format) somewhere in a dash-flag cluster
      echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)' || continue
      # (b) a -j flag char (BSD no-set parse mode) somewhere in a dash-flag cluster
      echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*j[a-zA-Z]*([[:space:]]|$)' || continue
      # (c) a quoted format string containing a literal uppercase Z (UTC marker)
      echo "$seg" | grep -qE '"[^"]*Z[^"]*"|'"'"'[^'"'"']*Z[^'"'"']*'"'" || continue
      # (d) epoch output
      echo "$seg" | grep -qE '\+%s' || continue
      # Safe iff a flag cluster contains -u (interpret input as UTC)
      if echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*u[a-zA-Z]*([[:space:]]|$)'; then
        continue
      fi
      print_violation "$file" "$line_num" "BSD_DATE_PARSE_Z_WITHOUT_U" \
        "BSD 'date -jf' parsing a Z/UTC timestamp to epoch without -u parses in local time, skewing the epoch by the local offset — use 'date -u -jf ...'"
    done < <(echo "$line_content" | grep -oE 'date[^|;&]*' || true)
  done < <(grep -nE 'date[^|;&]*-[a-zA-Z]*j' "$file" 2>/dev/null || true)
done

