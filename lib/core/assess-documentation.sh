#!/bin/bash

# assess-documentation.sh - Multi-layer documentation assessment
# Layer 1 (always): Update .rite/docs/ with machine-optimized internal docs
# Layer 2 (premium): Update user project docs IF .rite/doc-sync.md exists
#
# Usage:
#   assess-documentation.sh <PR_NUMBER> [--auto]

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f assess_internal_changelog >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/logging.sh"
source "$RITE_LIB_DIR/utils/gh-retry.sh"
source "$RITE_LIB_DIR/utils/markers.sh"
source "$RITE_LIB_DIR/providers/provider-interface.sh"
load_provider "${RITE_REVIEW_PROVIDER:-claude}"
# generate_adr_for_ref lives in its own helper module so other callers
# (bootstrap-docs.sh) can use it without sourcing this script's
# top-level executable body. See lib/utils/adr-generator.sh.
source "$RITE_LIB_DIR/utils/adr-generator.sh"
source "$RITE_LIB_DIR/utils/tag-index.sh"
source "$RITE_LIB_DIR/utils/docs-map.sh"
source "$RITE_LIB_DIR/utils/drift-log.sh"

# Timeout per provider call in doc assessment (seconds)
DOC_CLAUDE_TIMEOUT="${RITE_DOC_CLAUDE_TIMEOUT:-120}"

PR_NUMBER="${1:-}"
AUTO_MODE=""
WORKTREE_PATH=""

if [ -z "$PR_NUMBER" ]; then
  print_error "Usage: $0 <pr_number> [--auto] [--worktree <path>]"
  exit 1
fi
shift

# Parse remaining flags. Order is not significant.
# --auto runs in unsupervised mode (no interactive prompts).
# --worktree <path> tells the script to operate in the feature worktree so Layer 2
# commits land on the feature branch (squash-merged with the PR). When omitted,
# falls back to RITE_PROJECT_ROOT (main worktree) for backward compatibility with
# any caller still invoking this post-merge.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto)
      AUTO_MODE="--auto"
      shift
      ;;
    --worktree)
      if [ -z "${2:-}" ]; then
        print_error "--worktree requires a path argument"
        exit 1
      fi
      WORKTREE_PATH="$2"
      shift 2
      ;;
    *)
      print_error "Unknown argument: $1"
      print_error "Usage: $0 <pr_number> [--auto] [--worktree <path>]"
      exit 1
      ;;
  esac
done

# Ensure a valid cwd before any git-aware tool (e.g. claude --print) runs.
#
# Historically this script ran post-merge from the main worktree (RITE_PROJECT_ROOT).
# Now it runs pre-merge from the feature worktree when invoked with --worktree, so
# Layer 2's git commit lands on the feature branch and rides the squash merge.
#
# Why the cwd matters: the claude CLI probes cwd for git context on startup; if the
# directory is gone it emits "failed to run git: fatal: Unable to read current
# working directory" and exits 1. RITE_PROJECT_ROOT is always safe (main worktree
# never disappears mid-run); a passed --worktree is safe for the duration of the
# fix loop because workflow-runner.sh waits for this script before any worktree
# removal in phase_merge_pr.
if [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ]; then
  cd "$WORKTREE_PATH"
else
  cd "${RITE_PROJECT_ROOT}"
fi

# Check provider CLI availability and authentication
provider_detect_cli || exit 1
provider_validate_cli || exit 1

# =====================================================================
# SHARED DATA (computed once, used by both layers)
# =====================================================================

# Fetch PR metadata. gh_safe retries on 429/5xx with exponential backoff; if it
# exhausts all retries (persistent GitHub outage), it returns non-zero. We capture
# the exit code explicitly so we can print a clear "skipped" message and exit 0
# rather than letting set -e crash the script with a cryptic error.
#
# Idiom: `|| _pr_data_exit=$?` (not `if ! gh_safe`) because `pr view` output is
# captured directly into PR_DATA via $().  For `pr diff` below we use temp file +
# `if ! gh_safe` because that idiom avoids the PIPESTATUS-in-subshell problem
# (see CLAUDE.md) when the output is written via redirection rather than $().
_pr_data_exit=0
PR_DATA=$(gh_safe pr view "$PR_NUMBER" --json title,body,files,commits,reviews,comments) || _pr_data_exit=$?
if [ "$_pr_data_exit" -ne 0 ]; then
  # gh_safe exhausted retries on a persistent 5xx/429 — GitHub API is unavailable.
  # Exit 0 so the batch reporter doesn't mark the merged issue as failed (see #57).
  print_warning "Doc assessment skipped for PR #${PR_NUMBER}: GitHub API unavailable after ${RITE_GH_MAX_RETRIES:-3} attempts — re-run with \`bash lib/core/assess-documentation.sh ${PR_NUMBER} --auto\` later"
  exit 0
fi
PR_DATA="${PR_DATA:-"{}"}"
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title' || true)
PR_BODY=$(echo "$PR_DATA" | jq -r '.body // ""' || true)

# Fetch PR diff separately. gh pr diff is the call that triggered the live 5xx
# ("this diff is temporarily unavailable due to heavy server load"). gh_safe
# retries on 5xx automatically; on exhausted retries we exit 0 (see #62).
#
# Use a temp file for output and the `if !` idiom to capture the exit code.
# `if` is exempt from set -e, so gh_safe's failure is captured correctly
# without || true swallowing it. This avoids the PIPESTATUS-in-subshell
# problem (see CLAUDE.md) without needing a second temp file.
_diff_raw_file=$(mktemp 2>/dev/null) || {
  print_warning "Doc assessment skipped for PR #${PR_NUMBER}: mktemp failed (disk full or /tmp unavailable)"
  exit 0
}
_pr_diff_exit=0
# NOTE: `if !` negates the exit code, so _pr_diff_exit is always 1 on failure
# (not the true gh_safe exit code). This is intentional — we only need to
# distinguish success (0) from any failure (non-zero), not the specific code.
if ! gh_safe pr diff "$PR_NUMBER" > "$_diff_raw_file"; then
  _pr_diff_exit=1
fi

# Filter out hunks whose file path matches a documentation location, so this
# assessment doesn't see its own prior commits in the diff on later fix-loop
# iterations. The doc commit that lands on the feature branch during loop N
# would otherwise appear as input to loop N+1's doc assessment — wasted tokens
# at best, feedback loop at worst (changelog entries getting recursively summarized).
#
# Paths filtered: .rite/docs/* (Layer 1 internal docs, tracked only in sharkrite
# itself) and docs/* / *.md at repo root (typical Layer 2 user-doc targets).
# Filter is conservative: a project that puts code in docs/ would lose those hunks
# from doc assessment, but doc assessment is supposed to reason about docs, not
# code under docs/.
_diff_filtered_file=$(mktemp 2>/dev/null) || _diff_filtered_file="$_diff_raw_file"
if [ "$_diff_filtered_file" != "$_diff_raw_file" ]; then
  awk '
    /^diff --git a\/(\.rite\/docs|docs)\// { skip=1; next }
    /^diff --git a\/[^\/]+\.md / { skip=1; next }
    /^diff --git / { skip=0 }
    !skip { print }
  ' "$_diff_raw_file" > "$_diff_filtered_file"
fi

PR_DIFF=$(head -500 "$_diff_filtered_file" || true)
rm -f "$_diff_raw_file"
[ "$_diff_filtered_file" != "$_diff_raw_file" ] && rm -f "$_diff_filtered_file"
if [ "${_pr_diff_exit}" -ne 0 ]; then
  print_warning "Doc assessment skipped for PR #${PR_NUMBER}: GitHub API unavailable after ${RITE_GH_MAX_RETRIES:-3} attempts — re-run with \`bash lib/core/assess-documentation.sh ${PR_NUMBER} --auto\` later"
  exit 0
fi
PR_DIFF="${PR_DIFF:-}"
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.files[]?.path // empty' | head -30 || true)

# =====================================================================
# LAYER 1: INTERNAL DOCS (always runs)
# =====================================================================

# Track results for one-liner summary.
# Functions run in parallel subshells, so use marker files instead of a shared array.
INTERNAL_UPDATED=()
_MARKER_DIR=$(mktemp -d 2>/dev/null) || {
  print_warning "Doc assessment skipped for PR #${PR_NUMBER}: mktemp -d failed (disk full or /tmp unavailable)"
  exit 0
}
# Cleanup trap: remove _MARKER_DIR on any exit (normal, error, or signal)
trap 'rm -rf "${_MARKER_DIR:-}"' EXIT
_mark_updated() { touch "$_MARKER_DIR/$1"; }

mkdir -p "${RITE_INTERNAL_DOCS_DIR}" "${RITE_INTERNAL_DOCS_DIR}/adr"

# --- Internal doc helper functions ---

assess_internal_changelog() {
  local pr_number="$1"
  local pr_title="$2"
  local changed_files="$3"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/changelog.md"

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# Changelog" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication: skip if PR already present.
  # Use an exact numeric match — "#${pr_number}" followed by a non-digit or end-of-line
  # prevents false positives where a shorter number (e.g. #5) matches inside a longer
  # one (e.g. #55).  The entry format is "… (#N) [files]" so ")" is the typical
  # following character, but anchoring to [^0-9]|$ covers all valid positions.
  if grep -qE "#${pr_number}([^0-9]|$)" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Determine change type from title
  local change_type="change"
  if echo "$pr_title" | grep -qiE "^feat"; then change_type="feat"
  elif echo "$pr_title" | grep -qiE "^fix"; then change_type="fix"
  elif echo "$pr_title" | grep -qiE "^refactor"; then change_type="refactor"
  elif echo "$pr_title" | grep -qiE "^docs"; then change_type="docs"
  elif echo "$pr_title" | grep -qiE "^test"; then change_type="test"
  elif echo "$pr_title" | grep -qiE "^chore"; then change_type="chore"
  fi

  # Build file list (compact)
  local file_list=$(echo "$changed_files" | head -5 | tr '\n' ', ' | sed 's/,$//' || true)

  # Prepend entry: newest date section at the top (Keep a Changelog convention)
  local today=$(date +%Y-%m-%d)
  local entry="- ${change_type}: ${pr_title} (#${pr_number}) [${file_list}]"

  if grep -q "^## $today" "$doc_file" 2>/dev/null; then
    # Date section exists — prepend the new entry directly after the date header.
    # The section is already at the top (inserted there on first entry today),
    # so we just need to inject the entry line after the header.
    #
    # Guard: mktemp failure (disk full, /tmp missing) must not abort the parent
    # assess-documentation.sh process — changelog is a nice-to-have.
    # Return 0 (graceful skip) so downstream assessments still run.
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null) || {
      print_warning "  changelog: mktemp failed — skipping entry for PR #${pr_number} (temp space issue?)"
      return 0
    }
    awk -v date="## $today" -v entry="$entry" '
      $0 == date { print; print entry; inserted=1; next }
      { print }
    ' "$doc_file" > "$tmp_file"
    mv "$tmp_file" "$doc_file"
  else
    # Date section does not exist yet — prepend a new section immediately after
    # the "# Changelog" header line so newest dates appear at the top of the file.
    # Strategy: emit the new date+entry block right after the title line, then
    # suppress the one blank separator line that follows the title (it will be
    # re-emitted by the new block itself), then continue with the rest of the file.
    #
    # Guard: same isolation contract as the branch above — skip this entry
    # gracefully when mktemp fails rather than aborting the parent process.
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null) || {
      print_warning "  changelog: mktemp failed — skipping entry for PR #${pr_number} (temp space issue?)"
      return 0
    }
    awk -v date="## $today" -v entry="$entry" '
      $0 == "# Changelog" && !done { print; print ""; print date; print entry; print ""; done=1; skip_blank=1; next }
      skip_blank && /^$/ { skip_blank=0; next }
      { print }
      END { if (!done) { print ""; print date; print entry } }
    ' "$doc_file" > "$tmp_file"
    mv "$tmp_file" "$doc_file"
  fi

  _mark_updated "changelog"
}

assess_internal_security() {
  local pr_number="$1"
  local pr_diff="$2"
  local changed_files="$3"
  local pr_title="$4"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/security.md"

  # Check if diff touches security-relevant files
  local auth_pattern="${BLOCKER_AUTH_PATHS:-auth/|Auth|authentication|authorization|cognito|oauth}"
  local infra_pattern="${BLOCKER_INFRASTRUCTURE_PATHS:-infrastructure/|cdk/|terraform/|cloudformation/|\.github/workflows/|\.claude/}"

  local has_security_files=false

  if echo "$changed_files" | grep -qiE "$auth_pattern" 2>/dev/null; then
    has_security_files=true
  elif echo "$changed_files" | grep -qiE "$infra_pattern" 2>/dev/null; then
    has_security_files=true
  elif echo "$changed_files" | grep -qiE "credential|token|secret|encrypt|session|password|api.?key" 2>/dev/null; then
    has_security_files=true
  elif echo "$pr_diff" | grep -qiE "credential|token|secret|encrypt|session|password|api.?key" 2>/dev/null; then
    has_security_files=true
  fi

  if [ "$has_security_files" = false ]; then
    return 0
  fi

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# Security Findings" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication: exact numeric match (see changelog dedup comment for rationale)
  if grep -qE "#${pr_number}([^0-9]|$)" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Generate structured security findings via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<SECURITY_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this PR diff for security-relevant patterns. Output in this exact format:

## PR #${pr_number} - $(date +%Y-%m-%d)
<CATEGORY>: <file_path>
- <pattern description in one line>
- <gap or concern in one line>

Categories: AUTH_CHANGE, CRED_HANDLING, INFRA_CHANGE, SESSION_MGMT, INPUT_VALIDATION, ENCRYPTION

Only include findings that exist. No empty categories.

PR Title: ${pr_title}
Changed files:
${changed_files}

Diff (truncated):
${pr_diff}
SECURITY_EOF

  verbose_info "  Assessing security findings..."
  local security_output
  # Use doc_assessment model (sonnet): structured pattern matching, not deep reasoning.
  # Independent of RITE_REVIEW_MODEL — see docs/architecture/behavioral-design.md.
  security_output=$(provider_run_prompt_with_timeout "$(cat "$prompt_file")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$security_output" ]; then
    echo "" >> "$doc_file"
    echo "$security_output" >> "$doc_file"
    echo "" >> "$doc_file"
    _mark_updated "security"
    echo "partial_complete:security"
  fi
}

assess_internal_architecture() {
  local pr_number="$1"
  local pr_diff="$2"
  local changed_files="$3"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/architecture.md"

  # Check if diff touches architectural files (new/removed files, config, entry points)
  local has_arch_changes=false

  # New or removed files in core source dirs
  if echo "$pr_diff" | grep -qE "^(diff --git a/|new file mode|deleted file mode)" 2>/dev/null; then
    if echo "$changed_files" | grep -qiE "\.(sh|ts|js|py|go|rs|java)$" 2>/dev/null; then
      has_arch_changes=true
    fi
  fi

  # Config variable definitions
  if echo "$pr_diff" | grep -qiE "^[\+\-].*(_CONFIG|_DIR|_PATH|_PATTERN|_MODE|export )" 2>/dev/null; then
    has_arch_changes=true
  fi

  # Entry point / dispatch changes
  if echo "$changed_files" | grep -qiE "(bin/|entrypoint|main\.|index\.|dispatch|router)" 2>/dev/null; then
    has_arch_changes=true
  fi

  if [ "$has_arch_changes" = false ]; then
    return 0
  fi

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# Architecture Reference" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication: exact numeric match (see changelog dedup comment for rationale)
  if grep -qE "#${pr_number}([^0-9]|$)" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Generate via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<ARCH_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this PR for architectural changes. Output in this exact format:

## PR #${pr_number} - $(date +%Y-%m-%d)
ADDED: <file_path> — <one-line purpose>
REMOVED: <file_path> — <was used for>
MODIFIED: <file_path> — <what changed>
CONFIG: <VAR_NAME>=<default> — <purpose>
DEPENDENCY: <from> → <to> — <relationship>

Only include categories with actual changes. No empty sections.

Changed files:
${changed_files}

Diff (truncated):
${pr_diff}
ARCH_EOF

  verbose_info "  Assessing architecture..."
  local arch_output
  # Use doc_assessment model (sonnet): structured pattern matching, not deep reasoning.
  # Independent of RITE_REVIEW_MODEL — see docs/architecture/behavioral-design.md.
  arch_output=$(provider_run_prompt_with_timeout "$(cat "$prompt_file")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$arch_output" ]; then
    # Truncation safety: architecture is append-only but verify output isn't garbage.
    # printf '%s\n' ensures a trailing newline so wc -l counts the last line even
    # when the output has no trailing newline (wc -l counts newline characters).
    local output_lines=$(printf '%s\n' "$arch_output" | wc -l | tr -d ' ')
    if [ "$output_lines" -gt 1 ]; then
      echo "" >> "$doc_file"
      echo "$arch_output" >> "$doc_file"
      echo "" >> "$doc_file"
      _mark_updated "architecture"
      echo "partial_complete:architecture"
    fi
  fi
}

assess_internal_api() {
  local pr_number="$1"
  local pr_diff="$2"
  local changed_files="$3"
  local doc_file="${RITE_INTERNAL_DOCS_DIR}/api.md"

  # Check if diff modifies CLI flags, help text, config vars, exit codes, script interfaces
  local has_api_changes=false

  if echo "$pr_diff" | grep -qiE "(getopts|--[a-z]|usage:|exit [0-9]|print_error.*Usage)" 2>/dev/null; then
    has_api_changes=true
  elif echo "$pr_diff" | grep -qiE "^[\+\-].*RITE_" 2>/dev/null; then
    has_api_changes=true
  elif echo "$changed_files" | grep -qiE "(bin/|cli|help)" 2>/dev/null; then
    has_api_changes=true
  fi

  if [ "$has_api_changes" = false ]; then
    return 0
  fi

  # Initialize if new
  if [ ! -f "$doc_file" ]; then
    echo "# API Reference" > "$doc_file"
    echo "" >> "$doc_file"
  fi

  # Deduplication: exact numeric match (see changelog dedup comment for rationale)
  if grep -qE "#${pr_number}([^0-9]|$)" "$doc_file" 2>/dev/null; then
    return 0
  fi

  # Generate via Claude
  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<API_EOF
Output ONLY structured reference data for machine consumption.
No prose, no explanations, no markdown paragraphs.
Format: file paths, patterns, one-line descriptions, tabular data.

Analyze this PR for API/CLI interface changes. Output in this exact format:

## PR #${pr_number} - $(date +%Y-%m-%d)
FLAG: --flag-name — <description> (added|changed|removed)
CONFIG: VAR_NAME=default — <description> (added|changed|removed)
EXIT_CODE: N — <meaning> (added|changed)
INTERFACE: script.sh <args> — <change description>

Only include categories with actual changes. No empty sections.

Changed files:
${changed_files}

Diff (truncated):
${pr_diff}
API_EOF

  verbose_info "  Assessing API changes..."
  local api_output
  # Use doc_assessment model (sonnet): structured pattern matching, not deep reasoning.
  # Independent of RITE_REVIEW_MODEL — see docs/architecture/behavioral-design.md.
  api_output=$(provider_run_prompt_with_timeout "$(cat "$prompt_file")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$api_output" ]; then
    # printf '%s\n' ensures a trailing newline so wc -l counts the last line even
    # when the output has no trailing newline (wc -l counts newline characters).
    local output_lines=$(printf '%s\n' "$api_output" | wc -l | tr -d ' ')
    if [ "$output_lines" -gt 1 ]; then
      echo "" >> "$doc_file"
      echo "$api_output" >> "$doc_file"
      echo "" >> "$doc_file"
      _mark_updated "api"
      echo "partial_complete:api"
    fi
  fi
}

# generate_adr_for_ref is defined in lib/utils/adr-generator.sh and sourced
# at the top of this file. It calls _mark_updated() (defined above) on success.

assess_internal_adr() {
  local pr_number="$1"
  local pr_diff="$2"
  local pr_body="$3"
  local pr_title="$4"

  # Check if diff introduces a pattern change (new category, rule type, phase, approach substitution)
  local has_pattern_change=false

  # New phases, categories, rule types
  if echo "$pr_diff" | grep -qiE "^[\+].*(phase_|_CATEGORY|_RULE|_TYPE|_PATTERN).*=" 2>/dev/null; then
    has_pattern_change=true
  fi

  # Significant structural additions (new functions, new case arms)
  if echo "$pr_diff" | grep -cE "^\+.*(^[a-z_]+\(\)|case .* in)" 2>/dev/null | grep -qvE "^0$"; then
    has_pattern_change=true
  fi

  # PR body explicitly mentions decision/tradeoff/alternative
  if echo "$pr_body" | grep -qiE "(decision|tradeoff|trade-off|alternative|approach|instead of|replaced)" 2>/dev/null; then
    has_pattern_change=true
  fi

  if [ "$has_pattern_change" = false ]; then
    return 0
  fi

  # Call the refactored function. Capture the returned adr_file path (non-empty = success).
  local adr_result
  adr_result=$(generate_adr_for_ref "pr" "$pr_number" "$pr_title" "$pr_body" "$pr_diff" "${CHANGED_FILES:-}" 2>/dev/null) || true
  if [ -n "$adr_result" ]; then
    echo "partial_complete:adr"
  fi
}

update_conventions_from_marker() {
  # update_conventions_from_marker PR_NUMBER PR_BODY
  #
  # Extracts all <!-- sharkrite-convention -->...<!-- /sharkrite-convention --> blocks
  # from the PR body and updates docs/architecture/conventions.md in the project root.
  #
  # Each convention title is canonical — exactly ONE entry per unique title.
  # Three cases (see behavioral-design.md → "Conventions Catalog: Accumulate-in-Place
  # Contract" for the full rationale):
  #   title absent              → append a new rendered entry
  #   title present, PR# present → no-op (idempotent — already recorded)
  #   title present, PR# absent  → accumulate in place: append ", #PR" to the existing
  #                                entry's References line (no duplicate heading created)
  #
  # No Claude call — purely local file I/O + one gh API call already cached in
  # PR_BODY (passed as arg 2).  Runs synchronously (fast).
  local pr_number="$1"
  local pr_body="$2"
  local conventions_file="${RITE_PROJECT_ROOT}/docs/architecture/conventions.md"

  # Extract the raw content between every <!-- sharkrite-convention --> pair.
  # Strategy: write PR body to a temp file, then use awk to collect all blocks.
  # Using a temp file avoids subshell + pipeline issues with set -e.
  local _body_file
  # Guard: mktemp failure (disk full, /tmp missing) must not abort the parent
  # assess-documentation.sh process — conventions are a nice-to-have, not a
  # hard blocker.  Return 0 (graceful skip) so downstream assessments still run.
  _body_file=$(mktemp 2>/dev/null) || {
    print_warning "  conventions: mktemp failed for body file — skipping (temp space issue?)"
    return 0
  }
  # Write PR body to temp file; printf '%s' avoids interpreting escape sequences
  printf '%s' "$pr_body" > "$_body_file"

  # awk extracts zero or more blocks; each block is separated by a sentinel line
  # "---CONVENTION_BLOCK_END---" so the outer loop can split on it.
  # Use -v to pass the marker constant so no raw "sharkrite-*" literal appears here.
  #
  # Fenced code block guard: PR bodies often document the convention format inside
  # triple-backtick blocks. Without a fence guard the extractor would ingest the
  # template example as a real convention block.  Track in_fence so that markers
  # inside ``` ... ``` are treated as literal text, not as real extraction triggers.
  #
  # Three-level fence tracking (fixes issues #429 / #430 / #433 / #434 / #520):
  #
  # Bug 1 (column-0 fence inside real block): The original guard applied to ALL
  # lines including those inside an open convention block.  When a real block's
  # example field contained a column-0 ````` the guard toggled in_fence and
  # started silently dropping lines — including the close marker, which caused
  # the block to be truncated (never emitted).
  # Fix: Convention block content is accumulated BEFORE the fence guard fires.
  # When in_block=1, every line (including `````) goes to the accumulator via
  # `in_block { ...; next }` so the fence guard never sees it.
  #
  # Bug 2 (indented / N-backtick fences bypass guard): The original /^```/
  # pattern required the fence to start at column-0 with exactly 3 backticks
  # (prefix match — it actually matched 4+ too, but not indented fences).
  # A 4-backtick outer fence containing an unindented 3-backtick inner fence
  # would trip the guard at the inner ``` and turn off in_fence prematurely,
  # potentially allowing a marker inside the outer fence to be extracted.
  # Fix: Track fence_len (count of opening backticks).  A fence is opened only
  # when NOT currently in a fence (prevents inner fences from being openers).
  # A fence is closed only when the closing line has >= fence_len backticks.
  # This matches the CommonMark rule: a fenced block opened with N backticks
  # can only be closed by N or more backticks on an otherwise blank line.
  # Indented fences (up to 3 leading spaces) are also detected as CommonMark
  # allows up to 3 spaces of indentation on fence markers.
  #
  # Bug 3 (info-string on closing line bypasses guard — unterminated fence):
  # CommonMark 0.30 §4.5: a closing fence must consist ONLY of backticks
  # followed by optional whitespace — no info string is allowed.  The old
  # closing check tested only fence_len, so a line like "```bash" or "``` :"
  # (colon preceded by a space) was accepted as a closing fence when it should
  # not be.  A fence opened with such a line as the only potential closer would
  # never actually close, causing everything that follows — including real
  # convention blocks — to be silently swallowed as fenced content until EOF.
  # Fix: After counting the closing backticks, extract the remainder of the
  # line (close_after).  Accept the close only when close_after matches
  # /^[[:space:]]*$/ (empty or whitespace only).  Lines with an info string
  # (e.g. "```bash", "``` :") no longer act as spurious closers.
  local _blocks_file
  # Guard: same isolation contract as _body_file — clean up _body_file on failure.
  _blocks_file=$(mktemp 2>/dev/null) || {
    print_warning "  conventions: mktemp failed for blocks file — skipping (temp space issue?)"
    rm -f "$_body_file"
    return 0
  }
  awk -v open_marker="<!-- ${RITE_MARKER_CONVENTION} -->" \
      -v close_marker="<!-- /${RITE_MARKER_CONVENTION} -->" '
    # Convention block content is processed FIRST (before the fence guard).
    # This is the fix for Bug 1: when inside a convention block, every line
    # (including column-0 backtick fences) is accumulated as raw content.
    # The fence guard rules below never fire for lines consumed here.
    $0 == open_marker && !in_fence { in_block=1; block=""; next }
    in_block && $0 == close_marker { print block; print "---CONVENTION_BLOCK_END---"; in_block=0; next }
    in_block { block = (block == "") ? $0 : block "\n" $0; next }

    # Fence guard (top-level only — in_block lines are consumed above).
    # Bug 2 fix: track fence_len so that a 4-backtick outer fence is only
    # closed by 4+ backticks; an inner 3-backtick sequence does not prematurely
    # close the outer fence and allow enclosed markers to leak through.
    # Also detect indented fences (up to 3 leading spaces) per CommonMark spec.
    # Bug 3 fix: closing fence must have NO info string after the backticks;
    # see close_after check below (issue #520).
    !in_fence && /^[[:space:]]{0,3}```/ {
      # Extract the run of backticks after optional leading spaces.
      # fence_len holds the count for this fence; close requires >= fence_len.
      fence_str = $0
      sub(/^[[:space:]]*/, "", fence_str)   # strip leading spaces
      fence_len = 0
      while (substr(fence_str, fence_len + 1, 1) == "`") fence_len++
      in_fence = 1
      next
    }
    in_fence && /^[[:space:]]{0,3}```/ {
      # Count backticks on this potential closing line.
      close_str = $0
      sub(/^[[:space:]]*/, "", close_str)
      close_len = 0
      while (substr(close_str, close_len + 1, 1) == "`") close_len++
      # CommonMark closing fence rule: the closing line must consist of ONLY
      # the backtick run plus optional trailing whitespace — no info string
      # (e.g. "```bash" or "``` :" must NOT close the fence).
      # substr(..., close_len+1) extracts everything after the backticks;
      # matching /^[[:space:]]*$/ ensures it is empty or whitespace only.
      close_after = substr(close_str, close_len + 1)
      if (close_len >= fence_len && close_after ~ /^[[:space:]]*$/) {
        in_fence = 0; fence_len = 0
      }
      next
    }
    in_fence { next }

    # Spurious close marker outside a block (no-op)
    $0 == close_marker { next }
  ' "$_body_file" > "$_blocks_file"
  rm -f "$_body_file"

  # If no blocks found, nothing to do (silent — no warning, no file creation)
  if [ ! -s "$_blocks_file" ]; then
    rm -f "$_blocks_file"
    return 0
  fi

  # Blocks exist — auto-bootstrap the catalog if missing. Only create when there
  # is something to write so projects that never use the marker don't accumulate
  # an empty doc.
  if [ ! -f "$conventions_file" ]; then
    mkdir -p "$(dirname "$conventions_file")"
    # Marker literals are injected via variable to satisfy RAW_MARKER_LITERAL lint.
    local _open_marker="<!-- ${RITE_MARKER_CONVENTION} -->"
    local _close_marker="<!-- /${RITE_MARKER_CONVENTION} -->"
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: marker constants must expand
    cat > "$conventions_file" <<EOF
# Conventions Catalog

**Auto-appended on merge — do not hand-edit.**

To add a convention, include a \`${RITE_MARKER_CONVENTION}\` block in your PR body:

\`\`\`
${_open_marker}
title: Your convention title
rule: One-sentence statement of the rule
why: Why this rule exists / what goes wrong without it
example: |
  # BAD
  ...
  # GOOD
  ...
references: <commit-sha>, #<issue>, #<pr>
${_close_marker}
\`\`\`

The merge automation extracts the block and appends a rendered entry below.
Entries are append-only; each entry's \`references\` field links to the issue(s) and
commit(s) that surfaced or fixed the pattern.

---
EOF
    print_info "Created $conventions_file (first convention entry triggered bootstrap)"
  fi

  # Process each block separated by the sentinel
  local _current_block=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    if [ "$_line" = "---CONVENTION_BLOCK_END---" ]; then
      # Parse YAML-ish fields from _current_block.
      #
      # Field extraction must operate only on the scalar (non-example) portion of
      # the block.  The multi-line `example: |` literal block scalar can contain
      # arbitrary content — including lines that start with "rule:", "references:",
      # or any other key name.  Running grep "^rule:" against the full block would
      # silently pick up such lines from inside the example and corrupt the field.
      #
      # _block_no_example strips the example section before scalar field extraction:
      # - When `example: |` is seen, skip=1.
      # - While skip=1, skip all lines that are NOT a known top-level field name.
      # - A known field name (title|rule|why|example|references|tags|new-tags) at
      #   column-0 resets skip=0 and is printed (it's the real top-level key that
      #   ends the example section, even if the same name appears inside the example).
      #
      # KNOWN ASYMMETRY: a col-0 known-field-name line inside the example section
      # simultaneously (a) terminates the example in _example_awk (truncating any
      # example content that follows it) and (b) is treated as a real scalar field
      # by _no_example_awk (printed into _block_no_example).  This means such a line
      # IS leaked into _block_no_example as a candidate scalar value.  For `references`
      # this is benign because `tail -1` (not `head -1`) is used for extraction —
      # `tail -1` always selects the last occurrence, which is the real field that
      # follows the example.  For `title`, `rule`, and `why` the standard convention
      # block order places those fields BEFORE the example section, so they are never
      # affected by this asymmetry in practice.
      #
      # Shared field-name boundary pattern used by both _no_example_awk and
      # _example_awk below.  Centralised here so a new field name (e.g. a future
      # "severity:" key) is added in exactly one place.  Both awk programs must
      # use the same set — see "KNOWN ASYMMETRY" note above for why they must agree.
      local _FIELD_NAMES='(title|rule|why|example|references|tags|new-tags)'
      # The awk program is stored in a variable so the || true guard appears on a
      # separate line (required by the UNSAFE_PIPE_IN_CMDSUB lint rule).
      local _no_example_awk="/^example:[[:space:]]*\|/ { skip=1; next } skip && /^${_FIELD_NAMES}:/ { skip=0; print; next } skip { next } { print }"
      local _block_no_example
      _block_no_example=$(printf '%s' "$_current_block" | awk "$_no_example_awk" || true)

      local _title _rule _why _example _references _tags _new_tags
      _title=$(printf '%s' "$_block_no_example" | grep "^title:" | head -1 | sed 's/^title:[[:space:]]*//' || true)
      _rule=$(printf '%s' "$_block_no_example" | grep "^rule:" | head -1 | sed 's/^rule:[[:space:]]*//' || true)
      _why=$(printf '%s' "$_block_no_example" | grep "^why:" | head -1 | sed 's/^why:[[:space:]]*//' || true)
      # Use tail -1 (not head -1) for references — tail -1 is the actual correctness
      # mechanism here (not the field-name boundary in _no_example_awk).
      # In the standard convention block order (title/rule/why/example/references),
      # `references:` appears AFTER the example section.  However, if the example
      # contains a col-0 "references:" line, _no_example_awk treats it as a
      # known-field terminator and prints it into _block_no_example before the real
      # field.  head -1 would therefore pick up the example-embedded (wrong) value.
      # tail -1 always picks the LAST occurrence, which is the real references field
      # that follows the example section.  See "KNOWN ASYMMETRY" note above.
      _references=$(printf '%s' "$_block_no_example" | grep "^references:" | tail -1 | sed 's/^references:[[:space:]]*//' || true)
      # tags: is a single-line comma-separated field (e.g. "tags: foo, bar")
      _tags=$(printf '%s' "$_block_no_example" | grep "^tags:" | head -1 | sed 's/^tags:[[:space:]]*//' || true)
      # new-tags: is a multi-line block — extract the "  - name: justification" lines.
      # These appear between "new-tags:" and the next top-level field or end of block.
      # The awk program is stored in a variable first for UNSAFE_PIPE_IN_CMDSUB compliance.
      local _new_tags_awk="/^new-tags:/ { in_nt=1; next } in_nt && /^${_FIELD_NAMES}:/ { in_nt=0 } in_nt { print }"
      _new_tags=$(printf '%s' "$_block_no_example" | awk "$_new_tags_awk" || true)

      # Extract multi-line example block (everything after "example: |" up to the
      # next top-level key or end of block).  The example field uses YAML literal
      # block scalar style ("example: |") — subsequent indented lines are content.
      # The terminator matches only the known top-level field names, so lines inside
      # the example that use non-field key names (e.g., "timeout: 30", shell
      # assignments) do not prematurely truncate the example content.
      #
      # KNOWN LIMITATION: a col-0 known-field-name line inside the example (e.g.,
      # "references: some-link" at column-0 with no indent) DOES terminate the
      # example extraction — content after that line is silently lost from the
      # extracted example.  This is the same boundary used by _no_example_awk
      # (see "KNOWN ASYMMETRY" note above).  Well-formed convention blocks use
      # 2-space indentation for all example content, making col-0 field names
      # unambiguous terminators in practice.
      # The awk program is stored in a variable first so the || true guard appears
      # on the next line (required by the UNSAFE_PIPE_IN_CMDSUB lint rule).
      local _example_awk="/^example:[[:space:]]*\|/ { in_ex=1; next } in_ex && /^${_FIELD_NAMES}:/ { in_ex=0 } in_ex { sub(/^  /, \"\"); print }"
      _example=$(printf '%s' "$_current_block" | awk "$_example_awk" || true)

      # Skip blocks with no title (malformed)
      if [ -z "$_title" ]; then
        print_warning "  conventions: skipping malformed block (no title) in PR #${pr_number}"
        _current_block=""
        continue
      fi

      # Idempotency and accumulate-in-place contract (#320):
      #
      # Conventions are canonical — each unique title has exactly ONE entry in the
      # catalog. Multiple PRs that surface or refine the same convention accumulate
      # their PR numbers in that single entry's References line, rather than
      # producing duplicate headings.
      #
      # Cases:
      #   title absent              → append a new entry (existing behavior)
      #   title present, PR# present → already recorded, no-op (idempotent)
      #   title present, PR# absent  → accumulate: append PR# to existing References line
      #
      # Match strategy for idempotency: title_found=1 when we see "## <title>",
      # then scan forward for "**References:**" with "#pr_number" as a whole token
      # (tokenized on spaces/commas to avoid #42 matching #420) before the next
      # "## " heading.
      local _already_present=false
      local _title_exists=false
      if grep -qxF -- "## ${_title}" "$conventions_file" 2>/dev/null; then
        _title_exists=true
        # Title exists — check if this PR# is already in its references line
        if awk -v title="## ${_title}" -v prnum="#${pr_number}" '
          BEGIN { matched=0 }
          $0 == title { found=1; next }
          found && /^\*\*References:\*\*/ {
            n = split($0, tokens, /[[:space:],]+/)
            for (i = 1; i <= n; i++) {
              if (tokens[i] == prnum) { matched=1; exit }
            }
            found=0; next
          }
          found && /^## / { found=0 }
          END { exit (matched ? 0 : 1) }
        ' "$conventions_file" 2>/dev/null; then
          _already_present=true
        fi
      fi

      if [ "$_already_present" = "true" ]; then
        verbose_info "  conventions: '$_title' already recorded for PR #${pr_number} — skipping"
        # Still update tag-index even when convention is a no-op: the pointer may
        # not exist yet (e.g. tag-index was bootstrapped after the first PR merged).
        update_tag_index_from_block "$_tags" "$_new_tags" "conventions.md" "$_title" "$pr_number"
        _mark_updated "tag-index"
        _current_block=""
        continue
      fi

      if [ "$_title_exists" = "true" ]; then
        # Title exists but this PR# is not yet in its References line.
        # Accumulate in place: append ", #PR_NUMBER" to the existing entry's
        # References line rather than creating a duplicate heading.
        # This preserves the append-only catalog contract (one canonical entry
        # per convention; multiple PRs accumulate on the same entry).
        #
        # awk rewrites the file in-place via a temp file:
        # - scans for "## <title>" to locate the right entry (handles multiple
        #   entries with different titles; stops at the first match)
        # - within that entry, finds "**References:**" and appends ", #PR_NUMBER"
        # - all other lines pass through unchanged
        local _refs_tmp
        # Guard: mktemp failure must not propagate — skip this block's accumulation
        # and continue the while loop so other blocks in the PR body are processed.
        _refs_tmp=$(mktemp 2>/dev/null) || {
          print_warning "  conventions: mktemp failed for refs rewrite — skipping accumulate for '$_title' (temp space issue?)"
          _current_block=""
          continue
        }
        local _awk_exit=0
        awk -v title="## ${_title}" -v prnum="#${pr_number}" '
          BEGIN { in_target=0; updated=0 }
          $0 == title && !updated { in_target=1; print; next }
          in_target && /^\*\*References:\*\*/ && !updated {
            print $0 ", " prnum
            in_target=0; updated=1; next
          }
          in_target && /^## / { in_target=0 }
          { print }
          END { if (!updated) exit 3 }
        ' "$conventions_file" > "$_refs_tmp" || _awk_exit=$?
        # Only replace the file if awk produced non-empty output (safety net)
        # and awk reported a successful update (exit 0; exit 3 means no References
        # line was found — the catalog entry is malformed or has no References line).
        if [ -s "$_refs_tmp" ] && [ "$_awk_exit" -eq 0 ]; then
          mv "$_refs_tmp" "$conventions_file"
          print_info "  conventions: updated references for '$_title' (added PR #${pr_number})"
          _mark_updated "conventions"
        else
          rm -f "$_refs_tmp"
          print_warning "  conventions: could not append PR #${pr_number} to '$_title' — no References line found in entry (skipping)"
        fi
        # Update tag-index regardless of whether the References accumulation succeeded
        update_tag_index_from_block "$_tags" "$_new_tags" "conventions.md" "$_title" "$pr_number"
        _mark_updated "tag-index"
        _current_block=""
        continue
      fi

      # Title is new — build the rendered markdown entry and append it.
      # If references already contains a value from the PR body, append the PR#.
      # If references is empty, use just the PR#.
      local _refs_line
      if [ -n "$_references" ]; then
        _refs_line="${_references}, #${pr_number}"
      else
        _refs_line="#${pr_number}"
      fi

      {
        echo ""
        echo "## ${_title}"
        echo ""
        [ -n "$_rule" ] && echo "**Rule:** ${_rule}"
        echo ""
        [ -n "$_why" ] && echo "**Why:** ${_why}"
        if [ -n "$_example" ]; then
          echo ""
          echo "**Example:**"
          # Use a fence that is longer than any run of backticks inside the example.
          # Standard markdown: a fenced block is closed only by a fence of equal
          # or greater length, so we need at least (max_run + 1) backticks.
          # Minimum is 3 (the CommonMark minimum fence length).
          #
          # Algorithm:
          #   1. grep -oE finds every maximal run of backticks in the example.
          #   2. awk computes the length of the longest run (0 when no runs found).
          #   3. fence_len = max(3, longest_run + 1).
          #
          # Using printf '%s' + grep avoids $() subshell newline-stripping issues
          # and is safe under set -euo pipefail (|| true guards the grep).
          local _max_backtick_run
          _max_backtick_run=$(printf '%s' "$_example" | grep -oE '`+' | awk 'BEGIN{m=0} {if(length($0)>m) m=length($0)} END{print m}' || true)
          _max_backtick_run="${_max_backtick_run:-0}"
          local _fence_len
          _fence_len=$(( _max_backtick_run + 1 ))
          [ "$_fence_len" -lt 3 ] && _fence_len=3
          local _fence
          _fence=$(printf '%*s' "$_fence_len" '' | tr ' ' '`')
          echo "${_fence}bash"
          printf '%s\n' "$_example"
          echo "$_fence"
        fi
        echo ""
        echo "**References:** ${_refs_line}"
        echo ""
        echo "---"
      } >> "$conventions_file"

      print_info "  conventions: appended '${_title}' (PR #${pr_number})"
      _mark_updated "conventions"
      # Update tag-index with any tags declared in this new convention block
      update_tag_index_from_block "$_tags" "$_new_tags" "conventions.md" "$_title" "$pr_number"
      _mark_updated "tag-index"
      _current_block=""
    else
      # Accumulate block lines
      if [ -z "$_current_block" ]; then
        _current_block="$_line"
      else
        _current_block="${_current_block}
${_line}"
      fi
    fi
  done < "$_blocks_file"
  rm -f "$_blocks_file"
}

# reconcile_tag_index PR_BODY PR_NUMBER
#
# Stage 3 drift reconciliation skeleton — triggered after update_conventions_from_marker
# adds any new tags from the PR's convention block.  Parses the PR body for unfenced
# `new-tags:` name/justification pairs and logs a per-tag audit line via
# tag_index_log_history().
#
# This function is the foundation for Stage 3; the two sonnet passes (similarity
# check and coverage check) are stubbed as no-ops here and will be filled in by
# later sub-issues (#766, #767).
#
# Graceful-degradation contract (absorbs #764):
#   - A non-zero return must NEVER abort the doc-assessment pass.
#   - All call sites must use `reconcile_tag_index ... || true`.
#   - All error paths inside this function return 0 (no abort signal).
#
# Fence-guard awk: new-tags: content inside triple-backtick code fences is NOT
# extracted (mirrors the fence-guard in update_conventions_from_marker).
#
# Arguments:
#   $1 — PR body text
#   $2 — PR number (for audit lines)
reconcile_tag_index() {
  local pr_body="$1"
  local pr_number="$2"

  # No-op when body is empty — nothing to parse.
  if [ -z "$pr_body" ]; then
    return 0
  fi

  # Write PR body to a temp file so awk can read it without subshell/pipefail
  # complications.  mktemp failure is non-fatal — skip with a warning.
  local _body_file
  _body_file=$(mktemp 2>/dev/null) || {
    print_warning "  tag-index reconcile: mktemp failed — skipping (temp space issue?)"
    return 0
  }
  printf '%s' "$pr_body" > "$_body_file"

  # Extract unfenced new-tags: lines via fence-guarded awk.
  #
  # The sharkrite-convention block format for new-tags is:
  #   new-tags:
  #     - tagname: One-line justification
  #
  # Strategy: track fence depth (in_fence) using the same col-0 backtick logic
  # as update_conventions_from_marker.  Only emit lines when not inside a fence.
  # Output format: one "TAGNAME\tJUSTIFICATION" line per new-tags entry.
  local _new_tag_pairs
  _new_tag_pairs=$(awk '
    BEGIN { in_fence=0; fence_len=0 }

    # Detect opening/closing fences (col-0 backtick runs of 3+)
    /^(`{3,})/ {
      # Count leading backticks portably (avoid gawk-only 3-arg match).
      run_len = 0
      while (substr($0, run_len + 1, 1) == "`") run_len++
      if (!in_fence) {
        in_fence   = 1
        fence_len  = run_len
        next
      } else if (run_len >= fence_len) {
        in_fence  = 0
        fence_len = 0
        next
      }
    }

    # Skip all lines inside a fence
    in_fence { next }

    # Match "  - tagname: justification" pattern (new-tags: list items)
    /^[[:space:]]*-[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]/ {
      # Strip leading "  - " prefix
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      # Split on first colon to get tag and justification
      colon_pos = index(line, ":")
      if (colon_pos > 0) {
        tag   = substr(line, 1, colon_pos - 1)
        justif = substr(line, colon_pos + 1)
        # Trim leading whitespace from justification
        sub(/^[[:space:]]+/, "", justif)
        if (tag != "" && justif != "") {
          print tag "\t" justif
        }
      }
    }
  ' "$_body_file" || true)
  rm -f "$_body_file"

  # No new-tags: entries found — nothing to audit.
  if [ -z "$_new_tag_pairs" ]; then
    return 0
  fi

  # Log one audit line per new tag via tag_index_log_history().
  local _pair _tag _justif
  while IFS= read -r _pair; do
    [ -z "$_pair" ] && continue
    _tag="${_pair%%	*}"
    _justif="${_pair#*	}"
    # Trim and validate both fields before logging.
    _tag="${_tag#"${_tag%%[![:space:]]*}"}"
    _tag="${_tag%"${_tag##*[![:space:]]}"}"
    _justif="${_justif#"${_justif%%[![:space:]]*}"}"
    _justif="${_justif%"${_justif##*[![:space:]]}"}"
    # Skip if either field is empty after trimming (malformed entry).
    # Two separate checks avoid shell operator precedence ambiguity with || + &&.
    [ -z "$_tag" ] && continue
    [ -z "$_justif" ] && continue
    tag_index_log_history justified "$pr_number" "$_tag" "$_justif"
  done <<< "$_new_tag_pairs"

  # --- Similarity check (#766) + non-numeric confidence guard (#763) ---
  # Ask sonnet whether any of the NEW tags are semantic duplicates of an
  # EXISTING tag; auto-apply a merge only when the model's confidence is a valid
  # number <= 1.0 AND >= 0.85.  Graceful: any provider/JSON failure skips all
  # merges and preserves the new tags (never aborts).
  local _similarity_result=""

  # Build the list of existing tag names from the index.
  local _existing_tags=""
  if parse_tag_index 2>/dev/null; then
    local _et
    for _et in "${TAG_NAMES[@]+"${TAG_NAMES[@]}"}"; do
      [ -z "$_et" ] && continue
      if [ -z "$_existing_tags" ]; then
        _existing_tags="$_et"
      else
        _existing_tags="${_existing_tags}
${_et}"
      fi
    done
  fi

  # Build the list of new tag NAMES from _new_tag_pairs (tag<TAB>justification).
  local _new_tags=""
  local _sim_pair _sim_tag
  while IFS= read -r _sim_pair; do
    [ -z "$_sim_pair" ] && continue
    _sim_tag="${_sim_pair%%	*}"
    _sim_tag="${_sim_tag#"${_sim_tag%%[![:space:]]*}"}"
    _sim_tag="${_sim_tag%"${_sim_tag##*[![:space:]]}"}"
    [ -z "$_sim_tag" ] && continue
    if [ -z "$_new_tags" ]; then
      _new_tags="$_sim_tag"
    else
      _new_tags="${_new_tags}
${_sim_tag}"
    fi
  done <<< "$_new_tag_pairs"

  # Skip entirely when either side is empty — no possible merges.
  if [ -n "$_existing_tags" ] && [ -n "$_new_tags" ]; then
    local _sim_prompt
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: ${_new_tags}/${_existing_tags} must be expanded into the prompt
    _sim_prompt="$(cat <<SIMILARITY_EOF
Output ONLY a single JSON object. No prose before or after.

You are deduplicating a tag catalog. Below are NEW tags being added and the
EXISTING tags already in the catalog. Identify which NEW tags are semantic
duplicates of an EXISTING tag (same concept, different wording).

Return JSON of the form:
{"merges":[{"from":"<new tag name>","into":"<existing tag name>","confidence":<number 0..1>}]}

Rules:
- Propose a merge ONLY when you are confident (confidence >= 0.85).
- "from" MUST be one of the NEW tags; "into" MUST be one of the EXISTING tags.
- If there are no duplicates, return {"merges":[]}.
- confidence MUST be a plain decimal number between 0 and 1.

NEW tags:
${_new_tags}

EXISTING tags:
${_existing_tags}
SIMILARITY_EOF
)"

    # Use the doc_assessment model (sonnet): structured semantic comparison.
    _similarity_result=$(provider_run_prompt_with_timeout "$_sim_prompt" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true

    if [ -n "$_similarity_result" ]; then
      # Parse merge entries as compact JSON objects (one per line). jq guarded
      # with || true so malformed/empty JSON degrades to zero merges.
      local _merges
      _merges=$(printf '%s' "$_similarity_result" | jq -c '.merges[]?' 2>/dev/null || true)

      if [ -n "$_merges" ]; then
        local _merge_obj _from_tag _into_tag _conf
        while IFS= read -r _merge_obj; do
          [ -z "$_merge_obj" ] && continue
          _from_tag=$(printf '%s' "$_merge_obj" | jq -r '.from // empty' 2>/dev/null || true)
          _into_tag=$(printf '%s' "$_merge_obj" | jq -r '.into // empty' 2>/dev/null || true)
          # Extract confidence as a raw string so we can validate it ourselves
          # rather than letting jq silently coerce a non-numeric value (#763).
          _conf=$(printf '%s' "$_merge_obj" | jq -r '.confidence // empty | tostring' 2>/dev/null || true)

          [ -z "$_from_tag" ] && continue
          [ -z "$_into_tag" ] && continue

          # Confidence guard (#763): accept ONLY a plain number that is <= 1.0.
          # Reject (skip, do not coerce) anything else: "0.9x", "abc", "1.5", "".
          case "$_conf" in
            *[!0-9.]* | "" ) continue ;;        # non-numeric chars or empty
          esac
          # Must match ^[0-9]+(\.[0-9]+)?$ (single optional decimal point).
          if ! printf '%s' "$_conf" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
            continue
          fi
          # Numerically <= 1.0 (awk handles the decimal comparison portably).
          if [ "$(awk -v c="$_conf" 'BEGIN { print (c <= 1.0) ? 1 : 0 }')" != "1" ]; then
            continue
          fi
          # Apply only at confidence >= 0.85.
          if [ "$(awk -v c="$_conf" 'BEGIN { print (c >= 0.85) ? 1 : 0 }')" != "1" ]; then
            continue
          fi

          if tag_index_merge_tag "$_from_tag" "$_into_tag"; then
            tag_index_log_history merged "$pr_number" "$_from_tag" "$_into_tag"
          fi
        done <<< "$_merges"
      fi
    fi
  fi

  # --- Coverage check (drift) (#767) ---
  # Ask sonnet, for each NEW tag, which existing catalog headings (in
  # conventions.md / encountered-issues.md / behavioral-design.md) describe the
  # same subject but are NOT yet pointed at by tag-index.md → that tag, then add
  # the missing pointers (section-safe via tag_index_add_coverage_pointer).
  # Graceful: any provider/JSON failure adds zero pointers and never aborts.
  # Anti-hallucination: a returned pointer is applied ONLY when its tag is one
  # of THIS PR's new tags (_new_tags, built above for the similarity check).
  local _coverage_result=""

  if [ -n "$_new_tags" ]; then
    # Gather catalog content best-effort — skip any file that is absent.
    local _catalog_content=""
    local _cat_file
    for _cat_file in \
      "${RITE_PROJECT_ROOT}/docs/architecture/conventions.md" \
      "${RITE_PROJECT_ROOT}/docs/architecture/encountered-issues.md" \
      "${RITE_PROJECT_ROOT}/docs/architecture/behavioral-design.md"; do
      [ -f "$_cat_file" ] || continue
      _catalog_content="${_catalog_content}
--- $(basename "$_cat_file") ---
$(cat "$_cat_file" 2>/dev/null || true)"
    done

    # Only call the model when we actually have catalog content to scan against.
    if [ -n "$_catalog_content" ]; then
      local _coverage_prompt
      # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: ${_new_tags}/${_catalog_content} must be expanded into the prompt
      _coverage_prompt="$(cat <<COVERAGE_EOF
Output ONLY a single JSON object. No prose before or after.

You maintain a tag index that routes tags to headings in catalog docs. Below are
NEW tags being added and the catalog documents (each headed by its filename).
For each NEW tag, identify existing catalog headings whose subject matter matches
that tag but which are NOT obviously already pointed at — these are missing
pointers the index should gain.

Return JSON of the form:
{"missing_pointers":[{"tag":"<new tag name>","target":"file.md#heading"}]}

Rules:
- "tag" MUST be one of the NEW tags listed below.
- "target" MUST be "<filename>#<exact heading text>" using a heading that
  literally appears in that file.
- Propose a pointer ONLY when the heading clearly concerns the tag's subject.
- If there are no missing pointers, return {"missing_pointers":[]}.

NEW tags:
${_new_tags}

Catalog documents:
${_catalog_content}
COVERAGE_EOF
)"

      # Use the doc_assessment model (sonnet): structured heading matching.
      _coverage_result=$(provider_run_prompt_with_timeout "$_coverage_prompt" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true

      if [ -n "$_coverage_result" ]; then
        # Parse pointer entries as compact JSON objects (one per line). jq guarded
        # with || true so malformed/empty JSON degrades to zero pointers.
        local _pointers
        _pointers=$(printf '%s' "$_coverage_result" | jq -c '.missing_pointers[]?' 2>/dev/null || true)

        if [ -n "$_pointers" ]; then
          local _ptr_obj _cov_tag _cov_target _cov_file _cov_heading _is_new_tag
          while IFS= read -r _ptr_obj; do
            [ -z "$_ptr_obj" ] && continue
            _cov_tag=$(printf '%s' "$_ptr_obj" | jq -r '.tag // empty' 2>/dev/null || true)
            _cov_target=$(printf '%s' "$_ptr_obj" | jq -r '.target // empty' 2>/dev/null || true)

            [ -z "$_cov_tag" ] && continue
            [ -z "$_cov_target" ] && continue

            # Anti-hallucination guard: the tag MUST be one of THIS PR's new tags.
            # _new_tags is newline-separated; match a whole line exactly.
            _is_new_tag=$(printf '%s\n' "$_new_tags" | grep -qxF "$_cov_tag" && echo "yes" || true)
            if [ "$_is_new_tag" != "yes" ]; then
              print_warning "  tag-index: skipping coverage pointer for unknown tag '${_cov_tag}' (not a new tag in this PR)" >&2
              continue
            fi

            # Derive file/heading the same way the helper does (split on FIRST #).
            _cov_file="${_cov_target%%#*}"
            _cov_heading="${_cov_target#*#}"

            # Ensure the tag's section exists so the section-safe insert has an
            # anchor (mirrors update_tag_index_from_block). No-op if present.
            tag_index_ensure_file
            tag_index_ensure_heading "$_cov_tag"

            if tag_index_add_coverage_pointer "$_cov_tag" "$_cov_target"; then
              tag_index_log_history added "$pr_number" "$_cov_tag" "$_cov_file" "$_cov_heading"
            fi
          done <<< "$_pointers"
        fi
      fi
    fi
  fi

  return 0
}

# commit_catalog_files — best-effort commit (and push) of the two auto-written
# catalog files after the writers run.
#
# Context: update_conventions_from_marker() and update_tag_index_from_block()
# write docs/architecture/conventions.md and docs/architecture/tag-index.md
# directly into the main worktree ($RITE_PROJECT_ROOT). Without a commit step
# the changes are stranded as uncommitted/untracked state and silently lost
# when any clean-tree operation (checkout, stash, reset) runs.  This helper
# is the commit step; it mirrors the Layer 2 best-effort commit+push style at
# lines ~1959-1979 of this file.
#
# Safety constraints (see issue #1030):
#   - All git ops use `git -C "$RITE_PROJECT_ROOT"` — the script cds into the
#     feature worktree when invoked with --worktree, so relative-path git ops
#     would target the wrong worktree.
#   - `git add` is issued per-file (not as a multi-file batch) so that a
#     missing tag-index.md (first PR with tags) does not cause git to exit
#     non-zero and silently skip staging conventions.md alongside it.
#   - Change detection covers both modified ("M ") and untracked ("??") states
#     so tag-index.md (which may be newly created) is handled correctly.
#   - When the main worktree HEAD is not on the default branch (main/master),
#     we skip silently with one info line. Committing catalogs onto an arbitrary
#     feature checkout would corrupt the user's working tree.
#   - Push uses an explicit `git push origin main` refspec (not a bare `git
#     push`) to satisfy the GIT_PUSH_NO_REFSPEC lint rule and be unambiguous.
#   - Push failure is non-fatal but the commit is rolled back (`reset --soft
#     HEAD~1`) so local main stays fast-forwardable. A bare "local only"
#     approach would leave local main with a commit that can never be pushed,
#     breaking the post-merge `git pull --ff-only` in merge-pr.sh.
#   - Any git failure (commit fails, repo not found) returns 0 so downstream
#     assessments still run.
commit_catalog_files() {
  local pr_number="$1"

  # Guard: only commit when the main worktree is on the default branch.
  # Committing onto a user's feature branch or a detached HEAD would be wrong.
  local _main_branch
  _main_branch=$(git -C "$RITE_PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  case "${_main_branch}" in
    main|master)
      # On the default branch — safe to commit catalogs.
      ;;
    ""|HEAD)
      # Detached HEAD or unknown — skip.
      print_info "  catalog commit: detached HEAD or unresolvable branch in main worktree — skipping"
      return 0
      ;;
    *)
      # Some other branch (user's feature checkout).  Skip rather than pollute.
      print_info "  catalog commit: main worktree is on '${_main_branch}' (not main/master) — skipping"
      return 0
      ;;
  esac

  # Check whether either catalog file has uncommitted changes (modified or untracked).
  # `git status --porcelain -- <paths>` outputs one line per changed path; empty = clean.
  # `|| true` prevents the pipeline from killing the script under set -e when no
  # paths are listed (git exits 0 anyway, but the || true is defensive).
  local _status
  _status=$(git -C "$RITE_PROJECT_ROOT" status --porcelain \
    -- "docs/architecture/conventions.md" "docs/architecture/tag-index.md" 2>/dev/null || true)

  if [ -z "$_status" ]; then
    # No changes to either catalog file — nothing to commit.
    return 0
  fi

  # Stage exactly the two catalog paths (no broad git add -A / git add .).
  # Add each file individually so a missing tag-index.md (first PR with tags)
  # does not cause git add to exit non-zero and skip staging conventions.md.
  git -C "$RITE_PROJECT_ROOT" add "docs/architecture/conventions.md" 2>/dev/null || true
  git -C "$RITE_PROJECT_ROOT" add "docs/architecture/tag-index.md" 2>/dev/null || true

  # Commit best-effort.  `git commit` exits non-zero if there is nothing to commit
  # (e.g. the add above was a no-op because the file was already staged); that is
  # not an error — just return 0 without a push attempt.
  if git -C "$RITE_PROJECT_ROOT" commit \
    -m "docs: update catalog files for PR #${pr_number}

Auto-committed by assess-documentation (conventions + tag-index catalog update).

Related: #${pr_number}" 2>/dev/null; then
    # Commit succeeded — push best-effort with an explicit refspec so the lint
    # rule (GIT_PUSH_NO_REFSPEC) is satisfied and the push target is unambiguous.
    # If push fails (e.g. non-fast-forward because origin/main advanced while we
    # were working), undo the commit so local main stays fast-forwardable.
    # Leaving a committed-but-not-pushable HEAD would break the workflow's own
    # post-merge "git pull --ff-only" in merge-pr.sh.
    if git -C "$RITE_PROJECT_ROOT" push origin main 2>/dev/null; then
      print_info "  catalog commit: committed and pushed catalog updates for PR #${pr_number}"
    else
      # Push failed — roll back the commit so local main is not left diverged.
      git -C "$RITE_PROJECT_ROOT" reset --soft HEAD~1 2>/dev/null || true
      print_info "  catalog commit: push failed for PR #${pr_number} — catalog changes left as uncommitted local state"
    fi
  fi

  return 0
}

# --- Run internal doc assessments ---

# Conventions marker extraction is instant (no Claude call) — run inline
update_conventions_from_marker "$PR_NUMBER" "$PR_BODY"
# Tag-index reconcile: parse PR body for new-tags: justifications and log audit
# lines.  The || true backstop (#764) ensures a non-zero return never aborts the
# doc-assessment pass under set -euo pipefail.
reconcile_tag_index "$PR_BODY" "$PR_NUMBER" || true
# Commit any catalog changes the two writers above produced.  Best-effort:
# never aborts the assessment on failure.
commit_catalog_files "$PR_NUMBER" || true

# Changelog is instant (no Claude call) — run inline
assess_internal_changelog "$PR_NUMBER" "$PR_TITLE" "$CHANGED_FILES"

# Claude-calling assessments run in parallel (each writes to its own file)
_assess_pids=()
_assess_names=()
assess_internal_security "$PR_NUMBER" "$PR_DIFF" "$CHANGED_FILES" "$PR_TITLE" &
_assess_pids+=($!)
_assess_names+=("security")
assess_internal_architecture "$PR_NUMBER" "$PR_DIFF" "$CHANGED_FILES" &
_assess_pids+=($!)
_assess_names+=("architecture")
assess_internal_api "$PR_NUMBER" "$PR_DIFF" "$CHANGED_FILES" &
_assess_pids+=($!)
_assess_names+=("api")
assess_internal_adr "$PR_NUMBER" "$PR_DIFF" "$PR_BODY" "$PR_TITLE" &
_assess_pids+=($!)
_assess_names+=("adr")
# Wait individually so we can report which assessments failed
for _i in "${!_assess_pids[@]}"; do
  _pid_exit=0
  wait "${_assess_pids[$_i]}" 2>/dev/null || _pid_exit=$?
  if [ "$_pid_exit" -ne 0 ]; then
    print_warning "Internal doc assessment failed: ${_assess_names[$_i]} (exit $_pid_exit)" >&2
  fi
done
unset _assess_pids _assess_names

# Collect marker files into INTERNAL_UPDATED array
for _marker in "$_MARKER_DIR"/*; do
  [ -f "$_marker" ] && INTERNAL_UPDATED+=("$(basename "$_marker")")
done

# --- Reconciliation pass: fold PR deltas into baseline ---
# Triggered when a doc accumulates 3+ PR sections. Merges append-only deltas
# back into the baseline so stale top-level statements get corrected.

reconcile_internal_doc() {
  local doc_file="$1"
  local doc_name="$2"

  [ -f "$doc_file" ] || return 0

  # Count PR delta sections (## PR #N headers)
  local pr_section_count
  pr_section_count=$(grep -c "^## PR #" "$doc_file" 2>/dev/null || true)

  # Only reconcile when 3+ PR sections have accumulated
  if [ "$pr_section_count" -lt 3 ]; then
    return 0
  fi

  local current_content
  current_content=$(cat "$doc_file")
  local current_lines
  # printf '%s\n' ensures a trailing newline so wc -l counts the last line even
  # when the file content has no trailing newline (wc -l counts newline characters).
  current_lines=$(printf '%s\n' "$current_content" | wc -l | tr -d ' ')

  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" <<RECONCILE_EOF
Output ONLY the reconciled document. No explanations before or after.

This ${doc_name} document has a baseline section followed by incremental PR delta sections.
The PR deltas contain newer, more accurate information that may contradict the baseline.

Your task: merge ALL PR delta information INTO the baseline sections, then REMOVE the PR delta
sections. The result should be a single cohesive document with no "## PR #N" sections remaining.

Rules:
- When a PR delta contradicts the baseline, the PR delta is correct (it's newer)
- Preserve all information from PR deltas — fold it into the appropriate baseline section
- If the baseline says something like "No X found" but a PR delta documents X, UPDATE the baseline
- Keep the same top-level structure and format as the baseline
- Do NOT add prose, explanations, or summaries — maintain machine-formatted reference style
- Do NOT lose any information from either baseline or deltas

Current document:
${current_content}
RECONCILE_EOF

  verbose_info "  Reconciling doc updates..."
  local reconciled_output
  # Use doc_assessment model (sonnet): structured merging of doc sections.
  # Independent of RITE_REVIEW_MODEL — see docs/architecture/behavioral-design.md.
  reconciled_output=$(provider_run_prompt_with_timeout "$(cat "$prompt_file")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -z "$reconciled_output" ]; then
    return 0
  fi

  # Truncation safety: reconciled doc should be at least 60% of original.
  # printf '%s\n' ensures a trailing newline so wc -l counts the last line even
  # when the output has no trailing newline (wc -l counts newline characters).
  local new_lines
  new_lines=$(printf '%s\n' "$reconciled_output" | wc -l | tr -d ' ')
  local min_lines=$((current_lines * 60 / 100))

  if [ "$new_lines" -lt "$min_lines" ]; then
    print_warning "  Reconciliation of $doc_name skipped (output too short: ${new_lines} vs ${current_lines} lines)"
    return 0
  fi

  # Verify PR sections were actually merged (no ## PR # headers should remain)
  local remaining_pr_sections
  remaining_pr_sections=$(echo "$reconciled_output" | grep -c "^## PR #" 2>/dev/null || true)
  if [ "$remaining_pr_sections" -gt 0 ]; then
    print_warning "  Reconciliation of $doc_name skipped (PR sections not merged)"
    return 0
  fi

  echo "$reconciled_output" > "$doc_file"
  _mark_updated "${doc_name}(reconciled)"
}

# Run reconciliation in parallel — each call writes to its own file, no shared state
_reconcile_pids=()
_reconcile_names=()
reconcile_internal_doc "${RITE_INTERNAL_DOCS_DIR}/security.md" "security" &
_reconcile_pids+=($!)
_reconcile_names+=("security")
reconcile_internal_doc "${RITE_INTERNAL_DOCS_DIR}/architecture.md" "architecture" &
_reconcile_pids+=($!)
_reconcile_names+=("architecture")
reconcile_internal_doc "${RITE_INTERNAL_DOCS_DIR}/api.md" "api" &
_reconcile_pids+=($!)
_reconcile_names+=("api")
# Wait individually so we can report which reconciliations failed
for _i in "${!_reconcile_pids[@]}"; do
  _pid_exit=0
  wait "${_reconcile_pids[$_i]}" 2>/dev/null || _pid_exit=$?
  if [ "$_pid_exit" -ne 0 ]; then
    print_warning "Doc reconciliation failed: ${_reconcile_names[$_i]} (exit $_pid_exit)" >&2
  fi
done
unset _reconcile_pids _reconcile_names

# Re-collect markers after reconciliation
for _marker in "$_MARKER_DIR"/*; do
  [ -f "$_marker" ] || continue
  _name="$(basename "$_marker")"
  # Skip if already in array
  # Empty-array safe idiom (bash 3.2 / set -u): "${arr[@]+"${arr[@]}"}" expands
  # to nothing when the array is empty, avoiding "unbound variable" under set -u.
  _found=false
  for _existing in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
    [ "$_existing" = "$_name" ] && { _found=true; break; }
  done
  [ "$_found" = false ] && INTERNAL_UPDATED+=("$_name")
done

# --- Cross-document consistency validation ---
# Same logic as bootstrap-docs.sh but runs during assessment when a reconciliation
# just happened (docs were rewritten, good time to catch cross-doc drift).

_validate_cross_doc_consistency() {
  local docs_dir="$1"
  local arch_file="${docs_dir}/architecture.md"
  local api_file="${docs_dir}/api.md"
  local security_file="${docs_dir}/security.md"

  # Need at least 2 docs
  local doc_count=0
  [ -f "$arch_file" ] && doc_count=$((doc_count + 1))
  [ -f "$api_file" ] && doc_count=$((doc_count + 1))
  [ -f "$security_file" ] && doc_count=$((doc_count + 1))
  [ "$doc_count" -lt 2 ] && return 0

  local arch_content="" api_content="" security_content=""
  [ -f "$arch_file" ] && arch_content=$(cat "$arch_file")
  [ -f "$api_file" ] && api_content=$(cat "$api_file")
  [ -f "$security_file" ] && security_content=$(cat "$security_file")

  local prompt_file=$(mktemp)
  cat > "$prompt_file" <<VALIDATE_EOF
You are validating consistency across multiple generated documentation files.
Find CONTRADICTIONS between documents — places where two docs state different facts
about the same thing (e.g., different default values, conflicting file lists, one doc
says a feature exists while another says it doesn't).

Output format — ONLY output contradictions found. If none, output exactly: NO_CONTRADICTIONS

For each contradiction:
CONTRADICTION: <brief description>
FILE1: <filename> LINE: "<the contradicting text>"
FILE2: <filename> LINE: "<the contradicting text>"
CORRECTION: <which file is likely correct and what the fix is>

Rules:
- Only flag actual contradictions (same fact, different values)
- Do NOT flag omissions (one doc has info the other lacks)
- Do NOT flag stylistic differences
- Focus on: default values, file paths, feature existence claims, configuration

--- architecture.md ---
${arch_content}

--- api.md ---
${api_content}

--- security.md ---
${security_content}
VALIDATE_EOF

  local validation_output
  # Use doc_assessment model (sonnet): cross-doc consistency check, structured comparison.
  # Independent of RITE_REVIEW_MODEL — see docs/architecture/behavioral-design.md.
  validation_output=$(provider_run_prompt_with_timeout "$(cat "$prompt_file")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -z "$validation_output" ] || echo "$validation_output" | grep -q "^NO_CONTRADICTIONS"; then
    return 0
  fi

  # Apply corrections per file
  for target_file in "$arch_file" "$api_file" "$security_file"; do
    [ -f "$target_file" ] || continue
    local target_name=$(basename "$target_file")
    echo "$validation_output" | grep -q "$target_name" || continue

    local current_content=$(cat "$target_file")
    local fix_prompt_file=$(mktemp)
    cat > "$fix_prompt_file" <<FIX_EOF
Apply ONLY the corrections listed below to this document. Change nothing else.
Output the COMPLETE corrected file.

Corrections to apply:
${validation_output}

Current ${target_name}:
${current_content}
FIX_EOF

    local fixed_output
    # Use doc_assessment model (sonnet): applying targeted corrections to a doc file.
    # Independent of RITE_REVIEW_MODEL — see docs/architecture/behavioral-design.md.
    fixed_output=$(provider_run_prompt_with_timeout "$(cat "$fix_prompt_file")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null) || true
    rm -f "$fix_prompt_file"

    if [ -n "$fixed_output" ]; then
      # printf '%s\n' ensures a trailing newline so wc -l counts the last line
      # even when output has no trailing newline (wc -l counts newline characters).
      local orig_lines=$(printf '%s\n' "$current_content" | wc -l | tr -d ' ')
      local fixed_lines=$(printf '%s\n' "$fixed_output" | wc -l | tr -d ' ')
      local min_lines=$((orig_lines * 80 / 100))
      if [ "$fixed_lines" -ge "$min_lines" ]; then
        echo "$fixed_output" > "$target_file"
        _mark_updated "${target_name}(consistency-fix)"
      fi
    fi
  done
}

# Only run cross-doc validation when a reconciliation actually happened
# (indicated by "(reconciled)" in INTERNAL_UPDATED)
RECONCILED=false
# Empty-array safe idiom (bash 3.2 / set -u): "${arr[@]+"${arr[@]}"}" expands
# to nothing when the array is empty, avoiding "unbound variable" under set -u.
for item in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
  if echo "$item" | grep -q "reconciled"; then
    RECONCILED=true
    break
  fi
done

if [ "$RECONCILED" = true ]; then
  verbose_info "  Validating cross-doc consistency..."
  _validate_cross_doc_consistency "${RITE_INTERNAL_DOCS_DIR}"
fi

# Internal docs (.rite/docs/) are gitignored in target projects — no commit needed.
# The files are written directly to the local .rite/docs/ directory.

# =====================================================================
# COMBINED OUTPUT HEADER
# =====================================================================

print_header "📚 Documentation"

# Final marker collection (picks up cross-doc consistency fixes)
for _marker in "$_MARKER_DIR"/*; do
  [ -f "$_marker" ] || continue
  _name="$(basename "$_marker")"
  _found=false
  # Empty-array safe idiom (bash 3.2 / set -u): "${arr[@]+"${arr[@]}"}" expands
  # to nothing when the array is empty, avoiding "unbound variable" under set -u.
  for _existing in "${INTERNAL_UPDATED[@]+"${INTERNAL_UPDATED[@]}"}"; do
    [ "$_existing" = "$_name" ] && { _found=true; break; }
  done
  [ "$_found" = false ] && INTERNAL_UPDATED+=("$_name")
done
rm -rf "$_MARKER_DIR"

# Internal docs one-liner summary
if [ ${#INTERNAL_UPDATED[@]} -gt 0 ]; then
  INTERNAL_SUMMARY=$(printf '%s ✓  ' "${INTERNAL_UPDATED[@]}")
  echo -e "${GREEN}    Internal: ${INTERNAL_SUMMARY% }${NC}"
else
  print_info "  Internal: up to date"
fi

# =====================================================================
# LAYER 2: USER PROJECT DOCS (only if doc-sync.md exists)
# =====================================================================

# ---------------------------------------------------------------------------
# _append_doc_drift_entry PR_NUMBER PR_BODY CHANGED_FILES
#
# Changelog-mode helper: append one drift log entry for this PR and commit
# + push the log only. Called when RITE_DOC_MODE=changelog AND doc-sync.md
# is absent (the user has opted in to changelog mode but not sync mode).
#
# Graceful-degradation contract: same as reconcile_tag_index (lines 1009-1012)
# — every error path prints a warning and returns 0 so the doc-assessment pass
# is never aborted.
#
# Arguments:
#   $1  PR number
#   $2  PR body text (already-fetched PR_BODY — no extra gh call)
#   $3  Newline-separated changed files (non-docs), may be empty
# ---------------------------------------------------------------------------
_append_doc_drift_entry() {
  local pr_number="$1"
  local pr_body="$2"
  local changed_files_no_docs="$3"

  # ------------------------------------------------------------------
  # Skip: docs-only PR (CHANGED_FILES_NO_DOCS is empty) — no entry,
  # no noise. One verbose line so diagnostics are traceable.
  # ------------------------------------------------------------------
  if [ -z "$changed_files_no_docs" ]; then
    verbose_info "  drift-log: PR #${pr_number} is docs-only — skipping drift entry"
    return 0
  fi

  # ------------------------------------------------------------------
  # Extract issue number from PR body via the same sed as merge-pr.sh:1062.
  # No extra gh call — PR_BODY is already fetched.
  # ------------------------------------------------------------------
  local issue_number
  issue_number="$(echo "$pr_body" | sed -n 's/.*Closes #\([0-9]\{1,\}\).*/\1/p' | head -1 || true)"
  issue_number="${issue_number:--}"   # fall back to "-" when absent

  # ------------------------------------------------------------------
  # Implicated docs: source the docs map, grep each mapped doc for
  # mentions of the changed source paths or their basenames, and collect
  # up to 10 matches with their nearest heading (section attribution).
  # ------------------------------------------------------------------
  # Ensure docs map exists (build silently if missing; errors are non-fatal).
  docs_map_ensure || true

  local map_file
  map_file="$(docs_map_path)" || true

  local implicated_docs=""
  local _impl_count=0
  local _cf_line

  if [ -f "$map_file" ]; then
    # Collect doc file paths from the map (column 1, skip the comment header).
    # Use a while-read loop for bash 3.2 compat (no mapfile).
    local -a _doc_files=()
    while IFS= read -r _map_row; do
      # Skip comment header lines (start with #)
      case "$_map_row" in '#'*) continue ;; esac
      # Extract field 1 (tab-separated)
      local _doc_rel_path
      _doc_rel_path="$(echo "$_map_row" | cut -f1 || true)"
      [ -z "$_doc_rel_path" ] && continue
      # De-duplicate: only add when not already in _doc_files.
      local _already=false
      local _existing_df
      for _existing_df in "${_doc_files[@]+"${_doc_files[@]}"}"; do
        [ "$_existing_df" = "$_doc_rel_path" ] && { _already=true; break; }
      done
      [ "$_already" = false ] && _doc_files+=("$_doc_rel_path")
    done < "$map_file"

    # For each mapped doc, grep for mentions of each changed file or its
    # basename. Record file + nearest heading (section attribution from map).
    local _doc_rel
    for _doc_rel in "${_doc_files[@]+"${_doc_files[@]}"}"; do
      [ "$_impl_count" -ge 10 ] && break   # cap at 10

      local _doc_abs="${RITE_PROJECT_ROOT}/${_doc_rel}"
      [ -f "$_doc_abs" ] || continue

      # Check if any changed file (path or basename) appears in this doc.
      local _matched=false
      local _matched_term=""
      while IFS= read -r _cf_line || [ -n "$_cf_line" ]; do
        [ -z "$_cf_line" ] && continue
        # Check both the full relative path and the basename.
        local _cf_base
        _cf_base="$(basename "$_cf_line")"
        if grep -qF "$_cf_line" "$_doc_abs" 2>/dev/null || \
           grep -qF "$_cf_base" "$_doc_abs" 2>/dev/null; then
          _matched=true
          _matched_term="$_cf_base"
          break
        fi
      done <<EOF_CFCHECK
$changed_files_no_docs
EOF_CFCHECK

      [ "$_matched" = false ] && continue

      # Best-effort section attribution: look up the first heading for this
      # doc in the TSV map (column 5 = heading_text). awk -F'\t' for portable
      # tab-separated parsing (BSD + GNU awk both support -F'\t').
      local _section=""
      _section="$(awk -F'\t' -v doc="$_doc_rel" '$1 == doc && $5 != "" { print $5; exit }' \
        "$map_file" 2>/dev/null || true)"
      # If map lookup returned empty, fall back to the first heading in the file.
      if [ -z "$_section" ]; then
        _section="$(grep -m1 '^#' "$_doc_abs" 2>/dev/null | sed 's/^#\{1,6\}[[:space:]]*//' || true)"
      fi

      if [ -n "$_section" ]; then
        implicated_docs="${implicated_docs}- ${_doc_rel} — \"${_section}\""$'\n'
      else
        implicated_docs="${implicated_docs}- ${_doc_rel}"$'\n'
      fi
      _impl_count=$((_impl_count + 1))
    done
  fi

  # Strip trailing newline from implicated_docs.
  implicated_docs="${implicated_docs%$'\n'}"

  # Skip: zero implicated docs — no entry, no noise.
  if [ -z "$implicated_docs" ]; then
    verbose_info "  drift-log: PR #${pr_number} — no implicated docs found; skipping drift entry"
    return 0
  fi

  # ------------------------------------------------------------------
  # One-liner suspected inaccuracy via doc_assessment model.
  # On provider failure/empty, degrade to deterministic fallback text.
  # Mirrors the model-call pattern at assess-documentation.sh line 1932.
  # Rule 31: never pass "" as model. Rule 32: use provider_resolve_model.
  # ------------------------------------------------------------------
  local _drift_prompt_file
  _drift_prompt_file="$(mktemp 2>/dev/null)" || {
    print_warning "drift-log: mktemp failed for prompt — using fallback inaccuracy line"
    _drift_prompt_file=""
  }

  local suspected_inaccuracy=""
  if [ -n "$_drift_prompt_file" ]; then
    # sharkrite-lint disable UNQUOTED_HEREDOC - Reason: context vars must expand
    cat > "$_drift_prompt_file" <<DRIFT_PROMPT_EOF
You are reviewing a merged pull request to identify the single most likely documentation
inaccuracy it may have introduced.

PR #${pr_number} changed these source files:
${changed_files_no_docs}

The following documentation files were found to mention these files:
${implicated_docs}

In one sentence (≤120 chars), describe the most likely documentation inaccuracy
introduced by this change. Focus on concrete details: changed defaults, removed
features, new commands, renamed symbols, or altered behaviour. Do NOT start with
"The documentation" — start with the specific claim that may now be outdated.

Output ONLY the one-sentence inaccuracy description. Nothing else.
DRIFT_PROMPT_EOF

    suspected_inaccuracy="$(provider_run_prompt_with_timeout "$(cat "$_drift_prompt_file")" \
      "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>/dev/null)" || true
    rm -f "$_drift_prompt_file"
  fi

  # Degrade on empty/failed provider response.
  if [ -z "$suspected_inaccuracy" ]; then
    suspected_inaccuracy="not assessed — provider unavailable; verify implicated sections manually"
  fi

  # ------------------------------------------------------------------
  # Append drift entry (via drift-log.sh library — never aborts).
  # ------------------------------------------------------------------
  drift_log_append "$pr_number" "$issue_number" \
    "$changed_files_no_docs" "$implicated_docs" "$suspected_inaccuracy" || {
    print_warning "drift-log: append failed for PR #${pr_number} — skipping commit"
    return 0
  }

  print_info "  drift-log: recorded drift entry for PR #${pr_number} → docs/sharkrite-drift-log.md"

  # ------------------------------------------------------------------
  # Commit + push the drift log only. Mirrors the Layer 2 commit block
  # at assess-documentation.sh lines 1965-1985.
  # ------------------------------------------------------------------
  local _log_path
  _log_path="$(drift_log_path)" || { print_warning "drift-log: could not resolve path for commit"; return 0; }

  git add "$_log_path" 2>/dev/null || { print_warning "drift-log: git add failed — entry written but not committed"; return 0; }

  local _commit_msg="docs: record drift entry for PR #${pr_number}"
  if git commit -m "$_commit_msg" 2>/dev/null; then
    if git push 2>/dev/null; then
      print_info "  drift-log: committed and pushed"
    else
      print_info "  drift-log: committed (push failed — local only)"
    fi
  else
    # Nothing staged (e.g. no-op append somehow). Not an error.
    verbose_info "  drift-log: nothing to commit (entry may already exist)"
  fi
}

DOC_SYNC_FILE="${RITE_PROJECT_ROOT}/.rite/doc-sync.md"

if [ ! -f "$DOC_SYNC_FILE" ]; then
  # ------------------------------------------------------------------
  # Changelog mode: doc-sync.md absent AND RITE_DOC_MODE=changelog.
  # Append one drift entry instead of editing user docs; then exit 0.
  # Default/unset mode: current behaviour byte-identical (exit 0, no-op).
  # ------------------------------------------------------------------
  if [ "${RITE_DOC_MODE:-}" = "changelog" ]; then
    # Compute CHANGED_FILES_NO_DOCS here — the sync-mode path computes it
    # at line 1785 (after this guard), so we must duplicate it for changelog.
    _CHANGELOG_CHANGED_FILES_NO_DOCS="$(echo "$PR_DATA" | jq -r '.files[]?.path // empty' | grep -v '^docs/' | head -20 || true)"
    _append_doc_drift_entry "$PR_NUMBER" "$PR_BODY" "$_CHANGELOG_CHANGED_FILES_NO_DOCS" || true
  fi
  echo ""
  exit 0
fi

# Read custom sync instructions
DOC_SYNC_INSTRUCTIONS=$(cat "$DOC_SYNC_FILE")

# --- Gather context (quiet — no output) ---

# Look for Sharkrite review in formal reviews first, then comments
_JQ_SHARKRITE_REVIEW_F="[.reviews[] | select(.body | contains(\"${RITE_MARKER_REVIEW}\") or contains(\"${RITE_MARKER_REVIEW_DATA}\"))] | .[-1] | .body // \"\""
SHARKRITE_REVIEW=$(echo "$PR_DATA" | jq -r "$_JQ_SHARKRITE_REVIEW_F" 2>/dev/null)

if [ -z "$SHARKRITE_REVIEW" ] || [ "$SHARKRITE_REVIEW" = "null" ]; then
  _JQ_SHARKRITE_REVIEW_C="[.comments[] | select(.body | contains(\"${RITE_MARKER_REVIEW}\") or contains(\"${RITE_MARKER_REVIEW_DATA}\"))] | .[-1] | .body // \"\""
  SHARKRITE_REVIEW=$(echo "$PR_DATA" | jq -r "$_JQ_SHARKRITE_REVIEW_C" 2>/dev/null)
fi

# Extract documentation-related items from review
DOC_ITEMS_FROM_REVIEW=""
REVIEW_HAS_DOC_ITEMS=false

if [ -n "$SHARKRITE_REVIEW" ] && [ "$SHARKRITE_REVIEW" != "null" ]; then
  DOC_ITEMS_FROM_REVIEW=$(echo "$SHARKRITE_REVIEW" | grep -iE "(documentation|docs/|README|CLAUDE\.md|update.*doc|missing.*doc|add.*doc)" | head -20 || echo "")
  if [ -n "$DOC_ITEMS_FROM_REVIEW" ]; then
    REVIEW_HAS_DOC_ITEMS=true
  fi
fi

# Get changed files (excluding docs/)
CHANGED_FILES_NO_DOCS=$(echo "$PR_DATA" | jq -r '.files[]?.path // empty' | grep -v '^docs/' | head -20 || true)

# Get commit messages for context
COMMIT_MESSAGES=$(echo "$PR_DATA" | jq -r '.commits[]?.messageHeadline // empty' | head -10 || true)

# Get current documentation structure
DOC_FILES=$(find docs/ -name "*.md" 2>/dev/null | sort || echo "")

# Get CLAUDE.md sections if it exists
CLAUDE_MD_SECTIONS=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_MD_SECTIONS=$(grep "^##" CLAUDE.md | head -30 || true)
fi

# Get project README sections if available (configurable per project)
README_SECTIONS=""
if [ -n "${RITE_SCRIPTS_README:-}" ] && [ -f "$RITE_SCRIPTS_README" ]; then
  README_SECTIONS=$(grep "^##" "$RITE_SCRIPTS_README" | head -20 || true)
elif [ -f "README.md" ]; then
  README_SECTIONS=$(grep "^##" README.md | head -20 || true)
fi

# Get table of contents from each major doc to understand coverage
ARCHITECTURE_DOCS=""
for doc in docs/architecture/*.md; do
  if [ -f "$doc" ]; then
    ARCHITECTURE_DOCS="$ARCHITECTURE_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

PROJECT_DOCS=""
for doc in docs/project/*.md; do
  if [ -f "$doc" ]; then
    PROJECT_DOCS="$PROJECT_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

WORKFLOW_DOCS=""
for doc in docs/workflows/*.md; do
  if [ -f "$doc" ]; then
    WORKFLOW_DOCS="$WORKFLOW_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

SECURITY_DOCS=""
for doc in docs/security/*.md; do
  if [ -f "$doc" ]; then
    SECURITY_DOCS="$SECURITY_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

DEVELOPMENT_DOCS=""
for doc in docs/development/*.md; do
  if [ -f "$doc" ]; then
    DEVELOPMENT_DOCS="$DEVELOPMENT_DOCS\n$(basename "$doc"): $( (grep "^#" "$doc" || true) | head -5 | sed 's/^/  /')"
  fi
done

# --- Assessment ---

# Build assessment prompt - include review context if available
REVIEW_CONTEXT_SECTION=""
if [ "$REVIEW_HAS_DOC_ITEMS" = true ]; then
  REVIEW_CONTEXT_SECTION="
**Documentation Items from Sharkrite Review:**
The code review already identified these documentation-related items. Use these as your primary guide:
\`\`\`
$DOC_ITEMS_FROM_REVIEW
\`\`\`

Focus on addressing the specific items mentioned in the review.
"
fi

# Pre-compute doc structure (avoid nested $() inside heredoc)
CLAUDE_MD_INLINE=$(echo "$CLAUDE_MD_SECTIONS" | head -10 | tr '\n' ';' || true)
README_INLINE=""
if [ -n "$README_SECTIONS" ]; then
  README_INLINE="- README.md (project overview): $(echo "$README_SECTIONS" | head -10 | tr '\n' ';')"
fi

# Build assessment prompt in temp file (heredoc inside $() is fragile —
# PR body content can contain shell metacharacters that break parsing)
ASSESS_PROMPT_FILE=$(mktemp)
cat > "$ASSESS_PROMPT_FILE" <<ASSESS_PROMPT_EOF
You are reviewing a pull request to assess if documentation needs updating.

**Custom Instructions:**
$DOC_SYNC_INSTRUCTIONS

**PR Title:** $PR_TITLE

**PR Description:**
$PR_BODY
$REVIEW_CONTEXT_SECTION
**Changed Files (excluding docs/):**
$CHANGED_FILES_NO_DOCS

**Recent Commits:**
$COMMIT_MESSAGES

**Existing Documentation Structure:**

Root-level docs:
- CLAUDE.md (main architecture guide): $CLAUDE_MD_INLINE
$README_INLINE

docs/architecture/ (system design, infrastructure, database):
$(echo -e "$ARCHITECTURE_DOCS")

docs/project/ (business requirements, roadmap, pricing):
$(echo -e "$PROJECT_DOCS")

docs/workflows/ (CI/CD, automation, GitHub Actions):
$(echo -e "$WORKFLOW_DOCS")

docs/security/ (security patterns, vulnerabilities):
$(echo -e "$SECURITY_DOCS")

docs/development/ (dev guides, testing, setup):
$(echo -e "$DEVELOPMENT_DOCS")

**Your Task:**
Assess whether ANY documentation needs to be updated based on these code changes.
Use the Custom Instructions above to determine which docs to check and what rules to follow.

**Response Format:**
If documentation updates are needed, respond with:
NEEDS_UPDATE: <file1.md>, <file2.md>, <file3.md>
REASON: <Brief explanation of what needs updating>

If no documentation updates needed, respond with:
NO_UPDATE_NEEDED
REASON: <Brief explanation>

**Be strict:** Architectural changes, new patterns, new scripts, infrastructure changes ALWAYS need documentation.

**Examples of what doesn't need docs:**
- Bug fixes to existing code (no pattern change)
- Updating existing tests (no new testing strategy)
- Refactoring without behavior change
- Minor version bumps
- Comment improvements
ASSESS_PROMPT_EOF

echo "    Project docs: analyzing..."

# Run assessment — sonnet handles this structured "does diff affect doc X?" task well.
# Uses doc_assessment model, independent of RITE_REVIEW_MODEL.
ASSESSMENT_OUTPUT=$(provider_run_prompt_with_timeout "$(cat "$ASSESS_PROMPT_FILE")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>&1)
rm -f "$ASSESS_PROMPT_FILE"

# --- Apply or report ---

# Guard and extraction use the SAME anchor (^NEEDS_UPDATE: with colon). The old
# colon-less guard let a malformed model line ("NEEDS_UPDATE" alone) enter the
# branch while the colon-anchored extraction returned empty — read -ra of ""
# then produced an empty FILES_ARRAY whose bare [@] crashes bash 3.2 under set -u.
if echo "$ASSESSMENT_OUTPUT" | grep -q "^NEEDS_UPDATE:"; then
  DOCS_TO_UPDATE=$(echo "$ASSESSMENT_OUTPUT" | grep "^NEEDS_UPDATE:" | sed 's/NEEDS_UPDATE: //' || true)
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //' || true)

  echo "    Project docs: $DOCS_TO_UPDATE"
  echo "    Reason: $REASON"

  # In supervised mode, confirm before applying
  APPLY_UPDATES=true
  if [ "${AUTO_MODE:-}" != "--auto" ]; then
    echo ""
    read -p "Apply documentation updates? (Y/n): " APPLY_DOCS
    if [[ "$APPLY_DOCS" =~ ^[Nn]$ ]]; then
      APPLY_UPDATES=false
      read -p "Continue with merge without doc updates? (y/N): " CONTINUE
      if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        print_info "Merge cancelled - update documentation first"
        exit 2
      fi
    fi
  fi

  if [ "$APPLY_UPDATES" = true ]; then
    IFS=',' read -ra FILES_ARRAY <<< "$DOCS_TO_UPDATE"
    UPDATED_FILES=()
    SKIPPED_FILES=()

    # +idiom: "NEEDS_UPDATE:" with an empty file list still passes the guard
    # above; read -ra of "" yields an empty array whose bare [@] crashes
    # bash 3.2 under set -u.
    for doc_file in "${FILES_ARRAY[@]+"${FILES_ARRAY[@]}"}"; do
      doc_file=$(echo "$doc_file" | xargs)  # trim whitespace

      if [ ! -f "$doc_file" ]; then
        SKIPPED_FILES+=("$doc_file (not found)")
        continue
      fi

      CURRENT_CONTENT=$(cat "$doc_file")

      UPDATE_PROMPT_FILE=$(mktemp)
      cat > "$UPDATE_PROMPT_FILE" <<UPDATE_PROMPT_EOF
You are updating documentation to reflect code changes from a PR.

**Documentation Update Rule:**
- If pertinent topic exists: expand section as necessary with new information
- If topic doesn't exist: add new section in appropriate location
- Keep updates minimal and focused on the actual changes
- Consider PR scope - don't over-document minor changes
- Match existing documentation style and format

**PR Context:**
- PR #$PR_NUMBER: $PR_TITLE
- Reason for doc update: $REASON

**PR Changes (diff):**
\`\`\`
$PR_DIFF
\`\`\`

**Current Documentation Content:**
\`\`\`markdown
$CURRENT_CONTENT
\`\`\`

**Your Task:**
Update this documentation file to reflect the PR changes. Output the COMPLETE updated file.

**Guidelines:**
- Maintain all existing content unless it contradicts new changes
- Add new sections only if substantive new functionality was added
- Expand existing sections if the topic is already covered
- Use consistent markdown formatting
- Keep the same structure and organization
- Update timestamps if present (format: YYYY-MM-DD)

Output ONLY the complete updated markdown file, nothing else.
UPDATE_PROMPT_EOF

      # Retry loop for transient empty Claude CLI responses (exit 0 + empty stdout).
      # Same pattern as local-review.sh: max 2 attempts, 3s delay.
      MAX_DOC_ATTEMPTS=2
      DOC_ATTEMPT=0
      CLAUDE_EXIT=0
      UPDATED_CONTENT=""
      while [ $DOC_ATTEMPT -lt $MAX_DOC_ATTEMPTS ] && [ -z "$UPDATED_CONTENT" ]; do
        DOC_ATTEMPT=$((DOC_ATTEMPT + 1))
        CLAUDE_EXIT=0
        # Use doc_assessment model (sonnet) for applying the doc update.
        UPDATED_CONTENT=$(provider_run_prompt_with_timeout "$(cat "$UPDATE_PROMPT_FILE")" "$(provider_resolve_model doc_assessment)" true "$DOC_CLAUDE_TIMEOUT" 2>&1) || CLAUDE_EXIT=$?
        if [ $CLAUDE_EXIT -eq 0 ] && [ -z "$UPDATED_CONTENT" ] && [ $DOC_ATTEMPT -lt $MAX_DOC_ATTEMPTS ]; then
          print_warning "Claude returned empty doc update (attempt $DOC_ATTEMPT/$MAX_DOC_ATTEMPTS) — retrying in 3s..."
          sleep 3
        fi
      done
      rm -f "$UPDATE_PROMPT_FILE"

      if [ $CLAUDE_EXIT -eq 0 ] && [ -n "$UPDATED_CONTENT" ]; then
        # Verify update looks reasonable (not truncated).
        # printf '%s\n' ensures a trailing newline so wc -l counts the last line
        # even when content has no trailing newline (wc -l counts newline characters).
        ORIGINAL_SIZE=$(printf '%s\n' "$CURRENT_CONTENT" | wc -l)
        NEW_SIZE=$(printf '%s\n' "$UPDATED_CONTENT" | wc -l)
        MIN_SIZE=$((ORIGINAL_SIZE * 80 / 100))

        if [ "$NEW_SIZE" -lt "$MIN_SIZE" ]; then
          SKIPPED_FILES+=("$doc_file (truncated output)")
          continue
        fi

        # Backup original
        cp "$doc_file" "${doc_file}.backup-$(date +%s)"

        # Apply update
        echo "$UPDATED_CONTENT" > "$doc_file"
        UPDATED_FILES+=("$doc_file")
      else
        SKIPPED_FILES+=("$doc_file (generation failed)")
      fi
    done

    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
      # Git add and commit
      git add "${UPDATED_FILES[@]}"

      COMMIT_MSG="docs: update documentation for PR #$PR_NUMBER

Auto-updated by doc assessment:
- Files: ${UPDATED_FILES[*]}
- Reason: $REASON

Related: #$PR_NUMBER"

      if git commit -m "$COMMIT_MSG" 2>/dev/null; then
        if git push 2>/dev/null; then
          echo -e "${GREEN}    Project docs: updated ${#UPDATED_FILES[@]} file(s) and pushed${NC}"
        else
          echo "    Project docs: updated ${#UPDATED_FILES[@]} file(s) (push failed — local only)"
        fi
      else
        echo "    Project docs: no changes to commit"
      fi

      # Send Slack notification
      if [ -n "${SLACK_WEBHOOK:-}" ]; then
        # sharkrite-lint disable UNQUOTED_HEREDOC - Intentional: variables must be expanded
        SLACK_MESSAGE=$(cat <<EOF
{
  "text": "📚 *Documentation Auto-Updated*",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*PR #$PR_NUMBER*: $PR_TITLE\\n\\n*Files updated:* \\\`${UPDATED_FILES[*]}\\\`\\n\\n*Reason:* $REASON\\n\\nDocumentation committed and merge proceeding."
      }
    }
  ]
}
EOF
)
        curl -X POST "$SLACK_WEBHOOK" \
          -H "Content-Type: application/json" \
          -d "$SLACK_MESSAGE" \
          --silent --output /dev/null
      fi
    else
      echo "    Project docs: 0 files updated"
    fi

    if [ ${#SKIPPED_FILES[@]} -gt 0 ]; then
      for f in "${SKIPPED_FILES[@]}"; do
        print_warning "  Skipped: $f"
      done
    fi
  fi
else
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //' || echo "Documentation is current")
  echo -e "${GREEN}    Project docs: up to date ($REASON)${NC}"
fi

echo ""
exit 0
