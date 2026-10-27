#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::docs_run_assertion_audit, lib/utils/drift-log.sh::drift_log_clear_doc
BATS_TEST_TIMEOUT=60
#
# Regression tests for #1441: After rite align-docs audit, clear drift entries
# for audited docs and rebuild the docs map.
#
# Covers:
#  1. Drift entries for audited docs (all branches) are cleared at audit completion.
#  2. Drift entries for docs NOT in audit scope survive.
#  3. The docs map is rebuilt (docs_map_build called) after audit completes.
#  4. Structural: drift_log_clear_doc uses per-file rm — no glob in rm calls.

load '../helpers/setup'

# ---------------------------------------------------------------------------
# Write a minimal v4 docs-map.tsv.
# Args: map_file "doc_path|heading_level|heading_text|doc_type" ...
# ---------------------------------------------------------------------------
_write_map() {
  local map_file="$1"; shift
  printf '# docs-map v4 sha=abc123 built=2026-10-26T00:00:00Z\n' > "$map_file"
  local entry
  for entry in "$@"; do
    local _p _hl _ht _dt
    _p="$(printf '%s' "$entry" | cut -d'|' -f1)"
    _hl="$(printf '%s' "$entry" | cut -d'|' -f2)"
    _ht="$(printf '%s' "$entry" | cut -d'|' -f3)"
    _dt="$(printf '%s' "$entry" | cut -d'|' -f4)"
    printf '%s\tabc123\t-\t%s\t%s\tfingerprint000\t%s\t-\t-\t-\n' \
      "$_p" "$_hl" "$_ht" "$_dt" >> "$map_file"
  done
}

# ---------------------------------------------------------------------------
# Build a helper script that runs docs_run_assertion_audit with stubs.
#
# Unlike the helper in align-docs-assertion-audit.bats, this one uses the REAL
# drift_log_clear_doc so clearing behaviour can be verified.  docs_map_build is
# replaced with a sentinel-touch stub so the rebuild call is observable.
#
# Arguments:
#   $1 — provider output (what the stub provider echoes per section)
#   $2 — stdin to feed (e.g. $'y\n' to confirm the gate, then n per finding)
#   $3 — optional path to touch when docs_map_build is called
# ---------------------------------------------------------------------------
_audit_clear_helper() {
  local provider_output="$1"
  local stdin_input="${2:-$(printf 'y\n')}"
  local map_build_sentinel="${3:-}"

  local helper="${BATS_TEST_TMPDIR}/audit_clear_helper.sh"
  # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: variables must expand in helper script
  cat > "$helper" << HELPER_EOF
#!/bin/bash
set -euo pipefail
export RITE_LIB_DIR="${RITE_LIB_DIR}"
export RITE_PROJECT_ROOT="${RITE_PROJECT_ROOT}"
export RITE_STATE_DIR="${RITE_STATE_DIR}"
export RITE_TARGET_BRANCH="main"
export _RITE_FORCE_TTY=1
source "\${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
provider_run_prompt_with_timeout() { printf '%s\n' "${provider_output}"; }
provider_resolve_model()           { echo "claude-sonnet-4-6"; }
docs_map_path()    { echo "\${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_ensure()  { return 0; }
docs_resolve_doc_scope() {
  awk -F'\t' '/^#/{next} NF>=1{print \$1}' "\${RITE_PROJECT_ROOT}/docs/docs-map.tsv" 2>/dev/null | sort -u || true
}
docs_map_adr_links() { true; }
docs_map_build() {
  if [ -n "${map_build_sentinel}" ]; then
    touch "${map_build_sentinel}"
  fi
  return 0
}
lock_acquire() { return 0; }
lock_release() { return 0; }
print_info()    { true; }
print_warning() { true; }
print_success() { true; }
git() {
  case "\${1:-}" in
    -C) shift; shift ;;
  esac
  case "\${1:-}" in
    rev-parse) echo "main" ;;
    *) true ;;
  esac
}
docs_run_assertion_audit "\${@}"
HELPER_EOF

  chmod +x "$helper"
  echo "$helper"
}

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_PROJECT_ROOT/docs"
  mkdir -p "$RITE_STATE_DIR/doc-drift/main"

  printf '# Feature A\n\nThis section describes feature A.\n' \
    > "$RITE_PROJECT_ROOT/docs/feature-a.md"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Test 1: Entries for audited docs are cleared on all branches; unaudited survive.
# ---------------------------------------------------------------------------
@test "audit completion clears entries for audited docs across all branches" {
  local slug="docs--feature-a.md"
  local other_slug="docs--other-doc.md"

  # Pre-populate entries for the audited doc on two branches
  mkdir -p "$RITE_STATE_DIR/doc-drift/main"
  mkdir -p "$RITE_STATE_DIR/doc-drift/release-1.2"
  printf 'doc=docs/feature-a.md\tbranch=main\tpr=1\tissue=-\tassertion=assert1\tkind=refinement\tevidence=foo\trecorded=2026-10-01T00:00:00Z\n' \
    > "$RITE_STATE_DIR/doc-drift/main/${slug}"
  printf 'doc=docs/feature-a.md\tbranch=release-1.2\tpr=2\tissue=-\tassertion=assert2\tkind=refinement\tevidence=bar\trecorded=2026-10-02T00:00:00Z\n' \
    > "$RITE_STATE_DIR/doc-drift/release-1.2/${slug}"

  # Pre-populate entry for an out-of-scope doc (must survive)
  printf 'doc=docs/other-doc.md\tbranch=main\tpr=3\tissue=-\tassertion=other\tkind=refinement\tevidence=baz\trecorded=2026-10-03T00:00:00Z\n' \
    > "$RITE_STATE_DIR/doc-drift/main/${other_slug}"

  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature"

  local helper
  helper="$(_audit_clear_helper "ASSESSMENT: nothing to report" "$(printf 'y\n')")"

  run bash "$helper" <<< "$(printf 'y\n')"

  # Audited doc entries cleared on both branches
  [ ! -f "$RITE_STATE_DIR/doc-drift/main/${slug}" ]
  [ ! -f "$RITE_STATE_DIR/doc-drift/release-1.2/${slug}" ]

  # Out-of-scope doc entry survives
  [ -f "$RITE_STATE_DIR/doc-drift/main/${other_slug}" ]
}

# ---------------------------------------------------------------------------
# Test 2: docs_map_build is called after the audit completes.
# ---------------------------------------------------------------------------
@test "docs map is rebuilt after audit completes" {
  _write_map "$RITE_PROJECT_ROOT/docs/docs-map.tsv" \
    "docs/feature-a.md|1|Feature A|feature"

  local sentinel="$RITE_TEST_TMPDIR/map_rebuilt"
  local helper
  helper="$(_audit_clear_helper "ASSESSMENT: nothing to report" "$(printf 'y\n')" "$sentinel")"

  run bash "$helper" <<< "$(printf 'y\n')"

  [ -f "$sentinel" ]
}

# ---------------------------------------------------------------------------
# Test 3: drift_log_clear_doc uses per-file rm — no glob in rm calls (#345 class).
# ---------------------------------------------------------------------------
@test "drift_log_clear_doc uses per-file removal, no glob pattern in rm calls" {
  local drift_log_sh="$RITE_LIB_DIR/utils/drift-log.sh"
  [ -f "$drift_log_sh" ]

  # Extract drift_log_clear_doc function body (lines between the () { and closing })
  local body
  body="$(awk '/^drift_log_clear_doc\(\)/{p=1; next} p && /^}$/{p=0} p{print}' "$drift_log_sh" || true)"

  [ -n "$body" ]

  # No rm call with a glob expansion (* wildcard in the path argument) — #345 class
  local bad_rm
  bad_rm="$(printf '%s\n' "$body" | grep -E 'rm -f[[:space:]].*\*' | grep -v '^[[:space:]]*#' || true)"
  [ -z "$bad_rm" ]
}
