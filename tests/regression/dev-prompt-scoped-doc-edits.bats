#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh, lib/providers/claude.sh
# Regression test: the dev-session Phase 5 prohibition on doc edits must carry
# a Files-to-Modify carve-out so that issues that legitimately list a doc file
# in their Files to Modify section are not silently blocked.
#
# Without the carve-out, an issue that explicitly lists docs/foo.md in
# Files to Modify contradicts the blanket "Do NOT update files in docs/"
# prohibition — and per the #495 regression class, a blanket prohibition
# overrides the issue body, causing the model to silently skip the listed
# doc work.
#
# Related: #495 (Phase 4 framing regression — precedent for "one contradicting
# phrasing overrides a prohibition"), #466 (added Phase 4 prohibition while
# leaving the contradictory framing that #495 exposed).

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export WORKFLOW_FILE="${RITE_LIB_DIR}/core/claude-workflow.sh"
  export PROVIDER_FILE="${RITE_LIB_DIR}/providers/claude.sh"
}

# ---------------------------------------------------------------------------
# Phase 5 prohibition must carry the carve-out on the same line
# ---------------------------------------------------------------------------

@test "Phase 5 prohibition retains the docs/README/CHANGELOG restriction" {
  _p5=$(sed -n '/^### Phase 5: Code Comments/,/^### Phase 6:/p' "$WORKFLOW_FILE" || true)
  if ! echo "$_p5" | grep -qE 'Do NOT update files in docs/'; then
    echo "FAIL: Phase 5 no longer contains the docs/README/CHANGELOG prohibition"
    echo "$_p5"
    return 1
  fi
  true
}

@test "Phase 5 prohibition carries the Files-to-Modify carve-out" {
  _p5=$(sed -n '/^### Phase 5: Code Comments/,/^### Phase 6:/p' "$WORKFLOW_FILE" || true)
  if ! echo "$_p5" | grep -qE 'unless the issue.*Files to Modify.*explicitly lists them'; then
    echo "FAIL: Phase 5 prohibition is missing the Files-to-Modify carve-out"
    echo "$_p5"
    return 1
  fi
  true
}

@test "Phase 5 prohibition and carve-out appear on the same line" {
  _p5=$(sed -n '/^### Phase 5: Code Comments/,/^### Phase 6:/p' "$WORKFLOW_FILE" || true)
  if ! echo "$_p5" | grep -qE 'Do NOT update files in docs/.*unless the issue.*Files to Modify.*explicitly lists them'; then
    echo "FAIL: prohibition and carve-out are not on the same line in Phase 5"
    echo "$_p5" | grep -E 'Do NOT update|Files to Modify' || true
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Single-location invariant: the prohibition must exist exactly once in lib/
# ---------------------------------------------------------------------------

@test "prohibition text exists exactly once in lib/ (no un-carved copy)" {
  _count=$(grep -rn 'docs/, README, or CHANGELOG' "$RITE_LIB_DIR" | wc -l | tr -d ' ' || true)
  if [ "$_count" != "1" ]; then
    echo "FAIL: 'docs/, README, or CHANGELOG' appears $_count times in lib/ (expected exactly 1)"
    grep -rn 'docs/, README, or CHANGELOG' "$RITE_LIB_DIR" || true
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Fix-session Scope block must NOT gain a docs prohibition (different contract)
# ---------------------------------------------------------------------------

@test "fix-session Scope block has no docs/README/CHANGELOG prohibition" {
  _scope=$(sed -n '/^## Scope$/,/^$/p' "$WORKFLOW_FILE" || true)
  _count=$(echo "$_scope" | grep -c 'CHANGELOG' || true)
  if [ "$_count" != "0" ]; then
    echo "FAIL: fix-session Scope block unexpectedly contains a CHANGELOG reference"
    echo "$_scope" | grep 'CHANGELOG' || true
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Phase 5 heading must be unchanged (sed range terminator in existing tests)
# ---------------------------------------------------------------------------

@test "Phase 5 heading is still '### Phase 5: Code Comments' (sed range terminator)" {
  _count=$(grep -c '^### Phase 5: Code Comments' "$WORKFLOW_FILE" || true)
  if [ "$_count" != "1" ]; then
    echo "FAIL: '### Phase 5: Code Comments' heading not found or duplicated (count: $_count)"
    grep -n '^### Phase 5' "$WORKFLOW_FILE" || true
    return 1
  fi
  true
}

# ---------------------------------------------------------------------------
# Preamble + mock fixture audit: both silent on docs (nothing to reword)
# ---------------------------------------------------------------------------

@test "claude.sh preamble Phase 5 todo does not add a docs prohibition" {
  # The preamble's Phase 5 todo reads "Adding inline comments for complex logic"
  # and is intentionally silent on docs — the prohibition lives only in
  # claude-workflow.sh Phase 5 step 2. Verify no docs prohibition was added.
  if grep -q 'Do NOT update files in docs' "$PROVIDER_FILE"; then
    echo "FAIL: lib/providers/claude.sh now contains a docs prohibition"
    grep -n 'Do NOT update files in docs' "$PROVIDER_FILE" || true
    echo "If a cross-reference was added, it must carry the Files-to-Modify carve-out"
    return 1
  fi
  true
}

@test "gemini-mock fixture Phase 5 todo does not add a docs prohibition" {
  _mock_file="${BATS_TEST_DIRNAME}/../fixtures/providers/gemini-mock.sh"
  if [ ! -f "$_mock_file" ]; then
    skip "gemini-mock.sh not found at expected path"
  fi
  if grep -q 'Do NOT update files in docs' "$_mock_file"; then
    echo "FAIL: tests/fixtures/providers/gemini-mock.sh now contains a docs prohibition"
    grep -n 'Do NOT update files in docs' "$_mock_file" || true
    echo "If a cross-reference was added, it must carry the Files-to-Modify carve-out"
    return 1
  fi
  true
}
