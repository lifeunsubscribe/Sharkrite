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
