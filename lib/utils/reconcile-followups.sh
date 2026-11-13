#!/bin/bash
# lib/utils/reconcile-followups.sh
# Batch-end follow-up reconciliation pass.
#
# Two-tier design: deterministic filter first, one LLM call per changed finding.
#
# Tier 1 — Deterministic filter (zero LLM calls):
#   For each follow-up carrying both RITE_MARKER_FINDING_SHA and
#   RITE_MARKER_FINDING_LOCATION, compute whether the file at the location
#   changed between finding-sha and the target-branch HEAD.  Unchanged
#   findings are left untouched — no network writes, no LLM call.
#
# Tier 2 — Judgment (one call per changed finding):
#   Provider: provider_resolve_model triage (never bare "").
#   Returns compact JSON: {"verdict":"resolved|partially-resolved|still-open","reason":"..."}
#   resolved → close (or comment-only for security-labeled issues)
#   partially-resolved → annotate comment, leave open
#   still-open → remove needs-re-triage label, leave open (batch verified it)
#
# Security guard: issues labeled "security" are NEVER auto-closed. A resolved
# verdict posts the evidence comment and leaves the issue open for human close.
# This guard applies ONLY here — it does not modify v1's per-merge labeling.
#
# Pre-#1547 issues missing both markers are skipped silently (no noise for
# historical follow-ups with no anchor data).
#
# Provider degradation: when a cap/auth error fires, the pass lists remaining
# unclassified candidates in stderr (operator warning) and emits the diag with
# actual partial counts.  Nothing is closed on the deterministic signal alone
# (a changed file does not mean a resolved finding).
#
# Entry point: reconcile_batch_followups()
# Requires: _batch_followups_created (batch-reporter.sh), gh_safe (gh-retry.sh),
#   provider_resolve_model/provider_run_prompt (provider-interface.sh),
#   RITE_PROJECT_ROOT, RITE_MARKER_FINDING_SHA, RITE_MARKER_FINDING_LOCATION,
#   RITE_MARKER_PARENT_PR (all from their respective source files).

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f reconcile_batch_followups >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# _get_code_region FILE LOC_RAW
#
# Return ±25 lines of FILE around the line number encoded in LOC_RAW.
# LOC_RAW examples: "lib/core/foo.sh:42", "lib/core/foo.sh", "foo.sh:120-130".
# When no line number is extractable, returns the first 60 lines of the file.
# Returns empty string when the file does not exist (deleted by the fix).
# ---------------------------------------------------------------------------
# Deferred-findings pool: pool issues are reconciled per entry.
source "$RITE_LIB_DIR/utils/followup-pool.sh"

_get_code_region() {
  local _file="$1"
  local _loc_raw="$2"
  local _abs_file="${RITE_PROJECT_ROOT}/${_file}"

  [ -f "$_abs_file" ] || return 0

  local _lineno=""
  _lineno=$(echo "$_loc_raw" | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)

  if [ -z "${_lineno:-}" ]; then
    head -60 "$_abs_file" 2>/dev/null || true
    return 0
  fi

  local _start _end _total
  _total=$(wc -l < "$_abs_file" 2>/dev/null || true)
  _start=$(( _lineno - 25 ))
  _end=$(( _lineno + 25 ))
  [ "$_start" -lt 1 ] && _start=1
  [ "$_end" -gt "$_total" ] && _end="$_total"

  sed -n "${_start},${_end}p" "$_abs_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _classify_finding ISSUE_NUM BODY CURRENT_REGION MODEL
#
# Ask the triage model whether the finding is resolved / partially-resolved /
# still-open given the current code region.
#
# Stdout: one of resolved, partially-resolved, still-open (empty on parse error)
# Exit:   0 = success, 5 = provider cap, 18 = auth failure, 1 = other error
# ---------------------------------------------------------------------------
_classify_finding() {
  local _issue_num="$1"
  local _body="$2"
  local _region="$3"
  local _model="$4"

  local _region_head=""
  _region_head=$(echo "$_region" | head -c 4000 || true)

  local _body_head=""
  _body_head=$(echo "$_body" | head -c 2000 || true)

  local _prompt
  # shellcheck disable=SC2016
  _prompt="You are a code-review RECONCILER. A follow-up issue was filed for a finding. Determine if the current code resolves, partially resolves, or still exposes the finding.

FINDING (issue #${_issue_num} body, first 2000 chars):
${_body_head}

CURRENT CODE REGION (the file location the finding pointed at):
${_region_head}

Output ONLY compact JSON: {\"verdict\":\"resolved|partially-resolved|still-open\",\"reason\":\"<=10 words\"}.
Definitions:
  resolved — the code change directly addresses the finding; a reviewer would close the issue.
  partially-resolved — the code changed but the vulnerable surface described still exists.
  still-open — the relevant code is unchanged or the change is unrelated to the finding."

  local _resp _exit=0
  _resp=$(provider_run_prompt "$_prompt" "$_model" "true" 2>/dev/null) || _exit=$?

  if [ "$_exit" -ne 0 ]; then
    return "$_exit"
  fi

  local _json _verdict
  _json=$(echo "$_resp" | grep -oE '\{[^{}]*"verdict"[^{}]*\}' | head -1 || true)
  if [ -z "${_json:-}" ]; then
    return 1
  fi
  if ! echo "$_json" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  _verdict=$(echo "$_json" | jq -r '.verdict // ""' 2>/dev/null || true)
  case "${_verdict:-}" in
    resolved|partially-resolved|still-open)
      printf '%s' "$_verdict"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _do_close_or_comment ISSUE_NUM LABELS RANGE
#
# Security guard: when issue carries "security" label, post evidence comment
# only and leave open for human close.  Otherwise close with a comment citing
# the commit range that resolved it.
# ---------------------------------------------------------------------------
_do_close_or_comment() {
  local _issue_num="$1"
  local _labels="$2"
  local _range="$3"

  if echo "${_labels:-}" | tr ' ' '\n' | grep -qx "security"; then
    local _body_text
    _body_text="**Reconciliation note (auto):** Triage classifier assessed this finding as resolved by commits in range \`${_range}\`. The \`security\` label prevents auto-close — please review the commit range and close manually if satisfied."
    local _rc=0
    gh_safe issue comment "$_issue_num" --body "$_body_text" >/dev/null 2>&1 || _rc=$?
    if [ "$_rc" -ne 0 ]; then
      print_warning "reconcile: could not comment on security issue #${_issue_num} (exit ${_rc})"
    fi
    return 0
  fi

  local _close_body
  _close_body="**Reconciliation (auto):** Triage classifier assessed this finding as resolved by commits in range \`${_range}\`. Closing — re-open if the fix is incomplete."
  local _rc=0
  gh_safe issue comment "$_issue_num" --body "$_close_body" >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    print_warning "reconcile: could not comment on issue #${_issue_num} before close (exit ${_rc})"
  fi
  local _close_rc=0
  gh_safe issue close "$_issue_num" >/dev/null 2>&1 || _close_rc=$?
  if [ "$_close_rc" -ne 0 ]; then
    print_warning "reconcile: could not close issue #${_issue_num} (exit ${_close_rc})"
  fi
}

# ---------------------------------------------------------------------------
# _do_annotate ISSUE_NUM TARGET_REF
#
# Post a comment stating the finding is partially resolved — what code changed
# but the described surface remains.  Leave issue open.
# ---------------------------------------------------------------------------
_do_annotate() {
  local _issue_num="$1"
  local _target_ref="$2"

  local _body_text
  _body_text="**Reconciliation note (auto):** Code at the finding location changed (as of \`${_target_ref}\`), but triage classifier found the described surface partially remains. Leaving open — verify and update scope if needed."
  local _rc=0
  gh_safe issue comment "$_issue_num" --body "$_body_text" >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    print_warning "reconcile: could not annotate issue #${_issue_num} (exit ${_rc})"
  fi
}

# ---------------------------------------------------------------------------
# _do_verify ISSUE_NUM
#
# The batch confirmed this finding is still open. Remove the needs-re-triage
# label (the per-merge v1 breadcrumb) so it does not accumulate stale labels.
# ---------------------------------------------------------------------------
_do_verify() {
  local _issue_num="$1"

  local _rc=0
  gh_safe issue edit "$_issue_num" --remove-label "needs-re-triage" \
    >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    print_warning "reconcile: could not remove needs-re-triage from #${_issue_num} (exit ${_rc})"
  fi
}

# ---------------------------------------------------------------------------
# reconcile_batch_followups
#
# Main entry point. Called from batch-process-issues.sh after all merges.
# Requires RITE_PROJECT_ROOT, RITE_LOG_FILE (via _batch_followups_created),
# and the provider interface already loaded.
#
# Opt-out: RITE_BATCH_RECONCILE=false skips the entire pass.
# ---------------------------------------------------------------------------
# _reconcile_pool POOL_NUM BODY TARGET_REF MODEL
# Per-entry reconcile for a deferred-findings pool issue. Each entry carries
# its own finding-sha + location markers; an entry whose file changed since
# its sha is classified exactly like a standalone follow-up, and a `resolved`
# verdict moves it to "Resolved during run" (the pool closes itself when no
# entries remain). Prints "closed annotated verified skipped providerok" so the
# caller can fold the counts into the batch totals.
# _reconcile_pool_skip POOL KEY REASON [FILE] — count one skipped pool entry
# (in the caller's _skipped) and say why, one diag line per entry. Dace asked
# twice what "skipped=38" meant (freshup, 2026-11-12); the per-entry reason is
# the answer. "unchanged" is the healthy case: the finding's file has not
# changed since the finding was recorded, so there is nothing to re-classify.
_reconcile_pool_skip() {
  _skipped=$((_skipped+1))
  declare -f _diag >/dev/null 2>&1 && \
    _diag "FOLLOWUP_RECONCILE_SKIP pool=${1:-} entry=${2:-} reason=${3:-unknown}${4:+ file=$4}"
  return 0
}

_reconcile_pool() {
  local _pool="$1" _body="$2" _target_ref="$3" _model="$4"
  local _closed=0 _annotated=0 _verified=0 _skipped=0 _ok=1 _unchanged=0
  local _key _sha _loc _title _file _changed _region _block _verdict _rc _f1 _f2 _f3 _f4 _eline
  # Explicit split: IFS=$'\t' read collapses an empty sha/location column.
  while IFS= read -r _eline; do
    [ -z "${_eline:-}" ] && continue
    _followup_pool_split_tsv "$_eline"
    _key="$_f1"; _sha="$_f2"; _loc="$_f3"; _title="$_f4"
    _file=$(_followup_pool_loc_file "${_loc:-}")
    if [ -z "${_sha:-}" ]; then _reconcile_pool_skip "$_pool" "$_key" no_sha; continue; fi
    if [ -z "${_file:-}" ]; then _reconcile_pool_skip "$_pool" "$_key" no_location; continue; fi
    if ! git -C "$RITE_PROJECT_ROOT" cat-file -e "${_sha}^{commit}" 2>/dev/null; then
      _reconcile_pool_skip "$_pool" "$_key" sha_unreachable; continue
    fi
    _changed=$(git -C "$RITE_PROJECT_ROOT" diff --name-only "${_sha}..${_target_ref}" -- 2>/dev/null || true)
    if ! grep -qxF "$_file" <<< "${_changed:-}"; then
      # Not a skip in any meaningful sense: the code the finding names has not
      # changed since it was recorded, so it is still open by construction.
      _unchanged=$((_unchanged+1)); _reconcile_pool_skip "$_pool" "$_key" unchanged "$_file"; continue
    fi
    if [ "$_ok" -eq 0 ]; then _reconcile_pool_skip "$_pool" "$_key" provider_unavailable; continue; fi
    _region=$(_get_code_region "$_file" "$_loc" 2>/dev/null || true)
    _block=$(followup_pool_entry_block "$_body" "$_key")
    _rc=0
    _verdict=$(_classify_finding "${_pool}/${_key}" "$_block" "$_region" "$_model") || _rc=$?
    if [ "$_rc" -ne 0 ]; then
      if [ "$_rc" -eq 5 ] || [ "$_rc" -eq 18 ]; then _ok=0; fi
      _reconcile_pool_skip "$_pool" "$_key" "classify_failed_rc${_rc}"; continue
    fi
    case "${_verdict:-}" in
      resolved)
        if followup_pool_resolve_entry "$_pool" "$_key" "${_sha}..${_target_ref}"; then
          _closed=$((_closed+1))
          # Body changed on GitHub — re-read so later entries are addressed in the new body.
          _body=$(gh_safe issue view "$_pool" --json body --jq '.body' 2>/dev/null || echo "$_body")
        else
          _reconcile_pool_skip "$_pool" "$_key" resolve_write_failed
        fi ;;
      partially-resolved) _annotated=$((_annotated+1)) ;;
      still-open)         _verified=$((_verified+1)) ;;
      *)                  _reconcile_pool_skip "$_pool" "$_key" "unclassified_${_verdict:-empty}" ;;
    esac
  done <<< "$(followup_pool_entries "$_body")"
  echo "$_closed $_annotated $_verified $_skipped $_ok $_unchanged"
}

reconcile_batch_followups() {
  if [ "${RITE_BATCH_RECONCILE:-true}" = "false" ]; then
    return 0
  fi

  local _fu_list=""
  _fu_list=$(_batch_followups_created 2>/dev/null || true)

  # Every open deferred-findings pool joins the candidate list, not only the
  # one this run created: a pool from an earlier run is re-reconciled at the
  # end of every later run until its entries resolve and it closes itself.
  local _open_pools=""
  if declare -f followup_pool_open_pools >/dev/null 2>&1; then
    _open_pools=$(followup_pool_open_pools 2>/dev/null || true)
  fi
  if [ -n "${_open_pools:-}" ]; then
    _fu_list=$(printf '%s\n%s\n' "${_fu_list:-}" "$_open_pools" | grep -E '^[0-9]+$' | sort -un || true)
  fi

  if [ -z "${_fu_list:-}" ]; then
    declare -f _diag >/dev/null 2>&1 && \
      _diag "FOLLOWUP_RECONCILED closed=0 annotated=0 verified=0 skipped=0"
    return 0
  fi

  local _candidate_count
  _candidate_count=$(printf '%s\n' "$_fu_list" | grep -c . || true)
  print_step "Batch-end follow-up reconciliation (${_candidate_count} candidates)"

  local _target_branch="${RITE_TARGET_BRANCH:-main}"
  local _target_ref="origin/${_target_branch}"

  # Resolve the triage model once — never pass "" (Rule 31).
  local _triage_model=""
  _triage_model=$(provider_resolve_model "triage") || _triage_model=""
  if [ -z "${_triage_model:-}" ]; then
    print_warning "reconcile: provider_resolve_model failed — skipping classification pass"
    declare -f _diag >/dev/null 2>&1 && \
      _diag "FOLLOWUP_RECONCILED closed=0 annotated=0 verified=0 skipped=${_candidate_count}"
    return 0
  fi

  # Provider availability flag: set to false on cap/auth error.
  local _provider_ok=true
  local _provider_unavail_list=""

  local _closed=0 _annotated=0 _verified=0 _skipped=0 _pool_unchanged=0

  local _fu_num=""
  while IFS= read -r _fu_num; do
    [ -z "${_fu_num:-}" ] && continue

    # ── Fetch issue body and labels ──────────────────────────────────────────
    local _gh_resp=""
    _gh_resp=$(gh_safe issue view "$_fu_num" \
      --json body,labels \
      --jq '{body:.body, labels:[.labels[].name | ascii_downcase]}' \
      2>/dev/null || true)

    if [ -z "${_gh_resp:-}" ]; then
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    local _issue_body=""
    _issue_body=$(echo "$_gh_resp" | jq -r '.body // ""' 2>/dev/null || true)
    local _issue_labels=""
    _issue_labels=$(echo "$_gh_resp" | jq -r '.labels | join(" ")' 2>/dev/null || true)

    # ── Deferred-findings pool: reconcile per entry, not per issue ──────────
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FOLLOWUP_POOL is a marker constant defined in lib/utils/markers.sh; not a user config var.
    if grep -qE "${RITE_MARKER_FOLLOWUP_POOL}:[A-Za-z0-9._-]+" <<< "${_issue_body:-}"; then
      if [ "$_provider_ok" = "false" ]; then
        _provider_unavail_list="${_provider_unavail_list}#${_fu_num} "
        _skipped=$(( _skipped + 1 ))
        continue
      fi
      local _pool_counts _pc _pa _pv _ps _pok _pu
      _pool_counts=$(_reconcile_pool "$_fu_num" "$_issue_body" "$_target_ref" "$_triage_model")
      read -r _pc _pa _pv _ps _pok _pu <<< "$_pool_counts"
      _closed=$(( _closed + ${_pc:-0} )); _annotated=$(( _annotated + ${_pa:-0} ))
      _verified=$(( _verified + ${_pv:-0} )); _skipped=$(( _skipped + ${_ps:-0} ))
      _pool_unchanged=$(( _pool_unchanged + ${_pu:-0} ))
      if [ "${_pok:-1}" = "0" ]; then
        _provider_ok=false
        _provider_unavail_list="${_provider_unavail_list}#${_fu_num} "
        print_warning "reconcile: provider unavailable during pool #${_fu_num} — remaining entries need manual re-triage"
      fi
      continue
    fi

    # ── Tier 1: deterministic filter — both markers required ─────────────────
    # Format-anchored guards (BARE_MARKER_GREP rule): require [0-9a-f]+ / [^-]+
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_SHA is a marker constant defined in lib/utils/markers.sh; not a user config var; must keep RITE_ prefix for naming consistency with the rest of the marker set.
    if ! grep -qE "${RITE_MARKER_FINDING_SHA}:[0-9a-f]{7,}" <<< "${_issue_body:-}"; then
      _skipped=$(( _skipped + 1 ))
      continue
    fi
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_LOCATION is a marker constant defined in lib/utils/markers.sh; not a user config var; must keep RITE_ prefix for naming consistency with the rest of the marker set.
    if ! grep -qE "${RITE_MARKER_FINDING_LOCATION}:[^-]" <<< "${_issue_body:-}"; then
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    # Extract SHA — suppression comments must immediately precede the flagged lines.
    local _finding_sha=""
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_SHA is a marker constant defined in lib/utils/markers.sh; not a user config var; must keep RITE_ prefix for naming consistency with the rest of the marker set.
    local _sha_pat="${RITE_MARKER_FINDING_SHA}:[0-9a-f]{7,}"
    _finding_sha=$(echo "$_issue_body" | grep -oE "$_sha_pat" | head -1 | cut -d: -f2 || true)
    _finding_sha="${_finding_sha:-}"

    # Extract location value (may contain spaces; strip up to closing -->).
    local _loc_line=""
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_LOCATION is a marker constant defined in lib/utils/markers.sh; not a user config var; must keep RITE_ prefix for naming consistency with the rest of the marker set.
    local _loc_pat="${RITE_MARKER_FINDING_LOCATION}:"
    _loc_line=$(echo "$_issue_body" | grep "$_loc_pat" | head -1 || true)
    local _finding_loc_raw=""
    # sharkrite-lint disable UNDOCUMENTED_RITE_VAR - Reason: RITE_MARKER_FINDING_LOCATION is a marker constant defined in lib/utils/markers.sh; not a user config var; must keep RITE_ prefix for naming consistency with the rest of the marker set.
    local _loc_strip_pat="${RITE_MARKER_FINDING_LOCATION}"
    _finding_loc_raw=$(echo "$_loc_line" | sed "s/.*${_loc_strip_pat}://; s/[[:space:]]*-->.*//" || true)
    _finding_loc_raw="${_finding_loc_raw:-}"

    # Strip line number from location to get the file path
    local _finding_file=""
    _finding_file=$(echo "$_finding_loc_raw" | sed 's/:[0-9]*$//' || true)
    _finding_file="${_finding_file:-}"

    if [ -z "${_finding_sha:-}" ] || [ -z "${_finding_file:-}" ]; then
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    # Validate SHA is reachable before diffing — an unreachable SHA silently
    # returns empty diff (same as "unchanged"), causing permanent invisible skip.
    if ! git -C "$RITE_PROJECT_ROOT" cat-file -e "${_finding_sha}^{commit}" 2>/dev/null; then
      print_warning "reconcile: SHA ${_finding_sha} unreachable in repo — skipping #${_fu_num}"
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    # Compute changed files between finding-sha and current target ref
    local _changed_files=""
    _changed_files=$(git -C "$RITE_PROJECT_ROOT" diff --name-only \
      "${_finding_sha}..${_target_ref}" -- 2>/dev/null || true)

    if ! grep -qxF "$_finding_file" <<< "${_changed_files:-}"; then
      # Finding location unchanged — leave alone, zero LLM calls
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    # ── Tier 2: classification call ──────────────────────────────────────────
    if [ "$_provider_ok" = "false" ]; then
      _provider_unavail_list="${_provider_unavail_list}#${_fu_num} "
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    local _region=""
    _region=$(_get_code_region "$_finding_file" "$_finding_loc_raw" 2>/dev/null || true)

    local _verdict="" _classify_exit=0
    _verdict=$(_classify_finding "$_fu_num" "$_issue_body" "$_region" "$_triage_model") \
      || _classify_exit=$?

    if [ "$_classify_exit" -ne 0 ]; then
      if [ "$_classify_exit" -eq 5 ] || [ "$_classify_exit" -eq 18 ]; then
        _provider_ok=false
        print_warning "reconcile: provider unavailable (exit ${_classify_exit}) — skipping remaining classifications"
        _provider_unavail_list="${_provider_unavail_list}#${_fu_num} "
      fi
      _skipped=$(( _skipped + 1 ))
      continue
    fi

    local _commit_range="${_finding_sha}..${_target_ref}"
    case "${_verdict:-}" in
      resolved)
        _do_close_or_comment "$_fu_num" "$_issue_labels" "$_commit_range"
        if echo "${_issue_labels:-}" | tr ' ' '\n' | grep -qx "security"; then
          _annotated=$(( _annotated + 1 ))
        else
          _closed=$(( _closed + 1 ))
        fi
        ;;
      partially-resolved)
        _do_annotate "$_fu_num" "$_target_ref"
        _annotated=$(( _annotated + 1 ))
        ;;
      still-open)
        _do_verify "$_fu_num"
        _verified=$(( _verified + 1 ))
        ;;
      *)
        _skipped=$(( _skipped + 1 ))
        ;;
    esac

  done <<< "$_fu_list"

  # Emit diag for health-report aggregation
  declare -f _diag >/dev/null 2>&1 && \
    _diag "FOLLOWUP_RECONCILED closed=${_closed} annotated=${_annotated} verified=${_verified} skipped=${_skipped} unchanged=${_pool_unchanged}"

  local _actioned=$(( _closed + _annotated + _verified ))
  if [ "$_actioned" -gt 0 ]; then
    print_info "Reconciled follow-ups: ${_closed} closed, ${_annotated} annotated, ${_verified} verified, ${_skipped} unchanged/skipped"
  fi

  # List candidates the provider couldn't classify (no silent loss)
  if [ -n "${_provider_unavail_list:-}" ]; then
    print_warning "reconcile: provider unavailable — these follow-ups need manual re-triage: ${_provider_unavail_list}"
  fi
}
