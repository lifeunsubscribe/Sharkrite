#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/batch-process-issues.sh, bin/rite
# tests/regression/batch-label-dependency-closure.bats
#
# Regression test: preflight dependency closure check for label batch runs.
#
# Issue #554 — "Preflight dependency closure for label batch runs"
# Issue #560 — "--state filter mode preflights against open-only"
#
# Problem: `rite --label X` selects issues by label only. When a dependency
# of a selected issue lives outside the label (mislabeled or in another
# category), the batch discovered it serially — each dependent hit the
# per-issue dep-skip guard one by one, silently no-op'ing most of the slate.
#
# Fix: a preflight closure pass runs immediately after FETCHED_ISSUES is
# resolved. It batch-fetches selected issue bodies in one gh call, collects
# all out-of-selection dep refs, batch-checks their open/closed state with
# one gh issue list call, and emits a single upfront summary block. In
# supervised mode it prompts to include missing deps; in auto mode it warns
# and defers to the existing per-issue backstop.
#
# --state filter scoping (issue #560): preflight only runs when --state open
# is selected. For --state closed and --state all the preflight is skipped
# with an informational message — closed issues have no actionable open
# blockers, and mixed-state selections would produce partial/misleading
# analysis. The per-issue dep-skip guard remains the backstop for all modes.
#
# Tests in this file:
#   STRUCTURAL (static code inspection):
#     1. Preflight block exists and is guarded by FILTER_TYPE
#     2. Dep-ref pattern matches the per-issue guard pattern (same regex)
#     3. Supervised mode prompt exists in the preflight block
#     4. Auto mode does NOT change ISSUE_LIST (deterministic selection)
#     5. Per-issue dep-skip guard at lines ~620+ is unchanged
#     6. --state skip guard exists in production code (issue #560)
#
#   BEHAVIORAL (subprocess scripting):
#     7. dep outside selection → "Dependency Closure Warning" summary present
#     8. dep inside selection → no summary block emitted
#     9. dep outside selection but already closed → no summary block emitted
#    10. multiple selected issues, only some with oos deps → only those listed
#    11. supervised mode prompt fires when oos open dep found
#    12. supervised mode: answering Y adds dep to ISSUE_LIST (dep runs first)
#    13. supervised mode: answering n leaves ISSUE_LIST unchanged
#    14. auto mode: warning printed, ISSUE_LIST unchanged
#    15. --state closed → preflight skipped with informational message
#    16. --state all → preflight skipped with informational message
#    17. --state open → preflight runs normally (same as label mode)
#
#   PARITY (per-issue skip guard preserved):
#    18. per-issue dep skip guard still present at expected location in batch file

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BATCH_PROCESSOR="$REPO_ROOT/lib/core/batch-process-issues.sh"
RITE_BIN="$REPO_ROOT/bin/rite"

setup() {
  [ -f "$BATCH_PROCESSOR" ] || {
    echo "FATAL: $BATCH_PROCESSOR not found" >&2
    return 1
  }
}

# =============================================================================
# STRUCTURAL: static code inspection
# =============================================================================

@test "structural: preflight closure block exists and is guarded by FILTER_TYPE" {
  # The block must be conditional on FILTER_TYPE so numeric-list invocations
  # (rite N1 N2 N3) are not affected.
  grep -q 'FILTER_TYPE' "$BATCH_PROCESSOR" || {
    echo "FAIL: FILTER_TYPE not referenced in batch-process-issues.sh" >&2
    return 1
  }

  # The preflight closure check must be guarded by FILTER_TYPE
  grep -q 'Preflight Dependency Closure' "$BATCH_PROCESSOR" || {
    echo "FAIL: Preflight Dependency Closure block not found in batch-process-issues.sh" >&2
    return 1
  }

  # The block must check FILTER_TYPE non-empty before running
  grep -qE '\[ -n.*FILTER_TYPE.*\]' "$BATCH_PROCESSOR" || {
    echo "FAIL: FILTER_TYPE guard not found for preflight closure block" >&2
    return 1
  }
}

@test "structural: dep-ref regex pattern in preflight matches the per-issue guard pattern" {
  # Both the preflight and per-issue guard must use the same dependency patterns:
  # 'After:? #', 'Depends on #', 'Blocked by:? #'
  # If they diverge, some deps would be caught by one but not the other.

  # Count occurrences of the canonical dep-ref pattern
  _pattern_count=$(grep -c "(After:? #|Depends on #|Blocked by:? #)" "$BATCH_PROCESSOR" || true)

  # Must appear at least twice: once in preflight, once in per-issue guard
  [ "$_pattern_count" -ge 2 ] || {
    echo "FAIL: dep-ref pattern found $_pattern_count times, expected at least 2" >&2
    echo "      Both preflight closure and per-issue guard must use the same pattern" >&2
    return 1
  }
}

@test "structural: supervised mode prompt exists in preflight closure block" {
  # The prompt must fire only in supervised mode (RITE_SUPERVISED=true).
  # Grep for the RITE_SUPERVISED check inside the preflight section.

  # Extract the preflight block — from "Preflight Dependency Closure" to the
  # closing `fi` that ends the FILTER_TYPE guard
  _block=$(awk '
    /Preflight Dependency Closure/ { in_block=1 }
    in_block { print $0 }
    in_block && /^fi$/ { exit }
  ' "$BATCH_PROCESSOR")

  [ -n "$_block" ] || {
    echo "FAIL: Could not extract preflight closure block" >&2
    return 1
  }

  # Must check RITE_SUPERVISED
  echo "$_block" | grep -q 'RITE_SUPERVISED' || {
    echo "FAIL: RITE_SUPERVISED check not found in preflight closure block" >&2
    return 1
  }

  # Must have a read prompt for user input
  echo "$_block" | grep -q 'read -r' || {
    echo "FAIL: 'read -r' prompt not found in preflight supervised branch" >&2
    return 1
  }
}

@test "structural: auto mode does NOT change ISSUE_LIST in preflight block" {
  # The auto mode branch must not add issues to ISSUE_LIST.
  # This preserves deterministic selection from the user's flag.

  # Extract the auto-mode branch of the preflight block (after the `else`
  # branch of the RITE_SUPERVISED check)
  _block=$(awk '
    /Preflight Dependency Closure/ { in_block=1 }
    in_block { print $0 }
    in_block && /^fi$/ { exit }
  ' "$BATCH_PROCESSOR")

  # Find the else branch of the RITE_SUPERVISED if
  _auto_branch=$(echo "$_block" | awk '
    /RITE_SUPERVISED/ { in_supervised=1 }
    in_supervised && /^    else$/ { in_auto=1; next }
    in_auto && /^    fi$/ { exit }
    in_auto { print $0 }
  ')

  # The auto mode branch must NOT contain ISSUE_LIST modification
  if echo "$_auto_branch" | grep -qE 'ISSUE_LIST=\('; then
    echo "FAIL: auto mode branch modifies ISSUE_LIST — violates deterministic selection contract" >&2
    echo "      DO NOT auto-include in unsupervised mode per scope boundary" >&2
    return 1
  fi
}

@test "structural: per-issue dep-skip guard at ~620+ is unchanged and still present" {
  # The existing per-issue dep-skip guard (lines ~457-499 before this PR's
  # insertion) must remain unchanged. It is the backstop for within-batch
  # failures and MUST NOT be removed or altered.

  # Verify the dep-failed divergence comment is still present
  grep -q "Deliberate divergence from single-issue mode" "$BATCH_PROCESSOR" || {
    echo "FAIL: 'Deliberate divergence' comment not found — per-issue guard may have been removed" >&2
    return 1
  }

  # Verify the dep_failed status is still set (per-issue backstop behavior)
  grep -q '"dep_failed"' "$BATCH_PROCESSOR" || {
    echo "FAIL: dep_failed status not found — per-issue dep skip guard may have been removed" >&2
    return 1
  }

  # Verify that gh_safe issue view per-dep is still used in the per-issue guard
  # (not the preflight — the backstop must still do its own check at run time)
  grep -qE 'gh_safe issue view.*dep_num.*state' "$BATCH_PROCESSOR" || {
    echo "FAIL: per-dep state check (gh_safe issue view dep_num) not found in per-issue guard" >&2
    return 1
  }
}

@test "structural: bin/rite exports RITE_SUPERVISED when --supervised is passed" {
  # Supervised mode propagation: bin/rite must export RITE_SUPERVISED=true
  # so batch-process-issues.sh can detect it via the env (since bin/rite uses
  # exec and cannot pass it as a flag through the batch filter dispatch path).
  grep -qE 'export RITE_SUPERVISED' "$RITE_BIN" || {
    echo "FAIL: 'export RITE_SUPERVISED' not found in bin/rite" >&2
    echo "      Without this, batch-process-issues.sh cannot detect supervised mode" >&2
    return 1
  }

  # The export must be in the --supervised argument handler
  _supervised_block=$(awk '
    /--supervised\)/ { in_block=1; next }
    in_block && /^\s*;;/ { exit }
    in_block { print $0 }
  ' "$RITE_BIN")

  echo "$_supervised_block" | grep -q 'RITE_SUPERVISED' || {
    echo "FAIL: RITE_SUPERVISED export not inside --supervised block in bin/rite" >&2
    return 1
  }
}

@test "structural: --state skip guard exists in production code (issue #560)" {
  # The preflight block must contain a guard that skips when FILTER_TYPE=state
  # and FILTER_VALUE != "open". This prevents false-positive coverage claims
  # when closed or all-state issue selections are run.

  # Verify the state-type check exists
  grep -qE 'FILTER_TYPE.*=.*state' "$BATCH_PROCESSOR" || {
    echo "FAIL: state filter type check not found in batch-process-issues.sh" >&2
    echo "      Expected: [ \"\${FILTER_TYPE:-}\" = \"state\" ] guard in preflight block" >&2
    return 1
  }

  # Verify the open-only condition
  grep -qE 'FILTER_VALUE.*!=.*open' "$BATCH_PROCESSOR" || {
    echo "FAIL: FILTER_VALUE != open check not found in batch-process-issues.sh" >&2
    echo "      Expected: [ \"\${FILTER_VALUE:-}\" != \"open\" ] guard in preflight block" >&2
    return 1
  }

  # Verify the skip message is present
  grep -q 'preflight checks open-issue dependencies only' "$BATCH_PROCESSOR" || {
    echo "FAIL: 'preflight checks open-issue dependencies only' skip message not found" >&2
    return 1
  }
}

# =============================================================================
# BEHAVIORAL: subprocess scripting
# =============================================================================

# Helper: create a test script that simulates the preflight logic in isolation.
# It stubs gh_safe, print_header/info/warning/success, and exercises the
# preflight dep closure check logic.
#
# Arguments:
#   $1: FILTER_TYPE ("label", "milestone", or "" to disable check)
#   $2: FILTER_VALUE (e.g. "frontend")
#   $3: ISSUE_LIST (space-separated, e.g. "10 11 12")
#   $4: ISSUE_BODIES_JSON: jq-style list for the batch body fetch stub
#       Format: '[{"number":N,"body":"text"}, ...]'
#   $5: OPEN_ISSUES_JSON: jq-style list for the dep state batch check
#       Format: '[{"number":N}, ...]' (only open issues listed)
#   $6: RITE_SUPERVISED ("true" or "false")
#   $7: SUPERVISED_REPLY (user reply to prompt, e.g. "y" or "n")
#
# The script prints to stdout, exits 0 on success.
_create_preflight_test_script() {
  local filter_type="$1"
  local filter_value="$2"
  local issue_list="$3"
  local bodies_json="$4"
  local open_issues_json="$5"
  local supervised="${6:-false}"
  local reply="${7:-}"

  cat << SCRIPT_EOF
#!/usr/bin/env bash
set -euo pipefail

# ---- Stubs ----
print_header()  { echo "HEADER: \$*"; }
print_info()    { echo "INFO: \$*"; }
print_warning() { echo "WARNING: \$*"; }
print_success() { echo "SUCCESS: \$*"; }

_gh_call_count=0
gh_safe() {
  _gh_call_count=\$((_gh_call_count + 1))
  if [ "\${1:-}" = "issue" ] && [ "\${2:-}" = "list" ]; then
    # Check if this is the body-fetch call (has --json number,body)
    _args="\$*"
    if echo "\$_args" | grep -q '"number,body"'; then
      # Return bodies JSON — jq processes to base64 format
      echo '${bodies_json}' | jq -r '.[] | [(.number | tostring), (.body | @base64)] | join(" ")'
    else
      # Return open issues JSON for dep state check
      echo '${open_issues_json}' | jq -r '.[].number'
    fi
    return 0
  fi
  echo ""
  return 0
}

FILTER_TYPE="${filter_type}"
FILTER_VALUE="${filter_value}"
ISSUE_LIST=(${issue_list})
RITE_SUPERVISED="${supervised}"

# Simulate the supervised mode read by pre-setting stdin
$([ -n "${reply}" ] && echo "exec < <(echo '${reply}')" || echo "# no reply needed")

# ---- Run the preflight closure logic ----
# (Copy of the preflight block from batch-process-issues.sh, minus external deps)
if [ -n "\${FILTER_TYPE:-}" ] && [ \${#ISSUE_LIST[@]} -gt 0 ]; then
  # --state skip guard (issue #560): preflight is only meaningful for open issues.
  if [ "\${FILTER_TYPE:-}" = "state" ] && [ "\${FILTER_VALUE:-}" != "open" ]; then
    print_header "Preflight Dependency Closure Check"
    print_info "Skipping: preflight checks open-issue dependencies only."
    print_info "(Selection is --state \${FILTER_VALUE:-?} — per-issue dep guard remains active.)"
    echo ""
  else
  print_header "Preflight Dependency Closure Check"

  declare -A _in_selection
  for _sel_num in "\${ISSUE_LIST[@]}"; do
    _in_selection["\$_sel_num"]=1
  done

  _preflight_bodies_raw=\$(gh_safe issue list \\
    --state open \\
    --json number,body \\
    --limit 200 \\
    --jq '.[] | [(.number | tostring), (.body | @base64)] | join(" ")' 2>/dev/null || true)

  declare -A _oos_dep_map
  _oos_issue_nums=""
  _all_candidate_deps=""

  if [ -n "\$_preflight_bodies_raw" ]; then
    while IFS= read -r _pf_line; do
      _pf_num="\${_pf_line%% *}"
      _pf_body_b64="\${_pf_line#* }"
      [ -n "\${_in_selection[\$_pf_num]:-}" ] || continue
      [ -z "\$_pf_body_b64" ] && continue

      _pf_body=\$(echo "\$_pf_body_b64" | base64 --decode 2>/dev/null || \\
                 echo "\$_pf_body_b64" | base64 -D 2>/dev/null || true)
      [ -z "\$_pf_body" ] && continue

      _dep_refs=\$(echo "\$_pf_body" | grep -oiE '(After:? #|Depends on #|Blocked by:? #)[0-9]+' | grep -oE '[0-9]+' || true)
      [ -z "\$_dep_refs" ] && continue

      _oos_deps_for_this=""
      for _dep_num in \$_dep_refs; do
        [ -n "\${_in_selection[\$_dep_num]:-}" ] && continue
        _oos_deps_for_this="\${_oos_deps_for_this:+\$_oos_deps_for_this }\$_dep_num"
        case " \$_all_candidate_deps " in
          *" \$_dep_num "*) ;;
          *) _all_candidate_deps="\${_all_candidate_deps:+\$_all_candidate_deps }\$_dep_num" ;;
        esac
      done

      if [ -n "\$_oos_deps_for_this" ]; then
        _oos_dep_map["\$_pf_num"]="\$_oos_deps_for_this"
        case " \$_oos_issue_nums " in
          *" \$_pf_num "*) ;;
          *) _oos_issue_nums="\${_oos_issue_nums:+\$_oos_issue_nums }\$_pf_num" ;;
        esac
      fi
    done <<< "\$_preflight_bodies_raw"
  fi

  declare -A _dep_is_open
  if [ -n "\$_all_candidate_deps" ]; then
    _candidate_array=()
    for _cd in \$_all_candidate_deps; do
      _candidate_array+=("\$_cd")
    done
    _jq_filter='[.[] | select('
    _first_cd=true
    for _cd in "\${_candidate_array[@]}"; do
      if [ "\$_first_cd" = "true" ]; then
        _jq_filter="\${_jq_filter}.number == \${_cd}"
        _first_cd=false
      else
        _jq_filter="\${_jq_filter} or .number == \${_cd}"
      fi
    done
    _jq_filter="\${_jq_filter}) | .number] | .[]"

    _open_deps_raw=\$(gh_safe issue list \\
      --state open \\
      --json number \\
      --limit 500 \\
      --jq "\$_jq_filter" 2>/dev/null || true)

    if [ -n "\$_open_deps_raw" ]; then
      while IFS= read -r _od_num; do
        [ -n "\$_od_num" ] && _dep_is_open["\$_od_num"]=1
      done <<< "\$_open_deps_raw"
    fi
  fi

  _filtered_oos_issue_nums=""
  declare -A _filtered_oos_dep_map
  _all_missing_deps=""

  for _oos_num in \$_oos_issue_nums; do
    _deps="\${_oos_dep_map[\$_oos_num]:-}"
    _open_oos_deps=""
    for _d in \$_deps; do
      [ -n "\${_dep_is_open[\$_d]:-}" ] || continue
      _open_oos_deps="\${_open_oos_deps:+\$_open_oos_deps }\$_d"
      case " \$_all_missing_deps " in
        *" \$_d "*) ;;
        *) _all_missing_deps="\${_all_missing_deps:+\$_all_missing_deps }\$_d" ;;
      esac
    done
    if [ -n "\$_open_oos_deps" ]; then
      _filtered_oos_dep_map["\$_oos_num"]="\$_open_oos_deps"
      _filtered_oos_issue_nums="\${_filtered_oos_issue_nums:+\$_filtered_oos_issue_nums }\$_oos_num"
    fi
  done

  if [ -n "\$_filtered_oos_issue_nums" ]; then
    print_warning "Dependency Closure Warning"
    for _oos_num in \$_filtered_oos_issue_nums; do
      _deps="\${_filtered_oos_dep_map[\$_oos_num]:-}"
      _deps_formatted=\$(echo "\$_deps" | sed 's/ /, #/g; s/^/#/' || true)
      echo "  AFFECTED: Issue #\${_oos_num} depends on: \${_deps_formatted}"
    done

    if [ "\${RITE_SUPERVISED:-false}" = "true" ]; then
      print_info "Missing open dependencies: \${_all_missing_deps}"
      printf "Include these missing dependencies in this batch? [Y/n] "
      read -r _include_deps_reply
      _include_deps_reply="\${_include_deps_reply:-y}"
      if [[ "\$_include_deps_reply" =~ ^[Yy]\$ ]]; then
        for _d in \$_all_missing_deps; do
          ISSUE_LIST=("\$_d" "\${ISSUE_LIST[@]}")
          _in_selection["\$_d"]=1
        done
        print_success "Added to batch"
        echo "ISSUE_LIST_AFTER: \${ISSUE_LIST[*]}"
      else
        print_info "Proceeding without missing dependencies"
        echo "ISSUE_LIST_AFTER: \${ISSUE_LIST[*]}"
      fi
    else
      print_info "Auto mode: proceeding with current selection."
      echo "ISSUE_LIST_AFTER: \${ISSUE_LIST[*]}"
    fi
  else
    print_success "All dependencies are within the selection (or already closed)"
    echo "ISSUE_LIST_AFTER: \${ISSUE_LIST[*]}"
  fi
  fi  # end: else branch of state-filter skip guard
fi

echo "ISSUE_LIST_FINAL: \${ISSUE_LIST[*]}"
echo "GH_CALLS: \$_gh_call_count"
SCRIPT_EOF
}

@test "behavioral: dep outside selection → Dependency Closure Warning emitted" {
  # Setup: issue 10 (selected, labeled 'frontend') depends on #5 (open, labeled 'backend')
  # #5 is NOT in the selection. Expected: warning block with Issue #10 listed.

  _script="$BATS_TEST_TMPDIR/test-dep-outside.sh"
  _create_preflight_test_script \
    "label" "frontend" "10" \
    '[{"number":10,"body":"Depends on #5\n\nSome description"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Expected 'Dependency Closure Warning' in output" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "AFFECTED: Issue #10" || {
    echo "FAIL: Expected issue #10 in the closure warning" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: dep inside selection → no warning block" {
  # Setup: issue 10 depends on #5, and #5 IS in the selection.
  # Expected: no warning, success message only.

  _script="$BATS_TEST_TMPDIR/test-dep-inside.sh"
  _create_preflight_test_script \
    "label" "frontend" "10 5" \
    '[{"number":10,"body":"Depends on #5"},{"number":5,"body":"No deps"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Warning should not appear when dep is inside selection" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "All dependencies are within the selection" || {
    echo "FAIL: Expected success message when dep is inside selection" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: dep outside selection but already closed → no warning block" {
  # Setup: issue 10 depends on #5, #5 is outside selection but CLOSED.
  # The dep batch fetch returns no open issues (empty array).
  # Expected: no warning — closed deps are fine.

  _script="$BATS_TEST_TMPDIR/test-dep-closed.sh"
  _create_preflight_test_script \
    "label" "frontend" "10" \
    '[{"number":10,"body":"Blocked by: #5"}]' \
    '[]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Warning should not appear when dep is closed" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "All dependencies are within the selection" || {
    echo "FAIL: Expected success message when all deps are closed or in selection" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: multiple issues, only some with oos open deps → only those listed" {
  # Setup:
  #   Issue 10: depends on #3 (open, outside selection) → should appear in warning
  #   Issue 11: depends on #4 (closed, outside selection) → should NOT appear
  #   Issue 12: no deps → should NOT appear
  # Expected: warning lists only issue #10, not #11 or #12.

  _script="$BATS_TEST_TMPDIR/test-partial-oos.sh"
  _create_preflight_test_script \
    "label" "frontend" "10 11 12" \
    '[{"number":10,"body":"After #3"},{"number":11,"body":"Depends on #4"},{"number":12,"body":"No deps here"}]' \
    '[{"number":3}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Warning should appear since issue #10 has oos open dep" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "AFFECTED: Issue #10" || {
    echo "FAIL: Issue #10 should be listed in warning (has oos open dep #3)" >&2
    echo "Output: $output" >&2
    return 1
  }
  # Issue #11's dep (#4) is closed — should not appear in warning
  ! echo "$output" | grep -q "AFFECTED: Issue #11" || {
    echo "FAIL: Issue #11 should not appear (dep #4 is closed)" >&2
    echo "Output: $output" >&2
    return 1
  }
  # Issue #12 has no deps — should not appear
  ! echo "$output" | grep -q "AFFECTED: Issue #12" || {
    echo "FAIL: Issue #12 should not appear (no deps)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: supervised mode prompt fires when oos open dep found" {
  # Setup: issue 10 depends on #5 (open, outside selection); supervised mode on.
  # Expected: prompt is shown asking whether to include dep.

  _script="$BATS_TEST_TMPDIR/test-supervised-prompt.sh"
  _create_preflight_test_script \
    "label" "frontend" "10" \
    '[{"number":10,"body":"Depends on #5"}]' \
    '[{"number":5}]' \
    "true" "n" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "Missing open dependencies" || {
    echo "FAIL: Expected 'Missing open dependencies' prompt line" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: supervised mode answering Y adds dep to ISSUE_LIST before dependents" {
  # Setup: issue 10 depends on #5 (open, outside); user answers Y.
  # Expected: ISSUE_LIST now contains 5 AND 10, with 5 BEFORE 10 (prepended).

  _script="$BATS_TEST_TMPDIR/test-supervised-yes.sh"
  _create_preflight_test_script \
    "label" "frontend" "10" \
    '[{"number":10,"body":"Depends on #5"}]' \
    '[{"number":5}]' \
    "true" "y" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "Added to batch" || {
    echo "FAIL: Expected 'Added to batch' success message" >&2
    echo "Output: $output" >&2
    return 1
  }
  # ISSUE_LIST should contain both 5 and 10
  _list_line=$(echo "$output" | grep "ISSUE_LIST_FINAL:" | tail -1)
  echo "$_list_line" | grep -q "5" || {
    echo "FAIL: Dep #5 not added to ISSUE_LIST" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$_list_line" | grep -q "10" || {
    echo "FAIL: Original #10 not in ISSUE_LIST after dep addition" >&2
    echo "Output: $output" >&2
    return 1
  }
  # 5 must appear before 10 (prepended as dep)
  _list_value="${_list_line#ISSUE_LIST_FINAL: }"
  _pos_5=$(echo "$_list_value" | tr ' ' '\n' | grep -n "^5$" | cut -d: -f1 || true)
  _pos_10=$(echo "$_list_value" | tr ' ' '\n' | grep -n "^10$" | cut -d: -f1 || true)
  [ -n "$_pos_5" ] && [ -n "$_pos_10" ] && [ "$_pos_5" -lt "$_pos_10" ] || {
    echo "FAIL: Dep #5 should be before dependent #10 in list. List: $_list_value" >&2
    return 1
  }
}

@test "behavioral: supervised mode answering n leaves ISSUE_LIST unchanged" {
  # Setup: issue 10 depends on #5 (open, outside); user answers n.
  # Expected: ISSUE_LIST still contains only 10, dep #5 not added.

  _script="$BATS_TEST_TMPDIR/test-supervised-no.sh"
  _create_preflight_test_script \
    "label" "frontend" "10" \
    '[{"number":10,"body":"Depends on #5"}]' \
    '[{"number":5}]' \
    "true" "n" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  _list_line=$(echo "$output" | grep "ISSUE_LIST_FINAL:" | tail -1)
  # Dep #5 should NOT be in the list
  ! echo "$_list_line" | grep -qE '(^| )5( |$)' || {
    echo "FAIL: Dep #5 should NOT be in ISSUE_LIST when user answers n" >&2
    echo "Output: $output" >&2
    return 1
  }
  # Original issue #10 must remain
  echo "$_list_line" | grep -q "10" || {
    echo "FAIL: Original #10 must remain in ISSUE_LIST" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: auto mode prints warning but does not change ISSUE_LIST" {
  # Setup: issue 10 depends on #5 (open, outside); auto mode (RITE_SUPERVISED=false).
  # Expected: warning printed, ISSUE_LIST still only contains 10.

  _script="$BATS_TEST_TMPDIR/test-auto-mode.sh"
  _create_preflight_test_script \
    "label" "frontend" "10" \
    '[{"number":10,"body":"After #5"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Warning must be shown in auto mode" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "Auto mode: proceeding with current selection" || {
    echo "FAIL: 'Auto mode: proceeding' message not found" >&2
    echo "Output: $output" >&2
    return 1
  }
  # ISSUE_LIST must be unchanged (no dep added)
  _list_line=$(echo "$output" | grep "ISSUE_LIST_FINAL:" | tail -1)
  ! echo "$_list_line" | grep -qE '(^| )5( |$)' || {
    echo "FAIL: Auto mode must NOT add dep #5 to ISSUE_LIST" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: no-filter invocation (numeric list) skips preflight entirely" {
  # When FILTER_TYPE is empty (rite N1 N2), the preflight block must not run.
  # Expected: no 'Preflight Dependency Closure' header in output.

  _script="$BATS_TEST_TMPDIR/test-no-filter.sh"
  _create_preflight_test_script \
    "" "" "10" \
    '[{"number":10,"body":"Depends on #5"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "Preflight Dependency Closure" || {
    echo "FAIL: Preflight block must not run when FILTER_TYPE is empty (numeric-list mode)" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: --state closed → preflight skipped with informational message" {
  # Setup: issue 10 selected via --state closed; it has an open dep #5 outside
  # selection. Expected: preflight block does NOT emit a "Dependency Closure
  # Warning" — instead it emits the skip message and leaves ISSUE_LIST unchanged.

  _script="$BATS_TEST_TMPDIR/test-state-closed.sh"
  _create_preflight_test_script \
    "state" "closed" "10" \
    '[{"number":10,"body":"**Dependencies**: After #5"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  # Must NOT emit a warning — closed issues have no actionable open blockers
  ! echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Dependency Closure Warning must not fire for --state closed" >&2
    echo "Output: $output" >&2
    return 1
  }
  # Must emit the skip notification
  echo "$output" | grep -q "preflight checks open-issue dependencies only" || {
    echo "FAIL: Expected skip notification for --state closed" >&2
    echo "Output: $output" >&2
    return 1
  }
  # Must mention the actual state value for clarity
  echo "$output" | grep -q "closed" || {
    echo "FAIL: Skip message should mention the state value 'closed'" >&2
    echo "Output: $output" >&2
    return 1
  }
  # ISSUE_LIST must be unchanged
  _list_line=$(echo "$output" | grep "ISSUE_LIST_FINAL:" | tail -1)
  echo "$_list_line" | grep -q "10" || {
    echo "FAIL: ISSUE_LIST must still contain the original issue #10" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: --state all → preflight skipped with informational message" {
  # Setup: issues 10 11 selected via --state all; issue 10 has open dep #5.
  # Expected: preflight skipped — mixed open/closed selection would produce
  # partial/misleading analysis.

  _script="$BATS_TEST_TMPDIR/test-state-all.sh"
  _create_preflight_test_script \
    "state" "all" "10 11" \
    '[{"number":10,"body":"**Dependencies**: Depends on #5"},{"number":11,"body":"No deps"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  ! echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Dependency Closure Warning must not fire for --state all" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "preflight checks open-issue dependencies only" || {
    echo "FAIL: Expected skip notification for --state all" >&2
    echo "Output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "all" || {
    echo "FAIL: Skip message should mention the state value 'all'" >&2
    echo "Output: $output" >&2
    return 1
  }
}

@test "behavioral: --state open → preflight runs normally (same as label mode)" {
  # Setup: issue 10 selected via --state open; dep #5 is open and outside selection.
  # Expected: preflight runs and emits Dependency Closure Warning — same behavior
  # as --label or --milestone selections.

  _script="$BATS_TEST_TMPDIR/test-state-open.sh"
  _create_preflight_test_script \
    "state" "open" "10" \
    '[{"number":10,"body":"Depends on #5\n\nSome description"}]' \
    '[{"number":5}]' \
    "false" "" > "$_script"
  chmod +x "$_script"
  run bash "$_script"

  [ "$status" -eq 0 ] || {
    echo "Script failed: $output" >&2
    return 1
  }
  # Must NOT emit the skip message — open state runs preflight normally
  ! echo "$output" | grep -q "preflight checks open-issue dependencies only" || {
    echo "FAIL: --state open must not trigger the skip guard" >&2
    echo "Output: $output" >&2
    return 1
  }
  # Must emit the closure warning (dep #5 is open and outside selection)
  echo "$output" | grep -q "Dependency Closure Warning" || {
    echo "FAIL: Expected Dependency Closure Warning for --state open with oos open dep" >&2
    echo "Output: $output" >&2
    return 1
  }
}

# =============================================================================
# PARITY: verify per-issue dep skip guard is unchanged
# =============================================================================

@test "parity: per-issue dep-skip divergence comment count unchanged (>= 4)" {
  # The parity contract requires at least 4 divergence comments covering the
  # documented short-circuits (parent-PR-deferred, dep-failed, active-process,
  # in-current-branch). Adding the preflight block does NOT add a new
  # divergence — it's a preflight pass, not a short-circuit that bypasses
  # workflow-runner.sh.
  _divergence_count=$(grep -c "Deliberate divergence from single-issue mode" "$BATCH_PROCESSOR" || true)
  [ "$_divergence_count" -ge 4 ] || {
    echo "FAIL: expected at least 4 divergence comments, found $_divergence_count" >&2
    echo "Each batch short-circuit must retain its 'Deliberate divergence' comment" >&2
    return 1
  }
}

@test "parity: preflight block does NOT appear as a new batch short-circuit (no new divergence comment for it)" {
  # The preflight closure check runs before the processing loop — it is not a
  # per-issue short-circuit that bypasses workflow-runner.sh. Verify it does
  # not add a new divergence comment (that would change the parity test count).
  _preflight_divergence=$(grep -A5 "Preflight Dependency Closure" "$BATCH_PROCESSOR" | \
    grep -c "Deliberate divergence from single-issue mode" || true)
  [ "$_preflight_divergence" -eq 0 ] || {
    echo "FAIL: preflight block should not have a 'Deliberate divergence' comment" >&2
    echo "      The preflight is a pre-loop advisory pass, not a per-issue short-circuit" >&2
    return 1
  }
}
