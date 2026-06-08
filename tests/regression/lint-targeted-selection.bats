#!/usr/bin/env bats
# sharkrite-test-covers: tools/*-lint.sh, lib/utils/test-gate.sh
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
  [[ "$output" =~ "targeted scope (1 file" ]] || { echo "expected '1 file' count; got:" >&2; echo "$output" >&2; return 1; }
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
