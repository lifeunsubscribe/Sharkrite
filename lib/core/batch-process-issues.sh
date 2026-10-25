#!/usr/bin/env bash
# batch-process-issues.sh
# Batch process multiple GitHub issues in unsupervised mode
# Usage:
#   rite 19 21 31 32              # Process specific issues
#   rite --label bug              # Process all issues with label
#   rite --milestone v1.0         # Process all issues in milestone
#
# Features:
#   - Unsupervised batch processing (--auto mode for all issues)
#   - Session limit enforcement (8 issues OR 4 hours)
#   - Smart follow-up pairing (fix → merge parent PR)
#   - Progress tracking and notifications
#   - Automatic worktree management
#   - Comprehensive summary report

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_BATCH_PROCESS_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_BATCH_PROCESS_LOADED=true

# Generate a unique batch ID for this invocation so that parallel batches in
# the same project each get their own SESSION_STATE_FILE.
# Use epoch-seconds + PID + RANDOM for portability: date +%s works on both
# macOS (BSD) and Linux, and the PID+RANDOM suffix prevents collisions when
# two batches start within the same second.
if [ -z "${RITE_BATCH_ID:-}" ]; then
  RITE_BATCH_ID="$(date +%s)-$$-${RANDOM}"
  export RITE_BATCH_ID
fi

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

# Re-derive SESSION_STATE_FILE via config.sh now that RITE_BATCH_ID is set.
# When bin/rite invokes this script via exec, config.sh was already sourced by
# the parent (with no RITE_BATCH_ID set yet), so SESSION_STATE_FILE is stale.
# Re-sourcing config.sh with RITE_BATCH_ID exported lets its canonical path
# formula (_batch_id_suffix logic) produce the correct per-batch path,
# keeping path derivation in one place so any future rename stays in sync.
unset SESSION_STATE_FILE
source "$_SCRIPT_DIR/../utils/config.sh"

# Source libraries
source "$RITE_LIB_DIR/utils/session-tracker.sh"
source "$RITE_LIB_DIR/utils/notifications.sh"
source "$RITE_LIB_DIR/utils/blocker-rules.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/utils/pr-detection.sh"
source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/issue-lock.sh"
source "$RITE_LIB_DIR/utils/date-helpers.sh"
source "$RITE_LIB_DIR/utils/cap-resume.sh"

source "$RITE_LIB_DIR/utils/colors.sh"

# Summary computation + stats-output functions (sourceable by regression tests)
source "$_SCRIPT_DIR/batch-reporter.sh"

# _extract_gate_signature <json_file>
# Extract the circuit-breaker fingerprint from a gate-findings JSON file.
# Returns the sorted unique set of failing test/lint files joined by commas,
# or an empty string when the gate was skipped or produced no parseable findings.
# An empty signature is treated as "no gate evidence" — it does NOT advance
# the consecutive-failure counter so non-gate failures don't count toward the trip.
_extract_gate_signature() {
  local json_file="${1:-}"
  [ -f "$json_file" ] || { printf ''; return 0; }
  # Skipped gates (missing runner, gate_timeout, etc.) carry no signal.
  local _skipped
  _skipped=$(jq -r '.skipped // "false"' "$json_file" 2>/dev/null || echo "false")
  if [ "$_skipped" = "true" ]; then
    printf ''
    return 0
  fi
  # Sorted unique file paths from both tests[] and lint[].
  # For bats failures .tests[].file is always "bats"; for node tests it is the
  # actual file path. Including lint[] catches repeated lint-only gate failures.
  # `// empty` drops null entries (e.g. a bats record without a file field).
  local _sig
  _sig=$(jq -r \
    '([.tests[].file // empty] + [.lint[].file // empty]) | sort | unique | join(",")' \
    "$json_file" 2>/dev/null || true)
  printf '%s' "${_sig:-}"
}

# Update the circuit-breaker counter for one issue outcome.
#
# Usage: _update_gate_breaker_counter <gate_json_file_or_empty> <issue_status>
#
# Mutates the three caller-scope variables:
#   _gate_consec_count  — current consecutive-match streak
#   _gate_consec_sig    — signature that the streak tracks
#   _gate_circuit_tripped — set to "true" when breaker fires
#
# Returns:
#   0  — normal (breaker not yet tripped)
#   16 — breaker just tripped (caller should break the loop and exit 16)
#
# Design notes:
#   • Non-failure statuses always reset the streak (these issues produced no
#     gate failures, so they cannot be part of a repeated-failure pattern).
#   • Gate failures with an empty parseable signature (gate_crashed, etc.)
#     also reset — they carry no repeatable signal.
#   • Gate failures with a non-empty signature advance the streak when they
#     match the previous sig, or restart it (count=1) when they differ.
#   • RITE_BATCH_GATE_TRIP=0 disables the breaker entirely.
#
# This function is defined separately from the main loop so that behavioral
# bats tests can source just this function (via RITE_SOURCE_FUNCTIONS_ONLY=1
# + awk extraction) and drive it directly — rather than re-implementing the
# counter logic inside the test, which cannot catch skip-path bugs (#823).
_update_gate_breaker_counter() {
  local _gate_json="${1:-}"  # path to gate-findings JSON (may be empty)
  local _issue_status="${2:-}"

  # Non-failure outcomes: reset streak, no further action.
  case "$_issue_status" in
    completed|already_closed_at_start|in_progress_elsewhere|pr_number_refused|\
    branch_mismatch|in_current_branch|waiting_for_parent|dep_failed|not_found)
      _gate_consec_count=0
      _gate_consec_sig=""
      return 0
      ;;
  esac

  # Failure path: inspect gate findings.
  if [ -n "$_gate_json" ] && [ -f "$_gate_json" ]; then
    local _this_sig
    _this_sig=$(_extract_gate_signature "$_gate_json" || true)
    if [ -n "$_this_sig" ]; then
      if [ "$_this_sig" = "$_gate_consec_sig" ]; then
        _gate_consec_count=$((_gate_consec_count + 1))
      else
        _gate_consec_sig="$_this_sig"
        _gate_consec_count=1
      fi
      if [ "${RITE_BATCH_GATE_TRIP:-3}" -gt 0 ] && \
         [ "$_gate_consec_count" -ge "${RITE_BATCH_GATE_TRIP:-3}" ]; then
        _gate_circuit_tripped=true
        return 16
      fi
    else
      # Gate ran but produced no parseable signature (e.g. gate_crashed).
      # Environmental noise — reset so we don't block on ambiguous data.
      _gate_consec_count=0
      _gate_consec_sig=""
    fi
  else
    # No gate findings (crashed before gate ran): reset streak.
    # Dev-phase or infrastructure failures, not repeated gate failures.
    _gate_consec_count=0
    _gate_consec_sig=""
  fi
  return 0
}

# Record a run to the persistent history file
record_run() {
  local issue="$1" mode="$2"
  local history_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/run-history.log"
  mkdir -p "$(dirname "$history_file")"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $issue $mode" >> "$history_file"
}

# Batch processing requires associative arrays (bash 4+)
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_newer_bash" ] && [ "$_newer_bash" != "$BASH" ]; then
      exec "$_newer_bash" "$0" "$@"
    fi
  done
  echo "Error: Batch processing requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

# Layer-2 dry-run backstop (defense in depth): bin/rite's dry-run choke point
# plans-and-exits before dispatch, so RITE_DRY_RUN=true must never reach this
# script's execution entry. If it does, refuse loudly rather than run the batch
# for real. Gated to direct execution — tests source this file for its
# functions (tests/regression/lib-resource-safety.bats), and a source-time exit
# would violate re-source safety.
if [ "${RITE_DRY_RUN:-false}" = "true" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  print_error "RITE_DRY_RUN=true but execution reached batch-process-issues.sh — refusing to run batch (dry-run is plan-only; see 'rite --dry-run')"
  exit 1
fi

# Check dependencies
if ! command -v gh &> /dev/null; then
  print_error "GitHub CLI required: brew install gh"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  print_error "jq required: brew install jq"
  exit 1
fi

# Parse arguments
ISSUE_LIST=()
FILTER_TYPE=""
FILTER_VALUE=""
SMART_WAIT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --smart-wait)
      SMART_WAIT=true
      shift
      ;;
    --label)
      FILTER_TYPE="label"
      FILTER_VALUE="$2"
      shift 2
      ;;
    --milestone)
      FILTER_TYPE="milestone"
      FILTER_VALUE="$2"
      shift 2
      ;;
    --state)
      FILTER_TYPE="state"
      FILTER_VALUE="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_LIST+=("$1")
      fi
      shift
      ;;
  esac
done

# Fetch issues if filter specified
if [ -n "$FILTER_TYPE" ]; then
  print_header "📋 Fetching Issues with Filter"
  print_info "Filter: $FILTER_TYPE = $FILTER_VALUE"

  case "$FILTER_TYPE" in
    label)
      FETCHED_ISSUES=$(gh_safe issue list --label "$FILTER_VALUE" --state open --json number --jq '.[].number' | sort -n | tr '\n' ' ' || true)
      ;;
    milestone)
      FETCHED_ISSUES=$(gh_safe issue list --milestone "$FILTER_VALUE" --state open --json number --jq '.[].number' | sort -n | tr '\n' ' ' || true)
      ;;
    state)
      FETCHED_ISSUES=$(gh_safe issue list --state "$FILTER_VALUE" --json number --jq '.[].number' | sort -n | tr '\n' ' ' || true)
      ;;
  esac

  # Convert to array
  read -ra ISSUE_LIST <<< "$FETCHED_ISSUES"

  print_success "Found ${#ISSUE_LIST[@]} issues"
  echo "Issues: ${ISSUE_LIST[*]}"
  echo ""
fi

# Validate we have issues to process
if [ ${#ISSUE_LIST[@]} -eq 0 ]; then
  print_error "No issues specified"
  echo ""
  echo "Usage:"
  echo "  rite 19 21 31 32              # Process specific issues"
  echo "  rite --label bug              # Process all issues with label"
  echo "  rite --milestone v1.0         # Process all issues in milestone"
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
# _extract_dep_issues_from_body BODY
#
# Scope the dependency-ref extraction to the structured "Dependencies:" field
# of the issue body, preventing prose/documentation examples (e.g. "After #1"
# in a description) from being parsed as live dependency edges.
#
# Root bug (2026-06-12, issue #556): the old whole-body grep harvested
# "After #1" from #556's prose explanation of the ordinal-ref bug, found
# issue #1 open, and skipped #556 with dep_failed — even though its actual
# Dependencies field said "None". Third instance of the unanchored-marker
# class (see CLAUDE.md "Unanchored marker grep").
#
# Algorithm (mirrors plan-issues.sh strict-lint dep extraction, PR #557):
#   1. Walk lines; track fenced-code-block state — lines inside ``` fences
#      are skipped entirely (fence guard prevents documented-marker false
#      positives; mirrors the BARE_MARKER_GREP rule and encountered-issues
#      renderer's extractor approach).
#   2. Enter dep-collection mode when a line matches EITHER:
#      a. "**Dependencies**:" or "Dependencies:" (canonical inline form, PR #964)
#      b. "## Dependencies" or "### Dependencies" etc. (legacy markdown-header
#         form — issues created before PR #964 used this style; e.g. #967
#         which ran concurrently with its open parent #921 because the guard
#         missed its "## Dependencies / After: #921" body). The `**Dependencies**:`
#         line form remains the canonical authoring format — the legacy form is
#         read-side only.
#   3. While in dep-collection mode:
#      a. Strip "(can run in parallel with #N, ...)" annotations — these are
#         scheduling hints, not dependency edges (see plan-issues.sh:1466-1473).
#      b. Collect all #N issue refs from the cleaned line — both keyword-anchored
#         ("After #5", "Blocked by: #5", "Depends on #5") and bare refs ("#5").
#         Using the # prefix as a format anchor prevents plain numeric words
#         (versions, timeouts, counts) from being harvested as issue numbers.
#      c. Stop at the next markdown section header (lines starting with "**"
#         or "##") or the "---" horizontal rule used as a section divider.
#   4. If no Dependencies: header is found → output nothing (no deps).
#      Rationale: a body lacking the structured field is malformed per the
#      issue template; any dep-pattern in the prose is unreliable. An
#      operator running `rite N1 N2` is presumed to have resolved ordering
#      manually (per the parity contract). Falling back to whole-body parsing
#      is precisely the bug we are fixing.
#
# Outputs: space-separated issue numbers (may be empty), no trailing newline.
# Caller must use `|| true` — grep exits 1 on no match.
#
_extract_dep_issues_from_body() {
  local _body="$1"
  local _in_deps=false
  local _in_fence=false
  local _collected=""

  while IFS= read -r _bline; do
    # Fence guard: toggle in/out of fenced code blocks on ``` markers.
    # When inside a fence, skip ALL header detection — a "## Dependencies"
    # or "**Dependencies**:" line inside a code example must not trigger
    # dep collection (BARE_MARKER_GREP rule: format anchor needed; fence
    # content is documentation, not live dependency edges).
    case "$_bline" in
      '```'*) [ "$_in_fence" = false ] && _in_fence=true || _in_fence=false; continue ;;
    esac
    [ "$_in_fence" = true ] && continue

    # Detect the canonical Dependencies: header (with or without ** markdown bold).
    # This is the form produced by the generator (PR #964) and the authoring standard.
    if echo "$_bline" | grep -qiE '^(\*\*)?Dependencies(\*\*)?\s*:'; then
      _in_deps=true
      # Strip parallel-with annotations before harvesting inline refs
      local _clean
      _clean=$(echo "$_bline" | sed -E 's/\([^)]*[Pp]arallel[^)]*\)//g' || true)
      # Collect all #N issue refs from the header line (bare and keyword-anchored).
      # The # prefix is a format anchor: it prevents plain numeric words
      # (versions, timeouts, ordinals) from being harvested as issue numbers.
      # Covers: "After #5", "Blocked by: #5", "Depends on #5", and bare "#5".
      local _inline_refs
      _inline_refs=$(echo "$_clean" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)
      [ -n "$_inline_refs" ] && _collected="${_collected:+$_collected }$_inline_refs"
      continue
    fi

    # Detect the legacy markdown-header form: "## Dependencies" (any level ##).
    # Issues authored before PR #964 used this style; deps appear on following
    # lines as "After: #N" / "Blocked by: #N". The header line itself carries
    # no inline refs, so just enter dep-collection mode and continue.
    if echo "$_bline" | grep -qiE '^##+ Dependencies\s*$'; then
      _in_deps=true
      continue
    fi

    # Stop at next section header or horizontal rule
    if [ "$_in_deps" = true ]; then
      case "$_bline" in
        "**"*|"##"*|"---"*) _in_deps=false; continue ;;
      esac
      # Strip parallel-with annotations
      local _clean
      _clean=$(echo "$_bline" | sed -E 's/\([^)]*[Pp]arallel[^)]*\)//g' || true)
      # Collect all #N issue refs from the continuation line (bare and keyword-anchored).
      # The # prefix is a format anchor: bare "#42" and "After #42" are both captured;
      # plain numeric words (versions, timeouts, ordinals) are not.
      local _refs
      _refs=$(echo "$_clean" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true)
      [ -n "$_refs" ] && _collected="${_collected:+$_collected }$_refs"
    fi
  done <<< "$_body"

  echo -n "$_collected"
}

# ---------------------------------------------------------------------------
# _check_dep_queued_later DEP_NUM ISSUE_NUM CURRENT_QI
#
# Scan ISSUE_LIST from index CURRENT_QI onwards (not from the beginning) for
# DEP_NUM. Only entries at CURRENT_QI+ are unprocessed; entries before that
# index have already run and must not trigger a false "queued later" deferral.
#
# Anti-cycle cap: if _DEFER_COUNT[ISSUE_NUM] >= _UNIQUE_ISSUE_COUNT, fall
# through without scanning — prevents infinite deferral loops when the dep
# never closes. The cap uses _UNIQUE_ISSUE_COUNT (the operator-supplied count,
# frozen before any deferrals) rather than ${#ISSUE_LIST[@]} (which grows
# with every deferral). Using the live list length would let the counter trail
# the bound forever in a k-cycle — the cap would never fire.
#
# Globals read:  ISSUE_LIST, _DEFER_COUNT, _UNIQUE_ISSUE_COUNT
# Globals written (on match): DEP_IN_QUEUE=true, DEP_IN_QUEUE_NUM=DEP_NUM
# Returns: 0 in all cases (caller checks DEP_IN_QUEUE, not the exit code)
#
# Sourceable by tests via awk extraction (same pattern as
# _extract_dep_issues_from_body).
_check_dep_queued_later() {
  local _dep_num="$1"
  local _issue_num="$2"
  local _current_qi="$3"

  local _defer_count="${_DEFER_COUNT[$_issue_num]:-0}"
  # Cap: frozen unique-issue count bounds cycles; falls back to live length for
  # tests that inline-source only this function without the full batch preamble.
  local _max_defer="${_UNIQUE_ISSUE_COUNT:-${#ISSUE_LIST[@]}}"
  if [ "$_defer_count" -ge "$_max_defer" ]; then
    return 0
  fi

  local _qi_scan=$_current_qi
  while [ "$_qi_scan" -lt "${#ISSUE_LIST[@]}" ]; do
    if [ "${ISSUE_LIST[$_qi_scan]}" = "$_dep_num" ]; then
      DEP_IN_QUEUE=true
      DEP_IN_QUEUE_NUM="$_dep_num"
      return 0
    fi
    _qi_scan=$((_qi_scan + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# _ftm_file_overlap ISSUE_BODY
#
# Parse the issue body's "Files to Modify:" section and check whether any
# declared path intersects the changed files of another in-flight worktree.
#
# Detection is local-only: git worktree list + git -C <wt> diff — no network
# calls. Excludes the main checkout and the current working directory from
# the worktree scan (this batch's own). An empty or missing "Files to
# Modify:" section is a silent no-op (returns without setting either global).
#
# Diff base resolution order (most-to-least specific):
#   1. merge-base HEAD origin/main  (production: remote ref)
#   2. merge-base HEAD main         (tests / no remote configured)
#   3. rev-list --max-parents=0     (first commit — last resort)
# Any worktree for which the base cannot be resolved is skipped silently.
#
# On overlap, sets globals _OVERLAP_FILES (comma-joined matching paths) and
# _OVERLAP_WT (path of the first overlapping worktree).
# Returns 0 always; caller inspects _OVERLAP_FILES for non-empty.
#
# Globals written: _OVERLAP_FILES, _OVERLAP_WT
# Deliberate batch-only behavior: single-issue mode has no queue to defer
# into. See behavioral-design.md → "Cross-Batch File Overlap: Warn and Reorder".
# ---------------------------------------------------------------------------

# batch_suffix_matches_issue <path> <issue_num>
# Returns 0 when the path (or basename) encodes the given issue number.
# Covers the _b<N> batch-suffix form (e.g. slug_b1419-1420-1421) AND the
# plain [-_]<N>[-_] separator form. Whole-token matching prevents substring
# collisions (_b99 must not fire for issue 9).
batch_suffix_matches_issue() {
  local _bsm_path="$1" _bsm_n="$2"
  case "$_bsm_path" in
    *[-_]"${_bsm_n}"[-_]*|\
    *[-_]"${_bsm_n}"|\
    *"_b${_bsm_n}"[-_]*|\
    *"_b${_bsm_n}") return 0;;
  esac
  return 1
}

_ftm_file_overlap() {
  local _issue_body="${1:-}"
  _OVERLAP_FILES=""
  _OVERLAP_WT=""

  # Step 1: extract the "Files to Modify:" section from the issue body.
  # Matches: "Files to Modify:", "**Files to Modify:**", with optional
  # trailing colon.  Section ends at a blank line or a new section header.
  _ftm_section=$(printf '%s\n' "$_issue_body" | awk '
    /^[[:space:]]*(\*\*)?Files to Modify:?(\*\*)?[[:space:]]*$/ { in_s=1; next }
    in_s && /^[[:space:]]*$/ { in_s=0; next }
    in_s && /^(##|[*][*][A-Z]|[A-Z][A-Za-z])/ { in_s=0; next }
    in_s { print }
  ' || true)

  [ -z "$_ftm_section" ] && return 0

  # Step 2: extract file paths — first backtick-quoted token per list item.
  _parsed_paths=""
  while IFS= read -r _ftm_line; do
    # Only process list items starting with optional whitespace + "- "
    case "$_ftm_line" in -\ *|\ *-\ *) ;; *) continue;; esac
    # Extract first backtick-quoted token
    _raw="${_ftm_line#*\`}"
    _fpath="${_raw%%\`*}"
    # No backtick found: fall back to first whitespace-delimited word after "- "
    if [ -z "$_fpath" ] || [ "$_fpath" = "$_raw" ]; then
      _fpath="${_ftm_line#*- }"
      _fpath="${_fpath%% *}"
    fi
    [ -z "$_fpath" ] && continue
    # Require at least one path separator or dot to filter prose tokens
    case "$_fpath" in */*|*.*) ;; *) continue;; esac
    _parsed_paths="${_parsed_paths}${_fpath}
"
  done < <(printf '%s\n' "$_ftm_section")

  [ -z "$_parsed_paths" ] && return 0

  # Step 3: enumerate other in-flight worktrees (local git only).
  _ftm_main_wt=$(git rev-parse --show-toplevel 2>/dev/null || true)
  _ftm_self_wt=$(pwd)

  while IFS= read -r _wt_line; do
    _wt_dir="${_wt_line%% *}"
    [ -d "$_wt_dir" ] || continue
    # Skip this batch's own checkout
    [ "$_wt_dir" = "$_ftm_main_wt" ] && continue
    [ "$_wt_dir" = "$_ftm_self_wt" ] && continue
    # Skip the current issue's own pre-existing worktree (resume path) to
    # prevent self-deferral. batch_suffix_matches_issue covers both [-_]<N> and
    # _b<N> forms; whole-token matching prevents substring collisions
    # (e.g. issue 9 must not skip a worktree for issue 99).
    if [ -n "${ISSUE_NUM:-}" ] && batch_suffix_matches_issue "$(basename "$_wt_dir")" "$ISSUE_NUM"; then
      continue
    fi

    # Resolve the diff base for this worktree (see resolution order above)
    _wt_base=$(git -C "$_wt_dir" merge-base HEAD origin/main 2>/dev/null || \
               git -C "$_wt_dir" merge-base HEAD main 2>/dev/null || \
               git -C "$_wt_dir" rev-list --max-parents=0 HEAD 2>/dev/null || true)
    [ -z "$_wt_base" ] && continue

    # Files changed on this worktree's branch vs its base
    _wt_changed=$(git -C "$_wt_dir" diff --name-only "${_wt_base}...HEAD" 2>/dev/null || true)
    [ -z "$_wt_changed" ] && continue

    # Step 4: intersect declared paths with this worktree's changed files
    _overlap_list=""
    while IFS= read -r _decl_path; do
      [ -z "$_decl_path" ] && continue
      _decl_cmp="${_decl_path%/}"   # strip trailing slash for comparison
      [ -z "$_decl_cmp" ] && continue

      _matched=false
      while IFS= read -r _wt_file; do
        [ -z "$_wt_file" ] && continue
        # Exact match
        if [ "$_wt_file" = "$_decl_cmp" ]; then
          _matched=true; break
        fi
        # Directory prefix match (declared is a directory)
        case "$_wt_file" in "${_decl_cmp}/"*) _matched=true; break;; esac
        # Glob match (declared contains * or ?)
        case "$_decl_cmp" in *'*'*|*'?'*)
          # shellcheck disable=SC2254
          case "$_wt_file" in $_decl_cmp) _matched=true; break;; esac
        esac
      done < <(printf '%s\n' "$_wt_changed")

      if [ "$_matched" = true ]; then
        _overlap_list="${_overlap_list:+${_overlap_list},}${_decl_cmp}"
      fi
    done < <(printf '%s\n' "$_parsed_paths")

    if [ -n "$_overlap_list" ]; then
      _OVERLAP_FILES="$_overlap_list"
      _OVERLAP_WT="$_wt_dir"
      return 0
    fi
  done < <(git worktree list 2>/dev/null || true)

  return 0
}

# ---------------------------------------------------------------------------
# _apply_overlap_defer_or_warn
#
# Apply the defer-or-warn decision after _ftm_file_overlap has populated
# _OVERLAP_FILES/_OVERLAP_WT.  When _OVERLAP_FILES is empty, returns 0
# immediately (no overlap detected, caller proceeds).
#
# When overlap is detected:
#   Below cap  → increments _DEFER_COUNT[$ISSUE_NUM], re-appends $ISSUE_NUM to
#                ISSUE_LIST, sets ISSUE_STATUS[ISSUE_NUM]="deferred_for_overlap",
#                prints a warning, and returns 1 (caller must `continue` the loop).
#   Cap reached → prints a warn-in-place warning and returns 0 (caller proceeds).
#
# Returns:
#   0 → no overlap, or cap exhausted → caller runs the issue in place
#   1 → issue deferred → caller must `continue` the batch loop
#
# Globals read:  _OVERLAP_FILES, _OVERLAP_WT, ISSUE_NUM, _DEFER_COUNT,
#                _UNIQUE_ISSUE_COUNT, ISSUE_LIST
# Globals written: _DEFER_COUNT, ISSUE_LIST, ISSUE_STATUS
# Extracted so tests can source and call it directly rather than duplicating
# the cap comparison and ISSUE_LIST re-append logic in a heredoc fixture.
# ---------------------------------------------------------------------------
_apply_overlap_defer_or_warn() {
  [ -n "${_OVERLAP_FILES:-}" ] || return 0

  local _overlap_defer_count="${_DEFER_COUNT[$ISSUE_NUM]:-0}"
  local _overlap_max="${_UNIQUE_ISSUE_COUNT:-${#ISSUE_LIST[@]}}"

  if [ "$_overlap_defer_count" -lt "$_overlap_max" ]; then
    _DEFER_COUNT[$ISSUE_NUM]=$(( _overlap_defer_count + 1 ))
    print_warning "Cross-batch file overlap: issue #$ISSUE_NUM shares files (${_OVERLAP_FILES}) with in-flight worktree $(basename "$_OVERLAP_WT") — deferring to end of queue (defer #${_DEFER_COUNT[$ISSUE_NUM]})"
    ISSUE_LIST+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="deferred_for_overlap"
    if declare -f _diag >/dev/null 2>&1; then
      _diag "OVERLAP_DEFER issue=$ISSUE_NUM files=${_OVERLAP_FILES} worktree=$(basename "$_OVERLAP_WT")"
    fi
    return 1
  else
    print_warning "Cross-batch file overlap: issue #$ISSUE_NUM shares files (${_OVERLAP_FILES}) with in-flight worktree $(basename "$_OVERLAP_WT") — defer cap reached, running in place"
    if declare -f _diag >/dev/null 2>&1; then
      _diag "OVERLAP_DEFER issue=$ISSUE_NUM files=${_OVERLAP_FILES} worktree=$(basename "$_OVERLAP_WT") cap_exhausted=true"
    fi
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Preflight dependency closure check (label/milestone/state filter mode only)
#
# Problem: `rite --label X` selects issues by label only. When a dependency
# of a selected issue lives outside the label (mislabeled or in a different
# category), the batch discovers it serially — each dependent hits the
# per-issue dep-skip guard at lines ~457-499 and is silently skipped. The
# batch fails safe, but can no-op most of its slate with scattered warnings.
#
# Fix: run one upfront pass that:
#   1. Fetches all selected issue bodies in a single gh call (not per-issue)
#   2. Extracts dep refs (same patterns as the per-issue guard: After #N /
#      Depends on #N / Blocked by: #N)
#   3. Identifies which deps are open AND outside the current selection
#   4. Emits a single upfront summary listing every affected issue + its
#      out-of-selection dep — so the user sees the full picture at once
#   5. In supervised mode (RITE_SUPERVISED=true): prompt to add missing open
#      deps to ISSUE_LIST (default yes)
#   6. In auto mode: warn upfront and proceed (per-issue skip guard remains
#      the backstop)
#
# This check runs only when a filter was used (FILTER_TYPE is non-empty).
# Numeric-list invocations (`rite N1 N2 N3`) are presumed intentional by
# the user and skip this check.
#
# --state filter scoping: the preflight only makes sense for open issues.
#   - `--state open`  → run preflight normally (selected issues are all open)
#   - `--state closed` → skip preflight: closed issues are already resolved;
#     their dependencies are no longer actionable blockers.
#   - `--state all`   → skip preflight: the selection mixes open and closed
#     issues; filtering to open-only would contradict the user's explicit
#     all-state intent, and analyzing only the open subset without flagging
#     it as partial overclaims coverage. Defer to the per-issue dep guard.
#   Design decision (issue #560): scope preflight to open-only selections.
#   The per-issue dep-skip guard remains the backstop for all state modes.
#
# The per-issue dep-skip guard (search for "DEP_ISSUES=" below) is unchanged;
# it still owns within-batch failures (dep failed mid-run) and acts as the
# final backstop.
# ---------------------------------------------------------------------------
if [ -n "${FILTER_TYPE:-}" ] && [ ${#ISSUE_LIST[@]} -gt 0 ]; then
  # --state filter: only run preflight when the selected state is "open".
  # Closed-issue selections have no actionable open blockers; all-state
  # selections mix states in a way that makes partial open-only analysis
  # misleading. Skip gracefully and let the per-issue guard handle it.
  # ${FILTER_VALUE,,} lowercases the value so "Open"/"OPEN" match "open" (issue #590).
  if [ "${FILTER_TYPE:-}" = "state" ] && [ "${FILTER_VALUE,,}" != "open" ]; then
    print_header "🔗 Preflight Dependency Closure Check"
    print_info "Skipping: preflight checks open-issue dependencies only."
    print_info "(Selection is --state ${FILTER_VALUE:-?} — per-issue dep guard remains active.)"
    echo ""
  else
  print_header "🔗 Preflight Dependency Closure Check"
  print_info "Checking for open dependencies outside the current selection..."
  echo ""

  # Step 1: Build a reverse-lookup set: is issue N in ISSUE_LIST?
  declare -A _in_selection
  for _sel_num in "${ISSUE_LIST[@]}"; do
    _in_selection["$_sel_num"]=1
  done

  # Step 2: Fetch bodies of all selected issues by number.
  # We query each selected issue individually to guarantee correctness on
  # large repos (an issue list capped at --limit N silently drops issues
  # outside that window, producing a false "no missing deps" result).
  # The selection is user-supplied and bounded (typically ≤8 per batch
  # slot), so N individual gh issue view calls are acceptable here.
  # Using jq @base64 on the body avoids multi-line / tab / backslash
  # issues — each output line is exactly "<number> <base64-encoded-body>".
  # base64 is available on both macOS and Linux.
  _preflight_bodies_raw=""
  for _sel_num in "${ISSUE_LIST[@]}"; do
    _pf_body_b64_one=$(gh_safe issue view "$_sel_num" \
      --json number,body \
      --jq '[(.number | tostring), (.body | @base64)] | join(" ")' 2>/dev/null || true)
    [ -z "$_pf_body_b64_one" ] && continue
    _preflight_bodies_raw="${_preflight_bodies_raw:+${_preflight_bodies_raw}
}${_pf_body_b64_one}"
  done

  # Step 3: Parse bodies and extract all dep refs for selected issues.
  # For each selected issue, record its out-of-selection dep numbers.
  # Also accumulate all unique dep numbers that are outside the selection.
  declare -A _oos_dep_map   # _oos_dep_map["N"] = space-separated dep numbers
  _oos_issue_nums=""        # space-separated selected issues with oos open deps
  _all_candidate_deps=""    # all unique dep numbers outside selection (may be open or closed)

  if [ -n "$_preflight_bodies_raw" ]; then
    while IFS= read -r _pf_line; do
      _pf_num="${_pf_line%% *}"
      _pf_body_b64="${_pf_line#* }"
      # Only process issues that are in our selection
      [ -n "${_in_selection[$_pf_num]:-}" ] || continue
      [ -z "$_pf_body_b64" ] && continue

      # Decode body from base64 — macOS uses `-D`, Linux uses `-d`; `--decode`
      # works on both with GNU coreutils; use the long form for portability.
      _pf_body=$(echo "$_pf_body_b64" | base64 --decode 2>/dev/null || \
                 echo "$_pf_body_b64" | base64 -D 2>/dev/null || true)
      [ -z "$_pf_body" ] && continue

      # Scope extraction to the Dependencies: field (same as per-issue guard below).
      # Whole-body grep causes prose examples like "After #1" in a description to
      # be harvested as live dep edges (live bug: issue #556, 2026-06-12).
      _dep_refs=$(_extract_dep_issues_from_body "$_pf_body" || true)
      [ -z "$_dep_refs" ] && continue

      _oos_deps_for_this=""
      for _dep_num in $_dep_refs; do
        # Skip if dep is already in the selection
        [ -n "${_in_selection[$_dep_num]:-}" ] && continue

        # Record this dep as a candidate (we'll batch-check open/closed next)
        _oos_deps_for_this="${_oos_deps_for_this:+$_oos_deps_for_this }$_dep_num"

        # Accumulate unique candidates for the batch state check
        case " $_all_candidate_deps " in
          *" $_dep_num "*) ;;
          *) _all_candidate_deps="${_all_candidate_deps:+$_all_candidate_deps }$_dep_num" ;;
        esac
      done

      if [ -n "$_oos_deps_for_this" ]; then
        _oos_dep_map["$_pf_num"]="$_oos_deps_for_this"
        case " $_oos_issue_nums " in
          *" $_pf_num "*) ;;
          *) _oos_issue_nums="${_oos_issue_nums:+$_oos_issue_nums }$_pf_num" ;;
        esac
      fi
    done <<< "$_preflight_bodies_raw"
  fi

  # Step 4: Batch-check which candidate deps are open with ONE gh issue list call.
  # This is the "prefetch pattern" — we collect all dep numbers first, then
  # resolve their states in one network round-trip rather than one per dep.
  # The per-issue dep-skip guard (DEP_ISSUES= block) does one `gh issue view`
  # per dep at run time; this preflight avoids that for the upfront summary.
  declare -A _dep_is_open   # _dep_is_open["N"]=1 means dep N is open
  if [ -n "$_all_candidate_deps" ]; then
    # Build a jq filter that selects only the dep numbers we care about.
    # gh issue list returns all open issues; we filter to our candidate set.
    # Portability: use a bash while-read loop instead of mapfile (bash 3.2 compat).
    _candidate_array=()
    for _cd in $_all_candidate_deps; do
      _candidate_array+=("$_cd")
    done
    # jq select filter: .number == N1 or .number == N2 ...
    _jq_filter='[.[] | select('
    _first_cd=true
    for _cd in "${_candidate_array[@]}"; do
      if [ "$_first_cd" = "true" ]; then
        _jq_filter="${_jq_filter}.number == ${_cd}"
        _first_cd=false
      else
        _jq_filter="${_jq_filter} or .number == ${_cd}"
      fi
    done
    _jq_filter="${_jq_filter}) | .number] | .[]"

    _open_deps_raw=$(gh_safe issue list \
      --state open \
      --json number \
      --limit 500 \
      --jq "$_jq_filter" 2>/dev/null || true)

    if [ -n "$_open_deps_raw" ]; then
      while IFS= read -r _od_num; do
        [ -n "$_od_num" ] && _dep_is_open["$_od_num"]=1
      done <<< "$_open_deps_raw"
    fi
  fi

  # Step 5: Filter _oos_dep_map down to only open deps.
  # Remove entries that turned out to be closed — closed deps are fine.
  _filtered_oos_issue_nums=""
  declare -A _filtered_oos_dep_map
  _all_missing_deps=""   # unique open out-of-selection deps across all issues

  for _oos_num in $_oos_issue_nums; do
    _deps="${_oos_dep_map[$_oos_num]:-}"
    _open_oos_deps=""
    for _d in $_deps; do
      [ -n "${_dep_is_open[$_d]:-}" ] || continue
      _open_oos_deps="${_open_oos_deps:+$_open_oos_deps }$_d"
      case " $_all_missing_deps " in
        *" $_d "*) ;;
        *) _all_missing_deps="${_all_missing_deps:+$_all_missing_deps }$_d" ;;
      esac
    done
    if [ -n "$_open_oos_deps" ]; then
      _filtered_oos_dep_map["$_oos_num"]="$_open_oos_deps"
      _filtered_oos_issue_nums="${_filtered_oos_issue_nums:+$_filtered_oos_issue_nums }$_oos_num"
    fi
  done

  # Step 6: Emit upfront summary (single block, not one warning per issue).
  if [ -n "$_filtered_oos_issue_nums" ]; then
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "Dependency Closure Warning"
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "The following selected issues have open dependencies OUTSIDE the"
    print_info "current selection (${FILTER_TYPE}=${FILTER_VALUE:-*})."
    print_info "Without those dependencies, the affected issues will be skipped"
    print_info "at run time by the per-issue dependency guard."
    print_info "(Note: this is a single-level check — direct deps only. Transitive"
    print_info "dependencies are caught per-issue at run time by the dep-skip guard.)"
    echo ""

    for _oos_num in $_filtered_oos_issue_nums; do
      _deps="${_filtered_oos_dep_map[$_oos_num]:-}"
      # Format dep list as "#N1, #N2, ..." for readability
      _deps_formatted=$(echo "$_deps" | sed 's/ /, #/g; s/^/#/' || true)
      echo "  • Issue #${_oos_num}  →  open dep(s) outside selection: ${_deps_formatted}"
    done
    echo ""
    print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step 7: Supervised mode — prompt to pull missing deps into the batch.
    # Auto mode: warn only, no selection change (deterministic from user's flag).
    if [ "${RITE_SUPERVISED:-false}" = "true" ]; then
      print_info "Missing open dependencies: ${_all_missing_deps}"
      echo ""
      # Default yes: pressing Enter includes them
      printf "Include these missing dependencies in this batch? [Y/n] "
      read -r _include_deps_reply || _include_deps_reply=""
      _include_deps_reply="${_include_deps_reply:-y}"
      if [[ "$_include_deps_reply" =~ ^[Yy]$ ]]; then
        _added_deps=""
        for _d in $_all_missing_deps; do
          # Prepend so deps run before their dependents
          ISSUE_LIST=("$_d" "${ISSUE_LIST[@]}")
          _in_selection["$_d"]=1
          _added_deps="${_added_deps:+$_added_deps }$_d"
        done
        # TOTAL_ISSUES is set after this block at line ~412; echo the new count here
        _added_deps_fmt=$(echo "$_added_deps" | sed 's/ /, #/g; s/^/#/' || true)
        print_success "Added ${_added_deps_fmt} to batch (${#ISSUE_LIST[@]} issues total)"
        echo ""
      else
        print_info "Proceeding without missing dependencies — affected issues will be skipped at run time"
        echo ""
      fi
    else
      # Auto mode: warn already printed above — no selection change.
      # The per-issue dep-skip guard (DEP_ISSUES= block) remains the backstop.
      # DO NOT auto-include: selection must stay deterministic from user's flag.
      print_info "Auto mode: proceeding with current selection."
      print_info "Affected issues will be skipped at run time by the dependency guard."
      echo ""
    fi
  else
    print_success "All dependencies are within the selection (or already closed)"
    echo ""
  fi

  # Clean up preflight temporaries (unset associative arrays + scalars)
  unset _in_selection _oos_dep_map _dep_is_open _filtered_oos_dep_map
  unset _preflight_bodies_raw _all_candidate_deps _oos_issue_nums
  unset _filtered_oos_issue_nums _all_missing_deps _jq_filter _open_deps_raw
  unset _candidate_array
  fi  # end: else branch of state-filter skip guard
fi

# Register a cleanup trap so the per-batch state file is removed on any exit
# (normal, error, kill).  Without this, abnormal exits (break/exit 1/5/10 or
# SIGTERM) leave orphaned /tmp files that grow unbounded across batch runs.
# The trap fires after the summary report exits, so cleanup always runs.
#
# The trap also emits a RITE_EXIT diag so silent exits from the batch
# dispatcher itself (set -e firing in the loop, subshell crashes, etc.) are
# observable in the log. The per-issue workflow-runner.sh process has its
# own RITE_EXIT diag — this one covers the batch orchestrator. See issue #471.
_cleanup_batch_session() {
  local rc=$?
  if declare -f _diag >/dev/null 2>&1; then
    _diag "RITE_EXIT code=${rc} mode=batch current_issue=${ISSUE_NUM:-unknown}"
  fi
  rm -f "${SESSION_STATE_FILE:-}"
  # Release the repo-level batch mutex (pid-checked; safe on interrupt/error/normal exit).
  if declare -f release_batch_lock >/dev/null 2>&1; then
    release_batch_lock
  fi
}
trap '_cleanup_batch_session' EXIT

# Initialize session tracking
init_session "batch-${ISSUE_LIST[0]}-$(date +%s)"

# Batch processing state
BATCH_START_TIME=$(date +%s)

# One line per finished issue: this issue's time and the batch's wall clock so
# far. BATCH_START_TIME is this process's own variable, so nothing a child or a
# test does to the session state file can move it.
_print_issue_duration() {
  local _now
  _now=$(date +%s)
  print_info "Duration: $(_format_elapsed "$ISSUE_DURATION") this issue · $(_format_elapsed $((_now - BATCH_START_TIME))) batch so far (${CURRENT_ISSUE:-?}/${TOTAL_ISSUES:-?})"
}
TOTAL_ISSUES=${#ISSUE_LIST[@]}
# Freeze unique-issue count for reporting. TOTAL_ISSUES may grow as deferred
# issues are appended to ISSUE_LIST — _UNIQUE_ISSUE_COUNT stays at the
# operator-supplied count so summaries and success rates are never inflated.
_UNIQUE_ISSUE_COUNT=${#ISSUE_LIST[@]}
COMPLETED_ISSUES=0
MERGED_CLEANUP_FAILED=()         # Exit 6: merged but cleanup crashed
FAILED_ISSUES=()                 # Exit 1: genuine failure (dev or merge)
BLOCKED_ISSUES=()                # Exit 2: blocker
SKIPPED_ISSUES=()                # Various skip reasons (all counted together for stats)
ALREADY_CLOSED_AT_START_ISSUES=() # Exit 12: already closed when batch started, no new work
IN_PROGRESS_ELSEWHERE_ISSUES=()  # Exit 14: locked by another live session, not a failure
PR_NUMBER_REFUSED_ISSUES=()      # Exit 15: number refers to a PR, not an issue — refused
AUTH_FAILURE_ISSUES=()           # Exit 18: provider auth failure — batch halted, remainder skipped

# Auth-halt flag: set to true when exit 18 triggers a batch halt so the
# post-loop pass can mark remaining unprocessed issues as skipped:auth.
_BATCH_AUTH_HALT=false

# Cap-abort flag: set to true when exit 5 breaks the issue loop so the
# post-loop path can attempt an opt-in auto-resume (lib/utils/cap-resume.sh).
_CAP_ABORT=false

# Circuit-breaker state (issue #823): consecutive identical gate failures.
# Tracks the last-seen gate failure signature and the run length so the batch
# can halt before dispatching more issues into a doomed environment.
# Signature = sorted unique failing-test-file paths from gate-findings JSON.
# The breaker trips when _gate_consec_count reaches RITE_BATCH_GATE_TRIP.
# Both counters live in the main script body (not functions) because bash 4
# associative-array state must be in scope for the main loop.
_gate_consec_count=0
_gate_consec_sig=""
_gate_circuit_tripped=false
RITE_BATCH_GATE_TRIP="${RITE_BATCH_GATE_TRIP:-3}"

# Per-issue tracking (associative arrays, requires bash 4+)
declare -A ISSUE_STATUS
declare -A ISSUE_TIME
declare -A ISSUE_PR
declare -A ISSUE_BRANCH
declare -A PR_CHANGES
declare -A _DEFER_COUNT  # defer counter per issue; anti-cycle cap for DEP_IN_QUEUE path
declare -A _LIVE_LOCK_WAIT_PID  # background sleep PID per dep-live-lock-deferred issue
declare -A _PARENT_LIVE_LOCK_WAIT_PID  # background sleep PID per parent-live-lock-deferred issue

# Summary arrays
SECURITY_UPDATES=()
NEW_ISSUES_CREATED=()
FAILED_PAIRS=()

# Pre-start checks
print_info "Running pre-start checks..."

# ---------------------------------------------------------------------------
# Repo-level batch mutex (issue #833)
#
# Acquire before any issue processing so concurrent batch invocations fail
# loudly instead of contending on shared state (scratchpad locks, worktree
# pool).  A refused batch exits 17 — distinct from per-issue failures so
# callers and nightly automation can distinguish "another batch is running"
# from a genuine workflow failure.
#
# The EXIT trap (_cleanup_batch_session) releases the lock unconditionally via
# release_batch_lock(), which is pid-checked so it never removes another
# process's lock.  The trap fires on normal exit, error, and SIGINT.
#
# Stale locks (dead PID) are atomically reclaimed by acquire_batch_lock() so
# a crashed batch never permanently blocks subsequent invocations.
# ---------------------------------------------------------------------------
_batch_issue_list_str="${ISSUE_LIST[*]}"
# Concurrent batches are the DEFAULT workflow (the original design: "split into
# parallel groups of 8"). The per-issue locks + the active-issue skip below are
# the real collision guards; repo-wide merge-time sweeps carry their own guards
# (#890). The whole-batch mutex is OPT-IN (RITE_BATCH_SERIALIZE=true) for
# cautious/low-resource runs — with queue-then-run semantics (#956/#957), or
# hard refusal under RITE_BATCH_QUEUE=false. (#958: serialization was never
# the operator's ask; parallel throughput was.)
if [ "${RITE_BATCH_SERIALIZE:-false}" != "true" ]; then
  print_info "Running without the batch mutex (concurrent batches allowed; per-issue locks guard collisions). Set RITE_BATCH_SERIALIZE=true to queue instead."
elif ! acquire_batch_lock "$_batch_issue_list_str"; then
  # A LIVE batch holds the repo lock (stale locks were already reclaimed
  # inside acquire_batch_lock). Default behavior is to QUEUE (#956): the
  # whole point of the mutex is fire-and-forget stacking of batches, so wait
  # with a heartbeat and start when the holder releases. Set
  # RITE_BATCH_QUEUE=false for the old hard-refusal (exit 17 — kept for
  # scripts that want a fast no).
  if [ "${RITE_BATCH_QUEUE:-true}" != "true" ]; then
    # acquire_batch_lock already printed the holder PID + issue list to stderr.
    print_error "Batch refused: another batch is already running. Exit code 17."
    exit 17
  fi
  _bq_holder_pid=$(cat "${RITE_LOCK_DIR}/batch.lock/pid" 2>/dev/null || echo "?")
  _bq_holder_issues=$(cat "${RITE_LOCK_DIR}/batch.lock/issues" 2>/dev/null || echo "?")
  print_info "Queued behind running batch (PID ${_bq_holder_pid}; issues: ${_bq_holder_issues}) — will start when it finishes. Ctrl-C to leave the queue."
  _bq_waited=0
  # 2>/dev/null: each re-attempt would spam the holder-PID refusal line; the
  # initial message + the 60s heartbeat carry that information.
  until acquire_batch_lock "$_batch_issue_list_str" 2>/dev/null; do
    sleep 15
    _bq_waited=$((_bq_waited + 15))
    if [ $((_bq_waited % 60)) -eq 0 ]; then
      _bq_holder_pid=$(cat "${RITE_LOCK_DIR}/batch.lock/pid" 2>/dev/null || echo "?")
      print_info "  ...still queued (${_bq_waited}s) behind PID ${_bq_holder_pid}"
    fi
  done
  print_success "Lock acquired after ${_bq_waited}s in queue — starting batch"
fi

# AWS credential check — warn only, don't block. If creds are actually needed,
# tests will fail (which IS a hard gate).
if detect_aws_project && ! detect_credentials_expired; then
  print_warning "AWS credentials expired — run: aws sso login --profile ${RITE_AWS_PROFILE}"
fi

# Filter out issues that are actively running in another process.
#
# The regex requires the issue number to follow workflow-runner.sh or
# claude-workflow.sh as a positional argument — NOT just appear anywhere on
# the line. The old pattern (" ${N}( |$)") false-positived against:
#   - the PID column (ps -eo pid,command pads with spaces, so a workflow-runner.sh
#     whose PID is N produces a line containing " N " from the PID column itself)
#   - any unrelated number that happened to land between spaces in argv
# Live failure: 2026-06-08 batch for issues 393 395 377 silently skipped 377
# even though no process was running it.
#
# When the skip fires we also print the matched line so a future false positive
# is debuggable from the log instead of requiring live process inspection.
_all_procs=$(ps -eo command 2>/dev/null || true)
_active_matches=$(echo "$_all_procs" | grep -E "(workflow-runner|claude-workflow)\.sh" | grep -v "grep" || true)
_filtered_list=()
_active_skipped=()
declare -A _active_skipped_matches
for _issue_num in "${ISSUE_LIST[@]}"; do
  _match_line=$(echo "$_active_matches" | grep -E "(workflow-runner|claude-workflow)\.sh ${_issue_num}( |$)" | head -1 || true)
  if [ -n "$_match_line" ]; then
    _active_skipped+=("$_issue_num")
    _active_skipped_matches["$_issue_num"]="$_match_line"
  else
    _filtered_list+=("$_issue_num")
  fi
done
if [ ${#_active_skipped[@]} -gt 0 ]; then
  print_warning "Skipping issues already running: ${_active_skipped[*]}"
  for _skip_issue in "${_active_skipped[@]}"; do
    print_info "  #${_skip_issue} matched: ${_active_skipped_matches[$_skip_issue]}"
  done
  ISSUE_LIST=("${_filtered_list[@]}")
  TOTAL_ISSUES=${#ISSUE_LIST[@]}
  _UNIQUE_ISSUE_COUNT=${#ISSUE_LIST[@]}
fi

# Check session limits upfront
SESSION_STATE=$(get_session_info)
ISSUES_COMPLETED=$(echo "$SESSION_STATE" | jq -r '.issues_completed')
# Use cumulative active work (not wall-clock age of the state file) — issue #283.
# get_cumulative_work_seconds returns the sum of per-issue tracked durations, so a
# zombie file from a prior batch contributes 0 seconds of active work.
CUMULATIVE_SECS=$(get_cumulative_work_seconds)
ELAPSED_HOURS=$(( CUMULATIVE_SECS / 3600 ))

# Issue-count cap removed — was a stale heuristic with misleading "token limit"
# message. The real session-budget signal is the cumulative-hours cap enforced
# inside the batch loop below.

print_success "Pre-start checks passed"
echo ""


print_header "🚀 Batch Processing Started"
echo "Issues: ${ISSUE_LIST[*]} ($TOTAL_ISSUES total)"
echo "Mode: Unsupervised (--auto)"
echo ""

# Pre-flight blocker scan: Check all issues for potential blockers upfront
print_header "🔍 Pre-Flight Blocker Scan"
print_info "Scanning all issues for potential blockers before starting..."
echo ""

PREFLIGHT_BLOCKERS=()
PREFLIGHT_BLOCKER_MSGS=()

for ISSUE_NUM in "${ISSUE_LIST[@]}"; do
  # Check if issue has an open PR (use shared detection for accurate body-based matching)
  PR_NUMBER=""
  detect_pr_for_issue "$ISSUE_NUM" 2>/dev/null || true

  if [ -n "$PR_NUMBER" ]; then
    print_info "Issue #$ISSUE_NUM has PR #$PR_NUMBER - checking for blockers..."

    # Run blocker checks (pass "unsupervised" since this is batch mode)
    BLOCKER_CHECK=$(check_blockers "pre-merge" "$PR_NUMBER" "$ISSUE_NUM" "unsupervised" 2>&1) || {
      BLOCKER_FOUND=true
      # Extract blocker type from check_blockers output
      BLOCKER_TYPE=$(echo "$BLOCKER_CHECK" | grep -o "BLOCKER:.*" | head -1 || echo "Unknown blocker")
      PREFLIGHT_BLOCKERS+=("$ISSUE_NUM")
      PREFLIGHT_BLOCKER_MSGS+=("$BLOCKER_TYPE")
      print_warning "Issue #$ISSUE_NUM: $BLOCKER_TYPE"
    }
  fi
done

if [ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]; then
  echo ""
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_warning "Pre-Flight Blockers Detected"
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  print_info "The following issues have potential blockers:"
  echo ""

  for i in "${!PREFLIGHT_BLOCKERS[@]}"; do
    echo "  • Issue #${PREFLIGHT_BLOCKERS[$i]}: ${PREFLIGHT_BLOCKER_MSGS[$i]}"
  done

  echo ""
  print_info "These issues will be deferred during batch processing"
  print_info "Workflow will continue with non-blocked issues"
  echo ""
  print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
else
  print_success "No blockers detected in pre-flight scan"
  echo ""
fi

# Layer 3 — Session-level remote-ref prefetch (optional, best-effort):
# A single `git fetch --prune` refreshes refs/remotes/origin/* so per-issue
# closed-issue cleanup can use `git show-ref --verify --quiet refs/remotes/origin/<branch>`
# (local, instant) instead of a per-issue `git ls-remote` (network).
# This is a belt-and-suspenders optimization: Layer 1 already eliminates the
# network call for merged PRs (the common case). This helps the rare
# closed-not-merged path scale to large batches without compounding latency.
# Failure is non-fatal — per-issue cleanup degrades gracefully.
_BATCH_FETCH_PRUNE_DONE=false
print_info "Prefetching remote refs (git fetch --prune)..."
# run_with_timeout, not bare `timeout` — stock macOS has no timeout(1) (it's
# gtimeout via coreutils); a bare call is exit-127 and misreports as "timed out".
# run_with_timeout degrades to running unbounded when no timeout binary exists,
# which is acceptable for this non-fatal prefetch.
if run_with_timeout 10 git fetch --prune origin >/dev/null 2>&1; then
  _BATCH_FETCH_PRUNE_DONE=true
  print_success "Remote refs up to date"
else
  print_warning "git fetch --prune failed or timed out (non-fatal — cleanup will use network checks)"
fi
export _BATCH_FETCH_PRUNE_DONE
echo ""

# Send batch start notification
send_notification_all "🚀 *Batch Processing Started*
*Total Issues:* $TOTAL_ISSUES
*Issues:* ${ISSUE_LIST[*]}
*Pre-flight Blockers:* ${#PREFLIGHT_BLOCKERS[@]}
*Mode:* Unsupervised" "normal"

# Clear any stale fixed-name cap-reset-line.txt from a prior single-issue run.
# In batch mode the file is now named cap-reset-line-${RITE_BATCH_ID}.txt (unique
# per invocation), so parallel batch groups cannot clobber each other.  The
# fixed-name fallback is only written by single-issue (non-batch) runs where
# RITE_BATCH_ID is absent; clearing it here prevents a stale single-issue file
# from feeding a wrong reset_epoch if this batch also caps.
rm -f "${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}/cap-reset-line.txt" 2>/dev/null || true

# Age-based reclamation for per-batch state files (cap-reset-line-*.txt and
# cap-resume-*.json).  The per-batch naming introduced by PR #1352 means files
# are never overwritten — a batch that caps without auto-resume leaves its
# manifest and reset-line as permanent orphans.  Delete files older than 7 days.
#
# Unlike the fixed-name cleanup above (which must NOT use a glob — a concurrent
# live batch's file could match the pattern), age-gated deletion is safe with a
# glob: any file 7+ days old predates the current run by definition, and
# RITE_BATCH_ID was generated at the top of this file (epoch+PID+RANDOM), so the
# current batch's own files are at most a few seconds old.
_cap_state_dir="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
find "$_cap_state_dir" -maxdepth 1 -name 'cap-reset-line-*.txt' -mtime +7 -delete 2>/dev/null || true
find "$_cap_state_dir" -maxdepth 1 -name 'cap-resume-*.json'    -mtime +7 -delete 2>/dev/null || true

# Process each issue
# Use a while-index loop instead of `for x in "${arr[@]}"` so that appending a
# deferred issue to ISSUE_LIST (DEP_IN_QUEUE path below) is visible to
# subsequent iterations — a for-in snapshot would miss newly appended elements.
_batch_qi=0
while [ "$_batch_qi" -lt "${#ISSUE_LIST[@]}" ]; do
  ISSUE_NUM="${ISSUE_LIST[$_batch_qi]}"
  _batch_qi=$((_batch_qi + 1))
  TOTAL_ISSUES=${#ISSUE_LIST[@]}
  ISSUE_START_TIME=$(date +%s)
  CURRENT_ISSUE=$((COMPLETED_ISSUES + ${#FAILED_ISSUES[@]} + ${#BLOCKED_ISSUES[@]} + ${#SKIPPED_ISSUES[@]} + 1))

  print_header "📌 Processing Issue #$ISSUE_NUM ($CURRENT_ISSUE/$TOTAL_ISSUES)"
  record_run "$ISSUE_NUM" "batch"

  # Fetch issue details
  ISSUE_DETAILS=$(gh_safe issue view "$ISSUE_NUM" --json title,labels,state)
  ISSUE_DETAILS="${ISSUE_DETAILS:-"{}"}"

  if [ "$ISSUE_DETAILS" = "{}" ]; then
    print_error "Issue #$ISSUE_NUM not found"
    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="not_found"
    # Non-failure outcome: reset consecutive gate-failure streak before skipping.
    _gate_consec_count=0; _gate_consec_sig=""
    continue
  fi

  ISSUE_TITLE=$(echo "$ISSUE_DETAILS" | jq -r '.title')
  ISSUE_STATE=$(echo "$ISSUE_DETAILS" | jq -r '.state')

  print_info "Title: $ISSUE_TITLE"
  print_info "State: $ISSUE_STATE"
  echo ""

  # Closed issues: do NOT short-circuit here. Let workflow-runner.sh handle them
  # via run_workflow() → handle_closed_issue(). That path prints the full closure
  # summary, removes dangling artifacts (worktree, local branch, remote branch,
  # session state file), and returns exit 0 — which the batch records as
  # "completed" and continues to the next issue.
  #
  # Parity contract: batch mode must produce identical per-issue side effects as
  # single-issue mode. Short-circuiting here would skip all cleanup that
  # workflow-runner.sh performs for closed issues.
  # See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity Contract"
  # Bug history: #274 — batch silently bypassed closed-issue cleanup for 8 orphan
  # worktrees that accumulated from issues processed via batch (#34, #201-#203).

  # Parent-PR and dependency guards only apply to OPEN issues. For CLOSED issues
  # both guards are skipped so run_workflow() → handle_closed_issue() handles all
  # cleanup. Without this gate the waiting_for_parent path can bypass
  # handle_closed_issue() (reproducing the #274 orphan-worktree bug class) and
  # the dep guard burns gh issue view per-dep-per-pass on already-closed issues.
  # See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity Contract"
  ISSUE_BODY=""
  if [ "$ISSUE_STATE" != "CLOSED" ]; then

  # Check if this is a follow-up issue with parent PR dependency
  ISSUE_BODY=$(gh_safe issue view "$ISSUE_NUM" --json body --jq '.body')
  ISSUE_BODY="${ISSUE_BODY:-}"
  PARENT_PR=""

  # If this issue was previously live-lock deferred because its parent issue was
  # live in another batch session, join the background sleep before re-checking
  # the parent PR state so the foreign session has had wall-clock time to merge.
  # Mirrors the dep live-lock wait join below (_LIVE_LOCK_WAIT_PID path).
  _parent_live_lock_wait_pid="${_PARENT_LIVE_LOCK_WAIT_PID[$ISSUE_NUM]:-}"
  if [ -n "$_parent_live_lock_wait_pid" ]; then
    wait "$_parent_live_lock_wait_pid" 2>/dev/null || true
    unset '_PARENT_LIVE_LOCK_WAIT_PID[$ISSUE_NUM]'
  fi

  # Require digits in the outer guard too — otherwise issue bodies that DOCUMENT
  # the marker format (e.g. "sharkrite-parent-pr:N" as an example) trigger the
  # inner extraction, which returns empty, which under set -e + pipefail kills
  # the script silently. Live bug: issue #34's body listed the marker as an
  # example and the entire batch died mid-stream with no error output.
  if echo "$ISSUE_BODY" | grep -qE "${RITE_MARKER_PARENT_PR}:[0-9]+"; then
    # Extract parent PR number from body marker
    PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE "${RITE_MARKER_PARENT_PR}:[0-9]+" | cut -d: -f2 || true)

    if [ -n "$PARENT_PR" ]; then
      # Check if parent PR is still open
      PARENT_PR_STATE=$(gh_safe pr view "$PARENT_PR" --json state --jq '.state')
      PARENT_PR_STATE="${PARENT_PR_STATE:-}"

      # Resolve parent issue number from parent PR body — needed by both the
      # OPEN branch (queue-membership check) and the MERGED branch (status
      # message). Must run unconditionally before the state dispatch; live
      # crash 2026-06-05 (finance-glance): PARENT_ISSUE was only set inside
      # the OPEN branch, so the MERGED branch hit `unbound variable`.
      PARENT_ISSUE=$(gh_safe pr view "$PARENT_PR" --json body --jq '.body' | grep -oE "$CLOSING_ISSUE_GREP_REGEX" | head -1 | grep -oE '[0-9]+' || true)
      PARENT_ISSUE="${PARENT_ISSUE:-}"

      if [ "$PARENT_PR_STATE" = "OPEN" ]; then
        # Check if parent issue is in our queue
        PARENT_IN_QUEUE=false
        for queued_issue in "${ISSUE_LIST[@]}"; do
          if [ "$queued_issue" = "$PARENT_ISSUE" ]; then
            PARENT_IN_QUEUE=true
            break
          fi
        done

        if [ "$PARENT_IN_QUEUE" = true ]; then
          print_success "Parent issue #$PARENT_ISSUE is in queue - this is a follow-up pair"
          print_info "Follow-up work will update parent issue #$PARENT_ISSUE's PR before merging parent"
        else
          # PARENT_IN_QUEUE=false: check for a live issue-lock on the parent
          # before skipping. If the parent issue is actively being worked in a
          # concurrent batch session it will likely merge before this batch
          # drains — defer rather than skip. Same logic as the DEP_ISSUES
          # live-lock path below; same _DEFER_COUNT anti-cycle cap.
          # Deliberate batch-only divergence: single-issue mode has no queue to
          # defer into. See behavioral-design.md → "Dependency Detection".
          _parent_live_lock_defer_count="${_DEFER_COUNT[$ISSUE_NUM]:-0}"
          _parent_live_lock_max="${RITE_LIVE_LOCK_MAX_DEFERS:-10}"
          if ! printf '%s' "$_parent_live_lock_max" | grep -qE '^[0-9]+$'; then
            print_warning "RITE_LIVE_LOCK_MAX_DEFERS='$_parent_live_lock_max' is not a non-negative integer — ignoring, using default 10"
            _parent_live_lock_max=10
          fi
          _PARENT_LIVE_LOCK=false
          if [ -n "$PARENT_ISSUE" ] && [ "$_parent_live_lock_defer_count" -lt "$_parent_live_lock_max" ]; then
            _parent_pid_file="${RITE_LOCK_DIR}/issue-${PARENT_ISSUE}.lock/pid"
            if [ -f "$_parent_pid_file" ]; then
              _parent_lock_pid=$(cat "$_parent_pid_file" 2>/dev/null || true)
              if [ -n "$_parent_lock_pid" ] && [ "$_parent_lock_pid" != "$$" ] && kill -0 "$_parent_lock_pid" 2>/dev/null; then
                _PARENT_LIVE_LOCK=true
              fi
            fi
          fi
          if [ "${_PARENT_LIVE_LOCK:-false}" = true ]; then
            _DEFER_COUNT[$ISSUE_NUM]=$(( ${_DEFER_COUNT[$ISSUE_NUM]:-0} + 1 ))
            print_info "Parent issue #$PARENT_ISSUE is live in another batch session — deferring issue #$ISSUE_NUM to end of queue (defer #${_DEFER_COUNT[$ISSUE_NUM]})"
            _live_lock_wait="${RITE_LIVE_LOCK_DEFER_WAIT:-30}"
            if ! printf '%s' "$_live_lock_wait" | grep -qE '^[0-9]+$'; then
              print_warning "RITE_LIVE_LOCK_DEFER_WAIT='$_live_lock_wait' is not a non-negative integer — ignoring, using default 30"
              _live_lock_wait=30
            fi
            if [ "$_live_lock_wait" -gt 0 ]; then
              sleep "$_live_lock_wait" >/dev/null 2>&1 &
              _PARENT_LIVE_LOCK_WAIT_PID[$ISSUE_NUM]=$!
            fi
            ISSUE_LIST+=("$ISSUE_NUM")
            ISSUE_STATUS["$ISSUE_NUM"]="deferred_for_parent"
            echo ""
            _gate_consec_count=0; _gate_consec_sig=""
            continue
          fi
          # No live lock on parent (or cap exhausted): fall through to skip.
          # Deliberate divergence from single-issue mode: batch skips follow-up
          # issues whose parent PR is still open AND the parent issue is not in
          # this batch. This is an orchestrator-level decision that requires
          # knowledge of the full queue — run_workflow() cannot make this call
          # because it processes one issue at a time without queue visibility.
          # The skip is correct: processing a follow-up before the parent merges
          # causes failures (the follow-up's code changes reference code that
          # hasn't landed yet). Single-issue mode does not have this guard because
          # the user invoking `rite N` is presumed to know the ordering constraint.
          # Regression test: tests/regression/batch-single-issue-parity.bats
          #   @test "parent-PR-deferred divergence: documented and intentional"
          print_info "Parent issue #$PARENT_ISSUE is still open - deferring issue #$ISSUE_NUM"
          print_info "This follow-up issue will be processed after parent issue merges"
          SKIPPED_ISSUES+=("$ISSUE_NUM")
          ISSUE_STATUS["$ISSUE_NUM"]="waiting_for_parent"
          echo ""
          # Non-failure outcome: reset consecutive gate-failure streak before skipping.
          _gate_consec_count=0; _gate_consec_sig=""
          continue
        fi
      elif [ "$PARENT_PR_STATE" = "MERGED" ]; then
        print_success "Parent issue #$PARENT_ISSUE is merged - proceeding with follow-up"
      fi
    fi
  fi

  # If this issue was previously live-lock deferred, join the background sleep
  # before re-checking the dep so the foreign session has had wall-clock time to
  # merge. The sleep runs concurrently with other queue items; the wait here is
  # near-instant when those items took longer than the sleep duration.
  _live_lock_wait_pid="${_LIVE_LOCK_WAIT_PID[$ISSUE_NUM]:-}"
  if [ -n "$_live_lock_wait_pid" ]; then
    wait "$_live_lock_wait_pid" 2>/dev/null || true
    unset '_LIVE_LOCK_WAIT_PID[$ISSUE_NUM]'
  fi

  # Check if issue depends on another issue that failed/was skipped in this batch.
  # Extract only from the structured Dependencies: field — NOT the full body.
  # Whole-body grep causes prose examples (e.g. "After #1" in a description)
  # to be harvested as live dep edges. See _extract_dep_issues_from_body() above
  # and CLAUDE.md "Unanchored marker grep" for the bug class (issue #556).
  DEP_ISSUES=$(_extract_dep_issues_from_body "$ISSUE_BODY" || true)
  if [ -n "$DEP_ISSUES" ]; then
    DEP_FAILED=false
    DEP_IN_QUEUE=false
    DEP_IN_QUEUE_NUM=""
    FAILED_DEP=""
    DEP_REASON=""
    _DEP_LIVE_LOCK=false
    for dep_num in $DEP_ISSUES; do
      dep_status="${ISSUE_STATUS[$dep_num]:-}"
      if [ "$dep_status" = "failed" ] || [ "$dep_status" = "blocked" ] || [ "$dep_status" = "not_found" ] || [ "$dep_status" = "dep_failed" ]; then
        DEP_FAILED=true
        FAILED_DEP="$dep_num"
        DEP_REASON="$dep_status in this batch"
        break
      fi
      # Also check if dep issue is still open with an unmerged PR
      dep_issue_state=$(gh_safe issue view "$dep_num" --json state --jq '.state')
      dep_issue_state="${dep_issue_state:-}"
      if [ "$dep_issue_state" = "OPEN" ]; then
        # If dep is queued AFTER the current position in this batch, defer rather
        # than fail — mirrors PARENT_IN_QUEUE check.
        # Positional scan (from _batch_qi): already-processed entries (index <
        # _batch_qi) are excluded so an OPEN dep that already ran (e.g.
        # waiting_for_parent, branch_mismatch) does not trigger a false deferral.
        # Anti-cycle cap: _check_dep_queued_later refuses to scan when
        # _DEFER_COUNT[ISSUE_NUM] >= _UNIQUE_ISSUE_COUNT (the frozen operator-supplied
        # count, not the live list length which grows with every deferral).
        _check_dep_queued_later "$dep_num" "$ISSUE_NUM" "$_batch_qi"
        # If dep is not queued later in this batch, check whether it holds a live
        # issue-lock — another concurrent batch session is actively working on it
        # and will likely merge before this batch drains. Reuses the same
        # _DEFER_COUNT anti-cycle cap so a stalled foreign session cannot loop
        # this issue forever. Local filesystem check only; no network calls.
        # Deliberate batch-only divergence: single-issue mode has no queue to
        # defer into. See behavioral-design.md → "Dependency Detection".
        if [ "$DEP_IN_QUEUE" = false ]; then
          _live_lock_defer_count="${_DEFER_COUNT[$ISSUE_NUM]:-0}"
          _live_lock_max="${RITE_LIVE_LOCK_MAX_DEFERS:-10}"
          if ! printf '%s' "$_live_lock_max" | grep -qE '^[0-9]+$'; then
            print_warning "RITE_LIVE_LOCK_MAX_DEFERS='$_live_lock_max' is not a non-negative integer — ignoring, using default 10"
            _live_lock_max=10
          fi
          if [ "$_live_lock_defer_count" -lt "$_live_lock_max" ]; then
            _dep_pid_file="${RITE_LOCK_DIR}/issue-${dep_num}.lock/pid"
            if [ -f "$_dep_pid_file" ]; then
              _dep_lock_pid=$(cat "$_dep_pid_file" 2>/dev/null || true)
              if [ -n "$_dep_lock_pid" ] && [ "$_dep_lock_pid" != "$$" ] && kill -0 "$_dep_lock_pid" 2>/dev/null; then
                DEP_IN_QUEUE=true
                DEP_IN_QUEUE_NUM="$dep_num"
                _DEP_LIVE_LOCK=true
              fi
            fi
          fi
        fi
        if [ "$DEP_IN_QUEUE" = false ]; then
          DEP_FAILED=true
          FAILED_DEP="$dep_num"
          DEP_REASON="issue still open (PR not merged)"
        fi
        break
      fi
    done
    if [ "$DEP_IN_QUEUE" = true ]; then
      # Dep is open but either queued later in this batch or live-locked in
      # another concurrent session — append current issue to the end of the
      # queue. The while-index loop (not a for-in snapshot) picks it up.
      _DEFER_COUNT[$ISSUE_NUM]=$(( ${_DEFER_COUNT[$ISSUE_NUM]:-0} + 1 ))
      if [ "${_DEP_LIVE_LOCK:-false}" = true ]; then
        print_info "Dependency #$DEP_IN_QUEUE_NUM is live in another batch session — deferring issue #$ISSUE_NUM to end of queue (defer #${_DEFER_COUNT[$ISSUE_NUM]})"
        # Start a background sleep so other queued issues run concurrently during
        # the wait. The background sleep is joined before re-checking the dep
        # (see the _LIVE_LOCK_WAIT_PID wait block above). This prevents the sleep
        # from blocking issues unrelated to this dep. The queue-later path omits
        # the sleep because natural issue-processing time provides the buffer.
        _live_lock_wait="${RITE_LIVE_LOCK_DEFER_WAIT:-30}"
        if ! printf '%s' "$_live_lock_wait" | grep -qE '^[0-9]+$'; then
          print_warning "RITE_LIVE_LOCK_DEFER_WAIT='$_live_lock_wait' is not a non-negative integer — ignoring, using default 30"
          _live_lock_wait=30
        fi
        if [ "$_live_lock_wait" -gt 0 ]; then
          sleep "$_live_lock_wait" >/dev/null 2>&1 &
          _LIVE_LOCK_WAIT_PID[$ISSUE_NUM]=$!
        fi
      else
        print_info "Dependency #$DEP_IN_QUEUE_NUM is queued later — deferring issue #$ISSUE_NUM to after dep (defer #${_DEFER_COUNT[$ISSUE_NUM]})"
      fi
      ISSUE_LIST+=("$ISSUE_NUM")
      # Do NOT update TOTAL_ISSUES here — live length is for the loop bound only
      # (line 927 re-computes it each iteration). Reporting uses _UNIQUE_ISSUE_COUNT.
      ISSUE_STATUS["$ISSUE_NUM"]="deferred_for_dep"
      echo ""
      _gate_consec_count=0; _gate_consec_sig=""
      continue
    fi
    if [ "$DEP_FAILED" = true ]; then
      # Deliberate divergence from single-issue mode: batch skips dependent issues
      # when a dependency failed/was blocked/is still open within the same batch.
      # This is an orchestrator-level decision that requires the batch's accumulated
      # ISSUE_STATUS map — run_workflow() processes one issue at a time and cannot
      # know what happened to sibling issues in this run. Single-issue mode has no
      # equivalent guard: the user invoking `rite N` is presumed to have resolved
      # dependencies manually. Processing a dependent issue while its dependency
      # hasn't landed causes predictable failures (missing schema, missing APIs, etc.).
      # Regression test: tests/regression/batch-single-issue-parity.bats
      #   @test "dep-failed divergence: documented and intentional"
      print_warning "Dependency #$FAILED_DEP not ready (${DEP_REASON:-unknown}) — skipping issue #$ISSUE_NUM"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="dep_failed"
      echo ""
      # Non-failure outcome: reset consecutive gate-failure streak before skipping.
      _gate_consec_count=0; _gate_consec_sig=""
      continue
    fi
  fi
  fi  # [ "$ISSUE_STATE" != "CLOSED" ] — parent-PR + dep guards

  # ---------------------------------------------------------------------------
  # Per-slot cross-batch file overlap check: warn and reorder when this
  # issue's declared Files-to-Modify intersect an in-flight worktree's diff.
  # Local git only — no network calls. Missing/empty "Files to Modify:"
  # section is a silent no-op. Bounded by the shared _DEFER_COUNT anti-cycle
  # cap (_UNIQUE_ISSUE_COUNT); cap exhausted → warning + run in place.
  # Deliberate batch-only divergence: single-issue mode has no queue to defer
  # into. See behavioral-design.md → "Cross-Batch File Overlap: Warn and Reorder".
  #
  # Skipped for CLOSED issues: cleanup-only work touches no source files and
  # therefore cannot conflict with another worktree's diff. The parity contract
  # ("do NOT short-circuit here", above) owns closed-issue handling via
  # run_workflow() → handle_closed_issue(). Deferring a closed issue only
  # delays cleanup while burning the defer cap.
  # ---------------------------------------------------------------------------
  if [ "$ISSUE_STATE" != "CLOSED" ]; then
    _OVERLAP_FILES=""
    _OVERLAP_WT=""
    _ftm_file_overlap "$ISSUE_BODY"
    _overlap_action_rc=0; _apply_overlap_defer_or_warn || _overlap_action_rc=$?
    if [ "$_overlap_action_rc" -ne 0 ]; then
      echo ""
      _gate_consec_count=0; _gate_consec_sig=""
      continue
    fi
  fi

  # Check if issue is actively being worked on (worktree exists with a running rite/claude process)
  _active_wt=""
  if detect_pr_for_issue "$ISSUE_NUM" 2>/dev/null; then
    detect_worktree_for_pr "$PR_NUMBER" 2>/dev/null || true
    _active_wt="${WORKTREE_PATH:-}"
  fi
  if [ -z "$_active_wt" ]; then
    _main_wt=$(git rev-parse --show-toplevel)
    _active_wt=$(git worktree list | awk '{print $1}' | grep -v "^${_main_wt}$" | \
      grep -E "(issue[^0-9]?${ISSUE_NUM}([^0-9]|$)|#${ISSUE_NUM}([^0-9]|$)|[-_]${ISSUE_NUM}[-_]|[-_]${ISSUE_NUM}$|_b${ISSUE_NUM}[-_]|_b${ISSUE_NUM}$)" | head -1 || true)
  fi
  if [ -n "$_active_wt" ]; then
    # Check if a rite or claude process is running for this issue
    _loop_procs=$(ps -eo pid,command 2>/dev/null || true)
    if echo "$_loop_procs" | grep -qE "workflow-runner\.sh ${ISSUE_NUM}( |$)" || \
       echo "$_loop_procs" | grep -qE "claude-workflow\.sh ${ISSUE_NUM}( |$)"; then
      # Deliberate divergence from single-issue mode: batch skips issues that
      # are actively running in a concurrent rite/claude process. This is a
      # safety guard to prevent two sessions from racing on the same issue and
      # corrupting the branch, worktree, or session state. Single-issue mode
      # does not have this guard because invoking `rite N` directly while another
      # `rite N` runs is intentional (e.g., supervised retry) and the user accepts
      # responsibility. In batch mode, the same issue appearing twice would be a
      # bug in the queue, not an intentional retry.
      # Regression test: tests/regression/batch-single-issue-parity.bats
      #   @test "active-process divergence: documented and intentional"
      print_warning "Issue #$ISSUE_NUM is actively running in another process — skipping"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="active"
      echo ""
      # Non-failure outcome: reset consecutive gate-failure streak before skipping.
      _gate_consec_count=0; _gate_consec_sig=""
      continue
    fi
  fi
  # Reset PR_NUMBER — detect_pr_for_issue sets it globally
  PR_NUMBER=""
  WORKTREE_PATH=""

  # Check if issue already has open PR (must have "Closes #XX" in body)
  EXISTING_PR=""
  for pr_num in $(gh_safe pr list --state open --json number --jq '.[].number' || true); do
    if gh_safe pr view "$pr_num" --json body --jq '.body' | grep -q "Closes #${ISSUE_NUM}\$\|Closes #${ISSUE_NUM}[^0-9]" 2>/dev/null; then
      EXISTING_PR="$pr_num"
      break
    fi
  done

  if [ -n "$EXISTING_PR" ]; then
    # If smart-wait enabled and this looks like a parent issue, wait for review
    if [ "$SMART_WAIT" = true ]; then
      # Check if this issue's PR was just updated by a previous issue in batch
      get_latest_work_commit_time "" "$EXISTING_PR"
      PR_UPDATED="$LATEST_COMMIT_TIME"
      REVIEW_TIME=$(gh_safe pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt')
      REVIEW_TIME="${REVIEW_TIME:-}"

      if [ -n "$PR_UPDATED" ] && [ -n "$REVIEW_TIME" ] && [[ "$PR_UPDATED" > "$REVIEW_TIME" ]]; then
        print_info "⏰ Smart Wait: issue #$ISSUE_NUM updated after review"
        print_info "Waiting for new review (timeout: 15 minutes, poll every 2 min)..."
        echo ""

        WAIT_START=$(date +%s)
        MAX_WAIT=$((15 * 60))  # 15 minutes
        POLL_INTERVAL=120       # 2 minutes

        while true; do
          sleep $POLL_INTERVAL

          # Check for newer review
          NEW_REVIEW_TIME=$(gh_safe pr view "$EXISTING_PR" --json comments --jq '.comments | map(select(.author.login == "claude")) | .[-1].createdAt')
          NEW_REVIEW_TIME="${NEW_REVIEW_TIME:-}"

          if [ -n "$NEW_REVIEW_TIME" ] && [[ "$NEW_REVIEW_TIME" > "$PR_UPDATED" ]]; then
            print_success "New review detected! Continuing with merge workflow..."
            echo ""
            break
          fi

          ELAPSED=$(($(date +%s) - WAIT_START))
          if [ $ELAPSED -ge $MAX_WAIT ]; then
            print_warning "Timeout: No review after 15 minutes"

            # Send Slack notification
            send_notification "⏱️ Manual Intervention Needed" "Issue #$ISSUE_NUM: PR #$EXISTING_PR timeout waiting for review. Run: \`rite $ISSUE_NUM\`" "warning"

            print_info "Slack notification sent"
            print_info "Manual run needed: rite $ISSUE_NUM"
            echo ""

            SKIPPED_ISSUES+=("$ISSUE_NUM")
            ISSUE_STATUS["$ISSUE_NUM"]="review_timeout"
            ISSUE_PR["$ISSUE_NUM"]="$EXISTING_PR"
            continue 2  # Skip to next issue in outer loop
          fi

          print_info "Still waiting... ($((ELAPSED / 60))/$((MAX_WAIT / 60)) min)"
        done
      fi
    fi

    # Check if we're already in this PR's branch (avoid conflicts)
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    PR_BRANCH=$(gh_safe pr view "$EXISTING_PR" --json headRefName --jq '.headRefName')
    PR_BRANCH="${PR_BRANCH:-}"

    if [ -n "$CURRENT_BRANCH" ] && [ -n "$PR_BRANCH" ] && [ "$CURRENT_BRANCH" = "$PR_BRANCH" ]; then
      # Deliberate divergence from single-issue mode: batch skips an issue if the
      # current working directory is already on that issue's branch. This prevents
      # git operations (checkout, worktree add) from conflicting with the active
      # branch. Single-issue mode allows this because the user explicitly chose the
      # issue and can resolve the conflict interactively. In batch mode, reusing the
      # current branch would corrupt its state for the remaining batch issues.
      # Regression test: tests/regression/batch-single-issue-parity.bats
      #   @test "in-current-branch divergence: documented and intentional"
      print_warning "Already in this issue's branch ($PR_BRANCH) - skipping to avoid conflicts"
      SKIPPED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="in_current_branch"
      ISSUE_PR["$ISSUE_NUM"]="$EXISTING_PR"
      echo ""
      # Non-failure outcome: reset consecutive gate-failure streak before skipping.
      _gate_consec_count=0; _gate_consec_sig=""
      continue
    fi

    # Otherwise, proceed - workflow will use worktree for this PR's branch
    print_info "Will continue work on issue #$ISSUE_NUM in worktree"
    echo ""
  fi

  # Run workflow in unsupervised mode
  print_info "Starting workflow-runner.sh --auto..."
  echo ""

  # Export BATCH_MODE flag so nested scripts know we're in batch processing
  export BATCH_MODE=true
  # Export full issue list so nested scripts (e.g., merge cleanup) can protect sibling worktrees
  export BATCH_ISSUE_LIST="${ISSUE_LIST[*]}"

  # Record per-issue start time for cumulative active-work tracking (issue #283).
  # end_issue_tracking is called in the success and failure branches below so
  # cumulative_work_seconds is always updated regardless of outcome.
  start_issue_tracking "$ISSUE_NUM"

  # Circuit-breaker sentinel: capture a reference timestamp BEFORE the workflow
  # runs so we can find the gate-findings JSON it writes (named by PR number,
  # which we don't know here) by selecting files newer than this sentinel.
  # The sentinel is a temp file whose mtime is set at creation time; we compare
  # it against gate-findings-*.json files after the workflow exits.
  # Scoped with PID suffix to prevent concurrent batches from racing on globs.
  _gate_sentinel=$(mktemp "/tmp/rite_gate_sentinel_${ISSUE_NUM}_$$.XXXXXX" 2>/dev/null || true)

  # Run workflow and capture exit code explicitly before any if/then test.
  # `if cmd; then` discards non-zero codes — use the canonical set-e-safe
  # capture pattern so exit 12 (closed at start), 0 (active completion), and
  # other non-zero codes (failures) are all distinguishable.
  # See: docs/architecture/exit-codes.md
  _WF_EXIT=0
  "$RITE_LIB_DIR/core/workflow-runner.sh" "$ISSUE_NUM" --unsupervised || _WF_EXIT=$?

  if [ $_WF_EXIT -eq 0 ]; then
    # Active completion: issue was worked on in this session. Gather PR stats
    # for the batch summary (PR number, branch, file/line counts, tech-debt).
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    # Get PR number for this issue (closing-ref in PR body, most recent first).
    # Use a local jq filter over `pr list`, NOT `--search`: the GitHub search
    # API is slow and rate-limited (measured ~3min/call vs ~0.5s for this list
    # path), and it dominated the per-issue gap in batch runs. This mirrors the
    # de-searched pattern in pr-detection.sh::detect_pr_for_issue and
    # workflow-runner.sh, but with --state all because the PR is typically
    # already MERGED by the time we reach this post-completion stat-gathering.
    # The just-created PR is the newest, so --limit 100 (newest-first) covers it.
    # jq `// empty` converts null to no output; the bash-level strip below is
    # belt-and-suspenders for any future call path that may not use `// empty`.
    PR_NUMBER=$(gh_safe pr list --state all --json number,body --limit 100 | \
      jq --arg issue "$ISSUE_NUM" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
      '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)
    PR_NUMBER="${PR_NUMBER:-}"
    [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""

    if [ -n "$PR_NUMBER" ]; then
      print_info "PR: #$PR_NUMBER"
      ISSUE_PR["$ISSUE_NUM"]="$PR_NUMBER"

      # Capture branch name and changes summary
      BRANCH_NAME=$(gh_safe pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
      BRANCH_NAME="${BRANCH_NAME:-}"
      if [ -n "$BRANCH_NAME" ]; then
        ISSUE_BRANCH["$ISSUE_NUM"]="$BRANCH_NAME"
      fi

      # Capture changes summary (files changed + lines)
      PR_STATS=$(gh_safe pr view "$PR_NUMBER" --json additions,deletions,changedFiles --jq '"\(.changedFiles) files, +\(.additions)/-\(.deletions) lines"')
      PR_STATS="${PR_STATS:-}"
      if [ -n "$PR_STATS" ]; then
        PR_CHANGES["$PR_NUMBER"]="$PR_STATS"
      fi

      # Check for security doc updates
      SECURITY_DOC_UPDATED=$(gh_safe pr view "$PR_NUMBER" --json files --jq '.files[].path' | grep -c "docs/security/DEVELOPMENT-GUIDE.md" || true)
      if [ "$SECURITY_DOC_UPDATED" -gt 0 ]; then
        SECURITY_UPDATES+=("PR #$PR_NUMBER: Updated DEVELOPMENT-GUIDE.md with findings from #$ISSUE_NUM")
      fi

      # Check for new tech-debt issues created.
      # `// empty` prevents jq from outputting literal "null" when no issue matches.
      NEW_DEBT_ISSUE=$(gh_safe issue list --label "tech-debt" --state open --search "${RITE_MARKER_PARENT_PR}:$PR_NUMBER in:body" --json number --jq '.[0].number // empty')
      NEW_DEBT_ISSUE="${NEW_DEBT_ISSUE:-}"
      [ "$NEW_DEBT_ISSUE" = "null" ] && NEW_DEBT_ISSUE=""
      if [ -n "$NEW_DEBT_ISSUE" ]; then
        NEW_ISSUES_CREATED+=("Issue #$NEW_DEBT_ISSUE (from PR #$PR_NUMBER)")
      fi
    fi
    _print_issue_duration
    echo ""

    COMPLETED_ISSUES=$((COMPLETED_ISSUES + 1))
    ISSUE_STATUS["$ISSUE_NUM"]="completed"

    # Send success notification if smart-wait was used (means auto-merge happened)
    if [ "$SMART_WAIT" = true ] && [ -n "$PR_NUMBER" ]; then
      send_notification "✅ Auto-Merge Success!" "Issue #$ISSUE_NUM completed and PR #$PR_NUMBER merged automatically! Duration: $(_format_elapsed "$ISSUE_DURATION")" "success"
    fi

  elif [ $_WF_EXIT -eq 12 ]; then
    # Already closed at start: handle_closed_issue() ran and printed the closure
    # summary + cleaned any orphan artifacts. No dev session ran — skip all the
    # post-issue gh API calls (pr list, pr view x3, issue list) that gather stats
    # for the batch report. Those calls are only meaningful after active dev work.
    #
    # Parity note: the per-issue SIDE EFFECTS (closure summary, artifact cleanup)
    # are identical to single-issue mode — that's the parity contract. The batch-
    # level REPORTING layer is intentionally differentiated based on what kind of
    # work happened. This is documented divergence, not a parity violation.
    # See: docs/architecture/behavioral-design.md — "Batch ↔ Single-Issue Parity Contract"
    # See: docs/architecture/exit-codes.md — exit code 12
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_info "Issue #$ISSUE_NUM was already closed — no new work this session"
    _print_issue_duration
    echo ""

    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ALREADY_CLOSED_AT_START_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="already_closed_at_start"

  elif [ $_WF_EXIT -eq 14 ]; then
    # Issue locked by another live session: acquire_issue_lock() rejected this
    # issue because another rite process holds the lock. This is an expected
    # concurrency condition — NOT a failure. No dev session ran.
    # Record as in_progress_elsewhere (SKIPPED class) so the batch summary shows
    # a clear "already being processed" line, not a spurious failed entry.
    # The "Issue #N is already being processed by PID X" message was already
    # printed to stderr by acquire_issue_lock() before exit 14 was emitted.
    # See: docs/architecture/exit-codes.md — exit code 14
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_info "⏭️  Issue #$ISSUE_NUM skipped — already being processed by another session"
    _print_issue_duration
    echo ""

    SKIPPED_ISSUES+=("$ISSUE_NUM")
    IN_PROGRESS_ELSEWHERE_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="in_progress_elsewhere"

  elif [ $_WF_EXIT -eq 15 ]; then
    # Number refers to a PR, not an issue: handle_pr_number_refused() rejected
    # this number. GitHub's shared number space means gh issue view succeeds for
    # PR numbers — the refusal message was already printed by the handler.
    # Record as pr_number_refused (SKIPPED class, not FAILED). No dev session
    # ran and no stat-gathering is needed.
    # See: docs/architecture/exit-codes.md — exit code 15
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_info "⏭️  #$ISSUE_NUM skipped — number refers to a PR, not an issue"
    _print_issue_duration
    echo ""

    SKIPPED_ISSUES+=("$ISSUE_NUM")
    PR_NUMBER_REFUSED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="pr_number_refused"

  elif [ $_WF_EXIT -eq 19 ]; then
    # PR base branch differs from the effective target: handle_branch_mismatch()
    # refused and already printed the verbose block with the corrected command.
    # Record as branch_mismatch (SKIPPED class, not FAILED) so the batch does
    # not count this as an error and the gate-breaker streak resets.
    # No dev session ran; no stat-gathering is needed.
    # See: docs/architecture/exit-codes.md — exit code 19
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    print_info "⏭️  #$ISSUE_NUM skipped — PR base branch does not match effective target (see corrected command above)"
    _print_issue_duration
    echo ""

    SKIPPED_ISSUES+=("$ISSUE_NUM")
    ISSUE_STATUS["$ISSUE_NUM"]="branch_mismatch"

  else
    EXIT_CODE=$_WF_EXIT
    # Record end of per-issue tracking regardless of failure type (issue #283)
    end_issue_tracking "$ISSUE_NUM"
    ISSUE_END_TIME=$(date +%s)
    ISSUE_DURATION=$((ISSUE_END_TIME - ISSUE_START_TIME))
    ISSUE_TIME["$ISSUE_NUM"]=$ISSUE_DURATION

    # Classify failure type based on exit code
    if [ $EXIT_CODE -eq 6 ]; then
      # Merge succeeded but cleanup failed — work IS on remote
      print_warning "Issue #$ISSUE_NUM: merge succeeded but cleanup failed (exit code: 6)"
      _print_issue_duration
      echo ""
      MERGED_CLEANUP_FAILED+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="merged_cleanup_failed"

      # Get PR number so we can show the URL in the summary.
      # Local jq filter over `pr list` (not the slow/rate-limited --search API);
      # --state all because the merge already happened. See note at the
      # active-completion site above.
      PR_NUMBER=$(gh_safe pr list --state all --json number,body --limit 100 | \
        jq --arg issue "$ISSUE_NUM" --arg closing_re "$CLOSING_ISSUE_JQ_REGEX" -r \
        '[.[] | select(.body | test($closing_re + $issue + "\\b"))] | sort_by(.number) | last | .number // empty' || true)
      PR_NUMBER="${PR_NUMBER:-}"
      if [ -n "$PR_NUMBER" ]; then
        ISSUE_PR["$ISSUE_NUM"]="$PR_NUMBER"
      fi

    elif [ $EXIT_CODE -eq 13 ]; then
      # Invariant violated: workflow completed all phases but produced no commits
      # and no PR — this is a bug in the workflow logic or a sourcing side-effect.
      # The full diagnostic was already printed by run_workflow before it returned 13.
      # Record as a distinct failure class (not the same as a dev/merge failure)
      # so operators can identify phantom completions in the batch log.
      # Continue the loop — other issues are not affected by this bug.
      # See: docs/architecture/exit-codes.md (exit 13 — invariant violated)
      print_error "Issue #$ISSUE_NUM: workflow invariant violated — no commits and no PR produced (exit code: 13)"
      print_error "This is a workflow logic bug, not a user-actionable failure — check logs above"
      _print_issue_duration
      echo ""
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="invariant_violated"
      increment_failed   # session tracker: invariant_violated counts as processed

    elif [ $EXIT_CODE -eq 5 ]; then
      # Usage cap reached — abort batch, write resume manifest, print resume cmd.
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="usage_cap"
      increment_failed   # session tracker: usage_cap counts as processed

      # Read reset-line persisted by claude.sh when the cap was detected.
      # RITE_BATCH_ID is always set in batch context (see top of this file), so the
      # per-batch filename is always used here — parallel groups get their own file.
      _cap_state="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
      _cap_reset_file="${_cap_state}/cap-reset-line-${RITE_BATCH_ID}.txt"
      _cap_reset_text=$(cat "$_cap_reset_file" 2>/dev/null | head -1 || true)
      rm -f "$_cap_reset_file" 2>/dev/null || true

      # Parse the reset epoch from the CLI message
      _cap_reset_epoch=0
      if [ -n "$_cap_reset_text" ]; then
        _cap_reset_epoch=$(cap_reset_to_epoch "$_cap_reset_text" || echo "0")
      fi

      # Remaining issues: current (cap'd) + all not-yet-started in ISSUE_LIST
      _remaining=("$ISSUE_NUM")
      _seen_remaining=" $ISSUE_NUM "
      for _ri in "${ISSUE_LIST[@]}"; do
        case " $_seen_remaining " in
          *" $_ri "*) continue ;;
        esac
        # Include not-yet-started, dependency-deferred, parent-deferred, and blocked
        # issues — all represent work the batch still owes. waiting_for_parent is
        # excluded: that issue's PR is already in-flight and resuming won't re-run it.
        case "${ISSUE_STATUS[$_ri]:-}" in
          "" | deferred_for_dep | deferred_for_parent | blocked)
            _remaining+=("$_ri")
            _seen_remaining="${_seen_remaining}${_ri} "
            ;;
        esac
      done

      # Reconstruct passthrough flags (--smart-wait and --branch for non-main targets)
      _batch_flags=""
      [ "$SMART_WAIT" = "true" ] && _batch_flags="--smart-wait"
      if [ -n "${RITE_TARGET_BRANCH:-}" ] && [ "${RITE_TARGET_BRANCH}" != "main" ]; then
        _batch_flags="${_batch_flags:+$_batch_flags }--branch $RITE_TARGET_BRANCH"
      fi

      # Build resume command
      _resume_cmd="rite ${_remaining[*]}"
      [ -n "$_batch_flags" ] && _resume_cmd="$_resume_cmd $_batch_flags"

      # Write the resume manifest so an auto-resume (or the user) can re-run exactly.
      # Per-batch filename prevents parallel groups from overwriting each other's manifest.
      mkdir -p "$_cap_state"
      _manifest_path="${_cap_state}/cap-resume-${RITE_BATCH_ID}.json"
      _written_epoch=$(date +%s)
      _issues_json=""
      for _ri in "${_remaining[@]}"; do
        [ -n "$_issues_json" ] && _issues_json="${_issues_json},"
        _issues_json="${_issues_json}${_ri}"
      done
      # Propagate resumed=true when already in a resumed run so a second cap in
      # the resumed batch does not trigger another auto-resume loop.
      _resumed_val="false"
      [ "${_RITE_CAP_RESUMED:-}" = "1" ] && _resumed_val="true"
      jq -n \
        --argjson issues "[${_issues_json}]" \
        --arg flags "$_batch_flags" \
        --argjson reset_epoch "$_cap_reset_epoch" \
        --arg reset_text "${_cap_reset_text:-}" \
        --argjson written "$_written_epoch" \
        --argjson resumed "$_resumed_val" \
        '{issues: $issues, flags: $flags, reset_epoch: $reset_epoch, reset_text: $reset_text, written: $written, resumed: $resumed}' \
        > "$_manifest_path"

      # Print enhanced abort message
      print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      print_error "Usage cap reached on issue #$ISSUE_NUM — aborting batch"
      print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      if [ -n "$_cap_reset_text" ]; then
        _reset_display=$(echo "$_cap_reset_text" | grep -ioE "resets [0-9]+:[0-9]+[ap]m( \([^)]+\))?" || echo "$_cap_reset_text")
        print_info "Cap ${_reset_display}"
      fi
      print_info "Resume with: $_resume_cmd"
      _print_issue_duration
      echo ""
      _CAP_ABORT=true
      break

    elif [ $EXIT_CODE -eq 18 ]; then
      # Provider auth failure — the Claude CLI is logged out (401 / "Invalid API
      # key" class error). Every subsequent issue's dev session will fail
      # identically, so halt the batch immediately rather than burning ~2min per
      # remaining issue on guaranteed-futile retries.
      # Remaining unprocessed issues are marked skipped:auth in the post-loop
      # pass below (_BATCH_AUTH_HALT flag).
      # See: lib/providers/claude.sh (fingerprint detection → exit 18)
      # See: docs/architecture/exit-codes.md — exit 18
      print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      print_error "Provider auth failure on issue #$ISSUE_NUM — halting batch"
      print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      print_error "$(provider_name) is logged out — run: claude /login"
      print_info "All remaining issues will be recorded as skipped:auth."
      print_info "Re-run this batch after logging in."
      _print_issue_duration
      echo ""
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="auth_failure"
      increment_failed   # session tracker: auth_failure counts as processed
      AUTH_FAILURE_ISSUES+=("$ISSUE_NUM")
      _BATCH_AUTH_HALT=true
      break

    elif [ $EXIT_CODE -eq 10 ]; then
      # Blocker detected - defer instead of stopping
      print_error "Issue #$ISSUE_NUM failed (exit code: $EXIT_CODE)"
      _print_issue_duration
      echo ""
      print_warning "Blocker detected - deferring issue #$ISSUE_NUM"
      BLOCKED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="blocked"

      # Send blocker notification
      send_blocker_notification "Workflow Blocker" "$ISSUE_NUM"

      print_info "Will retry after processing remaining issues"
      echo ""
      # Continue with next issue instead of breaking

    else
      # Other failure (dev or merge actually failed)
      print_error "Issue #$ISSUE_NUM failed (exit code: $EXIT_CODE)"
      _print_issue_duration
      echo ""
      FAILED_ISSUES+=("$ISSUE_NUM")
      ISSUE_STATUS["$ISSUE_NUM"]="failed"
      increment_failed   # session tracker: failed counts as processed
    fi
  fi

  # Circuit-breaker check (issue #823): after every issue, update the
  # consecutive-identical-gate-failure counter via _update_gate_breaker_counter.
  # Strategy: read the gate-findings JSON written during this workflow run
  # (identified by being newer than _gate_sentinel), extract the failure
  # signature (sorted unique failing-file paths), and compare to the last
  # seen signature.  Only gate failures with a non-empty signature advance
  # the counter; successful issues or non-gate failures reset it.
  # See: docs/architecture/exit-codes.md — exit code 16
  _issue_gate_json=""
  if [ -n "${_gate_sentinel:-}" ]; then
    # Find the gate-findings JSON written during this issue's workflow run.
    # workflow-runner.sh writes it to RITE_STATE_DIR/gate-findings-<PR>.json.
    # We use -newer so we don't pick up stale files from prior issues.
    _gate_state_dir="${RITE_STATE_DIR:-$RITE_PROJECT_ROOT/.rite/state}"
    _issue_gate_json=$(find "$_gate_state_dir" -maxdepth 1 \
      -name "gate-findings-*.json" -newer "$_gate_sentinel" 2>/dev/null | head -1 || true)
    rm -f "${_gate_sentinel:-}"
    _gate_sentinel=""
  fi

  _issue_status="${ISSUE_STATUS[$ISSUE_NUM]:-}"
  _breaker_exit=0
  _update_gate_breaker_counter "$_issue_gate_json" "$_issue_status" || _breaker_exit=$?
  if [ "$_breaker_exit" -eq 16 ]; then
    if declare -f _diag >/dev/null 2>&1; then
      _diag "GATE_CIRCUIT_BREAKER tripped consecutive=${_gate_consec_count} threshold=${RITE_BATCH_GATE_TRIP} sig=${_gate_consec_sig}"
    fi
    print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_error "Circuit breaker tripped: ${RITE_BATCH_GATE_TRIP} consecutive gate failures with identical signature"
    print_error "Shared failure signature: ${_gate_consec_sig}"
    print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_warning "Cause is likely environmental (broken test environment, unresolvable import, or red main),"
    print_warning "not per-issue — dispatching more issues would waste time and may mint follow-up issues."
    echo ""
    print_info "Remediation:"
    print_info "  1. Run: make check && bats -r tests/ (verify the test suite passes locally)"
    print_info "  2. Check for a broken import or build step matching the signature above"
    print_info "  3. If main is red, wait for the red commit to be reverted or fixed"
    print_info "  4. Re-run this batch once the environment is green"
    print_info "  Override with: RITE_BATCH_GATE_TRIP=0 rite <issues...> (disables breaker)"
    echo ""
    break
  fi

  # Issue-count cap removed. Only cumulative active-work hours cap matters now.
  CUMULATIVE_SECS=$(get_cumulative_work_seconds)
  ELAPSED_HOURS=$(( CUMULATIVE_SECS / 3600 ))
  if [ "$ELAPSED_HOURS" -ge "${RITE_MAX_SESSION_HOURS:-12}" ]; then
    print_warning "Cumulative active-work limit reached (${ELAPSED_HOURS}h)"
    print_info "Stopping batch processing"
    break
  fi

  # No between-issue delay: gh_safe handles 429/5xx with exponential backoff
  # and Claude provider calls have their own retry logic. The original 5s sleep
  # was defensive against rate limits before gh_safe existed; it's pure overhead
  # now. For an 8-issue batch the wait alone added 35s — often >90% of total
  # batch time after #316's closed-issue optimization.
  if [ "$CURRENT_ISSUE" -lt "$TOTAL_ISSUES" ]; then
    echo ""
  fi
done

# Post-loop: mark any unprocessed issues as skipped:auth when the batch was
# halted by a provider auth failure (exit 18). These issues never entered the
# workflow — they would have hit the same guaranteed-fatal auth error.
# The ISSUE_LIST may include issues that were skipped earlier for other reasons
# (dep_failed, not_found, etc.) — only issues with no recorded status are new.
if [ "$_BATCH_AUTH_HALT" = "true" ]; then
  for _unprocessed_num in "${ISSUE_LIST[@]}"; do
    if [ -z "${ISSUE_STATUS[$_unprocessed_num]:-}" ]; then
      SKIPPED_ISSUES+=("$_unprocessed_num")
      ISSUE_STATUS["$_unprocessed_num"]="skipped:auth"
    fi
  done
fi

# Post-loop: issues still in deferred_for_dep or deferred_for_parent state were
# never retried because the batch halted early (circuit-breaker, session-hours,
# auth halt, or error). Move each unique such issue to SKIPPED so it appears in
# summary accounting. ISSUE_LIST may contain the same issue multiple times (one
# entry per defer); track seen numbers to add each exactly once.
_seen_deferred=""
for _deferred_num in "${ISSUE_LIST[@]}"; do
  _deferred_status="${ISSUE_STATUS[$_deferred_num]:-}"
  if [ "$_deferred_status" = "deferred_for_dep" ] || [ "$_deferred_status" = "deferred_for_parent" ]; then
    case " $_seen_deferred " in
      *" $_deferred_num "*) continue ;;
    esac
    _seen_deferred="$_seen_deferred $_deferred_num"
    SKIPPED_ISSUES+=("$_deferred_num")
    if [ "$_deferred_status" = "deferred_for_dep" ]; then
      ISSUE_STATUS["$_deferred_num"]="dep_deferred_incomplete"
    else
      ISSUE_STATUS["$_deferred_num"]="parent_deferred_incomplete"
    fi
  fi
done

# Calculate final stats
# TOTAL_PROCESSED = issues that actually ran through the workflow (completed, failed, or blocked).
# Skipped issues (waiting_for_parent, already_closed, dep_failed, etc.) are intentionally
# excluded — they never entered the workflow — and are reported separately via ${#SKIPPED_ISSUES[@]}.
BATCH_END_TIME=$(date +%s)
TOTAL_DURATION=$((BATCH_END_TIME - BATCH_START_TIME))
_batch_compute_totals

# Restore TOTAL_ISSUES to the frozen unique-issue count for all reporting.
# The loop re-computed TOTAL_ISSUES each iteration (line below ISSUE_NUM=...) so
# it grew to include deferred-append entries. Reporting must show the operator-
# supplied count, not the inflated queue length.
TOTAL_ISSUES=$_UNIQUE_ISSUE_COUNT

# Generate summary report
# Retry blocked issues (they may have follow-up issues created now)
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  print_header "🔄 Retrying Previously Blocked Issues"

  echo "Found ${#BLOCKED_ISSUES[@]} blocked issue(s) - checking if follow-ups were created..."
  echo ""

  RETRY_SUCCESS=()
  STILL_BLOCKED=()

  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    # Check if follow-up issue was created for this blocker
    FOLLOWUP_ISSUE=$(gh_safe issue list --search "parent-pr in:body in:title" --label "review-follow-up" --state open --json number,body --jq ".[] | select(.body | contains(\"#$ISSUE_NUM\")) | .number" | head -1 || true)
    FOLLOWUP_ISSUE="${FOLLOWUP_ISSUE:-}"

    if [ -n "$FOLLOWUP_ISSUE" ]; then
      print_info "Issue #$ISSUE_NUM blocked → Follow-up #$FOLLOWUP_ISSUE created"
      print_success "No retry needed - workflow created follow-up issue"
      RETRY_SUCCESS+=("$ISSUE_NUM")
    else
      print_warning "Issue #$ISSUE_NUM still blocked (no follow-up created)"
      STILL_BLOCKED+=("$ISSUE_NUM")
    fi
    echo ""
  done

  # Update blocked list to only include still-blocked items
  BLOCKED_ISSUES=("${STILL_BLOCKED[@]}")
fi

print_header "📊 Batch Processing Summary"

# Emit Overall Statistics + Skipped Issues sections via the extracted function.
# The function is the single source of truth for this output — regression tests
# source this file and call it directly so they bind to the real formula.
_batch_print_stats

# Detailed issue breakdown
if [ $COMPLETED_ISSUES -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Completed Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$ISSUE_NUM]}" = "completed" ]; then
      DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
      PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
      echo "  ✅ Issue #$ISSUE_NUM → PR #$PR_NUM ($(_format_elapsed "$DURATION"))"
    fi
  done | sort -t'#' -k2 -n
  echo ""
fi

if [ ${#MERGED_CLEANUP_FAILED[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Merged (with cleanup warnings)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${MERGED_CLEANUP_FAILED[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
    REPO_URL=$(gh_safe repo view --json url --jq '.url' || true)
    REPO_URL="${REPO_URL:-}"
    if [ -n "$REPO_URL" ] && [ "$PR_NUM" != "N/A" ]; then
      echo "  ⚠️  Issue #$ISSUE_NUM → PR #$PR_NUM ($(_format_elapsed "$DURATION")) - ${REPO_URL}/pull/${PR_NUM}"
    else
      echo "  ⚠️  Issue #$ISSUE_NUM → PR #$PR_NUM ($(_format_elapsed "$DURATION"))"
    fi
  done | sort -t'#' -k2 -n
  echo ""
  print_info "These PRs merged successfully but post-merge cleanup encountered errors"
  print_info "Work IS on remote — no need to re-run"
  echo ""
fi

if [ ${#FAILED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Failed Issues"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${FAILED_ISSUES[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    echo "  ❌ Issue #$ISSUE_NUM ($(_format_elapsed "$DURATION"))"
  done
  echo ""
fi

if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Still Blocked Issues (Manual Intervention Needed)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    DURATION=${ISSUE_TIME[$ISSUE_NUM]:-0}
    echo "  🚨 Issue #$ISSUE_NUM ($(_format_elapsed "$DURATION"))"
  done
  echo ""
  print_warning "These issues require manual review - no follow-up was created"
  echo ""
fi

# (Skipped Issues section is now emitted by _batch_print_stats above)

# Build comprehensive Slack summary
NOTIFICATION_MESSAGE="📊 *Batch Processing Complete*

*Overall Statistics:*
• Total Issues: $TOTAL_ISSUES
• Completed: $COMPLETED_ISSUES ✅
• Failed: ${#FAILED_ISSUES[@]} ❌
• Blocked: ${#BLOCKED_ISSUES[@]} 🚨
• Skipped: ${#SKIPPED_ISSUES[@]} ⏭️
• Issues Created: $(_batch_followups_created | grep -c . || true) 📋
• Duration: $(_format_elapsed "$TOTAL_DURATION")
• Success Rate: $((COMPLETED_ISSUES * 100 / TOTAL_ISSUES))%"

# Add merged branches section
if [ $COMPLETED_ISSUES -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*🌿 Merged Branches:*"
  for ISSUE_NUM in "${!ISSUE_STATUS[@]}"; do
    if [ "${ISSUE_STATUS[$ISSUE_NUM]}" = "completed" ]; then
      PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-""}
      BRANCH=${ISSUE_BRANCH[$ISSUE_NUM]:-"unknown"}
      CHANGES="N/A"
      [ -n "$PR_NUM" ] && CHANGES=${PR_CHANGES[$PR_NUM]:-"N/A"}
      NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• \`$BRANCH\` → PR #$PR_NUM ($CHANGES)"
    fi
  done | sort -t'#' -k2 -n
fi

# Add security doc updates section
if [ ${#SECURITY_UPDATES[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*🔒 Security Doc Updates:*"
  for update in "${SECURITY_UPDATES[@]}"; do
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• $update"
  done
fi

# Add new issues created section
if [ ${#NEW_ISSUES_CREATED[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*📝 New \`tech-debt\` Issues:*"
  for issue in "${NEW_ISSUES_CREATED[@]}"; do
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• $issue"
  done
fi

# Add failed pairs section (needs manual restart)
if [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*⚠️  Failed Pairs (Manual Restart Needed):*"
  for ISSUE_NUM in "${BLOCKED_ISSUES[@]}"; do
    PR_NUM=${ISSUE_PR[$ISSUE_NUM]:-"N/A"}
    NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE
• Issue #$ISSUE_NUM (PR #$PR_NUM) - Run: \`rite $ISSUE_NUM\`"
  done
fi

# Add session stats
SESSION_STATE=$(get_session_info)
TOTAL_TOKENS=$(echo "$SESSION_STATE" | jq -r '.tokens_used // 0' || true)
SESSION_DURATION=$(echo "$SESSION_STATE" | jq -r '.session_start // 0')
if [ "$SESSION_DURATION" != "0" ]; then
  SESSION_ELAPSED=$(( $(date +%s) - SESSION_DURATION ))
  SESSION_HOURS=$(( SESSION_ELAPSED / 3600 ))
  SESSION_MINS=$(( (SESSION_ELAPSED % 3600) / 60 ))

  NOTIFICATION_MESSAGE="$NOTIFICATION_MESSAGE

*📈 Session Stats:*
• Total Time: ${SESSION_HOURS}h ${SESSION_MINS}m
• Issues Processed: $(echo "$SESSION_STATE" | jq -r '.issues_completed // 0')
• Approx Tokens: $TOTAL_TOKENS"
fi

send_notification_all "$NOTIFICATION_MESSAGE" "normal"

# Opt-in auto-resume: if a cap abort occurred and RITE_CAP_AUTORESUME=true,
# wait for the reset time and exec a fresh rite invocation with the remaining
# issues.  attempt_cap_autoresume either execs (and does not return) or
# returns 1 when not eligible — fall through to the normal exit path.
if [ "${_CAP_ABORT:-false}" = "true" ]; then
  attempt_cap_autoresume "${_manifest_path:-}" || true
fi

# Exit with appropriate code
# Circuit-breaker trip takes priority — it is a distinct failure mode that
# requires environmental remediation before the batch can make progress.
# See: docs/architecture/exit-codes.md — exit code 16
if [ "${_gate_circuit_tripped:-false}" = "true" ]; then
  print_error "Batch halted by circuit breaker (repeated identical gate failures)"
  print_info "Signature: ${_gate_consec_sig}"
  exit 16
elif [ ${#BLOCKED_ISSUES[@]} -gt 0 ]; then
  print_warning "Batch paused due to blocker"
  exit 10
elif [ ${#FAILED_ISSUES[@]} -gt 0 ] && [ $COMPLETED_ISSUES -eq 0 ]; then
  print_error "All issues failed"
  exit 1
elif [ $COMPLETED_ISSUES -eq 0 ]; then
  print_warning "No issues completed"
  exit 0
else
  print_success "Batch processing completed"
  exit 0
fi

# Helper function: Create batch resume script
create_batch_resume_script() {
  local blocked_issue="$1"
  shift
  local remaining_issues=("$@")

  # Filter out already processed issues
  local resume_list=()
  local found_blocked=false

  for issue in "${remaining_issues[@]}"; do
    if [ "$found_blocked" = true ]; then
      resume_list+=("$issue")
    fi

    if [ "$issue" = "$blocked_issue" ]; then
      found_blocked=true
      resume_list+=("$issue")  # Include blocked issue for retry
    fi
  done

  # Create resume directory
  mkdir -p "${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/.resume"

  local resume_script="${RITE_PROJECT_ROOT}/${RITE_DATA_DIR}/.resume/resume-batch-${blocked_issue}.sh"

  cat > "$resume_script" <<EOF
#!/bin/bash
# Auto-generated batch resume script
# Blocked on issue: #${blocked_issue}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

echo "🔄 Resuming batch processing..."
echo "Remaining issues: ${resume_list[*]}"
echo ""

# Resume with remaining issues
rite ${resume_list[*]}
EOF

  chmod +x "$resume_script"

  print_success "Batch resume script created: $resume_script"
}
