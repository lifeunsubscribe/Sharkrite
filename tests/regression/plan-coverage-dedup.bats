#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-coverage-dedup.bats
#
# Regression test for phantom-dupe in coverage reconciliation.
#
# Bug: _validate_coverage called an LLM to resolve "phantom" checklist entries
# (✅ lines referencing titles not in emitted ---ISSUE--- blocks). The LLM
# phantom-resolver regenerated issues already present under slightly different
# titles; _dedup_issues then ran on the union but normalizes only case/whitespace,
# so semantic dupes slipped through.
#
# Real incidents: finance-glance planning runs where issue counts went 5→4 and 8→7
# after dedup, meaning the phantom resolver regenerated an issue that was already
# emitted under a variant title.
#
# Fix: _validate_coverage is now a deterministic pass:
#   1. Build canonical-title index from emitted issues (lowercase + trim).
#   2. Match each checklist title against the index (same canonicalization).
#   3. Matched → keep checklist line.
#   4. Unmatched → emit WARNING, strip orphan checklist line.
#   5. _dedup_issues runs after reconciliation as the single dedup source.
#   No LLM calls.
#
# Tests in this file:
#   A. Title with case/whitespace variation matches an emitted issue → zero
#      phantom warnings, N unique issues, no duplicates.
#      (Reproduces the finance-glance 5→4 scenario: LLM regenerated a title
#       it saw in lowercase in the checklist that was TitleCase in the block.)
#   B. Title in checklist has NO matching issue → one WARNING line to stderr,
#      orphan checklist line stripped, exit 0, no new issue generated.
#      (Reproduces the finance-glance 8→7 scenario: a genuine checklist orphan
#       that should just be logged and removed, not re-generated.)
#   C. No checklist section → function returns immediately (happy path).
#   D. Acceptance criteria: _validate_coverage makes zero provider_run calls.

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract _validate_coverage and _dedup_issues via awk so no top-level
# plan-issues.sh code (network calls, interactive prompts) runs.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Source portable-cmds.sh (provides portable_sed_i used by _validate_coverage)
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh"

  # Stub print_* functions so _validate_coverage output goes cleanly to stderr
  # without requiring colors.sh and terminal setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }

  # Extract _validate_coverage, _coverage_missing_titles, and _dedup_issues from
  # plan-issues.sh. The awk brace-depth tracker pulls each function body in full.
  # _coverage_missing_titles is a dependency of _validate_coverage (residual
  # reconciliation), so it must be extracted too.
  eval "$(awk '
    /^_validate_coverage\(\)/ { in_fn=1; depth=0 }
    /^_coverage_missing_titles\(\)/ { in_fn=1; depth=0 }
    /^_dedup_issues\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a fixture issues file
#
# Usage: write_fixture <file> [extra_block...]
#
# The file starts with a coverage-checklist preamble followed by zero or more
# ---ISSUE--- blocks appended as extra arguments (each must be a complete
# ---ISSUE--- ... ---END--- string).
# ---------------------------------------------------------------------------

write_fixture() {
  local file="$1"
  shift
  # Write preamble (coverage checklist) supplied via stdin-style heredoc in caller.
  # Here we just create the file; callers will append the blocks.
  printf '' > "$file"
  for block in "$@"; do
    printf '%s\n' "$block" >> "$file"
  done
}

# ---------------------------------------------------------------------------
# Fixture A — finance-glance 5→4 scenario
#
# Checklist references "implement budget tracking" (lowercase).
# Emitted block has TITLE: "Implement Budget Tracking" (title-case).
# _validate_coverage must recognise these as the same after canonicalization
# and emit NO warning, leaving issue count unchanged.
# ---------------------------------------------------------------------------

@test "Fixture A: case/whitespace variation in checklist matches emitted issue — no phantom warning" {
  local issues_file="$RITE_TEST_TMPDIR/issues-a.txt"

  # Preamble with coverage checklist referencing the title in lowercase
  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ Budget display → Issue "implement budget tracking"
- ✅ Transaction list → Issue "List Transactions"

---ISSUE---
TITLE: Implement Budget Tracking
LABELS: feature
TIME: 1hr
BODY:
Add a budget tracking screen.
---END---
---ISSUE---
TITLE: List Transactions
LABELS: feature
TIME: 30min
BODY:
Show transaction history.
---END---
FIXTURE

  # Run reconciler; capture stderr to check for WARNING lines.
  local stderr_out
  stderr_out=$(mktemp)
  _validate_coverage "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ]

  # Must emit NO WARNING lines (both checklist titles matched)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNING lines, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must still have exactly 2 issues
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 2 ] || {
    echo "FAIL: expected 2 issues, got $issue_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture B — finance-glance 8→7 scenario
#
# Checklist references "Add Notification Preferences" but no matching issue
# was emitted. The reconciler must:
#   - emit exactly one WARNING line to stderr
#   - strip the orphaned checklist line from the file
#   - exit 0
#   - NOT add any new issue (count stays the same)
# ---------------------------------------------------------------------------

@test "Fixture B: unmatched checklist title emits one WARNING, strips orphan, makes no new issue" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ User settings → Issue "Add User Settings Screen"
- ✅ Notifications → Issue "Add Notification Preferences"

---ISSUE---
TITLE: Add User Settings Screen
LABELS: feature
TIME: 1hr
BODY:
Implement the settings screen.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _validate_coverage "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ]

  # Must emit exactly one WARNING line for the missing title
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 WARNING line, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Warning must name the orphaned title
  grep -q "Add Notification Preferences" "$stderr_out" || {
    echo "FAIL: WARNING line does not mention the orphaned title" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issue count must remain 1 (no new issue generated)
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue after reconciliation, got $issue_count" >&2
    false
  }

  # Orphaned checklist line must be stripped from the file
  grep -q "Add Notification Preferences" "$issues_file" && {
    echo "FAIL: orphaned checklist line still present in output file" >&2
    false
  }

  # The matched checklist line must still be present
  grep -q "Add User Settings Screen" "$issues_file" || {
    echo "FAIL: matched checklist line was incorrectly removed" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture C — no checklist section → early return, file unchanged
# ---------------------------------------------------------------------------

@test "Fixture C: no coverage checklist returns immediately without modifying file" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Some Issue
LABELS: feature
TIME: 30min
BODY:
Just an issue with no checklist preamble.
---END---
FIXTURE

  local original_content
  original_content=$(cat "$issues_file")

  _validate_coverage "$issues_file"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  local current_content
  current_content=$(cat "$issues_file")
  [ "$original_content" = "$current_content" ] || {
    echo "FAIL: file was modified when it had no checklist" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture D — multi-orphan: two unmatched checklist entries produce two WARNINGs
# ---------------------------------------------------------------------------

@test "Fixture D: two orphaned checklist entries produce two WARNING lines" {
  local issues_file="$RITE_TEST_TMPDIR/issues-d.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ Feature alpha → Issue "Build Alpha Feature"
- ✅ Feature beta → Issue "Build Beta Feature"
- ✅ Feature gamma → Issue "Build Gamma Feature"

---ISSUE---
TITLE: Build Alpha Feature
LABELS: feature
TIME: 1hr
BODY:
Alpha implementation.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _validate_coverage "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 2 ] || {
    echo "FAIL: expected 2 WARNING lines, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issue count must remain 1
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue, got $issue_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture E — slash / regex-metacharacter title
#
# Checklist references a title containing forward slashes and other
# sed-regex metacharacters (e.g. "CI/CD pipeline setup").  The old
# portable_sed_i "/→ Issue \"$ref_title\"/d" interpolated the raw title
# into a sed address; a `/` in the title produced an unterminated address
# error that aborted _validate_coverage under set -euo pipefail.
#
# With the grep -vF fix the title is treated as a fixed string, so the
# slash is harmless.  The orphan line must be stripped and one WARNING
# emitted.
# ---------------------------------------------------------------------------

@test "Fixture E: checklist title with slashes/metacharacters strips orphan without sed error" {
  local issues_file="$RITE_TEST_TMPDIR/issues-e.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ Pipeline → Issue "CI/CD pipeline setup"
- ✅ Auth → Issue "Add Auth Module"

---ISSUE---
TITLE: Add Auth Module
LABELS: feature
TIME: 1hr
BODY:
Implement authentication.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _validate_coverage "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0 (no sed syntax error)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: _validate_coverage exited $exit_code — possible sed metacharacter crash" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly one WARNING (for the slash-title orphan)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 WARNING, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Orphaned checklist line must be stripped
  grep -q "CI/CD pipeline setup" "$issues_file" && {
    echo "FAIL: slash-title orphan line still present in output" >&2
    false
  }

  # The matched checklist line must remain
  grep -q "Add Auth Module" "$issues_file" || {
    echo "FAIL: matched checklist line was incorrectly removed" >&2
    false
  }

  # Issue count must remain 1
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue, got $issue_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture F — substring collision
#
# Checklist references "Add API" which is a strict prefix/substring of the
# emitted title "Add API Rate Limiting".  With unanchored grep -qF the
# shorter title matched the longer one, so a genuine orphan was silently
# swallowed.  With grep -qxF (whole-line) the match requires the full
# canonical string, so the shorter title is correctly treated as an orphan
# and one WARNING is emitted.
# ---------------------------------------------------------------------------

@test "Fixture F: substring checklist title is not falsely matched by longer emitted title" {
  local issues_file="$RITE_TEST_TMPDIR/issues-f.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ API integration → Issue "Add API"
- ✅ Rate limiting → Issue "Add API Rate Limiting"

---ISSUE---
TITLE: Add API Rate Limiting
LABELS: feature
TIME: 1hr
BODY:
Implement rate limiting for the API.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _validate_coverage "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # "Add API" has no matching issue (only "Add API Rate Limiting" was emitted).
  # Must emit exactly one WARNING for the substring orphan.
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 WARNING for substring orphan, got $warning_count" >&2
    echo "--- stderr ---" >&2
    cat "$stderr_out" >&2
    false
  }

  # Warning must name the shorter title
  grep -q "Add API\"" "$stderr_out" || grep -q "Add API'" "$stderr_out" || grep -q 'Add API' "$stderr_out" || {
    echo "FAIL: WARNING does not mention the orphaned title 'Add API'" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issue count must remain 1
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue, got $issue_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Acceptance criterion: _validate_coverage makes zero provider_run calls
# (structural check via grep on the source file)
# ---------------------------------------------------------------------------

@test "acceptance: _validate_coverage contains no provider_run calls" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # Extract just the _validate_coverage function body using awk
  local fn_body
  fn_body=$(awk '
    /^_validate_coverage\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # Must not contain any provider_run calls
  local provider_call_count
  provider_call_count=$(echo "$fn_body" | grep -c "provider_run" || true)

  [ "$provider_call_count" -eq 0 ] || {
    echo "FAIL: _validate_coverage contains $provider_call_count provider_run call(s)" >&2
    echo "$fn_body" | grep "provider_run" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance criterion: phantom_* variables are absent from the file
# ---------------------------------------------------------------------------

@test "acceptance: phantom_prompt, phantom_file, PHANTOM_EOF, clean_phantom absent from plan-issues.sh" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  local phantom_count
  phantom_count=$(grep -cE 'phantom_prompt|PHANTOM_EOF|phantom_file[^s]|clean_phantom' "$plan_issues_sh" || true)

  [ "$phantom_count" -eq 0 ] || {
    echo "FAIL: $phantom_count phantom_* reference(s) still present in plan-issues.sh" >&2
    grep -nE 'phantom_prompt|PHANTOM_EOF|phantom_file[^s]|clean_phantom' "$plan_issues_sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture G — zero-emission / truncated generation
#
# Real incident: finance-glance run 2026-06-09. The model produced a coverage
# checklist (7 ✅ entries) and a closing summary, then STOPPED before emitting
# any ---ISSUE--- block. The old reconciler treated all 7 as orphans: it emitted
# 7 "stripping orphan" warnings and reported "0 issues" with exit 0 — a truncated
# generation silently reported as success.
#
# Fix: when the checklist has ≥1 ✅ entry but ZERO ---ISSUE--- blocks were
# emitted, _validate_coverage must fail hard (exit non-zero) with a single error,
# not N orphan warnings. The caller aborts instead of "succeeding" with 0 issues.
# ---------------------------------------------------------------------------

@test "Fixture G: checklist entries with zero emitted issues — single hard error, non-zero exit" {
  local issues_file="$RITE_TEST_TMPDIR/issues-g.txt"

  # Coverage checklist with 3 ✅ entries, then NO ---ISSUE--- blocks at all.
  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ Harden glance parse → Issue "Harden glance parse for live contract"
- ✅ Due tab → Issue "Implement Due tab rendering"
- ✅ Worth tab → Issue "Implement Worth tab rendering"
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  # Capture the non-zero return inline so bats doesn't abort the test at this line.
  local exit_code=0
  _validate_coverage "$issues_file" 2>"$stderr_out" || exit_code=$?

  # Must fail hard (non-zero) so the caller aborts.
  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit on zero-emission, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly ONE error line — NOT one "stripping orphan" warning per entry.
  local error_count
  error_count=$(grep -c "^ERROR:" "$stderr_out" || true)
  [ "$error_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 ERROR line, got $error_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must NOT emit the per-entry orphan-stripping warnings (the old noisy behavior).
  local orphan_warnings
  orphan_warnings=$(grep -c "stripping orphan" "$stderr_out" || true)
  [ "$orphan_warnings" -eq 0 ] || {
    echo "FAIL: expected 0 'stripping orphan' warnings, got $orphan_warnings" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H — all-deferred plan (legitimate zero issues)
#
# A plan where every item is deferred (0 ✅ checklist entries) is a legitimate
# "nothing to create" outcome, NOT a truncation. The zero-emission guard keys on
# ✅ entries existing, so this must still return 0 (no false hard-fail).
# ---------------------------------------------------------------------------

@test "Fixture H: all-deferred checklist (no ✅ entries) — returns 0, not a hard-fail" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ⏭️ Multi-institution support → Deferred to Phase 4 (ADR D7)
- ⏭️ 3D-printed frame → Deferred to Phase 4 (ADR follow-up #7)
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _validate_coverage "$issues_file" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: all-deferred plan should return 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture I — partial emission (N planned, M<N emitted)
#
# Real incident: finance-glance run 2026-06-09 (13:02). The checklist planned 4
# issues but only 3 ---ISSUE--- blocks emitted; the 4th was silently stripped and
# the run proceeded with 3 — silently dropping a planned issue.
#
# After the generate_issues retry loop fails to recover, _validate_coverage must:
#   - NOT hard-fail (3 good issues must survive — don't nuke the slate)
#   - strip ONLY the dropped checklist line
#   - emit exactly one LOUD warning that names the dropped issue (not silent)
# ---------------------------------------------------------------------------

@test "Fixture I: partial emission (4 planned, 3 emitted) — one named warning, 3 issues survive, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-i.txt"

  cat > "$issues_file" <<'FIXTURE'
## Coverage Checklist

- ✅ Due tab → Issue "Implement Due tab draw routine"
- ✅ Worth tab → Issue "Implement Worth tab draw routine"
- ✅ Goals tab → Issue "Implement Goals tab draw routine"
- ✅ Hardware validation → Issue "On-hardware end-to-end validation pass"

---ISSUE---
TITLE: Implement Due tab draw routine
LABELS: firmware
TIME: 45min
BODY:
Due tab.
---END---
---ISSUE---
TITLE: Implement Worth tab draw routine
LABELS: firmware
TIME: 45min
BODY:
Worth tab.
---END---
---ISSUE---
TITLE: Implement Goals tab draw routine
LABELS: firmware
TIME: 30min
BODY:
Goals tab.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _validate_coverage "$issues_file" 2>"$stderr_out" || exit_code=$?

  # Must NOT hard-fail — 3 issues did emit.
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: partial emission should exit 0 (don't nuke the slate), got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Exactly one warning, naming the dropped issue.
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 warning for the dropped issue, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -q "On-hardware end-to-end validation pass" "$stderr_out" || {
    echo "FAIL: warning does not name the dropped issue" >&2
    cat "$stderr_out" >&2
    false
  }

  # The 3 emitted issues survive.
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 3 ] || {
    echo "FAIL: expected 3 surviving issues, got $issue_count" >&2
    false
  }

  # The dropped checklist line is stripped.
  grep -q "On-hardware end-to-end validation pass" "$issues_file" && {
    echo "FAIL: dropped checklist line was not stripped" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Acceptance: generate_issues retries on a truncated generation
#
# Guards the auto-retry that recovers from the finance-glance 2026-06-09 failure
# mode: the provider emits a COVERAGE checklist but 0 ---ISSUE--- blocks. Rather
# than accept it (the old break-on-non-empty behavior), generate_issues must
# detect zero issue markers + a COVERAGE checklist and re-issue with an escalated
# directive. Structural check (the loop embeds a live provider call, so a behavioral
# test would require a full provider mock + config bootstrap).
# ---------------------------------------------------------------------------

@test "acceptance: generate_issues retries when planned issue blocks are missing (M<N and M=0)" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^generate_issues\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  # Must gate the retry on the checklist-vs-emitted comparison (covers both the
  # partial M<N case and the M=0 truncation case), not a bare marker count.
  echo "$fn_body" | grep -q '_coverage_missing_titles "$temp_file"' || {
    echo "FAIL: generate_issues no longer compares checklist titles against emitted blocks" >&2
    false
  }
  # Must re-issue via the escalation prompt that NAMES the missing issues.
  echo "$fn_body" | grep -q 'RETRY — YOUR PREVIOUS RESPONSE WAS INCOMPLETE' || {
    echo "FAIL: generate_issues missing the escalation-retry directive" >&2
    false
  }
  echo "$fn_body" | grep -q '_missing_list' || {
    echo "FAIL: escalation directive no longer lists the specific missing issues" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: the base prompt's closing directive states the issue blocks are
# the required deliverable (prompt hardening against treating the checklist as
# the output).
# ---------------------------------------------------------------------------

@test "acceptance: prompt directive states issue blocks are the required deliverable" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  grep -q "The issue blocks are the required deliverable" "$plan_issues_sh" || {
    echo "FAIL: prompt no longer states the issue blocks are the required deliverable" >&2
    false
  }
}
