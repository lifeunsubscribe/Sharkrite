#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/42-producer-pipe-to-grep-q.sh, tools/sharkrite-lint.sh
#
# Tests for Rule 42: PRODUCER_PIPE_TO_GREP_Q
#
# Bug class: Under set -o pipefail, `echo "$VAR" | grep -q` returns exit 141
# when grep exits on its first match before the producer finishes writing. The
# still-writing echo receives SIGPIPE → exit 141, which pipefail propagates as
# "no match". Fix: use a here-string (<<< "$VAR") which has no producer process.
#
# Fixture strategy: .sh fixtures injected via RITE_LINT_EXTRA_DIRS (SHELL_FILES scan).

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
# Positive detections
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
check_flag() {
  local flag="$1"
  if echo "$flag" | grep -qE '^[a-z]+$'; then
    echo "valid"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\${VAR}\" | grep -qiE" {
  cat > "$SH_DIR/bad-echo-braces.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_output() {
  if echo "${error_output}" | grep -qiE "rate.?limit"; then
    echo "rate limited"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on printf '%s\n' \"\$VAR\" | grep -q" {
  cat > "$SH_DIR/bad-printf.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_set() {
  local set="$1"
  if printf '%s\n' "$set" | grep -qxF "value"; then
    echo "in set"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\$VAR\" | grep -iqE (flag order not starting with q)" {
  cat > "$SH_DIR/bad-echo-iq.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
detect_category() {
  local text="$1"
  if echo "$text" | grep -iqE '(fix|bug|issue|error)'; then
    echo "fix"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on printf '%s' \"\$VAR\" | grep -q (printf without newline)" {
  cat > "$SH_DIR/bad-printf-no-newline.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_trusted() {
  local content="$1"
  if printf '%s' "$content" | grep -q "has not been trusted"; then
    echo "untrusted"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\${VAR:-}\" | grep -q (default form)" {
  cat > "$SH_DIR/bad-echo-default.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_optional() {
  if echo "${body:-}" | grep -qE "pattern"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

# ---------------------------------------------------------------------------
# Negative cases: should NOT fire
# ---------------------------------------------------------------------------

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on command producer (git | grep -q)" {
  cat > "$SH_DIR/good-cmd-producer.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_log() {
  if git log --oneline | grep -q "pattern"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on here-string form" {
  cat > "$SH_DIR/good-herestring.sh" <<'EOF'
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
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on a full-line comment" {
  cat > "$SH_DIR/good-comment.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# BAD: echo "$VAR" | grep -q "pattern" — use here-strings instead
check() { true; }
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire when suppression comment precedes the line" {
  cat > "$SH_DIR/good-suppressed.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_meta() {
  local line="$1"
  # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: intentional for meta-test
  if echo "$line" | grep -q "pattern"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on echo with literal string (no \$)" {
  cat > "$SH_DIR/good-literal.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check() {
  if echo "some constant string" | grep -q "constant"; then
    echo "found"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Codebase state
# ---------------------------------------------------------------------------

@test "PRODUCER_PIPE_TO_GREP_Q: the real lib/bin/tools tree is clean" {
  cd "$RITE_REPO_ROOT"
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "A lib/bin/tools file uses echo/printf piped to grep -q (SIGPIPE risk under pipefail):"
    echo "$output"
    false
  }
}
