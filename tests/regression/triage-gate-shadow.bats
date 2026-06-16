#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/local-review.sh, lib/utils/triage-classify.sh
#
# Triage gate — SHADOW mode (_triage_emit_shadow). PR-1 lands shadow-only:
# classify the diff and emit a paired TRIAGE_SHADOW diag alongside the real
# opus review; NOTHING is skipped. These tests lock in the two-layer contract:
#   - Layer-1 deterministic guards force "substantive" regardless of the
#     classifier (and the classifier is NOT called when a guard trips).
#   - Layer-2 classifier decides the cleared remainder; low confidence escalates.
# The classifier and gh are stubbed so tests are offline + deterministic.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_MARKER_REVIEW="sharkrite-local-review"
  export RITE_TRIAGE_MAX_FILES=3
  export RITE_TRIAGE_MAX_LINES=30
  unset RITE_VERBOSE

  # Load only the function defs (no script body / no gh / no claude).
  RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/core/local-review.sh"

  # Stubs: capture the diag, no prior reviews (first pass), classifier verdict
  # is driven per-test via TRIAGE_STUB_VERDICT / TRIAGE_STUB_CONF.
  _diag() { echo "$1"; }
  gh_safe() { echo "${GH_PRIOR_REVIEWS:-0}"; }
  claude_provider_resolve_model() { echo "claude-haiku-4-5"; }
  provider_run_prompt() {
    printf '{"verdict":"%s","confidence":%s,"reason":"stub"}\n' \
      "${TRIAGE_STUB_VERDICT:-substantive}" "${TRIAGE_STUB_CONF:-0.9}"
  }
  export -f _diag gh_safe claude_provider_resolve_model provider_run_prompt
}

_run_shadow() { # $1=diff $2=files
  _triage_emit_shadow 42 "$1" "$2" 0 0 1 1
}

@test "shadow: trivial docs diff, no guard → classifier verdict trivial" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  diff=$(printf 'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n+a documentation line\n')
  run _run_shadow "$diff" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRIAGE_SHADOW"* ]]
  [[ "$output" == *"haiku=trivial"* ]]
  [[ "$output" == *"guard=none"* ]]
  [[ "$output" == *"category=docs"* ]]
}

@test "shadow: deletion present → Layer-1 guard forces substantive" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.99  # classifier WOULD say trivial...
  diff=$(printf 'diff --git a/x.sh b/x.sh\ndeleted file mode 100644\n--- a/x.sh\n+++ /dev/null\n-old\n')
  run _run_shadow "$diff" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"haiku=substantive"* ]]   # ...but the guard overrides it
  [[ "$output" == *"guard=deletion"* ]]
}

@test "shadow: security token added → guard=security" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.99
  diff=$(printf 'diff --git a/a.sh b/a.sh\n+++ b/a.sh\n+  eval "$cmd"\n')
  run _run_shadow "$diff" 1
  [[ "$output" == *"haiku=substantive"* ]]
  [[ "$output" == *"guard=security"* ]]
}

@test "shadow: file-count ceiling → guard=size_files" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.99
  diff=$(printf 'diff --git a/c.md b/c.md\n+x\n')
  run _run_shadow "$diff" 5   # 5 >= RITE_TRIAGE_MAX_FILES(3)
  [[ "$output" == *"haiku=substantive"* ]]
  [[ "$output" == *"guard=size_files"* ]]
}

@test "shadow: low classifier confidence escalates to substantive" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.5  # below 0.8 gate
  diff=$(printf 'diff --git a/notes.md b/notes.md\n+just a note\n')
  run _run_shadow "$diff" 1
  [[ "$output" == *"haiku=substantive"* ]]
  [[ "$output" == *"reason=lowconf_0.5"* ]]
}

@test "shadow: prior review markers present → pass=fixreview" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  export GH_PRIOR_REVIEWS=2   # >=2 → genuine prior pass
  diff=$(printf 'diff --git a/d.md b/d.md\n+doc\n')
  run _run_shadow "$diff" 1
  [[ "$output" == *"pass=fixreview"* ]]
}

@test "shadow: first pass (no prior markers) → pass=first" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  export GH_PRIOR_REVIEWS=0
  diff=$(printf 'diff --git a/d.md b/d.md\n+doc\n')
  run _run_shadow "$diff" 1
  [[ "$output" == *"pass=first"* ]]
}

@test "shadow: paired diag carries the opus findings passed in" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  diff=$(printf 'diff --git a/d.md b/d.md\n+doc\n')
  run _triage_emit_shadow 42 "$diff" 1 2 3 4 5
  [[ "$output" == *"opus_critical=2"* ]]
  [[ "$output" == *"opus_high=3"* ]]
  [[ "$output" == *"opus_med=4"* ]]
  [[ "$output" == *"opus_low=5"* ]]
}

# ---------------------------------------------------------------------------
# #531: path-based sensitive guard when there is NO PR (the fast-path runs
# pre-commit). Calling detect_sensitivity_areas with an empty PR is a bug —
# `gh pr view ""` resolves to the current branch's PR and flags unrelated files.
# triage_classify_diff must instead check the diff's own paths. detect_sensitivity_areas
# is intentionally NOT defined in this harness, so the empty-PR path-based branch runs.
# ---------------------------------------------------------------------------
_classify() { triage_classify_diff "" "$1" "${2:-1}"; }
_mk_diff() { printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n+# a comment\n' "$1" "$1" "$1" "$1"; }

@test "#531 no-PR: protected script path → sensitive guard" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  run _classify "$(_mk_diff lib/core/workflow-runner.sh)"
  [[ "$output" == substantive\|*\|sensitive\|* ]]
}

@test "#531 no-PR: auth path → sensitive guard" {
  run _classify "$(_mk_diff src/auth/login.sh)"
  [[ "$output" == substantive\|*\|sensitive\|* ]]
}

@test "#531 no-PR: ordinary source file → NOT sensitive (classifier decides)" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  run _classify "$(_mk_diff lib/utils/colors.sh)"
  [[ "$output" == trivial\|* ]]
  [[ "$output" != *"|sensitive|"* ]]
}

@test "#531 no-PR: docs are NOT treated as sensitive (fast-path's main use case)" {
  export TRIAGE_STUB_VERDICT=trivial TRIAGE_STUB_CONF=0.95
  run _classify "$(_mk_diff docs/architecture/foo.md)"
  [[ "$output" != *"|sensitive|"* ]]
}
