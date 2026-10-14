#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/promote-branch.sh
# tests/regression/promote-review-followup.bats
#
# Regression tests for non-CRITICAL promotion review follow-up issue creation (#1209).
#
# Tests verify:
#   1. Findings-line parse path: HIGH+MEDIUM review creates one follow-up issue
#      with the correct labels and a title referencing the branch.
#   2. JSON-block parse path: HIGH+MEDIUM review (via sharkrite-review-data JSON
#      block) also creates a follow-up issue.
#   3. Zero non-CRITICAL findings → no follow-up issue is created.
#   4. gh issue create failure is best-effort: the merge still completes (exit 0).
#   5. Structural: promote-branch.sh never invokes a fix-mode session.

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Minimal lib stubs: same shape as promote-branch.bats but with
# RITE_MARKER_REVIEW_DATA defined (required by the non-CRITICAL block).
# ---------------------------------------------------------------------------
_write_followup_stubs() {
  local _lib="$1"
  mkdir -p "$_lib/utils" "$_lib/core" "$_lib/providers"

  cat > "$_lib/utils/config.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f _pf_config_stub >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_pf_config_stub() { true; }
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT:-$(pwd)}"
RITE_LIB_DIR="${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/.."}"
RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-fake-project}"
RITE_INSTALL_DIR="${RITE_INSTALL_DIR:-$(dirname "${BASH_SOURCE[0]}")/../..}"
RITE_STATE_DIR="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
RITE_WORKTREE_DIR="${RITE_WORKTREE_DIR:-/tmp/test-worktrees}"
export RITE_DATA_DIR RITE_PROJECT_ROOT RITE_LIB_DIR RITE_PROJECT_NAME
export RITE_INSTALL_DIR RITE_STATE_DIR RITE_WORKTREE_DIR
STUB

  cat > "$_lib/utils/colors.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f print_info >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
print_header()  { echo "=== $* ==="; }
print_info()    { echo "[INFO] $*"; }
print_step()    { echo "[STEP] $*"; }
print_success() { echo "[OK] $*"; }
print_warning() { echo "[WARN] $*" >&2; }
print_error()   { echo "[ERROR] $*" >&2; }
STUB

  cat > "$_lib/utils/logging.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f _diag >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
_diag()           { true; }
verbose_header()  { true; }
verbose_info()    { true; }
verbose_step()    { true; }
verbose_success() { true; }
verbose_warning() { true; }
STUB

  cat > "$_lib/utils/gh-retry.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f gh_safe >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
gh_safe() { true; }
STUB

  cat > "$_lib/utils/git-helpers.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f git_fetch_safe >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
git_fetch_safe() { return 0; }
rmdir_empty_worktree_container() { return 0; }
STUB

  cat > "$_lib/utils/blocker-rules.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f detect_critical_issues >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
detect_critical_issues() { return 0; }
STUB

  cat > "$_lib/utils/integration-ledger.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f integration_ledger_append >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
integration_ledger_append()        { return 0; }
integration_ledger_entries()       { return 0; }
integration_ledger_mark_promoted() { return 0; }
STUB

  cat > "$_lib/providers/provider-interface.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f provider_resolve_model >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
provider_resolve_model()           { echo "claude-sonnet-4-6"; }
provider_run_prompt_with_timeout() { echo "stub"; return 0; }
STUB

  cat > "$_lib/utils/promotion-composer.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f compose_promotion_pr_body >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub promotion body"; return 0; }
STUB

  cat > "$_lib/core/local-review.sh" << 'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$_lib/core/local-review.sh"

  # markers.sh: defines RITE_MARKER_REVIEW_DATA needed by the non-CRITICAL block
  cat > "$_lib/utils/markers.sh" << 'STUB'
#!/bin/bash
set -euo pipefail
if declare -f rite_markers_loaded >/dev/null 2>&1; then return 0 2>/dev/null || true; fi
rite_markers_loaded() { return 0; }
RITE_MARKER_REVIEW="sharkrite-local-review"
RITE_MARKER_ASSESSMENT="sharkrite-assessment"
RITE_MARKER_FOLLOWUP="sharkrite-followup-issue"
RITE_MARKER_REVIEW_DATA="sharkrite-review-data"
export RITE_MARKER_REVIEW RITE_MARKER_ASSESSMENT RITE_MARKER_FOLLOWUP RITE_MARKER_REVIEW_DATA
STUB

  cat > "$_lib/core/merge-pr.sh" << 'STUB'
#!/bin/bash
_MERGE_PR_SH_SOURCED_IN_TEST=true
STUB
}

# ---------------------------------------------------------------------------
# Helper: write a small runner script, chmod it, echo its path
# ---------------------------------------------------------------------------
_write_followup_runner() {
  local _path="$RITE_TEST_TMPDIR/runner_$$.sh"
  cat > "$_path"
  chmod +x "$_path"
  echo "$_path"
}

# ---------------------------------------------------------------------------
# Helper: write a minimal fake-git binary for a full run_promote flow.
# Returns "0" for rev-list (not behind main), a SHA for rev-parse,
# and handles ls-remote and worktree add.
# ---------------------------------------------------------------------------
_write_fake_git() {
  local _bin_dir="$1"
  mkdir -p "$_bin_dir"
  cat > "$_bin_dir/git" << 'GITEOF'
#!/bin/bash
for _a in "$@"; do [ "$_a" = "rev-list" ] && { echo "0"; exit 0; }; done
case "${1:-}" in
  rev-parse) echo "abc1234500000000000000000000000000000000"; exit 0 ;;
  ls-remote) echo "abc refs/heads/test-branch"; exit 0 ;;
  worktree)  [ "${2:-}" = "add" ] && mkdir -p "${3:-}"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
GITEOF
  chmod +x "$_bin_dir/git"
}

setup()    { setup_test_tmpdir; }
teardown() { teardown_test_tmpdir; }

# ===========================================================================
# Group 1: Findings-line parse path → follow-up issue created
# ===========================================================================

@test "Findings-line: HIGH+MEDIUM review creates one follow-up issue with correct labels and title" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/issue_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-fl"
  _write_fake_git "$_fake_bin"

  # Review body with a Findings line (no JSON block) — all on one line so the
  # grep -E "CRITICAL:.*HIGH:.*MEDIUM:.*LOW:" pattern fires.
  local _review_file="$RITE_TEST_TMPDIR/fake_review_fl.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

## Code Review

Findings: CRITICAL: 0 | HIGH: 2 | MEDIUM: 1 | LOW: 0
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  # Follow-up issue was created
  [ -f "$_call_log" ]
  grep -q "ISSUE_CREATE" "$_call_log"
  # Must carry both required labels
  grep -q "from-review" "$_call_log"
  grep -q "needs-re-triage" "$_call_log"
  # Title must reference the promoted branch
  grep -q "test-branch" "$_call_log"
  # Exactly one issue create call
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
}

# ===========================================================================
# Group 1b: Emoji-Findings-line (production review format) → follow-up created
# ===========================================================================

@test "Emoji-Findings-line: production emoji format creates one follow-up issue" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/emoji_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-ef"
  _write_fake_git "$_fake_bin"

  # Production reviews emit emoji prefixes: 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | …
  local _review_file="$RITE_TEST_TMPDIR/fake_review_ef.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

## Code Review

Findings: 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | 🟡 MEDIUM: 1 | 🟢 LOW: 0
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  grep -q "ISSUE_CREATE" "$_call_log"
  grep -q "from-review" "$_call_log"
  grep -q "needs-re-triage" "$_call_log"
}

# ===========================================================================
# Group 1c: Corrupt JSON + valid Findings line → fallback creates follow-up
# ===========================================================================

@test "corrupt JSON + valid Findings line: priority-2 fallback creates one follow-up issue" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/fallback_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-fb"
  _write_fake_git "$_fake_bin"

  # Malformed JSON block (jq -e '.summary' fails) followed by a valid Findings line.
  local _review_file="$RITE_TEST_TMPDIR/fake_review_fb.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

<!-- sharkrite-review-data
{not valid json at all
-->

## Code Review

Findings: CRITICAL: 0 | HIGH: 3 | MEDIUM: 0 | LOW: 1
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  grep -q "ISSUE_CREATE" "$_call_log"
  grep -q "from-review" "$_call_log"
  grep -q "needs-re-triage" "$_call_log"
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
}

# ===========================================================================
# Group 1d: Marker-only review (no JSON, no Findings line) → follow-up created
# ===========================================================================

@test "marker-only: item-marker-only review creates one follow-up issue" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/marker_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-mk"
  _write_fake_git "$_fake_bin"

  # Review body with only item markers — no JSON block, no Findings line.
  local _review_file="$RITE_TEST_TMPDIR/fake_review_mk.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

## Code Review

<!-- item:1 severity:HIGH -->
Potential null dereference in foo.sh line 42.
<!-- item:2 severity:MEDIUM -->
Missing input validation in bar.sh.
<!-- item:3 severity:LOW -->
Unused variable in baz.sh.
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  # Follow-up issue must be created from marker-only review
  [ -f "$_call_log" ]
  grep -q "ISSUE_CREATE" "$_call_log"
  grep -q "from-review" "$_call_log"
  grep -q "needs-re-triage" "$_call_log"
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
}

# ===========================================================================
# Group 1e: Oversized review body (>55000 chars) → truncation pointer appears
# ===========================================================================

@test "oversized review: body >55000 chars includes truncation pointer" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/trunc_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-tr"
  _write_fake_git "$_fake_bin"

  # Build a review body that exceeds 55000 chars. Use a Findings line so
  # parsing succeeds, then pad with a large block.
  local _review_file="$RITE_TEST_TMPDIR/fake_review_tr.txt"
  {
    printf '<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->\n\n'
    printf 'Findings: CRITICAL: 0 | HIGH: 1 | MEDIUM: 0 | LOW: 0\n\n'
    printf '<!-- sharkrite-review-data\n'
    # Pad to exceed 55000 chars
    python3 -c "print('x' * 56000)"
    printf '\n-->\n'
  } > "$_review_file"

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
_issue_body_file="$RITE_TEST_TMPDIR/issue_body_$$.txt"
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          # Capture the --body argument value
          local _next_is_body=0
          for _arg in "\$@"; do
            if [ "\$_next_is_body" = "1" ]; then
              printf '%s' "\$_arg" > "\$_issue_body_file"
              _next_is_body=0
            fi
            [ "\$_arg" = "--body" ] && _next_is_body=1
          done
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
echo "BODY_FILE=\$_issue_body_file"
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  grep -q "ISSUE_CREATE" "$_call_log"
  # Truncation pointer must appear in the output
  echo "$output" | grep -q "review truncated"
}

# ===========================================================================
# Group 2: JSON-block parse path → follow-up issue created
# ===========================================================================

@test "JSON-block: HIGH+MEDIUM review creates one follow-up issue" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/json_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-jb"
  _write_fake_git "$_fake_bin"

  # Review body with sharkrite-review-data JSON block
  local _review_file="$RITE_TEST_TMPDIR/fake_review_jb.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

<!-- sharkrite-review-data
{"summary": {"critical": 0, "high": 1, "medium": 2, "low": 0}}
-->

## Code Review
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  grep -q "ISSUE_CREATE" "$_call_log"
}

# ===========================================================================
# Group 3: Zero non-CRITICAL findings → no issue created
# ===========================================================================

@test "zero non-CRITICAL findings: no follow-up issue is created" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _call_log="$RITE_TEST_TMPDIR/zero_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-zero"
  _write_fake_git "$_fake_bin"

  # Review with zero findings across all severities
  local _review_file="$RITE_TEST_TMPDIR/fake_review_zero.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

## Code Review

Findings: CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)  echo '{"merged":true}'; return 0 ;;
    issue)
      case "\${2:-}" in
        create)
          printf 'ISSUE_CREATE %s\n' "\$*" >> "$_call_log"
          echo "https://github.com/owner/repo/issues/99"
          return 0 ;;
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  [ "$status" -eq 0 ]
  # No follow-up issue should be created
  [ ! -f "$_call_log" ] || ! grep -q "ISSUE_CREATE" "$_call_log"
}

# ===========================================================================
# Group 4: gh issue create failure is best-effort — merge still completes
# ===========================================================================

@test "gh issue create failure does not block the merge" {
  local _lib="$RITE_TEST_TMPDIR/lib"
  _write_followup_stubs "$_lib"

  local _merge_log="$RITE_TEST_TMPDIR/merge_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-be"
  _write_fake_git "$_fake_bin"

  local _review_file="$RITE_TEST_TMPDIR/fake_review_be.txt"
  cat > "$_review_file" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

Findings: CRITICAL: 0 | HIGH: 1 | MEDIUM: 1 | LOW: 0
REVIEWEOF

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt"
export PATH="$_fake_bin:\$PATH"
source "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
set +u; set +o pipefail
git_fetch_safe()            { return 0; }
integration_ledger_entries() {
  printf 'issue=10\tpr=55\tsha=abc000\tmerged_at=2026-01-01T00:00:00Z\tpromoted=false\n'
}
integration_ledger_mark_promoted() { return 0; }
gather_promotion_context()  { return 0; }
compose_promotion_pr_body() { echo "stub body"; return 0; }
detect_critical_issues()    { return 0; }
run_test_gate()             { return 0; }
gh_safe() {
  case "\${1:-}" in
    pr)
      case "\${2:-}" in
        list)   echo ""; return 0 ;;
        create) echo "55"; return 0 ;;
        edit)   return 0 ;;
        view)
          if [ "\${4:-}" = "--json" ] && [ "\${5:-}" = "comments" ]; then
            cat "$_review_file"
          fi
          return 0 ;;
      esac ;;
    repo) echo 'owner/repo'; return 0 ;;
    api)
      echo "MERGE_CALLED" >> "$_merge_log"
      echo '{"merged":true}'
      return 0 ;;
    issue)
      case "\${2:-}" in
        create) return 1 ;;  # Simulate gh issue create failure
        comment) return 0 ;;
      esac ;;
  esac
  return 0
}
run_promote "test-branch" 2>&1
RUNEOF
)

  run bash "$_runner" 2>&1
  # Merge must still complete despite issue create failure
  [ "$status" -eq 0 ]
  [ -f "$_merge_log" ]
  grep -q "MERGE_CALLED" "$_merge_log"
}

# ===========================================================================
# Group 5: Structural — no fix-mode session in promote path
# ===========================================================================

@test "promote-branch.sh never invokes a fix-mode session" {
  # The promote path must never call into the dev/fix session machinery.
  # A fix loop would re-run the 20+ min full suite per iteration and violates
  # the "classify only, never fix" contract from issue #1209.
  ! grep -qE "claude_provider_run_agentic_session|run_fix_session|FIX_MODE|FIX_PROMPT" \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh"
}
