#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/config.sh
# tests/test_utils/test_config_parser.bats
# Tests for parse_rite_config() - strict KEY=VALUE parser

setup() {
  # Create temp directory for test configs
  TEST_TEMP_DIR="$(mktemp -d)"

  # Export required variables for config.sh
  export RITE_PROJECT_ROOT="$BATS_TEST_DIRNAME/../.."
  export RITE_PROJECT_NAME="sharkrite-test"
  export RITE_INSTALL_DIR="${HOME}/.rite"
}

teardown() {
  # Clean up temp files
  rm -rf "$TEST_TEMP_DIR"
  rm -f /tmp/sharkrite-config-rce
}

# Helper: Source just the parse_rite_config function
load_parser() {
  # Extract and source the parse_rite_config function from config.sh
  eval "$(sed -n '/^parse_rite_config() {/,/^}/p' "$RITE_PROJECT_ROOT/lib/utils/config.sh")"
}

@test "parse_rite_config prevents command execution via backticks" {
  load_parser

  cat > "$TEST_TEMP_DIR/malicious.conf" << 'EOF'
BAD_KEY=`touch /tmp/sharkrite-config-rce`
EOF

  parse_rite_config "$TEST_TEMP_DIR/malicious.conf"

  [ ! -f /tmp/sharkrite-config-rce ]
}

@test "parse_rite_config prevents command execution via dollar-paren" {
  load_parser

  cat > "$TEST_TEMP_DIR/malicious.conf" << 'EOF'
WORSE_KEY=$(touch /tmp/sharkrite-config-rce)
EOF

  parse_rite_config "$TEST_TEMP_DIR/malicious.conf"

  [ ! -f /tmp/sharkrite-config-rce ]
}

@test "parse_rite_config prevents command execution via semicolon" {
  load_parser

  cat > "$TEST_TEMP_DIR/malicious.conf" << 'EOF'
EVIL_KEY=value; touch /tmp/sharkrite-config-rce
EOF

  parse_rite_config "$TEST_TEMP_DIR/malicious.conf"

  [ ! -f /tmp/sharkrite-config-rce ]
}

@test "parse_rite_config strips double quotes from values" {
  load_parser

  cat > "$TEST_TEMP_DIR/quotes.conf" << 'EOF'
DOUBLE_QUOTED="value with spaces"
EOF

  parse_rite_config "$TEST_TEMP_DIR/quotes.conf"

  [ "$DOUBLE_QUOTED" = "value with spaces" ]
}

@test "parse_rite_config strips single quotes from values" {
  load_parser

  cat > "$TEST_TEMP_DIR/quotes.conf" << 'EOF'
SINGLE_QUOTED='another value'
EOF

  parse_rite_config "$TEST_TEMP_DIR/quotes.conf"

  [ "$SINGLE_QUOTED" = "another value" ]
}

@test "parse_rite_config handles unquoted values" {
  load_parser

  cat > "$TEST_TEMP_DIR/simple.conf" << 'EOF'
SIMPLE_VALUE=test123
EOF

  parse_rite_config "$TEST_TEMP_DIR/simple.conf"

  [ "$SIMPLE_VALUE" = "test123" ]
}

@test "parse_rite_config ignores lowercase variable names" {
  load_parser

  cat > "$TEST_TEMP_DIR/invalid.conf" << 'EOF'
lowercase_key=should_be_ignored
VALID_KEY=should_work
EOF

  parse_rite_config "$TEST_TEMP_DIR/invalid.conf"

  [ -z "${lowercase_key:-}" ]
  [ "$VALID_KEY" = "should_work" ]
}

@test "parse_rite_config ignores comment lines" {
  load_parser

  cat > "$TEST_TEMP_DIR/comments.conf" << 'EOF'
# This is a comment
VALID_KEY=value
  # Indented comment
ANOTHER_KEY=value2
EOF

  parse_rite_config "$TEST_TEMP_DIR/comments.conf"

  [ "$VALID_KEY" = "value" ]
  [ "$ANOTHER_KEY" = "value2" ]
}

@test "parse_rite_config ignores shell commands" {
  load_parser

  cat > "$TEST_TEMP_DIR/commands.conf" << 'EOF'
echo "This should not execute"
if [ -f /tmp/test ]; then echo "bad"; fi
VALID_KEY=value
EOF

  parse_rite_config "$TEST_TEMP_DIR/commands.conf"

  [ "$VALID_KEY" = "value" ]
}

@test "parse_rite_config handles empty file" {
  load_parser

  touch "$TEST_TEMP_DIR/empty.conf"

  # Should not error
  parse_rite_config "$TEST_TEMP_DIR/empty.conf"
}

@test "parse_rite_config handles nonexistent file" {
  load_parser

  # Should not error
  parse_rite_config "$TEST_TEMP_DIR/does-not-exist.conf"
}

@test "parse_rite_config handles complex quoted values" {
  load_parser

  cat > "$TEST_TEMP_DIR/complex.conf" << 'EOF'
COMPLEX_VALUE="value with 'single quotes' inside"
ANOTHER_COMPLEX='value with "double quotes" inside'
EOF

  parse_rite_config "$TEST_TEMP_DIR/complex.conf"

  [ "$COMPLEX_VALUE" = "value with 'single quotes' inside" ]
  [ "$ANOTHER_COMPLEX" = 'value with "double quotes" inside' ]
}

@test "parse_rite_config loads real .rite/config" {
  load_parser

  # Test with the actual project config
  if [ -f "$RITE_PROJECT_ROOT/.rite/config" ]; then
    parse_rite_config "$RITE_PROJECT_ROOT/.rite/config"

    # Verify expected keys are set
    [ -n "${RITE_TEST_CMD:-}" ]
    [ -n "${RITE_PROJECT_CONTEXT:-}" ]
    [ -n "${RITE_PLAN_DOCS:-}" ]
  else
    skip "No .rite/config found"
  fi
}

@test "parse_rite_config exports variables" {
  load_parser

  cat > "$TEST_TEMP_DIR/export.conf" << 'EOF'
EXPORT_TEST=exported_value
EOF

  parse_rite_config "$TEST_TEMP_DIR/export.conf"

  # Run in subshell to verify it's exported
  result=$(bash -c 'echo "$EXPORT_TEST"')
  [ "$result" = "exported_value" ]
}

@test "parse_rite_config handles values with equals signs" {
  load_parser

  cat > "$TEST_TEMP_DIR/equals.conf" << 'EOF'
BASE64_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0=
URL_WITH_QUERY="https://example.com/api?key=value&foo=bar"
MULTIPLE_EQUALS=a=b=c=d
EOF

  parse_rite_config "$TEST_TEMP_DIR/equals.conf"

  [ "$BASE64_TOKEN" = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0=" ]
  [ "$URL_WITH_QUERY" = "https://example.com/api?key=value&foo=bar" ]
  [ "$MULTIPLE_EQUALS" = "a=b=c=d" ]
}

@test "parse_rite_config handles malformed quotes - empty string" {
  load_parser

  cat > "$TEST_TEMP_DIR/malformed.conf" << 'EOF'
EMPTY_QUOTED=""
EOF

  parse_rite_config "$TEST_TEMP_DIR/malformed.conf"

  # Empty string should be preserved correctly
  [ "$EMPTY_QUOTED" = "" ]
}

@test "parse_rite_config handles malformed quotes - single quote" {
  load_parser

  cat > "$TEST_TEMP_DIR/malformed.conf" << 'EOF'
SINGLE_QUOTE="
EOF

  parse_rite_config "$TEST_TEMP_DIR/malformed.conf"

  # Single quote should be kept as-is (not matched by regex)
  [ "$SINGLE_QUOTE" = '"' ]
}

@test "parse_rite_config handles malformed quotes - triple quotes" {
  load_parser

  cat > "$TEST_TEMP_DIR/malformed.conf" << 'EOF'
TRIPLE_QUOTED="""
EOF

  parse_rite_config "$TEST_TEMP_DIR/malformed.conf"

  # Triple quotes: outer pair stripped, middle one preserved
  [ "$TRIPLE_QUOTED" = '"' ]
}

@test "parse_rite_config handles malformed quotes - mismatched quotes" {
  load_parser

  cat > "$TEST_TEMP_DIR/malformed.conf" << 'EOF'
MISMATCHED="value'
EOF

  parse_rite_config "$TEST_TEMP_DIR/malformed.conf"

  # Mismatched quotes: regex won't match, kept as-is
  [ "$MISMATCHED" = '"value'"'"'' ]
}
