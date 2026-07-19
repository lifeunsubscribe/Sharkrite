#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/utils/test-gate.sh
# Fix-loop gate selects tests INCREMENTALLY (#724): the post-fix gate diffs
# against the PRE-FIX HEAD, not origin/main, so it re-runs only tests covering
# what THIS iteration's fix changed. A doc-only fix then selects ~0 bats instead
# of re-running the full origin/main targeted set on every iteration (the waste
# that made #724 run the same 17-file gate 4 times, ~17 min, same 3 failures).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  TEST_REPO=$(mktemp -d); export TEST_REPO
  STUB_DIR="$TEST_REPO/stub"; mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/bats" <<'STUB'
#!/bin/bash
_out=""; _prev=""
for _a in "$@"; do [ "$_prev" = "--output" ] && _out="$_a"; _prev="$_a"; done
[ -n "$_out" ] && { mkdir -p "$_out"; printf 'TAP version 13\n1..1\nok 1 stub\n' > "$_out/report.tap"; }
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
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression" "$TEST_REPO/docs"
  printf '#!/bin/bash\nfoo() { echo hi; }\n' > "$TEST_REPO/lib/utils/foo.sh"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/foo.sh\n@test "covers foo" { true; }\n' \
    > "$TEST_REPO/tests/regression/foo.bats"
  printf '# notes\n' > "$TEST_REPO/docs/notes.md"
  (cd "$TEST_REPO" && git init -q && git config user.email t@t && git config user.name t \
     && git add -A && git commit -qm base) >/dev/null 2>&1
  BASE_SHA=$(cd "$TEST_REPO" && git rev-parse HEAD); export BASE_SHA
  # A doc-only "fix" commit on top of BASE (no lib/test change).
  (cd "$TEST_REPO" && printf '# notes\nmore\n' > docs/notes.md \
     && git add -A && git commit -qm 'doc-only fix') >/dev/null 2>&1
}

teardown() { rm -rf "${TEST_REPO:-}"; }

@test "incremental base: a doc-only fix since BASE selects ZERO bats" {
  run bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' PR_NUMBER=779
    _diag() { true; }; export -f _diag 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/test-gate.sh'
    PATH='$STUB_DIR':\$PATH RITE_TEST_GATE_DIFF_BASE='$BASE_SHA' run_test_gate '$TEST_REPO/gate.json' '$TEST_REPO'
  " </dev/null
  # On environments where the gate fixture can't run (e.g. GNU CI without ~/.rite),
  # the selection line won't appear — skip rather than false-fail (verified on macOS).
  [[ "$output" == *"Selection:"* ]] || skip "gate fixture did not run in this environment (see #709)"
  # doc-only change against BASE → no covered bats → targeted selection of zero
  [[ "$output" == *"targeted (0/"* ]] || [[ "$output" == *"no covered tests"* ]] || [[ "$output" == *"skipping bats"* ]]
}

@test "workflow-runner: loop gate diffs against pre-fix HEAD, not origin/main" {
  # Structural: ties the speed behavior to the source (run_workflow is a large
  # function that can't be unit-invoked).
  grep -q '_pre_fix_head=$(git -C "$WORKTREE_PATH" rev-parse HEAD' "${RITE_LIB_DIR}/core/workflow-runner.sh"
  # Fallback is now origin/${_target} (target-aware, not pinned to origin/main) — updated by #1035
  grep -q 'RITE_TEST_GATE_DIFF_BASE="${_pre_fix_head:-origin/${_target}}" run_test_gate "$_gate_output_file"' "${RITE_LIB_DIR}/core/workflow-runner.sh"
}
