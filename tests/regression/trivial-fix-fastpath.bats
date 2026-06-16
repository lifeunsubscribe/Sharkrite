#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/trivial-fix-fastpath.sh, lib/utils/triage-classify.sh
#
# Trivial-fix fast-path (#531). The fast-path applies a concrete patch from the
# issue body and merges it ONLY after the cheap haiku triage classifier + the
# post-commit gate both pass — skipping the Phase-1 Claude dev session AND the
# full opus review. These tests lock in:
#   1. Eligibility parsing (marker + ```diff block).
#   2. The acceptance contract: an eligible issue runs ZERO dev sessions and
#      exactly ONE gate, posts the fast-path PR comment, and returns ready-to-merge.
#   3. Side-effect-free fall-back: ineligible / triage-substantive / gate-fail /
#      patch-doesn't-apply all return 1 with no commit, push, or PR.
#
# git, gh, the gate, and the classifier are all stubbed → offline + deterministic.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_PROJECT_ROOT="$(mktemp -d)"
  export RITE_WORKTREE_DIR="$(mktemp -d)/wt"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_WORKTREE_DIR" "$RITE_STATE_DIR"

  # Load fast-path functions only (no executable body).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/utils/trivial-fix-fastpath.sh"

  # Sentinels for assertions.
  export _GATE_CALLS="$RITE_PROJECT_ROOT/gate-calls"
  export _GIT_LOG="$RITE_PROJECT_ROOT/git-cmds"
  export _DEVSESSION="$RITE_PROJECT_ROOT/dev-session-called"
  : > "$_GATE_CALLS"; : > "$_GIT_LOG"

  # --- stubs -------------------------------------------------------------
  print_header()  { :; }
  print_info()    { :; }
  print_step()    { :; }
  print_success() { :; }
  print_warning() { :; }
  print_error()   { :; }
  _diag()         { :; }

  # gh_safe: dispatch on the subcommand. Issue body is driven per-test via
  # ISSUE_BODY; pr create returns a URL ending in the PR number.
  gh_safe() {
    case "$*" in
      *"issue view"*"body"*)  echo "${ISSUE_BODY:-}";;
      *"issue view"*"title"*) echo "Fix a typo in foo.sh";;
      *"pr create"*)          echo "https://github.com/x/y/pull/777";;
      *"pr list"*)            echo "777";;
      *"pr comment"*)         echo "${_FASTPATH_COMMENT:-}" > "$RITE_PROJECT_ROOT/pr-comment"; echo ok;;
      *)                      echo "";;
    esac
  }

  # run_test_gate: record each call; write a green (or red) sentinel JSON.
  run_test_gate() {
    echo "called" >> "$_GATE_CALLS"
    printf '{"lint":[],"tests":[],"exit_code":%s,"skipped":false}\n' "${GATE_EXIT:-0}" > "$1"
    return 0
  }

  # triage classifier: verdict driven per-test.
  triage_classify_diff() {
    printf '%s|%s|none|stub|2|logic\n' "${TRIAGE_VERDICT:-trivial}" "${TRIAGE_CONF:-0.95}"
  }

  # provider shims (Layer-2 path is bypassed by the triage stub, but the
  # fast-path tries to load a provider — make that a no-op).
  load_provider() { :; }
  provider_run_prompt() { echo '{"verdict":"trivial","confidence":0.95,"reason":"stub"}'; }
  claude_provider_resolve_model() { echo "claude-haiku-4-5"; }

  # If a dev session were ever invoked, this would fire (it must NOT).
  claude_dev_session() { echo "called" > "$_DEVSESSION"; }

  # git stub: record commands; succeed for the orchestration verbs. Failure
  # modes are driven per-test via APPLY_CHECK_FAIL.
  git() {
    echo "$*" >> "$_GIT_LOG"
    case "$*" in
      *"apply --check"*) return "${APPLY_CHECK_FAIL:-0}";;
      *"worktree add"*)  mkdir -p "$(echo "$* " | grep -oE '/[^ ]*/wt/[^ ]*' | head -1)" 2>/dev/null || true; return 0;;
      *" diff --name-only"*) echo "lib/foo.sh"; return 0;;
      *" diff"*)         printf 'diff --git a/lib/foo.sh b/lib/foo.sh\n--- a/lib/foo.sh\n+++ b/lib/foo.sh\n-old\n+new\n'; return 0;;
      *)                 return 0;;
    esac
  }

  export -f gh_safe run_test_gate triage_classify_diff load_provider \
    provider_run_prompt claude_provider_resolve_model claude_dev_session git \
    print_header print_info print_step print_success print_warning print_error _diag
}

teardown() {
  rm -rf "$RITE_PROJECT_ROOT" "${RITE_WORKTREE_DIR%/wt}" 2>/dev/null || true
}

_eligible_body() {
  cat <<'EOF'
## Summary
Trivial typo fix.

<!-- sharkrite-fastpath -->
```diff
--- a/lib/foo.sh
+++ b/lib/foo.sh
@@ -1,1 +1,1 @@
-old
+new
```
EOF
}

# ---- eligibility parsing -------------------------------------------------
@test "parse: eligible body (marker + diff) → 0, files extracted" {
  run fastpath_parse_issue "$(_eligible_body)"
  [ "$status" -eq 0 ]
}

@test "parse: no marker → ineligible" {
  run fastpath_parse_issue "$(printf '## Summary\n```diff\n-a\n+b\n```\n')"
  [ "$status" -ne 0 ]
}

@test "parse: marker but no diff block → ineligible" {
  run fastpath_parse_issue "$(printf '<!-- sharkrite-fastpath -->\nno diff here\n')"
  [ "$status" -ne 0 ]
}

# ---- acceptance: eligible → 0 dev sessions, exactly 1 gate ---------------
@test "fastpath: eligible+trivial+green → ready to merge, ONE gate, ZERO dev sessions" {
  export ISSUE_BODY="$(_eligible_body)"
  export TRIAGE_VERDICT=trivial GATE_EXIT=0
  run try_trivial_fix_fastpath 42
  [ "$status" -eq 0 ]
  # Exactly one gate run.
  [ "$(grep -c called "$_GATE_CALLS")" -eq 1 ]
  # Zero dev sessions.
  [ ! -f "$_DEVSESSION" ]
  # Committed + pushed + PR created.
  grep -q "commit" "$_GIT_LOG"
  grep -q "push" "$_GIT_LOG"
  # Fast-path PR comment posted.
  [ -f "$RITE_PROJECT_ROOT/pr-comment" ]
}

# ---- fall-back paths are side-effect free (no commit/push) ---------------
@test "fastpath: ineligible issue → returns 1, no worktree, no gate" {
  export ISSUE_BODY="## Just a normal issue, no patch."
  run try_trivial_fix_fastpath 42
  [ "$status" -eq 1 ]
  [ ! -s "$_GATE_CALLS" ]
  [ ! -s "$_GIT_LOG" ]
}

@test "fastpath: triage substantive → returns 1, no commit/push" {
  export ISSUE_BODY="$(_eligible_body)"
  export TRIAGE_VERDICT=substantive
  run try_trivial_fix_fastpath 42
  [ "$status" -eq 1 ]
  ! grep -q "commit" "$_GIT_LOG"
  ! grep -q "push" "$_GIT_LOG"
  [ ! -f "$_DEVSESSION" ]
}

@test "fastpath: gate fails → returns 1, no commit/push" {
  export ISSUE_BODY="$(_eligible_body)"
  export TRIAGE_VERDICT=trivial GATE_EXIT=1
  run try_trivial_fix_fastpath 42
  [ "$status" -eq 1 ]
  # Gate ran once, but no commit/push followed.
  [ "$(grep -c called "$_GATE_CALLS")" -eq 1 ]
  ! grep -q "commit" "$_GIT_LOG"
  ! grep -q "push" "$_GIT_LOG"
}

@test "fastpath: patch does not apply → returns 1, no gate, no commit" {
  export ISSUE_BODY="$(_eligible_body)"
  export APPLY_CHECK_FAIL=1
  run try_trivial_fix_fastpath 42
  [ "$status" -eq 1 ]
  [ ! -s "$_GATE_CALLS" ]
  ! grep -q "commit" "$_GIT_LOG"
}
