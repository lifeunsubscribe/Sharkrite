#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/repo-status.sh
# tests/regression/worktree-stale-detection-symlinks.bats
#
# Regression test for: Prevent stale detection from traversing symlinks
#
# Bug: find "$wt_path" -type f ... traverses into .venv (a symlink in worktrees
# pointing back to main). When the symlink target is removed/moved, find still
# descends into it, stat returns mtime=0 for each broken entry, and
# portable_find_max_mtime returns 0 → DAYS_OLD=999 → worktree marked stale and
# removed, destroying uncommitted source files.
#
# Fix: all three find call sites now use -not -type l (skip symlinks) and
# -not -path exclusions for .venv/node_modules/.rite.
#
# Tests:
# 1. find -not -type l skips broken .venv symlink; source file still found
# 2. portable_find_max_mtime returns real mtime when source file is recent
#    (not 0 from broken symlink stat failure)
# 3. Stale verdict is NOT triggered when source file is fresh
# 4. find does not traverse into node_modules or .rite dirs
# 5. find still returns source files when .venv symlink is valid (not broken)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  # Source portable-cmds for portable_find_max_mtime and portable_stat_mtime
  source "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  # Create a simulated worktree directory
  WT_PATH="${RITE_TEST_TMPDIR}/fake-worktree"
  mkdir -p "$WT_PATH"

  # Create a real source file (recently modified)
  echo "export function main() {}" > "$WT_PATH/main.ts"

  # Create a broken .venv symlink (target does not exist — simulates removed venv)
  ln -s "/nonexistent/path/that/does/not/exist" "$WT_PATH/.venv"

  export WT_PATH
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# Core: broken symlink is skipped; source file is still found
# =============================================================================

@test "find -not -type l skips broken .venv symlink and finds real source file" {
  # The fixed find command (from cleanup-worktrees.sh) must:
  # 1. Skip the broken .venv symlink (-not -type l)
  # 2. Still find main.ts (a real file)
  run bash -c '
    find "'"$WT_PATH"'" -not -type l \( -name "*.ts" -o -name "*.js" \) \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" -not -path "*/.rite/*" \
      -print0 2>/dev/null \
      | tr "\0" "\n"
  '
  [ "$status" -eq 0 ]
  # Must find main.ts
  [[ "$output" == *"main.ts"* ]]
  # Must NOT include anything from .venv
  [[ "$output" != *".venv"* ]]
}

# =============================================================================
# Core: mtime is non-zero when only a real source file exists
# =============================================================================

@test "portable_find_max_mtime returns non-zero mtime when source file is recent" {
  # Before the fix, a broken .venv symlink caused stat failures that propagated
  # 0 mtime values, returning 0 → DAYS_OLD=999.
  # After the fix, the broken symlink is excluded; the real file's mtime is used.
  run bash -c '
    source "'"${RITE_REPO_ROOT}"'/lib/utils/portable-cmds.sh"
    find "'"$WT_PATH"'" -not -type l \( -name "*.ts" -o -name "*.js" \) \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" -not -path "*/.rite/*" \
      -print0 2>/dev/null \
      | portable_find_max_mtime || true
  '
  [ "$status" -eq 0 ]
  # mtime must be a non-zero epoch value (i.e., the real file was found)
  [ "$output" -gt 0 ]
}

# =============================================================================
# Regression: worktree with broken .venv + fresh source is NOT marked stale
# =============================================================================

@test "worktree with broken .venv symlink and recent source is not marked stale" {
  # Reproduce the stale-detection logic from cleanup-worktrees.sh inline.
  # A DAYS_OLD > 14 with UNCOMMITTED_COUNT=0 triggers a stale verdict.
  # Before the fix: LAST_MODIFIED=0 (from broken symlink stat) → DAYS_OLD=999 → stale.
  # After the fix: LAST_MODIFIED = mtime of main.ts (recent) → DAYS_OLD=0 → not stale.
  run bash -c '
    source "'"${RITE_REPO_ROOT}"'/lib/utils/portable-cmds.sh"

    LAST_MODIFIED=$(find "'"$WT_PATH"'" -not -type l \( -name "*.ts" -o -name "*.js" \) \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" -not -path "*/.rite/*" \
      -print0 2>/dev/null \
      | portable_find_max_mtime || true)
    [ "${LAST_MODIFIED:-0}" = "0" ] && LAST_MODIFIED=""

    if [ -n "$LAST_MODIFIED" ]; then
      DAYS_OLD=$(( ( $(date +%s) - LAST_MODIFIED ) / 86400 ))
    else
      DAYS_OLD=999
    fi

    echo "DAYS_OLD=$DAYS_OLD"
  '
  [ "$status" -eq 0 ]
  # DAYS_OLD must be 0 (file was just created in setup)
  [[ "$output" == "DAYS_OLD=0" ]]
}

# =============================================================================
# Guard: node_modules and .rite directories are not traversed
# =============================================================================

@test "find excludes node_modules directory from traversal" {
  # Create a source file inside node_modules — must NOT be returned
  mkdir -p "$WT_PATH/node_modules/some-pkg"
  echo "stale content" > "$WT_PATH/node_modules/some-pkg/index.ts"

  run bash -c '
    find "'"$WT_PATH"'" -not -type l \( -name "*.ts" -o -name "*.js" \) \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" -not -path "*/.rite/*" \
      -print0 2>/dev/null \
      | tr "\0" "\n"
  '
  [ "$status" -eq 0 ]
  # Must still find main.ts
  [[ "$output" == *"main.ts"* ]]
  # Must NOT find anything inside node_modules
  [[ "$output" != *"node_modules"* ]]
}

@test "find excludes .rite directory from traversal" {
  # In worktrees, .rite is typically a symlink back to main; if the symlink is
  # valid, -not -type l alone won't stop find from following it. The -not -path
  # exclusion is a belt-and-suspenders guard.
  mkdir -p "$WT_PATH/.rite/worktrees"
  echo "old rite data" > "$WT_PATH/.rite/worktrees/config.sh"

  run bash -c '
    find "'"$WT_PATH"'" -not -type l \( -name "*.ts" -o -name "*.js" -o -name "*.sh" \) \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" -not -path "*/.rite/*" \
      -print0 2>/dev/null \
      | tr "\0" "\n"
  '
  [ "$status" -eq 0 ]
  # Must find main.ts
  [[ "$output" == *"main.ts"* ]]
  # Must NOT find anything inside .rite
  [[ "$output" != *".rite"* ]]
}

# =============================================================================
# Correctness: valid (non-broken) .venv symlink also does not inflate mtime
# =============================================================================

@test "find excludes valid .venv symlink directory via -not -path" {
  # Remove the broken symlink from setup and replace with a real directory
  rm "$WT_PATH/.venv"
  mkdir -p "$WT_PATH/.venv/lib/python3.11/site-packages"
  # Put a very OLD file inside .venv to confirm it's not counted
  touch -t 200001010000 "$WT_PATH/.venv/lib/python3.11/site-packages/old.py" 2>/dev/null || \
    touch "$WT_PATH/.venv/lib/python3.11/site-packages/old.py"

  run bash -c '
    source "'"${RITE_REPO_ROOT}"'/lib/utils/portable-cmds.sh"
    find "'"$WT_PATH"'" -not -type l \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" -not -path "*/.rite/*" \
      -print0 2>/dev/null \
      | tr "\0" "\n"
  '
  [ "$status" -eq 0 ]
  # Must find main.ts but NOT old.py inside .venv
  [[ "$output" == *"main.ts"* ]]
  [[ "$output" != *".venv"* ]]
}
