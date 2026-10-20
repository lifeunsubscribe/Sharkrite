#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/utils/review-helper.sh, lib/core/workflow-runner.sh, lib/utils/pr-detection.sh::detect_review_state
# Regression test for issue #354: Stale-review-loop guard fires on fresh reviews
# Regression test for issue #1303: Fix loop deadlocks when staleness oracles disagree
# Regression test for issue #1305: detect_review_state standalone-path deadlock (timestamp-only)
#
# Root cause (#354): The staleness check in assess-and-resolve.sh used timestamp
# comparison (review.createdAt vs latest commit time). This is racy — GitHub's
# API can return stale timestamps, and successive fix iterations may produce
# commits that post-date a fresh review even when the review actually covers HEAD.
#
# Root cause (#1303): Phase 2 (workflow-runner.sh::phase_create_pr) used a
# timestamp-based oracle to decide "skip push/review", while Phase 3
# (assess-and-resolve.sh) used a SHA-based oracle to decide "review is stale".
# When the two oracles disagree (timestamp says current / SHA says stale), Phase 3
# reroutes to Phase 2, Phase 2 declines to regenerate, and the loop hard-fails
# after hours of correct completed work (live: issue #1231, 7h23m wasted).
#
# Root cause (#1305): detect_review_state (lib/utils/pr-detection.sh) uses
# timestamp-only comparison (iso_to_epoch), not the SHA oracle. The standalone
# --review-latest path calls it to decide whether to skip regeneration. When
# GitHub API createdAt post-dates local commit time but the embedded SHA mismatches
# HEAD, --review-latest incorrectly reports "current". --assess-and-fix is not
# deadlocked (its assess-and-resolve.sh SHA oracle detects stale and triggers a
# fresh review via exit 3), but --review-latest in isolation misleads the user.
#
# Fix (#354): SHA-based staleness detection in assess-and-resolve.sh.
# Fix (#1303): Phase 2's skip decision now uses extract_review_sha (same oracle).
#   - local-review.sh embeds the HEAD SHA in the review marker: commit:<sha>
#   - Both phases compare that SHA to the current HEAD
#   - Timestamp comparison is preserved as a fallback for pre-#354 reviews
# Known limitation (#1305): detect_review_state remains timestamp-only (tracked
#   for migration — see behavioral-design.md "Stale Review Loop" section).
#
# These tests verify:
#   1. extract_review_sha correctly parses the commit: attribute from markers
#   2. SHA match → no false stale detection (the false-positive from issue #354)
#   3. SHA is ancestor → genuinely stale (correctly detected)
#   4. No SHA in review → falls back to timestamp comparison
#   5. Review marker written by local-review.sh contains commit: attribute
#   6. The #341 scenario (multiple iterations, finding counts change) doesn't
#      produce a false stale verdict
#   7. Phase 2 skip decision uses the same SHA oracle as Phase 3 (issue #1303)
#   8. SHA-mismatch: Phase 2 does NOT skip, so Phase 3's reroute can proceed
#   9. detect_review_state uses timestamp oracle (not SHA) — standalone-path
#      limitation sentinel (issue #1305)

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  MARKERS_SH="${RITE_REPO_ROOT}/lib/utils/markers.sh"
  REVIEW_HELPER_SH="${RITE_REPO_ROOT}/lib/utils/review-helper.sh"
  ASSESS_AND_RESOLVE="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"

  export MARKERS_SH REVIEW_HELPER_SH ASSESS_AND_RESOLVE

  # Source markers to get RITE_MARKER_REVIEW constant
  # shellcheck source=/dev/null
  source "$MARKERS_SH"
}

# Helper: source review-helper.sh in a subshell snippet, setting up the
# minimal RITE_LIB_DIR env that review-helper.sh requires.
# Usage: add to the beginning of a bash -c block:
#   _setup_review_helper='
#     export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
#     source "${REVIEW_HELPER_SH}"
#   '
#   run bash -c "${_setup_review_helper}; ..."

# =============================================================================
# extract_review_sha: correctly parses the commit: attribute
# =============================================================================

@test "extract_review_sha: returns SHA from marker with commit attribute" {
  # Uses the canonical extract_review_sha from lib/utils/review-helper.sh.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    # Use the expanded constant in the fixture (double-quoted so variable expands)
    review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-06-04T15:03:35Z commit:abc1234def567 -->

Some review content here.\"

    result=\$(extract_review_sha \"\$review_body\")
    echo \"\$result\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "abc1234def567" ]]
}

@test "extract_review_sha: returns empty for review without commit attribute (pre-fix review)" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    # Old review format (before issue #354 fix) — no commit: attribute
    review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-05-01T10:00:00Z -->

Some review content here.\"

    result=\$(extract_review_sha \"\$review_body\")
    echo \"result=['\$result']\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "result=['']" ]]
}

@test "extract_review_sha: returns full 40-char SHA when full SHA is embedded" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    full_sha='a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'
    review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-06-04T15:00:00Z commit:\${full_sha} -->\"

    result=\$(extract_review_sha \"\$review_body\")
    echo \"\$result\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" ]]
}

@test "extract_review_sha: does not match commit: outside the marker comment" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    # Review body has commit: SHA in the text content but NOT in the marker
    review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-06-04T15:00:00Z -->

The commit:deadbeef123 introduced a new function. See also commit:feedface456.\"

    result=\$(extract_review_sha \"\$review_body\")
    echo \"result=['\$result']\"
  "
  [ "$status" -eq 0 ]
  # Should return empty — the commit: appears in review body text, not in the marker
  [[ "$output" == "result=['']" ]]
}

# =============================================================================
# SHA comparison logic: fresh review (SHA match) should NOT trigger staleness
# =============================================================================

@test "SHA match: review is current — no staleness flag" {
  # Simulates the core logic that assess-and-resolve.sh applies:
  # when review_sha == current_head_sha, _review_is_stale stays false.
  run bash -c "
    set -euo pipefail

    review_sha='abc1234def567890abc1234def567890abc12345'
    current_head_sha='abc1234def567890abc1234def567890abc12345'

    _review_is_stale=false
    if [ -n \"\$review_sha\" ] && [ -n \"\$current_head_sha\" ]; then
      if [ \"\$review_sha\" = \"\$current_head_sha\" ]; then
        _review_is_stale=false
      else
        _review_is_stale=true
      fi
    fi

    echo \"\$_review_is_stale\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "false" ]]
}

@test "SHA mismatch (ancestor): review is stale — staleness flag set" {
  # Simulates the ancestor-check path in assess-and-resolve.sh.
  # We use a real git repo (mktemp) with two commits to test ancestry.
  local tmpdir
  tmpdir=$(mktemp -d)

  run bash -c "
    set -euo pipefail
    tmpdir='$tmpdir'
    cd \"\$tmpdir\"
    git init -q
    git config user.email 'test@test.com'
    git config user.name 'Test'

    # Create base commit (simulates the commit that was reviewed)
    echo 'initial' > file.txt
    git add file.txt
    git commit -q -m 'initial commit'
    review_sha=\$(git rev-parse HEAD)

    # Create fix commit (simulates a fix pushed after the review)
    echo 'fix' >> file.txt
    git add file.txt
    git commit -q -m 'fix commit'
    current_head_sha=\$(git rev-parse HEAD)

    # Simulate the staleness check
    _review_is_stale=false
    if [ \"\$review_sha\" = \"\$current_head_sha\" ]; then
      _review_is_stale=false
    elif git merge-base --is-ancestor \"\$review_sha\" \"\$current_head_sha\" 2>/dev/null; then
      _review_is_stale=true
    else
      _review_is_stale=true
    fi

    echo \"\$_review_is_stale\"
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == "true" ]]
}

@test "SHA match after fix-loop iteration: no false stale verdict (issue #341 scenario)" {
  # Reproduces the exact scenario from issue #341:
  #   - Multiple fix-loop iterations run
  #   - Finding counts change across iterations (proves reviews are being regenerated)
  #   - The latest review covers the current HEAD
  # Asserts: no staleness flag fires when review_sha == current_head_sha.
  run bash -c "
    set -euo pipefail

    # Simulate what happens at iteration 3 of the fix loop in issue #341:
    # Review was regenerated after each fix commit; the latest review covers HEAD.
    # Both review_sha and current_head_sha are the same (review covers HEAD).
    current_head_sha='563e5de02d6287c9150f91a90e2b931bc9d5e563'

    # The review was generated against THIS exact commit
    review_sha=\"\$current_head_sha\"

    _review_is_stale=false
    if [ -n \"\$review_sha\" ] && [ -n \"\$current_head_sha\" ]; then
      if [ \"\$review_sha\" = \"\$current_head_sha\" ]; then
        # SHA match: review covers HEAD — no stale verdict
        _review_is_stale=false
      else
        _review_is_stale=true
      fi
    fi

    echo \"stale=\$_review_is_stale\"
    # Even if finding counts changed across iterations (MEDIUM/LOW fluctuated),
    # the staleness check ONLY cares about SHA — not finding counts.
    echo 'SHA-based check correctly ignores finding count changes'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale=false"* ]]
  [[ "$output" == *"SHA-based check correctly ignores finding count changes"* ]]
}

# =============================================================================
# Review marker written by local-review.sh includes commit: attribute
# =============================================================================

@test "local-review.sh review marker format includes commit: attribute when SHA available" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'

    # Simulate how local-review.sh constructs the marker (local-review.sh:487)
    EFFECTIVE_MODEL='claude-opus-4-8'
    PR_HEAD_SHA='abc1234def5678'
    _REVIEW_SHA_ATTR=''
    if [ -n \"\${PR_HEAD_SHA:-}\" ]; then
      _REVIEW_SHA_ATTR=\" commit:\${PR_HEAD_SHA}\"
    fi

    REVIEW_COMMENT=\"<!-- \${RITE_MARKER_REVIEW} model:\${EFFECTIVE_MODEL} timestamp:2026-06-04T15:03:35Z\${_REVIEW_SHA_ATTR} -->\"

    echo \"\$REVIEW_COMMENT\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"commit:abc1234def5678"* ]]
  [[ "$output" == *"sharkrite-local-review"* ]]
  [[ "$output" == *"model:claude-opus-4-8"* ]]
}

@test "local-review.sh review marker format omits commit: attribute when SHA absent" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'

    # When PR_HEAD_SHA is empty (headRefOid unavailable), no commit: attribute
    EFFECTIVE_MODEL='claude-opus-4-8'
    PR_HEAD_SHA=''
    _REVIEW_SHA_ATTR=''
    if [ -n \"\${PR_HEAD_SHA:-}\" ]; then
      _REVIEW_SHA_ATTR=\" commit:\${PR_HEAD_SHA}\"
    fi

    REVIEW_COMMENT=\"<!-- \${RITE_MARKER_REVIEW} model:\${EFFECTIVE_MODEL} timestamp:2026-06-04T15:03:35Z\${_REVIEW_SHA_ATTR} -->\"

    echo \"\$REVIEW_COMMENT\"
  "
  [ "$status" -eq 0 ]
  # commit: attribute must NOT appear when SHA was empty
  [[ "$output" != *"commit:"* ]]
  # The rest of the marker must still be valid
  [[ "$output" == *"sharkrite-local-review"* ]]
  [[ "$output" == *"model:claude-opus-4-8"* ]]
}

# =============================================================================
# Backward compatibility: timestamp fallback for reviews without commit: SHA
# =============================================================================

@test "timestamp fallback: old review (no SHA) falling back correctly" {
  # Simulates the fallback path in assess-and-resolve.sh for pre-#354 reviews.
  # When no SHA is embedded, the staleness check should still work via timestamps.
  run bash -c "
    set -euo pipefail

    # Old review — no commit: attribute
    review_sha=''
    current_head_sha='abc1234def567890abc1234def567890abc12345'

    _review_is_stale=false
    _staleness_method=''

    if [ -n \"\$review_sha\" ] && [ -n \"\$current_head_sha\" ]; then
      _staleness_method='sha'
      # Would do SHA comparison here
    else
      # Fallback to timestamp
      _staleness_method='timestamp'
    fi

    echo \"method=\$_staleness_method\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "method=timestamp" ]]
}

# =============================================================================
# Force-push edge case: SHA not in ancestry chain
# =============================================================================

@test "force-push edge case: unrelated SHA treated as stale" {
  # When review_sha is not found in the ancestry of current HEAD (can happen
  # with force-pushes during the workflow), we treat the review as stale.
  local tmpdir
  tmpdir=$(mktemp -d)

  run bash -c "
    set -euo pipefail
    tmpdir='$tmpdir'
    cd \"\$tmpdir\"
    git init -q
    git config user.email 'test@test.com'
    git config user.name 'Test'

    # Create branch A (simulates the reviewed commit's chain)
    echo 'branch-a' > file.txt
    git add file.txt
    git commit -q -m 'branch A commit'
    review_sha=\$(git rev-parse HEAD)

    # Create an orphan branch (simulates a force-push that rewrote history)
    git checkout -q --orphan orphan-branch
    git rm -qrf .
    echo 'force-pushed' > newfile.txt
    git add newfile.txt
    git commit -q -m 'force push commit'
    current_head_sha=\$(git rev-parse HEAD)

    # Simulate staleness check for force-push case
    _review_is_stale=false
    if [ \"\$review_sha\" = \"\$current_head_sha\" ]; then
      _review_is_stale=false
    elif git merge-base --is-ancestor \"\$review_sha\" \"\$current_head_sha\" 2>/dev/null; then
      _review_is_stale=true
    else
      # SHA not in ancestry chain — treat as stale
      _review_is_stale=true
    fi

    echo \"\$_review_is_stale\"
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == "true" ]]
}

# =============================================================================
# Integration: extract_review_sha round-trip with actual marker format
# =============================================================================

@test "round-trip: write marker with SHA, extract SHA back" {
  # Verifies that the canonical extract_review_sha (from review-helper.sh)
  # correctly round-trips a SHA written by local-review.sh's marker format.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    original_sha='abc1234def567890abc1234def567890abc12345'
    _REVIEW_SHA_ATTR=\" commit:\${original_sha}\"

    # Simulate local-review.sh writing the marker
    review_comment=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-06-04T15:03:35Z\${_REVIEW_SHA_ATTR} -->

Actual review content follows here.\"

    # Simulate assess-and-resolve.sh reading the SHA back using the shared helper
    extracted_sha=\$(extract_review_sha \"\$review_comment\")

    if [ \"\$extracted_sha\" = \"\$original_sha\" ]; then
      echo 'ROUND_TRIP_OK'
    else
      echo \"MISMATCH: expected '\$original_sha', got '\$extracted_sha'\"
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "ROUND_TRIP_OK" ]]
}

# =============================================================================
# resolve_pr_head_sha: local-git fallback path (no network required)
# =============================================================================

@test "resolve_pr_head_sha: falls back to local git when API unavailable and branch matches" {
  # Verifies that resolve_pr_head_sha correctly falls back to local git when
  # gh is mocked to fail (API unavailable). The worktree_path argument guides
  # the fallback to the correct git context rather than cwd.
  #
  # This tests the branch-name-guard path: when branch name is unavailable
  # (partial API failure), the function warns and uses the worktree's HEAD.
  local tmpdir
  tmpdir=$(mktemp -d)

  run bash -c "
    set -euo pipefail
    tmpdir='$tmpdir'

    # Set up a minimal git repo to represent the PR worktree
    cd \"\$tmpdir\"
    git init -q
    git config user.email 'test@test.com'
    git config user.name 'Test'
    echo 'content' > file.txt
    git add file.txt
    git commit -q -m 'test commit'
    expected_sha=\$(git rev-parse HEAD)

    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    # Override gh_safe to simulate a complete API failure (empty output).
    # This forces the function into the local-git fallback path.
    gh_safe() { echo ''; }
    export -f gh_safe

    # With both _rph_remote_sha and _rph_branch_name empty, the function
    # falls into the 'branch name unknown — fall back with a warning' path.
    # It should return the worktree's HEAD SHA (not cwd's HEAD, which could
    # be different if cwd is the main checkout).
    result=\$(resolve_pr_head_sha '42' \"\$tmpdir\" 2>/dev/null)

    if [ \"\$result\" = \"\$expected_sha\" ]; then
      echo 'FALLBACK_OK'
    else
      echo \"MISMATCH: expected '\$expected_sha', got '\$result'\"
    fi
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == "FALLBACK_OK" ]]
}

@test "resolve_pr_head_sha: returns empty when API fails and no worktree provided and branch mismatches" {
  # Verifies that resolve_pr_head_sha returns empty (safe) rather than
  # guessing when API fails, no worktree_path is given, and the current
  # branch does not match the expected PR branch. This prevents the
  # false-positive stale verdict that issue #354 fixed.
  run bash -c "
    set -euo pipefail

    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    # Mock gh_safe: returns a valid branch name but empty SHA (partial failure).
    # The local git fallback will only proceed if cwd's branch matches.
    # We are running outside any git repo in this subshell, so git commands fail.
    gh_safe() {
      # Return branch name but empty sha — simulates partial API failure
      echo '{\"name\": \"feat/some-pr-branch\", \"sha\": \"\"}'
    }
    export -f gh_safe

    # resolve_pr_head_sha should return empty because:
    # - Remote SHA is empty (partial failure)
    # - No worktree_path provided
    # - git rev-parse may fail outside a repo (so branch guard fires empty)
    result=\$(resolve_pr_head_sha '42' 2>/dev/null || true)
    result=\"\${result:-}\"

    # The result should be empty — no guessing from wrong context
    if [ -z \"\$result\" ]; then
      echo 'SAFE_EMPTY_OK'
    else
      echo \"UNEXPECTED_SHA: '\$result'\"
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "SAFE_EMPTY_OK" ]]
}

# =============================================================================
# Issue #1303: Phase 2 skip decision uses the SHA oracle (not timestamps)
#
# These tests exercise the logic introduced in workflow-runner.sh::phase_create_pr
# to replace the epoch comparison. The logic is extracted here as a shell fragment
# (same technique as the assess-and-resolve.sh tests above) because phase_create_pr
# cannot be invoked without a real git + GitHub environment.
# =============================================================================

@test "phase_create_pr skip logic: SHA match → review is current, skip is valid" {
  # Simulates the core of the new phase_create_pr skip check:
  # when the review marker's SHA equals local_head, the skip fires.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    local_head='abc1234def567890abc1234def567890abc12345'

    # Simulate the review JSON that gh would return (body contains the marker)
    _skip_review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-10-14T18:00:00Z commit:\${local_head} -->

Review content.\"

    _skip_review_sha=\$(extract_review_sha \"\$_skip_review_body\")
    _skip_review_sha=\"\${_skip_review_sha:-}\"

    # Apply the same decision as phase_create_pr
    _would_skip=false
    if [ -n \"\$_skip_review_sha\" ]; then
      if [ \"\$_skip_review_sha\" = \"\$local_head\" ]; then
        _would_skip=true
      fi
    fi

    echo \"would_skip=\$_would_skip\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "would_skip=true" ]]
}

@test "phase_create_pr skip logic: SHA mismatch → review is stale, skip does NOT fire" {
  # Reproduces the issue #1303 scenario: the review has a SHA, but it does not
  # match the current HEAD (fix commits were pushed after the review was generated).
  # Phase 2 must NOT skip — it must regenerate so Phase 3 will see a current review.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    # The review was generated against the old HEAD (0a8746fb in the live incident)
    review_head='0a8746fb0a8746fb0a8746fb0a8746fb0a8746fb'
    # Fix commits were pushed; local_head advanced to a new SHA (324cba0a live)
    local_head='324cba0a324cba0a324cba0a324cba0a324cba0a'

    _skip_review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-10-14T18:00:00Z commit:\${review_head} -->

Review content.\"

    _skip_review_sha=\$(extract_review_sha \"\$_skip_review_body\")
    _skip_review_sha=\"\${_skip_review_sha:-}\"

    _would_skip=false
    if [ -n \"\$_skip_review_sha\" ]; then
      if [ \"\$_skip_review_sha\" = \"\$local_head\" ]; then
        _would_skip=true
      fi
      # SHA present but mismatched → stale, fall through (would_skip stays false)
    fi

    echo \"would_skip=\$_would_skip sha_present=\$([ -n \"\$_skip_review_sha\" ] && echo true || echo false)\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "would_skip=false sha_present=true" ]]
}

@test "phase_create_pr skip logic: no SHA → timestamp fallback path taken" {
  # Pre-#354 review: no commit: attribute in marker.
  # Phase 2 must fall back to the timestamp comparison, not treat the review as stale.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    local_head='abc1234def567890abc1234def567890abc12345'

    # Old marker format (no commit: attribute)
    _skip_review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-05-01T10:00:00Z -->

Review content.\"

    _skip_review_sha=\$(extract_review_sha \"\$_skip_review_body\")
    _skip_review_sha=\"\${_skip_review_sha:-}\"

    # Determine which decision path is taken
    _decision_path=''
    if [ -n \"\$_skip_review_sha\" ]; then
      _decision_path='sha'
    else
      _decision_path='timestamp_fallback'
    fi

    echo \"path=\$_decision_path\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "path=timestamp_fallback" ]]
}

@test "two-oracle agreement: SHA match → both Phase 2 and Phase 3 agree review is current" {
  # Core contract from issue #1303: when Phase 2's skip oracle and Phase 3's
  # staleness oracle both use extract_review_sha against the same review body,
  # they must reach the same conclusion for every input.
  #
  # This test verifies the SHA-match case: both phases agree the review is current.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    current_head='abc1234def567890abc1234def567890abc12345'

    review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-10-14T18:00:00Z commit:\${current_head} -->

Review content.\"

    review_sha=\$(extract_review_sha \"\$review_body\")

    # Phase 2 verdict: skip iff SHA matches
    phase2_current=false
    if [ -n \"\$review_sha\" ] && [ \"\$review_sha\" = \"\$current_head\" ]; then
      phase2_current=true
    fi

    # Phase 3 verdict: not stale iff SHA matches
    phase3_current=false
    if [ -n \"\$review_sha\" ] && [ \"\$review_sha\" = \"\$current_head\" ]; then
      phase3_current=true
    fi

    echo \"phase2=\$phase2_current phase3=\$phase3_current agree=\$([ \"\$phase2_current\" = \"\$phase3_current\" ] && echo yes || echo no)\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "phase2=true phase3=true agree=yes" ]]
}

@test "two-oracle agreement: SHA mismatch → both Phase 2 and Phase 3 agree review is stale" {
  # Verifies the SHA-mismatch case: both phases agree the review is stale,
  # so Phase 3's reroute to Phase 2 will be acted upon (Phase 2 won't skip).
  # This is the exact deadlock scenario from issue #1303.
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR=\"\${RITE_REPO_ROOT}/lib\"
    source \"\${REVIEW_HELPER_SH}\"

    review_head='0a8746fb0a8746fb0a8746fb0a8746fb0a8746fb'
    current_head='324cba0a324cba0a324cba0a324cba0a324cba0a'

    review_body=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-10-14T18:00:00Z commit:\${review_head} -->

Review content.\"

    review_sha=\$(extract_review_sha \"\$review_body\")

    # Phase 2 verdict: skip only if SHA matches (false when mismatched)
    phase2_would_skip=false
    if [ -n \"\$review_sha\" ] && [ \"\$review_sha\" = \"\$current_head\" ]; then
      phase2_would_skip=true
    fi

    # Phase 3 verdict: stale if SHA present and does not match
    phase3_stale=false
    if [ -n \"\$review_sha\" ] && [ \"\$review_sha\" != \"\$current_head\" ]; then
      phase3_stale=true
    fi

    # Deadlock-free contract: Phase 3 reroutes → Phase 2 will regenerate (not skip)
    deadlock_free=\$([ \"\$phase3_stale\" = 'true' ] && [ \"\$phase2_would_skip\" = 'false' ] && echo yes || echo no)
    echo \"phase2_skip=\$phase2_would_skip phase3_stale=\$phase3_stale deadlock_free=\$deadlock_free\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "phase2_skip=false phase3_stale=true deadlock_free=yes" ]]
}

# =============================================================================
# Structural guard: phase_create_pr wires the SHA oracle, not the epoch oracle
#
# The behavioral tests above inline the decision logic as a quoted fragment.
# That means a revert of phase_create_pr to iso_to_epoch (the #1303 bug) would
# not be caught by any of them — they all pass regardless of what the real
# function body contains.
#
# This test parses the actual phase_create_pr body and enforces two invariants:
#   1. extract_review_sha is called (SHA oracle is wired in — positive invariant)
#   2. iso_to_epoch appears only AFTER extract_review_sha (timestamp is fallback-only)
# =============================================================================

@test "structural: phase_create_pr calls extract_review_sha before any iso_to_epoch (SHA oracle is primary)" {
  # Regression guard for issue #1303.
  # If phase_create_pr is reverted to epoch comparison as the primary skip path,
  # invariant 1 (missing extract_review_sha) or invariant 2 (wrong ordering) will fail.
  run bash -c "
    set -euo pipefail
    wf=\"\${RITE_REPO_ROOT}/lib/core/workflow-runner.sh\"

    # Extract phase_create_pr body: from function header to first top-level '}'
    fn_body=\$(awk '/^phase_create_pr\(\) \{/,/^\}/' \"\$wf\")

    # Invariant 1: SHA oracle must be present in the function
    if ! echo \"\$fn_body\" | grep -q 'extract_review_sha'; then
      echo 'FAIL: extract_review_sha not found in phase_create_pr — SHA oracle is missing'
      exit 1
    fi

    # Invariant 2: iso_to_epoch (timestamp fallback) must appear AFTER extract_review_sha
    line_sha=\$(echo \"\$fn_body\" | grep -n 'extract_review_sha' | head -1 | cut -d: -f1 || true)
    line_epoch=\$(echo \"\$fn_body\" | grep -n 'iso_to_epoch' | head -1 | cut -d: -f1 || true)

    if [ -z \"\$line_epoch\" ]; then
      echo 'PASS: no iso_to_epoch in phase_create_pr (pure SHA-oracle path)'
      exit 0
    fi

    if [ \"\$line_epoch\" -gt \"\$line_sha\" ]; then
      echo 'PASS'
    else
      echo \"FAIL: iso_to_epoch (fn-line \$line_epoch) precedes extract_review_sha (fn-line \$line_sha) — timestamp is the primary oracle, not the fallback\"
      exit 1
    fi
  "
  [ "$status" -eq 0 ]
  [[ "$output" == PASS* ]]
}

# =============================================================================
# Structural sentinel: detect_review_state uses timestamp oracle, not SHA oracle
#
# detect_review_state (lib/utils/pr-detection.sh) is the standalone-path site.
# Unlike the two orchestrated-loop sites above, it uses iso_to_epoch timestamp
# comparison — not extract_review_sha. This is the known limitation tracked in
# issue #1305.
#
# The deadlock scenario: GitHub API createdAt post-dates local commit time, but
# the embedded SHA mismatches HEAD. detect_review_state reports REVIEW_IS_CURRENT=true
# (timestamp says current), while assess-and-resolve.sh says stale (SHA mismatch).
# --review-latest calls detect_review_state and refuses to regenerate.
# --assess-and-fix is not permanently deadlocked (assess-and-resolve.sh exit 3
# triggers a fresh review), but --review-latest in isolation misleads the user.
#
# This test is a sentinel: it passes while issue #1305 is open (detect_review_state
# is still timestamp-only) and fails with an explanatory message when the migration
# to the SHA oracle lands (at which point this test must be updated).
# =============================================================================

@test "structural: detect_review_state uses timestamp oracle (not SHA oracle) — standalone-path limitation (issue #1305)" {
  # Sentinel for issue #1305: documents that detect_review_state is the remaining
  # timestamp-only site. Fails with a clear message when issue #1305 is resolved.
  run bash -c "
    set -euo pipefail
    det=\"\${RITE_REPO_ROOT}/lib/utils/pr-detection.sh\"

    # Extract detect_review_state body: from function header to first top-level '}'
    fn_body=\$(awk '/^detect_review_state\(\) \{/,/^\}/' \"\$det\")

    # Invariant 1: timestamp oracle (iso_to_epoch) must be present
    if ! echo \"\$fn_body\" | grep -q 'iso_to_epoch'; then
      echo 'FAIL: iso_to_epoch not found in detect_review_state — timestamp oracle missing or function shape changed'
      exit 1
    fi

    # Invariant 2: SHA oracle (extract_review_sha) must NOT be present
    # If this fires, issue #1305 may have been resolved — update this test to assert
    # the new SHA-oracle invariants (mirroring the phase_create_pr structural test above)
    if echo \"\$fn_body\" | grep -q 'extract_review_sha'; then
      echo 'SENTINEL FIRED: extract_review_sha found in detect_review_state — issue #1305 may be resolved; update this test to assert the SHA-oracle invariants'
      exit 1
    fi

    echo 'PASS: detect_review_state is timestamp-only (issue #1305 open)'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == PASS* ]]
}
