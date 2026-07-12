#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/test-gate.sh
# Regression for #944: an empty re-selection must never overwrite a failing
# verdict. The fix-loop re-gate deliberately narrows its diff base to the fix
# commit, so a fix touching only uncovered paths computed an EMPTY selection
# and reported outcome=passed having verified NOTHING (live escape: PR #931 —
# selected=15/failed then selected=0/passed → 855 merged red → repaired #943).
# Mechanism under test: the gate persists failing FILES per PR at outcome time
# and UNIONS them into the next run's selection; a passing outcome clears the
# state so genuine zero-selection runs (docs-only diffs) stay skipped.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  GATE="${RITE_REPO_ROOT}/lib/utils/test-gate.sh"
  STATE_DIR="${BATS_TEST_TMPDIR}/state"
  mkdir -p "$STATE_DIR" "${BATS_TEST_TMPDIR}/proj/tests"
}

@test "behavioral: prior-failure list unions into an empty selection (snippet of the injection block)" {
  # Replicates the injection logic against a state file + empty selection.
  run bash -c '
    set -euo pipefail
    project_root="'"${BATS_TEST_TMPDIR}"'/proj"
    printf "#!/usr/bin/env bats\n" > "$project_root/tests/prev-fail.bats"
    state="'"$STATE_DIR"'/gate-prior-failing-pr7.list"
    printf "tests/prev-fail.bats\n" > "$state"
    _selection=""
    if [ -s "$state" ]; then
      while IFS= read -r _pf; do
        [ -z "$_pf" ] && continue
        [ -f "$project_root/$_pf" ] || continue
        printf "%s\n" "$_selection" | grep -qxF "$_pf" || _selection="${_selection:+$_selection
}$_pf"
      done < "$state"
    fi
    echo "SEL=[$_selection]"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"SEL=[tests/prev-fail.bats]"* ]]
}

@test "behavioral: deleted previously-failing file is not injected (no ghost selection)" {
  run bash -c '
    set -euo pipefail
    project_root="'"${BATS_TEST_TMPDIR}"'/proj"
    state="'"$STATE_DIR"'/gate-prior-failing-pr8.list"
    printf "tests/deleted-file.bats\n" > "$state"
    _selection=""
    if [ -s "$state" ]; then
      while IFS= read -r _pf; do
        [ -z "$_pf" ] && continue
        [ -f "$project_root/$_pf" ] || continue
        _selection="$_pf"
      done < "$state"
    fi
    echo "SEL=[$_selection]"
  '
  [[ "$output" == *"SEL=[]"* ]]
}

@test "source: selection block unions prior failures before the empty-selection branch" {
  run grep -n "Re-verifying .* previously-failing file(s) from the last gate round" "$GATE"
  [ "$status" -eq 0 ]
  run grep -n "reselected_prior=true" "$GATE"
  [ "$status" -eq 0 ]
  # Injection must occur BEFORE the empty-selection skip decides anything:
  inj=$(grep -n "gate-prior-failing-pr" "$GATE" | head -1 | cut -d: -f1)
  skip=$(grep -n "no covered tests for changed paths, skipping bats" "$GATE" | cut -d: -f1)
  [ "$inj" -lt "$skip" ]
}

@test "source: outcome hook persists failing files and clears on pass" {
  run grep -n 'if \[ "\$_outcome" = "passed" \]' "$GATE"
  [ "$status" -eq 0 ]
  grep -A1 'if \[ "\$_outcome" = "passed" \]' "$GATE" | grep -qF 'rm -f "$_vp_state_file"'
  # Synthetics never persist (a swallow is not a re-runnable failure):
  run grep -cF "grep -v '^\\[tests_not_run\\]'" "$GATE"
  [ "$output" -ge 2 ]   # flake-retry (#945) + verdict persistence (#944) both exclude synthetics
}

# --- #983: gather-failure fallback (persist full selection when names unmap) ---

@test "behavioral: gather-failure TAP persists full selection (not empty state)" {
  # Runs the REAL persist hook — sed-extracted from $GATE and eval'd in
  # function scope (the block uses `local`) — against a gather-failure TAP
  # ("not ok 1 bats-gather-tests", a name grep -lF never maps to a file) and
  # a 2-file selection. Before #983 the fallback was absent: _vp_out stayed
  # empty, nothing persisted, and the next round re-selected 0 files →
  # vacuous pass → live escapes #964/#965/#977. Also asserts the passed
  # outcome clears the state file (same hook, second invocation).
  _driver="$BATS_TEST_TMPDIR/persist-hook-driver.sh"
  cat > "$_driver" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -euo pipefail
GATE="$1"; project_root="$2"; RITE_STATE_DIR="$3"

mkdir -p "$project_root/tests" "$RITE_STATE_DIR"
# Two bats files in the selection (content is irrelevant for the gather case)
printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > "$project_root/tests/alpha.bats"
printf '#!/usr/bin/env bats\n@test "y" { true; }\n' > "$project_root/tests/beta.bats"

# TAP output for a gather failure: only the synthetic gather-tests line
_tests_raw_file=$(mktemp)
printf '1..1\nnot ok 1 bats-gather-tests\n' > "$_tests_raw_file"

PR_NUMBER=983
_outcome="failed"
_selection="tests/alpha.bats
tests/beta.bats"

# Extract the persist hook verbatim: from the state-file assignment to the
# first 2-space fi (the outer if/elif close). Anchor drift fails loudly here.
_hook_src=$(sed -n '/local _vp_state_file=/,/^  fi$/p' "$GATE")
[ -n "$_hook_src" ] || { echo "FAIL: could not extract persist hook from $GATE" >&2; exit 1; }
_persist_hook() { eval "$_hook_src"; }

_persist_hook
_state="$RITE_STATE_DIR/gate-prior-failing-pr${PR_NUMBER}.list"
grep -qxF "tests/alpha.bats" "$_state" && echo "alpha:found"
grep -qxF "tests/beta.bats"  "$_state" && echo "beta:found"

# Passing outcome clears the state file (behavioral half of source test above)
_outcome="passed"
_persist_hook
[ ! -f "$_state" ] && echo "cleared:ok"
DRIVER_EOF
  run bash "$_driver" "$GATE" "$BATS_TEST_TMPDIR/proj" "$STATE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha:found"* ]]
  [[ "$output" == *"beta:found"* ]]
  [[ "$output" == *"cleared:ok"* ]]
}

@test "source: gather-failure fallback (full-selection persist) exists in persist hook" {
  # #983: when _vp_out is empty after name→file mapping, we fall back to the full
  # selection.  Assert both the guard and the fallback assignment are present.
  run grep -cF 'if [ -z "$_vp_out" ]' "$GATE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # Fallback assigns _selection into _vp_out
  run grep -cF '_vp_out=$(printf' "$GATE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
