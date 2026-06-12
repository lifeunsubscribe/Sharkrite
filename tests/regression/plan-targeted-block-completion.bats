#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-targeted-block-completion.bats
#
# Regression tests for _request_missing_blocks in plan-issues.sh.
#
# Background: full-slate regeneration retries reproducibly truncate the same
# final block — three consecutive finance-glance `rite plan` runs (2026-06-09
# .. 2026-06-11, six full generations) dropped the last non-code-edit issue
# every time, and the escalated full-slate retry never recovered it. The fix
# is a targeted completion pass: when the kept slate has >=1 block but the
# COVERAGE checklist lists titles with no block, request ONLY the missing
# block(s) in a short follow-up call and append them.
#
# Contract under test:
#   1. Missing block + stub returns it -> appended, slate complete
#   2. Completion prompt asks only for the missing title(s) and lists emitted
#      ordinals so "After #N" refs resolve against the existing slate
#   3. Stub returns prose with no well-formed block -> slate unchanged, warning
#   4. Stub returns empty -> slate unchanged, warning
#   5. Nothing missing -> provider NOT called
#   6. Zero emitted blocks (checklist-only truncation) -> provider NOT called
#      (zero-emission hard error is _validate_coverage's job)

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub print_* functions so output goes cleanly without terminal setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }

  # Extract the functions under test from plan-issues.sh (same awk brace-depth
  # technique as plan-validator-strict.bats — no top-level code runs).
  local fn
  for fn in _request_missing_blocks _coverage_missing_titles _normalize_issue_markers; do
    eval "$(awk -v target="^${fn}\\\\(\\\\)" '
      $0 ~ target { in_fn=1; depth=0 }
      in_fn {
        for (i=1; i<=length($0); i++) {
          c=substr($0,i,1)
          if (c=="{") depth++
          if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
        }
        print; next
      }
    ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
  done

  # Provider stub: records the prompt it was called with, replies with a
  # canned response file. Existence of STUB_PROMPT_FILE == "provider called".
  export STUB_PROMPT_FILE="$RITE_TEST_TMPDIR/stub-prompt.txt"
  export STUB_RESPONSE_FILE="$RITE_TEST_TMPDIR/stub-response.txt"
  provider_run_streaming_prompt() {
    printf '%s' "$1" > "$STUB_PROMPT_FILE"
    cat "$STUB_RESPONSE_FILE" 2>/dev/null || true
  }
}

teardown() {
  teardown_test_tmpdir
}

# Helper: a slate whose checklist plans three issues but only two have blocks.
_write_partial_slate() {
  cat > "$1" <<'SLATE'
```
COVERAGE:
- ✅ Harden the parse → Issue "Harden glance parse" [own issue — foundational]
- ✅ Implement the Due tab → Issue "Implement Due tab"
- ✅ On-hardware validation → Issue "Validate on hardware"
```
---ISSUE---
TITLE: Harden glance parse
LABELS: phase-3,frontend,priority-high
TIME: 1hr
BODY:
**Description**: Parse hardening.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Implement Due tab
LABELS: phase-3,frontend,priority-medium
TIME: 1hr
BODY:
**Description**: Due tab.
**Dependencies**: After #1
---END---
SLATE
}

@test "missing block recovered: completion response appended, slate complete" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  _write_partial_slate "$slate"

  cat > "$STUB_RESPONSE_FILE" <<'RESPONSE'
---ISSUE---
TITLE: Validate on hardware
LABELS: phase-3,frontend,priority-medium
TIME: 1hr
BODY:
**Description**: End-to-end validation.
**Dependencies**: After #1, #2
---END---
RESPONSE

  local stderr_out
  stderr_out=$(mktemp)
  _request_missing_blocks "$slate" "BASE PROMPT" 2>"$stderr_out"

  # All three planned titles now have blocks
  [ "$(grep -c '^TITLE:' "$slate")" -eq 3 ] || {
    echo "FAIL: expected 3 TITLE lines after completion" >&2
    cat "$slate" >&2
    false
  }
  grep -qx "TITLE: Validate on hardware" "$slate" || {
    echo "FAIL: appended block's title missing from slate" >&2
    false
  }

  # Nothing left missing
  [ -z "$(_coverage_missing_titles "$slate")" ] || {
    echo "FAIL: checklist still reports missing titles" >&2
    false
  }

  # Success reported
  grep -q "recovered all" "$stderr_out" || {
    echo "FAIL: expected recovery success message" >&2
    cat "$stderr_out" >&2
    false
  }
  rm -f "$stderr_out"
}

@test "completion prompt asks only for the missing title and lists emitted ordinals" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  _write_partial_slate "$slate"

  cat > "$STUB_RESPONSE_FILE" <<'RESPONSE'
---ISSUE---
TITLE: Validate on hardware
LABELS: phase-3,frontend,priority-medium
TIME: 1hr
BODY:
**Description**: End-to-end validation.
**Dependencies**: After #1, #2
---END---
RESPONSE

  _request_missing_blocks "$slate" "BASE PROMPT" 2>/dev/null

  [ -f "$STUB_PROMPT_FILE" ] || { echo "FAIL: provider never called" >&2; false; }

  grep -q "TARGETED COMPLETION" "$STUB_PROMPT_FILE" || {
    echo "FAIL: completion directive missing from prompt" >&2
    false
  }
  # The missing title is named in the ask
  grep -q "Validate on hardware" "$STUB_PROMPT_FILE" || {
    echo "FAIL: missing title not named in completion prompt" >&2
    false
  }
  # Emitted ordinals are listed so After #N refs resolve
  grep -q "#1 Harden glance parse" "$STUB_PROMPT_FILE" || {
    echo "FAIL: emitted ordinal #1 not listed in completion prompt" >&2
    false
  }
  grep -q "#2 Implement Due tab" "$STUB_PROMPT_FILE" || {
    echo "FAIL: emitted ordinal #2 not listed in completion prompt" >&2
    false
  }
  # Already-emitted titles must appear only in the ordinal listing (the ask is
  # for the missing block only) — the base prompt is "BASE PROMPT" so the only
  # occurrences are the ordinal list itself.
  [ "$(grep -c "Harden glance parse" "$STUB_PROMPT_FILE")" -eq 1 ] || {
    echo "FAIL: emitted title repeated outside the ordinal listing" >&2
    false
  }
}

@test "prose-only completion response: slate unchanged, warning emitted" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  _write_partial_slate "$slate"

  cat > "$STUB_RESPONSE_FILE" <<'RESPONSE'
I looked at the codebase and here are my thoughts about the validation issue.
No structured block follows.
RESPONSE

  local stderr_out
  stderr_out=$(mktemp)
  _request_missing_blocks "$slate" "BASE PROMPT" 2>"$stderr_out"

  [ "$(grep -c '^TITLE:' "$slate")" -eq 2 ] || {
    echo "FAIL: slate changed despite no well-formed block in response" >&2
    false
  }
  grep -q "no well-formed issue block" "$stderr_out" || {
    echo "FAIL: expected no-well-formed-block warning" >&2
    cat "$stderr_out" >&2
    false
  }
  rm -f "$stderr_out"
}

@test "empty completion response: slate unchanged, warning emitted" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  _write_partial_slate "$slate"

  : > "$STUB_RESPONSE_FILE"

  local stderr_out
  stderr_out=$(mktemp)
  _request_missing_blocks "$slate" "BASE PROMPT" 2>"$stderr_out"

  [ "$(grep -c '^TITLE:' "$slate")" -eq 2 ] || {
    echo "FAIL: slate changed despite empty completion response" >&2
    false
  }
  grep -q "returned no output" "$stderr_out" || {
    echo "FAIL: expected no-output warning" >&2
    cat "$stderr_out" >&2
    false
  }
  rm -f "$stderr_out"
}

@test "fully covered checklist: provider is not called" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'SLATE'
```
COVERAGE:
- ✅ Harden the parse → Issue "Harden glance parse"
```
---ISSUE---
TITLE: Harden glance parse
LABELS: phase-3,frontend,priority-high
TIME: 1hr
BODY:
**Description**: Parse hardening.
**Dependencies**: None
---END---
SLATE

  _request_missing_blocks "$slate" "BASE PROMPT" 2>/dev/null

  [ ! -f "$STUB_PROMPT_FILE" ] || {
    echo "FAIL: provider called despite full coverage" >&2
    false
  }
}

@test "zero emitted blocks (checklist-only truncation): provider is not called" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'SLATE'
```
COVERAGE:
- ✅ Harden the parse → Issue "Harden glance parse"
- ✅ On-hardware validation → Issue "Validate on hardware"
```
SLATE

  _request_missing_blocks "$slate" "BASE PROMPT" 2>/dev/null

  [ ! -f "$STUB_PROMPT_FILE" ] || {
    echo "FAIL: provider called for zero-block slate (that is _validate_coverage's case)" >&2
    false
  }
}
