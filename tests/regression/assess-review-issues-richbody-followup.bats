#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh
#
# Regression test for the #790 follow-on: the SURVIVING ACTIONABLE_LATER
# follow-up issue (filed by assess-review-issues.sh's OLD emit path) must now
# carry the runbook-compliant rich body — `## Description` + Claude Context +
# Acceptance Criteria + Verification Commands + Done Definition + Scope Boundary
# + Dependencies + both source/parent markers — instead of the sparse
# `## From PR #N Assessment` shape it used to ship.
#
# Background:
#   assess-review-issues.sh files ACTIONABLE_LATER per-item follow-ups FIRST,
#   which sets RITE_PER_ITEM_ISSUES_FILE → assess-and-resolve.sh skips its
#   richer per-finding loop for those findings. So the body emitted HERE is the
#   one users actually see. This suite drives the real script end-to-end (mock
#   claude returns an ACTIONABLE_LATER assessment; mock gh captures the
#   --body-file passed to `issue create`) and asserts the new body shape.
#
# Tests:
#   1. Body contains all runbook section headers + parent-PR marker
#   2. HIGH finding (with Location) → concrete `sed -n` verification command
#   3. MEDIUM finding (no Location) → `# TODO` verification fallback
#   4. Two distinct findings → two issue-create calls with distinct titles
#   5. No cross-finding Location leak (MEDIUM body lacks the HIGH Location)
#   6. Single-quote Location → `# TODO:` prose fallback (sanitization regression)

setup() {
  # Mirror empty-assessment-fails-loud.bats: source config, mock claude + gh on PATH.
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "${RITE_LIB_DIR}/utils/config.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  export PR_NUMBER=42
  export RITE_ISSUE_NUMBER=15
  export AUTO_MODE=true

  # Mock review file (content is irrelevant — the mock claude ignores it).
  export MOCK_REVIEW_FILE=$(mktemp)
  cat > "$MOCK_REVIEW_FILE" <<'EOF'
## Code Review Summary

**Findings: CRITICAL: 0 | HIGH: 1 | MEDIUM: 1 | LOW: 0**
EOF

  export MOCK_PROVIDER_DIR=$(mktemp -d)
  export PATH="$MOCK_PROVIDER_DIR:$PATH"

  # Capture file: the mock gh appends each `issue create --body-file` body here,
  # delimited so tests can split per-finding bodies.
  export CREATE_CAPTURE="${MOCK_PROVIDER_DIR}/issue-create-bodies.txt"
  : > "$CREATE_CAPTURE"
  # Capture file for the titles passed to `issue create`.
  export TITLE_CAPTURE="${MOCK_PROVIDER_DIR}/issue-create-titles.txt"
  : > "$TITLE_CAPTURE"

  # Mock claude: emit a two-finding ACTIONABLE_LATER assessment.
  #   - HIGH finding WITH a **Location:** lib/core/foo.sh:42 field
  #   - MEDIUM finding WITHOUT a Location field
  cat > "$MOCK_PROVIDER_DIR/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Fix input validation bypass - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** The login handler does not validate user input before use.
**Context:** Out of scope for this PR but should be tracked.
**Location:** lib/core/foo.sh:42
**Defer Reason:** Larger refactor than this PR allows.

### Improve vague error messages - ACTIONABLE_LATER

**Severity:** MEDIUM
**Category:** UX
**Reasoning:** Error messages do not tell the user what went wrong.
**Context:** Cosmetic but worth addressing.
**Defer Reason:** Low priority relative to PR goal.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  # Mock gh: capture issue-create bodies/titles, return benign responses
  # for everything else so no real network call happens.
  cat > "$MOCK_PROVIDER_DIR/gh" <<MOCK_EOF
#!/bin/bash
# Capture files passed via env (exported above).
CREATE_CAPTURE="${CREATE_CAPTURE}"
TITLE_CAPTURE="${TITLE_CAPTURE}"
PR_NUMBER="${PR_NUMBER}"
MOCK_EOF
  cat >> "$MOCK_PROVIDER_DIR/gh" <<'MOCK_EOF'

case "$1" in
  pr)
    case "$2" in
      view)
        # The script asks for several --json shapes. Return one object that
        # satisfies all of them (body, comments, files, headRefName).
        echo '{"body":"Closes #15","comments":[],"files":[{"path":"lib/core/foo.sh"},{"path":"lib/utils/bar.sh"}],"headRefName":"fix-15-richbody"}'
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
        # No existing issues → no dedup match → new-issue path runs.
        echo '[]'
        ;;
      view)
        echo '{"body":""}'
        ;;
      create)
        # Extract --title and --body-file args.
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
        # Emit a plausible issue URL so the script extracts a number.
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
    # ensure_labels_exist may call `gh label create/list`.
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

# Helper: run the script and return the full capture file contents.
_run_assess() {
  run bash "${RITE_LIB_DIR}/core/assess-review-issues.sh" "$PR_NUMBER" "$MOCK_REVIEW_FILE" --auto
  [ "$status" -eq 0 ] || {
    echo "assess-review-issues.sh exited $status"
    echo "--- output ---"
    echo "$output"
    false
  }
}

# Extract the Nth captured issue body (1-based) from the capture file.
_nth_body() {
  local _n="$1"
  awk -v want="$_n" '
    /===ISSUE_BODY_START===/ { idx++; if (idx==want) { capturing=1; next } }
    /===ISSUE_BODY_END===/   { if (capturing) { capturing=0 } }
    capturing { print }
  ' "$CREATE_CAPTURE"
}

# ─── Test 1: all runbook section headers + parent-PR marker present ───────────

@test "richbody: surviving follow-up body contains all runbook sections + markers" {
  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no first issue body captured"; cat "$CREATE_CAPTURE"; false; }

  for _section in \
    '## Description' \
    '## Claude Context' \
    '## Acceptance Criteria' \
    '## Verification Commands' \
    '## Done Definition' \
    '## Scope Boundary' \
    '## Dependencies'; do
    echo "$_body" | grep -qF "$_section" || {
      echo "FAIL: body missing section: $_section"
      echo "--- body ---"
      echo "$_body"
      false
    }
  done

  # Parent-PR marker must be present (carried alongside the source-issue marker).
  echo "$_body" | grep -qE 'sharkrite-parent-pr:[0-9]+' || {
    echo "FAIL: body missing sharkrite-parent-pr marker"
    echo "$_body"
    false
  }
}

# ─── Test 2: HIGH finding (with Location) → concrete sed -n verification ───────

@test "richbody: HIGH finding with Location yields concrete sed -n verification command" {
  _run_assess

  # Locate the body whose title is the HIGH finding.
  local _high_body
  _high_body=$(_high_finding_body)
  [ -n "$_high_body" ] || { echo "FAIL: HIGH finding body not found"; cat "$CREATE_CAPTURE"; false; }

  echo "$_high_body" | grep -qF "sed -n '42p' 'lib/core/foo.sh'" || {
    echo "FAIL: HIGH body lacks concrete sed -n verification command derived from Location"
    echo "--- HIGH body ---"
    echo "$_high_body"
    false
  }
}

# ─── Test 3: MEDIUM finding (no Location) → # TODO verification fallback ───────

@test "richbody: MEDIUM finding without Location yields # TODO verification fallback" {
  _run_assess

  local _med_body
  _med_body=$(_medium_finding_body)
  [ -n "$_med_body" ] || { echo "FAIL: MEDIUM finding body not found"; cat "$CREATE_CAPTURE"; false; }

  echo "$_med_body" | grep -qF "# TODO: add verification command for this finding" || {
    echo "FAIL: MEDIUM body lacks the # TODO verification fallback"
    echo "--- MEDIUM body ---"
    echo "$_med_body"
    false
  }
}

# ─── Test 4: two distinct findings → two issue-create calls, distinct titles ──

@test "richbody: two findings produce two issue-create calls with distinct titles" {
  _run_assess

  local _count
  _count=$(grep -c '===ISSUE_BODY_START===' "$CREATE_CAPTURE" || true)
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected 2 issue-create calls, got $_count"
    cat "$CREATE_CAPTURE"
    false
  }

  # Titles captured, both present and distinct.
  grep -qF "Fix input validation bypass" "$TITLE_CAPTURE" || {
    echo "FAIL: HIGH finding title not captured"; cat "$TITLE_CAPTURE"; false
  }
  grep -qF "Improve vague error messages" "$TITLE_CAPTURE" || {
    echo "FAIL: MEDIUM finding title not captured"; cat "$TITLE_CAPTURE"; false
  }
  local _distinct
  _distinct=$(sort -u "$TITLE_CAPTURE" | grep -c . || true)
  [ "$_distinct" -eq 2 ] || {
    echo "FAIL: titles are not distinct (got $_distinct unique)"; cat "$TITLE_CAPTURE"; false
  }
}

# ─── Test 5: no cross-finding Location leak ───────────────────────────────────

@test "richbody: MEDIUM finding body does NOT carry the HIGH finding's Location" {
  _run_assess

  local _med_body
  _med_body=$(_medium_finding_body)
  [ -n "$_med_body" ] || { echo "FAIL: MEDIUM finding body not found"; cat "$CREATE_CAPTURE"; false; }

  echo "$_med_body" | grep -qF "lib/core/foo.sh:42" && {
    echo "FAIL: MEDIUM body leaked the HIGH finding's Location (cross-finding state leak)"
    echo "--- MEDIUM body ---"
    echo "$_med_body"
    false
  }
  # Also: it must NOT carry a **Location:** line at all.
  echo "$_med_body" | grep -qE '^\*\*Location:\*\*' && {
    echo "FAIL: MEDIUM body has a Location line despite the finding having none"
    echo "$_med_body"
    false
  }
  return 0
}

# ─── Test 6: single-quote Location → sanitized to # TODO: prose fallback ──────

@test "richbody: single-quote in Location yields # TODO: prose fallback (sanitization)" {
  # Override the claude mock: emit one HIGH finding with a single-quote in the
  # Location path. The path-sanitization grep must reject it and fall back to
  # the `# TODO:` prose form rather than injecting the quote into a sed command.
  cat > "$MOCK_PROVIDER_DIR/claude" <<'MOCK_EOF'
#!/bin/bash
cat <<'ASSESSMENT_EOF'
### Weird path finding - ACTIONABLE_LATER

**Severity:** HIGH
**Category:** Security
**Reasoning:** Path with an embedded quote.
**Context:** Tracked separately.
**Location:** lib/core/fo'o.sh:42
**Defer Reason:** Needs investigation.
ASSESSMENT_EOF
exit 0
MOCK_EOF
  chmod +x "$MOCK_PROVIDER_DIR/claude"

  _run_assess

  local _body
  _body=$(_nth_body 1)
  [ -n "$_body" ] || { echo "FAIL: no issue body captured"; cat "$CREATE_CAPTURE"; false; }

  # Must use the prose fallback (NOT a sed/grep command embedding the quote).
  echo "$_body" | grep -qF "# TODO: add verification command for:" || {
    echo "FAIL: single-quote Location did not fall back to # TODO: prose form"
    echo "--- body ---"
    echo "$_body"
    false
  }
  # Defensive: there must be no sed -n command built from the tainted path.
  echo "$_body" | grep -qF "sed -n '42p'" && {
    echo "FAIL: tainted path produced a sed -n verification command (sanitization bypassed)"
    echo "$_body"
    false
  }
  return 0
}

# ─── Helpers: locate a finding's body by its title ────────────────────────────

# Return the captured body whose body contains the HIGH finding's acceptance line.
_high_finding_body() {
  local _i _n _b
  _n=$(grep -c '===ISSUE_BODY_START===' "$CREATE_CAPTURE" || true)
  for _i in $(seq 1 "$_n"); do
    _b=$(_nth_body "$_i")
    if echo "$_b" | grep -qF "[HIGH] Fix input validation bypass"; then
      echo "$_b"
      return 0
    fi
  done
  return 0
}

# Return the captured body whose body contains the MEDIUM finding's acceptance line.
_medium_finding_body() {
  local _i _n _b
  _n=$(grep -c '===ISSUE_BODY_START===' "$CREATE_CAPTURE" || true)
  for _i in $(seq 1 "$_n"); do
    _b=$(_nth_body "$_i")
    if echo "$_b" | grep -qF "[MEDIUM] Improve vague error messages"; then
      echo "$_b"
      return 0
    fi
  done
  return 0
}
