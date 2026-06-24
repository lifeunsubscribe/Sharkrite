#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
# Regression: the linter must never block reading stdin.
#
# Live incident (issue 649, twice): sharkrite-lint.sh Rules 7/8/9 run
# `awk '...' "${ARR[@]}"`; when the file-array is EMPTY (zero file args), awk
# falls back to reading STDIN. The gate runs the linter (directly or via a bats
# test like fix-review-push-refspec.bats) with stdin inherited from the tty, so
# awk blocked on the terminal forever and wedged the whole run (78 min, and
# again inside the baseline-diff probe). Rule 18 already guarded its awk with
# `[ "${#SHELL_FILES[@]}" -gt 0 ]`; Rules 7/8/9 were missed and now redirect
# `</dev/null` so an empty array can never reach the tty.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  REAL_LINT="$RITE_REPO_ROOT/tools/sharkrite-lint.sh"
  TO=timeout
  command -v timeout >/dev/null 2>&1 || TO=gtimeout
}

@test "lint is stdin-safe: empty CORE_FILES array can't block on a live stdin" {
  command -v "$TO" >/dev/null 2>&1 || skip "no timeout/gtimeout binary available"

  # Fixture project: has lib shell files (SHELL_FILES non-empty) but NO lib/core/
  # so CORE_FILES is empty — that's the array that fed Rule 9's awk into stdin.
  local fixture="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$fixture/tools" "$fixture/lib" "$fixture/bin"   # deliberately no lib/core/
  cp "$REAL_LINT" "$fixture/tools/sharkrite-lint.sh"
  printf '#!/bin/bash\necho hi\n' > "$fixture/lib/foo.sh"

  # stdin is a descriptor that stays open well past the timeout. Pre-fix, Rule 9's
  # awk (empty CORE_FILES) reads it and hangs → timeout kills it → status 124.
  # Post-fix, the `</dev/null` on the array-fed awk makes it ignore stdin → the
  # linter finishes (any exit code) well within the bound.
  run "$TO" 20 bash "$fixture/tools/sharkrite-lint.sh" < <(sleep 45)

  # The only failure we care about is a timeout (124 from timeout, or 137/143 if
  # it had to SIGKILL). Lint findings (exit 1) or setup errors are fine — we are
  # asserting it did NOT hang.
  [ "$status" -ne 124 ]
  [ "$status" -ne 137 ]
  [ "$status" -ne 143 ]
}
