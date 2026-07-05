#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/create-pr.sh, lib/core/assess-review-issues.sh, lib/core/plan-issues.sh, lib/utils/scratchpad-manager.sh, lib/core/batch-process-issues.sh, bin/rite-full-suite
# Regression: BSD/GNU portability round 2 (audit 2026-07-04). GNU-only idioms
# that SILENTLY misbehave on BSD (macOS) while passing GNU/Linux CI:
#   - sed BRE \| alternation (BSD: literal) — dropped/over-captured sections
#   - sed \b/\u escapes (BSD: literal u) — garbled PR titles
#   - sed Q (BSD: invalid command, masked by || fallback) — unbounded scratchpad
#   - bare `timeout` (stock macOS has none) — exit 127 misread as "timed out"
#   - mktemp X's not terminal (BSD: literal name) — predictable temp files
# Each test pins the fixed source AND verifies the replacement's behavior on
# the host sed/awk (BSD on macOS, GNU on Linux CI — must pass on BOTH).

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
}

@test "create-pr: branch-name title-case uses awk (no GNU sed \u); behavior correct" {
  # Old pattern must be gone (it produced "uix uogin uug" on BSD).
  run grep -F 's/\b\(.\)/\u\1/g' "${RITE_REPO_ROOT}/lib/core/create-pr.sh"
  [ "$status" -ne 0 ]
  # New pipeline title-cases correctly on this host's tools.
  result=$(echo "fix/login-rate-limit" | sed 's/.*\///' | tr '-' ' ' \
    | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) substr($i,2)}1')
  [ "$result" = "Login Rate Limit" ] || { echo "got: $result"; false; }
}

@test "assess-review-issues: conventions extraction uses -E alternation and matches" {
  run grep -F "sed -nE '/[Cc]ommit [Cc]onventions|" "${RITE_REPO_ROOT}/lib/core/assess-review-issues.sh"
  [ "$status" -eq 0 ]
  # The ERE range extracts the section on this host's sed.
  result=$(printf '# Doc\n## Commit Conventions\nrule-a\n## Next\nother\n' \
    | sed -nE '/[Cc]ommit [Cc]onventions|[Gg]it.*[Cc]onventions/,/^## /p' | head -3)
  [[ "$result" == *"rule-a"* ]] || { echo "section not extracted: $result"; false; }
}

@test "plan-issues: Files-to-Modify range uses -E alternation and stops at boundary" {
  run grep -F "sed -nE '/Files to Modify/,/^\*\*|^##|^Related|^\$/p'" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh"
  [ "$status" -eq 0 ]
  # Range must STOP at the blank line — BSD's literal-\| bug ran to EOF and
  # picked up routers from later sections.
  result=$(printf 'Files to Modify\n- routers/auth.py\n\nFiles to Read\n- routers/other.py\n' \
    | sed -nE '/Files to Modify/,/^\*\*|^##|^Related|^$/p' | grep -oiE 'routers/[a-z_]+\.py' | head -1)
  [ "$result" = "routers/auth.py" ] || { echo "over-captured: $result"; false; }
}

@test "scratchpad-manager: entry trim uses POSIX q (not GNU Q) and extracts entries" {
  run grep -F "sed '/^## /q'" "${RITE_REPO_ROOT}/lib/utils/scratchpad-manager.sh"
  [ "$status" -eq 0 ]
  run grep -F "sed '/^## /Q'" "${RITE_REPO_ROOT}/lib/utils/scratchpad-manager.sh"
  [ "$status" -ne 0 ]
  # The q-based pipeline yields the entries (Q hard-errored on BSD → empty →
  # entry_count always 0 → the keep-last-4 trim never fired).
  result=$(printf '### PR #7\nfinding\n## Completed Work Archive\nold\n' \
    | sed '/^## /q' | grep -A 9999 "^### PR #" | head -c 5000)
  [[ "$result" == *"### PR #7"* ]] && [[ "$result" != *"old"* ]] || { echo "got: $result"; false; }
}

@test "batch prefetch is bounded via run_with_timeout, not bare timeout" {
  run grep -E '^if run_with_timeout 10 git fetch --prune origin' "${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  [ "$status" -eq 0 ]
  run grep -E '^if timeout 10 git fetch' "${RITE_REPO_ROOT}/lib/core/batch-process-issues.sh"
  [ "$status" -ne 0 ]
}

@test "rite-full-suite mktemp templates end in XXXXXX (BSD requires terminal X's)" {
  # A suffix after the X's is a GNU extension; BSD creates the LITERAL name,
  # breaking concurrent runs. All templates must end with XXXXXX.
  run grep -nE 'mktemp .*XXXXXX[^"]+"' "${RITE_REPO_ROOT}/bin/rite-full-suite"
  [ "$status" -ne 0 ] || { echo "non-terminal X's: $output"; false; }
  # And the fixed templates still exist (3 call sites).
  count=$(grep -cE 'mktemp "\$\{TMPDIR:-/tmp\}/rite_fs_[a-z_]+_\$\$_XXXXXX"' "${RITE_REPO_ROOT}/bin/rite-full-suite")
  [ "$count" -eq 3 ] || { echo "expected 3 fixed templates, got $count"; false; }
}
