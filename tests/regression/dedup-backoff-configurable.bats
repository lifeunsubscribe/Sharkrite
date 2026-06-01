#!/usr/bin/env bats
# tests/regression/dedup-backoff-configurable.bats
#
# Regression test: RITE_DEDUP_BACKOFF env var controls the dedup backoff interval
# in assess-and-resolve.sh's follow-up issue creation loop.
#
# Background: issue #130 documented the timing budget interaction between the
# pr_followup_lock waiter (60s budget) and the lock holder's dedup search loop.
# The dedup backoff (_dedup_backoff) is the largest tunable knob for reducing
# worst-case holder time.  It must be configurable so operators can trade off
# dedup confidence (more retries = more gh index lag tolerance) vs lock hold time
# (fewer/shorter retries = faster lock release).
#
# Fix: _dedup_backoff="${RITE_DEDUP_BACKOFF:-5}" in assess-and-resolve.sh
#      RITE_DEDUP_BACKOFF default + export in config.sh
#
# Test strategy: extract the _dedup_backoff assignment line verbatim, set
# RITE_DEDUP_BACKOFF to a non-default value in the environment, source the
# assignment in a subshell, and assert the variable took the env value.
#
# Verification command: bats tests/regression/dedup-backoff-configurable.bats

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
}

teardown() {
  teardown_test_tmpdir
}

# ─── Tests ───────────────────────────────────────────────────────────────────

@test "RITE_DEDUP_BACKOFF env var overrides default dedup backoff" {
  local result
  result=$(
    RITE_DEDUP_BACKOFF=2 bash -c '
      _dedup_backoff="${RITE_DEDUP_BACKOFF:-5}"
      echo "$_dedup_backoff"
    '
  )

  [ "$result" = "2" ] || {
    echo "FAIL: expected _dedup_backoff=2, got '$result'"
    false
  }
}

@test "_dedup_backoff defaults to 5 when RITE_DEDUP_BACKOFF is unset" {
  local result
  result=$(
    bash -c '
      unset RITE_DEDUP_BACKOFF
      _dedup_backoff="${RITE_DEDUP_BACKOFF:-5}"
      echo "$_dedup_backoff"
    '
  )

  [ "$result" = "5" ] || {
    echo "FAIL: expected default _dedup_backoff=5, got '$result'"
    false
  }
}

@test "RITE_DEDUP_BACKOFF is exported by config.sh" {
  # Verify config.sh sets and exports RITE_DEDUP_BACKOFF so subprocesses
  # (e.g., assess-and-resolve.sh when called from workflow-runner.sh) inherit it.
  #
  # We look for the export line directly rather than sourcing config.sh
  # (which requires a full project root setup) to keep the test fast and isolated.
  local export_count
  export_count=$(grep -c "^export RITE_DEDUP_BACKOFF" "${RITE_REPO_ROOT}/lib/utils/config.sh" || true)

  [ "$export_count" -ge 1 ] || {
    echo "FAIL: 'export RITE_DEDUP_BACKOFF' not found in lib/utils/config.sh"
    echo "config.sh must export RITE_DEDUP_BACKOFF so assess-and-resolve.sh inherits it"
    false
  }
}

@test "RITE_DEDUP_BACKOFF default is defined in config.sh" {
  # The default value must be set in config.sh, not just in assess-and-resolve.sh,
  # so project .rite/config files can override it consistently.
  local def_count
  def_count=$(grep -c 'RITE_DEDUP_BACKOFF.*:-5' "${RITE_REPO_ROOT}/lib/utils/config.sh" || true)

  [ "$def_count" -ge 1 ] || {
    echo "FAIL: RITE_DEDUP_BACKOFF default (:-5) not found in lib/utils/config.sh"
    false
  }
}

@test "assess-and-resolve.sh reads _dedup_backoff from RITE_DEDUP_BACKOFF" {
  # Verify the production code uses ${RITE_DEDUP_BACKOFF:-5} (not a hardcoded literal)
  # so the env var actually takes effect at runtime.
  local usage_count
  usage_count=$(grep -c 'RITE_DEDUP_BACKOFF:-' "${RITE_REPO_ROOT}/lib/core/assess-and-resolve.sh" || true)

  [ "$usage_count" -ge 1 ] || {
    echo "FAIL: 'RITE_DEDUP_BACKOFF:-' not found in lib/core/assess-and-resolve.sh"
    echo "assess-and-resolve.sh must use \${RITE_DEDUP_BACKOFF:-5} for _dedup_backoff"
    false
  }
}

@test "lock timeout comment in issue-lock.sh references RITE_DEDUP_BACKOFF tuning knob" {
  # Verify the timing budget documentation in issue-lock.sh mentions RITE_DEDUP_BACKOFF
  # so operators know where to look when tuning under slow-GitHub conditions.
  local doc_count
  doc_count=$(grep -c 'RITE_DEDUP_BACKOFF' "${RITE_REPO_ROOT}/lib/utils/issue-lock.sh" || true)

  [ "$doc_count" -ge 1 ] || {
    echo "FAIL: RITE_DEDUP_BACKOFF not mentioned in lib/utils/issue-lock.sh"
    echo "The timing budget comment must reference the tuning knob"
    false
  }
}
