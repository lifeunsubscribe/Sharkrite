#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh::_mpr_await_mergeable
# tests/regression/await-mergeable-after-push.bats
#
# GitHub computes a PR's mergeability lazily, and a PUSH INVALIDATES it. So
# right after pushing, `mergeable` reads UNKNOWN — meaning "not computed yet",
# never "conflicting".
#
# merge-pr.sh already knew this for its FIRST read and retried there. The two
# post-push re-checks did not: each did a bare `sleep 3` and one read, at the
# exact moment the answer is least likely to be ready, because the push that
# invalidated it had just completed.
#
# Live failure: issue #1273, PR #1336. The conflict resolver succeeded, its
# resolutions were committed and pushed, and the single read that followed came
# back UNKNOWN. That was reported as
#
#     ❌ PR still not mergeable after resolution (state: UNKNOWN)
#     ❌ PR has merge conflicts that could not be auto-resolved
#
# and the issue failed after 17m30s of real work. Polling the same PR moments
# later returned MERGEABLE three times running — it had been mergeable all along.
#
# Tests in this file:
#   1. returns the state as soon as GitHub reports a real one
#   2. keeps polling through UNKNOWN and returns the eventual answer
#   3. returns CONFLICTING unchanged — a real conflict must still fail
#   4. gives up as UNKNOWN after the attempt budget, exit 0 (never kills set -e)
#   5. no post-push site does a bare single read any more

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
MERGE_PR="$REPO_ROOT/lib/core/merge-pr.sh"

setup() {
  [ -f "$MERGE_PR" ] || { echo "FATAL: $MERGE_PR not found" >&2; return 1; }
  _tmpdir=$(mktemp -d)
  _seq="$_tmpdir/seq"
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Drive the helper with a scripted sequence of gh responses (one per line).
_run_helper() {
  printf '%s\n' "$1" > "$_seq"
  run bash -c "
    set -uo pipefail
    _SEQ='$_seq'
    # Stub gh_safe: pop the next scripted state each call.
    gh_safe() {
      local _n
      _n=\$(head -1 \"\$_SEQ\")
      sed -i.bak '1d' \"\$_SEQ\" 2>/dev/null || true
      printf '%s\n' \"\$_n\"
    }
    # sleep is a no-op so the test does not actually wait.
    sleep() { :; }
    print_status() { :; }
    $(sed -n '/^_mpr_await_mergeable()/,/^}/p' "$MERGE_PR")
    _mpr_await_mergeable 1336 ${2:-8}
  "
}

@test "returns the state immediately when GitHub has already computed it" {
  _run_helper "MERGEABLE"

  [ "$status" -eq 0 ] || { echo "FAIL: exit $status: $output" >&2; return 1; }
  [ "$output" = "MERGEABLE" ] || {
    echo "FAIL: expected MERGEABLE, got '$output'" >&2
    return 1
  }
}

@test "polls through UNKNOWN and returns the eventual answer" {
  # This is the #1273 shape: the first reads land before GitHub finishes.
  _run_helper "UNKNOWN
UNKNOWN
UNKNOWN
MERGEABLE"

  [ "$output" = "MERGEABLE" ] || {
    echo "FAIL: expected MERGEABLE after polling, got '$output'" >&2
    echo "      a single read here is what failed issue #1273" >&2
    return 1
  }
}

@test "returns CONFLICTING unchanged — a real conflict must still fail" {
  # The fix must not paper over genuine conflicts by waiting them out.
  _run_helper "UNKNOWN
CONFLICTING"

  [ "$output" = "CONFLICTING" ] || {
    echo "FAIL: expected CONFLICTING to pass through, got '$output'" >&2
    return 1
  }
}

@test "gives up as UNKNOWN after the budget and still exits 0" {
  # Callers branch on the string under `set -e`; a non-zero return would take
  # the whole merge phase down instead of reporting an indeterminate state.
  _run_helper "UNKNOWN
UNKNOWN
UNKNOWN" 2

  [ "$status" -eq 0 ] || {
    echo "FAIL: must exit 0 even when the state never resolves (got $status)" >&2
    return 1
  }
  [ "$output" = "UNKNOWN" ] || {
    echo "FAIL: expected UNKNOWN after exhausting attempts, got '$output'" >&2
    return 1
  }
}

@test "structural: no post-push site does a bare single mergeable read" {
  # Every read of .mergeable must go through the helper. A bare read followed
  # by a verdict is the bug.
  _bare=$(grep -n "json mergeable" "$MERGE_PR" \
            | grep -v '_mpr_await_mergeable' \
            | grep -v '^[0-9]*:[[:space:]]*#' || true)

  # The helper itself contains the only legitimate raw read.
  _count=$(printf '%s\n' "$_bare" | grep -c 'json mergeable' || true)
  [ "${_count:-0}" -le 1 ] || {
    echo "FAIL: more than one raw .mergeable read remains:" >&2
    echo "$_bare" >&2
    echo "      post-push reads must use _mpr_await_mergeable" >&2
    return 1
  }
}
