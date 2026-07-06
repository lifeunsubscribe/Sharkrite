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
#   9. Path 1 false-positive: superstring issue NOT labeled (parent-pr:4070 vs PR #407)
#  10. Path 2 multi-line body: digit-leading body lines do NOT become phantom issues
#  11. Path 2 superstring: source-issue:1000 NOT labeled when searching source-issue:100
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
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: markers.sh uses a function-sentinel guard (declare -f rite_markers_loaded); pre-source stubs are preserved on source.
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

  # Body for issue #350: carries the exact parent-pr:407 marker.
  local _body_350="<!-- ${RITE_MARKER_PARENT_PR}:${pr} -->"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    # Path 1: issue list for parent-pr search → return the follow-up issue
    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      printf '%s\n' "$followup_issue"
      return 0
    fi

    # Path 1 re-verification: issue view returns a body with the exact marker
    if [ "$subcmd" = "issue" ] && [ "$action" = "view" ]; then
      printf '%s\n' "$_body_350"
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
      # Path 2: source-issue:100 search → return only the issue NUMBER.
      # Path 2 now fetches numbers only (no body in jq output) to avoid
      # multi-line body mis-parse; body is retrieved via a separate view call.
      if echo "$_args_str" | grep -qF "${RITE_MARKER_SOURCE_ISSUE}:${src_issue}"; then
        printf '%s\n' "$lineage_followup"
        return 0
      fi
      echo ""
      return 0
    fi

    # Path 2 per-candidate body fetch (and Path 1 re-verification).
    if [ "$subcmd" = "issue" ] && [ "$action" = "view" ]; then
      # Return the lineage body for #348.
      printf '%s\n' "$_lineage_body"
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
      # Path 1: direct search returns #350 (number only)
      if echo "$_args_str" | grep -qF "${RITE_MARKER_PARENT_PR}:${pr}"; then
        echo "$both_hit"
        return 0
      fi
      # Path 2: source-issue search also surfaces #350 (number only — no body
      # in jq output; body is fetched separately via issue view).
      if echo "$_args_str" | grep -qF "${RITE_MARKER_SOURCE_ISSUE}:${src_issue}"; then
        printf '%s\n' "$both_hit"
        return 0
      fi
      echo ""
      return 0
    fi

    # Per-candidate body fetch (Path 1 re-verification and Path 2 re-verify).
    if [ "$subcmd" = "issue" ] && [ "$action" = "view" ]; then
      printf '%s\n' "$_body_350"
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

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Path 1 false-positive rejection — superstring issue NOT labeled
#
# Regression guard for the boundary-anchor fix (finding #1):
# GitHub's search index can return issue #4070 when querying parent-pr:407
# because the colon-tokenization does a substring match.  The per-candidate
# body re-verification must reject #4070 by requiring ([^0-9]|$) after the PR
# number in the anchored grep.
#
# Scenario:
#   - PR #407 merges.
#   - GitHub search returns issue #4070 as a false-positive hit (its body carries
#     sharkrite-parent-pr:4070, NOT sharkrite-parent-pr:407).
#   - The re-verification fetch of #4070 returns that body.
#   - The boundary-anchored grep must reject it — no comment, no label.
# ─────────────────────────────────────────────────────────────────────────────

@test "Path 1 false-positive: superstring issue (parent-pr:4070) is NOT labeled when PR #407 merges" {
  _load_reconcile_fn

  local pr=407
  local false_positive_issue=4070

  local _comments="$RITE_TEST_TMPDIR/comments-t9.txt"
  local _labels="$RITE_TEST_TMPDIR/labels-t9.txt"
  touch "$_comments" "$_labels"

  # Body of issue #4070: carries parent-pr:4070, NOT parent-pr:407.
  local _body_4070="<!-- ${RITE_MARKER_PARENT_PR}:${false_positive_issue} -->"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    # Path 1: search returns the superstring issue as a false-positive hit
    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      printf '%s\n' "$false_positive_issue"
      return 0
    fi

    # Re-verification: issue view returns the body with parent-pr:4070 (not :407)
    if [ "$subcmd" = "issue" ] && [ "$action" = "view" ]; then
      printf '%s\n' "$_body_4070"
      return 0
    fi

    # These must NOT be called — the false-positive must be rejected
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

  # No source-issue arg → lineage path skipped entirely
  _reconcile_followup_issues_on_merge "$pr"

  local _comment_count
  _comment_count=$(grep -c "^${false_positive_issue}$" "$_comments" || true)
  [ "$_comment_count" -eq 0 ] || {
    echo "FAIL: issue #${false_positive_issue} (parent-pr:4070) should NOT be commented when PR #407 merges, got $_comment_count comment(s)"
    cat "$_comments" || true
    false
  }

  local _label_count
  _label_count=$(grep -c "^${false_positive_issue}$" "$_labels" || true)
  [ "$_label_count" -eq 0 ] || {
    echo "FAIL: issue #${false_positive_issue} (parent-pr:4070) should NOT be labeled when PR #407 merges, got $_label_count label call(s)"
    cat "$_labels" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: Path 2 multi-line body — digit-leading body lines do NOT become
#          phantom issues
#
# Regression guard for the multi-line body mis-parse fix:
# The old Path 2 embedded issue bodies inline in the jq output
# ('.[] | "\(.number) \(.body)"'), so a multi-line body produced multiple
# physical lines.  Lines starting with digits were treated as issue numbers,
# causing phantom comment/label calls on unrelated issues.
#
# The fix fetches numbers only from `issue list`, then fetches the body per-
# candidate via `issue view` — exactly as Path 1 does.  This test simulates
# a multi-line body with a digit-leading line (e.g. "100 completed items")
# and verifies only the real follow-up issue (#348) gets processed.
# ─────────────────────────────────────────────────────────────────────────────

@test "Path 2 multi-line body: digit-leading body lines do NOT become phantom issues" {
  _load_reconcile_fn

  local pr=407
  local src_issue=100
  local predecessor_pr=200
  local lineage_followup=348
  # A digit that appears in the body — this would have been treated as a
  # phantom issue number by the old code path.
  local phantom_number=999

  local _comments="$RITE_TEST_TMPDIR/comments-t10.txt"
  local _labels="$RITE_TEST_TMPDIR/labels-t10.txt"
  touch "$_comments" "$_labels"

  # Body of issue #348: multi-line, with a digit-leading line that old code
  # would have mistaken for an issue number.
  local _lineage_body
  _lineage_body="<!-- ${RITE_MARKER_PARENT_PR}:${predecessor_pr} --><!-- ${RITE_MARKER_SOURCE_ISSUE}:${src_issue} -->
${phantom_number} completed items in this follow-up
Some more body text"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      local _args_str="$*"
      # Path 1: no direct hits
      if echo "$_args_str" | grep -qF "${RITE_MARKER_PARENT_PR}:${pr}"; then
        echo ""
        return 0
      fi
      # Path 2: source-issue search returns the lineage issue NUMBER only.
      if echo "$_args_str" | grep -qF "${RITE_MARKER_SOURCE_ISSUE}:${src_issue}"; then
        printf '%s\n' "$lineage_followup"
        return 0
      fi
      echo ""
      return 0
    fi

    # Per-candidate body fetch — returns the multi-line body.
    if [ "$subcmd" = "issue" ] && [ "$action" = "view" ]; then
      printf '%s\n' "$_lineage_body"
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

  # The real follow-up #348 must receive exactly one comment + label.
  local _comment_count
  _comment_count=$(grep -c "^${lineage_followup}$" "$_comments" || true)
  [ "$_comment_count" -eq 1 ] || {
    echo "FAIL: expected 1 comment on issue #${lineage_followup}, got $_comment_count"
    cat "$_comments" || true
    false
  }

  # The phantom number (999) must NOT have been processed.
  local _phantom_comments
  _phantom_comments=$(grep -c "^${phantom_number}$" "$_comments" || true)
  [ "$_phantom_comments" -eq 0 ] || {
    echo "FAIL: digit-leading body line ${phantom_number} was treated as a phantom issue number; got $_phantom_comments comment(s)"
    cat "$_comments" || true
    false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: Path 2 superstring — source-issue:1000 NOT labeled when searching
#          source-issue:100
#
# Regression guard for the Path 2 boundary-anchor fix:
# GitHub's search index returns superstring hits (source-issue:1000 when
# querying source-issue:100).  Path 2's re-verification now uses a
# boundary-anchored grep to reject those hits.
#
# Scenario:
#   - PR #407 merges for source issue #100.
#   - GitHub search returns issue #999 as a false-positive (its body carries
#     sharkrite-source-issue:1000, NOT sharkrite-source-issue:100).
#   - The boundary-anchored grep must reject issue #999 — no comment, no label.
# ─────────────────────────────────────────────────────────────────────────────

@test "Path 2 superstring: source-issue:1000 NOT labeled when searching source-issue:100" {
  _load_reconcile_fn

  local pr=407
  local src_issue=100
  local false_positive_issue=999

  local _comments="$RITE_TEST_TMPDIR/comments-t11.txt"
  local _labels="$RITE_TEST_TMPDIR/labels-t11.txt"
  touch "$_comments" "$_labels"

  # Body of issue #999: carries source-issue:1000, NOT source-issue:100.
  local _body_999="<!-- ${RITE_MARKER_SOURCE_ISSUE}:1000 -->"

  gh_safe() {
    local subcmd="${1:-}"
    local action="${2:-}"

    if [ "$subcmd" = "issue" ] && [ "$action" = "list" ]; then
      local _args_str="$*"
      # Path 1: no direct hits
      if echo "$_args_str" | grep -qF "${RITE_MARKER_PARENT_PR}:${pr}"; then
        echo ""
        return 0
      fi
      # Path 2: search returns the superstring issue as a false-positive number.
      if echo "$_args_str" | grep -qF "${RITE_MARKER_SOURCE_ISSUE}:${src_issue}"; then
        printf '%s\n' "$false_positive_issue"
        return 0
      fi
      echo ""
      return 0
    fi

    # Per-candidate body fetch: returns the :1000 body (the superstring).
    if [ "$subcmd" = "issue" ] && [ "$action" = "view" ]; then
      printf '%s\n' "$_body_999"
      return 0
    fi

    # These must NOT be called — the false-positive must be rejected.
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
  _comment_count=$(grep -c "^${false_positive_issue}$" "$_comments" || true)
  [ "$_comment_count" -eq 0 ] || {
    echo "FAIL: issue #${false_positive_issue} (source-issue:1000) should NOT be commented when searching source-issue:100, got $_comment_count comment(s)"
    cat "$_comments" || true
    false
  }

  local _label_count
  _label_count=$(grep -c "^${false_positive_issue}$" "$_labels" || true)
  [ "$_label_count" -eq 0 ] || {
    echo "FAIL: issue #${false_positive_issue} (source-issue:1000) should NOT be labeled when searching source-issue:100, got $_label_count label call(s)"
    cat "$_labels" || true
    false
  }
}
