#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/repo-status.sh
# Regression tests for the "Integration branches" section in repo-wide --status.
#
# Tests:
# 1. Missing ledger dir  → section absent (byte-identical to today's output)
# 2. Empty ledger dir    → section absent
# 3. All-promoted ledger + no in-flight worktrees + no origin ref → section absent (retired)
# 4. One unpromoted entry + origin ref at parity → header + awaiting-promotion row + --promote suggestion
# 5. One unpromoted entry + origin ref behind main → header + row + --sync suggestion
# 6. In-flight worktree (open PR targeting branch) → in-flight row rendered
# 7. Branch name with '/' (e.g. release/1.2) recovered correctly (not truncated by basename)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  # Point state dir at our test tmpdir so ledger files don't touch the real .rite/
  export RITE_STATE_DIR="${RITE_TEST_TMPDIR}/state"
  mkdir -p "$RITE_STATE_DIR"

  # Set a stable project root for behind_main_count git calls
  export RITE_PROJECT_ROOT="$RITE_REPO_ROOT"

  # Source repo-status.sh — defines render_integration_branches + behind_main_count
  # shellcheck disable=SC1090
  source "$RITE_REPO_ROOT/lib/utils/repo-status.sh"
  # Restore flags after source (lib sets -euo pipefail in the calling shell)
  set +u; set +o pipefail

  # --- Stub out helpers that make network/git calls we don't want in tests ---

  # Colors: define minimal stubs so echo -e output is predictable
  CYAN=""   ; export CYAN
  BLUE=""   ; export BLUE
  YELLOW="" ; export YELLOW
  RED=""    ; export RED
  DIM=""    ; export DIM
  NC=""     ; export NC

  # _issue_link: output plain "#N  " (no OSC 8)
  _issue_link() { printf '#%s%*s' "$1" "$(( $2 - 1 - ${#1} ))" ""; }

  # _pr_link: output plain "PR#N"
  _pr_link() { printf 'PR#%s' "$1"; }

  # behind_main_count: stub — returns value from STUB_BEHIND (default 0)
  behind_main_count() { echo "${STUB_BEHIND:-0}"; }
  export STUB_BEHIND

  # git rev-parse for origin/<branch>: controlled via STUB_ORIGIN_SHA
  # We override the git function so git rev-parse calls in render_integration_branches return
  # STUB_ORIGIN_SHA (non-empty = ref exists; empty = ref absent).
  # The real behind_main_count is also stubbed above so no real git call needed there.
  git() {
    case "$*" in
      *"rev-parse origin/"*)
        if [ -n "${STUB_ORIGIN_SHA:-}" ]; then
          echo "$STUB_ORIGIN_SHA"
        else
          return 1
        fi
        ;;
      *)
        command git "$@"
        ;;
    esac
  }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a ledger entry line (matches integration-ledger.sh format)
# ---------------------------------------------------------------------------
_write_ledger_entry() {
  local branch="$1" issue="$2" pr="$3" sha="$4" promoted="${5:-false}"
  local ledger_dir="${RITE_STATE_DIR}/integration-branches"
  mkdir -p "$(dirname "${ledger_dir}/${branch}.log")"
  printf 'issue=%s\tpr=%s\tsha=%s\tmerged_at=2026-07-07T04:00:00Z\tpromoted=%s\n' \
    "$issue" "$pr" "$sha" "$promoted" >> "${ledger_dir}/${branch}.log"
}

# ---------------------------------------------------------------------------
# 1. Missing ledger dir → no Integration branches header
# ---------------------------------------------------------------------------
@test "render_integration_branches: missing ledger dir produces no output" {
  rm -rf "${RITE_STATE_DIR}/integration-branches"
  run render_integration_branches "[]" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"Integration Branches"* ]]
}

# ---------------------------------------------------------------------------
# 2. Empty ledger dir → no Integration branches header
# ---------------------------------------------------------------------------
@test "render_integration_branches: empty ledger dir produces no output" {
  mkdir -p "${RITE_STATE_DIR}/integration-branches"
  run render_integration_branches "[]" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"Integration Branches"* ]]
}

# ---------------------------------------------------------------------------
# 3. Fully-retired ledger (all promoted, no in-flight, no origin ref) → skip
# ---------------------------------------------------------------------------
@test "render_integration_branches: all-promoted ledger with no origin ref is silently skipped" {
  _write_ledger_entry "staging" 42 97 "abc1234abcdef" "true"
  STUB_ORIGIN_SHA=""  # no local origin/staging ref
  run render_integration_branches "[]" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"Integration Branches"* ]]
}

# ---------------------------------------------------------------------------
# 4. One unpromoted entry + origin ref at parity → header + row + --promote
# ---------------------------------------------------------------------------
@test "render_integration_branches: unpromoted entry at parity shows header, row, and --promote suggestion" {
  _write_ledger_entry "staging" 42 97 "abc1234abcdef" "false"
  STUB_ORIGIN_SHA="abc1234abcdef"
  STUB_BEHIND=0  # at parity with main

  run render_integration_branches "[]" ""
  [ "$status" -eq 0 ]
  # Section header must appear
  [[ "$output" == *"Integration Branches"* ]]
  # Branch name in output
  [[ "$output" == *"staging"* ]]
  # Awaiting-promotion row
  [[ "$output" == *"awaiting promotion"* ]]
  # Short SHA in output
  [[ "$output" == *"abc1234"* ]]
  # Suggest --promote (at parity + unpromoted)
  [[ "$output" == *"--promote staging"* ]]
  # Must NOT suggest --sync
  [[ "$output" != *"--sync"* ]]
}

# ---------------------------------------------------------------------------
# 5. One unpromoted entry + origin ref behind main → header + row + --sync
# ---------------------------------------------------------------------------
@test "render_integration_branches: branch behind main shows --sync suggestion" {
  _write_ledger_entry "staging" 42 97 "abc1234abcdef" "false"
  STUB_ORIGIN_SHA="abc1234abcdef"
  STUB_BEHIND=3  # 3 commits behind main

  run render_integration_branches "[]" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Integration Branches"* ]]
  # Suggest --sync when behind
  [[ "$output" == *"--sync staging"* ]]
  # Must NOT suggest --promote
  [[ "$output" != *"--promote"* ]]
  # Behind-main count visible
  [[ "$output" == *"3 behind main"* ]]
}

# ---------------------------------------------------------------------------
# 6. In-flight worktree (open PR with baseRefName == branch) → in-flight row
# ---------------------------------------------------------------------------
@test "render_integration_branches: in-flight PR targeting branch renders in-flight row" {
  _write_ledger_entry "staging" 42 97 "abc1234abcdef" "false"
  STUB_ORIGIN_SHA="abc1234abcdef"
  STUB_BEHIND=0

  # Minimal open-PR JSON with baseRefName == "staging"
  local prs_json
  prs_json='[{"number":101,"headRefName":"feat/my-feature","baseRefName":"staging","body":"Closes #55"}]'

  run render_integration_branches "$prs_json" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Integration Branches"* ]]
  # In-flight row
  [[ "$output" == *"in flight"* ]]
  [[ "$output" == *"PR#101"* ]]
}

# ---------------------------------------------------------------------------
# 7. Branch name with '/' → recovered correctly (not truncated)
# ---------------------------------------------------------------------------
@test "render_integration_branches: branch name with '/' is not truncated by basename" {
  _write_ledger_entry "release/1.2" 77 120 "deadbeefcafe0" "false"
  STUB_ORIGIN_SHA="deadbeefcafe0"
  STUB_BEHIND=0

  run render_integration_branches "[]" ""
  [ "$status" -eq 0 ]
  # Full branch name must appear — not just "1.2" as basename would produce
  [[ "$output" == *"release/1.2"* ]]
  # And NOT accidentally show just "1.2" as a standalone branch name
  # (i.e., the branch header should contain the slash)
  local _branch_line
  _branch_line=$(echo "$output" | grep -v "^#" | grep "release")
  [[ "$_branch_line" == *"release/1.2"* ]]
}

# ---------------------------------------------------------------------------
# Structural: render_integration_branches is defined and called from repo_wide_status
# ---------------------------------------------------------------------------
@test "repo-status.sh: render_integration_branches definition and call site both exist" {
  local _repo_status="${RITE_REPO_ROOT}/lib/utils/repo-status.sh"
  # Definition line
  run grep -n "^render_integration_branches()" "$_repo_status"
  [ "$status" -eq 0 ]
  # Call site inside repo_wide_status
  run grep -n "render_integration_branches" "$_repo_status"
  [ "$status" -eq 0 ]
  # There should be at least 2 hits: definition + call
  local _count
  _count=$(grep -c "render_integration_branches" "$_repo_status" || true)
  [ "$_count" -ge 2 ]
}

@test "repo-status.sh: baseRefName is included in open-PR batch fetch" {
  run grep -n "number,body,headRefName,baseRefName" "$RITE_REPO_ROOT/lib/utils/repo-status.sh"
  [ "$status" -eq 0 ]
}

@test "repo-status.sh: merge-base appears exactly once (inside behind_main_count)" {
  local _count
  _count=$(grep -c "merge-base" "$RITE_REPO_ROOT/lib/utils/repo-status.sh" || true)
  # Exactly 1: inside behind_main_count() definition; the two inline copies replaced
  [ "$_count" -eq 1 ]
}

@test "repo-status.sh: render_integration_branches makes no gh calls" {
  local _func_body
  _func_body=$(sed -n '/^render_integration_branches()/,/^}/p' "$RITE_REPO_ROOT/lib/utils/repo-status.sh")
  local _gh_count
  _gh_count=$(echo "$_func_body" | grep -c "gh_safe\|[^a-z]gh " || true)
  [ "$_gh_count" -eq 0 ]
}
