#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/utils/create-followup-issues.sh, lib/utils/issue-lock.sh, lib/core/assess-review-issues.sh
# tests/regression/followup-evidence-write-failure.bats
#
# Regression test for the evidence write failure gap in the follow-up issue
# dedup guarantee.
#
# Bug: assess-and-resolve.sh posted the marker comment with
#   gh pr comment "$PR_NUMBER" --body-file ... 2>/dev/null || true
# which silently swallowed failures.  If the comment write failed AND the
# GitHub search index hadn't indexed the new issue yet, a waiting process
# would see no evidence of prior creation and create a duplicate.
#
# Fix: write a durable local evidence file (write_followup_evidence) to
# RITE_LOCK_DIR while the lock is still held, before any network call.
# Waiters check this file first (read_followup_evidence) — it's local FS,
# no network, and survives comment-write failures.
#
# Tests in this file:
#   1. write_followup_evidence creates the evidence file with the issue number
#   2. read_followup_evidence returns the issue number from the file
#   3. read_followup_evidence returns empty when no evidence exists
#   4. Evidence file is keyed by PR + source issue (independent scopes)
#   5. Evidence file key for PR-only (no source issue) differs from sourced key
#   6. Waiter reads local evidence and skips creation when comment write fails
#   7. Atomic write: evidence file is not partially visible (tmp+mv pattern)
#   8. Malformed evidence file (non-numeric) is treated as no evidence

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOCK_DIR="$RITE_TEST_TMPDIR/.rite/locks"

  mkdir -p "$RITE_LOCK_DIR"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Source the lock utilities (includes write_followup_evidence / read_followup_evidence)
  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  # Track "created" issues in a shared file (mirrors assess-and-resolve.sh pattern)
  export ISSUES_FILE="$RITE_TEST_TMPDIR/created-issues.txt"
  touch "$ISSUES_FILE"
}

teardown() {
  teardown_test_tmpdir
}

# ─── Unit tests: write_followup_evidence / read_followup_evidence ─────────────

@test "write_followup_evidence creates evidence file with issue number" {
  run write_followup_evidence 42 1234
  [ "$status" -eq 0 ]

  local evidence_file="$RITE_LOCK_DIR/pr-42-followup-created.txt"
  [ -f "$evidence_file" ] || {
    echo "FAIL: evidence file not created at $evidence_file"
    false
  }

  local contents
  contents=$(cat "$evidence_file")
  [ "$contents" = "1234" ] || {
    echo "FAIL: expected '1234', got '$contents'"
    false
  }
}

@test "read_followup_evidence returns issue number when evidence exists" {
  write_followup_evidence 43 5678

  local result
  result=$(read_followup_evidence 43)

  [ "$result" = "5678" ] || {
    echo "FAIL: expected '5678', got '$result'"
    false
  }
}

@test "read_followup_evidence returns empty when no evidence file exists" {
  local result
  result=$(read_followup_evidence 999)

  [ -z "$result" ] || {
    echo "FAIL: expected empty, got '$result'"
    false
  }
}

@test "evidence file is keyed by PR and source issue independently" {
  # Two different source issues on the same PR must produce separate evidence files
  write_followup_evidence 50 1001 10
  write_followup_evidence 50 1002 11

  local file_src10="$RITE_LOCK_DIR/pr-50-src-10-followup-created.txt"
  local file_src11="$RITE_LOCK_DIR/pr-50-src-11-followup-created.txt"

  [ -f "$file_src10" ] || {
    echo "FAIL: evidence file for source issue #10 not found"
    false
  }
  [ -f "$file_src11" ] || {
    echo "FAIL: evidence file for source issue #11 not found"
    false
  }

  local num_src10 num_src11
  num_src10=$(read_followup_evidence 50 10)
  num_src11=$(read_followup_evidence 50 11)

  [ "$num_src10" = "1001" ] || { echo "FAIL: src10 expected 1001, got $num_src10"; false; }
  [ "$num_src11" = "1002" ] || { echo "FAIL: src11 expected 1002, got $num_src11"; false; }
}

@test "PR-only evidence key differs from source-issue-keyed evidence key" {
  # PR-only and sourced writes must not overwrite each other
  write_followup_evidence 60 2001         # PR-only
  write_followup_evidence 60 2002 15      # sourced

  local result_pr_only result_sourced
  result_pr_only=$(read_followup_evidence 60)
  result_sourced=$(read_followup_evidence 60 15)

  [ "$result_pr_only" = "2001" ] || { echo "FAIL: PR-only expected 2001, got $result_pr_only"; false; }
  [ "$result_sourced" = "2002" ] || { echo "FAIL: sourced expected 2002, got $result_sourced"; false; }
}

# ─── Integration: waiter reads local evidence when comment write fails ─────────
#
# Simulates the edge case from the bug report:
#   Process A: acquires lock, creates issue, writes local evidence, attempts
#              comment post (fails, silently swallowed), releases lock.
#   Process B: acquires lock, checks local evidence (finds it), skips creation.
#
# Without the fix, Process B would find no evidence (no comment, index lagged)
# and create a duplicate.

# Helper: simulates assess-and-resolve.sh critical section WITH evidence write
# and a FAILING gh pr comment call.
run_create_with_failing_comment() {
  local pr_number="$1"
  local source_issue="${2:-}"

  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  local _lock_held=false
  if acquire_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null; then
    _lock_held=true
  fi

  # Check local evidence first (the fix)
  local existing
  existing=$(read_followup_evidence "$pr_number" "$source_issue" || true)

  if [ -z "$existing" ]; then
    # "Create" the issue
    local issue_num=9001
    echo "PR${pr_number}:${issue_num}" >> "$ISSUES_FILE"

    # Write durable local evidence BEFORE the comment (the fix)
    write_followup_evidence "$pr_number" "$issue_num" "$source_issue" 2>/dev/null || true

    # Simulate gh pr comment failing (||true pattern from original code)
    false || true  # comment "fails" silently
  fi

  [ "$_lock_held" = "true" ] && release_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null || true
}

# Helper: simulates the waiter process — same as above but checks evidence first
run_waiter_with_evidence_check() {
  local pr_number="$1"
  local source_issue="${2:-}"

  source "$RITE_LIB_DIR/utils/issue-lock.sh"

  local _lock_held=false
  if acquire_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null; then
    _lock_held=true
  fi

  # Check local evidence first (the fix: this is where the bug was)
  local existing
  existing=$(read_followup_evidence "$pr_number" "$source_issue" || true)

  if [ -z "$existing" ]; then
    # No evidence found — would create a duplicate (THIS IS THE BUG PATH)
    local issue_num=9002
    echo "PR${pr_number}:DUPLICATE:${issue_num}" >> "$ISSUES_FILE"
  fi
  # If evidence found, skip creation (correct behaviour)

  [ "$_lock_held" = "true" ] && release_pr_followup_lock "$pr_number" "$source_issue" 2>/dev/null || true
}

@test "waiter reads local evidence and skips creation when comment write fails" {
  local pr_number=70

  # Process A: creates issue, writes evidence, comment "fails"
  run_create_with_failing_comment "$pr_number"

  # Verify evidence was written (lock is now released)
  local evidence
  evidence=$(read_followup_evidence "$pr_number")
  [ -n "$evidence" ] || {
    echo "FAIL: evidence not written by Process A"
    false
  }

  # Process B: waiter — should find local evidence and skip creation
  run_waiter_with_evidence_check "$pr_number"

  # Only one entry should exist — no duplicate
  local total
  total=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || true)
  [ "$total" -eq 1 ] || {
    echo "FAIL: expected 1 issue entry, got $total (duplicate created)"
    cat "$ISSUES_FILE"
    false
  }

  # Specifically: no DUPLICATE entry
  local dup_count
  dup_count=$(grep -c "^PR${pr_number}:DUPLICATE:" "$ISSUES_FILE" 2>/dev/null || true)
  [ "$dup_count" -eq 0 ] || {
    echo "FAIL: duplicate entry found in issues file"
    cat "$ISSUES_FILE"
    false
  }
}

@test "waiter reads local evidence for source-issue-keyed lock when comment fails" {
  local pr_number=71
  local source_issue=42

  run_create_with_failing_comment "$pr_number" "$source_issue"

  local evidence
  evidence=$(read_followup_evidence "$pr_number" "$source_issue")
  [ -n "$evidence" ] || {
    echo "FAIL: evidence not written for sourced lock"
    false
  }

  run_waiter_with_evidence_check "$pr_number" "$source_issue"

  local total
  total=$(grep -c "^PR${pr_number}:" "$ISSUES_FILE" 2>/dev/null || true)
  [ "$total" -eq 1 ] || {
    echo "FAIL: expected 1 issue entry for (PR $pr_number, src $source_issue), got $total"
    cat "$ISSUES_FILE"
    false
  }
}

# ─── Atomic write guard ────────────────────────────────────────────────────────
#
# The evidence write uses a tmp-then-mv pattern so readers never see a partial
# file.  Verify that the final file contains exactly the issue number (no
# truncated or partial writes visible).

@test "evidence file write is atomic: final file contains only the issue number" {
  write_followup_evidence 80 3333

  local evidence_file="$RITE_LOCK_DIR/pr-80-followup-created.txt"
  [ -f "$evidence_file" ]

  # File must contain exactly one line: the issue number
  local line_count
  line_count=$(wc -l < "$evidence_file" | tr -d ' ')
  [ "$line_count" -eq 1 ] || {
    echo "FAIL: expected 1 line, got $line_count"
    cat -A "$evidence_file"
    false
  }

  local content
  content=$(cat "$evidence_file")
  [[ "$content" =~ ^[0-9]+$ ]] || {
    echo "FAIL: file content '$content' is not a plain integer"
    false
  }
}

# ─── Malformed evidence file ───────────────────────────────────────────────────
#
# If the evidence file exists but contains non-numeric data (e.g., truncated
# write from a crash mid-mv, or manually created test artifact), read_followup_evidence
# should return empty rather than propagating garbage into the dedup check.

@test "malformed evidence file (non-numeric) is treated as no evidence" {
  local evidence_file="$RITE_LOCK_DIR/pr-90-followup-created.txt"
  # Write intentionally malformed content
  printf 'not-a-number\n' > "$evidence_file"

  local result
  result=$(read_followup_evidence 90)

  [ -z "$result" ] || {
    echo "FAIL: expected empty for malformed file, got '$result'"
    false
  }
}

# ─── derive_followup_finding_key — canonical per-finding key (issue #729) ──────
#
# These tests verify that derive_followup_finding_key produces a stable, consistent
# key from (source_issue, title, finding_index) so that evidence written by
# assess-review-issues.sh is readable by _followup_dedup_check Source 1 in
# assess-and-resolve.sh (and vice versa).

@test "derive_followup_finding_key produces consistent key for same inputs" {
  local key1 key2
  key1=$(derive_followup_finding_key 42 "Fix the flaky test harness" 1)
  key2=$(derive_followup_finding_key 42 "Fix the flaky test harness" 1)
  [ "$key1" = "$key2" ] || {
    echo "FAIL: same inputs produced different keys: '$key1' vs '$key2'"
    false
  }
}

@test "derive_followup_finding_key embeds source issue number in key" {
  local key
  key=$(derive_followup_finding_key 99 "Some title" 1)
  echo "$key" | grep -q "^99-" || {
    echo "FAIL: key '$key' does not start with source issue '99-'"
    false
  }
}

@test "derive_followup_finding_key embeds finding_index in key" {
  local key1 key2
  key1=$(derive_followup_finding_key 10 "Identical title" 1)
  key2=$(derive_followup_finding_key 10 "Identical title" 2)
  [ "$key1" != "$key2" ] || {
    echo "FAIL: different indices produced same key '$key1' — index collision not disambiguated"
    false
  }
  echo "$key1" | grep -q "\-1$" || {
    echo "FAIL: key '$key1' does not end with '-1' (finding_index 1)"
    false
  }
  echo "$key2" | grep -q "\-2$" || {
    echo "FAIL: key '$key2' does not end with '-2' (finding_index 2)"
    false
  }
}

@test "derive_followup_finding_key slugifies title (lowercases and replaces non-alnum)" {
  local key
  key=$(derive_followup_finding_key 5 "Fix: Foo Bar / Baz (2026)" 1)
  # Key format: "<src>-<slug>-<idx>"; slug must be lowercase alnum+dash only
  local slug
  slug=$(echo "$key" | sed 's/^5-//; s/-[0-9]*$//')
  echo "$slug" | grep -qE '^[a-z0-9-]+$' || {
    echo "FAIL: slug '$slug' contains non-alnum/dash chars"
    false
  }
  # Must not contain uppercase
  echo "$slug" | grep -q '[A-Z]' && {
    echo "FAIL: slug '$slug' contains uppercase chars"
    false
  }
  true
}

@test "derive_followup_finding_key truncates slug to 40 chars" {
  local long_title="This is a very long finding title that exceeds forty characters by quite a margin"
  local key
  key=$(derive_followup_finding_key 7 "$long_title" 1)
  local slug
  slug=$(echo "$key" | sed 's/^7-//; s/-[0-9]*$//')
  local slug_len=${#slug}
  [ "$slug_len" -le 40 ] || {
    echo "FAIL: slug length $slug_len exceeds 40 chars: '$slug'"
    false
  }
}

@test "derive_followup_finding_key falls back to 'finding-N' when title produces empty slug" {
  # A title consisting entirely of non-alnum chars (e.g. "---") produces an empty slug.
  # The function must fall back to "finding-<idx>" to avoid a degenerate "0--1" key.
  local key
  key=$(derive_followup_finding_key 3 "---" 2)
  echo "$key" | grep -q "finding-2" || {
    echo "FAIL: key '$key' does not contain 'finding-2' fallback"
    false
  }
}

@test "derive_followup_finding_key keys match between source-issue 0 and empty source" {
  # Callers may pass empty string or "0" for unknown source issue — both must
  # produce the same key so assess-and-resolve.sh (_FOLLOWUP_FINDING_KEY default
  # ISSUE_NUMBER:-0) and assess-review-issues.sh (RITE_ISSUE_NUMBER:-0) agree.
  local key_zero key_empty
  key_zero=$(derive_followup_finding_key 0 "Test title" 1)
  key_empty=$(derive_followup_finding_key "" "Test title" 1)
  [ "$key_zero" = "$key_empty" ] || {
    echo "FAIL: source_issue '0' and '' produce different keys: '$key_zero' vs '$key_empty'"
    false
  }
}
