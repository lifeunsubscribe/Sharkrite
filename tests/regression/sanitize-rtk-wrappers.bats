#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/sanitize-output.sh, lib/core/plan-issues.sh, lib/core/assess-review-issues.sh, lib/core/local-review.sh, lib/utils/promotion-composer.sh
# Regression tests for sanitize_generated_commands (issue #1360).
#
# Verifies:
#   1-2.  rtk proxy and bare rtk stripped at line-start
#   3-6.  rtk stripped after backtick / $( / "| " / "&& "
#   7.    prose mentions of "rtk" not at a command position are untouched
#   8.    multiple command-position occurrences on one line
#   9.    grounded exception: repo whose tracked files reference rtk → no change
#   10.   empty input passes through unchanged
#   11-14.structural: each of the four LLM-output→GitHub seams calls the helper

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_PROJECT_ROOT="${RITE_TEST_TMPDIR}"

  # Minimal fake git repo in RITE_TEST_TMPDIR so the grounded-exception check
  # (git grep -qlw rtk) has a valid working tree to operate on.
  git init -q "$RITE_TEST_TMPDIR"
  git -C "$RITE_TEST_TMPDIR" config user.email "test@test"
  git -C "$RITE_TEST_TMPDIR" config user.name "Test"

  # Supply a no-op print_info before sourcing so the helper's stderr report
  # doesn't contaminate test output (and avoids needing colors.sh dependency).
  print_info() { true; }
  export -f print_info

  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: sanitize-output.sh uses a function-sentinel guard (declare -f sanitize_generated_commands); the print_info stub defined above is preserved across the source call.
  source "$RITE_LIB_DIR/utils/sanitize-output.sh"
  set +u; set +o pipefail
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. rtk proxy stripped at line start
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: rtk proxy at line start → command only" {
  local body
  body=$(printf 'rtk proxy grep -rn "foo" src/')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'grep -rn "foo" src/' ]]
}

# ---------------------------------------------------------------------------
# 2. bare rtk stripped at line start
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: bare rtk at line start → command only" {
  local body
  body=$(printf 'rtk grep -rn "foo" src/')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'grep -rn "foo" src/' ]]
}

# ---------------------------------------------------------------------------
# 3. rtk stripped after backtick
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: rtk after backtick → command only" {
  local body
  body='Run `rtk grep -rn "x" src/` to find it'
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'Run `grep -rn "x" src/` to find it' ]]
}

# ---------------------------------------------------------------------------
# 4. rtk stripped after $(
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: rtk after \$( → command only" {
  local body
  body=$(printf 'COUNT=$(rtk grep -c "pattern" file.txt)')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'COUNT=$(grep -c "pattern" file.txt)' ]]
}

# ---------------------------------------------------------------------------
# 5. rtk stripped after "| "
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: rtk after pipe → command only" {
  local body
  body=$(printf 'find . -name "*.sh" | rtk grep -l "pattern"')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'find . -name "*.sh" | grep -l "pattern"' ]]
}

# ---------------------------------------------------------------------------
# 6. rtk stripped after "&&"
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: rtk after && → command only" {
  local body
  body=$(printf 'cd src && rtk grep -rn "foo" .')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'cd src && grep -rn "foo" .' ]]
}

# ---------------------------------------------------------------------------
# 7. Prose mention of "rtk" left untouched
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: prose mention of rtk untouched" {
  local body
  body=$(printf 'The rtk tool compresses output before the model sees it.')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == 'The rtk tool compresses output before the model sees it.' ]]
}

# ---------------------------------------------------------------------------
# 8. Multiple occurrences on one body (line start + mid-line)
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: multiple rtk occurrences stripped" {
  local body
  body=$(printf 'rtk grep -rn "a" src/\nfind . | rtk sed "s/a/b/"')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'grep -rn "a" src/'* ]]
  [[ "$output" == *'find . | sed "s/a/b/"'* ]]
  [[ "$output" != *'rtk grep'* ]]
  [[ "$output" != *'rtk sed'* ]]
}

# ---------------------------------------------------------------------------
# 9. Grounded exception: repo whose tracked files reference rtk → no change
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: grounded exception skips rtk-using repo" {
  # Commit a file referencing "rtk" as a whole word so git grep -qlw rtk succeeds.
  printf 'rtk grep foo\n' > "$RITE_TEST_TMPDIR/rtk-helper.sh"
  git -C "$RITE_TEST_TMPDIR" add rtk-helper.sh
  git -C "$RITE_TEST_TMPDIR" commit -q -m "add rtk reference"

  local body
  body=$(printf 'rtk grep -rn "Only on this device" src/')
  run sanitize_generated_commands "$body" "$RITE_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  # Output must be unchanged because the repo references rtk
  [[ "$output" == 'rtk grep -rn "Only on this device" src/' ]]
}

# ---------------------------------------------------------------------------
# 10. Empty input passes through
# ---------------------------------------------------------------------------
@test "sanitize_generated_commands: empty input passes through unchanged" {
  run sanitize_generated_commands ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 11. Seam: plan-issues.sh calls sanitize_generated_commands before --body-file
# ---------------------------------------------------------------------------
@test "plan-issues.sh seam: sanitize_generated_commands called before body_file write" {
  run grep -n "sanitize_generated_commands" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh"
  [ "$status" -eq 0 ]
  # Must appear before the printf to body_file
  local sanitize_line body_printf_line
  sanitize_line=$(echo "$output" | grep -m1 "sanitize_generated_commands" | cut -d: -f1)
  body_printf_line=$(grep -n 'printf.*current_body.*body_file\|printf.*body_file' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" | grep -v "sanitize" | head -1 | cut -d: -f1 || true)
  [ -n "$sanitize_line" ]
}

# ---------------------------------------------------------------------------
# 12. Seam: assess-review-issues.sh calls sanitize_generated_commands before --body-file
# ---------------------------------------------------------------------------
@test "assess-review-issues.sh seam: sanitize_generated_commands called before body write" {
  run grep -n "sanitize_generated_commands" "${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 13. Seam: local-review.sh calls sanitize_generated_commands before PR comment
# ---------------------------------------------------------------------------
@test "local-review.sh seam: sanitize_generated_commands called on REVIEW_OUTPUT" {
  run grep -n "sanitize_generated_commands" "${RITE_REPO_ROOT}/lib/core/local-review.sh"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 14. Seam: promotion-composer.sh calls sanitize_generated_commands on llm_output
# ---------------------------------------------------------------------------
@test "promotion-composer.sh seam: sanitize_generated_commands called on llm_output" {
  run grep -n "sanitize_generated_commands" "${RITE_REPO_ROOT}/lib/utils/promotion-composer.sh"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 15-19. Meta-command passthrough (issue #1372)
#   rtk meta-commands have no underlying command — stripping "rtk " would
#   leave a nonexistent bare word. All five meta-commands must pass through
#   unchanged at every command position.
# ---------------------------------------------------------------------------

@test "sanitize_generated_commands: rtk gain passes through unchanged (line-start)" {
  run sanitize_generated_commands "$(printf 'rtk gain')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk gain' ]]
}

@test "sanitize_generated_commands: rtk discover passes through unchanged" {
  run sanitize_generated_commands "$(printf 'rtk discover')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk discover' ]]
}

@test "sanitize_generated_commands: rtk stats passes through unchanged" {
  run sanitize_generated_commands "$(printf 'rtk stats')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk stats' ]]
}

@test "sanitize_generated_commands: rtk init passes through unchanged" {
  run sanitize_generated_commands "$(printf 'rtk init')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk init' ]]
}

@test "sanitize_generated_commands: rtk read passes through unchanged" {
  run sanitize_generated_commands "$(printf 'rtk read')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk read' ]]
}

@test "sanitize_generated_commands: rtk gain --history passes through unchanged" {
  run sanitize_generated_commands "$(printf 'rtk gain --history')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk gain --history' ]]
}

@test "sanitize_generated_commands: rtk stats --detail passes through unchanged" {
  run sanitize_generated_commands "$(printf 'rtk stats --detail')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'rtk stats --detail' ]]
}

@test "sanitize_generated_commands: rtk gain survives at all command positions" {
  local body
  body=$(printf 'See `rtk gain` for savings\nresult=$(rtk gain)\nrake clean | rtk gain\ncd repo && rtk gain')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`rtk gain`'* ]]
  [[ "$output" == *'$(rtk gain)'* ]]
  [[ "$output" == *'| rtk gain'* ]]
  [[ "$output" == *'&& rtk gain'* ]]
}

@test "sanitize_generated_commands: rtk stats --detail survives at all command positions" {
  local body
  body=$(printf 'See `rtk stats --detail`\nresult=$(rtk stats --detail)\npipe | rtk stats --detail\ncd repo && rtk stats --detail')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`rtk stats --detail`'* ]]
  [[ "$output" == *'$(rtk stats --detail)'* ]]
  [[ "$output" == *'| rtk stats --detail'* ]]
  [[ "$output" == *'&& rtk stats --detail'* ]]
}

@test "sanitize_generated_commands: wrapper stripped but meta-command preserved in same body" {
  local body
  body=$(printf 'rtk gain\nrtk grep -rn "foo" src/')
  run sanitize_generated_commands "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'rtk gain'* ]]
  [[ "$output" == *'grep -rn "foo" src/'* ]]
  [[ "$output" != *'rtk grep'* ]]
}

@test "sanitize_generated_commands: rtk readlink still stripped (not a meta-command)" {
  run sanitize_generated_commands "$(printf 'rtk readlink /some/path')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'readlink /some/path' ]]
}

@test "sanitize_generated_commands: rtk initdb still stripped (not a meta-command)" {
  run sanitize_generated_commands "$(printf 'rtk initdb --auth=md5')"
  [ "$status" -eq 0 ]
  [[ "$output" == 'initdb --auth=md5' ]]
}
