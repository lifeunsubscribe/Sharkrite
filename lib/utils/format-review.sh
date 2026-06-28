#!/bin/bash
# lib/utils/format-review.sh
# Pretty-print a Sharkrite PR review for terminal display.
# Usage: format-review.sh <review_file>
#
# Renders a clean, colorized terminal view of a review comment body:
#   - a summary banner (findings counts + verdict) read from the authoritative
#     review-data JSON block via jq, falling back to the markdown Findings line
#     when the JSON is absent
#   - severity-grouped findings rendered from the markdown body, with fenced
#     code/fix blocks PRESERVED (indented + dimmed)
#
# It strips the review marker line, the model's pre-review preamble, all
# HTML-comment markers (including <!-- item:N --> delimiters), and the trailing
# JSON data block — none of which belong on screen.

# Re-source guard: skip if already loaded (idempotent sourcing)
if [ "${_RITE_FORMAT_REVIEW_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_FORMAT_REVIEW_LOADED=true

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"
fi

set -euo pipefail

# Reuse the shared color palette and the canonical marker constants (never
# hardcode marker strings — see lib/utils/markers.sh).
source "$RITE_LIB_DIR/utils/colors.sh"
source "$RITE_LIB_DIR/utils/markers.sh"

# ---------------------------------------------------------------------------
# _fr_render_banner: print the summary banner from the embedded JSON block.
# Arg 1: the raw JSON (contents of the review-data block, markers stripped).
# Returns 0 if a banner was rendered, 1 if the JSON is missing/unparseable
# (caller then falls back to the markdown Findings line).
# ---------------------------------------------------------------------------
_fr_render_banner() {
  local json="$1"
  [ -n "$json" ] || return 1
  echo "$json" | jq -e '.summary' >/dev/null 2>&1 || return 1

  local crit high med low verdict files vcolor vlabel
  crit=$(echo "$json" | jq -r '.summary.critical // 0')
  high=$(echo "$json" | jq -r '.summary.high // 0')
  med=$(echo "$json" | jq -r '.summary.medium // 0')
  low=$(echo "$json" | jq -r '.summary.low // 0')
  verdict=$(echo "$json" | jq -r '.summary.verdict // ""')
  files=$(echo "$json" | jq -r '.metadata.files_analyzed // empty')

  [ -n "$files" ] && printf '%bFiles analyzed:%b %s\n' "$BOLD" "$NC" "$files"
  printf '%bFindings:%b  %bCRITICAL: %s%b  |  %bHIGH: %s%b  |  %bMEDIUM: %s%b  |  %bLOW: %s%b\n' \
    "$BOLD" "$NC" \
    "$RED" "$crit" "$NC" \
    "$YELLOW" "$high" "$NC" \
    "$CYAN" "$med" "$NC" \
    "$DIM" "$low" "$NC"

  case "$verdict" in
    BLOCK_MERGE)           vcolor="$RED";    vlabel="🚫 BLOCK MERGE" ;;
    NEEDS_WORK)            vcolor="$YELLOW"; vlabel="⚠️  NEEDS WORK" ;;
    APPROVE_WITH_COMMENTS) vcolor="$CYAN";   vlabel="💬 APPROVE WITH COMMENTS" ;;
    APPROVED)              vcolor="$GREEN";  vlabel="✅ APPROVED" ;;
    *)                     vcolor="$NC";     vlabel="$verdict" ;;
  esac
  [ -n "$verdict" ] && printf '%bVerdict:%b  %b%s%b\n' "$BOLD" "$NC" "$vcolor" "$vlabel" "$NC"
  return 0
}

# ---------------------------------------------------------------------------
# _fr_render_body: render the markdown body (read on stdin).
# The caller has already removed the preamble (everything before the first
# `## ` heading), the `## ` title line itself, and the trailing JSON block.
# ---------------------------------------------------------------------------
_fr_render_body() {
  local in_code=false prev_blank=true seen=false line clean payload color hdr nl
  while IFS= read -r line || [ -n "$line" ]; do
    # Code-fence toggle — preserve everything between fences verbatim.
    if [[ "$line" =~ ^[[:space:]]*'```' ]]; then
      if [ "$in_code" = false ]; then in_code=true; else in_code=false; fi
      prev_blank=false
      continue
    fi
    if [ "$in_code" = true ]; then
      # %s keeps backslashes (regexes, escapes) intact; only the color is %b.
      printf '    %b%s%b\n' "$DIM" "$line" "$NC"
      prev_blank=false
      continue
    fi

    # Drop HTML-comment lines (review marker, <!-- item:N --> delimiters, etc.).
    [[ "$line" =~ ^[[:space:]]*'<!--' ]] && continue
    # Drop horizontal rules.
    [[ "$line" =~ ^[[:space:]]*-{3,}[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*={3,}[[:space:]]*$ ]] && continue

    # Leading newline before a header — suppressed for the very first block so
    # the body sits snug under the banner.
    nl=$'\n'
    [ "$seen" = false ] && nl=""

    # Item title: #### N. Title
    if [[ "$line" =~ ^####[[:space:]]+(.+)$ ]]; then
      payload=$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/\*\*//g; s/`//g' || true)
      printf '%s%b%s%b\n' "$nl" "$BOLD" "$payload" "$NC"
      prev_blank=false; seen=true
      continue
    fi

    # Severity / section header: ### <emoji> CRITICAL Issues, ### What Looks Good …
    if [[ "$line" =~ ^###[[:space:]]+(.+)$ ]]; then
      hdr=$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/\*\*//g' || true)
      case "$hdr" in
        *CRITICAL*|*Critical*) color="$RED" ;;
        *HIGH*|*High*)         color="$YELLOW" ;;
        *MEDIUM*|*Medium*)     color="$CYAN" ;;
        *LOW*|*Low*)           color="$DIM" ;;
        *Good*|*LGTM*)         color="$GREEN" ;;
        *)                     color="$BLUE" ;;
      esac
      printf '%s%b%s%b\n' "$nl" "${BOLD}${color}" "$hdr" "$NC"
      prev_blank=false; seen=true
      continue
    fi

    # Any other heading level (e.g. a stray ## ) — drop the marker, keep text.
    if [[ "$line" =~ ^#+[[:space:]]+(.+)$ ]]; then
      payload=$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/\*\*//g; s/`//g' || true)
      printf '%b%s%b\n' "$BOLD" "$payload" "$NC"
      prev_blank=false; seen=true
      continue
    fi

    # Collapse runs of blank lines to one.
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      [ "$prev_blank" = true ] && continue
      prev_blank=true
      echo ""
      continue
    fi
    prev_blank=false

    # Strip markdown emphasis + inline code backticks from prose.
    clean=$(printf '%s' "$line" | sed -E 's/\*\*//g; s/__//g; s/`//g' || true)

    # Skip the counts lines — the JSON banner already shows them.
    case "$clean" in
      "Files Analyzed:"*|"Findings:"*) continue ;;
    esac

    # Bullets / checklist items.
    if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.+)$ ]]; then
      payload=$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/\*\*//g; s/__//g; s/`//g; s/^\[[ xX]\][[:space:]]*//' || true)
      printf '  • %s\n' "$payload"
      seen=true
      continue
    fi

    # Known field labels get a color accent; everything else is plain prose.
    case "$clean" in
      File:*|Category:*|Problem:*|Impact:*|Fix:*|Code:*|Recommendation:*|"Next Steps:"*|Verdict:*)
        printf '%b%s%b\n' "$CYAN" "$clean" "$NC" ;;
      *)
        printf '%s\n' "$clean" ;;
    esac
    seen=true
  done
}

# ---------------------------------------------------------------------------
# _fr_fallback_clean: last-resort renderer for a review with no `## ` heading
# (malformed / pre-template). Strips the JSON block and all HTML-comment lines
# so raw markers never reach the screen; prints everything else verbatim.
# ---------------------------------------------------------------------------
_fr_fallback_clean() {
  local file="$1"
  awk -v marker="<!-- $RITE_MARKER_REVIEW_DATA" '
    index($0, marker) == 1 { injson = 1 }
    injson { if ($0 ~ /-->/) injson = 0; next }
    /^[[:space:]]*<!--/ { next }
    { print }
  ' "$file"
}

# Run main logic only when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  REVIEW_FILE="${1:-}"
  if [ ! -f "${REVIEW_FILE:-}" ]; then
    echo "Error: Review file not found: ${REVIEW_FILE:-}" >&2
    exit 1
  fi

  # 1. Summary banner from the authoritative JSON block (markers stripped via
  #    1d;$d, matching the extraction idiom in local-review.sh). Fall back to the
  #    markdown Findings line when no parseable JSON is present.
  _JSON_BLOCK=$(sed -n "/<!-- ${RITE_MARKER_REVIEW_DATA}/,/-->/p" "$REVIEW_FILE" | sed '1d;$d' || true)
  if ! _fr_render_banner "$_JSON_BLOCK"; then
    _FINDINGS=$(grep -m1 -E "Findings:.*CRITICAL" "$REVIEW_FILE" | sed -E 's/\*\*//g' || true)
    [ -n "$_FINDINGS" ] && printf '%b%s%b\n' "$BOLD" "$_FINDINGS" "$NC"
  fi
  echo ""

  # 2. Body: lines after the first `## ` heading and before the JSON block.
  #    Everything before the heading (model preamble + review marker) is dropped.
  _BODY=$(awk -v marker="<!-- $RITE_MARKER_REVIEW_DATA" '
    index($0, marker) == 1 { exit }
    !started && /^## / { started = 1; next }
    started { print }
  ' "$REVIEW_FILE" || true)

  if [ -z "$_BODY" ]; then
    _fr_fallback_clean "$REVIEW_FILE"
  else
    printf '%s\n' "$_BODY" | _fr_render_body
  fi
fi
