#!/usr/bin/env bats
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

  # Extract _validate_coverage and _dedup_issues from plan-issues.sh.
  # The awk brace-depth tracker pulls each function body in full.
  eval "$(awk '
    /^_validate_coverage\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
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
