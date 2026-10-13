#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh, lib/core/plan-issues.sh
# Regression: every #!/bin/bash file in lib/ bin/ tools/ must either parse clean
# under bash 3.2 (/bin/bash -n exits 0) OR carry the BASH_VERSINFO self-re-exec
# guard in its first 30 lines.
#
# Bug class: bash 3.2's $(…) scanner does not understand heredocs inside command
# substitution — var=$(cat <<EOF ... EOF) corrupts parse state hundreds of lines
# downstream (live: assess-documentation.sh:1382, plan-issues.sh:3080,
# 2026-10-11/12). Rule 21 (BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT) catches enumerated
# builtins but cannot detect this parse-state corruption class; this sweep test
# is the deterministic backstop.
#
# The test is skipped on Linux CI where /bin/bash is bash 4+, since bash 4+
# parses heredoc-in-cmdsubst correctly and the guard is irrelevant there.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_REPO_ROOT
}

# ---------------------------------------------------------------------------
# Sweep: every #!/bin/bash file must parse under 3.2 OR have the guard
# ---------------------------------------------------------------------------

@test "every #!/bin/bash file in lib/ bin/ tools/ passes bash -n or carries BASH_VERSINFO guard" {
  # Skip on non-3.2 /bin/bash (Linux CI, homebrew-as-system, etc.)
  _bash_major=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "0")
  if [ "$_bash_major" -ge 4 ]; then
    skip "/bin/bash is bash ${_bash_major}.x, not 3.2 — parse sweep skipped (not macOS system bash)"
  fi

  _failures=()
  while IFS= read -r _f; do
    # A file that parses cleanly under bash 3.2 needs no guard.
    if /bin/bash -n "$_f" 2>/dev/null; then
      continue
    fi
    # Parse fails under bash 3.2 — must carry the BASH_VERSINFO re-exec guard
    # somewhere in the first 30 lines so it fires before the parser reaches the
    # unparseable construct at runtime.
    if head -30 "$_f" | grep -qE 'BASH_VERSINFO\[0\].*-lt 4'; then
      continue
    fi
    _failures+=("$_f")
  done < <(grep -rl '^#!/bin/bash' \
      "$RITE_REPO_ROOT/lib" \
      "$RITE_REPO_ROOT/bin" \
      "$RITE_REPO_ROOT/tools" \
    2>/dev/null || true)

  if [ ${#_failures[@]} -gt 0 ]; then
    echo "Files that fail /bin/bash -n AND lack BASH_VERSINFO guard in first 30 lines:"
    printf '  %s\n' "${_failures[@]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Spot-check: the two files that triggered this regression have the guard
# ---------------------------------------------------------------------------

@test "assess-documentation.sh carries BASH_VERSINFO guard in first 30 lines" {
  run head -30 "$RITE_REPO_ROOT/lib/core/assess-documentation.sh"
  echo "$output" | grep -qE 'BASH_VERSINFO\[0\].*-lt 4'
}

@test "plan-issues.sh carries BASH_VERSINFO guard in first 30 lines" {
  run head -30 "$RITE_REPO_ROOT/lib/core/plan-issues.sh"
  echo "$output" | grep -qE 'BASH_VERSINFO\[0\].*-lt 4'
}

# ---------------------------------------------------------------------------
# Behavioral: the sourced-context branch must fail loudly, not re-exec.
#
# When bin/rite sources these files it has already consumed the argv, so
# `exec "$newer_bash" "$0" "$@"` would restart the CALLER with no arguments —
# silently doing the wrong thing. The guard must detect BASH_SOURCE != $0 and
# return non-zero with an actionable message instead. Executed directly, the
# same guard must take the re-exec path and run to completion under bash 4+.
# ---------------------------------------------------------------------------

@test "sourced under bash 3.2: guard fails loudly instead of re-execing" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' || skip "/bin/bash is bash 4+ (Linux CI) — guard is inert"

  for _f in lib/core/plan-issues.sh lib/core/assess-documentation.sh; do
    run /bin/bash -c "source '$RITE_REPO_ROOT/$_f'"
    # Must refuse: non-zero status and a message naming bash 4+.
    [ "$status" -ne 0 ] || {
      echo "FAIL: $_f sourced cleanly under bash 3.2 — guard did not fire"
      false
    }
    echo "$output" | grep -qi "bash 4" || {
      echo "FAIL: $_f guard message does not name the bash 4+ requirement: $output"
      false
    }
    # Must NOT have corrupted the parse (the pre-guard symptom was a syntax
    # error at a line hundreds deep, never a clean refusal).
    echo "$output" | grep -qi "syntax error" && {
      echo "FAIL: $_f still hits the 3.2 parse bug before the guard runs: $output"
      false
    }
  done
  true
}

@test "executed under bash 3.2: guard re-execs to bash 4+ and parses" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' || skip "/bin/bash is bash 4+ (Linux CI) — guard is inert"
  _newer=""
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$_c" ] && _newer="$_c" && break
  done
  [ -n "$_newer" ] || skip "no bash 4+ installed to re-exec into"

  # RITE_SOURCE_FUNCTIONS_ONLY stops the body before any side effects; reaching
  # that return at all proves the re-exec happened and the file parsed.
  run /bin/bash -c "RITE_SOURCE_FUNCTIONS_ONLY=1 '$RITE_REPO_ROOT/lib/core/plan-issues.sh' --preview </dev/null"
  echo "$output" | grep -qi "syntax error" && {
    echo "FAIL: direct execution still hit the 3.2 parse bug: $output"
    false
  }
  echo "$output" | grep -qi "requires bash 4" && {
    echo "FAIL: direct execution took the fail-loudly branch instead of re-execing: $output"
    false
  }
  true
}
