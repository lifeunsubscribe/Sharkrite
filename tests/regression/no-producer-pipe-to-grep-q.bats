#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/*.sh
# Regression test for: Use here-strings for grep -q tests in lib/core (#1639)
#
# Bug class: Under set -o pipefail, grep -q exits on the first match without
# consuming all stdin. The still-writing producer receives SIGPIPE and exits
# non-zero; pipefail propagates that exit, so a successful match becomes
# exit 141 — read as "no match". The fix is to use here-strings (<<< "$VAR")
# which have no producer process and therefore cannot receive SIGPIPE.
#
# Root cause confirmed in PR #1634 (tools/ sweep). This test pins the lib/core
# sweep: zero producer-variable pipe into grep -q must remain after each merge.
#
# Verification command (from acceptance criteria):
#   grep -rnE "(printf '%s\\n' \"\$...\"|echo \"\$...\") | grep -q" lib/core \
#     | grep -vE '^\S+:\s*#' | wc -l  # expect 0

@test "no producer-variable pipe into grep -q remains in lib/core" {
  local _repo_root
  _repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  # Count echo/printf "$VAR" | grep -q patterns in lib/core (non-comment lines only)
  local _count
  _count=$(grep -rnE \
    "(printf '%s\\\\n' \"\\\$\{?[A-Za-z0-9_]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -q" \
    "${_repo_root}/lib/core" \
    | grep -vE '^[^[:space:]]+:[[:space:]]*#' \
    | wc -l \
    || true)
  _count="${_count//[[:space:]]/}"

  if [ "$_count" -ne 0 ]; then
    echo "Found $_count producer-variable pipe into grep -q in lib/core (expected 0):" >&2
    grep -rnE \
      "(printf '%s\\\\n' \"\\\$\{?[A-Za-z0-9_]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -q" \
      "${_repo_root}/lib/core" \
      | grep -vE '^[^[:space:]]+:[[:space:]]*#' >&2 || true
  fi

  [ "$_count" -eq 0 ]
}
