# Test Authoring Runbook
## Sharkrite bats test craft — read before writing or modifying any test

### Purpose

Phase 4 of a dev session is Test Authoring & Syntax Check: write/update tests plus
`bash -n` only — the rite workflow runs the full suite after the session, never
inside it. This runbook encodes the authoring craft learned from live incidents
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
