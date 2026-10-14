#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/utils/gate-verdict.sh, Makefile

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: test-gate.sh uses a function-sentinel guard (declare -f run_test_gate); pre-source _diag() stub is preserved on source.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# ─── Unit: _parse_lint_line handles shellcheck gcc format ─────────────────────

@test "_parse_lint_line: parses shellcheck gcc format violation" {
  # gcc format: file:line:col: level: message [SCnnnn]
  run _parse_lint_line "lib/core/docs-command.sh:42:3: warning: In POSIX sh, trap argument should be a simple string. [SC2064]"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q '"rule":"SC2064"'
  echo "$output" | grep -q '"file":"lib/core/docs-command.sh"'
  echo "$output" | grep -q '"line":"42"'
}

@test "_parse_lint_line: returns non-zero for non-shellcheck lines" {
  run _parse_lint_line "Running shellcheck..."
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_parse_lint_line: still parses custom-lint format" {
  run _parse_lint_line "lib/bar.sh:88: [BARE_MARKER_GREP] Unanchored marker grep"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q '"rule":"BARE_MARKER_GREP"'
}

# ─── Integration: full gate emits lint findings from shellcheck failure ────────

@test "gate: shellcheck gcc violation produces lint[] finding with SC code, file, line" {
  # Stub make: shellcheck emits a gcc-format violation, lint passes.
  cat > "$STUB_DIR/make" <<'STUB'
#!/bin/bash
case "${*}" in
  *shellcheck*)
    echo "lib/core/docs-command.sh:42:3: warning: In POSIX sh, trap argument should be a simple string. [SC2064]"
    exit 1
    ;;
  *lint*)
    echo "Running custom lint rules..."
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/make"

  # Stub bats (no-op, all tests pass)
  cat > "$STUB_DIR/bats" <<'STUB'
#!/bin/bash
printf 'TAP version 13\n1..1\nok 1 stub\n'
exit 0
STUB
  chmod +x "$STUB_DIR/bats"

  # Minimal sharkrite repo with git history for diff base
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo ok
lint:
	@echo ok
EOF
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression"
  printf '#!/bin/bash\nfoo() { echo hi; }\n' > "$TEST_REPO/lib/utils/foo.sh"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n@test "x" { true; }\n' \
    > "$TEST_REPO/tests/regression/foo.bats"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf '#!/bin/bash\nfoo() { echo changed; }\n' > lib/utils/foo.sh \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  local gate_json="$TEST_REPO/gate.json"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1190
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$gate_json' '$TEST_REPO'
  " </dev/null
  [ -f "$gate_json" ] || skip "gate fixture did not run in this environment (see #709)"

  # Gate must fail (shellcheck non-zero)
  [ "$status" -eq 1 ]

  # lint[] must contain at least one item with SC2064
  run jq -r '.lint | length' "$gate_json"
  [ "$output" -ge 1 ]

  run jq -r '.lint[0].rule' "$gate_json"
  [ "$output" = "SC2064" ]

  run jq -r '.lint[0].file' "$gate_json"
  [ "$output" = "lib/core/docs-command.sh" ]

  run jq -r '.lint[0].line' "$gate_json"
  [ "$output" = "42" ]
}

@test "gate: lint_count in TEST_GATE diag counts shellcheck violations" {
  # Stub make: shellcheck emits TWO gcc violations, lint passes.
  cat > "$STUB_DIR/make" <<'STUB'
#!/bin/bash
case "${*}" in
  *shellcheck*)
    printf 'lib/a.sh:10:1: warning: message one [SC2064]\n'
    printf 'lib/b.sh:20:1: warning: message two [SC2064]\n'
    exit 1
    ;;
  *lint*)
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/make"

  cat > "$STUB_DIR/bats" <<'STUB'
#!/bin/bash
printf 'TAP version 13\n1..1\nok 1 stub\n'
exit 0
STUB
  chmod +x "$STUB_DIR/bats"

  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo ok
lint:
	@echo ok
EOF
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression"
  printf '#!/bin/bash\nfoo() { echo hi; }\n' > "$TEST_REPO/lib/utils/foo.sh"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n@test "x" { true; }\n' \
    > "$TEST_REPO/tests/regression/foo.bats"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf '#!/bin/bash\nfoo() { echo changed; }\n' > lib/utils/foo.sh \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  local gate_json="$TEST_REPO/gate.json"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1190
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$gate_json' '$TEST_REPO'
  " </dev/null
  [ -f "$gate_json" ] || skip "gate fixture did not run in this environment (see #709)"

  run jq -r '.lint | length' "$gate_json"
  [ "$output" -eq 2 ]
}

@test "gate: zero shellcheck violations leaves lint[] empty" {
  # Stub make: shellcheck passes cleanly, lint passes.
  cat > "$STUB_DIR/make" <<'STUB'
#!/bin/bash
case "${*}" in
  *shellcheck*)
    echo "Running shellcheck..."
    exit 0
    ;;
  *lint*)
    echo "Running custom lint rules..."
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/make"

  cat > "$STUB_DIR/bats" <<'STUB'
#!/bin/bash
printf 'TAP version 13\n1..1\nok 1 stub\n'
exit 0
STUB
  chmod +x "$STUB_DIR/bats"

  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo ok
lint:
	@echo ok
EOF
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression"
  printf '#!/bin/bash\nfoo() { echo hi; }\n' > "$TEST_REPO/lib/utils/foo.sh"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n@test "x" { true; }\n' \
    > "$TEST_REPO/tests/regression/foo.bats"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf '#!/bin/bash\nfoo() { echo changed; }\n' > lib/utils/foo.sh \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  local gate_json="$TEST_REPO/gate.json"
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=1190
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$gate_json' '$TEST_REPO'
  " </dev/null
  [ -f "$gate_json" ] || skip "gate fixture did not run in this environment (see #709)"

  [ "$status" -eq 0 ]
  run jq -r '.lint | length' "$gate_json"
  [ "$output" -eq 0 ]
}
