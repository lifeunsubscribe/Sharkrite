#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
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
#  14. Fenced code block guard: marker inside ``` ... ``` is not extracted
#  15. Fenced code block guard: real marker after a fence IS still extracted
#  20. Bug1 fix: real block with col-0 code fence in example is NOT truncated
#  21. Bug1 fix: real block with multiple col-0 code fences in example extracts fully
#  22. Bug2 fix: marker inside 4-backtick fence with inner 3-backtick is NOT extracted
#  23. Bug2 fix: real block after 4-backtick fence with inner 3-backtick IS extracted

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

  # Source tag-index.sh so update_tag_index_from_block() is available.
  # update_conventions_from_marker() calls it directly; without this source
  # the function is undefined and the test would crash.
  source "${RITE_REPO_ROOT}/lib/utils/tag-index.sh"

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

  # The 3-backtick bash opener must NOT be present.
  # This entry's example contains ``` sequences; if the fence promotion logic
  # failed and used a 3-backtick fence, a ```bash opener would appear in the
  # file and the inner ``` would terminate the fence early.
  run grep '^\`\`\`bash$' "$conventions_file"
  [ "$status" -ne 0 ]

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

# ---------------------------------------------------------------------------
# Test: Example containing 4 consecutive backticks — fence promoted to 5
#
# The previous hard-cap at 4 backticks failed when the example itself
# contained a 4-backtick sequence (e.g. a ````code```` span). This test
# verifies that the fence is dynamically promoted to 5 backticks so the
# inner 4-backtick sequence cannot close the outer fence early.
# ---------------------------------------------------------------------------

@test "example with 4 consecutive backticks: fence promoted to 5 backticks" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: four-backtick-example
rule: Fence length must exceed the longest backtick run in the example
why: A 4-backtick fence is terminated by any 4-backtick sequence inside the content
example: |
  # BAD: using a 4-backtick code span inside a 4-backtick fence
  ```` inline code span ````
  # GOOD: use the appropriate fence length dynamically
  echo "no ambiguity"
references: #395
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "395" "$pr_body"

  # The entry must exist
  grep -q "^## four-backtick-example$" "$conventions_file"

  # A 5-backtick bash fence opener must be present (promoted past 4)
  grep -q '^\`\`\`\`\`bash$' "$conventions_file"

  # A 5-backtick fence closer must be present
  grep -q '^\`\`\`\`\`$' "$conventions_file"

  # The 4-backtick content must be preserved inside the fence (not truncated)
  grep -q 'inline code span' "$conventions_file"

  # A 3-backtick bash opener must NOT be present — the seed convention has no
  # example, so any ```bash line in the file came from this entry.  If present,
  # the fence was under-promoted (3 backticks instead of 5).
  run grep '^\`\`\`bash$' "$conventions_file"
  [ "$status" -ne 0 ]

  # A 4-backtick bash opener must NOT be present — the example contains a
  # 4-backtick run, so a ````bash fence would be terminated by it prematurely.
  run grep '^\`\`\`\`bash$' "$conventions_file"
  [ "$status" -ne 0 ]

  # The references line must be correct
  grep -q '\*\*References:\*\* #395' "$conventions_file"
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

# ---------------------------------------------------------------------------
# Test 12: example: block precedes real field, column-0 field name inside
#          example must NOT overwrite the real scalar field
#
# This is the field-stripping asymmetry bug: _no_example_awk previously
# terminated the skip on ANY non-indented line, so a column-0 "references:"
# or "rule:" inside the example would leak into _block_no_example.  When the
# example block appears BEFORE the real field, head -1 picks the example's
# value instead of the real one.
#
# The fix (issue #328): _no_example_awk now terminates the skip only on the
# same known-field-name boundary used by _example_awk
# (title|rule|why|example|references), matching the behavior documented in the
# comment at assess-documentation.sh:570.
# ---------------------------------------------------------------------------

@test "example before real field: column-0 field name in example does not corrupt scalar field" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Build a block where:
  #   - example: appears BEFORE the real references: field
  #   - the example contains a column-0 "references: fake-value" line
  #   - the real references: field follows after the example
  # printf is used so the column-0 line has no leading whitespace.
  local pr_body
  pr_body=$(printf '%s\n' \
    '<!-- sharkrite-convention -->' \
    'title: example-before-real-field' \
    'rule: Field stripping must use field-name boundary not indentation boundary' \
    'why: Indentation-only boundary leaks column-0 lines from example into scalar extraction' \
    'example: |' \
    '  # A YAML snippet that has a column-0 references: key (no indent):' \
    'references: fake-doc-link' \
    '  # The real field below must not be overwritten by this line' \
    'references: real-ref-value, #328' \
    '<!-- /sharkrite-convention -->')

  update_conventions_from_marker "328" "$pr_body"

  # Entry must exist
  grep -q "^## example-before-real-field$" "$conventions_file"

  # The References line must use the REAL field value, not the fake one from
  # inside the example.
  grep -q "\*\*References:\*\* real-ref-value, #328" "$conventions_file"

  # The fake value must NOT appear in the References rendered line
  run grep "\*\*References:\*\*.*fake-doc-link" "$conventions_file"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test 13: Auto-bootstrap — conventions.md is created when missing IF a PR
# body contains a marker block. Projects without sharkrite-convention markers
# never trigger creation (verified separately by removing the seed file and
# running with a no-marker body — see end of this test).
# ---------------------------------------------------------------------------

@test "auto-bootstrap: missing conventions.md is created when a marker block exists" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Remove the seed file so the bootstrap path is exercised
  rm -f "$conventions_file"
  [ ! -f "$conventions_file" ]

  local pr_body
  pr_body="$(one_block_body)"
  update_conventions_from_marker "42" "$pr_body"

  # File must now exist
  [ -f "$conventions_file" ]

  # Scaffold header must be present
  grep -q "^# Conventions Catalog$" "$conventions_file"

  # The marker block from the PR must have been appended
  grep -q "^## no-eval-on-gh-data$" "$conventions_file"
  grep -q "\*\*References:\*\* abc1234, #99, #42" "$conventions_file"
}

@test "auto-bootstrap: missing conventions.md is NOT created when PR body has no marker" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Remove the seed file
  rm -f "$conventions_file"

  local pr_body="This PR fixes a thing. No conventions here. Closes #77"
  update_conventions_from_marker "77" "$pr_body"

  # File must still not exist (no marker → no bootstrap → no empty file in repo)
  [ ! -f "$conventions_file" ]
}

# ---------------------------------------------------------------------------
# Tag extraction tests (Stage 2)
#
# These tests verify that update_conventions_from_marker() also extracts the
# `tags:` and `new-tags:` fields from convention blocks and writes the
# corresponding pointers into docs/architecture/tag-index.md.
# ---------------------------------------------------------------------------

# Helper: build a PR body with a convention block that has a tags: field
tagged_block_body() {
  cat <<'BODY'
<!-- sharkrite-convention -->
title: tagged-convention-example
rule: Always declare tags for new conventions
why: Tags enable the tag-index routing system to load relevant prior art
tags: set-e, subshell
references: #50
<!-- /sharkrite-convention -->
BODY
}

# Helper: PR body with a new-tags: justification for a brand-new tag
new_tag_block_body() {
  cat <<'BODY'
<!-- sharkrite-convention -->
title: new-tag-convention-example
rule: New tags must be justified in new-tags:
why: Forces explicit reasoning for expanding the tag vocabulary
tags: brand-new-tag
new-tags:
  - brand-new-tag: Covers patterns related to this brand-new concept
references: #60
<!-- /sharkrite-convention -->
BODY
}

# ---------------------------------------------------------------------------
# Test 14: tags: field → tag-index.md headings and pointers are created
# ---------------------------------------------------------------------------

@test "tags: field creates headings and pointers in tag-index.md" {
  local tag_index_file="${RITE_TEST_TMPDIR}/docs/architecture/tag-index.md"
  local pr_body
  pr_body="$(tagged_block_body)"

  # Pre-populate tag-index.md with the tags that the block references
  cat > "$tag_index_file" <<'EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## set-e

## subshell

EOF

  update_conventions_from_marker "50" "$pr_body"

  # Both tag sections must have pointers to conventions.md → tagged-convention-example
  # (use -F not -xF: BSD grep on macOS chokes on -xF with multi-byte UTF-8 chars like →)
  grep -qF "conventions.md → tagged-convention-example" "$tag_index_file"

  # The pointer must appear under the correct heading
  # Check that "set-e" section contains the pointer
  awk '/^## set-e/{found=1} found && /conventions.md.*tagged-convention-example/{exit 0} found && /^## / && !/^## set-e/{exit 1}' \
    "$tag_index_file"

  # Check that "subshell" section contains the pointer
  awk '/^## subshell/{found=1} found && /conventions.md.*tagged-convention-example/{exit 0} found && /^## / && !/^## subshell/{exit 1}' \
    "$tag_index_file"
}

# ---------------------------------------------------------------------------
# Test 15: Pointer accumulation is idempotent — running twice does not duplicate
# ---------------------------------------------------------------------------

@test "tag pointer accumulation is idempotent: re-running same PR does not duplicate pointers" {
  local tag_index_file="${RITE_TEST_TMPDIR}/docs/architecture/tag-index.md"
  local pr_body
  pr_body="$(tagged_block_body)"

  cat > "$tag_index_file" <<'EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## set-e

## subshell

EOF

  # First run
  update_conventions_from_marker "50" "$pr_body"

  # Second run — must be a no-op for tag-index
  update_conventions_from_marker "50" "$pr_body"

  # Each pointer must appear exactly once
  local count
  count=$(grep -c "conventions.md → tagged-convention-example" "$tag_index_file" || true)
  # One pointer per tag section (2 tags), but each should appear exactly once per section
  # set-e section: 1 pointer; subshell section: 1 pointer → total 2 lines with the pointer text
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test 16: new-tags: field creates a new heading in tag-index.md
# ---------------------------------------------------------------------------

@test "new-tags: field auto-creates the corresponding heading in tag-index.md" {
  local tag_index_file="${RITE_TEST_TMPDIR}/docs/architecture/tag-index.md"
  local pr_body
  pr_body="$(new_tag_block_body)"

  # tag-index.md does NOT have "brand-new-tag" yet
  cat > "$tag_index_file" <<'EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

EOF

  update_conventions_from_marker "60" "$pr_body"

  # The new tag heading must have been created
  grep -qxF "## brand-new-tag" "$tag_index_file"

  # A pointer must exist under the new heading
  # (use -F not -xF: BSD grep on macOS chokes on -xF with multi-byte UTF-8 chars like →)
  grep -qF "conventions.md → new-tag-convention-example" "$tag_index_file"
}

# ---------------------------------------------------------------------------
# Test 17: tag-index.md auto-bootstrapped when missing
# ---------------------------------------------------------------------------

@test "tag-index.md is auto-created when missing and a tagged convention block is processed" {
  local tag_index_file="${RITE_TEST_TMPDIR}/docs/architecture/tag-index.md"
  local pr_body
  pr_body="$(new_tag_block_body)"

  # Ensure it does not exist
  rm -f "$tag_index_file"
  [ ! -f "$tag_index_file" ]

  update_conventions_from_marker "60" "$pr_body"

  # tag-index.md must now exist
  [ -f "$tag_index_file" ]

  # Bootstrap header must be present
  grep -q "^# Tag Index$" "$tag_index_file"

  # The new tag heading must have been created
  grep -qxF "## brand-new-tag" "$tag_index_file"

  # A pointer must exist under the new heading
  # (use -F not -xF: BSD grep on macOS chokes on -xF with multi-byte UTF-8 chars like →)
  grep -qF "conventions.md → new-tag-convention-example" "$tag_index_file"
}

# ---------------------------------------------------------------------------
# Test 18: Convention block without tags: leaves tag-index.md unchanged
# ---------------------------------------------------------------------------

@test "convention block without tags: field leaves tag-index.md unchanged" {
  local tag_index_file="${RITE_TEST_TMPDIR}/docs/architecture/tag-index.md"
  cat > "$tag_index_file" <<'EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

EOF
  local before_content
  before_content=$(cat "$tag_index_file")

  # Use the original one_block_body which has no tags: field
  local pr_body
  pr_body="$(one_block_body)"
  update_conventions_from_marker "42" "$pr_body"

  local after_content
  after_content=$(cat "$tag_index_file")
  [ "$before_content" = "$after_content" ]
}

# Test 14: Fenced code block guard — marker inside ``` is not extracted
#
# PR bodies that document the convention format (e.g. "To add a convention,
# include a block like this: ```...```") contain real <!-- sharkrite-convention
# --> lines inside a fenced code block.  Without a fence guard the extractor
# would ingest those template lines as a real convention block, creating a
# spurious catalog entry (e.g. "## Your convention title").
#
# The fix: the AWK extractor tracks in_fence and skips all lines inside
# ``` ... ``` fences, so the marker is treated as literal text rather than
# an extraction trigger.
# ---------------------------------------------------------------------------

@test "fenced code block: marker inside backtick fence is not extracted" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # PR body that documents the convention format with the marker inside a fence.
  # This mirrors what a documentation PR or a CLAUDE.md update PR body would look
  # like — the template example is fenced, not a real convention block.
  local pr_body
  pr_body=$(cat <<'BODY'
This PR updates the documentation to explain the self-documenting convention format.

To add a convention, include a block like this in your PR body:

```
<!-- sharkrite-convention -->
title: Your convention title
rule: One-sentence statement of the rule
why: Why this rule exists
example: |
  # BAD
  ...
  # GOOD
  ...
references: <commit-sha>, #<issue>, #<pr>
<!-- /sharkrite-convention -->
```

The merge automation extracts the block and appends a rendered entry.
BODY
)

  update_conventions_from_marker "400" "$pr_body"

  # The template title must NOT appear in conventions.md — it is inside a fence
  run grep "^## Your convention title$" "$conventions_file"
  [ "$status" -ne 0 ]

  # conventions.md must be unchanged (no new entries beyond the seed)
  run grep "^## " "$conventions_file"
  [ "$status" -eq 0 ]
  # Only the seed entry should be present
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "## seed-convention" ]
}

@test "fenced code block: real marker after fence is still extracted" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # PR body with a fenced template example AND a real convention block after it.
  # The fenced block must be skipped; the real block must be extracted.
  local pr_body
  pr_body=$(cat <<'BODY'
This PR adds a new convention and documents the format.

Template (do not extract):

```
<!-- sharkrite-convention -->
title: Template title — do not extract
rule: This is only a template example
why: Documentation of the format
references: #0
<!-- /sharkrite-convention -->
```

Real convention block below (DO extract):

<!-- sharkrite-convention -->
title: fenced-guard-real-block
rule: Markers inside fenced code blocks must not be extracted
why: PR bodies that document the format would otherwise produce spurious catalog entries
references: abc1234, #401
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "401" "$pr_body"

  # The template title (inside the fence) must NOT appear
  run grep "^## Template title" "$conventions_file"
  [ "$status" -ne 0 ]

  # The real convention title (outside the fence) MUST appear
  grep -q "^## fenced-guard-real-block$" "$conventions_file"
  grep -q "\*\*References:\*\* abc1234, #401" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 19: col-0 known-field-name inside example — tail -1 correctness and
#          truncation boundary are both documented and tested
#
# The "KNOWN ASYMMETRY" in assess-documentation.sh:
#   (a) _example_awk terminates the example at the col-0 known-field-name line —
#       example content that follows is silently lost (truncated).
#   (b) _no_example_awk treats the same col-0 line as a real scalar field and
#       prints it into _block_no_example.
#
# For `references:` this is benign because `tail -1` selects the last
# occurrence (the real field that follows the example), not the first
# (the fake value from inside the example).
#
# This test explicitly asserts both behaviors:
#   1. The references scalar field uses the REAL value (tail -1 correctness).
#   2. Example content that follows the col-0 field-name IS truncated
#      (known limitation — lines after the col-0 field-name do not appear
#      in the rendered example section).
# ---------------------------------------------------------------------------

@test "col-0 field name in example: tail -1 selects real references, example is truncated after the col-0 line" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Build a block where:
  #   - The example contains a col-0 "references: fake" line mid-example
  #   - More example content follows (AFTER-TRUNCATION-MARKER)
  #   - The real references: field comes last
  # printf is used so the col-0 line has exactly no leading whitespace.
  local pr_body
  pr_body=$(printf '%s\n' \
    '<!-- sharkrite-convention -->' \
    'title: col-zero-field-in-example' \
    'rule: Scalar field correctness depends on tail -1, not field-name boundary' \
    'why: _no_example_awk leaks col-0 field names from inside the example into _block_no_example' \
    'example: |' \
    '  # BEFORE: content before the col-0 fake field line' \
    'references: fake-value-inside-example' \
    '  # AFTER: content after the col-0 fake field line (silently truncated)' \
    'references: real-ref-value, #397' \
    '<!-- /sharkrite-convention -->')

  update_conventions_from_marker "397" "$pr_body"

  # Entry must exist
  grep -q "^## col-zero-field-in-example$" "$conventions_file"

  # --- correctness assertion: tail -1 picks the real field ---
  # The References line must use the REAL field value, not the fake embedded one.
  grep -q "\*\*References:\*\* real-ref-value, #397" "$conventions_file"

  # The fake value must NOT appear in the rendered References line.
  run grep "\*\*References:\*\*.*fake-value-inside-example" "$conventions_file"
  [ "$status" -ne 0 ]

  # --- truncation assertion: example content after col-0 field is lost ---
  # "BEFORE" content (before the col-0 fake field) IS in the rendered example.
  grep -q "BEFORE: content before the col-0 fake field line" "$conventions_file"

  # "AFTER" content (after the col-0 fake field) is NOT in the rendered example
  # because _example_awk terminates the example at the col-0 known-field-name.
  # This is the KNOWN LIMITATION documented in the source code comment.
  run grep "AFTER: content after the col-0 fake field line" "$conventions_file"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test 20 (Bug 1 fix): Real convention block with column-0 code fence in
# example — block is NOT truncated (fence guard does not fire inside block)
#
# Bug: The original fence guard `/^```/ { in_fence = !in_fence; next }` fired
# unconditionally.  When a real convention block's example field contained a
# column-0 ``` fence, the guard toggled in_fence while in_block=1, causing
# subsequent lines (including the close marker) to be skipped.  The block was
# never emitted — silently truncated.
#
# Fix: Convention block content is accumulated BEFORE the fence guard, so the
# guard never fires when in_block=1.
# ---------------------------------------------------------------------------

@test "Bug1: real block with col-0 code fence in example is NOT truncated" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # Convention block whose example field contains a column-0 ``` fence.
  # The original fence guard would toggle in_fence at the ``` line inside
  # the block, causing the close marker to be skipped and the block to be lost.
  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: col-zero-fence-in-example
rule: Convention blocks with column-0 code fences must be fully extracted
why: The fence guard must not fire inside a convention block
example: |
  # BAD: unguarded grep
  COUNT=$(echo "$text" | grep -c "pattern")
```bash
  # This inner fence is at column-0 inside the example
  COUNT=$(echo "$text" | grep -c "pattern" || true)
```
  # GOOD: guarded
  COUNT=$(echo "$text" | grep -c "pattern" || true)
references: #429
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "429" "$pr_body"

  # The entry MUST exist (block was not truncated)
  grep -q "^## col-zero-fence-in-example$" "$conventions_file"

  # Content before the column-0 fence must be present
  grep -q "unguarded grep" "$conventions_file"

  # Content from inside the column-0 fence must be present (not skipped)
  grep -q "inner fence is at column-0" "$conventions_file"

  # Content after the column-0 fence must be present (not dropped)
  grep -q "GOOD: guarded" "$conventions_file"

  # References must be correct
  grep -q "\*\*References:\*\* #429" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 21 (Bug 1 fix): Real convention block ends correctly even when its
# example contains MULTIPLE column-0 code fences
#
# Verifies that the fence guard does not interleave state with in_block
# for a block that has paired (open+close) column-0 fences in the example.
# ---------------------------------------------------------------------------

@test "Bug1: real block with multiple col-0 fences in example extracts fully" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  local pr_body
  pr_body=$(cat <<'BODY'
<!-- sharkrite-convention -->
title: multi-col-zero-fences-in-example
rule: Paired column-0 fences inside example do not corrupt extraction
why: Both the opening and closing fence are inside the block and must be captured
example: |
  # BEFORE-FIRST-FENCE
```
  first inner fence content
```
  # BETWEEN-FENCES
```bash
  second inner fence content
```
  # AFTER-LAST-FENCE
references: #430
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "430" "$pr_body"

  # The entry MUST exist
  grep -q "^## multi-col-zero-fences-in-example$" "$conventions_file"

  # Content from each section must be present
  grep -q "BEFORE-FIRST-FENCE" "$conventions_file"
  grep -q "first inner fence content" "$conventions_file"
  grep -q "BETWEEN-FENCES" "$conventions_file"
  grep -q "second inner fence content" "$conventions_file"
  grep -q "AFTER-LAST-FENCE" "$conventions_file"

  grep -q "\*\*References:\*\* #430" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 22 (Bug 2 fix): Convention marker inside a 4-backtick fence is NOT
# extracted (4-backtick fence closes correctly, guard is not prematurely
# turned off by an inner 3-backtick sequence)
#
# Bug: The original /^```/ pattern toggled in_fence for ANY line starting
# with 3+ backticks.  A 4-backtick outer fence containing an unindented
# 3-backtick inner sequence would turn in_fence OFF at the inner ```, causing
# lines after it (including a convention marker) to be processed as top-level
# content and spuriously extracted.
#
# Fix: Track fence_len so only a fence of >= opening length closes the block.
# ---------------------------------------------------------------------------

@test "Bug2: marker inside 4-backtick fence with inner 3-backtick is NOT extracted" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # PR body where the convention template is inside a 4-backtick fence.
  # The fence contains an inner ``` sequence that would confuse the original guard.
  local pr_body
  pr_body=$(cat <<'BODY'
This PR documents the convention format using a 4-backtick fence:

````markdown
Here is a code block inside the documentation:

```
some code here
```

<!-- sharkrite-convention -->
title: Spurious extraction title — must NOT appear
rule: This must not be extracted
why: It is inside a 4-backtick fence
references: #0
<!-- /sharkrite-convention -->
````

The above is just documentation.
BODY
)

  update_conventions_from_marker "433" "$pr_body"

  # The spurious title must NOT appear in conventions.md
  run grep "^## Spurious extraction title" "$conventions_file"
  [ "$status" -ne 0 ]

  # conventions.md must be unchanged (no new entries beyond the seed)
  local count
  count=$(grep -c "^## " "$conventions_file" || true)
  [ "$count" -eq 1 ]
  grep -q "^## seed-convention$" "$conventions_file"
}

# ---------------------------------------------------------------------------
# Test 23 (Bug 2 fix): Real convention block AFTER a 4-backtick fence (that
# contains an inner 3-backtick) is still correctly extracted
#
# Verifies that the fence state is fully reset after the 4-backtick fence
# closes, so real convention blocks that follow it are not lost.
# ---------------------------------------------------------------------------

@test "Bug2: real block after 4-backtick fence with inner 3-backtick IS extracted" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  local pr_body
  pr_body=$(cat <<'BODY'
Documentation section (4-backtick fence, do not extract):

````markdown
```
code inside the documentation fence
```
<!-- sharkrite-convention -->
title: Should NOT be extracted (in 4-backtick fence)
<!-- /sharkrite-convention -->
````

Real convention block (DO extract):

<!-- sharkrite-convention -->
title: real-after-4-backtick-fence
rule: Blocks after a properly-closed 4-backtick fence must be extracted
why: Fence state must be fully reset after close
references: #434
<!-- /sharkrite-convention -->
BODY
)

  update_conventions_from_marker "434" "$pr_body"

  # The spurious (fenced) title must NOT appear
  run grep "^## Should NOT be extracted" "$conventions_file"
  [ "$status" -ne 0 ]

  # The real convention block (outside the fence) MUST appear
  grep -q "^## real-after-4-backtick-fence$" "$conventions_file"
  grep -q "\*\*References:\*\* #434" "$conventions_file"
}
