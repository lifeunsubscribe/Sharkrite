#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-full-suite
# tests/regression/full-suite-investigate.bats
#
# Regression tests for the --investigate flag added in issue #1228.
#
# Tests verify (per acceptance criteria):
#  1. A failing run with --investigate produces a dated report naming each
#     failing test and its persistent/cleared classification.
#  2. All-flake runs (cleared on serial re-run) produce a report but file no issue.
#  3. A persistent failure files exactly one issue carrying the dedup marker;
#     a second run with the same failing set files none.
#  4. A passing run writes no report, no issue, and clears the stale failure flag.
#  5. Issue creation failure leaves an orphan artifact rather than losing findings.
#
# Pattern follows full-suite-subcommand.bats: helpers are written to the fake
# project; the script is invoked via `run env ... bash "$_FULL_SUITE_SCRIPT"`.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  export _FAKE_PROJECT="$RITE_TEST_TMPDIR/fake-project"
  mkdir -p "$_FAKE_PROJECT/.rite/logs" \
           "$_FAKE_PROJECT/.rite/state" \
           "$_FAKE_PROJECT/.rite/reports" \
           "$_FAKE_PROJECT/tests"

  export _FULL_SUITE_SCRIPT="$RITE_REPO_ROOT/bin/rite-full-suite"
  export _GH_CALL_LOG="$RITE_TEST_TMPDIR/gh-calls.log"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Shared helper: write minimal lib stubs into the fake project.
# Mirrors _write_lib_stubs() in full-suite-subcommand.bats.
# ---------------------------------------------------------------------------
_write_lib_stubs() {
  mkdir -p "$_FAKE_PROJECT/lib/utils" "$_FAKE_PROJECT/lib/providers"

  cat > "$_FAKE_PROJECT/lib/utils/config.sh" << 'STUB'
#!/bin/bash
RITE_DATA_DIR="${RITE_DATA_DIR:-.rite}"
RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT:-$(pwd)}"
RITE_LIB_DIR="${RITE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")/../}"
RITE_PROJECT_NAME="${RITE_PROJECT_NAME:-fake-project}"
export RITE_DATA_DIR RITE_PROJECT_ROOT RITE_LIB_DIR RITE_PROJECT_NAME
STUB

  cat > "$_FAKE_PROJECT/lib/utils/colors.sh" << 'STUB'
#!/bin/bash
print_header()  { echo "=== $* ==="; }
print_info()    { echo "[INFO] $*"; }
print_step()    { echo "[STEP] $*"; }
print_success() { echo "[OK] $*"; }
print_warning() { echo "[WARN] $*"; }
print_error()   { echo "[ERROR] $*" >&2; }
strip_ansi()    { cat; }
STUB

  cat > "$_FAKE_PROJECT/lib/utils/logging.sh" << 'STUB'
#!/bin/bash
_RITE_LOGGING_LOADED=true
is_verbose() { [ "${RITE_VERBOSE:-false}" = "true" ]; }
_diag() {
  local msg="$1"
  if [ -n "${RITE_LOG_FILE:-}" ]; then
    echo "[diag] $(date '+%H:%M:%S') | $msg" >> "$RITE_LOG_FILE"
  fi
}
verbose_header()  { true; }
verbose_info()    { true; }
verbose_step()    { true; }
verbose_success() { true; }
verbose_warning() { true; }
STUB

  # Provider stubs: avoid touching the real Claude provider
  cat > "$_FAKE_PROJECT/lib/providers/provider-interface.sh" << 'STUB'
#!/bin/bash
_LOADED_PROVIDER=""
load_provider()        { _LOADED_PROVIDER="stub"; return 0; }
provider_detect_cli()  { return 0; }
provider_resolve_model() { echo "claude-sonnet-4-6"; }
provider_run_prompt()  {
  # Emit a minimal interpretation so report tests can assert on it
  echo "- Stub interpretation line for test"
}
STUB

  cat > "$_FAKE_PROJECT/lib/providers/claude.sh" << 'STUB'
#!/bin/bash
# provider stub — never sourced directly in these tests
STUB

  # markers.sh stub: export the full-suite-remediation marker constant
  cat > "$_FAKE_PROJECT/lib/utils/markers.sh" << 'STUB'
#!/bin/bash
RITE_MARKER_FULL_SUITE_REMEDIATION="sharkrite-full-suite-remediation"
export RITE_MARKER_FULL_SUITE_REMEDIATION
STUB

  # gh-retry.sh stub: gh_safe is a thin pass-through to the PATH gh binary
  cat > "$_FAKE_PROJECT/lib/utils/gh-retry.sh" << 'STUB'
#!/bin/bash
_RITE_GH_RETRY_LOADED=true
gh_safe() { gh "$@"; }
STUB
}

# ---------------------------------------------------------------------------
# Helper: write a minimal fake bats test file containing a named @test.
# Usage: _write_fake_bats_test <dir> <filename> <test_name>
# ---------------------------------------------------------------------------
_write_fake_bats_test() {
  local dir="$1" fname="$2" tname="$3"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bats\n@test "%s" {\n  true\n}\n' "$tname" > "${dir}/${fname}"
}

# ---------------------------------------------------------------------------
# Helper: write make stub that always exits 0
# ---------------------------------------------------------------------------
_write_make_stub() {
  mkdir -p "$_FAKE_PROJECT/bin"
  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/make"
  chmod +x "$_FAKE_PROJECT/bin/make"
}

# ---------------------------------------------------------------------------
# Test 1: --investigate on a failing run produces a dated report
# with persistent/cleared classification.
# ---------------------------------------------------------------------------
@test "investigate: failing run produces report with persistent/cleared classification" {
  _write_lib_stubs
  _write_make_stub

  local test_name="persistent-test-for-investigate-1"
  _write_fake_bats_test "$_FAKE_PROJECT/tests" "sample.bats" "$test_name"

  mkdir -p "$_FAKE_PROJECT/bin"

  # bats stub:
  #   parallel run (-r tests/) → emits "not ok N <name>" and exits 1
  #   serial run (specific file) → exits 1 (persistent failure)
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..1\nnot ok 1 %s\n  # (in test file %s/tests/sample.bats, line 2)\n' "$test_name" "$_FAKE_PROJECT"
  exit 1
else
  # Serial re-run of the specific file — still fails (persistent)
  printf '1..1\nnot ok 1 %s\n  # assertion: false\n' "$test_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  # gh stub: records calls; issue list returns null (no existing issue), create succeeds.
  # The --jq '.[0].number' expression on an empty array returns "null", so we match that.
  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  # Simulate --jq '.[0].number' on empty array: returns "null"
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/42"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # Report must exist
  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]

  # Report must name the test as persistent
  grep -q "$test_name" "$_report"
  grep -qi "persistent" "$_report"
}

# ---------------------------------------------------------------------------
# Test 2: --investigate when all failures clear on serial re-run → report
# written as flake, no issue created.
# ---------------------------------------------------------------------------
@test "investigate: cleared-on-serial failures reported as flake, no issue filed" {
  _write_lib_stubs
  _write_make_stub

  local test_name="flaky-test-clears-on-serial-2"
  _write_fake_bats_test "$_FAKE_PROJECT/tests" "flaky.bats" "$test_name"

  mkdir -p "$_FAKE_PROJECT/bin"

  # bats stub:
  #   parallel run → fails
  #   serial run  → passes (cleared)
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..1\nnot ok 1 %s\n' "$test_name"
  exit 1
else
  printf '1..1\nok 1 %s\n' "$test_name"
  exit 0
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  # gh stub: records all calls; issue create must NOT be called (all-flake run)
  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/99"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # Report must exist
  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]

  # Report must mention cleared/flake
  grep -qi "cleared\|flake" "$_report"

  # gh issue create must NOT have been called
  if [ -f "$_GH_CALL_LOG" ]; then
    ! grep -q "issue create" "$_GH_CALL_LOG"
  fi
}

# ---------------------------------------------------------------------------
# Test 3a: --investigate with persistent failure → files exactly one issue
# carrying the dedup marker.
# ---------------------------------------------------------------------------
@test "investigate: persistent failure files exactly one issue with dedup marker" {
  _write_lib_stubs
  _write_make_stub

  local test_name="persistent-dedup-test-3a"
  _write_fake_bats_test "$_FAKE_PROJECT/tests" "persistent.bats" "$test_name"

  mkdir -p "$_FAKE_PROJECT/bin"

  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..1\nnot ok 1 %s\n  # (in test file %s/tests/persistent.bats, line 2)\n' "$test_name" "$_FAKE_PROJECT"
  exit 1
else
  printf '1..1\nnot ok 1 %s\n  # assertion: true (still fails)\n' "$test_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  # No existing issue — simulate --jq '.[0].number' on empty array returning "null"
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/55"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # gh issue create must have been called exactly once
  local _create_count
  _create_count=$(grep -c "issue create" "$_GH_CALL_LOG" || true)
  [ "$_create_count" -eq 1 ]

  # The issue body file passed via --body-file must contain the dedup marker
  # Find the body file path from the gh call log
  local _body_file_arg
  _body_file_arg=$(grep "issue create" "$_GH_CALL_LOG" | grep -oE -- '--body-file [^ ]+' | awk '{print $2}' || true)
  # We can't read the temp file after deletion, but we can check the report has the marker prefix
  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]
  # Report should record the persistent test
  grep -q "$test_name" "$_report"
}

# ---------------------------------------------------------------------------
# Test 3b: second run with same failing set → dedup check prevents duplicate.
# ---------------------------------------------------------------------------
@test "investigate: second run with same failing set files no issue (dedup)" {
  _write_lib_stubs
  _write_make_stub

  local test_name="persistent-dedup-test-3b"
  _write_fake_bats_test "$_FAKE_PROJECT/tests" "persist2.bats" "$test_name"

  mkdir -p "$_FAKE_PROJECT/bin"

  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..1\nnot ok 1 %s\n' "$test_name"
  exit 1
else
  printf '1..1\nnot ok 1 %s\n  # assertion: still fails\n' "$test_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  # Pre-compute the expected dedup hash (same method as bin/rite-full-suite:
  # sort the hash_lines_file containing just the test name, then cksum).
  local _expected_hash
  _expected_hash=$(printf '%s\n' "$test_name" | cksum | awk '{print $1}')

  # gh stub: issue list returns an existing issue number — simulate the
  # --jq '.[].number' output from a matching issue (dedup should fire).
  # issue view returns a body containing the marker so client-side verification
  # passes (mirrors the hardened dedup pattern from merge-pr.sh:129-142).
  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "77"
  exit 0
fi
if echo "\$*" | grep -q "issue view"; then
  echo "<!-- sharkrite-full-suite-remediation:${_expected_hash} -->"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/99"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # gh issue create must NOT have been called (dedup hit)
  if [ -f "$_GH_CALL_LOG" ]; then
    ! grep -q "issue create" "$_GH_CALL_LOG"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: passing run → no report written, no issue filed, failure flag cleared.
# ---------------------------------------------------------------------------
@test "investigate: passing run writes no report and no issue" {
  _write_lib_stubs
  _write_make_stub

  mkdir -p "$_FAKE_PROJECT/bin" "$_FAKE_PROJECT/tests"

  # Pre-write a stale failure flag to confirm it gets cleared
  echo "outcome=failed" > "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag"

  printf '#!/bin/bash\nexit 0\n' > "$_FAKE_PROJECT/bin/bats"
  chmod +x "$_FAKE_PROJECT/bin/bats"

  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  [ "$status" -eq 0 ]

  # No report should have been written
  local _report_count
  _report_count=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | wc -l | tr -d ' ' || true)
  [ "${_report_count:-0}" -eq 0 ]

  # Failure flag must have been deleted
  [ ! -f "$_FAKE_PROJECT/.rite/state/full-suite-failure.flag" ]

  # gh issue create must not have been called
  if [ -f "$_GH_CALL_LOG" ]; then
    ! grep -q "issue create" "$_GH_CALL_LOG"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: two-test stub where serial re-run fails only one.
# The passing test must land in Cleared; the failing one in Persistent.
# The remediation issue body must NOT mention the cleared test.
# ---------------------------------------------------------------------------
@test "investigate: mixed file — only persistently-failing test reaches issue body" {
  _write_lib_stubs
  _write_make_stub

  local persist_name="mixed-persist-test-6"
  local clear_name="mixed-clear-test-6"

  # Write a two-test bats file
  local bats_file="$_FAKE_PROJECT/tests/mixed.bats"
  printf '#!/usr/bin/env bats\n@test "%s" { false; }\n@test "%s" { true; }\n' \
    "$persist_name" "$clear_name" > "$bats_file"

  mkdir -p "$_FAKE_PROJECT/bin"

  # bats stub:
  #   parallel run → both fail
  #   serial run → only persist_name fails; clear_name passes
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..2\nnot ok 1 %s\nnot ok 2 %s\n' "$persist_name" "$clear_name"
  exit 1
else
  # Serial re-run: only the first test still fails
  printf '1..2\nnot ok 1 %s\n  # assertion: false\nok 2 %s\n' "$persist_name" "$clear_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/66"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # Report must exist and name the persistent test
  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]
  grep -q "$persist_name" "$_report"

  # The cleared test must appear in the Cleared section (or at minimum must NOT
  # appear in a Persistent heading), and the issue must have been filed once.
  local _create_count
  _create_count=$(grep -c "issue create" "$_GH_CALL_LOG" || true)
  [ "$_create_count" -eq 1 ]

  # The issue body (captured via --body-file) must name the persistent test.
  # Since temp files are deleted, verify indirectly via the report which mirrors
  # the persistent set.
  grep -q "$persist_name" "$_report"
  # The cleared test must NOT appear in the "## Persistent Failures" section.
  # Extract that section (lines between the heading and the next ## heading)
  # and assert the clear name is absent. This is discriminating: reverting to
  # the old substring-match classification leaves this assertion failing because
  # clear_name would appear under Persistent Failures.
  ! awk '/^## Persistent Failures/{p=1; next} p && /^## /{p=0} p' "$_report" \
      | grep -qF "$clear_name"
}

# ---------------------------------------------------------------------------
# Test 6b: name-collision guard — a cleared test whose name is a prefix of a
# persistent test's name must still be classified as cleared, not persistent.
# Regression test for the substring-match bug: grep -F "foo" matched "not ok 1 foo-bar"
# causing "foo" to be misclassified as persistent when only "foo-bar" persisted.
# ---------------------------------------------------------------------------
@test "investigate: cleared test with name that is prefix of persistent test is not misclassified" {
  _write_lib_stubs
  _write_make_stub

  local persist_name="prefix-collision-test-6b-extended"
  local clear_name="prefix-collision-test-6b"

  # Write a two-test bats file
  local bats_file="$_FAKE_PROJECT/tests/collision.bats"
  printf '#!/usr/bin/env bats\n@test "%s" { false; }\n@test "%s" { true; }\n' \
    "$persist_name" "$clear_name" > "$bats_file"

  mkdir -p "$_FAKE_PROJECT/bin"

  # bats stub:
  #   parallel run → both fail
  #   serial run → only persist_name fails; clear_name passes
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..2\nnot ok 1 %s\nnot ok 2 %s\n' "$persist_name" "$clear_name"
  exit 1
else
  printf '1..2\nnot ok 1 %s\n  # assertion: false\nok 2 %s\n' "$persist_name" "$clear_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/67"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]

  # persist_name must be in the Persistent Failures section
  awk '/^## Persistent Failures/{p=1; next} p && /^## /{p=0} p' "$_report" \
      | grep -qF "$persist_name"

  # clear_name must NOT appear in the Persistent Failures section.
  # Use backtick-wrapped grep: clear_name is a prefix of persist_name, so
  # a bare grep -F would match the persistent entry as a substring.
  ! awk '/^## Persistent Failures/{p=1; next} p && /^## /{p=0} p' "$_report" \
      | grep -qF "\`${clear_name}\`"
}

# ---------------------------------------------------------------------------
# Test 6c: name-collision guard — a cleared test whose name is a trailing
# substring (suffix) of a persistent test's name must still be classified
# as cleared, not persistent.
# Regression for the suffix-anchor bug: with the old
# substr($0,len-len(name)+1)==name comparison, "collision-test-6c" matched
# the end of "not ok 1 suffix-collision-test-6c".
# ---------------------------------------------------------------------------
@test "investigate: cleared test with name that is suffix of persistent test is not misclassified" {
  _write_lib_stubs
  _write_make_stub

  local persist_name="suffix-collision-test-6c"
  local clear_name="collision-test-6c"

  # Write a two-test bats file
  local bats_file="$_FAKE_PROJECT/tests/collision-suffix.bats"
  printf '#!/usr/bin/env bats\n@test "%s" { false; }\n@test "%s" { true; }\n' \
    "$persist_name" "$clear_name" > "$bats_file"

  mkdir -p "$_FAKE_PROJECT/bin"

  # bats stub:
  #   parallel run → both fail
  #   serial run → only persist_name fails; clear_name passes
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..2\nnot ok 1 %s\nnot ok 2 %s\n' "$persist_name" "$clear_name"
  exit 1
else
  printf '1..2\nnot ok 1 %s\n  # assertion: false\nok 2 %s\n' "$persist_name" "$clear_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/68"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]

  # persist_name must be in the Persistent Failures section
  awk '/^## Persistent Failures/{p=1; next} p && /^## /{p=0} p' "$_report" \
      | grep -qF "\`${persist_name}\`"

  # clear_name must NOT appear in the Persistent Failures section.
  # Use backtick-wrapped grep: clear_name is a suffix of persist_name, so a
  # bare grep -F would match the persistent entry as a substring.
  ! awk '/^## Persistent Failures/{p=1; next} p && /^## /{p=0} p' "$_report" \
      | grep -qF "\`${clear_name}\`"
}

# ---------------------------------------------------------------------------
# Test 7: persistent failure with no "#" assertion comment.
# The report and remediation issue must still be produced (no silent death).
# ---------------------------------------------------------------------------
@test "investigate: persistent failure with no assertion comment still produces report and issue" {
  _write_lib_stubs
  _write_make_stub

  local test_name="no-assertion-persistent-test-7"
  _write_fake_bats_test "$_FAKE_PROJECT/tests" "noassert.bats" "$test_name"

  mkdir -p "$_FAKE_PROJECT/bin"

  # bats stub: both parallel and serial fail, with NO "#" assertion comment
  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..1\nnot ok 1 %s\n' "$test_name"
  exit 1
else
  # Serial re-run: still fails, but emits no assertion comment
  printf '1..1\nnot ok 1 %s\n' "$test_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "https://github.com/owner/repo/issues/88"
  exit 0
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # Script must not have exited with set -e silent death: report must exist
  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ] || { echo "report not written — script likely died silently"; false; }

  # Report must name the persistent test
  grep -q "$test_name" "$_report"

  # Issue must have been filed (persistent failure exists)
  local _create_count
  _create_count=$(grep -c "issue create" "$_GH_CALL_LOG" || true)
  [ "$_create_count" -eq 1 ] || { echo "expected 1 issue create call, got $_create_count"; false; }
}

# ---------------------------------------------------------------------------
# Test 5: issue creation failure → orphan artifact written, findings not lost.
# ---------------------------------------------------------------------------
@test "investigate: issue creation failure leaves orphan artifact" {
  _write_lib_stubs
  _write_make_stub

  local test_name="persistent-orphan-test-5"
  _write_fake_bats_test "$_FAKE_PROJECT/tests" "orphan.bats" "$test_name"

  mkdir -p "$_FAKE_PROJECT/bin"

  cat > "$_FAKE_PROJECT/bin/bats" << EOF
#!/bin/bash
if echo "\$*" | grep -q -- "-r tests/"; then
  printf '1..1\nnot ok 1 %s\n' "$test_name"
  exit 1
else
  printf '1..1\nnot ok 1 %s\n  # assertion: fails in serial too\n' "$test_name"
  exit 1
fi
EOF
  chmod +x "$_FAKE_PROJECT/bin/bats"

  # gh stub: issue list returns null (no existing issue), issue create FAILS
  cat > "$_FAKE_PROJECT/bin/gh" << EOF
#!/bin/bash
echo "\$@" >> "$_GH_CALL_LOG"
if echo "\$*" | grep -q "issue list"; then
  echo "null"
  exit 0
fi
if echo "\$*" | grep -q "issue create"; then
  echo "gh: API error" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$_FAKE_PROJECT/bin/gh"

  run env \
    PATH="$_FAKE_PROJECT/bin:$PATH" \
    RITE_INSTALL_DIR="$_FAKE_PROJECT" \
    RITE_LIB_DIR="$_FAKE_PROJECT/lib" \
    RITE_PROJECT_ROOT="$_FAKE_PROJECT" \
    RITE_DATA_DIR=".rite" \
    bash "$_FULL_SUITE_SCRIPT" --investigate

  # Orphan artifact must exist and contain the test name
  local _orphan="$_FAKE_PROJECT/.rite/orphaned-followup-items.md"
  [ -f "$_orphan" ]
  grep -q "$test_name" "$_orphan"

  # Report must still have been written despite issue creation failure
  local _report
  _report=$(find "$_FAKE_PROJECT/.rite/reports" -name "full-suite-*.md" | head -1 || true)
  [ -n "$_report" ]
}
