#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh::inject_issue_context_into_fix_prompt|inject_rejection_reasons_into_fix_prompt
# Regression tests for issue #1828: fix sessions receive the issue body as
# quoted data, and a rejection-reason section for re-raised items.
#
# Tests in this file:
#   1. issue body is quoted — inject_issue_context_into_fix_prompt adds BEGIN/END_USER_DATA
#   2. no issue body — empty fetch leaves FIX_PROMPT unchanged
#   3. rejection reason leads — Prior Fix Rejected Because field appears before ## Issues to Fix
#   4. no rejection section — items without the field leave FIX_PROMPT unchanged
#   5. ends with the exit instruction — both inject calls precede EXIT_INSTRUCTION in assembly

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  export CLAUDE_WORKFLOW="${RITE_REPO_ROOT}/lib/core/claude-workflow.sh"
  [ -f "$CLAUDE_WORKFLOW" ] || { echo "setup: claude-workflow.sh missing" >&2; false; }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. issue body is quoted
# ---------------------------------------------------------------------------
@test "fix-prompt-issue-context: issue body is quoted" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    print_info()    { :; }
    print_status()  { :; }
    print_success() { :; }
    print_warning() { :; }
    print_error()   { echo \"\$*\" >&2; }
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'
    set +u; set +o pipefail
    # Define gh_safe AFTER sourcing: gh-retry.sh uses an env-var re-source guard and
    # would overwrite any pre-source stub (Test Authoring Runbook Rule 2).
    gh_safe() {
      if [ \"\$1\" = 'issue' ]; then
        printf '%s' '{\"title\":\"Fix the thing\",\"body\":\"## Acceptance Criteria\n- [ ] bats tests/regression/my.bats\"}'
      else echo ''; fi
    }
    FIX_PROMPT=''
    ISSUE_NUMBER=42
    inject_issue_context_into_fix_prompt
    printf '%s' \"\$FIX_PROMPT\"
  " </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'--- BEGIN_USER_DATA ---'* ]]
  [[ "$output" == *'--- END_USER_DATA ---'* ]]
  [[ "$output" == *'Fix the thing'* ]]
  [[ "$output" == *'quoted data'* ]]
  [[ "$output" == *'gate'* ]]
}

# ---------------------------------------------------------------------------
# 2. no issue body — fetch failed or issue has none: prompt is unchanged
# ---------------------------------------------------------------------------
@test "fix-prompt-issue-context: no issue body" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    print_info()    { :; }
    print_status()  { :; }
    print_success() { :; }
    print_warning() { :; }
    print_error()   { echo \"\$*\" >&2; }
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'
    set +u; set +o pipefail
    # Stub returns no body (empty string on issue fetch)
    gh_safe() { echo ''; }
    FIX_PROMPT='base prompt'
    ISSUE_NUMBER=99
    inject_issue_context_into_fix_prompt
    printf '%s' \"\$FIX_PROMPT\"
  " </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = 'base prompt' ]
}

# ---------------------------------------------------------------------------
# 3. rejection reason leads — section appears before ## Issues to Fix
# ---------------------------------------------------------------------------
@test "fix-prompt-issue-context: rejection reason leads" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    print_info()    { :; }
    print_status()  { :; }
    print_success() { :; }
    print_warning() { :; }
    print_error()   { echo \"\$*\" >&2; }
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'
    set +u; set +o pipefail
    FIX_PROMPT=''
    ACTIONABLE_NOW_ITEMS='### Vocabulary lookup missing - ACTIONABLE_NOW
**Severity:** HIGH
**Prior Fix Rejected Because:** Previous fix grew the alias list instead of using vocabulary lookup.
**Suggested Fix:** Use the vocabulary lookup pattern.'
    inject_rejection_reasons_into_fix_prompt
    FIX_PROMPT+='## Issues to Fix'
    printf '%s' \"\$FIX_PROMPT\"
  " </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *'Vocabulary lookup missing'* ]]
  [[ "$output" == *'Previous fix grew the alias list'* ]]
  # Rejection section must precede ## Issues to Fix
  [[ "$output" == *'prior fixes were rejected'*'## Issues to Fix'* ]]
}

# ---------------------------------------------------------------------------
# 4. no rejection section — items without the field leave prompt unchanged
# ---------------------------------------------------------------------------
@test "fix-prompt-issue-context: no rejection section" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    print_info()    { :; }
    print_status()  { :; }
    print_success() { :; }
    print_warning() { :; }
    print_error()   { echo \"\$*\" >&2; }
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'
    set +u; set +o pipefail
    FIX_PROMPT='base prompt'
    ACTIONABLE_NOW_ITEMS='### Some first-pass finding - ACTIONABLE_NOW
**Severity:** MEDIUM
**Suggested Fix:** Do the thing.'
    inject_rejection_reasons_into_fix_prompt
    printf '%s' \"\$FIX_PROMPT\"
  " </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = 'base prompt' ]
}

# ---------------------------------------------------------------------------
# 5. ends with the exit instruction — both inject calls precede EXIT_INSTRUCTION
# ---------------------------------------------------------------------------
@test "fix-prompt-issue-context: ends with the exit instruction" {
  # Structural: both inject function calls appear before FIX_PROMPT+="$EXIT_INSTRUCTION"
  # in the FIX_REVIEW_MODE assembly block.
  local _ctx _rej _exit
  _ctx=$(awk '/inject_issue_context_into_fix_prompt/ && !/^[[:space:]]*#/ && !/^inject_issue_context_into_fix_prompt\(\)/ {print NR; exit}' "$CLAUDE_WORKFLOW" || true)
  _rej=$(awk '/inject_rejection_reasons_into_fix_prompt/ && !/^[[:space:]]*#/ && !/^inject_rejection_reasons_into_fix_prompt\(\)/ {print NR; exit}' "$CLAUDE_WORKFLOW" || true)
  _exit=$(awk '/FIX_PROMPT.*EXIT_INSTRUCTION/ && !/^[[:space:]]*#/ {print NR; exit}' "$CLAUDE_WORKFLOW" || true)
  [ -n "$_ctx" ]
  [ -n "$_rej" ]
  [ -n "$_exit" ]
  [ "$_ctx" -lt "$_exit" ]
  [ "$_rej" -lt "$_exit" ]
}
