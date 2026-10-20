#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gh-retry.sh, lib/core/claude-workflow.sh
# Regression test: transport-level network error retry in gh_safe (#1188)
#
# Covers:
#   1. gh_safe retries on transport errors (TCP timeout, connection reset, etc.)
#   2. gh_safe does NOT retry non-transient errors (auth failure)
#   3. Fix-mode fetch distinguishes network failure from genuine absence:
#        gh_safe non-zero exit → "Failed to fetch assessment (network error)"
#        gh_safe exit 0 + empty → "No assessment found"

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/gh-retry-network-test"
  mkdir -p "$TEST_TMPDIR"

  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
  export GH_RETRY_SH
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ===========================================================================
# Transport-error retry in gh_safe
# ===========================================================================

@test "gh_safe retries on 'read: operation timed out' and succeeds on later attempt" {
  local attempt_file="$TEST_TMPDIR/attempts-timeout"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'Post "https://api.github.com/graphql": read tcp 10.0.0.1:52345->140.82.114.6:443: read: operation timed out' >&2
  exit 1
fi
echo '{"title":"Recovered PR"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Recovered PR" ]]
  # Verified it retried: attempt file should read 2
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on 'connection reset by peer' and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-connreset"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'read tcp: connection reset by peer' >&2
  exit 1
fi
echo '{"number":42}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json number)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "42" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on 'dial tcp' error and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-dialtcp"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'dial tcp 140.82.114.6:443: connect: connection refused' >&2
  exit 1
fi
echo '{"title":"PR back"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "PR back" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on 'i/o timeout' and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-iotimeout"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'dial tcp: i/o timeout' >&2
  exit 1
fi
echo '{"title":"Recovered"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Recovered" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on 'unexpected EOF' and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-eof"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'unexpected EOF' >&2
  exit 1
fi
echo '{"title":"Back"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Back" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on gh DNS failure output ('error connecting to') and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-dns"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'error connecting to api.github.com' >&2
  echo 'check your internet connection' >&2
  exit 1
fi
echo '{"title":"DNS recovered"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "DNS recovered" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on ': EOF' (mid-response connection close) and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-eof-bare"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'read tcp 10.0.0.1:52345->140.82.114.6:443: read: EOF' >&2
  exit 1
fi
echo '{"title":"EOF recovered"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "EOF recovered" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe retries on 'context deadline exceeded' (client timeout) and succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts-deadline"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 2 ]; then
  echo 'Post "https://api.github.com/graphql": context deadline exceeded' >&2
  exit 1
fi
echo '{"title":"Deadline recovered"}'
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    result=\$(gh_safe pr view 42 --json title)
    echo \"\$result\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Deadline recovered" ]]
  [ "$(cat "$attempt_file")" = "2" ]
}

@test "gh_safe exhausts transport-error retries and returns non-zero on persistent timeout" {
  local attempt_file="$TEST_TMPDIR/attempts-exhaust"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
echo 'read: operation timed out' >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title
  "

  [ "$status" -ne 0 ]
  # Must have been called exactly RITE_GH_MAX_RETRIES times (all retries exhausted)
  [ "$(cat "$attempt_file")" = "3" ]
}

# ===========================================================================
# Non-transient errors are NOT retried (auth failure)
# ===========================================================================

@test "gh_safe does NOT retry auth failure — called exactly once" {
  local call_count_file="$TEST_TMPDIR/auth-call-count"
  echo "0" > "$call_count_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$call_count_file")
count=\$((count + 1))
echo "\$count" > "$call_count_file"
echo "You are not logged into any GitHub host. Run gh auth login and try again." >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  export RITE_GH_MAX_RETRIES=3
  export RITE_GH_RETRY_MAX_SLEEP=0

  run bash -c "
    export PATH='$STUB_BIN:$PATH'
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr view 42 --json title || true
    echo \"calls:\$(cat '$call_count_file')\"
  "

  [ "$status" -eq 0 ]
  # Must have been called exactly once — auth failure is non-transient
  [[ "$output" =~ "calls:1" ]]
}

# ===========================================================================
# Fix-mode fetch: network error vs genuine absence (structural assert)
#
# We verify that claude-workflow.sh carries both distinct paths in its source code:
#   1. _fetch_exit capture pattern — gh_safe non-zero exit → "network error" message
#   2. Genuine-absence check — empty result (gh_safe exit 0 + empty) → "No assessment found"
# This is a structural pin rather than a full behavioral test because exercising
# FIX_REVIEW_MODE requires wiring the entire claude-workflow environment.
# ===========================================================================

@test "fix-mode fetch uses _fetch_exit capture pattern (not bare || true)" {
  local workflow_file="$PROJECT_ROOT/lib/core/claude-workflow.sh"

  # The capture pattern must exist: assignment then || _fetch_exit=$?
  run grep -c "_fetch_exit=0" "$workflow_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  run grep -c "_fetch_exit=\$?" "$workflow_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "fix-mode fetch emits error message with exit code on non-zero gh_safe exit" {
  local workflow_file="$PROJECT_ROOT/lib/core/claude-workflow.sh"

  # Message must include the exit code and a re-run directive; "network error" attribution
  # was removed (#1188) because gh_safe also returns non-zero for auth failures and
  # malformed --jq, making "network error" misleading for non-retriable failures.
  run grep -c "Failed to fetch assessment.*exit.*re-run to retry" "$workflow_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "fix-mode genuine-absence check is separate from fetch-error path" {
  local workflow_file="$PROJECT_ROOT/lib/core/claude-workflow.sh"

  # "No assessment found" message must still exist for the genuine-absence case
  run grep -c "No assessment found" "$workflow_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  # The network-error message must be a distinct string
  run grep -c "Failed to fetch assessment" "$workflow_file"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
