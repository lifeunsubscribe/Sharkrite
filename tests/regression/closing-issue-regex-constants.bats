#!/usr/bin/env bats
# tests/regression/closing-issue-regex-constants.bats
#
# Regression test for: closing-issue regex duplicated across multiple files
# Issue: #91 (inherited from PR #180 assessment)
#
# Root cause: The closing-keyword regex pattern was inlined in 8 locations
# across 6 files with 3 distinct variants, creating maintainability risk
# (one copy updated without others → inconsistent issue resolution).
#
# Fix: Consolidate into two constants in lib/utils/pr-detection.sh:
#   CLOSING_ISSUE_JQ_REGEX  — prefix for jq test() expressions
#   CLOSING_ISSUE_GREP_REGEX — full pattern for grep -oE extraction
#
# Tests in this file:
#   1. CLOSING_ISSUE_JQ_REGEX is exported by pr-detection.sh
#   2. CLOSING_ISSUE_GREP_REGEX is exported by pr-detection.sh
#   3. CLOSING_ISSUE_JQ_REGEX matches all expected keyword variants
#   4. CLOSING_ISSUE_GREP_REGEX matches all expected keyword variants and extracts numbers
#   5. Both constants are consistent with each other (same keyword coverage)
#   6. CLOSING_ISSUE_JQ_REGEX does not match non-closing references (e.g. "Mentions #5")
#   7. Constants survive double-source (idempotent re-source)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  # Create a minimal git repo so config.sh's detect_project_root() succeeds
  git init --quiet "$RITE_TEST_TMPDIR/repo"
  cd "$RITE_TEST_TMPDIR/repo"
  git commit --quiet --allow-empty -m "init"

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/repo"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub gh and git-fetch calls so sourcing pr-detection.sh doesn't hit network
  export MOCK_BIN_DIR="$RITE_TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"
  cat > "$MOCK_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "[]"
GHEOF
  chmod +x "$MOCK_BIN_DIR/gh"
  export PATH="$MOCK_BIN_DIR:$PATH"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: source pr-detection in a subshell, print the requested variable
# ---------------------------------------------------------------------------
_source_and_print() {
  local var="$1"
  (
    source "$RITE_LIB_DIR/utils/pr-detection.sh"
    echo "${!var}"
  )
}

# ---------------------------------------------------------------------------
# Test 1: CLOSING_ISSUE_JQ_REGEX is defined after sourcing pr-detection.sh
# ---------------------------------------------------------------------------
@test "CLOSING_ISSUE_JQ_REGEX is defined by pr-detection.sh" {
  local val
  val=$(_source_and_print CLOSING_ISSUE_JQ_REGEX)
  [ -n "$val" ]
}

# ---------------------------------------------------------------------------
# Test 2: CLOSING_ISSUE_GREP_REGEX is defined after sourcing pr-detection.sh
# ---------------------------------------------------------------------------
@test "CLOSING_ISSUE_GREP_REGEX is defined by pr-detection.sh" {
  local val
  val=$(_source_and_print CLOSING_ISSUE_GREP_REGEX)
  [ -n "$val" ]
}

# ---------------------------------------------------------------------------
# Test 3: CLOSING_ISSUE_JQ_REGEX matches all expected keyword variants
# ---------------------------------------------------------------------------
@test "CLOSING_ISSUE_JQ_REGEX matches all closing-keyword variants via jq test()" {
  source "$RITE_LIB_DIR/utils/pr-detection.sh"

  # Each of these should match the jq regex prefix + an issue number
  local -a should_match=(
    "Closes #42"
    "closes #42"
    "Fixes #42"
    "fixes #42"
    "Resolves #42"
    "resolves #42"
    "Closes #42 and some text"
    "This PR resolves #42 completely"
  )

  for body in "${should_match[@]}"; do
    local result
    result=$(echo "[{\"body\": \"$body\"}]" | \
      jq --arg issue "42" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
      '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | length')
    [ "$result" -gt 0 ] || {
      echo "FAIL: expected match for: $body" >&2
      false
    }
  done
}

# ---------------------------------------------------------------------------
# Test 4: CLOSING_ISSUE_GREP_REGEX extracts issue numbers from all keyword variants
# ---------------------------------------------------------------------------
@test "CLOSING_ISSUE_GREP_REGEX extracts issue numbers from all keyword variants" {
  source "$RITE_LIB_DIR/utils/pr-detection.sh"

  local -a cases=(
    "Closes #42:42"
    "closes #7:7"
    "Fixes #100:100"
    "fixes #3:3"
    "Resolves #55:55"
    "resolves #200:200"
  )

  for case in "${cases[@]}"; do
    local body="${case%%:*}"
    local expected="${case##*:}"
    local extracted
    extracted=$(echo "$body" | grep -oE "$CLOSING_ISSUE_GREP_REGEX" | grep -oE '[0-9]+' || true)
    [ "$extracted" = "$expected" ] || {
      echo "FAIL: from '$body' expected '$expected' but got '$extracted'" >&2
      false
    }
  done
}

# ---------------------------------------------------------------------------
# Test 5: Both constants cover the same 6 keyword variants
# ---------------------------------------------------------------------------
@test "CLOSING_ISSUE_JQ_REGEX and CLOSING_ISSUE_GREP_REGEX have consistent keyword coverage" {
  source "$RITE_LIB_DIR/utils/pr-detection.sh"

  local -a keywords=("Closes" "closes" "Fixes" "fixes" "Resolves" "resolves")

  for kw in "${keywords[@]}"; do
    # jq test(): keyword + " #42" should match the jq prefix
    local jq_match
    jq_match=$(echo "\"${kw} #42\"" | \
      jq --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
      'test($closing_re + "42\\b")')
    [ "$jq_match" = "true" ] || {
      echo "FAIL: CLOSING_ISSUE_JQ_REGEX did not match keyword '$kw'" >&2
      false
    }

    # grep -oE: keyword + " #42" should be extracted
    local grep_match
    grep_match=$(echo "${kw} #42" | grep -oE "$CLOSING_ISSUE_GREP_REGEX" || true)
    [ -n "$grep_match" ] || {
      echo "FAIL: CLOSING_ISSUE_GREP_REGEX did not match keyword '$kw'" >&2
      false
    }
  done
}

# ---------------------------------------------------------------------------
# Test 6: CLOSING_ISSUE_JQ_REGEX does not match non-closing references
# ---------------------------------------------------------------------------
@test "CLOSING_ISSUE_JQ_REGEX does not match non-closing references" {
  source "$RITE_LIB_DIR/utils/pr-detection.sh"

  local -a should_not_match=(
    "Mentions #42"
    "See #42 for context"
    "Related to #42"
    "Follow-up from #42"
    "Part of #42"
  )

  for body in "${should_not_match[@]}"; do
    local result
    result=$(echo "[{\"body\": \"$body\"}]" | \
      jq --arg issue "42" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
      '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | length')
    [ "$result" -eq 0 ] || {
      echo "FAIL: unexpected match for non-closing reference: $body" >&2
      false
    }
  done
}

# ---------------------------------------------------------------------------
# Test 7: Constants survive double-source (idempotent re-source)
# ---------------------------------------------------------------------------
@test "closing-issue constants are defined correctly after double-source" {
  local val1 val2
  val1=$(
    source "$RITE_LIB_DIR/utils/pr-detection.sh"
    source "$RITE_LIB_DIR/utils/pr-detection.sh"
    echo "${CLOSING_ISSUE_JQ_REGEX}|${CLOSING_ISSUE_GREP_REGEX}"
  )
  # Both constants should be non-empty
  local jq_re="${val1%%|*}"
  local grep_re="${val1##*|}"
  [ -n "$jq_re" ]
  [ -n "$grep_re" ]
}
