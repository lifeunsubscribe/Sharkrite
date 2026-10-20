#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh
#
# Step-6 Check 2's marker scan must ignore conflict markers inside ``` fences
# (#1364).
#
# docs/architecture/behavioral-design.md documents this exact conflict shape
# with a literal example at column 0 inside a fenced block (added by #1319). A
# plain grep matched it, so EVERY conflict touching that file became
# permanently unresolvable — and it is the most frequently conflicted file in
# the repo.
#
# Live: #1221's rebase failed with "Conflict markers remain in:
# docs/architecture/behavioral-design.md" while the resolver session itself
# reported "the remaining <<<<<<< at line 2225 is inside a documentation code
# block, not an actual conflict marker". The session was right.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUT="$RITE_REPO_ROOT/lib/utils/conflict-resolver.sh"
  FIX="$BATS_TEST_TMPDIR"
}

# The scan exactly as Check 2 runs it, lifted from source so the test tracks
# the real implementation rather than a copy of it.
_scan() {
  tr -d '\r' < "$1" 2>/dev/null | awk '
    /^```/ { fence = !fence; next }
    !fence && /^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]]|\|\|\|\|\|\|\|[[:space:]])/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
}

@test "a fenced documentation example is NOT flagged" {
  printf 'intro\n```\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> side\n```\ntail\n' > "$FIX/doc.md"
  run _scan "$FIX/doc.md"
  [ "$status" -ne 0 ]
}

@test "the real behavioral-design.md is NOT flagged" {
  # The file that actually broke #1221. If this regresses, every conflict
  # involving it becomes unresolvable again.
  run _scan "$RITE_REPO_ROOT/docs/architecture/behavioral-design.md"
  [ "$status" -ne 0 ] || {
    echo "behavioral-design.md flagged as containing conflict markers — #1221 class regression"
    grep -nE '^<<<<<<< |^=======$|^>>>>>>> ' "$RITE_REPO_ROOT/docs/architecture/behavioral-design.md" | head -5
    false
  }
}

@test "a genuine leftover marker at top level IS flagged" {
  printf 'line\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> side\n' > "$FIX/real.md"
  run _scan "$FIX/real.md"
  [ "$status" -eq 0 ]
}

@test "a real marker outside a fence is flagged even when a fenced example exists" {
  printf 'intro\n```\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> side\n```\ntail\n<<<<<<< HEAD\nreal\n=======\nalso\n>>>>>>> side\n' > "$FIX/both.md"
  run _scan "$FIX/both.md"
  [ "$status" -eq 0 ]
}

@test "diff3 base-version markers are still caught outside fences" {
  printf 'x\n||||||| base\nold\n' > "$FIX/diff3.md"
  run _scan "$FIX/diff3.md"
  [ "$status" -eq 0 ]
}

@test "a non-markdown file with no fences behaves exactly as before" {
  printf '#!/bin/bash\n<<<<<<< HEAD\necho a\n=======\necho b\n>>>>>>> side\n' > "$FIX/script.sh"
  run _scan "$FIX/script.sh"
  [ "$status" -eq 0 ]
}

@test "structural: Check 2 uses the fence-aware awk, not a bare grep" {
  local _region
  _region=$(sed -n '/FENCE-AWARE/,/_cr_conflict_files$/p' "$SUT")
  [ -n "$_region" ]
  echo "$_region" | grep -q 'fence = !fence'
  # The bare grep form must be gone from the scan.
  ! echo "$_region" | grep -qE 'grep -qE .\^\(<<<<<<<'
}

@test "structural: the tradeoff is documented at the check" {
  # A real conflict opening inside an already-open fence is skipped. That is
  # deliberate and must stay written down next to the code.
  sed -n '/FENCE-AWARE/,/local _cr_marker_found/p' "$SUT" | grep -qi "tradeoff"
}
