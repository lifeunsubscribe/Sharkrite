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
