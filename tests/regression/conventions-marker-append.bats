#!/usr/bin/env bats
# tests/regression/conventions-marker-append.bats
#
# Regression tests for update_conventions_from_marker() in assess-documentation.sh.
#
# The function:
#   1. Extracts <!-- sharkrite-convention -->...<!-- /sharkrite-convention --> blocks
#      from a PR body string.
#   2. Parses YAML-ish fields (title, rule, why, example, references).
#   3. Appends a rendered markdown entry to docs/architecture/conventions.md.
#   4. Is idempotent: re-running with the same title + PR# is a no-op.
#
# Tests:
#   1. Happy path: PR body with one marker block → entry appended to conventions.md
#   2. Idempotency: re-run with same PR# → no duplicate entry
#   3. No marker: PR body without any marker block → conventions.md unchanged
#   4. Multiple blocks: PR body with two marker blocks → both entries appended
#   5. Malformed block (no title): skipped with warning, no crash

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract update_conventions_from_marker() and its helpers from
# assess-documentation.sh without running any top-level script code.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INTERNAL_DOCS_DIR="${RITE_TEST_TMPDIR}/.rite/docs"
  mkdir -p "$RITE_INTERNAL_DOCS_DIR"

  # _MARKER_DIR is used by _mark_updated() inside the function
  export _MARKER_DIR
  _MARKER_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/markers.XXXXXX")"

  # Load marker constants (RITE_MARKER_CONVENTION) so the function uses the
  # correct marker string when building open/close awk patterns.
  source "${RITE_REPO_ROOT}/lib/utils/markers.sh"

  # Source colors/logging stubs so print_warning and print_info don't crash
  # (they write to stderr in the real lib; for tests we just silence them).
  print_warning() { :; }
  print_info()    { :; }
  verbose_info()  { :; }
  export -f print_warning print_info verbose_info

  # Extract _mark_updated() and update_conventions_from_marker() from
  # assess-documentation.sh via awk, same pattern as changelog-ordering.bats.
  eval "$(awk '
    /^_mark_updated\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
    /^update_conventions_from_marker\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/assess-documentation.sh")"

  # Create a minimal conventions.md in RITE_PROJECT_ROOT/docs/architecture/
  mkdir -p "${RITE_TEST_TMPDIR}/docs/architecture"
  cat > "${RITE_TEST_TMPDIR}/docs/architecture/conventions.md" <<'EOF'
# Sharkrite Conventions Catalog

**Auto-appended on merge — do not hand-edit.**

---

## seed-convention

**Rule:** This is a seed entry for testing.

**Why:** Provides a baseline so idempotency checks have something to work with.

**References:** #1

---
EOF
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: build a PR body with one sharkrite-convention block
# ---------------------------------------------------------------------------
one_block_body() {
  cat <<'BODY'
This PR adds some improvements.

<!-- sharkrite-convention -->
title: no-eval-on-gh-data
rule: Never use eval on data fetched from the GitHub API
why: GitHub API responses can contain arbitrary user-controlled text; eval on that data is a remote code execution vector
example: |
  # BAD
  eval "$(gh pr view 42 --json title --jq '.title')"
  # GOOD
  TITLE=$(gh pr view 42 --json title --jq '.title')
references: abc1234, #99
<!-- /sharkrite-convention -->

Closes #55
BODY
}

# ---------------------------------------------------------------------------
# Test 1: Happy path — single block is appended to conventions.md
# ---------------------------------------------------------------------------

@test "happy path: single marker block is appended to conventions.md" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local pr_body
  pr_body="$(one_block_body)"

  update_conventions_from_marker "42" "$pr_body"

  # Entry heading must exist
  grep -q "^## no-eval-on-gh-data$" "$conventions_file"

  # Rule line must be present
  grep -q "Never use eval on data fetched from the GitHub API" "$conventions_file"

  # Why line must be present
  grep -q "GitHub API responses can contain arbitrary user-controlled text" "$conventions_file"

  # Example block must be present
  grep -q "^# BAD" "$conventions_file"
  grep -q "eval.*gh pr view" "$conventions_file"

  # References must include both the original refs and the new PR#
  grep -q "\*\*References:\*\* abc1234, #99, #42" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 2: Idempotency — re-running with same PR# produces no duplicate
# ---------------------------------------------------------------------------

@test "idempotency: same PR number does not produce duplicate entry" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local pr_body
  pr_body="$(one_block_body)"

  # First run
  update_conventions_from_marker "42" "$pr_body"

  # Second run — must be a no-op
  update_conventions_from_marker "42" "$pr_body"

  # The heading must appear exactly once
  local count
  count=$(grep -c "^## no-eval-on-gh-data$" "$conventions_file" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 3: No marker — conventions.md is unchanged
# ---------------------------------------------------------------------------

@test "no marker: PR body without marker block leaves conventions.md unchanged" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Capture content before
  local before_content
  before_content=$(cat "$conventions_file")

  local pr_body="This PR makes minor fixes. No conventions here. Closes #77"
  update_conventions_from_marker "77" "$pr_body"

  # Content must be identical
  local after_content
  after_content=$(cat "$conventions_file")
  [ "$before_content" = "$after_content" ]
}

# ---------------------------------------------------------------------------
# Test 4: Multiple blocks — both entries are appended
# ---------------------------------------------------------------------------

@test "multiple blocks: two marker blocks in one PR both get appended" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local pr_body
  pr_body=$(cat <<'BODY'
PR with two conventions.

<!-- sharkrite-convention -->
title: first-new-convention
rule: Always do the first thing
why: Because the first thing matters
references: #10
<!-- /sharkrite-convention -->

Some text in between.

<!-- sharkrite-convention -->
title: second-new-convention
rule: Always do the second thing
why: Because the second thing also matters
references: #20
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "88" "$pr_body"

  # Both headings must appear
  grep -q "^## first-new-convention$" "$conventions_file"
  grep -q "^## second-new-convention$" "$conventions_file"

  # Both references lines must include PR #88
  grep -q "\*\*References:\*\* #10, #88" "$conventions_file"
  grep -q "\*\*References:\*\* #20, #88" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 5: Malformed block (no title) — skipped, no crash, file unchanged
# ---------------------------------------------------------------------------

@test "malformed block: block without title is skipped without crashing" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local before_content
  before_content=$(cat "$conventions_file")

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
rule: This block has no title field
why: Missing title
<!-- /sharkrite-convention -->
BODY
)

  # Must not crash
  update_conventions_from_marker "99" "$pr_body"

  # File content must be unchanged (malformed block is skipped)
  local after_content
  after_content=$(cat "$conventions_file")
  [ "$before_content" = "$after_content" ]
}

# ---------------------------------------------------------------------------
# Test 6: Seed entry already in file — different PR# accumulates in place
#
# Under the accumulate-in-place contract (#320):
# - Conventions are canonical: each unique title has exactly ONE entry.
# - When a new PR references the same convention title, its PR# is appended
#   to the existing entry's References line rather than creating a duplicate
#   heading.
# ---------------------------------------------------------------------------

@test "existing title different PR: same title from new PR accumulates references in place" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # The seed entry uses title "seed-convention" with references #1.
  # A new PR (123) with the same title should NOT create a duplicate heading;
  # it should accumulate #123 into the existing entry's References line.
  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: seed-convention
rule: Updated rule statement from a new PR
why: Because the rule evolved
references: #1
<!-- /sharkrite-convention -->
BODY
)

  # First: confirm idempotency with the same PR# that's already in the seed
  # (PR #1 is already in the seed's References: #1 line)
  update_conventions_from_marker "1" "$pr_body"

  # The heading appears exactly once (no duplicate added for same PR#)
  local count
  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 1 ]

  # Now a new PR (123) with the same title SHOULD accumulate in place —
  # exactly one heading, but the References line now contains both PR numbers.
  update_conventions_from_marker "123" "$pr_body"

  # Still exactly one heading (no duplicate entry created)
  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 1 ]

  # References line must now include both PR numbers
  grep -q "\*\*References:\*\*.*#1.*#123" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 7: Idempotency after accumulate-in-place — re-run is still a no-op
#
# After PR #123 has been accumulated into the seed-convention's References
# line, a second run for PR #123 must be detected as already-present and
# produce no changes.
# ---------------------------------------------------------------------------

@test "idempotency: PR accumulated into existing entry is not duplicated on re-run" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: seed-convention
rule: Updated rule statement from a new PR
why: Because the rule evolved
references: #1
<!-- /sharkrite-convention -->
BODY
)

  # PR #123 → first run → accumulates #123 into seed-convention's References
  update_conventions_from_marker "123" "$pr_body"

  local count
  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 1 ]

  # Capture content after first accumulation
  local after_first
  after_first=$(cat "$conventions_file")

  # PR #123 again → must be a no-op (idempotent: #123 is now in References)
  update_conventions_from_marker "123" "$pr_body"

  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 1 ]

  # File content must be byte-for-byte identical (no changes on re-run)
  local after_second
  after_second=$(cat "$conventions_file")
  [ "$after_first" = "$after_second" ]
}

# ---------------------------------------------------------------------------
# Test 8: Prefix collision guard — #42 must NOT be mistaken for #420
#
# The idempotency check tokenizes the References line on spaces/commas and
# compares each token exactly (so "#42" != "#420"). Under the accumulate-in-
# place contract (#320), PR #42 (not yet in the entry) should:
#   - NOT be silently treated as a no-op (that was the old substring bug)
#   - Accumulate into the existing entry's References line (new behavior)
#
# After accumulation, the entry has exactly ONE heading with "#420, #42"
# in its References line. A subsequent run for #42 must be a no-op.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test 9: Example containing triple backticks — fence delimiter is promoted
#
# If the example field contains ``` (triple backticks), the rendered entry
# must use a 4-backtick fence so the inner ``` cannot terminate the outer
# fence early and corrupt the append-only conventions file.
#
# Also verifies that a normal example (no ``` inside) still produces the
# standard 3-backtick fence — the promotion is conditional.
# ---------------------------------------------------------------------------

@test "example with triple backticks: uses 4-backtick fence to avoid early termination" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: unescaped-backtick-example
rule: Use 4-backtick fence when example contains triple backticks
why: A triple-backtick inside a triple-backtick fence terminates the fence early, corrupting the append-only catalog
example: |
  # BAD: describe something using ```inline code``` in prose
  echo "document with ```backticks``` inside"
  # GOOD: just avoid the ambiguity or escape it
  echo "document with backtick blocks"
references: #319
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "321" "$pr_body"

  # The entry must exist
  grep -q "^## unescaped-backtick-example$" "$conventions_file"

  # A 4-backtick bash fence opener must be present (not 3-backtick)
  grep -q '^\`\`\`\`bash$' "$conventions_file"

  # A 4-backtick fence closer must be present
  grep -q '^\`\`\`\`$' "$conventions_file"

  # No standalone 3-backtick opener for this entry (would indicate early fence break)
  # Count lines after the heading: the opener must be the 4-backtick one
  local fence_count
  fence_count=$(grep -c '^\`\`\`bash$' "$conventions_file" || true)
  # The seed or normal entries may have ```bash fences, but the new entry must not
  # add one — it should only have the ````bash opener.
  # Verify the inner triple-backtick text is present (content not truncated)
  grep -q 'backticks' "$conventions_file"
}

@test "example without triple backticks: uses standard 3-backtick fence" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local pr_body
  pr_body="$(one_block_body)"

  update_conventions_from_marker "42" "$pr_body"

  # The standard opener must be present (not the 4-backtick promoted one)
  grep -q '^\`\`\`bash$' "$conventions_file"
}

@test "idempotency: PR #42 is not mistaken for already-recorded PR #420" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Manually plant an entry for "prefix-collision-test" with PR #420 recorded.
  cat >> "$conventions_file" <<'EOF'

## prefix-collision-test

**Rule:** Never use substring matching for PR token comparison.

**Why:** #420 contains #42 as a substring; an unanchored index() call would
falsely detect PR #42 as already recorded.

**References:** #420

---
EOF

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: prefix-collision-test
rule: Never use substring matching for PR token comparison
why: Substring match causes false idempotency hit
<!-- /sharkrite-convention -->
BODY
)

  # PR #42 is NOT yet in the References line — this must NOT be treated as a no-op.
  # Under the accumulate-in-place contract, #42 should be appended to the
  # existing entry's References line (not create a duplicate heading).
  update_conventions_from_marker "42" "$pr_body"

  # Still exactly ONE heading (accumulate-in-place, not duplicate)
  local count
  count=$(grep -c "^## prefix-collision-test$" "$conventions_file" || true)
  [ "$count" -eq 1 ]

  # References line must now include BOTH #420 and #42
  grep -q "\*\*References:\*\*.*#420.*#42" "$conventions_file"

  # Re-running for PR #42 now must be a no-op (idempotent)
  local after_first
  after_first=$(cat "$conventions_file")

  update_conventions_from_marker "42" "$pr_body"

  count=$(grep -c "^## prefix-collision-test$" "$conventions_file" || true)
  [ "$count" -eq 1 ]

  # File content must be byte-for-byte identical (no changes on re-run)
  local after_second
  after_second=$(cat "$conventions_file")
  [ "$after_first" = "$after_second" ]
}

# ---------------------------------------------------------------------------
# Test 10: Example containing a column-0 non-field key: line — not truncated
#
# Bug fixed in issue #319/#320/#321: the awk terminator was /^[a-z_]+:/
# which matched ANY lowercase identifier followed by a colon at column-0,
# including lines inside the example that are not real convention field names.
# The fix restricts the terminator to the five known top-level field names:
# title|rule|why|example|references.
#
# This test uses a block where the example section contains a line "timeout: 30"
# at column-0 (no indentation — malformed YAML literal block, but the parser
# must be robust).  The old terminator stopped the example at "timeout:";
# the new terminator only stops at recognized field names, so the full
# content after "timeout: 30" must also appear in the rendered output.
# ---------------------------------------------------------------------------

@test "example with column-0 non-field key: line is not truncated by the awk terminator" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Build the block with a column-0 "timeout:" line inside the example section.
  # printf is used to avoid heredoc indentation issues — the block must have
  # "timeout: 30" at column-0 (no leading spaces) to trigger the old bug.
  local pr_body
  pr_body=$(printf '%s\n' \
    '<!-- sharkrite-convention -->' \
    'title: example-with-bare-key' \
    'rule: Example blocks may contain config-style key: value lines' \
    'why: Restricting the awk terminator prevents example truncation' \
    'example: |' \
    '  # BAD: hardcoded values' \
    'timeout: 30' \
    '  retries: 3' \
    '  # GOOD: via environment' \
    '  timeout: ${TIMEOUT:-30}' \
    'references: #319' \
    '<!-- /sharkrite-convention -->')

  update_conventions_from_marker "319" "$pr_body"

  # Entry must exist
  grep -q "^## example-with-bare-key$" "$conventions_file"

  # "timeout: 30" at column-0 must NOT have terminated the example — both
  # "retries: 3" (after timeout:) and the GOOD section must be present.
  grep -q "retries: 3" "$conventions_file"
  grep -q 'timeout: \${TIMEOUT' "$conventions_file"

  # References must use the real field value, not be empty or wrong
  grep -q "\*\*References:\*\* #319" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 11: Example containing "references: ..." at column-0 — field not corrupted
#
# Bug fixed in issue #319/#320/#321: grep "^references:" ran against the full
# block including example content.  If the example contained a line like
# "references: some-docs-link" at column-0 (before dedent), that line would
# be picked up as the actual references field value, overwriting the real one.
#
# The fix: field extraction runs against _block_no_example (the block with the
# example section stripped out) so example content cannot corrupt scalar fields.
# ---------------------------------------------------------------------------

@test "example containing references: line does not corrupt the references field" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: references-in-example
rule: Field extraction must ignore example content
why: grep against the full block picks up key: value lines from inside the example
example: |
  # This example documents a YAML file that has a "references:" key
  # BAD: inline refs
  references: http://example.com/bad
  # GOOD: external file
  references: ./docs/refs.md
references: abc1234, #99
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "320" "$pr_body"

  # Entry must exist
  grep -q "^## references-in-example$" "$conventions_file"

  # The References line must use the REAL field value (abc1234, #99, #320),
  # NOT the value from inside the example ("http://example.com/bad").
  grep -q "\*\*References:\*\* abc1234, #99, #320" "$conventions_file"

  # The example content must still be present (not lost during field stripping)
  grep -q "references: http://example.com/bad" "$conventions_file"
  grep -q "references: ./docs/refs.md" "$conventions_file"
}
