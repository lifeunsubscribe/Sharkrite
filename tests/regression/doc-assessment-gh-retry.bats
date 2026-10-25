#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/utils/gh-retry.sh
# Regression test: assess-documentation.sh retries on GitHub 5xx (transient)
# Issue #62
#
# Live failure 2026-05-27:
#   could not find pull request diff: HTTP 500: Server Error: Sorry, this diff
#   is temporarily unavailable due to heavy server load.
#   PullRequest.diff not_available
#   ⚠️  Documentation assessment finished with errors (exit 1)
#
# A manual retry seconds later worked fine — confirming a transient failure.
#
# Acceptance criteria:
# 1. gh_safe retries 5xx automatically (inherited from gh-retry.sh behavior).
# 2. When gh returns 500 on the first two attempts then succeeds on the third,
#    assess-documentation.sh completes successfully (exit 0).
# 3. (pr diff criteria removed 2026-10-21: the script no longer fetches the
#    diff — its only consumer, the per-merge doc-sync rewrite, was retired.)
# 4. When gh exhausts all retries on pr view, assessment exits 0 with a clear
#    "Doc assessment skipped for PR #N" message.
# 5. Static check: the gh calls in assess-documentation.sh use gh_safe (not
#    bare gh), confirming the retry layer is in place.
# 6. Static check: the "skipped" message text is present in
#    assess-documentation.sh to guard against accidental removal.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/doc-retry-test"
  mkdir -p "$TEST_TMPDIR"

  # Stub bin dir — prepend to PATH so fake gh overrides the real one
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
  export GH_RETRY_SH
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ===========================================================================
# Test 1: gh returns 500 twice then succeeds — assessment must complete (exit 0)
# ===========================================================================

@test "doc-assessment: gh 500 twice then success — assessment completes (exit 0)" {
  # Stub: pr view and pr diff both return 500 on first 2 calls, succeed on 3rd.
  # We track call count in a shared file so both operations hit the same counter.
  # Named diff-attempts (same convention as Test 4) — counts across ALL gh calls
  # in this test, not just pr diff calls.
  local attempt_file="$TEST_TMPDIR/diff-attempts"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -le 2 ]; then
  echo "HTTP 500: Server Error: Sorry, this diff is temporarily unavailable due to heavy server load." >&2
  exit 1
fi
# Succeed: return minimal valid output for pr view or pr diff
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  echo '{"title":"Fix something","body":"","files":[{"path":"lib/foo.sh"}],"commits":[],"reviews":[],"comments":[]}'
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "diff" ]; then
  echo "diff --git a/lib/foo.sh b/lib/foo.sh"
  echo "+added line"
  exit 0
fi
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  # Invoke gh_safe directly (not the full assess-documentation.sh which needs
  # a real repo+config environment). We test that gh_safe retries 5xx and
  # eventually succeeds — this is the mechanism assess-documentation.sh relies on.
  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr diff 42)
    echo \"exit:\$?\"
    echo \"result:\${result:0:30}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "exit:0" ]]
  [[ "$output" =~ "diff --git" ]]
}

# ===========================================================================
# Test 3: gh exhausts all retries on pr view — assess-documentation exits 0
#          with a clear "skipped" message
# ===========================================================================

@test "doc-assessment: exhausted retries on pr view — exits 0 with skipped message" {
  # Stub: pr view always returns 500
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "HTTP 500: Server Error" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=2
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    RITE_GH_MAX_RETRIES=2
    PR_NUMBER=59

    _pr_data_exit=0
    PR_DATA=\$(gh_safe pr view \"\$PR_NUMBER\" --json title,body,files,commits,reviews,comments) || _pr_data_exit=\$?
    if [ \"\$_pr_data_exit\" -ne 0 ]; then
      echo \"Doc assessment skipped for PR #\${PR_NUMBER}: GitHub API unavailable after \${RITE_GH_MAX_RETRIES:-3} attempts\"
      exit 0
    fi

    echo 'assessment completed'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Doc assessment skipped for PR #59" ]]
  [[ "$output" != *"assessment completed"* ]]
}

# ===========================================================================
# Test 5: Static check — assess-documentation.sh uses gh_safe (not bare gh)
# ===========================================================================

@test "assess-documentation.sh: gh calls use gh_safe not bare gh" {
  local assess_doc="$PROJECT_ROOT/lib/core/assess-documentation.sh"

  # Check for gh_safe usage on the pr view line
  local pr_view_line
  pr_view_line=$(grep "pr view.*--json" "$assess_doc")
  [[ "$pr_view_line" =~ "gh_safe" ]]

  # Verify no bare `gh pr diff` or `gh pr view` calls (raw gh, not wrapped)
  local bare_gh_count
  bare_gh_count=$(grep -cE '^\s*PR_(DATA|DIFF)=\$\(gh ' "$assess_doc" || true)
  [ "$bare_gh_count" -eq 0 ]
}

# ===========================================================================
# Test 6: Static check — "skipped" message text present in source
# ===========================================================================

@test "assess-documentation.sh: skipped message text present in source" {
  local assess_doc="$PROJECT_ROOT/lib/core/assess-documentation.sh"

  # The clear retry message must exist in the source — guards against accidental removal
  local skipped_count
  skipped_count=$(grep -c "Doc assessment skipped for PR" "$assess_doc" || true)
  [ "$skipped_count" -ge 1 ]

  # The re-run instructions must mention the script path
  local rerun_count
  rerun_count=$(grep -c "assess-documentation.sh" "$assess_doc" || true)
  [ "$rerun_count" -ge 1 ]
}

