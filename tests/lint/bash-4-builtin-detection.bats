#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh
# Tests for Rule 21: BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT
#
# Verifies that the lint rule correctly flags bash 4+ builtins (mapfile,
# readarray, declare -A) in #!/bin/bash scripts that lack a BASH_VERSINFO
# re-exec guard, and correctly passes scripts that are guarded or use a
# modern shebang.
#
# Fixture injection:
#   Fixtures are written into BATS_TEST_TMPDIR and injected via
#   RITE_LINT_EXTRA_DIRS so the linter scans them without touching the
#   project's own lib/ tree. Each test creates its fixture, runs lint,
#   checks for the rule name in output, then moves on (teardown cleans up).

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"

  # Fixture directory — outside the project tree, injected via env var
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/bash4-builtin-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
  unset RITE_LINT_EXTRA_DIRS
}

# Helper: write a fixture file to the fixture dir and run lint.
# Returns lint output in $output and exit status in $status.
_run_lint_with_fixture() {
  local name="$1"
  local content="$2"
  printf '%s\n' "$content" > "$FIXTURE_DIR/${name}.sh"
  run bash "$LINT_SCRIPT"
}

# ---------------------------------------------------------------------------
# Should FIRE (violations)
# ---------------------------------------------------------------------------

@test "rule fires: #!/bin/bash + mapfile without BASH_VERSINFO guard" {
  _run_lint_with_fixture "bad-mapfile" '#!/bin/bash
set -euo pipefail
_RITE_FOO_LOADED="${_RITE_FOO_LOADED:-}"
[ "${_RITE_FOO_LOADED}" = "true" ] && { return 0 2>/dev/null || true; }
_RITE_FOO_LOADED=true

mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

@test "rule fires: #!/bin/bash + readarray without BASH_VERSINFO guard" {
  _run_lint_with_fixture "bad-readarray" '#!/bin/bash
set -euo pipefail

readarray -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

@test "rule fires: #!/bin/bash + declare -A without BASH_VERSINFO guard" {
  _run_lint_with_fixture "bad-declare-A" '#!/bin/bash
set -euo pipefail

declare -A MY_MAP
MY_MAP[key]="value"
echo "${MY_MAP[key]}"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

@test "rule fires: #!/bin/bash + declare -gA (global assoc array, combined flags) without guard" {
  _run_lint_with_fixture "bad-declare-gA" '#!/bin/bash
set -euo pipefail

declare -gA MY_GLOBAL_MAP
MY_GLOBAL_MAP[key]="value"
echo "${MY_GLOBAL_MAP[key]}"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

@test "rule fires: #!/bin/bash + declare -Ar (readonly assoc array, combined flags) without guard" {
  _run_lint_with_fixture "bad-declare-Ar" '#!/bin/bash
set -euo pipefail

declare -Ar MY_READONLY_MAP=([key]="value")
echo "${MY_READONLY_MAP[key]}"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

@test "rule fires: #!/bin/bash + local -A (assoc array in function) without guard" {
  _run_lint_with_fixture "bad-local-A" '#!/bin/bash
set -euo pipefail

my_func() {
  local -A my_map
  my_map[key]="value"
  echo "${my_map[key]}"
}
my_func'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

# ---------------------------------------------------------------------------
# Should PASS (no violations from this rule)
# ---------------------------------------------------------------------------

@test "rule passes: #!/usr/bin/env bash + mapfile (modern shebang, PATH picks bash 5)" {
  _run_lint_with_fixture "good-env-bash-mapfile" '#!/usr/bin/env bash
set -euo pipefail

mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  # Rule 21 must NOT fire (modern shebang is exempt)
  local r21_lines
  r21_lines=$(echo "$output" | grep "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" || true)
  [[ "$r21_lines" != *"good-env-bash-mapfile"* ]]
}

@test "rule passes: #!/bin/bash + mapfile + BASH_VERSINFO re-exec guard present" {
  _run_lint_with_fixture "good-versinfo-guard" '#!/bin/bash
set -euo pipefail

# Self-re-exec under bash 4+ if we landed on system bash 3.2 (macOS default).
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "$BASH" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  # Rule 21 must NOT fire (BASH_VERSINFO guard is present)
  local r21_lines
  r21_lines=$(echo "$output" | grep "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" || true)
  [[ "$r21_lines" != *"good-versinfo-guard"* ]]
}

@test "rule passes: #!/bin/bash + mapfile + arithmetic BASH_VERSINFO guard (( BASH_VERSINFO[0] < 4 ))" {
  # Covers audit-dropped-followups.sh style guard: arithmetic conditional, no exec.
  # The exemption must fire for both test-builtin and arithmetic guard shapes.
  _run_lint_with_fixture "good-arithmetic-versinfo" '#!/bin/bash
set -euo pipefail

# Bash 4+ required for mapfile
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: Requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  local r21_lines
  r21_lines=$(echo "$output" | grep "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" || true)
  [[ "$r21_lines" != *"good-arithmetic-versinfo"* ]]
}

@test "rule passes: #!/bin/bash + mapfile + suppression comment on preceding line" {
  _run_lint_with_fixture "good-suppressed" '#!/bin/bash
set -euo pipefail

# sharkrite-lint disable BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT - reason: called only from CI with bash 4+
mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  # Rule 21 must NOT fire (suppression comment present)
  local r21_lines
  r21_lines=$(echo "$output" | grep "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" || true)
  [[ "$r21_lines" != *"good-suppressed"* ]]
}

# ---------------------------------------------------------------------------
# Granular exemption: BASH_VERSINFO in comment / diagnostic must NOT exempt
# ---------------------------------------------------------------------------
# These tests cover the "over-broad exemption" fix (issue #334): a file that
# only mentions BASH_VERSINFO in a comment or in a diagnostic echo — without
# an actual version-comparison guard — must still be flagged by Rule 21.

@test "rule fires: #!/bin/bash + mapfile + BASH_VERSINFO only in a comment" {
  # BASH_VERSINFO appears but only inside a comment — no functional guard.
  # The old implementation exempted the whole file; the new one must not.
  _run_lint_with_fixture "bad-versinfo-comment-only" '#!/bin/bash
set -euo pipefail
# Note: this script requires bash 4+. See BASH_VERSINFO for version info.

mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

@test "rule fires: #!/bin/bash + mapfile + BASH_VERSINFO only in diagnostic echo" {
  # BASH_VERSINFO appears in an echo for diagnostic output, not a guard.
  # Accessing ${BASH_VERSINFO[*]} for display does not protect against bash 3.2.
  _run_lint_with_fixture "bad-versinfo-diagnostic-only" '#!/bin/bash
set -euo pipefail

echo "Running on bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" >&2

mapfile -t MY_ARRAY < <(find . -name "*.sh")
echo "done"'

  [[ "$output" == *"BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT"* ]]
}

# ---------------------------------------------------------------------------
# Codebase sweep: no existing violations in the production codebase
# ---------------------------------------------------------------------------

@test "codebase: no BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT violations in lib/ bin/ tools/" {
  # After the fix in issue #327, running lint against the real codebase must
  # produce zero Rule 21 violations. If this test fails, a bash-4+ builtin
  # was added to a #!/bin/bash script without the appropriate guard.
  unset RITE_LINT_EXTRA_DIRS   # scan only the project tree, not fixtures

  run bash "$LINT_SCRIPT"

  local r21_violations
  r21_violations=$(echo "$output" | grep "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" || true)

  if [ -n "$r21_violations" ]; then
    echo "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT violations found:" >&3
    echo "$r21_violations" >&3
    false
  fi
}
