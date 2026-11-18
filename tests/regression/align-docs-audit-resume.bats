#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/docs-command.sh::docs_run_assertion_audit|_docs_audit_build_prompt|_docs_audit_list_sections|_docs_audit_state_dir|_docs_audit_state_has|_docs_audit_state_add|_docs_audit_state_drop|_docs_audit_state_drop_doc|_docs_extract_section_own|docs_reconcile_drift, lib/utils/doc-consent.sh::_run_align_docs_passes, bin/rite
# tests/regression/align-docs-audit-resume.bats
#
# Regression tests for #1826: the align-docs assertion audit shows its
# progress, saves it after every section, and resumes.
#
# Live failure (2026-11-18): `rite align-docs behavioral-design.md` planned
# 150 model calls, printed nothing for 25 minutes, and was stopped at call 37
# with every finding lost. The H1 row sent the whole file and every parent
# section re-sent its children.
#
# The provider is a stub driven by env vars; everything else in the audit is
# the real code, including the saved-progress files under RITE_STATE_DIR.

load '../helpers/setup'

# Map row: "doc|level|heading|type" (rubric fixed to "-").
_write_map() {
  local map_file="$1"
  shift
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

# Three sections, each with text of its own.
_three_section_fixture() {
  printf '# Guide\n\nIntro text.\n\n## Alpha\n\nAlpha text.\n\n## Beta\n\nBeta text.\n' \
    > "$RITE_PROJECT_ROOT/docs/guide.md"
  _write_map "$MAP" \
    "docs/guide.md|1|Guide|other" \
    "docs/guide.md|2|Alpha|other" \
    "docs/guide.md|2|Beta|other"
}

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/project"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="$RITE_PROJECT_ROOT/.rite/state"
  mkdir -p "$RITE_PROJECT_ROOT/docs" "$RITE_STATE_DIR"
  MAP="$RITE_PROJECT_ROOT/docs/docs-map.tsv"
  AUDIT_DIR="$RITE_STATE_DIR/doc-audit"

  export STUB_DIR="$RITE_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  export STUB_OUTPUT="NOTHING_FOUND"
  unset STUB_FAIL_AT STUB_FAIL_RC STUB_MAP_SRC

  # The audit under test, real code, with the provider and the drift store
  # stubbed. Stub behaviour comes from the environment:
  #   STUB_OUTPUT    what every model call answers
  #   STUB_FAIL_AT   1-based call number that fails instead ("all": every call) ...
  #   STUB_FAIL_RC   ... with this exit code
  #   STUB_MAP_SRC   file docs_map_build copies into place (default: no-op)
  HELPER="$RITE_TEST_TMPDIR/audit_helper.sh"
  cat > "$HELPER" <<'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_TARGET_BRANCH="main"
export _RITE_FORCE_TTY=1
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
provider_run_prompt_with_timeout() {
  local _n=0
  [ -f "${STUB_DIR}/calls.count" ] && _n="$(cat "${STUB_DIR}/calls.count")"
  _n=$((_n + 1))
  echo "$_n" > "${STUB_DIR}/calls.count"
  printf '%s\n---CALL-BOUNDARY---\n' "$1" >> "${STUB_DIR}/calls.log"
  if [ "${STUB_FAIL_AT:-0}" = "$_n" ] || [ "${STUB_FAIL_AT:-0}" = "all" ]; then
    return "${STUB_FAIL_RC:-1}"
  fi
  printf '%s\n' "${STUB_OUTPUT}"
}
provider_resolve_model() { echo "stub-model"; }
docs_map_path() { echo "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"; }
docs_map_build() {
  echo "build" >> "${STUB_DIR}/map-build.log"
  if [ -n "${STUB_MAP_SRC:-}" ]; then
    cp "${STUB_MAP_SRC}" "${RITE_PROJECT_ROOT}/docs/docs-map.tsv"
  fi
}
docs_map_ensure() { return 0; }
docs_resolve_doc_scope() {
  awk -F'\t' '/^#/{next} NF>=1{print $1}' "${RITE_PROJECT_ROOT}/docs/docs-map.tsv" 2>/dev/null | sort -u || true
}
docs_map_adr_links() { true; }
drift_log_append() {
  local _IFS_SAVE="$IFS"
  IFS='|'
  printf '%s\n' "$*" >> "${STUB_DIR}/drift.log"
  IFS="$_IFS_SAVE"
}
drift_log_clear_doc() { printf '%s\n' "$1" >> "${STUB_DIR}/clear.log"; }
print_info()    { printf 'INFO: %s\n' "$*" >&2; }
print_warning() { printf 'WARN: %s\n' "$*" >&2; }
print_status()  { printf '%s\n' "$*" >&2; }
print_success() { true; }
git() {
  case "${1:-}" in
    -C) shift; shift ;;
  esac
  case "${1:-}" in
    rev-parse) echo "main" ;;
    *) true ;;
  esac
}
docs_run_assertion_audit "$@"
HELPER_EOF
  chmod +x "$HELPER"
}

teardown() {
  teardown_test_tmpdir
}

_calls() {
  if [ -f "$STUB_DIR/calls.count" ]; then cat "$STUB_DIR/calls.count"; else echo 0; fi
}

_reset_calls() {
  rm -f "$STUB_DIR/calls.count" "$STUB_DIR/calls.log"
}

# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------
@test "progress line: one line per section with position, finding count and duration" {
  _three_section_fixture

  run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]

  [[ "$output" =~ \[1/3\]\ docs/guide\.md\ §\ Guide\ \.\.\.\ 0\ finding\(s\)\ \([0-9]+s\) ]]
  [[ "$output" =~ \[2/3\]\ docs/guide\.md\ §\ Alpha\ \.\.\.\ 0\ finding\(s\)\ \([0-9]+s\) ]]
  [[ "$output" =~ \[3/3\]\ docs/guide\.md\ §\ Beta\ \.\.\.\ 0\ finding\(s\)\ \([0-9]+s\) ]]
  # The plan names the model and the real call count before anything is spent.
  [[ "$output" == *"Model calls:   3  (one per section, stub-model)"* ]]
  [[ "$output" == *"Progress is saved after every section"* ]]
}

# ---------------------------------------------------------------------------
# Section slicing
# ---------------------------------------------------------------------------
@test "own body: a parent section is sent without its child sections" {
  _three_section_fixture

  run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 3 ]

  # First call is the H1 row: its own intro only, never the children's text.
  local first
  first="$(awk '/^---CALL-BOUNDARY---$/{exit} {print}' "$STUB_DIR/calls.log")"
  [[ "$first" == *"Intro text."* ]]
  [[ "$first" != *"Alpha text."* ]]
  [[ "$first" != *"Beta text."* ]]
  # Each child's text is sent exactly once across the whole run.
  [ "$(grep -c "Alpha text." "$STUB_DIR/calls.log")" -eq 1 ]
  [ "$(grep -c "Beta text." "$STUB_DIR/calls.log")" -eq 1 ]
}

@test "own body: a section with no text of its own makes no model call" {
  printf '# Guide\n\n## Alpha\n\nAlpha text.\n' > "$RITE_PROJECT_ROOT/docs/guide.md"
  _write_map "$MAP" "docs/guide.md|1|Guide|other" "docs/guide.md|2|Alpha|other"

  run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 1 ]
  [[ "$output" == *"Sections:      1  (+1 with no text of their own, not sent)"* ]]
  [[ "$output" == *"[1/1] docs/guide.md § Alpha"* ]]
}

@test "own body: a repeated heading resolves to its own occurrence" {
  printf '# Guide\n\n## One\n\n### Test\n\nFirst test text.\n\n## Two\n\n### Test\n\nSecond test text.\n' \
    > "$RITE_PROJECT_ROOT/docs/guide.md"
  _write_map "$MAP" "docs/guide.md|3|Test|other" "docs/guide.md|3|Test|other"

  run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 2 ]
  [ "$(grep -c "First test text." "$STUB_DIR/calls.log")" -eq 1 ]
  [ "$(grep -c "Second test text." "$STUB_DIR/calls.log")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Saved progress
# ---------------------------------------------------------------------------
@test "resume: a second run calls the model only for sections not yet checked" {
  _three_section_fixture

  # Run 1: the third call fails, so two sections are saved and one is not.
  STUB_FAIL_AT=3 STUB_FAIL_RC=1 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 3 ]
  [[ "$output" == *"[3/3] docs/guide.md § Beta ... failed (rc=1"* ]]
  [ "$(wc -l < "$AUDIT_DIR/done.tsv" | tr -d ' ')" -eq 2 ]

  # Run 2: resume. One call, for the section that failed.
  _reset_calls
  run bash "$HELPER" "docs/guide.md" <<< $'r\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 1 ]
  [[ "$output" == *"Already done:  2"* ]]
  [[ "$output" == *"Model calls:   1  "* ]]
  [[ "$output" == *"Resuming: 2 section(s) already checked, 1 to go"* ]]
  grep -q "Beta text." "$STUB_DIR/calls.log"
  ! grep -q "Alpha text." "$STUB_DIR/calls.log"

  # Everything checked and reviewed: the saved progress is dropped.
  [ ! -e "$AUDIT_DIR/done.tsv" ]
}

@test "resume: findings are written to disk as each call finishes" {
  _three_section_fixture
  export STUB_OUTPUT="FINDING: accuracy|the default is wrong"

  # Second call hits the usage cap: the first section's finding must already be saved.
  STUB_FAIL_AT=2 STUB_FAIL_RC=5 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 5 ]
  [ "$(wc -l < "$AUDIT_DIR/findings.tsv" | tr -d ' ')" -eq 1 ]
  grep -q "the default is wrong" "$AUDIT_DIR/findings.tsv"
  [ "$(wc -l < "$AUDIT_DIR/done.tsv" | tr -d ' ')" -eq 1 ]
}

@test "resume: start over discards the saved progress and calls every section" {
  _three_section_fixture
  STUB_FAIL_AT=3 STUB_FAIL_RC=1 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]

  _reset_calls
  run bash "$HELPER" "docs/guide.md" <<< $'s\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 3 ]
}

@test "resume: declining at the resume prompt makes no call and keeps the progress" {
  _three_section_fixture
  STUB_FAIL_AT=3 STUB_FAIL_RC=1 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]

  _reset_calls
  run bash "$HELPER" "docs/guide.md" <<< $'n\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 0 ]
  [ "$(wc -l < "$AUDIT_DIR/done.tsv" | tr -d ' ')" -eq 2 ]
}

@test "changed section: it is audited again and its old findings are not offered" {
  _three_section_fixture
  export STUB_OUTPUT="FINDING: accuracy|stale claim"

  # Run 1: all three checked; quit the review at once so nothing is reviewed.
  run bash "$HELPER" "docs/guide.md" <<< $'y\nq\n'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$AUDIT_DIR/findings.tsv" | tr -d ' ')" -eq 3 ]

  # Alpha is rewritten between runs.
  printf '# Guide\n\nIntro text.\n\n## Alpha\n\nAlpha text, rewritten.\n\n## Beta\n\nBeta text.\n' \
    > "$RITE_PROJECT_ROOT/docs/guide.md"

  _reset_calls
  export STUB_OUTPUT="NOTHING_FOUND"
  run bash "$HELPER" "docs/guide.md" <<< $'r\ny\ny\n'
  [ "$status" -eq 0 ]

  # Only the changed section is called again.
  [ "$(_calls)" -eq 1 ]
  grep -q "Alpha text, rewritten." "$STUB_DIR/calls.log"

  # Guide and Beta findings are offered; Alpha's old finding is not.
  [ "$(grep -c "assertion audit; section:" "$STUB_DIR/drift.log")" -eq 2 ]
  ! grep -q "section: Alpha" "$STUB_DIR/drift.log"
  [[ "$output" == *"3 section(s) checked, 2 finding(s)"* ]]
}

# ---------------------------------------------------------------------------
# Stops
# ---------------------------------------------------------------------------
@test "usage cap: the audit stops at once, keeps its progress and says how to resume" {
  _three_section_fixture

  STUB_FAIL_AT=2 STUB_FAIL_RC=5 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 5 ]
  # No third call after the cap.
  [ "$(_calls)" -eq 2 ]
  [[ "$output" == *"usage cap"* ]]
  [[ "$output" == *"Progress saved: 1 of 3 section(s) checked. Resume with: rite align-docs docs/guide.md"* ]]
  [ "$(wc -l < "$AUDIT_DIR/done.tsv" | tr -d ' ')" -eq 1 ]
  # Nothing was cleared or recorded on a stopped run.
  [ ! -e "$STUB_DIR/clear.log" ]
  [ ! -e "$STUB_DIR/drift.log" ]
}

@test "usage cap: an auth failure stops the same way with its own exit code" {
  _three_section_fixture

  STUB_FAIL_AT=1 STUB_FAIL_RC=18 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 18 ]
  [ "$(_calls)" -eq 1 ]
  [[ "$output" == *"Resume with: rite align-docs docs/guide.md"* ]]
}

@test "usage cap: three failed calls in a row stop the audit" {
  printf '# G\n\nA.\n\n## B\n\nB.\n\n## C\n\nC.\n\n## D\n\nD.\n\n## E\n\nE.\n' \
    > "$RITE_PROJECT_ROOT/docs/guide.md"
  _write_map "$MAP" "docs/guide.md|1|G|other" "docs/guide.md|2|B|other" \
    "docs/guide.md|2|C|other" "docs/guide.md|2|D|other" "docs/guide.md|2|E|other"

  # Five sections, every call fails: the audit must give up after the third.
  STUB_FAIL_AT=all STUB_FAIL_RC=1 run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 1 ]
  [ "$(_calls)" -eq 3 ]
  [[ "$output" == *"three model calls in a row failed"* ]]
}

# ---------------------------------------------------------------------------
# Review
# ---------------------------------------------------------------------------
@test "quit: review asks once per section and quitting keeps the rest for the next run" {
  _three_section_fixture
  export STUB_OUTPUT=$'FINDING: accuracy|first claim\nFINDING: role|second claim'

  # Run 1: gate y, section 1 "all", section 2 "quit".
  run bash "$HELPER" "docs/guide.md" <<< $'y\na\nq\n'
  [ "$status" -eq 0 ]
  # One answer recorded both findings of section 1.
  [ "$(grep -c "section: Guide" "$STUB_DIR/drift.log")" -eq 2 ]
  ! grep -q "section: Alpha" "$STUB_DIR/drift.log"
  [[ "$output" == *"Review paused: 2 section(s) still to review. Resume with: rite align-docs docs/guide.md"* ]]
  [ "$(wc -l < "$AUDIT_DIR/reviewed.tsv" | tr -d ' ')" -eq 1 ]

  # Run 2: no model calls; the two unreviewed sections are offered, Guide is not.
  _reset_calls
  rm -f "$STUB_DIR/drift.log"
  run bash "$HELPER" "docs/guide.md" <<< $'r\nn\na\n'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 0 ]
  ! grep -q "section: Guide" "$STUB_DIR/drift.log"
  ! grep -q "section: Alpha" "$STUB_DIR/drift.log"
  [ "$(grep -c "section: Beta" "$STUB_DIR/drift.log")" -eq 2 ]
  [ ! -e "$AUDIT_DIR/done.tsv" ]
}

@test "quit: pick asks finding by finding within a section" {
  printf '# Guide\n\nIntro text.\n' > "$RITE_PROJECT_ROOT/docs/guide.md"
  _write_map "$MAP" "docs/guide.md|1|Guide|other"
  export STUB_OUTPUT=$'FINDING: accuracy|first claim\nFINDING: role|second claim\nFINDING: nondeterministic|third claim'

  run bash "$HELPER" "docs/guide.md" <<< $'y\np\nn\ny\n'
  [ "$status" -eq 0 ]
  ! grep -q "first claim" "$STUB_DIR/drift.log"
  grep -q "second claim|reference-missing|assertion audit; section: Guide" "$STUB_DIR/drift.log"
  # The nondeterministic finding is recorded without a question.
  grep -q "third claim|refinement|nondeterministic assertion; section: Guide" "$STUB_DIR/drift.log"
  [[ "$output" == *"2 finding(s) recorded (1 auto-refinement, 1 user-accepted)"* ]]
}

@test "quit: end of input during review counts as quit, not as an answer" {
  _three_section_fixture
  export STUB_OUTPUT="FINDING: accuracy|a claim"

  # Gate answered; the review gets no input at all.
  run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_DIR/drift.log" ]
  [[ "$output" == *"Review paused: 3 section(s) still to review"* ]]
  [ "$(wc -l < "$AUDIT_DIR/done.tsv" | tr -d ' ')" -eq 3 ]
}

@test "cleared once: a doc's old drift entries are cleared once per audit cycle" {
  _three_section_fixture
  export STUB_OUTPUT="FINDING: accuracy|a claim"

  # Run 1: review one section, then quit.
  run bash "$HELPER" "docs/guide.md" <<< $'y\ny\nq\n'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_DIR/clear.log" | tr -d ' ')" -eq 1 ]

  # Run 2 (resumed): the entry recorded in run 1 must not be wiped.
  run bash "$HELPER" "docs/guide.md" <<< $'r\ny\ny\n'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_DIR/clear.log" | tr -d ' ')" -eq 1 ]

  # Run 3 is a new cycle: cleared again.
  run bash "$HELPER" "docs/guide.md" <<< $'y\nn\nn\nn\n'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_DIR/clear.log" | tr -d ' ')" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Map freshness
# ---------------------------------------------------------------------------
@test "map is rebuilt before the section list is read" {
  printf '# Guide\n\nIntro text.\n\n## Alpha\n\nAlpha text.\n' > "$RITE_PROJECT_ROOT/docs/guide.md"
  # The map on disk is stale: it only knows the H1 row.
  _write_map "$MAP" "docs/guide.md|1|Guide|other"
  # The rebuild produces the current two-row map.
  _write_map "$RITE_TEST_TMPDIR/fresh-map.tsv" \
    "docs/guide.md|1|Guide|other" "docs/guide.md|2|Alpha|other"
  export STUB_MAP_SRC="$RITE_TEST_TMPDIR/fresh-map.tsv"

  run bash "$HELPER" "docs/guide.md" <<< $'y\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sections:      2"* ]]
  [ "$(_calls)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
@test "log file: rite align-docs writes rite-align-docs-*.log" {
  mkdir -p "$RITE_TEST_TMPDIR/logproj/.rite/logs"
  local stub_bin="$RITE_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  printf '#!/bin/bash\necho "ok"\nexit 0\n' > "$stub_bin/claude"
  chmod +x "$stub_bin/claude"

  PATH="$stub_bin:$PATH" run env \
    -u RITE_LOG_FILE -u RITE_LOG_AUTO -u PR_NUMBER -u ISSUE_NUMBER -u RITE_STATE_DIR \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/logproj" \
    RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks" \
    bash "$RITE_REPO_ROOT/bin/rite" align-docs < /dev/null

  local count
  count=$(ls "$RITE_TEST_TMPDIR/logproj/.rite/logs"/rite-align-docs-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "log file: the consent switches stay unlogged" {
  mkdir -p "$RITE_TEST_TMPDIR/logproj/.rite/logs"

  run env \
    -u RITE_LOG_FILE -u RITE_LOG_AUTO -u PR_NUMBER -u ISSUE_NUMBER -u RITE_STATE_DIR \
    RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR/logproj" \
    RITE_LOCK_DIR="$RITE_TEST_TMPDIR/locks" \
    bash "$RITE_REPO_ROOT/bin/rite" align-docs --disable < /dev/null

  local count
  count=$(ls "$RITE_TEST_TMPDIR/logproj/.rite/logs"/rite-align-docs-*.log 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Closing reconcile
# ---------------------------------------------------------------------------
_reconcile_helper() {
  local helper="$RITE_TEST_TMPDIR/reconcile_helper.sh"
  cat > "$helper" <<'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export RITE_TARGET_BRANCH="main"
source "${RITE_LIB_DIR}/core/docs-command.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: docs-command.sh uses declare -f rite_docs function-sentinel guard; post-source stubs are preserved
docs_map_ensure() { return 0; }
_docs_main_entries_pass() { printf 'pass %s\n' "$1" >> "${STUB_DIR}/reconcile.log"; }
docs_reconcile_adr_drift() { printf 'adr\n' >> "${STUB_DIR}/reconcile.log"; }
_docs_update_engine() { printf 'legacy\n' >> "${STUB_DIR}/reconcile.log"; }
print_info()    { printf 'INFO: %s\n' "$*" >&2; }
print_warning() { printf 'WARN: %s\n' "$*" >&2; }
docs_reconcile_drift "$@"
HELPER_EOF
  chmod +x "$helper"
  echo "$helper"
}

_seed_entry() {
  local doc="$1" slug
  slug="$(printf '%s' "$doc" | sed 's|/|--|g')"
  mkdir -p "$RITE_STATE_DIR/doc-drift/main"
  printf 'doc=%s\tbranch=main\tpr=0\tissue=-\tassertion=some claim\tkind=contradiction\tevidence=audit\trecorded=2026-11-18T00:00:00Z\n' \
    "$doc" > "$RITE_STATE_DIR/doc-drift/main/${slug}.log"
}

@test "closing reconcile: with doc names it offers entries for those docs only" {
  _seed_entry "docs/guide.md"
  _seed_entry "docs/other.md"
  local helper
  helper="$(_reconcile_helper)"

  run bash "$helper" "docs/guide.md"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/reconcile.log")" = "pass docs/guide.md" ]
}

@test "closing reconcile: a named doc with no entries is a no-op with one info line" {
  _seed_entry "docs/other.md"
  local helper
  helper="$(_reconcile_helper)"

  run bash "$helper" "docs/guide.md"
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_DIR/reconcile.log" ]
  [[ "$output" == *"No drift entries for the named doc(s)"* ]]
}

@test "closing reconcile: without doc names every doc and the ADR pass still run" {
  _seed_entry "docs/guide.md"
  _seed_entry "docs/other.md"
  local helper
  helper="$(_reconcile_helper)"

  run bash "$helper"
  [ "$status" -eq 0 ]
  grep -q "pass docs/guide.md" "$STUB_DIR/reconcile.log"
  grep -q "pass docs/other.md" "$STUB_DIR/reconcile.log"
  grep -q "adr" "$STUB_DIR/reconcile.log"
}

@test "closing reconcile: align-docs forwards its doc names and skips it after a quit" {
  local helper="$RITE_TEST_TMPDIR/passes_helper.sh"
  cat > "$helper" <<'HELPER_EOF'
#!/bin/bash
set -euo pipefail
export _RITE_FORCE_TTY=1
source "${RITE_LIB_DIR}/utils/doc-consent.sh"
# sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: doc-consent.sh uses declare -f ensure_doc_mode function-sentinel guard; post-source stubs are preserved
docs_run_restructure_assessment() { return 0; }
docs_run_assertion_audit() { _DOCS_AUDIT_STOPPED="${STUB_STOPPED:-false}"; }
docs_reconcile_drift() { printf 'reconcile %s\n' "$*" >> "${STUB_DIR}/passes.log"; }
_run_align_docs_passes "$@"
HELPER_EOF

  run bash "$helper" "docs/guide.md"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/passes.log")" = "reconcile docs/guide.md" ]

  rm -f "$STUB_DIR/passes.log"
  STUB_STOPPED=true run bash "$helper" "docs/guide.md"
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_DIR/passes.log" ]
}
