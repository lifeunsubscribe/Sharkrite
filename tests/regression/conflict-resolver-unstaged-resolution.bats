#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh
#
# attempt_claude_merge_resolution's Step-6 verification must accept a resolution
# that is correct in the WORKING TREE but not staged (#1314).
#
# That is the function's documented contract: the session prompt says "do NOT
# run git add", and the header says the caller stages via
# commit_resolved_conflicts "because the session cannot run git side effects".
# So every known conflict path is still unmerged in the index at verification
# time, by design.
#
# The original Check 1 (#435) predated that split and asserted an EMPTY index.
# #932 moved staging out of the session and added the no-git-add instruction but
# left the assertion behind, so the check could only pass when the session
# DISOBEYED. Once it complied, every Claude conflict resolution failed with
# "Unresolved files remain" right after reporting a correct resolution — live:
# #1231 (pr 1299) and #1143 (pr 1312), both 2026-10-19, both correctly merging
# append-only drift-log entries and both rejected.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SUT="$RITE_REPO_ROOT/lib/utils/conflict-resolver.sh"
  REPO="$BATS_TEST_TMPDIR/conflict-repo"
  mkdir -p "$REPO"
  (
    cd "$REPO" || exit 1
    git init -q .
    git config user.email t@t
    git config user.name t
    printf 'line1\n' > f.md
    git add -A && git commit -qm base
    git checkout -qb side
    printf 'line1\nSIDE\n' > f.md && git commit -qam side
    git checkout -q -
    printf 'line1\nMAIN\n' > f.md && git commit -qam main
    git merge side >/dev/null 2>&1 || true
  ) >/dev/null 2>&1
}

# Step-6 Check 1, lifted from the source so the test tracks the real logic.
_run_check1() {
  local _cr_conflict_files="$1"
  eval "$(sed -n '/# Check 1: No UNEXPECTED unmerged files/,/^  fi$/p' "$SUT" \
    | sed 's/_cr_error/echo/; s/ >&2//; s/git merge --abort.*//; s/return 1/return 1/')"
}

@test "Step 6 accepts a resolution written to the working tree but not staged" {
  cd "$REPO"
  [ "$(git diff --name-only --diff-filter=U | wc -l | tr -d ' ')" -eq 1 ]
  # A COMPLIANT session: write resolved content, do not stage.
  printf 'line1\nMAIN\nSIDE\n' > f.md

  run _run_check1 "f.md"
  [ "$status" -eq 0 ] || {
    echo "Check 1 rejected a correct unstaged resolution — the #1231/#1143 failure:"
    echo "$output"
    false
  }
}

@test "Step 6 still rejects an unmerged path the session was never given" {
  cd "$REPO"
  printf 'line1\nMAIN\nSIDE\n' > f.md
  # Fabricate a second unmerged entry absent from the conflict list.
  printf 'other\n' > g.md
  local _blob
  _blob=$(git hash-object -w g.md)
  git update-index --index-info <<EOF
100644 $_blob 1	g.md
100644 $_blob 2	g.md
EOF
  run _run_check1 "f.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "g.md"
}

@test "Check 2 is what rejects leftover conflict markers, not Check 1" {
  cd "$REPO"
  # Untouched merge output still carries markers.
  grep -qE '^<<<<<<<[[:space:]]' f.md
  # Check 1 passes (the path IS a known conflict path)...
  run _run_check1 "f.md"
  [ "$status" -eq 0 ]
  # ...and Check 2's regex is the one that catches it.
  run bash -c "tr -d '\r' < '$REPO/f.md' | grep -qE '^(<<<<<<<[[:space:]]|=======\$|>>>>>>>[[:space:]]|\|\|\|\|\|\|\|[[:space:]])'"
  [ "$status" -eq 0 ]
}

@test "structural: Check 1 does not assert an empty index" {
  # The regression this file exists for. A bare count of diff-filter=U with a
  # -ne 0 rejection cannot coexist with the no-git-add prompt.
  local _region
  _region=$(sed -n '/# Check 1:/,/# Check 2:/p' "$SUT")
  [ -n "$_region" ]
  ! echo "$_region" | grep -qE '_cr_remaining.*-ne 0'
  # It must compare against the known conflict path list instead.
  echo "$_region" | grep -q '_cr_conflict_files'
}

@test "structural: the session prompt and the verification agree on staging" {
  # If the prompt ever stops forbidding git add, Check 1's premise changes.
  # Keep them visibly coupled so the next edit has to consider both.
  grep -q "do NOT run git add" "$SUT"
  grep -q "caller stages via" "$SUT" || grep -q "commit_resolved_conflicts" "$SUT"
}
