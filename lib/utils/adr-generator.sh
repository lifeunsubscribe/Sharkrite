#!/bin/bash
# lib/utils/adr-generator.sh
#
# Single-decision-record (ADR) generator. Extracted from
# assess-documentation.sh so callers can use this function without sourcing
# the post-merge doc-assessment script (which has top-level executable code
# that runs the whole assessment pipeline as a side effect of sourcing).
#
# Live regression that motivated this extraction:
#   bootstrap-docs.sh used to `source assess-documentation.sh` just to get
#   `generate_adr_for_ref`. That side-effectfully ran the whole post-merge
#   assessment in the bootstrap context, hit a "Cannot iterate over null"
#   jq error against a nonexistent PR, then ran into `exit 0` (which
#   terminates the sourcing parent shell). The batch runner saw exit 0
#   and falsely reported the issue as completed.
#   See: docs/architecture/behavioral-design.md → "Test stubs MUST NOT
#   live in production paths" (same class of bug: file that's both a
#   library and a script with no guard separating the two modes).
#
# Dependencies (sourced by callers, not by this file):
#   - provider-interface.sh + a loaded provider (for run_prompt_with_timeout
#     and resolve_model)
#
# Optional functions the caller may define:
#   - _mark_updated NAME      — receives the marker name on success; this
#                                module calls it via `declare -f` check so
#                                callers that don't aggregate output can
#                                skip defining it.
#   - verbose_info MESSAGE    — receives the "checking for ADR-worthy…"
#                                progress message; silent if undefined.

set -euo pipefail

# Re-source guard: skip if already loaded
if declare -f generate_adr_for_ref >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Timeout for the ADR-generation provider call. Defaults match
# assess-documentation.sh so the extraction is a pure refactor.
ADR_GENERATOR_TIMEOUT="${RITE_DOC_CLAUDE_TIMEOUT:-120}"

# generate_adr_for_ref - Generate ADR for either a PR or a commit
#
# Args:
#   $1: ref_type     - "pr" or "commit"
#   $2: ref_id       - PR number (e.g., "123") or commit SHA (e.g., "a1b2c3d")
#   $3: title        - PR title or commit message subject
#   $4: body         - PR body or full commit message
#   $5: diff         - PR diff or commit diff
#   $6: changed_files - newline-separated list of changed files
#
# Returns:
#   Path to the created ADR file on stdout (e.g.,
#   ".rite/docs/adr/003-replace-eval-with-allowlist.md") on success.
#   Empty stdout if the provider judged the change not ADR-worthy or
#   the ADR for this ref already exists.
generate_adr_for_ref() {
  local ref_type="$1"
  local ref_id="$2"
  local title="$3"
  local body="$4"
  local diff="$5"
  local changed_files="$6"
  local adr_dir="${RITE_INTERNAL_DOCS_DIR}/adr"

  mkdir -p "$adr_dir"

  # Scan existing ADRs for highest number
  local highest=0
  local adr_file num
  for adr_file in "$adr_dir"/*.md; do
    if [ -f "$adr_file" ]; then
      num=$(basename "$adr_file" | grep -oE "^[0-9]+" || echo "0")
      # Strip leading zeros to prevent bash octal interpretation (008 invalid)
      num=$((10#$num))
      if [ "$num" -gt "$highest" ]; then
        highest="$num"
      fi
    fi
  done
  local next_num=$((highest + 1))
  local next_num_padded
  next_num_padded=$(printf "%03d" "$next_num")

  # Deduplication: skip if ADR already exists for this PR or commit.
  # Metadata is written as bold markdown (**PR:** / **Commit:**).
  if [ "$ref_type" = "pr" ]; then
    if grep -rl "\*\*PR:\*\* #${ref_id}" "$adr_dir" 2>/dev/null | head -1 | grep -q .; then
      return 0
    fi
  elif [ "$ref_type" = "commit" ]; then
    if grep -rl "\*\*Commit:\*\* ${ref_id}" "$adr_dir" 2>/dev/null | head -1 | grep -q .; then
      return 0
    fi
  fi

  # Build compact file list for the Files: metadata line
  local changed_files_list
  changed_files_list=$(echo "$changed_files" | head -10 | tr '\n' ', ' | sed 's/,$//' || true)

  # Build metadata line based on ref_type
  local ref_metadata
  if [ "$ref_type" = "pr" ]; then
    ref_metadata="**PR:** #${ref_id}"
  else
    ref_metadata="**Commit:** ${ref_id}"
  fi

  # Generate ADR via provider
  local prompt_file
  prompt_file=$(mktemp)
  cat > "$prompt_file" <<ADR_EOF
Output ONLY a single ADR document in this exact format. No extra text before or after.

# ADR-${next_num_padded}: <Brief Title>

**Date:** $(date +%Y-%m-%d)
${ref_metadata}
**Files:** ${changed_files_list}
**Context:** <1-2 lines from the description and diff explaining why this change was needed>
**Decision:** <1-2 lines describing what was changed>
**Tradeoffs:** <1-2 lines on what was gained vs lost>

If this change does NOT represent a significant architectural decision (pattern change, approach substitution, tradeoff decision), output nothing.

Title: ${title}
Description:
${body}

Diff (truncated):
${diff}
ADR_EOF

  # Optional progress message — only emitted if caller defined verbose_info.
  if declare -f verbose_info >/dev/null 2>&1; then
    verbose_info "  Checking for ADR-worthy decisions..."
  fi

  local adr_output
  # doc_assessment model (sonnet): structured pattern matching, not deep
  # reasoning. Independent of RITE_REVIEW_MODEL.
  # See: docs/architecture/behavioral-design.md → "Doc assessment model".
  adr_output=$(provider_run_prompt_with_timeout \
    "$(cat "$prompt_file")" \
    "$(provider_resolve_model doc_assessment)" \
    true \
    "$ADR_GENERATOR_TIMEOUT" 2>/dev/null) || true
  rm -f "$prompt_file"

  if [ -n "$adr_output" ]; then
    # Extract brief title for filename
    local brief_title
    brief_title=$(echo "$adr_output" | head -1 | sed 's/^# ADR-[0-9]*: //' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40 || true)
    if [ -z "$brief_title" ]; then
      if [ "$ref_type" = "pr" ]; then
        brief_title="pr-${ref_id}"
      else
        brief_title="commit-${ref_id:0:7}"
      fi
    fi

    local out_path="${adr_dir}/${next_num_padded}-${brief_title}.md"
    echo "$adr_output" > "$out_path"

    # Optional marker notification — only emitted if caller defined
    # _mark_updated. Lets the post-merge doc-assessment aggregate the
    # generated ADR into its summary; bootstrap-docs doesn't aggregate.
    if declare -f _mark_updated >/dev/null 2>&1; then
      _mark_updated "ADR-${next_num_padded}"
    fi

    echo "$out_path"
  fi
}
