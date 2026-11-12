#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/*.sh, lib/utils/*.sh, lib/providers/*.sh, bin/rite, bin/rite-full-suite
# Regression test for: Use here-strings for grep -q tests in lib/ and bin/ (#1639, #1640)
#
# Bug class: Under set -o pipefail, grep -q exits on the first match without
# consuming all stdin. The still-writing producer receives SIGPIPE and exits
# non-zero; pipefail propagates that exit, so a successful match becomes
# exit 141 — read as "no match". The fix is to use here-strings (<<< "$VAR")
# which have no producer process and therefore cannot receive SIGPIPE.
#
# Root cause confirmed in PR #1634 (tools/ sweep). This test pins the full
# sweep: zero producer-variable pipe into grep -q must remain in lib/ and bin/
# after each merge.
#
# Verification command (from acceptance criteria):
#   grep -rnE "(printf '%s\\n' \"\$...\"|echo \"\$...\") | grep -q" lib bin \
#     | grep -vE '^\S+:\s*#' | wc -l  # expect 0

@test "no producer-variable pipe into grep -q remains in lib/core" {
  local _repo_root
  _repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  # Count echo/printf "$VAR" | grep -q patterns in lib/core (non-comment lines only)
  local _count
  _count=$(grep -rnE \
    "(printf '%s(\\\\n)?' \"\\\$\{?[A-Za-z0-9_:-]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -[[:alpha:]]*q" \
    "${_repo_root}/lib/core" \
    | grep -vE '^[^[:space:]]+:[[:space:]]*#' \
    | wc -l \
    || true)
  _count="${_count//[[:space:]]/}"

  if [ "$_count" -ne 0 ]; then
    echo "Found $_count producer-variable pipe into grep -q in lib/core (expected 0):" >&2
    grep -rnE \
      "(printf '%s(\\\\n)?' \"\\\$\{?[A-Za-z0-9_:-]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -[[:alpha:]]*q" \
      "${_repo_root}/lib/core" \
      | grep -vE '^[^[:space:]]+:[[:space:]]*#' >&2 || true
  fi

  [ "$_count" -eq 0 ]
}

@test "no producer-variable pipe into grep -q remains in lib/utils, lib/providers, bin" {
  local _repo_root
  _repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  # Count echo/printf "$VAR" | grep -q patterns in lib/ and bin/ outside lib/core
  # (lib/core was swept in #1639; lib/utils, lib/providers, bin were swept in #1640)
  local _count
  _count=$(grep -rnE \
    "(printf '%s(\\\\n)?' \"\\\$\{?[A-Za-z0-9_:-]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -[[:alpha:]]*q" \
    "${_repo_root}/lib/utils" \
    "${_repo_root}/lib/providers" \
    "${_repo_root}/bin" \
    | grep -vE '^[^[:space:]]+:[[:space:]]*#' \
    | wc -l \
    || true)
  _count="${_count//[[:space:]]/}"

  if [ "$_count" -ne 0 ]; then
    echo "Found $_count producer-variable pipe into grep -q in lib/utils, lib/providers, bin (expected 0):" >&2
    grep -rnE \
      "(printf '%s(\\\\n)?' \"\\\$\{?[A-Za-z0-9_:-]+\}?\"|echo \"\\\$\{?[A-Za-z0-9_:-]+\}?\") \| grep -[[:alpha:]]*q" \
      "${_repo_root}/lib/utils" \
      "${_repo_root}/lib/providers" \
      "${_repo_root}/bin" \
      | grep -vE '^[^[:space:]]+:[[:space:]]*#' >&2 || true
  fi

  [ "$_count" -eq 0 ]
}
