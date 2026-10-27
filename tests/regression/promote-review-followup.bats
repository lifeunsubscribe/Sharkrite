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
load_provider()                    { return 0; }
provider_detect_cli()              { return 0; }
provider_healthcheck()             { return 0; }
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

  # format-review.sh: redirect to the real file so parse_review_severity_counts
  # runs with actual logic (tests verify parse-driven issue creation).
  # The real file sources colors.sh and markers.sh from $RITE_LIB_DIR (= $_lib),
  # both of which are already stubbed above.
  cat > "$_lib/utils/format-review.sh" << FORMAT_STUB
#!/bin/bash
# shellcheck source=/dev/null
source "$RITE_REPO_ROOT/lib/utils/format-review.sh"
FORMAT_STUB
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

# ===========================================================================
# Group 6: Assessment pass at promote (#1278)
#
# Phase 5b runs assess-review-issues.sh on the promotion review so the
# NOW/LATER/DISMISSED judgment is applied before anything is filed, and so the
# assessor's cross-PR dedup search can match per-issue follow-ups already on
# file. These tests pin the three-way outcome:
#   assessed + NOW items  → one aggregated ACTIONABLE_NOW issue, fallback inert
#   assessed + none left  → nothing filed (DISMISSED items are dropped)
#   not assessed          → deterministic raw-review fallback, unchanged
#
# Every review body below carries a HIGH+MEDIUM Findings line, so the
# deterministic fallback WOULD fire if it were not correctly gated. That is
# what makes "no needs-re-triage issue" a meaningful assertion.
# ===========================================================================

# Writes a stub assessor into the fake lib's core/ dir.
#   $1 = lib dir, $2 = stdout to emit, $3 = exit code,
#   $4 = env-capture log path, $5 = per-item issue numbers to passback (space-sep)
_write_stub_assessor() {
  local _lib="$1" _out="$2" _code="$3" _envlog="$4" _later="${5:-}"
  mkdir -p "$_lib/core"
  cat > "$_lib/core/assess-review-issues.sh" << STUBEOF
#!/bin/bash
# Stub assessor: records its env contract, then emits a canned classification.
{
  echo "PR=\${1:-}"
  echo "REVIEW_FILE_EXISTS=\$( [ -f "\${2:-}" ] && echo yes || echo no )"
  echo "AUTO=\${3:-}"
  echo "RITE_ISSUE_NUMBER=[\${RITE_ISSUE_NUMBER-UNSET}]"
  echo "RITE_RETRY_COUNT=\${RITE_RETRY_COUNT-UNSET}"
  echo "RITE_REVIEW_JUST_POSTED=\${RITE_REVIEW_JUST_POSTED-UNSET}"
  echo "RITE_ASSESSMENT_TIMEOUT=\${RITE_ASSESSMENT_TIMEOUT-UNSET}"
  echo "PER_ITEM_FILE=\${RITE_PER_ITEM_ISSUES_FILE-UNSET}"
} >> "$_envlog"
for _n in ${_later}; do
  echo "\$_n" >> "\${RITE_PER_ITEM_ISSUES_FILE:-/dev/null}"
done
cat << 'OUTEOF'
${_out}
OUTEOF
exit ${_code}
STUBEOF
  chmod +x "$_lib/core/assess-review-issues.sh"
}

# Shared review body: HIGH+MEDIUM so the deterministic fallback would fire.
_write_noncrit_review() {
  cat > "$1" << 'REVIEWEOF'
<!-- sharkrite-local-review model:test timestamp:2026-01-01T00:00:00Z commit:abc -->

## Code Review

Findings: CRITICAL: 0 | HIGH: 2 | MEDIUM: 1 | LOW: 0
REVIEWEOF
}

# Builds and runs a full promote flow against a stub assessor.
# Sets _call_log / _env_log for the caller to assert on.
_run_promote_with_assessor() {
  local _tag="$1" _assess_out="$2" _assess_code="$3" _later="${4:-}" _openlist="${5:-}"
  _lib="$RITE_TEST_TMPDIR/lib-$_tag"
  _write_followup_stubs "$_lib"
  _call_log="$RITE_TEST_TMPDIR/${_tag}_issue_calls.log"
  _env_log="$RITE_TEST_TMPDIR/${_tag}_assessor_env.log"
  _write_stub_assessor "$_lib" "$_assess_out" "$_assess_code" "$_env_log" "$_later"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-$_tag"
  _write_fake_git "$_fake_bin"
  local _review_file="$RITE_TEST_TMPDIR/review_$_tag.txt"
  _write_noncrit_review "$_review_file"

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-$_tag"
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
ensure_labels_exist()       { return 0; }
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
        list)
          printf '%s' "$_openlist"
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
}

@test "assessment path: ACTIONABLE_NOW items create one aggregated issue and the raw fallback stays inert" {
  _run_promote_with_assessor "now" "### Unvalidated input - ACTIONABLE_NOW
Reasoning: missing bounds check.

### Naming nit - DISMISSED
Reasoning: style preference." 0 ""

  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  # Exactly one issue — the assessed NOW rollup, not also the raw fallback.
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
  grep -q "ACTIONABLE_NOW" "$_call_log"
  grep -q "test-branch" "$_call_log"
  grep -q "from-review" "$_call_log"
  grep -q "tech-debt" "$_call_log"
  # The deterministic fallback's label must be absent — it is gated off.
  ! grep -q "needs-re-triage" "$_call_log"
}

@test "assessment path: assessor receives the promote env contract (empty RITE_ISSUE_NUMBER widens dedup)" {
  _run_promote_with_assessor "env" "### Thing - ACTIONABLE_NOW
Reasoning: x." 0 ""

  [ "$status" -eq 0 ]
  [ -f "$_env_log" ]
  grep -q "^PR=55$" "$_env_log"
  grep -q "^REVIEW_FILE_EXISTS=yes$" "$_env_log"
  grep -q "^AUTO=--auto$" "$_env_log"
  # Empty, not unset: the empty value is what widens the Stage-2 dedup search
  # from "same source issue" to "any open follow-up".
  grep -q "^RITE_ISSUE_NUMBER=\[\]$" "$_env_log"
  grep -q "^RITE_RETRY_COUNT=0$" "$_env_log"
  grep -q "^RITE_REVIEW_JUST_POSTED=true$" "$_env_log"
  # Promotion reviews span every constituent issue — timeout above the 300s default.
  grep -q "^RITE_ASSESSMENT_TIMEOUT=600$" "$_env_log"
  # Passback file must be a real path so ACTIONABLE_LATER issues are countable.
  ! grep -q "^PER_ITEM_FILE=UNSET$" "$_env_log"
}

@test "assessment path: ACTIONABLE_LATER per-item issues are counted, not re-filed in aggregate" {
  # Assessor files its own per-item issues and passes the numbers back; the
  # aggregate must report that count rather than duplicating those findings.
  _run_promote_with_assessor "later" "### Later thing - ACTIONABLE_LATER
Reasoning: defer." 0 "201 202"

  [ "$status" -eq 0 ]
  # Zero ACTIONABLE_NOW → no aggregate issue at all.
  [ ! -f "$_call_log" ] || [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 0 ]
  echo "$output" | grep -q "2 issue(s) filed for ACTIONABLE_LATER"
}

@test "assessment path: all-DISMISSED review files nothing" {
  _run_promote_with_assessor "dismissed" "NO_ACTIONABLE_ITEMS" 0 ""

  [ "$status" -eq 0 ]
  # NO_ACTIONABLE_ITEMS is a successful assessment with zero survivors — the
  # whole point of assessing at promote. Nothing may be filed.
  [ ! -f "$_call_log" ] || [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 0 ]
}

@test "assessment path: assessor failure falls back to the deterministic raw capture" {
  _run_promote_with_assessor "fail" "" 1 ""

  [ "$status" -eq 0 ]
  # Fallback fired: the raw-capture issue carries needs-re-triage.
  [ -f "$_call_log" ]
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
  grep -q "needs-re-triage" "$_call_log"
}

@test "assessment path: ALL_ITEMS sentinel falls back to the deterministic raw capture" {
  # ALL_ITEMS means the assessor declined to classify (provider unavailable).
  # Treating it as a successful assessment would drop every finding.
  _run_promote_with_assessor "allitems" "ALL_ITEMS" 0 ""

  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
  grep -q "needs-re-triage" "$_call_log"
}

@test "assessment path: promote still files nothing when there is no assessor at all" {
  # Pre-#1278 installs and target repos without the assessor must keep the
  # deterministic behaviour exactly. No stub assessor is written here.
  local _lib="$RITE_TEST_TMPDIR/lib-noassessor"
  _write_followup_stubs "$_lib"
  [ ! -f "$_lib/core/assess-review-issues.sh" ]
  local _call_log="$RITE_TEST_TMPDIR/noassessor_calls.log"
  local _fake_bin="$RITE_TEST_TMPDIR/fake-git-na"
  _write_fake_git "$_fake_bin"
  local _review_file="$RITE_TEST_TMPDIR/review_na.txt"
  _write_noncrit_review "$_review_file"

  local _runner
  _runner=$(_write_followup_runner << RUNEOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="$_lib"
export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
export RITE_INSTALL_DIR="$RITE_TEST_TMPDIR"
export RITE_WORKTREE_DIR="$RITE_TEST_TMPDIR/wt-na"
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
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
  grep -q "needs-re-triage" "$_call_log"
}

@test "promote-branch.sh assessment is best-effort: no exit on assessor failure" {
  # The assessor invocation must capture its exit code, never let set -e abort
  # the promote. Phase 5b has already passed every gate at that point.
  _region=$(sed -n '/Phase 5b: Assess the promotion review/,/Fallback: deterministic capture/p' \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh")
  [ -n "$_region" ]
  # Exit code captured, not propagated.
  echo "$_region" | grep -q '|| _promo_assess_exit=\$?'
  # No bare exit anywhere in the assessment region.
  ! echo "$_region" | grep -qE '^\s*exit [0-9]'
}

# ===========================================================================
# Group 7: ACTIONABLE_NOW dedup at promote (#1294)
#
# The assessor's own dedup runs only inside its ACTIONABLE_LATER loop, so NOW
# items reached the aggregate unchecked. The first live run proved it:
# promoting plan-quality re-filed a finding already tracked as #1253.
# ===========================================================================

# Loads ONLY the two pure dedup helpers out of promote-branch.sh. Sourcing the
# whole orchestrator pulls in config.sh, which has no valid environment in a
# hermetic test; these functions have no dependencies beyond coreutils.
_load_promote_dedup_helpers() {
  eval "$(sed -n '/^_promote_title_matches_open_issue()/,/^}/p' \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh")"
  eval "$(sed -n '/^_promote_strip_tracked_now_blocks()/,/^}/p' \
    "$RITE_REPO_ROOT/lib/core/promote-branch.sh")"
}

@test "_promote_title_matches_open_issue: 2+ long-word overlap is a match" {
  _load_promote_dedup_helpers
  local _list="1253:Unlisted multi-part suffixes collapse to bare public suffix producing nonsense spikes
1196:Tally recurring review findings in health report"
  run _promote_title_matches_open_issue \
    "Unlisted suffixes collapse to the public suffix" "$_list"
  [ "$status" -eq 0 ]
  [ "$output" = "1253" ]
}

@test "_promote_title_matches_open_issue: fewer than 2 overlapping long words is not a match" {
  _load_promote_dedup_helpers
  local _list="1196:Tally recurring review findings in health report"
  run _promote_title_matches_open_issue \
    "Spike title truncation collides in _dedup_issues" "$_list"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_promote_title_matches_open_issue: words of 3 chars or fewer do not count" {
  _load_promote_dedup_helpers
  # "the" and "and" overlap but are too short; no long word is shared.
  local _list="500:the cat and the dog"
  run _promote_title_matches_open_issue "the bird and the fish" "$_list"
  [ "$status" -ne 0 ]
}

@test "_promote_title_matches_open_issue: empty issue list never matches" {
  _load_promote_dedup_helpers
  run _promote_title_matches_open_issue "anything plausible here" ""
  [ "$status" -ne 0 ]
}

@test "_promote_strip_tracked_now_blocks: removes only the named ACTIONABLE_NOW blocks" {
  _load_promote_dedup_helpers
  local _dups="$BATS_TEST_TMPDIR/dups.txt"
  printf 'Dup finding one\n' > "$_dups"
  local _txt="### Dup finding one - ACTIONABLE_NOW
Reasoning: already tracked.

### Keep me - ACTIONABLE_NOW
Reasoning: genuinely new.

### Dup finding one - ACTIONABLE_LATER
Reasoning: same title, DIFFERENT state — must survive.

### Other thing - DISMISSED
Reasoning: kept in the text."

  run _promote_strip_tracked_now_blocks "$_txt" "$_dups"
  [ "$status" -eq 0 ]
  # The duplicate NOW block is gone...
  ! echo "$output" | grep -q "already tracked"
  # ...but the new NOW block, the same-titled LATER block, and DISMISSED stay.
  echo "$output" | grep -q "Keep me - ACTIONABLE_NOW"
  echo "$output" | grep -q "Dup finding one - ACTIONABLE_LATER"
  echo "$output" | grep -q "DIFFERENT state"
  echo "$output" | grep -q "Other thing - DISMISSED"
}

@test "dedup at promote: a NOW finding already tracked is not re-filed; the new one is" {
  _run_promote_with_assessor "dedup" "### Unlisted suffixes collapse to the public suffix - ACTIONABLE_NOW
Reasoning: already tracked elsewhere.

### Spike title truncation collides in the key builder - ACTIONABLE_NOW
Reasoning: genuinely new." 0 "" \
    "1253:Unlisted multi-part suffixes collapse to bare public suffix producing nonsense spikes"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 of 2 ACTIONABLE_NOW finding(s) already tracked"
  [ -f "$_call_log" ]
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
  # The filed issue must carry the new finding and name the tracked one as skipped.
  grep -q "Spike title truncation" "$_call_log"
  grep -q "already tracked as #1253" "$_call_log"
  # The duplicate's own reasoning block must NOT be in the body.
  ! grep -q "already tracked elsewhere" "$_call_log"
}

@test "dedup at promote: all NOW findings already tracked files nothing at all" {
  _run_promote_with_assessor "alldup" "### Unlisted suffixes collapse to the public suffix - ACTIONABLE_NOW
Reasoning: already tracked." 0 "" \
    "1253:Unlisted multi-part suffixes collapse to bare public suffix producing nonsense spikes"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already tracked — nothing new to file"
  [ ! -f "$_call_log" ] || [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 0 ]
}

@test "dedup at promote: an unavailable issue list files the aggregate whole" {
  # Best-effort: a failed list fetch must not drop findings. Empty list → no
  # filtering → the aggregate is filed exactly as it was before dedup existed.
  _run_promote_with_assessor "nolist" "### Unlisted suffixes collapse to the public suffix - ACTIONABLE_NOW
Reasoning: would have matched if the list had loaded." 0 "" ""

  [ "$status" -eq 0 ]
  [ -f "$_call_log" ]
  [ "$(grep -c 'ISSUE_CREATE' "$_call_log")" -eq 1 ]
  grep -q "would have matched" "$_call_log"
}
