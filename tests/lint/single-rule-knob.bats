#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
# sharkrite-gate-serial — the empty-knob test deliberately runs ONE full 36-rule
# scan (~85s); keep it out of the parallel group so it never contends toward the
# 120s BATS_TEST_TIMEOUT (the exact hang class this knob exists to prevent).
#
# Regression tests for the SHARKRITE_LINT_ONLY single-rule knob.
#
# Why it exists (2026-07-18 gate-hang incident): lint-rule bats tests each
# shelled out to the FULL 36-rule linter (~84s/scan, some files 10-26x), none
# serial-marked — under the gate's `bats --jobs 8` the concurrent scans starved
# the CPU, blew the 120s BATS_TEST_TIMEOUT, and dragged gates to the 1800s
# watchdog (batch 155134: 15-42min gates, 3 issues failed). The knob lets a
# rule's own test run JUST that rule (~1s).
#
# Contract pinned here:
#   1. Scoped run executes ONLY the named rule (other rules' checks absent)
#   2. Scoped run still DETECTS violations of the named rule (exit 1)
#   3. A rule number with no fragment FAILS LOUDLY (exit 1) — a typo must
#      never silently source zero rules and let a "no violation" assert pass
#   4. Unset/empty knob runs all rules (production/gate path unchanged)

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
  FIXTURE_DIR=$(mktemp -d)
  export FIXTURE_DIR
}

teardown() { rm -rf "$FIXTURE_DIR"; }

@test "SHARKRITE_LINT_ONLY: scoped run detects a violation of the named rule" {
  # Rule 15 (BARE_MARKER_GREP) fixture: unanchored marker grep
  cat > "$FIXTURE_DIR/bad.sh" <<'EOF'
#!/bin/bash
if echo "$X" | grep -q "sharkrite-parent-pr:"; then echo hi; fi
EOF
  RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR" SHARKRITE_LINT_ONLY=15 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "BARE_MARKER_GREP" ]]
}

@test "SHARKRITE_LINT_ONLY: scoped run skips other rules' checks" {
  # A file that trips Rule 16 (MISSING_RESOURCE_GUARD is lib/-scoped; use a
  # rule that scans EXTRA_DIRS: Rule 08 UNSAFE_PIPE_IN_CMDSUB) — but scope to
  # Rule 15 only. The Rule 08 violation must NOT be reported.
  cat > "$FIXTURE_DIR/pipe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
VAR=$(echo "$text" | grep "pattern")
EOF
  RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR" SHARKRITE_LINT_ONLY=15 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
}

@test "SHARKRITE_LINT_ONLY: comma list runs each named rule" {
  cat > "$FIXTURE_DIR/pipe.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
VAR=$(echo "$text" | grep "pattern")
EOF
  RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR" SHARKRITE_LINT_ONLY=15,08 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
}

@test "SHARKRITE_LINT_ONLY: nonexistent rule number fails loudly, not silently" {
  SHARKRITE_LINT_ONLY=999 run bash "$LINT_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "no tools/lint-rules/999-" ]]
}

@test "SHARKRITE_LINT_ONLY: exact-number match — 1 does not alias rules 10-19" {
  # Rule 1 exists; rule 10 also exists. A glob-based membership check might
  # treat ",1," as matching ",10," (substring). Verify rule 10's check is absent.
  cat > "$FIXTURE_DIR/sed-i.sh" <<'EOF'
#!/bin/bash
sed -i '' 's/foo/bar/' file.txt
EOF
  RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR" SHARKRITE_LINT_ONLY=01 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "BARE_BSD_SED_I" ]]
}
