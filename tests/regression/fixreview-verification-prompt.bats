#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh
#
# Regression tests for issue #910 — fix-loop re-reviews were byte-identical fresh
# audits, causing NOW count to grow instead of converge (live: PR #905, 2026-07-05).
#
# Fix: local-review.sh detects fixreview passes (≥2 prior review markers) and
# injects a VERIFICATION PASS context: the prior review body + fix-commit diff +
# instructions to verify prior findings rather than re-audit from scratch.
#
# These are structural tests: they assert that the prompt builder embeds the
# required wording and logic in local-review.sh. Behavioral correctness (actually
# calling gh, building diffs) is tested via integration; prompt contract tests
# here ensure the framing survives future refactors.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export LOCAL_REVIEW_SCRIPT="${RITE_REPO_ROOT}/lib/core/local-review.sh"
  [ -f "$LOCAL_REVIEW_SCRIPT" ] || {
    echo "setup: LOCAL_REVIEW_SCRIPT not found at $LOCAL_REVIEW_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: fixreview pass detection is present ─────────────────────────────

@test "local-review.sh: fixreview pass detection checks prior review marker count" {
  # The script must count prior review comments to identify fixreview passes.
  # Threshold is ≥1: this check happens BEFORE posting, so any count ≥1
  # means a prior review already exists (this is a fixreview pass).
  run grep -n 'prior_review_count\|_prior.*review.*count' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no prior review count detection found in $LOCAL_REVIEW_SCRIPT"
    false
  }

  # Must check for ≥1 to detect fixreview (count is pre-post so count=1 = one prior review)
  run grep -n 'ge 1\|-ge 1' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no ≥1 fixreview threshold found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 2: fixreview prompt contains verification-first framing ─────────────

@test "local-review.sh: fixreview prompt contains VERIFICATION PASS framing" {
  # The injected section must tell the reviewer this is verification, not a fresh audit.
  run grep -n 'VERIFICATION PASS\|verification pass' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no VERIFICATION PASS framing found in $LOCAL_REVIEW_SCRIPT"
    false
  }

  run grep -n 'NOT a fresh audit\|not.*fresh audit' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'NOT a fresh audit' instruction found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 3: fixreview prompt instructs FIXED/NOT FIXED verification ─────────

@test "local-review.sh: fixreview prompt instructs reviewer to verify FIXED or NOT FIXED" {
  run grep -n 'FIXED.*NOT FIXED\|NOT FIXED.*FIXED\|FIXED or NOT FIXED\|determine.*FIXED' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no FIXED/NOT FIXED verification instruction found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 4: fixreview prompt injects prior review body ──────────────────────

@test "local-review.sh: fixreview prompt includes prior review body section" {
  # The prompt must embed the prior review body so the reviewer can check each finding.
  run grep -n 'Prior Review\|prior_review_body\|_prior_review_body' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no prior review body injection found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 5: fixreview prompt includes fix-commit diff ───────────────────────

@test "local-review.sh: fixreview prompt includes fix-commit diff section" {
  # The fix-commit diff scopes the reviewer to changes since the prior review.
  run grep -n 'fix_commit_diff\|_fix_commit_diff\|Fix Commits' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no fix-commit diff section found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 6: fix-commit diff uses three-dot syntax ───────────────────────────

@test "local-review.sh: fix-commit diff uses three-dot ancestor syntax" {
  # git diff <sha>...origin/<branch> gives commits SINCE the prior review SHA.
  run grep -nE '\.\.\.origin/' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'sha...origin/<branch>' three-dot diff syntax found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 7: new findings bar — introduced-by-fix or CRITICAL only ────────────

@test "local-review.sh: fixreview prompt restricts new findings to introduced-by-fix or CRITICAL" {
  # The instructions must state the bar for new findings on a verification pass.
  run grep -n 'introduced by the fix\|introduced by fix' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no 'introduced by fix' new-findings bar found in $LOCAL_REVIEW_SCRIPT"
    false
  }

  run grep -n 'CRITICAL severity\|CRITICAL.*regardless' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: no CRITICAL severity exception for new findings found in $LOCAL_REVIEW_SCRIPT"
    false
  }
}

# ─── Test 8: first-pass prompt is unchanged (FIXREVIEW_CONTEXT_SECTION is empty) ─

@test "local-review.sh: first-pass prompt is not altered (FIXREVIEW_CONTEXT_SECTION guarded by count check)" {
  # The fixreview section must only be injected when prior review count ≥ 1
  # (pre-post count; ≥1 means a prior review already exists).
  # Verify that the variable name is only populated inside the count guard.
  local inject_line count_line
  inject_line=$(grep -n 'FIXREVIEW_CONTEXT_SECTION=' "$LOCAL_REVIEW_SCRIPT" | grep -v '""$' | head -1 || true)
  count_line=$(grep -n 'ge 1\|-ge 1' "$LOCAL_REVIEW_SCRIPT" | head -1 || true)

  # The injecting assignment must appear after the count guard line in the file.
  [ -n "$inject_line" ] || {
    echo "FAIL: FIXREVIEW_CONTEXT_SECTION assignment not found in $LOCAL_REVIEW_SCRIPT"
    false
  }
  [ -n "$count_line" ] || {
    echo "FAIL: ge 1 count guard not found in $LOCAL_REVIEW_SCRIPT"
    false
  }

  local inject_num count_num
  inject_num="${inject_line%%:*}"
  count_num="${count_line%%:*}"
  [ "$inject_num" -gt "$count_num" ] || {
    echo "FAIL: FIXREVIEW_CONTEXT_SECTION injected (line $inject_num) before count guard (line $count_num)"
    false
  }
}

# ─── Test 9: FIXREVIEW_CONTEXT_SECTION is included in prompt assembly ─────────

@test "local-review.sh: FIXREVIEW_CONTEXT_SECTION is included in REVIEW_PROMPT assembly" {
  run grep -n 'FIXREVIEW_CONTEXT_SECTION' "$LOCAL_REVIEW_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: FIXREVIEW_CONTEXT_SECTION not referenced in $LOCAL_REVIEW_SCRIPT"
    false
  }

  # Must appear in the REVIEW_PROMPT assignment
  run grep -n 'REVIEW_PROMPT=.*FIXREVIEW_CONTEXT_SECTION\|FIXREVIEW_CONTEXT_SECTION.*REVIEW_PROMPT' "$LOCAL_REVIEW_SCRIPT"
  if [ "$status" -ne 0 ]; then
    # Also check multi-line: REVIEW_PROMPT= followed by FIXREVIEW_CONTEXT_SECTION on an adjacent line
    block=$(awk '/REVIEW_PROMPT=/{f=1} f{print; if (/FIXREVIEW_CONTEXT_SECTION/) exit}' "$LOCAL_REVIEW_SCRIPT")
    [[ "$block" == *"FIXREVIEW_CONTEXT_SECTION"* ]] || {
      echo "FAIL: FIXREVIEW_CONTEXT_SECTION not found in REVIEW_PROMPT assembly"
      false
    }
  fi
}
