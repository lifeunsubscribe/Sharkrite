#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/39H-bsd-lenient-regex.sh, tools/sharkrite-lint.sh
#
# Tests for Rule 39H: BSD_LENIENT_REGEX
#
# Sub-check A: \s inside a grep/awk/sed regex argument.
#   BSD reads \s as literal 's'; GNU reads it as whitespace shorthand.
#   A test using \s passes on macOS (dev box) while testing nothing useful,
#   or strips only lines starting with literal 's'.
#   Fix: use [[:space:]] (POSIX character class, both platforms).
#
# Sub-check B: \` inside a single-quoted grep argument.
#   GNU grep treats \` as a beginning-of-buffer anchor; BSD reads a plain
#   backtick.  Consequence: assertions pass on macOS and fail on Linux CI.
#   Fix: remove the backslash — write '```bash' not '\`\`\`bash'.
#
# Fixture strategy:
#   .sh fixtures → inject via RITE_LINT_EXTRA_DIRS (SHELL_FILES scan)
#   .bats fixtures → write into $FIXTURE_DIR/tests/ and cd there before
#     running the linter, so `find tests -name '*.bats'` finds them.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  FIXTURE_DIR=$(mktemp -d)
  SH_DIR="${FIXTURE_DIR}/extra-sh"
  mkdir -p "$SH_DIR"
  mkdir -p "$FIXTURE_DIR/tests/regression" "$FIXTURE_DIR/tests/fixtures"
  export RITE_LINT_EXTRA_DIRS="$SH_DIR"
}

teardown() {
  unset RITE_LINT_EXTRA_DIRS
  rm -rf "$FIXTURE_DIR"
}

# ---------------------------------------------------------------------------
# Sub-check A — .sh files via RITE_LINT_EXTRA_DIRS
# ---------------------------------------------------------------------------

@test "BSD_LENIENT_REGEX A: fires on \\s in grep -qE in a .sh file" {
  cat > "$SH_DIR/bad-grep.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
strip_comments() {
  grep -vE '^\s*#' "$1"
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BSD_LENIENT_REGEX"* ]]
  [[ "$output" == *"bad-grep.sh"* ]]
}

@test "BSD_LENIENT_REGEX A: fires on \\s in awk pattern in a .sh file" {
  cat > "$SH_DIR/bad-awk.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
count_leading() {
  echo "$1" | awk '/^\s+foo/ { print NR }'
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BSD_LENIENT_REGEX"* ]]
}

@test "BSD_LENIENT_REGEX A: fires on \\s in sed pattern in a .sh file" {
  cat > "$SH_DIR/bad-sed.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
strip_leading() {
  echo "$1" | sed 's/^\s*//'
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BSD_LENIENT_REGEX"* ]]
}

@test "BSD_LENIENT_REGEX A: does NOT fire on [[:space:]] in grep (POSIX form)" {
  cat > "$SH_DIR/good-posix.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
strip_comments() {
  grep -vE '^[[:space:]]*#' "$1"
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BSD_LENIENT_REGEX A: does NOT fire on a full-line comment containing \\s" {
  cat > "$SH_DIR/commented.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# grep -qE '^\s*#' is non-portable; use [[:space:]] instead
do_thing() { true; }
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BSD_LENIENT_REGEX A: does NOT fire when suppression comment precedes the line" {
  cat > "$SH_DIR/suppressed.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
strip_comments() {
  # sharkrite-lint disable BSD_LENIENT_REGEX - Reason: third-party tool, cannot change
  grep -vE '^\s*#' "$1"
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BSD_LENIENT_REGEX A: does NOT fire on grep inside an echo string" {
  # echo describing a pattern is not a grep command; \s inside the
  # double-quoted string is stripped by _r39h_strip_quoted before the
  # grep/awk/sed command-position check.
  cat > "$SH_DIR/echo-desc.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
explain() {
  echo "the dep-guard uses grep -qE '^\s*:'"
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Sub-check A — .bats files via cd + find tests
# ---------------------------------------------------------------------------

@test "BSD_LENIENT_REGEX A: fires on \\s in grep inside a .bats file" {
  cat > "$FIXTURE_DIR/tests/regression/bad.bats" <<'EOF'
#!/usr/bin/env bats
@test "strip comments" {
  run grep -vE '^\s*#' "$TARGET"
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BSD_LENIENT_REGEX"* ]]
  [[ "$output" == *"bad.bats"* ]]
}

@test "BSD_LENIENT_REGEX A: does NOT fire on .bats file in tests/fixtures/" {
  # tests/fixtures/ is excluded from scanning to avoid flagging fixture strings.
  cat > "$FIXTURE_DIR/tests/fixtures/sample.bats" <<'EOF'
#!/usr/bin/env bats
@test "x" { grep -qE '^\s*#' file; }
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BSD_LENIENT_REGEX A: does NOT fire on suppressed .bats line" {
  cat > "$FIXTURE_DIR/tests/regression/suppressed.bats" <<'EOF'
#!/usr/bin/env bats
@test "meta check" {
  # sharkrite-lint disable BSD_LENIENT_REGEX - Reason: fixture STRING describing the bad form; not executed
  local bad_pattern='^\s*#'
  run grep -vE "$bad_pattern" file
  [ "$status" -eq 0 ]
}
EOF
  cd "$FIXTURE_DIR"
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Sub-check B — \` in single-quoted grep argument
# ---------------------------------------------------------------------------

@test "BSD_LENIENT_REGEX B: fires on \\` inside a single-quoted grep pattern" {
  cat > "$SH_DIR/bad-backtick.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
detect_fence() {
  grep -q '^\`\`\`bash' "$1"
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BSD_LENIENT_REGEX"* ]]
  [[ "$output" == *"bad-backtick.sh"* ]]
}

@test "BSD_LENIENT_REGEX B: does NOT fire when suppression precedes the backtick line" {
  cat > "$SH_DIR/suppressed-bt.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
detect_fence() {
  # sharkrite-lint disable BSD_LENIENT_REGEX - Reason: BSD grep only, not in CI path
  grep -q '^\`\`\`bash' "$1"
}
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "BSD_LENIENT_REGEX B: does NOT fire on a full-line comment containing backtick" {
  cat > "$SH_DIR/commented-bt.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# was: grep -q '^\`\`\`bash' — now use '```bash'
detect_fence() { true; }
EOF
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Codebase state
# ---------------------------------------------------------------------------

@test "BSD_LENIENT_REGEX: the real lib/bin/tools tree is clean" {
  cd "$RITE_REPO_ROOT"
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "A lib/bin/tools file uses a BSD-lenient regex idiom that breaks on GNU/Linux:"
    echo "$output"
    false
  }
}

@test "BSD_LENIENT_REGEX: the real tests/ tree is clean" {
  cd "$RITE_REPO_ROOT"
  # Run without RITE_LINT_EXTRA_DIRS so only real project files are scanned.
  unset RITE_LINT_EXTRA_DIRS
  SHARKRITE_LINT_ONLY=39H run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "A .bats file uses a BSD-lenient regex idiom that breaks on GNU/Linux:"
    echo "$output"
    false
  }
}
