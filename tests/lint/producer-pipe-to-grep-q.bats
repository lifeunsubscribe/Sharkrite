#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/42-producer-pipe-to-grep-q.sh, tools/sharkrite-lint.sh
#
# Tests for Rule 42: PRODUCER_PIPE_TO_GREP_Q
#
# Bug class: Under set -o pipefail, echo "$VAR" | grep -q exits on first
# match; the producer receives SIGPIPE and exits non-zero; pipefail propagates
# that exit, so a successful match returns exit 141 — read as "no match".
#
# Fix: use a here-string — grep -q "pattern" <<< "$VAR" — which has no
# producer process and therefore cannot receive SIGPIPE.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  FIXTURE_DIR=$(mktemp -d)
  SH_DIR="${FIXTURE_DIR}/extra-sh"
  mkdir -p "$SH_DIR"
  export RITE_LINT_EXTRA_DIRS="$SH_DIR"
}

teardown() {
  unset RITE_LINT_EXTRA_DIRS
  rm -rf "$FIXTURE_DIR"
}

# ---------------------------------------------------------------------------
# Should FIRE
# ---------------------------------------------------------------------------

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\$VAR\" | grep -q" {
  cat > "$SH_DIR/bad-echo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_body() {
  local body="$1"
  if echo "$body" | grep -q "pattern"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
  [[ "$output" == *"bad-echo.sh"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\$VAR\" | grep -qE" {
  cat > "$SH_DIR/bad-echo-e.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_error() {
  local err="$1"
  if echo "$err" | grep -qE "rate.?limit|429"; then
    return 1
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\$VAR\" | grep -qiE" {
  cat > "$SH_DIR/bad-echo-ie.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
classify() {
  local output="$1"
  if echo "$output" | grep -qiE "FAILED|error"; then
    echo "failed"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on printf '%s\\n' \"\$VAR\" | grep -q" {
  cat > "$SH_DIR/bad-printf.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
has_title() {
  local titles="$1" candidate="$2"
  if ! printf '%s\n' "$titles" | grep -qxF "$candidate"; then
    return 1
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
  [[ "$output" == *"bad-printf.sh"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\$sha1\" | grep -q (digit in variable name)" {
  cat > "$SH_DIR/bad-digit.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_sha() {
  local sha1="$1"
  if echo "$sha1" | grep -q "^abc"; then
    echo "matched"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on printf '%s\\n' \"\${var:-}\" | grep -q (braced with default)" {
  cat > "$SH_DIR/bad-printf-default.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_title() {
  local title="${1:-}"
  if printf '%s\n' "${title:-}" | grep -q "pattern"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\${VAR:-}\" | grep -q (braced with default)" {
  cat > "$SH_DIR/bad-braced.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_changed() {
  if ! echo "${_changed:-}" | grep -qxF "$_file"; then
    return 0
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

# ---------------------------------------------------------------------------
# Should NOT fire
# ---------------------------------------------------------------------------

@test "PRODUCER_PIPE_TO_GREP_Q: does not fire on command producer (git log | grep -q)" {
  cat > "$SH_DIR/ok-cmd.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_log() {
  if git log --oneline | grep -q "fix"; then
    echo "has fix"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ok-cmd.sh"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does not fire on here-string (already fixed)" {
  cat > "$SH_DIR/ok-herestring.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_body() {
  local body="$1"
  if grep -q "pattern" <<< "$body"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ok-herestring.sh"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does not fire on full-line comment" {
  cat > "$SH_DIR/ok-comment.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# example: echo "$VAR" | grep -q "pattern"  (do not use this)
check_body() {
  if grep -q "pattern" <<< "$1"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ok-comment.sh"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: suppression comment disables the rule" {
  cat > "$SH_DIR/suppressed.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_body() {
  local body="$1"
  # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: test fixture
  if echo "$body" | grep -q "pattern"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"suppressed.sh"* ]]
}
