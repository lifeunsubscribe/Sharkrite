#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh, lib/utils/test-gate.sh
#
# Regression test: targeted lint selection via RITE_LINT_FILES.
#
# Parallels the bats `sharkrite-test-covers` targeting (#462) for the
# custom-lint pass. The optimization narrows `make lint` to the commit's
# changed-file set when invoked from test-gate.sh.
#
# Mechanism:
#   - tools/sharkrite-lint.sh: when RITE_LINT_FILES is set, SHELL_FILES is
#     filtered to the intersection. Empty intersection → exit 0 with notice.
#   - lib/utils/test-gate.sh: _select_lint_by_changed_paths returns either
#     FORCE_FULL (lint-rule/Makefile changed), an absolute-path list, or
#     empty (no shell-source changes).
#
# Direct `make lint` (no env var) keeps full-scan behavior unchanged.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LINT_SCRIPT="$PROJECT_ROOT/tools/sharkrite-lint.sh"

  # Fixture dir lives outside the project tree so production lint runs ignore
  # it; we inject it via RITE_LINT_EXTRA_DIRS to make it visible to SHELL_FILES.
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/lint-targeted-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/lint-targeted-fixtures"
  unset RITE_LINT_EXTRA_DIRS
  unset RITE_LINT_FILES
}

# ---------------------------------------------------------------------------
# sharkrite-lint.sh: RITE_LINT_FILES intersection
# ---------------------------------------------------------------------------

@test "RITE_LINT_FILES unset: full scan, all violations reported" {
  # Two fixtures, each with a violation in a different rule.
  cat > "$FIXTURE_DIR/a-bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
local foo="bar"
echo "$foo"
EOF
  cat > "$FIXTURE_DIR/b-bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
gh pr list
EOF

  run "$LINT_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "a-bad.sh" ]] || { echo "$output" >&2; return 1; }
  [[ "$output" =~ "b-bad.sh" ]] || { echo "$output" >&2; return 1; }
}

@test "RITE_LINT_FILES restricts scan to listed file only" {
  cat > "$FIXTURE_DIR/a-bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
local foo="bar"
echo "$foo"
EOF
  cat > "$FIXTURE_DIR/b-bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
gh pr list
EOF

  export RITE_LINT_FILES="$FIXTURE_DIR/a-bad.sh"
  run "$LINT_SCRIPT"

  # a-bad.sh is in scope → its violation is reported, exit non-zero
  [ "$status" -ne 0 ]
  [[ "$output" =~ "a-bad.sh" ]] || { echo "expected a-bad.sh in output; got:" >&2; echo "$output" >&2; return 1; }
  # b-bad.sh is out of scope → must NOT be reported
  [[ ! "$output" =~ "b-bad.sh" ]] || { echo "b-bad.sh unexpectedly reported; got:" >&2; echo "$output" >&2; return 1; }
  # Header confirms targeted mode
  [[ "$output" =~ "targeted scope" ]] || { echo "expected 'targeted scope' notice; got:" >&2; echo "$output" >&2; return 1; }
}

@test "RITE_LINT_FILES with no in-scope files: exit 0 with notice" {
  cat > "$FIXTURE_DIR/a-bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
local foo="bar"
echo "$foo"
EOF

  # RITE_LINT_FILES points at a path NOT under bin/lib/tools and not in
  # RITE_LINT_EXTRA_DIRS — empty intersection.
  export RITE_LINT_FILES="/tmp/this-path-does-not-exist-in-shell-files.sh"
  run "$LINT_SCRIPT"

  [ "$status" -eq 0 ] || { echo "expected exit 0; got status=$status output:" >&2; echo "$output" >&2; return 1; }
  [[ "$output" =~ "no in-scope shell files" ]] || { echo "$output" >&2; return 1; }
  # a-bad.sh's violation must NOT be reported (it was excluded by the filter)
  [[ ! "$output" =~ "a-bad.sh" ]] || { echo "$output" >&2; return 1; }
}

@test "RITE_LINT_FILES drops nonexistent entries silently" {
  cat > "$FIXTURE_DIR/real.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
local foo="bar"
echo "$foo"
EOF

  # Mix: one real fixture + one nonexistent — only the real one survives the
  # intersection, and lint proceeds normally over it.
  export RITE_LINT_FILES="$FIXTURE_DIR/nonexistent.sh
$FIXTURE_DIR/real.sh"
  run "$LINT_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "real.sh" ]] || { echo "$output" >&2; return 1; }
  [[ "$output" =~ "targeted scope (1 shell file" ]] || { echo "expected '1 shell file' count; got:" >&2; echo "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# test-gate.sh: _select_lint_by_changed_paths helper
# ---------------------------------------------------------------------------

@test "_select_lint_by_changed_paths: empty diff → FORCE_FULL" {
  # Source the helper. test-gate.sh expects RITE_LIB_DIR pre-set.
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  run _select_lint_by_changed_paths "" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "FORCE_FULL" ]
}

@test "_select_lint_by_changed_paths: lint-rule change forces full scan" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  # A change to tools/sharkrite-lint.sh must trip the FORCE_FULL trigger:
  # new rule may apply retroactively to files outside the diff.
  _changed="lib/core/foo.sh
tools/sharkrite-lint.sh
docs/README.md"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "FORCE_FULL" ]
}

@test "_select_lint_by_changed_paths: Makefile change forces full scan" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  _changed="lib/core/foo.sh
Makefile"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "FORCE_FULL" ]
}

@test "_select_lint_by_changed_paths: docs-only diff → empty (skip lint)" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  # No bin/lib/tools entries → no lint-eligible paths emitted. test-gate
  # treats empty stdout as "skip lint".
  _changed="docs/architecture/foo.md
README.md"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected empty output; got: '$output'" >&2; return 1; }
}

@test "_select_lint_by_changed_paths: shell-source diff emits absolute paths" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  # Use a file that genuinely exists in the project so the [ -f ] guard passes.
  _changed="lib/utils/test-gate.sh
docs/architecture/foo.md"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  # docs/ filtered out; lib/ entry emitted as absolute path
  [ "$output" = "$PROJECT_ROOT/lib/utils/test-gate.sh" ] || {
    echo "expected absolute path to lib/utils/test-gate.sh; got: '$output'" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: deleted files filtered out by [ -f ]" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  # A file in the diff that no longer exists on disk (deletion) must not be
  # emitted — passing a nonexistent absolute path to RITE_LINT_FILES would
  # waste work and confuse the intersection check.
  _changed="lib/core/this-file-was-deleted-by-the-commit.sh"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected empty output for deleted file; got: '$output'" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# RITE_TEST_GATE_SKIP_TRIGGERS — same env var that bypasses bats triggers
# also bypasses lint triggers. post-merge-verify.sh sets it once and both
# selectors respond.
# ---------------------------------------------------------------------------

@test "_select_lint_by_changed_paths: SKIP_TRIGGERS bypasses Makefile trigger" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  RITE_TEST_GATE_SKIP_TRIGGERS=true \
    run _select_lint_by_changed_paths "Makefile" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" != "FORCE_FULL" ] || {
    echo "regression: Makefile still forced FORCE_FULL under SKIP_TRIGGERS" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: SKIP_TRIGGERS off → Makefile still triggers" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"

  # Default mode unchanged: trigger fires.
  run _select_lint_by_changed_paths "Makefile" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "FORCE_FULL" ] || {
    echo "regression: Makefile NOT triggering FORCE_FULL in default mode" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Rules 34/35: changed .bats files must be passed to lint (issue #921)
#
# _select_lint_by_changed_paths previously only emitted bin/lib/tools paths,
# so BATS_PRE_SOURCE_STUB_OVERWRITE (Rule 34) and BATS_FILE_SCOPE_ENV_READ
# (Rule 35) never ran against changed .bats files through the post-commit
# gate.  The fix adds tests/*.bats and tests/*/*.bats to the eligible pattern.
# ---------------------------------------------------------------------------

@test "_select_lint_by_changed_paths: changed .bats in tests/regression/ is emitted" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  set +u; set +o pipefail

  # Use a file that genuinely exists so the [ -f ] guard passes.
  _changed="tests/regression/lint-targeted-selection.bats"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT_ROOT/tests/regression/lint-targeted-selection.bats" ] || {
    echo "expected absolute path to bats file; got: '$output'" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: changed .bats in tests/lint/ is emitted" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  set +u; set +o pipefail

  _changed="tests/lint/bats-hygiene-rules.bats"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT_ROOT/tests/lint/bats-hygiene-rules.bats" ] || {
    echo "expected absolute path to bats file; got: '$output'" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: bats-only diff produces non-empty output (lint runs)" {
  # Regression: with only .bats files changed and no bin/lib/tools changes,
  # the old code returned empty (skip lint).  Empty means Rules 34/35 never
  # ran against the changed bats file — the exact gap this issue fixes.
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  set +u; set +o pipefail

  _changed="tests/regression/lint-targeted-selection.bats"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -n "$output" ] || {
    echo "REGRESSION: bats-only diff returned empty — Rules 34/35 would be skipped" >&2
    return 1
  }
  [ "$output" != "FORCE_FULL" ] || {
    echo "FAIL: bats-only diff escalated to full lint scan (unexpected)" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: mixed bats + lib diff emits both" {
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  set +u; set +o pipefail

  _changed=$(printf 'lib/utils/test-gate.sh\ntests/regression/lint-targeted-selection.bats\n')
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "lib/utils/test-gate.sh" || {
    echo "expected lib/utils/test-gate.sh in output; got: '$output'" >&2
    return 1
  }
  echo "$output" | grep -q "tests/regression/lint-targeted-selection.bats" || {
    echo "expected bats file in output; got: '$output'" >&2
    return 1
  }
}

@test "_select_lint_by_changed_paths: docs-only diff still produces empty even with bats extension" {
  # Docs changes are still ignored — only bin/lib/tools/tests/*.bats are eligible.
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  set +u; set +o pipefail

  _changed="docs/architecture/foo.md
README.md"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected empty output; got: '$output'" >&2; return 1; }
}

@test "_select_lint_by_changed_paths: nonexistent .bats file filtered by [ -f ]" {
  # A deleted .bats file in the diff must not be emitted.
  export RITE_LIB_DIR="$PROJECT_ROOT/lib"
  source "$PROJECT_ROOT/lib/utils/test-gate.sh"
  set +u; set +o pipefail

  _changed="tests/regression/this-was-deleted.bats"
  run _select_lint_by_changed_paths "$_changed" "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "expected empty for deleted bats; got: '$output'" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# End-to-end: Rules 34/35 actually execute against a .bats-only RITE_LINT_FILES
#
# These tests verify the full path: RITE_LINT_FILES with a .bats-only set →
# sharkrite-lint.sh does NOT early-exit → Rules 34/35 run and report violations.
# Without the fix, sharkrite-lint.sh exited 0 ("no in-scope shell files") before
# the rules were ever sourced, so no violations were reported even for bad code.
# ---------------------------------------------------------------------------

@test "E2E: bats-only RITE_LINT_FILES: lint does not skip, Rule 35 banner appears" {
  # Fixture: a .bats file with a RITE_* file-scope reference (Rule 35 violation).
  # Placed in BATS_TEST_TMPDIR so it does not live under tests/ (avoids
  # confusing the real test suite's own targeted selection).
  local _bats_fixture="${BATS_TEST_TMPDIR}/rule35-fixture.bats"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/config.sh\n_SCOPE_VAR="${RITE_LIB_DIR}/something.sh"\n@test "placeholder" { true; }\n' \
    > "$_bats_fixture"

  # RITE_LINT_FILES contains ONLY the .bats fixture — no bin/lib/tools entries.
  export RITE_LINT_FILES="$_bats_fixture"
  run "$LINT_SCRIPT"

  # Must NOT have silently skipped (old bug: exit 0 with "no in-scope shell files").
  [[ ! "$output" =~ "no in-scope shell files" ]] || {
    echo "REGRESSION: lint skipped when bats-only RITE_LINT_FILES was set" >&2
    echo "output: $output" >&2
    return 1
  }
  # Rule 35 banner must appear — confirms the rule actually executed.
  [[ "$output" =~ "BATS_FILE_SCOPE_ENV_READ" ]] || {
    echo "FAIL: Rule 35 (BATS_FILE_SCOPE_ENV_READ) banner not found in lint output" >&2
    echo "output: $output" >&2
    return 1
  }
}

@test "E2E: bats-only RITE_LINT_FILES: Rule 35 reports the fixture violation" {
  # Same fixture as above — rerun asserting a violation is actually recorded
  # (non-zero exit) and names the fixture file.
  local _bats_fixture="${BATS_TEST_TMPDIR}/rule35-violation-fixture.bats"
  printf '#!/usr/bin/env bats\n# sharkrite-test-covers: lib/utils/config.sh\n_SCOPE_VAR="${RITE_LIB_DIR}/something.sh"\n@test "placeholder" { true; }\n' \
    > "$_bats_fixture"

  export RITE_LINT_FILES="$_bats_fixture"
  run "$LINT_SCRIPT"

  # Lint must exit non-zero (violation found).
  [ "$status" -ne 0 ] || {
    echo "FAIL: expected non-zero exit for Rule 35 violation; got status=0" >&2
    echo "output: $output" >&2
    return 1
  }
  # The fixture file must be named in the output.
  [[ "$output" =~ "rule35-violation-fixture.bats" ]] || {
    echo "FAIL: fixture file not named in lint output" >&2
    echo "output: $output" >&2
    return 1
  }
}

@test "E2E: bats-only RITE_LINT_FILES: Rule 34 banner appears on stub-overwrite fixture" {
  # Fixture: a .bats file with a pre-source stub that would be overwritten by
  # an env-var-guarded lib source (Rule 34 violation).
  local _bats_fixture="${BATS_TEST_TMPDIR}/rule34-fixture.bats"
  # The fixture defines gh_safe() before sourcing a lib path, which triggers
  # Rule 34 since gh_safe is a well-known stub that env-var-guarded libs overwrite.
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    '# sharkrite-test-covers: lib/utils/config.sh' \
    'setup() {' \
    '  gh_safe() { echo "stub"; }' \
    '  source "${RITE_LIB_DIR}/utils/gh-retry.sh"' \
    '}' \
    '@test "placeholder" { true; }' \
    > "$_bats_fixture"

  export RITE_LINT_FILES="$_bats_fixture"
  run "$LINT_SCRIPT"

  # Rule 34 banner must appear — confirms the rule executed.
  [[ "$output" =~ "BATS_PRE_SOURCE_STUB_OVERWRITE" ]] || {
    echo "FAIL: Rule 34 (BATS_PRE_SOURCE_STUB_OVERWRITE) banner not found in lint output" >&2
    echo "output: $output" >&2
    return 1
  }
}
