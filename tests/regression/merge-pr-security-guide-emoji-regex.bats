#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/merge-pr.sh::update_security_guide_from_pr
#
# Regression test for the emoji-intolerant findings-detection regex in
# update_security_guide_from_pr() (issue #1346 / PR #1345 follow-up).
#
# Root cause: the original grep used adjacent bare-pipe-separated fields:
#   grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+"
# Production reviews emit emoji between fields:
#   "Findings: 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | 🟡 MEDIUM: 1 | 🟢 LOW: 0"
# The old pattern required adjacent fields with no room for any emoji prefix,
# so the security-guide auto-update was silently dead for every emoji-annotated
# review.
#
# Fix: use .* between anchored field patterns (same as parse_review_severity_counts
# Tier 2 in lib/utils/format-review.sh).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PROJECT_ROOT
}

# ---------------------------------------------------------------------------
# The canonical emoji-tolerant pattern lives in parse_review_severity_counts
# (lib/utils/format-review.sh); update_security_guide_from_pr delegates to it.
# These tests assert the regex itself is correct — no stubs or sources needed.
# ---------------------------------------------------------------------------

@test "emoji-prefixed findings line matches the emoji-tolerant detection pattern" {
  local findings_with_emoji="Findings: 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | 🟡 MEDIUM: 1 | 🟢 LOW: 0"
  local pattern="CRITICAL: *[0-9]+.*HIGH: *[0-9]+.*MEDIUM: *[0-9]+"
  echo "$findings_with_emoji" | grep -qE "$pattern"
}

@test "plain findings line (no emoji) matches the emoji-tolerant detection pattern" {
  local findings_plain="Findings: CRITICAL: 1 | HIGH: 0 | MEDIUM: 0 | LOW: 0"
  local pattern="CRITICAL: *[0-9]+.*HIGH: *[0-9]+.*MEDIUM: *[0-9]+"
  echo "$findings_plain" | grep -qE "$pattern"
}

@test "emoji-prefixed findings line does NOT match the old adjacent-fields pattern" {
  local findings_with_emoji="Findings: 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | 🟡 MEDIUM: 1 | 🟢 LOW: 0"
  local old_pattern="Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+"
  # This must NOT match — the old pattern is the bug we fixed.
  run bash -c "echo '$findings_with_emoji' | grep -qE '$old_pattern'"
  [ "$status" -ne 0 ]
}

@test "emoji-tolerant individual extraction returns correct HIGH count from emoji line" {
  local findings_with_emoji="Findings: 🔴 CRITICAL: 0 | 🟠 HIGH: 2 | 🟡 MEDIUM: 1 | 🟢 LOW: 0"
  local high_num
  high_num=$(echo "$findings_with_emoji" | grep -oE "HIGH: *[0-9]+" | grep -oE "[0-9]+" || echo "0")
  [ "$high_num" = "2" ]
}

@test "emoji-tolerant individual extraction returns correct CRITICAL count from emoji line" {
  local findings_with_emoji="Findings: 🔴 CRITICAL: 3 | 🟠 HIGH: 1 | 🟡 MEDIUM: 0 | 🟢 LOW: 0"
  local crit_num
  crit_num=$(echo "$findings_with_emoji" | grep -oE "CRITICAL: *[0-9]+" | grep -oE "[0-9]+" || echo "0")
  [ "$crit_num" = "3" ]
}

@test "update_security_guide_from_pr uses emoji-tolerant grep pattern (structural pin)" {
  local src="$PROJECT_ROOT/lib/core/merge-pr.sh"
  # The old adjacent-fields pattern must not be present in the function.
  # grep -c returns 0 when no lines match, which is what we want.
  local bad_count
  bad_count=$(grep -c 'grep -oE "Findings: CRITICAL:' "$src" || true)
  [ "$bad_count" -eq 0 ]
}

@test "update_security_guide_from_pr delegates to parse_review_severity_counts (structural pin)" {
  local src="$PROJECT_ROOT/lib/core/merge-pr.sh"
  # The shared helper must be called — inline copy was the drift risk.
  local call_count
  call_count=$(grep -c 'parse_review_severity_counts' "$src" || true)
  [ "$call_count" -ge 1 ]
}
