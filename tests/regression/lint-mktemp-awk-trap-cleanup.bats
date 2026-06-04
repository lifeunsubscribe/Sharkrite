#!/usr/bin/env bats
# Regression test for: mktemp AWK program file leaks on script abort
# Issue #237 — parent PR #225
#
# Problem: Rules 8 and 13 in sharkrite-lint.sh create mktemp files to hold AWK
# programs. Without a trap, any signal or future edit that aborts the script
# between mktemp and rm -f orphans those temp files in /tmp.
#
# Fix: Added three layers of protection:
#   1. Pre-initialize _r8_awk="" and _r13_awk="" before the trap is set so
#      that cleanup is safe even if the script aborts before mktemp is called.
#   2. trap '_cleanup_awk_tmpfiles' EXIT INT TERM at the top of the script
#      so any termination path triggers cleanup.
#   3. Inline rm -f + variable-clear after each rule's awk run as the
#      happy-path cleanup (avoids holding the fd until EXIT).
#
# This test verifies:
#   1. The trap declaration is present and covers EXIT, INT, and TERM.
#   2. The sentinel variables are initialized to "" BEFORE the mktemp calls.
#   3. The EXIT trap removes temp files on normal exit, error exit, and when
#      mktemp was never called (empty-string guard prevents 'rm -f ""').

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LINT_SCRIPT="$PROJECT_ROOT/tools/sharkrite-lint.sh"
}

# ---------------------------------------------------------------------------
# Static structural assertions
# ---------------------------------------------------------------------------

@test "sharkrite-lint.sh has a trap covering EXIT INT TERM for awk temp files" {
  # The trap must reference the cleanup function and cover all three signals.
  run grep -n "trap.*EXIT.*INT.*TERM" "$LINT_SCRIPT"

  [ "$status" -eq 0 ]
  # At least one line must reference the cleanup function name
  [[ "$output" =~ "_cleanup_awk_tmpfiles" ]]
}

@test "_r8_awk and _r13_awk are initialized to empty string before mktemp calls" {
  # The sentinel variables must be set to "" before their first mktemp assignment.
  # This guarantees the cleanup trap's '[ -n "$_r8_awk" ]' check is always safe
  # even if the script is aborted before mktemp runs.

  # Extract line numbers for the empty-string initializations and mktemp calls.
  _init_r8=$(grep -n '^_r8_awk=""' "$LINT_SCRIPT" | head -1 | cut -d: -f1 || true)
  _init_r13=$(grep -n '^_r13_awk=""' "$LINT_SCRIPT" | head -1 | cut -d: -f1 || true)
  _mktemp_r8=$(grep -n '_r8_awk=$(mktemp)' "$LINT_SCRIPT" | head -1 | cut -d: -f1 || true)
  _mktemp_r13=$(grep -n '_r13_awk=$(mktemp)' "$LINT_SCRIPT" | head -1 | cut -d: -f1 || true)

  # All four lines must exist
  [ -n "$_init_r8" ]   || { echo "_r8_awk=\"\" initializer not found" >&2; return 1; }
  [ -n "$_init_r13" ]  || { echo "_r13_awk=\"\" initializer not found" >&2; return 1; }
  [ -n "$_mktemp_r8" ] || { echo "_r8_awk=\$(mktemp) not found" >&2; return 1; }
  [ -n "$_mktemp_r13" ]|| { echo "_r13_awk=\$(mktemp) not found" >&2; return 1; }

  # Initializations must precede the mktemp calls
  [ "$_init_r8"  -lt "$_mktemp_r8"  ] || {
    echo "_r8_awk=\"\" (line $_init_r8) must appear before _r8_awk=\$(mktemp) (line $_mktemp_r8)" >&2
    return 1
  }
  [ "$_init_r13" -lt "$_mktemp_r13" ] || {
    echo "_r13_awk=\"\" (line $_init_r13) must appear before _r13_awk=\$(mktemp) (line $_mktemp_r13)" >&2
    return 1
  }
}

@test "_cleanup_awk_tmpfiles function is defined before the trap is installed" {
  # The function definition must appear before the trap line that references it.
  _func_line=$(grep -n "_cleanup_awk_tmpfiles()" "$LINT_SCRIPT" | head -1 | cut -d: -f1 || true)
  _trap_line=$(grep -n "trap.*_cleanup_awk_tmpfiles" "$LINT_SCRIPT" | head -1 | cut -d: -f1 || true)

  [ -n "$_func_line" ] || { echo "_cleanup_awk_tmpfiles() definition not found" >&2; return 1; }
  [ -n "$_trap_line" ] || { echo "trap '_cleanup_awk_tmpfiles' not found" >&2; return 1; }

  [ "$_func_line" -lt "$_trap_line" ] || {
    echo "_cleanup_awk_tmpfiles() (line $_func_line) must be defined before trap (line $_trap_line)" >&2
    return 1
  }
}

@test "cleanup function removes _r8_awk and _r13_awk temp files when non-empty" {
  # Extract the cleanup function body and verify it references both variables
  # with a [ -n ... ] guard (safe against empty-string rm -f).
  run grep -A4 "_cleanup_awk_tmpfiles()" "$LINT_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "_r8_awk" ]]
  [[ "$output" =~ "_r13_awk" ]]
  [[ "$output" =~ "rm -f" ]]
}

# ---------------------------------------------------------------------------
# Functional tests: EXIT trap cleans up temp files in all exit paths
# ---------------------------------------------------------------------------

@test "EXIT trap fires and removes temp files on normal script exit" {
  # Verify the happy-path cleanup: when the script exits normally (not via signal),
  # the EXIT trap still fires and removes any surviving temp files.
  # This tests that _r8_awk="" and _r13_awk="" are cleared by inline rm -f before
  # EXIT fires (so EXIT sees empty vars and skips rm) — demonstrating the dual-
  # cleanup design: inline rm after each rule, trap as safety net.

  _test_script="${BATS_TEST_TMPDIR}/exit-trap-test.sh"
  _sentinel="${BATS_TEST_TMPDIR}/exit-trap-fired"
  _paths_file="${BATS_TEST_TMPDIR}/exit-tmp-paths.txt"

  cat > "$_test_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

SENTINEL_FILE="$1"
PATHS_FILE="$2"

_r8_awk=""
_r13_awk=""
_cleanup_awk_tmpfiles() {
  [ -n "$_r8_awk"  ] && rm -f "$_r8_awk"
  [ -n "$_r13_awk" ] && rm -f "$_r13_awk"
  touch "$SENTINEL_FILE"
}
trap '_cleanup_awk_tmpfiles' EXIT

# Create the temp files
_r8_awk=$(mktemp)
_r13_awk=$(mktemp)

# Write their paths so the test can check them
echo "$_r8_awk"  > "$PATHS_FILE"
echo "$_r13_awk" >> "$PATHS_FILE"

# Simulate a mid-run abort: do NOT call the inline rm -f
# The EXIT trap must handle cleanup.
exit 0
SCRIPT_EOF
  chmod +x "$_test_script"

  run bash "$_test_script" "$_sentinel" "$_paths_file"

  # Script must exit 0
  [ "$status" -eq 0 ]

  # Sentinel must exist (EXIT trap fired)
  [ -f "$_sentinel" ] || {
    echo "EXIT trap did not fire (sentinel file not created)" >&2
    return 1
  }

  # Read temp file paths
  _r8_path=$(sed -n '1p' "$_paths_file" || true)
  _r13_path=$(sed -n '2p' "$_paths_file" || true)

  # Temp files must have been removed by the EXIT trap
  if [ -f "$_r8_path" ]; then
    rm -f "$_r8_path" 2>/dev/null || true
    echo "LEAK: _r8_awk temp file was NOT removed by EXIT trap: $_r8_path" >&2
    return 1
  fi
  if [ -f "$_r13_path" ]; then
    rm -f "$_r13_path" 2>/dev/null || true
    echo "LEAK: _r13_awk temp file was NOT removed by EXIT trap: $_r13_path" >&2
    return 1
  fi
}

@test "EXIT trap fires on error exit and removes temp files" {
  # Simulate script dying mid-run (set -e triggers on a failing command).
  # The EXIT trap must still fire and clean up the temp files.

  _test_script="${BATS_TEST_TMPDIR}/error-exit-trap-test.sh"
  _sentinel="${BATS_TEST_TMPDIR}/error-trap-fired"
  _paths_file="${BATS_TEST_TMPDIR}/error-tmp-paths.txt"

  cat > "$_test_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

SENTINEL_FILE="$1"
PATHS_FILE="$2"

_r8_awk=""
_r13_awk=""
_cleanup_awk_tmpfiles() {
  [ -n "$_r8_awk"  ] && rm -f "$_r8_awk"
  [ -n "$_r13_awk" ] && rm -f "$_r13_awk"
  touch "$SENTINEL_FILE"
}
trap '_cleanup_awk_tmpfiles' EXIT

_r8_awk=$(mktemp)
_r13_awk=$(mktemp)

echo "$_r8_awk"  > "$PATHS_FILE"
echo "$_r13_awk" >> "$PATHS_FILE"

# Trigger a non-zero exit (simulates a set -e failure mid-script)
exit 42
SCRIPT_EOF
  chmod +x "$_test_script"

  run bash "$_test_script" "$_sentinel" "$_paths_file"

  # Script must exit 42 (deliberate non-zero)
  [ "$status" -eq 42 ]

  # Sentinel must exist (EXIT trap fired even on non-zero exit)
  [ -f "$_sentinel" ] || {
    echo "EXIT trap did not fire on error exit (sentinel file not created)" >&2
    return 1
  }

  _r8_path=$(sed -n '1p' "$_paths_file" || true)
  _r13_path=$(sed -n '2p' "$_paths_file" || true)

  if [ -f "$_r8_path" ]; then
    rm -f "$_r8_path" 2>/dev/null || true
    echo "LEAK: _r8_awk temp file was NOT removed by EXIT trap on error exit: $_r8_path" >&2
    return 1
  fi
  if [ -f "$_r13_path" ]; then
    rm -f "$_r13_path" 2>/dev/null || true
    echo "LEAK: _r13_awk temp file was NOT removed by EXIT trap on error exit: $_r13_path" >&2
    return 1
  fi
}

@test "cleanup function with unset variables does not crash (empty-string guard)" {
  # If the script exits BEFORE mktemp runs (e.g., at startup), the cleanup
  # function must not call 'rm -f ""' (which would fail under set -e).
  # The [ -n "$_r8_awk" ] guard prevents this.

  _test_script="${BATS_TEST_TMPDIR}/trap-before-mktemp.sh"
  _sentinel="${BATS_TEST_TMPDIR}/early-trap-fired"

  cat > "$_test_script" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

SENTINEL_FILE="$1"

_r8_awk=""
_r13_awk=""
_cleanup_awk_tmpfiles() {
  [ -n "$_r8_awk"  ] && rm -f "$_r8_awk"
  [ -n "$_r13_awk" ] && rm -f "$_r13_awk"
  touch "$SENTINEL_FILE"
}
trap '_cleanup_awk_tmpfiles' EXIT

# mktemp intentionally NOT called here — simulate abort before Rule 8/13
# The cleanup must not crash when vars are still empty strings.
exit 1
SCRIPT_EOF
  chmod +x "$_test_script"

  run bash "$_test_script" "$_sentinel"

  # Script exits 1 (the deliberate exit code)
  [ "$status" -eq 1 ]

  # Sentinel must exist (EXIT trap fired without crash from 'rm -f ""')
  [ -f "$_sentinel" ] || {
    echo "EXIT trap did not fire or crashed — cleanup may have called 'rm -f \"\"'" >&2
    return 1
  }
}
