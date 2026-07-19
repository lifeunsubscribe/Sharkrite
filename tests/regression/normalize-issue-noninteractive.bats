#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/normalize-issue.sh
#
# Regression for the gate freeze (2026-07-18): normalize_piped_input()'s approval
# block read from </dev/tty unconditionally ("always interactive, even in
# --auto"). </dev/tty bypasses an fd-0 </dev/null guard, so in any
# non-interactive context — --auto, piped input, or the post-commit gate driving
# real bin/rite (bare-subcommand-routing.bats) — the blocking read SIGTTIN-stops
# the backgrounded process group and hangs the whole run to the 1800s gate
# watchdog. The fix gates the approval loop on an interactive stdin ([ -t 0 ]).
#
# These tests are LOAD-INDEPENDENT and invoke NO real rite/gate: they drive the
# function directly with fd 0 redirected from /dev/null and bound it with
# `timeout` — a timeout (exit 124) means the freeze reproduced.

setup() { RITE_LIB_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/lib"; }

# Driver that sources the function then OVERRIDES its deps with stubs (last
# definition wins — normalize-issue.sh re-sources the provider interface at
# load time, so stubbing before the source would be clobbered). This isolates
# the approval block: provider_detect_cli=false forces the bash-cleanup
# fallback, gh_safe stubs the create, so control reaches the approval loop.
_write_driver() {
  cat > "$1" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
RITE_LIB_DIR="$1"
source "$RITE_LIB_DIR/utils/normalize-issue.sh"
# Override AFTER source so these win over the real provider/gh functions.
provider_detect_cli() { return 1; }     # no CLI → bash-cleanup fallback (skips provider)
provider_run_prompt() { echo ""; }
gh_safe() { echo "https://github.com/o/r/issues/123"; return 0; }
_cleanup_title() { echo "$1"; }
print_info() { :; }; print_warning() { :; }; print_error() { :; }; print_status() { :; }
verbose_info() { :; }
normalize_piped_input "Fix the login button on mobile"
DRIVER
}

@test "anti-hang: non-interactive stdin auto-approves and does NOT block on </dev/tty" {
  _d="$BATS_TEST_TMPDIR/driver.sh"; _write_driver "$_d"
  # fd 0 = /dev/null → [ -t 0 ] is false → must auto-approve, not read the tty.
  run timeout 10 bash "$_d" "$RITE_LIB_DIR" </dev/null
  [ "$status" -ne 124 ] || {
    echo "FAIL: normalize_piped_input hung (timeout 124) under non-interactive stdin" >&2
    echo "      The approval block is still reading </dev/tty without an [ -t 0 ] guard." >&2
    return 1
  }
  # rc 0 means it auto-approved and ran through to gh issue create (not the
  # 'n'-abort path, which returns 1, and not a hang).
  [ "$status" -eq 0 ] || {
    echo "FAIL: expected rc 0 (auto-approved → created); got $status. Output: $output" >&2
    return 1
  }
}

@test "structural: the approval block is guarded by an interactive-stdin check" {
  _f="${RITE_LIB_DIR}/utils/normalize-issue.sh"
  # The </dev/tty reads must live under an `if [ ! -t 0 ]` / `[ -t 0 ]` guard,
  # not run unconditionally.
  grep -qE '\[ ! -t 0 \]|\[ -t 0 \]' "$_f" || {
    echo "FAIL: no [ -t 0 ] interactive guard around the approval block" >&2
    return 1
  }
  # And the stale 'always interactive, even in --auto' comment must be gone.
  ! grep -q 'always interactive, even in --auto' "$_f" || {
    echo "FAIL: the misleading 'always interactive, even in --auto' comment remains" >&2
    return 1
  }
}

@test "structural: the interactive approval path is preserved (still reads </dev/tty)" {
  _f="${RITE_LIB_DIR}/utils/normalize-issue.sh"
  grep -q 'read -p "Approve and create issue' "$_f"
  grep -q '</dev/tty' "$_f"
}
