# Test Authoring Runbook
## Sharkrite bats test craft — read before writing or modifying any test

### Purpose

Phase 4 of a dev session is Test Authoring & Syntax Check & Lint: write/update
tests, run `bash -n`, and run `tools/sharkrite-lint.sh` — the rite workflow runs
the full suite after the session, never inside it. This runbook encodes the authoring craft learned from live incidents
(2026-07): where to put tests, how to stub, how to source, and which markers to
carry. Each rule names its deterministic enforcer (lint rule in
`tools/sharkrite-lint.sh`) where one exists; rules without one are marked
**prompt-residue** — this text is the only guard, so apply them with extra care.

---

### 1. Extend-over-create (prompt-residue; future lint nudge planned)

Before creating a new `.bats` file, find an existing file that already covers the
same lib paths and append your `@test` there. File count is the main wall-clock
multiplier for the post-commit gate (audit: 90% of test-adding commits added one
new file each).

Run this pre-authoring grep for each source file you changed:

```bash
grep -rln "sharkrite-test-covers:.*lib/utils/your-file.sh" tests/regression tests/lint
```

Append to a matching file when one exists. Create a new file only when no
existing file covers the paths, or the existing file's setup/fixture style is
incompatible with what you need.

### 2. Stubbing that works (#848 lint pending; prompt-residue until it lands)

- **Hide a binary by stripping PATH, not by defining a function.** A shell
  function override cannot defeat `command -v` lookups of a real binary, and
  `export -f` stubs die at external-exec boundaries — anything invoked via
  `timeout(1)`, `xargs`, `env`, or a non-bash subprocess never sees the function
  (the `_hide_npm` incident). Build a stub dir containing only the binaries you
  want visible and point `PATH` at it.
- **Re-stub AFTER sourcing env-guarded libs.** Libs with `_RITE_*_LOADED` env
  guards (e.g. `gh-retry.sh` / `_RITE_GH_RETRY_LOADED`) define their real
  functions at source time and OVERWRITE any same-named stub defined before the
  source. Define (or re-define) stubs like `gh_safe` after the LAST `source`
  line in `setup()`. Live failure: a pre-source `gh_safe` stub was silently
  overwritten and the exit-14 test hit live GitHub for two days.

### 3. Sourcing libs in tests (Rule 30: `BATS_SETUP_STRICT_LEAK`)

- Source executable libs with `RITE_SOURCE_FUNCTIONS_ONLY=1 source "$file"` so
  only function definitions load (no program body, no network calls).
- After the LAST lib source in `setup()`/`setup_file()`, restore bats' shell
  flags: `set +u; set +o pipefail`. Lib files run `set -euo pipefail` at source
  time and `source` executes in the caller's shell — the leaked flags swallow a
  failing test into "not run" (the gate then sees exit 1 with zero findings).
- **NEVER `set +e`.** bats failure detection relies on errexit; with it disabled
  a failing test reports `ok` (verified live — strictly worse than the swallow).

### 4. No `trap ... EXIT` in `@test` bodies (Rule 29: `TRAP_EXIT_IN_BATS_TEST`)

bats emits each test's result from its own EXIT trap. A `trap ... EXIT` (or
`trap - EXIT`) inside a `@test` body clobbers it — the result is silently
dropped ("Executed N instead of expected M tests"). Cleanup belongs in
`teardown()`; bats runs it for every test, pass or fail.

### 5. Covers-header accuracy (accuracy: future lint; presence: `MISSING_TEST_COVERAGE_HEADER`)

The `# sharkrite-test-covers:` header drives targeted gate selection — list ONLY
paths the tests actually exercise (source, invoke, or grep). Aspirational
entries make the file run on unrelated changes and inflate every gate iteration
(audit: 5/15 sampled wide files were aspirational; full-phase.bats was 6/6
aspirational). Rule of thumb: every non-glob header entry should have at least
one reference in a test body. Headerless files are SKIPPED by the gate — always
include the header on new files, and keep it truthful on existing ones.

**Narrow the header to functions when the source file is large.** A path may
carry a function scope:

```
# sharkrite-test-covers: lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial
```

The gate then selects this file only when the diff touches one of those
top-level functions. A bare path keeps file-level behavior, so adopt it where
it pays: a 2,900-line file with 34 functions and 29 covering test files meant a
20-line change selected all 29 — which wasted gate time AND created the
parallel load that made those same tests flake. Unattributable changes
(top-level constants, non-shell files, no computable diff) fall back to
file-level selection: precision is an optimization, never a filter that can
hide a regression.

**Scoping must follow the dependency graph, not just the name you wrote.** The
gate expands a changed function to everything that (transitively) calls it, so a
test scoped to an orchestrator still runs when a helper beneath it changes.
Honor the same principle anywhere else: `jest --findRelatedTests` follows the
import graph and `pytest-testmon` tracks executed lines for exactly this reason.
A scoping scheme that ignores transitivity does not save time, it loses coverage.

**Scope only what is genuinely narrow.** Measured on sharkrite (2026-10-13):
27 of 32 test-gate.sh coverers invoke the real gate end-to-end, so caller
expansion correctly implicates them on almost any change — scoping their headers
narrowed selection from 32 files to 29 and added noise for nothing. Only three
files exercise a single function directly, and only those were scoped. If a test
drives the whole pipeline, leave the bare path: the honest fix there is test
architecture (fewer end-to-end tests), not a more clever header.

**This generalizes — carry it into every repo you build tests for.** Whatever
the language or runner, wire the tightest *correct* selection the toolchain
supports, and never settle for "run everything":

- **jest / vitest** — `--findRelatedTests <changed files>`, or `--changedSince`
  against the diff base; prefer passing the explicit changed-file list so the
  runner and the gate agree on what "changed" means.
- **pytest** — `pytest-testmon` (per-test dependency tracking) or at minimum
  path-scoped selection of the changed package.
- **go** — `go test ./<changed package>/...` rather than `./...`.
- **monorepos** — map changed paths to workspaces and test only those, then let
  the framework scope within each workspace.

Two invariants when you add scoping anywhere: it must **fail safe** (anything
unattributable runs the broader set), and a full unfiltered suite must never
run inside a workflow — that belongs in an overnight pipeline only.

### 6. Serial hint (prompt-residue; lint heuristic pending)

If a test uses `kill`, background jobs (`&`), sleep-based timing, or concurrency
probes, add `# sharkrite-gate-serial` within the file's first 15 lines so the
gate keeps it out of parallel batches. Audit: the 6 flaky files caused roughly
half of all failure-event content, and none of them carried the hint.

### 7. Fixture hygiene (prompt-residue)

- Generated-fixture strings must not contain patterns that repo-wide pin tests
  grep for (the #860 echo-source incident: a fixture's echoed orchestrator
  source-line string tripped a pin that greps `tests/` without echo-awareness).
  Use neutral names (e.g. `config.sh`) in fixture strings.
- When a fixture contains literal `@test` lines, generate it with `printf`
  rather than a heredoc — bats' preprocessor rewrites heredoc `@test` lines
  in-place, and the planned-set parser reads on-disk sources.

### 8. Structural vs behavioral pins (prompt-residue)

- **Behavioral fixture tests are the default:** exercise the function and assert
  output/exit codes.
- **Structural greps** (asserting source text contains/lacks a pattern) only for
  invariants code cannot express — cd-guards, guard placement, wording
  contracts.
- **Codebase-wide sweeps belong in lint rules, not bats:** full lint runs
  unfiltered in seconds, while a bats sweep imposes a selection floor on every
  gate run. Audit: 198 grep-pins across 48 files, 14 already dead.

### 9. Assert against the verdict seam, not the full gate (prompt-residue)

When every assertion in a test is a `jq` check on the gate's JSON output — exit
code, `tests[]` length and content, `lint[]` length and content — call
`_gate_build_verdict` directly instead of `run_test_gate`. The verdict seam is a
pure function of its inputs: no subprocess, no stub runner on `PATH`, no git
fixture needed.

**How to recognise a verdict-only test:** every assertion after the gate call
is one of `[ "$_rc" -eq N ]`, `run jq -r '...' "$_out"`, or
`[[ "$output" == *"..."* ]]`. If any assertion touches a file created by the
runner (a `diag.log`, a worktree, a node_modules tree) the test is not
verdict-only and must keep `run_test_gate`.

**Pattern:**

```bash
@test "description of the gate JSON behavior" {
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  _lint_raw="$BATS_TEST_TMPDIR/lint.raw"
  _tests_raw="$BATS_TEST_TMPDIR/tests.raw"
  _out="$BATS_TEST_TMPDIR/out.json"

  # Pre-built lint raw (empty = make check passed)
  printf '' > "$_lint_raw"
  # Pre-built TAP — exactly what run_test_gate would hand to _gate_build_verdict
  # after watchdog/notrun synthesis:
  printf 'TAP version 13\n1..1\nnot ok 1 deliberately failing test\n' > "$_tests_raw"

  _rc=0; _gate_build_verdict "$_lint_raw" "$_tests_raw" 0 1 "$_out" "" "" || _rc=$?
  [ "$_rc" -eq 1 ]

  run jq -r '.exit_code' "$_out"; [ "$output" = "1" ]
  run jq -r '.tests | length' "$_out"; [ "$output" -ge 1 ]
}
```

**Signature:**
`_gate_build_verdict lint_raw tests_raw lint_exit tests_exit out_json [reason] [head_sha]`

- `lint_raw` — raw `make check` stdout (gcc format: `file:line:col: level: msg [SCnnnn]`)
- `tests_raw` — raw bats TAP output, including any already-synthesized
  `[tests_not_run]` lines (watchdog collapse or per-test synthesis from
  `_synthesize_notrun_findings`)
- `lint_exit` / `tests_exit` — original process exit codes (1 = failure)
- `out_json` — path for the output JSON
- `reason` — top-level verdict reason (mirroring `_gate_reason` in `run_test_gate`);
  per-finding reasons always derive from the `[tests_not_run]` prefix
- `head_sha` — optional SHA embedded in the JSON; empty string is fine for tests

**TAP fixture content for watchdog tests.** Copy the exact text from
`_make_tests_raw_watchdog` in `tests/regression/gate-verdict-seam.bats`:

```
1..N
not ok 1 [tests_not_run] watchdog killed bats group after 1800s — N tests not run; root cause is gate runtime, not the tests (reduce selection cost: add # sharkrite-gate-serial to load-heavy files, or scope lint rules with SHARKRITE_LINT_ONLY=N)
```

**TAP fixture content for non-watchdog plan-deficit tests** (`_synthesize_notrun_findings`):

```
1..N
not ok 1 [tests_not_run] planned test in selected bats file(s) never reported a result (bats plan/executed mismatch) — test name unresolvable; check the run log
```

**Setup.** Source only `gate-verdict.sh` (not `test-gate.sh`) and add the
`BATS_PRE_SOURCE_STUB_OVERWRITE` suppression comment since the file uses a
function-sentinel guard:

```bash
setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  _diag() { true; }
  source "$RITE_LIB_DIR/utils/config.sh" 2>/dev/null || true
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: gate-verdict.sh uses a function-sentinel guard (declare -f _gate_write_json); pre-source _diag() stub is preserved on source.
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
}
```

**Header.** Scope to `_gate_build_verdict` so the test only runs when that
function changes:

```
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_build_verdict
```

**Serial hint.** Do NOT add `# sharkrite-gate-serial` — verdict-seam tests spawn
no subprocesses and are safe to run in parallel.

**Canonical reference:** `tests/regression/gate-verdict-seam.bats`.

### 10. Shared mocks (prompt-residue)

When three or more test files in a repo each carry their own copy of the same
module mock block or mock-client factory, extract it to the framework's shared
setup **before adding a fourth**. The threshold is ≥3 duplicating files; at
that point the cost of a future per-file patch (update N files, rerun, miss
one) outweighs the one-time extraction.

**Per-framework extraction targets:**

- **vitest** — add the mock to `setupFiles` in `vitest.config.ts`
  (e.g. `setupFiles: ['test/setup/mocks.ts']`); hoisted `vi.mock()` calls in
  that file are visible to every test without re-declaring.
- **jest** — add the mock to `setupFilesAfterEach` (or `setupFiles` for
  module-level mocks) in `jest.config.*`; shared factory functions go in
  `test/helpers/` and are imported where needed.
- **bats** — add the shared helper function or stub-dir setup to
  `tests/helpers/`; source it from each `setup()` via
  `source "$BATS_TEST_DIRNAME/../helpers/mock-client.bash"`.

Live failure (orrery batch 2026-10-27): five vitest files each carried their
own `vi.mock('react-native'|'expo-crypto'|'expo-linking')` blocks and a
per-file `makeMockClient` variant. A review-fix polyfill import broke all 14
tests in one file at module load; the fix was to add yet another per-file
hoisted mock, where a centralized `setupFiles` entry would have been a
one-line change in one place.
