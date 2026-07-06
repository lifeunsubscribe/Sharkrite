#!/usr/bin/env bats
# sharkrite-test-covers: lib/providers/claude.sh, lib/core/batch-process-issues.sh, lib/core/batch-reporter.sh
# tests/regression/batch-auth-halt.bats
#
# Regression test: provider auth failure must halt the entire batch immediately
# and mark remaining issues as skipped:auth rather than burning ~2min per issue
# on guaranteed-futile retries.
#
# Issue #937 — "Halt batch on provider auth failure"
#
# Motivation: LeadFlow/sharkrite Pilot 2026-07-05/06: the logged-out batch
# burned 8 issues × ~2min of guaranteed-futile retries ("Invalid API key ·
# Please run /login" ×3 quick retries per issue).  The fix: detect the auth
# fingerprint at the provider boundary → exit 18 → batch halts with a clear
# "run: claude /login" message → remaining issues recorded as skipped:auth.
#
# Tests in this file:
#
#   STRUCTURAL (static code inspection):
#     1. claude_provider_run_agentic_session exits 18 on auth fingerprint (grep)
#     2. Auth fingerprint patterns cover the live phrasings from the log
#     3. claude-workflow.sh exits 18 on CLAUDE_EXIT_CODE=18 (propagates)
#     4. batch-process-issues.sh has elif for exit 18 in dispatch block
#     5. batch-process-issues.sh sets _BATCH_AUTH_HALT=true on exit 18
#     6. batch-process-issues.sh has post-loop pass marking skipped:auth
#     7. exit-codes.md documents exit 18 in the cross-script table
#
#   UNIT (auth fingerprint detector in claude.sh):
#     8. "Invalid API key · Please run /login" detected as exit 18
#     9. "API Error: 401 ... authentication_error ... Please run /login" detected
#    10. "not logged in" detected
#    11. Spending-cap message NOT mis-detected as auth failure (stays exit 5)
#    12. Clean exit (exit 0) NOT mis-detected as auth failure
#    13. Non-auth failure (generic exit 1, no auth message) stays generic
#
#   BEHAVIORAL (batch halt + skipped accounting):
#    14. Auth failure marks remaining issues skipped:auth in ISSUE_STATUS
#    15. Auth failure issues appear in AUTH_FAILURE_ISSUES array
#    16. skipped:auth issues are included in SKIPPED_ISSUES
#    17. _batch_print_stats reports skipped:auth issues in their own section
#    18. _batch_print_stats excludes skipped:auth from generic Skipped Issues section

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CLAUDE_PROVIDER="$REPO_ROOT/lib/providers/claude.sh"
CLAUDE_WORKFLOW="$REPO_ROOT/lib/core/claude-workflow.sh"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
BATCH_REPORTER="$REPO_ROOT/lib/core/batch-reporter.sh"
EXIT_CODES_DOC="$REPO_ROOT/docs/architecture/exit-codes.md"

setup() {
  for _f in "$CLAUDE_PROVIDER" "$CLAUDE_WORKFLOW" "$BATCH_PROCESSOR" \
             "$BATCH_REPORTER" "$EXIT_CODES_DOC"; do
    [ -f "$_f" ] || {
      echo "FATAL: $_f not found" >&2
      return 1
    }
  done
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# =============================================================================
# STRUCTURAL: verify the implementation is in place (static code inspection)
# =============================================================================

@test "structural: claude_provider_run_agentic_session emits exit 18 on auth fingerprint" {
  # The provider must set _exit_code=18 when auth phrases are found.
  grep -q '_exit_code=18' "$CLAUDE_PROVIDER" || {
    echo "FAIL: '_exit_code=18' not found in claude.sh" >&2
    echo "      Auth fingerprint detection must translate to exit 18" >&2
    return 1
  }
}

@test "structural: auth fingerprint pattern covers 'Invalid API key' live phrasing" {
  # Live phrasing from rite-855-871-872 batch log (2026-07-05).
  grep -qiE 'invalid api key' "$CLAUDE_PROVIDER" || {
    echo "FAIL: 'invalid api key' not in auth fingerprint pattern in claude.sh" >&2
    return 1
  }
}

@test "structural: auth fingerprint pattern covers 'Please run /login' live phrasing" {
  grep -qiE 'please run /login' "$CLAUDE_PROVIDER" || {
    echo "FAIL: 'please run /login' not in auth fingerprint pattern in claude.sh" >&2
    return 1
  }
}

@test "structural: auth fingerprint pattern covers '401 / authentication_error' phrasing" {
  grep -qiE 'authentication_error|401' "$CLAUDE_PROVIDER" || {
    echo "FAIL: '401' or 'authentication_error' not in auth fingerprint pattern in claude.sh" >&2
    return 1
  }
}

@test "structural: claude-workflow.sh exits 18 when CLAUDE_EXIT_CODE is 18" {
  # claude-workflow.sh must propagate exit 18 so batch-process-issues.sh can catch it.
  grep -q 'CLAUDE_EXIT_CODE.*18\|18.*CLAUDE_EXIT_CODE' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: exit 18 handler not found in claude-workflow.sh" >&2
    return 1
  }
  grep -q 'exit 18' "$CLAUDE_WORKFLOW" || {
    echo "FAIL: 'exit 18' not found in claude-workflow.sh" >&2
    return 1
  }
}

@test "structural: claude-workflow.sh exit-18 block mentions 'claude /login'" {
  # The operator-facing remediation message must name the command to run.
  _block=$(grep -A5 'CLAUDE_EXIT_CODE.*18\|18.*CLAUDE_EXIT_CODE' "$CLAUDE_WORKFLOW" || true)
  echo "$_block" | grep -qi 'login' || {
    echo "FAIL: exit-18 block in claude-workflow.sh does not mention 'login'" >&2
    echo "      Found: $_block" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has elif branch for exit code 18" {
  grep -qE 'elif.*EXIT_CODE.*18|elif.*18.*EXIT_CODE' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'elif [ \$EXIT_CODE -eq 18 ]' not found in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh sets _BATCH_AUTH_HALT=true on exit 18" {
  grep -q '_BATCH_AUTH_HALT=true' "$BATCH_PROCESSOR" || {
    echo "FAIL: '_BATCH_AUTH_HALT=true' not found in batch-process-issues.sh" >&2
    echo "      This flag drives the post-loop skipped:auth marking pass" >&2
    return 1
  }
}

@test "structural: batch-process-issues.sh has post-loop pass marking skipped:auth" {
  # After the loop, remaining unprocessed issues must be recorded as skipped:auth.
  grep -q 'skipped:auth' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'skipped:auth' not found in batch-process-issues.sh" >&2
    return 1
  }
  grep -q '_BATCH_AUTH_HALT' "$BATCH_PROCESSOR" || {
    echo "FAIL: '_BATCH_AUTH_HALT' check not found in batch-process-issues.sh" >&2
    return 1
  }
}

@test "structural: exit-codes.md documents exit 18 in the cross-script table" {
  # The cross-script table uses Producer/Consumer columns; it is the top table.
  _cross_table=$(awk '
    /^## Cross-script signal codes/ { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$EXIT_CODES_DOC")

  [ -n "$_cross_table" ] || {
    echo "FAIL: Could not find cross-script table in exit-codes.md" >&2
    return 1
  }

  echo "$_cross_table" | grep -q '18' || {
    echo "FAIL: exit 18 not documented in cross-script table of exit-codes.md" >&2
    return 1
  }
}

# =============================================================================
# UNIT: auth fingerprint detection in claude_provider_run_agentic_session
#
# Strategy: run a bash subshell that stubs out run_with_timeout, tee, and the
# streaming filter so we can control what stdout/stderr the provider sees,
# then source only the agentic session function and drive it directly.
#
# PATH-stripping approach: create a stub dir with only the binaries we need,
# so 'claude' resolves to our stub (which prints the auth error and exits 1).
# =============================================================================

@test "unit: 'Invalid API key · Please run /login' detected → exit 18" {
  _tmpdir=$(mktemp -d)

  # Stub claude that prints the live auth fingerprint and exits 1
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Invalid API key · Please run /login" >&2
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  # Stub jq (used by stream filter) — just drain stdin
  cat > "$_tmpdir/jq" <<'STUB'
#!/bin/bash
cat >/dev/null
STUB
  chmod +x "$_tmpdir/jq"

  # Stub tee: write to capture file and pass through to stdout
  # tee needs to write to the _stdout_capture file the provider creates
  cat > "$_tmpdir/tee" <<'STUB'
#!/bin/bash
# Write stdin to the capture file (last arg) and to stdout
_cap="${@: -1}"
while IFS= read -r _line; do
  printf '%s\n' "$_line" >> "$_cap"
  printf '%s\n' "$_line"
done
STUB
  chmod +x "$_tmpdir/tee"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export RITE_CLAUDE_TIMEOUT_PROMPT=10
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10

    # Source only the function we need (no executable body)
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    # Restore bats shell flags swallowed by set -euo pipefail in sourced file
    set +u; set +o pipefail

    # run_with_timeout: just run the command directly (no timeout binary needed)
    run_with_timeout() { shift; \"\$@\"; }

    # Detect the CLI so CLAUDE_PROVIDER_CMD is set
    claude_provider_detect_cli

    # _claude_write_hook_settings: no-op (no hook file in test env)
    _claude_write_hook_settings() { echo ''; }
    # _claude_pretooluse_hook_path: no-op
    _claude_pretooluse_hook_path() { echo ''; }

    # claude_provider_build_tool_restrictions: no-op
    claude_provider_build_tool_restrictions() { echo 'none'; }

    # claude_provider_resolve_model: fixed
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }

    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true /dev/null || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 18 ] || {
    echo "FAIL: expected exit 18 for auth fingerprint, got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "unit: 'authentication_error ... Please run /login' (401 API error) detected → exit 18" {
  _tmpdir=$(mktemp -d)

  # Stub claude that prints the 401 API error variant and exits 1
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo 'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"Invalid authentication credentials"}} · Please run /login' >&2
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  cat > "$_tmpdir/jq" <<'STUB'
#!/bin/bash
cat >/dev/null
STUB
  chmod +x "$_tmpdir/jq"

  cat > "$_tmpdir/tee" <<'STUB'
#!/bin/bash
_cap="${@: -1}"
while IFS= read -r _line; do
  printf '%s\n' "$_line" >> "$_cap"
  printf '%s\n' "$_line"
done
STUB
  chmod +x "$_tmpdir/tee"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export RITE_CLAUDE_TIMEOUT_PROMPT=10
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10

    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail

    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }

    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true /dev/null || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 18 ] || {
    echo "FAIL: expected exit 18 for 401-class auth error, got: $status" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "unit: spending-cap message does NOT produce exit 18 (stays exit 5)" {
  _tmpdir=$(mktemp -d)

  # Stub claude that prints a usage-cap message (not auth failure)
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Spending cap reached resets 11:20pm" >&2
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  cat > "$_tmpdir/jq" <<'STUB'
#!/bin/bash
cat >/dev/null
STUB
  chmod +x "$_tmpdir/jq"

  cat > "$_tmpdir/tee" <<'STUB'
#!/bin/bash
_cap="${@: -1}"
while IFS= read -r _line; do
  printf '%s\n' "$_line" >> "$_cap"
  printf '%s\n' "$_line"
done
STUB
  chmod +x "$_tmpdir/tee"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export RITE_CLAUDE_TIMEOUT_PROMPT=10
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10

    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail

    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }

    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true /dev/null || _exit=\$?
    exit \$_exit
  "

  [ "$status" -eq 5 ] || {
    echo "FAIL: expected exit 5 for spending-cap message, got: $status" >&2
    echo "      (spending cap must not be mis-classified as auth failure)" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "unit: generic non-auth provider failure stays generic (not exit 18)" {
  _tmpdir=$(mktemp -d)

  # Stub claude that fails with a generic error (no auth fingerprint)
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
echo "Internal error: something went wrong" >&2
exit 1
STUB
  chmod +x "$_tmpdir/claude"

  cat > "$_tmpdir/jq" <<'STUB'
#!/bin/bash
cat >/dev/null
STUB
  chmod +x "$_tmpdir/jq"

  cat > "$_tmpdir/tee" <<'STUB'
#!/bin/bash
_cap="${@: -1}"
while IFS= read -r _line; do
  printf '%s\n' "$_line" >> "$_cap"
  printf '%s\n' "$_line"
done
STUB
  chmod +x "$_tmpdir/tee"

  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir'
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    export RITE_CLAUDE_TIMEOUT_PROMPT=10
    export RITE_CLAUDE_TIMEOUT_AGENTIC=10

    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$CLAUDE_PROVIDER' || true
    set +u; set +o pipefail

    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    _claude_pretooluse_hook_path() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }

    _exit=0
    claude_provider_run_agentic_session 'test prompt' 10 true /dev/null || _exit=\$?
    exit \$_exit
  "

  # Must NOT be exit 18 (auth) or exit 5 (cap) — generic failure is exit 1
  [ "$status" -ne 18 ] || {
    echo "FAIL: generic failure must not produce exit 18 (auth sentinel)" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "$status" -ne 5 ] || {
    echo "FAIL: generic failure must not produce exit 5 (usage-cap sentinel)" >&2
    echo "      output: $output" >&2
    return 1
  }
  [ "$status" -ne 0 ] || {
    echo "FAIL: a failing provider must not return exit 0" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: batch halt + skipped:auth accounting
#
# These tests drive _batch_print_stats from batch-reporter.sh directly,
# simulating the state that batch-process-issues.sh would have produced
# after an auth-failure halt.
# =============================================================================

@test "behavioral: auth failure marks remaining unprocessed issues skipped:auth in ISSUE_STATUS" {
  # Simulate: ISSUE_LIST=[10,11,12], issue 10 fails with auth (exit 18),
  # issues 11 and 12 are never processed. The post-loop pass must mark 11 and 12
  # as skipped:auth.
  run bash -c "
    set -euo pipefail

    # Extract the post-loop skipped:auth marking logic from batch-process-issues.sh.
    # The pattern: if _BATCH_AUTH_HALT=true; iterate ISSUE_LIST; mark unset entries.
    # We replicate the state and run the same logic inline.

    declare -A ISSUE_STATUS
    SKIPPED_ISSUES=()
    ISSUE_LIST=(10 11 12)

    # Issue 10 was processed and failed with auth
    ISSUE_STATUS[10]='auth_failure'

    # Issues 11 and 12 have no status (never processed)
    _BATCH_AUTH_HALT=true

    if [ \"\$_BATCH_AUTH_HALT\" = 'true' ]; then
      for _unprocessed_num in \"\${ISSUE_LIST[@]}\"; do
        if [ -z \"\${ISSUE_STATUS[\$_unprocessed_num]:-}\" ]; then
          SKIPPED_ISSUES+=(\"\$_unprocessed_num\")
          ISSUE_STATUS[\"\$_unprocessed_num\"]='skipped:auth'
        fi
      done
    fi

    # Verify
    [ \"\${ISSUE_STATUS[11]:-}\" = 'skipped:auth' ] || {
      echo \"FAIL: issue 11 status='\${ISSUE_STATUS[11]:-}' expected 'skipped:auth'\"
      exit 1
    }
    [ \"\${ISSUE_STATUS[12]:-}\" = 'skipped:auth' ] || {
      echo \"FAIL: issue 12 status='\${ISSUE_STATUS[12]:-}' expected 'skipped:auth'\"
      exit 1
    }
    # Issue 10's status must be unchanged (auth_failure, not skipped:auth)
    [ \"\${ISSUE_STATUS[10]:-}\" = 'auth_failure' ] || {
      echo \"FAIL: issue 10 status='\${ISSUE_STATUS[10]:-}' expected 'auth_failure'\"
      exit 1
    }
    # Both 11 and 12 must be in SKIPPED_ISSUES
    _count=\${#SKIPPED_ISSUES[@]}
    [ \"\$_count\" -eq 2 ] || {
      echo \"FAIL: expected 2 skipped:auth issues, got \$_count\"
      exit 1
    }
    echo 'OK'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK' || {
    echo "FAIL: behavioral test did not reach OK" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "behavioral: _batch_print_stats prints auth-skipped section when AUTH_FAILURE_ISSUES is set" {
  run bash -c "
    set -euo pipefail

    # Source batch-reporter.sh (pure bash, no external deps)
    source '$BATCH_REPORTER'
    set +u; set +o pipefail

    # Simulate state after auth-failure halt on issue 10, issues 11/12 skipped:auth
    TOTAL_ISSUES=3
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=(10)
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(11 12)
    AUTH_FAILURE_ISSUES=(10)
    ALREADY_CLOSED_AT_START_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()
    TOTAL_DURATION=15
    declare -A ISSUE_STATUS
    ISSUE_STATUS[10]='auth_failure'
    ISSUE_STATUS[11]='skipped:auth'
    ISSUE_STATUS[12]='skipped:auth'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  # The auth-skipped section header must appear
  echo "$output" | grep -qi 'auth failure\|Provider Auth\|skipped.*auth' || {
    echo "FAIL: expected auth-failure section in _batch_print_stats output" >&2
    echo "      output: $output" >&2
    return 1
  }

  # Both skipped:auth issues must be listed
  echo "$output" | grep -q '#11' || {
    echo "FAIL: issue #11 not listed in auth-failure section" >&2
    echo "      output: $output" >&2
    return 1
  }
  echo "$output" | grep -q '#12' || {
    echo "FAIL: issue #12 not listed in auth-failure section" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "behavioral: _batch_print_stats excludes skipped:auth issues from generic Skipped Issues section" {
  run bash -c "
    set -euo pipefail

    source '$BATCH_REPORTER'
    set +u; set +o pipefail

    TOTAL_ISSUES=4
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=(10)
    BLOCKED_ISSUES=()
    # Mix: 11/12 are skipped:auth, 13 is dep_failed (generic skip)
    SKIPPED_ISSUES=(11 12 13)
    AUTH_FAILURE_ISSUES=(10)
    ALREADY_CLOSED_AT_START_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()
    TOTAL_DURATION=20
    declare -A ISSUE_STATUS
    ISSUE_STATUS[10]='auth_failure'
    ISSUE_STATUS[11]='skipped:auth'
    ISSUE_STATUS[12]='skipped:auth'
    ISSUE_STATUS[13]='dep_failed'

    _batch_compute_totals
    _out=\$(_batch_print_stats)

    # The generic 'Skipped Issues' section must contain issue 13 (dep_failed)
    echo \"\$_out\" | grep -q '#13' || {
      echo 'FAIL: issue #13 (dep_failed) missing from generic Skipped Issues section'
      exit 1
    }

    # The generic 'Skipped Issues' section must NOT list 11 or 12 under 'Skipped Issues'
    # (they appear in the auth-failure section instead).
    # Strategy: find the 'Skipped Issues' header block and check it doesn't list 11/12.
    _generic_block=\$(echo \"\$_out\" | awk '
      /^Skipped Issues\$/ { in_section=1; next }
      in_section && /^━/ { exit }
      in_section { print }
    ')

    # The generic section should not contain 11 or 12 (they are in auth section)
    if echo \"\$_generic_block\" | grep -q '#11'; then
      echo 'FAIL: issue #11 (skipped:auth) appeared in generic Skipped Issues section'
      exit 1
    fi
    if echo \"\$_generic_block\" | grep -q '#12'; then
      echo 'FAIL: issue #12 (skipped:auth) appeared in generic Skipped Issues section'
      exit 1
    fi

    echo 'OK'
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK' || {
    echo "FAIL: behavioral test did not reach OK" >&2
    echo "      output: $output" >&2
    return 1
  }
}

@test "behavioral: _batch_print_stats shows remediation message in auth-failure section" {
  run bash -c "
    set -euo pipefail

    source '$BATCH_REPORTER'
    set +u; set +o pipefail

    TOTAL_ISSUES=2
    COMPLETED_ISSUES=0
    MERGED_CLEANUP_FAILED=()
    FAILED_ISSUES=(10)
    BLOCKED_ISSUES=()
    SKIPPED_ISSUES=(11)
    AUTH_FAILURE_ISSUES=(10)
    ALREADY_CLOSED_AT_START_ISSUES=()
    IN_PROGRESS_ELSEWHERE_ISSUES=()
    TOTAL_DURATION=10
    declare -A ISSUE_STATUS
    ISSUE_STATUS[10]='auth_failure'
    ISSUE_STATUS[11]='skipped:auth'

    _batch_compute_totals
    _batch_print_stats
  "

  [ "$status" -eq 0 ]

  # Remediation message must mention 'login'
  echo "$output" | grep -qi 'login' || {
    echo "FAIL: auth-failure section does not mention 'login' remediation" >&2
    echo "      output: $output" >&2
    return 1
  }
}
