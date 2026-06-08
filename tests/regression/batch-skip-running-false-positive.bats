#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh
# Regression test for: batch skip-running check false-positives on PID column
#
# Bug history:
#   2026-06-08 — `rite 393 395 377` skipped 377 with
#     "⚠️  Skipping issues already running: 377"
#   even though no process was running. The check at
#   batch-process-issues.sh:218-234 reads `ps -eo pid,command` and matches
#   each issue number with `grep -qE " ${N}( |$)"`. The leading-space anchor
#   was intended to match argv tokens, but `ps -eo pid,command` puts the
#   right-aligned PID in the first column padded with spaces. A
#   workflow-runner.sh or claude-workflow.sh with PID 377 (or any other
#   batched issue number) produces a line like:
#       "  377 /bin/bash /path/workflow-runner.sh 412 --auto"
#   The regex matches " 377 " from the PID column itself — a false positive
#   that silently drops the issue from the batch.
#
# Fix:
#   1. Use `ps -eo command` (no PID column) — eliminates the column class
#   2. Anchor the regex to require the script name immediately before the
#      issue number, so unrelated numbers in argv positions don't match.
#   3. Print the matching process line when a skip fires so future false
#      positives are diagnosable from the log.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
}

# Helper: run the matching logic on a fixture and report which issues match
# Arguments:
#   $1 — issue numbers (space-separated)
#   stdin — simulated `ps -eo command` output
# Output: space-separated list of matched issue numbers
_run_match() {
  local issues="$1"
  local procs
  procs=$(cat)
  bash -c "
    set -euo pipefail
    _all_procs=\$(printf '%s\n' '$procs')
    _active_matches=\$(echo \"\$_all_procs\" | grep -E '(workflow-runner|claude-workflow)\.sh' | grep -v 'grep' || true)
    _matched=()
    for _issue_num in $issues; do
      _match_line=\$(echo \"\$_active_matches\" | grep -E \"(workflow-runner|claude-workflow)\\.sh \${_issue_num}( |\\\$)\" | head -1 || true)
      if [ -n \"\$_match_line\" ]; then
        _matched+=(\"\$_issue_num\")
      fi
    done
    echo \"\${_matched[*]:-}\"
  "
}

# ---------------------------------------------------------------------------
# Test: PID column matching the issue number is NOT a false positive
#   (this is the exact #471-follow-up live failure shape)
# ---------------------------------------------------------------------------
@test "PID column with issue number does NOT trigger a skip" {
  # A workflow-runner.sh whose PID is 377, processing a different issue (412).
  # The OLD regex " ${N}( |$)" would match " 377 " from the PID column,
  # falsely skipping issue 377 from the batch.
  run _run_match "393 395 377" <<'PROCS'
  377 /bin/bash /Users/sarahtime/Dev/sharkrite/lib/core/workflow-runner.sh 412 --auto
  500 /bin/bash /Users/sarahtime/Dev/sharkrite/lib/core/claude-workflow.sh 412
PROCS

  [ "$status" -eq 0 ]
  # No issue from the batch should match — 412 isn't in the batch list.
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test: stray ' 377 ' anywhere in argv does NOT trigger a skip
# ---------------------------------------------------------------------------
@test "issue number appearing as a non-script-arg does NOT trigger a skip" {
  # A workflow-runner.sh with --timeout 377 (hypothetical flag value) —
  # the OLD regex would match " 377 " in the argv. The anchored regex
  # requires the issue number to follow the script name.
  run _run_match "377" <<'PROCS'
12345 /bin/bash /path/workflow-runner.sh 500 --timeout 377 --auto
PROCS

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test: legitimate match — workflow-runner.sh with the issue number as arg 1
# ---------------------------------------------------------------------------
@test "issue number as positional arg to workflow-runner.sh IS matched" {
  run _run_match "377" <<'PROCS'
12345 /bin/bash /path/workflow-runner.sh 377 --auto
PROCS

  [ "$status" -eq 0 ]
  [ "$output" = "377" ]
}

# ---------------------------------------------------------------------------
# Test: legitimate match — claude-workflow.sh with the issue number as arg 1
# ---------------------------------------------------------------------------
@test "issue number as positional arg to claude-workflow.sh IS matched" {
  run _run_match "412" <<'PROCS'
12345 /bin/bash /path/claude-workflow.sh 412
PROCS

  [ "$status" -eq 0 ]
  [ "$output" = "412" ]
}

# ---------------------------------------------------------------------------
# Test: non-script process lines never match
# ---------------------------------------------------------------------------
@test "non-script processes with the issue number do NOT match" {
  # An editor, a search command, an unrelated bash invocation — none should match.
  run _run_match "377" <<'PROCS'
12345 vim /Users/sarahtime/Dev/sharkrite/.rite/locks/issue-377.lock
12346 grep -r 377 lib/
12347 /bin/bash /path/some-other-script.sh 377
PROCS

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Test: multiple legitimate matches in one ps snapshot
# ---------------------------------------------------------------------------
@test "multiple genuine concurrent runs all match" {
  run _run_match "393 395 377" <<'PROCS'
12345 /bin/bash /path/workflow-runner.sh 393 --auto
12346 /bin/bash /path/workflow-runner.sh 377 --auto
12347 /bin/bash /path/claude-workflow.sh 395
PROCS

  [ "$status" -eq 0 ]
  [[ "$output" == *"393"* ]]
  [[ "$output" == *"395"* ]]
  [[ "$output" == *"377"* ]]
}

# ---------------------------------------------------------------------------
# Test: structural — batch script uses the anchored regex with script name
# ---------------------------------------------------------------------------
@test "batch script uses anchored regex with script name" {
  local batch="${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  run grep -F 'workflow-runner|claude-workflow)\.sh ${_issue_num}' "$batch"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test: structural — pre-start filter uses `ps -eo command` (no pid column)
# ---------------------------------------------------------------------------
@test "pre-start filter reads ps -eo command, not ps -eo pid,command" {
  local batch="${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  run grep -F '_all_procs=$(ps -eo command' "$batch"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test: structural — skip warning includes the matched process line
# ---------------------------------------------------------------------------
@test "skip warning prints the matching process line for diagnosis" {
  local batch="${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  run grep -F 'matched:' "$batch"
  [ "$status" -eq 0 ]
}
