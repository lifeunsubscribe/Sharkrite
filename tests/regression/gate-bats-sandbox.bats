#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
#
# The gate must run bats in a sandbox: stdin from /dev/null, live-workflow env
# scrubbed, and a whole-run watchdog OUTSIDE the bats process group.
#
# Live freeze (2026-07-01, rite 804): the gate's bats run inherited the
# workflow's tty stdin and environment. A regression test executed the real
# bin/rite, which wrote to the REAL run log via inherited RITE_LOG_FILE,
# spawned an orphaned create-pr.sh carrying the real PR_NUMBER (which ran a
# second gate + real reviews against the live PR), and read the tty from a
# background job — SIGTTIN stopped the whole bats process group, including the
# BATS_TEST_TIMEOUT per-test watchdogs, freezing the gate ~3.5h until manually
# killed. Neither the per-test timeout (#654-adjacent) nor the outer wait
# backstop bounded this path.

setup() { export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"; }

@test "structural: sandbox env scrub is defined with all deny-listed vars" {
  # Workflow vars (live-freeze class, see header) plus BATS_* IPC vars (#993:
  # inherited BATS_RUN_TMPDIR/BATS_ROOT_PID deadlock nested bats runs). The
  # definition spans continuation lines, so extract from the opening paren to
  # the closing paren and assert each -u flag is present.
  _def=$(sed -n '/_bats_sandbox=(env -u/,/)/p' "${RITE_LIB_DIR}/utils/test-gate.sh")
  [ -n "$_def" ]
  for _var in RITE_LOG_FILE PR_NUMBER ISSUE_NUMBER \
      BATS_RUN_TMPDIR BATS_SUITE_TMPDIR BATS_FILE_TMPDIR \
      BATS_TEST_TMPDIR BATS_ROOT_PID BATS_LIBEXEC_DIR \
      BATS_TMPDIR BATS_SUITE_TEST_NUMBER; do
    echo "$_def" | grep -q -- "-u $_var" || {
      echo "FAIL: _bats_sandbox scrub is missing -u $_var" >&2
      return 1
    }
  done
  # BATS_TEST_TIMEOUT must NOT be scrubbed: the gate exports its own per-test
  # watchdog value, and -u here would strip that export from the wrapped bats,
  # disabling per-test timeouts and breaking swallowed-test detection (live
  # regression caught by gate-notrun-detection.bats tests 14/15 on PR #995).
  echo "$_def" | grep -q -- "-u BATS_TEST_TIMEOUT" && {
    echo "FAIL: _bats_sandbox must not scrub BATS_TEST_TIMEOUT (gate-owned export)" >&2
    return 1
  }
  return 0
}

@test "structural: sandbox is defined BEFORE the first bats invocation" {
  _sandbox_ln=$(grep -nE '_bats_sandbox=\(env -u' "${RITE_LIB_DIR}/utils/test-gate.sh" | head -1 | cut -d: -f1)
  _first_bats_ln=$(grep -nE '\-\-report-formatter tap --output' "${RITE_LIB_DIR}/utils/test-gate.sh" | head -1 | cut -d: -f1)
  [ -n "$_sandbox_ln" ]
  [ -n "$_first_bats_ln" ]
  [ "$_sandbox_ln" -lt "$_first_bats_ln" ]
}

@test "structural: every bats invocation applies the sandbox and stdin redirect" {
  # 6 invocation sites: full/parallel/serial x pretty/tap-fallback.
  _sandbox_uses=$(grep -c '"\${_bats_sandbox\[@\]}"' "${RITE_LIB_DIR}/utils/test-gate.sh")
  [ "$_sandbox_uses" -ge 6 ]
  _stdin_redirects=$(grep -c '< /dev/null' "${RITE_LIB_DIR}/utils/test-gate.sh")
  [ "$_stdin_redirects" -ge 6 ]
}

@test "structural: whole-run watchdog wraps bats and is prompt-free" {
  # Watchdog array built from gtimeout/timeout via command -v (no
  # ensure_timeout_cmd — its supervised-mode prompt would read stdin mid-gate).
  grep -qE '_bats_watchdog=\(gtimeout -k 30' "${RITE_LIB_DIR}/utils/test-gate.sh"
  grep -qE '_bats_watchdog=\(timeout -k 30' "${RITE_LIB_DIR}/utils/test-gate.sh"
  # No ensure_timeout_cmd CALLS (comment lines excluded — the rationale comment
  # names it deliberately).
  ! grep -vE '^\s*#' "${RITE_LIB_DIR}/utils/test-gate.sh" | grep -q 'ensure_timeout_cmd'
  _watchdog_uses=$(grep -c '_bats_watchdog\[@\]' "${RITE_LIB_DIR}/utils/test-gate.sh")
  # Definition sites + 6 invocation sites
  [ "$_watchdog_uses" -ge 6 ]
}

@test "structural: watchdog kill (exit 124/137) is surfaced with a diag line" {
  _kill_notes=$(grep -c 'TEST_GATE_WATCHDOG_KILL' "${RITE_LIB_DIR}/utils/test-gate.sh")
  # full + parallel + serial paths
  [ "$_kill_notes" -ge 3 ]
}

@test "behavioral: gate-style invocation strips workflow env and gives tests EOF stdin" {
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  _d=$(mktemp -d)
  cat > "$_d/sandbox-probe.bats" <<'EOF'
@test "probe" {
  [ -z "${RITE_LOG_FILE:-}" ]
  [ -z "${PR_NUMBER:-}" ]
  # cat must return immediately (EOF from /dev/null), not block on a tty.
  _got=$(cat)
  [ -z "$_got" ]
}
EOF
  _start=$(date +%s)
  run env RITE_LOG_FILE=/tmp/must-not-leak.log PR_NUMBER=999 \
      env -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER \
      bats "$_d/sandbox-probe.bats" < /dev/null
  _elapsed=$(( $(date +%s) - _start ))
  rm -rf "$_d"
  [ "$status" -eq 0 ]
  [ "$_elapsed" -lt 30 ]
}

@test "behavioral: rite-spawning test file redirects every rite invocation's stdin" {
  # The file whose test froze the 2026-07-01 gate: every real-bin/rite
  # invocation must carry < /dev/null so it can never read the gate's tty.
  _rite_calls=$(grep -c 'bash "\$_FAKE_BIN/rite"' \
    "${BATS_TEST_DIRNAME}/bare-subcommand-routing.bats")
  _guarded_calls=$(grep 'bash "\$_FAKE_BIN/rite"' \
    "${BATS_TEST_DIRNAME}/bare-subcommand-routing.bats" | grep -c '< /dev/null')
  [ "$_rite_calls" -gt 0 ]
  [ "$_rite_calls" -eq "$_guarded_calls" ]
}
