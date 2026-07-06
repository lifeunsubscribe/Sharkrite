# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 29: trap ... EXIT inside a @test body in a .bats file
#
# bats-core emits each test's result ('ok'/'not ok') from its OWN EXIT trap in
# bats-exec-test. A `trap ... EXIT` (or `trap - EXIT`) inside a @test body
# CLOBBERS that trap: the test's result is never written to the TAP stream,
# bats reports "Executed N instead of expected M tests", and the report.tap
# has no 'not ok' line for the gate to count — the failure is invisible
# (test_count=0 despite exit 1; four blind fix rounds in the 2026-07-01
# not-run incident, tests/regression/batch-locked-issue-in-progress-status.bats:506).
# Cleanup belongs in teardown() — bats runs it for every test, pass or fail.
#
# Heredoc-aware (mirrors Rules 27/28's state tracking): trap lines inside
# heredoc fixture scripts written BY a test are content, not test-shell code.
#
# Suppression: place on the line immediately before the flagged code:
#   # sharkrite-lint disable TRAP_EXIT_IN_BATS_TEST - Reason: <text>
echo "Checking for trap ... EXIT inside @test bodies in .bats files..."

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    */tests/fixtures/*|tests/fixtures/*) continue ;;
  esac
  _r29_file_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; in_test = 0 }
    {
      if (in_heredoc) {
        _close = $0; sub(/^[[:space:]]*/, "", _close)
        if (_close == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      # Heredoc-start detection runs for EVERY non-comment line (not just inside
      # @test bodies): a fixture heredoc at setup/file scope containing literal
      # @test + trap lines must not fool the state machine.
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      if (!in_test) {
        if ($0 ~ /^[[:space:]]*@test[[:space:]]/) {
          # one-liner @test "..." { ...; } never re-opens on the next line
          if ($0 ~ /\{/ && $0 ~ /\}[[:space:]]*$/) next
          in_test = 1
        }
        next
      }
      if ($0 ~ /^}[[:space:]]*$/) { in_test = 0; next }
      if ($0 ~ /^[[:space:]]*trap[[:space:]]/ && $0 ~ /(^|[^A-Za-z_])EXIT([^A-Za-z_]|$)/) print FNR
    }
  ' "$bats_file" </dev/null 2>/dev/null || true)
  [ -z "$_r29_file_hits" ] && continue
  while IFS= read -r _hit_line; do
    [ -z "$_hit_line" ] && continue
    _prev_line=$(sed -n "$((_hit_line - 1))p" "$bats_file" 2>/dev/null || true)
    if echo "$_prev_line" | grep -qE '#.*sharkrite-lint.*disable.*TRAP_EXIT_IN_BATS_TEST'; then
      continue
    fi
    print_violation "$bats_file" "$_hit_line" "TRAP_EXIT_IN_BATS_TEST" \
      "trap ... EXIT inside a @test body clobbers bats' result-emitting EXIT trap — the test's result is silently dropped ('Executed N instead of expected M'); move cleanup into teardown()"
  done <<< "$_r29_file_hits"
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)

