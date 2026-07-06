# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 30: bats setup()/setup_file() sources a lib file without restoring bats' shell flags
#
# Every lib file (directly or transitively via config.sh/logging.sh) runs
# `set -euo pipefail` at source time, and `source` executes in the CALLER's
# shell — so a setup() that sources a lib file leaks -u and pipefail into the
# bats-exec-test shell for the whole test. bats' native test-time flags are
# ehBET (errexit ON, nounset off, pipefail off). With BATS_TEST_TIMEOUT set
# (exported by test-gate.sh), the leaked flags make bats' timeout-countdown
# cleanup (bats-exec-test:263 `kill` without || true) abort bats-exec-test
# before the 'not ok' line is emitted: a FAILING test is swallowed to
# "not run" and the gate sees exit 1 with zero findings (2026-07-01 incident).
#
# Required guard after the last lib source in the function body:
#   set +u; set +o pipefail  # bats needs its own error handling ...
#
# Do NOT use `set +e` — bats' failure detection relies on errexit; with it
# disabled a failing test reports 'ok' (verified live, worse than the swallow).
#
# Heredoc-aware: source lines inside fixture heredocs are content, not setup
# code. Sources via tests/helpers (load_lib) are out of scope — flag only
# direct lib sources (paths through lib/ or $RITE_LIB_DIR).
#
# Suppression: place on the line immediately before the flagged source line:
#   # sharkrite-lint disable BATS_SETUP_STRICT_LEAK - Reason: <text>
echo "Checking for bats setup() sourcing lib files without a strict-mode guard..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r30_file_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; in_setup = 0; pend = 0; pline = 0 }
    {
      if (in_heredoc) {
        _close = $0; sub(/^[[:space:]]*/, "", _close)
        if (_close == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      # Heredoc-start detection runs for EVERY non-comment line (not just inside
      # setup bodies): a fixture heredoc containing literal setup() + source
      # lines must not fool the state machine.
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      if (!in_setup) {
        if ($0 ~ /^(setup|setup_file|setup_suite)[[:space:]]*\(\)/) { in_setup = 1; pend = 0 }
        else next
      }
      if ($0 ~ /^}[[:space:]]*$/) {
        if (pend) print pline
        in_setup = 0; pend = 0
        next
      }
      # guard seen: set +u / set +o nounset clears any pending source.
      # Deliberately EXCLUDES any form containing +e (set +eu, set +e):
      # disabling errexit in setup() breaks bats failure detection itself
      # (a failing test reports ok) — a strictly worse swallow than the one
      # this rule prevents. Verified empirically 2026-07-02.
      if ($0 ~ /set[[:space:]]+\+[a-df-z]*u[a-df-z]*([[:space:];]|$)/ || $0 ~ /set[[:space:]]+\+o[[:space:]]+nounset/) { pend = 0 }
      if ($0 ~ /(^|[^A-Za-z0-9_.])(source|\.)[ \t]+/ &&
          $0 ~ /(lib|LIB_DIR[}"'"'"']*)\/(core|utils|providers|hooks)\/|config\.sh/) {
        pend = 1; pline = FNR
      }
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r30_file_hits" ] && continue
  while IFS= read -r _hit_line; do
    [ -z "$_hit_line" ] && continue
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BATS_SETUP_STRICT_LEAK'; then
      continue
    fi
    print_violation "$bats_file" "$_hit_line" "BATS_SETUP_STRICT_LEAK" \
      "setup() sources a lib file, leaking set -u/pipefail into the bats test shell — with BATS_TEST_TIMEOUT this swallows failing tests to 'not run'; add \`set +u; set +o pipefail\` after the source (keep -e: bats' failure detection needs it)"
  done <<< "$_r30_file_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

