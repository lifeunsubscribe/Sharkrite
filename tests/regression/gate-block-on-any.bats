#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Phase 3: the gate blocks on ANY test failure in the targeted selection.
#
# Baseline-diff (new-vs-pre-existing suppression) was removed once main went
# green: with a green base, every failure in the targeted selection is this
# change's to fix, so the gate blocks on all of them. This replaces the old
# _classify_test_failures / _compute_baseline_red_names probe machinery
# (deleted), whose only purpose was to tolerate a red baseline on origin/main.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"

  # Fake bats: emit a FAILING TAP on stdout and exit non-zero. It lacks the
  # --report-formatter string, so the gate takes its fallback (stdout-TAP) path.
  cat > "$STUB_DIR/bats" <<'STUB'
#!/bin/bash
printf 'TAP version 13\n1..1\nnot ok 1 deliberately failing test\n'
exit 1
STUB
  chmod +x "$STUB_DIR/bats"

  # Mock sharkrite repo: Makefile with no-op shellcheck:/lint: (gate detects
  # sharkrite by those targets), a lib file, and a bats test that covers it.
  # A second commit changes the lib file so the changed-paths diff selects the
  # covering test (targeted selection, not FORCE_FULL).
  cat > "$TEST_REPO/Makefile" <<'EOF'
.PHONY: shellcheck lint
shellcheck:
	@echo ok
lint:
	@echo ok
EOF
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression"
  printf '#!/bin/bash\nfoo() { echo hi; }\n' > "$TEST_REPO/lib/utils/foo.sh"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n@test "covers foo" { true; }\n' \
    > "$TEST_REPO/tests/regression/foo.bats"
  (cd "$TEST_REPO" \
     && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base \
     && git update-ref refs/remotes/origin/main HEAD \
     && printf '#!/bin/bash\nfoo() { echo changed; }\n' > lib/utils/foo.sh \
     && git add -A && git commit -qm change) >/dev/null 2>&1

  _diag() { true; }
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
}

teardown() { rm -rf "${TEST_REPO:-}"; }

@test "_tap_failure_name strips prefix and trailing whitespace" {
  run _tap_failure_name "not ok 12 some descriptive name   "
  [ "$status" -eq 0 ]
  [ "$output" = "some descriptive name" ]
}

@test "block-on-any: a failing test in the targeted selection fails the gate" {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=778
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
  [ "$status" -eq 1 ]
  [ -f "$TEST_REPO/gate.json" ]

  # outcome=failed ⟺ exit_code=1
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]

  # The failure is reported in tests[] (NOT suppressed as 'pre-existing').
  run jq -r '.tests | length' "$TEST_REPO/gate.json"
  [ "$output" -ge 1 ]
}
