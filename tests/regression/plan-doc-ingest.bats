#!/usr/bin/env bats
# tests/regression/plan-doc-ingest.bats
#
# Regression tests for the docs/ auto-discovery feature in plan-issues.sh.
#
# Feature: `rite plan` auto-discovers ADRs, README.md, and docs/**/*.md and
# injects them into the generation prompt as authoritative grounding context.
# This prevents the planner from generating issues that conflict with ADR
# constraints that live only in docs (not carried by TODO comments in code).
#
# Acceptance criteria verified here:
#   A. ADR content appears in generation prompt (sentinel string test).
#   B. User-supplied doc_paths continue to load fully (no behavior change).
#   C. RITE_PLAN_DOC_BYTE_CAP=0 disables auto-discovery (escape hatch).
#   D. ADRs + README load in full even when total exceeds cap; remaining
#      docs are dropped alphabetically and logged to stderr (truncation policy).
#   E. Generation prompt contains the reconciliation instruction string.
#   F. Byte cap: doc that fits within remaining budget is included;
#      doc that exceeds remaining budget is skipped with a logged warning.
#
# Test strategy:
#   - Extract _collect_auto_docs and generate_issues-adjacent logic via awk.
#   - Use RITE_PLAN_DRYRUN_DUMP_PROMPT=1 to dump the assembled prompt without
#     making a provider call, then assert sentinel strings appear.
#   - Stub provider_detect_cli and gh_safe so plan_issues() doesn't require
#     a live GitHub connection.

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: source only the functions we need from plan-issues.sh, stubbing
# external dependencies that require network / live environment.
# ---------------------------------------------------------------------------

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

  # Create .rite dir so config.sh mkdir doesn't fail
  mkdir -p "$RITE_TEST_TMPDIR/.rite"

  # Stub print_* so output goes cleanly to stderr without requiring colors.sh
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Stub provider functions — no real provider needed for prompt-dump tests
  provider_detect_cli()           { return 0; }
  provider_run_streaming_prompt() { echo "STUB_STREAMING_OUTPUT"; }

  # Stub gh_safe — no GitHub connection needed
  gh_safe() { echo ""; }

  # Stub portable_sed_i (needed by plan-issues.sh sourcing chain)
  if ! declare -f portable_sed_i >/dev/null 2>&1; then
    if [ -f "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh" ]; then
      # shellcheck disable=SC1090
      source "${RITE_REPO_ROOT}/lib/utils/portable-cmds.sh"
    fi
  fi

  # Extract only _collect_auto_docs and generate_issues from plan-issues.sh
  # to avoid running the plan_issues() interactive body (reads from stdin).
  eval "$(awk '
    /^_collect_auto_docs\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
    /^generate_issues\(\)/ { in_fn=1; depth=0 }
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
# Helper: create a minimal docs/ tree in the test tmpdir
# ---------------------------------------------------------------------------

_make_docs_tree() {
  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"
}

# ---------------------------------------------------------------------------
# Fixture A: ADR sentinel appears in the assembled prompt
#
# An ADR with a unique sentinel string SENTINEL_ZQX42 lives in docs/.
# _collect_auto_docs must pick it up and include its content so that when
# generate_issues assembles the prompt, the sentinel is present.
# ---------------------------------------------------------------------------

@test "Fixture A: ADR sentinel string appears in the generation prompt" {
  _make_docs_tree

  # Place an ADR with a unique sentinel
  local adr_path="$RITE_TEST_TMPDIR/docs/ADR-001-payload-assembly.md"
  cat > "$adr_path" <<'ADR'
# ADR-001: Payload Assembly

SENTINEL_ZQX42

Payload must be assembled from multiple sources before transmission.
ADR

  # Collect auto docs
  local auto_docs
  auto_docs=$(_collect_auto_docs)

  # The sentinel must appear in the collected content
  echo "$auto_docs" | grep -q "SENTINEL_ZQX42" || {
    echo "FAIL: sentinel SENTINEL_ZQX42 not found in collected auto-docs" >&2
    echo "--- collected content ---" >&2
    echo "$auto_docs" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture A2: ADR appears in generate_issues prompt dump
#
# Uses RITE_PLAN_DRYRUN_DUMP_PROMPT=1 to dump the full prompt without a
# provider call, then asserts the sentinel is present.
# ---------------------------------------------------------------------------

@test "Fixture A2: ADR sentinel appears in generate_issues prompt dump" {
  _make_docs_tree

  local adr_path="$RITE_TEST_TMPDIR/docs/ADR-001-payload-assembly.md"
  cat > "$adr_path" <<'ADR'
# ADR-001

SENTINEL_ZQX42_PROMPT_DUMP

Design constraint: payload assembled from multiple sources.
ADR

  # Stub CLAUDE.md for project_context
  echo "# Test Project" > "$RITE_TEST_TMPDIR/CLAUDE.md"

  # Build doc_content as plan_issues() would (empty explicit paths here)
  local doc_content=""
  local auto_docs
  auto_docs=$(_collect_auto_docs)
  [ -n "$auto_docs" ] && doc_content+="$auto_docs"

  # Dump prompt via RITE_PLAN_DRYRUN_DUMP_PROMPT=1
  export RITE_PLAN_DRYRUN_DUMP_PROMPT=1
  local prompt_output
  prompt_output=$(generate_issues \
    "$doc_content" \
    "$(head -150 "$RITE_TEST_TMPDIR/CLAUDE.md")" \
    "" "" "" "" "2hr" "" "" "")

  # Sentinel must appear in the prompt
  echo "$prompt_output" | grep -q "SENTINEL_ZQX42_PROMPT_DUMP" || {
    echo "FAIL: sentinel not found in dumped prompt" >&2
    echo "--- prompt (first 50 lines) ---" >&2
    echo "$prompt_output" | head -50 >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture B: explicit doc_paths continue to load fully (no behavior change)
#
# User supplies an explicit path. The doc must appear in the prompt exactly
# once (not duplicated by auto-discovery).
# ---------------------------------------------------------------------------

@test "Fixture B: user-supplied doc_paths load without double-injection" {
  _make_docs_tree

  local user_doc="$RITE_TEST_TMPDIR/docs/my-spec.md"
  cat > "$user_doc" <<'DOC'
# My Spec

SENTINEL_USER_DOC_UNIQUE

Implementation specification.
DOC

  # Also place an ADR so auto-discovery has something to find
  cat > "$RITE_TEST_TMPDIR/docs/ADR-002-test.md" <<'ADR'
# ADR-002: Test ADR
ADR

  # Collect auto docs — passing user_doc as already-loaded to prevent injection
  local auto_docs
  auto_docs=$(_collect_auto_docs "$user_doc")

  # ADR must appear (auto-discovered)
  echo "$auto_docs" | grep -q "ADR-002" || {
    echo "FAIL: auto-discovered ADR not found in auto_docs" >&2
    false
  }

  # User doc sentinel must NOT appear in auto_docs (it was passed as already-loaded)
  local found_user_sentinel
  found_user_sentinel=$(echo "$auto_docs" | grep -c "SENTINEL_USER_DOC_UNIQUE" || true)
  [ "$found_user_sentinel" -eq 0 ] || {
    echo "FAIL: user-supplied doc was double-injected by auto-discovery" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture C: RITE_PLAN_DOC_BYTE_CAP=0 disables auto-discovery
# ---------------------------------------------------------------------------

@test "Fixture C: RITE_PLAN_DOC_BYTE_CAP=0 disables auto-discovery" {
  _make_docs_tree

  cat > "$RITE_TEST_TMPDIR/docs/ADR-003-disabled.md" <<'ADR'
# ADR-003

SENTINEL_DISABLED_CAP_ZERO

This should not appear when cap=0.
ADR

  export RITE_PLAN_DOC_BYTE_CAP=0

  local auto_docs
  auto_docs=$(_collect_auto_docs)

  # Output must be empty — no auto-discovery when cap=0
  [ -z "$auto_docs" ] || {
    echo "FAIL: expected empty output with cap=0, got:" >&2
    echo "$auto_docs" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture D: ADRs and README load in full even when total exceeds cap;
# other docs are skipped with a logged warning when budget is exhausted.
# ---------------------------------------------------------------------------

@test "Fixture D: ADR and README load in full; over-budget docs are skipped with warning" {
  _make_docs_tree

  # Large ADR that will exceed the cap on its own
  local big_adr="$RITE_TEST_TMPDIR/docs/ADR-big.md"
  # Create ~200B content
  printf '# Big ADR\n\nSENTINEL_BIG_ADR\n\n%s\n' "$(head -c 180 /dev/zero | tr '\0' 'x')" > "$big_adr"

  # Small other doc that would fit but cap is already exceeded by the ADR
  local other_doc="$RITE_TEST_TMPDIR/docs/other-notes.md"
  printf '# Notes\n\nSENTINEL_OTHER_NOTES\n' > "$other_doc"

  # Set cap to 100 — smaller than the big ADR (~200B) to trigger "exceeded" path
  export RITE_PLAN_DOC_BYTE_CAP=100

  local auto_docs
  local stderr_out
  stderr_out=$(mktemp)
  auto_docs=$(_collect_auto_docs 2>"$stderr_out")

  # Big ADR must appear in full (ADRs always load regardless of cap)
  echo "$auto_docs" | grep -q "SENTINEL_BIG_ADR" || {
    echo "FAIL: big ADR sentinel not found — ADR must load even when it exceeds cap" >&2
    false
  }

  # other-notes.md must NOT appear (budget exhausted by ADR)
  echo "$auto_docs" | grep -q "SENTINEL_OTHER_NOTES" && {
    echo "FAIL: over-budget doc was included despite budget being exhausted" >&2
    false
  }

  # A skip warning must have been logged to stderr
  grep -q "skipping" "$stderr_out" || {
    echo "FAIL: expected a 'skipping' warning for the over-budget doc" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture E: generation prompt contains the reconciliation instruction string
# ---------------------------------------------------------------------------

@test "Fixture E: generation prompt contains the reconciliation instruction" {
  # No docs needed — just verify the prompt text
  echo "# Test Project" > "$RITE_TEST_TMPDIR/CLAUDE.md"

  export RITE_PLAN_DRYRUN_DUMP_PROMPT=1
  local prompt_output
  prompt_output=$(generate_issues \
    "" \
    "project context" \
    "" "" "" "" "2hr" "" "" "")

  echo "$prompt_output" | grep -q "Reconcile.*TODO\|RECONCILE TODOS" || {
    echo "FAIL: reconciliation instruction not found in prompt" >&2
    echo "--- prompt (first 80 lines) ---" >&2
    echo "$prompt_output" | head -80 >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture F: byte cap budget — doc within budget is included,
# doc beyond budget is skipped
# ---------------------------------------------------------------------------

@test "Fixture F: docs within remaining budget are included; docs beyond budget are skipped" {
  _make_docs_tree

  # Small doc that fits
  local small_doc="$RITE_TEST_TMPDIR/docs/small.md"
  printf '# Small\n\nSENTINEL_SMALL_DOC\n' > "$small_doc"
  local small_bytes
  small_bytes=$(wc -c < "$small_doc")

  # Large doc that won't fit — twice the cap size
  local large_doc="$RITE_TEST_TMPDIR/docs/zzz-large.md"  # zzz- prefix sorts last
  printf '# Large\n\nSENTINEL_LARGE_DOC\n%s\n' "$(head -c 600 /dev/zero | tr '\0' 'y')" > "$large_doc"

  # Set cap just large enough for small_doc but not large_doc
  export RITE_PLAN_DOC_BYTE_CAP=$((small_bytes + 50))

  local auto_docs
  local stderr_out
  stderr_out=$(mktemp)
  auto_docs=$(_collect_auto_docs 2>"$stderr_out")

  # small_doc must appear
  echo "$auto_docs" | grep -q "SENTINEL_SMALL_DOC" || {
    echo "FAIL: small doc not found in auto_docs (it should fit within budget)" >&2
    false
  }

  # large_doc must NOT appear
  echo "$auto_docs" | grep -q "SENTINEL_LARGE_DOC" && {
    echo "FAIL: large doc was included despite exceeding the remaining budget" >&2
    false
  }

  # A skip warning must have been logged
  grep -q "skipping" "$stderr_out" || {
    echo "FAIL: expected a 'skipping' warning for the over-budget large doc" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture G: README.md is auto-discovered and injected
# ---------------------------------------------------------------------------

@test "Fixture G: README.md at project root is auto-discovered and injected" {
  printf '# My Project README\n\nSENTINEL_README_CONTENT\n' > "$RITE_TEST_TMPDIR/README.md"

  local auto_docs
  auto_docs=$(_collect_auto_docs)

  echo "$auto_docs" | grep -q "SENTINEL_README_CONTENT" || {
    echo "FAIL: README sentinel not found in collected auto-docs" >&2
    echo "--- collected content ---" >&2
    echo "$auto_docs" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture H: no docs/ directory — _collect_auto_docs exits cleanly
# ---------------------------------------------------------------------------

@test "Fixture H: no docs/ directory — _collect_auto_docs exits cleanly with empty output" {
  # No docs/ dir in RITE_TEST_TMPDIR

  local auto_docs
  auto_docs=$(_collect_auto_docs)

  # Should produce empty output (no crash, no warning)
  [ -z "$auto_docs" ] || {
    echo "FAIL: expected empty output when no docs/ exists, got:" >&2
    echo "$auto_docs" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: _collect_auto_docs is defined in plan-issues.sh source
# ---------------------------------------------------------------------------

@test "acceptance: _collect_auto_docs function is defined in plan-issues.sh" {
  grep -q "^_collect_auto_docs()" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" || {
    echo "FAIL: _collect_auto_docs function not found in plan-issues.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: RITE_PLAN_DOC_BYTE_CAP is declared in config.sh
# ---------------------------------------------------------------------------

@test "acceptance: RITE_PLAN_DOC_BYTE_CAP is declared in config.sh" {
  grep -q "RITE_PLAN_DOC_BYTE_CAP" "${RITE_REPO_ROOT}/lib/utils/config.sh" || {
    echo "FAIL: RITE_PLAN_DOC_BYTE_CAP not found in config.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: reconciliation instruction string is in plan-issues.sh prompt
# ---------------------------------------------------------------------------

@test "acceptance: reconciliation instruction string exists in plan-issues.sh" {
  grep -q "Reconcile.*TODO\|RECONCILE TODOS" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" || {
    echo "FAIL: reconciliation instruction not found in plan-issues.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture I: dedup — docs/README.md and root README.md produce distinct headers
#
# When both files exist, their block labels must differ so that a reader of
# the assembled prompt can distinguish which content came from which file.
# Before the fix, both used basename-only labels (--- README.md ---), producing
# two identically-labeled blocks with different content.
# ---------------------------------------------------------------------------

@test "Fixture I: docs/README.md and root README.md produce distinct headers" {
  mkdir -p "$RITE_TEST_TMPDIR/docs"

  # Root README
  printf '# Root README\nSENTINEL_ROOT_README\n' > "$RITE_TEST_TMPDIR/README.md"

  # docs/README.md — same basename, different path and content
  printf '# Docs README\nSENTINEL_DOCS_README\n' > "$RITE_TEST_TMPDIR/docs/README.md"

  local auto_docs
  auto_docs=$(_collect_auto_docs)

  # Both sentinels must appear
  echo "$auto_docs" | grep -q "SENTINEL_ROOT_README" || {
    echo "FAIL: root README sentinel not found in auto_docs" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }
  echo "$auto_docs" | grep -q "SENTINEL_DOCS_README" || {
    echo "FAIL: docs/README.md sentinel not found in auto_docs" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }

  # Headers must be distinct — the root uses "README.md" and the docs one
  # uses the project-relative path "docs/README.md".
  echo "$auto_docs" | grep -q "^--- README.md ---" || {
    echo "FAIL: root README header '--- README.md ---' not found" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }
  echo "$auto_docs" | grep -q "^--- docs/README.md ---" || {
    echo "FAIL: docs/README.md relative-path header '--- docs/README.md ---' not found" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }

  # Count occurrences of "--- README.md ---": must be exactly 1 (root only).
  # "docs/README.md" must appear separately.
  local root_count
  root_count=$(echo "$auto_docs" | grep -c "^--- README.md ---" || true)
  [ "$root_count" -eq 1 ] || {
    echo "FAIL: expected exactly 1 '--- README.md ---' header, got $root_count" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture J: RITE_PLAN_INCLUDE_README=false skips root README injection
# ---------------------------------------------------------------------------

@test "Fixture J: RITE_PLAN_INCLUDE_README=false suppresses root README injection" {
  printf '# My Project README\nSENTINEL_README_SKIP\n' > "$RITE_TEST_TMPDIR/README.md"

  local auto_docs
  RITE_PLAN_INCLUDE_README=false auto_docs=$(_collect_auto_docs)

  # README content must NOT appear
  ! echo "$auto_docs" | grep -q "SENTINEL_README_SKIP" || {
    echo "FAIL: README content found in auto_docs despite RITE_PLAN_INCLUDE_README=false" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }
}

@test "Fixture J2: RITE_PLAN_INCLUDE_README=0 suppresses root README injection" {
  printf '# My Project README\nSENTINEL_README_SKIP_ZERO\n' > "$RITE_TEST_TMPDIR/README.md"

  local auto_docs
  RITE_PLAN_INCLUDE_README=0 auto_docs=$(_collect_auto_docs)

  ! echo "$auto_docs" | grep -q "SENTINEL_README_SKIP_ZERO" || {
    echo "FAIL: README content found in auto_docs despite RITE_PLAN_INCLUDE_README=0" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }
}

@test "Fixture J3: RITE_PLAN_INCLUDE_README=true (default) still injects root README" {
  printf '# My Project README\nSENTINEL_README_DEFAULT\n' > "$RITE_TEST_TMPDIR/README.md"

  local auto_docs
  RITE_PLAN_INCLUDE_README=true auto_docs=$(_collect_auto_docs)

  echo "$auto_docs" | grep -q "SENTINEL_README_DEFAULT" || {
    echo "FAIL: README content not found despite RITE_PLAN_INCLUDE_README=true" >&2
    echo "--- collected ---" >&2
    echo "$auto_docs" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: RITE_PLAN_INCLUDE_README is declared in config.sh
# ---------------------------------------------------------------------------

@test "acceptance: RITE_PLAN_INCLUDE_README is declared in config.sh" {
  grep -q "RITE_PLAN_INCLUDE_README" "${RITE_REPO_ROOT}/lib/utils/config.sh" || {
    echo "FAIL: RITE_PLAN_INCLUDE_README not found in config.sh" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: RITE_PLAN_INCLUDE_README is documented in project.conf.example
# ---------------------------------------------------------------------------

@test "acceptance: RITE_PLAN_INCLUDE_README is documented in project.conf.example" {
  grep -q "RITE_PLAN_INCLUDE_README" "${RITE_REPO_ROOT}/config/project.conf.example" || {
    echo "FAIL: RITE_PLAN_INCLUDE_README not documented in config/project.conf.example" >&2
    false
  }
}
