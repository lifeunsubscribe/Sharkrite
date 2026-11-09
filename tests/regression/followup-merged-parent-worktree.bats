#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh::find_worktree_for_task, lib/utils/pr-detection.sh::detect_parent_pr_attachment
# tests/regression/followup-merged-parent-worktree.bats
#
# A follow-up issue whose parent PR is already MERGED must NOT adopt the
# parent's lingering local worktree. Only an OPEN parent warrants adoption.
#
# Live failure 2026-11-07 (issue #1630): batch rite-1613-... ran follow-up #1613
# (parent PR #1612). workflow-runner.sh correctly printed "parent PR #1612 is
# MERGED — running fresh branch". Twenty lines later, find_worktree_for_task in
# claude-workflow.sh independently fetched headRefName for PR #1612 without
# checking state, found the lingering local worktree, navigated into it, and
# bailed with "Work already completed! Issue #1613 (PR #1612) Status: MERGED".
#
# Root cause: two independent derivations of "is the parent still live?" with
# different answers. Fix: find_worktree_for_task routes through
# detect_parent_pr_attachment (the shared helper) instead of re-deriving.
#
# Tests in this file:
#   1. MERGED parent with lingering worktree: find_worktree_for_task returns empty
#   2. OPEN parent with existing worktree: find_worktree_for_task returns that worktree
#   3. CLOSED parent: treated same as MERGED (fresh branch)
#   4. Env-var fast path: _RITE_PARENT_ATTACHMENT_MODE=ignore skips adoption
#   5. Env-var fast path: _RITE_PARENT_ATTACHMENT_MODE=adopt uses _RITE_PARENT_PR_BRANCH
#   6. Structural: find_worktree_for_task has no bare headRefName-only parent PR lookup

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CW="$REPO_ROOT/lib/core/claude-workflow.sh"
PR_DETECTION="$REPO_ROOT/lib/utils/pr-detection.sh"

setup() {
  [ -f "$CW" ] || { echo "FATAL: $CW not found" >&2; return 1; }
  [ -f "$PR_DETECTION" ] || { echo "FATAL: $PR_DETECTION not found" >&2; return 1; }
  command -v jq >/dev/null || skip "jq not installed"
  export RITE_LIB_DIR="$REPO_ROOT/lib"
  _tmpdir=$(mktemp -d)
  _wt_dir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
  [ -n "${_wt_dir:-}" ] && rm -rf "$_wt_dir" || true
}

# ---------------------------------------------------------------------------
# _drive BODY PR_STATE PR_BRANCH WTL_LINE1 WTL_LINE2 [ENV_MODE [ENV_BRANCH]]
#
# Builds a self-contained bash driver script that:
#   - defines gh_safe / git stubs referencing the given fixture values
#   - inlines detect_parent_pr_attachment (from pr-detection.sh)
#   - inlines find_worktree_for_task (from claude-workflow.sh)
#   - calls find_worktree_for_task "1613" and prints "result=..."
#
# Using a temp file (not bash -c "...") avoids quoting-hell with function
# bodies that contain double quotes and dollar signs.
# ---------------------------------------------------------------------------
_drive() {
  local _body="$1"      # issue body text returned by gh issue view
  local _state="$2"     # parent PR state ("OPEN", "MERGED", "CLOSED")
  local _branch="$3"    # parent PR headRefName
  local _wt1="$4"       # first worktree line (main)
  local _wt2="$5"       # second worktree line (feature; "" = no feature worktree)
  local _env_mode="${6:-}"    # optional pre-set _RITE_PARENT_ATTACHMENT_MODE
  local _env_br="${7:-}"      # optional pre-set _RITE_PARENT_PR_BRANCH

  # Write body to a temp file so the stub can read it without quoting issues.
  printf '%s' "$_body" > "$_tmpdir/body.txt"

  local _s="$_tmpdir/driver.sh"

  # --- script header (quoted heredoc: no variable expansion) ---
  cat > "$_s" <<'HEADER'
#!/bin/bash
# Bash 4+ re-exec (process substitution in find_worktree_for_task needs it)
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for _nb in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$_nb" ] && exec "$_nb" "$0" "$@"
  done
  echo "Error: bash 4+ required" >&2; exit 1
fi
set -uo pipefail
RITE_MARKER_PARENT_PR="sharkrite-parent-pr"
CLOSING_ISSUE_JQ_REGEX="(close[sd]?|fix(e[sd])?|resolve[sd]?) #"
HEADER

  # --- inject fixture values using %q (safe shell quoting) ---
  printf 'BODY_FILE=%q\n' "$_tmpdir/body.txt" >> "$_s"
  printf 'PR_STATE=%q\n'  "$_state"           >> "$_s"
  printf 'PR_BRANCH=%q\n' "$_branch"          >> "$_s"
  printf 'WT1=%q\n'       "$_wt1"             >> "$_s"
  printf 'WT2=%q\n'       "$_wt2"             >> "$_s"

  # optional env vars forwarded from workflow-runner.sh
  if [ -n "$_env_mode" ]; then
    printf 'export _RITE_PARENT_ATTACHMENT_MODE=%q\n' "$_env_mode" >> "$_s"
  fi
  if [ -n "$_env_br" ]; then
    printf 'export _RITE_PARENT_PR_BRANCH=%q\n' "$_env_br" >> "$_s"
  fi

  # --- stubs (quoted heredoc) ---
  cat >> "$_s" <<'STUBS'
gh_safe() {
  local _c="$1"; shift
  case "$_c" in
    issue) cat "$BODY_FILE" ;;
    pr)
      # gh pr list --state all ... → empty list (this follow-up has no own PR yet)
      if printf '%s' "$*" | grep -q 'state all'; then
        printf '[]'
      else
        # gh pr view N --json state,headRefName (from detect_parent_pr_attachment)
        printf '{"state":"%s","headRefName":"%s"}' "$PR_STATE" "$PR_BRANCH"
      fi
      ;;
  esac
  return 0
}
git() {
  if [ "$1" = worktree ] && [ "$2" = list ]; then
    printf '%s\n' "$WT1"
    [ -n "$WT2" ] && printf '%s\n' "$WT2" || true
    return 0
  fi
  command git "$@"
}
STUBS

  # --- inline detect_parent_pr_attachment and find_worktree_for_task ---
  sed -n '/^detect_parent_pr_attachment()/,/^}/p' "$PR_DETECTION" >> "$_s"
  printf '\n' >> "$_s"
  sed -n '/^find_worktree_for_task()/,/^}/p' "$CW" >> "$_s"

  # --- main call (quoted heredoc) ---
  cat >> "$_s" <<'TAIL'
_out=$(find_worktree_for_task "1613" 2>/dev/null)
printf 'result=%s\n' "${_out:-EMPTY}"
TAIL

  run bash "$_s"
  _status="$status"
  _result="$output"
}

# ---------------------------------------------------------------------------
# Test 1: MERGED parent with lingering worktree → no adoption
# ---------------------------------------------------------------------------

@test "MERGED parent with lingering worktree: find_worktree_for_task returns empty" {
  _drive \
    "Follow-up. <!-- sharkrite-parent-pr:1612 -->" \
    "MERGED" "feat/parent-branch" \
    "/home/user/repo  abc1234 [main]" \
    "$_wt_dir  def5678 [feat/parent-branch]"

  [ "$_status" -eq 0 ] || {
    echo "FAIL: script exited $_status; output: $_result" >&2; return 1
  }
  echo "$_result" | grep -q 'result=EMPTY' || {
    echo "FAIL: expected EMPTY for MERGED parent; got: $_result" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Test 2: OPEN parent with existing worktree → worktree adopted
# ---------------------------------------------------------------------------

@test "OPEN parent with existing worktree: find_worktree_for_task returns that worktree" {
  _drive \
    "Follow-up. <!-- sharkrite-parent-pr:1612 -->" \
    "OPEN" "feat/parent-branch" \
    "/home/user/repo  abc1234 [main]" \
    "$_wt_dir  def5678 [feat/parent-branch]"

  [ "$_status" -eq 0 ] || {
    echo "FAIL: script exited $_status; output: $_result" >&2; return 1
  }
  # Result should be "wt_path|branch"
  echo "$_result" | grep -q "result=${_wt_dir}|feat/parent-branch" || {
    echo "FAIL: expected worktree adoption for OPEN parent; got: $_result" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Test 3: CLOSED parent → same as MERGED, no adoption
# ---------------------------------------------------------------------------

@test "CLOSED parent with lingering worktree: find_worktree_for_task returns empty" {
  _drive \
    "Follow-up. <!-- sharkrite-parent-pr:1612 -->" \
    "CLOSED" "feat/parent-branch" \
    "/home/user/repo  abc1234 [main]" \
    "$_wt_dir  def5678 [feat/parent-branch]"

  [ "$_status" -eq 0 ] || {
    echo "FAIL: script exited $_status; output: $_result" >&2; return 1
  }
  echo "$_result" | grep -q 'result=EMPTY' || {
    echo "FAIL: expected EMPTY for CLOSED parent; got: $_result" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Test 4: Env-var fast path — _RITE_PARENT_ATTACHMENT_MODE=ignore skips
# adoption even when API would say OPEN.
# ---------------------------------------------------------------------------

@test "env-var fast path: _RITE_PARENT_ATTACHMENT_MODE=ignore overrides API OPEN" {
  _drive \
    "Follow-up. <!-- sharkrite-parent-pr:1612 -->" \
    "OPEN" "feat/parent-branch" \
    "/home/user/repo  abc1234 [main]" \
    "$_wt_dir  def5678 [feat/parent-branch]" \
    "ignore" "feat/parent-branch"

  [ "$_status" -eq 0 ] || {
    echo "FAIL: script exited $_status; output: $_result" >&2; return 1
  }
  echo "$_result" | grep -q 'result=EMPTY' || {
    echo "FAIL: env-var ignore must override API OPEN; got: $_result" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Test 5: Env-var fast path — _RITE_PARENT_ATTACHMENT_MODE=adopt uses
# _RITE_PARENT_PR_BRANCH directly (no extra API call).
# ---------------------------------------------------------------------------

@test "env-var fast path: _RITE_PARENT_ATTACHMENT_MODE=adopt uses _RITE_PARENT_PR_BRANCH" {
  # API would say MERGED, but env var says adopt (workflow-runner.sh already decided)
  _drive \
    "Follow-up. <!-- sharkrite-parent-pr:1612 -->" \
    "MERGED" "feat/parent-branch" \
    "/home/user/repo  abc1234 [main]" \
    "$_wt_dir  def5678 [feat/parent-branch]" \
    "adopt" "feat/parent-branch"

  [ "$_status" -eq 0 ] || {
    echo "FAIL: script exited $_status; output: $_result" >&2; return 1
  }
  echo "$_result" | grep -q "result=${_wt_dir}|feat/parent-branch" || {
    echo "FAIL: env-var adopt must use the worktree regardless of API state; got: $_result" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Test 6: Structural — find_worktree_for_task must NOT contain a bare
# headRefName-only gh pr view for the parent PR path. The old code had:
#   gh_safe pr view "$parent_pr" --json headRefName --jq '.headRefName'
# After the fix, state is always checked via detect_parent_pr_attachment.
# ---------------------------------------------------------------------------

@test "structural: find_worktree_for_task has no bare headRefName-only parent PR lookup" {
  local _fwt_body
  _fwt_body=$(sed -n '/^find_worktree_for_task()/,/^}/p' "$CW")

  # Assert the old unguarded pattern is absent.
  # Safe to match literally: detect_parent_pr_attachment (a different file) uses
  # state,headRefName together — it cannot trigger this rule.
  if printf '%s\n' "$_fwt_body" | grep -qE 'pr view.*--json headRefName[^,]'; then
    echo "FAIL: find_worktree_for_task still has a state-less headRefName lookup:" >&2
    printf '%s\n' "$_fwt_body" | grep -n 'pr view' >&2 || true
    return 1
  fi
}
