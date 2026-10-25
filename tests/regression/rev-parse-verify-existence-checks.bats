#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/repo-status.sh, lib/utils/stale-branch.sh, lib/utils/divergence-handler.sh, lib/utils/pr-detection.sh, lib/utils/mid-run-rebase.sh, lib/core/workflow-runner.sh, lib/core/merge-pr.sh, lib/core/promote-branch.sh
# tests/regression/rev-parse-verify-existence-checks.bats
#
# `git rev-parse <ref>` is not an existence check. On a MISSING ref it writes
# the LITERAL ARGUMENT to stdout and exits 128:
#
#     $ git rev-parse origin/gone 2>/dev/null; echo "exit=$?"
#     origin/gone
#     exit=128
#
# So the idiom `x=$(git rev-parse "origin/$b" 2>/dev/null || echo "")` captures
# the string "origin/gone", not "". Every `[ -z "$x" ]` / `[ -n "$x" ]` built on
# it is inverted: a ref that does not exist reads as one that does. The
# `|| echo ""` never helps — rev-parse already wrote to stdout before failing.
#
# `--verify --quiet` is the correct probe: silent, exit 1, nothing on stdout.
#
# Live symptom: `rite --status` listed gate-refactor, plan-quality and
# supervised-ux as Integration Branches forever after promotion. The retirement
# check in render_integration_branches is
#
#     all entries promoted AND no in-flight PRs AND no origin/<branch> ref
#
# and the third clause could never be true, so a fully-retired ledger rendered
# an empty header in perpetuity. Four other sites had the same inversion with
# quieter consequences (unpushed counts, "cannot determine HEAD state" guards).
#
# Tests in this file:
#   1. the premise: bare rev-parse really does echo the missing ref
#   2. --verify --quiet really is silent and non-zero
#   3. no ref-existence rev-parse in lib/ is missing --verify
#   4. a fully-retired ledger renders nothing
#   5. a ledger with an unpromoted entry still renders
#   6. a ledger whose branch still exists on the remote still renders

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# A throwaway repo with one commit, so rev-parse has something real to resolve.
_make_repo() {
  git -C "$_tmpdir" init -q 2>/dev/null
  git -C "$_tmpdir" config user.email t@t.t
  git -C "$_tmpdir" config user.name t
  echo x > "$_tmpdir/f"
  git -C "$_tmpdir" add f
  git -C "$_tmpdir" commit -qm init
}

# Render the integration section against a synthetic ledger dir.
_render() {
  bash -c "
    set -uo pipefail
    export RITE_STATE_DIR='$_tmpdir/state'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    source '$REPO_ROOT/lib/utils/colors.sh' 2>/dev/null || true
    source '$REPO_ROOT/lib/utils/integration-ledger.sh' 2>/dev/null || true
    source '$REPO_ROOT/lib/utils/repo-status.sh' 2>/dev/null || true
    cd '$_tmpdir'
    render_integration_branches '${1:-[]}' '' 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  "
}

# =============================================================================
# PREMISE — pin the git behavior the bug rests on
# =============================================================================

@test "premise: bare rev-parse echoes the missing ref to stdout" {
  _make_repo
  run bash -c "git -C '$_tmpdir' rev-parse 'origin/definitely-gone' 2>/dev/null || echo ''"

  [ "$output" = "origin/definitely-gone" ] || {
    echo "FAIL: expected the literal ref echoed, got: '$output'" >&2
    echo "      if git changed this, the idiom may be safe again — but the" >&2
    echo "      --verify form is correct either way" >&2
    return 1
  }
}

@test "premise: --verify --quiet is silent and non-zero on a missing ref" {
  _make_repo
  run bash -c "git -C '$_tmpdir' rev-parse --verify --quiet 'origin/definitely-gone' 2>/dev/null || echo ''"

  [ -z "$output" ] || {
    echo "FAIL: --verify --quiet produced output: '$output'" >&2
    return 1
  }

  # And it still resolves a ref that DOES exist.
  run bash -c "git -C '$_tmpdir' rev-parse --verify --quiet HEAD 2>/dev/null || echo ''"
  [ -n "$output" ] || {
    echo "FAIL: --verify --quiet failed to resolve HEAD" >&2
    return 1
  }
}

# =============================================================================
# SWEEP — the class must not come back
# =============================================================================

@test "sweep: no ref-existence rev-parse in lib/ omits --verify" {
  _bad=$(grep -rnE 'rev-parse "(origin/|refs/)' "$REPO_ROOT/lib/" \
           | grep -v -- '--verify' || true)

  [ -z "$_bad" ] || {
    echo "FAIL: rev-parse used as a ref probe without --verify:" >&2
    echo "$_bad" >&2
    echo "" >&2
    echo "      On a missing ref this captures the literal argument, so any" >&2
    echo "      -z/-n test on the result is inverted. Use:" >&2
    echo "        git rev-parse --verify --quiet \"origin/\$b\" 2>/dev/null || true" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIOR — the symptom she reported
# =============================================================================

@test "retire: a fully-promoted ledger whose branch is gone renders nothing" {
  _make_repo
  mkdir -p "$_tmpdir/state/integration-branches"
  printf 'issue=1236\tpr=1276\tsha=%s\tmerged_at=2026-10-19T21:36:24Z\tpromoted=true\n' \
    "$(git -C "$_tmpdir" rev-parse HEAD)" \
    > "$_tmpdir/state/integration-branches/gate-refactor.log"

  run _render

  [ -z "$output" ] || {
    echo "FAIL: retired ledger still rendered:" >&2
    echo "$output" >&2
    echo "      all entries promoted, no PRs, no origin/gate-refactor ref —" >&2
    echo "      this ledger is done and must disappear from --status" >&2
    return 1
  }
}

@test "retain: a ledger with an unpromoted entry still renders" {
  _make_repo
  mkdir -p "$_tmpdir/state/integration-branches"
  printf 'issue=1240\tpr=1311\tsha=%s\tmerged_at=2026-10-20T00:15:05Z\tpromoted=false\n' \
    "$(git -C "$_tmpdir" rev-parse HEAD)" \
    > "$_tmpdir/state/integration-branches/pending-work.log"

  run _render

  echo "$output" | grep -q 'pending-work' || {
    echo "FAIL: a branch with unpromoted work must stay visible" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "retain: a ledger whose branch still exists on origin still renders" {
  _make_repo
  # Give the repo a real origin/<branch> ref so the third clause is false.
  git -C "$_tmpdir" update-ref refs/remotes/origin/live-branch \
    "$(git -C "$_tmpdir" rev-parse HEAD)"
  mkdir -p "$_tmpdir/state/integration-branches"
  printf 'issue=1241\tpr=1316\tsha=%s\tmerged_at=2026-10-20T01:43:11Z\tpromoted=true\n' \
    "$(git -C "$_tmpdir" rev-parse HEAD)" \
    > "$_tmpdir/state/integration-branches/live-branch.log"

  run _render

  echo "$output" | grep -q 'live-branch' || {
    echo "FAIL: branch still on origin must stay visible even when fully promoted" >&2
    echo "      output: $output" >&2
    return 1
  }
}
