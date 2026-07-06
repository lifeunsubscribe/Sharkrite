# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 23: MISSING_TAG_JUSTIFICATION — tag in convention block not in tag-index.md
#          and not in the same block's new-tags: field
#
# When a <!-- sharkrite-convention --> block declares `tags: foo, bar`, every tag
# must either:
#   (a) already have a `## foo` heading in docs/architecture/tag-index.md, OR
#   (b) appear in the same block's `new-tags:` section with a justification line.
#
# Without this rule, a contributor could introduce a tag that silently fails to
# accumulate pointers because no matching heading exists in the index.  Forcing
# explicit `new-tags:` justification keeps the index coherent and makes drift
# visible at authoring time (rather than silently at merge time).
#
# Tag-index path: derived from PROJECT_ROOT, same location as the write helpers.
# When tag-index.md does not exist, this rule is skipped entirely — a missing
# index is acceptable before the first tagged PR merges.
#
# Override: set RITE_TAG_INDEX_PATH_OVERRIDE to redirect to a temp file.
# This is the test-isolation hook — tests set this variable so the linter reads
# a seeded fixture instead of the real docs/architecture/tag-index.md.
# Without this, any test that seeds tag-index.md must mutate the real file, which
# is a crash-unsafe isolation hazard (backup/restore races in parallel runs).
#
# Files scanned: SHELL_FILES (bin/, lib/, tools/) — the same files already
# processed by other lint rules.  Convention blocks may also appear embedded as
# heredoc strings in PR creation scripts; the file scan catches those.
echo "Checking for missing tag justification in convention blocks..."

_tag_index_path="${RITE_TAG_INDEX_PATH_OVERRIDE:-${PROJECT_ROOT}/docs/architecture/tag-index.md}"

# Only run the check when tag-index.md exists; a missing index means no tags
# have been established yet, so no violation is possible.
if [ -f "$_tag_index_path" ]; then

  # Build a set of known tags from the index — one tag name per line, lowercased.
  # Parse `## tagname` headings.  Use awk for BSD AWK compatibility.
  _known_tags_file=$(mktemp)
  awk '/^## / { tag=substr($0, 4); sub(/^[[:space:]]+/, "", tag); sub(/[[:space:]]+$/, "", tag); print tolower(tag) }' \
    "$_tag_index_path" > "$_known_tags_file" 2>/dev/null || true

  for file in "${SHELL_FILES[@]}"; do
    # Use awk to extract convention blocks and check their tags fields.
    # The awk program:
    #   1. Collects lines between <!-- sharkrite-convention --> markers.
    #   2. On block-end, checks each tag from `tags:` against:
    #      a. The known_tags_file (pre-built tag list).
    #      b. The `new-tags:` section inside the same block.
    #   3. Reports "FILE:LINE:TAGNAME" for each unresolved tag.
    #
    # Variables passed to awk:
    #   open_marker  — the exact opening marker string (via variable to satisfy RAW_MARKER_LITERAL lint)
    #   close_marker — the exact closing marker string
    #   tags_file    — path to the pre-built known tags file
    _r23_violations=$(awk \
      -v open_marker="<!-- sharkrite-convention -->" \
      -v close_marker="<!-- /sharkrite-convention -->" \
      -v tags_file="$_known_tags_file" \
      'BEGIN {
        # Load known tags into associative array
        while ((getline tag_line < tags_file) > 0) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", tag_line)
          if (length(tag_line) > 0) known_tags[tag_line] = 1
        }
        close(tags_file)
        in_block = 0
        block_start_line = 0
        tags_line = ""
        new_tags_block = ""
      }
      $0 == open_marker  { in_block = 1; block_start_line = NR; tags_line = ""; new_tags_block = ""; in_new_tags = 0; in_example = 0; next }
      $0 == close_marker {
        if (!in_block) { next }
        in_block = 0

        # Parse tags: field (comma-separated)
        if (length(tags_line) == 0) { next }

        # Build set of new-tags from new-tags block
        split("", new_tags_set)
        n = split(new_tags_block, nt_lines, "\n")
        for (i = 1; i <= n; i++) {
          line = nt_lines[i]
          gsub(/^[[:space:]]*-[[:space:]]*/, "", line)
          colon = index(line, ":")
          if (colon > 1) {
            nt_name = substr(line, 1, colon - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", nt_name)
            if (length(nt_name) > 0) {
              new_tags_set[tolower(nt_name)] = 1
            }
          }
        }

        # Check each tag
        # Output uses tab as field separator (file\tlinenum\ttag) so paths containing
        # colons (e.g. CI matrix job paths) parse correctly downstream.
        split(tags_line, tag_tokens, ",")
        for (i = 1; i <= length(tag_tokens); i++) {
          tok = tag_tokens[i]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", tok)
          if (length(tok) == 0) continue
          tok_lower = tolower(tok)
          if (!(tok_lower in known_tags) && !(tok_lower in new_tags_set)) {
            print FILENAME "\t" block_start_line "\t" tok
          }
        }
        next
      }
      in_block && /^example:[[:space:]]*\|/ { in_example = 1; in_new_tags = 0; next }
      in_block && in_example && /^(title|rule|why|example|references|tags|new-tags):/ { in_example = 0 }
      in_block && in_example { next }
      in_block && /^tags:/ {
        tags_line = substr($0, 6)
        gsub(/^[[:space:]]+/, "", tags_line)
        in_new_tags = 0
        next
      }
      in_block && /^new-tags:/ { in_new_tags = 1; next }
      in_block && in_new_tags && /^(title|rule|why|example|references|tags):/ { in_new_tags = 0 }
      in_block && in_new_tags { new_tags_block = new_tags_block $0 "\n"; next }
    ' "$file" 2>/dev/null || true)

    if [ -n "$_r23_violations" ]; then
      while IFS= read -r _r23_hit; do
        [ -z "$_r23_hit" ] && continue
        # Tab-separated: file<TAB>linenum<TAB>tag — safe for paths containing colons
        _r23_file=$(echo "$_r23_hit" | cut -f1)
        _r23_line=$(echo "$_r23_hit" | cut -f2)
        _r23_tag=$(echo "$_r23_hit" | cut -f3)
        print_violation "$_r23_file" "$_r23_line" "MISSING_TAG_JUSTIFICATION" \
          "tag '${_r23_tag}' in convention block is not in tag-index.md and has no new-tags: justification — add it to new-tags: with a one-line reason or add a ## ${_r23_tag} heading to docs/architecture/tag-index.md"
      done <<< "$_r23_violations"
    fi
  done

  rm -f "$_known_tags_file"
fi

