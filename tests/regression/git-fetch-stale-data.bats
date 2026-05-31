#!/usr/bin/env bats
# tests/regression/git-fetch-stale-data.bats
#
# Regression test for: Stop reading refs after silent git fetch failure
#
# Bug pattern: `git fetch origin <ref> 2>/dev/null || true` immediately
# followed by reading the fetched ref. On network failure, fetch silently
# succeeds (exit 0 from || true), and subsequent reads use STALE remote state.
#
# Fix: `git_fetch_safe` in lib/utils/git-helpers.sh — 3 retries with backoff,
# fails loudly (exit 1 + remediation) after exhausting retries.
#
# This test verifies:
# 1. git_fetch_safe retries on failure
# 2. git_fetch_safe returns non-zero after all retries exhausted
# 3. git_fetch_safe prints a clear error + remediation message
# 4. git_fetch_safe succeeds immediately when fetch works
# 5. Codebase has zero remaining bare `git fetch ... || true` patterns

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  # Set up RITE_LIB_DIR so git-helpers.sh can find colors.sh
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Create a fake git repo so git commands don't fail on "not a git repo"
  git init -q "$RITE_TEST_TMPDIR/repo"
  cd "$RITE_TEST_TMPDIR/repo"
  git config user.email "test@test.com"
  git config user.name "Test"

  # Inject a fake PATH directory before real git — tests can drop shims here
  export SHIM_DIR="$RITE_TEST_TMPDIR/shims"
  mkdir -p "$SHIM_DIR"
  export PATH="$SHIM_DIR:$PATH"

  # Source git helpers (and colors it depends on)
  source "$RITE_LIB_DIR/utils/colors.sh"
  source "$RITE_LIB_DIR/utils/git-helpers.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: create a git shim that fails N times then succeeds
# ---------------------------------------------------------------------------
_make_failing_git_shim() {
  local fail_count="$1"  # How many times to fail before succeeding
  local counter_file="$RITE_TEST_TMPDIR/fail_count"
  echo "0" > "$counter_file"

  cat > "$SHIM_DIR/git" <<EOF
#!/bin/bash
# Git shim: fails on fetch for the first $fail_count calls, then passes
if [[ "\$*" == *"fetch"* ]]; then
  count=\$(cat "$counter_file")
  count=\$((count + 1))
  echo "\$count" > "$counter_file"
  if [ "\$count" -le $fail_count ]; then
    exit 1
  fi
fi
# Delegate all non-fetch commands (and successful fetches) to real git
exec "$(which git)" "\$@"
EOF
  chmod +x "$SHIM_DIR/git"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "git_fetch_safe: succeeds immediately when fetch works" {
  # Set up a real remote so fetch can succeed
  local remote_dir="$RITE_TEST_TMPDIR/remote"
  git init -q --bare "$remote_dir"
  git remote add origin "$remote_dir"

  # Create and push an initial commit so origin/main exists
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  git push -q origin "HEAD:refs/heads/main"

  run git_fetch_safe origin main
  [ "$status" -eq 0 ]
}

@test "git_fetch_safe: retries on transient failure (fails 2 times, succeeds 3rd)" {
  # Set up a real remote
  local remote_dir="$RITE_TEST_TMPDIR/remote"
  git init -q --bare "$remote_dir"
  git remote add origin "$remote_dir"
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  git push -q origin "HEAD:refs/heads/main"

  # Inject shim that fails twice then delegates to real git
  _make_failing_git_shim 2

  run git_fetch_safe origin main
  [ "$status" -eq 0 ]

  # Verify the shim was called at least twice (retries happened)
  local call_count
  call_count=$(cat "$RITE_TEST_TMPDIR/fail_count")
  [ "$call_count" -ge 2 ]
}

@test "git_fetch_safe: returns non-zero after all retries exhausted" {
  # Inject shim that always fails on fetch
  cat > "$SHIM_DIR/git" <<'SHIM'
#!/bin/bash
if [[ "$*" == *"fetch"* ]]; then
  exit 1
fi
SHIM
  chmod +x "$SHIM_DIR/git"

  run git_fetch_safe origin main
  [ "$status" -ne 0 ]
}

@test "git_fetch_safe: prints clear error message on failure" {
  # Inject shim that always fails on fetch
  cat > "$SHIM_DIR/git" <<'SHIM'
#!/bin/bash
if [[ "$*" == *"fetch"* ]]; then
  exit 1
fi
SHIM
  chmod +x "$SHIM_DIR/git"

  run git_fetch_safe origin main
  [ "$status" -ne 0 ]
  # Error message must mention the remote and ref
  [[ "$output" =~ "origin" ]]
  [[ "$output" =~ "main" ]]
  # Must include remediation hint
  [[ "$output" =~ "network" ]] || [[ "$output" =~ "Remediation" ]] || [[ "$output" =~ "check" ]]
}

@test "git_fetch_safe: prints retry warnings before final failure" {
  # Inject shim that always fails on fetch
  cat > "$SHIM_DIR/git" <<'SHIM'
#!/bin/bash
if [[ "$*" == *"fetch"* ]]; then
  exit 1
fi
SHIM
  chmod +x "$SHIM_DIR/git"

  run git_fetch_safe origin main
  [ "$status" -ne 0 ]
  # Should mention attempts/retries
  [[ "$output" =~ "attempt" ]] || [[ "$output" =~ "retr" ]]
}

@test "codebase has no bare 'git fetch ... 2>/dev/null || true' patterns" {
  # This is the core regression guard — ensures no one re-introduces the bug
  PROJECT_ROOT="$(cd "${RITE_REPO_ROOT}" && pwd)"

  run bash -c "grep -rnE 'git fetch [^\|]* 2>/dev/null \|\| true' \"$PROJECT_ROOT/lib/\" | grep -v '\.sh:#' || true"

  # The only acceptable match is a comment (not executable code)
  if [ -n "$output" ]; then
    # Filter out comment lines (lines where the matched code is inside a comment)
    while IFS= read -r line; do
      # Strip the filename:lineno: prefix and check if the rest starts with #
      code_part="${line#*:*:}"
      trimmed="${code_part#"${code_part%%[! ]*}"}"  # ltrim
      if [[ "$trimmed" == \#* ]]; then
        # It's a comment — acceptable
        continue
      fi
      fail "Bare 'git fetch ... 2>/dev/null || true' found in executable code: $line"
    done <<< "$output"
  fi
}

@test "all callers that read a fetched ref use git_fetch_safe" {
  # Verify the specific files that were buggy now use git_fetch_safe
  PROJECT_ROOT="${RITE_REPO_ROOT}"

  for f in \
    "lib/core/claude-workflow.sh" \
    "lib/core/merge-pr.sh" \
    "lib/core/undo-workflow.sh"; do

    # Should have at least one git_fetch_safe call
    count=$(grep -c "git_fetch_safe" "$PROJECT_ROOT/$f" || true)
    if [ "$count" -eq 0 ]; then
      fail "$f: expected at least one git_fetch_safe call, found 0"
    fi
  done
}
