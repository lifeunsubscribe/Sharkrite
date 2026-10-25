#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh::generate_issues|_request_missing_blocks|_regen_block_sections
# tests/regression/plan-end-delimiter-unique.bats
#
# Regression tests for the per-generation unique end token in plan-issues.sh
# (#1342 — same fix class as docs-command.sh #1233).
#
# Bug: plan-issues.sh used the hardcoded string ---END--- as the LLM output
# delimiter.  Seven bats files in the repo contain line-alone ---END--- today;
# if a generated issue body quotes any of them, the streaming awk terminates
# the block prematurely and the issue body is silently truncated.
#
# Fix: each LLM call site generates a per-call unique end token
# ("---END-${RANDOM}${RANDOM}---") and embeds it in both the prompt and the
# parser so that ---END--- in body content is never mistaken for the delimiter.
# Three sites are fixed:
#   1. generate_issues     — main streaming awk (_plan_end_token)
#   2. _request_missing_blocks — targeted completion call (_rb_end_token)
#   3. _regen_block_sections   — section-repair call (_regen_end_token)
#
# Tests in this file:
#   A. Structural: _plan_end_token defined + streaming awk uses variable not literal
#   B. Structural: _rb_end_token defined in _request_missing_blocks
#   C. Structural: _regen_end_token defined in _regen_block_sections
#   D. Behavioral: _request_missing_blocks — issue body containing ---END--- is
#      not truncated when the unique token is used as the actual delimiter

PLAN_ISSUES="${BATS_TEST_DIRNAME}/../../lib/core/plan-issues.sh"

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }

  # Extract the functions under test via brace-depth awk (no top-level code runs).
  local fn
  for fn in _canon_title _request_missing_blocks _coverage_missing_titles _normalize_issue_markers; do
    eval "$(awk -v target="^${fn}\\(\\)" '
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

  # Provider stub: extracts the per-call end token from the prompt and offers it
  # via STUB_TOKEN_FILE so behavioral tests can construct responses using the
  # real token (same pattern as rite-docs-directed-update.bats AC #16).
  export STUB_TOKEN_FILE="$RITE_TEST_TMPDIR/stub-token.txt"
  export STUB_RESPONSE_FILE="$RITE_TEST_TMPDIR/stub-response.txt"
  provider_run_streaming_prompt() {
    # Extract the per-generation end token from the prompt (#1342).
    local _tok
    _tok="$(printf '%s\n' "$1" | grep -oE -- '---END-[0-9]+---' | head -1 || true)"
    printf '%s\n' "${_tok:-}" > "$STUB_TOKEN_FILE"
    # Replace @@END@@ placeholder in STUB_RESPONSE_FILE with the real token.
    if [ -n "$_tok" ] && [ -f "$STUB_RESPONSE_FILE" ]; then
      sed "s/@@END@@/${_tok}/" "$STUB_RESPONSE_FILE"
    elif [ -f "$STUB_RESPONSE_FILE" ]; then
      cat "$STUB_RESPONSE_FILE"
    fi
  }
  provider_resolve_model() { printf 'claude-sonnet-4-6\n'; }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Acceptance criterion A (#1342): _plan_end_token defined in generate_issues
# and streaming awk uses the variable, not a hardcoded ---END--- literal
# ---------------------------------------------------------------------------

@test "generate_issues defines _plan_end_token and streaming awk uses it (#1342)" {
  # Token definition must exist in generate_issues
  local token_def_count
  token_def_count=$(grep -c '_plan_end_token="---END-' "$PLAN_ISSUES" || true)
  [ "$token_def_count" -ge 1 ]

  # Streaming awk must use -v _end_tok= (injecting the variable)
  local awk_var_count
  awk_var_count=$(grep -c -- '-v _end_tok=' "$PLAN_ISSUES" || true)
  [ "$awk_var_count" -ge 1 ]

  # Streaming awk must NOT match the hardcoded string "---END---" as a delimiter
  # (the literal appears in comments and other parsers — so we check inside the
  # streaming awk block specifically: no '$0 == "---END---"' pattern)
  local hardcoded_in_streaming
  hardcoded_in_streaming=$(awk '
    /\| awk -v _end_tok=/ { in_awk=1; next }
    in_awk && /\| tee / { in_awk=0; next }
    in_awk && /\$0 == "---END---"/ { found++ }
    END { print found+0 }
  ' "$PLAN_ISSUES" || true)
  [ "${hardcoded_in_streaming:-0}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion B (#1342): _rb_end_token defined in _request_missing_blocks
# ---------------------------------------------------------------------------

@test "_request_missing_blocks defines _rb_end_token (#1342)" {
  local rb_def_count
  rb_def_count=$(grep -c '_rb_end_token="---END-' "$PLAN_ISSUES" || true)
  [ "$rb_def_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion C (#1342): _regen_end_token defined in _regen_block_sections
# ---------------------------------------------------------------------------

@test "_regen_block_sections defines _regen_end_token (#1342)" {
  local regen_def_count
  regen_def_count=$(grep -c '_regen_end_token="---END-' "$PLAN_ISSUES" || true)
  [ "$regen_def_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion D (#1342): _request_missing_blocks does not truncate
# an issue block whose body contains ---END--- on its own line
# ---------------------------------------------------------------------------

@test "_request_missing_blocks: issue body with ---END--- not truncated (#1342)" {
  # Slate has two issues; COVERAGE lists a third that was not emitted.
  local slate="$RITE_TEST_TMPDIR/slate.txt"
  cat > "$slate" <<'SLATE'
```
COVERAGE:
- ✅ Issue Alpha
- ✅ Issue Beta
- ✅ Issue Gamma
```
---ISSUE---
TITLE: Issue Alpha
LABELS: phase-1,backend,priority-high
TIME: 1hr
BODY:
**Description**: Alpha.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Issue Beta
LABELS: phase-1,backend,priority-medium
TIME: 30min
BODY:
**Description**: Beta.
**Dependencies**: After #1
---END---
SLATE

  # Stub response: Issue Gamma's body quotes a bats test that contains ---END---
  # on its own line.  @@END@@ is the placeholder for the real per-call token.
  cat > "$STUB_RESPONSE_FILE" <<'RESPONSE'
---ISSUE---
TITLE: Issue Gamma
LABELS: phase-1,backend,priority-low
TIME: 30min
BODY:
**Description**: Gamma — references a test fixture containing ---END---.

Example from tests/regression/some-test.bats:
```
---END---
```

The above line must not truncate this issue block.
**Dependencies**: After #1, #2
@@END@@
RESPONSE

  _request_missing_blocks "$slate" "BASE PROMPT" 2>/dev/null

  # All three planned titles must now have blocks
  local title_count
  title_count=$(grep -c '^TITLE:' "$slate" || true)
  [ "$title_count" -eq 3 ] || {
    echo "FAIL: expected 3 TITLE lines, got ${title_count}" >&2
    cat "$slate" >&2
    return 1
  }

  # The ---END--- in the body must be present (not truncated)
  grep -qF 'The above line must not truncate this issue block.' "$slate" || {
    echo "FAIL: body content after ---END--- was truncated" >&2
    cat "$slate" >&2
    return 1
  }

  # The fixture ---END--- line itself must appear in the body (not just the comment)
  grep -qF 'Example from tests/regression/some-test.bats:' "$slate" || {
    echo "FAIL: body content before ---END--- was not captured" >&2
    cat "$slate" >&2
    return 1
  }
}
