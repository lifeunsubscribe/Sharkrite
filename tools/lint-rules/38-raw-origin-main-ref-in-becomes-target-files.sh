# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 38: RAW_ORIGIN_MAIN_REF — literal origin/main (or two-word "origin main")
# in the ten BECOMES-TARGET files (§5.2 of docs/architecture/branch-flag-design.md).
#
# WHY THIS RULE EXISTS
# --------------------
# When rite resolves a target branch (integration-x, main, etc.) it stores the
# resolved ref and seeds all downstream phases with it (via resolve_target_branch,
# issue #1033). A hardcoded `origin/main` in a BECOMES-TARGET file bypasses this
# resolver and silently mixes trunk code into an integration-branch worktree — the
# kind of bug that only surfaces at promotion time, far from the bad commit.
#
# The §5/§5.2 BECOMES-TARGET partition (converted by #1036/#1037/#1038/#1039) is
# meant to be complete. This rule is the §6.4 deterministic backstop: any missed
# or future-reintroduced raw-main ref in these files turns CI red immediately.
# The suppression comments document the §5.1 STAYS-MAIN / §5.2 BECOMES-TARGET
# partition in-code where review can see it.
#
# SCOPE: exactly the ten §5.2 BECOMES-TARGET files
# -------------------------------------------------
# Files NOT in scope are main-by-design whole files (§5.1 / §5.3):
#   lib/utils/post-merge-verify.sh  — tests the trunk; main-relative by design
#   lib/utils/divergence-handler.sh — classifying what's-already-on-trunk is
#                                     inherently main-relative (--not origin/main)
#   lib/utils/repo-status.sh        — scan_worktrees behind-main display (§5.3)
#   lib/core/undo-workflow.sh       — reset-to-trunk semantics (§5.1)
#   bin/rite                        — behind-main status display (§5.3, #1046)
#   lib/utils/blocker-rules.sh      — already origin/$base_branch-parameterized;
#                                     only comments mention origin/main
#
# PATTERN: non-comment lines matching ERE: origin(/|[[:space:]]+)main([^[:alnum:]_-]|$)
# - slash form:   origin/main    (catches origin/main...HEAD, origin/main", origin/main;)
# - two-word form: origin main   (catches "git fetch origin main", "git_fetch_safe origin main")
# - trailing guard: [^[:alnum:]_-]|$ prevents false-positives on origin/mainline,
#   origin/main-backup, while still catching origin/main) origin/main; origin main --quiet
# Full-line comments (^[[:space:]]*#) are skipped — suppression applies to code lines.
#
# SUPPRESSION: place on the line immediately before the flagged code:
#   # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: <site-specific reason>
# Canonical reason for STAYS-MAIN survivors: "trunk-health, intentionally main"
# (vary the reason per site — the reasons ARE the in-code partition documentation).
#
# See: docs/architecture/branch-flag-design.md §5, §6.4, §7 (Chunk 6)
echo "Checking for raw origin/main refs in target-branch-aware files..."

# Build the candidate file list from SHELL_FILES filtered to the ten BECOMES-TARGET
# paths.  Suffix matching via case allows RITE_LINT_EXTRA_DIRS fixture trees that
# mimic these paths to be scanned correctly — same approach as Rule 24's
# */lib/utils/*.sh filter.
_r38_target_files=()
for _f in "${SHELL_FILES[@]}"; do
  case "$_f" in
    */lib/core/claude-workflow.sh|\
    */lib/core/workflow-runner.sh|\
    */lib/core/create-pr.sh|\
    */lib/core/merge-pr.sh|\
    */lib/utils/trivial-fix-fastpath.sh|\
    */lib/utils/mid-run-rebase.sh|\
    */lib/utils/conflict-resolver.sh|\
    */lib/utils/scope-checker.sh|\
    */lib/utils/test-gate.sh|\
    */lib/utils/stale-branch.sh)
      _r38_target_files+=("$_f")
      ;;
  esac
done

for file in "${_r38_target_files[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^[[:space:]]*#'; then
      continue
    fi

    # Check for suppression comment on preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || true)
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*RAW_ORIGIN_MAIN_REF'; then
      continue
    fi

    print_violation "$file" "$line_num" "RAW_ORIGIN_MAIN_REF" \
      "raw origin/main ref in a target-branch-aware file — resolve through resolve_target_branch (see docs/architecture/branch-flag-design.md §5/§6.4) or suppress with a reasoned marker if this site is intentionally trunk-relative"
  done < <(grep -nE 'origin(/|[[:space:]]+)main([^[:alnum:]_-]|$)' "$file" 2>/dev/null || true)
done
