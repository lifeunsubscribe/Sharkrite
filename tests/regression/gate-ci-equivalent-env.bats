#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/utils/gate-runners.sh
#
# Regression: the post-commit gate's targeted bats selection must run in a
# CI-equivalent environment to prevent test breakage that is invisible locally
# but red in CI (issue #1607).
#
# Three hostile-environment factors addressed:
#   1. claude binary absent/untrusted in CI — masked with a shim that exits 1.
#      10 of the 2026-10-27 red-main episode's 38 failures came from tests that
#      silently depended on a real claude binary in PATH.
#   2. GNU tools preferred when installed — 18 of the episode's failures came
#      from BSD/GNU regex divergences invisible on the macOS dev machine.
#   3. flock(1) availability exposed — 2 tests never ran locally (macOS has no
#      flock) so "0 failures" was not the same as "everything ran".

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
}

# ---------------------------------------------------------------------------
# Structural: _bats_sandbox now includes a PATH= entry
# ---------------------------------------------------------------------------

@test "structural: _bats_sandbox contains a PATH= entry for CI-equivalent env" {
  # After #1607 the sandbox must set PATH so bats children see the shim dir and
  # (when present) the GNU tool gnubin dirs.
  _def=$(sed -n '/_bats_sandbox=(env -u/,/)/p' "${RITE_LIB_DIR}/utils/test-gate.sh")
  [ -n "$_def" ]
  # The PATH assignment is _outside_ the -u list (it's a VAR=VAL, not -u VAR).
  # We look for it in the broader assembly block that follows _bats_sandbox.
  grep -q 'PATH=' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: test-gate.sh must set PATH= for CI-equivalent env" >&2
    return 1
  }
  grep -q '_bats_sandbox+=(PATH=' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: PATH must be appended to _bats_sandbox via _bats_sandbox+=(PATH=...)" >&2
    return 1
  }
}

@test "structural: _cienv_shim_dir is initialized before the EXIT trap body" {
  # The trap must guard rm -rf with a non-empty check.  If _cienv_shim_dir is
  # never initialised before the trap fires, the guard would expand to rm -rf ""
  # which is a no-op — but we want the initialisation to prove intent.
  grep -q '_cienv_shim_dir=""' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: _cienv_shim_dir must be initialised to empty before the trap" >&2
    return 1
  }
}

@test "structural: _cienv_shim_dir is cleaned up in the EXIT trap" {
  # The pattern mirrors _bats_tap_dir cleanup already in the trap.
  grep -q '"${_cienv_shim_dir:-}"' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: _cienv_shim_dir must be cleaned up via rm -rf in the EXIT trap" >&2
    return 1
  }
}

@test "structural: GATE_ENV diag is emitted inside the sharkrite terminal digest" {
  grep -q 'GATE_ENV gnu=' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: GATE_ENV diag must be emitted with gnu= field" >&2
    return 1
  }
  grep -q 'claude=masked' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: GATE_ENV diag must include claude=masked" >&2
    return 1
  }
  grep -q 'flock=' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: GATE_ENV diag must include flock= field" >&2
    return 1
  }
  grep -q 'skipped=' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: GATE_ENV diag must include skipped= field" >&2
    return 1
  }
}

@test "structural: skip count subtracts from pass count before terminal output" {
  # _bats_pass currently includes TAP ^ok lines that have # skip.  We must
  # subtract _bats_skip_count so the digest shows genuine passes only.
  grep -q '_bats_pass=.*_bats_pass.*_bats_skip_count' "${RITE_LIB_DIR}/utils/test-gate.sh" || {
    echo "FAIL: _bats_pass must be corrected by subtracting _bats_skip_count" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Unit: _cienv_gnu_prefix helper
# ---------------------------------------------------------------------------

@test "unit: _cienv_gnu_prefix returns empty string when no gnubin dirs exist" {
  # Skip when ggrep (Homebrew GNU grep) is installed — the function will find
  # the real gnubin dirs and return a non-empty prefix, which is correct
  # behaviour but defeats the "empty when absent" assertion.  Test 7 covers the
  # installed case.
  command -v ggrep >/dev/null 2>&1 && skip "ggrep (GNU grep via Homebrew) is installed — _cienv_gnu_prefix will return non-empty on this machine"
  _tmpdir=$(mktemp -d)
  cat > "$_tmpdir/probe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$1"
result=$(_cienv_gnu_prefix)
if [ -n "$result" ]; then
  echo "FAIL: expected empty prefix, got: $result" >&2
  exit 1
fi
EOF
  # On macOS without Homebrew grep/gawk gnubin the function should return "".
  # On Linux system grep/awk are GNU but live at /usr/bin, not in gnubin dirs —
  # so the function also returns "" (it only checks the Homebrew install paths).
  run bash "$_tmpdir/probe.sh" "${RITE_LIB_DIR}/utils/gate-runners.sh"
  rm -rf "$_tmpdir"
  [ "$status" -eq 0 ]
}

@test "unit: _cienv_gnu_prefix returns a trailing-colon prefix when gnubin present" {
  command -v ggrep >/dev/null 2>&1 || skip "ggrep (GNU grep via Homebrew) not installed"
  _tmpdir=$(mktemp -d)
  cat > "$_tmpdir/probe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$1"
result=$(_cienv_gnu_prefix)
# When a gnubin dir is present the prefix must be non-empty and end with ':'
# (so it can be prepended to PATH without introducing a double-colon).
[ -n "$result" ] || { echo "FAIL: expected non-empty prefix with ggrep installed" >&2; exit 1; }
case "$result" in
  *:) ;;
  *) echo "FAIL: prefix must end with ':', got: '$result'" >&2; exit 1 ;;
esac
EOF
  run bash "$_tmpdir/probe.sh" "${RITE_LIB_DIR}/utils/gate-runners.sh"
  rm -rf "$_tmpdir"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Behavioral: claude shim masks the real binary
# ---------------------------------------------------------------------------

@test "behavioral: a claude shim in a prepended dir shadows real claude" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  # Create a shim matching what test-gate.sh writes
  printf '#!/bin/sh\necho "[gate-cienv] claude is masked" >&2\nexit 1\n' > "$_d/claude"
  chmod +x "$_d/claude"
  # Write a probe bats test that runs claude and asserts it fails
  cat > "$_d/probe.bats" <<'EOF'
@test "probe: claude exits non-zero when masked by shim" {
  run claude --version
  [ "$status" -ne 0 ]
}
EOF
  run env PATH="$_d:$PATH" bats "$_d/probe.bats" < /dev/null
  rm -rf "$_d"
  [ "$status" -eq 0 ]
}

@test "behavioral: claude shim file is executable and exits 1" {
  _d=$(mktemp -d)
  printf '#!/bin/sh\necho "[gate-cienv] claude is masked in CI-equivalent gate environment" >&2\nexit 1\n' \
    > "$_d/claude"
  chmod +x "$_d/claude"
  run "$_d/claude"
  rm -rf "$_d"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Behavioral: skip count is extracted from TAP output
# ---------------------------------------------------------------------------

@test "behavioral: _bats_skip_count is positive when TAP contains skip lines" {
  # Verify that the grep pattern '# skip' (lowercase) matches bats-core output.
  # bats-core emits: "ok N test name # skip reason" (lowercase skip).
  _tap=$(printf 'ok 1 runs fine\nok 2 skipped test # skip flock not available\nok 3 another skip # skip no tool\nnot ok 4 failure\n')
  _count=$(printf '%s\n' "$_tap" | grep -c "# skip" || true)
  [ "$_count" -eq 2 ] || {
    echo "FAIL: expected 2 skip lines, got $_count" >&2
    return 1
  }
}

@test "behavioral: _bats_skip_count grep pattern does not match uppercase SKIP" {
  # The gate uses lowercase 'skip' — ensure uppercase SKIP does not match.
  _tap=$(printf 'ok 1 test # SKIP uppercase should not match\n')
  _count=$(printf '%s\n' "$_tap" | grep -c "# skip" || true)
  [ "$_count" -eq 0 ] || {
    echo "FAIL: uppercase '# SKIP' must not be counted as a skip directive" >&2
    return 1
  }
}
