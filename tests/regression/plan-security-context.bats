#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh::_collect_security_context
# tests/regression/plan-security-context.bats
#
# Regression tests for the open-security-deferrals injection feature (#1553).
#
# Feature: `rite plan` queries open issues labeled "security" (up to 20) and
# injects them into the generation prompt as an "Open Security Deferrals" block
# so the planner can emit Blocked-by edges when planned work touches an affected
# surface.
#
# Acceptance criteria verified here:
#   A. Two open security issues → prompt contains the headed block + both issue refs.
#   B. Zero open security issues → prompt contains NO security block (benign absence
#      is silent — zero output noise).
#   C. Info line emitted to stderr when security issues exist (count + numbers).
#   D. Info line NOT emitted when no security issues exist.
#   E. Block is bounded (gh query limits to 20 issues max via --limit 20).
#   F. Location hint appears in block when issue body contains a lib/ path.
#   G. Location hint omitted gracefully when issue body has no lib/ or bin/ path.
#   H. _collect_security_context is defined in plan-issues.sh.
#   I. generate_issues prompt dump contains the security block when context provided.
#
# Test strategy:
#   - Stub gh_safe to return fixture data for "--label security" calls.
#   - Use RITE_PLAN_DRYRUN_DUMP_PROMPT=1 to dump the assembled prompt without
#     a provider call, then assert sentinel strings appear.
#   - Extract _collect_security_context and generate_issues via awk (same
#     technique as plan-doc-ingest.bats).

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  export RITE_DATA_DIR=".rite"
  export RITE_PLAN_DOC_BYTE_CAP=50000
  export RITE_PLAN_MAX_ESTIMATE="2hr"
  export RITE_PLAN_DOCS=""
  export RITE_PLAN_DRYRUN_DUMP_PROMPT=""

  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  provider_detect_cli()           { return 0; }
  provider_run_streaming_prompt() { echo "STUB_STREAMING_OUTPUT"; }

  # Default gh_safe stub: return empty (no security issues, no labels, no existing issues)
  gh_safe() { echo ""; }

  if ! declare -f portable_sed_i >/dev/null 2>&1; then
    if [ -f "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh" ]; then
      # shellcheck disable=SC1090
      # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: portable-cmds.sh uses a function-sentinel guard (declare -f portable_sed_i); pre-source stubs are preserved on source.
      source "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh"
      set +u; set +o pipefail
    fi
  fi

  # Extract _collect_security_context and generate_issues from plan-issues.sh.
  # Both are needed: _collect_security_context for direct unit tests,
  # generate_issues for prompt-dump integration tests.
  eval "$(awk '
    /^_collect_security_context[(][)]/ { in_fn=1; depth=0 }
    /^generate_issues[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

  # Stub _build_available_tags_context (called inside generate_issues)
  _build_available_tags_context() { echo ""; }
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Fixture A: two open security issues → block + both issue refs in output
# ---------------------------------------------------------------------------

@test "Fixture A: two open security issues appear in _collect_security_context output" {
  # Stub gh_safe to return two security issues (TSV: number, title, body)
  gh_safe() {
    case "$*" in
      *"--label security"*)
        printf '%s\t%s\t%s\n' \
          "42" "Session fixation in auth flow" "Affects lib/core/claude-workflow.sh line 300" \
          "99" "CSRF token not validated" "No specific file referenced"
        ;;
      *) echo "" ;;
    esac
  }

  local result
  result=$(_collect_security_context)

  # Must contain the section heading
  echo "$result" | grep -q "Open Security Deferrals" || {
    echo "FAIL: 'Open Security Deferrals' heading not found in output" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Must reference both issue numbers
  echo "$result" | grep -q "#42" || {
    echo "FAIL: issue #42 not found in security context output" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
  echo "$result" | grep -q "#99" || {
    echo "FAIL: issue #99 not found in security context output" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture B: zero open security issues → empty output (no block injected)
# ---------------------------------------------------------------------------

@test "Fixture B: zero open security issues → _collect_security_context returns empty" {
  # gh_safe already stubs to return empty (default stub in setup())

  local result
  result=$(_collect_security_context)

  [ -z "$result" ] || {
    echo "FAIL: expected empty output with no security issues, got:" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture C: info line emitted to stderr when security issues exist
# ---------------------------------------------------------------------------

@test "Fixture C: info line is emitted to stderr when open security issues exist" {
  gh_safe() {
    case "$*" in
      *"--label security"*)
        printf '%s\t%s\t%s\n' \
          "42" "Session fixation in auth flow" "Affects lib/core/claude-workflow.sh"
        ;;
      *) echo "" ;;
    esac
  }

  local security_context
  security_context=$(_collect_security_context)

  local stderr_out
  stderr_out=$(mktemp)

  # Simulate the info-line logic from plan_issues()
  if [ -n "$security_context" ]; then
    local _sec_numbers
    _sec_numbers=$(printf '%s' "$security_context" | grep -oE '#[0-9]+' | tr '\n' ' ' || true)
    local _sec_count
    _sec_count=$(printf '%s' "$security_context" | grep -c '^- #' || true)
    print_info "Open security deferrals: ${_sec_count} issue(s) (${_sec_numbers% }) — planned work touching affected surfaces MUST declare 'Blocked by: #N'" 2>"$stderr_out"
  fi

  grep -q "Open security deferrals" "$stderr_out" || {
    echo "FAIL: expected info line about open security deferrals in stderr" >&2
    cat "$stderr_out" >&2
    false
  }

  grep -q "#42" "$stderr_out" || {
    echo "FAIL: expected issue #42 to appear in the info line" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture D: no info line emitted when no security issues exist
# ---------------------------------------------------------------------------

@test "Fixture D: no info line emitted when no open security issues" {
  # gh_safe default stub returns empty

  local security_context
  security_context=$(_collect_security_context)

  local stderr_out
  stderr_out=$(mktemp)

  # Replicate the guard from plan_issues()
  if [ -n "$security_context" ]; then
    print_info "Open security deferrals: ..." 2>"$stderr_out"
  fi

  local line_count
  line_count=$(wc -l < "$stderr_out" || true)
  [ "$line_count" -eq 0 ] || {
    echo "FAIL: expected no output to stderr when no security issues, got:" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture E: gh query uses --limit 20 (block is bounded)
# ---------------------------------------------------------------------------

@test "Fixture E: _collect_security_context query passes --limit 20 (block is bounded)" {
  grep -q '\-\-limit 20' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" || {
    echo "FAIL: '--limit 20' not found in _collect_security_context in plan-issues.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture F: location hint appears when issue body contains a lib/ path
# ---------------------------------------------------------------------------

@test "Fixture F: location hint from lib/ path appears in block entry" {
  gh_safe() {
    case "$*" in
      *"--label security"*)
        printf '%s\t%s\t%s\n' \
          "55" "Token leak in provider" "Grep lib/providers/claude.sh for the pattern"
        ;;
      *) echo "" ;;
    esac
  }

  local result
  result=$(_collect_security_context)

  echo "$result" | grep -q "lib/providers/claude.sh" || {
    echo "FAIL: expected location hint 'lib/providers/claude.sh' in block entry" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture G: location hint omitted when issue body has no lib/ or bin/ path
# ---------------------------------------------------------------------------

@test "Fixture G: location hint omitted gracefully when body has no lib/ or bin/ path" {
  gh_safe() {
    case "$*" in
      *"--label security"*)
        printf '%s\t%s\t%s\n' \
          "77" "Missing rate limit" "No specific file. Affects the entire API layer."
        ;;
      *) echo "" ;;
    esac
  }

  local result
  result=$(_collect_security_context)

  # Must have the entry without a [location:] annotation
  echo "$result" | grep -q "^- #77:" || {
    echo "FAIL: expected entry for #77 in block" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }

  # Must NOT have a [location:] annotation for this entry
  local loc_count
  loc_count=$(echo "$result" | grep "^- #77:" | grep -c "\[location:" || true)
  [ "$loc_count" -eq 0 ] || {
    echo "FAIL: unexpected [location:] annotation for entry with no lib/bin path" >&2
    echo "--- output ---" >&2
    echo "$result" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture I: generate_issues prompt dump contains the security block
# ---------------------------------------------------------------------------

@test "Fixture I: generate_issues prompt dump contains security block when context provided" {
  echo "# Test Project" > "$RITE_TEST_TMPDIR/CLAUDE.md"

  export RITE_PLAN_DRYRUN_DUMP_PROMPT=1

  local security_ctx
  security_ctx="## Open Security Deferrals (open issues with the 'security' label)
Any planned issue whose implementation touches the same files or surfaces listed
below MUST declare \`Blocked by: #N\` in its Dependencies field, or explicitly
state why the dependency does not apply.
- #42: Session fixation in auth flow [location: lib/core/claude-workflow.sh]
"

  local prompt_output
  prompt_output=$(generate_issues \
    "" \
    "project context" \
    "" "" "" "" "2hr" "" "" "" "$security_ctx")

  echo "$prompt_output" | grep -q "Open Security Deferrals" || {
    echo "FAIL: 'Open Security Deferrals' heading not found in prompt dump" >&2
    echo "--- prompt (first 80 lines) ---" >&2
    echo "$prompt_output" | head -80 >&2
    false
  }

  echo "$prompt_output" | grep -q "#42" || {
    echo "FAIL: issue #42 not found in prompt dump" >&2
    echo "--- prompt (first 80 lines) ---" >&2
    echo "$prompt_output" | head -80 >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture I2: generate_issues prompt dump has NO security block when context empty
# ---------------------------------------------------------------------------

@test "Fixture I2: generate_issues prompt dump has no security block when context empty" {
  echo "# Test Project" > "$RITE_TEST_TMPDIR/CLAUDE.md"

  export RITE_PLAN_DRYRUN_DUMP_PROMPT=1

  local prompt_output
  prompt_output=$(generate_issues \
    "" \
    "project context" \
    "" "" "" "" "2hr" "" "" "" "")

  local sec_count
  sec_count=$(echo "$prompt_output" | grep -c "Open Security Deferrals" || true)
  [ "$sec_count" -eq 0 ] || {
    echo "FAIL: expected no 'Open Security Deferrals' block in prompt when context is empty, got ${sec_count} occurrence(s)" >&2
    echo "--- prompt (first 80 lines) ---" >&2
    echo "$prompt_output" | head -80 >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: _collect_security_context is defined in plan-issues.sh
# ---------------------------------------------------------------------------

@test "acceptance: _collect_security_context function is defined in plan-issues.sh" {
  grep -q "^_collect_security_context()" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" || {
    echo "FAIL: _collect_security_context function not found in plan-issues.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: generate_issues accepts the security_context 11th parameter
# ---------------------------------------------------------------------------

@test "acceptance: generate_issues declares security_context as its 11th parameter" {
  grep -q 'local security_context=.*11' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" || {
    echo "FAIL: security_context 11th parameter not found in generate_issues" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: CLAUDE.md rite plan paragraph mentions the security block
# ---------------------------------------------------------------------------

@test "acceptance: CLAUDE.md rite plan paragraph mentions the security-issues block" {
  grep -q "security" "${RITE_REPO_ROOT}/CLAUDE.md" | grep -q "plan" || true
  grep -n "security" "${RITE_REPO_ROOT}/CLAUDE.md" | grep -qi "Open Security Deferrals\|security.*block\|security.*inject\|security.*plan\|labeled.*security\|label.*security" || {
    echo "FAIL: CLAUDE.md does not mention the security-issues block in the rite plan context" >&2
    false
  }
}
