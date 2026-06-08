#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/merge-pr.sh
# tests/regression/closed-issue-cleanup-no-hang.bats
#
# Regression test: closed-issue cleanup does not make unnecessary network calls
# Issue #287 (originally #182, #200, #203)
#
# Bug history (2026-06-04):
#   handle_closed_issue() unconditionally called `git ls-remote --heads origin <branch>`
#   for every closed issue during cleanup, even when the PR was merged (the most common
#   case). The merge handler (merge-pr.sh via `gh pr merge --delete-branch`) already
#   deleted the remote branch, so the ls-remote was a confirmed no-op that still
#   made a full network round-trip — 0.3s on fast networks, 30s+ on slow ones,
#   indefinite on hung remotes.
#
# Fix (lib/core/workflow-runner.sh — handle_closed_issue):
#   Layer 1: When pr_state == "MERGED", skip the git ls-remote check entirely.
#            merge-pr.sh deletes the remote branch via --delete-branch; this relies
#            on that contract (documented in behavioral-design.md).
#   Layer 2: On the closed-not-merged path, wrap git ls-remote and git push --delete
#            with run_with_timeout 5 so a hung network can't stall the workflow.
#   Layer 3: batch-process-issues.sh runs `timeout 10 git fetch --prune origin` once
#            at session start. handle_closed_issue uses git show-ref (local) when
#            _BATCH_FETCH_PRUNE_DONE=true instead of git ls-remote (network).
#
# Static checks performed here (no live network or real GitHub API needed):
#   1. Layer 1: The MERGED short-circuit is present and precedes git ls-remote.
#   2. Layer 2: git ls-remote and git push --delete are wrapped with run_with_timeout.
#   3. Layer 3a: batch-process-issues.sh contains the session-level git fetch --prune.
#   4. Layer 3b: handle_closed_issue uses git show-ref when _BATCH_FETCH_PRUNE_DONE=true.
#   5. Timeout.sh is sourced in workflow-runner.sh (needed by run_with_timeout).
#   6. The contract comment references behavioral-design.md.
#   7. NO unconditional git ls-remote for merged PRs (the original hang source).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WORKFLOW_RUNNER="$SCRIPT_DIR/lib/core/workflow-runner.sh"
BATCH_PROCESSOR="$SCRIPT_DIR/lib/core/batch-process-issues.sh"

# ---------------------------------------------------------------------------
# Test 1: Layer 1 — MERGED short-circuit skips git ls-remote
# ---------------------------------------------------------------------------

@test "Layer 1: handle_closed_issue short-circuits git ls-remote for MERGED PRs" {
  [ -f "$WORKFLOW_RUNNER" ]

  # The fix must check pr_state == MERGED before calling git ls-remote.
  # Extract the handle_closed_issue function body (between its definition and closing brace).
  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_closed_issue function body" >&2
    return 1
  }

  # The MERGED guard must exist within the function
  _merged_line=$(echo "$_func_body" | grep -E '(pr_state|MERGED).*MERGED|MERGED.*(pr_state)' | head -1 | cut -d: -f1)
  [ -n "$_merged_line" ] || {
    echo "FAIL: No pr_state == MERGED check found in handle_closed_issue" >&2
    return 1
  }

  # git ls-remote must either not appear (fully removed from merged path) OR
  # appear only in an else branch AFTER the MERGED guard.
  _ls_remote_line=$(echo "$_func_body" | grep -E "git ls-remote" | head -1 | cut -d: -f1)
  if [ -n "$_ls_remote_line" ]; then
    # ls-remote exists — it must come AFTER the MERGED guard (i.e., in the else branch)
    [ "$_ls_remote_line" -gt "$_merged_line" ] || {
      echo "FAIL: git ls-remote (line $_ls_remote_line) appears before or at MERGED guard (line $_merged_line)" >&2
      echo "      The merged short-circuit must precede git ls-remote to prevent the hang" >&2
      return 1
    }
  fi
  # If _ls_remote_line is empty, git ls-remote was removed entirely from the function — even better.
}

# ---------------------------------------------------------------------------
# Test 2: Layer 2 — git ls-remote is wrapped with timeout (not-merged path)
# ---------------------------------------------------------------------------

@test "Layer 2: git ls-remote on not-merged path is wrapped with run_with_timeout" {
  [ -f "$WORKFLOW_RUNNER" ]

  # git ls-remote must NOT appear bare (unwrapped) in handle_closed_issue.
  # It must be preceded by run_with_timeout on the same logical line.
  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  # If git ls-remote appears, it must be prefixed with run_with_timeout
  if echo "$_func_body" | grep -q "git ls-remote"; then
    echo "$_func_body" | grep "git ls-remote" | grep -q "run_with_timeout" || {
      echo "FAIL: git ls-remote in handle_closed_issue is not wrapped with run_with_timeout" >&2
      echo "      Bare git ls-remote can hang indefinitely on slow/stuck networks" >&2
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Layer 2 — git push --delete is wrapped with timeout
# ---------------------------------------------------------------------------

@test "Layer 2: git push origin --delete on not-merged path is wrapped with run_with_timeout" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  # git push origin --delete must be wrapped with run_with_timeout
  if echo "$_func_body" | grep -q "git push origin --delete"; then
    echo "$_func_body" | grep "git push origin --delete" | grep -q "run_with_timeout" || {
      echo "FAIL: git push origin --delete in handle_closed_issue is not wrapped with run_with_timeout" >&2
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# Test 4: timeout.sh is sourced in workflow-runner.sh (run_with_timeout dep)
# ---------------------------------------------------------------------------

@test "timeout.sh is sourced in workflow-runner.sh" {
  [ -f "$WORKFLOW_RUNNER" ]

  grep -qE 'source.*timeout\.sh' "$WORKFLOW_RUNNER" || {
    echo "FAIL: timeout.sh is not sourced in workflow-runner.sh" >&2
    echo "      run_with_timeout is undefined without it" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 5: ensure_timeout_cmd is called after sourcing timeout.sh
# ---------------------------------------------------------------------------

@test "ensure_timeout_cmd is called in workflow-runner.sh after sourcing timeout.sh" {
  [ -f "$WORKFLOW_RUNNER" ]

  # Locate source of timeout.sh and ensure_timeout_cmd call, verify ordering
  _source_line=$(grep -n "source.*timeout\.sh" "$WORKFLOW_RUNNER" | head -1 | cut -d: -f1)
  _ensure_line=$(grep -n "^ensure_timeout_cmd" "$WORKFLOW_RUNNER" | head -1 | cut -d: -f1)

  [ -n "$_source_line" ] || {
    echo "FAIL: source timeout.sh not found in workflow-runner.sh" >&2
    return 1
  }
  [ -n "$_ensure_line" ] || {
    echo "FAIL: ensure_timeout_cmd not called in workflow-runner.sh" >&2
    return 1
  }
  [ "$_ensure_line" -gt "$_source_line" ] || {
    echo "FAIL: ensure_timeout_cmd (line $_ensure_line) is called before source timeout.sh (line $_source_line)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 6: Layer 3 — batch processor has session-level git fetch --prune
# ---------------------------------------------------------------------------

@test "Layer 3: batch-process-issues.sh has session-level git fetch --prune" {
  [ -f "$BATCH_PROCESSOR" ]

  grep -qE "git fetch --prune origin" "$BATCH_PROCESSOR" || {
    echo "FAIL: batch-process-issues.sh does not have git fetch --prune origin" >&2
    echo "      Session-level prefetch eliminates per-issue network calls for not-merged path" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 7: Layer 3 — batch fetch is wrapped with timeout (non-fatal)
# ---------------------------------------------------------------------------

@test "Layer 3: batch git fetch --prune is wrapped with timeout" {
  [ -f "$BATCH_PROCESSOR" ]

  # The fetch must be guarded so a slow/hung network doesn't stall the batch startup
  grep -E "git fetch --prune origin" "$BATCH_PROCESSOR" | grep -q "timeout" || {
    echo "FAIL: git fetch --prune origin in batch processor is not wrapped with timeout" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 8: Layer 3 — batch fetch sets _BATCH_FETCH_PRUNE_DONE flag
# ---------------------------------------------------------------------------

@test "Layer 3: batch fetch sets _BATCH_FETCH_PRUNE_DONE on success" {
  [ -f "$BATCH_PROCESSOR" ]

  grep -q "_BATCH_FETCH_PRUNE_DONE" "$BATCH_PROCESSOR" || {
    echo "FAIL: _BATCH_FETCH_PRUNE_DONE flag not found in batch-process-issues.sh" >&2
    echo "      handle_closed_issue uses this flag to choose local vs network check" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 9: Layer 3 — handle_closed_issue uses git show-ref when prefetch done
# ---------------------------------------------------------------------------

@test "Layer 3: handle_closed_issue uses git show-ref when _BATCH_FETCH_PRUNE_DONE=true" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  # Both the flag check and git show-ref must be present in the function
  echo "$_func_body" | grep -q "_BATCH_FETCH_PRUNE_DONE" || {
    echo "FAIL: _BATCH_FETCH_PRUNE_DONE check not found in handle_closed_issue" >&2
    return 1
  }
  echo "$_func_body" | grep -q "git show-ref" || {
    echo "FAIL: git show-ref not found in handle_closed_issue" >&2
    echo "      When _BATCH_FETCH_PRUNE_DONE=true, local ref check should be used" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 10: Contract comment references behavioral-design.md
# ---------------------------------------------------------------------------

@test "handle_closed_issue has contract comment referencing behavioral-design.md" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  echo "$_func_body" | grep -q "behavioral-design.md" || {
    echo "FAIL: No reference to behavioral-design.md in handle_closed_issue" >&2
    echo "      The contract between merge-pr.sh and the cleanup section must be documented" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Test 11: No unconditional (unguarded) git ls-remote in handle_closed_issue
# ---------------------------------------------------------------------------

@test "handle_closed_issue has no unconditional git ls-remote (all occurrences are guarded)" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  # Every git ls-remote COMMAND (not comment) must be wrapped with run_with_timeout.
  # _func_body lines have format "LINENO: <actual content>" (from the awk NR prefix).
  # Strip the leading number+colon before checking for comments.
  while IFS= read -r line; do
    if echo "$line" | grep -q "git ls-remote"; then
      # Strip the "LINENO: " prefix added by awk to get the actual content
      _content=$(echo "$line" | sed 's/^[0-9]*: *//')
      # Skip comment lines — they may mention git ls-remote as documentation
      if echo "$_content" | grep -qE '^\s*#'; then
        continue
      fi
      # Non-comment line with git ls-remote: must be wrapped with run_with_timeout
      echo "$_content" | grep -q "run_with_timeout" || {
        echo "FAIL: Found unguarded git ls-remote command: $line" >&2
        echo "      All git ls-remote calls must be wrapped with run_with_timeout to prevent hangs" >&2
        return 1
      }
    fi
  done <<< "$_func_body"
}

# ---------------------------------------------------------------------------
# Tests 12–14: found_local_orphans gate (issue #301)
#
# These tests verify the refined gating logic added by #301:
#   - found_local_orphans is the primary signal; MERGED is secondary/defensive.
#   - Network is skipped when BOTH signals are false (no local orphans AND MERGED).
#   - Network fires when either signal is true.
# ---------------------------------------------------------------------------

@test "found_local_orphans: variable is declared in handle_closed_issue" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print $0 }
  ' "$WORKFLOW_RUNNER")

  # found_local_orphans must be declared and initialized to false
  echo "$_func_body" | grep -qE 'found_local_orphans=false' || {
    echo "FAIL: found_local_orphans=false not found in handle_closed_issue" >&2
    echo "      The variable must be initialized before steps 1-2 (worktree/branch cleanup)" >&2
    return 1
  }
}

@test "found_local_orphans: set to true in worktree removal block (step 1)" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  # Locate the worktree removal block (git worktree remove) and the
  # found_local_orphans=true assignment. The orphans assignment must
  # appear AFTER worktree remove (i.e., inside the success branch).
  _wt_remove_line=$(echo "$_func_body" | grep -E "git worktree remove" | head -1 | cut -d: -f1)
  [ -n "$_wt_remove_line" ] || {
    echo "FAIL: git worktree remove not found in handle_closed_issue" >&2
    return 1
  }

  # The first found_local_orphans=true must appear after git worktree remove
  _orphans_true_line=$(echo "$_func_body" | grep -E 'found_local_orphans=true' | head -1 | cut -d: -f1)
  [ -n "$_orphans_true_line" ] || {
    echo "FAIL: found_local_orphans=true not found in handle_closed_issue" >&2
    echo "      It must be set in the worktree removal success block (step 1)" >&2
    return 1
  }
  [ "$_orphans_true_line" -gt "$_wt_remove_line" ] || {
    echo "FAIL: found_local_orphans=true (line $_orphans_true_line) appears before git worktree remove (line $_wt_remove_line)" >&2
    echo "      found_local_orphans must be set only when worktree removal actually succeeded" >&2
    return 1
  }
}

@test "found_local_orphans: set to true in local branch deletion block (step 2)" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  # Locate the local branch deletion block (git branch -D) and verify
  # found_local_orphans=true is set inside its success branch.
  # The second found_local_orphans=true assignment (step 2) must appear
  # AFTER git branch -D so that the flag is only raised when a local branch
  # was actually deleted — not merely when one was checked for.
  _branch_delete_line=$(echo "$_func_body" | grep -E "git branch -D" | head -1 | cut -d: -f1)
  [ -n "$_branch_delete_line" ] || {
    echo "FAIL: git branch -D not found in handle_closed_issue" >&2
    return 1
  }

  # The second found_local_orphans=true assignment belongs to step 2.
  # Exclude comment lines (^LINENO:[space]*#) so that inline comments mentioning
  # found_local_orphans=true don't shift the position count; head -2 | tail -1 then
  # selects the second code assignment robustly without relying on sed line numbers.
  _second_orphans_line=$(echo "$_func_body" | grep -E 'found_local_orphans=true' | grep -vE '^[0-9]+:[[:space:]]*#' | head -2 | tail -1 | cut -d: -f1)
  [ -n "$_second_orphans_line" ] || {
    echo "FAIL: second found_local_orphans=true assignment not found in handle_closed_issue" >&2
    echo "      Step 2 (git branch -D success block) must set found_local_orphans=true" >&2
    return 1
  }
  [ "$_second_orphans_line" -gt "$_branch_delete_line" ] || {
    echo "FAIL: second found_local_orphans=true (line $_second_orphans_line) appears before git branch -D (line $_branch_delete_line)" >&2
    echo "      found_local_orphans must be set only when local branch deletion actually succeeded (step 2)" >&2
    return 1
  }
}

@test "found_local_orphans: gate precedes git ls-remote (network skipped when no orphans)" {
  [ -f "$WORKFLOW_RUNNER" ]

  _func_body=$(awk '
    /^handle_closed_issue\(\)/ { in_func=1; next }
    in_func && /^\}$/ { exit }
    in_func { print NR": "$0 }
  ' "$WORKFLOW_RUNNER")

  [ -n "$_func_body" ] || {
    echo "FAIL: Could not extract handle_closed_issue function body" >&2
    return 1
  }

  # The outer gate that wraps the network block must reference found_local_orphans.
  # This ensures closed-not-merged PRs with no local orphans skip the network call.
  _gate_line=$(echo "$_func_body" | grep -E 'found_local_orphans.*true.*MERGED|MERGED.*found_local_orphans' | head -1 | cut -d: -f1)
  [ -n "$_gate_line" ] || {
    echo "FAIL: No combined found_local_orphans + MERGED gate found in handle_closed_issue" >&2
    echo "      Expected: [ \"\$found_local_orphans\" = \"true\" ] || [ \"\${pr_state:-}\" != \"MERGED\" ]" >&2
    echo "      The gate must short-circuit network calls when no local orphans exist." >&2
    return 1
  }

  # git ls-remote must appear AFTER the combined gate (inside the gated block)
  _ls_remote_line=$(echo "$_func_body" | grep -E "git ls-remote" | head -1 | cut -d: -f1)
  if [ -n "$_ls_remote_line" ]; then
    [ "$_ls_remote_line" -gt "$_gate_line" ] || {
      echo "FAIL: git ls-remote (line $_ls_remote_line) appears before or at the combined gate (line $_gate_line)" >&2
      echo "      git ls-remote must be inside the found_local_orphans || !MERGED gated block" >&2
      return 1
    }
  fi
  # If ls-remote is absent entirely, the gate is even stronger — pass.
}
