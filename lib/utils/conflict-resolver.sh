#!/bin/bash
# lib/utils/conflict-resolver.sh
# Claude-assisted merge conflict resolution.
#
# Entry condition:
#   Caller may invoke from either a merge-conflict state OR a clean tree (e.g. after
#   aborting a rebase/merge). Step 3 re-runs git merge to recreate conflict markers.
#   This file does NOT push, run tests, or print to stdout.
#
# Handoff contract (issues #858, #871): the resolver SESSION only WRITES resolved
# file content — in-session git side effects are policy-blocked for agentic sessions,
# so resolved content may be left unstaged (or even untracked, in the add/add
# materialization path, which also leaves a staged deletion at the same path).
# The SCRIPT side owns staging and committing: after attempt_claude_merge_resolution
# returns 0, callers MUST run commit_resolved_conflicts() (defined below), which
# stages via scoped `git add -- <conflict-paths>` (set from _RITE_RESOLVER_CONFLICT_PATHS,
# populated before the session; falls back to `git add -A` for direct callers),
# detects the live rebase/merge/plain context, and continues/commits accordingly —
# surfacing git's stderr on failure.
#
# Exit codes (public contract — do NOT change without updating all call sites):
#   0 = all conflicts resolved in the working tree (NOT necessarily staged or
#       committed — callers must complete the handoff via commit_resolved_conflicts)
#   1 = failed (merge aborted, working tree returned to clean state)
#   5 = provider usage cap reached (propagate to batch abort — do NOT fall back)
#
# Output: stderr only — stdout is reserved for pipe data per project convention.
#
# Invocation styles (both accepted):
#   Positional: attempt_claude_merge_resolution BRANCH ISSUE_NUMBER PR_NUMBER
#   Named:      attempt_claude_merge_resolution --branch-name B --issue-number N --pr-number P

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f attempt_claude_merge_resolution >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

# Source gh retry wrapper for resilient GitHub API calls
if ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# Source timeout wrapper (needed by provider agentic sessions).
# config.sh may skip this when RITE_LIB_DIR is pre-set.
if [ -f "$RITE_LIB_DIR/utils/timeout.sh" ] && ! declare -f run_with_timeout >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/timeout.sh"
fi

# ===================================================================
# OUTPUT HELPERS (stderr only — stdout reserved for pipe data)
# ===================================================================

_cr_info()    { echo "ℹ️  $1" >&2; }
_cr_warning() { echo "⚠️  $1" >&2; }
_cr_error()   { echo "❌ $1" >&2; }
_cr_status()  { echo "$1" >&2; }

# ===================================================================
# SHARED CHECK HELPERS
# ===================================================================

# _cr_file_has_conflict_markers FILE
#
# Fence-aware, CR-stripped conflict-marker scan for a single file.
# Returns 0 when conflict markers are found (caller's "if" branch fires),
#         1 when the file is clean.
#
# Regex anchors each marker precisely to avoid false positives:
#   <<<<<<<[[:space:]] — open-marker always followed by a space + branch name
#   =======$           — separator is exactly 7 '=' alone on the line;
#                        avoids false-positives from markdown setext underlines
#                        ("========") or doc separators ("=======foo")
#   >>>>>>>[[:space:]] — close-marker always followed by a space + branch name
#   |||||||[[:space:]] — diff3/zdiff3 base-version marker; always has a space;
#                        produced by merge.conflictstyle=diff3 or zdiff3
#
# CR-strip (tr -d '\r'): a CRLF-line-ending file ends the separator with
# "=======\r", which the anchored "=======$" misses — a bad resolution would
# be silently accepted (#533).  Stripping CR is portable (unlike '\r?' which
# GNU grep -E treats as a literal 'r').
#
# FENCE-AWARE: lines inside a ``` block are documentation, not markers.
# docs/architecture/behavioral-design.md documents this very conflict shape
# with a literal example at column 0 inside a fenced block (added by #1319).
# A plain grep matched it, so EVERY conflict touching that file became
# permanently unresolvable.  Live: #1221, where the resolver session itself
# reported "the remaining <<<<<<< at line 2225 is inside a documentation code
# block, not an actual conflict marker" and the old inline check overrode it.
#
# Tradeoff, stated deliberately: a REAL conflict region that opens inside an
# already-open fence is skipped by this scan.  That is the safer direction —
# failing closed on documented examples blocks real work every time, while the
# skipped case needs a conflict to begin mid-fence AND to survive Check 1.
#
# DO NOT WEAKEN: see #1221/#533 for the exact shapes this check guards.
_cr_file_has_conflict_markers() {
  local _cff_file="$1"
  tr -d '\r' < "$_cff_file" 2>/dev/null | awk '
      /^```/ { fence = !fence; next }
      !fence && /^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]]|\|\|\|\|\|\|\|[[:space:]])/ { found = 1; exit }
      END { exit(found ? 0 : 1) }
    '
}

# _cr_check_no_unexpected_unmerged KNOWN_FILES
#
# Check 1: abort if any currently-unmerged path is NOT in the original conflict
# set.  Called from both the in-loop verification and the outer Step 6 so the
# invariant is enforced identically in both code paths.
# On violation: prints the unexpected paths, calls git merge --abort, returns 1.
# On success: returns 0.
_cr_check_no_unexpected_unmerged() {
  local _cnuu_known_files="$1"
  local _cnuu_unexpected=""
  local _cnuu_u_path
  while IFS= read -r _cnuu_u_path; do
    [ -z "$_cnuu_u_path" ] && continue
    if ! printf '%s\n' "$_cnuu_known_files" | grep -qxF "$_cnuu_u_path"; then
      _cnuu_unexpected="${_cnuu_unexpected}${_cnuu_u_path}
"
    fi
  done < <(git diff --name-only --diff-filter=U 2>/dev/null || true)

  if [ -n "${_cnuu_unexpected:-}" ]; then
    _cr_error "Unmerged path(s) the session was never given:"
    printf '%s' "$_cnuu_unexpected" | sed 's/^/    /' >&2
    git merge --abort 2>/dev/null || true
    return 1
  fi
  return 0
}

# ===================================================================
# POST-RESOLUTION VIABILITY GATES (issue #1603)
# ===================================================================

# _cr_check_resolution_gates FILES
#
# Check 3 (syntax) and Check 4 (test-count) on the resolved working-tree files.
# Called by attempt_claude_merge_resolution after Check 2 (marker scan), before
# commit_resolved_conflicts.  Both gates are deliberately narrow and
# deterministic — they catch "unparseable" and "coverage vanished", not
# "merged wrong".  Full lint/test suites belong in the post-commit gate, not here.
#
# Check 3: bash -n on every resolved *.sh file and every file under bin/.
# Check 4: for every resolved *.bats file, count ^@test lines in the merged
#          file and in both index parents (stage 2 = ours/HEAD, stage 3 =
#          theirs/MERGE_HEAD or rebased commit).  Fail when the merged count is
#          strictly lower than BOTH parents — a count below both sides means the
#          resolution invented a deletion, which is the #1328 signature.  When
#          only one parent has the file (e.g. modify/delete conflict), the
#          comparison is skipped: the missing side is treated as absent, not 0.
#
# Returns:
#   0 — all files passed both gates
#   1 — at least one file failed; per-file reason reported to stderr
#
# A CONFLICT_RESOLVE_GATE diag line is emitted on every call (pass or fail)
# when _diag is loaded (logging.sh is sourced by callers, not by this file).
_cr_check_resolution_gates() {
  local _crg_files="$1"
  local _crg_failed=false
  local _crg_n_syntax=0
  local _crg_n_testcount=0
  local _crg_f
  local _crg_syntax_out
  local _crg_merged_count
  local _crg_has_ours
  local _crg_has_theirs
  local _crg_ours_count
  local _crg_theirs_count
  local _crg_fail_testcount

  while IFS= read -r _crg_f; do
    [ -z "$_crg_f" ] && continue

    # Check 3: Syntax gate — *.sh files and files under bin/ (skip if deleted)
    case "$_crg_f" in
      *.sh|bin/*)
        if [ -f "$_crg_f" ]; then
          _crg_syntax_out=""
          if ! _crg_syntax_out=$(bash -n "$_crg_f" 2>&1); then
            _cr_error "Syntax error in resolved file: $_crg_f"
            printf '%s\n' "$_crg_syntax_out" >&2
            _crg_failed=true
            _crg_n_syntax=$((_crg_n_syntax + 1))
          fi
        fi
        ;;
    esac

    # Check 4: Test-count gate — *.bats files
    # A deleted .bats file (not present in working tree) has a merged count of 0,
    # which is the strongest instance of the coverage-vanished class: if both
    # parents had tests, a deletion passes the strictly-below-both check.
    # Strictly-lower-than-both is the signal: a legitimate merge may drop tests
    # that one side deleted (count falls below the higher parent only), but a
    # count below BOTH sides means the resolution invented a deletion — the
    # #1328 signature (four tests silently stopped asserting anything, main red
    # for a week before #1593 caught it).
    case "$_crg_f" in
      *.bats)
        if [ -f "$_crg_f" ]; then
          _crg_merged_count=$(grep -c '^@test ' "$_crg_f" || true)
        else
          _crg_merged_count=0
        fi
        _crg_has_ours=false
        _crg_has_theirs=false
        _crg_ours_count=""
        _crg_theirs_count=""

        # git cat-file -e exits 0 when the object exists in the index at that
        # stage, non-zero otherwise.  Stage 2 = ours (HEAD), stage 3 = theirs
        # (MERGE_HEAD or the rebased commit).
        git cat-file -e ":2:${_crg_f}" 2>/dev/null && _crg_has_ours=true || true
        git cat-file -e ":3:${_crg_f}" 2>/dev/null && _crg_has_theirs=true || true

        if [ "$_crg_has_ours" = true ]; then
          _crg_ours_count=$(git show ":2:${_crg_f}" 2>/dev/null | grep -c '^@test ' || true)
        fi
        if [ "$_crg_has_theirs" = true ]; then
          _crg_theirs_count=$(git show ":3:${_crg_f}" 2>/dev/null | grep -c '^@test ' || true)
        fi

        # Skip when only one parent has the file — it is a new file on that
        # side, not a deletion, so there is no coverage floor to enforce.
        _crg_fail_testcount=false
        if [ "$_crg_has_ours" = true ] && [ "$_crg_has_theirs" = true ]; then
          if [ "$_crg_merged_count" -lt "$_crg_ours_count" ] \
             && [ "$_crg_merged_count" -lt "$_crg_theirs_count" ]; then
            _crg_fail_testcount=true
          fi
        fi

        if [ "$_crg_fail_testcount" = true ]; then
          _cr_error "Test count dropped in resolved file: $_crg_f (merged=${_crg_merged_count} ours=${_crg_ours_count} theirs=${_crg_theirs_count})"
          _crg_failed=true
          _crg_n_testcount=$((_crg_n_testcount + 1))
        fi
        ;;
    esac
  done <<< "$_crg_files"

  if declare -f _diag >/dev/null 2>&1; then
    local _crg_outcome="passed"
    [ "$_crg_failed" = true ] && _crg_outcome="failed"
    _diag "CONFLICT_RESOLVE_GATE outcome=${_crg_outcome} syntax=${_crg_n_syntax} testcount=${_crg_n_testcount}"
  fi

  [ "$_crg_failed" = false ]
}

# ===================================================================
# ADD/ADD OVERWRITE-COLLISION DETECTION (issue #783)
# ===================================================================
#
# When two branches independently CREATE different files at the SAME path,
# the stash → rebase → stash-pop flow (stale-branch.sh) fails with ZERO
# unmerged entries: git refuses to overwrite the now-tracked file with the
# stashed/untracked version ("already exists, no checkout" / "would be
# overwritten by merge"). This is NOT a 3-way content conflict, so the
# `--diff-filter=U` signal the resolver keys off is empty. Without explicit
# detection the resolver mistakes this for either "merge succeeded" or the
# generic "unexpected state" bail — surfacing nothing actionable.
#
# Detection has two independent signals (either is sufficient):
#   1. git output matches the overwrite/untracked-collision signatures
#   2. a preserved stash holds an untracked file at a path that the current
#      tree now TRACKS (the realistic stale-branch case: the colliding stash
#      is left un-popped, so the resolver's own `git merge` reports
#      "Already up to date" and there is no git error text to inspect).

# _cr_output_signals_overwrite_collision OUTPUT
# Returns 0 if the captured git output text matches a known overwrite/untracked
# collision signature, 1 otherwise.
_cr_output_signals_overwrite_collision() {
  local _out="${1:-}"
  [ -z "$_out" ] && return 1
  echo "$_out" | grep -qiE 'already exists, no checkout|would be overwritten by (merge|checkout)|untracked working tree files would be overwritten'
}

# _cr_stash_untracked_collision_paths
# Prints (newline-delimited) the paths held as UNTRACKED files in the most
# recent stash that ALSO already exist (tracked or present) in the current
# working tree — i.e. a same-path add/add collision that blocked a stash pop.
# Prints nothing when there is no stash, or no colliding untracked path.
# Conservative: only files git records as untracked-in-stash are considered.
_cr_stash_untracked_collision_paths() {
  git rev-parse --verify --quiet refs/stash >/dev/null 2>&1 || return 0
  local _untracked
  # `stash show --include-untracked --name-only` lists ALL files in the stash
  # (tracked + untracked); we only want the untracked ones, which are the only
  # ones that produce the "already exists, no checkout" pop failure. Diff the
  # untracked-only commit (stash@{0}^3) against its parent to get exactly the
  # untracked set. Falls back to empty when the stash has no untracked part.
  _untracked=$(git show --name-only --pretty=format: 'stash@{0}^3' 2>/dev/null || true)
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    # Colliding only if the path now exists in the working tree (it would be
    # clobbered by the pop). A tracked-and-present file is the add/add case.
    if [ -e "$_p" ]; then
      printf '%s\n' "$_p"
    fi
  done <<< "$_untracked"
}

# _cr_materialize_addadd_conflict PATH
# Turns a detected same-path add/add collision into a real in-file 3-way
# conflict so the existing LLM resolution flow (Step 4-6) can content-merge it.
# The current on-disk version (main/HEAD's file) becomes the HEAD side; the
# stashed untracked version becomes the incoming side. The file is left with
# standard conflict markers and recorded as unmerged in the index, exactly as
# `git merge` would for a tracked add/add conflict — so the downstream verify
# checks (Check 1 + Check 2) validate the LLM's resolution identically.
# Returns 0 on success (an unmerged conflict now exists), 1 if it could not
# reconstruct both sides (caller should fall back to surfacing both versions).
_cr_materialize_addadd_conflict() {
  local _path="$1"
  [ -z "$_path" ] && return 1
  # The incoming (branch) version lives in the untracked part of the stash.
  local _incoming
  _incoming=$(git show "stash@{0}^3:$_path" 2>/dev/null || true)
  # The current (main/HEAD) version is on disk now.
  [ -f "$_path" ] || return 1
  local _ours
  _ours=$(cat "$_path" 2>/dev/null || true)
  # Reconstruct standard conflict markers (HEAD = current/main, incoming = branch).
  {
    printf '<<<<<<< HEAD\n'
    printf '%s\n' "$_ours"
    printf '=======\n'
    printf '%s\n' "$_incoming"
    printf '>>>>>>> stash (branch %s)\n' "${_cr_branch_name:-incoming}"
  } > "$_path" || return 1
  # Mark the path unmerged in the index so the standard verify path applies.
  # Best-effort: if the index update fails, the in-file markers still let the
  # LLM resolve, and Check 2 (marker scan) will validate.
  git rm --cached --quiet "$_path" 2>/dev/null || true
  return 0
}

# ===================================================================
# PUBLIC: attempt_claude_merge_resolution
# ===================================================================

# attempt_claude_merge_resolution [OPTIONS]
#
# Attempts to resolve merge conflicts using an agentic Claude session.
# May be called from a clean tree (e.g. after a caller aborts rebase/merge) or
# from an active conflict state. Step 3 re-runs git merge to recreate conflict
# markers regardless of entry state.
#
# Options (all optional):
#   --issue-number NUM    GitHub issue number
#   --issue-desc TEXT     Issue title/description
#   --pr-number NUM       GitHub PR number
#   --branch-name NAME    Branch name (derived from HEAD if omitted)
#   --merge-target REF    What we're merging (default: origin/main)
#   --timeout SECONDS     Agentic session timeout (default: RITE_FIX_TIMEOUT or 1800)
#
# Returns:
#   0 = all conflicts resolved in the working tree (caller must stage + commit
#       via commit_resolved_conflicts — the session cannot run git side effects)
#   1 = failed (merge aborted, working tree clean)
#
# Side effects:
#   - Loads dev provider (caller must reload their provider after if needed)
#   - On success: resolved content is in the working tree; staging state varies
#     (the add/add materialization path leaves resolved content untracked with a
#     staged deletion at the same path). Run commit_resolved_conflicts next.
#   - On failure: merge is aborted, working tree is clean
attempt_claude_merge_resolution() {
  local _cr_issue_number=""
  local _cr_issue_desc=""
  local _cr_pr_number=""
  local _cr_branch_name=""
  # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: positional-caller cold-start default; all rite callers pass --merge-target explicitly per #1039
  local _cr_merge_target="origin/main"
  local _cr_timeout="${RITE_FIX_TIMEOUT:-1800}"
  local _cr_diff_lines="${RITE_CONFLICT_DIFF_LINES:-200}"

  # Parse arguments — accept both named flags and positional form:
  #   Positional: attempt_claude_merge_resolution BRANCH ISSUE_NUMBER PR_NUMBER
  #   Named:      --branch-name B --issue-number N --pr-number P
  # Positional detection: first arg doesn't start with '--'
  if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
    # Positional form
    _cr_branch_name="${1:-}"
    _cr_issue_number="${2:-}"
    _cr_pr_number="${3:-}"
  else
    # Named flags
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue-number) _cr_issue_number="$2"; shift 2 ;;
        --issue-desc)   _cr_issue_desc="$2"; shift 2 ;;
        --pr-number)    _cr_pr_number="$2"; shift 2 ;;
        --branch-name)  _cr_branch_name="$2"; shift 2 ;;
        --merge-target) _cr_merge_target="$2"; shift 2 ;;
        --timeout)      _cr_timeout="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
  fi

  # Derive branch name if not provided
  if [ -z "$_cr_branch_name" ]; then
    _cr_branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  fi

  # ── Step 1: Check for any active conflict state ──
  # Callers may invoke us from a clean tree (they aborted the rebase/merge before
  # calling, which is the common pattern in stale-branch.sh and divergence-handler.sh).
  # We record files here if we're mid-merge — Step 2 aborts it and gathers context,
  # then Step 3 re-runs the merge to recreate conflict markers for Claude.
  # After Step 3 re-creates the conflict, we refresh _cr_conflict_files from the live state.
  local _cr_conflict_files
  _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

  # ── Step 2: Abort any in-progress merge and gather context ──
  # No-op when called from a clean tree (the common caller pattern).
  git merge --abort 2>/dev/null || true

  # Convert the newline-delimited conflict-file list to an array so that each
  # file path is passed as a distinct, properly-quoted argument to git commands.
  # Using a while-read loop (not mapfile) for bash 3.2 compatibility.
  # When _cr_conflict_files is empty the loop body never runs, leaving the array empty.
  local _cr_conflict_files_arr=()
  while IFS= read -r _cr_f; do
    [ -n "$_cr_f" ] && _cr_conflict_files_arr+=("$_cr_f")
  done <<< "$_cr_conflict_files"

  # Gather context diffs before Step 3 re-runs the merge.
  # If _cr_conflict_files is empty (clean-tree entry), these diffs will be based
  # on all files changed between HEAD and merge target — still useful context for Claude.
  # When the array is non-empty, pass "-- file1 file2 ..." with each path quoted.
  local _cr_branch_diff=""
  if [ "${#_cr_conflict_files_arr[@]}" -gt 0 ]; then
    _cr_branch_diff=$(git diff "${_cr_merge_target}...HEAD" -- "${_cr_conflict_files_arr[@]}" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
  else
    _cr_branch_diff=$(git diff "${_cr_merge_target}...HEAD" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
  fi

  # Main's commits and diff to conflicting files since branch diverged
  local _cr_merge_base
  _cr_merge_base=$(git merge-base HEAD "$_cr_merge_target" 2>/dev/null || echo "")
  local _cr_main_log=""
  local _cr_main_diff=""
  if [ -n "$_cr_merge_base" ]; then
    if [ "${#_cr_conflict_files_arr[@]}" -gt 0 ]; then
      _cr_main_log=$(git log --oneline "${_cr_merge_base}..${_cr_merge_target}" -- "${_cr_conflict_files_arr[@]}" 2>/dev/null | head -20 || echo "")
      _cr_main_diff=$(git diff "${_cr_merge_base}..${_cr_merge_target}" -- "${_cr_conflict_files_arr[@]}" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
    else
      _cr_main_log=$(git log --oneline "${_cr_merge_base}..${_cr_merge_target}" 2>/dev/null | head -20 || echo "")
      _cr_main_diff=$(git diff "${_cr_merge_base}..${_cr_merge_target}" 2>/dev/null | head -"$_cr_diff_lines" || echo "")
    fi
  fi

  # PR context (if available)
  local _cr_pr_title="" _cr_pr_body=""
  if [ -n "$_cr_pr_number" ]; then
    _cr_pr_title=$(gh_safe pr view "$_cr_pr_number" --json title --jq '.title' 2>/dev/null || echo "")
    _cr_pr_body=$(gh_safe pr view "$_cr_pr_number" --json body --jq '.body' 2>/dev/null || echo "")
  fi

  # Issue context (if available and no PR)
  local _cr_issue_title=""
  if [ -n "$_cr_issue_number" ] && [ -z "$_cr_pr_number" ]; then
    _cr_issue_title=$(gh_safe issue view "$_cr_issue_number" --json title --jq '.title' 2>/dev/null || echo "${_cr_issue_desc:-}")
  fi

  # ── Step 3: Re-start merge so Claude sees conflict markers ──
  # Capture merge output (stdout+stderr) so we can distinguish a genuine
  # success from an overwrite/untracked add/add collision (issue #783).
  local _cr_merge_output _cr_merge_exit=0
  _cr_merge_output=$(git merge "$_cr_merge_target" --no-edit 2>&1) || _cr_merge_exit=$?

  if [ "$_cr_merge_exit" -eq 0 ]; then
    # git reports success — but a same-path add/add collision can hide here:
    # in the stale-branch flow the branch is already rebased onto main, so this
    # merge is "Already up to date" while the colliding branch file sits
    # un-popped in the stash. Detect and convert it to a resolvable conflict.
    local _cr_addadd_paths
    _cr_addadd_paths=$(_cr_stash_untracked_collision_paths || true)
    if [ -n "$_cr_addadd_paths" ]; then
      _cr_warning "Same-path add/add collision detected (stashed branch file overwrites a now-tracked path)"
      echo "$_cr_addadd_paths" | sed 's/^/  /' >&2
      local _cr_materialized=false
      while IFS= read -r _cr_ap; do
        [ -z "$_cr_ap" ] && continue
        if _cr_materialize_addadd_conflict "$_cr_ap"; then
          _cr_materialized=true
        fi
      done <<< "$_cr_addadd_paths"
      if [ "$_cr_materialized" = true ]; then
        _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        # Materialized files are removed-from-index (git rm --cached); pick them
        # up via the working-tree path list when --diff-filter=U is empty.
        if [ -z "$_cr_conflict_files" ]; then
          _cr_conflict_files="$_cr_addadd_paths"
        fi
        _cr_info "Routing same-path add/add collision to content merge"
      else
        # Could not reconstruct both sides — surface them clearly instead of bailing.
        _cr_error "Same-path add/add collision at: $(echo "$_cr_addadd_paths" | tr '\n' ' ')"
        _cr_error "Two independently-created versions exist at the same path; a content merge is required (run 'git stash show -p' to inspect the branch version)."
        return 1
      fi
    else
      # Genuine success — no conflicts to resolve
      _cr_info "Merge succeeded — no conflict resolution needed"
      return 0
    fi
  else
    # Merge reported failure. Refresh conflict files from the live merge state
    # (covers the case where Step 1 found none because the caller aborted before
    # invoking us).
    _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$_cr_conflict_files" ]; then
      # Zero unmerged entries but the merge failed: this is the add/add
      # overwrite collision class (issue #783), NOT a true unexpected state.
      # The authoritative signal is a stash holding an untracked file that now
      # collides with a tracked path; the git output signature corroborates it.
      local _cr_addadd_paths=""
      _cr_addadd_paths=$(_cr_stash_untracked_collision_paths || true)
      if [ -z "$_cr_addadd_paths" ] && _cr_output_signals_overwrite_collision "$_cr_merge_output"; then
        # Output names a collision but no colliding stash was found — surface it.
        _cr_error "Overwrite/untracked collision during merge; could not identify a stashed colliding path. Inspect manually (git status; git stash list)."
        git merge --abort 2>/dev/null || true
        return 1
      fi
      if [ -n "$_cr_addadd_paths" ]; then
        _cr_warning "Same-path add/add collision detected (overwrite blocked, zero unmerged entries)"
        echo "$_cr_addadd_paths" | sed 's/^/  /' >&2
        git merge --abort 2>/dev/null || true
        local _cr_materialized=false
        while IFS= read -r _cr_ap; do
          [ -z "$_cr_ap" ] && continue
          if _cr_materialize_addadd_conflict "$_cr_ap"; then
            _cr_materialized=true
          fi
        done <<< "$_cr_addadd_paths"
        if [ "$_cr_materialized" = true ]; then
          _cr_conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
          if [ -z "$_cr_conflict_files" ]; then
            _cr_conflict_files="$_cr_addadd_paths"
          fi
          _cr_info "Routing same-path add/add collision to content merge"
        else
          _cr_error "Same-path add/add collision at: $(echo "$_cr_addadd_paths" | tr '\n' ' ')"
          _cr_error "Two independently-created versions exist at the same path; a content merge is required (run 'git stash show -p' to inspect the branch version)."
          return 1
        fi
      else
        _cr_error "Merge failed but no unmerged files found — unexpected state"
        git merge --abort 2>/dev/null || true
        return 1
      fi
    fi
  fi

  # ── Step 3b: Deterministic pre-pass for append-only artifacts ──
  #
  # Some conflicts have exactly one correct resolution and need no judgment.
  # The drift log is append-only: every entry is a self-delimited block with
  # its own recorded: ISO8601 timestamp, entries are mutually independent, and
  # burn-down removes whole blocks. The resolution is therefore the union of
  # both sides ordered by timestamp — computable, not a matter of opinion.
  #
  # Resolving these here means a batch whose only conflict is the drift log
  # never pays for a provider session at all. Two of the three conflicts in
  # dogfooding logs were exactly that (#1231 pr:1299, #1143 pr:1312), each
  # burning a 60-274s session to arrive at this function's output.
  #
  # Every handler must be total and must fail CLOSED: if it cannot prove the
  # conflict is the shape it understands, it returns non-zero and the path
  # stays in the LLM list. A deterministic merge is only allowed to replace
  # judgment where there is no judgment to make.
  local _cr_deterministic=0
  local _cr_llm_files=""
  # Declared before the deterministic branch because BOTH arms set it: the
  # all-deterministic arm skips the session and reports success directly.
  local _cr_session_exit=0
  local _cr_dp _cr_driftrel
  while IFS= read -r _cr_dp; do
    [ -n "$_cr_dp" ] || continue
    # Load the drift-log library once so both the path accessor and the merge
    # function are available. It owns the path literal (Rule 19 allowlists it),
    # which keeps a "sharkrite-*" string out of this file entirely.
    if ! declare -f drift_log_relpath >/dev/null 2>&1; then
      # shellcheck source=/dev/null
      source "${RITE_LIB_DIR:-}/utils/drift-log.sh" 2>/dev/null || true
    fi
    _cr_driftrel=""
    if declare -f drift_log_relpath >/dev/null 2>&1; then
      _cr_driftrel=$(drift_log_relpath || true)
    fi

    if [ -n "${_cr_driftrel:-}" ] \
       && { [ "$_cr_dp" = "$_cr_driftrel" ] || [ "${_cr_dp%/$_cr_driftrel}" != "$_cr_dp" ]; } \
       && declare -f drift_log_union_merge >/dev/null 2>&1 \
       && drift_log_union_merge "$_cr_dp"; then
      _cr_deterministic=$((_cr_deterministic + 1))
      continue
    fi
    _cr_llm_files="${_cr_llm_files}${_cr_dp}
"
  done <<< "$_cr_conflict_files"

  if [ "$_cr_deterministic" -gt 0 ]; then
    _cr_info "Resolved ${_cr_deterministic} append-only conflict(s) deterministically — no provider call" >&2
    # _diag lives in logging.sh, which this file does not source — the callers
    # (stale-branch.sh, mid-run-rebase.sh) do. Guarded so a direct caller that
    # has not loaded it still works.
    if declare -f _diag >/dev/null 2>&1; then
      _diag "CONFLICT_RESOLVER_DETERMINISTIC issue=${_cr_issue_number:-} pr=${_cr_pr_number:-} resolved=${_cr_deterministic} llm_remaining=$(printf '%s' "${_cr_llm_files:-}" | grep -c . || true)"
    fi
  fi

  # Everything resolved without the LLM — skip Steps 4-5 entirely and go
  # straight to verification, which is oracle-agnostic about HOW a path was
  # resolved.
  _cr_llm_files=$(printf '%s' "$_cr_llm_files" | grep -v '^$' || true)
  if [ -z "${_cr_llm_files:-}" ]; then
    _cr_info "All conflicts resolved deterministically — skipping provider session" >&2
    _cr_session_exit=0
  else

  # ── Steps 4-6: Session + verify — bounded retry loop ──
  #
  # The session is a probabilistic producer: at large conflict sets it reliably
  # resolves most files but may leave markers in a few (live: 2026-11-04,
  # doc-refactor rebase, 8 of 11 files correct on first attempt). A single abort
  # discards the correct work. This loop re-prompts with ONLY the still-failing
  # files, up to _CR_MAX_RESOLVE_ATTEMPTS total — matching the pattern used by
  # the review loop (local-review.sh ~line 637) and the fix loop
  # (assess-and-resolve.sh, up to 3 retries on ACTIONABLE_NOW findings).
  #
  # Timeout budget is shared: each attempt gets (total - elapsed), not a fresh
  # copy of the full timeout. Worst-case wall-clock stays at one _cr_timeout.
  #
  # _CR_MAX_RESOLVE_ATTEMPTS is a module constant, not operator config: the right
  # number is small and evidence-based (the 2026-11-04 live failure needed only 2
  # attempts; more than 3 suggests a structural problem in the conflict set, not a
  # simple marker miss). Rule 36 (UNDOCUMENTED_RITE_VAR) only applies to RITE_*
  # vars; this underscore-prefixed constant is intentionally internal.
  local _CR_MAX_RESOLVE_ATTEMPTS=3
  local _cr_remaining_files="$_cr_llm_files"
  local _cr_attempt=0
  local _cr_start_time
  _cr_start_time=$(date +%s)
  local _cr_attempt_timeout=0
  local _cr_still_failing=""
  local _cr_still_count=0
  local _cr_remaining_count=0
  local _cr_retry_ctx=""
  local _cr_prompt=""
  local _cr_stderr_file=""

  # Provider setup runs once — healthcheck and preflight are lightweight; running
  # them once up front avoids paying auth-check cost on every retry attempt.
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  load_provider "${RITE_DEV_PROVIDER:-claude}"

  # Provider preflight: fail fast on untrusted workspace (Claude CLI >=2.1.284).
  # Skip when the sentinel is already set — the run-level preflight (batch or
  # single-issue) already passed, so re-checking here would fire a redundant
  # 120s-bounded API call per conflict resolution inside the same run.
  # Standalone callers (rite --sync, direct script invocation) never export the
  # sentinel, so they always get the full check.
  provider_detect_cli || { git merge --abort 2>/dev/null || true; return 1; }
  if [ "${_RITE_PROVIDER_PREFLIGHT_OK:-}" != "true" ]; then
    if ! provider_healthcheck; then
      git merge --abort 2>/dev/null || true
      return 1
    fi
  fi

  # Publish the pre-session conflict-path list for commit_resolved_conflicts.
  # Must reflect the FULL conflict set (including deterministically-resolved files)
  # so commit_resolved_conflicts stages every path. The variable is cleared after use.
  # Using -A would sweep operator WIP that was stash-popped into the tree before
  # this call (dirty-worktree → stash → abort → pop → resolve flow in stale-branch.sh).
  _RITE_RESOLVER_CONFLICT_PATHS="$_cr_conflict_files"
  export _RITE_RESOLVER_CONFLICT_PATHS

  while [ "$_cr_attempt" -lt "$_CR_MAX_RESOLVE_ATTEMPTS" ]; do
    _cr_attempt=$((_cr_attempt + 1))
    _cr_remaining_count=$(printf '%s\n' "$_cr_remaining_files" | grep -c . || true)

    # Per-attempt diagnostic — health-report aggregation tracks attempt count
    # and how many files still needed LLM resolution going in.
    if declare -f _diag >/dev/null 2>&1; then
      _diag "CONFLICT_RESOLVE_ATTEMPT n=${_cr_attempt} remaining=${_cr_remaining_count}"
    fi

    # Compute remaining time budget for this attempt.
    # Shared budget: attempt N gets (total - elapsed), not a fresh timeout copy.
    _cr_elapsed=$(( $(date +%s) - _cr_start_time ))
    _cr_attempt_timeout=$(( _cr_timeout - _cr_elapsed ))
    if [ "$_cr_attempt_timeout" -le 0 ]; then
      _cr_error "Timeout budget (${_cr_timeout}s) exhausted before attempt ${_cr_attempt}"
      git merge --abort 2>/dev/null || true
      return 1
    fi

    # ── Step 4: Build prompt ──
    # Use _cr_remaining_files so each attempt only asks the session to resolve
    # files that still have markers — already-resolved files must not be re-touched.
    _cr_status "Conflicts to resolve via Claude (attempt ${_cr_attempt}/${_CR_MAX_RESOLVE_ATTEMPTS}):" >&2
    echo "$_cr_remaining_files" | sed 's/^/  /' >&2

    # Retry preamble: injected on attempt 2+ so the session knows exactly why
    # these files are being re-submitted and which files to leave untouched.
    _cr_retry_ctx=""
    if [ "$_cr_attempt" -gt 1 ]; then
      _cr_retry_ctx="RETRY: This is attempt ${_cr_attempt} of ${_CR_MAX_RESOLVE_ATTEMPTS}. The previous session left conflict markers in the following files — these are the ONLY files that still need resolution. Files not in this list were already resolved correctly and MUST NOT be modified.

Reason per path: conflict markers remain in the working tree.

"
    fi

    _cr_prompt="${_cr_retry_ctx}You are running inside a Sharkrite (\`rite\`) workflow session in a git worktree with merge conflicts that need resolution.

main is the source of truth. It represents accepted, merged work. This branch is the newcomer.
Your job: rebase this branch's INTENT onto main's current reality.

Write the resolved content to each conflicting file. The workflow stages and commits it after
the session — do NOT run git add, git commit, git push, or any gh commands.

RULES:
- main wins on structure: if main changed an API contract, function signature, config schema,
  database model, or interface — adopt main's version. Then adapt this branch's changes to work
  with main's structure.
- Preserve this branch's intent, not its exact code. If main restructured code that this branch
  also modified, re-implement the branch's purpose on top of main's new structure.
- NEVER create dual code paths, compatibility shims, or 'detect and route' patterns to avoid
  choosing between the two sides. Pick main's structure, apply the branch's feature to it.
- If both sides added genuinely independent, non-overlapping features (different functions,
  different endpoints, different config keys), include both.
- When unsure which side should win for a specific conflict, prefer main's version — it is
  safer to under-apply the branch than to break accepted work."

    # Append context sections based on what's available
    if [ -n "$_cr_pr_number" ] && [ -n "$_cr_pr_title" ]; then
      _cr_prompt+="

## This PR (#${_cr_pr_number}): ${_cr_pr_title}
${_cr_pr_body:-}"
    elif [ -n "$_cr_issue_number" ]; then
      _cr_prompt+="

## Issue #${_cr_issue_number}: ${_cr_issue_title:-${_cr_issue_desc:-}}"
    fi

    _cr_prompt+="

## This branch's changes to the conflicting files:
\`\`\`
${_cr_branch_diff:-No diff available}
\`\`\`

## Commits on ${_cr_merge_target} that touched these files since branch diverged:
${_cr_main_log:-No commits found}

## ${_cr_merge_target}'s diff to conflicting files:
\`\`\`
${_cr_main_diff:-No diff available}
\`\`\`

## Conflicting files to resolve:
${_cr_remaining_files}

Read each conflicting file now. The files contain conflict markers (<<<<<<< HEAD, =======, >>>>>>>).
Resolve every conflict by writing the resolved content to each file. The workflow stages and commits
the resolved files after this session ends."

    # ── Step 5: Run agentic session ──
    _cr_status "Running Claude conflict resolution session (attempt ${_cr_attempt}/${_CR_MAX_RESOLVE_ATTEMPTS})..." >&2

    _cr_session_exit=0
    _cr_stderr_file=$(mktemp)

    provider_run_agentic_session "$_cr_prompt" "$_cr_attempt_timeout" true "$_cr_stderr_file" || _cr_session_exit=$?

    # Non-retryable exit-code fast paths.
    # Exit 5 = usage cap; exit 18 = auth failure (see CLAUDE.md exit-code table).
    # provider_detect_error never returns "USAGE_CAP" (only
    # PROVIDER_BUG|RATE_LIMITED|AUTH_EXPIRED|NETWORK_ERROR|UNKNOWN), so for the
    # cap the exit code is the only signal. For auth failure, exit 18 is primary
    # and provider_detect_error on stderr is belt-and-suspenders.
    if [ "$_cr_session_exit" -eq 5 ]; then
      rm -f "$_cr_stderr_file"
      git merge --abort 2>/dev/null || true
      _cr_error "Provider usage cap reached during conflict resolution"
      return 5
    fi
    if [ "$_cr_session_exit" -eq 18 ]; then
      rm -f "$_cr_stderr_file"
      git merge --abort 2>/dev/null || true
      _cr_error "Provider auth expired during conflict resolution — run: claude /login"
      return 18
    fi

    if [ "$_cr_session_exit" -ne 0 ]; then
      _cr_warning "Conflict resolution session exited with code $_cr_session_exit"
      if [ -s "$_cr_stderr_file" ]; then
        _cr_info "Session stderr:" >&2
        head -5 "$_cr_stderr_file" >&2
        # Classify before discarding: break immediately on non-retryable errors.
        local _cr_error_type
        _cr_error_type=$(provider_detect_error "$(cat "$_cr_stderr_file")" "$_cr_session_exit") || true
        if [ "$_cr_error_type" = "AUTH_EXPIRED" ]; then
          rm -f "$_cr_stderr_file"
          git merge --abort 2>/dev/null || true
          _cr_error "Provider auth expired during conflict resolution — run: claude /login"
          return 18
        fi
      fi
    fi
    if [ "$_cr_session_exit" -eq 124 ]; then
      _cr_warning "Conflict resolution session timed out"
    fi
    rm -f "$_cr_stderr_file"

    # ── Inline Verification (Step 6 for LLM path) ──

    # Check 1: No UNEXPECTED unmerged files (not retryable — abort immediately).
    # A session that introduces a new unmerged path has done something the resolver
    # cannot safely interpret; aborting is the correct response regardless of attempt count.
    _cr_check_no_unexpected_unmerged "$_cr_conflict_files" || return 1

    # Check 2: Fence-aware conflict-marker scan on the REMAINING files.
    # Collect still-failing paths — the loop uses them as the retry target on
    # the next attempt. See _cr_file_has_conflict_markers for the full rationale
    # (CR-strip for CRLF; fence-awareness for documented examples — #1221/#533).
    # DO NOT WEAKEN this check.
    _cr_still_failing=""
    while IFS= read -r _cr_f; do
      [ -z "$_cr_f" ] && continue
      [ -f "$_cr_f" ] || continue
      if _cr_file_has_conflict_markers "$_cr_f"; then
        _cr_error "Conflict markers remain in: $_cr_f"
        _cr_still_failing="${_cr_still_failing}${_cr_f}
"
      fi
    done <<< "$_cr_remaining_files"

    _cr_still_failing=$(printf '%s' "$_cr_still_failing" | grep -v '^$' || true)
    if [ -z "${_cr_still_failing:-}" ]; then
      # All remaining files resolved on this attempt.
      _cr_status "All conflicts resolved on attempt ${_cr_attempt}/${_CR_MAX_RESOLVE_ATTEMPTS}" >&2
      return 0
    fi

    # Still-failing files remain — decide: retry or abort.
    _cr_still_count=$(printf '%s\n' "$_cr_still_failing" | grep -c . || true)
    if [ "$_cr_attempt" -ge "$_CR_MAX_RESOLVE_ATTEMPTS" ]; then
      _cr_error "Conflict markers remain in ${_cr_still_count} file(s) after ${_cr_attempt} attempt(s):"
      printf '%s' "$_cr_still_failing" | sed 's/^/    /' >&2
      _cr_error "Merge was aborted. To resolve manually: re-run the merge, resolve each file listed above, then: git add <files> && git merge --continue"
      git merge --abort 2>/dev/null || true
      return 1
    fi

    _cr_warning "Attempt ${_cr_attempt}: ${_cr_still_count} file(s) still have conflict markers — retrying with remaining files only"
    _cr_remaining_files="$_cr_still_failing"
  done

  # Exited without returning (guard against future loop modifications).
  git merge --abort 2>/dev/null || true
  return 1

  fi
  # ── end of the "some paths need the LLM" branch ──
  # LLM path returns 0 or 1 from within the retry loop above.
  # Execution reaches here only when _cr_llm_files was empty (deterministic path).

  # ── Step 6: Verify resolution (deterministic path only) ──
  # LLM path: verification runs inline inside the retry loop above and returns
  # 0 or 1 from there — execution never reaches here on the LLM path.
  # Deterministic path: runs once here after all append-only conflicts resolved.

  # Check 1: No UNEXPECTED unmerged files
  #
  # Deliberately not "no unmerged files at all". This function's contract (see
  # the header) is "resolved in the WORKING TREE — the caller stages via
  # commit_resolved_conflicts, because the session cannot run git side
  # effects", and the session prompt says in as many words: "do NOT run git
  # add". So every known conflict path is still unmerged in the index at this
  # point, by design.
  #
  # The original check (#435) predated that split and asserted an empty index.
  # #932 moved staging out of the session and added the no-git-add instruction
  # but left this assertion behind, so the check could only pass when the
  # session DISOBEYED its prompt. Once it complied, every Claude conflict
  # resolution failed with "Unresolved files remain" immediately after the
  # session reported a correct resolution — live: #1231 (pr 1299) and #1143
  # (pr 1312), both 2026-10-19, both resolving append-only drift-log entries
  # correctly and both rejected.
  #
  # What is still worth catching here is an unmerged path that is NOT one the
  # session was told about: a conflict that appeared after the path list was
  # captured, or one the session silently introduced. Content validity of the
  # known paths is Check 2's job (conflict markers in the working tree), and
  # the two together are the real contract: every unmerged path is a known
  # conflict path, and every known conflict path is marker-free.
  _cr_check_no_unexpected_unmerged "$_cr_conflict_files" || return 1

  # Check 2: No literal conflict markers in resolved files (belt-and-suspenders)
  #
  # Regex anchors each marker precisely to avoid false positives — see
  # _cr_file_has_conflict_markers for the full rationale (CR-strip for CRLF,
  # fence-awareness for documented examples in ``` blocks — #1221/#533).
  # DO NOT WEAKEN this check.
  local _cr_marker_found=false
  while IFS= read -r _cr_f; do
    [ -z "$_cr_f" ] && continue
    [ -f "$_cr_f" ] || continue
    if _cr_file_has_conflict_markers "$_cr_f"; then
      _cr_error "Conflict markers remain in: $_cr_f"
      _cr_marker_found=true
    fi
  done <<< "$_cr_conflict_files"

  if [ "$_cr_marker_found" = true ]; then
    _cr_error "Conflict markers remain in the working tree after the session"
    git merge --abort 2>/dev/null || true
    return 1
  fi

  # Check 3 (syntax) and Check 4 (test-count): viability gates
  if ! _cr_check_resolution_gates "$_cr_conflict_files"; then
    git merge --abort 2>/dev/null || true
    return 1
  fi

  # Resolution verified — complete the handoff with commit_resolved_conflicts
  return 0
}

# ===================================================================
# PUBLIC: commit_resolved_conflicts
# ===================================================================

# commit_resolved_conflicts [WORKTREE_PATH]
#
# Script-side stage+commit handoff after a successful resolver session (#858).
# The resolver session WRITES resolved file content but cannot reliably stage
# or commit it (in-session git side effects are policy-blocked), so the script
# owns the whole sequence:
#
#   1. Stage the conflict paths captured before the resolver session (#871).
#      Staged set is scoped to _RITE_RESOLVER_CONFLICT_PATHS (set by
#      attempt_claude_merge_resolution before the agentic session) to avoid
#      sweeping operator WIP that was stash-popped back into the tree before
#      the resolver ran (dirty-worktree → stash → abort → pop → resolve flow).
#      Falls back to `git add -A` when the variable is unset (backward compat
#      for callers that bypass attempt_claude_merge_resolution).
#      Load-bearing BEFORE any staged-changes check: the add/add
#      materialization path leaves the index holding a staged deletion while
#      the resolved content sits UNTRACKED at the same path — committing
#      without this add would commit a bare deletion (live: issue #821, 2026-07-03).
#   2. Context detection from OBSERVABLE git state, not the documented flow:
#        rebase in progress ($git_dir/rebase-merge or rebase-apply) →
#          GIT_EDITOR=true git rebase --continue (or `git rebase --skip` when
#          the resolution left nothing to commit — the patch is already
#          upstream and --continue would refuse with "No changes")
#        merge in progress ($git_dir/MERGE_HEAD) → git commit --no-edit
#          (MERGE_MSG exists for --no-edit to reuse)
#        plain → commit staged changes with an explicit -m: no MERGE_MSG
#          exists, so a bare `git commit --no-edit` dies with "Aborting commit
#          due to empty commit message" (the exact failure 2>/dev/null
#          swallowed in issue #821); a clean index is a no-op success (the
#          resolver's internal merge auto-committed).
#   3. On failure: PRINT git's captured output (no 2>/dev/null swallowing) and
#      abort context-correctly — rebase --abort mid-rebase, merge --abort
#      mid-merge. The old inline call-site blocks ran `git merge --abort`
#      unconditionally, which no-ops mid-rebase and strands the worktree.
#
# Returns:
#   0 = resolution committed (or nothing needed committing)
#   1 = failure (context aborted, git output printed to stderr)
commit_resolved_conflicts() {
  local _crc_wt="${1:-.}"

  # Resolve the worktree's private git dir (worktree-aware: in a linked
  # worktree, rebase-merge/MERGE_HEAD live under .git/worktrees/<name>).
  local _crc_gitdir
  _crc_gitdir=$(git -C "$_crc_wt" rev-parse --git-dir 2>/dev/null || true)
  case "$_crc_gitdir" in
    ""|/*) : ;;
    # rev-parse --git-dir output is relative to the worktree when not absolute
    *) _crc_gitdir="$_crc_wt/$_crc_gitdir" ;;
  esac

  local _crc_context="plain"
  if [ -n "$_crc_gitdir" ] && { [ -d "$_crc_gitdir/rebase-merge" ] || [ -d "$_crc_gitdir/rebase-apply" ]; }; then
    _crc_context="rebase"
  elif [ -n "$_crc_gitdir" ] && [ -f "$_crc_gitdir/MERGE_HEAD" ]; then
    _crc_context="merge"
  fi

  # Stage the conflict paths captured before the resolver session, not the
  # whole worktree (-A). Using -A would sweep operator WIP that was stash-popped
  # back into the tree before attempt_claude_merge_resolution was called
  # (the dirty-worktree → stash → abort → pop → resolve flow in stale-branch.sh).
  #
  # _RITE_RESOLVER_CONFLICT_PATHS is set by attempt_claude_merge_resolution
  # immediately before the agentic session; it contains only the unmerged file
  # paths from `git diff --name-only --diff-filter=U`. We clear it here after
  # reading so it doesn't leak to subsequent calls. Falls back to -A when the
  # variable is unset (e.g. when commit_resolved_conflicts is called by a caller
  # that did not go through attempt_claude_merge_resolution, preserving backward
  # compatibility with direct callers).
  local _crc_conflict_paths="${_RITE_RESOLVER_CONFLICT_PATHS:-}"
  unset _RITE_RESOLVER_CONFLICT_PATHS

  local _crc_out=""
  local _crc_failed=false

  if [ -n "$_crc_conflict_paths" ]; then
    # Scoped staging: stage only the pre-session conflict paths (plus any newly
    # materialized versions at those paths). Reads the list line-by-line so each
    # path is passed as a distinct, properly-quoted argument to git add.
    local _crc_add_args=()
    while IFS= read -r _crc_p; do
      [ -n "$_crc_p" ] && _crc_add_args+=("$_crc_p")
    done <<< "$_crc_conflict_paths"
    if [ "${#_crc_add_args[@]}" -gt 0 ]; then
      if ! _crc_out=$(git -C "$_crc_wt" add -- "${_crc_add_args[@]}" 2>&1); then
        _crc_failed=true
      fi
    fi
  else
    # Fallback: no path list available — stage everything (backward compat).
    if ! _crc_out=$(git -C "$_crc_wt" add -A 2>&1); then
      _crc_failed=true
    fi
  fi

  if [ "$_crc_failed" = false ]; then
    case "$_crc_context" in
      rebase)
        if git -C "$_crc_wt" diff --cached --quiet 2>/dev/null; then
          # Resolution left nothing to commit (the stopped commit's change is
          # already upstream). --continue refuses with "No changes"; --skip is
          # git's documented continuation for this state.
          _crc_out=$(git -C "$_crc_wt" rebase --skip 2>&1) || _crc_failed=true
        else
          # GIT_EDITOR=true keeps --continue non-interactive (it re-opens the
          # replayed commit's message in an editor otherwise).
          _crc_out=$(GIT_EDITOR=true git -C "$_crc_wt" rebase --continue 2>&1) || _crc_failed=true
        fi
        ;;
      merge)
        # MERGE_MSG exists for --no-edit to reuse. Always commit: even an
        # index identical to HEAD needs the merge commit for ancestry.
        _crc_out=$(git -C "$_crc_wt" commit --no-edit 2>&1) || _crc_failed=true
        ;;
      *)
        # Plain context: either the resolver's internal merge auto-committed
        # (index clean — nothing to do) or the add above staged resolved
        # content with no merge/rebase in progress (add/add materialization).
        if ! git -C "$_crc_wt" diff --cached --quiet 2>/dev/null; then
          _crc_out=$(git -C "$_crc_wt" commit --no-edit -m "Resolve conflicts (Claude-assisted resolution)" 2>&1) || _crc_failed=true
        fi
        ;;
    esac
  fi

  if [ "$_crc_failed" = true ]; then
    _cr_error "Failed to commit resolved conflicts (context: $_crc_context)"
    if [ -n "$_crc_out" ]; then
      printf '%s\n' "$_crc_out" >&2
    fi
    case "$_crc_context" in
      rebase) git -C "$_crc_wt" rebase --abort 2>/dev/null || true ;;
      merge)  git -C "$_crc_wt" merge --abort 2>/dev/null || true ;;
    esac
    return 1
  fi
  return 0
}
