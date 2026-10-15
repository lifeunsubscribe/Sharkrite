#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh::_changed_functions_in_file|_bats_file_matches_changed|_parse_test_coverage_header
#
# Function-scoped test selection (#1229).
#
# Coverage headers may narrow a path to specific top-level functions:
#     # sharkrite-test-covers: lib/utils/test-gate.sh::_compute_bats_jobs
# A test is then selected only when the diff touches one of those functions.
#
# Why: test-gate.sh is ~2900 lines with 34 functions and 29 bats files declare
# it, so editing one 20-line function selected all 29 — wasting time AND
# creating the parallel load that made the gate-invoking tests flake.
#
# Invariant under test: precision is an OPTIMIZATION, never a filter that can
# hide a regression. Any unattributable change falls back to file-level match.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/markers.sh" 2>/dev/null || true
  # portable_sed_i: the fixture mutates files in place, and a bare `sed -i ''`
  # is BSD-only. portable-cmds.sh guards on `declare -f portable_sed_i`, a
  # function sentinel, so this source cannot clobber a caller's definition.
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/portable-cmds.sh"
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/test-gate.sh"
  set +u; set +o pipefail

  TEST_REPO="$BATS_TEST_TMPDIR/fnscope-repo"
  mkdir -p "$TEST_REPO/lib/utils" "$TEST_REPO/tests/regression"
}

teardown() { rm -rf "${TEST_REPO:-}"; }

# Build a git repo whose HEAD changes exactly one function of lib/utils/sut.sh.
_make_repo_changing() {
  local _which="$1"
  cat > "$TEST_REPO/lib/utils/sut.sh" <<'SUT'
#!/bin/bash
# header comment above alpha
alpha() {
  echo "alpha v1"
  if true; then echo "nested"; fi
}

# header comment above beta
beta() {
  echo "beta v1"
}

# orchestrator calls alpha — a change to alpha must implicate this too
gamma() {
  alpha
  echo "gamma v1"
}
TOP_LEVEL_CONST="v1"
SUT
  ( cd "$TEST_REPO" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm base \
      && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
  [ -d "$TEST_REPO/.git" ] || fail "fixture git init failed"
  # portable_sed_i, not a bare `sed -i ''`. The BSD form makes GNU sed read the
  # empty string as the script and the expression as a filename, so all 14 tests
  # in this file died on Linux CI with "sed: can't read s/…/: No such file or
  # directory" while passing on the macOS dev box.
  case "$_which" in
    alpha)   portable_sed_i 's/echo "alpha v1"/echo "alpha v2"/' "$TEST_REPO/lib/utils/sut.sh" ;;
    beta)    portable_sed_i 's/echo "beta v1"/echo "beta v2"/'   "$TEST_REPO/lib/utils/sut.sh" ;;
    comment) portable_sed_i 's/# header comment above beta/# header comment above beta (reworded)/' "$TEST_REPO/lib/utils/sut.sh" ;;
    toplevel) portable_sed_i 's/TOP_LEVEL_CONST="v1"/TOP_LEVEL_CONST="v2"/' "$TEST_REPO/lib/utils/sut.sh" ;;
  esac
  ( cd "$TEST_REPO" && git add -A && git commit -qm change ) >/dev/null 2>&1
}

_write_covering_test() {
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: %s\n@test "x" { true; }\n' "$1" \
    > "$TEST_REPO/tests/regression/cover.bats"
}

# ---------------------------------------------------------------------------
# Attribution
# ---------------------------------------------------------------------------

@test "changed line inside a function attributes to that function" {
  _make_repo_changing alpha
  run _changed_functions_in_file "lib/utils/sut.sh" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" != *"beta"* ]]
}

@test "comment block above a definition attributes to that function" {
  _make_repo_changing comment
  run _changed_functions_in_file "lib/utils/sut.sh" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"beta"* ]]
}

@test "top-level change is unattributable (empty → caller fails safe)" {
  _make_repo_changing toplevel
  run _changed_functions_in_file "lib/utils/sut.sh" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}

@test "non-shell file is unattributable" {
  _make_repo_changing alpha
  run _changed_functions_in_file "docs/readme.md" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

@test "scoped header SKIPS a test when a different function changed" {
  _make_repo_changing beta
  _write_covering_test "lib/utils/sut.sh::alpha"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 1 ]
}

@test "scoped header SELECTS a test when its function changed" {
  _make_repo_changing alpha
  _write_covering_test "lib/utils/sut.sh::alpha"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 0 ]
}

@test "scoped header selects on ANY listed function (| separator)" {
  _make_repo_changing beta
  _write_covering_test "lib/utils/sut.sh::alpha|beta"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 0 ]
}

@test "FAIL-SAFE: unattributable change selects a scoped test anyway" {
  _make_repo_changing toplevel
  _write_covering_test "lib/utils/sut.sh::alpha"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 0 ]
}

@test "BACKWARD COMPAT: bare path header is unaffected by scoping" {
  _make_repo_changing beta
  _write_covering_test "lib/utils/sut.sh"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 0 ]
}

@test "BACKWARD COMPAT: headerless file still skipped" {
  _make_repo_changing alpha
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$TEST_REPO/tests/regression/cover.bats"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 1 ]
}

@test "a non-matching path in a scoped header does not select" {
  _make_repo_changing alpha
  _write_covering_test "lib/core/other.sh::alpha"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Caller expansion (#1230) — scoping must follow the call graph, or a header
# naming an orchestrator silently loses coverage when a helper it calls changes.
# ---------------------------------------------------------------------------

@test "changing a callee implicates its caller" {
  _make_repo_changing alpha
  run _changed_functions_in_file "lib/utils/sut.sh" "$TEST_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"gamma"* ]]
  [[ "$output" != *"beta"* ]]
}

@test "test scoped to the CALLER is selected when the callee changes" {
  _make_repo_changing alpha
  _write_covering_test "lib/utils/sut.sh::gamma"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 0 ]
}

@test "expansion does not widen to unrelated functions" {
  _make_repo_changing beta
  _write_covering_test "lib/utils/sut.sh::gamma"
  RITE_PROJECT_ROOT="$TEST_REPO" run _bats_file_matches_changed \
    "$TEST_REPO/tests/regression/cover.bats" "lib/utils/sut.sh"
  [ "$status" -eq 1 ]
}
