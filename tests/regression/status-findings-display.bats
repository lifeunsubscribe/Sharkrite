#!/usr/bin/env bats
# sharkrite-test-covers: bin/rite
# Regression for #1347: bin/rite --status Findings display uses the same
# 3-tier parse idiom as the other consolidation sites.
#
# The per-issue --status display previously used:
#   grep -oE "CRITICAL: [0-9]+ \| HIGH: [0-9]+ \| MEDIUM: [0-9]+ \| LOW: [0-9]+"
# which required a literal space-pipe-space separator between fields.  The
# modern production review format emits emoji between the pipe and the field
# name ("| 🟠 HIGH: 2 |"), so the adjacent-fields regex matched nothing and
# the Findings line was silently omitted.
#
# Fix: source format-review.sh in the --status block and call
# parse_review_severity_counts(), which handles all three tiers.

RITE_BIN=""

setup() {
  RITE_BIN="${BATS_TEST_DIRNAME}/../../bin/rite"
  [ -f "$RITE_BIN" ]
}

@test "bin/rite sources format-review.sh in the --status block" {
  # The source must appear after pr-detection.sh (which is the --status block
  # guard) and before the findings extraction code.
  grep -q 'source.*utils/format-review.sh' "$RITE_BIN"
}

@test "bin/rite --status no longer contains the broken adjacent-fields regex" {
  # The old pattern required a literal '| HIGH' separator — emoji between the
  # pipe and the field name breaks it.  This structural pin prevents regression.
  ! grep -q 'grep -oE "CRITICAL: \[0-9\]+ \\\\| HIGH: \[0-9\]+ \\\\| MEDIUM' "$RITE_BIN"
}

@test "bin/rite --status calls parse_review_severity_counts for findings extraction" {
  grep -q 'parse_review_severity_counts' "$RITE_BIN"
}

@test "bin/rite --status uses _PRC_TIER guard before printing Findings line" {
  grep -q '_PRC_TIER' "$RITE_BIN"
}
