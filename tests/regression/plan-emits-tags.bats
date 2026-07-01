#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh
# tests/regression/plan-emits-tags.bats
#
# Regression tests for the tag-index Stage 5 write-path (#404): `rite plan`
# emits a <!-- sharkrite-issue-tags --> block in generated issues, closing the
# loop with the Stage 4 read-path (build_relevant_prior_art extracts exactly
# this block).
#
# This is prompt-construction + injection, so it is tested STRUCTURALLY — the
# actual Claude call (populating the tags: line) is the model's job. We assert:
#   A. With a fixture tag-index.md, the generation prompt CONTAINS the
#      "Available tags" context (tag headings + first pointer).
#   B. With a fixture tag-index.md, the prompt CONTAINS the instruction to emit
#      a <!-- sharkrite-issue-tags --> block AND the new-tags: justification rule.
#   C. With NO tag-index.md (missing), the prompt does NOT instruct a tag block
#      (clean degrade) and generation still proceeds (issue format intact).
#   D. With an EMPTY / scaffold-only tag-index.md, same clean degrade as C.
#   E. _build_available_tags_context emits tag + first pointer per tag, and
#      degrades to empty on a missing/empty index.
#
# Test strategy (mirrors plan-doc-ingest.bats):
#   - Extract _build_available_tags_context and generate_issues from
#     plan-issues.sh via awk (avoids running the interactive plan_issues body).
#   - Source lib/utils/tag-index.sh so parse_tag_index is available to the
#     extracted helper.
#   - Use RITE_PLAN_DRYRUN_DUMP_PROMPT=1 to dump the assembled prompt without a
#     provider call, then assert sentinel strings appear / are absent.
#   - Stub provider_detect_cli and gh_safe so nothing hits the network.

load '../helpers/setup.bash'

# The literal marker string, defined here (a test file — RAW_MARKER_LITERAL lint
# allowlists tests/) so the assertions can grep for the concrete emitted text.
ISSUE_TAGS_MARKER="sharkrite-issue-tags"

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INSTALL_DIR="${RITE_REPO_ROOT}"
  export RITE_DATA_DIR=".rite"
  export RITE_PLAN_DOC_BYTE_CAP=50000
  export RITE_PLAN_MAX_ESTIMATE="2hr"
  export RITE_PLAN_DOCS=""
  export RITE_PLAN_DRYRUN_DUMP_PROMPT=""

  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"

  # Stub print_* so output goes cleanly to stderr without requiring colors.sh
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Stub provider + gh so no real provider / GitHub connection is needed
  provider_detect_cli()           { return 0; }
  provider_run_streaming_prompt() { echo "STUB_STREAMING_OUTPUT"; }
  gh_safe() { echo ""; }

  # portable_sed_i is part of plan-issues.sh's sourcing chain
  if ! declare -f portable_sed_i >/dev/null 2>&1; then
    if [ -f "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh" ]; then
      # shellcheck disable=SC1090
      source "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh"
    fi
  fi

  # RITE_MARKER_ISSUE_TAGS is referenced in the prompt-construction code, so the
  # extracted generate_issues needs it. markers.sh defines it.
  if [ -z "${RITE_MARKER_ISSUE_TAGS:-}" ]; then
    if [ -f "${RITE_REPO_ROOT}/lib/utils/markers.sh" ]; then
      # shellcheck disable=SC1090
      source "${RITE_REPO_ROOT}/lib/utils/markers.sh"
    fi
  fi

  # parse_tag_index is used by _build_available_tags_context. Source the real
  # read helpers so the extracted function resolves it (RITE_LIB_DIR is set).
  if ! declare -f parse_tag_index >/dev/null 2>&1; then
    if [ -f "${RITE_REPO_ROOT}/lib/utils/tag-index.sh" ]; then
      # shellcheck disable=SC1090
      source "${RITE_REPO_ROOT}/lib/utils/tag-index.sh"
    fi
  fi

  # Extract _build_available_tags_context and generate_issues from plan-issues.sh
  # via a brace-depth scan (avoids running the interactive plan_issues body).
  eval "$(awk '
    /^_build_available_tags_context[(][)]/ { in_fn=1; depth=0 }
    /^generate_issues[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_tag_index() {
  cat > "$RITE_TEST_TMPDIR/docs/architecture/tag-index.md" <<'IDX'
# Tag Index

**Auto-maintained — do not hand-edit.** See `docs/architecture/tag-index-system.md`.

---

## subshell

- conventions.md → Subshell variable loss
- encountered-issues.md → Subshell pipefail propagation

## set-e

- conventions.md → grep -c pattern
- encountered-issues.md → Bare-prefix marker grep
IDX
}

# Dump the generation prompt for a given tag-index state. Populates $output.
_dump_prompt() {
  export RITE_PLAN_DRYRUN_DUMP_PROMPT=1
  run generate_issues \
    "DOC_CONTENT_DUMMY" \
    "# Test Project" \
    "runbook text" \
    "" "" "" "2hr" "" "" ""
  export RITE_PLAN_DRYRUN_DUMP_PROMPT=""
}

# ---------------------------------------------------------------------------
# E: _build_available_tags_context — tag + first pointer per tag
# ---------------------------------------------------------------------------

@test "E1: _build_available_tags_context emits each tag with its first pointer" {
  _write_tag_index

  local ctx
  ctx=$(_build_available_tags_context)

  echo "$ctx" | grep -qE '^- subshell — conventions.md → Subshell variable loss$' || {
    echo "FAIL: subshell tag + first pointer missing" >&2
    echo "--- context ---" >&2; echo "$ctx" >&2; false
  }
  echo "$ctx" | grep -qE '^- set-e — conventions.md → grep -c pattern$' || {
    echo "FAIL: set-e tag + first pointer missing" >&2
    echo "--- context ---" >&2; echo "$ctx" >&2; false
  }

  # Only the FIRST pointer per tag is included (not the second).
  echo "$ctx" | grep -q "Subshell pipefail propagation" && {
    echo "FAIL: second pointer leaked into context (should be first-only)" >&2
    echo "$ctx" >&2; false
  }
  echo "$ctx" | grep -q "Bare-prefix marker grep" && {
    echo "FAIL: second pointer leaked into context (should be first-only)" >&2
    echo "$ctx" >&2; false
  }
  true
}

@test "E2: _build_available_tags_context is empty when index is missing" {
  # No tag-index.md written.
  local ctx
  ctx=$(_build_available_tags_context || true)
  [ -z "$ctx" ] || {
    echo "FAIL: expected empty context for missing index, got: [$ctx]" >&2
    false
  }
}

@test "E3: _build_available_tags_context is empty for a scaffold-only index (no tags)" {
  cat > "$RITE_TEST_TMPDIR/docs/architecture/tag-index.md" <<'IDX'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

IDX
  local ctx
  ctx=$(_build_available_tags_context || true)
  [ -z "$ctx" ] || {
    echo "FAIL: expected empty context for scaffold-only index, got: [$ctx]" >&2
    false
  }
}

@test "E4: _build_available_tags_context is empty for a 0-byte index file" {
  : > "$RITE_TEST_TMPDIR/docs/architecture/tag-index.md"
  local ctx
  ctx=$(_build_available_tags_context || true)
  [ -z "$ctx" ] || {
    echo "FAIL: expected empty context for empty index, got: [$ctx]" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# A: with a fixture index, the prompt CONTAINS the available-tags context
# ---------------------------------------------------------------------------

@test "A: generation prompt contains the Available tags context from the index" {
  _write_tag_index
  _dump_prompt

  [ "$status" -eq 0 ] || {
    echo "FAIL: generate_issues (dry-run dump) exited $status" >&2
    echo "$output" >&2; false
  }

  echo "$output" | grep -q "Available tags" || {
    echo "FAIL: 'Available tags' header missing from prompt" >&2
    false
  }
  # The actual tag vocabulary + first pointer must be present in the prompt.
  echo "$output" | grep -q "subshell — conventions.md → Subshell variable loss" || {
    echo "FAIL: subshell tag context not injected into prompt" >&2
    false
  }
  echo "$output" | grep -q "set-e — conventions.md → grep -c pattern" || {
    echo "FAIL: set-e tag context not injected into prompt" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# B: with a fixture index, the prompt instructs the tag block + new-tags rule
# ---------------------------------------------------------------------------

@test "B: prompt instructs emitting the sharkrite-issue-tags block" {
  _write_tag_index
  _dump_prompt

  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

  # The open + close marker (built from RITE_MARKER_ISSUE_TAGS) must appear.
  echo "$output" | grep -qF "<!-- ${ISSUE_TAGS_MARKER} -->" || {
    echo "FAIL: open marker <!-- ${ISSUE_TAGS_MARKER} --> not in prompt" >&2
    false
  }
  echo "$output" | grep -qF "<!-- /${ISSUE_TAGS_MARKER} -->" || {
    echo "FAIL: close marker <!-- /${ISSUE_TAGS_MARKER} --> not in prompt" >&2
    false
  }
  # The tags: line instruction must be present.
  echo "$output" | grep -q "tags:" || {
    echo "FAIL: 'tags:' instruction missing from prompt" >&2
    false
  }
}

@test "B2: prompt instructs the new-tags: justification rule" {
  _write_tag_index
  _dump_prompt

  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

  echo "$output" | grep -q "new-tags:" || {
    echo "FAIL: 'new-tags:' justification rule missing from prompt" >&2
    false
  }
  # The instruction must tell Claude to SELECT from the existing tags.
  echo "$output" | grep -qi "SELECT from these" || {
    echo "FAIL: 'select from existing tags' instruction missing from prompt" >&2
    false
  }
  # And to justify any genuinely new tag.
  echo "$output" | grep -qi "justification" || {
    echo "FAIL: new-tag justification wording missing from prompt" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# C: missing index — clean degrade (no tag block instruction), still generates
# ---------------------------------------------------------------------------

@test "C: missing index — prompt does NOT instruct a tag block (clean degrade)" {
  # No tag-index.md written.
  _dump_prompt

  [ "$status" -eq 0 ] || {
    echo "FAIL: generate_issues (dry-run) exited $status with no index" >&2
    echo "$output" >&2; false
  }

  # No tag-block instruction should appear.
  echo "$output" | grep -qF "${ISSUE_TAGS_MARKER}" && {
    echo "FAIL: tag-block marker present in prompt despite missing index" >&2
    false
  }
  echo "$output" | grep -q "Available tags" && {
    echo "FAIL: Available-tags context present despite missing index" >&2
    false
  }
  echo "$output" | grep -q "new-tags:" && {
    echo "FAIL: new-tags rule present despite missing index" >&2
    false
  }

  # Generation still proceeds: the issue output format must still be present.
  echo "$output" | grep -q -- "---ISSUE---" || {
    echo "FAIL: issue output format missing — generation did not proceed" >&2
    false
  }
  echo "$output" | grep -q "Output format" || {
    echo "FAIL: 'Output format' section missing — generation did not proceed" >&2
    false
  }
  true
}

@test "D: scaffold-only index — clean degrade (no tag block instruction)" {
  cat > "$RITE_TEST_TMPDIR/docs/architecture/tag-index.md" <<'IDX'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

IDX
  _dump_prompt

  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

  echo "$output" | grep -qF "${ISSUE_TAGS_MARKER}" && {
    echo "FAIL: tag-block marker present for a scaffold-only (no tags) index" >&2
    false
  }
  # Still generates.
  echo "$output" | grep -q -- "---ISSUE---" || {
    echo "FAIL: issue output format missing for scaffold-only index" >&2
    false
  }
  true
}
