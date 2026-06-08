#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/utils/stale-branch.sh
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

@test "codebase has no bare 'git fetch ... 2>/dev/null || <non-fatal>' patterns" {
  # Regression guard — ensures no one re-introduces the silent-fetch bug in any spelling.
  #
  # Caught variants:
  #   git fetch origin main 2>/dev/null || true
  #   git fetch origin main 2>/dev/null || print_warning "..."
  #   git fetch origin main 2>/dev/null || print_info "..."
  #   git fetch origin main 2>/dev/null || :
  #   git fetch origin main 2>/dev/null || echo "..."
  #
  # Allowlisted (must NOT be flagged):
  #   Lines whose || block contains "exit 1" — these are fail-loud callers
  #   fetch origin main:main — best-effort local-main fast-forward, not used for branching
  #   Comment lines (line content starts with #)
  PROJECT_ROOT="$(cd "${RITE_REPO_ROOT}" && pwd)"

  # Match: git fetch ... 2>/dev/null || <anything that isn't an exit-1 block>
  # We capture all `git fetch` lines that suppress stderr and continue non-fatally.
  run bash -c "grep -rnE 'git fetch [^|]* 2>/dev/null \|\|' \"$PROJECT_ROOT/lib/\" || true"

  if [ -n "$output" ]; then
    while IFS= read -r line; do
      # Skip comment lines (code part starts with #)
      code_part="${line#*:*:}"
      trimmed="${code_part#"${code_part%%[! ]*}"}"  # ltrim
      if [[ "$trimmed" == \#* ]]; then
        continue
      fi

      # Allowlist: fail-loud callers — the || block exits with exit 1
      # These are acceptable: they suppress noisy stderr but surface failure via exit code.
      # IMPORTANT: both alternatives must be anchored immediately after || so that "exit 1"
      # appearing inside a warning message string does not accidentally allowlist the line.
      # \|\|[[:space:]]* matches the || and optional spaces; then either:
      #   \{[[:space:]]*$  — a block-open { ending the line (multi-line exit block)
      #   exit[[:space:]]+1 — a direct exit 1 immediately after ||
      if [[ "$line" =~ \|\|[[:space:]]*(\{[[:space:]]*$|exit[[:space:]]+1) ]]; then
        continue
      fi

      # Allowlist: fetch origin main:main — best-effort local-main fast-forward
      # This uses a different redirect style (>/dev/null 2>&1) but allowlist defensively.
      if [[ "$line" =~ "fetch origin main:main" ]]; then
        continue
      fi

      fail "Bare 'git fetch ... 2>/dev/null || <non-fatal>' found in executable code: $line"
    done <<< "$output"
  fi
}

@test "allowlist regex does NOT skip lines where 'exit 1' appears only in message text" {
  # Negative test: a line whose || block is a print_warning containing "exit 1" in the
  # message string must still be FLAGGED — the allowlist must not match it.
  #
  # Before the fix, `exit[[:space:]]+1` was a top-level alternation that matched anywhere
  # on the line, so the line below would have been silently skipped.
  local bad_line='lib/core/foo.sh:42:  git fetch origin main 2>/dev/null || print_warning "fetch failed, caller will exit 1 later"'

  # Run the same allowlist check logic the regression guard uses
  local matched=false

  # Skip comment lines check (not a comment)
  local code_part="${bad_line#*:*:}"
  local trimmed="${code_part#"${code_part%%[! ]*}"}"
  if [[ "$trimmed" == \#* ]]; then
    matched=true  # would be skipped as comment — unexpected for this input
  fi

  # Allowlist check: exit 1 anchored immediately after || (no wildcard before it)
  if [[ "$bad_line" =~ \|\|[[:space:]]*(\{[[:space:]]*$|exit[[:space:]]+1) ]]; then
    matched=true
  fi

  # fetch origin main:main check (not applicable here)
  if [[ "$bad_line" =~ "fetch origin main:main" ]]; then
    matched=true
  fi

  # The line must NOT be allowlisted — it is a bare non-fatal continuation
  if [ "$matched" = true ]; then
    fail "Allowlist incorrectly skipped a line where 'exit 1' appears only inside a message string: $bad_line"
  fi
}

@test "all callers that read a fetched ref use git_fetch_safe" {
  # Verify the specific files that were buggy now use git_fetch_safe
  PROJECT_ROOT="${RITE_REPO_ROOT}"

  for f in \
    "lib/core/claude-workflow.sh" \
    "lib/core/merge-pr.sh" \
    "lib/core/undo-workflow.sh" \
    "lib/utils/divergence-handler.sh"; do

    # Should have at least one git_fetch_safe call
    count=$(grep -c "git_fetch_safe" "$PROJECT_ROOT/$f" || true)
    if [ "$count" -eq 0 ]; then
      fail "$f: expected at least one git_fetch_safe call, found 0"
    fi
  done
}
