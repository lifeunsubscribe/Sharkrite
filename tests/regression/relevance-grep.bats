#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/relevance-grep.sh
#
# Regression tests for relevance_grep() in lib/utils/relevance-grep.sh.
#
# relevance_grep(ISSUE_TEXT, [PROJECT_ROOT]) scans issue body text for:
#   - file paths    [a-zA-Z0-9_/][a-zA-Z0-9_/-]*\.(sh|md|conf|bats)
#   - `func()`      backticked function-call symbols
#   - `$VAR`        backticked env-var symbols
# greps each under PROJECT_ROOT/{lib,bin} (top-3 hits per symbol) and emits
#   Existing usages of `X`:
#     - file:line
# blocks. Returns empty + exit 0 on empty text / no hits (never fails).
#
# Tests:
#   1. extracts a file path and emits a usage block (lib/bin only, top-3)
#   2. extracts `foo()` and `$VAR` symbols and emits usage blocks
#   3. only lib/ and bin/ are searched (matches outside are ignored)
#   4. empty ISSUE_TEXT → empty output, exit 0
#   5. no matching symbols / no hits → empty output, exit 0
#   6. #774/#776: a target file whose ONLY lib/bin occurrence is its own
#      header-comment self-reference is NOT surfaced as its own "existing usage"
#   7. re-source safety: sourcing the file twice under set -euo pipefail exits 0

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export PROJ="$RITE_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/lib/utils" "$PROJ/lib/core" "$PROJ/bin" "$PROJ/docs"
  source "${RITE_REPO_ROOT}/lib/utils/relevance-grep.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# 1. File-path extraction → usage block
# ---------------------------------------------------------------------------
@test "file path in issue text emits an Existing usages block" {
  cat > "$PROJ/lib/core/workflow-runner.sh" <<'EOF'
#!/bin/bash
source "$RITE_LIB_DIR/utils/timeout.sh"
ensure_timeout_cmd
EOF

  run relevance_grep 'Modify the runner to call timeout.sh helpers.' "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Existing usages of `timeout.sh`:'* ]]
  [[ "$output" == *'lib/core/workflow-runner.sh:2'* ]]
}

# ---------------------------------------------------------------------------
# 2. Backticked `foo()` and `$VAR` symbol extraction → usage blocks
# ---------------------------------------------------------------------------
@test "backticked func() and \$VAR symbols emit usage blocks" {
  cat > "$PROJ/lib/utils/timeout.sh" <<'EOF'
#!/bin/bash
ensure_timeout_cmd() {
  : "$RITE_TIMEOUT_BIN"
}
EOF

  run relevance_grep 'The fix should call `ensure_timeout_cmd()` and read `$RITE_TIMEOUT_BIN`.' "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Existing usages of `ensure_timeout_cmd()`:'* ]]
  [[ "$output" == *'Existing usages of `$RITE_TIMEOUT_BIN`:'* ]]
  [[ "$output" == *'lib/utils/timeout.sh:'* ]]
}

# ---------------------------------------------------------------------------
# 3. Only lib/ and bin/ are searched (top-3 cap, no docs/)
# ---------------------------------------------------------------------------
@test "search is confined to lib and bin and capped at 3 hits" {
  # A matching reference in docs/ must be ignored.
  echo 'mentions helper.sh' > "$PROJ/docs/notes.md"
  # Four lib references — output must keep at most 3.
  cat > "$PROJ/lib/utils/a.sh" <<'EOF'
# uses helper.sh
# uses helper.sh
# uses helper.sh
# uses helper.sh
EOF

  run relevance_grep 'See helper.sh for details.' "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Existing usages of `helper.sh`:'* ]]
  # docs/ never appears
  [[ "$output" != *'docs/notes.md'* ]]
  # at most 3 "  - file:line" hit lines for this symbol
  hit_count=$(printf '%s' "$output" | grep -c '^  - ' || true)
  [ "$hit_count" -le 3 ]
  [ "$hit_count" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 4. Empty ISSUE_TEXT → empty output, exit 0
# ---------------------------------------------------------------------------
@test "empty issue text returns empty output and exit 0" {
  run relevance_grep '' "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 5. No matching symbols / no hits → empty output, exit 0
# ---------------------------------------------------------------------------
@test "text with no recognizable symbols returns empty output and exit 0" {
  run relevance_grep 'Just some prose with nothing to grep for here.' "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "symbol with no lib/bin hits returns empty output and exit 0" {
  run relevance_grep 'Reference to nonexistent-thing.sh that is nowhere.' "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 6. #774/#776 regression: self-referential header comment is NOT surfaced
# ---------------------------------------------------------------------------
@test "#774/#776: target file's own header-comment self-reference is not listed as its own usage" {
  # The file the issue intends to MODIFY. Its ONLY lib/bin occurrence is its
  # own self-naming header comment on line 2.
  cat > "$PROJ/lib/utils/target.sh" <<'EOF'
#!/bin/bash
# lib/utils/target.sh — does a thing
do_thing() {
  echo hi
}
EOF

  run relevance_grep 'Modify lib/utils/target.sh to do the thing better.' "$PROJ"
  [ "$status" -eq 0 ]
  # The self-naming header comment must NOT be surfaced as prior art.
  [[ "$output" != *'Existing usages of `lib/utils/target.sh`:'* ]]
  [[ "$output" != *'lib/utils/target.sh:2'* ]]
  # With no other reference, output for this symbol is empty.
  [ -z "$output" ]
}

@test "#774/#776: genuine cross-file usage IS still surfaced even when target self-references" {
  cat > "$PROJ/lib/utils/target.sh" <<'EOF'
#!/bin/bash
# lib/utils/target.sh — does a thing
do_thing() { echo hi; }
EOF
  # A genuine prior-art reference from another file must still appear.
  cat > "$PROJ/lib/core/caller.sh" <<'EOF'
#!/bin/bash
source "$RITE_PROJECT_ROOT/lib/utils/target.sh"
EOF

  run relevance_grep 'Modify lib/utils/target.sh.' "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Existing usages of `lib/utils/target.sh`:'* ]]
  [[ "$output" == *'lib/core/caller.sh:2'* ]]
  # The self-reference line is still filtered out.
  [[ "$output" != *'lib/utils/target.sh:2'* ]]
}

# ---------------------------------------------------------------------------
# 7. Re-source safety (double-source under set -euo pipefail)
# ---------------------------------------------------------------------------
@test "sourcing relevance-grep.sh twice under set -euo pipefail exits 0" {
  run bash -c "set -euo pipefail
    source '${RITE_REPO_ROOT}/lib/utils/relevance-grep.sh'
    source '${RITE_REPO_ROOT}/lib/utils/relevance-grep.sh'
    echo DOUBLE_SOURCE_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'DOUBLE_SOURCE_OK'* ]]
}
