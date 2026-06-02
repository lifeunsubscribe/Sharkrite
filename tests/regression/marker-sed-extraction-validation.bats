#!/usr/bin/env bats
# Regression test for #197: Validate sharkrite-extract marker pairs for sed extraction
#
# Failure modes this test guards against:
#
#   1. Missing marker: sed '/start/,/end/p' finds no boundaries → empty output.
#      Downstream [ -n "$VAR" ] fails, but the error message says nothing about
#      the missing marker being the root cause.
#
#   2. Duplicate marker: sed opens on the first start, closes on the first end.
#      With two copies of the block, the extracted range spans both copies — code
#      is over-broad and incorrect, but the non-empty check still passes (silent
#      mis-extraction).
#
#   3. Reversed markers: end marker appears before start → sed finds no range →
#      empty output, same silent failure as missing marker.
#
# This test verifies:
#   1. Missing start marker → empty extraction (demonstrates the gap)
#   2. Duplicate start marker → over-broad extraction (demonstrates the gap)
#   3. Reversed markers → empty extraction (demonstrates the gap)
#   4. Marker count assertions catch all three failure modes before sed runs
#   5. Lint rule UNBALANCED_EXTRACT_MARKERS detects missing, duplicate, orphaned,
#      and reversed markers in shell files
#   6. Codebase sweep: all sharkrite-extract markers in the real codebase are
#      balanced with count==1 for each start and end

setup() {
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-extract-test"
  mkdir -p "$RITE_TEST_ROOT"

  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export PROJECT_ROOT

  # Lint test fixtures live in BATS_TEST_TMPDIR (unique per test, parallel-safe).
  # They are injected into the linter via RITE_LINT_EXTRA_DIRS instead of a symlink
  # inside lib/. This prevents the linter from scanning fixture files during
  # production make check runs (Issue #194: find -L scans symlinked fixture dir),
  # and eliminates the shared lib/test-fixtures-temp symlink that was unsafe for
  # parallel bats execution (Issue #191).
  export RITE_LINT_FIXTURES_DIR="${BATS_TEST_TMPDIR}/rite-lint-fixtures"
  export RITE_LINT_TEST_DIR="$RITE_LINT_FIXTURES_DIR"
  export RITE_LINT_EXTRA_DIRS="$RITE_LINT_FIXTURES_DIR"
  mkdir -p "$RITE_LINT_FIXTURES_DIR"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
  rm -rf "$RITE_LINT_FIXTURES_DIR"
}

# ---------------------------------------------------------------------------
# Behavioral tests: demonstrate the failure modes
# ---------------------------------------------------------------------------

@test "missing start marker yields empty sed extraction" {
  # Create a source file with only an end marker (no start).
  # sed range extraction returns empty — the content-anchor check would fail
  # but there is no diagnostic pointing to the missing marker as root cause.
  cat > "$RITE_TEST_ROOT/source-missing-start.sh" <<'EOF'
#!/bin/bash
# This is some code
while true; do
  do_something
done
# sharkrite-extract: my-loop-end
EOF

  EXTRACTED=$(sed -n '/# sharkrite-extract: my-loop-start/,/# sharkrite-extract: my-loop-end/p' \
    "$RITE_TEST_ROOT/source-missing-start.sh" || true)

  # Extraction yields empty — the missing-marker failure is silent
  [ -z "$EXTRACTED" ]
}

@test "duplicate start marker yields over-broad sed extraction" {
  # Create a source file with two start markers but one end marker.
  # sed opens range at the first start (line 3) and closes at the end (line 9).
  # The extracted block includes everything between first start and the end,
  # which is MORE than the intended block (lines 6-9 only).
  cat > "$RITE_TEST_ROOT/source-duplicate-start.sh" <<'EOF'
#!/bin/bash
# Some preamble code that should NOT be extracted
# sharkrite-extract: my-loop-start
first_loop() { echo first; }
# sharkrite-extract: my-loop-start
actual_loop() { echo actual; }
# sharkrite-extract: my-loop-end
EOF

  EXTRACTED=$(sed -n '/# sharkrite-extract: my-loop-start/,/# sharkrite-extract: my-loop-end/p' \
    "$RITE_TEST_ROOT/source-duplicate-start.sh" || true)

  # Over-broad extraction: includes content before the second start marker
  [[ "$EXTRACTED" == *"first_loop"* ]]
  # The intended content is also there — content-anchor check passes vacuously
  [[ "$EXTRACTED" == *"actual_loop"* ]]
}

@test "reversed markers yield empty sed extraction" {
  # Create a source file where end marker appears before start marker.
  # Layout:
  #   line 2: # sharkrite-extract: my-loop-end   (end before start)
  #   line 3: some_function() { ... }             (the "intended" block)
  #   line 4: # sharkrite-extract: my-loop-start  (start comes last)
  #
  # sed -n '/start/,/end/p' opens the range at line 4 (start), then scans
  # forward for a closing end marker. There is no end marker after line 4,
  # so the range extends to EOF. The only line printed is line 4 itself
  # (the start marker comment). some_function on line 3 is BEFORE the start
  # and is never included. This is consistent across BSD and GNU sed.
  cat > "$RITE_TEST_ROOT/source-reversed.sh" <<'EOF'
#!/bin/bash
# sharkrite-extract: my-loop-end
some_function() { echo "this should not be extracted"; }
# sharkrite-extract: my-loop-start
EOF

  EXTRACTED=$(sed -n '/# sharkrite-extract: my-loop-start/,/# sharkrite-extract: my-loop-end/p' \
    "$RITE_TEST_ROOT/source-reversed.sh" || true)

  # The intended block content must NOT appear — some_function is before the
  # start marker and is excluded regardless of sed implementation.
  [[ "$EXTRACTED" != *"some_function"* ]]

  # The start marker line itself IS included (sed opened the range there and
  # ran to EOF). This confirms sed did execute and the assertion above is not
  # vacuously true due to an empty-extraction edge case.
  [[ "$EXTRACTED" == *"sharkrite-extract: my-loop-start"* ]]
}

# ---------------------------------------------------------------------------
# Validation: marker count assertions catch failure modes before sed runs
# ---------------------------------------------------------------------------

@test "count assertion catches missing start marker before sed runs" {
  cat > "$RITE_TEST_ROOT/source-no-start.sh" <<'EOF'
#!/bin/bash
do_work() { echo "work"; }
# sharkrite-extract: my-loop-end
EOF

  run bash -c '
    SCRIPT="'"$RITE_TEST_ROOT/source-no-start.sh"'"
    START_COUNT=$(grep -c "# sharkrite-extract: my-loop-start" "$SCRIPT" || true)
    END_COUNT=$(grep -c "# sharkrite-extract: my-loop-end" "$SCRIPT" || true)
    if [ "$START_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ]; then
      echo "FAIL: markers not exactly-once: start=$START_COUNT end=$END_COUNT" >&2
      exit 1
    fi
    echo "PASS: markers OK"
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"start=0"* ]]
}

@test "count assertion catches duplicate end marker before sed runs" {
  cat > "$RITE_TEST_ROOT/source-dup-end.sh" <<'EOF'
#!/bin/bash
# sharkrite-extract: my-loop-start
do_work() { echo "work"; }
# sharkrite-extract: my-loop-end
extra_function() { echo "extra"; }
# sharkrite-extract: my-loop-end
EOF

  run bash -c '
    SCRIPT="'"$RITE_TEST_ROOT/source-dup-end.sh"'"
    START_COUNT=$(grep -c "# sharkrite-extract: my-loop-start" "$SCRIPT" || true)
    END_COUNT=$(grep -c "# sharkrite-extract: my-loop-end" "$SCRIPT" || true)
    if [ "$START_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ]; then
      echo "FAIL: markers not exactly-once: start=$START_COUNT end=$END_COUNT" >&2
      exit 1
    fi
    echo "PASS: markers OK"
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"end=2"* ]]
}

@test "count assertion passes for valid balanced markers" {
  cat > "$RITE_TEST_ROOT/source-valid.sh" <<'EOF'
#!/bin/bash
# sharkrite-extract: my-loop-start
do_work() { echo "work"; }
# sharkrite-extract: my-loop-end
EOF

  run bash -c '
    SCRIPT="'"$RITE_TEST_ROOT/source-valid.sh"'"
    START_COUNT=$(grep -c "# sharkrite-extract: my-loop-start" "$SCRIPT" || true)
    END_COUNT=$(grep -c "# sharkrite-extract: my-loop-end" "$SCRIPT" || true)
    if [ "$START_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ]; then
      echo "FAIL: markers not exactly-once: start=$START_COUNT end=$END_COUNT" >&2
      exit 1
    fi
    echo "PASS: markers OK"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Lint rule tests: UNBALANCED_EXTRACT_MARKERS (Rule 18)
# ---------------------------------------------------------------------------

@test "lint rule detects missing end marker for sharkrite-extract" {
  cat > "$RITE_LINT_TEST_DIR/missing-end-marker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# sharkrite-extract: worker-loop-start
while true; do
  echo "loop body"
done
# NOTE: missing worker-loop-end marker
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "missing-end-marker.sh" ]]
}

@test "lint rule detects duplicate start marker for sharkrite-extract" {
  cat > "$RITE_LINT_TEST_DIR/duplicate-start-marker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# sharkrite-extract: worker-loop-start
first_copy() { echo "first"; }
# sharkrite-extract: worker-loop-start
second_copy() { echo "second"; }
# sharkrite-extract: worker-loop-end
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "duplicate-start-marker.sh" ]]
}

@test "lint rule detects orphaned end marker with no matching start" {
  cat > "$RITE_LINT_TEST_DIR/orphaned-end-marker.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

do_work() { echo "work"; }
# sharkrite-extract: worker-loop-end
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "orphaned-end-marker.sh" ]]
}

@test "lint rule reports each duplicate end marker separately when no start exists" {
  # Regression test for #251: two end markers with no start should produce two
  # separate violation reports (one per line), not one. The root cause (missing
  # start) is the same for both, but the count must reflect both occurrences.
  cat > "$RITE_LINT_TEST_DIR/duplicate-end-no-start.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

do_work() { echo "work"; }
# sharkrite-extract: worker-loop-end
extra_function() { echo "extra"; }
# sharkrite-extract: worker-loop-end
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "duplicate-end-no-start.sh" ]]

  # Both end marker lines must be reported — count violations for this file.
  # Each violation line has format: "✗ <file>:<line> - UNBALANCED_EXTRACT_MARKERS: ..."
  _violation_count=$(echo "$output" | grep -c "duplicate-end-no-start\.sh.*UNBALANCED_EXTRACT_MARKERS" || true)
  [ "$_violation_count" -eq 2 ]

  # Each violation must reference a distinct line number — guards against the
  # degenerate case where the same line is reported twice instead of two
  # separate orphaned end-markers being reported independently.
  _line1=$(echo "$output" | grep "duplicate-end-no-start\.sh.*UNBALANCED_EXTRACT_MARKERS" | head -1 | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)
  _line2=$(echo "$output" | grep "duplicate-end-no-start\.sh.*UNBALANCED_EXTRACT_MARKERS" | tail -1 | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)
  [ -n "$_line1" ]
  [ -n "$_line2" ]
  [ "$_line1" -ne "$_line2" ]
}

@test "lint rule deduplicates via _seen_pairs when start exists with two ends" {
  # Regression test for the start-matched deduplication path: when a start marker
  # exists alongside two duplicate end markers, the start-marker loop processes
  # the (file, name) pair once (setting _seen_pairs), reports the end imbalance
  # exactly once, and the end-marker loop skips both end occurrences because
  # _seen_pairs already has the key set.  This ensures a future accidental removal
  # of the _seen_pairs guard in the end-marker loop would be caught immediately.
  cat > "$RITE_LINT_TEST_DIR/start-with-duplicate-ends.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# sharkrite-extract: worker-loop-start
do_work() { echo "work"; }
# sharkrite-extract: worker-loop-end
extra_function() { echo "extra"; }
# sharkrite-extract: worker-loop-end
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "start-with-duplicate-ends.sh" ]]

  # The start-marker loop detects the imbalance (end count != 1) and reports it
  # exactly once (one (file, name) pair). The end-marker loop must NOT add more
  # reports for the same pair — _seen_pairs prevents re-entry.
  _violation_count=$(echo "$output" | grep -c "start-with-duplicate-ends\.sh.*UNBALANCED_EXTRACT_MARKERS" || true)
  [ "$_violation_count" -eq 1 ]
}

@test "lint rule detects reversed markers where end appears before start" {
  # Both start and end markers are present (count==1 each), but end precedes
  # start in the file. sed -n '/start/,/end/p' will open the range at the
  # start marker and never find a closing end after it, yielding wrong output.
  # Rule 18's line-ordering check must catch this.
  cat > "$RITE_LINT_TEST_DIR/reversed-markers.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# sharkrite-extract: worker-loop-end
do_work() { echo "work"; }
# sharkrite-extract: worker-loop-start
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "reversed-markers.sh" ]]
}

@test "lint rule allows valid balanced sharkrite-extract marker pair" {
  # Create valid markers in RITE_TEST_ROOT (outside lib/) — linter won't scan it.
  # The important thing is that NO invalid markers exist in the lint fixture dir.
  # (teardown removes any previous fixtures, so the dir is clean here.)
  cat > "$RITE_TEST_ROOT/valid-markers.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

# sharkrite-extract: worker-loop-start
do_work() { echo "work"; }
# sharkrite-extract: worker-loop-end
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  # Confirm Rule 18 actually executed (not silently skipped due to empty file list)
  [[ "$output" =~ "Checking for unbalanced or duplicated sharkrite-extract marker pairs" ]]

  # The codebase may have pre-existing lint violations from other rules, but
  # UNBALANCED_EXTRACT_MARKERS must NOT be flagged (no unbalanced markers exist
  # in the lib/bin/tools source files, and the valid fixture is outside scope).
  [[ ! "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
}

# ---------------------------------------------------------------------------
# Codebase sweep: real sharkrite-extract markers are balanced
# ---------------------------------------------------------------------------

@test "lint rule UNBALANCED_EXTRACT_MARKERS is defined in sharkrite-lint.sh" {
  cd "$PROJECT_ROOT"
  run grep -q "UNBALANCED_EXTRACT_MARKERS" tools/sharkrite-lint.sh
  [ "$status" -eq 0 ]
}

@test "codebase has zero unbalanced sharkrite-extract markers in source files" {
  # Verify that every sharkrite-extract marker in source files (lib/, bin/, tools/)
  # is balanced: each start has exactly one matching end in the same file, and
  # vice versa. Test files (tests/) are excluded because they legitimately reference
  # marker names multiple times inside grep patterns and heredoc fixture scripts.
  # The lint rule Rule 18 (UNBALANCED_EXTRACT_MARKERS) enforces the same invariant
  # at CI time via make check.
  cd "$PROJECT_ROOT"

  run bash -c '
    violations=""

    # Collect source files only — exclude tests/ to avoid false positives from
    # test fixtures that intentionally contain multiple marker occurrences.
    files=$(grep -rl "sharkrite-extract:" lib/ bin/ tools/ 2>/dev/null || true)

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      # Extract unique marker names from this file (strip -start/-end suffix)
      names=$(grep -oE "sharkrite-extract: [a-z0-9_-]+" "$f" 2>/dev/null \
        | sed "s/sharkrite-extract: //" \
        | sed "s/-start$//" \
        | sed "s/-end$//" \
        | sort -u || true)

      while IFS= read -r name; do
        [ -z "$name" ] && continue
        start_count=$(grep -c "# sharkrite-extract: ${name}-start" "$f" 2>/dev/null || true)
        end_count=$(grep -c "# sharkrite-extract: ${name}-end" "$f" 2>/dev/null || true)

        if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
          violations="${violations}$f: marker '\''${name}'\'' start=${start_count} end=${end_count} (expected 1 each)\n"
        fi
      done <<< "$names"
    done <<< "$files"

    if [ -n "$violations" ]; then
      printf "FAIL: Unbalanced sharkrite-extract markers found:\n%s" "$violations"
      exit 1
    fi
    echo "PASS: all sharkrite-extract markers are balanced"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---------------------------------------------------------------------------
# Regression: find -L must not scan test-fixtures-temp in production lint runs
# Issue #194: find -L scans symlinked fixture directory in production lint runs
#
# When bats tests ran, they created lib/test-fixtures-temp → BATS_SUITE_TMPDIR.
# If 'make check' was run simultaneously, find -L followed the live symlink and
# scanned intentionally-invalid fixture files, producing false lint violations.
# Fix: sharkrite-lint.sh now excludes *test-fixtures-temp* from all find scans
# and accepts fixture dirs via RITE_LINT_EXTRA_DIRS instead of symlinks.
# ---------------------------------------------------------------------------

@test "linter excludes test-fixtures-temp symlink even when symlink is live" {
  # Create a fixture directory with a file that would trigger UNBALANCED_EXTRACT_MARKERS.
  # Create it under BATS_TEST_TMPDIR — NOT injected via RITE_LINT_EXTRA_DIRS.
  # Then create a lib/test-fixtures-temp symlink pointing to it.
  # The linter must NOT scan it (the exclusion guard must work).
  _fixture_dir="${BATS_TEST_TMPDIR}/production-lint-fixture"
  _symlink="$PROJECT_ROOT/lib/test-fixtures-temp"
  mkdir -p "$_fixture_dir"
  cat > "$_fixture_dir/sneaky-fixture.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# sharkrite-extract: sneaky-loop-start
do_work() { echo "work"; }
# NOTE: no end marker — would trigger UNBALANCED_EXTRACT_MARKERS
EOF
  # Create the live symlink in lib/ (simulates interrupted bats teardown)
  ln -sf "$_fixture_dir" "$_symlink"

  cd "$PROJECT_ROOT"
  # Run WITHOUT RITE_LINT_EXTRA_DIRS — the fixture should not be injected
  run env -u RITE_LINT_EXTRA_DIRS bash -c 'cd "$1" && tools/sharkrite-lint.sh' _ "$PROJECT_ROOT"

  # Cleanup before assertions (in case assertions fail, symlink is removed)
  rm -f "$_symlink"
  rm -rf "$_fixture_dir"

  # The linter must not report sneaky-fixture.sh — it was excluded by the
  # test-fixtures-temp path exclusion, not injected via RITE_LINT_EXTRA_DIRS.
  [[ "$output" != *"sneaky-fixture.sh"* ]]
  [[ "$output" != *"sneaky-loop"* ]]
}

@test "linter scans fixture dir when injected via RITE_LINT_EXTRA_DIRS" {
  # Verify that the RITE_LINT_EXTRA_DIRS mechanism works: a fixture with an
  # unbalanced marker injected via env var IS detected by the linter.
  # This confirms that the test infrastructure replacement (RITE_LINT_EXTRA_DIRS
  # instead of symlink) actually exercises the lint rules.
  cat > "$RITE_LINT_FIXTURES_DIR/extra-dirs-fixture.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# sharkrite-extract: extra-dirs-loop-start
do_work() { echo "work"; }
# NOTE: no end marker — triggers UNBALANCED_EXTRACT_MARKERS
EOF

  cd "$PROJECT_ROOT"
  run tools/sharkrite-lint.sh

  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNBALANCED_EXTRACT_MARKERS" ]]
  [[ "$output" =~ "extra-dirs-fixture.sh" ]]
}

# ---------------------------------------------------------------------------
# Regression: parallel bats safety — no shared symlink in lib/
# Issue #191: Shared lib/test-fixtures-temp symlink not safe for parallel bats
#
# The previous implementation used a single fixed path lib/test-fixtures-temp
# shared across all tests in a suite. Parallel bats invocations would race to
# create/remove the same symlink. The fix uses BATS_TEST_TMPDIR (unique per
# test) for fixtures and RITE_LINT_EXTRA_DIRS for injection — no shared path.
# ---------------------------------------------------------------------------

@test "test infrastructure does not create lib/test-fixtures-temp symlink" {
  # Verify that setup() no longer creates a symlink in lib/.
  # If this test passes, the parallel-safety fix is in place.
  [ ! -L "$PROJECT_ROOT/lib/test-fixtures-temp" ]
}

@test "fixture dir is unique per test (BATS_TEST_TMPDIR-based)" {
  # Verify that RITE_LINT_FIXTURES_DIR is under BATS_TEST_TMPDIR, not
  # BATS_SUITE_TMPDIR. BATS_TEST_TMPDIR is unique per test, making each
  # test's fixture dir independent for parallel execution safety.
  [[ "$RITE_LINT_FIXTURES_DIR" == "${BATS_TEST_TMPDIR}"* ]]
}
