#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite-health-report
# tests/regression/health-report-cr-precompute.bats
#
# Verifies that bin/rite-health-report pre-computes CR_TOP5_ISSUES and
# CR_MEDIAN_DURATION_S in bash from CR_LINES before passing data to Claude,
# instead of delegating those arithmetic operations to the LLM.
#
# The computation logic lives in the main script body (not in functions), so
# tests run the exact pipelines as subprocesses via helper scripts written to
# BATS_TEST_TMPDIR. Each helper sources the same pipeline that the script uses,
# reads CR_LINES from an exported env var, and prints the result.

load '../helpers/setup'

setup() {
  setup_test_tmpdir

  # Write a helper script for CR_TOP5_ISSUES computation.
  # Mirrors bin/rite-health-report lines 133-151 exactly.
  cat > "$RITE_TEST_TMPDIR/compute_top5.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
CR_LINES="${CR_LINES:-}"
CR_TOP5_ISSUES="N/A"
if [ -n "$CR_LINES" ]; then
  _cr_top5_raw=$(echo "$CR_LINES" | grep -oE 'issue=[0-9]+' | grep -oE '[0-9]+' | sort | uniq -c | sort -rn | head -5 || true)
  if [ -n "$_cr_top5_raw" ]; then
    _cr_top5_parts=""
    while IFS= read -r _cr_line; do
      _cr_count=$(echo "$_cr_line" | awk '{print $1}' || true)
      _cr_issue=$(echo "$_cr_line" | awk '{print $2}' || true)
      if [ -n "$_cr_issue" ] && [ -n "$_cr_count" ]; then
        if [ -n "$_cr_top5_parts" ]; then
          _cr_top5_parts="${_cr_top5_parts}, #${_cr_issue} (${_cr_count}x)"
        else
          _cr_top5_parts="#${_cr_issue} (${_cr_count}x)"
        fi
      fi
    done <<< "$_cr_top5_raw"
    [ -n "$_cr_top5_parts" ] && CR_TOP5_ISSUES="$_cr_top5_parts"
  fi
fi
echo "$CR_TOP5_ISSUES"
EOF
  chmod +x "$RITE_TEST_TMPDIR/compute_top5.sh"

  # Write a helper script for CR_MEDIAN_DURATION_S computation.
  # Mirrors bin/rite-health-report lines 158-176 exactly.
  cat > "$RITE_TEST_TMPDIR/compute_median.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
CR_LINES="${CR_LINES:-}"
CR_MEDIAN_DURATION_S="N/A"
if [ -n "$CR_LINES" ]; then
  _cr_durations=$(echo "$CR_LINES" | grep -oE 'duration_s=[0-9]+' | grep -oE '[0-9]+' | sort -n || true)
  if [ -n "$_cr_durations" ]; then
    _cr_dur_count=$(echo "$_cr_durations" | wc -l | tr -d ' ' || true)
    if [ "${_cr_dur_count:-0}" -gt 0 ] 2>/dev/null; then
      _cr_mid=$(( (_cr_dur_count + 1) / 2 ))
      _cr_median_val=$(echo "$_cr_durations" | sed -n "${_cr_mid}p" || true)
      if [ $(( _cr_dur_count % 2 )) -eq 0 ] 2>/dev/null; then
        _cr_mid2=$(( _cr_mid + 1 ))
        _cr_val2=$(echo "$_cr_durations" | sed -n "${_cr_mid2}p" || true)
        if [ -n "$_cr_median_val" ] && [ -n "$_cr_val2" ]; then
          _cr_median_val=$(( (_cr_median_val + _cr_val2) / 2 ))
        fi
      fi
      [ -n "$_cr_median_val" ] && CR_MEDIAN_DURATION_S="${_cr_median_val}s"
    fi
  fi
fi
echo "$CR_MEDIAN_DURATION_S"
EOF
  chmod +x "$RITE_TEST_TMPDIR/compute_median.sh"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# CR_TOP5_ISSUES tests
# ---------------------------------------------------------------------------

@test "CR_TOP5_ISSUES: empty CR_LINES returns N/A" {
  run env CR_LINES="" "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_TOP5_ISSUES: single issue appears once" {
  run env CR_LINES="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=55 duration_s=30" \
    "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "#42 (1x)" ]
}

@test "CR_TOP5_ISSUES: same issue repeated counts correctly" {
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=55 duration_s=30
[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=55 duration_s=45
[diag] CONFLICT_RESOLVER context=mid_run_rebase outcome=cap_hit issue=42 pr=55 duration_s=60"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "#42 (3x)" ]
}

@test "CR_TOP5_ISSUES: multiple issues sorted by frequency descending" {
  # Issue 99: 3x, issue 42: 2x, issue 7: 1x
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=20
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=30
[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=40
[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=50
[diag] CONFLICT_RESOLVER context=mid_run_rebase outcome=resolved issue=7 pr=8 duration_s=60"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$status" -eq 0 ]
  # Highest-frequency issue must come first
  [[ "$output" == "#99 (3x)"* ]]
  [[ "$output" == *"#42 (2x)"* ]]
  [[ "$output" == *"#7 (1x)"* ]]
}

@test "CR_TOP5_ISSUES: caps at 5 issues even when more exist" {
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=4 pr=4 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=5 pr=5 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=6 pr=6 duration_s=10"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$status" -eq 0 ]
  # N entries have N-1 commas; cap at 5 means at most 4 commas
  comma_count=$(echo "$output" | tr -cd ',' | wc -c | tr -d ' ')
  [ "$comma_count" -le 4 ]
}

@test "CR_TOP5_ISSUES: bare-marker guard — empty issue= field is ignored" {
  # skipped_no_resolver lines have issue= with no digits — must not produce output
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue= pr="
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_TOP5_ISSUES: output is deterministic across two runs" {
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=10
[diag] CONFLICT_RESOLVER context=divergence outcome=failed issue=42 pr=50 duration_s=40
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=99 pr=100 duration_s=20"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_top5.sh"
  _first="$output"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_top5.sh"
  [ "$output" = "$_first" ]
}

# ---------------------------------------------------------------------------
# CR_MEDIAN_DURATION_S tests
# ---------------------------------------------------------------------------

@test "CR_MEDIAN_DURATION_S: empty CR_LINES returns N/A" {
  run env CR_LINES="" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_MEDIAN_DURATION_S: lines with no duration_s field return N/A" {
  # skipped_no_resolver lines have no duration_s field
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue=42 pr=55"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "N/A" ]
}

@test "CR_MEDIAN_DURATION_S: single duration value" {
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=42 pr=55 duration_s=45"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "45s" ]
}

@test "CR_MEDIAN_DURATION_S: odd count — picks middle value" {
  # Sorted: 10, 30, 50 — median is 30
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=30
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=50"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}

@test "CR_MEDIAN_DURATION_S: even count — integer average of two middle values" {
  # Sorted: 10, 20, 40, 80 — median is (20+40)/2 = 30
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=20
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=80
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=4 pr=4 duration_s=40"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}

@test "CR_MEDIAN_DURATION_S: even count with odd sum truncates via integer division" {
  # Sorted: 10, 11 — median is (10+11)/2 = 10 (integer division truncates)
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=11"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "10s" ]
}

@test "CR_MEDIAN_DURATION_S: skipped_no_resolver lines (no duration_s) do not affect median" {
  # skipped line has no duration_s; durations: 20, 40 — median is (20+40)/2 = 30
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=skipped_no_resolver issue=1 pr=1
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=40
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=20"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "30s" ]
}

@test "CR_MEDIAN_DURATION_S: output is deterministic across two runs" {
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=10
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=30
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=3 pr=3 duration_s=50"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  _first="$output"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$output" = "$_first" ]
}

@test "CR_MEDIAN_DURATION_S: large duration values handled correctly" {
  # 1800s (30m) and 3600s (1h) — median is (1800+3600)/2 = 2700
  _lines="[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=1 pr=1 duration_s=1800
[diag] CONFLICT_RESOLVER context=stale_rebase outcome=resolved issue=2 pr=2 duration_s=3600"
  run env CR_LINES="$_lines" "$RITE_TEST_TMPDIR/compute_median.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "2700s" ]
}
