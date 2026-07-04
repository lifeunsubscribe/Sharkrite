#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh, lib/utils/labels.sh
# tests/regression/followup-reconcile-on-merge.bats
#
# Regression test for: reconcile follow-up issues when parent PR merges (#824)
#
# Background:
#   Follow-up issues extracted from a PR review are never re-checked when their
#   parent PR merges, so findings fixed in-branch survive as open zombie issues.
#   Live evidence: LeadFlow #348's demanded change merged inside successor PR #407
#   yet #348 stayed open and burned a batch session the same afternoon.
#
# Fix: _reconcile_followup_issues_on_merge PR_NUMBER [SOURCE_ISSUE] in
#      lib/core/merge-pr.sh:
#   1. Enumerates open issues whose body carries sharkrite-parent-pr:<PR> (direct)
#   2. Also covers close-and-restart lineage via sharkrite-source-issue:<N> marker
#      in each follow-up issue body (predecessor PR follow-ups sharing the same
#      source issue are included when SOURCE_ISSUE arg is provided)
#   3. Posts "parent PR #N merged — re-verify this finding against main" comment
#   4. Adds needs-re-triage label to each found issue
#   5. Makes zero extra gh calls when no follow-ups are found (network-light)
#
# Tests in this file:
#   1. Direct match: issue with parent-pr marker gets comment + label
#   2. No follow-ups: zero extra comment/label calls when search returns empty
#   3. Lineage path: follow-up pointing at predecessor PR is included via
#      source-issue arg (close-and-restart scenario)
#   4. Dedup: issue appearing in both direct and lineage hits processed only once
#   5. Static: _reconcile_followup_issues_on_merge function exists in merge-pr.sh
#   6. Static: call site present in merge-pr.sh after follow-up issues section
#   7. Static: format-anchored grep used (BARE_MARKER_GREP compliance)
#   8. Static: needs-re-triage label defined in labels.sh
#
# Verification command:
#   bats tests/regression/followup-reconcile-on-merge.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Suppress print_* helpers before sourcing — they may not be defined at
  # source time and dependencies emit them during load.
  print_info()    { :; }
  print_warning() { :; }
  print_success() { :; }
  print_error()   { :; }
  verbose_info()  { :; }
  _diag()         { :; }

  # Source markers so RITE_MARKER_PARENT_PR / RITE_MARKER_SOURCE_ISSUE are set.
  source "$RITE_LIB_DIR/utils/markers.sh"
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: load _reconcile_followup_issues_on_merge from merge-pr.sh without
# running its script body.
#
# merge-pr.sh has top-level executable code (network calls, arg parsing) that
# must not run during tests.  We extract and eval only the function definition
# using awk, then stub its dependencies (gh_safe, ensure_labels_exist) inline
# per test.
#
# Rationale for eval: the target is static source text from a repo file, not
# variable or command output.  No external input is eval'd.
# ---------------------------------------------------------------------------
_load_reconcile_fn() {
  local _merge_pr_sh="${RITE_REPO_ROOT}/lib/core/merge-pr.sh"
  [ -f "$_merge_pr_sh" ] || { echo "merge-pr.sh not found" >&2; return 1; }

  # Extract the function body using awk.  Stops at the first top-level closing
  # brace (column-0 `}`) after the function header.
  local _fn_text
  _fn_text=$(awk '
    /^_reconcile_followup_issues_on_merge[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^[}]/ { exit }
  ' "$_merge_pr_sh")

  [ -n "$_fn_text" ] || {
    echo "_reconcile_followup_issues_on_merge not found in merge-pr.sh" >&2
    return 1
  }

  # Stub ensure_labels_exist so it does not attempt real gh label calls.
  ensure_labels_exist() { :; }

  # shellcheck disable=SC2116,SC2034
  eval "$_fn_text"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Direct match — issue with sharkrite-parent-pr:<N> gets comment + label
#
# Merged PR #407 has no source-issue lineage arg.  gh issue list returns #350
# for the parent-pr:407 search.  Verify comment + label are posted.
# ─────────────────────────────────────────────────────────────────────────────

@test "direct match: issue with parent-pr marker gets comment and needs-re-triage label" {
  _load_reconcile_fn

  local pr=407
  local followup_issue=350

  local _comments="$RITE_TEST_TMPDIR/comments-t1.txt"
  local _labels="$RITE_TEST_TMPDIR/labels-t1.txt"
  touch "$_comments" "$_labels"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    # Path 1: issue list for parent-pr search → return the follow-up issue
    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      printf '%s\n' "$followup_issue"
      return 0
    fi

    # Record issue comment calls (3rd arg is issue number)
    if [ "$subcmd" = "issue" ] && [ "$action" = "comment" ]; then
      echo "${3:-}" >> "$_comments"
      return 0
    fi

    # Record issue edit --add-label calls (3rd arg is issue number)
    if [ "$subcmd" = "issue" ] && [ "$action" = "edit" ]; then
      echo "${3:-}" >> "$_labels"
      return 0
    fi

    return 0
  }

  # No source-issue arg → lineage path skipped entirely
  _reconcile_followup_issues_on_merge "$pr"

  local _comment_count
  _comment_count=$(grep -c "^${followup_issue}$" "$_comments" || true)
  [ "$_comment_count" -eq 1 ] || {
    echo "FAIL: expected 1 comment on issue #${followup_issue}, got $_comment_count"
    cat "$_comments" || true
    false
  }

  local _label_count
  _label_count=$(grep -c "^${followup_issue}$" "$_labels" || true)
  [ "$_label_count" -eq 1 ] || {
    echo "FAIL: expected 1 label call on issue #${followup_issue}, got $_label_count"
    cat "$_labels" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: No follow-ups — zero comment or label calls when searches return empty
#
# Network-light contract: when gh issue list returns nothing for BOTH paths,
# no comment or label calls are made (early return after dedup step).
# ─────────────────────────────────────────────────────────────────────────────

@test "no follow-ups: zero comment or label calls when searches return empty" {
  _load_reconcile_fn

  local pr=500
  local src=200  # source issue provided to enable lineage path

  local _comment_calls=0
  local _label_calls=0

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    # Both searches (parent-pr and source-issue) return empty
    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      echo ""
      return 0
    fi

    # These must NOT be called when search results are empty
    if [ "$subcmd" = "issue" ] && [ "$action" = "comment" ]; then
      _comment_calls=$(( _comment_calls + 1 ))
      return 0
    fi
    if [ "$subcmd" = "issue" ] && [ "$action" = "edit" ]; then
      _label_calls=$(( _label_calls + 1 ))
      return 0
    fi

    return 0
  }

  _reconcile_followup_issues_on_merge "$pr" "$src"

  [ "$_comment_calls" -eq 0 ] || {
    echo "FAIL: expected zero comment calls, got $_comment_calls (network-light violated)"
    false
  }
  [ "$_label_calls" -eq 0 ] || {
    echo "FAIL: expected zero label calls, got $_label_calls (network-light violated)"
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Lineage path — follow-up pointing at predecessor PR is included via
#         the source-issue arg (close-and-restart scenario)
#
# Scenario:
#   - PR #200 (original) closed and restarted as PR #407.
#   - Follow-up #348 was filed against PR #200: carries sharkrite-parent-pr:200
#     and sharkrite-source-issue:100.
#   - PR #407 merges for source issue #100.
#   - Path 1 (parent-pr:407) returns nothing.
#   - Path 2 (source-issue:100) surfaces #348 — included because its body does
#     NOT carry sharkrite-parent-pr:407.
# Expected: issue #348 receives a comment + label.
# ─────────────────────────────────────────────────────────────────────────────

@test "lineage path: follow-up pointing at predecessor PR is included via source-issue arg" {
  _load_reconcile_fn

  local pr=407
  local src_issue=100        # source issue closed by the merged PR
  local predecessor_pr=200   # the closed predecessor PR
  local lineage_followup=348 # follow-up filed against predecessor

  local _comments="$RITE_TEST_TMPDIR/comments-t3.txt"
  local _labels="$RITE_TEST_TMPDIR/labels-t3.txt"
  touch "$_comments" "$_labels"

  # Body of issue #348: parent-pr points at predecessor #200, not at #407.
  local _lineage_body="<!-- ${RITE_MARKER_PARENT_PR}:${predecessor_pr} --><!-- ${RITE_MARKER_SOURCE_ISSUE}:${src_issue} -->"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      local _args_str="$*"
      # Path 1: parent-pr:407 search → no direct hits
      if echo "$_args_str" | grep -qF "${RITE_MARKER_PARENT_PR}:${pr}"; then
        echo ""
        return 0
      fi
      # Path 2: source-issue:100 search → return the lineage issue
      # Format: "<number> <body>" per --jq '.[] | "\(.number) \(.body)"'
      if echo "$_args_str" | grep -qF "${RITE_MARKER_SOURCE_ISSUE}:${src_issue}"; then
        printf '%s %s\n' "$lineage_followup" "$_lineage_body"
        return 0
      fi
      echo ""
      return 0
    fi

    if [ "$subcmd" = "issue" ] && [ "$action" = "comment" ]; then
      echo "${3:-}" >> "$_comments"
      return 0
    fi
    if [ "$subcmd" = "issue" ] && [ "$action" = "edit" ]; then
      echo "${3:-}" >> "$_labels"
      return 0
    fi

    return 0
  }

  _reconcile_followup_issues_on_merge "$pr" "$src_issue"

  local _comment_count
  _comment_count=$(grep -c "^${lineage_followup}$" "$_comments" || true)
  [ "$_comment_count" -eq 1 ] || {
    echo "FAIL: expected 1 comment on lineage issue #${lineage_followup}, got $_comment_count"
    echo "comments file:"; cat "$_comments" || true
    false
  }

  local _label_count
  _label_count=$(grep -c "^${lineage_followup}$" "$_labels" || true)
  [ "$_label_count" -eq 1 ] || {
    echo "FAIL: expected 1 label call on lineage issue #${lineage_followup}, got $_label_count"
    echo "labels file:"; cat "$_labels" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Dedup — issue in both direct and lineage hits is processed only once
#
# An issue carrying BOTH sharkrite-parent-pr:<merged-PR> AND
# sharkrite-source-issue:<src> appears in Path 1 (direct) AND would appear in
# Path 2 (source-issue search).  The dedup step (sort -un) must ensure only one
# comment + one label call is made.
# ─────────────────────────────────────────────────────────────────────────────

@test "dedup: issue appearing in both direct and lineage hits is processed only once" {
  _load_reconcile_fn

  local pr=407
  local src_issue=100
  # Issue #350 carries BOTH markers — appears in both search paths.
  local both_hit=350

  local _comments="$RITE_TEST_TMPDIR/comments-t4.txt"
  local _labels="$RITE_TEST_TMPDIR/labels-t4.txt"
  touch "$_comments" "$_labels"

  # Body of issue #350: carries parent-pr:407 AND source-issue:100.
  local _body_350="<!-- ${RITE_MARKER_PARENT_PR}:${pr} --><!-- ${RITE_MARKER_SOURCE_ISSUE}:${src_issue} -->"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      local _args_str="$*"
      # Path 1: direct search returns #350
      if echo "$_args_str" | grep -qF "${RITE_MARKER_PARENT_PR}:${pr}"; then
        echo "$both_hit"
        return 0
      fi
      # Path 2: source-issue search also surfaces #350
      if echo "$_args_str" | grep -qF "${RITE_MARKER_SOURCE_ISSUE}:${src_issue}"; then
        printf '%s %s\n' "$both_hit" "$_body_350"
        return 0
      fi
      echo ""
      return 0
    fi

    if [ "$subcmd" = "issue" ] && [ "$action" = "comment" ]; then
      echo "${3:-}" >> "$_comments"
      return 0
    fi
    if [ "$subcmd" = "issue" ] && [ "$action" = "edit" ]; then
      echo "${3:-}" >> "$_labels"
      return 0
    fi

    return 0
  }

  _reconcile_followup_issues_on_merge "$pr" "$src_issue"

  # Exactly ONE comment on #350, not two
  local _comment_count
  _comment_count=$(grep -c "^${both_hit}$" "$_comments" || true)
  [ "$_comment_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 comment on issue #${both_hit} (dedup), got $_comment_count"
    cat "$_comments" || true
    false
  }

  # Exactly ONE label call on #350, not two
  local _label_count
  _label_count=$(grep -c "^${both_hit}$" "$_labels" || true)
  [ "$_label_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 label call on issue #${both_hit} (dedup), got $_label_count"
    cat "$_labels" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Static — _reconcile_followup_issues_on_merge function exists
# ─────────────────────────────────────────────────────────────────────────────

@test "static: _reconcile_followup_issues_on_merge function is defined in merge-pr.sh" {
  grep -q '^_reconcile_followup_issues_on_merge()' \
    "$RITE_REPO_ROOT/lib/core/merge-pr.sh" || {
    echo "FAIL: _reconcile_followup_issues_on_merge() not found in lib/core/merge-pr.sh"
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Static — call site present in merge-pr.sh, positioned correctly
#
# The call must appear AFTER the "Follow-up Issues" display section and BEFORE
# the "Cleanup: branches + worktree" section.
# ─────────────────────────────────────────────────────────────────────────────

@test "static: _reconcile_followup_issues_on_merge is called post-merge with PR_NUMBER" {
  local _merge_pr_sh="$RITE_REPO_ROOT/lib/core/merge-pr.sh"

  # Call must exist with the PR_NUMBER arg
  grep -q '_reconcile_followup_issues_on_merge "\$PR_NUMBER"' "$_merge_pr_sh" || {
    echo "FAIL: no call to _reconcile_followup_issues_on_merge with \$PR_NUMBER in merge-pr.sh"
    false
  }

  # Verify ordering via line numbers: follow-up display < call < cleanup
  local _followup_display_line
  _followup_display_line=$(grep -n 'Follow-up Issues' "$_merge_pr_sh" | head -1 | cut -d: -f1)

  local _call_line
  _call_line=$(grep -n '_reconcile_followup_issues_on_merge "\$PR_NUMBER"' "$_merge_pr_sh" \
    | head -1 | cut -d: -f1)

  local _cleanup_line
  _cleanup_line=$(grep -n 'Cleanup: branches + worktree' "$_merge_pr_sh" | head -1 | cut -d: -f1)

  [ -n "$_followup_display_line" ] || {
    echo "FAIL: could not find 'Follow-up Issues' section in merge-pr.sh"
    false
  }
  [ -n "$_call_line" ] || {
    echo "FAIL: could not find _reconcile_followup_issues_on_merge call in merge-pr.sh"
    false
  }
  [ -n "$_cleanup_line" ] || {
    echo "FAIL: could not find 'Cleanup: branches + worktree' section in merge-pr.sh"
    false
  }

  [ "$_call_line" -gt "$_followup_display_line" ] || {
    echo "FAIL: reconcile call (line $_call_line) must be after Follow-up Issues section (line $_followup_display_line)"
    false
  }
  [ "$_call_line" -lt "$_cleanup_line" ] || {
    echo "FAIL: reconcile call (line $_call_line) must be before Cleanup section (line $_cleanup_line)"
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Static — format-anchored grep (BARE_MARKER_GREP compliance)
#
# Per the BARE_MARKER_GREP rule: outer grep guards for sharkrite markers must
# include [0-9]+ to prevent bare-prefix false matches on documentation examples.
# Verifies the function's source-issue outer guard uses grep -qE with [0-9]+.
# ─────────────────────────────────────────────────────────────────────────────

@test "static: format-anchored grep used for marker detection in _reconcile_followup_issues_on_merge" {
  local _merge_pr_sh="$RITE_REPO_ROOT/lib/core/merge-pr.sh"

  # Extract the function body for scoped checks.
  local _fn_body
  _fn_body=$(awk '
    /^_reconcile_followup_issues_on_merge[(][)]/ { in_fn=1 }
    in_fn { print }
    in_fn && /^[}]/ { exit }
  ' "$_merge_pr_sh")

  [ -n "$_fn_body" ] || {
    echo "FAIL: could not extract _reconcile_followup_issues_on_merge body"
    false
  }

  # The format-anchored guard for the lineage path must use grep -qE with [0-9]+.
  # This prevents bare-prefix matches on doc examples (e.g. "sharkrite-source-issue:N").
  echo "$_fn_body" | grep -qE 'grep -qE.*\[0-9\]\+' || {
    echo "FAIL: _reconcile_followup_issues_on_merge does not use format-anchored grep -qE with [0-9]+"
    echo "      The BARE_MARKER_GREP rule requires a digit anchor to prevent doc-placeholder matches."
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Static — needs-re-triage label defined in labels.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "static: needs-re-triage label is defined in lib/utils/labels.sh" {
  grep -q 'needs-re-triage' "$RITE_REPO_ROOT/lib/utils/labels.sh" || {
    echo "FAIL: 'needs-re-triage' label not found in lib/utils/labels.sh"
    false
  }
}
