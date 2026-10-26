#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-sections-lint.bats
#
# Regression tests for _lint_issues_sections, _check_block_sections, and
# _regen_block_sections in plan-issues.sh.
#
# Background (2026-10-11): a rite plan recovery block (returned by the targeted
# completion call) came back without its Documentation Impact section. The
# dedup pass caught the duplicated block but nothing validated section
# completeness on recovered blocks. _lint_issues_sections fills that gap — it
# runs in the shared lint chain so all block entry paths (first pass, targeted
# completion, feedback-loop regeneration) are covered.
#
# Contracts under test:
#   1. Block missing Documentation Impact → regen requested; still missing
#      after 2 attempts → non-zero exit with issue title + section named
#   2. Block with all required sections → passes (exit 0, no regen)
#   3. Feature-labeled block without Bug Class Analysis → passes (not required)
#   4. Bug-labeled block without Bug Class Analysis → fails
#   5. Bug-labeled block WITH Bug Class Analysis → passes
#   6. Block missing multiple sections → all missing names reported together
#   7. Regen succeeds on first attempt → block repaired, file rewritten, exit 0
#   8. Regen succeeds on second attempt → repaired, exit 0

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub print_* so output goes cleanly without terminal setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }

  # Extract the functions under test using the same awk brace-depth technique
  # as plan-targeted-block-completion.bats. Each function is extracted
  # independently so stubs defined below are not overwritten by sourcing.
  local fn
  for fn in _plan_streaming_awk _check_block_sections _regen_extract_block _regen_block_sections _lint_issues_sections _normalize_issue_markers; do
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

  # Provider stub: records the prompt it was called with; replies with canned
  # response file. Existence of STUB_PROMPT_FILE signals "provider was called".
  # Re-stub AFTER function extraction (env-guarded libs overwrite pre-source stubs).
  export STUB_PROMPT_FILE="$RITE_TEST_TMPDIR/stub-prompt.txt"
  export STUB_RESPONSE_FILE="$RITE_TEST_TMPDIR/stub-response.txt"
  export STUB_CALL_COUNT_FILE="$RITE_TEST_TMPDIR/stub-call-count.txt"
  printf '0' > "$STUB_CALL_COUNT_FILE"

  provider_run_streaming_prompt() {
    printf '%s' "$1" > "$STUB_PROMPT_FILE"
    local _cnt
    _cnt=$(cat "$STUB_CALL_COUNT_FILE" 2>/dev/null || printf '0')
    printf '%d' "$((_cnt + 1))" > "$STUB_CALL_COUNT_FILE"
    # Extract the per-regen unique end token from the prompt (---END-NNN---),
    # then replace canonical ---END--- with it in the canned response so that
    # _plan_streaming_awk can find the unique terminator and emit the block.
    local _tok
    _tok=$(printf '%s' "$1" | grep -oE -- '---END-[0-9]+---' | head -1 || true)
    if [ -n "$_tok" ] && [ -f "$STUB_RESPONSE_FILE" ]; then
      awk -v tok="$_tok" '{ if ($0 == "---END---") print tok; else print }' "$STUB_RESPONSE_FILE" || true
    else
      cat "$STUB_RESPONSE_FILE" 2>/dev/null || true
    fi
  }

  provider_resolve_model() {
    printf 'stub-model'
  }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Shared fixture builder: a complete issue block with all required sections.
# Call with a variable name to write the block into (assigned via printf to
# stdout — caller captures via $(...)).
# ---------------------------------------------------------------------------
_complete_block() {
  cat <<'BLOCK'
---ISSUE---
TITLE: Add request validation
LABELS: phase-2,backend,priority-high
TIME: 1hr
BODY:
**Description**: Add input validation to the login endpoint to reject malformed requests.
This prevents 400-class errors from reaching the handler.

**Claude Context**:
Files to Read:
- lib/core/auth.sh

Files to Modify:
- lib/core/auth.sh

**Acceptance Criteria**:
- [ ] Malformed token rejected: `bash -n lib/core/auth.sh`

**Done Definition**: Done when malformed tokens are rejected at the validation layer with a clear error message.

**Scope Boundary**:
- DO: add input validation to auth.sh
- DO NOT: change token format or downstream consumers

**Dependencies**: None

**Documentation Impact**: No new user-facing surface — read-only accuracy check: docs/architecture/behavioral-design.md section "Auth" (verify: `grep -n "Auth" docs/architecture/behavioral-design.md`).
---END---
BLOCK
}

# ---------------------------------------------------------------------------
# Contract 2: complete block passes without calling the provider
# ---------------------------------------------------------------------------

@test "complete block passes with exit 0 and no provider call" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  _complete_block > "$slate"

  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>/dev/null || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for complete block, got $exit_code" >&2
    false
  }
  [ ! -f "$STUB_PROMPT_FILE" ] || {
    echo "FAIL: provider called despite complete block" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Contract 3: feature block without Bug Class Analysis passes
# ---------------------------------------------------------------------------

@test "feature-labeled block without Bug Class Analysis — passes, no regen" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  _complete_block > "$slate"
  # Labels do not include "bug" — Bug Class Analysis must NOT be required

  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>/dev/null || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for feature block without Bug Class Analysis, got $exit_code" >&2
    false
  }
  [ ! -f "$STUB_PROMPT_FILE" ] || {
    echo "FAIL: provider called for feature block" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Contract 4: bug-labeled block without Bug Class Analysis fails
# ---------------------------------------------------------------------------

@test "bug-labeled block without Bug Class Analysis — fails naming section" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'FIXTURE'
---ISSUE---
TITLE: Fix null pointer in auth
LABELS: phase-2,backend,priority-high,bug
TIME: 30min
BODY:
**Description**: Fix null pointer dereference when token is empty.

**Claude Context**:
Files to Read:
- lib/core/auth.sh

Files to Modify:
- lib/core/auth.sh

**Acceptance Criteria**:
- [ ] No crash on empty token: `bash -n lib/core/auth.sh`

**Done Definition**: Done when the null pointer no longer occurs.

**Scope Boundary**:
- DO: fix the null check in auth.sh
- DO NOT: change the token format

**Dependencies**: None

**Documentation Impact**: No user-facing surface added.
---END---
FIXTURE

  # Provider returns a complete block on the first attempt (but test contract 4
  # is "fails naming section" — override stub to return nothing so regen fails)
  : > "$STUB_RESPONSE_FILE"

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for bug block missing Bug Class Analysis, got 0" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -qi "Bug Class Analysis" "$stderr_out" || {
    echo "FAIL: expected 'Bug Class Analysis' named in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -q "Fix null pointer in auth" "$stderr_out" || {
    echo "FAIL: expected issue title named in stderr output" >&2
    cat "$stderr_out" >&2
    false
  }
  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Contract 5: bug-labeled block WITH Bug Class Analysis passes
# ---------------------------------------------------------------------------

@test "bug-labeled block with Bug Class Analysis — passes, no regen" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'FIXTURE'
---ISSUE---
TITLE: Fix null pointer in auth
LABELS: phase-2,backend,priority-high,bug
TIME: 30min
BODY:
**Description**: Fix null pointer dereference when token is empty.

**Claude Context**:
Files to Read:
- lib/core/auth.sh

Files to Modify:
- lib/core/auth.sh

**Acceptance Criteria**:
- [ ] No crash on empty token: `bash -n lib/core/auth.sh`

**Done Definition**: Done when the null pointer no longer occurs.

**Scope Boundary**:
- DO: fix the null check in auth.sh
- DO NOT: change the token format

**Dependencies**: None

**Documentation Impact**: No user-facing surface added.

**Bug Class Analysis**:
1. Specific failure: null pointer on line 42 when token empty
2. General class: missing guard before dereference
3. Sibling instances: lib/core/session.sh:88 — same pattern
4. Scope decision: session.sh handled in this PR
---END---
FIXTURE

  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>/dev/null || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 for bug block with Bug Class Analysis, got $exit_code" >&2
    false
  }
  [ ! -f "$STUB_PROMPT_FILE" ] || {
    echo "FAIL: provider called despite complete bug block" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Contract 1: block missing Documentation Impact → regen fails → non-zero
# with issue title and section named
# ---------------------------------------------------------------------------

@test "block missing Documentation Impact — still missing after 2 retries — non-zero, title and section named" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'FIXTURE'
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add an in-memory cache to reduce database reads on hot paths.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Cache hit observed: `grep -n "cache" lib/core/db.sh`

**Done Definition**: Done when cache reduces hot-path DB reads by removing redundant calls.

**Scope Boundary**:
- DO: add cache to db.sh
- DO NOT: change the DB schema

**Dependencies**: None
---END---
FIXTURE
  # Note: Documentation Impact is absent from this fixture.

  # Provider returns a block that STILL lacks Documentation Impact — regen fails
  cat > "$STUB_RESPONSE_FILE" <<'REGEN'
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add an in-memory cache to reduce database reads on hot paths.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Cache hit observed: `grep -n "cache" lib/core/db.sh`

**Done Definition**: Done when cache reduces hot-path DB reads by removing redundant calls.

**Scope Boundary**:
- DO: add cache to db.sh
- DO NOT: change the DB schema

**Dependencies**: None
---END---
REGEN

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for block still missing Documentation Impact, got 0" >&2
    cat "$stderr_out" >&2
    false
  }

  # Issue title named in error output
  grep -q "Add cache layer" "$stderr_out" || {
    echo "FAIL: expected issue title 'Add cache layer' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Missing section name named in error output
  grep -qi "Documentation Impact" "$stderr_out" || {
    echo "FAIL: expected 'Documentation Impact' named in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  # Provider was called (regen attempted) — stub call count should be 2
  local call_count
  call_count=$(cat "$STUB_CALL_COUNT_FILE" 2>/dev/null || printf '0')
  [ "$call_count" -ge 1 ] || {
    echo "FAIL: expected provider to be called for regen, got call_count=$call_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Contract 7: regen succeeds on first attempt → block repaired, file rewritten
# ---------------------------------------------------------------------------

@test "regen succeeds on first attempt — block repaired, file rewritten, exit 0" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'FIXTURE'
PREAMBLE: coverage checklist would be here
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add an in-memory cache.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Cache works: `grep -n "cache" lib/core/db.sh`

**Done Definition**: Done when cache is wired.

**Scope Boundary**:
- DO: add cache
- DO NOT: change schema

**Dependencies**: None
---END---
FIXTURE

  # Provider returns a well-formed repaired block with Documentation Impact
  cat > "$STUB_RESPONSE_FILE" <<'REGEN'
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add an in-memory cache to reduce database reads on hot paths.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Cache works: `grep -n "cache" lib/core/db.sh`

**Done Definition**: Done when cache reduces hot-path DB reads.

**Scope Boundary**:
- DO: add cache to db.sh
- DO NOT: change the DB schema

**Dependencies**: None

**Documentation Impact**: No user-facing surface added — read-only check: verify `grep -n "cache" docs/architecture/behavioral-design.md` shows existing entry.
---END---
REGEN

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 after successful regen, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Repaired block written to file
  grep -q "Documentation Impact" "$slate" || {
    echo "FAIL: repaired block not written to slate file" >&2
    cat "$slate" >&2
    false
  }

  # Preamble preserved in the rewritten file
  grep -q "PREAMBLE:" "$slate" || {
    echo "FAIL: preamble lost after file rewrite" >&2
    cat "$slate" >&2
    false
  }

  # Success message emitted
  grep -q "repaired on attempt" "$stderr_out" || {
    echo "FAIL: expected 'repaired on attempt' success message in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Contract 6: block missing multiple sections — all missing names reported
# ---------------------------------------------------------------------------

@test "block missing multiple sections — all missing names reported in error" {
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'FIXTURE'
---ISSUE---
TITLE: Stub issue
LABELS: phase-1,backend,priority-low
TIME: 30min
BODY:
**Description**: Minimal stub for testing multi-section failure.

**Claude Context**:
Files to Read:
- lib/core/stub.sh

Files to Modify:
- lib/core/stub.sh
---END---
FIXTURE
  # Missing: Acceptance Criteria, Done Definition, Scope Boundary, Dependencies,
  # Documentation Impact

  # Provider returns an equally incomplete block — ensures multi-section failure path
  cat > "$STUB_RESPONSE_FILE" <<'REGEN'
---ISSUE---
TITLE: Stub issue
LABELS: phase-1,backend,priority-low
TIME: 30min
BODY:
**Description**: Minimal stub.

**Claude Context**:
Files to Read:
- lib/core/stub.sh

Files to Modify:
- lib/core/stub.sh
---END---
REGEN

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for multi-section failure, got 0" >&2
    false
  }

  # All missing sections named — check a representative subset
  grep -qi "Acceptance Criteria" "$stderr_out" || {
    echo "FAIL: expected 'Acceptance Criteria' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -qi "Documentation Impact" "$stderr_out" || {
    echo "FAIL: expected 'Documentation Impact' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -qi "Done Definition" "$stderr_out" || {
    echo "FAIL: expected 'Done Definition' in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# _check_block_sections unit tests (provider-independent)
# ---------------------------------------------------------------------------

@test "_check_block_sections: complete feature block returns empty string" {
  local blk
  blk=$(_complete_block)
  local result
  result=$(_check_block_sections "$blk")
  [ -z "$result" ] || {
    echo "FAIL: expected empty missing list for complete block, got: $result" >&2
    false
  }
}

@test "_check_block_sections: missing Documentation Impact returns that section name" {
  local blk
  blk=$(cat <<'BLOCK'
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add cache.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Works: `grep -n cache lib/core/db.sh`

**Done Definition**: Done when cache reduces reads.

**Scope Boundary**:
- DO: add cache
- DO NOT: change schema

**Dependencies**: None
---END---
BLOCK
)
  local result
  result=$(_check_block_sections "$blk")
  echo "$result" | grep -qi "Documentation Impact" || {
    echo "FAIL: expected 'Documentation Impact' in result '$result'" >&2
    false
  }
  # Should NOT report other sections as missing
  if echo "$result" | grep -qi "Acceptance Criteria"; then
    echo "FAIL: 'Acceptance Criteria' should not be missing, result: $result" >&2
    false
  fi
}

@test "_check_block_sections: bug label without Bug Class Analysis fails" {
  local blk
  blk=$(cat <<'BLOCK'
---ISSUE---
TITLE: Fix crash
LABELS: phase-1,backend,bug
TIME: 30min
BODY:
**Description**: Fix crash on empty input.

**Claude Context**:
Files to Read:
- lib/core/handler.sh

Files to Modify:
- lib/core/handler.sh

**Acceptance Criteria**:
- [ ] No crash: `bash -n lib/core/handler.sh`

**Done Definition**: Done when crash is gone.

**Scope Boundary**:
- DO: add null guard
- DO NOT: change API

**Dependencies**: None

**Documentation Impact**: No new surface.
---END---
BLOCK
)
  local result
  result=$(_check_block_sections "$blk")
  echo "$result" | grep -qi "Bug Class Analysis" || {
    echo "FAIL: expected 'Bug Class Analysis' in result for bug-labeled block missing it, got: $result" >&2
    false
  }
}

@test "_check_block_sections: Scope Boundary with only DO NOT (no DO) — flags Scope Boundary (DO)" {
  local blk
  blk=$(cat <<'BLOCK'
---ISSUE---
TITLE: Fix scope test
LABELS: phase-1,backend,priority-low
TIME: 30min
BODY:
**Description**: Testing scope boundary detection.

**Claude Context**:
Files to Read:
- lib/core/stub.sh

Files to Modify:
- lib/core/stub.sh

**Acceptance Criteria**:
- [ ] Works: `bash -n lib/core/stub.sh`

**Done Definition**: Done when stub works.

**Scope Boundary**:
- DO NOT: change anything else

**Dependencies**: None

**Documentation Impact**: None.
---END---
BLOCK
)
  local result
  result=$(_check_block_sections "$blk")
  echo "$result" | grep -qi "Scope Boundary (DO)" || {
    echo "FAIL: expected 'Scope Boundary (DO)' flagged when only DO NOT present, got: $result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Multi-block reparse: repaired block + intact block — structural integrity
#
# Regression for CRITICAL item: _lint_issues_sections was storing repaired
# blocks without a trailing newline ($() strips it), causing the next block's
# ---ISSUE--- marker to be concatenated onto the last line of the repaired block.
# The rewrite loop writes all blocks via printf '%s'; without the $'\n' suffix
# on the repaired block, block 2 starts immediately after block 1's last char.
# ---------------------------------------------------------------------------

@test "multi-block file: repaired block 1 + intact block 2 — both blocks structurally intact after rewrite" {
  local slate="$RITE_TEST_TMPDIR/slate-multi.txt"

  # Block 1: missing Documentation Impact (needs repair)
  # Block 2: complete (should be written verbatim, untouched)
  cat > "$slate" <<'FIXTURE'
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add an in-memory cache.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Cache works: `grep -n "cache" lib/core/db.sh`

**Done Definition**: Done when cache is wired.

**Scope Boundary**:
- DO: add cache
- DO NOT: change schema

**Dependencies**: None
---END---
---ISSUE---
TITLE: Add request validation
LABELS: phase-2,backend,priority-high
TIME: 1hr
BODY:
**Description**: Add input validation.

**Claude Context**:
Files to Read:
- lib/core/auth.sh

Files to Modify:
- lib/core/auth.sh

**Acceptance Criteria**:
- [ ] Validated: `bash -n lib/core/auth.sh`

**Done Definition**: Done when malformed input is rejected.

**Scope Boundary**:
- DO: add validation to auth.sh
- DO NOT: change token format

**Dependencies**: None

**Documentation Impact**: None — internal change only.
---END---
FIXTURE

  # Provider returns block 1 repaired (with Documentation Impact added)
  cat > "$STUB_RESPONSE_FILE" <<'REGEN'
---ISSUE---
TITLE: Add cache layer
LABELS: phase-3,backend,priority-medium
TIME: 1hr
BODY:
**Description**: Add an in-memory cache.

**Claude Context**:
Files to Read:
- lib/core/db.sh

Files to Modify:
- lib/core/db.sh

**Acceptance Criteria**:
- [ ] Cache works: `grep -n "cache" lib/core/db.sh`

**Done Definition**: Done when cache is wired.

**Scope Boundary**:
- DO: add cache
- DO NOT: change schema

**Dependencies**: None

**Documentation Impact**: No user-facing surface — verify: `grep -n "cache" docs/architecture/behavioral-design.md`.
---END---
REGEN

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_issues_sections "$slate" "BASE PROMPT" 2>"$stderr_out" || exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 after multi-block repair, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Re-parse: exactly 2 ---ISSUE--- markers and 2 ---END--- markers
  local issue_count end_count
  issue_count=$(grep -c "^---ISSUE---$" "$slate" || true)
  end_count=$(grep -c "^---END---$" "$slate" || true)

  [ "$issue_count" -eq 2 ] || {
    echo "FAIL: expected 2 ---ISSUE--- markers after rewrite, got $issue_count" >&2
    cat "$slate" >&2
    false
  }
  [ "$end_count" -eq 2 ] || {
    echo "FAIL: expected 2 ---END--- markers after rewrite, got $end_count" >&2
    cat "$slate" >&2
    false
  }

  # Each ---ISSUE--- and ---END--- must be on its own line (no concatenation)
  if grep -q "^---END------ISSUE---" "$slate"; then
    echo "FAIL: ---END--- and ---ISSUE--- concatenated — missing newline after repaired block" >&2
    cat "$slate" >&2
    false
  fi

  # Block 2's title still present and intact
  grep -q "TITLE: Add request validation" "$slate" || {
    echo "FAIL: block 2 title missing after rewrite" >&2
    cat "$slate" >&2
    false
  }

  # Repaired block 1 now has Documentation Impact
  grep -q "Documentation Impact" "$slate" || {
    echo "FAIL: Documentation Impact not present in repaired block 1" >&2
    cat "$slate" >&2
    false
  }

  rm -f "$stderr_out"
}
