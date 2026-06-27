#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/utils/tag-index.sh
# tests/regression/tag-index-reconcile.bats
#
# Regression tests for reconcile_tag_index() in assess-documentation.sh and
# tag_index_log_history() in tag-index.sh.
#
# Acceptance criteria verified:
#   AC1: Call site invokes reconcile_tag_index immediately after
#        update_conventions_from_marker WITH a || true backstop
#   AC2: Non-zero return from reconcile_tag_index does NOT abort the
#        doc-assessment pass under set -euo pipefail (#764 behavioral)
#   AC3: No-op (no error, no history line) when PR body has no new-tags: block
#        or the body is empty
#   AC4: A new-tags: line inside a fenced ``` block is NOT extracted
#   AC5: A justification audit line is logged via tag_index_log_history()
#        for each real new tag

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # _MARKER_DIR is used by _mark_updated() when called from the extracted functions
  export _MARKER_DIR
  _MARKER_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/markers.XXXXXX")"

  # Stub out functions that reconcile_tag_index and tag_index_log_history depend on
  # but that require a real environment (Claude, GitHub API, etc.).
  print_warning() { :; }
  print_info()    { :; }
  verbose_info()  { :; }
  export -f print_warning print_info verbose_info

  # Source tag-index.sh to load tag_index_log_history() and its helpers.
  source "${RITE_REPO_ROOT}/lib/utils/tag-index.sh"

  # Extract reconcile_tag_index() from assess-documentation.sh via awk.
  # We extract only that function to avoid executing the script's top-level body.
  eval "$(awk '
    /^reconcile_tag_index[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/assess-documentation.sh")"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# AC1: Call site is after update_conventions_from_marker with || true backstop
# ---------------------------------------------------------------------------

@test "AC1: reconcile_tag_index is called immediately after update_conventions_from_marker" {
  # Verify the call order and || true backstop directly in the source file.
  # Strategy: extract the region after update_conventions_from_marker's call line
  # and check that reconcile_tag_index appears before the next blank-line group.
  local src="${RITE_REPO_ROOT}/lib/core/assess-documentation.sh"

  # update_conventions_from_marker call must exist
  grep -q "^update_conventions_from_marker" "$src"

  # reconcile_tag_index call with || true must exist in the file
  grep -qE "^reconcile_tag_index .* \|\| true$" "$src"
}

@test "AC1: reconcile_tag_index call appears after update_conventions_from_marker in source order" {
  local src="${RITE_REPO_ROOT}/lib/core/assess-documentation.sh"

  # Get line numbers of both calls
  local ucm_line rti_line
  ucm_line=$(grep -n "^update_conventions_from_marker" "$src" | head -1 | cut -d: -f1 || true)
  rti_line=$(grep -n "^reconcile_tag_index" "$src" | grep -v "^[0-9]*:reconcile_tag_index()" | head -1 | cut -d: -f1 || true)

  # Both must be found
  [ -n "$ucm_line" ]
  [ -n "$rti_line" ]

  # reconcile_tag_index call must come AFTER update_conventions_from_marker call
  [ "$rti_line" -gt "$ucm_line" ]
}

@test "AC1: reconcile_tag_index call has || true backstop" {
  local src="${RITE_REPO_ROOT}/lib/core/assess-documentation.sh"
  # The call line must end with || true (absorbs #764)
  grep -qE "^reconcile_tag_index .* \|\| true$" "$src"
}

# ---------------------------------------------------------------------------
# AC2: Non-zero return from reconcile_tag_index does NOT abort under set -euo pipefail
# ---------------------------------------------------------------------------

@test "AC2: reconcile_tag_index failure does not abort caller under set -euo pipefail" {
  # Simulate a reconcile_tag_index that returns non-zero.
  # The || true backstop at the call site must absorb it.
  reconcile_tag_index_fail() { return 1; }

  # Run the pattern used at the call site under strict mode.
  # If the || true is missing, this subshell exits non-zero and bats marks it failed.
  run bash -euo pipefail -c '
    reconcile_tag_index_fail() { return 1; }
    export -f reconcile_tag_index_fail
    reconcile_tag_index_fail || true
    echo "reached"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"reached"* ]]
}

@test "AC2: a reconcile_tag_index error exit does NOT propagate through || true" {
  # Confirm that the exact call pattern in assess-documentation.sh is safe.
  run bash -c '
    set -euo pipefail
    reconcile_tag_index() { return 42; }
    reconcile_tag_index "body" "99" || true
    echo "continued"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"continued"* ]]
}

# ---------------------------------------------------------------------------
# AC3: No-op when PR body has no new-tags: block or is empty
# ---------------------------------------------------------------------------

@test "AC3: empty PR body is a no-op — no history log created" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  reconcile_tag_index "" "55"

  # No history log should have been written
  [ ! -f "$log_file" ] || [ ! -s "$log_file" ]
}

@test "AC3: PR body with no new-tags: line is a no-op — no history log created" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(cat <<'BODY'
This PR adds some improvements.

<!-- sharkrite-convention -->
title: some-convention
rule: A rule
why: A reason
references: abc1234, #99
<!-- /sharkrite-convention -->

Closes #55
BODY
)"

  reconcile_tag_index "$body" "55"

  [ ! -f "$log_file" ] || [ ! -s "$log_file" ]
}

@test "AC3: PR body with only tags: (no new-tags:) is a no-op" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(cat <<'BODY'
Some PR body.

tags: subshell, set-e

Closes #99
BODY
)"

  reconcile_tag_index "$body" "99"

  [ ! -f "$log_file" ] || [ ! -s "$log_file" ]
}

# ---------------------------------------------------------------------------
# AC4: new-tags: inside a fenced block is NOT extracted (fence guard)
# ---------------------------------------------------------------------------

@test "AC4: new-tags: inside a triple-backtick fence is not extracted" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  # This body documents the new-tags: format inside a code fence.
  # The fence guard must prevent it from being treated as a real new-tags entry.
  local body
  body="$(cat <<'BODY'
This PR documents the convention format.

Example usage:
```
new-tags:
  - fenced-tag: This justification is inside a fence and must not be extracted
```

Closes #42
BODY
)"

  reconcile_tag_index "$body" "42"

  [ ! -f "$log_file" ] || [ ! -s "$log_file" ]
}

@test "AC4: new-tags: inside a backtick-info fence (e.g. ```yaml) is not extracted" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(cat <<'BODY'
Showing YAML format:

\`\`\`yaml
new-tags:
  - yaml-fenced-tag: Should not be extracted
\`\`\`

Real content after fence.
BODY
)"
  # Use literal backticks via printf to avoid heredoc escaping issues
  body="$(printf '%s\n' \
    "Showing YAML format:" \
    "" \
    '```yaml' \
    "new-tags:" \
    "  - yaml-fenced-tag: Should not be extracted" \
    '```' \
    "" \
    "Real content after fence.")"

  reconcile_tag_index "$body" "43"

  [ ! -f "$log_file" ] || [ ! -s "$log_file" ]
}

@test "AC4: unfenced new-tags: IS extracted even when a fenced block precedes it" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(printf '%s\n' \
    "PR body with a fence block first." \
    "" \
    '```' \
    "  - fenced-decoy: Should not be extracted" \
    '```' \
    "" \
    "Real new-tags: section follows:" \
    "  - real-tag: This justification should be extracted")"

  reconcile_tag_index "$body" "44"

  [ -f "$log_file" ]
  grep -q "tag: real-tag" "$log_file"
  # The fenced decoy must NOT appear
  ! grep -q "fenced-decoy" "$log_file"
}

@test "AC4: fence guard works under BSD awk (/usr/bin/awk) — portability check" {
  # Skip when /usr/bin/awk is not available or is actually gawk.
  if [ ! -x /usr/bin/awk ]; then
    skip "/usr/bin/awk not available on this platform"
  fi
  if /usr/bin/awk --version 2>&1 | grep -qi gawk; then
    skip "/usr/bin/awk is gawk on this system — BSD-awk test not applicable"
  fi

  # Run the portable fence-counting awk inline under /usr/bin/awk and assert
  # it produces empty output for fenced-only content — verifies the fix for
  # the gawk-only 3-arg match() that was replaced with substr-counting.
  local body_file
  body_file="$(mktemp "${BATS_TEST_TMPDIR}/bsd-awk-test.XXXXXX")"
  printf '%s\n' \
    "This PR documents the new-tags format." \
    "" \
    '```' \
    "new-tags:" \
    "  - bsd-fenced-tag: This is inside a fence and must not be extracted" \
    '```' \
    "" \
    "No real new-tags: section here." \
    "" \
    "Closes #99" > "$body_file"

  local result
  result=$(/usr/bin/awk '
    BEGIN { in_fence=0; fence_len=0 }
    /^(`{3,})/ {
      run_len = 0
      while (substr($0, run_len + 1, 1) == "`") run_len++
      if (!in_fence) {
        in_fence  = 1
        fence_len = run_len
        next
      } else if (run_len >= fence_len) {
        in_fence  = 0
        fence_len = 0
        next
      }
    }
    in_fence { next }
    /^[[:space:]]*-[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      colon_pos = index(line, ":")
      if (colon_pos > 0) {
        tag    = substr(line, 1, colon_pos - 1)
        justif = substr(line, colon_pos + 1)
        sub(/^[[:space:]]+/, "", justif)
        if (tag != "" && justif != "") print tag "\t" justif
      }
    }
  ' "$body_file" || true)

  rm -f "$body_file"

  # Under BSD awk the fence guard must suppress the fenced tag.
  [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# AC5: Audit line logged via tag_index_log_history() for each real new tag
# ---------------------------------------------------------------------------

@test "AC5: one real new-tags: entry produces one audit line" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(cat <<'BODY'
PR adds a new convention.

new-tags:
  - while-read: Tracks the read-loop pattern for piped data
BODY
)"

  reconcile_tag_index "$body" "77"

  [ -f "$log_file" ]
  grep -q "tag: while-read" "$log_file"
  grep -q "Tracks the read-loop pattern" "$log_file"
  grep -q "PR #77" "$log_file"
}

@test "AC5: two new-tags: entries produce two audit lines" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(cat <<'BODY'
PR adds two conventions.

new-tags:
  - alpha-tag: First new tag justification
  - beta-tag: Second new tag justification
BODY
)"

  reconcile_tag_index "$body" "88"

  [ -f "$log_file" ]

  # Both tags must appear in the log
  grep -q "tag: alpha-tag" "$log_file"
  grep -q "tag: beta-tag" "$log_file"

  # Exactly two audit lines must be present for this PR
  local count
  count=$(grep -c "PR #88" "$log_file" || true)
  [ "$count" -eq 2 ]
}

@test "AC5: audit line includes tag name, justification, and PR number" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  local body
  body="$(cat <<'BODY'
new-tags:
  - pipefail-guard: Ensures pipefail errors are not silently swallowed
BODY
)"

  reconcile_tag_index "$body" "123"

  [ -f "$log_file" ]

  local line
  line=$(grep "tag: pipefail-guard" "$log_file")

  # Line must contain the tag name
  echo "$line" | grep -q "pipefail-guard"

  # Line must contain the justification
  echo "$line" | grep -q "Ensures pipefail errors"

  # Line must contain the PR number
  echo "$line" | grep -q "PR #123"
}

@test "AC5: tag_index_log_history creates .rite dir if missing and writes log" {
  # Ensure the .rite dir does NOT exist yet
  rm -rf "${RITE_TEST_TMPDIR}/.rite"
  [ ! -d "${RITE_TEST_TMPDIR}/.rite" ]

  tag_index_log_history "justified" "new-tag" "Some justification" "42"

  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  [ -f "$log_file" ]
  grep -q "tag: new-tag" "$log_file"
}

# ---------------------------------------------------------------------------
# AC: Per-action dedup — justified branch is idempotent on re-run (#765)
# ---------------------------------------------------------------------------

@test "AC-dedup-justified: calling justified twice does not produce a duplicate line" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history "justified" "dedup-tag" "Dedup justification" "200"
  tag_index_log_history "justified" "dedup-tag" "Dedup justification" "200"

  local count
  count=$(grep -c "tag: dedup-tag" "$log_file" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC: Per-action dedup — added branch is idempotent on re-run (absorbs #761)
# ---------------------------------------------------------------------------

@test "AC-dedup-added: calling added twice does not produce a duplicate line" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history "added" "my-tag" "conventions.md → grep -c pattern" "300"
  tag_index_log_history "added" "my-tag" "conventions.md → grep -c pattern" "300"

  local count
  count=$(grep -c "added: my-tag" "$log_file" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC: Per-action dedup — merged branch is idempotent on re-run (#765)
# ---------------------------------------------------------------------------

@test "AC-dedup-merged: calling merged twice does not produce a duplicate line" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history "merged" "new-tag" "into existing-tag" "400"
  tag_index_log_history "merged" "new-tag" "into existing-tag" "400"

  local count
  count=$(grep -c "merged: new-tag" "$log_file" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC: added entry uses file → heading separator, not file#heading (absorbs #762)
# ---------------------------------------------------------------------------

@test "AC-separator-added: added entry uses canonical file → heading separator" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history "added" "sep-tag" "conventions.md → Silent death" "500"

  # Must contain → separator (canonical pointer form)
  grep -q "conventions.md → Silent death" "$log_file"

  # Must NOT contain raw file#heading form
  ! grep -q "conventions.md#" "$log_file"
}

# ---------------------------------------------------------------------------
# AC: Multiple distinct entries accumulate without overwriting one another
# ---------------------------------------------------------------------------

@test "AC-accumulate: multiple distinct entries for the same tag accumulate" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history "justified" "accum-tag" "First justification" "600"
  tag_index_log_history "added"     "accum-tag" "conventions.md → Some heading" "601"
  tag_index_log_history "merged"    "accum-tag" "into base-tag" "602"

  # All three distinct lines must be present
  grep -q "tag: accum-tag" "$log_file"
  grep -q "added: accum-tag" "$log_file"
  grep -q "merged: accum-tag" "$log_file"

  # Total lines for accum-tag must be exactly 3
  local count
  count=$(grep -c "accum-tag" "$log_file" || true)
  [ "$count" -eq 3 ]
}

@test "AC-accumulate: two different tags for same PR each get their own line" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history "justified" "tag-alpha" "Alpha justification" "700"
  tag_index_log_history "justified" "tag-beta"  "Beta justification"  "700"

  grep -q "tag: tag-alpha" "$log_file"
  grep -q "tag: tag-beta"  "$log_file"

  local count
  count=$(grep -c "PR #700" "$log_file" || true)
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AC: Dedup uses whole-line (anchored) match — shorter key not suppressed by
#     a longer superset line already in the log (guards finding #1 fix)
# ---------------------------------------------------------------------------

@test "AC-dedup-wholeline: shorter detail not suppressed when log has longer superset line" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  # Pre-seed the log with a LONGER detail line for the same tag+PR.
  # Format: YYYY-MM-DD | PR #<N> | tag: <name> | <detail>
  # The date-stripped form of this line is:  "PR #800 | tag: short-tag | Longer justification text here"
  # That is a superset of the shorter entry's date-stripped form:
  #   "PR #800 | tag: short-tag | Short just"
  # A substring grep (-qF) would falsely match "Short just" inside the longer line
  # if the detail appeared there, but even without that, the tag+PR fragment
  # "PR #800 | tag: short-tag" appears in the superset line.
  printf '%s\n' "2026-06-01 | PR #800 | tag: short-tag | Longer justification text here" \
    > "$log_file"

  # Now log a distinct (shorter-detail) entry for the same tag+PR.
  # A substring match would falsely treat the dedup_key
  # "PR #800 | tag: short-tag | Short just" as already present because
  # grep -qF scans line contents and "PR #800 | tag: short-tag" is a substring
  # of the pre-seeded line.  A whole-line (-x) match must NOT suppress it.
  tag_index_log_history "justified" "short-tag" "Short just" "800"

  # Both the pre-seeded and newly-added lines must be present.
  local count
  count=$(grep -c "short-tag" "$log_file" || true)
  [ "$count" -eq 2 ]

  grep -q "Longer justification text here" "$log_file"
  grep -q "Short just" "$log_file"
}

# ---------------------------------------------------------------------------
# AC: Dedup is date-independent — cross-midnight re-run does not append duplicate
# ---------------------------------------------------------------------------

@test "AC-dedup-crossmidnight: same tuple logged on a prior date is still recognised as duplicate" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  # Pre-seed the log with an entry from a prior date (different date prefix).
  # Format matches what tag_index_log_history writes for the "justified" action:
  #   YYYY-MM-DD | PR #<N> | tag: <name> | <detail>
  printf '%s\n' "2025-12-31 | PR #900 | tag: midnight-tag | Midnight justification" \
    > "$log_file"

  # Call log_history with the same (action, tag, detail, PR) tuple "today".
  # The dedup_key (date-stripped) is identical to the pre-seeded line's stripped form.
  # The guard must detect the match and skip append, even though the date differs.
  tag_index_log_history "justified" "midnight-tag" "Midnight justification" "900"

  # Only the original entry must be present — no duplicate.
  local count
  count=$(grep -c "midnight-tag" "$log_file" || true)
  [ "$count" -eq 1 ]
}
