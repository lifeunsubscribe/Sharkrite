#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh::_ci_preflight, bin/rite
# Regression tests for the batch CI preflight (issue #1549).
#
# Before any slot starts, a batch reads the latest completed CI run per
# workflow on the target branch (one gh api call, per_page=30 + group_by).
# If any workflow's latest run has a red conclusion (failure, timed_out, or
# startup_failure), the batch halts with the failing workflow name, URL, and
# remediation instructions.
# --allow-red-main bypasses with a single warning line.
# Missing CI / empty results / API error -> proceed silently.
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1. _ci_preflight() function exists in batch-process-issues.sh
#     2. MAIN_CI_RED diag is emitted in _ci_preflight
#     3. --allow-red-main flag parsed in batch-process-issues.sh arg parser
#     4. --allow-red-main flag parsed in bin/rite
#     5. _ci_preflight is called after provider_healthcheck
#
#   BEHAVIORAL (_ci_preflight in isolation via awk-extract):
#     6. Red conclusion (failure) -> returns 1, prints halt block
#     7. Red conclusion (timed_out) -> returns 1
#     8. Red halt block includes workflow name and URL
#     9. Red halt block includes --allow-red-main remediation hint
#    10. Green conclusion (success) -> returns 0 silently
#    11. No completed runs (total_count=0) -> returns 0 silently
#    12. API error -> returns 0 silently
#    13. --allow-red-main with red CI -> returns 0 with one warning
#    14. Neutral conclusion -> returns 0 silently (not a hard failure)
#    15. MAIN_CI_RED diag includes branch and conclusion on halt path
#    16. startup_failure conclusion treated as red

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
RITE_BIN="$REPO_ROOT/bin/rite"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
  [ -f "$RITE_BIN" ] || {
    echo "FATAL: $RITE_BIN not found" >&2
    return 1
  }
  _tmpdir=$(mktemp -d)
  _stub_bin="$_tmpdir/stub-bin"
  mkdir -p "$_stub_bin"
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# Write a gh stub returning the given CI JSON to the stub_bin.
# Usage: _write_gh_stub <stub_path> <json_payload>
_write_gh_stub() {
  local _stub="$1" _json="$2"
  printf '#!/bin/bash\n' > "$_stub"
  printf 'if [[ "$*" == *"actions/runs"* ]]; then\n' >> "$_stub"
  printf '  printf '"'"'%s'"'"'\n' "$_json" >> "$_stub"
  printf '  exit 0\n' >> "$_stub"
  printf 'fi\n' >> "$_stub"
  printf 'exit 0\n' >> "$_stub"
  chmod +x "$_stub"
}

# =============================================================================
# STRUCTURAL
# =============================================================================

@test "structural: _ci_preflight() function exists in batch-process-issues.sh" {
  grep -q '^_ci_preflight()' "$BATCH_PROCESSOR"
}

@test "structural: MAIN_CI_RED diag token emitted inside _ci_preflight" {
  _body=$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}$/{ exit }' \
    "$BATCH_PROCESSOR")
  [ -n "$_body" ]
  echo "$_body" | grep -q 'MAIN_CI_RED'
}

@test "structural: --allow-red-main flag parsed in batch-process-issues.sh arg parser" {
  grep -q -- '--allow-red-main' "$BATCH_PROCESSOR"
}

@test "structural: --allow-red-main flag parsed in bin/rite" {
  grep -q -- '--allow-red-main' "$RITE_BIN"
}

@test "structural: _ci_preflight call site appears after provider_healthcheck" {
  _ph_line=$(awk '/if ! provider_healthcheck/{print NR; exit}' "$BATCH_PROCESSOR")
  _ci_call_line=$(awk '/if ! _ci_preflight/{print NR; exit}' "$BATCH_PROCESSOR")
  [ -n "$_ph_line" ] || { echo "FAIL: provider_healthcheck call not found" >&2; return 1; }
  [ -n "$_ci_call_line" ] || { echo "FAIL: _ci_preflight call not found" >&2; return 1; }
  [ "$_ci_call_line" -gt "$_ph_line" ]
}

# =============================================================================
# BEHAVIORAL: _ci_preflight in isolation
#
# Each test awk-extracts _ci_preflight from batch-process-issues.sh and evals
# it in a subshell with:
#   - a stubbed gh binary on PATH for the API call
#   - gh_safe() pass-through (calls the stub gh)
#   - print_warning/print_error/_diag stubs
#   - RITE_TARGET_BRANCH set per test
#   - the allow flag passed as $1 (not via env var)
# =============================================================================

@test "behavioral: red conclusion (failure) returns 1 with halt block" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"failure","name":"CI / Lint","html_url":"https://github.com/org/repo/actions/runs/99"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"CI is red"* ]] || [[ "$output" == *"preflight failed"* ]]
}

@test "behavioral: red conclusion (timed_out) returns 1" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"timed_out","name":"CI","html_url":"https://example.com"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 1 ]
}

@test "behavioral: red halt block includes workflow name and URL" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"failure","name":"CI / Lint","html_url":"https://github.com/org/repo/actions/runs/99"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"CI / Lint"* ]]
  [[ "$output" == *"https://github.com"* ]]
}

@test "behavioral: red halt block includes --allow-red-main remediation hint" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"failure","name":"CI","html_url":"https://example.com"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-red-main"* ]]
}

@test "behavioral: green conclusion (success) returns 0 with no output" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"success","name":"CI","html_url":"https://example.com"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "behavioral: no completed runs (total_count=0) returns 0 silently" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" '{"total_count":0,"workflow_runs":[]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "behavioral: API error (gh fails) returns 0 silently" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  printf '#!/bin/bash\n' > "$_stub_bin/gh"
  printf 'if [[ "$*" == *"actions/runs"* ]]; then echo "API error" >&2; exit 1; fi\n' >> "$_stub_bin/gh"
  printf 'exit 0\n' >> "$_stub_bin/gh"
  chmod +x "$_stub_bin/gh"

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 0 ]
}

@test "behavioral: --allow-red-main with red CI returns 0 with one warning" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"failure","name":"CI","html_url":"https://example.com"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight true 2>&1
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow-red-main"* ]] || [[ "$output" == *"red"* ]]
}

@test "behavioral: neutral conclusion returns 0 silently (not a hard failure)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"neutral","name":"CI","html_url":"https://example.com"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 0 ]
}

@test "behavioral: MAIN_CI_RED diag includes branch and conclusion on halt path" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"failure","name":"CI","html_url":"https://example.com"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=my-integration
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch=my-integration"* ]]
  [[ "$output" == *"conclusion=failure"* ]]
}

@test "behavioral: startup_failure conclusion treated as red (halts batch)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _write_gh_stub "$_stub_bin/gh" \
    '{"total_count":1,"workflow_runs":[{"conclusion":"startup_failure","name":"CI / Lint","html_url":"https://example.com/runs/42"}]}'

  run bash -c "
    export PATH=\"${_stub_bin}:$PATH\"
    gh_safe() { gh \"\$@\"; }
    print_warning() { echo \"WARNING: \$*\"; }
    print_error() { echo \"ERROR: \$*\" >&2; }
    _diag() { echo \"[diag] \$*\"; }
    export RITE_TARGET_BRANCH=main
    _func_src=\$(awk '/^_ci_preflight\(\)/{ in_func=1 } in_func{ print } in_func && /^\}\$/ { exit }' \
      '${BATCH_PROCESSOR}')
    eval \"\$_func_src\"
    _ci_preflight false 2>&1
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"CI is red"* ]] || [[ "$output" == *"preflight failed"* ]]
}
