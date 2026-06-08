#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
#
# Regression test for the MISSING_TEST_COVERAGE_HEADER lint rule.
# After PR #480 backfilled covers headers on all 142 bats files and
# the gate's default flipped (headerless = skipped), this rule enforces
# that every new bats file declares coverage so future tests participate
# in targeted selection.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  TEST_REPO=$(mktemp -d)
  export TEST_REPO
  # Mirror the project structure the lint script expects
  mkdir -p "$TEST_REPO/tests/regression" "$TEST_REPO/tests/helpers" "$TEST_REPO/tests/fixtures"
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tools"
  # Minimal lib files so the lint script's other rules don't crash
  echo '#!/bin/bash' > "$TEST_REPO/lib/utils/foo.sh"
  echo '#!/bin/bash' > "$TEST_REPO/tools/example-lint.sh"
}

teardown() {
  rm -rf "$TEST_REPO"
}

@test "MISSING_TEST_COVERAGE_HEADER: flags a bats file without the header" {
  cat > "$TEST_REPO/tests/regression/no-header.bats" <<'EOF'
#!/usr/bin/env bats
@test "fixture" { true; }
EOF
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER"
  echo "$output" | grep -q "no-header.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: passes when header is present" {
  cat > "$TEST_REPO/tests/regression/with-header.bats" <<'EOF'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/foo.sh
@test "fixture" { true; }
EOF
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*with-header.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: skips tests/helpers/ (support files)" {
  cat > "$TEST_REPO/tests/helpers/helper.bats" <<'EOF'
#!/usr/bin/env bats
@test "helper" { true; }
EOF
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*tests/helpers/helper.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: skips tests/fixtures/ (support files)" {
  cat > "$TEST_REPO/tests/fixtures/fixture.bats" <<'EOF'
#!/usr/bin/env bats
@test "fixture" { true; }
EOF
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*tests/fixtures/fixture.bats"
}

@test "MISSING_TEST_COVERAGE_HEADER: accepts header in first 5 lines" {
  cat > "$TEST_REPO/tests/regression/header-line-4.bats" <<'EOF'
#!/usr/bin/env bats
# Some leading comment
#
# sharkrite-test-covers: lib/utils/foo.sh
@test "fixture" { true; }
EOF
  cd "$TEST_REPO"
  run bash "$LINT_SCRIPT"
  ! echo "$output" | grep -q "MISSING_TEST_COVERAGE_HEADER.*header-line-4.bats"
}

