#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# sharkrite-gate-serial — spawns real inner bats runs (runbook rule 6); under --jobs load these
# time out at the 120s per-test budget (live: blocked issue #871's gate, 2026-07-05)
# Regression for #938: one bounded serial retry of failing bats files.
# A load-flake blocked three merges on 2026-07-05 (SIGINT pair twice, a
# symlink assert once) — each green in isolation minutes later. Contract:
# failing files re-run ONCE serially; tests passing the quiet run are flakes
# (not-ok lines FLIPPED to ok in place — TAP numbering preserved for the #804
# plan-deficit math — and named loudly); persisting failures block as before;
# watchdog kills and >max-files breakage never retry.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  # shellcheck source=/dev/null
  source "${RITE_REPO_ROOT}/lib/utils/test-gate.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  FIX_ROOT="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$FIX_ROOT/tests"
  # Stubs the function expects from gate scope (dynamic scoping).
  _gate_status() { echo "$@"; }
  _diag() { echo "[diag] $*"; }
  # Unset outer BATS_* env vars so nested bats invocations inside
  # _gate_flake_retry_pass don't inherit the outer test runner's IPC state and
  # hang (live: tests 11-12 timed out at 120s when BATS_SUITE_TMPDIR et al.
  # were inherited — inner bats tried to share outer bats' FD/socket channels).
  # Mirrors the production scrub in test-gate.sh (#993) — keep the lists in
  # sync (this one is the union of #991's empirical list + #993's).
  _bats_sandbox=(env
    -u BATS_SUITE_TMPDIR -u BATS_FILE_TMPDIR -u BATS_RUN_TMPDIR
    -u BATS_TEST_TMPDIR -u BATS_ROOT_PID -u BATS_LIBEXEC_DIR -u BATS_TMPDIR
    -u BATS_TEST_TIMEOUT -u BATS_SUITE_TEST_NUMBER
    -u RITE_LOG_FILE -u PR_NUMBER -u ISSUE_NUMBER)
  PR_NUMBER=0
}

teardown() { rm -rf "$FIX_ROOT"; }

# Helper: a test that fails until its state file exists (creates it on first run).
_write_toggle_fixture() {
  local name="$1" state="$2"
  # printf, not heredoc: bats preprocesses literal @test lines in this file,
  # corrupting heredoc fixture bodies (test-authoring runbook rule 7).
  printf '#!/usr/bin/env bats\n@test "toggle %s flakes once" {\n  if [ ! -f "%s" ]; then touch "%s"; false; fi\n  true\n}\n' \
    "$name" "$state" "$state" > "$FIX_ROOT/tests/${name}.bats"
}

@test "cleared: fail-once fixture passes serial retry, raw TAP flipped, exit 0" {
  _write_toggle_fixture "flaky" "$FIX_ROOT/state-flaky"
  local raw="$FIX_ROOT/raw.tap"
  # Simulate the original (loaded) run having failed it. State file now exists
  # (the fixture 'failed' once), so the retry's quiet run passes.
  touch "$FIX_ROOT/state-flaky"
  printf '1..1\nnot ok 1 toggle flaky flakes once\n' > "$raw"
  _parallel_files=("$FIX_ROOT/tests/flaky.bats")
  _serial_files=()

  run _gate_flake_retry_pass "$raw" "$FIX_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared on serial re-run (load flake): toggle flaky flakes once"* ]]
  [[ "$output" == *"TEST_GATE_FLAKE_RETRY cleared=1 persisted=0"* ]]
  # Recomputed exit is the LAST line of stdout
  [ "$(echo "$output" | tail -1)" = "0" ]
  # TAP flipped in place, numbering preserved
  grep -q "^ok 1 toggle flaky flakes once" "$raw"
  ! grep -q "^not ok" "$raw"
}

@test "persisted: always-failing fixture still blocks (exit 1, not flipped)" {
  printf '#!/usr/bin/env bats\n@test "always red" { false; }\n' > "$FIX_ROOT/tests/red.bats"
  local raw="$FIX_ROOT/raw.tap"
  printf '1..1\nnot ok 1 always red\n' > "$raw"
  _parallel_files=("$FIX_ROOT/tests/red.bats")
  _serial_files=()

  run _gate_flake_retry_pass "$raw" "$FIX_ROOT"
  [[ "$output" == *"TEST_GATE_FLAKE_RETRY cleared=0 persisted=1"* ]]
  [ "$(echo "$output" | tail -1)" = "1" ]
  grep -q "^not ok 1 always red" "$raw"
}

@test "mixed: flake cleared, real failure persists, exit stays 1" {
  _write_toggle_fixture "mix" "$FIX_ROOT/state-mix"
  touch "$FIX_ROOT/state-mix"
  printf '#!/usr/bin/env bats\n@test "really broken" { false; }\n' > "$FIX_ROOT/tests/red2.bats"
  local raw="$FIX_ROOT/raw.tap"
  printf '1..2\nnot ok 1 toggle mix flakes once\nnot ok 2 really broken\n' > "$raw"
  _parallel_files=("$FIX_ROOT/tests/mix.bats" "$FIX_ROOT/tests/red2.bats")
  _serial_files=()

  run _gate_flake_retry_pass "$raw" "$FIX_ROOT"
  [[ "$output" == *"cleared=1 persisted=1"* ]]
  [ "$(echo "$output" | tail -1)" = "1" ]
  grep -q "^ok 1 toggle mix flakes once" "$raw"
  grep -q "^not ok 2 really broken" "$raw"
}

@test "cap: more than max failing files skips retry as real breakage" {
  local raw="$FIX_ROOT/raw.tap"
  printf '1..6\n' > "$raw"
  _parallel_files=()
  local i
  for i in 1 2 3 4 5 6; do
    printf '#!/usr/bin/env bats\n@test "bulk %s" { false; }\n' "$i" > "$FIX_ROOT/tests/bulk$i.bats"
    printf 'not ok %s bulk %s\n' "$i" "$i" >> "$raw"
    _parallel_files+=("$FIX_ROOT/tests/bulk$i.bats")
  done
  _serial_files=()

  run _gate_flake_retry_pass "$raw" "$FIX_ROOT"
  [[ "$output" == *"skipping flake retry, treating as real breakage"* ]]
  [ "$(echo "$output" | tail -1)" = "1" ]
}

@test "synthetics: [tests_not_run] findings are never retried" {
  local raw="$FIX_ROOT/raw.tap"
  printf '1..1\nnot ok 1 [tests_not_run] planned test never reported a result\n' > "$raw"
  _parallel_files=("$FIX_ROOT/tests")   # anything; must not be consulted
  _serial_files=()

  run _gate_flake_retry_pass "$raw" "$FIX_ROOT"
  [[ "$output" != *"Flake retry:"* ]]
  [ "$(echo "$output" | tail -1)" = "1" ]
}

@test "no selection (full-suite path): retry skips, exit 1 unchanged" {
  local raw="$FIX_ROOT/raw.tap"
  printf '1..1\nnot ok 1 anything\n' > "$raw"
  _parallel_files=()
  _serial_files=()
  run _gate_flake_retry_pass "$raw" "$FIX_ROOT"
  [[ "$output" != *"Flake retry:"* ]]
  [ "$(echo "$output" | tail -1)" = "1" ]
}

@test "source: retry call is guarded by watchdog flag and off-switch" {
  run grep -E '_fr_watchdog:-false' "${RITE_REPO_ROOT}/lib/utils/test-gate.sh"
  [ "$status" -eq 0 ]
  run grep -E 'RITE_GATE_FLAKE_RETRY:-true' "${RITE_REPO_ROOT}/lib/utils/test-gate.sh"
  [ "$status" -eq 0 ]
}
