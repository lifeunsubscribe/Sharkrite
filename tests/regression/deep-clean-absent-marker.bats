#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh
# Regression test: absent last_deep_clean marker must NOT fire days-based trigger
#
# Bug (issue #787): When the <!-- last_deep_clean=... --> marker is missing,
# the sed|head pipeline exits 0 with empty output, so the "|| echo 1970-01-01"
# fallback never fires.  LAST_DEEP_CLEAN is empty; `date -d ""` fails and
# `|| echo 0` returns epoch 0, giving ~20632 days — spuriously triggering
# a deep clean + alarming warning on the first run per repo.
#
# Fix: explicit empty-string check after extraction.  Absent marker → initialize
# to today (DAYS_SINCE_CLEAN=0), write marker to scratchpad, skip days trigger.
# A genuine stale date still triggers normally.
#
# Tests:
#   1. Absent marker → SHOULD_DEEP_CLEAN=false, DAYS_SINCE_CLEAN=0
#   2. Absent marker → scratchpad is updated with today's date marker
#   3. Present but stale marker (>14 days) → days trigger fires
#   4. Present and fresh marker (<14 days) → days trigger does NOT fire
#   5. Size-based trigger still fires regardless of marker presence

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}/deep-clean-absent-marker"
  mkdir -p "$TEST_TMPDIR"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Helper: inline reproduction of the fixed absent-marker detection block
# from merge-pr.sh lines 1180-1222.  Extracts just the date/days logic so
# tests don't need to source the whole merge-pr.sh (which has heavy deps).
# ---------------------------------------------------------------------------
_run_marker_logic() {
  local scratchpad="$1"
  local size_override="${2:-}"  # optional: override wc -c result for size trigger tests
  bash -c "
    set -euo pipefail
    SCRATCHPAD_FILE='$scratchpad'

    SCRATCHPAD_SIZE=\$(wc -c < \"\$SCRATCHPAD_FILE\" 2>/dev/null || echo '0')
    ${size_override:+SCRATCHPAD_SIZE=$size_override}

    LAST_DEEP_CLEAN=\$(sed -n 's/.*<!-- last_deep_clean=\([0-9-]\+\).*/\1/p' \"\$SCRATCHPAD_FILE\" 2>/dev/null | head -1 || true)

    SHOULD_DEEP_CLEAN=false
    DEEP_CLEAN_REASON=''
    RECENT_COMMITS=5   # pretend active development so days trigger can fire

    if [ -z \"\${LAST_DEEP_CLEAN:-}\" ]; then
      INIT_TODAY=\$(date +%Y-%m-%d)
      INIT_TEMP=\$(mktemp)
      echo \"<!-- last_deep_clean=\${INIT_TODAY} -->\" > \"\$INIT_TEMP\"
      cat \"\$SCRATCHPAD_FILE\" >> \"\$INIT_TEMP\"
      mv \"\$INIT_TEMP\" \"\$SCRATCHPAD_FILE\"
      LAST_DEEP_CLEAN=\"\$INIT_TODAY\"
      DAYS_SINCE_CLEAN=0
    else
      DAYS_SINCE_CLEAN=\$(( ( \$(date +%s) - \$(date -d \"\$LAST_DEEP_CLEAN\" +%s 2>/dev/null || date -j -f \"%Y-%m-%d\" \"\$LAST_DEEP_CLEAN\" +%s 2>/dev/null || echo 0) ) / 86400 ))
    fi

    if [ \"\$SCRATCHPAD_SIZE\" -gt 51200 ]; then
      SHOULD_DEEP_CLEAN=true
      DEEP_CLEAN_REASON=\"size\"
    elif [ \"\$DAYS_SINCE_CLEAN\" -gt 14 ] && [ \"\$RECENT_COMMITS\" -gt 0 ]; then
      SHOULD_DEEP_CLEAN=true
      DEEP_CLEAN_REASON=\"last deep clean was \${DAYS_SINCE_CLEAN} days ago\"
    fi

    echo \"SHOULD_DEEP_CLEAN=\$SHOULD_DEEP_CLEAN\"
    echo \"DAYS_SINCE_CLEAN=\$DAYS_SINCE_CLEAN\"
    echo \"LAST_DEEP_CLEAN=\$LAST_DEEP_CLEAN\"
    echo \"DEEP_CLEAN_REASON=\$DEEP_CLEAN_REASON\"
  "
}

# ---------------------------------------------------------------------------
# Test 1: absent marker → days trigger does NOT fire, DAYS_SINCE_CLEAN=0
# ---------------------------------------------------------------------------
@test "absent marker: SHOULD_DEEP_CLEAN is false and DAYS_SINCE_CLEAN is 0" {
  local scratch="$TEST_TMPDIR/scratchpad.md"
  cat > "$scratch" <<'EOF'
# Sharkrite Scratchpad

## Current Work
- Branch: feat/foo (issue #1)
EOF

  run _run_marker_logic "$scratch"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "SHOULD_DEEP_CLEAN=false" ]] || {
    echo "Expected SHOULD_DEEP_CLEAN=false, got: $output"
    false
  }
  [[ "$output" =~ "DAYS_SINCE_CLEAN=0" ]] || {
    echo "Expected DAYS_SINCE_CLEAN=0, got: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 2: absent marker → scratchpad is updated with today's marker
# ---------------------------------------------------------------------------
@test "absent marker: scratchpad is updated with today's last_deep_clean marker" {
  local scratch="$TEST_TMPDIR/scratchpad.md"
  cat > "$scratch" <<'EOF'
# Sharkrite Scratchpad

## Current Work
- Branch: feat/foo (issue #1)
EOF

  _run_marker_logic "$scratch" > /dev/null

  local today
  today=$(date +%Y-%m-%d)

  grep -q "<!-- last_deep_clean=${today}" "$scratch" || {
    echo "Expected marker '<!-- last_deep_clean=${today}' not found in scratchpad"
    echo "Scratchpad contents:"
    cat "$scratch"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 3: stale marker (>14 days) → days trigger fires
# ---------------------------------------------------------------------------
@test "stale marker (>14 days ago): SHOULD_DEEP_CLEAN=true" {
  # Use a fixed date far in the past so elapsed time is always >14 days
  local stale_date="2020-01-01"
  local scratch="$TEST_TMPDIR/scratchpad.md"
  cat > "$scratch" <<EOF
<!-- last_deep_clean=${stale_date} -->
# Sharkrite Scratchpad
EOF

  run _run_marker_logic "$scratch"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "SHOULD_DEEP_CLEAN=true" ]] || {
    echo "Expected stale marker to trigger deep clean; output: $output"
    false
  }
  [[ "$output" =~ "days ago" ]] || {
    echo "Expected 'days ago' in DEEP_CLEAN_REASON; output: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 4: fresh marker (<14 days) → days trigger does NOT fire
# ---------------------------------------------------------------------------
@test "fresh marker (<14 days ago): SHOULD_DEEP_CLEAN=false" {
  local fresh_date
  fresh_date=$(date +%Y-%m-%d)  # today → 0 days → not stale
  local scratch="$TEST_TMPDIR/scratchpad.md"
  cat > "$scratch" <<EOF
<!-- last_deep_clean=${fresh_date} -->
# Sharkrite Scratchpad
EOF

  run _run_marker_logic "$scratch"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "SHOULD_DEEP_CLEAN=false" ]] || {
    echo "Expected fresh marker to NOT trigger deep clean; output: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 5: size-based trigger fires even when marker is absent
# ---------------------------------------------------------------------------
@test "absent marker + large scratchpad (>50KB): size trigger still fires" {
  local scratch="$TEST_TMPDIR/scratchpad.md"
  # Minimal content — override size to simulate >50KB
  echo "# Sharkrite Scratchpad" > "$scratch"

  run _run_marker_logic "$scratch" "52000"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "SHOULD_DEEP_CLEAN=true" ]] || {
    echo "Expected size trigger to fire even with absent marker; output: $output"
    false
  }
  [[ "$output" =~ "DEEP_CLEAN_REASON=size" ]] || {
    echo "Expected DEEP_CLEAN_REASON=size; output: $output"
    false
  }
}

# ---------------------------------------------------------------------------
# Test 6: absent marker does NOT produce the epoch-age warning (the original
# bug: "20632 days ago" in DEEP_CLEAN_REASON)
# ---------------------------------------------------------------------------
@test "absent marker: no bogus epoch-age (e.g. '20000 days ago') in output" {
  local scratch="$TEST_TMPDIR/scratchpad.md"
  echo "# Sharkrite Scratchpad" > "$scratch"

  run _run_marker_logic "$scratch"

  [ "$status" -eq 0 ]
  # If epoch-age logic fires, DAYS_SINCE_CLEAN will be > 10000
  if [[ "$output" =~ DAYS_SINCE_CLEAN=([0-9]+) ]]; then
    local days="${BASH_REMATCH[1]}"
    [ "$days" -lt 100 ] || {
      echo "Bogus epoch-age detected: DAYS_SINCE_CLEAN=${days} (expected 0)"
      echo "Full output: $output"
      false
    }
  fi
}
