#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/plan-issues.sh::_strip_self_dep_refs|generate_issues|_lint_issues_strict
#
# An issue's reference to its own ordinal in its Dependencies section is
# rewritten to "this issue" before strict lint, so it can't masquerade as a
# one-node cycle.
#
# Live failure (2026-10-24, doc-drift plan): issue #16 of 25 wrote
# "**Dependencies**: After #16's prerequisites — After #2, #13". Strict lint
# read #16 as an edge, reported "dependency cycle detected among: #16", and
# aborted the whole fable generation. Had it reached GitHub, the ordinal →
# issue-number rewrite would have made the issue block on itself forever.

load '../helpers/setup.bash'

setup() {
  setup_test_tmpdir
  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  # shellcheck disable=SC1090
  source "${RITE_REPO_ROOT}/lib/utils/markers.sh"
  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode swallows failing tests (2026-07-01 not-run incident); keep -e for bats failure detection

  _RITE_PLAN_TITLE_MAX_LEN=50
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  eval "$(awk '
    /^_title_is_spike[(][)]/ { in_fn=1; depth=0 }
    /^_strip_self_dep_refs[(][)]/ { in_fn=1; depth=0 }
    /^_strip_par_ref[(][)]/ { in_fn=1; depth=0 }
    /^_transform_dep_line[(][)]/ { in_fn=1; depth=0 }
    /^_autochain_rewrite_deps[(][)]/ { in_fn=1; depth=0 }
    /^_autochain_remove_par_annotation[(][)]/ { in_fn=1; depth=0 }
    /^_lint_issues_strict[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
}

teardown() {
  teardown_test_tmpdir
}

# _issue TITLE DEPS [DESCRIPTION] — one issue block with a unique file.
_issue() {
  local slug
  slug=$(printf '%s' "$1" | tr 'A-Z ' 'a-z_')
  cat <<EOF
---ISSUE---
TITLE: $1
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
${3:-Does a thing.}

**Claude Context**:
Files to Modify:
- src/${slug}.sh

**Acceptance Criteria**:
- [ ] Works: \`bats tests/${slug}.bats\`

**Done Definition**: Done when it works.

**Dependencies**: $2
---END---
EOF
}

@test "live reproduction: self-ref is rewritten and strict lint passes" {
  local f="$RITE_TEST_TMPDIR/issues.txt"
  { _issue "Add store" "None"; _issue "Emit entries" "After #2's prerequisites — After #1"; } > "$f"

  # Before the fix: the self-edge is a one-node cycle.
  local rc=0
  _lint_issues_strict "$f" "" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]

  run _strip_self_dep_refs "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dropped self-reference #2 from the Dependencies of 'Emit entries'"* ]]
  grep -qF "**Dependencies**: After this issue's prerequisites — After #1" "$f"

  rc=0
  _lint_issues_strict "$f" "" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ]
}

@test "word boundary: #1 does not touch #12 in issue 1" {
  local f="$RITE_TEST_TMPDIR/issues.txt"
  _issue "Add store" "After #12 (external)" > "$f"
  _strip_self_dep_refs "$f" 2>/dev/null
  grep -qF "**Dependencies**: After #12 (external)" "$f"
}

@test "only the Dependencies section is rewritten, not prose elsewhere" {
  local f="$RITE_TEST_TMPDIR/issues.txt"
  { _issue "Add store" "None"; _issue "Emit entries" "After #1" "Issue #2 is this one; see #2 notes."; } > "$f"
  _strip_self_dep_refs "$f" 2>/dev/null
  grep -qF "Issue #2 is this one; see #2 notes." "$f"
  grep -qF "**Dependencies**: After #1" "$f"
}

@test "ordinals skip spikes, matching strict lint's numbering" {
  local f="$RITE_TEST_TMPDIR/issues.txt"
  # Spike first: it has no ordinal, so the next issue is #1 and #1 is its self-ref.
  { _issue "Capture orbit sample - fixtures" "None"; _issue "Add store" "After #1"; } > "$f"
  _strip_self_dep_refs "$f" 2>/dev/null
  grep -qF "**Dependencies**: After this issue" "$f"
}

@test "a real two-issue cycle still fails strict lint" {
  local f="$RITE_TEST_TMPDIR/issues.txt"
  { _issue "Add store" "After #2"; _issue "Emit entries" "After #1"; } > "$f"
  _strip_self_dep_refs "$f" 2>/dev/null
  local rc=0 err
  err=$(_lint_issues_strict "$f" "" 2>&1) || rc=$?
  [ "$rc" -ne 0 ]
  [[ "$err" == *"dependency cycle detected"* ]]
}

@test "no self-ref: file is byte-identical and nothing is printed" {
  local f="$RITE_TEST_TMPDIR/issues.txt"
  { _issue "Add store" "None"; _issue "Emit entries" "After #1"; } > "$f"
  local before
  before=$(cat "$f")
  run _strip_self_dep_refs "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$f")" = "$before" ]
}

@test "wiring: generate_issues strips self-refs before strict lint" {
  local body
  body=$(awk '/^generate_issues[(][)]/,/^}/' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")
  local strip_line lint_line
  strip_line=$(printf '%s\n' "$body" | grep -n '_strip_self_dep_refs "\$temp_file"' | head -1 | cut -d: -f1)
  lint_line=$(printf '%s\n' "$body" | grep -n '_lint_issues_strict "\$temp_file"' | head -1 | cut -d: -f1)
  [ -n "$strip_line" ] && [ -n "$lint_line" ]
  [ "$strip_line" -lt "$lint_line" ]
}
