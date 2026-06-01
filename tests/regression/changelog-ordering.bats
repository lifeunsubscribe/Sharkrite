#!/usr/bin/env bats
# Test suite for issue #60: Add newest changelog entries at top
#
# Verifies that assess_internal_changelog() always inserts new entries
# at the top of the file (newest-first ordering), not at the bottom.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract just the assess_internal_changelog function from the source file
# and run it against a temp changelog file.
#
# Usage: run_changelog_update <changelog_file> <pr_number> <pr_title> <changed_files>
run_changelog_update() {
  local changelog_file="$1"
  local pr_number="$2"
  local pr_title="$3"
  local changed_files="$4"

  # Source only the function we need (with stubs for deps)
  bash -c "
    set -euo pipefail

    # Minimal stubs so the script sources cleanly without real env
    RITE_INTERNAL_DOCS_DIR=\"$(dirname "$changelog_file")\"
    _MARKER_DIR=\"\$(mktemp -d)\"
    _mark_updated() { touch \"\$_MARKER_DIR/\$1\"; }

    # Extract and eval just the assess_internal_changelog function
    $(sed -n '/^assess_internal_changelog()/,/^}/p' \
        "${BATS_TEST_DIRNAME}/../../lib/core/assess-documentation.sh")

    assess_internal_changelog '$pr_number' '$pr_title' '$changed_files'
    rm -rf \"\$_MARKER_DIR\"
  "
}

setup() {
  # Create a temp directory for the test changelog files
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "new day entry is inserted at top, not appended at bottom" {
  # Pre-create a changelog with an older date section at top
  cat > "$TEST_DIR/changelog.md" <<'EOF'
# Changelog

## 2026-05-20
- feat: old feature (#10) [lib/foo.sh]

## 2026-05-19
- fix: older fix (#9) [lib/bar.sh]
EOF

  # Run update for a date that doesn't exist yet (simulate "today" = 2026-05-27)
  # We patch the date by setting today inline via function override
  bash -c "
    set -euo pipefail
    RITE_INTERNAL_DOCS_DIR='$TEST_DIR'
    _MARKER_DIR=\"\$(mktemp -d)\"
    _mark_updated() { touch \"\$_MARKER_DIR/\$1\"; }

    $(sed -n '/^assess_internal_changelog()/,/^}/p' \
        "${BATS_TEST_DIRNAME}/../../lib/core/assess-documentation.sh" \
        | sed 's/local today=\$(date +%Y-%m-%d)/local today="2026-05-27"/')

    assess_internal_changelog '42' 'feat: new thing (#42)' 'lib/new.sh'
    rm -rf \"\$_MARKER_DIR\"
  "

  # 2026-05-27 must appear before 2026-05-20 in the file
  local line_27
  local line_20
  line_27=$(grep -n "^## 2026-05-27" "$TEST_DIR/changelog.md" | cut -d: -f1)
  line_20=$(grep -n "^## 2026-05-20" "$TEST_DIR/changelog.md" | cut -d: -f1)

  [ -n "$line_27" ]
  [ -n "$line_20" ]
  [ "$line_27" -lt "$line_20" ]
}

@test "new entry for existing day is inserted before other entries in that day" {
  # Pre-create changelog with today's date already present
  cat > "$TEST_DIR/changelog.md" <<'EOF'
# Changelog

## 2026-05-27
- change: earlier entry (#58) [lib/merge-pr.sh]

## 2026-05-26
- fix: even older fix (#45) [lib/foo.sh]
EOF

  bash -c "
    set -euo pipefail
    RITE_INTERNAL_DOCS_DIR='$TEST_DIR'
    _MARKER_DIR=\"\$(mktemp -d)\"
    _mark_updated() { touch \"\$_MARKER_DIR/\$1\"; }

    $(sed -n '/^assess_internal_changelog()/,/^}/p' \
        "${BATS_TEST_DIRNAME}/../../lib/core/assess-documentation.sh" \
        | sed 's/local today=\$(date +%Y-%m-%d)/local today="2026-05-27"/')

    assess_internal_changelog '59' 'fix: newer entry (#59)' 'lib/workflow-runner.sh'
    rm -rf \"\$_MARKER_DIR\"
  "

  # newer entry (#59) must appear before earlier entry (#58) within the same day
  local line_59
  local line_58
  line_59=$(grep -n "#59" "$TEST_DIR/changelog.md" | cut -d: -f1)
  line_58=$(grep -n "#58" "$TEST_DIR/changelog.md" | cut -d: -f1)

  [ -n "$line_59" ]
  [ -n "$line_58" ]
  [ "$line_59" -lt "$line_58" ]
}

@test "existing date section in wrong position is moved to top" {
  # changelog with three dated sections in oldest-first order (the pre-fix bug state)
  cat > "$TEST_DIR/changelog.md" <<'EOF'
# Changelog

## 2026-05-25
- fix: old fix (#9) [lib/bar.sh]

## 2026-05-26
- change: medium entry (#10) [lib/baz.sh]

## 2026-05-27
- change: newest existing entry (#11) [lib/qux.sh]
EOF

  bash -c "
    set -euo pipefail
    RITE_INTERNAL_DOCS_DIR='$TEST_DIR'
    _MARKER_DIR=\"\$(mktemp -d)\"
    _mark_updated() { touch \"\$_MARKER_DIR/\$1\"; }

    $(sed -n '/^assess_internal_changelog()/,/^}/p' \
        "${BATS_TEST_DIRNAME}/../../lib/core/assess-documentation.sh" \
        | sed 's/local today=\$(date +%Y-%m-%d)/local today="2026-05-27"/')

    assess_internal_changelog '12' 'change: brand new entry (#12)' 'lib/new.sh'
    rm -rf \"\$_MARKER_DIR\"
  "

  # After update: 2026-05-27 must come before 2026-05-26 and 2026-05-25
  local line_27
  local line_26
  local line_25
  line_27=$(grep -n "^## 2026-05-27" "$TEST_DIR/changelog.md" | cut -d: -f1)
  line_26=$(grep -n "^## 2026-05-26" "$TEST_DIR/changelog.md" | cut -d: -f1)
  line_25=$(grep -n "^## 2026-05-25" "$TEST_DIR/changelog.md" | cut -d: -f1)

  [ "$line_27" -lt "$line_26" ]
  [ "$line_27" -lt "$line_25" ]

  # New entry #12 must be present and before existing #11
  local line_12
  local line_11
  line_12=$(grep -n "#12" "$TEST_DIR/changelog.md" | cut -d: -f1)
  line_11=$(grep -n "#11" "$TEST_DIR/changelog.md" | cut -d: -f1)

  [ -n "$line_12" ]
  [ "$line_12" -lt "$line_11" ]
}

@test "no existing entries are lost after update" {
  cat > "$TEST_DIR/changelog.md" <<'EOF'
# Changelog

## 2026-05-25
- fix: entry-A (#1) [lib/a.sh]
- fix: entry-B (#2) [lib/b.sh]

## 2026-05-24
- feat: entry-C (#3) [lib/c.sh]
EOF

  bash -c "
    set -euo pipefail
    RITE_INTERNAL_DOCS_DIR='$TEST_DIR'
    _MARKER_DIR=\"\$(mktemp -d)\"
    _mark_updated() { touch \"\$_MARKER_DIR/\$1\"; }

    $(sed -n '/^assess_internal_changelog()/,/^}/p' \
        "${BATS_TEST_DIRNAME}/../../lib/core/assess-documentation.sh" \
        | sed 's/local today=\$(date +%Y-%m-%d)/local today="2026-05-26"/')

    assess_internal_changelog '4' 'feat: entry-D (#4)' 'lib/d.sh'
    rm -rf \"\$_MARKER_DIR\"
  "

  # All four entries must be present
  grep -q "#1" "$TEST_DIR/changelog.md"
  grep -q "#2" "$TEST_DIR/changelog.md"
  grep -q "#3" "$TEST_DIR/changelog.md"
  grep -q "#4" "$TEST_DIR/changelog.md"
}

@test "fresh changelog (only header) gets entry at top" {
  echo "# Changelog" > "$TEST_DIR/changelog.md"
  echo "" >> "$TEST_DIR/changelog.md"

  bash -c "
    set -euo pipefail
    RITE_INTERNAL_DOCS_DIR='$TEST_DIR'
    _MARKER_DIR=\"\$(mktemp -d)\"
    _mark_updated() { touch \"\$_MARKER_DIR/\$1\"; }

    $(sed -n '/^assess_internal_changelog()/,/^}/p' \
        "${BATS_TEST_DIRNAME}/../../lib/core/assess-documentation.sh" \
        | sed 's/local today=\$(date +%Y-%m-%d)/local today="2026-05-27"/')

    assess_internal_changelog '1' 'feat: first entry (#1)' 'lib/foo.sh'
    rm -rf \"\$_MARKER_DIR\"
  "

  # First non-blank, non-header line after "# Changelog" should be the date heading
  local first_section
  first_section=$(grep "^## " "$TEST_DIR/changelog.md" | head -1)
  [ "$first_section" = "## 2026-05-27" ]

  # Entry must be present
  grep -q "#1" "$TEST_DIR/changelog.md"
}
