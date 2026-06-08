#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/undo-workflow.sh
# Regression test: undo-workflow.sh follow-up issue dedup must work under bash 3.2
#
# Bug history (2026-06-04):
#   rite --undo <N> crashed when the issue had follow-up issues attached:
#     /bin/bash: line 133: mapfile: command not found
#   Root cause: undo-workflow.sh used `mapfile -t` for deduplication, which is a
#   bash 4.0+ builtin. macOS ships bash 3.2 as /bin/bash and any direct invocation
#   via the #!/bin/bash shebang uses it. Fixed in issue #327 by replacing mapfile
#   with a portable while-read loop that works on all bash versions.
#
# This file tests:
#   1. The deduplication logic works correctly under /bin/bash (3.2 on macOS)
#   2. No "command not found" error appears in stderr for the dedup code path
#   3. Duplicates are correctly removed and ordering is preserved (sort -un)

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT

  # Scratch dir for the test run
  TEST_DIR="${BATS_TEST_TMPDIR}/undo-bash32"
  mkdir -p "$TEST_DIR"
  export TEST_DIR
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Unit test: the portable dedup idiom itself (no undo-workflow.sh wiring)
# Runs the exact replacement code under /bin/bash to confirm it works in 3.2.
# ---------------------------------------------------------------------------

@test "portable while-read dedup works under /bin/bash (replaces mapfile)" {
  # Reproduces the exact while-read loop added in issue #327.
  # Run the snippet under /bin/bash explicitly (system bash 3.2 on macOS).
  run /bin/bash -c '
    set -euo pipefail
    FOLLOWUP_ISSUES=(5 3 5 1 3 2 1)

    if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
      _tmp_unique=()
      while IFS= read -r _line; do
        _tmp_unique+=("$_line")
      done < <(printf '"'"'%s\n'"'"' "${FOLLOWUP_ISSUES[@]}" | sort -un)
      FOLLOWUP_ISSUES=("${_tmp_unique[@]+"${_tmp_unique[@]}"}")
    fi

    # Print results — should be: 1 2 3 5 (sorted, deduped)
    printf "%s\n" "${FOLLOWUP_ISSUES[@]}"
  '

  # Must succeed (no mapfile crash)
  [ "$status" -eq 0 ]

  # Output must be the deduplicated, sorted list
  [ "${lines[0]}" = "1" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "3" ]
  [ "${lines[3]}" = "5" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "portable dedup does not emit 'command not found' under /bin/bash" {
  # Confirms no stderr output mentioning 'command not found' — the
  # specific failure mode from the bug report.
  run /bin/bash -c '
    set -euo pipefail
    FOLLOWUP_ISSUES=(10 20 10 30)

    if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
      _tmp_unique=()
      while IFS= read -r _line; do
        _tmp_unique+=("$_line")
      done < <(printf '"'"'%s\n'"'"' "${FOLLOWUP_ISSUES[@]}" | sort -un)
      FOLLOWUP_ISSUES=("${_tmp_unique[@]+"${_tmp_unique[@]}"}")
    fi

    printf "%s\n" "${FOLLOWUP_ISSUES[@]}"
  ' 2>&1  # capture stderr too so we can check it

  # No "command not found" in combined output
  [[ "$output" != *"command not found"* ]]
  [ "$status" -eq 0 ]
}

@test "portable dedup handles empty array safely under /bin/bash with set -u" {
  # The "${_tmp[@]+"${_tmp[@]}"}" idiom is critical: without it, an empty
  # _tmp_unique array under `set -u` causes "unbound variable" crash.
  # This replicates the PR #266 empty-array safety pattern.
  run /bin/bash -c '
    set -euo pipefail
    FOLLOWUP_ISSUES=()

    # Guard: only dedup when non-empty (same guard as undo-workflow.sh)
    if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
      _tmp_unique=()
      while IFS= read -r _line; do
        _tmp_unique+=("$_line")
      done < <(printf '"'"'%s\n'"'"' "${FOLLOWUP_ISSUES[@]}" | sort -un)
      FOLLOWUP_ISSUES=("${_tmp_unique[@]+"${_tmp_unique[@]}"}")
    fi

    echo "count=${#FOLLOWUP_ISSUES[@]}"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == "count=0" ]]
}

@test "portable dedup with single element returns that element" {
  run /bin/bash -c '
    set -euo pipefail
    FOLLOWUP_ISSUES=(42)

    if [ ${#FOLLOWUP_ISSUES[@]} -gt 0 ]; then
      _tmp_unique=()
      while IFS= read -r _line; do
        _tmp_unique+=("$_line")
      done < <(printf '"'"'%s\n'"'"' "${FOLLOWUP_ISSUES[@]}" | sort -un)
      FOLLOWUP_ISSUES=("${_tmp_unique[@]+"${_tmp_unique[@]}"}")
    fi

    printf "%s\n" "${FOLLOWUP_ISSUES[@]}"
  '

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "42" ]
  [ "${#lines[@]}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Codebase check: confirm mapfile is gone from undo-workflow.sh
# ---------------------------------------------------------------------------

@test "undo-workflow.sh no longer uses mapfile as a command (non-comment lines)" {
  # Verify the fix is in place: mapfile must not appear as an active command.
  # Comments referencing mapfile (e.g. "replaces `mapfile`") are acceptable;
  # only non-comment lines with mapfile as a command are a regression.
  #
  # Strategy: grep for lines containing 'mapfile', then keep only lines where
  # the content (after the line-number:) is not a pure comment (i.e., the
  # non-whitespace content does not start with '#').
  run bash -c "
    grep -n 'mapfile' '$RITE_REPO_ROOT/lib/core/undo-workflow.sh' \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
    || true
  "

  # If output is empty, no active mapfile command exists (only comments)
  [ -z "$output" ]
}

@test "undo-workflow.sh contains the portable while-read dedup loop" {
  # Confirm the replacement code is present (defense against accidental deletion).
  run grep -c 'while IFS= read -r _line' "$RITE_REPO_ROOT/lib/core/undo-workflow.sh"

  [ "$status" -eq 0 ]
  # At least one occurrence of the while-read loop
  [ "$output" -ge 1 ]
}
