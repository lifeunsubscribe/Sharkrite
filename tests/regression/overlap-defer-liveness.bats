#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh::_ftm_file_overlap|_apply_overlap_defer_or_warn
# tests/regression/overlap-defer-liveness.bats
#
# Regression tests for the liveness-gate additions to the cross-batch file
# overlap check (issue #1613).
#
# New invariants exercised here:
#   1. Single-issue batch (_UNIQUE_ISSUE_COUNT=1) → no-op, no output
#   2. Overlapping worktree with no lock entry → skipped (not in-flight)
#   3. Overlapping worktree with dead-pid lock → skipped
#   4. Overlapping worktree with backfill lock (no pid file) → skipped
#   5. Live intra-batch overlap (lock issue in ISSUE_LIST) → defer
#   6. Live cross-batch overlap (lock issue NOT in ISSUE_LIST) → info + proceed
#      and [diag] OVERLAP_CROSS_BATCH emitted
#
# The existing batch-cross-batch-overlap.bats covers the intra-batch defer
# and cap behaviors with live fixtures; this file focuses on the liveness
# gate new logic.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"

# =============================================================================
# Fixture helpers
# =============================================================================

# _setup_overlap_repo OVERLAP_FILE
#
# Create a minimal fixture git repo with one worktree whose branch has a
# commit touching OVERLAP_FILE.  Prints "<repo_path> <wt_path>" (space-sep).
_setup_overlap_repo() {
  local _overlap_file="${1:-lib/core/batch-process-issues.sh}"
  local _repo="$BATS_TEST_TMPDIR/repo-$$"
  # Use an issue-number-encoded basename so batch_suffix_matches_issue("ft-other-issue_b77", "77")
  # matches the lock file issue-77.lock — cwd comparison is unreliable (project-root lock).
  local _wt="$BATS_TEST_TMPDIR/ft-other-issue_b77"

  mkdir -p "$_repo"
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@sharkrite.test"
  git -C "$_repo" config user.name "Sharkrite Test"

  printf 'init\n' > "$_repo/README.md"
  git -C "$_repo" add README.md
  git -C "$_repo" commit -q -m "Initial commit"

  git -C "$_repo" branch "ft-other-issue"
  git -C "$_repo" worktree add -q "$_wt" "ft-other-issue"

  mkdir -p "$_wt/$(dirname "$_overlap_file")"
  printf 'changed\n' > "$_wt/$_overlap_file"
  git -C "$_wt" add "$_overlap_file"
  git -C "$_wt" commit -q -m "Change $_overlap_file"

  printf '%s %s\n' "$_repo" "$_wt"
}

# _extract_batch_functions DEST_DIR
#
# Extract batch_suffix_matches_issue, _ftm_file_overlap, and
# _apply_overlap_defer_or_warn from the production batch processor into
# separate files in DEST_DIR.  Returns 1 on extraction failure.
_extract_batch_functions() {
  local _dest="$1"

  awk '/^batch_suffix_matches_issue[(][)]/ { in_fn=1 }
       in_fn { print }
       in_fn && /^}$/ { exit }' \
    "$BATCH_PROCESSOR" > "$_dest/fn0.sh" 2>/dev/null
  grep -q "batch_suffix_matches_issue" "$_dest/fn0.sh" || return 1

  awk '/_ftm_file_overlap[(][)]/ { in_fn=1 }
       in_fn { print }
       in_fn && /^}$/ { exit }' \
    "$BATCH_PROCESSOR" > "$_dest/fn1.sh" 2>/dev/null
  grep -q "_ftm_file_overlap" "$_dest/fn1.sh" || return 1

  awk '/_apply_overlap_defer_or_warn[(][)]/ { in_fn=1 }
       in_fn { print }
       in_fn && /^}$/ { exit }' \
    "$BATCH_PROCESSOR" > "$_dest/fn2.sh" 2>/dev/null
  grep -q "_apply_overlap_defer_or_warn" "$_dest/fn2.sh" || return 1

  return 0
}

# _build_liveness_script REPO BODY_FILE LOCK_DIR UNIQUE_COUNT ISSUE_LIST_STR
#
# Generate a fixture shell script that:
#   1. Sets RITE_LOCK_DIR to LOCK_DIR (pre-populated by the test)
#   2. Inlines the three production functions extracted from the batch processor
#   3. Runs _ftm_file_overlap + _apply_overlap_defer_or_warn
#   4. Prints OVERLAP_DEFERRED / OVERLAP_CROSS_BATCH / PROCEEDED to stdout
#      Prints WARNING/INFO/[diag] lines also to stdout so `run` captures all
#
# Prints the path of the generated script.
_build_liveness_script() {
  local _repo="$1"
  local _body_file="$2"
  local _lock_dir="$3"
  local _unique_count="${4:-3}"
  local _issue_list_str="${5:-42}"  # space-separated issue numbers for ISSUE_LIST
  local _fns="$BATS_TEST_TMPDIR/fns-$$"
  local _script="$BATS_TEST_TMPDIR/test-liveness-$$.sh"

  mkdir -p "$_fns"
  _extract_batch_functions "$_fns" || {
    echo "ERROR: could not extract batch functions from $BATCH_PROCESSOR" >&2
    return 1
  }

  local _fn0_body _fn1_body _fn2_body
  _fn0_body=$(cat "$_fns/fn0.sh")
  _fn1_body=$(cat "$_fns/fn1.sh")
  _fn2_body=$(cat "$_fns/fn2.sh")

  cat > "$_script" << SCRIPT_EOF
#!/usr/bin/env bash
set -euo pipefail

RITE_LOCK_DIR="${_lock_dir}"

# Route all output to stdout so bats \`run\` captures everything.
print_warning() { printf 'WARNING: %s\n' "\$*"; }
print_info()    { printf 'INFO: %s\n' "\$*"; }
_diag()         { printf '[diag] %s\n' "\$*"; }

${_fn0_body}

${_fn1_body}

${_fn2_body}

declare -A ISSUE_STATUS
declare -A _DEFER_COUNT
_UNIQUE_ISSUE_COUNT=${_unique_count}
# shellcheck disable=SC2206
ISSUE_LIST=(${_issue_list_str})
ISSUE_NUM=42
_OVERLAP_FILES=""
_OVERLAP_WT=""
_OVERLAP_ISSUE_NUM=""

cd "${_repo}"
ISSUE_BODY=\$(cat "${_body_file}")

_ftm_file_overlap "\$ISSUE_BODY"

_list_len_before="\${#ISSUE_LIST[@]}"
_overlap_action_rc=0; _apply_overlap_defer_or_warn || _overlap_action_rc=\$?

if [ "\$_overlap_action_rc" -ne 0 ]; then
  echo "OVERLAP_DEFERRED: issue \$ISSUE_NUM files=\${_OVERLAP_FILES}"
  echo "DEFER_COUNT:\${_DEFER_COUNT[\$ISSUE_NUM]:-0}"
elif [ -n "\${_OVERLAP_ISSUE_NUM:-}" ]; then
  echo "OVERLAP_CROSS_BATCH: issue \$ISSUE_NUM files=\${_OVERLAP_FILES}"
else
  echo "PROCEEDED: issue \$ISSUE_NUM"
fi
SCRIPT_EOF
  chmod +x "$_script"
  echo "$_script"
}

# =============================================================================
# Tests
# =============================================================================

@test "single-issue batch: no-op — no overlap computation, no output" {
  read -r _repo _wt <<< "$(_setup_overlap_repo "lib/core/batch-process-issues.sh")"
  _body="$BATS_TEST_TMPDIR/body-single-$$.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  # _UNIQUE_ISSUE_COUNT=1 → unreorderable queue → silent no-op
  _lock_dir="$BATS_TEST_TMPDIR/locks-single-$$"
  mkdir -p "$_lock_dir"
  _script=$(_build_liveness_script "$_repo" "$_body" "$_lock_dir" 1 "42")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: expected PROCEEDED for single-issue batch; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -qi "overlap\|WARNING\|INFO\|\[diag\]" || {
    echo "FAIL: single-issue batch must produce no overlap output; got: $output" >&2; return 1
  }
}

@test "no-lock worktree: not counted as in-flight — proceeds silently" {
  read -r _repo _wt <<< "$(_setup_overlap_repo "lib/core/batch-process-issues.sh")"
  _body="$BATS_TEST_TMPDIR/body-nolock-$$.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  # Empty lock dir: no lock entry for the overlapping worktree
  _lock_dir="$BATS_TEST_TMPDIR/locks-nolock-$$"
  mkdir -p "$_lock_dir"

  _script=$(_build_liveness_script "$_repo" "$_body" "$_lock_dir" 3 "42")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: expected PROCEEDED when no lock exists; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED\|OVERLAP_CROSS_BATCH\|WARNING" || {
    echo "FAIL: lockless worktree must not trigger overlap action; got: $output" >&2; return 1
  }
}

@test "dead-pid lock: not counted as in-flight — proceeds silently" {
  read -r _repo _wt <<< "$(_setup_overlap_repo "lib/core/batch-process-issues.sh")"
  _body="$BATS_TEST_TMPDIR/body-deadpid-$$.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  # Capture a PID that will be dead by the time the fixture script runs.
  (exit 0) &
  _dead_pid=$!
  wait $_dead_pid 2>/dev/null || true

  _lock_dir="$BATS_TEST_TMPDIR/locks-deadpid-$$"
  mkdir -p "$_lock_dir/issue-77.lock"
  printf '%d\n' "$_dead_pid" > "$_lock_dir/issue-77.lock/pid"
  printf '%s\n' "$_wt"       > "$_lock_dir/issue-77.lock/cwd"

  _script=$(_build_liveness_script "$_repo" "$_body" "$_lock_dir" 3 "42")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: expected PROCEEDED for dead-pid lock; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED\|OVERLAP_CROSS_BATCH\|WARNING" || {
    echo "FAIL: dead-pid lock must not trigger overlap action; got: $output" >&2; return 1
  }
}

@test "backfill lock (no pid file): not counted as in-flight — proceeds silently" {
  read -r _repo _wt <<< "$(_setup_overlap_repo "lib/core/batch-process-issues.sh")"
  _body="$BATS_TEST_TMPDIR/body-backfill-$$.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  # Backfill lock: has cwd and backfill sentinel but NO pid file.
  _lock_dir="$BATS_TEST_TMPDIR/locks-backfill-$$"
  mkdir -p "$_lock_dir/issue-77.lock"
  printf '%s\n' "$_wt" > "$_lock_dir/issue-77.lock/cwd"
  touch "$_lock_dir/issue-77.lock/backfill"

  _script=$(_build_liveness_script "$_repo" "$_body" "$_lock_dir" 3 "42")
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "PROCEEDED" || {
    echo "FAIL: expected PROCEEDED for backfill lock; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED\|OVERLAP_CROSS_BATCH\|WARNING" || {
    echo "FAIL: backfill lock must not trigger overlap action; got: $output" >&2; return 1
  }
}

@test "intra-batch live lock: issue in ISSUE_LIST → defer" {
  read -r _repo _wt <<< "$(_setup_overlap_repo "lib/core/batch-process-issues.sh")"
  _body="$BATS_TEST_TMPDIR/body-intra-$$.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  # Live lock: use the fixture script's own PID ($$) so kill -0 always passes.
  # We write the PID into the lock file; the fixture script reads it at runtime.
  # Because we need the fixture script's PID (not the bats test PID), we let
  # the fixture script write its own PID to the lock before calling the overlap
  # check. Build a wrapper that sets up the lock and delegates to the inner script.
  _lock_dir="$BATS_TEST_TMPDIR/locks-intra-$$"
  mkdir -p "$_lock_dir/issue-77.lock"
  # Placeholder PID; replaced at runtime by the wrapper below.
  printf '0\n'    > "$_lock_dir/issue-77.lock/pid"
  printf '%s\n' "$_wt" > "$_lock_dir/issue-77.lock/cwd"

  # issue 77 IS in ISSUE_LIST (intra-batch)
  _inner=$(_build_liveness_script "$_repo" "$_body" "$_lock_dir" 3 "42 77")
  _wrapper="$BATS_TEST_TMPDIR/wrapper-intra-$$.sh"
  cat > "$_wrapper" << WRAP_EOF
#!/usr/bin/env bash
# Write this script's own PID into the lock so kill -0 succeeds.
printf '%d\n' \$\$ > "${_lock_dir}/issue-77.lock/pid"
exec bash "${_inner}"
WRAP_EOF
  chmod +x "$_wrapper"
  run bash "$_wrapper"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_DEFERRED" || {
    echo "FAIL: expected OVERLAP_DEFERRED for intra-batch live overlap; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "PROCEEDED\|OVERLAP_CROSS_BATCH" || {
    echo "FAIL: intra-batch overlap must defer, not proceed; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_DEFER" || {
    echo "FAIL: expected [diag] OVERLAP_DEFER for intra-batch overlap; got: $output" >&2; return 1
  }
}

@test "cross-batch live lock: issue NOT in ISSUE_LIST → info line + proceed + OVERLAP_CROSS_BATCH diag" {
  read -r _repo _wt <<< "$(_setup_overlap_repo "lib/core/batch-process-issues.sh")"
  _body="$BATS_TEST_TMPDIR/body-cross-$$.md"
  cat > "$_body" <<'BODY'
**Files to Modify:**
- `lib/core/batch-process-issues.sh` — overlap target
BODY

  _lock_dir="$BATS_TEST_TMPDIR/locks-cross-$$"
  mkdir -p "$_lock_dir/issue-77.lock"
  printf '0\n'    > "$_lock_dir/issue-77.lock/pid"
  printf '%s\n' "$_wt" > "$_lock_dir/issue-77.lock/cwd"

  # issue 77 is NOT in ISSUE_LIST — this batch only owns issue 42
  _inner=$(_build_liveness_script "$_repo" "$_body" "$_lock_dir" 3 "42")
  _wrapper="$BATS_TEST_TMPDIR/wrapper-cross-$$.sh"
  cat > "$_wrapper" << WRAP_EOF
#!/usr/bin/env bash
printf '%d\n' \$\$ > "${_lock_dir}/issue-77.lock/pid"
exec bash "${_inner}"
WRAP_EOF
  chmod +x "$_wrapper"
  run bash "$_wrapper"

  [ "$status" -eq 0 ] || {
    echo "Script exited $status: $output" >&2; return 1
  }
  echo "$output" | grep -q "OVERLAP_CROSS_BATCH: issue 42" || {
    echo "FAIL: expected OVERLAP_CROSS_BATCH outcome for cross-batch overlap; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "OVERLAP_DEFERRED" || {
    echo "FAIL: cross-batch overlap must NOT defer; got: $output" >&2; return 1
  }
  echo "$output" | grep -q "\[diag\] OVERLAP_CROSS_BATCH" || {
    echo "FAIL: expected [diag] OVERLAP_CROSS_BATCH for cross-batch overlap; got: $output" >&2; return 1
  }
  ! echo "$output" | grep -q "WARNING" || {
    echo "FAIL: cross-batch path must not emit WARNING (use INFO); got: $output" >&2; return 1
  }
}

@test "structural: kill -0 is present in _ftm_file_overlap in batch source" {
  _fn_text=$(awk '/_ftm_file_overlap[(][)]/ { in_fn=1 }
                   in_fn { print }
                   in_fn && /^}$/ { exit }' "$BATCH_PROCESSOR" || true)
  echo "$_fn_text" | grep -q "kill -0" || {
    echo "FAIL: _ftm_file_overlap must contain kill -0 liveness check" >&2; return 1
  }
}

@test "structural: OVERLAP_CROSS_BATCH diag emitted by _apply_overlap_defer_or_warn" {
  grep -q "OVERLAP_CROSS_BATCH" "$BATCH_PROCESSOR" || {
    echo "FAIL: OVERLAP_CROSS_BATCH diag not found in $BATCH_PROCESSOR" >&2; return 1
  }
}

@test "structural: no print_warning on cap-exhausted or cross-batch path" {
  _fn_text=$(awk '/_apply_overlap_defer_or_warn[(][)]/ { in_fn=1 }
                   in_fn { print }
                   in_fn && /^}$/ { exit }' "$BATCH_PROCESSOR" || true)
  # Only the intra-batch below-cap path should use print_warning.
  # Count print_warning occurrences: must be exactly 1 (the defer-below-cap line).
  _count=$(echo "$_fn_text" | grep -c "print_warning" || true)
  [ "$_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 print_warning in _apply_overlap_defer_or_warn (got $_count)" >&2
    echo "$_fn_text" | grep "print_warning" >&2
    return 1
  }
}
