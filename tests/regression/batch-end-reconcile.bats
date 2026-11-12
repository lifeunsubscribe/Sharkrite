#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/reconcile-followups.sh
# Tests for batch-end follow-up reconciliation pass (#1552).
# Covers all four processing paths:
#   1. Unchanged (deterministic skip — no LLM call)
#   2. Resolved   — issue closed with comment
#   3. Partially resolved — annotate comment, leave open
#   4. Security label — resolved verdict posts comment only, never auto-close

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_PROJECT_ROOT="${BATS_TEST_TMPDIR}/project"
  mkdir -p "$RITE_PROJECT_ROOT"

  # Minimal stub for config.sh symbols used by reconcile-followups.sh
  export RITE_TARGET_BRANCH="main"
  export RITE_BATCH_RECONCILE="true"
  export RITE_LOG_FILE="${BATS_TEST_TMPDIR}/rite.log"
  touch "$RITE_LOG_FILE"

  # Source the markers file so marker constants are available
  source "$RITE_LIB_DIR/utils/markers.sh"

  # Source the reconcile lib (functions only — no top-level side effects)
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: reconcile-followups.sh uses a function-sentinel guard (declare -f reconcile_batch_followups); stubs defined before source are preserved on re-source.
  source "$RITE_LIB_DIR/utils/reconcile-followups.sh"

  # Restore flags after sourcing (libs set -euo pipefail)
  set +u; set +o pipefail

  # Ensure diag.log exists so grep -c on it never fails with "file not found"
  touch "${BATS_TEST_TMPDIR}/diag.log"

  # Stub _diag so diag calls don't crash
  _diag() { echo "[diag] $*" >> "${BATS_TEST_TMPDIR}/diag.log"; }

  # Stub print_* (colors.sh not sourced in test isolation)
  print_step()    { true; }
  print_info()    { true; }
  print_warning() { echo "WARN: $*" >> "${BATS_TEST_TMPDIR}/warns.log"; }
  print_success() { true; }
}

teardown() {
  rm -rf "$RITE_PROJECT_ROOT"
}

# ---------------------------------------------------------------------------
# Helper: build a minimal follow-up issue body with both markers.
# ---------------------------------------------------------------------------
_make_body() {
  local sha="$1"
  local loc="$2"
  local extra="${3:-}"
  printf '## Finding\nSome finding text.\n<!-- %s:%s -->\n<!-- %s:%s -->\n%s\n' \
    "${RITE_MARKER_FINDING_SHA}" "$sha" \
    "${RITE_MARKER_FINDING_LOCATION}" "$loc" \
    "$extra"
}

# ---------------------------------------------------------------------------
# Path 1: Unchanged file — deterministic skip, zero LLM calls.
# ---------------------------------------------------------------------------
@test "unchanged file: issue is skipped, no gh calls, no LLM call" {
  local _classify_file="${BATS_TEST_TMPDIR}/classify_calls"
  echo 0 > "$_classify_file"

  _batch_followups_created() { printf '42\n'; }
  gh_safe() {
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      local _body
      _body=$(_make_body "abc1234" "lib/core/foo.sh:10")
      printf '{"body":"%s","labels":[]}\n' \
        "$(echo "$_body" | sed 's/"/\\"/g; s/$/\\n/g' | tr -d '\n')"
    else
      echo "gh_safe unexpected: $*" >&2
      return 1
    fi
  }
  git() {
    if [ "$1" = "-C" ] && [ "$3" = "cat-file" ]; then
      return 0  # SHA is reachable
    elif [ "$1" = "-C" ] && [ "$3" = "diff" ]; then
      # Return empty diff — file unchanged
      printf ''
    fi
  }
  provider_resolve_model() { printf 'claude-haiku-4-5'; }
  provider_run_prompt() {
    echo $(( $(cat "$_classify_file") + 1 )) > "$_classify_file"
    echo '{"verdict":"resolved","reason":"fixed"}'
  }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_classify_file")" -eq 0 ]  # zero LLM calls

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  [[ "$_diag_line" == *"closed=0"* ]]
  [[ "$_diag_line" == *"skipped=1"* ]]
}

# ---------------------------------------------------------------------------
# Path 2: Changed file, verdict = resolved → issue closed.
# ---------------------------------------------------------------------------
@test "resolved finding: issue is closed with a comment" {
  local _close_file="${BATS_TEST_TMPDIR}/close_called"
  local _comment_file="${BATS_TEST_TMPDIR}/comment_called"
  echo 0 > "$_close_file"
  echo 0 > "$_comment_file"

  _batch_followups_created() { printf '43\n'; }
  gh_safe() {
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      local _body
      _body=$(_make_body "abc1234" "lib/core/foo.sh:10")
      printf '{"body":"%s","labels":[]}\n' \
        "$(echo "$_body" | sed 's/"/\\"/g; s/$/\\n/g' | tr -d '\n')"
    elif [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
      echo $(( $(cat "$_comment_file") + 1 )) > "$_comment_file"
    elif [ "$1" = "issue" ] && [ "$2" = "close" ]; then
      echo $(( $(cat "$_close_file") + 1 )) > "$_close_file"
    fi
  }
  git() {
    if [ "$1" = "-C" ] && [ "$3" = "cat-file" ]; then
      return 0
    elif [ "$1" = "-C" ] && [ "$3" = "diff" ]; then
      printf 'lib/core/foo.sh\n'  # file changed
    fi
  }
  provider_resolve_model() { printf 'claude-haiku-4-5'; }
  provider_run_prompt() { printf '{"verdict":"resolved","reason":"fixed in PR"}'; }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_comment_file")" -ge 1 ]
  [ "$(cat "$_close_file")" -eq 1 ]

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  [[ "$_diag_line" == *"closed=1"* ]]
  [[ "$_diag_line" == *"annotated=0"* ]]
}

# ---------------------------------------------------------------------------
# Path 3: Changed file, verdict = partially-resolved → annotate, leave open.
# ---------------------------------------------------------------------------
@test "partially-resolved finding: comment posted, issue NOT closed" {
  local _comment_file="${BATS_TEST_TMPDIR}/comment_called"
  local _close_file="${BATS_TEST_TMPDIR}/close_called"
  echo 0 > "$_comment_file"
  echo 0 > "$_close_file"

  _batch_followups_created() { printf '44\n'; }
  gh_safe() {
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      local _body
      _body=$(_make_body "abc1234" "lib/core/foo.sh:10")
      printf '{"body":"%s","labels":[]}\n' \
        "$(echo "$_body" | sed 's/"/\\"/g; s/$/\\n/g' | tr -d '\n')"
    elif [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
      echo $(( $(cat "$_comment_file") + 1 )) > "$_comment_file"
    elif [ "$1" = "issue" ] && [ "$2" = "close" ]; then
      echo $(( $(cat "$_close_file") + 1 )) > "$_close_file"
    fi
  }
  git() {
    if [ "$1" = "-C" ] && [ "$3" = "cat-file" ]; then
      return 0
    elif [ "$1" = "-C" ] && [ "$3" = "diff" ]; then
      printf 'lib/core/foo.sh\n'
    fi
  }
  provider_resolve_model() { printf 'claude-haiku-4-5'; }
  provider_run_prompt() { printf '{"verdict":"partially-resolved","reason":"surface remains"}'; }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_comment_file")" -eq 1 ]
  [ "$(cat "$_close_file")" -eq 0 ]

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  [[ "$_diag_line" == *"annotated=1"* ]]
  [[ "$_diag_line" == *"closed=0"* ]]
}

# ---------------------------------------------------------------------------
# Path 4: Security-labeled issue — resolved verdict posts comment only.
# ---------------------------------------------------------------------------
@test "security label: resolved verdict posts comment but does NOT close" {
  local _comment_file="${BATS_TEST_TMPDIR}/comment_called"
  local _close_file="${BATS_TEST_TMPDIR}/close_called"
  echo 0 > "$_comment_file"
  echo 0 > "$_close_file"

  _batch_followups_created() { printf '45\n'; }
  gh_safe() {
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      local _body
      _body=$(_make_body "abc1234" "lib/core/auth.sh:55")
      # labels includes "security"
      printf '{"body":"%s","labels":["security","review-follow-up"]}\n' \
        "$(echo "$_body" | sed 's/"/\\"/g; s/$/\\n/g' | tr -d '\n')"
    elif [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
      echo $(( $(cat "$_comment_file") + 1 )) > "$_comment_file"
    elif [ "$1" = "issue" ] && [ "$2" = "close" ]; then
      echo $(( $(cat "$_close_file") + 1 )) > "$_close_file"
    fi
  }
  git() {
    if [ "$1" = "-C" ] && [ "$3" = "cat-file" ]; then
      return 0
    elif [ "$1" = "-C" ] && [ "$3" = "diff" ]; then
      printf 'lib/core/auth.sh\n'
    fi
  }
  provider_resolve_model() { printf 'claude-haiku-4-5'; }
  provider_run_prompt() { printf '{"verdict":"resolved","reason":"auth check fixed"}'; }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_comment_file")" -eq 1 ]  # comment posted
  [ "$(cat "$_close_file")" -eq 0 ]    # NEVER closed

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  # security-resolved counts as annotated (comment-only), not closed
  [[ "$_diag_line" == *"closed=0"* ]]
  [[ "$_diag_line" == *"annotated=1"* ]]
}

# ---------------------------------------------------------------------------
# Pre-#1547: missing markers → silently skipped.
# ---------------------------------------------------------------------------
@test "missing markers: issue silently skipped, zero LLM calls" {
  local _classify_file="${BATS_TEST_TMPDIR}/classify_calls"
  echo 0 > "$_classify_file"

  _batch_followups_created() { printf '46\n'; }
  gh_safe() {
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      # No finding markers in body
      printf '{"body":"Some old follow-up with no markers.","labels":[]}\n'
    fi
  }
  git() { printf ''; }
  provider_resolve_model() { printf 'claude-haiku-4-5'; }
  provider_run_prompt() {
    echo $(( $(cat "$_classify_file") + 1 )) > "$_classify_file"
    echo '{}'
  }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_classify_file")" -eq 0 ]

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  [[ "$_diag_line" == *"skipped=1"* ]]
}

# ---------------------------------------------------------------------------
# Provider unavailable: list candidates, emit diag, nothing closed.
# ---------------------------------------------------------------------------
@test "provider unavailable (exit 5): candidates listed, nothing closed" {
  local _close_file="${BATS_TEST_TMPDIR}/close_called"
  echo 0 > "$_close_file"

  _batch_followups_created() { printf '47\n'; }
  gh_safe() {
    if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
      local _body
      _body=$(_make_body "abc1234" "lib/core/foo.sh:10")
      printf '{"body":"%s","labels":[]}\n' \
        "$(echo "$_body" | sed 's/"/\\"/g; s/$/\\n/g' | tr -d '\n')"
    elif [ "$1" = "issue" ] && [ "$2" = "close" ]; then
      echo $(( $(cat "$_close_file") + 1 )) > "$_close_file"
    fi
  }
  git() {
    if [ "$1" = "-C" ] && [ "$3" = "cat-file" ]; then
      return 0
    elif [ "$1" = "-C" ] && [ "$3" = "diff" ]; then
      printf 'lib/core/foo.sh\n'  # file changed → would go to classification
    fi
  }
  provider_resolve_model() { printf 'claude-haiku-4-5'; }
  # Simulate cap/unavailable — exit 5
  provider_run_prompt() { return 5; }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_close_file")" -eq 0 ]

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  [[ "$_diag_line" == *"closed=0"* ]]
  [[ "$_diag_line" == *"skipped=1"* ]]
}

# ---------------------------------------------------------------------------
# Opt-out: RITE_BATCH_RECONCILE=false → no gh calls, no diag.
# ---------------------------------------------------------------------------
@test "RITE_BATCH_RECONCILE=false: pass skipped entirely" {
  export RITE_BATCH_RECONCILE="false"
  local _gh_file="${BATS_TEST_TMPDIR}/gh_called"
  echo 0 > "$_gh_file"
  _batch_followups_created() { printf '48\n'; }
  gh_safe() { echo $(( $(cat "$_gh_file") + 1 )) > "$_gh_file"; }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]
  [ "$(cat "$_gh_file")" -eq 0 ]
  # No diag emitted
  local _diag_count
  _diag_count=$(grep -c 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" || true)
  [ "$_diag_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Empty follow-up list: diag emitted with all zeros.
# ---------------------------------------------------------------------------
@test "empty follow-up list: diag emitted with all zeros" {
  _batch_followups_created() { printf ''; }
  # The candidate list also unions every open pool (#1737); without a stub this
  # test reached real GitHub and counted the live pool as skipped=1.
  gh_safe() { return 0; }

  run reconcile_batch_followups
  [ "$status" -eq 0 ]

  local _diag_line
  _diag_line=$(grep 'FOLLOWUP_RECONCILED' "${BATS_TEST_TMPDIR}/diag.log" | tail -1 || true)
  [[ "$_diag_line" == *"closed=0"* ]]
  [[ "$_diag_line" == *"annotated=0"* ]]
  [[ "$_diag_line" == *"verified=0"* ]]
  [[ "$_diag_line" == *"skipped=0"* ]]
}

# ---------------------------------------------------------------------------
# The batch-end call is isolated in a subshell: a crash inside the pass must not
# change the batch's exit code (#1758: set -u death at batch end → exit 1).
# ---------------------------------------------------------------------------
@test "batch-end reconcile call runs in a subshell with a warning fallback" {
  local _src="${RITE_LIB_DIR}/core/batch-process-issues.sh"
  local _block
  _block=$(sed -n '/RITE_BATCH_RECONCILE:-true/,/^fi$/p' "$_src")
  [[ "$_block" == *"("*"reconcile_batch_followups"*")"*"|| _reconcile_rc="* ]]
  [[ "$_block" == *"print_warning"*"reconcile pass failed"* ]]
}

