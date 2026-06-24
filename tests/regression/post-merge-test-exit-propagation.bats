#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/post-merge-verify.sh, lib/utils/test-gate.sh
# Regression test for: Fix tee'd pipeline test_exit in post-merge-verify
#
# Bug: post-merge-verify.sh used `$?` after a pipeline (`... | sed`) without
# pipefail enabled, which captured sed's exit code (always 0), not the test
# command's exit code. This allowed failing tests to be silently reported as
# passing at the merge gate.
#
# Fix: Enable `set -o pipefail` at the top of the script so that $? after
# a pipeline captures the first failing command's exit code, not the last
# command in the pipeline.
#
# Issue #485: post-merge-verify now delegates to run_test_gate for Sharkrite
# repos, applying the same targeted-selection logic as the pre-merge gate.
# Tests added here cover the new delegation path.

setup() {
  # Create minimal test environment
  export RITE_TEST_ROOT="${BATS_TEST_TMPDIR}/rite-test"
  export RITE_PROJECT_ROOT="$RITE_TEST_ROOT"
  export RITE_LIB_DIR="${RITE_TEST_ROOT}/lib"
  mkdir -p "$RITE_LIB_DIR/utils"

  # Create test worktree
  export TEST_WORKTREE="${RITE_TEST_ROOT}/test-wt"
  mkdir -p "$TEST_WORKTREE"

  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"

  # Stub config.sh (required by post-merge-verify.sh)
  cat > "$RITE_LIB_DIR/utils/config.sh" <<'CONFIG_EOF'
#!/bin/bash
RITE_LIB_DIR="${RITE_LIB_DIR}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
RITE_SKIP_TESTS="${RITE_SKIP_TESTS:-false}"
RITE_TEST_CMD="${RITE_TEST_CMD:-}"
CONFIG_EOF

  # Stub logging.sh with a _diag that is a no-op (avoids RITE_LOG_FILE dep)
  cat > "$RITE_LIB_DIR/utils/logging.sh" <<'LOG_EOF'
#!/bin/bash
_diag() { true; }
is_verbose() { false; }
export -f _diag is_verbose 2>/dev/null || true
LOG_EOF

  # Copy real markers.sh — needed by test-gate.sh for RITE_MARKER_TEST_COVERS
  cp "${REAL_RITE_ROOT}/lib/utils/markers.sh" "$RITE_LIB_DIR/utils/"

  # Copy test-gate.sh — post-merge-verify.sh sources it at load time, so every
  # test that sources post-merge-verify.sh needs it present (not just the few
  # that copy it explicitly). Without this, tests 1-3 fail at the source line.
  cp "${REAL_RITE_ROOT}/lib/utils/test-gate.sh" "$RITE_LIB_DIR/utils/"

  # Copy actual post-merge-verify.sh from the real repo
  cp "${REAL_RITE_ROOT}/lib/utils/post-merge-verify.sh" "$RITE_LIB_DIR/utils/"
}

teardown() {
  rm -rf "$RITE_TEST_ROOT"
}

# ---------------------------------------------------------------------------
# Original tests: non-Sharkrite path (RITE_TEST_CMD override)
# These verify the fallback (non-Sharkrite) code path is unchanged.
# ---------------------------------------------------------------------------

@test "verify_post_merge returns 0 when test command exits 0" {
  # Create a fake test command that succeeds
  export RITE_TEST_CMD="exit 0"

  # Source the script
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Run verify_post_merge
  run verify_post_merge "$TEST_WORKTREE"

  # Should succeed (exit 0)
  [ "$status" -eq 0 ]
}

@test "verify_post_merge returns 1 when test command exits 1 (critical regression guard)" {
  # Create a fake test command that fails
  export RITE_TEST_CMD="exit 1"

  # Source the script
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Skip the "check if main is broken" logic by stubbing git commands
  # We want to test only the exit code propagation, not the fallback logic
  function git() {
    if [[ "$*" == *"worktree add"* ]]; then
      # Fail worktree creation so main-check is skipped
      return 1
    fi
    # Pass through other git commands to real git
    command git "$@"
  }
  export -f git

  # Run verify_post_merge - should detect the failure
  run verify_post_merge "$TEST_WORKTREE"

  # Should fail (exit 1) because test_exit should be 1 from our stubbed command
  [ "$status" -eq 1 ]

  # Verify the error message indicates test failure
  [[ "$output" == *"Post-merge verification FAILED"* ]] || \
  [[ "$output" == *"tests now fail"* ]]
}

@test "verify_post_merge propagates exit code through tee'd pipeline with sed" {
  # This is the most specific test for the bug: verify that exit codes
  # propagate correctly through the exact pipeline pattern that was broken:
  # ( ... eval "$test_cmd" ) 2>&1 | sed 's/^/  /' >&2 || test_exit=$?

  # Create a test command that exits with a specific code
  export RITE_TEST_CMD="exit 42"

  # Source the script
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Stub git to skip main-check fallback
  function git() {
    if [[ "$*" == *"worktree add"* ]]; then
      return 1
    fi
    command git "$@"
  }
  export -f git

  # Run verify_post_merge
  run verify_post_merge "$TEST_WORKTREE"

  # Should fail (exit 1) - verify_post_merge converts any non-zero to 1
  [ "$status" -eq 1 ]

  # The key assertion: if the old bug existed (no pipefail), sed would have
  # returned 0 and test_exit would be 0, causing verify_post_merge to return 0.
  # With the fix (pipefail enabled), $? after the pipeline captures exit 42
  # from the test command, causing verify_post_merge to return 1.
}

@test "pipefail ensures \$? captures first failing command in pipeline" {
  # Verify that with pipefail enabled, $? after a pipeline captures the exit
  # code of the first failing command, not the last command in the pipeline.
  # This is the mechanism that makes exit code propagation work correctly.

  # Enable pipefail (matching post-merge-verify.sh)
  set -o pipefail

  # Run a command with no pipeline
  (exit 17) || EXIT_CODE=$?

  # Should capture the exit code correctly
  [ "$EXIT_CODE" -eq 17 ]

  # Run a command with a pipeline (first command fails, second succeeds)
  (exit 23) | cat >/dev/null || EXIT_CODE=$?

  # With pipefail, should capture the first command's exit code, not cat's
  [ "$EXIT_CODE" -eq 23 ]
}

@test "set -o pipefail is enabled in post-merge-verify.sh" {
  # Verify that pipefail is set to ensure pipeline failures propagate

  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Check if pipefail is enabled by examining shell options
  # The 'set -o' command lists all shell options and their states
  run bash -c "source '$RITE_LIB_DIR/utils/post-merge-verify.sh' && set -o | grep pipefail"

  # Should show "pipefail on"
  [[ "$output" == *"pipefail"*"on"* ]]
}

# ---------------------------------------------------------------------------
# New tests: Sharkrite path — delegates to run_test_gate (issue #485)
# ---------------------------------------------------------------------------

@test "verify_post_merge uses run_test_gate for Sharkrite repos" {
  # A Sharkrite repo has a Makefile with shellcheck: and lint: targets.
  # Verify that verify_post_merge calls run_test_gate (not the old test_cmd path).
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"

  # Copy real test-gate.sh
  cp "${REAL_RITE_ROOT}/lib/utils/test-gate.sh" "$RITE_LIB_DIR/utils/"

  # Create a Sharkrite-style Makefile in the test worktree
  cat > "$TEST_WORKTREE/Makefile" <<'MF_EOF'
shellcheck:
	@echo "shellcheck stub: OK"
lint:
	@echo "lint stub: OK"
test:
	@echo "test stub"
MF_EOF

  # Install a stub run_test_gate that records it was called and exits 0.
  # This verifies the delegation path fires without running the real gate.
  run_test_gate_called_file="${BATS_TEST_TMPDIR}/run_test_gate_called"
  # Export path so the overriding function can write to it
  export _PMV_GATE_CALLED_FILE="$run_test_gate_called_file"

  # Source post-merge-verify.sh (which sources test-gate.sh), then override
  # run_test_gate with our recording stub
  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"
  run_test_gate() {
    local _out_file="$1"
    touch "${_PMV_GATE_CALLED_FILE:-/dev/null}"
    # Write valid gate JSON (passed result)
    printf '{"lint":[],"tests":[],"exit_code":0}' > "$_out_file"
    return 0
  }
  export -f run_test_gate

  run verify_post_merge "$TEST_WORKTREE"

  [ "$status" -eq 0 ]
  # Confirm run_test_gate was invoked (not the old RITE_TEST_CMD path)
  [ -f "$run_test_gate_called_file" ]
}

@test "verify_post_merge returns 1 when run_test_gate fails on Sharkrite repo (no broken main)" {
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/utils/test-gate.sh" "$RITE_LIB_DIR/utils/"

  # Sharkrite Makefile
  cat > "$TEST_WORKTREE/Makefile" <<'MF_EOF'
shellcheck:
	@true
lint:
	@true
MF_EOF

  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Stub run_test_gate to fail (simulates test failures after merge)
  run_test_gate() {
    local _out_file="$1"
    printf '{"lint":[],"tests":[{"file":"bats","test_name":"foo","reason":"assertion failed"}],"exit_code":1}' > "$_out_file"
    return 1
  }
  export -f run_test_gate

  # Stub git worktree add to fail so the "is main broken" check is skipped
  git() {
    if [[ "$*" == *"worktree add"* ]]; then
      return 1
    fi
    command git "$@"
  }
  export -f git

  run verify_post_merge "$TEST_WORKTREE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Post-merge verification FAILED"* ]]
}

@test "verify_post_merge returns 0 when run_test_gate fails but main is also broken" {
  # If both the feature branch AND main fail the gate, the failure is a
  # pre-existing main problem — not a semantic conflict from this merge.
  # verify_post_merge should return 0 (allow workflow to proceed).
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/utils/test-gate.sh" "$RITE_LIB_DIR/utils/"

  # Sharkrite Makefile
  cat > "$TEST_WORKTREE/Makefile" <<'MF_EOF'
shellcheck:
	@true
lint:
	@true
MF_EOF

  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Stub run_test_gate to always fail (both feature branch and main checks)
  run_test_gate() {
    local _out_file="$1"
    printf '{"lint":[],"tests":[{"file":"bats","test_name":"broken","reason":"assertion failed"}],"exit_code":1}' > "$_out_file"
    return 1
  }
  export -f run_test_gate

  # Stub git worktree add to succeed (so main-broken check runs)
  local _fake_main_dir="${BATS_TEST_TMPDIR}/fake-main"
  mkdir -p "$_fake_main_dir"
  export _FAKE_MAIN_DIR="$_fake_main_dir"
  git() {
    if [[ "$*" == *"worktree add"* ]]; then
      # Succeed: copy the fake dir path from the args
      # The actual temp dir was created above; just return 0
      return 0
    fi
    if [[ "$*" == *"worktree remove"* ]]; then
      return 0
    fi
    command git "$@"
  }
  export -f git

  run verify_post_merge "$TEST_WORKTREE"

  # Should return 0: main is broken too, so this branch isn't at fault
  [ "$status" -eq 0 ]
  [[ "$output" == *"main branch is broken"* ]]
}

@test "verify_post_merge emits targeted-gate banner for Sharkrite repos" {
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/utils/test-gate.sh" "$RITE_LIB_DIR/utils/"

  cat > "$TEST_WORKTREE/Makefile" <<'MF_EOF'
shellcheck:
	@true
lint:
	@true
MF_EOF

  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Stub run_test_gate to succeed immediately
  run_test_gate() {
    local _out_file="$1"
    printf '{"lint":[],"tests":[],"exit_code":0}' > "$_out_file"
    return 0
  }
  export -f run_test_gate

  run verify_post_merge "$TEST_WORKTREE"

  [ "$status" -eq 0 ]
  # The Sharkrite path prints "targeted gate" rather than the old
  # "Running post-merge verification (make test)" style banner
  [[ "$output" == *"targeted gate"* ]]
}

# ---------------------------------------------------------------------------
# Real run_test_gate selection test (issue #485 / review finding #3)
#
# The four tests above stub run_test_gate, which means they cannot detect
# the diff-base defect fixed in items #1/#2. This test runs the REAL
# run_test_gate against a tiny fixture repo to verify:
#   1. RITE_TEST_GATE_DIFF_BASE=pre_merge_ref flows through correctly
#   2. Targeted selection picks only bats files whose covered paths changed
#      in the merge commit — not based on origin/main...HEAD merge-base
#   3. The TEST_GATE_SELECTION diag line is emitted with mode=targeted
# ---------------------------------------------------------------------------

@test "run_test_gate uses RITE_TEST_GATE_DIFF_BASE for targeted selection (real gate, no stub)" {
  # This test uses the REAL run_test_gate (not stubbed) against a tiny
  # fixture repo. It verifies that:
  # (a) When RITE_TEST_GATE_DIFF_BASE=<pre_merge_sha>, the gate diffs from
  #     that SHA to HEAD, picking only bats files whose covered paths changed.
  # (b) A bats file covering an UNCHANGED path is NOT selected.
  # (c) The [diag] TEST_GATE_SELECTION line is emitted with mode=targeted.
  #
  # Fixture layout:
  #   Makefile     — shellcheck: and lint: targets are no-ops
  #   tests/some-feature.bats  — covers lib/some-feature.sh (CHANGED in merge)
  #   tests/other-thing.bats   — covers lib/other-thing.sh (NOT changed)
  # Git history:
  #   commit A (pre-merge) — adds Makefile, bats files, lib/other-thing.sh
  #   commit B (merge)     — adds lib/some-feature.sh (simulates what main brought in)
  # RITE_TEST_GATE_DIFF_BASE=<SHA of commit A> → diff A...B shows only lib/some-feature.sh
  # → only tests/some-feature.bats selected (targeted mode, 1/2 files)

  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"

  # Set up a real git repo in a temp dir
  local _fixture_repo
  _fixture_repo="$(mktemp -d "${BATS_TEST_TMPDIR}/fixture-repo.XXXXXX")"

  (
    cd "$_fixture_repo"
    git init -q
    git config user.email "test@sharkrite.local"
    git config user.name "Sharkrite Test"

    # Makefile: shellcheck: and lint: are no-ops so run_test_gate succeeds
    cat > Makefile <<'MF'
shellcheck:
	@true
lint:
	@true
MF

    # First bats file: covers lib/some-feature.sh (will be changed in "merge")
    mkdir -p tests
    cat > tests/some-feature.bats <<'BATS1'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/some-feature.sh
@test "some-feature stub always passes" {
  true
}
BATS1

    # Second bats file: covers lib/other-thing.sh (NOT changed in "merge")
    cat > tests/other-thing.bats <<'BATS2'
#!/usr/bin/env bats
# sharkrite-test-covers: lib/other-thing.sh
@test "other-thing stub always passes" {
  true
}
BATS2

    # Initial source files
    mkdir -p lib
    echo "# other-thing" > lib/other-thing.sh

    # Commit A: baseline (pre-merge state)
    git add .
    git commit -q -m "baseline: add Makefile, tests, and other-thing"
  )

  # Save the pre-merge SHA (commit A)
  local _pre_merge_sha
  _pre_merge_sha=$(git -C "$_fixture_repo" rev-parse HEAD)

  # Commit B: add lib/some-feature.sh — simulates what main brought in via merge
  (
    cd "$_fixture_repo"
    echo "# some-feature" > lib/some-feature.sh
    git add lib/some-feature.sh
    git commit -q -m "merge: add lib/some-feature.sh from main"
  )

  # Set up RITE_LIB_DIR pointing to the real lib (for logging.sh, markers.sh, etc.)
  # but override config.sh so RITE_LIB_DIR points back to the real lib
  local _test_lib_dir="${BATS_TEST_TMPDIR}/testlib"
  mkdir -p "$_test_lib_dir/utils"

  # Stub config.sh so RITE_LIB_DIR keeps pointing to real lib
  cat > "$_test_lib_dir/utils/config.sh" <<CONFIG
#!/bin/bash
RITE_LIB_DIR="${REAL_RITE_ROOT}/lib"
RITE_PROJECT_ROOT="${_fixture_repo}"
CONFIG

  # Run the real run_test_gate in a subshell, capturing all output.
  # RITE_TEST_GATE_DIFF_BASE=<pre_merge_sha> → diff shows only lib/some-feature.sh
  # RITE_LOG_FILE → a real file: the gate routes raw bats output there (not to
  # stdout) so failing-test transcripts stay out of concurrent phases. The
  # which-file-ran signal this test checks (some-feature vs other-thing) lives in
  # that raw output, so we assert against stdout+log combined. The [test-gate]
  # selection lines (targeted, 1/2) remain on stdout.
  local _gate_out _gate_json _gate_exit _gate_log _gate_all
  _gate_json="${BATS_TEST_TMPDIR}/gate-real-$$.json"
  _gate_log="${BATS_TEST_TMPDIR}/gate-real-$$.log"

  _gate_out=$(
    export RITE_LIB_DIR="${REAL_RITE_ROOT}/lib"
    export RITE_PROJECT_ROOT="${_fixture_repo}"
    export RITE_LOG_FILE="${_gate_log}"
    export RITE_TEST_GATE_DIFF_BASE="${_pre_merge_sha}"
    unset run_test_gate 2>/dev/null || true  # ensure real function loads
    source "${REAL_RITE_ROOT}/lib/utils/test-gate.sh"
    run_test_gate "${_gate_json}" "${_fixture_repo}" 2>&1
  ) || _gate_exit=$?

  # stdout + the run log, where the raw bats output (naming the file that ran) goes.
  _gate_all="${_gate_out}
$(cat "${_gate_log}" 2>/dev/null || true)"

  # Verify targeted mode was selected (not full suite)
  [[ "$_gate_out" == *"targeted"* ]] || {
    echo "Expected targeted selection in gate output, got:" >&2
    echo "$_gate_out" >&2
    return 1
  }

  # Verify only 1 of 2 bats files was selected
  [[ "$_gate_out" == *"1/2"* ]] || [[ "$_gate_out" == *"1 of 2"* ]] || \
  [[ "$_gate_out" == *"(1/"* ]] || {
    echo "Expected 1/2 bats files selected, got:" >&2
    echo "$_gate_out" >&2
    return 1
  }

  # Verify some-feature.bats was run (its covered path changed)
  [[ "$_gate_all" == *"some-feature"* ]] || {
    echo "Expected some-feature.bats to be selected, got:" >&2
    echo "$_gate_all" >&2
    return 1
  }

  # Verify other-thing.bats was NOT run (its covered path did not change)
  [[ "$_gate_all" != *"other-thing"* ]] || {
    echo "other-thing.bats should NOT have been selected (its covered path unchanged), got:" >&2
    echo "$_gate_all" >&2
    return 1
  }

  rm -f "${_gate_json:-}"
  rm -rf "$_fixture_repo"
}

@test "verify_post_merge does NOT use run_test_gate for non-Sharkrite repos" {
  # A non-Sharkrite worktree (no shellcheck: + lint: Makefile) must go through
  # the original RITE_TEST_CMD path, not the gate delegation.
  REAL_RITE_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  cp "${REAL_RITE_ROOT}/lib/utils/test-gate.sh" "$RITE_LIB_DIR/utils/"

  # No Makefile in TEST_WORKTREE (or Makefile without shellcheck:/lint:)
  cat > "$TEST_WORKTREE/Makefile" <<'MF_EOF'
test:
	@echo "non-sharkrite test"
MF_EOF

  export RITE_TEST_CMD="exit 0"

  gate_called_sentinel="${BATS_TEST_TMPDIR}/gate_called"
  export _PMV_NONSR_SENTINEL="$gate_called_sentinel"

  source "$RITE_LIB_DIR/utils/post-merge-verify.sh"

  # Override run_test_gate to record if it's called (it should NOT be)
  run_test_gate() {
    touch "${_PMV_NONSR_SENTINEL:-/dev/null}"
    return 0
  }
  export -f run_test_gate

  run verify_post_merge "$TEST_WORKTREE"

  [ "$status" -eq 0 ]
  # Gate must NOT have been called for a non-Sharkrite repo
  [ ! -f "$gate_called_sentinel" ]
}
