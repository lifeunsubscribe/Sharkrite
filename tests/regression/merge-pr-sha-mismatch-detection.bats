#!/usr/bin/env bats
# Regression test: merge-pr.sh 409 detection depends on gh_safe stderr passthrough
#
# Documents and pins the contract between merge-pr.sh and gh-retry.sh:
#
#   merge-pr.sh calls gh_safe via _do_merge, which captures combined stdout+stderr
#   using `2>&1`. The 409 "Head branch was modified" detection relies on gh_safe
#   echoing GitHub's error text to its own stderr (gh-retry.sh non-transient path).
#   Without that echo, the grep silently fails to match and SHA-mismatch recovery
#   never triggers — no error, just a silent abort.
#
# What is tested:
#   1. gh_safe echoes 409/SHA-mismatch stderr verbatim on the non-transient path
#   2. _do_merge's 2>&1 captures gh_safe stderr into MERGE_OUTPUT
#   3. The grep in merge-pr.sh matches "Head branch was modified" from a real 409 body
#   4. Last-attempt fallthrough path also echoes stderr (transient-pattern error, retries exhausted)
#   5. Full end-to-end chain: _do_merge + gh_safe + grep detects 409 correctly
#
# If any of these break, the 409 recovery in merge-pr.sh stops working silently.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/sha-mismatch-test"
  mkdir -p "$TEST_TMPDIR"

  # Stub bin dir — prepend to PATH so our fake gh overrides the real one
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
  export GH_RETRY_SH
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Test 1: gh_safe echoes 409 error text to stderr on the non-transient path
#
# This is the base of the contract. If gh_safe doesn't echo 409 stderr,
# _do_merge's 2>&1 captures nothing useful.
# ---------------------------------------------------------------------------
@test "gh_safe echoes 409 'Head branch was modified' to stderr on non-transient path" {
  # Stub: returns 409-like response (non-transient — not 429 or 5xx, so no retry)
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo '{"message":"Head branch was modified. Review and try the merge again.","documentation_url":"https://docs.github.com/rest"}' >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    # Capture stderr to a temp file since run captures stdout
    err_file=\$(mktemp '$TEST_TMPDIR/err.XXXXXX')
    gh_safe api 'repos/owner/repo/pulls/42/merge' -X PUT -f merge_method=squash -f sha=abc123 2>\"\$err_file\" || true
    echo \"stderr_content:\$(cat \"\$err_file\")\"
  "

  # The 409 message must appear in stderr output
  [[ "$output" =~ "Head branch was modified" ]] || {
    echo "FAIL: gh_safe did not echo 409 error to stderr"
    echo "output was: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: _do_merge 2>&1 captures gh_safe stderr into MERGE_OUTPUT
#
# This tests the full chain: gh emits 409 to stderr → gh_safe passes it to
# its stderr → _do_merge's 2>&1 redirects it into MERGE_OUTPUT.
# ---------------------------------------------------------------------------
@test "_do_merge captures gh_safe stderr into MERGE_OUTPUT via 2>&1" {
  # Stub: simulates GitHub's 409 response for head-changed scenario
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo '{"message":"Head branch was modified. Review and try the merge again.","documentation_url":"https://docs.github.com/rest"}' >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'

    # Reproduce _do_merge exactly as in merge-pr.sh
    _do_merge() {
      MERGE_OUTPUT=\$(\"\$@\" 2>&1) && MERGE_EXIT_CODE=0 || MERGE_EXIT_CODE=\$?
    }

    _do_merge gh_safe api 'repos/owner/repo/pulls/42/merge' \
      -X PUT \
      -f merge_method=squash \
      -f sha=abc123

    echo \"exit_code:\$MERGE_EXIT_CODE\"
    echo \"output:\$MERGE_OUTPUT\"
  "

  # bash -c itself must succeed (we captured the inner error in MERGE_EXIT_CODE)
  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit_code:1" ]]

  # The 409 message must be in MERGE_OUTPUT (captured from gh_safe's stderr)
  [[ "$output" =~ "Head branch was modified" ]] || {
    echo "FAIL: 409 message not captured in MERGE_OUTPUT"
    echo "output was: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3: The grep pattern used in merge-pr.sh matches realistic 409 responses
#
# merge-pr.sh line ~721:
#   echo "$MERGE_OUTPUT" | grep -qiE "Head branch was modified|409"
#
# Tests multiple realistic GitHub 409 response bodies to ensure the pattern
# is robust — GitHub might vary the exact phrasing.
# ---------------------------------------------------------------------------
@test "merge-pr.sh grep pattern matches 'Head branch was modified' from 409 body" {
  # Realistic GitHub 409 JSON body for head-changed
  local body_json
  body_json='{"message":"Head branch was modified. Review and try the merge again.","documentation_url":"https://docs.github.com/rest"}'

  run bash -c "
    echo '$body_json' | grep -qiE 'Head branch was modified|409'
    echo \"matched:\$?\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "matched:0" ]]
}

@test "merge-pr.sh grep pattern matches bare '409' status text fallback" {
  # Some gh CLI versions may output the HTTP status code directly
  local status_line="HTTP 409: Conflict"

  run bash -c "
    echo '$status_line' | grep -qiE 'Head branch was modified|409'
    echo \"matched:\$?\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "matched:0" ]]
}

@test "merge-pr.sh grep pattern does NOT match unrelated errors" {
  # Verify the pattern isn't overly broad — a generic 422 or auth error
  # should not trigger the SHA-mismatch recovery path
  local unrelated="HTTP 422: Unprocessable Entity - Validation Failed"

  run bash -c "
    echo '$unrelated' | grep -qiE 'Head branch was modified|409'
    echo \"matched:\$?\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "matched:1" ]]
}

# ---------------------------------------------------------------------------
# Test 4: gh_safe last-attempt fallthrough path also echoes stderr
#
# When gh returns a transient-pattern error (429/5xx) on the LAST attempt,
# the retry guard (`attempt < MAX_RETRIES`) is false so no sleep/continue
# occurs. Execution falls through to the non-transient propagation block,
# which echoes stderr. Verifies stderr is always surfaced on that path.
# ---------------------------------------------------------------------------
@test "gh_safe exhausted-retries path echoes final stderr to caller" {
  # Stub: fails with a 5xx-pattern stderr message so gh_safe classifies it as
  # transient (the grep at the retry-classification block matches "500"/"server
  # error"). With RITE_GH_MAX_RETRIES=1, attempt(1) < 1 is false — no retry
  # fires. Execution falls through to the non-transient propagation block, which
  # echoes stderr. This exercises a different code path than Test 1 (Test 1's
  # stub does NOT match the transient-pattern grep).
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "HTTP 500 Server Error: Head branch was modified." >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=1  # Single attempt — exercises exhausted-retries path

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    export RITE_GH_MAX_RETRIES=1
    source '$GH_RETRY_SH'
    err_file=\$(mktemp '$TEST_TMPDIR/err.XXXXXX')
    gh_safe api 'repos/owner/repo/pulls/42/merge' -X PUT -f merge_method=squash -f sha=abc123 2>\"\$err_file\" || true
    echo \"stderr:\$(cat \"\$err_file\")\"
  "

  # The error text must have reached the caller's stderr
  [[ "$output" =~ "Head branch was modified" ]] || {
    echo "FAIL: exhausted-retries path did not echo stderr to caller"
    echo "output was: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 5: Full end-to-end chain — _do_merge receives 409, grep detects it
#
# This is the most important test: exercises the complete path that
# merge-pr.sh relies on in production.
# ---------------------------------------------------------------------------
@test "full chain: _do_merge + gh_safe + grep detects 409 SHA-mismatch" {
  # Stub: realistic GitHub 409 for head-changed
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo '{"message":"Head branch was modified. Review and try the merge again."}' >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  # Preserve system PATH alongside stub so mktemp/etc are available inside gh_safe
  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'

    _do_merge() {
      MERGE_OUTPUT=\$(\"\$@\" 2>&1) && MERGE_EXIT_CODE=0 || MERGE_EXIT_CODE=\$?
    }

    _do_merge gh_safe api 'repos/owner/repo/pulls/42/merge' \
      -X PUT -f merge_method=squash -f sha=abc123

    # Reproduce the exact detection logic from merge-pr.sh
    if [ \$MERGE_EXIT_CODE -ne 0 ] && echo \"\$MERGE_OUTPUT\" | grep -qiE 'Head branch was modified|409'; then
      echo 'sha_mismatch_detected'
    else
      echo 'sha_mismatch_NOT_detected'
      echo \"MERGE_OUTPUT was: \$MERGE_OUTPUT\"
    fi
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "sha_mismatch_detected" ]] || {
    echo "FAIL: end-to-end chain did not detect SHA mismatch"
    echo "output was: $output"
    false
  }
}
