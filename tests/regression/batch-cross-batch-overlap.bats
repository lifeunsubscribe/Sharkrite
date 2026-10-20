#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh::_ftm_file_overlap
# tests/regression/batch-cross-batch-overlap.bats
#
# Regression tests for the cross-batch file-overlap warn-and-reorder feature
# (issue #1168).
#
# The overlap check compares an issue's "Files to Modify:" section against
# the changed files of other in-flight worktrees (local git only, no network).
# On intersection: warn + re-append (bounded by _DEFER_COUNT/_UNIQUE_ISSUE_COUNT).
# Cap exhausted: warn + run in place (never skip).
# Missing/empty "Files to Modify:" section: silent no-op.
#
# Tests:
#   BEHAVIORAL:
#    1. Issue whose Files-to-Modify intersects another worktree's diff → deferred
#    2. Issue whose Files-to-Modify does NOT intersect → runs untouched
#    3. Cap exhausted → warns + runs in place (not skipped)
#    4. Missing "Files to Modify:" section → silent no-op (proceeds)
#    5. Empty "Files to Modify:" section → silent no-op (proceeds)
#    6. Directory-prefix declared (tests/regression/) matches changed file
#    7. Glob declared (lib/utils/*.sh) matches changed file
#
#   STRUCTURAL:
#    8. New block contains no gh or curl calls (local git only)
#    9. _ftm_file_overlap function present in batch source

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"

# =============================================================================
# Fixture helpers
# =============================================================================

# _setup_wt_repo OVERLAP_FILE
#
# Create a minimal fixture git repo with one worktree whose branch has a
# commit touching OVERLAP_FILE.  Prints "<repo_path>:<worktree_path>".
#
# The worktree path is meaningful to _ftm_file_overlap because the function
# runs git worktree list from the fixture repo directory and then calls
# git -C <wt> diff to compute changed files.
_setup_wt_repo() {
  local _overlap_file="${1:-lib/core/batch-process-issues.sh}"
  local _repo="$BATS_TEST_TMPDIR/repo-$$"
  local _wt="$BATS_TEST_TMPDIR/wt-$$"

  mkdir -p "$_repo"
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@sharkrite.test"
  git -C "$_repo" config user.name "Sharkrite Test"

  # Initial commit so the repo has a base commit
  printf 'init\n' > "$_repo/README.md"
  git -C "$_repo" add README.md
  git -C "$_repo" commit -q -m "Initial commit"

  # Create a branch and add a worktree for it
  git -C "$_repo" branch "ft-other-issue"
  git -C "$_repo" worktree add -q "$_wt" "ft-other-issue"

  # Commit in the worktree, touching the overlap file
  mkdir -p "$_wt/$(dirname "$_overlap_file")"
  printf 'changed\n' > "$_wt/$_overlap_file"
  git -C "$_wt" add "$_overlap_file"
  git -C "$_wt" commit -q -m "Change $_overlap_file"

  printf '%s:%s\n' "$_repo" "$_wt"
}

# _build_overlap_script REPO_PATH ISSUE_BODY_FILE [DEFER_COUNT] [UNIQUE_COUNT]
#
# Write a test script that:
#   1. Inlines _ftm_file_overlap (extracted from the batch processor)
#   2. Runs from REPO_PATH so git worktree list sees the fixture worktrees
#   3. Calls _ftm_file_overlap with the body from ISSUE_BODY_FILE
#   4. Prints OVERLAP_DEFERRED / OVERLAP_WARN_IN_PLACE / PROCEEDED + STATUS
# Prints the path of the generated script.
_build_overlap_script() {
  local _repo="$1"
  local _body_file="$2"
  local _defer_count="${3:-0}"
  local _unique_count="${4:-3}"
  local _script="$BATS_TEST_TMPDIR/test-overlap-$$.sh"

  local _fn_tmp="$BATS_TEST_TMPDIR/fn-body-$$.sh"
  awk '
    /_ftm_file_overlap[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^}$/ { exit }
  ' "$BATCH_PROCESSOR" > "$_fn_tmp" 2>/dev/null
  if ! grep -q "_ftm_file_overlap" "$_fn_tmp" 2>/dev/null; then
    echo "ERROR: could not extract _ftm_file_overlap from $BATCH_PROCESSOR" >&2
    return 1
  fi
  local _fn_body
  _fn_body=$(cat "$_fn_tmp" || true)

  cat > "$_script" <<SCRIPT_EOF
#!/usr/bin/env bash
set -euo pipefail

# Inline _ftm_file_overlap extracted from batch-process-issues.sh
${_fn_body}

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
_UNIQUE_ISSUE_COUNT=${_unique_count}
_DEFER_COUNT[42]=${_defer_count}
ISSUE_LIST=(42)
ISSUE_NUM=42

# Globals written by _ftm_file_overlap
_OVERLAP_FILES=""
_OVERLAP_WT=""

# Run from the fixture repo so git worktree list works
cd "${_repo}"

ISSUE_BODY=\$(cat "${_body_file}")

_ftm_file_overlap "\$ISSUE_BODY"

_overlap_defer_count="\${_DEFER_COUNT[\$ISSUE_NUM]:-0}"
_overlap_max="\${_UNIQUE_ISSUE_COUNT:-\${#ISSUE_LIST[@]}}"

if [ -n "\${_OVERLAP_FILES:-}" ]; then
  if [ "\$_overlap_defer_count" -lt "\$_overlap_max" ]; then
    _DEFER_COUNT[\$ISSUE_NUM]=\$(( _overlap_defer_count + 1 ))
    echo "OVERLAP_DEFERRED: issue \$ISSUE_NUM (defer #\${_DEFER_COUNT[\$ISSUE_NUM]}) files=\${_OVERLAP_FILES}"
    ISSUE_LIST+=("\$ISSUE_NUM")
    ISSUE_STATUS["\$ISSUE_NUM"]="deferred_for_overlap"
    echo "STATUS:deferred_for_overlap"
  else
    echo "OVERLAP_WARN_IN_PLACE: issue \$ISSUE_NUM files=\${_OVERLAP_FILES}"
    ISSUE_STATUS["\$ISSUE_NUM"]="cap_exhausted"
    echo "STATUS:cap_exhausted"
  fi
else
  echo "PROCEEDED: issue \$ISSUE_NUM"
  echo "STATUS:proceeded"
fi
SCRIPT_EOF
  chmod +x "$_script"
  echo "$_script"
}

# =============================================================================
# BEHAVIORAL
# =============================================================================

@test "behavioral: overlapping Files-to-Modify → issue deferred" {
  _parts=$(_setup_wt_repo "lib/core/batch-process-issues.sh")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-overlap.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — add overlap check
- a new bats file in `tests/regression/`
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_DEFERRED: issue 42" || {
    echo "FAIL: expected OVERLAP_DEFERRED; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "STATUS:deferred_for_overlap" || {
    echo "FAIL: expected STATUS:deferred_for_overlap; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: must NOT print PROCEEDED on overlap; got: $output" >&2; return 1
  }
}

@test "behavioral: non-overlapping Files-to-Modify → issue runs untouched" {
  _parts=$(_setup_wt_repo "lib/core/batch-process-issues.sh")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-no-overlap.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/utils/config.sh` — unrelated change
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42" || {
    echo "FAIL: expected PROCEEDED for non-overlapping issue; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED" || {
    echo "FAIL: must NOT defer non-overlapping issue; got: $output" >&2; return 1
  }
}

@test "behavioral: cap exhausted → warns and runs in place (never skipped)" {
  _parts=$(_setup_wt_repo "lib/core/batch-process-issues.sh")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-cap.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  # defer_count == unique_count → cap exhausted
  _script=$(_build_overlap_script "$_repo" "$_body" 3 3)
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_WARN_IN_PLACE: issue 42" || {
    echo "FAIL: expected OVERLAP_WARN_IN_PLACE on cap exhaustion; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "STATUS:cap_exhausted" || {
    echo "FAIL: expected STATUS:cap_exhausted; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "SKIPPED\|STATUS:skipped" || {
    echo "FAIL: issue must NOT be skipped when cap is exhausted; got: $output" >&2; return 1
  }
}

@test "behavioral: missing Files-to-Modify section → silent no-op (proceeds)" {
  _parts=$(_setup_wt_repo "lib/core/batch-process-issues.sh")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-nodecl.md"
  cat > "$_body" <<'BODY'
## Description

This issue has no Files to Modify section at all.

## Acceptance Criteria

- [ ] Something
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42" || {
    echo "FAIL: expected PROCEEDED when Files-to-Modify absent; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP" || {
    echo "FAIL: must not overlap-check when Files-to-Modify absent; got: $output" >&2; return 1
  }
}

@test "behavioral: empty Files-to-Modify section → silent no-op (proceeds)" {
  _parts=$(_setup_wt_repo "lib/core/batch-process-issues.sh")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-empty-ftm.md"
  # Section present but has no parseable file paths
  cat > "$_body" <<'BODY'
**Files to Modify:**

## Acceptance Criteria

- [ ] Something
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42" || {
    echo "FAIL: expected PROCEEDED for empty Files-to-Modify; got: $output" >&2; return 1
  }
}

@test "behavioral: directory-prefix declared (tests/regression/) matches changed file" {
  _parts=$(_setup_wt_repo "tests/regression/some-test.bats")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-dir-prefix.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `tests/regression/` — new bats file
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_DEFERRED: issue 42" || {
    echo "FAIL: directory-prefix declared path should match changed file under it; got: $output" >&2
    return 1
  }
}

@test "behavioral: glob declared (lib/utils/*.sh) matches changed file" {
  _parts=$(_setup_wt_repo "lib/utils/config.sh")
  _repo="${_parts%%:*}"
  _body="$BATS_TEST_TMPDIR/body-glob.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/utils/*.sh` — multiple util files
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_DEFERRED: issue 42" || {
    echo "FAIL: glob declared path should match changed file; got: $output" >&2; return 1
  }
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "behavioral: resumed issue's own worktree excluded — no self-deferral" {
  # Worktree path ends with "-42": basename matches *[-_]42, triggering the own-
  # worktree exclusion added for the resume path.  Without the fix the issue
  # would defer against itself up to _UNIQUE_ISSUE_COUNT times.
  local _repo="$BATS_TEST_TMPDIR/repo-resume-$$"
  local _own_wt="$BATS_TEST_TMPDIR/wt-ft-issue-42"

  mkdir -p "$_repo"
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@sharkrite.test"
  git -C "$_repo" config user.name "Sharkrite Test"

  printf 'init\n' > "$_repo/README.md"
  git -C "$_repo" add README.md
  git -C "$_repo" commit -q -m "Initial commit"

  git -C "$_repo" branch "ft-issue-42"
  git -C "$_repo" worktree add -q "$_own_wt" "ft-issue-42"

  # Commit touching the same file the issue declares in Files-to-Modify
  mkdir -p "$_own_wt/lib/core"
  printf 'changed\n' > "$_own_wt/lib/core/batch-process-issues.sh"
  git -C "$_own_wt" add "lib/core/batch-process-issues.sh"
  git -C "$_own_wt" commit -q -m "WIP for issue 42"

  _body="$BATS_TEST_TMPDIR/body-resume-$$-.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — resume of issue 42
BODY

  _script=$(_build_overlap_script "$_repo" "$_body")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED: issue 42" || {
    echo "FAIL: issue should PROCEED — own worktree must not trigger self-deferral; got: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED" || {
    echo "FAIL: issue must NOT defer against its own worktree; got: $output" >&2; return 1
  }
}

@test "structural: new overlap block contains no gh or curl calls (local git only)" {
  # Extract lines between the overlap-check comment marker and the next
  # section comment, then verify no network tool is invoked.
  _block=$(awk '
    /Per-slot cross-batch file overlap check/ { in_block=1 }
    in_block && /Check if issue is actively being worked on/ { exit }
    in_block { print }
  ' "$BATCH_PROCESSOR" || true)

  [ -n "$_block" ] || {
    echo "FAIL: could not find overlap block in $BATCH_PROCESSOR" >&2; return 1
  }
  ! echo "$_block" | grep -qE '\bgh\b|\bcurl\b' || {
    echo "FAIL: overlap block must not invoke gh or curl; block:" >&2
    echo "$_block" >&2
    return 1
  }
}

@test "structural: _ftm_file_overlap function present in batch source" {
  grep -q "_ftm_file_overlap()" "$BATCH_PROCESSOR" || {
    echo "FAIL: _ftm_file_overlap not found in $BATCH_PROCESSOR" >&2; return 1
  }
}
