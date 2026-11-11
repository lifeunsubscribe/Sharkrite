#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/*.sh

# Structural sweep: no single-variable producer pipe into grep -q in lib/core/.
#
# Under set -o pipefail, grep -q exiting on an early match sends SIGPIPE to a
# producer that is still writing; the pipeline returns 141, which reads as "no
# match" — a false negative. Here-strings avoid the SIGPIPE entirely.
# Root cause: #1633. This issue: #1639.

@test "no echo/printf variable pipe into grep -q in lib/core/" {
  local count
  count=$(grep -rnE \
    "(printf '%s\n' \"\\\$\{?[A-Za-z_]+\}?\"|echo \"\\\$\{?[A-Za-z_:-]+\}?\") \| grep -q" \
    "${BATS_TEST_DIRNAME}/../../lib/core" \
    | grep -vE '^[^[:space:]]+:[[:space:]]*#' \
    | wc -l \
    || true)
  [ "$count" -eq 0 ]
}
