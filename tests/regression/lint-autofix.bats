#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-autofix.sh, lib/core/workflow-runner.sh
#
# The deterministic pre-gate auto-fixer. These tests are the SAFETY PROOF — an
# auto-fixer that rewrites code must be behavior-preserving, idempotent, and must
# NOT over-match. Every transformation here mirrors a sharkrite-lint rule's
# documented fix. If a future change makes a rewrite unsafe, these fail.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "${BATS_TEST_DIRNAME}/../../tools/lint-autofix.sh"
  _diag() { :; }  # silence
  # in-scope dir for BARE_VAR_REFERENCE (the rule's scope is lib/utils/*.sh)
  mkdir -p "$BATS_TEST_TMPDIR/lib/utils"
}

_fix() { autofix_file "$1"; }   # echoes 1 if changed, 0 if not

# ---- GREP_C_ECHO_ZERO ----
@test "grep -c quoted || echo \"0\" → || true (incl. inside \$(...))" {
  f="$BATS_TEST_TMPDIR/g.sh"
  printf '#!/bin/bash\nC=$(echo x | grep -c p || echo "0")\n' > "$f"
  [ "$(_fix "$f")" = "1" ]
  grep -q '|| true)' "$f"
  ! grep -q 'echo "0"' "$f"
}

@test "grep -c bare || echo 0 → || true" {
  f="$BATS_TEST_TMPDIR/g2.sh"
  printf '#!/bin/bash\nC=$(grep -c p f || echo 0)\n' > "$f"
  [ "$(_fix "$f")" = "1" ]
  grep -q '|| true)' "$f"
}

@test "grep -o (NOT grep -c) || echo \"0\" is left ALONE (no over-match)" {
  f="$BATS_TEST_TMPDIR/g3.sh"
  printf '#!/bin/bash\nC=$(grep -o p f || echo "0")\n' > "$f"
  [ "$(_fix "$f")" = "0" ]
  grep -q 'echo "0"' "$f"   # untouched
}

# ---- JQ_DEFAULT_BRACE ----
@test "\${VAR:-{}} → \${VAR:-\"{}\"}" {
  f="$BATS_TEST_TMPDIR/j.sh"
  printf '#!/bin/bash\nx="${MYVAR:-{}}"\n' > "$f"
  [ "$(_fix "$f")" = "1" ]
  grep -qF ':-"{}"}' "$f"
  ! grep -qE ':-\{\}\}' "$f"
}

# ---- BARE_VAR_REFERENCE (scoped to lib/utils/*.sh) ----
@test "bare \$EMAIL_/\$AWS_ in lib/utils → \${..:-}" {
  f="$BATS_TEST_TMPDIR/lib/utils/n.sh"
  printf '#!/bin/bash\na="$EMAIL_NOTIFICATION_ADDRESS"\nb=$AWS_PROFILE\n' > "$f"
  [ "$(_fix "$f")" = "1" ]
  grep -q '${EMAIL_NOTIFICATION_ADDRESS:-}' "$f"
  grep -q '${AWS_PROFILE:-}' "$f"
}

@test "already-braced \${SLACK_WEBHOOK:-} is left alone" {
  f="$BATS_TEST_TMPDIR/lib/utils/n2.sh"
  printf '#!/bin/bash\na="${SLACK_WEBHOOK:-}"\nb="${RITE_EMAIL_FROM}"\n' > "$f"
  [ "$(_fix "$f")" = "0" ]
}

@test "BARE_VAR is NOT applied outside lib/utils (matches rule scope)" {
  f="$BATS_TEST_TMPDIR/elsewhere.sh"
  printf '#!/bin/bash\na="$EMAIL_NOTIFICATION_ADDRESS"\n' > "$f"
  [ "$(_fix "$f")" = "0" ]
  grep -q '"$EMAIL_NOTIFICATION_ADDRESS"' "$f"   # untouched
}

# ---- safety properties ----
@test "idempotent: a second pass changes nothing" {
  f="$BATS_TEST_TMPDIR/lib/utils/idem.sh"
  printf '#!/bin/bash\nC=$(grep -c p f || echo "0")\nx="${V:-{}}"\nt=$AWS_PROFILE\n' > "$f"
  [ "$(_fix "$f")" = "1" ]
  [ "$(_fix "$f")" = "0" ]
}

@test "fixed file still parses (bash -n)" {
  f="$BATS_TEST_TMPDIR/lib/utils/p.sh"
  printf '#!/bin/bash\nC=$(grep -c p f || echo "0")\nx="${V:-{}}"\nt=$EMAIL_X_Y\n' > "$f"
  _fix "$f" >/dev/null
  bash -n "$f"
}

@test "non-shell file is ignored" {
  f="$BATS_TEST_TMPDIR/readme.md"
  printf 'C=$(grep -c p f || echo "0")\n' > "$f"
  [ "$(_fix "$f")" = "0" ]
}

@test "unchanged shell file is not rewritten (returns 0)" {
  f="$BATS_TEST_TMPDIR/lib/utils/clean.sh"
  printf '#!/bin/bash\necho hello\n' > "$f"
  [ "$(_fix "$f")" = "0" ]
}

@test "autofix_run tallies + emits LINT_AUTOFIX diag" {
  _diag() { echo "$1"; }
  f="$BATS_TEST_TMPDIR/lib/utils/r.sh"
  printf '#!/bin/bash\nx="${V:-{}}"\n' > "$f"
  run autofix_run "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINT_AUTOFIX fixed=1"* ]]
}

# ---------------------------------------------------------------------------
# Wiring pins: the orchestrator must run the prepass BOUNDED (cannot hang),
# GUARDED (absent file → skip, not crash), and BEFORE the gate. These guard the
# operator's "no lag / no hang" requirement against silent regression.
# ---------------------------------------------------------------------------
_RUNNER="${BATS_TEST_DIRNAME}/../../lib/core/workflow-runner.sh"

@test "wiring: workflow-runner invokes tools/lint-autofix.sh" {
  grep -q 'tools/lint-autofix.sh' "$_RUNNER"
}

@test "wiring: prepass is HARD-bounded by run_with_timeout (no hang)" {
  grep -qE 'run_with_timeout [0-9]+ bash "\$_autofix_script"' "$_RUNNER"
}

@test "wiring: prepass source is guarded with [ -f ] (live-lib-lag safe)" {
  grep -qE '\[ -f "\$_autofix_script" \]' "$_RUNNER"
}

@test "wiring: prepass runs BEFORE the Phase 2 gate" {
  local fix_line phase2_line
  fix_line=$(grep -n 'tools/lint-autofix.sh' "$_RUNNER" | head -1 | cut -d: -f1)
  phase2_line=$(grep -n '# Phase 2: Push work and wait for review' "$_RUNNER" | head -1 | cut -d: -f1)
  [ -n "$fix_line" ] && [ -n "$phase2_line" ]
  [ "$fix_line" -lt "$phase2_line" ]
}
