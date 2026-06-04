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
# Test 6: Seed entry already in file — different PR# appends new entry
# ---------------------------------------------------------------------------

@test "existing title different PR: same title from new PR appends a second entry" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # The seed entry uses title "seed-convention" with references #1.
  # A new PR (123) with the same title is NOT a duplicate (different PR#) —
  # the function only skips when title AND PR# both match.
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

  # Now a new PR (123) with the same title SHOULD add another entry
  update_conventions_from_marker "123" "$pr_body"

  # Two instances of the heading now
  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test 7: Idempotency for PR recorded in a LATER same-title entry (regression)
#
# When multiple entries share the same title (allowed — different PRs), a
# re-run for a PR that was recorded in the *second* (or later) entry must
# still be detected as a no-op. The old awk exited on the first entry's
# heading match and never scanned forward to later entries with the same
# title, causing an unbounded duplicate to be appended.
# ---------------------------------------------------------------------------

@test "idempotency: PR in second same-title entry is not duplicated on re-run" {
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

  # PR #123 → first run → appends second entry for seed-convention
  update_conventions_from_marker "123" "$pr_body"

  local count
  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 2 ]

  # PR #123 again → must be a no-op (PR #123 is now in the *second* entry)
  update_conventions_from_marker "123" "$pr_body"

  count=$(grep -c "^## seed-convention$" "$conventions_file" || true)
  [ "$count" -eq 2 ]
}
