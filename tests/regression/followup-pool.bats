#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/followup-pool.sh::followup_pool_open_pools|followup_pool_enabled|followup_pool_run_id|followup_pool_issue|followup_pool_append|followup_pool_entries|followup_pool_entry_block|followup_pool_resolve_entry, lib/utils/markers.sh
#
# Deferred-findings pool (2026-11-11): one issue per run collects every
# ACTIONABLE_LATER / encountered finding. Contract under test:
#   - created lazily at the first finding, recovered from GitHub when the
#     local state file is gone, never created twice for one run
#   - dedup before append: same-pool (location file + shared title words) and
#     against open tech-debt / from-review issues
#   - entries carry source-issue / parent-pr / location / sha markers so the
#     reconcile pass can address them
#   - resolve moves an entry to "Resolved during run"; pool closes when empty
#
# gh_safe is stubbed with a file-backed fake GitHub under $FAKE_GH.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="$BATS_TEST_TMPDIR/state"; mkdir -p "$RITE_STATE_DIR"
  export FAKE_GH="$BATS_TEST_TMPDIR/gh"; mkdir -p "$FAKE_GH"
  echo 100 > "$FAKE_GH/next"
  export RITE_BATCH_ID="batch-test-1"
  unset RITE_LOG_FILE
  source "$RITE_LIB_DIR/utils/followup-pool.sh"
  _diag() { echo "[diag] $*" >> "$BATS_TEST_TMPDIR/diag.log"; }
  ensure_labels_exist() { return 0; }
  gh_safe() { _fake_gh "$@"; }
  set +u; set +o pipefail
}

# Minimal file-backed GitHub: issues/<n>.body, issues/<n>.labels, issues/<n>.state
_fake_gh() {
  local sub="$1 $2"; shift 2
  case "$sub" in
    "issue create")
      local title="" body_file="" labels=""
      while [ $# -gt 0 ]; do case "$1" in
        --title) title="$2"; shift 2;; --body-file) body_file="$2"; shift 2;;
        --label) labels="${labels:+$labels,}$2"; shift 2;; *) shift;; esac; done
      local n; n=$(cat "$FAKE_GH/next"); echo $((n+1)) > "$FAKE_GH/next"
      mkdir -p "$FAKE_GH/issues"
      cp "$body_file" "$FAKE_GH/issues/$n.body"; echo "$title" > "$FAKE_GH/issues/$n.title"
      echo "$labels" > "$FAKE_GH/issues/$n.labels"; echo open > "$FAKE_GH/issues/$n.state"
      [ -n "${FAKE_GH_CREATE_FAILS:-}" ] && return 1
      echo "https://github.com/x/y/issues/$n" ;;
    "issue view")
      local n="$1"; [ -f "$FAKE_GH/issues/$n.body" ] || return 1
      cat "$FAKE_GH/issues/$n.body" ;;   # --json body --jq .body
    "issue edit")
      local n="$1"; shift; while [ $# -gt 0 ]; do case "$1" in --body-file) cp "$2" "$FAKE_GH/issues/$n.body"; shift 2;; *) shift;; esac; done ;;
    "issue close")
      echo closed > "$FAKE_GH/issues/$1.state" ;;
    "issue list")
      # Two callers: pool discovery (--label followup-pool, jq on body marker)
      # and open-issue list (--label tech-debt|from-review → "num:title").
      local label="" jq=""
      while [ $# -gt 0 ]; do case "$1" in --label) label="$2"; shift 2;; --jq) jq="$2"; shift 2;; *) shift;; esac; done
      local f
      for f in "$FAKE_GH"/issues/*.state; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f" .state)
        [ "$(cat "$f")" = open ] || continue
        grep -q "$label" "$FAKE_GH/issues/$n.labels" || continue
        if [[ "$jq" == *contains* ]]; then
          local marker; marker=$(printf '%s' "$jq" | sed 's/.*contains("\(.*\)")).*/\1/')
          grep -qF "$marker" "$FAKE_GH/issues/$n.body" && echo "$n"
        elif [[ "$jq" == *@base64* ]]; then
          printf '%s\t%s\n' "$n" "$(base64 < "$FAKE_GH/issues/$n.body" | tr -d '\n')"
        elif [[ "$jq" == *".[].number"* ]]; then
          echo "$n"
        else
          echo "$n:$(cat "$FAKE_GH/issues/$n.title")"
        fi
      done ;;
    *) return 1 ;;
  esac
}

_body() { cat "$FAKE_GH/issues/$1.body"; }

@test "run id: batch id wins; solo falls back to the log slug" {
  [ "$(followup_pool_run_id)" = "batch-test-1" ]
  unset RITE_BATCH_ID; export RITE_LOG_FILE=/x/.rite/logs/rite-42-20261111-010101.log
  [ "$(followup_pool_run_id)" = "solo-42-20261111-010101" ]
}

@test "pool is created once per run with the run marker and the inbox label, then reused" {
  n1=$(followup_pool_issue); n2=$(followup_pool_issue)
  [ "$n1" = "$n2" ]
  grep -qF "<!-- sharkrite-followup-pool:batch-test-1 -->" "$FAKE_GH/issues/$n1.body"
  [ "$(cat "$FAKE_GH/issues/$n1.labels")" = "followup-pool" ]
  grep -q "FOLLOWUP_POOL_CREATED pool=$n1" "$BATS_TEST_TMPDIR/diag.log"
  [ "$(grep -c "FOLLOWUP_CREATED issue= pr= followup=$n1" "$BATS_TEST_TMPDIR/diag.log")" = "1" ]
  [ -f "$RITE_STATE_DIR/followup-no-inherit-$n1.marker" ]
}

@test "pool is recovered from GitHub when the local state file is gone (crash / other PID)" {
  n1=$(followup_pool_issue)
  rm -f "$RITE_STATE_DIR"/followup-pool-*.num
  n2=$(followup_pool_issue)
  [ "$n1" = "$n2" ]
  [ "$(ls "$FAKE_GH"/issues/*.title | wc -l | tr -d ' ')" = "1" ]
}

@test "pool creation failure returns 1 and leaves no state file (caller falls back)" {
  export FAKE_GH_CREATE_FAILS=1
  run followup_pool_issue
  [ "$status" -eq 1 ]
  [ ! -f "$RITE_STATE_DIR/followup-pool-batch-test-1.num" ]
}

@test "append writes an entry with all four markers above the Resolved section" {
  followup_pool_append 55 42 HIGH Reliability "Retry loop swallows exit 18" "lib/core/local-review.sh:664" abc1234 "Auth failures are retried three times." "Short-circuit on exit 18." "Out of scope for #42"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "appended" ]
  n=$(followup_pool_issue); b=$(_body "$n")
  echo "$b" | grep -q '^### Retry loop swallows exit 18$'
  echo "$b" | grep -qF '<!-- sharkrite-source-issue:42 --><!-- sharkrite-parent-pr:55 --><!-- sharkrite-finding-location:lib/core/local-review.sh:664 --><!-- sharkrite-finding-sha:abc1234 -->'
  echo "$b" | grep -qF -- '- **Suggested fix:** Short-circuit on exit 18.'
  # entry sits in Entries, before the Resolved header
  e=$(echo "$b" | grep -n '^### Retry' | cut -d: -f1); r=$(echo "$b" | grep -n '^## Resolved during run' | cut -d: -f1)
  [ "$e" -lt "$r" ]
  grep -q "FOLLOWUP_POOLED pool=$n issue=42 pr=55" "$BATS_TEST_TMPDIR/diag.log"
}

@test "same-pool dedup: restated finding on the same file records 'Also seen' instead of a second entry" {
  followup_pool_append 55 42 HIGH Reliability "Retry loop swallows exit 18 on auth failure" "lib/core/local-review.sh:664" abc1234 "r1"
  followup_pool_append 56 43 MEDIUM Reliability "Auth failure exit 18 burns all retry attempts in the loop" "lib/core/local-review.sh:700" def5678 "r2"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "pooled-duplicate" ]
  n=$(followup_pool_issue); b=$(_body "$n")
  [ "$(echo "$b" | grep -c '^### ')" = "1" ]
  echo "$b" | grep -qF -- '- **Also seen:** issue #43 via PR #56'
  grep -q "FOLLOWUP_POOL_DEDUP pool=$n issue=43 pr=56 matched=" "$BATS_TEST_TMPDIR/diag.log"
}

@test "same-pool dedup does NOT fire when titles overlap but the location files differ" {
  followup_pool_append 55 42 HIGH Reliability "Retry loop swallows exit 18 on auth failure" "lib/core/local-review.sh:664" abc1234 "r1"
  followup_pool_append 56 43 HIGH Reliability "Retry loop swallows exit 18 on auth failure" "lib/utils/conflict-resolver.sh:718" def5678 "r2"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "appended" ]
  [ "$(_body "$(followup_pool_issue)" | grep -c '^### ')" = "2" ]
}

@test "open-issue dedup: a finding already tracked by an open tech-debt issue is not pooled" {
  mkdir -p "$FAKE_GH/issues"
  echo "Non-retryable provider failures burn all retry attempts" > "$FAKE_GH/issues/7.title"
  echo "tech-debt,from-review" > "$FAKE_GH/issues/7.labels"; echo open > "$FAKE_GH/issues/7.state"; echo x > "$FAKE_GH/issues/7.body"
  followup_pool_append 55 42 HIGH Reliability "Provider failures that are non-retryable still burn retry attempts" "lib/x.sh:1" abc1234 "r"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "tracked:7" ]
  [ "$(_body "$(followup_pool_issue)" | grep -c '^### ')" = "0" ]
  grep -q "FOLLOWUP_POOL_DEDUP .* tracked=7" "$BATS_TEST_TMPDIR/diag.log"
}

@test "open-issue dedup never matches the finding's own source issue (live: #1668 lost two LATER findings)" {
  mkdir -p "$FAKE_GH/issues"
  echo "Flock path silently opens through live symlink lock, breaking cross-strategy exclusion" > "$FAKE_GH/issues/1668.title"
  echo "tech-debt,from-review" > "$FAKE_GH/issues/1668.labels"; echo open > "$FAKE_GH/issues/1668.state"; echo x > "$FAKE_GH/issues/1668.body"
  followup_pool_append 1725 1668 MEDIUM CodeQuality "Worst-case acquire latency silently doubles under cross-strategy contention" "lib/utils/scratchpad-lock.sh, ~line 173" abc1234 "r"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "appended" ]
  [ "$(_body "$(followup_pool_issue)" | grep -c '^### ')" = "1" ]
  ! grep -q "tracked=1668" "$BATS_TEST_TMPDIR/diag.log"
}

@test "open-issue dedup: two shared title words with no location evidence is not a match; three is" {
  mkdir -p "$FAKE_GH/issues"
  echo "Flock path silently opens through live symlink lock, breaking cross-strategy exclusion" > "$FAKE_GH/issues/8.title"
  echo "tech-debt" > "$FAKE_GH/issues/8.labels"; echo open > "$FAKE_GH/issues/8.state"; echo x > "$FAKE_GH/issues/8.body"
  # "lock" + "silently" only (hyphenated words count per part) → appended
  followup_pool_append 55 42 MEDIUM CodeQuality "Lock acquire latency silently doubles under contention" "lib/utils/scratchpad-lock.sh:173" abc1234 "r"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "appended" ]
  # flock + symlink + cross + strategy + exclusion → tracked
  followup_pool_append 55 42 MEDIUM CodeQuality "Flock acquirer follows symlink holder and breaks cross-strategy exclusion" "lib/utils/other.sh:1" abc1234 "r" "" "" k-other
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "tracked:8" ]
}

@test "cross-run dedup is location-aware: same two title words at a different file is a new entry" {
  followup_pool_append 55 42 HIGH Reliability "Retry loop swallows exit 18 on auth failure" "lib/core/local-review.sh:664" abc1234 "r"
  poolA=$(followup_pool_issue)
  export RITE_BATCH_ID="batch-test-2"; rm -f "$RITE_STATE_DIR"/followup-pool-*
  followup_pool_append 70 60 HIGH Reliability "Retry loop ignores auth failure" "lib/core/create-pr.sh:12" ffff111 "r"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "appended" ]
  poolB=$(followup_pool_issue)
  [ "$poolA" != "$poolB" ]
  [ "$(_body "$poolB" | grep -c '^### ')" = "1" ]
}

@test "pool recovery ignores a non-numeric gh result instead of recording it as the pool number" {
  gh_safe() { if [ "$1 $2" = "issue list" ]; then echo '[]'; return 0; fi; _fake_gh "$@"; }
  num=$(followup_pool_issue)
  [ "$num" = "100" ]
  [ "$(cat "$RITE_STATE_DIR/followup-pool-batch-test-1.num")" = "100" ]
}

@test "entries parser returns key, sha, location, title per entry" {
  followup_pool_append 55 42 HIGH Reliability "First finding here" "lib/a.sh:1" aaaaaaa "r" "" "" key-one
  followup_pool_append 55 42 LOW Style "Second different thing" "lib/b.sh:2" bbbbbbb "r" "" "" key-two
  out=$(followup_pool_entries "$(_body "$(followup_pool_issue)")")
  [ "$(echo "$out" | wc -l | tr -d ' ')" = "2" ]
  echo "$out" | grep -qP '^key-one\taaaaaaa\tlib/a.sh:1\tFirst finding here$' || echo "$out" | grep -q "^key-one	aaaaaaa	lib/a.sh:1	First finding here$"
}

@test "entry block returns exactly one entry's markdown" {
  followup_pool_append 55 42 HIGH Reliability "First finding here" "lib/a.sh:1" aaaaaaa "reason one" "" "" key-one
  followup_pool_append 55 42 LOW Style "Second different thing" "lib/b.sh:2" bbbbbbb "reason two" "" "" key-two
  blk=$(followup_pool_entry_block "$(_body "$(followup_pool_issue)")" key-two)
  echo "$blk" | grep -q '^### Second different thing$'
  echo "$blk" | grep -qF 'reason two'
  ! echo "$blk" | grep -qF 'reason one'
}

@test "resolve moves an entry to Resolved and closes the pool when none remain" {
  followup_pool_append 55 42 HIGH Reliability "First finding here" "lib/a.sh:1" aaaaaaa "r" "" "" key-one
  followup_pool_append 55 42 LOW Style "Second different thing" "lib/b.sh:2" bbbbbbb "r" "" "" key-two
  n=$(followup_pool_issue)
  followup_pool_resolve_entry "$n" key-one "aaaaaaa..origin/main"
  b=$(_body "$n")
  [ "$(echo "$b" | grep -c '^### ')" = "1" ]
  echo "$b" | grep -qF -- '- ~~First finding here~~ — resolved in `aaaaaaa..origin/main`'
  [ "$(cat "$FAKE_GH/issues/$n.state")" = open ]
  followup_pool_resolve_entry "$n" key-two "bbbbbbb..origin/main"
  [ "$(cat "$FAKE_GH/issues/$n.state")" = closed ]
  grep -q "FOLLOWUP_POOL_CLOSED pool=$n" "$BATS_TEST_TMPDIR/diag.log"
}

@test "pool unavailable on append returns 1 so the caller can fall back" {
  export FAKE_GH_CREATE_FAILS=1
  run followup_pool_append 55 42 HIGH Reliability "T" "lib/a.sh:1" aaaaaaa "r"
  [ "$status" -eq 1 ]
}

@test "operator toggle: RITE_FOLLOWUP_POOL=false disables the pool; default and any other value enable it" {
  unset RITE_FOLLOWUP_POOL; followup_pool_enabled
  RITE_FOLLOWUP_POOL=true followup_pool_enabled
  run env RITE_FOLLOWUP_POOL=false bash -c "source '$RITE_LIB_DIR/utils/followup-pool.sh'; followup_pool_enabled"
  [ "$status" -ne 0 ]
}

@test "cross-run dedup: a finding already held by an EARLIER run's open pool is not pooled again" {
  # Run A pools a finding, then run B (new RITE_BATCH_ID, fresh state) sees the same finding.
  followup_pool_append 55 42 HIGH Reliability "Retry loop swallows exit 18 on auth failure" "lib/core/local-review.sh:664" abc1234 "r"
  poolA=$(followup_pool_issue)
  export RITE_BATCH_ID="batch-test-2"; rm -f "$RITE_STATE_DIR"/followup-pool-*
  followup_pool_append 70 60 HIGH Reliability "Auth failure exit 18 swallowed by the retry loop" "lib/core/local-review.sh:664" ffff111 "r"
  [ "$FOLLOWUP_POOL_LAST_ACTION" = "tracked:$poolA" ]
  poolB=$(followup_pool_issue)
  [ "$poolA" != "$poolB" ]
  [ "$(_body "$poolB" | grep -c '^### ')" = "0" ]
}

@test "open pools: lists every open pool across runs, excludes closed ones" {
  followup_pool_append 55 42 HIGH Reliability "First finding here" "lib/a.sh:1" aaaaaaa "r" "" "" k1
  poolA=$(followup_pool_issue)
  export RITE_BATCH_ID="batch-test-2"; rm -f "$RITE_STATE_DIR"/followup-pool-*
  followup_pool_append 70 60 LOW Style "Second different thing" "lib/b.sh:2" bbbbbbb "r" "" "" k2
  poolB=$(followup_pool_issue)
  out=$(followup_pool_open_pools | sort -n | tr '\n' ' ')
  [ "$out" = "$poolA $poolB " ]
  echo closed > "$FAKE_GH/issues/$poolA.state"
  [ "$(followup_pool_open_pools | tr -d '\n')" = "$poolB" ]
}
