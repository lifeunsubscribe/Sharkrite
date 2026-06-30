#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Issue #804: Regenerate package-lock.json when package.json is staged.
#
# When a dev session edits package.json, the workflow's commit step must
# regenerate and stage package-lock.json so that npm ci (CI + the #784 node
# bootstrap) never EUSAGE-fails on lockfile drift.
#
# Test strategy:
#   - Create a minimal git repo with a package.json and a stale/absent lockfile.
#   - Stage a package.json change.
#   - Stub `npm` on PATH so each test controls the install outcome.
#   - Source regenerate_package_lockfiles from claude-workflow.sh via
#     RITE_SOURCE_FUNCTIONS_ONLY=1 and call it in the fixture git repo.
#
# Cases:
#   (a) package.json staged + npm succeeds → lockfile staged.
#   (b) no package.json staged → npm never called (no churn).
#   (c) npm fails → function exits non-zero (loud failure, no silent commit).
#   (d) monorepo: package.json in api/ → api/package-lock.json staged.
#   (e) npm not on PATH → warning, no error exit (graceful degradation).

# ---------------------------------------------------------------------------
# Setup: per-test fixture git repo + stub directory
# ---------------------------------------------------------------------------
setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"

  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"; export STUB_DIR

  # Marker file that the npm stub touches when it runs.
  NPM_INVOKED_MARKER="$TEST_REPO/npm-was-invoked"; export NPM_INVOKED_MARKER

  # Minimal git repo: one commit so git diff --cached works.
  (cd "$TEST_REPO" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && printf '{"name":"app","version":"1.0.0"}\n' > package.json \
    && printf '{"lockfileVersion":3,"requires":true,"packages":{}}\n' > package-lock.json \
    && git add -A \
    && git commit -qm "base") >/dev/null 2>&1
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write an npm stub. $1 = exit code the stub should produce for any subcommand.
# The stub touches NPM_INVOKED_MARKER whenever it runs, and writes a
# package-lock.json in cwd when subcommand is `install` and exit=0.
_write_npm_stub() {
  local _exit="${1:-0}"
  cat > "$STUB_DIR/npm" <<STUB
#!/bin/bash
touch "$NPM_INVOKED_MARKER"
case "\$1" in
  install)
    if [ "$_exit" -eq 0 ]; then
      # Simulate lockfile regeneration: write/update package-lock.json in cwd.
      printf '{"lockfileVersion":3,"requires":true,"packages":{"regenerated":true}}\n' > package-lock.json
    fi
    exit $_exit
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/npm"
}

# Run regenerate_package_lockfiles in a subshell inside TEST_REPO, with
# STUB_DIR prepended to PATH. Captures stdout+stderr. Sets $status.
_run_regen() {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export ISSUE_NUMBER='804'
    # Stub print_* helpers so output is predictable without the full lib stack.
    print_status()  { echo \"[STATUS] \$*\";  }
    print_success() { echo \"[OK] \$*\";      }
    print_warning() { echo \"[WARN] \$*\";    }
    print_error()   { echo \"[ERR] \$*\";     }
    export -f print_status print_success print_warning print_error
    source '$RITE_LIB_DIR/core/claude-workflow.sh'
    cd '$TEST_REPO'
    PATH='$STUB_DIR:\$PATH' regenerate_package_lockfiles
  " </dev/null
}

# ---------------------------------------------------------------------------
# (a) package.json staged + npm succeeds → lockfile regenerated and staged
# ---------------------------------------------------------------------------
@test "(a) staged package.json: npm runs and lockfile is re-staged" {
  _write_npm_stub 0

  # Stage a package.json change.
  (cd "$TEST_REPO" \
    && printf '{"name":"app","version":"1.0.1"}\n' > package.json \
    && git add package.json) >/dev/null 2>&1

  _run_regen

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $status"
    echo "--- output ---"; printf '%s\n' "${lines[@]}"
    false
  }

  # npm must have been invoked.
  [ -f "$NPM_INVOKED_MARKER" ] || {
    echo "FAIL: npm stub was not called — lockfile regeneration skipped"
    false
  }

  # The regenerated lockfile must be staged.
  _staged=$(cd "$TEST_REPO" && git diff --cached --name-only 2>/dev/null || true)
  echo "$_staged" | grep -q 'package-lock.json' || {
    echo "FAIL: package-lock.json not staged after regeneration"
    echo "Staged files: $_staged"
    false
  }

  # Output should mention success.
  printf '%s\n' "${lines[@]}" | grep -qi 'staged\|regenerat' || {
    echo "FAIL: expected success message in output"
    printf '%s\n' "${lines[@]}"
    false
  }
}

# ---------------------------------------------------------------------------
# (b) no package.json staged → npm never called, no lockfile churn
# ---------------------------------------------------------------------------
@test "(b) no staged package.json: npm not invoked, no lockfile churn" {
  _write_npm_stub 0

  # Stage only a non-package.json file.
  (cd "$TEST_REPO" \
    && printf 'console.log("hi");\n' > index.js \
    && git add index.js) >/dev/null 2>&1

  _run_regen

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $status"
    printf '%s\n' "${lines[@]}"
    false
  }

  # npm must NOT have been invoked.
  [ ! -f "$NPM_INVOKED_MARKER" ] || {
    echo "FAIL: npm was invoked despite no staged package.json (spurious churn)"
    false
  }
}

# ---------------------------------------------------------------------------
# (c) npm install fails → function exits non-zero (loud, no silent stale lock)
# ---------------------------------------------------------------------------
@test "(c) npm install fails → non-zero exit (no silent stale lockfile commit)" {
  _write_npm_stub 1

  (cd "$TEST_REPO" \
    && printf '{"name":"app","version":"2.0.0","dependencies":{"bad":"99.9.9"}}\n' > package.json \
    && git add package.json) >/dev/null 2>&1

  _run_regen

  [ "$status" -ne 0 ] || {
    echo "FAIL: expected non-zero exit when npm fails, got 0 — stale lock silently committed"
    false
  }

  # Output must mention the failure clearly.
  printf '%s\n' "${lines[@]}" | grep -qi 'fail\|error\|exit' || {
    echo "FAIL: expected error message in output on npm failure"
    printf '%s\n' "${lines[@]}"
    false
  }

  # No-stale-stage contract (AC #4): package-lock.json must NOT be staged after
  # a failed npm run — the caller must not be able to silently commit a stale lock.
  _staged=$(cd "$TEST_REPO" && git diff --cached --name-only 2>/dev/null || true)
  if echo "$_staged" | grep -q 'package-lock.json'; then
    echo "FAIL: package-lock.json was staged despite npm failure — stale lock would be committed"
    echo "Staged files: $_staged"
    false
  fi
}

# ---------------------------------------------------------------------------
# (d) monorepo: package.json in api/ → api/package-lock.json staged
# ---------------------------------------------------------------------------
@test "(d) monorepo: api/package.json staged → api/package-lock.json staged" {
  _write_npm_stub 0

  # Set up api/ subdirectory with its own package.json.
  (cd "$TEST_REPO" \
    && mkdir -p api \
    && printf '{"name":"api","version":"1.0.0"}\n' > api/package.json \
    && git add api/package.json \
    && git commit -qm "add api pkg") >/dev/null 2>&1

  # Stage a change to api/package.json (not the root one).
  (cd "$TEST_REPO" \
    && printf '{"name":"api","version":"1.1.0"}\n' > api/package.json \
    && git add api/package.json) >/dev/null 2>&1

  _run_regen

  [ "$status" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $status"
    printf '%s\n' "${lines[@]}"
    false
  }

  # npm must have been invoked (in api/).
  [ -f "$NPM_INVOKED_MARKER" ] || {
    echo "FAIL: npm stub not called for api/package.json"
    false
  }

  # api/package-lock.json must be staged.
  _staged=$(cd "$TEST_REPO" && git diff --cached --name-only 2>/dev/null || true)
  echo "$_staged" | grep -q 'api/package-lock.json' || {
    echo "FAIL: api/package-lock.json not staged after monorepo regeneration"
    echo "Staged files: $_staged"
    false
  }
}

# ---------------------------------------------------------------------------
# (e) npm not on PATH → warning printed, function exits 0 (graceful degradation)
# ---------------------------------------------------------------------------
@test "(e) npm missing from PATH → warning, exits 0 (graceful degradation)" {
  # Do NOT write an npm stub — git must remain on PATH but npm must be absent.
  # Using PATH='/nonexistent' removes git too, causing an early-return at the
  # no-staged-package.json branch before the npm-missing check is reached.
  # Instead, create a stub dir that forwards git (via a wrapper) but has no npm,
  # so the function sees staged package.json files but finds no npm binary.
  local _git_stub_dir
  _git_stub_dir="$(mktemp -d)"
  # Symlink the real git into the stub dir; npm is intentionally absent.
  ln -sf "$(command -v git)" "$_git_stub_dir/git"

  (cd "$TEST_REPO" \
    && printf '{"name":"app","version":"3.0.0"}\n' > package.json \
    && git add package.json) >/dev/null 2>&1

  # Run with a PATH that has git but no npm.
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export ISSUE_NUMBER='804'
    print_status()  { echo \"[STATUS] \$*\";  }
    print_success() { echo \"[OK] \$*\";      }
    print_warning() { echo \"[WARN] \$*\";    }
    print_error()   { echo \"[ERR] \$*\";     }
    export -f print_status print_success print_warning print_error
    source '$RITE_LIB_DIR/core/claude-workflow.sh'
    cd '$TEST_REPO'
    PATH='$_git_stub_dir' regenerate_package_lockfiles
  " </dev/null
  rm -rf "$_git_stub_dir"

  [ "$status" -eq 0 ] || {
    echo "FAIL: missing npm should warn but not fail (exit 0), got $status"
    printf '%s\n' "${lines[@]}"
    false
  }

  # Must emit a warning mentioning npm.
  printf '%s\n' "${lines[@]}" | grep -qi 'warn\|not found\|npm' || {
    echo "FAIL: expected warning message when npm is missing"
    printf '%s\n' "${lines[@]}"
    false
  }
}
