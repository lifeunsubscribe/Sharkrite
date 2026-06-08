#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
# tests/regression/conventions-mktemp-failure-isolation.bats
#
# Regression test for: inline mktemp failure-isolation gap in
# update_conventions_from_marker().
#
# Issue #346 (parent PR #318).
#
# Problem: update_conventions_from_marker() is called inline (not in a
# subshell) at the top of assess-documentation.sh's execution body.  Three
# mktemp calls inside the function were unguarded, so a mktemp failure under
# set -euo pipefail would kill the entire documentation-assessment process —
# aborting changelog, security, architecture, API, and ADR assessments too.
#
# Fix: each mktemp call now includes a || { ... return 0 / continue } guard
# that emits a warning and skips the function (or skips the current block for
# the in-loop mktemp) without propagating to the caller.
#
# This test verifies:
#   1. When mktemp always fails, update_conventions_from_marker returns 0
#      (does not propagate the failure).
#   2. A call made after update_conventions_from_marker with a failing mktemp
#      still executes — proving the parent process (assess-documentation.sh)
#      is not killed.
#   3. Static assertion: all three mktemp call-sites in the function have the
#      `|| {` guard pattern in the source file.

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: load update_conventions_from_marker() and dependencies exactly as
# conventions-marker-append.bats does — extract only the function bodies so
# we do not trigger top-level script execution.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_INTERNAL_DOCS_DIR="${RITE_TEST_TMPDIR}/.rite/docs"
  mkdir -p "$RITE_INTERNAL_DOCS_DIR"

  export _MARKER_DIR
  _MARKER_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/markers.XXXXXX")"

  source "${RITE_REPO_ROOT}/lib/utils/markers.sh"

  # Stub logging so output does not pollute bats' TAP stream.
  print_warning() { :; }
  print_info()    { :; }
  verbose_info()  { :; }
  export -f print_warning print_info verbose_info

  source "${RITE_REPO_ROOT}/lib/utils/tag-index.sh"

  # Extract _mark_updated() and update_conventions_from_marker() — same awk
  # extraction pattern used in conventions-marker-append.bats.
  eval "$(awk '
    /^_mark_updated\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
    /^update_conventions_from_marker\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/assess-documentation.sh")"

  mkdir -p "${RITE_TEST_TMPDIR}/docs/architecture"
  cat > "${RITE_TEST_TMPDIR}/docs/architecture/conventions.md" <<'EOF'
# Sharkrite Conventions Catalog

**Auto-appended on merge — do not hand-edit.**

---

## seed-convention

**Rule:** This is a seed entry for testing.

**Why:** Provides a baseline so mktemp failure tests have something to work with.

**References:** #1

---
EOF
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: build a minimal PR body with one sharkrite-convention block
# ---------------------------------------------------------------------------

minimal_pr_body() {
  cat <<'BODY'
This PR adds an improvement.

<!-- sharkrite-convention -->
title: test-convention-for-isolation
rule: Never let temp file creation abort the parent process
why: mktemp can fail under disk-full / missing-tmp conditions
references: #346
<!-- /sharkrite-convention -->

Closes #99
BODY
}

# ---------------------------------------------------------------------------
# Test 1: mktemp failure on _body_file → returns 0
# ---------------------------------------------------------------------------

@test "mktemp failure on body file: function returns 0 (does not propagate)" {
  # Shadow mktemp with a function that always fails.
  mktemp() { return 1; }
  export -f mktemp

  local pr_body
  pr_body="$(minimal_pr_body)"

  # The function must return 0 (graceful skip), not propagate the mktemp failure.
  run update_conventions_from_marker "99" "$pr_body"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 2: caller still executes after mktemp failure in update_conventions
# ---------------------------------------------------------------------------

@test "caller continues after update_conventions_from_marker mktemp failure" {
  # Shadow mktemp to always fail — simulates disk-full / /tmp missing.
  mktemp() { return 1; }
  export -f mktemp

  local pr_body
  pr_body="$(minimal_pr_body)"

  # Sentinel: will be set to "reached" if execution continues past the call.
  _sentinel="not-reached"

  # Run both calls in a subshell under set -euo pipefail so that any accidental
  # propagation would kill the subshell and leave _sentinel_file unwritten.
  local _sentinel_file="${BATS_TEST_TMPDIR}/sentinel"

  (
    set -euo pipefail
    update_conventions_from_marker "99" "$pr_body"
    # This line must execute even after the mktemp failure above.
    echo "reached" > "$_sentinel_file"
  )

  [ -f "$_sentinel_file" ] || {
    echo "FAIL: code after update_conventions_from_marker did not execute — process was killed" >&2
    return 1
  }
  [ "$(cat "$_sentinel_file")" = "reached" ]
}

# ---------------------------------------------------------------------------
# Test 3: static assertion — all three mktemp sites have isolation guards
# ---------------------------------------------------------------------------

@test "all three mktemp call-sites in update_conventions_from_marker have || guard" {
  local _src="${RITE_REPO_ROOT}/lib/core/assess-documentation.sh"

  # Extract lines of the function body only (from the function open to its
  # closing brace at column 0) so we don't accidentally count mktemp calls
  # outside the function.
  local _fn_body
  _fn_body="$(awk '
    /^update_conventions_from_marker\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$_src")"

  # Count bare mktemp assignments (without a guard) — pattern: mktemp) not
  # followed by || on the same line.
  # We accept both `$(mktemp)` on a line by itself and `$(mktemp 2>/dev/null)`.
  local _guarded_count
  _guarded_count=$(printf '%s\n' "$_fn_body" | grep -c '\$(mktemp' || true)

  local _unguarded_count
  _unguarded_count=$(printf '%s\n' "$_fn_body" | \
    grep '\$(mktemp' | grep -vc '||' || true)

  if [ "$_unguarded_count" -ne 0 ]; then
    echo "FAIL: $_unguarded_count unguarded mktemp call(s) found in update_conventions_from_marker()" >&2
    printf '%s\n' "$_fn_body" | grep '\$(mktemp' >&2
    return 1
  fi

  # There must be at least the 3 known mktemp calls in the function.
  if [ "$_guarded_count" -lt 3 ]; then
    echo "FAIL: expected at least 3 guarded mktemp calls, found $_guarded_count" >&2
    return 1
  fi
}
