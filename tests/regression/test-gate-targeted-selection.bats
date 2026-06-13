#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression test: test_gate targeted selection by changed paths (issue #462)
#
# Verifies:
#   1. Bats files declare coverage via `# sharkrite-test-covers: <paths>` header
#   2. Headerless bats files are skipped (post-#480 default) unless directly changed
#   3. Selection is ALWAYS targeted — no path-based full-suite triggers exist
#      (trigger list removed 2026-06-12; pinning tests below keep it removed)
#   4. Glob patterns in covers headers work (e.g., lib/utils/*.sh)
#   5. Empty diff falls back to full suite (the ONE remaining FORCE_FULL path,
#      depended on by post-merge-verify.sh's main-broken check)
#   6. _parse_test_coverage_header returns clean path lists

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Source test-gate.sh to get the helpers
  # shellcheck source=/dev/null
  source "${RITE_REPO_ROOT}/lib/utils/test-gate.sh"

  # Create a fixture repo with controlled bats files
  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  mkdir -p "$TEST_REPO/tests/regression"

  # Fixture A: bats file WITH header covering lib/core/foo.sh
  cat > "$TEST_REPO/tests/regression/covers-foo.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh
@test "fixture A" { true; }
EOF

  # Fixture B: bats file WITH header covering lib/utils/*.sh (glob)
  cat > "$TEST_REPO/tests/regression/covers-utils-glob.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/*.sh
@test "fixture B" { true; }
EOF

  # Fixture C: bats file WITHOUT header (should always run)
  cat > "$TEST_REPO/tests/regression/headerless.bats" <<'EOF'
#!/usr/bin/env bats
@test "fixture C" { true; }
EOF

  # Fixture D: bats file WITH header covering an unrelated file
  cat > "$TEST_REPO/tests/regression/covers-unrelated.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/some/other.sh
@test "fixture D" { true; }
EOF
}

teardown() {
  rm -rf "$TEST_REPO"
}

@test "_parse_test_coverage_header: extracts comma-separated paths" {
  result=$(_parse_test_coverage_header "$TEST_REPO/tests/regression/covers-foo.bats")
  [ "$result" = "lib/core/foo.sh" ]
}

@test "_parse_test_coverage_header: handles glob patterns" {
  result=$(_parse_test_coverage_header "$TEST_REPO/tests/regression/covers-utils-glob.bats")
  [ "$result" = "lib/utils/*.sh" ]
}

@test "_parse_test_coverage_header: returns empty for headerless files" {
  result=$(_parse_test_coverage_header "$TEST_REPO/tests/regression/headerless.bats")
  [ -z "$result" ]
}

@test "_bats_file_matches_changed: header match returns 0" {
  run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/covers-foo.bats" \
    "lib/core/foo.sh"
  [ "$status" -eq 0 ]
}

@test "_bats_file_matches_changed: header mismatch returns 1" {
  run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/covers-foo.bats" \
    "lib/other/bar.sh"
  [ "$status" -eq 1 ]
}

@test "_bats_file_matches_changed: glob header matches" {
  run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/covers-utils-glob.bats" \
    "lib/utils/foo.sh"
  [ "$status" -eq 0 ]
}

@test "_bats_file_matches_changed: glob header does not match outside scope" {
  run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/covers-utils-glob.bats" \
    "lib/core/foo.sh"
  [ "$status" -eq 1 ]
}

@test "_bats_file_matches_changed: headerless file is now SKIPPED (post-#480 default)" {
  # After #480 backfilled all bats files with covers headers, the gate treats
  # missing headers as missing coverage signal and skips them. New bats files
  # must declare coverage (enforced by MISSING_TEST_COVERAGE_HEADER lint rule).
  run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/headerless.bats" \
    "any/random/file.sh"
  [ "$status" -eq 1 ]
}

@test "_select_tests_by_changed_paths: targeted selection includes matching, excludes headerless" {
  result=$(_select_tests_by_changed_paths "lib/core/foo.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-foo.bats"
  ! echo "$result" | grep -q "headerless.bats"
  ! echo "$result" | grep -q "covers-utils-glob.bats"
  ! echo "$result" | grep -q "covers-unrelated.bats"
}

@test "_select_tests_by_changed_paths: glob header file is included when matching" {
  result=$(_select_tests_by_changed_paths "lib/utils/foo.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-utils-glob.bats"
  ! echo "$result" | grep -q "headerless.bats"
  ! echo "$result" | grep -q "covers-foo.bats"
}

# ---------------------------------------------------------------------------
# Pinning: NO path-based full-suite triggers (removed 2026-06-12).
# A full run costs hours per fix-loop iteration and drowned real findings in
# load-induced flake (live: issue #484 died mid-loop to a 165-file gate run).
# These tests keep the escalation removed — a future PR re-adding a trigger
# list must consciously delete them. The accepted coverage trade-off is
# documented in behavioral-design.md → "Test Selection by Changed Paths";
# issue #482 tracks the compensating periodic full-suite safety net.
# ---------------------------------------------------------------------------

@test "pinning: changed test-gate.sh stays targeted — never FORCE_FULL" {
  result=$(_select_tests_by_changed_paths "lib/utils/test-gate.sh" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ] || {
    echo "full-suite escalation re-appeared for test-gate.sh change" >&2
    return 1
  }
}

@test "pinning: changed Makefile yields empty selection, not FORCE_FULL" {
  result=$(_select_tests_by_changed_paths "Makefile" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ] || {
    echo "full-suite escalation re-appeared for Makefile change" >&2
    return 1
  }
  # No fixture covers Makefile → empty selection (caller skips bats)
  [ -z "$result" ] || {
    echo "expected empty selection for Makefile; got: $result" >&2
    return 1
  }
}

@test "pinning: changed tests/helpers file stays targeted — never FORCE_FULL" {
  result=$(_select_tests_by_changed_paths "tests/helpers/foo.bash" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ]
}

@test "pinning: changed tests/fixtures file stays targeted — never FORCE_FULL" {
  result=$(_select_tests_by_changed_paths "tests/fixtures/foo.json" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ]
}

@test "pinning: changed lint tool stays targeted — never FORCE_FULL" {
  result=$(_select_tests_by_changed_paths "tools/sharkrite-lint.sh" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: empty diff returns FORCE_FULL" {
  # The ONE intentional full-suite path: no diff computable. Depended on by
  # post-merge-verify.sh's main-broken check (DIFF_BASE=HEAD → empty diff).
  result=$(_select_tests_by_changed_paths "" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "pinning: mixed diff with Makefile stays targeted on the covered file" {
  changed=$(printf 'lib/core/foo.sh\nMakefile\n')
  result=$(_select_tests_by_changed_paths "$changed" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ] || {
    echo "Makefile in a mixed diff re-escalated to full suite" >&2
    return 1
  }
  echo "$result" | grep -q "covers-foo.bats" || {
    echo "expected covers-foo.bats in targeted selection; got: $result" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: only unrelated change excludes covers-foo" {
  result=$(_select_tests_by_changed_paths "lib/some/other.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-unrelated.bats"
  ! echo "$result" | grep -q "headerless.bats"
  ! echo "$result" | grep -q "covers-foo.bats"
  ! echo "$result" | grep -q "covers-utils-glob.bats"
}

# ---------------------------------------------------------------------------
# Regression: changed .bats file is included in its own diff (issue surfaced
# 2026-06-09 — the sharkrite-test-covers headers list SOURCE paths, never test
# paths, so a changed .bats path matched no header anywhere and the selection
# emerged empty. At the time, empty escalated to the full ~1500-test suite;
# today empty means "skip bats", which would silently skip the very file the
# commit edited. Either way the shortcut below is what makes a changed test
# run itself.
# ---------------------------------------------------------------------------

@test "_select_tests_by_changed_paths: changed .bats file is included verbatim" {
  # Direct edit to a test file → that test file must appear in the output.
  result=$(_select_tests_by_changed_paths "tests/regression/covers-foo.bats" "$TEST_REPO")
  echo "$result" | grep -q "covers-foo.bats" || {
    echo "expected covers-foo.bats in selection; got:" >&2
    echo "$result" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: changed headerless .bats file is included" {
  # Headerless files are normally skipped (post-#480 default), but a DIRECT
  # change to a headerless test must still cause it to run — otherwise the
  # user gets zero feedback on the file they just edited.
  result=$(_select_tests_by_changed_paths "tests/regression/headerless.bats" "$TEST_REPO")
  echo "$result" | grep -q "headerless.bats" || {
    echo "expected headerless.bats in selection (direct change overrides skip); got:" >&2
    echo "$result" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: changed .bats does NOT force full suite" {
  # Pre-fix behavior: result was empty, caller escalated. Post-fix: result
  # contains the changed .bats path, NOT the FORCE_FULL marker and NOT empty
  # (empty now means the caller skips bats — the changed test must run).
  result=$(_select_tests_by_changed_paths "tests/regression/covers-foo.bats" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ] || {
    echo "regression: changed .bats fell back to FORCE_FULL" >&2
    return 1
  }
  [ -n "$result" ] || {
    echo "regression: changed .bats produced empty selection (its own tests would be skipped)" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: mixed source + .bats change includes both" {
  # Realistic case: a fix touches both a source file and its test.
  changed=$(printf 'lib/core/foo.sh\ntests/regression/covers-unrelated.bats\n')
  result=$(_select_tests_by_changed_paths "$changed" "$TEST_REPO")
  echo "$result" | grep -q "covers-foo.bats" || { echo "$result" >&2; return 1; }
  echo "$result" | grep -q "covers-unrelated.bats" || { echo "$result" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Note: the RITE_TEST_GATE_SKIP_TRIGGERS bats-bypass tests that lived here
# were removed with the bats trigger list (2026-06-12) — with no bats
# triggers, the var has nothing to bypass on this path. The var still
# suppresses the LINT full-scan triggers; those tests live in
# tests/regression/lint-targeted-selection.bats.
# ---------------------------------------------------------------------------

@test "pinning: rebase-shaped diff (gate + covered source) stays targeted without any env var" {
  # Post-merge scenario that used to NEED the SKIP_TRIGGERS bypass: a rebase
  # pulls in lib/utils/test-gate.sh alongside lib/core/foo.sh. With triggers
  # gone, selection is targeted by default — no escape hatch required.
  changed=$(printf 'lib/utils/test-gate.sh\nlib/core/foo.sh\n')
  result=$(_select_tests_by_changed_paths "$changed" "$TEST_REPO")
  [ "$result" != "FORCE_FULL" ] || {
    echo "expected targeted, got FORCE_FULL" >&2
    return 1
  }
  echo "$result" | grep -q "covers-foo.bats" || {
    echo "expected covers-foo.bats; got: $result" >&2
    return 1
  }
}
