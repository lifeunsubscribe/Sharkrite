#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh, lib/utils/stale-branch.sh, lib/utils/divergence-handler.sh, lib/utils/mid-run-rebase.sh
# tests/regression/conflict-resolution-commit-handoff.bats
#
# Script-side commit handoff for resolver sessions (issue #858).
#
# The resolver session WRITES resolved files but cannot stage or commit them
# (in-session git side effects are policy-blocked). The old inline call-site
# blocks committed only when the index already had staged changes, swallowed
# commit stderr with 2>/dev/null, and ran `git merge --abort` unconditionally —
# a no-op mid-rebase (live: issue #821, 2026-07-03: resolution succeeded,
# commit failed silently, issue failed; the second occurrence left a staged
# deletion + the SAME path untracked, so a successful commit would have
# committed a bare deletion).
#
# These tests cover the shared helper commit_resolved_conflicts():
#   - rebase context: unstaged resolution lands as a completed rebase
#     (GIT_EDITOR=true git rebase --continue; --skip for empty patches)
#   - merge context: unstaged resolution lands as a merge commit
#   - plain context: add/add live-incident shape commits CONTENT, not a
#     bare deletion (git add -A before the staged-changes check)
#   - failure paths print git's actual stderr and abort context-correctly
#   - structural: all call sites delegate to the one shared helper

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  # Pin the LEGACY resolver/abort path: #855's small-branch fast-path (auto-mode
  # conflicts on <=RITE_REBASE_CONFLICT_RESTART_MAX work commits restart fresh)
  # would preempt the conflict-resolution contracts these tests pin. 0 disables
  # the fast-path; the restart contract is covered by stale-branch-conflict-restart.bats.
  export RITE_REBASE_CONFLICT_RESTART_MAX=0
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_LOG_FILE="/dev/null"
  unset RITE_VERBOSE

  # stale-branch.sh chains in colors, logging, post-merge-verify AND
  # conflict-resolver.sh (which defines commit_resolved_conflicts).
  source "$RITE_LIB_DIR/utils/stale-branch.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests; keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ───────────────────────────────────────────────────────────────────
# Fixture helpers (standalone repo, no remote — helper-level tests)
# ───────────────────────────────────────────────────────────────────

# Standalone repo with f.txt committed on main.
_make_repo() {
  REPO_DIR="$RITE_TEST_TMPDIR/repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "base" > f.txt
  git add f.txt
  git commit -qm "base"
  git branch -M main
}

# feat and main both rewrite f.txt → guaranteed content conflict.
# Leaves cwd on feat.
_make_conflict_branches() {
  git checkout -qb feat
  echo "feature version" > f.txt
  git commit -aqm "feat change"
  git checkout -q main
  echo "main version" > f.txt
  git commit -aqm "main change"
  git checkout -q feat
}

# ───────────────────────────────────────────────────────────────────
# Rebase context
# ───────────────────────────────────────────────────────────────────

@test "rebase context: unstaged resolver output lands as a completed rebase" {
  _make_repo
  _make_conflict_branches

  run git rebase main
  [ "$status" -ne 0 ]  # sanity: rebase stopped on the conflict
  local _gitdir
  _gitdir=$(git rev-parse --git-dir)
  [ -d "$_gitdir/rebase-merge" ] || [ -d "$_gitdir/rebase-apply" ]

  # Simulate the resolver session: WRITE the resolution, stage NOTHING.
  echo "resolved version" > f.txt

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 0 ]

  # Rebase completed — not aborted, not stranded mid-rebase
  [ ! -d "$_gitdir/rebase-merge" ]
  [ ! -d "$_gitdir/rebase-apply" ]
  [ -z "$(git diff --name-only --diff-filter=U)" ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feat" ]

  # Feature commit replayed on top of main's tip with the resolved content
  [ "$(git show HEAD:f.txt)" = "resolved version" ]
  [ "$(git rev-parse HEAD^)" = "$(git rev-parse main)" ]
}

@test "rebase context: resolution identical to upstream skips the empty patch" {
  _make_repo
  _make_conflict_branches

  run git rebase main
  [ "$status" -ne 0 ]

  # Resolver accepts main's side wholesale — the replayed patch becomes empty.
  # `git rebase --continue` refuses with "No changes"; the helper must --skip.
  echo "main version" > f.txt

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 0 ]

  local _gitdir
  _gitdir=$(git rev-parse --git-dir)
  [ ! -d "$_gitdir/rebase-merge" ]
  [ ! -d "$_gitdir/rebase-apply" ]
  [ "$(git rev-parse HEAD)" = "$(git rev-parse main)" ]
}

# ───────────────────────────────────────────────────────────────────
# Merge context
# ───────────────────────────────────────────────────────────────────

@test "merge context: unstaged resolver output lands as a merge commit" {
  _make_repo
  _make_conflict_branches

  run git merge main --no-edit
  [ "$status" -ne 0 ]  # sanity: merge stopped on the conflict
  local _gitdir
  _gitdir=$(git rev-parse --git-dir)
  [ -f "$_gitdir/MERGE_HEAD" ]

  # Simulate the resolver session: WRITE the resolution, stage NOTHING.
  echo "resolved version" > f.txt

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 0 ]

  # Merge concluded with a two-parent merge commit carrying the resolution
  [ ! -f "$_gitdir/MERGE_HEAD" ]
  [ "$(git show HEAD:f.txt)" = "resolved version" ]
  [ "$(git rev-parse HEAD^2)" = "$(git rev-parse main)" ]
}

# ───────────────────────────────────────────────────────────────────
# Plain context (the add/add live-incident shape + the no-op case)
# ───────────────────────────────────────────────────────────────────

@test "plain context: staged deletion + untracked rewrite at same path commits content, not a bare deletion" {
  _make_repo

  # Live incident shape (#821, second occurrence): the index holds a staged
  # deletion while the resolver's rewritten file sits UNTRACKED at the SAME
  # path (add/add materialization does `git rm --cached` + working-tree write).
  git rm --cached -q f.txt
  echo "resolved version" > f.txt

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 0 ]

  # git add -A BEFORE the staged-changes check is load-bearing: the path must
  # survive as tracked content — NOT a bare deletion.
  [ -n "$(git ls-files f.txt)" ]
  [ "$(git show HEAD:f.txt)" = "resolved version" ]
  # Plain context has no MERGE_MSG for --no-edit to reuse — the helper must
  # supply an explicit message (a bare --no-edit dies on empty message).
  [ "$(git log -1 --format=%s)" = "Resolve conflicts (Claude-assisted resolution)" ]
}

@test "plain context: clean tree is a no-op success (resolver already committed)" {
  _make_repo

  local _head_before
  _head_before=$(git rev-parse HEAD)

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$_head_before" ]
}

# ───────────────────────────────────────────────────────────────────
# Failure paths: stderr surfaced, context-correct abort
# ───────────────────────────────────────────────────────────────────

@test "failure path (merge context): git stderr is printed and the merge is aborted" {
  _make_repo
  _make_conflict_branches

  run git merge main --no-edit
  [ "$status" -ne 0 ]
  echo "resolved version" > f.txt

  # Force the commit to fail with a distinctive stderr marker
  git config core.hooksPath .git/hooks
  mkdir -p .git/hooks
  printf '#!/bin/sh\necho "CRC-HOOK-STDERR-MARKER: commit rejected by fixture hook" >&2\nexit 1\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 1 ]

  # No 2>/dev/null swallowing: git's actual stderr must be visible
  echo "$output" | grep -q "CRC-HOOK-STDERR-MARKER"
  echo "$output" | grep -q "Failed to commit resolved conflicts"
  echo "$output" | grep -q "context: merge"

  # Context-correct abort: merge state cleaned up
  [ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]
}

@test "failure path (rebase context): git stderr is printed and the REBASE is aborted (not merge)" {
  _make_repo
  _make_conflict_branches

  local _feat_tip
  _feat_tip=$(git rev-parse HEAD)

  run git rebase main
  [ "$status" -ne 0 ]
  echo "resolved version" > f.txt

  # Force the rebase-continue commit to fail: disable identity auto-detection
  # so the internal commit dies with a real, visible git error.
  git config user.useConfigOnly true
  git config --unset user.name
  git config --unset user.email
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 1 ]

  # git's actual stderr must be visible (no swallowing)
  echo "$output" | grep -qiE "committer identity unknown|no email was given"
  echo "$output" | grep -q "context: rebase"

  # Context-correct abort: `git rebase --abort` (the old blocks ran
  # `git merge --abort`, which no-ops mid-rebase and strands the worktree)
  local _gitdir
  _gitdir=$(git rev-parse --git-dir)
  [ ! -d "$_gitdir/rebase-merge" ]
  [ ! -d "$_gitdir/rebase-apply" ]
  [ "$(git rev-parse HEAD)" = "$_feat_tip" ]
}

# ───────────────────────────────────────────────────────────────────
# Integration: the stale-branch rebase path lands an unstaged resolution
# through the handoff (the live-incident call site)
# ───────────────────────────────────────────────────────────────────

@test "integration: _stale_rebase_onto_main lands unstaged resolver output through the rebase handoff" {
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")
  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  cd "$FIXTURE_REPO"

  BRANCH_NAME="fix/handoff-test-$$"
  git checkout -qb "$BRANCH_NAME" main
  echo "Feature line" >> README.md
  git commit -aqm "feature modifies README"
  git push -q -u origin "$BRANCH_NAME"
  git checkout -q main
  echo "Main line (conflict)" >> README.md
  git commit -aqm "main modifies README"
  git push -q origin main

  WORKTREE_PATH="$RITE_TEST_TMPDIR/wt-handoff"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" >/dev/null 2>&1

  # Stub resolver: recreate the live-incident shape — a rebase stopped on a
  # conflict, resolution WRITTEN to the working tree, NOTHING staged, exit 0.
  attempt_claude_merge_resolution() {
    cd "$WORKTREE_PATH" || return 1
    git rebase origin/main >/dev/null 2>&1 || true  # stops on the conflict
    printf '%s\n' "# Test Repository" "Resolved by stub" > README.md
    return 0
  }

  # Not under test here — keep the fixture fast and focused on the handoff.
  verify_post_merge() { return 0; }

  run _stale_rebase_onto_main "$WORKTREE_PATH" "$BRANCH_NAME" "auto" "858" ""
  [ "$status" -eq 0 ]

  # Rebase completed through the handoff (not stranded, not aborted)
  local _wt_gitdir
  _wt_gitdir=$(git -C "$WORKTREE_PATH" rev-parse --git-dir)
  [ ! -d "$_wt_gitdir/rebase-merge" ]
  [ ! -d "$_wt_gitdir/rebase-apply" ]
  [ -z "$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U)" ]

  # Resolved content is committed and force-pushed
  grep -q "Resolved by stub" "$WORKTREE_PATH/README.md"
  git -C "$WORKTREE_PATH" fetch -q origin "$BRANCH_NAME"
  [ "$(git -C "$WORKTREE_PATH" rev-parse HEAD)" = "$(git -C "$WORKTREE_PATH" rev-parse FETCH_HEAD)" ]
}

# ───────────────────────────────────────────────────────────────────
# Structural: one shared helper, all call sites delegate to it
# ───────────────────────────────────────────────────────────────────

@test "structural: all resolver call sites delegate to the shared commit_resolved_conflicts helper" {
  # Helper defined exactly once, in conflict-resolver.sh
  local _defs
  _defs=$(grep -c '^commit_resolved_conflicts()' "$RITE_REPO_ROOT/lib/utils/conflict-resolver.sh" || true)
  [ "$_defs" -eq 1 ]

  # Both stale-branch call sites call the helper (no duplicated inline block)
  local _calls
  _calls=$(grep -cF 'commit_resolved_conflicts "$worktree_path"' "$RITE_REPO_ROOT/lib/utils/stale-branch.sh" || true)
  [ "$_calls" -eq 2 ]

  # divergence-handler and mid-run-rebase call sites delegate too
  grep -q 'commit_resolved_conflicts' "$RITE_REPO_ROOT/lib/utils/divergence-handler.sh"
  grep -qF 'commit_resolved_conflicts "$worktree_path"' "$RITE_REPO_ROOT/lib/utils/mid-run-rebase.sh"

  # The old stderr-swallowing inline commit is gone from every call site
  local _f
  for _f in stale-branch.sh divergence-handler.sh mid-run-rebase.sh; do
    if grep -qF 'git commit --no-edit 2>/dev/null' "$RITE_REPO_ROOT/lib/utils/$_f"; then
      echo "stale swallowed-stderr commit block still present in $_f" >&2
      return 1
    fi
  done
}

# ───────────────────────────────────────────────────────────────────
# Structural: resolver prompt contains no denied git-add instruction
# ───────────────────────────────────────────────────────────────────

@test "structural: resolver session prompt contains no denied git add instruction (#871)" {
  # The PreToolUse deny hook blocks 'git add' inside agentic sessions. An
  # instruction to 'stage each file with git add' burns session turns and
  # produces confusing 'git add needs to be run outside this session' output.
  # Pin: conflict-resolver.sh's prompt text must not contain an in-session
  # git-add instruction. Acceptable forms: "git add" in RULES (prohibiting it)
  # or in comments, but NOT in a directive telling Claude to run it.
  local _resolver="$RITE_REPO_ROOT/lib/utils/conflict-resolver.sh"

  # The denied instruction appeared in two forms in the original prompt (#871):
  #   "stage it with 'git add <file>'"
  #   "stage each file with git add"
  # Check for both. Escape the pipe so grep sees a literal pipe char (OR is not needed;
  # we check each independently for a clearer failure message).
  if grep -q "stage.*with 'git add" "$_resolver"; then
    echo "Prompt still contains denied 'stage ... with git add <file>' instruction" >&2
    return 1
  fi
  if grep -q "stage each file with git add" "$_resolver"; then
    echo "Prompt still contains denied 'stage each file with git add' instruction" >&2
    return 1
  fi
}

# ───────────────────────────────────────────────────────────────────
# Scoped staging: operator WIP stays uncommitted after resolution
# ───────────────────────────────────────────────────────────────────

@test "scoped staging: operator WIP file stays uncommitted after conflict resolution handoff (#871)" {
  # Regression guard for the dirty-worktree + successful-resolution path.
  #
  # Scenario (mirrors the stale-branch.sh flow):
  #   1. Two branches conflict on conflict.txt (guaranteed content conflict)
  #   2. WIP file wip.txt exists in the worktree (operator uncommitted work)
  #   3. Resolver session stub WRITES resolved conflict.txt, stages NOTHING
  #   4. _RITE_RESOLVER_CONFLICT_PATHS is set to "conflict.txt" (pre-session capture)
  #   5. commit_resolved_conflicts is called — must stage ONLY conflict.txt
  #
  # Invariant: wip.txt must remain UNTRACKED and UNSTAGED after the handoff.
  # Previously git add -A would sweep wip.txt into the resolution commit.

  _make_repo
  _make_conflict_branches  # leaves cwd on feat, conflict on f.txt

  # Start a rebase to create the rebase context (the most common conflict path)
  run git rebase main
  [ "$status" -ne 0 ]  # sanity: rebase stopped on the conflict
  local _gitdir
  _gitdir=$(git rev-parse --git-dir)
  [ -d "$_gitdir/rebase-merge" ] || [ -d "$_gitdir/rebase-apply" ]

  # Simulate operator WIP: an untracked file that exists in the tree when the
  # resolver is called (simulates post-stash-pop state in stale-branch.sh)
  echo "operator WIP - must not ride the resolution commit" > wip.txt

  # Simulate resolver session: WRITE the resolution, stage NOTHING
  echo "resolved version" > f.txt

  # Set _RITE_RESOLVER_CONFLICT_PATHS as attempt_claude_merge_resolution would —
  # only the conflict file, not the WIP file
  export _RITE_RESOLVER_CONFLICT_PATHS="f.txt"

  # Call directly (not via 'run') so the variable unset in commit_resolved_conflicts
  # is visible in this shell — we need to verify it's cleared after use.
  commit_resolved_conflicts "$PWD"

  # Rebase must have completed (not stranded)
  [ ! -d "$_gitdir/rebase-merge" ]
  [ ! -d "$_gitdir/rebase-apply" ]

  # Resolved content must be in the commit
  [ "$(git show HEAD:f.txt)" = "resolved version" ]

  # WIP file must stay UNTRACKED — NOT in the commit, NOT staged.
  # git ls-files --error-unmatch exits 1 when the file is not tracked.
  # Use 'run' so bats captures the expected non-zero exit without tripping errexit.
  run git ls-files --error-unmatch wip.txt
  [ "$status" -ne 0 ]  # not tracked — WIP survived

  # Belt-and-suspenders: the resolution commit must not include wip.txt
  local _commit_files
  _commit_files=$(git show --name-only --pretty=format: HEAD || true)
  if echo "$_commit_files" | grep -qF "wip.txt"; then
    echo "wip.txt was swept into the resolution commit by git add -A" >&2
    return 1
  fi

  # _RITE_RESOLVER_CONFLICT_PATHS must be cleared after use (no leak to next call)
  [ -z "${_RITE_RESOLVER_CONFLICT_PATHS:-}" ]
}

@test "scoped staging: fallback to -A when _RITE_RESOLVER_CONFLICT_PATHS is unset (backward compat)" {
  # Callers that bypass attempt_claude_merge_resolution (e.g. direct test
  # invocations, or older call paths) should still work: no path list set →
  # fall back to git add -A, which is the original behavior.

  _make_repo

  # Live add/add incident shape: staged deletion + untracked rewrite at same path
  git rm --cached -q f.txt
  echo "resolved via fallback path" > f.txt

  # Explicitly unset the path list to exercise the fallback
  unset _RITE_RESOLVER_CONFLICT_PATHS

  run commit_resolved_conflicts "$PWD"
  [ "$status" -eq 0 ]

  # -A picked up the untracked rewrite — content committed, not a bare deletion
  [ -n "$(git ls-files f.txt)" ]
  [ "$(git show HEAD:f.txt)" = "resolved via fallback path" ]
}
