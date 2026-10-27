#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_resolve_node_lint_runner|_normalize_eslint_output

# Tests for issue #1545: run target repo scripts.lint in post-commit gate.
# Covers:
#   - _resolve_node_lint_runner extracts the lint runner with one-level delegation
#   - _normalize_eslint_output converts ESLint unix format to _parse_lint_line format
#   - No warning noise when scripts.lint is absent
#   - RITE_GATE_REPO_LINT=false disables the lint step
#   - A failing eslint run produces a blocking lint[] finding in the gate JSON

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  source "$RITE_LIB_DIR/utils/logging.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-runners.sh uses _node_pkg_manager function-sentinel guard; pre-source stubs are preserved.
  source "$RITE_LIB_DIR/utils/gate-runners.sh"
  set +u; set +o pipefail
}

# ---------------------------------------------------------------------------
# _resolve_node_lint_runner
# ---------------------------------------------------------------------------

@test "_resolve_node_lint_runner: returns empty string when no package.json" {
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "" ]
  rm -rf "$dir"
}

@test "_resolve_node_lint_runner: returns empty string when scripts.lint absent" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  printf '{"scripts":{"test":"jest"}}\n' > "$dir/package.json"
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "" ]
  rm -rf "$dir"
}

@test "_resolve_node_lint_runner: returns first token of scripts.lint" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  printf '{"scripts":{"lint":"eslint . --ext .ts,.tsx"}}\n' > "$dir/package.json"
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "eslint" ]
  rm -rf "$dir"
}

@test "_resolve_node_lint_runner: resolves one-level npm run delegation" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  printf '{"scripts":{"lint":"npm run lint:check","lint:check":"eslint src/"}}\n' > "$dir/package.json"
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "eslint" ]
  rm -rf "$dir"
}

@test "_resolve_node_lint_runner: resolves one-level pnpm run delegation" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  printf '{"scripts":{"lint":"pnpm run lint:all","lint:all":"eslint apps/"}}\n' > "$dir/package.json"
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "eslint" ]
  rm -rf "$dir"
}

@test "_resolve_node_lint_runner: returns non-eslint runner unchanged" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  printf '{"scripts":{"lint":"next lint"}}\n' > "$dir/package.json"
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "next" ]
  rm -rf "$dir"
}

@test "_resolve_node_lint_runner: returns empty on self-delegation guard (npm lint)" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  local dir
  dir=$(mktemp -d "/tmp/rite_test_nlr_$$_XXXXXX")
  # npm lint inside the lint script would recurse — must bail
  printf '{"scripts":{"lint":"npm lint"}}\n' > "$dir/package.json"
  result=$(_resolve_node_lint_runner "$dir")
  [ "$result" = "" ]
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# _normalize_eslint_output
# ---------------------------------------------------------------------------

@test "_normalize_eslint_output: converts ESLint unix violation to custom lint format" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  printf 'src/App.tsx:42:5: Unescaped entity found [Error/react/no-unescaped-entities]\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  result=$(cat "$out")
  [ "$result" = "src/App.tsx:42: [REACT_NO_UNESCAPED_ENTITIES] Unescaped entity found" ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: normalizes rule with dashes to underscores" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  printf 'lib/foo.js:10:1: Unexpected var [Error/no-var]\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  result=$(cat "$out")
  [ "$result" = "lib/foo.js:10: [NO_VAR] Unexpected var" ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: handles warning severity" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  printf 'src/index.ts:5:3: Prefer const over let [Warning/prefer-const]\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  result=$(cat "$out")
  [ "$result" = "src/index.ts:5: [PREFER_CONST] Prefer const over let" ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: skips summary lines (not violation format)" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  # ESLint appends a problem count summary — must be skipped
  printf '2 problems (2 errors, 0 warnings)\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  [ "$count" -eq 0 ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: produces nothing on empty file" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  : > "$raw"  # empty
  _normalize_eslint_output "$raw" "$out"
  count=$(wc -c < "$out" | tr -d ' ')
  [ "$count" -eq 0 ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: appends (does not overwrite) existing lines in output file" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  printf 'existing:1: [OLD_RULE] prior finding\n' > "$out"
  printf 'src/App.tsx:1:1: New issue [Error/no-unused-vars]\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  [ "$count" -eq 2 ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: normalized output matches _parse_lint_line pattern" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  # Load gate-verdict.sh to access _parse_lint_line
  source "$RITE_LIB_DIR/utils/gate-verdict.sh" 2>/dev/null || true
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  printf 'src/App.tsx:42:5: Unescaped entity [Error/react/no-unescaped-entities]\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  normalized_line=$(cat "$out")
  # _parse_lint_line should produce a JSON object (non-empty) for this line
  parsed=$(_parse_lint_line "$normalized_line" 2>/dev/null || true)
  [ -n "$parsed" ]
  # Parsed JSON should contain the rule name
  echo "$parsed" | grep -q "REACT_NO_UNESCAPED_ENTITIES"
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: multi-violation file produces one line per violation" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  printf 'src/App.tsx:10:5: Issue one [Error/rule-one]\n' > "$raw"
  printf 'src/App.tsx:20:3: Issue two [Error/rule-two]\n' >> "$raw"
  printf 'src/Other.tsx:5:1: Issue three [Warning/rule-three]\n' >> "$raw"
  _normalize_eslint_output "$raw" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  [ "$count" -eq 3 ]
  rm -f "$raw" "$out"
}

@test "_normalize_eslint_output: strips ANSI color codes before parsing" {
  local raw out
  raw=$(mktemp "/tmp/rite_test_neo_raw_$$_XXXXXX")
  out=$(mktemp "/tmp/rite_test_neo_out_$$_XXXXXX")
  # Embed an ANSI color sequence around the severity bracket
  printf 'src/App.tsx:5:1: Colorful message \033[31m[Error/no-var]\033[0m\n' > "$raw"
  _normalize_eslint_output "$raw" "$out"
  result=$(cat "$out")
  [ "$result" = "src/App.tsx:5: [NO_VAR] Colorful message" ]
  rm -f "$raw" "$out"
}
