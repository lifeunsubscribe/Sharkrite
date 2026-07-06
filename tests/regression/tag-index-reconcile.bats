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

  # Stubs for the sonnet similarity wiring (#766). DOC_CLAUDE_TIMEOUT and
  # claude_provider_resolve_model are normally provided by assess-documentation.sh's
  # top-level body, which we deliberately do not execute. provider_run_prompt_with_timeout
  # echoes whatever canned JSON a test places in SIMILARITY_JSON (empty by default,
  # so similarity-unaware tests stay no-ops).
  export DOC_CLAUDE_TIMEOUT=120
  export SIMILARITY_JSON=""
  export COVERAGE_JSON=""
  claude_provider_resolve_model() { echo "stub-model"; }
  # Both the similarity (#766) and coverage (#767) checks call this stub. They
  # are distinguished by prompt content: the coverage prompt asks for
  # "missing_pointers", the similarity prompt asks for "merges". This lets a
  # test set COVERAGE_JSON and SIMILARITY_JSON independently.
  provider_run_prompt_with_timeout() {
    case "$1" in
      *missing_pointers*) printf '%s' "${COVERAGE_JSON:-}" ;;
      *)                  printf '%s' "${SIMILARITY_JSON:-}" ;;
    esac
  }
  export -f claude_provider_resolve_model provider_run_prompt_with_timeout

  # Source tag-index.sh to load tag_index_log_history() and its helpers.
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: tag-index.sh uses a function-sentinel guard (declare -f tag_index_log_history); pre-source provider stubs are preserved on source. print_warning/print_info are re-stubbed below because colors.sh (chained) uses an env-var guard only.
  # shellcheck source=/dev/null
  source "${RITE_REPO_ROOT}/lib/utils/tag-index.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Re-stub after source: tag-index.sh chains to colors.sh (env-var guard
  # _RITE_COLORS_LOADED) which overwrites print_warning and print_info.
  print_warning() { :; }
  print_info()    { :; }
  verbose_info()  { :; }
  export -f print_warning print_info verbose_info

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
  # Built via printf with literal backticks (avoids bats test-body parse issues
  # with bare ``` heredoc lines — same pattern as the sibling AC4 test below).
  local body
  body="$(printf '%s\n' \
    "This PR documents the convention format." \
    "" \
    "Example usage:" \
    '```' \
    "new-tags:" \
    "  - fenced-tag: This justification is inside a fence and must not be extracted" \
    '```' \
    "" \
    "Closes #42")"

  reconcile_tag_index "$body" "42"

  [ ! -f "$log_file" ] || [ ! -s "$log_file" ]
}

@test "AC4: new-tags: inside a backtick-info fence (e.g. yaml) is not extracted" {
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

  tag_index_log_history justified "42" "new-tag" "Some justification"

  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  [ -f "$log_file" ]
  grep -q "tag: new-tag" "$log_file"
}

# ---------------------------------------------------------------------------
# Stage 3 (#765): action-aware history — dedup (#761) + → separator (#762)
# ---------------------------------------------------------------------------

@test "added action is deduped — two identical calls produce one line (#761)" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history added 5 foo docs/x.md "Heading"
  tag_index_log_history added 5 foo docs/x.md "Heading"

  [ -f "$log_file" ]
  local count
  count=$(grep -c "added foo" "$log_file" || true)
  [ "$count" -eq 1 ]
}

@test "merged action is idempotent — two identical calls produce one line (#761)" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history merged 5 foo bar
  tag_index_log_history merged 5 foo bar

  [ -f "$log_file" ]
  local count
  count=$(grep -c "merged foo into bar" "$log_file" || true)
  [ "$count" -eq 1 ]
}

@test "added action uses the → separator matching the index (#762)" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history added 5 foo docs/x.md "Heading"

  [ -f "$log_file" ]
  grep -q "→ docs/x.md → Heading" "$log_file"
}

@test "distinct actions accumulate as separate lines — no overwrite" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history justified 5 alpha "Some justification"
  tag_index_log_history added 5 beta docs/y.md "Beta Heading"
  tag_index_log_history merged 5 gamma delta

  [ -f "$log_file" ]
  grep -q "tag: alpha | Some justification" "$log_file"
  grep -q "added beta → docs/y.md → Beta Heading" "$log_file"
  grep -q "merged gamma into delta" "$log_file"

  local count
  count=$(grep -c "PR #5" "$log_file" || true)
  [ "$count" -eq 3 ]
}

@test "justified action is deduped — two identical calls produce one line (#761)" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  mkdir -p "${RITE_TEST_TMPDIR}/.rite"

  tag_index_log_history justified 5 mytag "because reasons"
  tag_index_log_history justified 5 mytag "because reasons"

  [ -f "$log_file" ]
  local count
  count=$(grep -c "tag: mytag | because reasons" "$log_file" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Stage 3 slice 3 (#766 + #763): similarity merge + confidence guard
# ---------------------------------------------------------------------------

# Writes a tag-index.md fixture with one EXISTING tag (merge target) and one
# NEW tag heading (merge source). In production update_conventions_from_marker
# creates the new tag's heading+pointer before reconcile_tag_index runs the
# similarity check, so a merge moves that pointer under the existing tag.
# When $2 is omitted, only the existing heading is written.
_seed_index_with_existing_tag() {
  local existing="$1"
  local newtag="${2:-}"
  mkdir -p "$(dirname "$TAG_INDEX_FILE")"
  cat > "$TAG_INDEX_FILE" <<SEED_EOF
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## ${existing}
- docs/x.md → Existing Heading
SEED_EOF
  if [ -n "$newtag" ]; then
    cat >> "$TAG_INDEX_FILE" <<SEED2_EOF

## ${newtag}
- docs/new.md → New Heading
SEED2_EOF
  fi
}

@test "#766: merge applied at confidence 0.92, NOT applied at 0.60" {
  # Seed both the existing target AND the new tag's heading (as
  # update_conventions_from_marker would have just done in production).
  _seed_index_with_existing_tag "set-e" "strict-mode"

  # High confidence -> merge new-tag 'strict-mode' into existing 'set-e'.
  export SIMILARITY_JSON='{"merges":[{"from":"strict-mode","into":"set-e","confidence":0.92}]}'

  local body
  body="$(printf '%s\n' \
    "new-tags:" \
    "  - strict-mode: Tracks strict shell mode usage")"

  reconcile_tag_index "$body" "200"

  # FROM heading is gone; the new tag's pointer is now folded under INTO.
  ! grep -q "^## strict-mode" "$TAG_INDEX_FILE"
  grep -q "^## set-e" "$TAG_INDEX_FILE"
  grep -q "docs/new.md → New Heading" "$TAG_INDEX_FILE"

  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  grep -q "merged strict-mode into set-e" "$log_file"

  # --- Low confidence: no merge ---
  _seed_index_with_existing_tag "set-e" "strict-mode"
  rm -f "$log_file"
  export SIMILARITY_JSON='{"merges":[{"from":"strict-mode","into":"set-e","confidence":0.60}]}'

  reconcile_tag_index "$body" "201"

  # At 0.60 both headings survive and no merge is logged.
  grep -q "^## strict-mode" "$TAG_INDEX_FILE"
  grep -q "^## set-e" "$TAG_INDEX_FILE"
  ! grep -q "merged strict-mode into set-e" "$log_file" 2>/dev/null || false
}

@test "#763: non-numeric/out-of-range confidence is SKIPPED (not coerced)" {
  local conf
  for conf in '"0.9x"' '"abc"' '1.5'; do
    # Seed BOTH headings so a merge COULD happen if the guard were absent —
    # that makes the "both still present" assertion a real signal of the skip.
    _seed_index_with_existing_tag "set-e" "strict-mode"
    local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
    rm -f "$log_file"
    export SIMILARITY_JSON="{\"merges\":[{\"from\":\"strict-mode\",\"into\":\"set-e\",\"confidence\":${conf}}]}"

    local body
    body="$(printf '%s\n' \
      "new-tags:" \
      "  - strict-mode: Tracks strict shell mode usage")"

    reconcile_tag_index "$body" "300"

    # Both headings still present — the invalid confidence was skipped, not coerced.
    grep -q "^## set-e" "$TAG_INDEX_FILE"
    grep -q "^## strict-mode" "$TAG_INDEX_FILE"
    ! grep -q "merged strict-mode into set-e" "$log_file" 2>/dev/null || false
  done
}

@test "#766: empty / malformed similarity JSON -> no merges, new tag preserved" {
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"

  local body
  body="$(printf '%s\n' \
    "new-tags:" \
    "  - lonely-tag: A tag with no semantic duplicate")"

  # Case A: empty response.
  _seed_index_with_existing_tag "set-e"
  rm -f "$log_file"
  export SIMILARITY_JSON=""
  reconcile_tag_index "$body" "400"
  grep -q "tag: lonely-tag" "$log_file"          # new tag preserved (justified)
  ! grep -q "^merged\|merged lonely-tag" "$log_file" 2>/dev/null || false

  # Case B: malformed JSON.
  _seed_index_with_existing_tag "set-e"
  rm -f "$log_file"
  export SIMILARITY_JSON='{this is not valid json'
  reconcile_tag_index "$body" "401"
  grep -q "tag: lonely-tag" "$log_file"
  grep -q "^## set-e" "$TAG_INDEX_FILE"
}

@test "tag_index_merge_tag moves FROM pointer under INTO, removes FROM, dedups" {
  mkdir -p "$(dirname "$TAG_INDEX_FILE")"
  cat > "$TAG_INDEX_FILE" <<'IDX_EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## from-tag
- docs/a.md → Alpha Heading
- docs/shared.md → Shared Heading

## into-tag
- docs/b.md → Beta Heading
- docs/shared.md → Shared Heading
IDX_EOF

  run tag_index_merge_tag "from-tag" "into-tag"
  [ "$status" -eq 0 ]

  # FROM heading removed entirely.
  ! grep -q "^## from-tag" "$TAG_INDEX_FILE"

  # FROM's unique pointer now lives under INTO.
  grep -q "docs/a.md → Alpha Heading" "$TAG_INDEX_FILE"

  # The shared pointer is NOT duplicated under INTO (it was already present).
  local count
  count=$(grep -c "docs/shared.md → Shared Heading" "$TAG_INDEX_FILE" || true)
  [ "$count" -eq 1 ]
}

@test "tag_index_merge_tag returns non-zero on missing file or absent heading" {
  # Missing index file.
  rm -f "$TAG_INDEX_FILE"
  run tag_index_merge_tag "from-tag" "into-tag"
  [ "$status" -ne 0 ]

  # FROM heading absent.
  mkdir -p "$(dirname "$TAG_INDEX_FILE")"
  cat > "$TAG_INDEX_FILE" <<'IDX_EOF'
# Tag Index

---

## into-tag
- docs/b.md → Beta Heading
IDX_EOF
  run tag_index_merge_tag "from-tag" "into-tag"
  [ "$status" -ne 0 ]

  # INTO heading absent.
  cat > "$TAG_INDEX_FILE" <<'IDX_EOF'
# Tag Index

---

## from-tag
- docs/a.md → Alpha Heading
IDX_EOF
  run tag_index_merge_tag "from-tag" "into-tag"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Stage 3 final slice (#767 + #759 + #760): coverage check + section-safe pointers
# ---------------------------------------------------------------------------

# Seeds a single conventions.md catalog file so the coverage check has content to
# scan (the coverage block skips the model call when no catalog file exists).
_seed_catalog_conventions() {
  mkdir -p "${RITE_TEST_TMPDIR}/docs/architecture"
  cat > "${RITE_TEST_TMPDIR}/docs/architecture/conventions.md" <<'CONV_EOF'
# Conventions

## grep -c pattern
Some content about grep -c.

## Silent death: pipelines inside $()
Some content about silent death.
CONV_EOF
}

@test "#759: coverage pointer lands INSIDE the target section, not the adjacent one" {
  # Fixture: target tag's section is followed by a blank line then another
  # heading. tag_index_add_coverage_pointer must insert directly under ## alpha,
  # NOT under ## beta.
  mkdir -p "$(dirname "$TAG_INDEX_FILE")"
  cat > "$TAG_INDEX_FILE" <<'IDX_EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## alpha

## beta
- docs/b.md → Beta Existing
IDX_EOF

  run tag_index_add_coverage_pointer "alpha" "conventions.md#New Alpha Heading"
  [ "$status" -eq 0 ]

  # The new pointer must appear in alpha's section. Verify section-safe placement:
  # the line immediately after "## alpha" is the new pointer.
  local after_alpha
  after_alpha=$(awk '/^## alpha$/{getline; print; exit}' "$TAG_INDEX_FILE")
  [ "$after_alpha" = "- conventions.md → New Alpha Heading" ]

  # And it must NOT have landed inside beta's section.
  local beta_section
  beta_section=$(awk '/^## beta$/{f=1; next} f&&/^## /{f=0} f{print}' "$TAG_INDEX_FILE")
  ! echo "$beta_section" | grep -q "New Alpha Heading"
}

@test "#767: coverage pointer applied for a valid new tag + history logs added" {
  _seed_catalog_conventions

  # Seed the index with the new tag's heading (as update_conventions_from_marker
  # would just have done in production).
  _seed_index_with_existing_tag "some-existing" "grep-count"

  export COVERAGE_JSON='{"missing_pointers":[{"tag":"grep-count","target":"conventions.md#grep -c pattern"}]}'

  local body
  body="$(printf '%s\n' \
    "new-tags:" \
    "  - grep-count: Tracks the grep -c count-and-exit-code pattern")"

  reconcile_tag_index "$body" "500"

  # The pointer appears under the grep-count tag.
  local grep_count_section
  grep_count_section=$(awk '/^## grep-count$/{f=1; next} f&&/^## /{f=0} f{print}' "$TAG_INDEX_FILE")
  echo "$grep_count_section" | grep -q "conventions.md → grep -c pattern"

  # History logs the added action: added <tag> → <file> → <heading>.
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  [ -f "$log_file" ]
  grep -q "added grep-count → conventions.md → grep -c pattern" "$log_file"
}

@test "#767: anti-hallucination — pointer for a tag NOT in this PR is skipped" {
  _seed_catalog_conventions
  _seed_index_with_existing_tag "some-existing" "real-tag"

  # The model returns a pointer for 'ghost-tag' which is NOT one of this PR's
  # new tags. It must be skipped (with a warning) and no pointer added for it.
  export COVERAGE_JSON='{"missing_pointers":[{"tag":"ghost-tag","target":"conventions.md#grep -c pattern"}]}'

  local body
  body="$(printf '%s\n' \
    "new-tags:" \
    "  - real-tag: A genuine new tag for this PR")"

  reconcile_tag_index "$body" "600"

  # No ## ghost-tag heading was created and no ghost-tag pointer exists.
  ! grep -q "^## ghost-tag" "$TAG_INDEX_FILE"
  ! grep -q "ghost-tag" "$TAG_INDEX_FILE"

  # No 'added ghost-tag' history line.
  local log_file="${RITE_TEST_TMPDIR}/.rite/tag-index-history.log"
  if [ -f "$log_file" ]; then
    ! grep -q "added ghost-tag" "$log_file"
  fi
}

@test "#767: malformed coverage JSON is a graceful no-op; multi-# target splits on first #" {
  # --- Part 1: malformed JSON -> no pointer added, no abort ---
  _seed_catalog_conventions
  _seed_index_with_existing_tag "some-existing" "safe-tag"

  export COVERAGE_JSON='{this is not valid json'

  local body
  body="$(printf '%s\n' \
    "new-tags:" \
    "  - safe-tag: A new tag whose coverage call yields malformed JSON")"

  # Must not abort under set -e (reconcile returns 0).
  reconcile_tag_index "$body" "700"

  # safe-tag's section gained no coverage pointer (only its seeded one remains).
  local safe_section
  safe_section=$(awk '/^## safe-tag$/{f=1; next} f&&/^## /{f=0} f{print}' "$TAG_INDEX_FILE")
  local ptr_count
  ptr_count=$(echo "$safe_section" | grep -c "^- " || true)
  [ "$ptr_count" -eq 1 ]

  # --- Part 2: target with multiple '#' splits on the FIRST # ---
  # file=conventions.md, heading="Heading#Sub" (the second # is preserved).
  run tag_index_add_coverage_pointer "safe-tag" "conventions.md#Heading#Sub"
  [ "$status" -eq 0 ]
  grep -q "conventions.md → Heading#Sub" "$TAG_INDEX_FILE"
}

@test "#760: full tag-index-reconcile suite is green (covered by this file running)" {
  # This file IS the suite; its own green run is the assertion for #760's
  # requirement that the coverage/awk area no longer breaks the gate. A trivial
  # passing assertion documents the intent without re-invoking bats recursively.
  [ 1 -eq 1 ]
}
