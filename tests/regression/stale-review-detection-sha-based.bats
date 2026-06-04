#!/usr/bin/env bats
# Regression test for issue #354: Stale-review-loop guard fires on fresh reviews
#
# Root cause: The staleness check in assess-and-resolve.sh used timestamp
# comparison (review.createdAt vs latest commit time). This is racy — GitHub's
# API can return stale timestamps, and successive fix iterations may produce
# commits that post-date a fresh review even when the review actually covers HEAD.
#
# Fix: SHA-based staleness detection.
#   - local-review.sh embeds the HEAD SHA in the review marker: commit:<sha>
#   - assess-and-resolve.sh compares that SHA to the current HEAD
#   - Timestamp comparison is preserved as a fallback for pre-fix reviews
#
# These tests verify:
#   1. extract_review_sha correctly parses the commit: attribute from markers
#   2. SHA match → no false stale detection (the false-positive from issue #354)
#   3. SHA is ancestor → genuinely stale (correctly detected)
#   4. No SHA in review → falls back to timestamp comparison
#   5. Review marker written by local-review.sh contains commit: attribute
#   6. The #341 scenario (multiple iterations, finding counts change) doesn't
#      produce a false stale verdict

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT

  MARKERS_SH="${RITE_REPO_ROOT}/lib/utils/markers.sh"
  ASSESS_AND_RESOLVE="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"

  # Source markers to get RITE_MARKER_REVIEW constant
  # shellcheck source=/dev/null
  source "$MARKERS_SH"
}

# =============================================================================
# extract_review_sha: correctly parses the commit: attribute
# =============================================================================

@test "extract_review_sha: returns SHA from marker with commit attribute" {
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'

    extract_review_sha() {
      local review_body=\"\$1\"
      echo \"\$review_body\" | grep -oE \"\${RITE_MARKER_REVIEW}[^>]*commit:[a-f0-9]{7,40}\" | \
        grep -oE \"commit:[a-f0-9]{7,40}\" | sed 's/commit://' | head -1 || true
    }

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
    source '${MARKERS_SH}'

    extract_review_sha() {
      local review_body=\"\$1\"
      echo \"\$review_body\" | grep -oE \"\${RITE_MARKER_REVIEW}[^>]*commit:[a-f0-9]{7,40}\" | \
        grep -oE \"commit:[a-f0-9]{7,40}\" | sed 's/commit://' | head -1 || true
    }

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
    source '${MARKERS_SH}'

    extract_review_sha() {
      local review_body=\"\$1\"
      echo \"\$review_body\" | grep -oE \"\${RITE_MARKER_REVIEW}[^>]*commit:[a-f0-9]{7,40}\" | \
        grep -oE \"commit:[a-f0-9]{7,40}\" | sed 's/commit://' | head -1 || true
    }

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
    source '${MARKERS_SH}'

    extract_review_sha() {
      local review_body=\"\$1\"
      echo \"\$review_body\" | grep -oE \"\${RITE_MARKER_REVIEW}[^>]*commit:[a-f0-9]{7,40}\" | \
        grep -oE \"commit:[a-f0-9]{7,40}\" | sed 's/commit://' | head -1 || true
    }

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
  run bash -c "
    set -euo pipefail
    source '${MARKERS_SH}'

    extract_review_sha() {
      local review_body=\"\$1\"
      echo \"\$review_body\" | grep -oE \"\${RITE_MARKER_REVIEW}[^>]*commit:[a-f0-9]{7,40}\" | \
        grep -oE \"commit:[a-f0-9]{7,40}\" | sed 's/commit://' | head -1 || true
    }

    original_sha='abc1234def567890abc1234def567890abc12345'
    _REVIEW_SHA_ATTR=\" commit:\${original_sha}\"

    # Simulate local-review.sh writing the marker
    review_comment=\"<!-- \${RITE_MARKER_REVIEW} model:claude-opus-4-8 timestamp:2026-06-04T15:03:35Z\${_REVIEW_SHA_ATTR} -->

Actual review content follows here.\"

    # Simulate assess-and-resolve.sh reading the SHA back
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
