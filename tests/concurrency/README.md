# Concurrency Tests

This directory contains tests for concurrent `rite` invocations — the #1 critical bug class in Sharkrite.

## Overview

Concurrent invocations happen when:
- Multiple developers run `rite` on different issues in the same repo
- Automated systems trigger multiple `rite` workflows simultaneously
- A developer runs `rite` while a previous session is still active

Without proper synchronization, these scenarios cause:
- **Data loss** in session state, scratchpad, and follow-up issues
- **File corruption** when multiple processes write to the same JSON/markdown files
- **Duplicate issues** when multiple processes create follow-ups for the same findings
- **Git push failures** when processes race to push to the same branch

## Test Files

### `issue-lock.bats`
Tests per-issue locking to prevent duplicate work.

**What it tests:**
- Lock acquisition and release
- Stale lock reclamation (dead process detection)
- Multiple issues can be locked simultaneously
- Only one process can work on an issue at a time

**Fixes verified:** Issue #8 (per-issue locking)

### `scratchpad-lock.bats`
Tests concurrent writes to the scratchpad file.

**What it tests:**
- Multiple processes adding encountered issues simultaneously
- Multiple processes updating security findings (PR review results)
- Scratchpad file creation race (when file doesn't exist)
- Structure preservation (sections don't get corrupted)

**Fixes verified:** Issue #19 (scratchpad race conditions)

**Expected behavior:**
- Before fix: Data loss, section corruption, duplicate headers
- After fix: All writes succeed, structure preserved, no data lost

### `session-state-race.bats`
Tests concurrent updates to `session-state.json`.

**What it tests:**
- Multiple processes updating different fields simultaneously
- Concurrent blocker approval additions
- Session initialization while updates are in progress
- High-concurrency stress test (10 processes × 10 updates)
- JSON corruption detection

**Fixes verified:** Issue #8 (session state races)

**Expected behavior:**
- Before fix: JSON corruption, lost updates, invalid structure
- After fix: Valid JSON always, all updates applied (or safely retried)

### `followup-issue-dedup.bats`
Tests follow-up issue deduplication.

**What it tests:**
- Multiple processes creating identical tech-debt issues
- Label creation races (same label from multiple processes)
- Mixed scenarios (some duplicate, some unique issues)
- Deduplication logic correctness

**Fixes verified:** Issue #25 (duplicate follow-up issues)

**Expected behavior:**
- Before fix: N duplicate issues created for same finding
- After fix: Only 1 issue created, other processes detect existing issue

### `stale-branch-push-race.bats`
Tests concurrent git operations.

**What it tests:**
- Multiple processes pushing to the same branch (non-fast-forward handling)
- Concurrent worktree creation for the same issue
- Concurrent branch creation with the same name
- Stale branch merge-main operations racing
- Force-push prevention (all pushes use refspec)

**Fixes verified:** Issue #15 (stale branch races), Issue #26 (worktree races)

**Expected behavior:**
- Before fix: Force pushes, worktree corruption, lost commits
- After fix: Graceful rejection handling, one succeeds + others retry

## How Concurrency Tests Work

### Barrier Synchronization

All tests use **barrier synchronization** (NOT sleep timers) for deterministic concurrency:

```bash
wait_at_barrier() {
  local barrier_name="$1"
  local expected_count="$2"
  local pid_file="$BARRIER_DIR/${barrier_name}.$$"

  # Mark this process as arrived
  touch "$pid_file"

  # Wait until all processes arrive
  local count=0
  while [ "$count" -lt "$expected_count" ]; do
    count=$(find "$BARRIER_DIR" -name "${barrier_name}.*" | wc -l)
    [ "$count" -lt "$expected_count" ] && sleep 0.1
  done
}
```

**Why barriers instead of sleep:**
- Sleep is non-deterministic (timing depends on system load)
- Barriers guarantee all processes start simultaneously
- Tests are reliable in CI environments

### Shared Fixture Pattern

Each test creates **ONE** shared fixture repo used by all processes:

```bash
setup() {
  setup_test_tmpdir
  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")
  # All processes work on FIXTURE_REPO
}
```

**Why shared fixture:**
- Actually exercises the race condition (processes conflict)
- Per-process fixtures would never race (false negatives)
- Matches real-world scenario (one repo, multiple developers)

### Exit Code Collection

Use temp files to collect exit codes from background processes:

```bash
for i in $(seq 1 $num_processes); do
  (
    # ... do work ...
    echo $? > "$exit_codes_dir/process_${i}.exit"
  ) &
done

wait

# Verify all succeeded
for i in $(seq 1 $num_processes); do
  exit_code=$(cat "$exit_codes_dir/process_${i}.exit")
  [ "$exit_code" -eq 0 ]
done
```

**Why temp files:**
- `wait $!` loses exit codes from earlier background processes
- Temp files preserve all exit codes reliably
- Allows detailed assertion on each process result

## Adding New Concurrency Tests

### 1. Identify the Race Condition

- What file/resource is accessed concurrently?
- What operation races (read-modify-write, create, append)?
- What is the expected behavior after the fix?

### 2. Create Test Structure

```bash
@test "concurrent operation X - expected behavior" {
  # Setup
  local num_processes=5
  local exit_codes_dir="$RITE_TEST_TMPDIR/exit_codes"
  mkdir -p "$exit_codes_dir"

  # Spawn N processes
  for i in $(seq 1 $num_processes); do
    (
      # Barrier: all processes wait here
      wait_at_barrier "test_name" "$num_processes"

      # Race happens here - all execute simultaneously
      # ... concurrent operation ...

      echo $? > "$exit_codes_dir/process_${i}.exit"
    ) &
  done

  # Wait for completion
  wait

  # Assert expected outcome
  # ... verify no data loss, no corruption, etc. ...
}
```

### 3. Use Hard Failure Assertions

All concurrency assertions must be hard failures.  The old "EXPECTED FAILURE"
`return 0` escape hatch made tests self-defeating — they passed even when the race
was detected, so they couldn't catch regressions.

```bash
[ "$actual_count" -eq "$expected_count" ] || {
  echo "REGRESSION: <what broke> — <which fix> regressed?"
  return 1  # Hard failure: test fails if fix regresses
}
```

**Never use `return 0` as an escape hatch in an assertion block.** If a fix
hasn't landed yet and the test would be a guaranteed failure in CI, use
`skip "Pending: waiting for issue #N to land"` instead — at least that's
honest about the state, and it's automatically un-skipped when the test
is run on a branch where the fix exists.

### 4. Test Checklist

- [ ] Uses barrier synchronization (no sleep)
- [ ] Uses shared fixture (not per-process fixtures)
- [ ] Collects exit codes via temp files
- [ ] Asserts final state correctness
- [ ] Uses hard failure assertions (no `return 0` escape hatches)
- [ ] Includes cleanup (teardown)

## Running the Tests

```bash
# Run all concurrency tests
make test FILTER=concurrency

# Run specific test file
bats tests/concurrency/issue-lock.bats

# Run with verbose output
bats -t tests/concurrency/scratchpad-lock.bats

# Run specific test within file
bats -f "concurrent scratchpad updates" tests/concurrency/scratchpad-lock.bats
```

## Regression Assertions

All concurrency fixes have now landed (issues #8, #9, #15, #19, #25, #26).
All tests use hard-failure assertions — if a fix regresses, the test will
fail.  The old "EXPECTED FAILURE" `return 0` escape hatch pattern has been
removed from all test files.

If a new concurrency fix is in-progress and not yet landed, use
`skip "Pending: waiting for issue #N"` rather than a `return 0` escape hatch.

## CI Integration

These tests run in CI on every PR:

```yaml
# .github/workflows/test.yml
- name: Run concurrency tests
  run: make test FILTER=concurrency
```

**Important:** CI environment may have different timing characteristics. Barriers ensure reliability across environments.

## macOS / bash 3.2 Compatibility

All five concurrency test files include a `setup_file()` guard that skips the
entire file when the test runner is bash 3.2 (macOS system bash):

```bash
setup_file() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    skip "Concurrency tests require bash 4+ (running bash ${BASH_VERSION}); install via: brew install bash"
  fi
}
```

**Why this is needed:** On macOS, `/bin/bash` is bash 3.2, which takes
50-150 ms per subshell on cold cache.  With N=5 processes and a 10 s barrier
window, you can still exhaust the timeout on a heavily-loaded laptop if the
subshells start serially rather than in parallel.  The skip eliminates false
failures on macOS dev machines while keeping full coverage on Linux CI (where
bash 4+ is the default) and for macOS developers who have Homebrew bash on
`PATH`.

To run concurrency tests locally on macOS:

```bash
# Option 1: invoke bats with Homebrew bash
/opt/homebrew/bin/bash $(which bats) tests/concurrency/

# Option 2: put Homebrew bash first in PATH
export PATH="/opt/homebrew/bin:$PATH"
bats tests/concurrency/
```

## Debugging Concurrency Tests

If a test fails intermittently:

1. **Check barrier count** - Does `expected_count` match actual spawned processes?
2. **Check cleanup** - Are background processes properly cleaned up in teardown?
3. **Check file paths** - Are temp files in `$RITE_TEST_TMPDIR` (auto-cleaned)?
4. **Barrier timeout** - Default is 10 seconds (100 × 0.1 s); was 5 s before this fix.
5. **Add debug output** - Use `>&2` to print to stderr (doesn't break assertions)
6. **bash version** - Run `bash --version`; must be 4+. On macOS, `brew install bash`.

Example debug pattern:

```bash
echo "DEBUG: Process $i starting, barrier count: $count" >&2
```

## References

- **Issue #8** - Per-issue locking + session state races
- **Issue #15** - Stale branch push races
- **Issue #19** - Scratchpad concurrent write races
- **Issue #25** - Duplicate follow-up issue creation
- **Issue #26** - Worktree creation races

See individual test files for detailed test cases and assertions.
