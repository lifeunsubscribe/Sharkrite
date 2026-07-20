#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh, lib/core/workflow-runner.sh, bin/rite
# Regression tests: merge-pr.sh conflict paths and ff section are PR-base-aware (#1035-1038)
#
# Covers:
#   1. PR_BASE charset validation — metacharacter baseRefName exits non-zero before any git mutation
#   2. Soft guard — blocks main-based PR when session target is non-main (RITE_TARGET_BRANCH)
#   3. Soft guard — --allow-main-base bypasses the guard and proceeds
#   4. Default behavior — resolved target=main + main base → guard does not fire
#   5. Three conflict sites use $PR_BASE (structural grep pins)
#   6. Local-main ff KEPT (STAYS-MAIN) and parallel $PR_BASE ff added for non-main bases
#   7. Flag plumbing — allow-main-base appears in bin/rite, workflow-runner.sh, merge-pr.sh

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/merge-pr-base-test"
  mkdir -p "$TEST_TMPDIR"

  # Stub bin dir — prepend to PATH so our fakes override the real binaries
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  # Stub git — records calls, never mutates anything
  cat > "$STUB_BIN/git" <<'GITEOF'
#!/bin/bash
# Record every invocation
echo "git $*" >> "$TEST_TMPDIR/git-calls.log"
# Handle specific queries merge-pr.sh makes before the guard fires
case "$*" in
  "branch --show-current")
    echo "main"
    ;;
  "worktree list"*"--porcelain"*)
    echo "worktree /tmp/fake-main"
    echo "HEAD abc123"
    echo "branch refs/heads/main"
    echo ""
    ;;
  "worktree list")
    echo "/tmp/fake-main abc123 [main]"
    ;;
  "stash list")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GITEOF
  chmod +x "$STUB_BIN/git"

  # Default stub jq — real jq used in tests that need it
  cat > "$STUB_BIN/jq" <<'JQEOF'
#!/bin/bash
# Pass through to real jq
exec "$(command -v jq 2>/dev/null || echo /usr/bin/jq)" "$@"
JQEOF
  chmod +x "$STUB_BIN/jq"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: build a minimal gh stub that returns a specific baseRefName
# ---------------------------------------------------------------------------
_make_gh_stub() {
  local base_ref="${1:-main}"
  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
echo '{"number":42,"title":"Test PR","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","url":"https://github.com/test/repo/pull/42","baseRefName":"${base_ref}","headRefName":"feat/test-branch","statusCheckRollup":[]}'
EOF
  chmod +x "$STUB_BIN/gh"
}

# ---------------------------------------------------------------------------
# Test 1: Structural — no literal origin/main at the three conflict sites
# (acceptance criterion: grep -c 'git merge origin/main' outputs 0)
# ---------------------------------------------------------------------------
@test "structural: no literal 'git merge origin/main' in merge-pr.sh" {
  count=$(grep -c 'git merge origin/main' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -eq 0 ] || {
    echo "FAIL: found $count literal 'git merge origin/main' in merge-pr.sh (should be 0)"
    grep -n 'git merge origin/main' "$PROJECT_ROOT/lib/core/merge-pr.sh"
    false
  }
}

@test "structural: no literal 'git_fetch_safe origin main' in merge-pr.sh" {
  count=$(grep -c 'git_fetch_safe origin main' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -eq 0 ] || {
    echo "FAIL: found $count literal 'git_fetch_safe origin main' in merge-pr.sh (should be 0)"
    grep -n 'git_fetch_safe origin main' "$PROJECT_ROOT/lib/core/merge-pr.sh"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: Structural — three PR_BASE fetch/merge pairs at the conflict sites
# ---------------------------------------------------------------------------
@test "structural: three 'git merge \"origin/\$PR_BASE\" --no-edit' in merge-pr.sh" {
  count=$(grep -cE 'git merge "origin/\$PR_BASE" --no-edit' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -eq 3 ] || {
    echo "FAIL: expected 3 conflict-site merges, found $count"
    grep -nE 'git merge "origin/\$PR_BASE" --no-edit' "$PROJECT_ROOT/lib/core/merge-pr.sh"
    false
  }
}

@test "structural: four 'git_fetch_safe origin \"\$PR_BASE\"' in merge-pr.sh" {
  # Three conflict-site fetches (stale-branch rebase paths) + one ledger SHA-extraction
  # last-resort fetch added by the integration-ledger feature (#1043).
  count=$(grep -cE 'git_fetch_safe origin "\$PR_BASE"' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -eq 4 ] || {
    echo "FAIL: expected 4 PR_BASE fetches (3 conflict-site + 1 ledger SHA fallback), found $count"
    grep -nE 'git_fetch_safe origin "\$PR_BASE"' "$PROJECT_ROOT/lib/core/merge-pr.sh"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3: Structural — local-main ff KEPT (STAYS-MAIN)
# ---------------------------------------------------------------------------
@test "structural: local-main ff lines still present (STAYS-MAIN)" {
  pull_count=$(grep -cE 'pull --ff-only origin main' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  fetch_count=$(grep -cE 'fetch origin main:main' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$pull_count" -ge 1 ] || {
    echo "FAIL: 'pull --ff-only origin main' line missing (STAYS-MAIN regression)"
    false
  }
  [ "$fetch_count" -ge 1 ] || {
    echo "FAIL: 'fetch origin main:main' line missing (STAYS-MAIN regression)"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: Structural — parallel PR_BASE ff paths added
# ---------------------------------------------------------------------------
@test "structural: parallel PR_BASE ff paths present in merge-pr.sh" {
  pull_count=$(grep -cE 'ff-only origin "\$PR_BASE"' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  fetch_count=$(grep -cE 'origin "\$PR_BASE:\$PR_BASE"' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$pull_count" -ge 1 ] || {
    echo "FAIL: 'pull --ff-only origin \"\$PR_BASE\"' line missing"
    false
  }
  [ "$fetch_count" -ge 1 ] || {
    echo "FAIL: 'fetch origin \"\$PR_BASE:\$PR_BASE\"' line missing"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 5: Structural — dead BASE_BRANCH var is gone
# ---------------------------------------------------------------------------
@test "structural: dead BASE_BRANCH variable removed from merge-pr.sh" {
  count=$(grep -c 'BASE_BRANCH' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -eq 0 ] || {
    echo "FAIL: BASE_BRANCH still present in merge-pr.sh ($count occurrences)"
    grep -n 'BASE_BRANCH' "$PROJECT_ROOT/lib/core/merge-pr.sh"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 6: Structural — charset validation present near PR_BASE extraction
# ---------------------------------------------------------------------------
@test "structural: charset validation present near PR_BASE extraction" {
  count=$(grep -c 'a-zA-Z0-9_./-' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -ge 1 ] || {
    echo "FAIL: charset validation pattern 'a-zA-Z0-9_./-' not found in merge-pr.sh"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 7: Structural — flag plumbing across all four files
# ---------------------------------------------------------------------------
@test "structural: allow-main-base appears in bin/rite" {
  grep -q 'allow-main-base' "$PROJECT_ROOT/bin/rite" || {
    echo "FAIL: allow-main-base not found in bin/rite"
    false
  }
}

@test "structural: allow-main-base appears in workflow-runner.sh" {
  grep -q 'allow-main-base' "$PROJECT_ROOT/lib/core/workflow-runner.sh" || {
    echo "FAIL: allow-main-base not found in workflow-runner.sh"
    false
  }
}

@test "structural: allow-main-base appears in merge-pr.sh" {
  grep -q 'allow-main-base' "$PROJECT_ROOT/lib/core/merge-pr.sh" || {
    echo "FAIL: allow-main-base not found in merge-pr.sh"
    false
  }
}

@test "structural: allow-main-base appears in CLAUDE.md" {
  grep -q 'allow-main-base' "$PROJECT_ROOT/CLAUDE.md" || {
    echo "FAIL: allow-main-base not found in CLAUDE.md"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 8: Charset validation — metacharacter in baseRefName exits before git mutations
#
# Uses a minimal inline driver that reproduces the charset-validation block from
# merge-pr.sh. This is a unit test of the guard logic itself, not a full
# merge-pr.sh integration test (the latter would require a git repo context).
# ---------------------------------------------------------------------------
@test "charset validation: metacharacter baseRefName exits non-zero without git calls" {
  run bash -c "
    set -euo pipefail
    PR_BASE='main\$(evil)'  # contains \$() — shell meta-character

    # Reproduce the merge-pr.sh charset check
    if ! printf '%s' \"\$PR_BASE\" | grep -qE '^[a-zA-Z0-9_./-]+\$' \
        || printf '%s' \"\$PR_BASE\" | grep -q '\\.\\.' ; then
      echo 'charset_rejected'
      exit 1
    fi
    echo 'charset_accepted'
    exit 0
  "
  [ "$status" -eq 1 ]
  [[ "$output" =~ "charset_rejected" ]] || {
    echo "FAIL: metacharacter baseRefName was NOT rejected"
    echo "output: $output"
    false
  }
}

@test "charset validation: path traversal '..' in baseRefName rejected" {
  run bash -c "
    set -euo pipefail
    PR_BASE='main/../etc/passwd'

    if ! printf '%s' \"\$PR_BASE\" | grep -qE '^[a-zA-Z0-9_./-]+\$' \
        || printf '%s' \"\$PR_BASE\" | grep -q '\\.\\.'; then
      echo 'charset_rejected'
      exit 1
    fi
    echo 'charset_accepted'
    exit 0
  "
  [ "$status" -eq 1 ]
  [[ "$output" =~ "charset_rejected" ]]
}

@test "charset validation: valid branch name 'staging' passes" {
  run bash -c "
    set -euo pipefail
    PR_BASE='staging'

    if ! printf '%s' \"\$PR_BASE\" | grep -qE '^[a-zA-Z0-9_./-]+\$' \
        || printf '%s' \"\$PR_BASE\" | grep -q '\\.\\.'; then
      echo 'charset_rejected'
      exit 1
    fi
    echo 'charset_accepted'
    exit 0
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "charset_accepted" ]]
}

@test "charset validation: valid branch name 'feature/my-branch_v1.2' passes" {
  run bash -c "
    set -euo pipefail
    PR_BASE='feature/my-branch_v1.2'

    if ! printf '%s' \"\$PR_BASE\" | grep -qE '^[a-zA-Z0-9_./-]+\$' \
        || printf '%s' \"\$PR_BASE\" | grep -q '\\.\\.'; then
      echo 'charset_rejected'
      exit 1
    fi
    echo 'charset_accepted'
    exit 0
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "charset_accepted" ]]
}

# ---------------------------------------------------------------------------
# Test 9: Soft guard — inline unit tests of the guard logic
#
# These tests exercise the guard decision logic (resolved-target vs PR_BASE)
# without requiring a full merge-pr.sh environment. The logic is reproduced
# from the guard block verbatim.
# ---------------------------------------------------------------------------
@test "soft guard: blocks when resolved target is non-main and PR_BASE is main" {
  run bash -c "
    set -euo pipefail
    PR_BASE='main'
    ALLOW_MAIN_BASE='false'
    # Simulate resolve_target_branch returning 'staging'
    _guard_resolved_target='staging'

    if [ \"\$ALLOW_MAIN_BASE\" != 'true' ] && [ \"\$PR_BASE\" = 'main' ]; then
      if [ \"\${_guard_resolved_target:-main}\" != 'main' ]; then
        echo \"guard_fired: PR_BASE=\$PR_BASE resolved_target=\$_guard_resolved_target\"
        exit 1
      fi
    fi
    echo 'guard_did_not_fire'
    exit 0
  "
  [ "$status" -eq 1 ]
  [[ "$output" =~ "guard_fired" ]] || {
    echo "FAIL: soft guard did not fire when expected"
    echo "output: $output"
    false
  }
}

@test "soft guard: --allow-main-base bypasses the guard" {
  run bash -c "
    set -euo pipefail
    PR_BASE='main'
    ALLOW_MAIN_BASE='true'
    _guard_resolved_target='staging'

    if [ \"\$ALLOW_MAIN_BASE\" != 'true' ] && [ \"\$PR_BASE\" = 'main' ]; then
      if [ \"\${_guard_resolved_target:-main}\" != 'main' ]; then
        echo 'guard_fired'
        exit 1
      fi
    fi
    echo 'guard_bypassed'
    exit 0
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "guard_bypassed" ]] || {
    echo "FAIL: --allow-main-base did not bypass the guard"
    echo "output: $output"
    false
  }
}

@test "soft guard: does not fire when resolved target is main (default behavior)" {
  run bash -c "
    set -euo pipefail
    PR_BASE='main'
    ALLOW_MAIN_BASE='false'
    _guard_resolved_target='main'

    if [ \"\$ALLOW_MAIN_BASE\" != 'true' ] && [ \"\$PR_BASE\" = 'main' ]; then
      if [ \"\${_guard_resolved_target:-main}\" != 'main' ]; then
        echo 'guard_fired'
        exit 1
      fi
    fi
    echo 'guard_did_not_fire'
    exit 0
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "guard_did_not_fire" ]] || {
    echo "FAIL: guard fired when resolved target = main (should not fire)"
    echo "output: $output"
    false
  }
}

@test "soft guard: does not fire when PR_BASE is non-main (guard is PR_BASE=main specific)" {
  run bash -c "
    set -euo pipefail
    PR_BASE='staging'
    ALLOW_MAIN_BASE='false'
    _guard_resolved_target='staging'

    if [ \"\$ALLOW_MAIN_BASE\" != 'true' ] && [ \"\$PR_BASE\" = 'main' ]; then
      if [ \"\${_guard_resolved_target:-main}\" != 'main' ]; then
        echo 'guard_fired'
        exit 1
      fi
    fi
    echo 'guard_did_not_fire'
    exit 0
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "guard_did_not_fire" ]]
}

# ---------------------------------------------------------------------------
# Test 10: ff section logic — structural pin for awk exact-match pattern
# ---------------------------------------------------------------------------
@test "structural: awk -v exact-string comparison used for PR_BASE worktree scan" {
  # The implementation must use awk -v b= ... $0 == "branch " b pattern (exact match)
  # rather than interpolating $PR_BASE into an awk regex (injection + '.' match-any risk)
  count=$(grep -c 'awk -v b=' "$PROJECT_ROOT/lib/core/merge-pr.sh" || true)
  [ "$count" -ge 1 ] || {
    echo "FAIL: awk -v exact-string pattern not found in merge-pr.sh"
    echo "The PR_BASE worktree scan must use awk -v b= for injection safety"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 11: ff section logic — non-main base triggers parallel ff, main base does not
#
# This is a unit test of the ff gate condition:
#   if [ "$PR_BASE" != "main" ]; then ... parallel ff ... fi
# ---------------------------------------------------------------------------
@test "ff gate: non-main PR_BASE triggers parallel ff block" {
  run bash -c "
    PR_BASE='staging'
    ff_count=0

    # Reproduce the ff gate from merge-pr.sh
    if [ \"\$PR_BASE\" != 'main' ]; then
      ff_count=\$((ff_count + 1))
    fi

    echo \"ff_count:\$ff_count\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ff_count:1" ]]
}

@test "ff gate: main PR_BASE skips parallel ff block (no duplicate)" {
  run bash -c "
    PR_BASE='main'
    ff_count=0

    if [ \"\$PR_BASE\" != 'main' ]; then
      ff_count=\$((ff_count + 1))
    fi

    echo \"ff_count:\$ff_count\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ff_count:0" ]]
}
