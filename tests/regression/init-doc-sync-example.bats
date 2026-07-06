#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite, templates/doc-sync.md.example
# tests/regression/init-doc-sync-example.bats
#
# Verifies that:
#   1. templates/doc-sync.md.example exists and is non-empty
#   2. bin/rite --init copies it as .rite/doc-sync.md.example (not .rite/doc-sync.md)
#      so it is inactive by default
#   3. README.md documents the opt-in path
#
# Structural tests: the template file and init copy-block are invariants
# that code cannot express as a runtime assertion without running --init
# end-to-end (which requires a real git repo + gh + Claude).

load '../helpers/setup'

setup() {
  setup_test_tmpdir
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Template existence
# ---------------------------------------------------------------------------

@test "templates/doc-sync.md.example exists and is non-empty" {
  [ -f "$RITE_REPO_ROOT/templates/doc-sync.md.example" ]
  [ -s "$RITE_REPO_ROOT/templates/doc-sync.md.example" ]
}

@test "templates/doc-sync.md.example documents how to activate (.rite/doc-sync.md)" {
  grep -q "doc-sync.md" "$RITE_REPO_ROOT/templates/doc-sync.md.example"
}

# ---------------------------------------------------------------------------
# bin/rite --init wiring: copy goes to .example (inactive), not active
# ---------------------------------------------------------------------------

@test "bin/rite copies doc-sync.md.example to .rite/ during init" {
  # Structural: the copy block must reference the correct source template
  grep -q "templates/doc-sync.md.example" "$RITE_REPO_ROOT/bin/rite"
}

@test "bin/rite copies doc-sync.md.example as .example suffix (stays inactive)" {
  # The destination must be doc-sync.md.example, NOT doc-sync.md
  # This ensures Layer 2 is opt-in: users copy .example to activate
  grep -qE 'doc-sync\.md\.example.*doc-sync\.md\.example|RITE_DATA_DIR.*doc-sync\.md\.example' \
    "$RITE_REPO_ROOT/bin/rite"
}

@test "bin/rite init block guards against overwriting existing doc-sync.md.example" {
  # The copy block must use [ ! -f ... ] guard (idempotent init)
  grep -q 'doc-sync.md.example' "$RITE_REPO_ROOT/bin/rite"
  # Verify it is wrapped in a [ ! -f ] guard (same pattern as other init copies)
  grep -A2 'doc-sync.md.example' "$RITE_REPO_ROOT/bin/rite" | grep -q '\-f'
}

# ---------------------------------------------------------------------------
# README documents the opt-in path
# ---------------------------------------------------------------------------

@test "README.md has a doc-sync section" {
  grep -q "doc-sync" "$RITE_REPO_ROOT/README.md"
}

@test "README.md explains how to activate Layer 2" {
  # Must mention copying .example to activate
  grep -q "doc-sync.md.example" "$RITE_REPO_ROOT/README.md"
  grep -q "doc-sync.md" "$RITE_REPO_ROOT/README.md"
}
