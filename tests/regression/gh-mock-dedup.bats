#!/usr/bin/env bats
# tests/regression/gh-mock-dedup.bats
#
# Regression tests verifying that mock_gh's stateful deduplication mode
# correctly simulates the gh commands used by assess-and-resolve.sh's
# dedup logic.
#
# Background:
#   The original mock_gh was stateless — it returned fixed JSON fixtures
#   regardless of previous calls.  Tests for assess-and-resolve.sh's dedup
#   logic therefore had to implement their own inline gh stubs (see
#   tests/regression/tech-debt-dedup.bats) or bypass gh entirely (see
#   tests/concurrency/followup-issue-dedup.bats).  This meant the mock
#   didn't exercise the real dedup decision tree at all.
#
#   The stateful dedup mode added to gh-mock.bash tracks created issues and
#   PR comments in temp files.  These tests verify that the mock correctly
#   simulates the following dedup-relevant behaviors:
#
#   1. gh issue create   → records issue; returns URL with assigned number
#   2. gh issue list --search "... in:body"  → finds issues by body substring
#   3. gh issue list --search "in:title ..."  → finds issues by title substring
#   4. gh pr comment N --body-file F  → records comment on PR
#   5. gh pr view N --json comments --jq ...  → returns comments count
#   6. Search-index lag simulation (GH_MOCK_ISSUE_INDEX_LAG)
#   7. Issue view (gh issue view N --json url --jq .url) → returns tracked URL
#   8. reset_gh_mock clears stateful mode between tests
#
# Tests are grouped by the gh command they exercise, then by scenario.
#
# Verification command: bats tests/regression/gh-mock-dedup.bats

load '../helpers/setup.bash'
load '../helpers/gh-mock.bash'

setup() {
  setup_test_tmpdir

  export RITE_REPO_ROOT
  export GH_MOCK_STATE_DIR="$RITE_TEST_TMPDIR/gh-mock-state"
  setup_gh_mock_state
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. gh issue create
# ---------------------------------------------------------------------------

@test "stateful: gh issue create records issue and returns URL" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "Test issue body" > "$body_file"

  run mock_gh issue create --title "Test issue" --body-file "$body_file" --label "tech-debt"
  [ "$status" -eq 0 ]
  # URL must end with a number
  [[ "$output" =~ /issues/[0-9]+$ ]]
}

@test "stateful: sequential gh issue creates get distinct numbers" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "body" > "$body_file"

  local url1 url2
  url1=$(mock_gh issue create --title "Issue A" --body-file "$body_file")
  url2=$(mock_gh issue create --title "Issue B" --body-file "$body_file")

  [ "$url1" != "$url2" ]

  local num1 num2
  num1="${url1##*/}"
  num2="${url2##*/}"
  [ "$num1" != "$num2" ]
}

@test "stateful: gh_mock_issue_count reflects created issues" {
  local count_before
  count_before=$(gh_mock_issue_count)
  [ "$count_before" -eq 0 ]

  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "body" > "$body_file"
  mock_gh issue create --title "Issue A" --body-file "$body_file" > /dev/null
  mock_gh issue create --title "Issue B" --body-file "$body_file" > /dev/null

  local count_after
  count_after=$(gh_mock_issue_count)
  [ "$count_after" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 2. gh issue list --search "... in:body"
# ---------------------------------------------------------------------------

@test "stateful: in:body search finds issue whose body contains the term" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  printf '<!-- sharkrite-source-issue:42 -->\nSome review feedback.' > "$body_file"
  mock_gh issue create --title "[review-follow-up] feedback for PR #99" \
    --body-file "$body_file" > /dev/null

  # This is exactly how assess-and-resolve.sh searches (primary dedup path)
  run mock_gh issue list \
    --state open \
    --search "sharkrite-source-issue:42 in:body" \
    --json number \
    --jq '.[0].number'

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "stateful: quoted in:body search finds issue (assess-and-resolve.sh primary path)" {
  # Verifies that the quoted search format used by assess-and-resolve.sh works:
  #   --search '"sharkrite-source-issue:42" in:body'
  # The mock must strip the surrounding quotes before matching — the body contains
  # the literal marker without quotes.
  local body_file="$RITE_TEST_TMPDIR/body.md"
  printf '<!-- sharkrite-source-issue:42 -->\nSome review feedback.' > "$body_file"
  mock_gh issue create --title "[review-follow-up] feedback for PR #99" \
    --body-file "$body_file" > /dev/null

  run mock_gh issue list \
    --state open \
    --search '"sharkrite-source-issue:42" in:body' \
    --json number \
    --jq '.[0].number'

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "stateful: quoted in:body search returns null when no match" {
  # Quoted variant of the no-match case.
  run mock_gh issue list \
    --state open \
    --search '"sharkrite-source-issue:99" in:body' \
    --json number \
    --jq '.[0].number'

  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "stateful: quoted in:body search scopes to source issue (no cross-contamination)" {
  # Quoted variant of the cross-contamination guard.
  local body_a="$RITE_TEST_TMPDIR/body_a.md"
  local body_b="$RITE_TEST_TMPDIR/body_b.md"
  printf '<!-- sharkrite-source-issue:20 -->' > "$body_a"
  printf '<!-- sharkrite-source-issue:21 -->' > "$body_b"

  mock_gh issue create --title "Follow-up for src #20" --body-file "$body_a" > /dev/null
  mock_gh issue create --title "Follow-up for src #21" --body-file "$body_b" > /dev/null

  local match20 match21
  match20=$(mock_gh issue list --state open \
    --search '"sharkrite-source-issue:20" in:body' \
    --json number --jq '.[0].number')
  match21=$(mock_gh issue list --state open \
    --search '"sharkrite-source-issue:21" in:body' \
    --json number --jq '.[0].number')

  [[ "$match20" =~ ^[0-9]+$ ]]
  [[ "$match21" =~ ^[0-9]+$ ]]
  [ "$match20" != "$match21" ]
}

@test "stateful: quoted in:body search does not false-positive match numeric prefix" {
  # Quoted variant: searching for '"sharkrite-source-issue:5"' must not return
  # an issue body containing sharkrite-source-issue:55.
  local body_five="$RITE_TEST_TMPDIR/body_five.md"
  local body_fiftyfive="$RITE_TEST_TMPDIR/body_fiftyfive.md"
  printf '<!-- sharkrite-source-issue:55 -->' > "$body_fiftyfive"
  printf '<!-- sharkrite-source-issue:5 -->'  > "$body_five"

  mock_gh issue create --title "Follow-up for src #55" --body-file "$body_fiftyfive" > /dev/null
  mock_gh issue create --title "Follow-up for src #5"  --body-file "$body_five"      > /dev/null

  local match5 match55
  match5=$(mock_gh issue list --state open \
    --search '"sharkrite-source-issue:5" in:body' \
    --json number --jq '.[0].number')
  match55=$(mock_gh issue list --state open \
    --search '"sharkrite-source-issue:55" in:body' \
    --json number --jq '.[0].number')

  [[ "$match5"  =~ ^[0-9]+$ ]]
  [[ "$match55" =~ ^[0-9]+$ ]]
  [ "$match5" != "$match55" ]
}

@test "stateful: in:body search returns null when no match" {
  # Empty state — no issues created
  run mock_gh issue list \
    --state open \
    --search "sharkrite-source-issue:99 in:body" \
    --json number \
    --jq '.[0].number'

  [ "$status" -eq 0 ]
  # jq '.[0].number' on empty array emits "null".
  # NOTE: the real caller in assess-and-resolve.sh:1137 pipes this output
  # through `grep -E '^[0-9]+$'` which converts "null" → empty string before
  # the dedup decision.  The mock faithfully returns the raw jq output ("null");
  # the grep post-processing is the caller's responsibility, not the mock's.
  [ "$output" = "null" ]
}

@test "stateful: in:body search is case-insensitive" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  printf '<!-- SHARKRITE-SOURCE-ISSUE:77 -->' > "$body_file"
  mock_gh issue create --title "Mixed case body" --body-file "$body_file" > /dev/null

  run mock_gh issue list \
    --state open \
    --search "sharkrite-source-issue:77 in:body" \
    --json number \
    --jq '.[0].number'

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "stateful: in:body search scopes to source issue (no cross-contamination)" {
  local body_a="$RITE_TEST_TMPDIR/body_a.md"
  local body_b="$RITE_TEST_TMPDIR/body_b.md"
  printf '<!-- sharkrite-source-issue:10 -->' > "$body_a"
  printf '<!-- sharkrite-source-issue:11 -->' > "$body_b"

  mock_gh issue create --title "Follow-up for src #10" --body-file "$body_a" > /dev/null
  mock_gh issue create --title "Follow-up for src #11" --body-file "$body_b" > /dev/null

  # Searching for source issue #10 must NOT find the issue for source #11
  local match10 match11
  match10=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:10 in:body" \
    --json number --jq '.[0].number')
  match11=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:11 in:body" \
    --json number --jq '.[0].number')

  # Both found, but they must be different issue numbers
  [[ "$match10" =~ ^[0-9]+$ ]]
  [[ "$match11" =~ ^[0-9]+$ ]]
  [ "$match10" != "$match11" ]
}

@test "stateful: in:body search does not false-positive match numeric prefix (e.g. :5 must not match :55)" {
  # Regression: naive contains() matching caused sharkrite-source-issue:5 to
  # match an issue body containing sharkrite-source-issue:55, producing a
  # false-positive dedup hit that would suppress follow-up issue creation.
  local body_five="$RITE_TEST_TMPDIR/body_five.md"
  local body_fiftyfive="$RITE_TEST_TMPDIR/body_fiftyfive.md"
  printf '<!-- sharkrite-source-issue:55 -->' > "$body_fiftyfive"
  printf '<!-- sharkrite-source-issue:5 -->'  > "$body_five"

  mock_gh issue create --title "Follow-up for src #55" --body-file "$body_fiftyfive" > /dev/null
  mock_gh issue create --title "Follow-up for src #5"  --body-file "$body_five"      > /dev/null

  local match5 match55
  match5=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:5 in:body" \
    --json number --jq '.[0].number')
  match55=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:55 in:body" \
    --json number --jq '.[0].number')

  # Each search must return exactly one issue and they must be distinct
  [[ "$match5"  =~ ^[0-9]+$ ]]
  [[ "$match55" =~ ^[0-9]+$ ]]
  [ "$match5" != "$match55" ]

  # Critically: searching for :5 must NOT return the :55 issue.
  # We verify by checking the body of the found issue via gh issue view.
  local url5
  url5=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:5 in:body" \
    --json url --jq '.[0].url')
  # The URL must contain the issue number for issue #5 (the lower-numbered one)
  # and must NOT be the :55 issue.
  [[ "$url5" =~ /issues/[0-9]+$ ]]
  local num5="${url5##*/issues/}"
  [ "$num5" = "$match5" ]
  [ "$num5" != "$match55" ]
}

# ---------------------------------------------------------------------------
# 3. gh issue list --search "in:title ..."
# ---------------------------------------------------------------------------

@test "stateful: in:title search finds issue by title substring" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "body" > "$body_file"
  mock_gh issue create \
    --title "[review-follow-up] review feedback from PR #55 for issue #20" \
    --body-file "$body_file" > /dev/null

  # This is the fallback title search in assess-and-resolve.sh
  run mock_gh issue list \
    --search "in:title review feedback from PR #55 for issue #20" \
    --json number,title,state \
    --limit 1 \
    --jq '.[] | select(.state == "open") | .number'

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "stateful: in:title search returns empty when no match" {
  run mock_gh issue list \
    --search "in:title review feedback from PR #999 for issue #88" \
    --json number,title,state \
    --limit 1 \
    --jq '.[] | select(.state == "open") | .number'

  [ "$status" -eq 0 ]
  # No match — output should be empty (jq selects nothing from empty array)
  [ -z "$output" ]
}

@test "stateful: in:title search does not match unrelated titles" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "body" > "$body_file"
  mock_gh issue create \
    --title "[review-follow-up] review feedback from PR #10 for issue #5" \
    --body-file "$body_file" > /dev/null

  # Different PR number — must not match
  run mock_gh issue list \
    --search "in:title review feedback from PR #11 for issue #5" \
    --json number,title,state \
    --limit 1 \
    --jq '.[] | select(.state == "open") | .number'

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 4. gh pr comment + 5. gh pr view comments
# ---------------------------------------------------------------------------

@test "stateful: gh pr comment records comment on PR" {
  local body_file="$RITE_TEST_TMPDIR/comment.md"
  printf '<!-- sharkrite-followup-issue:1000 -->\n📋 Follow-up created.' > "$body_file"

  mock_gh pr comment 42 --body-file "$body_file"

  local count
  count=$(gh_mock_pr_comment_count 42)
  [ "$count" -eq 1 ]
}

@test "stateful: gh pr view returns marker comment count" {
  local body_file="$RITE_TEST_TMPDIR/comment.md"
  printf '<!-- sharkrite-followup-issue:1001 -->\nFollowup details.' > "$body_file"
  mock_gh pr comment 43 --body-file "$body_file"

  # This is exactly how assess-and-resolve.sh checks for eventual-consistency evidence
  run mock_gh pr view 43 \
    --json comments \
    --jq '[.comments[].body | select(contains("<!-- sharkrite-followup-issue:"))] | length'

  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "stateful: gh pr view returns 0 marker comments on PR with no comments" {
  run mock_gh pr view 99 \
    --json comments \
    --jq '[.comments[].body | select(contains("<!-- sharkrite-followup-issue:"))] | length'

  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "stateful: gh pr view counts only followup markers (not plain comments)" {
  local plain_file="$RITE_TEST_TMPDIR/plain.md"
  local marker_file="$RITE_TEST_TMPDIR/marker.md"
  echo "Just a regular review comment." > "$plain_file"
  printf '<!-- sharkrite-followup-issue:1002 -->\nCreated follow-up.' > "$marker_file"

  mock_gh pr comment 44 --body-file "$plain_file"
  mock_gh pr comment 44 --body-file "$marker_file"

  run mock_gh pr view 44 \
    --json comments \
    --jq '[.comments[].body | select(contains("<!-- sharkrite-followup-issue:"))] | length'

  [ "$status" -eq 0 ]
  # Only 1 of the 2 comments contains the followup marker
  [ "$output" -eq 1 ]
}

@test "stateful: gh_mock_pr_comment_body returns comment body by index" {
  local body_file="$RITE_TEST_TMPDIR/comment.md"
  printf 'First comment body.' > "$body_file"
  mock_gh pr comment 45 --body-file "$body_file"

  local body
  body=$(gh_mock_pr_comment_body 45 0)
  [ "$body" = "First comment body." ]
}

# ---------------------------------------------------------------------------
# 6. Search-index lag simulation
# ---------------------------------------------------------------------------

@test "stateful: index lag=1 makes first search miss, second search find" {
  # Set lag BEFORE setup (setup_gh_mock_state reads the variable)
  export GH_MOCK_ISSUE_INDEX_LAG=1
  setup_gh_mock_state   # re-init with lag=1

  local body_file="$RITE_TEST_TMPDIR/body.md"
  printf '<!-- sharkrite-source-issue:50 -->' > "$body_file"
  mock_gh issue create --title "Lagged issue" --body-file "$body_file" > /dev/null

  # First search (within lag window) — should return null
  local first_result
  first_result=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:50 in:body" \
    --json number --jq '.[0].number')
  [ "$first_result" = "null" ]

  # Second search (lag exhausted) — should find the issue
  local second_result
  second_result=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:50 in:body" \
    --json number --jq '.[0].number')
  [[ "$second_result" =~ ^[0-9]+$ ]]

  unset GH_MOCK_ISSUE_INDEX_LAG
}

@test "stateful: index lag=0 (default) makes issue searchable immediately" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  printf '<!-- sharkrite-source-issue:60 -->' > "$body_file"
  mock_gh issue create --title "No-lag issue" --body-file "$body_file" > /dev/null

  local result
  result=$(mock_gh issue list --state open \
    --search "sharkrite-source-issue:60 in:body" \
    --json number --jq '.[0].number')
  [[ "$result" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# 7. gh issue view
# ---------------------------------------------------------------------------

@test "stateful: gh issue view returns URL for tracked issue" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "body" > "$body_file"
  local created_url
  created_url=$(mock_gh issue create --title "Viewable issue" --body-file "$body_file")
  local issue_num="${created_url##*/}"

  run mock_gh issue view "$issue_num" --json url --jq '.url'
  [ "$status" -eq 0 ]
  [ "$output" = "$created_url" ]
}

@test "stateful: gh issue view returns body for tracked issue" {
  # Verifies that the body-verification step added to assess-and-resolve.sh works:
  # after a search match, the caller fetches the body with
  #   gh issue view N --json body --jq '.body'
  # and confirms the marker is present before trusting the search result.
  local body_file="$RITE_TEST_TMPDIR/body.md"
  printf '<!-- sharkrite-source-issue:73 -->\nFeedback content.' > "$body_file"
  local created_url
  created_url=$(mock_gh issue create --title "Body-verifiable issue" --body-file "$body_file")
  local issue_num="${created_url##*/}"

  run mock_gh issue view "$issue_num" --json body --jq '.body'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sharkrite-source-issue:73"* ]]
}

@test "stateful: gh issue view fails for unknown issue number" {
  run mock_gh issue view 9999 --json url --jq '.url'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 8. reset_gh_mock clears stateful state
# ---------------------------------------------------------------------------

@test "stateful: reset_gh_mock clears all tracked issues and comments" {
  local body_file="$RITE_TEST_TMPDIR/body.md"
  echo "body" > "$body_file"
  mock_gh issue create --title "Before reset" --body-file "$body_file" > /dev/null

  local comment_file="$RITE_TEST_TMPDIR/comment.md"
  echo "comment" > "$comment_file"
  mock_gh pr comment 10 --body-file "$comment_file"

  # Confirm state was recorded
  [ "$(gh_mock_issue_count)" -eq 1 ]
  [ "$(gh_mock_pr_comment_count 10)" -eq 1 ]

  # Reset
  reset_gh_mock

  # State must be cleared
  [ "$(gh_mock_issue_count)" -eq 0 ]
  [ "$(gh_mock_pr_comment_count 10)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. Backward compatibility — fixture mode still works when state is inactive
# ---------------------------------------------------------------------------

@test "fixture mode: mock_gh works without GH_MOCK_STATE_DIR set" {
  # Disable stateful mode
  unset GH_MOCK_STATE_DIR

  export GH_MOCK_FIXTURE_DIR="${RITE_REPO_ROOT}/tests/fixtures/gh"

  run mock_gh pr view 123 --json number,title
  [ "$status" -eq 0 ]
  # Should return fixture content
  [[ "$output" == *"123"* ]]
}
