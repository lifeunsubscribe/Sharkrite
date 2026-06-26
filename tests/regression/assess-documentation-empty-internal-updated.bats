#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
# Regression test: INTERNAL_UPDATED[@] loops must not crash under bash 3.2 + set -u
#
# Bug: lib/core/assess-documentation.sh had three `for` loops iterating
# "${INTERNAL_UPDATED[@]}" without the empty-array-safe idiom. Under bash 3.2
# (macOS /bin/bash) and `set -u`, an empty array reference crashes with:
#   INTERNAL_UPDATED[@]: unbound variable
#
# Affected loops (before fix):
#   Line ~1148: re-collect dedup after reconciliation
#   Line ~1263: RECONCILED detection (primary bug report site, issue #721)
#   Line ~1289: final marker collection
#
# Fix: replaced all three with the PR #266 empty-array-safe idiom:
#   "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"
# This expands to nothing when the array is empty, satisfying set -u.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ASSESS_DOC_SCRIPT="$PROJECT_ROOT/lib/core/assess-documentation.sh"
}

# ---------------------------------------------------------------------------
# Static checks: confirm all three loops use the empty-array-safe idiom
# ---------------------------------------------------------------------------

@test "assess-documentation.sh: RECONCILED loop uses empty-array-safe idiom" {
  # The RECONCILED detection loop must use the "${arr[@]+"${arr[@]}"}" idiom.
  # Match the pattern that surrounds the "for item in" loop.
  run grep -c 'for item in "\${INTERNAL_UPDATED\[@\]+' "$ASSESS_DOC_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "assess-documentation.sh: re-collect dedup loop uses empty-array-safe idiom" {
  # There are two dedup loops (_existing in ...) — both must use the safe idiom.
  run grep -c 'for _existing in "\${INTERNAL_UPDATED\[@\]+' "$ASSESS_DOC_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "assess-documentation.sh: no bare INTERNAL_UPDATED[@] in for-loop heads" {
  # No `for ... in "${INTERNAL_UPDATED[@]}"` (without the +idiom) should remain.
  # The only safe bare references are inside the length-guarded `if` block.
  run bash -c "
    grep -n 'for.*in \"\${INTERNAL_UPDATED\[@\]}\"' '$ASSESS_DOC_SCRIPT' || true
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Behavioral checks: the empty-array idiom runs correctly under /bin/bash
# ---------------------------------------------------------------------------

@test "RECONCILED loop is safe with empty INTERNAL_UPDATED under /bin/bash set -u" {
  # Reproduces the exact crash path from issue #721.
  # The RECONCILED loop ran over an empty INTERNAL_UPDATED and crashed with:
  #   INTERNAL_UPDATED[@]: unbound variable
  run /bin/bash -c '
    set -euo pipefail
    INTERNAL_UPDATED=()
    RECONCILED=false
    for item in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      if echo "$item" | grep -q "reconciled"; then
        RECONCILED=true
        break
      fi
    done
    echo "RECONCILED=$RECONCILED"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "RECONCILED=false" ]]
}

@test "RECONCILED loop detects reconciled item when array is non-empty" {
  run /bin/bash -c '
    set -euo pipefail
    INTERNAL_UPDATED=("overview" "adr(reconciled)" "changelog")
    RECONCILED=false
    for item in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      if echo "$item" | grep -q "reconciled"; then
        RECONCILED=true
        break
      fi
    done
    echo "RECONCILED=$RECONCILED"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "RECONCILED=true" ]]
}

@test "re-collect dedup loop is safe with empty INTERNAL_UPDATED under /bin/bash set -u" {
  # Simulates the dedup loop that runs after reconciliation / final marker collection.
  run /bin/bash -c '
    set -euo pipefail
    INTERNAL_UPDATED=()
    _name="overview"
    _found=false
    for _existing in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      [ "$_existing" = "$_name" ] && { _found=true; break; }
    done
    [ "$_found" = false ] && INTERNAL_UPDATED+=("$_name")
    echo "count=${#INTERNAL_UPDATED[@]}"
    echo "item=${INTERNAL_UPDATED[0]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
  [[ "$output" == *"item=overview"* ]]
}

@test "re-collect dedup loop skips duplicates correctly" {
  run /bin/bash -c '
    set -euo pipefail
    INTERNAL_UPDATED=("overview" "adr")
    _name="overview"
    _found=false
    for _existing in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      [ "$_existing" = "$_name" ] && { _found=true; break; }
    done
    [ "$_found" = false ] && INTERNAL_UPDATED+=("$_name")
    echo "count=${#INTERNAL_UPDATED[@]}"
  '
  [ "$status" -eq 0 ]
  # overview was already present — must NOT be added again
  [[ "$output" == "count=2" ]]
}

@test "no unbound variable error from INTERNAL_UPDATED loops under /bin/bash set -u" {
  # End-to-end: run all three loop patterns in sequence with an empty array,
  # capturing both stdout and stderr. Must produce zero output mentioning
  # "unbound variable".
  run /bin/bash -c '
    set -euo pipefail
    INTERNAL_UPDATED=()

    # Loop 1: re-collect dedup (post-reconciliation)
    _name="doc-a"
    _found=false
    for _existing in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      [ "$_existing" = "$_name" ] && { _found=true; break; }
    done
    [ "$_found" = false ] && INTERNAL_UPDATED+=("$_name")

    # Loop 2: RECONCILED detection
    RECONCILED=false
    for item in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      if echo "$item" | grep -q "reconciled"; then
        RECONCILED=true
        break
      fi
    done

    # Loop 3: final marker collection dedup
    _name2="doc-b"
    _found2=false
    for _existing in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
      [ "$_existing" = "$_name2" ] && { _found2=true; break; }
    done
    [ "$_found2" = false ] && INTERNAL_UPDATED+=("$_name2")

    echo "OK count=${#INTERNAL_UPDATED[@]}"
  ' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  ! [[ "$output" == *"unbound variable"* ]]
}
