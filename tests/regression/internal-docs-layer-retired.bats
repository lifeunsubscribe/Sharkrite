#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/core/workflow-runner.sh, bin/rite, lib/utils/config.sh
#
# The internal .rite/docs/ layer is retired (2026-10-21).
#
# It maintained four files (changelog/security/architecture/api) plus keyword-
# selected "ADRs" under .rite/docs/, on two paths:
#   - a one-time bootstrap in phase_pre_start_checks (bootstrap-docs.sh) that
#     ran whenever any of the four files was missing — 5m38s before issue #1's
#     dev session in orrery's first batch (2026-10-21);
#   - four background sub-assessments + reconcile + cross-doc validation on
#     every merge (assess-documentation.sh Layer 1) — ~5 min and ~100k tokens
#     per merge. RITE_DOC_ASSESSMENT_TIMEOUT only killed the parent script; the
#     backgrounded sub-assessments survived and kept spending tokens.
# Nothing read the output. See behavioral-design.md → "Documentation Drift".
#
# What survives in Layer 1: conventions catalog, tag-index reconcile, catalog
# commit — all deterministic. Layer 2 (doc-sync / changelog drift) is untouched.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  ASSESS_DOC="$RITE_REPO_ROOT/lib/core/assess-documentation.sh"
  WORKFLOW_RUNNER="$RITE_REPO_ROOT/lib/core/workflow-runner.sh"
}

teardown() {
  teardown_test_tmpdir
}

# Build a throwaway project at $PROJ with stub gh + claude on PATH. The claude
# stub logs every invocation's stdin so a test can count model calls. Call it
# directly (not in $(...)) so its exports reach the stubs.
_make_project() {
  PROJ="$RITE_TEST_TMPDIR/proj"
  local root="$PROJ"
  mkdir -p "$root/docs/architecture" "$root/.rite" "$RITE_TEST_TMPDIR/bin"
  git -C "$root" init -q -b main
  git -C "$root" config user.email t@t.t
  git -C "$root" config user.name t
  printf '# Sharkrite Conventions Catalog\n\n---\n' > "$root/docs/architecture/conventions.md"
  git -C "$root" add -A
  git -C "$root" commit -qm init

  export CLAUDE_CALL_LOG="$RITE_TEST_TMPDIR/claude-calls.log"
  : > "$CLAUDE_CALL_LOG"
  cat > "$RITE_TEST_TMPDIR/bin/claude" <<'STUB'
#!/bin/bash
{ printf '=== call:'; cat; printf '\n'; } >> "$CLAUDE_CALL_LOG"
echo "ok"
STUB
  cat > "$RITE_TEST_TMPDIR/bin/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "pr view")
    jq -n --arg body "$(cat "$PR_BODY_FILE")" \
      '{title:"Add a thing", body:$body, files:[{path:"lib/core/thing.sh"}], commits:[{messageHeadline:"Add a thing"}], reviews:[], comments:[]}'
    ;;
  "pr diff")
    printf 'diff --git a/lib/core/thing.sh b/lib/core/thing.sh\n+thing() { :; }\n'
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$RITE_TEST_TMPDIR/bin/claude" "$RITE_TEST_TMPDIR/bin/gh"

  export PR_BODY_FILE="$RITE_TEST_TMPDIR/pr-body.md"
  cat > "$PR_BODY_FILE" <<'BODY'
Adds a thing.

<!-- sharkrite-convention -->
title: retired-layer-smoke
rule: The catalog still updates after the internal layer is gone
why: Layer 1 keeps only deterministic catalog maintenance
example: |
  update_conventions_from_marker "$PR_NUMBER" "$PR_BODY"
references: #1
<!-- /sharkrite-convention -->
BODY
}

@test "retired files are gone" {
  [ ! -e "$RITE_REPO_ROOT/lib/core/bootstrap-docs.sh" ]
  [ ! -e "$RITE_REPO_ROOT/lib/utils/adr-generator.sh" ]
}

@test "workflow-runner: pre-start no longer bootstraps .rite/docs" {
  local body
  body=$(awk '/^phase_pre_start_checks[(][)]/,/^}/' "$WORKFLOW_RUNNER")
  [ -n "$body" ]
  [[ "$body" != *"bootstrap-docs"* ]]
  [[ "$body" != *".rite/docs"* ]]
  [[ "$body" != *"INTERNAL_DOCS"* ]]
}

@test "assess-documentation: no internal sub-assessment, reconcile or cross-doc code remains" {
  run grep -nE 'assess_internal_|reconcile_internal_doc|_validate_cross_doc_consistency|RITE_INTERNAL_DOCS_DIR|generate_adr_for_ref|partial_complete' "$ASSESS_DOC"
  [ "$status" -eq 1 ]
}

@test "assess-documentation: Layer 1 calls a model only for tag dedup inside reconcile_tag_index" {
  # reconcile_tag_index's similarity/coverage checks are part of the tag-index
  # system and fire only when a PR declares new tags; everything else in
  # Layer 1 is deterministic.
  local layer1
  layer1=$(awk '/^# LAYER 1:/,/^# LAYER 2:/' "$ASSESS_DOC" \
    | awk '/^reconcile_tag_index[(][)]/{skip=1} !skip{print} skip && /^}/{skip=0}')
  [ -n "$layer1" ]
  [[ "$layer1" == *"update_conventions_from_marker()"* ]]
  [[ "$layer1" != *"provider_run_"* ]]
}

@test "bin/rite: ADR backfill flags are removed" {
  run grep -nE -- '--no-backfill-adrs|--backfill-count|RITE_NO_BACKFILL_ADRS|RITE_BACKFILL_ADR_COUNT' "$RITE_REPO_ROOT/bin/rite"
  [ "$status" -eq 1 ]
}

@test "workflow-runner: default RITE_DOC_ASSESSMENT_TIMEOUT stays 300" {
  run grep -c 'RITE_DOC_ASSESSMENT_TIMEOUT:-300' "$WORKFLOW_RUNNER"
  [ "$output" -ge 1 ]
}

@test "behavioral: a merge updates the conventions catalog, writes no .rite/docs, and makes no model call beyond the CLI health check" {
  _make_project
  local root="$PROJ"

  run env PATH="$RITE_TEST_TMPDIR/bin:$PATH" RITE_PROJECT_ROOT="$root" \
    RITE_LIB_DIR="$RITE_REPO_ROOT/lib" RITE_DOC_MODE="" \
    bash "$ASSESS_DOC" 7 --auto --worktree "$root"
  [ "$status" -eq 0 ]

  grep -q '^## retired-layer-smoke$' "$root/docs/architecture/conventions.md"
  [ ! -e "$root/.rite/docs" ]

  # provider_validate_cli pipes "test" once; nothing else may reach the CLI.
  local calls
  calls=$(grep -c '^=== call:' "$CLAUDE_CALL_LOG" || true)
  [ "$calls" -eq 1 ]
  grep -q '^=== call:test$' "$CLAUDE_CALL_LOG"
}
