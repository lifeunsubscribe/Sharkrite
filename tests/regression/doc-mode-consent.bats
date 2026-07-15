#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/doc-consent.sh, bin/rite, lib/utils/config.sh, lib/core/workflow-runner.sh
# tests/regression/doc-mode-consent.bats
#
# Regression tests for #1034: doc-mode consent at init and workflow start.
#
# Tests cover:
#   - record_doc_mode: writes RITE_DOC_MODE to .rite/config (idempotent)
#   - ensure_doc_mode: no-op when mode already set; session-only default in
#     non-TTY/batch/unsupervised contexts; never blocks batch
#   - bin/rite --init wiring: consent question text, scaffold path, map build call
#   - config.sh: empty-default sentinel + export declaration
#   - workflow-runner.sh: ensure_doc_mode called between banner and issue fetch

load '../helpers/setup'

setup() {
  setup_test_tmpdir
  # Point RITE_PROJECT_ROOT at a fixture with the .rite structure needed by tests
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  export RITE_DATA_DIR=".rite"
  mkdir -p "$RITE_PROJECT_ROOT/.rite"
  # Minimal config file for record_doc_mode to write into
  printf '# .rite/config\n' > "$RITE_PROJECT_ROOT/.rite/config"
  # Required by config.sh defaults that fire at source time
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_STATE_DIR"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Library shape and re-source safety
# ---------------------------------------------------------------------------

@test "doc-consent.sh defines ensure_doc_mode and record_doc_mode after source" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    declare -f ensure_doc_mode record_doc_mode >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "doc-consent.sh is double-source safe (idempotent)" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    declare -f ensure_doc_mode record_doc_mode >/dev/null && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# record_doc_mode: write and idempotency
# ---------------------------------------------------------------------------

@test "record_doc_mode sync writes RITE_DOC_MODE=sync to config" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    record_doc_mode sync
    grep -c '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}

@test "record_doc_mode changelog writes RITE_DOC_MODE=changelog to config" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    record_doc_mode changelog
    grep -c '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}

@test "record_doc_mode is idempotent: two calls leave exactly one RITE_DOC_MODE= line" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    record_doc_mode sync
    record_doc_mode changelog
    grep -c '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}

@test "record_doc_mode exports RITE_DOC_MODE in current process" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    record_doc_mode sync
    echo \"\$RITE_DOC_MODE\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync"* ]]
}

@test "record_doc_mode replaces commented-out # RITE_DOC_MODE= line" {
  # Seed with a commented line (as shipped in project.conf.example)
  printf '# RITE_DOC_MODE="changelog"\n' >> "$RITE_PROJECT_ROOT/.rite/config"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    record_doc_mode sync
    grep -c '^RITE_DOC_MODE=' '$RITE_PROJECT_ROOT/.rite/config' || true
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
}

# ---------------------------------------------------------------------------
# ensure_doc_mode: no-op when mode already set
# ---------------------------------------------------------------------------

@test "ensure_doc_mode is a no-op when RITE_DOC_MODE is already set" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export RITE_DOC_MODE=sync
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    ensure_doc_mode
    echo \"mode=\$RITE_DOC_MODE\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=sync"* ]]
  # Config should not be written (still has the minimal header only)
  [ "$(grep -c '^RITE_DOC_MODE=' "$RITE_PROJECT_ROOT/.rite/config" || true)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# ensure_doc_mode: non-TTY context → session-only changelog, no config write
# ---------------------------------------------------------------------------

@test "ensure_doc_mode in non-TTY uses session-only changelog and does not write config" {
  # Redirect stdin from /dev/null to make [ -t 0 ] return false (no TTY)
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export WORKFLOW_MODE=supervised
    export BATCH_MODE=false
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    ensure_doc_mode
    echo \"mode=\$RITE_DOC_MODE\"
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=changelog"* ]]
  # Config must NOT have a RITE_DOC_MODE= line written (session-only)
  [ "$(grep -c '^RITE_DOC_MODE=' "$RITE_PROJECT_ROOT/.rite/config" || true)" -eq 0 ]
}

@test "ensure_doc_mode in batch (BATCH_MODE=true) uses session-only changelog and does not write config" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export WORKFLOW_MODE=supervised
    export BATCH_MODE=true
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    ensure_doc_mode
    echo \"mode=\$RITE_DOC_MODE\"
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=changelog"* ]]
  [ "$(grep -c '^RITE_DOC_MODE=' "$RITE_PROJECT_ROOT/.rite/config" || true)" -eq 0 ]
}

@test "ensure_doc_mode in unsupervised mode uses session-only changelog and does not write config" {
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_PROJECT_ROOT'
    export RITE_DATA_DIR='.rite'
    export RITE_INSTALL_DIR='$RITE_REPO_ROOT'
    export RITE_LIB_DIR='$RITE_REPO_ROOT/lib'
    export WORKFLOW_MODE=unsupervised
    export BATCH_MODE=false
    source '$RITE_REPO_ROOT/lib/utils/doc-consent.sh'
    ensure_doc_mode
    echo \"mode=\$RITE_DOC_MODE\"
  " < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode=changelog"* ]]
  [ "$(grep -c '^RITE_DOC_MODE=' "$RITE_PROJECT_ROOT/.rite/config" || true)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# bin/rite --init wiring: structural pins
# ---------------------------------------------------------------------------

@test "bin/rite init block contains the consent question text" {
  # Structural: exact question wording is an invariant (acceptance criteria)
  count=$(grep -c "May sharkrite update files in docs/ when code changes make them inaccurate" \
    "$RITE_REPO_ROOT/bin/rite" || true)
  [ "$count" -ge 1 ]
}

@test "bin/rite init block calls docs_map_build" {
  count=$(grep -c 'docs_map_build' "$RITE_REPO_ROOT/bin/rite" || true)
  [ "$count" -ge 1 ]
}

@test "bin/rite init block sources doc-consent.sh" {
  grep -q 'doc-consent.sh' "$RITE_REPO_ROOT/bin/rite"
}

@test "bin/rite init block sources docs-map.sh" {
  grep -q 'docs-map.sh' "$RITE_REPO_ROOT/bin/rite"
}

# ---------------------------------------------------------------------------
# config.sh: empty-default sentinel and export
# ---------------------------------------------------------------------------

@test "config.sh declares RITE_DOC_MODE with empty-default sentinel" {
  count=$(grep -c 'RITE_DOC_MODE="${RITE_DOC_MODE:-}"' \
    "$RITE_REPO_ROOT/lib/utils/config.sh" || true)
  [ "$count" -eq 1 ]
}

@test "config.sh exports RITE_DOC_MODE" {
  count=$(grep -cE '^export RITE_DOC_MODE$' \
    "$RITE_REPO_ROOT/lib/utils/config.sh" || true)
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# workflow-runner.sh: ensure_doc_mode placement
# ---------------------------------------------------------------------------

@test "workflow-runner.sh sources doc-consent.sh" {
  grep -q 'doc-consent.sh' "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
}

@test "workflow-runner.sh calls ensure_doc_mode" {
  grep -q 'ensure_doc_mode' "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
}

@test "workflow-runner.sh ensure_doc_mode is called before the issue fetch (gh_safe issue view)" {
  # ensure_doc_mode must appear before the first gh_safe issue view call in run_workflow().
  # Use awk to find line numbers and assert ordering.
  run awk '
    /ensure_doc_mode/ && !found_ensure { ensure_line = NR; found_ensure = 1 }
    /gh_safe issue view/ && !found_gh   { gh_line    = NR; found_gh    = 1 }
    END {
      if (found_ensure && found_gh && ensure_line < gh_line) {
        print "OK ensure=" ensure_line " gh=" gh_line
      } else {
        print "FAIL ensure=" ensure_line " gh=" gh_line
        exit 1
      }
    }
  ' "$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# assess-documentation.sh untouched (scope boundary check)
# ---------------------------------------------------------------------------

@test "assess-documentation.sh is NOT modified by this issue (scope boundary)" {
  # The Layer 2 gate is reused, not duplicated — assess-documentation.sh must
  # be unchanged relative to origin/main.
  run bash -c "
    cd '$RITE_REPO_ROOT'
    git diff origin/main --stat -- lib/core/assess-documentation.sh 2>/dev/null || true
  "
  [ "$status" -eq 0 ]
  # Output should be empty (no changes to that file)
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# config/project.conf.example: RITE_DOC_MODE documented
# ---------------------------------------------------------------------------

@test "config/project.conf.example documents RITE_DOC_MODE" {
  count=$(grep -c 'RITE_DOC_MODE' "$RITE_REPO_ROOT/config/project.conf.example" || true)
  [ "$count" -ge 1 ]
}
