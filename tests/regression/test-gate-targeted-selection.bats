#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression test: test_gate targeted selection by changed paths (issue #462)
#
# Verifies:
#   1. Bats files declare coverage via `# sharkrite-test-covers: <paths>` header
#   2. Headerless bats files always run (conservative fallback)
#   3. Full-suite triggers (test-gate.sh, *-lint.sh, Makefile, tests/helpers/*, tests/fixtures/*)
#      override path-based selection and force the full suite
#   4. Glob patterns in covers headers work (e.g., lib/utils/*.sh)
#   5. Empty diff falls back to full suite (degenerate but safe)
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

@test "_bats_file_matches_changed: headerless file always matches (conservative)" {
  run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/headerless.bats" \
    "any/random/file.sh"
  [ "$status" -eq 0 ]
}

@test "_select_tests_by_changed_paths: targeted selection includes matching + headerless" {
  result=$(_select_tests_by_changed_paths "lib/core/foo.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-foo.bats"
  echo "$result" | grep -q "headerless.bats"
  ! echo "$result" | grep -q "covers-utils-glob.bats"
  ! echo "$result" | grep -q "covers-unrelated.bats"
}

@test "_select_tests_by_changed_paths: glob header file is included when matching" {
  result=$(_select_tests_by_changed_paths "lib/utils/foo.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-utils-glob.bats"
  echo "$result" | grep -q "headerless.bats"
  ! echo "$result" | grep -q "covers-foo.bats"
}

@test "_select_tests_by_changed_paths: full-suite trigger Makefile" {
  result=$(_select_tests_by_changed_paths "Makefile" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: full-suite trigger test-gate.sh" {
  result=$(_select_tests_by_changed_paths "lib/utils/test-gate.sh" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: full-suite trigger tests/helpers/*" {
  result=$(_select_tests_by_changed_paths "tests/helpers/foo.bash" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: full-suite trigger tests/fixtures/*" {
  result=$(_select_tests_by_changed_paths "tests/fixtures/foo.json" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: full-suite trigger *-lint.sh glob" {
  # The trigger pattern is tools/*-lint.sh (avoids literal sharkrite- marker)
  result=$(_select_tests_by_changed_paths "tools/sharkrite-lint.sh" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: empty diff returns FORCE_FULL" {
  result=$(_select_tests_by_changed_paths "" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: multiple changed files, one triggers full" {
  changed=$(printf 'lib/core/foo.sh\nMakefile\n')
  result=$(_select_tests_by_changed_paths "$changed" "$TEST_REPO")
  [ "$result" = "FORCE_FULL" ]
}

@test "_select_tests_by_changed_paths: only unrelated change excludes covers-foo" {
  result=$(_select_tests_by_changed_paths "lib/some/other.sh" "$TEST_REPO")
  echo "$result" | grep -q "covers-unrelated.bats"
  echo "$result" | grep -q "headerless.bats"
  ! echo "$result" | grep -q "covers-foo.bats"
  ! echo "$result" | grep -q "covers-utils-glob.bats"
}
