#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/post-merge-verify.sh
#
# Regression tests for the no-overlap skip removal (#1743).
#
# The no-overlap skip block was removed because it was unreachable for all
# production callers (#854/#1655 updated callers to pass origin/<target>,
# making merge-base(origin/<target>, HEAD) = origin/<target> after a rebase,
# so diff(_mb, pre_merge_ref) was always empty — the guard could never fire).
# The _main_files/_branch_files variable names were also inverted relative to
# their actual contents on the live caller path. Both issues are resolved by
# the removal.
#
# These tests confirm the gate ALWAYS runs regardless of file overlap, and
# preserve the safe-default (bad-ref) and overlapping-rebase behaviors.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export RITE_LIB_DIR="$REPO_ROOT/lib"

  # Pre-stub the gate + deps BEFORE sourcing so post-merge-verify.sh's guard
  # (declare -f run_test_gate) skips sourcing the real test-gate.sh, and so we
  # can detect whether the gate WOULD have run.
  export GATE_MARK="$BATS_TEST_TMPDIR/gate-ran"
  run_test_gate() { echo ran > "$GATE_MARK"; return 0; }
  _diag() { :; }
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: post-merge-verify.sh uses function-sentinel guards (declare -f verify_post_merge, declare -f _diag, declare -f run_test_gate); all pre-source stubs are preserved on source.
  source "$REPO_ROOT/lib/utils/post-merge-verify.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

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

@test "non-overlapping rebase: gate still runs (no-overlap skip was removed in #1743)" {
  # branch adds B.txt; main adds C.txt — disjoint files. With the old code the
  # skip block would have fired (when passed the pre-rebase SHA). After #1743 the
  # block is gone: the gate must always run regardless of file overlap.
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
  [[ "$output" != *"skipped"* ]] || { echo "gate was skipped but no-overlap skip block was removed" >&2; false; }
  [ -f "$GATE_MARK" ] || { echo "gate did not run despite no-overlap skip removal" >&2; false; }
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
