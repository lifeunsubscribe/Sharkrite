#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-health-report
# tests/regression/health-report-finding-recurrence.bats
#
# Verifies that bin/rite-health-report pre-computes RF_BLOCK from ACTIONABLE_NOW
# finding headers in log files:
#   - A title appearing 2+ times → block present with count
#   - All-unique titles → block absent
#   - Reasoning-text mention of ACTIONABLE_NOW (no ### header) → NOT counted
#
# Computation logic lives in the main script body. Tests run the exact pipelines
# as subprocesses via helper scripts written to BATS_TEST_TMPDIR, mirroring the
# precedent from health-report-cr-precompute.bats.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Helper: compute RF_BLOCK from log files listed in LOGFILES env var (space-separated paths).
  # Mirrors the precompute block in bin/rite-health-report exactly.
  cat > "$RITE_TEST_TMPDIR/compute_rf_block.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
RITE_HEALTH_RECURRENCE_MIN="${RITE_HEALTH_RECURRENCE_MIN:-2}"
_RECURRENCE_CAT_MIN=4

_rf_raw_headers=""
_rf_raw_cats=""
for logfile in ${LOGFILES:-}; do
  _rf_raw_headers+=$(grep -E '^### .* - ACTIONABLE_NOW' "$logfile" 2>/dev/null || true)
  _rf_raw_headers+=$'\n'
  _rf_raw_cats+=$(awk '
    /^### .* - ACTIONABLE_NOW/{capture=1; next}
    /^### /{capture=0}
    capture && /\*\*Category:\*\*/{
      sub(/.*\*\*Category:\*\*[[:space:]]*/, "")
      print tolower($0)
      capture=0
    }
  ' "$logfile" 2>/dev/null || true)
  _rf_raw_cats+=$'\n'
done
_rf_raw_headers=$(echo "$_rf_raw_headers" | sed '/^$/d' || true)
_rf_raw_cats=$(echo "$_rf_raw_cats" | sed '/^$/d' || true)

RF_BLOCK=""
if [ -n "$_rf_raw_headers" ]; then
  _rf_normalized=$(echo "$_rf_raw_headers" \
    | sed 's/^### //' \
    | sed 's/ - ACTIONABLE_NOW$//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[[:space:]]\+/ /g' \
    | sed 's/^ //; s/ $//' \
    | sort | uniq -c | sort -k1,1rn -k2 || true)

  _rf_title_lines=""
  while IFS= read -r _rf_entry; do
    _rf_count=$(echo "$_rf_entry" | awk '{print $1}' || true)
    _rf_title=$(echo "$_rf_entry" | sed 's/^[[:space:]]*[0-9]\+[[:space:]]*//' || true)
    if [ -n "$_rf_count" ] && [ -n "$_rf_title" ] \
        && [ "${_rf_count:-0}" -ge "${RITE_HEALTH_RECURRENCE_MIN:-2}" ] 2>/dev/null; then
      _rf_title_lines+="  ${_rf_count}x: ${_rf_title}"$'\n'
    fi
  done <<< "$_rf_normalized"

  _rf_cat_lines=""
  if [ -n "$_rf_raw_cats" ]; then
    _rf_cat_normalized=$(echo "$_rf_raw_cats" \
      | sed 's/[[:space:]]\+/ /g' \
      | sed 's/^ //; s/ $//' \
      | sort | uniq -c | sort -k1,1rn -k2 || true)
    while IFS= read -r _rf_entry; do
      _rf_count=$(echo "$_rf_entry" | awk '{print $1}' || true)
      _rf_cat=$(echo "$_rf_entry" | sed 's/^[[:space:]]*[0-9]\+[[:space:]]*//' || true)
      if [ -n "$_rf_count" ] && [ -n "$_rf_cat" ] \
          && [ "${_rf_count:-0}" -ge "${_RECURRENCE_CAT_MIN:-4}" ] 2>/dev/null; then
        _rf_cat_lines+="  ${_rf_count}x: ${_rf_cat}"$'\n'
      fi
    done <<< "$_rf_cat_normalized"
  fi

  if [ -n "$_rf_title_lines" ] || [ -n "$_rf_cat_lines" ]; then
    RF_BLOCK="Recurring finding classes — lint-rule candidates"
    RF_BLOCK+=" (title threshold: ${RITE_HEALTH_RECURRENCE_MIN}+, category threshold: ${_RECURRENCE_CAT_MIN}+):"
    if [ -n "$_rf_title_lines" ]; then
      RF_BLOCK+=$'\n'"By title (exact-normalized match):"$'\n'"${_rf_title_lines}"
    fi
    if [ -n "$_rf_cat_lines" ]; then
      RF_BLOCK+=$'\n'"By category (coarse backstop for reworded recurrences):"$'\n'"${_rf_cat_lines}"
    fi
  fi
fi
echo "$RF_BLOCK"
EOF
  chmod +x "$RITE_TEST_TMPDIR/compute_rf_block.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Scenario 1: title appearing 2x across two log files → block present
# ---------------------------------------------------------------------------

@test "RF_BLOCK: title appearing 2x across two logs is present with count" {
  printf '### Missing input validation - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Missing input validation - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recurring finding classes"* ]]
  [[ "$output" == *"2x: missing input validation"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 2: all-unique titles → block absent
# ---------------------------------------------------------------------------

@test "RF_BLOCK: all-unique titles produce empty block" {
  printf '### Missing input validation - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Unhandled error path - ACTIONABLE_NOW\n**Category:** correctness\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Scenario 3: reasoning-text mention of ACTIONABLE_NOW (no ### header) NOT counted
# ---------------------------------------------------------------------------

@test "RF_BLOCK: reasoning-text mention of ACTIONABLE_NOW without ### header is not counted" {
  # Log has two occurrences of the phrase but neither is a structured header
  printf 'This was the previous ACTIONABLE_NOW item that was already fixed.\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf 'The prior ACTIONABLE_NOW finding addressed the same concern.\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Additional correctness: LATER and DISMISSED headers are not counted
# ---------------------------------------------------------------------------

@test "RF_BLOCK: ACTIONABLE_LATER and DISMISSED headers do not trigger block" {
  printf '### Missing input validation - ACTIONABLE_LATER\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Missing input validation - DISMISSED\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Category backstop: category appearing 4x triggers the coarse-backstop path
# ---------------------------------------------------------------------------

@test "RF_BLOCK: category appearing 4x triggers category backstop even with unique titles" {
  printf '### Alpha finding - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Beta finding - ACTIONABLE_NOW\n**Category:** security\n' \
    >> "$RITE_TEST_TMPDIR/log1.log"
  printf '### Gamma finding - ACTIONABLE_NOW\n**Category:** security\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  printf '### Delta finding - ACTIONABLE_NOW\n**Category:** security\n' \
    >> "$RITE_TEST_TMPDIR/log2.log"
  run env LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recurring finding classes"* ]]
  [[ "$output" == *"By category"* ]]
  [[ "$output" == *"4x: security"* ]]
}

# ---------------------------------------------------------------------------
# Threshold knob: RITE_HEALTH_RECURRENCE_MIN=3 suppresses a 2x title
# ---------------------------------------------------------------------------

@test "RF_BLOCK: RITE_HEALTH_RECURRENCE_MIN=3 suppresses a title that appears only 2x" {
  printf '### Missing input validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### Missing input validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env RITE_HEALTH_RECURRENCE_MIN=3 \
    LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Normalization: case and extra whitespace do not create spurious distinct entries
# ---------------------------------------------------------------------------

@test "RF_BLOCK: title normalization — case and whitespace differences collapse to same entry" {
  printf '### Missing Input Validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log1.log"
  printf '### missing  input  validation - ACTIONABLE_NOW\n' \
    > "$RITE_TEST_TMPDIR/log2.log"
  run env LOGFILES="$RITE_TEST_TMPDIR/log1.log $RITE_TEST_TMPDIR/log2.log" \
    "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  # Both forms should normalize to the same title and produce a 2x entry
  [[ "$output" == *"2x: missing input validation"* ]]
}

# ---------------------------------------------------------------------------
# No logs / empty logs → block absent
# ---------------------------------------------------------------------------

@test "RF_BLOCK: no log files produces empty block" {
  run env LOGFILES="" "$RITE_TEST_TMPDIR/compute_rf_block.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
