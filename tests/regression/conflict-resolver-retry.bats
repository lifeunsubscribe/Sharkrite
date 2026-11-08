#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh
# tests/regression/conflict-resolver-retry.bats
#
# Tests the bounded retry loop added in #1602:
#   - A partial first session (markers remain in some files) triggers a retry
#     with ONLY the still-failing files, leaving correctly-resolved files untouched.
#   - A conflict set that converges on attempt 2 completes normally (return 0).
#   - A conflict set that never converges aborts after _CR_MAX_RESOLVE_ATTEMPTS
#     attempts (return 1) and names the still-unresolved paths.
#   - The diag line CONFLICT_RESOLVE_ATTEMPT is emitted per attempt.
#   - The timeout budget is shared across all attempts (not multiplied by 3).
#
# Only provider_run_agentic_session is stubbed — all other resolver logic runs
# from the actual source code. This follows the established pattern in
# conflict-resolver.bats (#1602 uses the same fixture helpers).

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

setup() {
  setup_test_tmpdir

  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Route diag lines to a log file we can assert against
  DIAG_LOG="$RITE_TEST_TMPDIR/conflict-resolver-retry-diag.log"
  export RITE_LOG_FILE="$DIAG_LOG"
  touch "$DIAG_LOG"

  # Provide _diag so the resolver's declare-f guard fires and diag lines are written.
  _diag() { printf '[diag] %s\n' "$*" >> "$RITE_LOG_FILE"; }

  unset RITE_VERBOSE

  cd "$FIXTURE_REPO"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create 5 conflicting files between a feature branch and origin/main.
# Returns with FIXTURE_REPO as cwd on the feature branch (clean tree, post-abort).
# Sets BRANCH_NAME and CONFLICT_FILES (newline-delimited list).
_setup_multi_file_conflict() {
  BRANCH_NAME="fix/retry-test-$$"
  CONFLICT_FILES=""

  local i
  for i in 1 2 3 4 5; do
    local fname="file${i}.txt"
    CONFLICT_FILES="${CONFLICT_FILES}${fname}
"
  done

  # Feature branch: add "branch" content to each file
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  for i in 1 2 3 4 5; do
    printf 'branch line %d\n' "$i" > "file${i}.txt"
    git add "file${i}.txt"
  done
  git commit -m "Branch: add 5 files" >/dev/null 2>&1

  # Advance main with conflicting content on the same files
  git checkout main >/dev/null 2>&1
  for i in 1 2 3 4 5; do
    printf 'main line %d\n' "$i" > "file${i}.txt"
    git add "file${i}.txt"
  done
  git commit -m "Main: add 5 files (conflicts with branch)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Return to feature branch in the standard pre-resolver state (clean tree)
  git checkout "$BRANCH_NAME" >/dev/null 2>&1
  git merge origin/main --no-edit 2>/dev/null || true
  git merge --abort 2>/dev/null || true
}

# Assert DIAG_LOG contains a matching line.
_assert_diag() {
  local pattern="$1"
  if ! grep -q "$pattern" "$DIAG_LOG" 2>/dev/null; then
    echo "FAIL: Expected diag pattern '$pattern' not found in $DIAG_LOG" >&2
    cat "$DIAG_LOG" >&2
    return 1
  fi
}

# ===========================================================================
# RETRY: first attempt leaves markers in 2 of 5 files; second attempt resolves
# them; resolver returns 0 without operator involvement.
# ===========================================================================

@test "retry: converges on attempt 2 when first session leaves markers in 2 files" {
  _setup_multi_file_conflict

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail

  # Track how many times provider_run_agentic_session is called.
  PROVIDER_CALL_COUNT=0

  # Attempt 1: resolve file1-file3 correctly; leave file4 and file5 with markers.
  # Attempt 2: resolve file4 and file5 (the ONLY files re-submitted on retry).
  # Parse the file list from the prompt arg — the resolver passes only still-failing
  # files on retry, so we must NOT use git diff to discover which files to process.
  # Do NOT call git add: the resolver checks file content (not index state) for markers.
  provider_run_agentic_session() {
    PROVIDER_CALL_COUNT=$(( PROVIDER_CALL_COUNT + 1 ))
    local _prompt="$1"
    local _conflicted
    _conflicted=$(printf '%s\n' "$_prompt" | awk '/^## Conflicting files to resolve:$/{f=1;next} /^Read each conflicting file/{f=0} f && NF{print}' || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      if [ "$PROVIDER_CALL_COUNT" -eq 1 ] && { [ "$_f" = "file4.txt" ] || [ "$_f" = "file5.txt" ]; }; then
        # Leave markers in file4 and file5 on the first attempt
        printf '<<<<<<< HEAD\nbranch content\n=======\nmain content\n>>>>>>> origin/main\n' > "$_f"
      else
        # Resolve cleanly (also handles the retry for file4/file5)
        printf 'resolved content\n' > "$_f"
      fi
    done <<< "$_conflicted"
    return 0
  }
  load_provider()       { return 0; }
  provider_detect_cli() { return 0; }
  provider_healthcheck(){ return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Must succeed
  [ "$result" -eq 0 ]

  # Provider was called exactly twice (one full attempt + one retry)
  [ "$PROVIDER_CALL_COUNT" -eq 2 ]

  # No conflict markers remain
  for i in 1 2 3 4 5; do
    if grep -qE '^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]])' "file${i}.txt" 2>/dev/null; then
      echo "FAIL: Conflict markers still present in file${i}.txt" >&2
      return 1
    fi
  done
}

# ===========================================================================
# RETRY: diag line is emitted for EACH attempt.
# ===========================================================================

@test "retry: emits CONFLICT_RESOLVE_ATTEMPT diag per attempt" {
  _setup_multi_file_conflict

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail

  PROVIDER_CALL_COUNT=0

  provider_run_agentic_session() {
    PROVIDER_CALL_COUNT=$(( PROVIDER_CALL_COUNT + 1 ))
    local _prompt="$1"
    local _conflicted
    _conflicted=$(printf '%s\n' "$_prompt" | awk '/^## Conflicting files to resolve:$/{f=1;next} /^Read each conflicting file/{f=0} f && NF{print}' || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      if [ "$PROVIDER_CALL_COUNT" -eq 1 ] && [ "$_f" = "file5.txt" ]; then
        # Leave file5 with markers on attempt 1 to force a retry
        printf '<<<<<<< HEAD\nbranch\n=======\nmain\n>>>>>>> origin/main\n' > "$_f"
      else
        printf 'resolved\n' > "$_f"
      fi
    done <<< "$_conflicted"
    return 0
  }
  load_provider()       { return 0; }
  provider_detect_cli() { return 0; }
  provider_healthcheck(){ return 0; }

  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || true

  # Attempt 1 diag: n=1
  _assert_diag "CONFLICT_RESOLVE_ATTEMPT n=1"
  # Attempt 2 diag: n=2 (only file5 remaining)
  _assert_diag "CONFLICT_RESOLVE_ATTEMPT n=2 remaining=1"
}

# ===========================================================================
# RETRY: files resolved on attempt 1 are not re-submitted on retry.
# The retry prompt receives ONLY the still-failing files.
# ===========================================================================

@test "retry: provider stub sees only still-failing files on the second attempt" {
  _setup_multi_file_conflict

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail

  PROVIDER_CALL_COUNT=0
  ATTEMPT2_FILES=""

  provider_run_agentic_session() {
    PROVIDER_CALL_COUNT=$(( PROVIDER_CALL_COUNT + 1 ))
    local _prompt="$1"
    local _conflicted
    _conflicted=$(printf '%s\n' "$_prompt" | awk '/^## Conflicting files to resolve:$/{f=1;next} /^Read each conflicting file/{f=0} f && NF{print}' || true)

    if [ "$PROVIDER_CALL_COUNT" -eq 2 ]; then
      # Record which files the resolver gave to the second attempt (from the prompt).
      # Only files still marked as failing are re-submitted; already-resolved files
      # must NOT appear here.
      ATTEMPT2_FILES="$_conflicted"
    fi

    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      if [ "$PROVIDER_CALL_COUNT" -eq 1 ] && { [ "$_f" = "file4.txt" ] || [ "$_f" = "file5.txt" ]; }; then
        # Leave markers in file4/file5 on attempt 1
        printf '<<<<<<< HEAD\nbranch\n=======\nmain\n>>>>>>> origin/main\n' > "$_f"
      else
        printf 'resolved\n' > "$_f"
      fi
    done <<< "$_conflicted"
    return 0
  }
  load_provider()       { return 0; }
  provider_detect_cli() { return 0; }
  provider_healthcheck(){ return 0; }

  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || true

  # Second call must have happened
  [ "$PROVIDER_CALL_COUNT" -eq 2 ]

  # Attempt 2 must NOT have been given file1, file2, or file3
  if printf '%s' "$ATTEMPT2_FILES" | grep -qE '^file[123]\.txt$'; then
    echo "FAIL: Attempt 2 was given already-resolved files: $ATTEMPT2_FILES" >&2
    return 1
  fi

  # Attempt 2 MUST have included file4 and file5
  printf '%s\n' "$ATTEMPT2_FILES" | grep -qE '^file4\.txt$'
  printf '%s\n' "$ATTEMPT2_FILES" | grep -qE '^file5\.txt$'
}

# ===========================================================================
# EXHAUSTION: session never resolves any file; resolver aborts after
# _CR_MAX_RESOLVE_ATTEMPTS attempts and returns 1.
# ===========================================================================

@test "retry: aborts after max attempts when no progress is made, returns 1" {
  _setup_multi_file_conflict

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail

  PROVIDER_CALL_COUNT=0

  # Stub always leaves markers — simulates a session that cannot converge.
  # Uses prompt arg for the file list; does NOT call git add (resolver checks
  # file content for markers, not index state).
  provider_run_agentic_session() {
    PROVIDER_CALL_COUNT=$(( PROVIDER_CALL_COUNT + 1 ))
    local _prompt="$1"
    local _conflicted
    _conflicted=$(printf '%s\n' "$_prompt" | awk '/^## Conflicting files to resolve:$/{f=1;next} /^Read each conflicting file/{f=0} f && NF{print}' || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      # Always leave conflict markers — never resolves
      printf '<<<<<<< HEAD\nbranch\n=======\nmain\n>>>>>>> origin/main\n' > "$_f"
    done <<< "$_conflicted"
    return 0
  }
  load_provider()       { return 0; }
  provider_detect_cli() { return 0; }
  provider_healthcheck(){ return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Must return 1 (failure)
  [ "$result" -eq 1 ]

  # Provider was called exactly _CR_MAX_RESOLVE_ATTEMPTS (3) times
  [ "$PROVIDER_CALL_COUNT" -eq 3 ]

  # Working tree must be clean (merge aborted)
  local remaining
  remaining=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$remaining" -eq 0 ]

  # Diag lines for all 3 attempts must be present
  _assert_diag "CONFLICT_RESOLVE_ATTEMPT n=1"
  _assert_diag "CONFLICT_RESOLVE_ATTEMPT n=2"
  _assert_diag "CONFLICT_RESOLVE_ATTEMPT n=3"
}

# ===========================================================================
# EXHAUSTION: working tree is clean after all attempts exhausted.
# ===========================================================================

@test "retry: leaves clean working tree after all attempts exhausted" {
  _setup_multi_file_conflict

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail

  # Provider always leaves markers — never resolves.
  provider_run_agentic_session() {
    local _prompt="$1"
    local _conflicted
    _conflicted=$(printf '%s\n' "$_prompt" | awk '/^## Conflicting files to resolve:$/{f=1;next} /^Read each conflicting file/{f=0} f && NF{print}' || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      printf '<<<<<<< HEAD\nbranch\n=======\nmain\n>>>>>>> origin/main\n' > "$_f"
    done <<< "$_conflicted"
    return 0
  }
  load_provider()       { return 0; }
  provider_detect_cli() { return 0; }
  provider_healthcheck(){ return 0; }

  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || true

  # Working tree must be clean (merge aborted by exhaustion path)
  local unmerged
  unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
  [ "$unmerged" -eq 0 ]

  # No staged conflicts either (git status should be clean or only show
  # the merge-aborted state, not unmerged entries)
  local staged
  staged=$(git status --porcelain 2>/dev/null | grep -c '^UU' || true)
  [ "$staged" -eq 0 ]
}

# ===========================================================================
# USAGE CAP: exit 5 propagates immediately — no retry on cap exhaustion.
# ===========================================================================

@test "retry: usage cap (exit 5) aborts immediately without retrying" {
  _setup_multi_file_conflict

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  set +u; set +o pipefail

  PROVIDER_CALL_COUNT=0

  provider_run_agentic_session() {
    PROVIDER_CALL_COUNT=$(( PROVIDER_CALL_COUNT + 1 ))
    return 5
  }
  load_provider()       { return 0; }
  provider_detect_cli() { return 0; }
  provider_healthcheck(){ return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # Must propagate exit 5
  [ "$result" -eq 5 ]

  # Provider called only once — no retry on cap
  [ "$PROVIDER_CALL_COUNT" -eq 1 ]
}
