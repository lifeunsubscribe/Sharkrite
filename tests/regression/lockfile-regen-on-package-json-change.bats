#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Issue #804: regenerate package-lock.json when a dev session changes package.json.
#
# Tests for `regenerate_lockfiles_if_needed`, the post-commit helper that:
#   1. Detects changed package.json files (vs origin/main) and runs
#      `npm install --package-lock-only` in their directories.
#   2. Stages + commits the regenerated package-lock.json as a follow-on commit.
#   3. Skips silently when no package.json changed (no spurious lockfile churn).
#   4. Fails loud (non-zero return) when npm install errors — never commits a
#      stale/partial lockfile.
#   5. Handles monorepos: each changed package.json directory is processed
#      independently (root + sub-package).
#
# `npm` is stubbed on PATH so tests run deterministically without a real registry.
# The function is exercised by sourcing claude-workflow.sh with
# RITE_SOURCE_FUNCTIONS_ONLY=1 (loads helpers only, no top-level side effects).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR
  # Marker touched by the npm stub's ci/install subcommand to record invocations.
  BOOTSTRAP_MARKER="$TEST_REPO/npm-was-invoked"; export BOOTSTRAP_MARKER

  # Minimal git repo: an initial commit on origin/main, then a feature commit
  # so git diff origin/main...HEAD produces a non-empty changed-file list.
  (cd "$TEST_REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && printf '{"name":"app","version":"1.0.0","scripts":{"test":"jest"}}\n' > package.json \
    && printf '{"lockfileVersion":3}\n' > package-lock.json \
    && printf 'export const x = 1;\n' > index.js \
    && git add -A \
    && git commit -qm "base" \
    && git update-ref refs/remotes/origin/main HEAD) >/dev/null 2>&1

  # Source stub helpers from claude-workflow.sh (functions only; no side effects)
  # We need print_* helpers available so the function can log. Source config
  # and then the workflow file in function-only mode.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# ---------------------------------------------------------------------------
# Helper: write a stub `npm` binary that:
#   $1 = "success"  → touches BOOTSTRAP_MARKER and regenerates a lockfile stub
#   $1 = "fail"     → touches BOOTSTRAP_MARKER and exits non-zero
# ---------------------------------------------------------------------------
_write_npm_stub() {
  local _behaviour="${1:-success}"
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
case "\$1" in
  install)
    touch "$BOOTSTRAP_MARKER"
    if [ "$_behaviour" = "success" ]; then
      # Simulate regeneration: write a minimal lockfile into the CWD
      printf '{"lockfileVersion":3,"_updated":true}\n' > package-lock.json
      exit 0
    else
      echo "npm ERR! ERESOLVE unresolvable conflict" >&2
      exit 1
    fi
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$STUB_DIR/npm"
}

# ---------------------------------------------------------------------------
# Helper: run regenerate_lockfiles_if_needed in a subshell inside TEST_REPO
# with STUB_DIR ahead on PATH.
#
# Sourcing claude-workflow.sh with RITE_SOURCE_FUNCTIONS_ONLY=1 loads all
# function definitions (including regenerate_lockfiles_if_needed, print_*,
# and their transitive deps) without running the top-level executable body.
# ---------------------------------------------------------------------------
_run_regen() {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export ISSUE_NUMBER='804'
    export RITE_LOG_FILE='/dev/null'
    cd '$TEST_REPO'
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh' 2>/dev/null || true
    PATH='$STUB_DIR':\$PATH regenerate_lockfiles_if_needed
  " 2>&1
}

# ---------------------------------------------------------------------------
# Case (a): package.json changed vs origin/main, npm install succeeds →
# lockfile is regenerated and committed as a follow-on commit.
# ---------------------------------------------------------------------------
@test "(a) package.json changed → npm install runs, lockfile commit added" {
  _write_npm_stub "success"

  # Feature commit that modifies package.json (simulates a dep change)
  (cd "$TEST_REPO" \
    && printf '{"name":"app","version":"1.0.0","dependencies":{"lodash":"4.17.21"},"scripts":{"test":"jest"}}\n' > package.json \
    && git add package.json \
    && git commit -qm "feat: add lodash") >/dev/null 2>&1

  local _commits_before
  _commits_before=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)

  _run_regen
  [ "$status" -eq 0 ] || {
    echo "FAIL: regenerate_lockfiles_if_needed returned non-zero (exit $status)"
    echo "--- output ---"; echo "$output"
    false
  }

  # npm install must have run (the whole point of #804)
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: npm install was not invoked despite package.json change"
    false
  }

  # A new follow-on commit must have been added for the lockfile regen
  local _commits_after
  _commits_after=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$_commits_after" -gt "$_commits_before" ] || {
    echo "FAIL: expected a new lockfile-regen commit; commit count before=$_commits_before after=$_commits_after"
    false
  }

  # The follow-on commit message must mention package-lock.json
  local _last_msg
  _last_msg=$(git -C "$TEST_REPO" log -1 --format='%s' 2>/dev/null || true)
  echo "$_last_msg" | grep -qi "package-lock" || {
    echo "FAIL: lockfile regen commit message does not mention package-lock: '$_last_msg'"
    false
  }
}

# ---------------------------------------------------------------------------
# Case (b): NO package.json changed vs origin/main → npm install is NOT
# invoked (no spurious lockfile churn).
# ---------------------------------------------------------------------------
@test "(b) no package.json changed → npm install skipped (no lockfile churn)" {
  _write_npm_stub "success"

  # Feature commit that only changes a source file (no package.json touch)
  (cd "$TEST_REPO" \
    && printf 'export const x = 2;\n' > index.js \
    && git add index.js \
    && git commit -qm "refactor: update index.js") >/dev/null 2>&1

  local _commits_before
  _commits_before=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)

  _run_regen
  [ "$status" -eq 0 ] || {
    echo "FAIL: regenerate_lockfiles_if_needed returned non-zero when no package.json changed (exit $status)"
    echo "--- output ---"; echo "$output"
    false
  }

  # npm install must NOT have run
  [ ! -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: npm install was invoked despite no package.json change (spurious churn)"
    false
  }

  # No additional commit should have been created
  local _commits_after
  _commits_after=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$_commits_after" -eq "$_commits_before" ] || {
    echo "FAIL: unexpected lockfile-regen commit when no package.json changed"
    false
  }
}

# ---------------------------------------------------------------------------
# Case (c): npm install fails → function returns non-zero, no partial commit.
# ---------------------------------------------------------------------------
@test "(c) npm install fails → non-zero return, no stale lockfile committed" {
  _write_npm_stub "fail"

  # Feature commit that changes package.json
  (cd "$TEST_REPO" \
    && printf '{"name":"app","version":"1.0.0","dependencies":{"impossible":"999.0.0"},"scripts":{"test":"jest"}}\n' > package.json \
    && git add package.json \
    && git commit -qm "feat: add impossible dep") >/dev/null 2>&1

  local _commits_before
  _commits_before=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)

  _run_regen
  [ "$status" -ne 0 ] || {
    echo "FAIL: expected non-zero return when npm install fails, got status 0"
    false
  }

  # No additional commit should have been created (no partial lockfile committed)
  local _commits_after
  _commits_after=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$_commits_after" -eq "$_commits_before" ] || {
    echo "FAIL: a lockfile commit was created despite npm install failure (stale lockfile danger)"
    false
  }
}

# ---------------------------------------------------------------------------
# Case (d): monorepo — a sub-package's package.json changed → npm install
# runs in the sub-package directory (not just root), and lockfile committed.
# ---------------------------------------------------------------------------
@test "(d) monorepo sub-package package.json changed → npm install runs in sub-package dir" {
  _write_npm_stub "success"

  # Set up monorepo sub-package on the base commit
  (cd "$TEST_REPO" \
    && mkdir -p api \
    && printf '{"name":"api","version":"1.0.0","scripts":{"test":"jest"}}\n' > api/package.json \
    && printf '{"lockfileVersion":3}\n' > api/package-lock.json \
    && git add api/ \
    && git commit -qm "chore: add api sub-package") >/dev/null 2>&1
  # Advance origin/main to include sub-package setup
  git -C "$TEST_REPO" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1

  # Now make a change to the sub-package's package.json (simulates dep addition)
  (cd "$TEST_REPO" \
    && printf '{"name":"api","version":"1.0.0","dependencies":{"express":"4.18.0"},"scripts":{"test":"jest"}}\n' > api/package.json \
    && git add api/package.json \
    && git commit -qm "feat(api): add express") >/dev/null 2>&1

  local _commits_before
  _commits_before=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)

  _run_regen
  [ "$status" -eq 0 ] || {
    echo "FAIL: regenerate_lockfiles_if_needed returned non-zero for monorepo sub-package (exit $status)"
    echo "--- output ---"; echo "$output"
    false
  }

  # npm install must have been invoked (for the api/ sub-package)
  [ -f "$BOOTSTRAP_MARKER" ] || {
    echo "FAIL: npm install was not invoked for monorepo sub-package package.json change"
    false
  }

  # A follow-on commit for the lockfile must have been added
  local _commits_after
  _commits_after=$(git -C "$TEST_REPO" rev-list --count origin/main..HEAD 2>/dev/null)
  [ "$_commits_after" -gt "$_commits_before" ] || {
    echo "FAIL: expected lockfile-regen commit for monorepo sub-package; count before=$_commits_before after=$_commits_after"
    false
  }
}
