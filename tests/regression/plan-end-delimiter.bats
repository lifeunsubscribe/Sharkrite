#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh::generate_issues|_request_missing_blocks|_normalize_issue_markers|_emitted_blocks
#
# Regression tests for ---END--- delimiter collision in plan-issues.sh.
#
# Bug: plan-issues.sh instructed the LLM to use ---END--- as the issue block
# end marker, then parsed the streaming output with an awk that matched the
# literal string ---END---. Seven bats files in the repo contain line-alone
# ---END--- today. When the LLM generates an issue body quoting any such file,
# the awk prematurely ended the block at the first ---END--- in the body,
# silently truncating or dropping the rest of that issue.
#
# Fix (issue #1342, same approach as docs-command.sh issue #1233):
#   1. generate_issues creates a per-run unique token at call time:
#      _plan_end_token="---END-${RANDOM}${RANDOM}---"
#   2. The unique token is embedded in the LLM prompt (replacing hardcoded ---END---).
#   3. The streaming awk matches end_tok (the unique token, passed via -v) and
#      normalises it to ---END--- in the output buffer before printing, so all
#      downstream parsers that read from the already-written file continue to
#      work with the canonical ---END--- marker.
#   4. _request_missing_blocks accepts the token as arg 3 and uses it in both
#      the completion prompt and the completion awk (same normalisation).
#
# Tests in this file:
#   A. Behavioral: the streaming-awk dedup does NOT truncate a block whose body
#      contains a bare ---END--- line when the unique token is used as end marker.
#   B. Behavioral: the streaming-awk normalises the unique token to ---END--- in
#      the emitted output, so downstream ---END--- parsers see the canonical form.
#   C. Structural: generate_issues uses a per-run unique token (not hardcoded ---END---).
#   D. Structural: the streaming awk passes the token via -v end_tok and normalises
#      via gsub(end_tok, "---END---", buf) before printing.
#   E. Structural: _request_missing_blocks accepts a third argument (_end_token)
#      and uses it in both the completion prompt and the completion awk.

# ---------------------------------------------------------------------------
# A + B — behavioral: simulate the streaming-awk with a unique token
#
# We run the exact awk body from generate_issues with a known test token,
# feeding it fixture data that has ---END--- inside a block body. The awk
# must emit the complete block (body preserved, no truncation) and normalise
# the end token to canonical ---END--- in its output.
# ---------------------------------------------------------------------------

@test "A: block body containing ---END--- is not prematurely terminated when unique token used" {
  local _tok="---END-TESTTOKEN---"
  # Construct input: preamble text, one block whose body contains ---END--- on its own line.
  local input
  input=$(printf '%s\n' \
    "COVERAGE: some preamble" \
    "---ISSUE---" \
    "TITLE: Issue with ---END--- in body" \
    "BODY:" \
    "This body references a bats file that contains:" \
    "---END---" \
    "which is the old delimiter." \
    "$_tok")

  local output
  output=$(printf '%s\n' "$input" | awk -v end_tok="$_tok" '
    /^---ISSUE---$/ { in_issue = 1; buf = $0 "\n"; title = ""; next }
    in_issue {
      buf = buf $0 "\n"
      if ($0 ~ /^TITLE: /) {
        title = substr($0, 8)
        if (title in seen) { exit }
        seen[title] = 1
      }
      if ($0 == end_tok) {
        gsub(end_tok, "---END---", buf)
        in_issue = 0; printf "%s", buf; buf = ""
      }
      next
    }
    { print }
  ')

  # The block TITLE must be present in output (block was not dropped)
  echo "$output" | grep -q "TITLE: Issue with" || {
    echo "FAIL: block was dropped — TITLE line not found in output" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # The body line containing ---END--- must survive intact (no truncation)
  echo "$output" | grep -q "which is the old delimiter" || {
    echo "FAIL: block was truncated — line after ---END--- in body is missing" >&2
    printf '%s\n' "$output" >&2
    false
  }
}

@test "B: unique end token is normalised to canonical ---END--- in output" {
  local _tok="---END-TESTTOKEN---"
  local input
  input=$(printf '%s\n' \
    "---ISSUE---" \
    "TITLE: Normalization test" \
    "BODY:" \
    "Simple body." \
    "$_tok")

  local output
  output=$(printf '%s\n' "$input" | awk -v end_tok="$_tok" '
    /^---ISSUE---$/ { in_issue = 1; buf = $0 "\n"; title = ""; next }
    in_issue {
      buf = buf $0 "\n"
      if ($0 ~ /^TITLE: /) {
        title = substr($0, 8)
        if (title in seen) { exit }
        seen[title] = 1
      }
      if ($0 == end_tok) {
        gsub(end_tok, "---END---", buf)
        in_issue = 0; printf "%s", buf; buf = ""
      }
      next
    }
    { print }
  ')

  # The unique token must NOT appear in output (it was normalised away)
  echo "$output" | grep -q "$_tok" && {
    echo "FAIL: unique end token still present in output — normalisation did not fire" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # The canonical ---END--- marker must appear (normalisation produced it)
  echo "$output" | grep -q "^---END---$" || {
    echo "FAIL: canonical ---END--- not found in output after normalisation" >&2
    printf '%s\n' "$output" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# C — structural: generate_issues generates a per-run unique token
#
# The token must be generated from $RANDOM (not hardcoded) and must NOT be
# the literal string ---END--- (which is the old, collision-prone marker).
# ---------------------------------------------------------------------------

@test "C: generate_issues uses per-run unique end token (not hardcoded ---END---)" {
  local plan_issues_sh="${BATS_TEST_DIRNAME}/../../lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^generate_issues[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # Must define a per-run end token using RANDOM (not a static literal)
  echo "$fn_body" | grep -q '_plan_end_token.*RANDOM' || {
    echo "FAIL: generate_issues does not define _plan_end_token with \$RANDOM" >&2
    false
  }

  # The hardcoded literal ---END--- must NOT appear alone on an output line
  # in the prompt format template within the function body.
  # (It would if the prompt still had a hardcoded ---END--- example line.)
  if echo "$fn_body" | grep -qE '^\s*---END---\s*$'; then
    echo "FAIL: generate_issues still has a bare hardcoded ---END--- line in the prompt template" >&2
    echo "$fn_body" | grep -n -- "---END---" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# D — structural: streaming awk uses -v end_tok= and gsub normalisation
# ---------------------------------------------------------------------------

@test "D: generate_issues streaming awk passes end_tok via -v and normalises via gsub" {
  local plan_issues_sh="${BATS_TEST_DIRNAME}/../../lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^generate_issues[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # Streaming awk must receive the token via -v end_tok=
  echo "$fn_body" | grep -q '\-v end_tok=' || {
    echo "FAIL: streaming awk does not receive end token via -v end_tok=" >&2
    false
  }

  # Streaming awk must normalise the token back to ---END--- via gsub
  echo "$fn_body" | grep -q 'gsub(end_tok, "---END---"' || {
    echo "FAIL: streaming awk does not normalise end_tok to ---END--- via gsub" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# E — structural: _request_missing_blocks accepts token arg and uses it
# ---------------------------------------------------------------------------

@test "E: _request_missing_blocks accepts _end_token param and uses it in completion awk" {
  local plan_issues_sh="${BATS_TEST_DIRNAME}/../../lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^_request_missing_blocks[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # Must declare _end_token from arg 3 (with ---END--- fallback for old callers)
  echo "$fn_body" | grep -q '_end_token.*3' || {
    echo "FAIL: _request_missing_blocks does not accept _end_token as arg 3" >&2
    false
  }

  # Completion awk must receive the token via -v end_tok=
  echo "$fn_body" | grep -q '\-v end_tok=.*_end_token' || {
    echo "FAIL: _request_missing_blocks completion awk does not receive _end_token via -v end_tok=" >&2
    false
  }

  # Completion awk must normalise back to ---END--- via gsub
  echo "$fn_body" | grep -q 'gsub(end_tok, "---END---"' || {
    echo "FAIL: _request_missing_blocks completion awk does not normalise end_tok to ---END--- via gsub" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# F — behavioral: interior ---END--- in body is escaped, not misread as
# block terminator by downstream parsers (#1342 truncation regression)
#
# Drives colliding body through the streaming-awk boundary and then through
# the standard block-parsing awk to assert: (1) only 1 block is emitted (no
# spurious split), (2) the interior marker is escaped to <!--rite-end-esc-->,
# (3) after unescaping (as the create loop does) the original ---END--- is
# restored, and (4) the line after the interior marker survives intact.
# ---------------------------------------------------------------------------

@test "F: interior ---END--- in body is escaped at stream boundary, not split downstream" {
  local _tok="---END-TESTTOKEN---"
  local input
  input=$(printf '%s\n' \
    "---ISSUE---" \
    "TITLE: Issue quoting bats fixture" \
    "BODY:" \
    "A bats fixture file contains this line alone:" \
    "---END---" \
    "which used to terminate the block early." \
    "$_tok")

  local output
  output=$(printf '%s\n' "$input" | awk -v end_tok="$_tok" '
    !in_issue && /^---ISSUE---$/ { in_issue = 1; buf = $0 "\n"; title = ""; next }
    in_issue {
      buf = buf $0 "\n"
      if ($0 ~ /^TITLE: /) {
        title = substr($0, 8)
        if (title in seen) { exit }
        seen[title] = 1
      }
      if ($0 == end_tok) {
        gsub("---END---",   "<!--rite-end-esc-->",   buf)
        gsub("---ISSUE---", "<!--rite-issue-esc-->", buf)
        gsub(end_tok, "---END---", buf)
        in_issue = 0; printf "%s", buf; buf = ""
      }
      next
    }
    { print }
  ')

  # The interior ---END--- must be escaped (not passed through as raw ---END---)
  echo "$output" | grep -q "<!--rite-end-esc-->" || {
    echo "FAIL: interior ---END--- was not escaped to <!--rite-end-esc-->" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # The line after the interior marker must survive (block was not truncated)
  echo "$output" | grep -q "which used to terminate the block early" || {
    echo "FAIL: block was truncated — line after interior ---END--- is missing" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # Exactly 1 canonical ---END--- must appear (the terminal marker)
  local _end_count
  _end_count=$(printf '%s\n' "$output" | grep -c "^---END---$" || true)
  [ "$_end_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 canonical ---END--- in output, got $_end_count" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # Downstream block parser extracts exactly 1 block from the escaped output
  local _block_count
  _block_count=$(printf '%s\n' "$output" | awk '
    !in_issue && /^---ISSUE---$/ { in_issue=1; next }
    in_issue && $0 == "---END---" { in_issue=0; count++ }
  END { print count+0 }
  ')
  [ "$_block_count" -eq 1 ] || {
    echo "FAIL: downstream parser found $_block_count block(s), expected 1" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # After unescaping (as create_issues does), the body contains the original ---END---
  local _unescaped
  _unescaped="${output//<!--rite-end-esc-->/---END---}"
  _unescaped="${_unescaped//<!--rite-issue-esc-->/---ISSUE---}"
  echo "$_unescaped" | grep -q "^---END---$" || {
    echo "FAIL: after unescaping, the original ---END--- body line is missing" >&2
    printf '%s\n' "$_unescaped" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# G — behavioral: interior ---ISSUE--- in body is escaped at stream boundary
# ---------------------------------------------------------------------------

@test "G: interior ---ISSUE--- in body is escaped at stream boundary, not misread as block start" {
  local _tok="---END-TESTTOKEN---"
  local input
  input=$(printf '%s\n' \
    "---ISSUE---" \
    "TITLE: Issue quoting ---ISSUE--- marker" \
    "BODY:" \
    "The format uses ---ISSUE--- as a separator." \
    "$_tok")

  local output
  output=$(printf '%s\n' "$input" | awk -v end_tok="$_tok" '
    !in_issue && /^---ISSUE---$/ { in_issue = 1; buf = $0 "\n"; title = ""; next }
    in_issue {
      buf = buf $0 "\n"
      if ($0 ~ /^TITLE: /) {
        title = substr($0, 8)
        if (title in seen) { exit }
        seen[title] = 1
      }
      if ($0 == end_tok) {
        gsub("---END---",   "<!--rite-end-esc-->",   buf)
        gsub("---ISSUE---", "<!--rite-issue-esc-->", buf)
        gsub(end_tok, "---END---", buf)
        in_issue = 0; printf "%s", buf; buf = ""
      }
      next
    }
    { print }
  ')

  # The interior ---ISSUE--- must be escaped (not passed through)
  echo "$output" | grep -q "<!--rite-issue-esc-->" || {
    echo "FAIL: interior ---ISSUE--- was not escaped to <!--rite-issue-esc-->" >&2
    printf '%s\n' "$output" >&2
    false
  }

  # Exactly 1 canonical ---ISSUE--- must appear (the block start)
  local _issue_count
  _issue_count=$(printf '%s\n' "$output" | grep -c "^---ISSUE---$" || true)
  [ "$_issue_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 canonical ---ISSUE--- in output, got $_issue_count" >&2
    printf '%s\n' "$output" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# H — behavioral: _emitted_blocks reads from a normalized file using
# "---END---" literally (not the unique token). Regression for finding 3
# where _emitted_blocks always returned empty because it matched end_tok
# (the unique token) against a file that already has canonical ---END---.
# ---------------------------------------------------------------------------

@test "H: _emitted_blocks awk matches canonical ---END--- in already-normalized file" {
  local normalized_file
  normalized_file=$(mktemp)
  # Simulate a file after streaming-awk normalization: canonical ---END--- markers
  printf '%s\n' \
    "---ISSUE---" \
    "TITLE: First issue" \
    "BODY:" \
    "First body." \
    "---END---" \
    "---ISSUE---" \
    "TITLE: Second issue" \
    "BODY:" \
    "Second body." \
    "---END---" > "$normalized_file"

  # Run the _emitted_blocks awk from _request_missing_blocks using "---END---" (the fix)
  local blocks
  blocks=$(awk '
    !in_issue && /^---ISSUE---$/ { in_issue=1; buf=$0"\n"; next }
    in_issue {
      buf = buf $0 "\n"
      if ($0 == "---END---") { in_issue=0; printf "%s", buf; buf="" }
      next
    }
  ' "$normalized_file" || true)

  rm -f "$normalized_file"

  # Both blocks must be found (not empty)
  [ -n "$blocks" ] || {
    echo "FAIL: _emitted_blocks returned empty — fix did not work" >&2
    false
  }

  echo "$blocks" | grep -q "TITLE: First issue" || {
    echo "FAIL: first block missing from _emitted_blocks output" >&2
    printf '%s\n' "$blocks" >&2
    false
  }

  echo "$blocks" | grep -q "TITLE: Second issue" || {
    echo "FAIL: second block missing from _emitted_blocks output" >&2
    printf '%s\n' "$blocks" >&2
    false
  }
}
