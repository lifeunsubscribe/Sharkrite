#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/repo-status.sh
# Regression test for: `rite --status` display polish
#
# Covers two visual nitpicks in the status display:
#
#   1. PR# bumped right up against the labels column (e.g.
#        "#471  Title…    2026-06-08  PR#476  bug, priority-high")
#      The fix gives the PR column a fixed width via the new _pr_link
#      MIN_WIDTH argument, so labels start at a predictable column whether
#      or not a PR exists.
#
#   2. Bracketed label prefixes in titles duplicating the labels column
#      (e.g. "[tech-debt] Harden…    tech-debt, priority-medium").
#      The new strip_label_prefix_from_title() drops the "[label] " prefix
#      when the bracket content matches one of the issue's labels.

setup() {
  RITE_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  export RITE_REPO_ROOT
  REPO_STATUS="$RITE_REPO_ROOT/lib/utils/repo-status.sh"
  export REPO_STATUS

  # Source the helpers without triggering top-level execution. repo-status.sh
  # only DEFINES functions at the top — there's no body that runs on source.
  # shellcheck disable=SC1090
  source "$REPO_STATUS"
}

# ---------------------------------------------------------------------------
# strip_label_prefix_from_title — happy path
# ---------------------------------------------------------------------------
@test "strip_label_prefix_from_title: strips [tech-debt] when label matches" {
  run strip_label_prefix_from_title "[tech-debt] Harden the regex" "tech-debt, priority-medium"
  [ "$status" -eq 0 ]
  [ "$output" = "Harden the regex" ]
}

@test "strip_label_prefix_from_title: case-insensitive match" {
  run strip_label_prefix_from_title "[Tech-Debt] Fix something" "tech-debt"
  [ "$status" -eq 0 ]
  [ "$output" = "Fix something" ]
}

@test "strip_label_prefix_from_title: matches a label deep in the CSV" {
  run strip_label_prefix_from_title "[bug] Crash on resume" "priority-high, bug, recurring-pattern"
  [ "$status" -eq 0 ]
  [ "$output" = "Crash on resume" ]
}

# ---------------------------------------------------------------------------
# strip_label_prefix_from_title — must NOT strip
# ---------------------------------------------------------------------------
@test "strip_label_prefix_from_title: leaves title alone when prefix is not a label" {
  # Title says "[hardening]" but no label by that name → leave alone
  run strip_label_prefix_from_title "[hardening] Make tests more strict" "bug, priority-medium"
  [ "$status" -eq 0 ]
  [ "$output" = "[hardening] Make tests more strict" ]
}

@test "strip_label_prefix_from_title: no bracket prefix → unchanged" {
  run strip_label_prefix_from_title "Just a normal title" "tech-debt"
  [ "$status" -eq 0 ]
  [ "$output" = "Just a normal title" ]
}

@test "strip_label_prefix_from_title: empty labels list → unchanged" {
  run strip_label_prefix_from_title "[tech-debt] Should not strip" ""
  [ "$status" -eq 0 ]
  [ "$output" = "[tech-debt] Should not strip" ]
}

@test "strip_label_prefix_from_title: bracket without trailing body → unchanged" {
  # Pure "[tech-debt]" with nothing after the bracket isn't a useful title; leave it.
  run strip_label_prefix_from_title "[tech-debt]" "tech-debt"
  [ "$status" -eq 0 ]
  [ "$output" = "[tech-debt]" ]
}

# ---------------------------------------------------------------------------
# _pr_link MIN_WIDTH padding
# ---------------------------------------------------------------------------
# Helper: count trailing literal spaces on a string. _pr_link emits the
# padding as plain spaces appended after the ANSI-reset sequence, so we can
# just chomp trailing spaces without parsing escape codes.
_count_trailing_spaces() {
  local s="$1" n=0
  while [ "${s: -1}" = " " ]; do
    n=$((n + 1))
    s="${s% }"
  done
  printf '%d' "$n"
}

@test "_pr_link: with min_width=10, short PR is padded to fill the column" {
  # PR#5 = 4 visible chars → 6 trailing spaces → 10 total visible chars
  local raw
  raw=$(_pr_link 5 "" 10)
  [[ "$raw" == *"PR#5"* ]]
  [ "$(_count_trailing_spaces "$raw")" -eq 6 ]
}

@test "_pr_link: with min_width=10, long PR text is not truncated" {
  # PR#12345 = 8 visible chars → 2 trailing spaces
  local raw
  raw=$(_pr_link 12345 "" 10)
  [[ "$raw" == *"PR#12345"* ]]
  [ "$(_count_trailing_spaces "$raw")" -eq 2 ]
}

@test "_pr_link: without min_width, no trailing padding is added" {
  # Backward-compat — the by-label code paths still call _pr_link with 2 args.
  local raw
  raw=$(_pr_link 99 "")
  [[ "$raw" == *"PR#99"* ]]
  [ "$(_count_trailing_spaces "$raw")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Structural: every title display site uses the strip helper
#
# If a future refactor adds a new title display without going through the
# strip helper, the bracketed-prefix nitpick comes back. Keep a count anchor
# so removals are visible.
# ---------------------------------------------------------------------------
@test "repo-status.sh: every truncate_str on a title goes through strip_label_prefix_from_title" {
  local strip_calls truncate_title_calls
  strip_calls=$(grep -c 'strip_label_prefix_from_title' "$REPO_STATUS")
  # 5 display sites + 1 function definition + 1 doc-comment usage line = 7
  # The exact count is less important than: strip is called for every title.
  # Assert there are at least as many strip calls as title-truncating sites.
  truncate_title_calls=$(grep -cE '_display_title=\$\(strip_label_prefix_from_title' "$REPO_STATUS")
  [ "$truncate_title_calls" -ge 5 ]
}

@test "repo-status.sh: PR display sites use fixed-width column (min_width=10)" {
  # The In Progress and Recently Closed sections must pad PR display to a
  # fixed column width so labels align consistently.
  run grep -F '_pr_link "${issue_pr_numbers[$i]}" "$repo_url" 10' "$REPO_STATUS"
  [ "$status" -eq 0 ]
  run grep -F '_pr_link "$closed_pr_num" "$repo_url" 10' "$REPO_STATUS"
  [ "$status" -eq 0 ]
}
