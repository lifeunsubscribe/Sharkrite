#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/post-merge-verify.sh
#
# verify_post_merge skips the targeted gate when a stale-branch rebase pulled in
# only files that do NOT overlap the branch's own changes — a semantic conflict
# is impossible there, so verifying is pure waste (and the wasted minutes let
# main advance, putting the branch behind again: the treadmill). Added 2026-06-16
# after #649/#631 resumes re-ran a 33-file gate on a 2-commit rebase that could
# not have introduced any conflict.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export RITE_LIB_DIR="$REPO_ROOT/lib"

  # Pre-stub the gate + deps BEFORE sourcing so post-merge-verify.sh's guard
  # (declare -f run_test_gate) skips sourcing the real test-gate.sh, and so we
  # can detect whether the gate WOULD have run.
  export GATE_MARK="$BATS_TEST_TMPDIR/gate-ran"
  run_test_gate() { echo ran > "$GATE_MARK"; return 0; }
  _diag() { :; }
  source "$REPO_ROOT/lib/utils/post-merge-verify.sh"

  # Temp git repo that LOOKS like sharkrite (Makefile with shellcheck:+lint:),
  # so the gate path is taken whenever verification is NOT skipped.
  WT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WT"
  git -C "$WT" init -q -b main
  git -C "$WT" config user.email t@t
  git -C "$WT" config user.name t
  printf 'shellcheck:\n\t@true\nlint:\n\t@true\n' > "$WT/Makefile"
  printf 'line1\nline2\n' > "$WT/A.txt"
  git -C "$WT" add -A
  git -C "$WT" commit -qm base
  git -C "$WT" update-ref refs/remotes/origin/main main
}

@test "no-overlap rebase: verification skipped, gate never runs" {
  # branch adds B.txt; main adds C.txt — disjoint files.
  git -C "$WT" checkout -q -b feat
  echo b > "$WT/B.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "branch B"
  PRE=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" checkout -q main
  echo c > "$WT/C.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "main C"
  git -C "$WT" update-ref refs/remotes/origin/main main
  git -C "$WT" checkout -q feat
  git -C "$WT" rebase -q origin/main

  rm -f "$GATE_MARK"
  run verify_post_merge "$WT" "$PRE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || { echo "expected skip message; got: $output" >&2; false; }
  [ ! -f "$GATE_MARK" ] || { echo "gate ran despite no overlap" >&2; false; }
}

@test "overlapping rebase: verification runs the gate" {
  # branch edits A.txt line1; main appends to A.txt — same file, non-conflicting
  # hunks (so the rebase applies cleanly) but an overlapping footprint.
  git -C "$WT" checkout -q -b feat
  printf 'BRANCH\nline2\n' > "$WT/A.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "branch A"
  PRE=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" checkout -q main
  printf 'line1\nline2\nMAIN\n' > "$WT/A.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "main A"
  git -C "$WT" update-ref refs/remotes/origin/main main
  git -C "$WT" checkout -q feat
  git -C "$WT" rebase -q origin/main

  rm -f "$GATE_MARK"
  run verify_post_merge "$WT" "$PRE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]] || { echo "wrongly skipped an overlapping rebase" >&2; false; }
  [ -f "$GATE_MARK" ] || { echo "gate did not run despite overlap" >&2; false; }
}

@test "unresolvable pre_ref falls through to verifying (safe default)" {
  # A bad pre_merge_ref makes merge-base fail; must NOT skip — verify instead.
  git -C "$WT" checkout -q -b feat
  echo b > "$WT/B.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "branch B"

  rm -f "$GATE_MARK"
  run verify_post_merge "$WT" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]] || { echo "skipped on a bad ref (should verify)" >&2; false; }
  [ -f "$GATE_MARK" ] || { echo "gate did not run on the safe-default path" >&2; false; }
}
