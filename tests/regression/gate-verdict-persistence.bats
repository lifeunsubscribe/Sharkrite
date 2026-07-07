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

# --- #985: gather-failure fallback (persist full selection when names unmap) ---

@test "behavioral: gather-failure TAP persists full selection (not empty state)" {
  # Replicates the persist hook logic for the case where the only TAP failure is
  # "bats-gather-tests" — a synthetic that grep -lF never maps to a real file.
  # Before #985 the fallback was absent: _vp_out stayed empty, nothing persisted,
  # and the next round re-selected 0 files → vacuous pass → live escapes #964/#977.
  run bash -c '
    set -euo pipefail
    project_root="'"${BATS_TEST_TMPDIR}"'/proj"
    state_dir="'"$STATE_DIR"'"
    mkdir -p "$project_root/tests"

    # Two bats files in the selection (content is irrelevant for the gather case)
    printf "#!/usr/bin/env bats\n@test \"x\" { true; }\n" \
      > "$project_root/tests/alpha.bats"
    printf "#!/usr/bin/env bats\n@test \"y\" { true; }\n" \
      > "$project_root/tests/beta.bats"

    # TAP output for a gather failure: only the synthetic gather-tests line
    tap_file=$(mktemp)
    printf "1..1\nnot ok 1 bats-gather-tests\n" > "$tap_file"

    _vp_state_file="$state_dir/gate-prior-failing-pr985.list"
    _selection="tests/alpha.bats
tests/beta.bats"

    # --- replicate persist hook logic (lib/utils/test-gate.sh ~2601-2628) ---
    _vp_names=$(grep -E '"'"'^not ok [0-9]+ '"'"'" "$tap_file" 2>/dev/null \
      | sed -E '"'"'s/^not ok [0-9]+ //'"'"' | sed '"'"'s/ # .*//'"'"' \
      | grep -v '"'"'^[[]tests_not_run[]]'"'"' || true)
    _vp_out=""
    if [ -n "$_vp_names" ] && [ -n "$_selection" ]; then
      _vp_sel_arr=()
      while IFS= read -r _vp_hit; do
        [ -n "$_vp_hit" ] && _vp_sel_arr+=("$project_root/$_vp_hit")
      done <<< "$_selection"
      while IFS= read -r _vp_name; do
        [ -z "$_vp_name" ] && continue
        _vp_hit=$(grep -lF "$_vp_name" "${_vp_sel_arr[@]+"${_vp_sel_arr[@]}"}" 2>/dev/null | head -1 || true)
        [ -n "$_vp_hit" ] && _vp_out="${_vp_out}${_vp_hit#"$project_root"/}"$'"'"'\n'"'"'
      done <<< "$_vp_names"
      _vp_out=$(printf '"'"'%s'"'"' "$_vp_out" | sort -u | grep -v '"'"'^$'"'"' || true)
      # #985 fallback: unmappable names (gather errors) → persist whole selection
      if [ -z "$_vp_out" ]; then
        _vp_out=$(printf '"'"'%s\n'"'"' "$_selection" | grep -v '"'"'^$'"'"' || true)
      fi
      if [ -n "$_vp_out" ]; then
        mkdir -p "$(dirname "$_vp_state_file")" 2>/dev/null || true
        printf '"'"'%s\n'"'"' "$_vp_out" > "$_vp_state_file"
      fi
    fi
    rm -f "$tap_file"
    # --- end replicate ---

    # Both selection files must appear in the state file
    grep -qxF "tests/alpha.bats" "$_vp_state_file" && echo "alpha:found"
    grep -qxF "tests/beta.bats"  "$_vp_state_file" && echo "beta:found"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha:found"* ]]
  [[ "$output" == *"beta:found"* ]]
}

@test "source: gather-failure fallback (full-selection persist) exists in persist hook" {
  # #985: when _vp_out is empty after name→file mapping, we fall back to the full
  # selection.  Assert both the guard and the fallback assignment are present.
  run grep -cF 'if [ -z "$_vp_out" ]' "$GATE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # Fallback assigns _selection into _vp_out
  run grep -cF '_vp_out=$(printf' "$GATE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
