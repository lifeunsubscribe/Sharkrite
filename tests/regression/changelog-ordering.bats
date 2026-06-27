#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
# tests/regression/changelog-ordering.bats
#
# Regression test for changelog prepend ordering bug.
#
# Bug: assess_internal_changelog() appended new date sections to the END of
# the changelog instead of prepending them at the top. Result: `head changelog.md`
# showed the oldest entries, forcing users to `tail` to find what was just shipped.
#
# Fix: new date sections are inserted immediately after the "# Changelog" title
# line so the newest date always appears first (Keep a Changelog convention).
#
# Tests in this file:
#   1. New entry on a new date goes to the TOP of the file (not bottom)
#   2. Multiple PRs on the same date: entries accumulate under the existing top section
#   3. Adding entries in chronological order produces newest-first file
#   4. Deduplication: second run with same PR number is a no-op
#   5. Initialization: empty/missing changelog gets a fresh header + entry at top

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: source assess_internal_changelog() without running top-level script code
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INTERNAL_DOCS_DIR="${RITE_TEST_TMPDIR}/.rite/docs"
  mkdir -p "$RITE_INTERNAL_DOCS_DIR"

  # Marker dir used by _mark_updated()
  export _MARKER_DIR
  _MARKER_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/markers.XXXXXX")"

  # Source only the two helpers we need from assess-documentation.sh.
  # We extract _mark_updated() and assess_internal_changelog() via awk so
  # the script's top-level code (which calls `gh pr view`, etc.) never runs.
  eval "$(awk '
    /^_mark_updated[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
    /^assess_internal_changelog[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/assess-documentation.sh")"

  # Fake `date` binary installed in test PATH so assess_internal_changelog()
  # picks up a fixed date via FAKE_TODAY env var.
  mkdir -p "${RITE_TEST_TMPDIR}/bin"
  cat > "${RITE_TEST_TMPDIR}/bin/date" <<'DATEEOF'
#!/usr/bin/env bash
if [ "$1" = "+%Y-%m-%d" ] && [ -n "${FAKE_TODAY:-}" ]; then
  echo "$FAKE_TODAY"
else
  command date "$@"
fi
DATEEOF
  chmod +x "${RITE_TEST_TMPDIR}/bin/date"
  export PATH="${RITE_TEST_TMPDIR}/bin:$PATH"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: pre-create a changelog with two older date sections
# ---------------------------------------------------------------------------
write_old_changelog() {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  cat > "$doc_file" <<'EOF'
# Changelog

## 2026-05-25
- change: Old entry B (#20) [lib/b.sh]

## 2026-05-24
- change: Old entry A (#10) [lib/a.sh]
EOF
}

# ---------------------------------------------------------------------------
# Test 1: New entry on a NEW date is prepended at the top
# ---------------------------------------------------------------------------

@test "ordering: new date section is inserted at the top, not appended" {
  write_old_changelog
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"

  FAKE_TODAY="2026-05-27" assess_internal_changelog "99" "feat: add new feature" "lib/new.sh"

  # First date heading in the file must be the new (newest) one
  local first_heading
  first_heading=$(grep "^## " "$doc_file" | head -1)
  [ "$first_heading" = "## 2026-05-27" ]

  # Old sections must still be present (nothing lost)
  grep -q "^## 2026-05-25" "$doc_file"
  grep -q "^## 2026-05-24" "$doc_file"

  # The new entry must appear before the old ones
  local new_line old_line
  new_line=$(grep -n "feat: add new feature" "$doc_file" | cut -d: -f1)
  old_line=$(grep -n "Old entry B" "$doc_file" | cut -d: -f1)
  [ "$new_line" -lt "$old_line" ]
}

# ---------------------------------------------------------------------------
# Test 2: Same date — second PR entry goes under existing top date section
# ---------------------------------------------------------------------------

@test "ordering: second PR on the same date accumulates under top date header" {
  write_old_changelog
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"

  # First PR today
  FAKE_TODAY="2026-05-27" assess_internal_changelog "100" "feat: first PR today" "lib/x.sh"
  # Second PR today
  FAKE_TODAY="2026-05-27" assess_internal_changelog "101" "fix: second PR today" "lib/y.sh"

  # Date heading should appear only once
  local date_count
  date_count=$(grep -c "^## 2026-05-27" "$doc_file" || true)
  [ "$date_count" -eq 1 ]

  # Both entries must be present
  grep -q "feat: first PR today" "$doc_file"
  grep -q "fix: second PR today" "$doc_file"

  # Both entries must appear before the old date sections
  local entry1_line entry2_line old_line
  entry1_line=$(grep -n "feat: first PR today" "$doc_file" | cut -d: -f1)
  entry2_line=$(grep -n "fix: second PR today" "$doc_file" | cut -d: -f1)
  old_line=$(grep -n "Old entry B" "$doc_file" | cut -d: -f1)
  [ "$entry1_line" -lt "$old_line" ]
  [ "$entry2_line" -lt "$old_line" ]
}

# ---------------------------------------------------------------------------
# Test 3: Adding entries in chronological order produces newest-first file
# ---------------------------------------------------------------------------

@test "ordering: chronological inserts produce newest-first date ordering" {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  echo "# Changelog" > "$doc_file"
  echo "" >> "$doc_file"

  # Simulate oldest date first, then middle, then newest
  FAKE_TODAY="2026-05-23" assess_internal_changelog "10" "chore: oldest entry" "lib/a.sh"
  FAKE_TODAY="2026-05-24" assess_internal_changelog "20" "chore: middle entry" "lib/b.sh"
  FAKE_TODAY="2026-05-25" assess_internal_changelog "30" "chore: newest entry" "lib/c.sh"

  # Verify newest-first ordering of date headings
  local first second third
  first=$(grep "^## " "$doc_file" | sed -n '1p')
  second=$(grep "^## " "$doc_file" | sed -n '2p')
  third=$(grep "^## " "$doc_file" | sed -n '3p')

  [ "$first"  = "## 2026-05-25" ]
  [ "$second" = "## 2026-05-24" ]
  [ "$third"  = "## 2026-05-23" ]
}

# ---------------------------------------------------------------------------
# Test 4: Deduplication — same PR number is a no-op
# ---------------------------------------------------------------------------

@test "dedup: same PR number is not added twice" {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  echo "# Changelog" > "$doc_file"
  echo "" >> "$doc_file"

  FAKE_TODAY="2026-05-27" assess_internal_changelog "55" "feat: some feature" "lib/z.sh"
  FAKE_TODAY="2026-05-27" assess_internal_changelog "55" "feat: some feature" "lib/z.sh"

  local count
  count=$(grep -c "#55" "$doc_file" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 4b: Deduplication — shorter PR number not false-positive-matched by
#          a longer PR number already in the changelog.
#          Bug: grep -q "#5" matched "#55", silently dropping PR #5.
# ---------------------------------------------------------------------------

@test "dedup: PR #5 is not suppressed when #55 is already present" {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  echo "# Changelog" > "$doc_file"
  echo "" >> "$doc_file"

  # Add PR #55 first
  FAKE_TODAY="2026-05-27" assess_internal_changelog "55" "feat: wider feature" "lib/wide.sh"

  # Now add PR #5 — with a bare grep -q "#5", this was silently dropped
  FAKE_TODAY="2026-05-27" assess_internal_changelog "5" "fix: narrow fix" "lib/narrow.sh"

  # PR #5 entry must be present
  grep -q "fix: narrow fix" "$doc_file"

  # PR #55 entry must still be present (not clobbered)
  grep -q "feat: wider feature" "$doc_file"
}

# ---------------------------------------------------------------------------
# Test 5: Fresh initialization — entry is added after the header
# ---------------------------------------------------------------------------

@test "init: new changelog gets date heading and entry after the title" {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  # Don't pre-create the file — let assess_internal_changelog initialize it

  FAKE_TODAY="2026-05-27" assess_internal_changelog "1" "feat: initial entry" "lib/init.sh"

  # File must exist
  [ -f "$doc_file" ]

  # Title must be first line
  local first_line
  first_line=$(head -1 "$doc_file")
  [ "$first_line" = "# Changelog" ]

  # Date heading and entry must be present
  grep -q "^## 2026-05-27" "$doc_file"
  grep -q "feat: initial entry" "$doc_file"

  # Date heading appears before the entry
  local date_line entry_line
  date_line=$(grep -n "^## 2026-05-27" "$doc_file" | cut -d: -f1)
  entry_line=$(grep -n "feat: initial entry" "$doc_file" | cut -d: -f1)
  [ "$date_line" -lt "$entry_line" ]
}

# ---------------------------------------------------------------------------
# Test 6: Non-standard title — entry must NOT be silently dropped
# ---------------------------------------------------------------------------

@test "robustness: non-standard title does not silently drop the new entry" {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  # Use a title that does not match "# Changelog" exactly
  cat > "$doc_file" <<'EOF'
# CHANGELOG

## 2026-05-24
- change: Old entry (#10) [lib/a.sh]
EOF

  FAKE_TODAY="2026-05-27" assess_internal_changelog "99" "feat: must not be lost" "lib/new.sh"

  # The new entry must appear in the file regardless of the non-standard title
  grep -q "feat: must not be lost" "$doc_file"

  # The old entry must still be present (nothing lost)
  grep -q "Old entry" "$doc_file"
}

# ---------------------------------------------------------------------------
# Test 7: Duplicate-prefixed title — entry appears exactly once
# ---------------------------------------------------------------------------

@test "robustness: second '# Changelog'-prefixed line does not produce duplicate date sections" {
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"
  # File contains two lines that start with "# Changelog" (e.g. a section comment)
  cat > "$doc_file" <<'EOF'
# Changelog

# Changelog (archived entries below)

## 2026-05-24
- change: Old entry (#10) [lib/a.sh]
EOF

  FAKE_TODAY="2026-05-27" assess_internal_changelog "99" "feat: new feature" "lib/new.sh"

  # The new date section must appear exactly once
  local date_count
  date_count=$(grep -c "^## 2026-05-27" "$doc_file" || true)
  [ "$date_count" -eq 1 ]

  # The new entry must be present
  grep -q "feat: new feature" "$doc_file"
}
