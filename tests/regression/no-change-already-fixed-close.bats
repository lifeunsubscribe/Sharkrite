#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh
# tests/regression/no-change-already-fixed-close.bats
#
# Regression tests for: Close already-fixed issues on no-change sessions (#821)
#
# Bug history (2026-07-01 LeadFlow #348):
#   The review-follow-up for issue #348 demanded `...commonLambdaEnv` on
#   CampaignSyncFunction. PR #407 merged that exact change at 15:37Z. The
#   15:54 batch run correctly made no changes (the fix was already on main)
#   and was marked "Issue #348 failed (exit code: 1)". The issue stayed open
#   and burned a session on every future batch (5 zombie sessions on
#   2026-07-06 alone, per Pilot).
#
# Design history (PR #873, CRITICAL review finding):
#   The first implementation EXECUTED the issue's verification command via
#   `run_with_timeout 30 bash -c "$_verify_cmd"` — an RCE vector (issue bodies
#   are attacker-controllable text). That branch was abandoned. This rebuild is
#   EXECUTION-FREE: the single verification line is parsed as DATA against a
#   strict whitelist (grep/git-grep shape, single-quoted pattern, safe
#   repo-relative path, no shell metacharacters) and re-checked with our own
#   `git grep -F --`. Nothing from the issue body is ever executed.
#
# Tests:
#   STRUCTURAL: function exists; both call sites gate the fail-loud path;
#     the function body is execution-free (no bash -c/eval/sh -c) and uses
#     git grep -F for the data check.
#   BEHAVIORAL (accept): pattern present on pinned main → close with evidence,
#     return 0, ALREADY_FIXED diag; bold-header format; leading-comment skip.
#   BEHAVIORAL (refuse): pattern absent; no section; empty body; every
#     whitelist violation (metacharacters, non-grep command, unquoted pattern,
#     path traversal, absolute path, multi-command block) → return 1, issue
#     NOT closed, and injection canaries never materialize.
#   REF-PINNING: HEAD != origin/main, dirty tree, fetch failure → return 1.

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# _setup_stub_lib  — minimal stub RITE_LIB_DIR so sourcing workflow-runner.sh
# fires no network calls (pattern from workflow-runner-no-work-invariant.bats).
# ---------------------------------------------------------------------------
_setup_stub_lib() {
  local _stub_lib="$RITE_TEST_TMPDIR/stub-lib"
  for _subdir in utils providers core; do
    mkdir -p "$_stub_lib/$_subdir"
  done

  for _mod in \
    utils/notifications.sh utils/blocker-rules.sh utils/session-tracker.sh \
    utils/pr-summary.sh utils/normalize-issue.sh utils/markers.sh \
    utils/pr-detection.sh utils/date-helpers.sh utils/stash-manager.sh \
    utils/mid-run-rebase.sh utils/review-helper.sh utils/colors.sh \
    utils/logging.sh utils/timeout.sh utils/test-gate.sh \
    providers/provider-interface.sh; do
    printf '#!/usr/bin/env bash\n# stub\n' > "$_stub_lib/$_mod"
  done

  echo "$_stub_lib"
}

# ---------------------------------------------------------------------------
# _setup_real_git_repo  — minimal real git repo that looks like a clean main
# checkout with a fake origin/main ref (written directly under .git/refs so
# no real remote is needed). HEAD == origin/main by default; tests mutate
# this state (extra commit / dirty file) to exercise the ref-pinning guards.
# The tracked file carries the marker string the accept-path data checks use.
# ---------------------------------------------------------------------------
_setup_real_git_repo() {
  local _repo="$RITE_TEST_TMPDIR/test-repo"
  mkdir -p "$_repo"
  git -C "$_repo" init -b main >/dev/null 2>&1 || git -C "$_repo" init >/dev/null 2>&1
  git -C "$_repo" config user.email "test@test.test"
  git -C "$_repo" config user.name "Test"
  printf 'initial\n...commonLambdaEnv,\n' > "$_repo/initial.txt"
  git -C "$_repo" add initial.txt
  git -C "$_repo" commit -m "initial commit" >/dev/null 2>&1

  local _sha
  _sha=$(git -C "$_repo" rev-parse HEAD)
  mkdir -p "$_repo/.git/refs/remotes/origin"
  echo "$_sha" > "$_repo/.git/refs/remotes/origin/main"

  echo "$_repo"
}

# ---------------------------------------------------------------------------
# _run_verify BODY_FILE [REPO]  — run verify_already_fixed_on_main in a
# subshell with stubs; issue body is read from BODY_FILE (a file, so payloads
# with quotes/metacharacters need no escaping in test source). Exit status is
# the function's return. gh mutation calls are recorded to $_gh_calls_file.
# Direct call + file capture (not `run`): the old harness pattern — keeps
# function-level stubs exportable and the subshell's cwd at the repo root so
# an accidentally-executed payload would land its canary there.
# ---------------------------------------------------------------------------
_run_verify() {
  local _body_file="$1"
  local _repo="${2:-$(_setup_real_git_repo)}"
  (
    set +e
    cd "$_repo" || exit 90
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$_repo"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE="$_log_file"
    WORKFLOW_MODE="unsupervised"
    CURRENT_RETRY=0
    INTERRUPT_RECEIVED=false
    GREEN=""; NC=""; BLUE=""; RED=""; YELLOW=""
    print_status()  { :; }
    print_info()    { :; }
    print_warning() { :; }
    print_error()   { echo "ERROR: $*" >&2; }
    print_success() { :; }
    print_header()  { :; }
    _diag()         { echo "_diag: $*" >> "$_log_file"; }
    _timer_start()  { :; }
    _timer_end()    { :; }

    # Stub only 'git fetch' (network); every other git subcommand runs real
    # so rev-parse/status/grep hit the fixture repo.
    git() {
      if [ "${1:-}" = "-C" ]; then
        local _dir="$2"; shift 2
        case "${1:-}" in
          fetch) return 0 ;;
          *)     command git -C "$_dir" "$@" ;;
        esac
      else
        case "${1:-}" in
          fetch) return 0 ;;
          *)     command git "$@" ;;
        esac
      fi
    }
    export -f git

    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    # gh_safe stub (defined AFTER sourcing — env-guarded libs overwrite stubs
    # at load time). Issue body comes from the payload file verbatim.
    gh_safe() {
      local _subcmd="${1:-}" _obj="${2:-}"
      case "$_subcmd $_obj" in
        "issue view")  cat "$_BODY_FILE" ;;
        "issue comment")
          echo "issue comment called: $*" >> "$_gh_calls_file"
          # Record the comment body for evidence assertions
          while [ $# -gt 0 ]; do
            if [ "$1" = "--body-file" ]; then cat "$2" >> "$_gh_calls_file"; fi
            shift
          done
          ;;
        "issue close") echo "issue close called: $*" >> "$_gh_calls_file" ;;
        "pr view")     echo "0" ;;
        "pr close")    echo "pr close called" >> "$_gh_calls_file" ;;
        *) : ;;
      esac
      return 0
    }
    _BODY_FILE="$_body_file"
    export _BODY_FILE
    export -f gh_safe

    verify_already_fixed_on_main "348"
  )
}

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_DATA_DIR=".rite"
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"

  _stub_lib=$(_setup_stub_lib)
  _log_file="$RITE_TEST_TMPDIR/test.log"
  _gh_calls_file="$RITE_TEST_TMPDIR/gh_calls.txt"
  touch "$_log_file" "$_gh_calls_file"
  _body_file="$RITE_TEST_TMPDIR/issue-body.md"
}

teardown() {
  teardown_test_tmpdir
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "structural: verify_already_fixed_on_main function is defined in workflow-runner.sh" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ -f "$_wfr" ]
  _count=$(grep -c "^verify_already_fixed_on_main()" "$_wfr" || true)
  [ "$_count" -ge 1 ]
}

@test "structural: both no-change retry paths call verify_already_fixed_on_main" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _count=$(grep -c "verify_already_fixed_on_main" "$_wfr" || true)
  # 1 definition + 2 call sites (+ comment mentions) — call sites are the pin:
  _calls=$(grep -c "if verify_already_fixed_on_main" "$_wfr" || true)
  [ "$_calls" -ge 2 ] || {
    echo "FAIL: expected 2 'if verify_already_fixed_on_main' call sites, found: $_calls (total refs: $_count)"
    return 1
  }
}

@test "structural [RCE pin]: function body is execution-free — no bash -c / eval / sh -c; data check is git grep -F" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _start=$(grep -n "^verify_already_fixed_on_main()" "$_wfr" | head -1 | cut -d: -f1)
  [ -n "$_start" ]
  # Extract the function body by line numbers (bats preprocessor mangles
  # literal 'name() {' patterns in test source — use the anchored grep above).
  _body=$(awk -v s="$_start" 'NR>=s { print; if (NR>s && /^}/) exit }' "$_wfr")
  # Comments stripped: assertions target executable lines only.
  _code=$(printf '%s\n' "$_body" | grep -v "^[[:space:]]*#" || true)

  # The data check must be our own fixed-string git grep:
  printf '%s\n' "$_code" | grep -qF 'grep -nF --' || {
    echo "FAIL: expected the data check to use 'git ... grep -nF --'"
    return 1
  }
  # NOTHING from the issue may be executed. If any of these reappear in the
  # function body, the #873 RCE has been reintroduced — hard fail.
  for _forbidden in "bash -c" "eval " "sh -c" "run_with_timeout"; do
    if printf '%s\n' "$_code" | grep -qF "$_forbidden"; then
      echo "FAIL: forbidden execution primitive '$_forbidden' found in verify_already_fixed_on_main body"
      return 1
    fi
  done
}

@test "structural: fail-loud path preserved after the gate (both sites keep the error message)" {
  _wfr="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  _count=$(grep -c 'print_error "Development produced no changes after retry"' "$_wfr" || true)
  [ "$_count" -ge 2 ] || {
    echo "FAIL: expected both fail-loud print_error sites to survive; found: $_count"
    return 1
  }
}

# =============================================================================
# BEHAVIORAL — accept path (evidence found on pinned main)
# =============================================================================

@test "behavioral: grep line whose pattern exists on main → closes issue with evidence, returns 0" {
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 0 ] || {
    echo "FAIL: expected exit 0 (already fixed), got $_result"
    cat "$_gh_calls_file"
    return 1
  }
  grep -q "issue close called" "$_gh_calls_file"
  grep -q "issue comment called" "$_gh_calls_file"
  # Evidence: the close comment must quote the matching line from the repo
  grep -qF "...commonLambdaEnv," "$_gh_calls_file" || {
    echo "FAIL: close comment does not quote the matched evidence line"
    cat "$_gh_calls_file"
    return 1
  }
  grep -q "ALREADY_FIXED" "$_log_file"
}

@test "behavioral: git grep form and flag tokens are accepted (flags ignored, our own -F lookup runs)" {
  printf '## Verification Commands\n```bash\ngit grep -qn %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 0 ]
  grep -q "issue close called" "$_gh_calls_file"
}

@test "behavioral: **Verification Commands**: bold-header format is also parsed" {
  printf '**Verification Commands**:\n```bash\ngrep -q %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 0 ]
  grep -q "issue close called" "$_gh_calls_file"
}

@test "behavioral: leading comment line in block is skipped — single real command still accepted" {
  printf '## Verification Commands\n```bash\n# should find the marker on main\ngrep -q %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 0 ]
  grep -q "issue close called" "$_gh_calls_file"
}

# =============================================================================
# BEHAVIORAL — refuse paths (no evidence → return 1, issue NOT closed)
# =============================================================================

@test "behavioral: pattern absent from main → returns 1, issue NOT closed" {
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' "'THIS_STRING_IS_NOT_IN_THE_REPO'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 1 ]
  if grep -q "issue close called" "$_gh_calls_file"; then
    echo "FAIL: issue was closed without evidence on main"
    return 1
  fi
}

@test "behavioral: no Verification Commands section → returns 1, issue NOT closed" {
  printf '## Description\nJust a description, no verification section.\n' > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 1 ]
  [ ! -s "$_gh_calls_file" ]
}

@test "behavioral: empty issue body → returns 1 gracefully" {
  : > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 1 ]
  [ ! -s "$_gh_calls_file" ]
}

@test "behavioral: multi-command block → refused (exactly one verification line required)" {
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\ngrep -q %s initial.txt\n```\n' "'initial'" "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" || _result=$?
  [ "$_result" -eq 1 ]
  [ ! -s "$_gh_calls_file" ]
}

# =============================================================================
# BEHAVIORAL — whitelist rejections (the RCE remediation itself)
# Every payload here would have EXECUTED under the #873 design. Each must be
# refused as unparseable data: return 1, no close, no side effects.
# =============================================================================

@test "behavioral [RCE]: metacharacter / non-grep / traversal payloads are all refused without side effects" {
  _repo=$(_setup_real_git_repo)

  # Payloads land one per file; quotes and metachars stay out of test source.
  _payloads="$RITE_TEST_TMPDIR/payloads"
  mkdir -p "$_payloads"

  # 1. command chaining via ';' — canary would be created if executed
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt; touch PWNED-canary\n```\n' "'initial'" > "$_payloads/p1.md"
  # 2. pipe
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt | touch PWNED-canary\n```\n' "'initial'" > "$_payloads/p2.md"
  # 3. command substitution in pattern (contains \$)
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' "'\$(touch PWNED-canary)'" > "$_payloads/p3.md"
  # 4. backtick substitution
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' '`touch PWNED-canary`' > "$_payloads/p4.md"
  # 5. non-grep command entirely
  printf '## Verification Commands\n```bash\ntouch PWNED-canary\n```\n' > "$_payloads/p5.md"
  # 6. rm disguised behind grep-ish name
  printf '## Verification Commands\n```bash\ngreprm -rf .\n```\n' > "$_payloads/p6.md"
  # 7. unquoted pattern (not single-quoted → not a literal by construction)
  printf '## Verification Commands\n```bash\ngrep -q initial initial.txt\n```\n' > "$_payloads/p7.md"
  # 8. path traversal
  printf '## Verification Commands\n```bash\ngrep -q %s ../../../etc/passwd\n```\n' "'root'" > "$_payloads/p8.md"
  # 9. absolute path
  printf '## Verification Commands\n```bash\ngrep -q %s /etc/passwd\n```\n' "'root'" > "$_payloads/p9.md"
  # 10. redirect
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt > PWNED-canary\n```\n' "'initial'" > "$_payloads/p10.md"

  for _p in "$_payloads"/p*.md; do
    : > "$_gh_calls_file"
    _result=0
    _run_verify "$_p" "$_repo" || _result=$?
    [ "$_result" -eq 1 ] || {
      echo "FAIL: payload $(basename "$_p") was ACCEPTED (exit $_result) — whitelist breach:"
      cat "$_p"
      return 1
    }
    if grep -q "issue close called" "$_gh_calls_file"; then
      echo "FAIL: payload $(basename "$_p") closed the issue"
      return 1
    fi
  done

  # THE pin: no canary may exist anywhere the payloads could have written one.
  [ ! -f "$_repo/PWNED-canary" ] || {
    echo "FAIL: injection canary exists — issue text was EXECUTED (#873 RCE reintroduced)"
    return 1
  }
  [ ! -f "$RITE_TEST_TMPDIR/PWNED-canary" ]
}

# =============================================================================
# REF-PINNING guards (ported from the #873 branch — evidence only counts
# against a checkout that IS origin/main)
# =============================================================================

@test "behavioral [ref-pinning]: HEAD != origin/main → returns 1 without closing issue" {
  _repo=$(_setup_real_git_repo)
  # Advance HEAD one commit; origin/main still points at the old SHA
  echo "extra" >> "$_repo/initial.txt"
  git -C "$_repo" add initial.txt
  git -C "$_repo" commit -m "extra commit" >/dev/null 2>&1

  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" "$_repo" || _result=$?
  [ "$_result" -eq 1 ] || {
    echo "FAIL: expected exit 1 (HEAD != origin/main guard), got $_result"
    return 1
  }
  [ ! -s "$_gh_calls_file" ]
}

@test "behavioral [ref-pinning]: dirty working tree → returns 1 without closing issue" {
  _repo=$(_setup_real_git_repo)
  # Dirty WITHOUT committing — HEAD still == origin/main
  echo "dirty modification" >> "$_repo/initial.txt"
  _head=$(git -C "$_repo" rev-parse HEAD)
  _origin=$(git -C "$_repo" rev-parse origin/main)
  [ "$_head" = "$_origin" ]

  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  _run_verify "$_body_file" "$_repo" || _result=$?
  [ "$_result" -eq 1 ] || {
    echo "FAIL: expected exit 1 (dirty tree guard), got $_result"
    return 1
  }
  [ ! -s "$_gh_calls_file" ]
}

@test "behavioral [ref-pinning]: fetch failure → returns 1 without closing issue" {
  _repo=$(_setup_real_git_repo)
  printf '## Verification Commands\n```bash\ngrep -q %s initial.txt\n```\n' "'...commonLambdaEnv,'" > "$_body_file"

  _result=0
  (
    set +e
    cd "$_repo" || exit 90
    export RITE_LIB_DIR="$_stub_lib"
    export RITE_PROJECT_ROOT="$_repo"
    export RITE_DATA_DIR=".rite"
    export RITE_LOG_FILE="$_log_file"
    WORKFLOW_MODE="unsupervised"
    CURRENT_RETRY=0
    INTERRUPT_RECEIVED=false
    GREEN=""; NC=""; BLUE=""; RED=""; YELLOW=""
    print_status()  { :; }
    print_info()    { :; }
    print_warning() { :; }
    print_error()   { echo "ERROR: $*" >&2; }
    print_success() { :; }
    print_header()  { :; }
    _diag()         { :; }
    _timer_start()  { :; }
    _timer_end()    { :; }

    # Stub 'git fetch' to FAIL (network down); everything else real.
    git() {
      if [ "${1:-}" = "-C" ]; then
        local _dir="$2"; shift 2
        case "${1:-}" in
          fetch) return 128 ;;
          *)     command git -C "$_dir" "$@" ;;
        esac
      else
        case "${1:-}" in
          fetch) return 128 ;;
          *)     command git "$@" ;;
        esac
      fi
    }
    export -f git

    # shellcheck disable=SC1090
    source "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"

    gh_safe() {
      case "${1:-} ${2:-}" in
        "issue view")  cat "$_BODY_FILE" ;;
        "issue comment"|"issue close") echo "${1:-} ${2:-} called" >> "$_gh_calls_file" ;;
        *) : ;;
      esac
      return 0
    }
    _BODY_FILE="$_body_file"
    export _BODY_FILE
    export -f gh_safe

    verify_already_fixed_on_main "348"
  ) || _result=$?

  [ "$_result" -eq 1 ] || {
    echo "FAIL: expected exit 1 (fetch-failure guard), got $_result"
    return 1
  }
  [ ! -s "$_gh_calls_file" ]
}
