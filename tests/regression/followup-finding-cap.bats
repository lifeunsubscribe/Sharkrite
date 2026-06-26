#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/utils/config.sh
# Regression tests for: per-finding GitHub API call cap (issue #649)
#
# Problem: the one-issue-per-finding loop in assess-and-resolve.sh ran full
# dedup machinery (issue list + issue view + pr view + backoff sleeps) plus
# create/comment/lock per finding with no upper bound.  A PR with 50+
# ACTIONABLE_LATER items could exhaust GitHub secondary rate limits.
#
# Fix: RITE_MAX_FINDINGS_PER_RUN (default 20) caps the loop.  When the cap
# is hit the script skips remaining findings, emits a print_warning, and
# writes a [diag] FOLLOWUP_CAP_HIT line to RITE_LOG_FILE.
#
# Tests in this file:
#   1. Static: RITE_MAX_FINDINGS_PER_RUN cap guard exists in the loop body
#   2. Static: _findings_skipped_by_cap tracking variable is initialized
#   3. Static: FOLLOWUP_CAP_HIT diag line exists in the post-loop section
#   4. Static: RITE_MAX_FINDINGS_PER_RUN is exported in config.sh
#   5. Unit:   findings beyond cap are counted in _findings_skipped_by_cap
#   6. Unit:   cap=0 disables the guard (all findings processed)
#   7. Unit:   cap exactly at finding count processes all findings (no skip)
#   8. Unit:   cap below finding count skips excess findings
#
# Verification commands:
#   bats tests/regression/followup-finding-cap.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir

  export ASSESS_RESOLVE_SCRIPT="${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh"
  export CONFIG_SCRIPT="${RITE_REPO_ROOT}/lib/utils/config.sh"

  [ -f "$ASSESS_RESOLVE_SCRIPT" ] || {
    echo "setup: ASSESS_RESOLVE_SCRIPT not found at $ASSESS_RESOLVE_SCRIPT" >&2
    false
  }
  [ -f "$CONFIG_SCRIPT" ] || {
    echo "setup: CONFIG_SCRIPT not found at $CONFIG_SCRIPT" >&2
    false
  }
}

teardown() {
  teardown_test_tmpdir
}

# ─── Test 1: Static — cap guard present in the per-finding loop ──────────────

@test "assess-and-resolve.sh: RITE_MAX_FINDINGS_PER_RUN cap guard exists in the loop" {
  # The cap guard must appear inside the per-finding while loop.
  # grep for the guard conditional that compares _finding_index to the cap.
  run grep -n 'RITE_MAX_FINDINGS_PER_RUN' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: No RITE_MAX_FINDINGS_PER_RUN reference found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected the cap guard to be present in the per-finding loop"
    false
  }

  # Also verify the cap guard performs a numeric comparison with _finding_index
  run grep -n '_finding_index.*_findings_cap\|_findings_cap.*_finding_index' "$ASSESS_RESOLVE_SCRIPT"
  [ "$status" -eq 0 ] || {
    echo "FAIL: No cap comparison between _finding_index and _findings_cap found"
    echo "Expected: if [ \"\$_findings_cap\" -gt 0 ] && [ \"\$_finding_index\" -gt \"\$_findings_cap\" ]"
    false
  }
}

# ─── Test 2: Static — skip counter initialized before the loop ───────────────

@test "assess-and-resolve.sh: _findings_skipped_by_cap initialized before the loop" {
  # The skip counter must be initialized to 0 before the while loop starts.
  run grep -n '_findings_skipped_by_cap=0' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: _findings_skipped_by_cap=0 not found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected initialization before the per-finding while loop"
    false
  }
}

# ─── Test 3: Static — FOLLOWUP_CAP_HIT diag line in post-loop section ────────

@test "assess-and-resolve.sh: FOLLOWUP_CAP_HIT diag line exists in post-loop section" {
  # After the while loop, when _findings_skipped_by_cap > 0, a _diag line
  # must be emitted to RITE_LOG_FILE for health-report aggregation.
  run grep -n 'FOLLOWUP_CAP_HIT' "$ASSESS_RESOLVE_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: FOLLOWUP_CAP_HIT diag line not found in $ASSESS_RESOLVE_SCRIPT"
    echo "Expected: _diag \"FOLLOWUP_CAP_HIT issue=... pr=... processed=... skipped=... cap=...\""
    false
  }
}

# ─── Test 4: Static — RITE_MAX_FINDINGS_PER_RUN exported in config.sh ────────

@test "config.sh: RITE_MAX_FINDINGS_PER_RUN is exported" {
  # The config must export the variable so child processes inherit it.
  run grep -n 'export RITE_MAX_FINDINGS_PER_RUN' "$CONFIG_SCRIPT"

  [ "$status" -eq 0 ] || {
    echo "FAIL: 'export RITE_MAX_FINDINGS_PER_RUN' not found in $CONFIG_SCRIPT"
    false
  }
}

# ─── Test 5: Unit — findings beyond cap are counted in _findings_skipped_by_cap

@test "per-finding cap: findings beyond cap increment _findings_skipped_by_cap" {
  # Simulate the cap logic for 5 findings with cap=3.
  # Expected: _findings_skipped_by_cap=2 (findings 4 and 5 are skipped).
  FILTERED_CONTENT="### Finding one - ACTIONABLE_LATER
**Severity:** HIGH

### Finding two - ACTIONABLE_LATER
**Severity:** MEDIUM

### Finding three - ACTIONABLE_LATER
**Severity:** HIGH

### Finding four - ACTIONABLE_LATER
**Severity:** MEDIUM

### Finding five - ACTIONABLE_LATER
**Severity:** LOW"

  _finding_index=0
  _findings_skipped_by_cap=0
  _findings_cap=3

  while IFS= read -r _fh_line; do
    [ -z "$_fh_line" ] && continue
    _finding_index=$((_finding_index + 1))
    # Mirror the cap guard from assess-and-resolve.sh
    if [ "$_findings_cap" -gt 0 ] 2>/dev/null && [ "$_finding_index" -gt "$_findings_cap" ]; then
      _findings_skipped_by_cap=$((_findings_skipped_by_cap + 1))
      continue
    fi
    # (remaining loop body would run here)
  done < <(echo "$FILTERED_CONTENT" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)

  [ "$_finding_index" -eq 5 ] || {
    echo "FAIL: Expected _finding_index=5 (all findings counted), got: $_finding_index"
    false
  }

  [ "$_findings_skipped_by_cap" -eq 2 ] || {
    echo "FAIL: Expected _findings_skipped_by_cap=2 (findings 4+5 skipped), got: $_findings_skipped_by_cap"
    false
  }
}

# ─── Test 6: Unit — cap=0 disables the guard (all findings processed) ─────────

@test "per-finding cap: cap=0 disables the guard and all findings are processed" {
  # When RITE_MAX_FINDINGS_PER_RUN=0, the guard must not skip any findings.
  FILTERED_CONTENT="### Finding A - ACTIONABLE_LATER
**Severity:** HIGH

### Finding B - ACTIONABLE_NOW
**Severity:** CRITICAL

### Finding C - ACTIONABLE_LATER
**Severity:** MEDIUM"

  _finding_index=0
  _findings_skipped_by_cap=0
  _findings_cap=0   # disabled

  while IFS= read -r _fh_line; do
    [ -z "$_fh_line" ] && continue
    _finding_index=$((_finding_index + 1))
    # Mirror the cap guard: [ 0 -gt 0 ] is false → guard never fires
    if [ "$_findings_cap" -gt 0 ] 2>/dev/null && [ "$_finding_index" -gt "$_findings_cap" ]; then
      _findings_skipped_by_cap=$((_findings_skipped_by_cap + 1))
      continue
    fi
    # (remaining loop body would run here)
  done < <(echo "$FILTERED_CONTENT" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)

  [ "$_findings_skipped_by_cap" -eq 0 ] || {
    echo "FAIL: Expected _findings_skipped_by_cap=0 (cap disabled), got: $_findings_skipped_by_cap"
    false
  }

  [ "$_finding_index" -eq 3 ] || {
    echo "FAIL: Expected all 3 findings processed, got: _finding_index=$_finding_index"
    false
  }
}

# ─── Test 7: Unit — cap exactly at finding count processes all findings ────────

@test "per-finding cap: cap equal to finding count processes all without skipping" {
  # 4 findings, cap=4 → no skips.
  FILTERED_CONTENT="### Alpha - ACTIONABLE_LATER
**Severity:** HIGH

### Beta - ACTIONABLE_NOW
**Severity:** MEDIUM

### Gamma - ACTIONABLE_LATER
**Severity:** HIGH

### Delta - ACTIONABLE_LATER
**Severity:** MEDIUM"

  _finding_index=0
  _findings_skipped_by_cap=0
  _findings_cap=4   # exact match

  while IFS= read -r _fh_line; do
    [ -z "$_fh_line" ] && continue
    _finding_index=$((_finding_index + 1))
    if [ "$_findings_cap" -gt 0 ] 2>/dev/null && [ "$_finding_index" -gt "$_findings_cap" ]; then
      _findings_skipped_by_cap=$((_findings_skipped_by_cap + 1))
      continue
    fi
  done < <(echo "$FILTERED_CONTENT" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)

  [ "$_findings_skipped_by_cap" -eq 0 ] || {
    echo "FAIL: Expected 0 skips when cap equals finding count, got: $_findings_skipped_by_cap"
    false
  }

  [ "$_finding_index" -eq 4 ] || {
    echo "FAIL: Expected _finding_index=4, got: $_finding_index"
    false
  }
}

# ─── Test 8: Unit — cap below finding count skips the excess ──────────────────

@test "per-finding cap: cap=1 with 3 findings skips 2" {
  # Minimal case: cap=1 means only the first finding is processed.
  FILTERED_CONTENT="### First - ACTIONABLE_NOW
**Severity:** CRITICAL

### Second - ACTIONABLE_LATER
**Severity:** HIGH

### Third - ACTIONABLE_LATER
**Severity:** MEDIUM"

  _finding_index=0
  _findings_skipped_by_cap=0
  _findings_cap=1

  while IFS= read -r _fh_line; do
    [ -z "$_fh_line" ] && continue
    _finding_index=$((_finding_index + 1))
    if [ "$_findings_cap" -gt 0 ] 2>/dev/null && [ "$_finding_index" -gt "$_findings_cap" ]; then
      _findings_skipped_by_cap=$((_findings_skipped_by_cap + 1))
      continue
    fi
  done < <(echo "$FILTERED_CONTENT" | grep -E "^### .* - ACTIONABLE_(NOW|LATER)" || true)

  [ "$_findings_skipped_by_cap" -eq 2 ] || {
    echo "FAIL: Expected 2 skipped findings (cap=1 out of 3), got: $_findings_skipped_by_cap"
    false
  }

  [ "$_finding_index" -eq 3 ] || {
    echo "FAIL: Expected _finding_index=3 (all counted even when skipped), got: $_finding_index"
    false
  }
}
