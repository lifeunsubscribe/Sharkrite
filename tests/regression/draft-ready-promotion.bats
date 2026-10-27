#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/create-pr.sh, lib/utils/gh-retry.sh
# Regression test for: Retry and hard-fail draft-ready promotion (#1527)
#
# Bug history (2026-10-26, doc-sync batch, issue #1432):
#   `gh_safe pr ready "$PR_NUMBER" 2>/dev/null || print_warning` swallowed
#   the error and continued. The PR stayed draft; merge gate refused it 23m
#   later. Root cause: stderr discarded + soft warning = silent non-starter.
#
#   Fix: capture stderr, hard-fail (exit 1) on persistent promotion failure.
#
# Coverage:
#   1. gh_safe pr ready retries transient failures (fail×2, succeed×3)
#   2. Persistent promotion failure propagates gh's stderr and exits non-zero
#   3. First-try promotion success exits 0 (happy path)
#   4. 2>/dev/null swallow removed from draft block (structural)
#   5. print_warning fallback removed — hard exit in its place (structural)
#   6. pr ready call guarded by IS_DRAFT check (non-draft PRs untouched) (structural)

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT

  export TEST_TMPDIR="$BATS_TEST_TMPDIR/draft-ready-test"
  mkdir -p "$TEST_TMPDIR"

  # Stub bin dir: drop fake gh here and prepend to PATH inside run bash -c
  export STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"

  GH_RETRY_SH="$PROJECT_ROOT/lib/utils/gh-retry.sh"
  export GH_RETRY_SH

  CREATE_PR_SH="$PROJECT_ROOT/lib/core/create-pr.sh"
  export CREATE_PR_SH
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. Retry: transient failure ×2, succeed on 3rd attempt
# ---------------------------------------------------------------------------
@test "gh_safe pr ready retries transient failure and eventually succeeds" {
  local attempt_file="$TEST_TMPDIR/attempts"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
if [ "\$count" -lt 3 ]; then
  echo "HTTP 503 Service Unavailable" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_GH_MAX_RETRIES=3
    export RITE_GH_RETRY_MAX_SLEEP=0
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr ready 123
  "

  [ "$status" -eq 0 ]
  [ "$(cat "$attempt_file")" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 2. Persistent failure: gh's stderr surfaces in the caller's stderr
# ---------------------------------------------------------------------------
@test "persistent gh pr ready failure propagates gh stderr and exits non-zero" {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
echo "GraphQL error: Could not resolve to a PullRequest with the number of 999." >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  local err_file="$TEST_TMPDIR/captured_err"

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_GH_MAX_RETRIES=3
    export RITE_GH_RETRY_MAX_SLEEP=0
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr ready 999 2>'$err_file'
  "

  [ "$status" -ne 0 ]
  grep -q "GraphQL error" "$err_file"
}

# ---------------------------------------------------------------------------
# 3. Happy path: first-try promotion exits 0
# ---------------------------------------------------------------------------
@test "gh_safe pr ready succeeds when gh exits 0 on first attempt" {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$STUB_BIN/gh"

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    source '$GH_RETRY_SH'
    gh_safe pr ready 123
  "

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. Retry exhaustion: persistent 503 exhausts all retries, non-zero + stderr
# ---------------------------------------------------------------------------
@test "gh_safe pr ready exhausts RITE_GH_MAX_RETRIES on persistent 503 and propagates stderr" {
  local attempt_file="$TEST_TMPDIR/exhaustion_attempts"
  echo "0" > "$attempt_file"

  cat > "$STUB_BIN/gh" <<EOF
#!/bin/bash
count=\$(cat "$attempt_file")
count=\$((count + 1))
echo "\$count" > "$attempt_file"
echo "HTTP 503 Service Unavailable" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"

  local err_file="$TEST_TMPDIR/exhaustion_err"

  run bash -c "
    export PATH=\"$STUB_BIN:\$PATH\"
    export RITE_GH_MAX_RETRIES=3
    export RITE_GH_RETRY_MAX_SLEEP=0
    source '$GH_RETRY_SH'
    sleep() { :; }
    export -f sleep
    gh_safe pr ready 123 2>'$err_file'
  "

  [ "$status" -ne 0 ]
  [ "$(cat "$attempt_file")" -eq 3 ]
  grep -q "503" "$err_file"
}

# ---------------------------------------------------------------------------
# 5. Structural: 2>/dev/null swallow removed from pr ready call
# ---------------------------------------------------------------------------
@test "create-pr.sh does not swallow pr ready stderr via 2>/dev/null" {
  ! grep -qE 'pr ready.*2>/dev/null' "$CREATE_PR_SH"
}

# ---------------------------------------------------------------------------
# 6. Structural: hard exit replaces print_warning soft fallback
# ---------------------------------------------------------------------------
@test "create-pr.sh draft block no longer uses print_warning for pr ready failure" {
  ! grep -qE 'pr ready[^#]*\|\|[^#]*print_warning' "$CREATE_PR_SH"
}

# ---------------------------------------------------------------------------
# 7. Structural: pr ready guarded by IS_DRAFT — non-draft PRs untouched
# ---------------------------------------------------------------------------
@test "pr ready call in create-pr.sh only appears inside IS_DRAFT block" {
  local prready_line isdraft_line
  prready_line=$(grep -n 'gh_safe pr ready' "$CREATE_PR_SH" | head -1 | cut -d: -f1)
  isdraft_line=$(grep -n 'IS_DRAFT.*true' "$CREATE_PR_SH" | head -1 | cut -d: -f1)
  [ -n "$prready_line" ]
  [ -n "$isdraft_line" ]
  [ "$isdraft_line" -lt "$prready_line" ]
}
