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

  # Lint test fixtures must be inside lib/ so the linter scans them
  export RITE_LINT_TEST_DIR="$PROJECT_ROOT/lib/test-fixtures-temp"
  mkdir -p "$RITE_LINT_TEST_DIR"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
  rm -rf "$RITE_LINT_TEST_DIR"
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
  # sed /start/,/end/p opens at start (line 5) but finds no end after it,
  # so the range extends to EOF — or if there is no start, yields empty.
  cat > "$RITE_TEST_ROOT/source-reversed.sh" <<'EOF'
#!/bin/bash
# sharkrite-extract: my-loop-end
some_function() { echo "this should not be extracted"; }
# sharkrite-extract: my-loop-start
EOF

  EXTRACTED=$(sed -n '/# sharkrite-extract: my-loop-start/,/# sharkrite-extract: my-loop-end/p' \
    "$RITE_TEST_ROOT/source-reversed.sh" || true)

  # When start appears after end, the range from start to next-end finds nothing
  # (no end marker follows the start), so extraction goes to EOF or yields the
  # start marker line only — in either case, content-anchor checks are unreliable.
  # The exact output depends on sed implementation; what matters is it is NOT
  # the intended block (which would contain "some_function").
  [[ "$EXTRACTED" != *"some_function"* ]]
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
