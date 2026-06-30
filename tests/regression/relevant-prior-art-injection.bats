#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Regression test: "Relevant prior art" injection wiring (#403 Stage 4, sub-issue S4-4)
#
# Covers build_relevant_prior_art — the integration step that wires the merged
# read-path helpers (lookup_tag_pointers + slice_section, relevance_grep) into the
# Phase 1 dev prompt. The helpers themselves are unit-tested by S4-1/2/3
# (tag-index-read-helpers.bats, relevance-grep.bats); this file tests only the
# dispatch/assembly/wiring layer.
#
# Tag-resolution fallback chain under test:
#   Path A (explicit tags)  — <!-- sharkrite-issue-tags --> block → sliced sections
#   Path C (keyword grep)   — title/body keyword matches a tag-index heading
#   Path D (no match)       — empty block; CLAUDE_PROMPT byte-identical to pre-#403
#   #773 regression         — typo'd-ONLY explicit tag (zero pointers) falls through
#                             to keyword matching instead of degrading to "no prior art"
#
# CRITICAL: every `source` of claude-workflow.sh in this file is prefixed with
# RITE_SOURCE_FUNCTIONS_ONLY=1 so it loads only the function definitions and never
# launches a real Claude Code dev session (the #775 gate failure was an unguarded
# source; phase3-no-dev-session-leak.bats / lib-resource-safety.bats catch it).

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_INSTALL_DIR="$RITE_REPO_ROOT"
  export RITE_DATA_DIR=".rite"

  mkdir -p "$RITE_TEST_TMPDIR/docs/architecture"
  mkdir -p "$RITE_TEST_TMPDIR/.rite"
  mkdir -p "$RITE_TEST_TMPDIR/lib/utils"
  mkdir -p "$RITE_TEST_TMPDIR/bin"

  TAG_INDEX_PATH="$RITE_TEST_TMPDIR/docs/architecture/tag-index.md"
  CONVENTIONS_PATH="$RITE_TEST_TMPDIR/docs/architecture/conventions.md"
  ENCOUNTERED_PATH="$RITE_TEST_TMPDIR/docs/architecture/encountered-issues.md"
  BEHAVIORAL_PATH="$RITE_TEST_TMPDIR/docs/architecture/behavioral-design.md"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Fixtures (reused from the stranded S4-4 attempt)
# ---------------------------------------------------------------------------

_seed_tag_index() {
  cat > "$TAG_INDEX_PATH" <<'EOTAG'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## subshell

- conventions.md → Subshell variable loss
- encountered-issues.md → Subshell pipefail propagation

## set-e

- conventions.md → grep -c pattern
- conventions.md → Silent death: pipelines inside $()

## gh-cli

- conventions.md → CWD after worktree removal
EOTAG
}

_seed_conventions() {
  cat > "$CONVENTIONS_PATH" <<'EOCONV'
# Conventions

## Subshell variable loss

Variables set inside `while read | pipe` are lost. Use process substitution or temp files.

This is a short section for testing.

## grep -c pattern

`grep -c` always outputs a count but returns exit code 1 when count is 0.

Use `|| true` to suppress the exit code.

## CWD after worktree removal

When merge-pr.sh finishes a successful merge it removes the feature-branch worktree.
The shell that called merge-pr.sh is still cd'd inside that now-deleted directory.
EOCONV
}

_seed_encountered_issues() {
  cat > "$ENCOUNTERED_PATH" <<'EOENC'
# Encountered Issues

## Subshell pipefail propagation

Pipelines inside $() run in a subshell. Under set -euo pipefail, a failing pipeline
inside $() kills the script silently.
EOENC
}

# ---------------------------------------------------------------------------
# Helper: run build_relevant_prior_art in isolation.
# Sources claude-workflow.sh under RITE_SOURCE_FUNCTIONS_ONLY=1 so ONLY the
# function definitions load (no dev session). stderr is captured into $output
# alongside stdout via `run` so the diagnostic-line assertions work.
# ---------------------------------------------------------------------------
_run_build_prior_art() {
  local issue_body="$1"
  local labels_csv="${2:-}"
  local issue_title="${3:-}"
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_SOURCE_FUNCTIONS_ONLY=1

    # Stub print helpers (build_relevant_prior_art routes its own logging to
    # stderr, but the sourced file's other functions may reference these).
    print_info()    { echo \"\$*\" >&2; }
    print_status()  { echo \"\$*\" >&2; }
    print_success() { echo \"\$*\" >&2; }
    print_warning() { echo \"\$*\" >&2; }
    gh_safe() { echo ''; }

    source '$RITE_LIB_DIR/utils/config.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/colors.sh' 2>/dev/null || true
    source '$RITE_LIB_DIR/utils/markers.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    # RITE_SOURCE_FUNCTIONS_ONLY=1 — load defs only, never start a dev session.
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'

    build_relevant_prior_art \
      $(printf '%q' "$issue_body") \
      '42' \
      '$RITE_TEST_TMPDIR' \
      $(printf '%q' "$labels_csv") \
      $(printf '%q' "$issue_title")
  "
}

# ===========================================================================
# Path A — explicit <!-- sharkrite-issue-tags --> block
# ===========================================================================

@test "Path A: explicit tag block yields sliced section + 'using explicit issue tags' on stderr" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  local issue_body
  issue_body=$(cat <<'EOBODY'
## Description
Fix a subshell variable-loss bug.

<!-- sharkrite-issue-tags -->
tags: subshell
<!-- /sharkrite-issue-tags -->
EOBODY
)

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Relevant prior art" ]]
  [[ "$output" =~ "Subshell variable loss" ]]
  [[ "$output" =~ "using explicit issue tags" ]]
}

@test "Path A: explicit multi-tag block loads pointers from all tags" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  local issue_body
  issue_body=$(cat <<'EOBODY'
## Description
Two unrelated areas.

<!-- sharkrite-issue-tags -->
tags: subshell, set-e
<!-- /sharkrite-issue-tags -->
EOBODY
)

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Subshell variable loss" ]]
  [[ "$output" =~ "grep -c pattern" ]]
  [[ "$output" =~ "using explicit issue tags" ]]
}

# ===========================================================================
# Path B — tags derived from GitHub issue labels matching ## headings (#777)
#
# Two label sources are covered, distinguished by the 'using label-derived tags'
# stderr line (so a Path-B pass can never be mistaken for Path A/C/D):
#   Test 1 — pre-fetched CSV (arg 4): the STANDALONE path's network-lazy reuse.
#   Test 2 — orchestrated fetch: arg 4 EMPTY, gh_safe stubbed to return the labels;
#            proves Path B works when the CSV was never prefetched (the #777 gap —
#            PR #771's bats only ever called the function with 3 args).
# ===========================================================================

@test "Path B: pre-fetched labels CSV (arg 4) → label-derived section + 'using label-derived tags' on stderr" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  # Body has NO explicit tag block and NO keyword that matches a heading
  # (avoids 'subshell'/'set-e'/'gh-cli'), so Path A and Path C cannot fire.
  # The labels CSV carries 'gh-cli', which matches the '## gh-cli' heading and
  # resolves to 'conventions.md → CWD after worktree removal'.
  local issue_body="Adjust an unrelated configuration knob with none of those words."

  _run_build_prior_art "$issue_body" "gh-cli"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Relevant prior art" ]]
  # The sliced section body proves the label-derived pointer was loaded.
  [[ "$output" =~ "CWD after worktree removal" ]]
  [[ "$output" =~ "removes the feature-branch worktree" ]]
  # Distinguishing stderr line — Path B, not A/C/D.
  [[ "$output" =~ "using label-derived tags" ]]
  # Negative: the other paths' diagnostics must NOT appear.
  [[ ! "$output" =~ "using explicit issue tags" ]]
  [[ ! "$output" =~ "using keyword-matched tags" ]]
}

@test "Path B: empty CSV + non-empty issue number → gh_safe-fetched labels still resolve (orchestrated path, #777)" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  # arg 4 EMPTY (as the orchestrated `rite N` path passes it). gh_safe is STUBBED
  # to return the labels CSV that the real `gh issue view --json labels --jq ...`
  # would emit. With the CSV empty, the ONLY way label-derived resolution can
  # occur is via the orchestrated fetch — so the section + diagnostic prove it
  # fired. A file sentinel additionally proves the STUB itself was consulted: the
  # function wraps the gh_safe call in `2>/dev/null`, so a stderr sentinel would be
  # swallowed; a touched file survives.
  # Body has no tag block and no keyword match so only the FETCH can drive Path B.
  local fetch_sentinel="$RITE_TEST_TMPDIR/gh_safe_called"

  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_SOURCE_FUNCTIONS_ONLY=1

    print_info()    { echo \"\$*\" >&2; }
    print_status()  { echo \"\$*\" >&2; }
    print_success() { echo \"\$*\" >&2; }
    print_warning() { echo \"\$*\" >&2; }

    source '$RITE_LIB_DIR/utils/markers.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'

    # Orchestrated-fetch stub: the function calls
    #   gh_safe issue view N --json labels --jq '[.labels[].name]|join(\",\")'
    # and captures stdout as the labels CSV. Return what jq would have produced,
    # and touch a file to PROVE the fetch branch consulted this stub (the call is
    # wrapped in 2>/dev/null inside the function, so a stderr marker is swallowed).
    # NOTE: defined AFTER sourcing claude-workflow.sh — that file sources
    # gh-retry.sh (the real gh_safe), which would otherwise override an earlier stub.
    gh_safe() {
      touch '$fetch_sentinel'
      echo 'gh-cli'
    }

    build_relevant_prior_art \
      'Adjust an unrelated configuration knob with none of those words.' \
      '4242' \
      '$RITE_TEST_TMPDIR' \
      '' \
      ''
  "

  [ "$status" -eq 0 ]
  # The fetch branch was reached — the stub was consulted (file sentinel).
  [ -f "$fetch_sentinel" ]
  # Path B resolved the fetched label → its catalog section is in stdout.
  [[ "$output" =~ "Relevant prior art" ]]
  [[ "$output" =~ "CWD after worktree removal" ]]
  # Distinguishing stderr line fires for the fetched case too.
  [[ "$output" =~ "using label-derived tags" ]]
}

# ===========================================================================
# Path C — keyword grep of title/body against tag-index headings
# ===========================================================================

@test "Path C: body keyword matches heading → prior art + 'using keyword-matched tags' on stderr" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  # No tag block, no labels — body mentions "subshell" (a ## heading).
  local issue_body="This issue fixes a bug related to subshell behavior in pipelines."

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Relevant prior art" ]]
  [[ "$output" =~ "Subshell variable loss" ]]
  [[ "$output" =~ "using keyword-matched tags" ]]
}

@test "Path C: title-only keyword match still resolves prior art" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  local issue_title="Harden subshell handling in the runner"
  local issue_body="Body with no matching keywords whatsoever."

  _run_build_prior_art "$issue_body" "" "$issue_title"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "Subshell variable loss" ]]
  [[ "$output" =~ "using keyword-matched tags" ]]
}

# ===========================================================================
# Path D — no match returns empty (no regression)
# ===========================================================================

@test "Path D: no tags + no keyword hits + no grep hits → empty stdout" {
  _seed_tag_index
  _seed_conventions

  # Body matches no heading and has no file-path / backtick symbols → grep empty
  # too. Assert on stdout in isolation (the function may log to stderr).
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_SOURCE_FUNCTIONS_ONLY=1
    gh_safe() { echo ''; }
    source '$RITE_LIB_DIR/utils/markers.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'
    out=\$(build_relevant_prior_art 'Adjust an unrelated configuration knob with none of those words.' '42' '$RITE_TEST_TMPDIR' '' '' 2>/dev/null)
    [ -z \"\$out\" ] && echo EMPTY_STDOUT || { echo \"NONEMPTY:[\$out]\"; exit 1; }
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "EMPTY_STDOUT" ]]
}

@test "Path D: empty prior-art block makes CLAUDE_PROMPT byte-identical to pre-#403 wiring" {
  _seed_tag_index
  _seed_conventions

  # Reproduces the call-site interpolation: when build_relevant_prior_art returns
  # empty, RELEVANT_PRIOR_ART_PROMPT stays "" and the assembled span
  # ${SECURITY_PROMPT}${RELEVANT_PRIOR_ART_PROMPT}${ENCOUNTERED_ISSUES_PROMPT}
  # must equal the pre-#403 span ${SECURITY_PROMPT}${ENCOUNTERED_ISSUES_PROMPT}.
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_SOURCE_FUNCTIONS_ONLY=1

    print_info()    { echo \"\$*\" >&2; }
    print_status()  { echo \"\$*\" >&2; }
    print_success() { echo \"\$*\" >&2; }
    print_warning() { echo \"\$*\" >&2; }
    gh_safe() { echo ''; }

    source '$RITE_LIB_DIR/utils/markers.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'

    SECURITY_PROMPT='SEC'
    ENCOUNTERED_ISSUES_PROMPT='ENC'

    _block=\$(build_relevant_prior_art 'Adjust an unrelated knob with none of those words.' '42' '$RITE_TEST_TMPDIR' '' '' 2>/dev/null || true)
    RELEVANT_PRIOR_ART_PROMPT=''
    if [ -n \"\${_block:-}\" ]; then RELEVANT_PRIOR_ART_PROMPT=\"\$_block\"; fi

    WITH=\"\${SECURITY_PROMPT}\${RELEVANT_PRIOR_ART_PROMPT}\${ENCOUNTERED_ISSUES_PROMPT}\"
    WITHOUT=\"\${SECURITY_PROMPT}\${ENCOUNTERED_ISSUES_PROMPT}\"
    [ \"\$WITH\" = \"\$WITHOUT\" ] && echo IDENTICAL || { echo \"DIFF: [\$WITH]\"; exit 1; }
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "IDENTICAL" ]]
}

# ===========================================================================
# #773 regression — explicit tags are NOT authoritative when they resolve to
# zero pointers. A typo'd-only tag block PLUS a real keyword in the body must
# fall through to Path C, not degrade straight to "no prior art".
# ===========================================================================

@test "#773: typo'd-only explicit tag (0 pointers) + real body keyword falls through to keyword match" {
  _seed_tag_index
  _seed_conventions
  _seed_encountered_issues

  # The tag block names ONLY a tag that doesn't exist in the index → 0 pointers.
  # The body separately mentions "subshell" (a real ## heading) → Path C resolves it.
  local issue_body
  issue_body=$(cat <<'EOBODY'
## Description
This change adjusts subshell handling.

<!-- sharkrite-issue-tags -->
tags: typo-nonexistent-tag
<!-- /sharkrite-issue-tags -->
EOBODY
)

  _run_build_prior_art "$issue_body"

  [ "$status" -eq 0 ]
  # MUST NOT be empty — the typo'd tag is not authoritative; keyword match wins.
  [ -n "$output" ]
  [[ "$output" =~ "Subshell variable loss" ]]
  # The fall-through diagnostic confirms Path A declined and Path C took over.
  [[ "$output" =~ "resolved to 0 pointers" ]]
  [[ "$output" =~ "using keyword-matched tags" ]]
}

@test "#773: typo'd-only explicit tag with NO body keyword still returns empty stdout (true Path D)" {
  _seed_tag_index
  _seed_conventions

  # Typo'd tag AND no real keyword anywhere → nothing resolves → empty STDOUT.
  # The function still logs a "resolved to 0 pointers" line to STDERR, so this
  # test captures stdout in isolation (2>/dev/null) rather than the merged
  # stream `run` would give — the contract is "stdout carries only the block".
  run bash -c "
    set -euo pipefail
    export RITE_PROJECT_ROOT='$RITE_TEST_TMPDIR'
    export RITE_LIB_DIR='$RITE_LIB_DIR'
    export RITE_INSTALL_DIR='$RITE_INSTALL_DIR'
    export RITE_SOURCE_FUNCTIONS_ONLY=1
    gh_safe() { echo ''; }
    source '$RITE_LIB_DIR/utils/markers.sh'
    source '$RITE_LIB_DIR/utils/tag-index.sh'
    source '$RITE_LIB_DIR/utils/relevance-grep.sh'
    RITE_SOURCE_FUNCTIONS_ONLY=1 source '$RITE_LIB_DIR/core/claude-workflow.sh'
    _body='## Description
Adjust an unrelated knob with none of those special words.

<!-- '\"\${RITE_MARKER_ISSUE_TAGS}\"' -->
tags: typo-nonexistent-tag
<!-- /'\"\${RITE_MARKER_ISSUE_TAGS}\"' -->'
    out=\$(build_relevant_prior_art \"\$_body\" '42' '$RITE_TEST_TMPDIR' '' '' 2>/dev/null)
    [ -z \"\$out\" ] && echo EMPTY_STDOUT || { echo \"NONEMPTY:[\$out]\"; exit 1; }
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ "EMPTY_STDOUT" ]]
}

# ===========================================================================
# Robustness — null/empty body must not crash under set -euo pipefail
# ===========================================================================

@test "null issue body does not crash" {
  _seed_tag_index
  _run_build_prior_art "null"
  [ "$status" -eq 0 ]
}

@test "empty issue body does not crash" {
  _seed_tag_index
  _run_build_prior_art ""
  [ "$status" -eq 0 ]
}
