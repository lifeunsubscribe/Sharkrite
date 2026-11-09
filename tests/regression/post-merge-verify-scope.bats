#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh, lib/utils/post-merge-verify.sh, lib/utils/stale-branch.sh
# tests/regression/post-merge-verify-scope.bats — post-merge (behind-target) gate
# is scoped to branch-own changes on resume (#1655).
#
# Live failure (2026-11-08): batch slot 1/8 — PR #1569's worktree merged 29 main
# commits; verify_post_merge defaulted to HEAD~1, so the gate selected 311/385
# bats files (3,729 tests). Root: same ruling as #854 for rebases applies equally
# to the merge path in claude-workflow.sh. Fix: pass origin/${_target} as the
# pre_merge_ref so the diff covers only the branch's own files.

setup() { export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"; }

@test "structural: claude-workflow.sh behind-target merge block passes origin/\${_target} to verify_post_merge" {
  # After #1655, the call must supply the target ref as the second arg — no bare call.
  _bare=$(grep -nE 'verify_post_merge "[.]" *$' \
    "${RITE_LIB_DIR}/core/claude-workflow.sh" || true)
  [ -z "$_bare" ] || {
    echo "claude-workflow.sh still calls verify_post_merge without a base ref:" >&2
    echo "$_bare" >&2
    return 1
  }
  grep -qF 'verify_post_merge "." "origin/${_target}"' \
    "${RITE_LIB_DIR}/core/claude-workflow.sh"
}

@test "structural: no bare verify_post_merge call in lib/ — every caller passes a second arg (#1655/#1687)" {
  # A bare call (only the worktree_path arg) falls back to HEAD~1, gating the full
  # merge delta from main instead of branch-own files. The grep matches any call
  # whose first quoted arg is immediately followed by ;, end-of-line, or ||.
  _bare=$(grep -rnE 'verify_post_merge "[^"]+"\s*(;|$|\|\|)' "${RITE_LIB_DIR}" 2>/dev/null || true)
  [ -z "$_bare" ] || {
    echo "verify_post_merge called without a second arg (target ref) in lib/:" >&2
    echo "$_bare" >&2
    return 1
  }
}

@test "behavioral: verify_post_merge forwards the target ref to RITE_TEST_GATE_DIFF_BASE" {
  _capture="$BATS_TEST_TMPDIR/base_capture"
  set +u; set +o pipefail
  # shellcheck source=/dev/null
  source "${RITE_LIB_DIR}/utils/post-merge-verify.sh"
  run_test_gate() {
    echo "${RITE_TEST_GATE_DIFF_BASE:-UNSET}" > "$_capture"
    printf '{"lint":[],"tests":[],"exit_code":0}\n' > "$1"
    return 0
  }
  export -f run_test_gate 2>/dev/null || true
  _wt=$(mktemp -d "$BATS_TEST_TMPDIR/wt_XXXXXX")
  ( cd "$_wt" \
    && git init -q . \
    && git commit -q --allow-empty -m init 2>/dev/null \
    && printf 'shellcheck:\n\ttrue\nlint:\n\ttrue\n' > Makefile )
  verify_post_merge "$_wt" "origin/main" || true
  [ -f "$_capture" ]
  [ "$(cat "$_capture")" = "origin/main" ]
}
