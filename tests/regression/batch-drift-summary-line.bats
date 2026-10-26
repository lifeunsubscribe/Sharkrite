#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# tests/regression/batch-drift-summary-line.bats
#
# A batch that finishes with pending drift entries must end with exactly one
# informational line: "N drift entries pending across M docs — run 'rite docs'"
# A batch with no entries (or tracking off) must print nothing extra.
#
# Issue #1428 — "Print pending-drift batch summary"
#
# Tests:
#   1. BEHAVIORAL: pending entries → correct N and M in the summary line
#   2. BEHAVIORAL: zero entries    → no drift line printed
#   3. BEHAVIORAL: RITE_STATE_DIR unset → no drift line (tracking off)
#   4. STRUCTURAL: no `read` in _batch_print_drift_summary (no prompting)
#   5. STRUCTURAL: function exists in batch-process-issues.sh
#   6. STRUCTURAL: call site present in main body after blocked-issues section

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH="$REPO_ROOT/lib/core/batch-process-issues.sh"
DRIFT_LOG="$REPO_ROOT/lib/utils/drift-log.sh"

setup() {
  [ -f "$BATCH" ] || { echo "FATAL: $BATCH not found" >&2; return 1; }
  [ -f "$DRIFT_LOG" ] || { echo "FATAL: $DRIFT_LOG not found" >&2; return 1; }
  _tmpdir=$(mktemp -d)
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

# ---------------------------------------------------------------------------
# _seed_entry STATE_DIR DOC BRANCH
# Write one raw TSV entry line to the structured entry file for (doc, branch).
# Bypasses drift_log_append to avoid lock_acquire in tests.
# ---------------------------------------------------------------------------
_seed_entry() {
  local _sd="$1" _doc="$2" _branch="$3"
  local _slug="${_doc//\//--}"
  mkdir -p "${_sd}/doc-drift/${_branch}"
  printf 'doc=%s\tbranch=%s\tpr=42\tissue=100\tassertion=test assertion\tkind=addition\tevidence=none\trecorded=2026-10-26T00:00:00Z\n' \
    "$_doc" "$_branch" >> "${_sd}/doc-drift/${_branch}/${_slug}.log"
}

# ---------------------------------------------------------------------------
# BEHAVIORAL
# ---------------------------------------------------------------------------

@test "behavioral: pending entries prints correct N and M" {
  # 3 total entries across 2 distinct docs
  _seed_entry "$_tmpdir" "docs/architecture/foo.md" "main"
  _seed_entry "$_tmpdir" "docs/architecture/foo.md" "main"  # second entry, same doc
  _seed_entry "$_tmpdir" "README.md" "main"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${REPO_ROOT}/lib'
    export RITE_STATE_DIR='${_tmpdir}'
    # Stub print_info to stdout so bats captures it
    print_info() { printf '%s\n' \"\$*\"; }
    source '${DRIFT_LOG}'
    # Extract and load the real function from the production file
    _fn_src=\$(awk '
      /^_batch_print_drift_summary\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH}')
    eval \"\$_fn_src\"
    _batch_print_drift_summary
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "3 drift entries pending across 2 docs" || {
    echo "FAIL: expected '3 drift entries pending across 2 docs'" >&2
    echo "      got: $output" >&2
    return 1
  }
  echo "$output" | grep -q "run 'rite docs'" || {
    echo "FAIL: expected \"run 'rite docs'\" in output" >&2
    echo "      got: $output" >&2
    return 1
  }
}

@test "behavioral: single entry single doc" {
  _seed_entry "$_tmpdir" "docs/architecture/adr-001.md" "main"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${REPO_ROOT}/lib'
    export RITE_STATE_DIR='${_tmpdir}'
    print_info() { printf '%s\n' \"\$*\"; }
    source '${DRIFT_LOG}'
    _fn_src=\$(awk '
      /^_batch_print_drift_summary\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH}')
    eval \"\$_fn_src\"
    _batch_print_drift_summary
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 drift entries pending across 1 docs" || {
    echo "FAIL: expected '1 drift entries pending across 1 docs'" >&2
    echo "      got: $output" >&2
    return 1
  }
}

@test "behavioral: same doc across two branches counts as 1 doc" {
  # The same doc in two branches = 1 distinct doc slug, 2 entries
  _seed_entry "$_tmpdir" "docs/architecture/foo.md" "main"
  _seed_entry "$_tmpdir" "docs/architecture/foo.md" "integration-1"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${REPO_ROOT}/lib'
    export RITE_STATE_DIR='${_tmpdir}'
    print_info() { printf '%s\n' \"\$*\"; }
    source '${DRIFT_LOG}'
    _fn_src=\$(awk '
      /^_batch_print_drift_summary\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH}')
    eval \"\$_fn_src\"
    _batch_print_drift_summary
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2 drift entries pending across 1 docs" || {
    echo "FAIL: expected '2 drift entries pending across 1 docs'" >&2
    echo "      got: $output" >&2
    return 1
  }
}

@test "behavioral: zero entries prints nothing" {
  # RITE_STATE_DIR exists but no doc-drift directory → zero entries
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${REPO_ROOT}/lib'
    export RITE_STATE_DIR='${_tmpdir}'
    print_info() { printf '%s\n' \"\$*\"; }
    source '${DRIFT_LOG}'
    _fn_src=\$(awk '
      /^_batch_print_drift_summary\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH}')
    eval \"\$_fn_src\"
    _batch_print_drift_summary
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "FAIL: expected no output when entries=0" >&2
    echo "      got: $output" >&2
    return 1
  }
}

@test "behavioral: RITE_STATE_DIR unset prints nothing (tracking off)" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${REPO_ROOT}/lib'
    unset RITE_STATE_DIR
    print_info() { printf '%s\n' \"\$*\"; }
    source '${DRIFT_LOG}'
    _fn_src=\$(awk '
      /^_batch_print_drift_summary\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH}')
    eval \"\$_fn_src\"
    _batch_print_drift_summary
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "FAIL: expected no output when RITE_STATE_DIR is unset" >&2
    echo "      got: $output" >&2
    return 1
  }
}

@test "behavioral: slash-named branch (release/1.2) — N and M both counted correctly" {
  # release/1.2 produces a 3-level-deep path: doc-drift/release/1.2/slug.log
  # -maxdepth 2 would miss it, causing M=0 while N=1 — a directly unmet AC.
  _seed_entry "$_tmpdir" "docs/architecture/foo.md" "release/1.2"

  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='${REPO_ROOT}/lib'
    export RITE_STATE_DIR='${_tmpdir}'
    print_info() { printf '%s\n' \"\$*\"; }
    source '${DRIFT_LOG}'
    _fn_src=\$(awk '
      /^_batch_print_drift_summary\(\)/ { in_func=1 }
      in_func { print }
      in_func && /^\}$/ { exit }
    ' '${BATCH}')
    eval \"\$_fn_src\"
    _batch_print_drift_summary
  "

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 drift entries pending across 1 docs" || {
    echo "FAIL: expected '1 drift entries pending across 1 docs'" >&2
    echo "      got: $output" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# STRUCTURAL
# ---------------------------------------------------------------------------

@test "structural: _batch_print_drift_summary() exists in batch-process-issues.sh" {
  grep -q '^_batch_print_drift_summary()' "$BATCH" || {
    echo "FAIL: _batch_print_drift_summary() not found in $BATCH" >&2
    return 1
  }
}

@test "structural: no 'read' command in _batch_print_drift_summary (informational only, no prompt)" {
  _fn_src=$(awk '
    /^_batch_print_drift_summary\(\)/ { in_func=1 }
    in_func { print }
    in_func && /^\}$/ { exit }
  ' "$BATCH")

  [ -n "$_fn_src" ] || {
    echo "FAIL: could not extract _batch_print_drift_summary from $BATCH" >&2
    return 1
  }

  echo "$_fn_src" | grep -qE '^\s*read\b' && {
    echo "FAIL: _batch_print_drift_summary contains a 'read' command — must not prompt" >&2
    return 1
  }
  return 0
}

@test "structural: _batch_print_drift_summary called from main body (visible in batch output)" {
  grep -q '^_batch_print_drift_summary$' "$BATCH" || {
    echo "FAIL: call site '_batch_print_drift_summary' not found in main body of $BATCH" >&2
    return 1
  }
}
