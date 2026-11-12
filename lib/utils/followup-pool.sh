#!/bin/bash
# lib/utils/followup-pool.sh — Deferred-findings pool (one issue per run)
#
# Replaces one-issue-per-deferred-finding with one pool issue per run that
# every ACTIONABLE_LATER review finding and every dev-session encountered
# issue is appended to. Decided 2026-11-11 after the 27-issue from-review
# queue triage (3 already fixed, 10 pointing at the wrong file, 2 with a
# second finding grafted on) and Dace's freshup report (restated findings
# filed 2-3 times per run).
#
# Contract (see behavioral-design.md → "Deferred-Findings Pool"):
#   - Created lazily at the FIRST deferred finding, never at batch end, so a
#     cap abort, crash or failed slot can never lose what was already pooled.
#   - Dedup BEFORE append: (a) against entries already in the pool this run,
#     (b) against any open tech-debt / from-review issue and the entries of
#     every other open pool — never against the finding's own source issue.
#     Match is location file + ≥2 shared title words; without a location on
#     both sides, ≥3 shared words. Title text alone is never enough.
#   - The pool is an INBOX, not a runnable issue: label `followup-pool`,
#     never `tech-debt`, so `rite --label tech-debt` cannot select it.
#   - Security findings never enter the pool (callers keep the individual
#     issue path for them).
#   - If the pool cannot be created or edited, the caller falls back to its
#     existing individual-issue path; nothing is silently dropped.
#
# Public API:
#   followup_pool_enabled               → 0 unless RITE_FOLLOWUP_POOL=false
#   followup_pool_run_id
#   followup_pool_issue                 → prints pool issue number (creates it)
#   followup_pool_append PR SRC_ISSUE SEVERITY CATEGORY TITLE LOCATION SHA \
#                        REASONING [SUGGESTED_FIX] [DEFER_REASON] [KEY]
#       → 0 appended / already pooled / tracked elsewhere (sets
#         FOLLOWUP_POOL_LAST_ACTION=appended|pooled-duplicate|tracked:<N>)
#         1 pool unavailable (caller must fall back)
#   followup_pool_entries BODY          → TSV: key<TAB>sha<TAB>location<TAB>title
#   followup_pool_open_pools            → every open pool number (all runs)
#   followup_pool_entry_block BODY KEY  → the entry's markdown block
#   followup_pool_resolve_entry POOL KEY RANGE → removes entry, closes pool when empty

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f followup_pool_append >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

_fp_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_fp_self_dir/config.sh"
fi
source "$RITE_LIB_DIR/utils/markers.sh"
# markers.sh is guarded by a function sentinel, so a long-running shell that
# loaded an older copy keeps it and never sees constants added later. Reload it
# when ours are missing (its assignments are idempotent). Live: the 2026-11-11
# batch started 09:53, #1741 landed 15:31, and the batch-end reconcile died
# here under set -u on RITE_MARKER_FOLLOWUP_POOL — no reconcile ran and the
# batch exited 1 after 19 completions (#1758).
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FOLLOWUP_POOL / RITE_MARKER_POOL_ENTRY are marker constants defined in lib/utils/markers.sh; not user config vars.
if [ -z "${RITE_MARKER_FOLLOWUP_POOL:-}" ] || [ -z "${RITE_MARKER_POOL_ENTRY:-}" ]; then
  unset -f rite_markers_loaded
  source "$RITE_LIB_DIR/utils/markers.sh"
fi
source "$RITE_LIB_DIR/utils/lock.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"
source "$RITE_LIB_DIR/utils/labels.sh"
if ! declare -f _diag >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/logging.sh"
fi

FOLLOWUP_POOL_LABEL="${FOLLOWUP_POOL_LABEL:-followup-pool}"
FOLLOWUP_POOL_LAST_ACTION=""

# Module-local aliases for the marker constants (defined in markers.sh, not
# user config — hence the per-line UNDOCUMENTED_RITE_VAR suppressions here,
# once, instead of at every use site below).
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FOLLOWUP_POOL is a marker constant defined in lib/utils/markers.sh; not a user config var.
_FP_M_POOL="$RITE_MARKER_FOLLOWUP_POOL"
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_POOL_ENTRY is a marker constant defined in lib/utils/markers.sh; not a user config var.
_FP_M_ENTRY="$RITE_MARKER_POOL_ENTRY"
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_LOCATION is a marker constant defined in lib/utils/markers.sh; not a user config var.
_FP_M_LOC="$RITE_MARKER_FINDING_LOCATION"
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_SHA is a marker constant defined in lib/utils/markers.sh; not a user config var.
_FP_M_SHA="$RITE_MARKER_FINDING_SHA"
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_SOURCE_ISSUE is a marker constant defined in lib/utils/markers.sh; not a user config var.
_FP_M_SRC="$RITE_MARKER_SOURCE_ISSUE"
# sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_PARENT_PR is a marker constant defined in lib/utils/markers.sh; not a user config var.
_FP_M_PR="$RITE_MARKER_PARENT_PR"

# followup_pool_enabled — operator toggle. RITE_FOLLOWUP_POOL=false restores
# one-issue-per-finding (global config, not a per-run escape hatch). Callers
# check this BEFORE deciding to pool so a disabled pool is silent, not a
# "pool unavailable" warning.
followup_pool_enabled() {
  [ "${RITE_FOLLOWUP_POOL:-true}" != "false" ]
}

# followup_pool_run_id — the identity the pool is keyed on.
# Batch runs: RITE_BATCH_ID (exported by batch-process-issues.sh, inherited by
# every slot). Solo runs: the log slug (unique per invocation) or the PID.
followup_pool_run_id() {
  if [ -n "${RITE_BATCH_ID:-}" ]; then
    echo "$RITE_BATCH_ID"; return 0
  fi
  if [ -n "${RITE_LOG_FILE:-}" ]; then
    local _slug
    _slug=$(basename "$RITE_LOG_FILE" .log)
    echo "solo-${_slug#rite-}"; return 0
  fi
  echo "solo-$$"
}

_followup_pool_state_dir() {
  echo "${RITE_STATE_DIR:-${RITE_PROJECT_ROOT:-$PWD}/${RITE_DATA_DIR:-.rite}/state}"
}

_followup_pool_state_file() {
  echo "$(_followup_pool_state_dir)/followup-pool-$(followup_pool_run_id).num"
}

# _followup_pool_find_open RUN_ID — recover the pool number from GitHub when the
# local state file is gone (crash, cap-resume on another PID). Prints number.
_followup_pool_find_open() {
  local _run="$1" _hit=""
  _hit=$(gh_safe issue list --state open --label "$FOLLOWUP_POOL_LABEL" --limit 50 \
    --json number,body \
    --jq ".[] | select(.body | contains(\"<!-- ${_FP_M_POOL}:${_run} -->\")) | .number" \
    2>/dev/null | head -1 | tr -cd '0-9' || true)
  [ -n "${_hit:-}" ] && echo "$_hit"
}

# followup_pool_issue — get-or-create the run's pool issue. Prints the number.
# Returns 1 when it cannot be created (caller falls back to individual issues).
followup_pool_issue() {
  local _run _state _lock _num=""
  _run=$(followup_pool_run_id)
  _state=$(_followup_pool_state_file)
  _lock="${_state}.lock"
  mkdir -p "$(dirname "$_state")" 2>/dev/null || true

  if ! lock_acquire "$_lock" 30; then
    echo "followup_pool_issue: could not acquire pool lock (30s)" >&2
    return 1
  fi
  trap 'lock_release "$_lock"' RETURN

  if [ -s "$_state" ]; then
    _num=$(head -1 "$_state" | tr -cd '0-9' || true)
    if [ -n "$_num" ]; then echo "$_num"; return 0; fi
  fi

  _num=$(_followup_pool_find_open "$_run" || true)
  if [ -n "${_num:-}" ]; then
    echo "$_num" > "$_state"
    echo "$_num"; return 0
  fi

  local _title _body_file _url
  _title="Deferred findings — run $(date '+%Y-%m-%d %H:%M') (${_run})"
  _body_file=$(mktemp)
  {
    echo "<!-- ${_FP_M_POOL}:${_run} -->"
    echo "Deferred review findings and dev-session encountered issues collected during run \`${_run}\`, started $(date '+%Y-%m-%d %H:%M:%S')."
    echo
    echo "This issue is an **inbox**, not a unit of work: \`rite --label tech-debt\` never selects it. Each entry below is one finding with its source issue, PR, location and the commit it was observed at. Every later run checks this pool before pooling a finding again and re-reconciles it at batch end: entries whose code has since changed are classified, resolved ones move to the bottom, and the pool closes itself when no entries remain. Promote an entry into a real issue by hand if it needs dedicated work."
    echo
    echo "## Entries"
    echo
    echo "## Resolved during run"
    echo
  } > "$_body_file"
  ensure_labels_exist "$FOLLOWUP_POOL_LABEL" >/dev/null 2>&1 || true
  _url=$(gh_safe issue create --title "$_title" --body-file "$_body_file" \
    --label "$FOLLOWUP_POOL_LABEL" 2>/dev/null || true)
  rm -f "$_body_file"
  _num=$(echo "${_url:-}" | grep -oE '[0-9]+$' || true)
  if [ -z "${_num:-}" ]; then
    echo "followup_pool_issue: gh issue create failed for run ${_run}" >&2
    return 1
  fi
  echo "$_num" > "$_state"
  # No-inherit marker: the pool is never a dev target, but keep parity with the
  # other follow-up creation sites so a stray `rite <pool>` cannot inherit an
  # integration-branch target.
  touch "$(_followup_pool_state_dir)/followup-no-inherit-${_num}.marker" 2>/dev/null || true
  _diag "FOLLOWUP_POOL_CREATED pool=${_num} run=${_run}"
  # Counted once by the batch reporter's "Issues Created" line and discovered
  # by the batch-end reconcile pass, which routes pool issues to the per-entry
  # path on the pool marker.
  _diag "FOLLOWUP_CREATED issue= pr= followup=${_num}"
  echo "$_num"
}

# _followup_pool_title_words TITLE — lowercase words longer than 3 chars, one per line.
_followup_pool_title_words() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | awk 'length($0) > 3' | sort -u
}

# _followup_pool_titles_match A B [MIN] — 0 when the two titles share at least
# MIN significant words (default 2). Callers pass 3 when there is no location
# evidence on either side: two shared words alone ("silently", "cross-strategy")
# is how #1668's own deferred findings were mistaken for #1668 (2026-11-11).
_followup_pool_titles_match() {
  local _shared _min="${3:-2}"
  _shared=$(comm -12 <(_followup_pool_title_words "$1") <(_followup_pool_title_words "$2") | wc -l | tr -d ' ' || true)
  [ "${_shared:-0}" -ge "$_min" ]
}

# _followup_pool_split_tsv LINE — set _f1 _f2 _f3 _f4 from a 4-column TSV line.
# `IFS=$'\t' read` collapses adjacent tabs (tab is IFS whitespace), so an empty
# sha or location column would shift the title left; split explicitly instead.
_followup_pool_split_tsv() {
  local _l="${1:-}"
  _f1="${_l%%$'\t'*}"; _l="${_l#*$'\t'}"
  _f2="${_l%%$'\t'*}"; _l="${_l#*$'\t'}"
  _f3="${_l%%$'\t'*}"
  _f4="${_l#*$'\t'}"
}

# _followup_pool_loc_file LOCATION — the file part of "path:line — text".
_followup_pool_loc_file() {
  printf '%s' "${1:-}" | sed -E 's/[[:space:]].*//; s/:[0-9]+.*$//' || true
}

# followup_pool_entries BODY — TSV of key, sha, location, title for each entry.
followup_pool_entries() {
  printf '%s\n' "${1:-}" | awk -v em="${_FP_M_ENTRY}" \
    -v sm="${_FP_M_SHA}" -v lm="${_FP_M_LOC}" '
    /^### / { title=$0; sub(/^### /, "", title); next }
    index($0, "<!-- " em ":") {
      key=$0; sub(".*<!-- " em ":", "", key); sub(/ -->.*/, "", key)
      sha=""; if (index($0, "<!-- " sm ":")) { sha=$0; sub(".*<!-- " sm ":", "", sha); sub(/ -->.*/, "", sha) }
      loc=""; if (index($0, "<!-- " lm ":")) { loc=$0; sub(".*<!-- " lm ":", "", loc); sub(/ -->.*/, "", loc) }
      printf "%s\t%s\t%s\t%s\n", key, sha, loc, title
    }'
}

# followup_pool_entry_block BODY KEY — the markdown block of one entry.
followup_pool_entry_block() {
  printf '%s\n' "${1:-}" | awk -v em="${_FP_M_ENTRY}" -v key="${2:-}" '
    /^### / { if (inb) exit; hdr=$0; next }
    /^## /  { if (inb) exit; hdr=""; next }
    index($0, "<!-- " em ":" key " -->") { inb=1; print hdr }
    inb { print }'
}

# _followup_pool_open_issue_list — cached list of open candidate issues (one
# fetch per run) for the against-open-issues dedup. One line per candidate:
# num<TAB>location-file<TAB>title. Plain tech-debt / from-review issues have
# an empty location file; entries of other open pools carry theirs.
_followup_pool_open_issue_list() {
  local _cache
  _cache="$(_followup_pool_state_file).openissues"
  if [ ! -f "$_cache" ]; then
    local _this_pool _pb _pn _el
    _this_pool=$(head -1 "$(_followup_pool_state_file)" 2>/dev/null | tr -cd '0-9' || true)
    {
      {
        gh_safe issue list --state open --label tech-debt --limit 200 --json number,title \
          --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true
        gh_safe issue list --state open --label from-review --limit 200 --json number,title \
          --jq '.[] | "\(.number):\(.title)"' 2>/dev/null || true
      } | awk -F: 'NF >= 2 && $1 ~ /^[0-9]+$/ { n=$1; sub(/^[0-9]+:/, ""); printf "%s\t\t%s\n", n, $0 }'
      # Entries of OTHER open pools (earlier runs): a finding already pooled last
      # night must not be pooled again tonight. Emitted with the entry's location file.
      gh_safe issue list --state open --label "$FOLLOWUP_POOL_LABEL" --limit 50 --json number,body \
        --jq '.[] | "\(.number)\t\(.body | @base64)"' 2>/dev/null | \
      while IFS=$'\t' read -r _pn _pb; do
        [ -z "${_pn:-}" ] && continue
        [ "$_pn" = "${_this_pool:-}" ] && continue
        followup_pool_entries "$(printf '%s' "$_pb" | base64 --decode 2>/dev/null || true)" | \
          while IFS= read -r _el; do
            [ -z "${_el:-}" ] && continue
            local _f1 _f2 _f3 _f4
            _followup_pool_split_tsv "$_el"
            printf '%s\t%s\t%s\n' "$_pn" "$(_followup_pool_loc_file "$_f3")" "$_f4"
          done
      done || true
    } | sort -u > "$_cache" 2>/dev/null || true
  fi
  cat "$_cache" 2>/dev/null || true
}

# followup_pool_append — see header. Returns 1 only when the pool is unavailable.
followup_pool_append() {
  local _pr="${1:-}" _src="${2:-}" _sev="${3:-MEDIUM}" _cat="${4:-}" _title="${5:-}"
  local _loc="${6:-}" _sha="${7:-}" _reason="${8:-}" _fix="${9:-}" _defer="${10:-}" _key="${11:-}"
  local _bf=""
  FOLLOWUP_POOL_LAST_ACTION=""

  local _num
  _num=$(followup_pool_issue) || return 1

  if [ -z "$_key" ]; then
    _key=$(printf '%s' "${_src:-0}-${_title}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-60 || true)
  fi

  local _state _lock
  _state=$(_followup_pool_state_file)
  _lock="${_state}.append.lock"
  if ! lock_acquire "$_lock" 30; then
    echo "followup_pool_append: could not acquire append lock (30s)" >&2
    return 1
  fi
  trap 'lock_release "$_lock"' RETURN

  local _body
  _body=$(gh_safe issue view "$_num" --json body --jq '.body' 2>/dev/null || true)
  if [ -z "${_body:-}" ]; then
    echo "followup_pool_append: could not read pool #${_num}" >&2
    return 1
  fi

  # (a) Dedup within the pool: same location file + ≥2 shared title words, or
  #     the identical key. A duplicate records where else it was seen.
  local _loc_file _line _ekey _esha _eloc _etitle _f1 _f2 _f3 _f4
  _loc_file=$(_followup_pool_loc_file "$_loc")
  while IFS= read -r _line; do
    [ -z "${_line:-}" ] && continue
    _followup_pool_split_tsv "$_line"
    _ekey="$_f1"; _esha="$_f2"; _eloc="$_f3"; _etitle="$_f4"
    local _dup=false
    if [ "$_ekey" = "$_key" ]; then
      _dup=true
    else
      local _eloc_file
      _eloc_file=$(_followup_pool_loc_file "$_eloc")
      if [ -n "$_loc_file" ] && [ "$_loc_file" = "$_eloc_file" ]; then
        _followup_pool_titles_match "$_title" "$_etitle" 2 && _dup=true
      elif [ -z "$_loc_file" ] || [ -z "$_eloc_file" ]; then
        _followup_pool_titles_match "$_title" "$_etitle" 3 && _dup=true
      fi
    fi
    if [ "$_dup" = true ]; then
      local _seen="- **Also seen:** issue #${_src:-?} via PR #${_pr:-?}"
      if ! printf '%s\n' "$_body" | grep -qF "$_seen"; then
        _body=$(printf '%s\n' "$_body" | awk -v em="${_FP_M_ENTRY}" -v key="$_ekey" -v seen="$_seen" '
          index($0, "<!-- " em ":" key " -->") { inb=1 }
          inb && (/^### / || /^## / || /^$/) && !done { print seen; done=1; inb=0 }
          { print }' || true)
        _bf=$(mktemp); printf '%s\n' "$_body" > "$_bf"
        gh_safe issue edit "$_num" --body-file "$_bf" >/dev/null 2>&1 || true
        rm -f "$_bf"
      fi
      FOLLOWUP_POOL_LAST_ACTION="pooled-duplicate"
      _diag "FOLLOWUP_POOL_DEDUP pool=${_num} issue=${_src} pr=${_pr} matched=${_ekey}"
      return 0
    fi
  done <<< "$(followup_pool_entries "$_body")"

  # (b) Dedup against open issues: an already-tracked finding is not re-pooled.
  #     The SOURCE issue is never a match: a PR's deferred findings naturally
  #     share words with the issue it closes, and that issue closes on merge —
  #     a "tracked" verdict there is a silent discard (live: #1668, 2026-11-11).
  local _oline _onum _oloc _otitle
  while IFS= read -r _oline; do
    [ -z "${_oline:-}" ] && continue
    case "$_oline" in
      *$'\t'*) _onum="${_oline%%$'\t'*}"; _oloc="${_oline#*$'\t'}"; _otitle="${_oloc#*$'\t'}"; _oloc="${_oloc%%$'\t'*}" ;;
      *) _onum="${_oline%%:*}"; _oloc=""; _otitle="${_oline#*:}" ;;   # pre-TSV cache line
    esac
    [ "$_onum" = "$_num" ] && continue
    [ -n "${_src:-}" ] && [ "$_onum" = "$_src" ] && continue
    local _omatch=false
    if [ -n "$_loc_file" ] && [ "$_loc_file" = "${_oloc:-}" ]; then
      _followup_pool_titles_match "$_title" "$_otitle" 2 && _omatch=true
    elif [ -z "$_loc_file" ] || [ -z "${_oloc:-}" ]; then
      _followup_pool_titles_match "$_title" "$_otitle" 3 && _omatch=true
    fi
    if [ "$_omatch" = true ]; then
      FOLLOWUP_POOL_LAST_ACTION="tracked:${_onum}"
      _diag "FOLLOWUP_POOL_DEDUP pool=${_num} issue=${_src} pr=${_pr} tracked=${_onum}"
      return 0
    fi
  done <<< "$(_followup_pool_open_issue_list)"

  # Append the entry just above "## Resolved during run".
  local _markers="<!-- ${_FP_M_ENTRY}:${_key} -->"
  [ -n "$_src" ] && _markers="${_markers}<!-- ${_FP_M_SRC}:${_src} -->"
  [ -n "$_pr" ]  && _markers="${_markers}<!-- ${_FP_M_PR}:${_pr} -->"
  if [ -n "$_loc" ] && printf '%s' "$_loc" | grep -qE '^[A-Za-z0-9 /._:#()-]+$'; then
    _markers="${_markers}<!-- ${_FP_M_LOC}:${_loc} -->"
  fi
  [ -n "$_sha" ] && _markers="${_markers}<!-- ${_FP_M_SHA}:${_sha} -->"

  local _entry
  _entry="### ${_title}
${_markers}
- **Severity:** ${_sev} · **Category:** ${_cat:-unspecified} · **From:** issue #${_src:-?} via PR #${_pr:-?}"
  [ -n "$_loc" ]    && _entry="${_entry}
- **Location:** \`${_loc}\`"
  [ -n "$_reason" ] && _entry="${_entry}
- **Finding:** ${_reason}"
  [ -n "$_fix" ]    && _entry="${_entry}
- **Suggested fix:** ${_fix}"
  [ -n "$_defer" ]  && _entry="${_entry}
- **Why deferred:** ${_defer}"

  # Insert above "## Resolved during run" (pure bash: BSD awk rejects a
  # multi-line -v string, the same trap as the 2026-11-11 issue-body edits).
  local _new_body _hdr="## Resolved during run"
  if [ "${_body#*"$_hdr"}" != "$_body" ]; then
    _new_body="${_body%%"$_hdr"*}${_entry}

${_hdr}${_body#*"$_hdr"}"
  else
    _new_body="${_body}

${_entry}"
  fi
  _bf=$(mktemp); printf '%s\n' "$_new_body" > "$_bf"
  if ! gh_safe issue edit "$_num" --body-file "$_bf" >/dev/null 2>&1; then
    rm -f "$_bf"
    echo "followup_pool_append: gh issue edit failed for pool #${_num}" >&2
    return 1
  fi
  rm -f "$_bf"
  FOLLOWUP_POOL_LAST_ACTION="appended"
  _diag "FOLLOWUP_POOLED pool=${_num} issue=${_src} pr=${_pr} key=${_key}"
  return 0
}

# followup_pool_open_pools — numbers of every open pool issue (all runs), one
# per line. The batch-end reconcile sweeps all of them, not only this run's,
# so an entry pooled on an earlier night is re-checked every night until its
# code changes and it resolves — the pool is cleaned at the end of every run.
followup_pool_open_pools() {
  gh_safe issue list --state open --label "$FOLLOWUP_POOL_LABEL" --limit 50 \
    --json number --jq '.[].number' 2>/dev/null || true
}

# followup_pool_resolve_entry POOL KEY RANGE — move an entry to "Resolved during
# run" (title struck through, commit range noted). Closes the pool when no
# entries remain. Used by the batch-end reconcile pass.
followup_pool_resolve_entry() {
  local _num="${1:-}" _key="${2:-}" _range="${3:-}"
  local _body _title _new
  _body=$(gh_safe issue view "$_num" --json body --jq '.body' 2>/dev/null || true)
  [ -n "${_body:-}" ] || return 1
  _title=$(followup_pool_entries "$_body" | awk -F'\t' -v k="$_key" '$1==k {print $4; exit}' || true)
  [ -n "${_title:-}" ] || return 1
  _new=$(printf '%s\n' "$_body" | awk -v em="${_FP_M_ENTRY}" -v key="$_key" '
    /^### / { if (inb) { inb=0 } ; hdr=$0; held=1; next }
    /^## /  { if (held && !inb) print hdr; held=0; inb=0; print; next }
    index($0, "<!-- " em ":" key " -->") { inb=1; held=0; next }
    inb { next }
    { if (held) { print hdr; held=0 } print }
    END { if (held) print hdr }' || true)
  _new=$(printf '%s\n' "$_new" | awk -v line="- ~~${_title}~~ — resolved in \`${_range}\`" '
    { print } /^## Resolved during run/ { print line }' || true)
  local _bf; _bf=$(mktemp); printf '%s\n' "$_new" > "$_bf"
  gh_safe issue edit "$_num" --body-file "$_bf" >/dev/null 2>&1 || { rm -f "$_bf"; return 1; }
  rm -f "$_bf"
  if [ -z "$(followup_pool_entries "$_new")" ]; then
    gh_safe issue close "$_num" --comment "Every pooled finding was resolved by later work in this run — closing the pool." >/dev/null 2>&1 || true
    _diag "FOLLOWUP_POOL_CLOSED pool=${_num}"
  fi
  return 0
}
