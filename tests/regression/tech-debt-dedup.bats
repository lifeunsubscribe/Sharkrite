#!/usr/bin/env bats
# tests/regression/tech-debt-dedup.bats
#
# Regression test for tech-debt issue deduplication bug.
#
# Bug: create_tech_debt_issues searched for issues using `${location} in:title`,
# but the issue title is "[tech-debt] ${category}: ${description}" — ${location}
# is never in the title.  Result: the dedup check never matched, and every run
# of create_tech_debt_issues created a new duplicate issue.
#
# Fix: embed a unique <!-- sharkrite-tech-debt:HASH --> marker in the issue body
# and search `in:body` instead, so dedup is reliable regardless of title wording.
#
# Tests in this file:
#   1. Running create_tech_debt_issues twice produces only one issue (dedup works)
#   2. Two distinct entries produce two issues (no false dedup)
#   3. The dedup marker is present in the created issue body
#   4. The dedup marker is NOT in the title (stays clean for human readers)

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Test setup: mock gh + scratchpad fixture
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  # Environment expected by scratchpad-manager.sh and config.sh
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  mkdir -p "$RITE_PROJECT_ROOT/$RITE_DATA_DIR"

  # The scratchpad file path (matches default in scratchpad-manager.sh)
  export SCRATCHPAD_FILE="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/scratch.md"

  # -------------------------------------------------------------------
  # Mock gh binary
  #
  # Behaviour:
  #   gh issue list -S "..." --state all --json number --jq '.[0].number'
  #     → checks GH_MOCK_ISSUE_BODIES_FILE for a matching marker; returns
  #       the issue number if found, empty otherwise.
  #
  #   gh issue create --title TITLE --body-file FILE ...
  #     → records the issue in GH_MOCK_ISSUES_FILE; echoes issue number.
  #
  #   gh label create / gh label list → succeed silently.
  # -------------------------------------------------------------------
  export MOCK_BIN_DIR="$RITE_TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"

  # Files used by the mock to track state
  export GH_MOCK_ISSUES_FILE="$RITE_TEST_TMPDIR/gh-issues.json"
  echo "[]" > "$GH_MOCK_ISSUES_FILE"

  cat > "$MOCK_BIN_DIR/gh" <<'GHEOF'
#!/usr/bin/env bash
# Minimal gh mock for tech-debt-dedup tests

_issues_file="${GH_MOCK_ISSUES_FILE:-/dev/null}"

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  # Parse -S search query to check for a dedup marker
  _search=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -S) _search="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Extract the marker from the search query.
  # Query format: "sharkrite-tech-debt:HASH" in:body
  # Strip surrounding quotes to get the bare marker.
  _marker=$(echo "$_search" | grep -oE 'sharkrite-tech-debt:[a-f0-9]+' || true)

  if [ -z "$_marker" ]; then
    echo "[]"
    exit 0
  fi

  # Check if any recorded issue body contains this marker
  _match=$(jq --arg m "$_marker" \
    '[.[] | select(.body | contains($m))] | .[0].number // empty' \
    "$_issues_file" 2>/dev/null || true)

  if [ -n "$_match" ]; then
    # Return JSON array with matching issue number (matches real gh output)
    echo "$_match"
  else
    echo ""
  fi

elif [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  # Parse --title and --body-file
  _title=""
  _body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) _title="$2"; shift 2 ;;
      --body-file) _body_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  _body=""
  [ -n "$_body_file" ] && [ -f "$_body_file" ] && _body=$(cat "$_body_file")

  # Assign next issue number
  _next=$(jq 'length + 100' "$_issues_file" 2>/dev/null || echo 100)

  # Append to issues list
  jq --argjson num "$_next" --arg title "$_title" --arg body "$_body" \
    '. += [{"number": $num, "title": $title, "body": $body}]' \
    "$_issues_file" > "${_issues_file}.tmp" && mv "${_issues_file}.tmp" "$_issues_file"

  echo "https://github.com/mock/repo/issues/${_next}"

elif [ "$1" = "label" ]; then
  # label create / label list — succeed silently
  exit 0

else
  exit 0
fi
GHEOF
  chmod +x "$MOCK_BIN_DIR/gh"

  # Put mock bin first in PATH
  export PATH="$MOCK_BIN_DIR:$PATH"

  # Source scratchpad-manager (after PATH override so it picks up mock gh)
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/scratchpad-manager.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a scratchpad with a given set of entries
# ---------------------------------------------------------------------------
write_scratchpad() {
  cat > "$SCRATCHPAD_FILE" <<'SCRATCHEOF'
# Scratchpad

## Current Work
Nothing here.

## Encountered Issues (Needs Triage)

SCRATCHEOF
  # Append entries passed as arguments (one per arg)
  for entry in "$@"; do
    echo "$entry" >> "$SCRATCHPAD_FILE"
  done

  echo "" >> "$SCRATCHPAD_FILE"
  echo "## Security Findings" >> "$SCRATCHPAD_FILE"
}

# ---------------------------------------------------------------------------
# Test 1: Running create_tech_debt_issues twice produces exactly one issue
# ---------------------------------------------------------------------------

@test "dedup: second run with identical entry skips creation" {
  local entry="- **2026-05-31** | \`lib/foo.sh:42\` | code-smell | Unnecessary eval in loop | Affects: performance and security | Fix: Replace eval with direct array access | Done: All tests pass, no eval in lib/foo.sh"
  write_scratchpad "$entry"

  # First run: should create one issue
  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # Verify one issue was created
  local count
  count=$(jq 'length' "$GH_MOCK_ISSUES_FILE")
  [ "$count" -eq 1 ]

  # Second run with same scratchpad: should skip (dedup match)
  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  # Still only one issue total
  count=$(jq 'length' "$GH_MOCK_ISSUES_FILE")
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: Two distinct entries produce two issues (no false dedup)
# ---------------------------------------------------------------------------

@test "dedup: two distinct entries produce two separate issues" {
  local entry1="- **2026-05-31** | \`lib/foo.sh:42\` | code-smell | Unnecessary eval in loop | Affects: performance | Fix: Replace eval | Done: Tests pass"
  local entry2="- **2026-05-31** | \`lib/bar.sh:99\` | security | Unquoted variable in curl call | Affects: security | Fix: Quote the variable | Done: Tests pass"
  write_scratchpad "$entry1" "$entry2"

  # First run: should create two issues
  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]

  local count
  count=$(jq 'length' "$GH_MOCK_ISSUES_FILE")
  [ "$count" -eq 2 ]

  # Second run: should skip both (each has its own marker)
  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  count=$(jq 'length' "$GH_MOCK_ISSUES_FILE")
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Test 3: Dedup marker is present in the created issue body
# ---------------------------------------------------------------------------

@test "dedup: created issue body contains sharkrite-tech-debt marker" {
  local entry="- **2026-05-31** | \`lib/baz.sh:7\` | test-failure | Missing bats assertion | Affects: CI reliability | Fix: Add assert | Done: Tests pass"
  write_scratchpad "$entry"

  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # Verify the body contains the marker
  local body
  body=$(jq -r '.[0].body' "$GH_MOCK_ISSUES_FILE")
  [[ "$body" == *"<!-- sharkrite-tech-debt:"* ]]
  [[ "$body" == *"-->"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Dedup marker does NOT appear in the issue title
# ---------------------------------------------------------------------------

@test "dedup: issue title does not contain the dedup marker" {
  local entry="- **2026-05-31** | \`lib/qux.sh:15\` | deprecation | Old API call | Affects: future compatibility | Fix: Update to new API | Done: Tests pass"
  write_scratchpad "$entry"

  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  local title
  title=$(jq -r '.[0].title' "$GH_MOCK_ISSUES_FILE")

  # Title must NOT contain the marker
  [[ "$title" != *"sharkrite-tech-debt"* ]]
  # Title must be in the expected format
  [[ "$title" == "[tech-debt] deprecation: "* ]]
}

# ---------------------------------------------------------------------------
# Test 5: Empty scratchpad produces zero issues (no regression)
# ---------------------------------------------------------------------------

@test "dedup: empty scratchpad returns 0 issues" {
  # No Encountered Issues section
  echo "# Scratchpad" > "$SCRATCHPAD_FILE"

  run create_tech_debt_issues ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  local count
  count=$(jq 'length' "$GH_MOCK_ISSUES_FILE")
  [ "$count" -eq 0 ]
}
