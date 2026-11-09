#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-selection.sh, lib/utils/test-gate.sh, tools/sharkrite-lint.sh
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
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

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

  # Fixture C: bats file WITHOUT header (skipped unless directly changed, post-#480)
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

  # Fixture E: header covers lib/core/a.sh; body references lib/utils/b.sh via
  # a $RITE_LIB_DIR-style path (not in the header).  Used to verify body-reference
  # selection when lib/utils/b.sh changes (acceptance criterion 1 / issue #1657).
  cat > "$TEST_REPO/tests/regression/covers-aonly-with-b-body.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/a.sh
setup() {
  _B_SH="$RITE_LIB_DIR/utils/b.sh"
}
@test "fixture E" { true; }
EOF

  # Fixture F: same shape as #1635 regression — header declares assess-documentation.sh
  # but body references lib/providers/claude.sh via a variable assignment.
  cat > "$TEST_REPO/tests/regression/covers-assess-doc-body-claude.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/utils/config.sh
setup() {
  CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh"
}
@test "fixture F" { true; }
EOF

  # Fixture G: header covers lib/core/a.sh; body mentions lib/utils/b.sh only
  # in a comment.  Fixed-string match is intentionally comment-inclusive.
  cat > "$TEST_REPO/tests/regression/covers-aonly-comment-b.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/a.sh
# This test exercises lib/utils/b.sh indirectly via fixture E above.
@test "fixture G" { true; }
EOF

  # Fixture H: body references bin/rite-full-suite (not bin/rite standalone).
  # Pins Rule 1 whole-token boundary: bin/rite must NOT match bin/rite-full-suite.
  cat > "$TEST_REPO/tests/regression/body-rite-full-suite.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/a.sh
setup() { FULL_SUITE="$PROJECT_ROOT/bin/rite-full-suite"; }
@test "fixture H" { true; }
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

@test "selection INCLUDES tests/concurrency/* when its header matches" {
  # Concurrency files are selected by header like any other bats file.
  # The serial marker (sharkrite-gate-serial) routes them to the serial lane —
  # it is not an exclusion. Inverted from the pre-#1659 exclusion pin.
  mkdir -p "$TEST_REPO/tests/concurrency"
  cat > "$TEST_REPO/tests/concurrency/race.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh
# sharkrite-gate-serial
@test "race" { true; }
EOF
  run _select_tests_by_changed_paths "lib/core/foo.sh" "$TEST_REPO"
  [ "$status" -eq 0 ]
  # The regression test covering foo.sh IS selected...
  echo "$output" | grep -q 'tests/regression/covers-foo.bats' \
    || { echo "FAIL: covers-foo.bats not selected; got: $output"; return 1; }
  # ...and so is the concurrency test covering the same source.
  echo "$output" | grep -q 'tests/concurrency/race.bats' \
    || { echo "FAIL: concurrency test missing from selection; got: $output"; return 1; }
}

@test "selection EXCLUDES tests/concurrency/* when its header does NOT match" {
  # Targeting still applies — concurrency files are not blanket-included.
  mkdir -p "$TEST_REPO/tests/concurrency"
  cat > "$TEST_REPO/tests/concurrency/race.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh
# sharkrite-gate-serial
@test "race" { true; }
EOF
  # Change to a file that the concurrency fixture does NOT cover.
  run _select_tests_by_changed_paths "lib/utils/unrelated.sh" "$TEST_REPO"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'tests/concurrency/race.bats' \
    || { echo "FAIL: concurrency test selected without header match; got: $output"; return 1; }
}

@test "selected concurrency file is classified as serial by _bats_file_is_serial" {
  # A concurrency file in the selection carries sharkrite-gate-serial, so run_test_gate
  # places it in the serial group (not parallel). Verify via the helper it uses.
  mkdir -p "$TEST_REPO/tests/concurrency"
  cat > "$TEST_REPO/tests/concurrency/race.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh
# sharkrite-gate-serial
@test "race" { true; }
EOF
  run _bats_file_is_serial "$TEST_REPO/tests/concurrency/race.bats"
  [ "$status" -eq 0 ] \
    || { echo "FAIL: concurrency fixture not classified as serial; would fall into parallel group"; return 1; }
}

@test "every file under tests/concurrency/ carries sharkrite-gate-serial (marker sweep)" {
  # Safety net: a new concurrency file added without the serial marker would fall
  # into the parallel job group, triggering barrier-timeout flakes. This pin fails
  # the gate the moment such a file is merged.
  local _missing=""
  local _f
  for _f in "$RITE_REPO_ROOT"/tests/concurrency/*.bats; do
    [ -f "$_f" ] || continue
    _bats_file_is_serial "$_f" || _missing="$_missing $(basename "$_f")"
  done
  [ -z "$_missing" ] \
    || { echo "FAIL: missing sharkrite-gate-serial in:$_missing"; return 1; }
}

# ---------------------------------------------------------------------------
# Serial gate hint (sharkrite-gate-serial) — #724
# Tests verify _bats_file_is_serial detection and the selection contract:
# serial-hinted files are INCLUDED in selection but flagged for serial execution.
# The split itself (parallel_files / serial_files arrays) lives in run_test_gate,
# not in _select_tests_by_changed_paths — these tests validate the helper that
# run_test_gate uses to perform the split.
# ---------------------------------------------------------------------------

@test "_bats_file_is_serial: returns 0 for file with sharkrite-gate-serial hint" {
  local serial_bats="$TEST_REPO/tests/regression/serial-hinted.bats"
  cat > "$serial_bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh
# sharkrite-gate-serial
@test "load sensitive" { true; }
EOF
  run _bats_file_is_serial "$serial_bats"
  [ "$status" -eq 0 ]
}

@test "_bats_file_is_serial: returns 1 for file without hint" {
  run _bats_file_is_serial "$TEST_REPO/tests/regression/covers-foo.bats"
  [ "$status" -eq 1 ]
}

@test "_bats_file_is_serial: returns 1 for headerless file" {
  run _bats_file_is_serial "$TEST_REPO/tests/regression/headerless.bats"
  [ "$status" -eq 1 ]
}

@test "_bats_file_is_serial: returns 1 for nonexistent file" {
  run _bats_file_is_serial "$TEST_REPO/tests/regression/does-not-exist.bats"
  [ "$status" -eq 1 ]
}

@test "_bats_file_is_serial: hint must be in first 15 lines (not beyond)" {
  # A hint on line 17 is NOT detected — hint must be near the top.
  local late_hint="$TEST_REPO/tests/regression/late-hint.bats"
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/core/foo.sh'
    for i in 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      echo "# line $i"
    done
    echo '# sharkrite-gate-serial'
    echo '@test "dummy" { true; }'
  } > "$late_hint"
  run _bats_file_is_serial "$late_hint"
  # Line 17 is beyond the 15-line window — hint is not detected
  [ "$status" -eq 1 ]
}

@test "selection INCLUDES serial-hinted files (hint is not an exclusion)" {
  # sharkrite-gate-serial is a scheduling hint, not an exclusion filter.
  # The file must still appear in _select_tests_by_changed_paths output.
  cat > "$TEST_REPO/tests/regression/serial-hinted.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/foo.sh
# sharkrite-gate-serial
@test "load sensitive" { true; }
EOF
  result=$(_select_tests_by_changed_paths "lib/core/foo.sh" "$TEST_REPO")
  echo "$result" | grep -q "serial-hinted.bats" || {
    echo "FAIL: serial-hinted.bats missing from selection; got: $result" >&2
    return 1
  }
}

@test "lib-resource-safety.bats carries the sharkrite-gate-serial hint" {
  # Pinning test: this file is the canonical example of a serial-hinted test
  # (sources every lib file twice; flaky under --jobs). Any PR that removes
  # the hint must consciously delete this assertion.
  local _lib_resource_safety="${RITE_REPO_ROOT}/tests/regression/lib-resource-safety.bats"
  run _bats_file_is_serial "$_lib_resource_safety"
  [ "$status" -eq 0 ] || {
    echo "FAIL: lib-resource-safety.bats lost its sharkrite-gate-serial hint" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Lint bats scope (issue #921 / PR #966):
# Changed .bats files must be passed to _select_lint_by_changed_paths so
# Rules 34 (BATS_PRE_SOURCE_STUB_OVERWRITE) and 35 (BATS_FILE_SCOPE_ENV_READ)
# run against the changed bats file during the post-commit gate.
# Previously _select_lint_by_changed_paths only emitted bin/lib/tools paths.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Body-reference selection (issue #1657)
# A bats file is also selected when its TEXT contains the literal path of a
# changed shell-source file — even if the sharkrite-test-covers header does
# not declare that path.  This catches tests that source, grep, or reference
# a changed file without declaring it in the header (the #1635 live miss).
# ---------------------------------------------------------------------------

@test "_select_tests_by_changed_paths: body reference selects file not covered by header (criterion 1)" {
  # Fixture E: header = lib/core/a.sh; body references lib/utils/b.sh
  # Changed path: lib/utils/b.sh (NOT in the header)
  # Expected: covers-aonly-with-b-body.bats is selected via body reference
  result=$(_select_tests_by_changed_paths "lib/utils/b.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-aonly-with-b-body.bats" || {
    echo "FAIL: body-reference file not selected; got: $result" >&2
    return 1
  }
  # The fixture for lib/core/a.sh (covers-foo.bats with header lib/core/foo.sh) is not
  # selected — sanity-check that the body-ref rule does not over-select.
  ! echo "$result" | grep -q "covers-unrelated.bats" || {
    echo "FAIL: covers-unrelated.bats should not be selected for lib/utils/b.sh" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: body reference in comment also selects file (fixed-string is intentional)" {
  # Fixture G: header = lib/core/a.sh; lib/utils/b.sh appears only in a comment.
  # Fixed-string match is intentionally comment-inclusive: a comment documenting
  # a dependency IS a dependency signal.  Pin this so nobody "optimizes" it away.
  result=$(_select_tests_by_changed_paths "lib/utils/b.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-aonly-comment-b.bats" || {
    echo "FAIL: comment-only body reference not selected; got: $result" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: #1635 shape — header assess-doc + body providers/claude selected on claude change" {
  # Fixture F mirrors the live miss: header declares assess-documentation.sh and
  # config.sh; body has CLAUDE_SH="$PROJECT_ROOT/lib/providers/claude.sh".
  # When lib/providers/claude.sh changes, the fixture must be selected via body
  # reference even though lib/providers/claude.sh is absent from the header.
  result=$(_select_tests_by_changed_paths "lib/providers/claude.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-assess-doc-body-claude.bats" || {
    echo "FAIL(#1635): body-reference file for providers/claude.sh not selected; got: $result" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: body reference does not select for non-shell-source changed paths" {
  # Body-reference rule applies only to shell sources (lib/**/*.sh, bin/*, tools/**/*.sh).
  # A changed Makefile or JSON file must NOT trigger body-reference scanning.
  result=$(_select_tests_by_changed_paths "Makefile" "$TEST_REPO")
  # Fixture E body has $RITE_LIB_DIR/utils/b.sh — not a Makefile reference.
  # Selection for Makefile should be empty (no header or body covers Makefile).
  [ -z "$result" ] || [ "$result" = "FORCE_FULL" ] || {
    # Only allow selection if a fixture happened to contain "Makefile" — none do.
    if echo "$result" | grep -q "covers-aonly-with-b-body.bats\|covers-assess-doc-body-claude.bats"; then
      echo "FAIL: body-reference rule fired for Makefile (non-shell-source); got: $result" >&2
      return 1
    fi
  }
  true  # empty selection for Makefile is the expected outcome
}

@test "_select_tests_by_changed_paths: body-reference selections carry by_ref: prefix for diag counting" {
  # The caller (run_test_gate in test-gate.sh) counts lines with "by_ref:" to populate
  # the by_ref=N field in the TEST_GATE_SELECTION diag.  Verify the prefix is present
  # so the counter works correctly.  The caller strips the prefix before passing paths
  # to bats — that is a test-gate.sh concern, not gate-selection.sh.
  result=$(_select_tests_by_changed_paths "lib/utils/b.sh" "$TEST_REPO")
  # At least one of the body-reference fixtures (E or G) must carry the prefix.
  echo "$result" | grep -q '^by_ref:' || {
    echo "FAIL: no by_ref: prefix in selection output; diag counting will report 0; got: $result" >&2
    return 1
  }
}

@test "_select_tests_by_changed_paths: header-only match does not carry by_ref: prefix" {
  # Regression guard for the by_ref overcounting bug: before the fix, the body
  # grep ran BEFORE the header check, so every file whose header declares a
  # changed path (the header line contains the path string) was emitted as
  # "by_ref:" even though a header match selected it.
  #
  # Fixture A: header = lib/core/foo.sh; body has no other lib/core/foo.sh reference.
  # When lib/core/foo.sh changes the file must be selected via header (bare filename),
  # NOT body reference (by_ref: prefix) — header takes priority.
  result=$(_select_tests_by_changed_paths "lib/core/foo.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-foo.bats" || {
    echo "FAIL: covers-foo.bats not selected at all; got: $result" >&2
    return 1
  }
  if echo "$result" | grep "covers-foo.bats" | grep -q '^by_ref:'; then
    echo "FAIL: covers-foo.bats has by_ref: prefix but it was selected via header — by_ref diag will be overcounted; got: $result" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Whole-token boundary for body-reference Rule 1 (issue #1651)
# bin/rite appeared as a prefix of bin/rite-full-suite, producing 6 measured
# false-positive selections.  The trailing anchor ([^-_./a-zA-Z0-9]|$) in
# the Rule 1 grep prevents bin/rite from matching bin/rite-full-suite.
# ---------------------------------------------------------------------------

@test "_bats_file_has_body_reference: bin/rite does NOT match bin/rite-full-suite (whole-token boundary)" {
  # Fixture H body has bin/rite-full-suite — bin/rite must not match it.
  # Pre-fix: grep -qF matched the substring. Post-fix: trailing anchor rejects it.
  run _bats_file_has_body_reference \
    "$TEST_REPO/tests/regression/body-rite-full-suite.bats" \
    "bin/rite"
  [ "$status" -eq 1 ] || {
    echo "FAIL: bin/rite matched bin/rite-full-suite body (substring boundary broken)" >&2
    return 1
  }
}

@test "_bats_file_has_body_reference: exact bin/rite match works (no false negative at token boundary)" {
  # Positive case: a file containing bin/rite as a whole token (quote-terminated)
  # must still be selected — the whole-token anchor must not introduce false negatives.
  local _bats_exact="$TEST_REPO/tests/regression/body-rite-exact.bats"
  {
    echo '#!/usr/bin/env bats'
    echo '# sharkrite-test-covers: lib/core/a.sh'
    echo 'setup() { R="/some/path/bin/rite"; }'
    echo '@test "x" { true; }'
  } > "$_bats_exact"
  run _bats_file_has_body_reference "$_bats_exact" "bin/rite"
  [ "$status" -eq 0 ] || {
    echo "FAIL: bin/rite not matched in a file that contains it as a whole token" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: changed .bats in tests/ is included in lint scope" {
  # Verifies the fix from issue #921: tests/*.bats and tests/*/*.bats are now
  # eligible paths for lint (so Rules 34/35 can run against them).
  # Use a bats file that genuinely exists so the [ -f ] guard passes.
  result=$(_select_lint_by_changed_paths "tests/regression/test-gate-targeted-selection.bats" "$RITE_REPO_ROOT")
  [ -n "$result" ] || {
    echo "REGRESSION(#921): changed bats file produced empty lint scope — Rules 34/35 would be skipped" >&2
    return 1
  }
  [ "$result" != "FORCE_FULL" ] || {
    echo "FAIL: changed bats file escalated to FORCE_FULL lint scan (unexpected)" >&2
    return 1
  }
  echo "$result" | grep -q "test-gate-targeted-selection.bats" || {
    echo "expected test-gate-targeted-selection.bats in lint scope; got: '$result'" >&2
    return 1
  }
}
