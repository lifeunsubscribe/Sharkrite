#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/stale-branch.sh, lib/utils/divergence-handler.sh, lib/utils/post-merge-verify.sh
# tests/regression/post-rebase-verify-scope.bats — post-rebase verification is
# scoped to branch changes (#854).
#
# Live failure (2026-07-02/03): rebase-path verify_post_merge passed the
# pre-rebase HEAD as diff base, so targeted selection covered every rebased-in
# main commit — 181/229 bats files (~1,800 tests) for a 2-commit branch,
# re-paid on every failed-downstream restart. The main delta was already gated
# per-merge (green-main); branch coverage against the post-rebase tree answers
# the rebase-conflict question.

setup() { export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"; }

@test "structural: rebase call sites pass origin/main, never a pre-rebase ref" {
  _bad=$(grep -nE 'verify_post_merge .*(pre_rebase|_pre_rebase)' \
    "${RITE_LIB_DIR}/utils/stale-branch.sh" \
    "${RITE_LIB_DIR}/utils/divergence-handler.sh" || true)
  [ -z "$_bad" ] || { echo "rebase-path verify still uses pre-rebase base:" >&2; echo "$_bad" >&2; return 1; }
  _good=$(grep -c 'verify_post_merge "\$worktree_path" "origin/main"' \
    "${RITE_LIB_DIR}/utils/stale-branch.sh")
  [ "$_good" -ge 3 ]
  grep -q 'verify_post_merge "." "origin/main"' "${RITE_LIB_DIR}/utils/divergence-handler.sh"
}

@test "structural: merge-context call sites keep the HEAD~1 default (no second arg)" {
  # stale-branch legacy merge path + claude-workflow post-merge remain default-based.
  _merge_sites=$(grep -c 'verify_post_merge "\$worktree_path";' "${RITE_LIB_DIR}/utils/stale-branch.sh" || true)
  [ "$_merge_sites" -ge 2 ]
}

@test "behavioral: verify_post_merge forwards the given base into RITE_TEST_GATE_DIFF_BASE" {
  _capture="$BATS_TEST_TMPDIR/base_capture"
  # Source only the function, stub run_test_gate to capture the env it receives.
  set +u; set +o pipefail
  # shellcheck source=/dev/null
  source "${RITE_LIB_DIR}/utils/post-merge-verify.sh"
  run_test_gate() { echo "${RITE_TEST_GATE_DIFF_BASE:-UNSET}" > "$_capture"; printf '{"lint":[],"tests":[],"exit_code":0}\n' > "$1"; return 0; }
  export -f run_test_gate 2>/dev/null || true
  _wt=$(mktemp -d "$BATS_TEST_TMPDIR/wt_XXXXXX")
  ( cd "$_wt" && git init -q . && git commit -q --allow-empty -m init 2>/dev/null
    printf 'shellcheck:\n\ttrue\nlint:\n\ttrue\n' > Makefile )
  verify_post_merge "$_wt" "origin/main" || true
  [ -f "$_capture" ]
  [ "$(cat "$_capture")" = "origin/main" ]
}
