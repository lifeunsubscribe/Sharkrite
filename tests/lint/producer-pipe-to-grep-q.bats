#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/42-producer-pipe-to-grep-q.sh, tools/sharkrite-lint.sh
#
# Tests for Rule 42: PRODUCER_PIPE_TO_GREP_Q
#
# Bug class: Under set -o pipefail, `grep -q` exits on the first match without
# consuming all stdin. The still-writing producer receives SIGPIPE and exits
# non-zero; pipefail propagates that exit, so a successful match becomes exit
# 141 — read as "no match". The fix is to use a here-string (<<< "$VAR")
# which has no producer process and therefore cannot receive SIGPIPE.
#
# Fixture strategy:
#   .sh fixtures → inject via RITE_LINT_EXTRA_DIRS (SHELL_FILES scan)

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
# Positive cases — rule should fire
# ---------------------------------------------------------------------------

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\$VAR\" | grep -q" {
  cat > "$SH_DIR/bad-echo.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_body() {
  local body="$1"
  if echo "$body" | grep -q "pattern"; then
    return 0
  fi
  return 1
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
check_guard() {
  local diff="$1"
  if echo "$diff" | grep -qE '^deleted file mode'; then
    echo "deletion"
  fi
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on echo \"\${VAR}\" | grep -q" {
  cat > "$SH_DIR/bad-echo-braces.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_it() {
  local val="${1:-}"
  if echo "${val}" | grep -q "foo"; then
    return 0
  fi
  return 1
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

@test "PRODUCER_PIPE_TO_GREP_Q: fires on printf '%s\\\n' \"\$VAR\" | grep -q" {
  cat > "$SH_DIR/bad-printf.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_format() {
  local body="$1"
  if printf '%s\n' "$body" | grep -qE "^## Code Review"; then
    return 0
  fi
  return 1
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
check_state() {
  if echo "${PR_STATE:-}" | grep -q "OPEN"; then
    return 0
  fi
  return 1
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRODUCER_PIPE_TO_GREP_Q"* ]]
}

# ---------------------------------------------------------------------------
# Negative cases — rule should NOT fire
# ---------------------------------------------------------------------------

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on command producer (cmd | grep -q)" {
  cat > "$SH_DIR/good-cmd.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_node() {
  if git log --oneline | grep -q "feat:"; then
    return 0
  fi
  return 1
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
    return 0
  fi
  return 1
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on a full-line comment" {
  cat > "$SH_DIR/commented.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# BAD: echo "$body" | grep -q "pattern" — use here-string instead
check_body() { true; }
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire when suppression comment precedes the line" {
  cat > "$SH_DIR/suppressed.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
check_body() {
  local body="$1"
  # sharkrite-lint disable PRODUCER_PIPE_TO_GREP_Q - Reason: intentional for demonstration
  if echo "$body" | grep -q "pattern"; then
    return 0
  fi
  return 1
}
EOF
  SHARKRITE_LINT_ONLY=42 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "PRODUCER_PIPE_TO_GREP_Q: does NOT fire on grep -o (output-or-nothing form)" {
  cat > "$SH_DIR/good-grep-o.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
extract_num() {
  local line="$1"
  echo "$line" | grep -oE '[0-9]+' || echo "0"
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
    echo "A lib/bin/tools file uses a single-variable producer piped into grep -q:"
    echo "$output"
    false
  }
}
