#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression: FORCE_FULL (the full ~181-file bats suite) is OPT-IN ONLY.
#
# The recurring "the full suite runs every time" regression came from a shared
# sentinel: _select_tests_by_changed_paths emits FORCE_FULL on an EMPTY
# changed-file set, and `git diff origin/main...HEAD 2>/dev/null || true`
# launders BOTH "no commits" and "diff errored / base unresolvable" into the
# same empty string. So a transient origin/main hiccup (or a caller that bypassed
# the upstream non-empty-diff guarantee) silently escalated a normal run to all
# ~181 files. The fix makes a full run require an EXPLICIT signal:
# RITE_GATE_FORCE_FULL=1, or a deliberately-HEAD diff base. An empty/errored
# diff against the DEFAULT base never runs the whole suite.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  ARGS_LOG="$TEST_REPO/bats_args.log"; export ARGS_LOG
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"

  # Fake bats: log argv (so we can assert -r tests/ was/wasn't passed), write a
  # minimal TAP report if --output is given, exit 0. Lacks "--report-formatter"
  # so the gate takes its fallback bats path — still passes -r tests/ on a full run.
  cat > "$STUB_DIR/bats" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGS_LOG"
_out=""
_prev=""
for _a in "\$@"; do [ "\$_prev" = "--output" ] && _out="\$_a"; _prev="\$_a"; done
[ -n "\$_out" ] && { mkdir -p "\$_out"; printf 'TAP version 13\n1..1\nok 1 stub\n' > "\$_out/report.tap"; }
exit 0
STUB
  chmod +x "$STUB_DIR/bats"

  # Mock sharkrite repo: Makefile with no-op shellcheck:/lint: (gate detects
  # sharkrite by those targets), one bats test, committed.
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo ok
lint:
	@echo ok
EOF
  mkdir -p "$TEST_REPO/tests/regression"
  printf '#!/usr/bin/env bats\n@test "smoke" { true; }\n' > "$TEST_REPO/tests/regression/smoke.bats"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base) >/dev/null 2>&1
  # origin/main resolves AND equals HEAD → `git diff origin/main...HEAD` is EMPTY
  # (the exact "base resolves but no changed files" case that must NOT go full).
  (cd "$TEST_REPO" && git update-ref refs/remotes/origin/main HEAD) >/dev/null 2>&1
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# $1 = extra env assignments prefixed to the run_test_gate call (may be empty)
_run_gate() {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=777
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    $1 PATH=$STUB_DIR:\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
}

@test "empty origin/main diff (base resolves) does NOT run the full suite" {
  _run_gate ""
  [ "$status" -eq 0 ]
  # Must not take the FORCE_FULL branch, and bats must not be invoked with -r tests/.
  [[ "$output" != *"Selection: full suite"* ]]
  if [ -f "$ARGS_LOG" ]; then
    ! grep -q -- '-r tests' "$ARGS_LOG"
  fi
}

@test "RITE_GATE_FORCE_FULL=1 runs the full suite (-r tests/)" {
  _run_gate "RITE_GATE_FORCE_FULL=1"
  [ "$status" -eq 0 ]
  [ -f "$ARGS_LOG" ]
  grep -q -- '-r tests' "$ARGS_LOG"
}

@test "deliberate DIFF_BASE=HEAD still runs the full suite (-r tests/)" {
  _run_gate "RITE_TEST_GATE_DIFF_BASE=HEAD"
  [ "$status" -eq 0 ]
  [ -f "$ARGS_LOG" ]
  grep -q -- '-r tests' "$ARGS_LOG"
}
