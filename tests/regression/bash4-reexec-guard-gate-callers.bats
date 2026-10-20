#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/workflow-runner.sh, lib/core/claude-workflow.sh, lib/core/promote-branch.sh, lib/core/assess-and-resolve.sh, lib/utils/post-merge-verify.sh, lib/utils/gate-runners.sh
# tests/regression/bash4-reexec-guard-gate-callers.bats
#
# PR #1361 added nested `case` statements inside process substitutions to
# lib/utils/gate-runners.sh. Bash 3.2 — which is what /bin/bash is on macOS —
# cannot parse that construct, so #1361 also added a hard bash-4 refusal at the
# top of the file:
#
#     ERROR: lib/utils/gate-runners.sh requires bash 4+. Install via: brew install bash
#
# The refusal is correct for the library. The problem is who loads it: five
# #!/bin/bash entry points source test-gate.sh (which sources gate-runners.sh),
# and none of them carried a re-exec guard. Under system bash every one of them
# died before doing any work.
#
# Live failure: batch `rite 1221 1277 1273 1143 1169` on 2026-10-20 —
# 5 of 5 issues failed, three of them in under 10 seconds, all with the same
# refusal line. #1277 burned 14m25s before hitting it at the documentation
# phase. The existing bin-bash-32-parse-sweep.bats did not catch this because
# gate-runners.sh DOES carry a BASH_VERSINFO guard in its first 30 lines, which
# is exactly what that sweep accepts — it checks the library, not its callers.
#
# Tests in this file:
#   1-5. each entry point parses under real /bin/bash
#   6-10. each entry point carries an EXECUTION-ONLY re-exec guard
#   11. the guard is execution-only (a sourced file must not exec the caller)
#   12. a guarded script actually lands on bash 4+ when run under /bin/bash
#   13. gate-runners.sh still refuses to load under 3.2 (the library contract)

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Every #!/bin/bash entry point that reaches gate-runners.sh via test-gate.sh.
GATE_CALLERS="lib/core/workflow-runner.sh
lib/core/claude-workflow.sh
lib/core/promote-branch.sh
lib/core/assess-and-resolve.sh
lib/utils/post-merge-verify.sh"

setup() {
  _sysbash=/bin/bash
  [ -x "$_sysbash" ] || skip "no /bin/bash on this host"
}

teardown() {
  [ -n "${_tmpdir:-}" ] && rm -rf "$_tmpdir" || true
}

_is_bash32() {
  "$_sysbash" -c 'exit $(( BASH_VERSINFO[0] >= 4 ))'
}

# =============================================================================
# PARSE: the whole point — these must load under the interpreter that runs them
# =============================================================================

@test "parse: every gate caller parses under real /bin/bash" {
  _failed=""
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    if ! "$_sysbash" -n "$REPO_ROOT/$_f" 2>/dev/null; then
      _failed="$_failed $_f"
    fi
  done <<< "$GATE_CALLERS"

  [ -z "$_failed" ] || {
    echo "FAIL: these do not parse under /bin/bash:$_failed" >&2
    echo "      they carry a #!/bin/bash shebang, so this is the interpreter" >&2
    echo "      that actually runs them" >&2
    return 1
  }
}

# =============================================================================
# GUARD: present, and execution-only
# =============================================================================

@test "guard: every gate caller carries a bash-4 re-exec guard" {
  _missing=""
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    grep -q 'BASH_VERSINFO\[0\]' "$REPO_ROOT/$_f" || _missing="$_missing $_f"
  done <<< "$GATE_CALLERS"

  [ -z "$_missing" ] || {
    echo "FAIL: no bash-4 guard in:$_missing" >&2
    echo "      each sources test-gate.sh -> gate-runners.sh, which refuses" >&2
    echo "      to load under bash 3.2" >&2
    return 1
  }
}

@test "guard: every gate caller's guard is execution-only, not sourced" {
  # exec in a sourced context re-execs the CALLER with the wrong argv.
  # See CLAUDE.md -> "macOS bash 3.2 compatibility".
  _bad=""
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    grep -qF 'BASH_SOURCE[0]}" = "$0"' "$REPO_ROOT/$_f" || _bad="$_bad $_f"
  done <<< "$GATE_CALLERS"

  [ -z "$_bad" ] || {
    echo "FAIL: guard is not execution-gated in:$_bad" >&2
    echo "      add [ \"\${BASH_SOURCE[0]}\" = \"\$0\" ] to the condition" >&2
    return 1
  }
}

@test "guard: re-exec preserves the argument vector" {
  _tmpdir=$(mktemp -d)
  # Reproduce the guard verbatim in a standalone script and confirm both the
  # interpreter swap and that "$@" survives it.
  cat > "$_tmpdir/probe.sh" <<'PROBE'
#!/bin/bash
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "${BASH:-}" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi
echo "major=${BASH_VERSINFO[0]} args=$*"
PROBE
  chmod +x "$_tmpdir/probe.sh"

  run "$_sysbash" "$_tmpdir/probe.sh" 1277 --unsupervised

  if _is_bash32 && [ ! -x /opt/homebrew/bin/bash ] && [ ! -x /usr/local/bin/bash ]; then
    skip "no bash 4+ installed to re-exec into"
  fi

  [ "$status" -eq 0 ] || {
    echo "FAIL: guarded script exited $status: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'args=1277 --unsupervised' || {
    echo "FAIL: argument vector lost across exec: $output" >&2
    return 1
  }
  echo "$output" | grep -qE 'major=[4-9]|major=[0-9]{2}' || {
    echo "FAIL: did not land on bash 4+: $output" >&2
    return 1
  }
}

# =============================================================================
# LIBRARY CONTRACT
# =============================================================================

@test "library: gate-runners.sh still refuses to load under bash 3.2" {
  # The refusal is the correct behavior for the library; this test pins it so
  # nobody "fixes" the symptom by deleting the guard and reintroducing a silent
  # parse failure. The callers are what had to change.
  _is_bash32 || skip "/bin/bash is not 3.2 on this host"

  run "$_sysbash" -c "source '$REPO_ROOT/lib/utils/gate-runners.sh'"

  [ "$status" -ne 0 ] || {
    echo "FAIL: gate-runners.sh loaded under 3.2 — the refusal is gone" >&2
    return 1
  }
  echo "$output" | grep -qi 'requires bash 4' || {
    echo "FAIL: expected the bash-4 refusal, got: $output" >&2
    return 1
  }
}
