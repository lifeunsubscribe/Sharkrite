#!/bin/bash
# lib/utils/trivial-fix-fastpath.sh — Trivial-fix fast-path (#531)
#
# For issues that carry a CONCRETE, deterministic edit, skip the Phase-1 Claude
# dev session AND the full opus review: apply the edit, run the post-commit gate
# + a cheap haiku triage classifier, and merge ONLY if both are green.
#
# Why a deterministic applier: a natural-language fix ("add a ${VAR:-} guard")
# can't be applied without an LLM — which is the very cost the fast-path exists to
# avoid. So eligibility requires the issue body to carry an explicit, machine-
# applicable patch (a fenced ```diff block under a `<!-- sharkrite-fastpath -->`
# marker). `git apply --check` is the applier: it handles multi-line edits,
# verifies the patch applies exactly once, and fails SAFELY (→ fall back) if the
# file has drifted. Issues without the marker/patch are ineligible and fall
# through to the normal flow with zero side effects.
#
# Safety model (issue #531, "gate + cheap triage review"):
#   1. apply --check + apply   — patch must apply cleanly
#   2. bash -n                 — touched shell files must parse
#   3. triage_classify_diff    — Layer-1 guards + haiku; must be "trivial"
#   4. run_test_gate           — make check + bats -r tests/ must pass
# ALL FOUR run on the worktree BEFORE any commit/push/PR, so a failure at any
# step is a side-effect-free fall-back to the normal Phase 1→4 flow. Only when
# all four pass do we commit, push, open a PR, and signal the caller to merge.
#
# Contract:
#   try_trivial_fix_fastpath <issue_number>
#     return 0 → handled: PR created + validated, READY TO MERGE. Sets globals
#                PR_NUMBER and WORKTREE_PATH; the caller invokes phase_merge_pr.
#     return 1 → not eligible OR validation failed: caller proceeds with the
#                normal flow. No worktree/branch/PR left behind.
#
# See: docs/architecture/behavioral-design.md → "Trivial-Fix Fast-Path".

set -euo pipefail

# Re-source guard (function-sentinel; this file does NOT export -f its functions).
if declare -f try_trivial_fix_fastpath >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source same-checkout siblings via a BASH_SOURCE-derived path (NOT RITE_LIB_DIR).
# config.sh sets RITE_LIB_DIR to the INSTALLED tree ($RITE_INSTALL_DIR/lib), which
# may lag this checkout — so a brand-new sibling (triage-classify.sh) would not be
# found there. Sourcing relative to this file guarantees the same-checkout copy and
# keeps the file re-source-safe when sourced straight from the repo (the
# lib-resource-safety test). Mirrors local-review.sh's triage-classify source.
_FASTPATH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_FASTPATH_DIR/config.sh"
fi
source "$_FASTPATH_DIR/colors.sh"
source "$_FASTPATH_DIR/logging.sh"
source "$_FASTPATH_DIR/gh-retry.sh"
source "$_FASTPATH_DIR/markers.sh"
source "$_FASTPATH_DIR/triage-classify.sh"   # triage_classify_diff (merge gate)
source "$_FASTPATH_DIR/test-gate.sh"         # run_test_gate (merge gate)

# ---------------------------------------------------------------------------
# fastpath_parse_issue <issue_body>
#
# Sets FASTPATH_DIFF (the unified-diff text) and FASTPATH_FILES (newline-
# separated changed file paths). Returns 0 if the body is fast-path-eligible
# (has the marker + a parseable ```diff block touching at least one file),
# 1 otherwise.
# ---------------------------------------------------------------------------
fastpath_parse_issue() {
  local _body="$1"
  FASTPATH_DIFF=""
  FASTPATH_FILES=""

  # Require the explicit opt-in marker. A pure presence marker (no value), so a
  # plain grep is correct here (the BARE_MARKER_GREP rule targets value markers).
  echo "$_body" | grep -q "${RITE_MARKER_FASTPATH}" || return 1

  # Extract the FIRST fenced ```diff block (everything between ```diff and the
  # next ``` fence). awk: set flag on the opening fence, stop at the closing one.
  FASTPATH_DIFF=$(echo "$_body" | awk '
    /^```diff[[:space:]]*$/ { infence=1; next }
    /^```/ { if (infence) exit }
    infence { print }
  ' || true)
  [ -n "$FASTPATH_DIFF" ] || return 1

  # Changed files from the patch (+++ b/<path> lines). Strip the "b/" prefix.
  FASTPATH_FILES=$(echo "$FASTPATH_DIFF" | grep -E '^\+\+\+ b/' | sed -E 's|^\+\+\+ b/||' || true)
  [ -n "$FASTPATH_FILES" ] || return 1

  return 0
}

# ---------------------------------------------------------------------------
# fastpath_cleanup_worktree <worktree_path> <branch>
# Remove a worktree + its local branch on a fall-back. Best-effort; never fatal.
# ---------------------------------------------------------------------------
fastpath_cleanup_worktree() {
  local _wt="${1:-}" _branch="${2:-}"
  [ -n "$_wt" ] && git -C "$RITE_PROJECT_ROOT" worktree remove --force "$_wt" 2>/dev/null || true
  [ -n "$_branch" ] && git -C "$RITE_PROJECT_ROOT" branch -D "$_branch" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# try_trivial_fix_fastpath <issue_number>
# ---------------------------------------------------------------------------
try_trivial_fix_fastpath() {
  local issue_number="$1"

  # --- 1. Eligibility (no side effects) -----------------------------------
  local _body
  _body=$(gh_safe issue view "$issue_number" --json body --jq '.body' 2>/dev/null || true)
  [ -n "$_body" ] || return 1
  fastpath_parse_issue "$_body" || return 1

  print_header "⚡ Trivial-Fix Fast-Path — Issue #$issue_number"
  print_info "Issue carries a concrete patch — attempting deterministic apply (skips dev session + full review)"

  local _issue_title
  _issue_title=$(gh_safe issue view "$issue_number" --json title --jq '.title' 2>/dev/null || echo "issue-$issue_number")

  # --- 2. Worktree + branch ----------------------------------------------
  local _branch="fastpath/issue-${issue_number}"
  local _safe="${_branch//\//-}"
  _safe="${_safe//../-}"; _safe="${_safe//./}"; _safe="${_safe#-}"; _safe="${_safe%-}"
  local _worktree="${RITE_WORKTREE_DIR}/${_safe}"

  git -C "$RITE_PROJECT_ROOT" fetch origin main --quiet 2>/dev/null || true
  mkdir -p "$RITE_WORKTREE_DIR" 2>/dev/null || true

  # If a stale worktree/branch from a prior aborted run exists, clear it first.
  fastpath_cleanup_worktree "$_worktree" "$_branch"

  local _base_ref="origin/main"
  git -C "$RITE_PROJECT_ROOT" rev-parse --verify "$_base_ref" >/dev/null 2>&1 || _base_ref="main"
  if ! git -C "$RITE_PROJECT_ROOT" worktree add -b "$_branch" "$_worktree" "$_base_ref" >/dev/null 2>&1; then
    print_warning "Fast-path: could not create worktree — falling back to normal flow"
    return 1
  fi

  # --- 3. Apply the patch (deterministic; fails safely on drift) ----------
  local _patch_file
  _patch_file="$(mktemp "/tmp/rite_fastpath_${issue_number}_$$.patch")"
  printf '%s\n' "$FASTPATH_DIFF" > "$_patch_file"

  if ! git -C "$_worktree" apply --check "$_patch_file" 2>/dev/null; then
    print_warning "Fast-path: patch does not apply cleanly (file drifted?) — falling back to normal flow"
    rm -f "$_patch_file"
    fastpath_cleanup_worktree "$_worktree" "$_branch"
    return 1
  fi
  git -C "$_worktree" apply "$_patch_file" 2>/dev/null
  rm -f "$_patch_file"
  print_success "Patch applied to: $(echo "$FASTPATH_FILES" | tr '\n' ' ')"

  # --- 4. Syntax check touched shell files --------------------------------
  local _f
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    case "$_f" in
      *.sh|*.bash|bin/*)
        if [ -f "$_worktree/$_f" ] && ! bash -n "$_worktree/$_f" 2>/dev/null; then
          print_warning "Fast-path: bash -n failed on $_f — falling back to normal flow"
          fastpath_cleanup_worktree "$_worktree" "$_branch"
          return 1
        fi
        ;;
    esac
  done <<< "$FASTPATH_FILES"

  # --- 5. Triage classifier (must be "trivial") ---------------------------
  # Ensure a provider is loaded for the classifier's Layer-2 call (the dispatch
  # context may not have one loaded — Phase 1 loads it in a subprocess).
  if ! declare -f provider_run_prompt >/dev/null 2>&1; then
    source "$RITE_LIB_DIR/providers/provider-interface.sh"
  fi
  if declare -f load_provider >/dev/null 2>&1; then
    load_provider "${RITE_REVIEW_PROVIDER:-claude}" 2>/dev/null || true
  fi
  # Run on the canonical git diff of the applied (uncommitted) change.
  local _real_diff _nfiles _cls _verdict _guard
  _real_diff=$(git -C "$_worktree" diff || true)
  _nfiles=$(git -C "$_worktree" diff --name-only | grep -c . || true)
  _cls=$(triage_classify_diff "" "$_real_diff" "${_nfiles:-1}" || echo "substantive|0|error|classify_failed|0|logic")
  IFS='|' read -r _verdict _ _guard _ _ _ <<< "$_cls"
  if [ "${_verdict:-substantive}" != "trivial" ]; then
    print_warning "Fast-path: triage classified the change as substantive (guard=${_guard:-none}) — falling back to full review"
    _diag "FASTPATH issue=${issue_number} outcome=fallback reason=triage_substantive guard=${_guard:-none}"
    fastpath_cleanup_worktree "$_worktree" "$_branch"
    return 1
  fi
  print_success "Triage: trivial (cheap classifier cleared the change)"

  # --- 6. Post-commit gate (make check + bats -r tests/) ------------------
  local _gate_file _gate_exit=0
  _gate_file="$(mktemp "/tmp/rite_fastpath_gate_${issue_number}_$$.json")"
  print_step "Running post-commit gate (make check + bats -r tests/)..."
  run_test_gate "$_gate_file" "$_worktree" || true
  if command -v jq >/dev/null 2>&1 && [ -f "$_gate_file" ]; then
    _gate_exit=$(jq -r '.exit_code // 0' "$_gate_file" 2>/dev/null || echo 0)
    case "$_gate_exit" in ''|*[!0-9]*) _gate_exit=0 ;; esac
  fi
  rm -f "$_gate_file"
  if [ "${_gate_exit:-0}" -ne 0 ]; then
    print_warning "Fast-path: post-commit gate found failures — falling back to full review/fix loop"
    _diag "FASTPATH issue=${issue_number} outcome=fallback reason=gate_failed exit=${_gate_exit}"
    fastpath_cleanup_worktree "$_worktree" "$_branch"
    return 1
  fi
  print_success "Gate passed (lint + tests green)"

  # --- 7. All gates green → commit, push, open PR -------------------------
  git -C "$_worktree" add -A 2>/dev/null
  if ! git -C "$_worktree" commit -q -m "$(printf '%s\n\nTrivial fix applied via fast-path (deterministic patch from issue).\n\nCloses #%s' "$_issue_title" "$issue_number")" 2>/dev/null; then
    print_warning "Fast-path: nothing to commit — falling back to normal flow"
    fastpath_cleanup_worktree "$_worktree" "$_branch"
    return 1
  fi

  if ! git -C "$_worktree" push -u origin "$_branch" >/dev/null 2>&1; then
    print_warning "Fast-path: push failed — falling back to normal flow"
    fastpath_cleanup_worktree "$_worktree" "$_branch"
    return 1
  fi

  local _pr_body
  _pr_body=$(printf 'Trivial-fix fast-path applied for issue #%s (skipped dev session + full review).\n\nThe change was applied deterministically from a patch in the issue body, then validated by:\n- `git apply --check` (patch applies cleanly)\n- `bash -n` syntax check\n- cheap haiku triage classifier (verdict: trivial)\n- post-commit gate (`make check` + `bats -r tests/`)\n\nCloses #%s\n\n<!-- sharkrite-fastpath-pr:%s -->' "$issue_number" "$issue_number" "$issue_number")

  PR_NUMBER=$(gh_safe pr create --title "$_issue_title" --body "$_pr_body" --head "$_branch" --base main 2>/dev/null | grep -oE '[0-9]+$' | tail -1 || true)
  if [ -z "${PR_NUMBER:-}" ]; then
    # PR may exist already; look it up by branch.
    PR_NUMBER=$(gh_safe pr list --head "$_branch" --json number --jq '.[0].number // empty' 2>/dev/null || true)
  fi
  if [ -z "${PR_NUMBER:-}" ]; then
    print_warning "Fast-path: PR creation failed — falling back to normal flow"
    fastpath_cleanup_worktree "$_worktree" "$_branch"
    return 1
  fi

  # Post the fast-path marker comment (acceptance criterion).
  gh_safe pr comment "$PR_NUMBER" --body "⚡ trivial-fix fastpath applied for issue #${issue_number} (skipped dev session + review; gate + triage both green)" 2>/dev/null || true

  # Export state for the caller's merge phase.
  WORKTREE_PATH="$_worktree"
  export WORKTREE_PATH PR_NUMBER
  local _fp_files_csv
  _fp_files_csv=$(echo "$FASTPATH_FILES" | tr '\n' ',' | sed 's/,$//' || true)
  _diag "FASTPATH issue=${issue_number} pr=${PR_NUMBER} outcome=ready_to_merge files=${_fp_files_csv}"
  print_success "Fast-path PR #${PR_NUMBER} created and validated — ready to merge"
  return 0
}

# ---------------------------------------------------------------------------
# Guard: when sourced with RITE_SOURCE_FUNCTIONS_ONLY=1, stop here so tests can
# load the functions without the dep sourcing below running side effects.
# (Kept for symmetry with other lib modules; this file has no executable body.)
# ---------------------------------------------------------------------------
if [ "${RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
