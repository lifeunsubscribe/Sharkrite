#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
#
# Regression test for #796: an ACTIONABLE_LATER finding that omits **Defer
# Reason:** must still produce a follow-up issue.
#
# Root cause: the awk block-extractor used **Defer Reason:** as its block
# terminator.  When the field was absent AND a second ACTIONABLE_LATER
# finding followed, neither "---END---" fired and the first finding was
# silently dropped.  The fix makes block boundaries structural (### header /
# EOF), so Defer Reason is printed but no longer controls termination.
#
# Tests:
#   1. Two consecutive ACTIONABLE_LATER findings where the FIRST lacks Defer
#      Reason → BOTH produce issues (2 gh issue create calls).
#   2. A single trailing ACTIONABLE_LATER finding (last in output) that lacks
#      Defer Reason → still produces an issue (EOF handler fires).
#   3. Happy-path unchanged: two findings that BOTH have Defer Reason still
#      produce exactly 2 issues.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"

  export PR_NUMBER=99
  export RITE_ISSUE_NUMBER=42
  export AUTO_MODE=true

  export MOCK_REVIEW_FILE=$(mktemp)
  cat > "$MOCK_REVIEW_FILE" <<'EOF'
## Code Review Summary

**Findings: CRITICAL: 0 | HIGH: 1 | MEDIUM: 1 | LOW: 0**
EOF

  export MOCK_PROVIDER_DIR=$(mktemp -d)
  export PATH="$MOCK_PROVIDER_DIR:$PATH"

  # Capture file: mock gh appends each issue-create body here.
  export CREATE_CAPTURE="${MOCK_PROVIDER_DIR}/issue-create-bodies.txt"
  : > "$CREATE_CAPTURE"
  export TITLE_CAPTURE="${MOCK_PROVIDER_DIR}/issue-create-titles.txt"
  : > "$TITLE_CAPTURE"

  # Mock gh: capture issue-create calls, return benign responses for the rest.
  cat > "$MOCK_PROVIDER_DIR/gh" <<MOCK_EOF
#!/bin/bash
CREATE_CAPTURE="${CREATE_CAPTURE}"
TITLE_CAPTURE="${TITLE_CAPTURE}"
PR_NUMBER="${PR_NUMBER}"
MOCK_EOF
  cat >> "$MOCK_PROVIDER_DIR/gh" <<'MOCK_EOF'

case "$1" in
  pr)
    case "$2" in
      view)
        echo '{"body":"Closes #42","comments":[],"files":[{"path":"lib/core/foo.sh"}],"headRefName":"fix-42-defer"}'
        ;;
      comment)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        echo '[]'
        ;;
      view)
        echo '{"body":""}'
        ;;
      create)
        _title=""
        _bodyfile=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --title) _title="$2"; shift 2 ;;
            --body-file) _bodyfile="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s\n' "$_title" >> "$TITLE_CAPTURE"
        {
          echo "===ISSUE_BODY_START==="
          cat "$_bodyfile"
          echo ""
          echo "===ISSUE_BODY_END==="
        } >> "$CREATE_CAPTURE"
        _n=$(( $(grep -c '===ISSUE_BODY_START===' "$CREATE_CAPTURE") + 100 ))
        echo "https://github.com/test/repo/issues/${_n}"
        ;;
      edit)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  label)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/gh"
}

teardown() {
  rm -f "$MOCK_REVIEW_FILE"
  rm -rf "$MOCK_PROVIDER_DIR"
}

# Helper: run assess-review-issues.sh with the mock claude already on PATH.
_run_assess() {
  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto
  [ "$status" -eq 0 ] || {
    echo "assess-review-issues.sh exited $status"
    echo "--- output ---"
    echo "$output"
    false
  }
}

# Helper: count how many issue-create bodies were captured.
_create_count() {
  grep -c '===ISSUE_BODY_START===' "$CREATE_CAPTURE" || true
}

# ─── Test 1: first of two ACTIONABLE_LATER findings omits Defer Reason ────────
#
# Assessment structure:
#   ### Finding A - ACTIONABLE_LATER   (HIGH, NO Defer Reason)
#   ### Finding B - ACTIONABLE_LATER   (MEDIUM, has Defer Reason)
#
# Pre-fix: only Finding B produced an issue (Finding A's block never closed).
# Post-fix: both produce issues.

@test "no-defer-reason drop: first finding without Defer Reason is not silently dropped" {
  cat > "$MOCK_PROVIDER_DIR/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Missing auth check - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** The admin endpoint skips authentication entirely.
**Context:** Out of scope for this PR but critical to track.
**Location:** lib/core/auth.sh:88

### Improve log verbosity - ACTIONABLE_LATER

**Severity:** MEDIUM
**Category:** Observability
**Reasoning:** Log lines omit the request ID, making tracing hard.
**Context:** Low urgency but should be tracked.
**Defer Reason:** Minor quality improvement relative to this PR.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  _run_assess

  local _count
  _count=$(_create_count)
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected 2 issue-create calls, got $_count"
    echo "--- TITLE_CAPTURE ---"
    cat "$TITLE_CAPTURE"
    echo "--- CREATE_CAPTURE ---"
    cat "$CREATE_CAPTURE"
    false
  }

  grep -qF "Missing auth check" "$TITLE_CAPTURE" || {
    echo "FAIL: first finding (no Defer Reason) was not filed"
    cat "$TITLE_CAPTURE"
    false
  }

  grep -qF "Improve log verbosity" "$TITLE_CAPTURE" || {
    echo "FAIL: second finding (has Defer Reason) was not filed"
    cat "$TITLE_CAPTURE"
    false
  }
}

# ─── Test 2: trailing ACTIONABLE_LATER finding without Defer Reason (EOF case) ─
#
# Assessment structure:
#   ### Only Finding - ACTIONABLE_LATER   (HIGH, NO Defer Reason, last in output)
#
# Pre-fix: the EOF handler was absent; the finding was silently dropped.
# Post-fix: END { if (in_later) print "---END---" } fires and the issue is created.

@test "no-defer-reason drop: trailing finding without Defer Reason is filed (EOF handler)" {
  cat > "$MOCK_PROVIDER_DIR/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Unvalidated redirect - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** The redirect target is not validated against an allowlist.
**Context:** Needs a dedicated security PR.
**Location:** lib/core/redirect.sh:15
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  _run_assess

  local _count
  _count=$(_create_count)
  [ "$_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue-create call, got $_count"
    echo "--- TITLE_CAPTURE ---"
    cat "$TITLE_CAPTURE"
    echo "--- CREATE_CAPTURE ---"
    cat "$CREATE_CAPTURE"
    false
  }

  grep -qF "Unvalidated redirect" "$TITLE_CAPTURE" || {
    echo "FAIL: trailing finding without Defer Reason was not filed"
    cat "$TITLE_CAPTURE"
    false
  }
}

# ─── Test 3: happy path — both findings have Defer Reason, still 2 issues ─────
#
# Regression guard: the structural-boundary change must not break the existing
# happy path where every finding includes Defer Reason.

@test "no-defer-reason drop: happy path (both findings have Defer Reason) unchanged" {
  cat > "$MOCK_PROVIDER_DIR/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Hardcoded timeout - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Reliability
**Reasoning:** The 30s timeout is hardcoded; should be configurable.
**Context:** Tracked separately from this PR.
**Location:** lib/utils/timeout.sh:5
**Defer Reason:** Config system refactor needed first.

### Dead code in parser - ACTIONABLE_LATER

**Severity:** MEDIUM
**Category:** Maintainability
**Reasoning:** The fallback branch has been unreachable since #400.
**Context:** Low risk but adds confusion.
**Defer Reason:** Cleanup sprint; no urgency.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  _run_assess

  local _count
  _count=$(_create_count)
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected 2 issue-create calls (happy path), got $_count"
    cat "$TITLE_CAPTURE"
    false
  }

  grep -qF "Hardcoded timeout" "$TITLE_CAPTURE" || {
    echo "FAIL: first finding (has Defer Reason) was not filed in happy path"
    cat "$TITLE_CAPTURE"
    false
  }

  grep -qF "Dead code in parser" "$TITLE_CAPTURE" || {
    echo "FAIL: second finding (has Defer Reason) was not filed in happy path"
    cat "$TITLE_CAPTURE"
    false
  }
}
