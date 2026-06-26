#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh, lib/core/assess-and-resolve.sh
# Phase 3: the gate blocks on ANY test failure in the targeted selection.
# Issue #718: block-on-any extended to the merge boundary (assess-and-resolve
# retry-cap) — [GATE] ACTIONABLE_NOW findings at 3/3 retries block merge.
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
  # On environments where the gate fixture cannot complete (e.g. GNU CI without
  # the ~/.rite install env config.sh expects — the same condition the sibling
  # gate-force-full-optin.bats hits there; tracked in #709), run_test_gate writes
  # no gate.json. Skip rather than false-fail: block-on-any is verified on macOS,
  # the environment the gate actually runs in.
  [ -f "$TEST_REPO/gate.json" ] || skip "gate fixture did not run in this environment (see #709)"
  [ "$status" -eq 1 ]

  # outcome=failed ⟺ exit_code=1
  run jq -r '.exit_code' "$TEST_REPO/gate.json"
  [ "$output" = "1" ]

  # The failure is reported in tests[] (NOT suppressed as 'pre-existing').
  run jq -r '.tests | length' "$TEST_REPO/gate.json"
  [ "$output" -ge 1 ]
}

# ─── Merge-boundary: [GATE] findings block at retry cap (issue #718) ─────────
#
# These static tests pin the assess-and-resolve.sh retry-cap behavior added in
# #718: a [GATE]-tagged ACTIONABLE_NOW item that survives all 3 fix iterations
# must block the merge (same path as CRITICAL), not defer+merge via tech-debt.
#
# Static approach (grep-based) matches the pattern in
# assess-and-resolve-shippable-defer.bats — no subprocess harness needed because
# the contract is structural: specific variable assignments in specific branches.

@test "merge-boundary: GATE_NOW_COUNT_REMAINING computed at retry cap" {
  # The fix (issue #718) introduces GATE_NOW_COUNT_REMAINING inside the
  # RETRY_COUNT >= 3 branch to count [GATE] ACTIONABLE_NOW headers still
  # present in ASSESSMENT_RESULT.  If this variable disappears the merge
  # boundary check is silently removed.
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  run grep -n "GATE_NOW_COUNT_REMAINING" "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: GATE_NOW_COUNT_REMAINING not found in assess-and-resolve.sh"
    echo "      The [GATE]-at-retry-cap block check (#718) may have been removed."
    false
  }
}

@test "merge-boundary: [GATE] header pattern is anchored at line start" {
  # The grep that counts remaining [GATE] items must be anchored (^### \[GATE\])
  # so it matches only structured headers, not [GATE] in body text.  An
  # unanchored pattern would false-positive on reasoning text that *mentions*
  # [GATE] (the "structured header matching" shell convention in CLAUDE.md).
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"
  run grep -n 'grep -c.*\^\#\#\# \\[GATE\\]' "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: anchored [GATE] header grep not found in assess-and-resolve.sh"
    echo "      Pattern must be: grep -c \"^\### \[GATE\].*- ACTIONABLE_NOW\""
    echo "      (anchored at ^ to avoid matching [GATE] in reasoning/body text)"
    false
  }
}

@test "merge-boundary: [GATE] at retry cap sets CREATE_CRITICAL_FOLLOWUP (not CREATE_SECURITY_DEBT)" {
  # When GATE_NOW_COUNT_REMAINING > 0 at the retry cap the code must set
  # CREATE_CRITICAL_FOLLOWUP=true (blocking path).  If it sets
  # CREATE_SECURITY_DEBT=true instead, the [GATE] finding is filed as tech-debt
  # and the PR merges red — the live regression in PR #712 / issue #649.
  #
  # We verify the structural ordering: CREATE_CRITICAL_FOLLOWUP= must appear
  # BEFORE CREATE_SECURITY_DEBT= in the file (gate-block branch precedes the
  # defer branch), and both must be present (non-gate HIGH still defers).
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  local _critical_line _debt_line
  _critical_line=$(grep -n "CREATE_CRITICAL_FOLLOWUP=true" "$_script" | head -1 | cut -d: -f1 || true)
  _debt_line=$(grep -n "CREATE_SECURITY_DEBT=true" "$_script" | head -1 | cut -d: -f1 || true)

  [ -n "$_critical_line" ] || {
    echo "FAIL: CREATE_CRITICAL_FOLLOWUP=true not found in assess-and-resolve.sh"
    false
  }
  [ -n "$_debt_line" ] || {
    echo "FAIL: CREATE_SECURITY_DEBT=true not found in assess-and-resolve.sh"
    echo "      Non-gate HIGH findings should still follow the defer+tech-debt path"
    false
  }
  [ "$_critical_line" -lt "$_debt_line" ] || {
    echo "FAIL: CREATE_CRITICAL_FOLLOWUP=true (line $_critical_line) does not appear"
    echo "      before CREATE_SECURITY_DEBT=true (line $_debt_line)"
    echo "      [GATE] block must precede the defer path in the source."
    false
  }
}

@test "merge-boundary: non-gate HIGH still reaches CREATE_SECURITY_DEBT path (no regression)" {
  # The defer+tech-debt path for non-gate HIGH review findings must survive the
  # #718 change.  Verify CREATE_SECURITY_DEBT=true still exists and is reachable
  # via the else arm of the GATE_NOW_COUNT_REMAINING guard.
  local _script="${BATS_TEST_DIRNAME}/../../lib/core/assess-and-resolve.sh"

  # Both the GATE_NOW_COUNT_REMAINING guard and CREATE_SECURITY_DEBT must coexist.
  run grep -c "CREATE_SECURITY_DEBT=true" "$_script"
  [ "$status" -eq 0 ] || true   # grep -c exits 1 on zero matches
  local _count="$output"
  [ "${_count:-0}" -ge 1 ] || {
    echo "FAIL: CREATE_SECURITY_DEBT=true not found — non-gate HIGH defer path removed"
    false
  }

  # DROP_RETRY_MEDIUM_LOW must also still be set in that path (filters MEDIUM/LOW
  # from tech-debt issue at retry limit — regression guard for defect #5).
  run grep -n "DROP_RETRY_MEDIUM_LOW=true" "$_script"
  [ "$status" -eq 0 ] || {
    echo "FAIL: DROP_RETRY_MEDIUM_LOW=true not found — MEDIUM/LOW filter at retry cap removed"
    false
  }
}
