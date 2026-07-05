#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
# Tests for Rule 33: EMPTY_ARRAY_EXPANSION_BASH32
#
# On macOS system bash 3.2, expanding an EMPTY array via "${arr[@]}" under
# set -u crashes with "arr[@]: unbound variable" (live class: #266, #327, the
# 2026-07-04 audit). The rule flags unguarded expansions in #!/bin/bash files;
# the +idiom, a nearby ${#arr[@]} count-guard, or a non-empty literal init
# make a site safe. Fixtures injected via RITE_LINT_EXTRA_DIRS (Rule 21 harness).

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/empty-array-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
}

_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE (violations)
# ---------------------------------------------------------------------------

@test "rule fires: unguarded for-loop expansion of possibly-empty array" {
  _run_lint_with_fixture "bad-for" '#!/bin/bash
set -euo pipefail
arr=()
while IFS= read -r x; do arr+=("$x"); done < /dev/null
sleep_lines() { :; }
sleep_lines; sleep_lines; sleep_lines; sleep_lines; sleep_lines
sleep_lines; sleep_lines; sleep_lines; sleep_lines; sleep_lines
for v in "${arr[@]}"; do echo "$v"; done'
  [[ "$output" == *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "rule fires: bare argument expansion of conditionally-populated array" {
  _run_lint_with_fixture "bad-args" '#!/bin/bash
set -euo pipefail
gh_args=()
if [ -n "${LABELS:-}" ]; then gh_args+=(--label "$LABELS"); fi
pad() { :; }
pad; pad; pad; pad; pad; pad; pad; pad; pad; pad; pad
some_cmd "${gh_args[@]}"'
  [[ "$output" == *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

# ---------------------------------------------------------------------------
# Should NOT fire (guarded / safe forms)
# ---------------------------------------------------------------------------

@test "rule silent: +idiom expansion" {
  _run_lint_with_fixture "ok-idiom" '#!/bin/bash
set -euo pipefail
arr=()
for v in "${arr[@]+"${arr[@]}"}"; do echo "$v"; done'
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "rule silent: count-guard within window" {
  _run_lint_with_fixture "ok-guard" '#!/bin/bash
set -euo pipefail
arr=()
if [ ${#arr[@]} -gt 0 ]; then
  for v in "${arr[@]}"; do echo "$v"; done
fi'
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "rule silent: non-empty literal init (single-line and multi-line)" {
  _run_lint_with_fixture "ok-literal" '#!/bin/bash
set -euo pipefail
one=(a b c)
for v in "${one[@]}"; do echo "$v"; done
many=(
  "alpha"
  "beta"
)
for v in "${many[@]}"; do echo "$v"; done'
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "rule silent: env-bash shebang is out of scope" {
  _run_lint_with_fixture "ok-envbash" '#!/usr/bin/env bash
set -euo pipefail
arr=()
p() { :; }
p; p; p; p; p; p; p; p; p; p; p
for v in "${arr[@]}"; do echo "$v"; done'
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "rule silent: inline suppression comment honored" {
  _run_lint_with_fixture "ok-suppressed" '#!/bin/bash
set -euo pipefail
arr=()
p() { :; }
p; p; p; p; p; p; p; p; p; p; p
# sharkrite-lint disable EMPTY_ARRAY_EXPANSION_BASH32 - Reason: populated by caller contract
for v in "${arr[@]}"; do echo "$v"; done'
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "rule silent: bash specials (BASH_SOURCE, PIPESTATUS) excluded" {
  _run_lint_with_fixture "ok-specials" '#!/bin/bash
set -euo pipefail
echo "${BASH_SOURCE[@]}"
true | true
echo "${PIPESTATUS[@]}"'
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}

@test "tree-wide: make-lint currently clean of the rule (all real sites fixed)" {
  run bash "$LINT_SCRIPT"
  [[ "$output" != *"EMPTY_ARRAY_EXPANSION_BASH32"* ]]
}
