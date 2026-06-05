#!/bin/bash
# lib/core/plan-issues.sh - Generate GitHub issues from architectural docs
#
# Usage (called by bin/rite):
#   plan_issues [doc_path] [user_instructions]
#   plan_issues --preview [doc_path] [user_instructions]
#
# Reads an architectural doc (or project default), generates well-structured
# GitHub issues using Claude + the issue runbook, and creates them after
# interactive approval.
#
# Config:
#   RITE_PLAN_DOCS — space-separated default doc paths (relative to project root)
#   RITE_PLAN_MAX_ESTIMATE — max time estimate before requiring decomposition (default: 2hr)

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f plan_issues >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source colors if not already loaded
if ! declare -f print_info &>/dev/null; then
  if [ -n "${RITE_LIB_DIR:-}" ]; then
    source "$RITE_LIB_DIR/utils/colors.sh"
  fi
fi

# Source portable command wrappers (sed -i — BSD/GNU compat)
if [ -n "${RITE_LIB_DIR:-}" ]; then
  source "$RITE_LIB_DIR/utils/portable-cmds.sh"
fi

# Source provider abstraction
if [ -n "${RITE_LIB_DIR:-}" ]; then
  source "$RITE_LIB_DIR/providers/provider-interface.sh"
  load_provider "${RITE_REVIEW_PROVIDER:-claude}"
fi

# Source gh retry wrapper if not already loaded
if [ -n "${RITE_LIB_DIR:-}" ] && ! declare -f gh_safe >/dev/null 2>&1; then
  source "$RITE_LIB_DIR/utils/gh-retry.sh"
fi

# =============================================================================
# _collect_auto_docs: auto-discover docs/**/*.md, ADRs, and README.md
#
# Appends grounding context to the plan prompt beyond user-supplied doc paths.
# Priority order:
#   1. ADRs: docs/**/*adr*.md + docs/ADR-*.md (loaded in full, highest priority)
#   2. README.md at project root (loaded in full)
#   3. Remaining docs/**/*.md (loaded alphabetically until byte cap is reached)
#
# The byte cap (RITE_PLAN_DOC_BYTE_CAP) applies to the total auto-injected
# content.  ADRs + README count first; remaining budget goes to other docs.
# Set RITE_PLAN_DOC_BYTE_CAP=0 to disable auto-discovery entirely.
#
# Output format matches the existing doc_content loop:
#   --- <basename> ---
#   <content>
#   --- end <basename> ---
#
# Usage: _collect_auto_docs [already-loaded-paths...]
#   Already-loaded paths are skipped to avoid double-injection.
# =============================================================================

_collect_auto_docs() {
  local byte_cap="${RITE_PLAN_DOC_BYTE_CAP:-50000}"
  local project_root="${RITE_PROJECT_ROOT:-.}"

  # Validate that byte_cap is a non-negative integer.  A non-numeric value
  # (e.g. "50kb") silently passes the -eq guard above but explodes at the
  # arithmetic expansion on line "remaining_budget=$((byte_cap - total_bytes))"
  # under set -euo pipefail.  Warn and reset to the built-in default.
  case "$byte_cap" in
    ''|*[!0-9]*)
      print_info "Auto-docs: RITE_PLAN_DOC_BYTE_CAP='$byte_cap' is not a valid integer — using default 50000" >&2
      byte_cap=50000
      ;;
  esac

  # Escape hatch: cap=0 disables auto-discovery entirely.
  if [ "$byte_cap" -eq 0 ]; then
    return 0
  fi

  # Build a set of already-loaded paths (passed as arguments) so we don't
  # double-inject docs the user explicitly provided.
  local -a loaded_paths=("$@")

  _is_already_loaded() {
    local candidate="$1"
    local p
    for p in "${loaded_paths[@]+"${loaded_paths[@]}"}"; do
      if [ "$p" = "$candidate" ]; then
        return 0
      fi
    done
    return 1
  }

  local total_bytes=0
  local auto_content=""

  # -------------------------------------------------------------------------
  # Phase 1: ADRs — load in full (highest priority, count toward cap first)
  # Matches: docs/**/*adr*.md (case-insensitive) and docs/ADR-*.md
  # -------------------------------------------------------------------------
  local -a adr_files=()
  local _f
  # Case-insensitive glob via find-style iteration with while-read (bash 3.2 safe).
  # We use a while-read loop over a glob expansion to stay portable.
  while IFS= read -r _f; do
    adr_files+=("$_f")
  done < <(
    # Find all .md files under docs/ that match ADR patterns (sort alphabetically)
    {
      # Pattern 1: docs/**/*adr*.md (any casing)
      find "$project_root/docs" -name "*[Aa][Dd][Rr]*.md" -type f 2>/dev/null | sort -u
      # Pattern 2: docs/ADR-*.md (already covered by the above but explicit for clarity)
      find "$project_root/docs" -name "ADR-*.md" -type f 2>/dev/null | sort -u
    } | sort -u
  )

  local adr_path
  for adr_path in "${adr_files[@]+"${adr_files[@]}"}"; do
    _is_already_loaded "$adr_path" && continue
    local adr_bytes
    adr_bytes=$(wc -c < "$adr_path" 2>/dev/null || echo 0)
    local adr_basename
    adr_basename=$(basename "$adr_path")
    # ADRs are always loaded in full regardless of remaining budget.
    # They count toward the cap — if the cap is already exceeded they still load.
    auto_content+="
--- $adr_basename ---
$(cat "$adr_path")
--- end $adr_basename ---

"
    total_bytes=$((total_bytes + adr_bytes))
    loaded_paths+=("$adr_path")
  done

  # -------------------------------------------------------------------------
  # Phase 2: README.md — load in full (high priority, counts toward cap)
  # -------------------------------------------------------------------------
  local readme_path="$project_root/README.md"
  if [ -f "$readme_path" ] && ! _is_already_loaded "$readme_path"; then
    local readme_bytes
    readme_bytes=$(wc -c < "$readme_path" 2>/dev/null || echo 0)
    auto_content+="
--- README.md ---
$(cat "$readme_path")
--- end README.md ---

"
    total_bytes=$((total_bytes + readme_bytes))
    loaded_paths+=("$readme_path")
  fi

  # -------------------------------------------------------------------------
  # Phase 3: Remaining docs/**/*.md — alphabetically, up to remaining budget
  # -------------------------------------------------------------------------
  local remaining_budget=$((byte_cap - total_bytes))

  # Warn prominently when ADRs + README have already consumed the entire budget.
  # Without this, every remaining doc is silently skipped with only a per-file
  # "skipping" message, making it non-obvious that grounding quality is degraded.
  if [ "$remaining_budget" -le 0 ] && [ -d "$project_root/docs" ]; then
    print_info "Auto-docs: ADRs + README consumed ${total_bytes}B which meets or exceeds the ${byte_cap}B cap — remaining docs/**/*.md will not be injected. Set RITE_PLAN_DOC_BYTE_CAP to a higher value to include them." >&2
  fi

  if [ -d "$project_root/docs" ]; then
    local -a other_docs=()
    while IFS= read -r _f; do
      other_docs+=("$_f")
    done < <(find "$project_root/docs" -name "*.md" -type f 2>/dev/null | sort)

    local doc_path
    for doc_path in "${other_docs[@]+"${other_docs[@]}"}"; do
      _is_already_loaded "$doc_path" && continue
      [ -f "$doc_path" ] || continue

      local doc_bytes
      doc_bytes=$(wc -c < "$doc_path" 2>/dev/null || echo 0)
      local doc_basename
      doc_basename=$(basename "$doc_path")

      if [ "$remaining_budget" -gt 0 ] && [ "$doc_bytes" -le "$remaining_budget" ]; then
        auto_content+="
--- $doc_basename ---
$(cat "$doc_path")
--- end $doc_basename ---

"
        remaining_budget=$((remaining_budget - doc_bytes))
        total_bytes=$((total_bytes + doc_bytes))
        loaded_paths+=("$doc_path")
      else
        # Doc exceeds remaining budget (or budget is already exhausted) — log and skip.
        print_info "Auto-docs: skipping $doc_basename (${doc_bytes}B > ${remaining_budget}B remaining budget)" >&2
      fi
    done
  fi

  if [ -n "$auto_content" ]; then
    print_info "Auto-docs: injected ~${total_bytes}B of grounding docs (cap: ${byte_cap}B)" >&2
  fi

  printf '%s' "$auto_content"
}

# =============================================================================
# MAIN: plan_issues
# =============================================================================

plan_issues() {
  local preview_only=false
  local doc_paths=()
  local user_instructions=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preview)
        preview_only=true
        shift
        ;;
      *)
        # First non-flag args that look like file paths go to doc_paths.
        # Everything else is user instructions (natural language).
        if [ -f "$RITE_PROJECT_ROOT/$1" ] || [ -f "$1" ]; then
          # Resolve to project-relative path
          if [ -f "$RITE_PROJECT_ROOT/$1" ]; then
            doc_paths+=("$RITE_PROJECT_ROOT/$1")
          else
            doc_paths+=("$1")
          fi
        else
          # Accumulate as natural language instructions
          if [ -n "$user_instructions" ]; then
            user_instructions="$user_instructions $1"
          else
            user_instructions="$1"
          fi
        fi
        shift
        ;;
    esac
  done

  # Fall back to config default docs if none specified
  if [ ${#doc_paths[@]} -eq 0 ]; then
    local default_docs="${RITE_PLAN_DOCS:-}"
    if [ -n "$default_docs" ]; then
      for doc in $default_docs; do
        local resolved=""
        if [ -f "$RITE_PROJECT_ROOT/$doc" ]; then
          resolved="$RITE_PROJECT_ROOT/$doc"
        elif [ -f "$doc" ]; then
          resolved="$doc"
        fi
        if [ -n "$resolved" ]; then
          doc_paths+=("$resolved")
        else
          print_warning "Default doc not found: $doc"
        fi
      done
    fi
  fi

  if [ ${#doc_paths[@]} -eq 0 ] && [ -z "$user_instructions" ]; then
    print_error "No architectural doc specified and no RITE_PLAN_DOCS configured"
    echo ""
    echo "Usage:"
    echo "  rite plan docs/architecture/phases.md"
    echo "  rite plan \"phases 2-4 except auth\""
    echo ""
    echo "Or set a default in .rite/config:"
    echo "  RITE_PLAN_DOCS=\"docs/architecture/phases.md docs/roadmap.md\""
    exit 1
  fi

  # Check provider CLI
  provider_detect_cli || exit 1

  # Load context files
  local doc_content=""
  for doc in "${doc_paths[@]}"; do
    local doc_basename
    doc_basename=$(basename "$doc")
    doc_content+="
--- $doc_basename ---
$(cat "$doc")
--- end $doc_basename ---

"
  done

  # Auto-discover additional grounding docs (ADRs, README, docs/**/*.md).
  # This runs regardless of whether user supplied explicit doc_paths — the
  # user-supplied paths are passed so auto-discovery skips them (no double-injection).
  # RITE_PLAN_DOC_BYTE_CAP=0 disables auto-discovery; explicit paths still load.
  local auto_docs
  auto_docs=$(_collect_auto_docs "${doc_paths[@]+"${doc_paths[@]}"}")
  if [ -n "$auto_docs" ]; then
    doc_content+="$auto_docs"
  fi

  # Load project CLAUDE.md (first 150 lines for context)
  local project_context=""
  if [ -f "$RITE_PROJECT_ROOT/CLAUDE.md" ]; then
    project_context=$(head -150 "$RITE_PROJECT_ROOT/CLAUDE.md")
  fi

  # Load issue runbook (project override or built-in)
  local runbook_content=""
  if [ -f "$RITE_PROJECT_ROOT/$RITE_DATA_DIR/issue-runbook.md" ]; then
    runbook_content=$(cat "$RITE_PROJECT_ROOT/$RITE_DATA_DIR/issue-runbook.md")
  elif [ -f "$RITE_INSTALL_DIR/docs/issue-runbook.md" ]; then
    runbook_content=$(cat "$RITE_INSTALL_DIR/docs/issue-runbook.md")
  fi

  # Load existing open issues to avoid duplicates and link dependencies
  local existing_issues=""
  existing_issues=$(gh_safe issue list --state open --limit 50 --json number,title,labels \
    --jq '.[] | "#\(.number) \(.title) [\([.labels[].name] | join(", "))]"' || true)
  existing_issues="${existing_issues:-}"

  # Detect repo's existing labels for accurate label suggestions
  local repo_labels=""
  repo_labels=$(gh_safe label list --limit 100 --json name --jq '.[].name' | tr '\n' ', ' || true)
  repo_labels="${repo_labels:-}"

  # Load previous deferrals for continuity across planning sessions
  local deferrals_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/deferrals.log"
  local previous_deferrals=""
  if [ -f "$deferrals_file" ]; then
    previous_deferrals=$(cat "$deferrals_file")
  fi

  # Load previous plan feedback (corrections from last approved session)
  local plan_feedback_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/plan-feedback.md"
  local accumulated_feedback=""
  if [ -f "$plan_feedback_file" ]; then
    accumulated_feedback=$(cat "$plan_feedback_file")
    print_info "Loaded corrections from previous session"
  fi

  local max_estimate="${RITE_PLAN_MAX_ESTIMATE:-2hr}"

  print_header "Issue Planner"

  if [ ${#doc_paths[@]} -gt 0 ]; then
    for doc in "${doc_paths[@]}"; do
      print_info "Source: $(basename "$doc")"
    done
  fi
  if [ -n "$user_instructions" ]; then
    print_info "Instructions: $user_instructions"
  fi
  if [ "$preview_only" = true ]; then
    print_info "Preview mode — no issues will be created"
  fi

  # Generate issues with Claude
  # Use || true to prevent set -e from killing the script when generate_issues
  # returns non-zero (e.g. provenance lint gate fired). The guard below detects
  # both empty output and a missing/deleted temp file.
  local issues_file
  issues_file=$(generate_issues "$doc_content" "$project_context" \
    "$runbook_content" "$existing_issues" "$repo_labels" "$user_instructions" "$max_estimate" \
    "$accumulated_feedback" "$previous_deferrals" "") || true

  if [ -z "$issues_file" ] || [ ! -f "$issues_file" ]; then
    print_error "Issue generation failed"
    exit 1
  fi

  # Interactive loop
  while true; do
    display_issues "$issues_file"

    if [ "$preview_only" = true ]; then
      echo ""
      _save_deferrals "$issues_file" "$deferrals_file"
      print_info "Preview complete — run without --preview to create issues"
      rm -f "$issues_file"
      exit 0
    fi

    echo ""
    read -p "Create these issues? (y)es / (n)o / (f)eedback: " -r RESPONSE

    case "$RESPONSE" in
      [Yy]|[Yy]es)
        create_issues "$issues_file"
        _save_deferrals "$issues_file" "$deferrals_file"
        # Persist accumulated feedback so next session starts with corrections
        if [ -n "${accumulated_feedback:-}" ]; then
          _save_plan_feedback "$accumulated_feedback" "$RITE_PROJECT_ROOT/$RITE_DATA_DIR/plan-feedback.md"
        fi
        rm -f "$issues_file"
        exit 0
        ;;
      [Nn]|[Nn]o)
        print_info "Cancelled — no issues created"
        rm -f "$issues_file"
        exit 0
        ;;
      *)
        # Anything else is treated as feedback
        local feedback="$RESPONSE"

        # If the response was just "f" or "feedback", prompt for the actual feedback
        if [[ "$RESPONSE" =~ ^[Ff](eedback)?$ ]]; then
          echo ""
          echo "What changes do you want? (press Enter twice when done)"
          echo ""
          feedback=""
          local empty_count=0
          while IFS= read -r line; do
            if [ -z "$line" ]; then
              empty_count=$((empty_count + 1))
              [ "$empty_count" -ge 2 ] && break
              feedback+=$'\n'
            else
              empty_count=0
              feedback+="$line"$'\n'
            fi
          done
        fi

        if [ -z "$feedback" ]; then
          print_warning "No feedback provided, showing issues again"
          continue
        fi

        # Accumulate feedback across iterations so corrections don't get lost
        if [ -n "${accumulated_feedback:-}" ]; then
          accumulated_feedback="${accumulated_feedback}

---
${feedback}"
        else
          accumulated_feedback="$feedback"
        fi

        # Extract deferral-like statements from feedback and persist them.
        # This ensures "defer X to phase Y" survives across sessions even if
        # Claude ignores the feedback or the user abandons without approving.
        _persist_feedback_deferrals "$feedback" "$deferrals_file"

        # Capture coverage checklist from prior iteration before deleting the file.
        # This carries forward codebase state findings (what already exists vs needs creation)
        # so Claude doesn't re-scope pre-existing artifacts during the feedback pass.
        local prior_coverage=""
        prior_coverage=$(sed '/^---ISSUE---$/q' "$issues_file" | grep -v "^---ISSUE---$" || true)

        print_status "Regenerating with your feedback..."
        rm -f "$issues_file"
        issues_file=$(generate_issues "$doc_content" "$project_context" \
          "$runbook_content" "$existing_issues" "$repo_labels" "$user_instructions" "$max_estimate" \
          "$accumulated_feedback" "$previous_deferrals" "$prior_coverage")

        if [ -z "$issues_file" ] || [ ! -f "$issues_file" ]; then
          print_error "Regeneration failed"
          exit 1
        fi
        ;;
    esac
  done
}

# =============================================================================
# Generate issues using Claude
# =============================================================================

generate_issues() {
  local doc_content="$1"
  local project_context="$2"
  local runbook_content="$3"
  local existing_issues="$4"
  local repo_labels="$5"
  local user_instructions="$6"
  local max_estimate="$7"
  local feedback="${8:-}"
  local previous_deferrals="${9:-}"
  local prior_coverage="${10:-}"

  local temp_file
  temp_file=$(mktemp)

  print_status "Generating issue definitions with Claude..." >&2

  local prompt
  # sharkrite-lint disable UNQUOTED_HEREDOC - Intentional: variables must be expanded
  prompt=$(cat <<PROMPT_EOF
You are generating GitHub issues for a software project, following the Sharkrite issue runbook.

**OUTPUT CONSTRAINT:** You will output the coverage checklist exactly once, then each issue exactly once. After the final ---END--- marker, you MUST stop generating. Do not review, summarize, or regenerate any issues. Any issue title that appears more than once is a waste of tokens. This constraint is non-negotiable.

**Project Context (from CLAUDE.md):**
${project_context:-No project CLAUDE.md found — infer conventions from the architectural doc.}

**Architectural Document(s) to plan from (including auto-discovered ADRs and grounding docs):**
${doc_content:-No document provided — generate issues based on the user instructions below.}

**RECONCILE TODOS AGAINST DESIGN DOCS:** The documents above are authoritative. **Reconcile every TODO comment in code against the design constraints documented above. Any constraint that appears only in docs (not carried by TODOs) must surface as its own issue or as an explicit WARNING flag in the coverage checklist.** Do not let an ADR-documented constraint go unaddressed because no TODO mentions it.

**Issue Runbook (quality standard — follow this precisely):**
${runbook_content:-Use standard issue structure: Title, Labels, Time, Description, Claude Context, Acceptance Criteria, Verification Commands, Done Definition, Scope Boundary, Dependencies.}

**Existing open issues (avoid duplicates, link dependencies where relevant):**
${existing_issues:-No open issues found.}

**Existing repo labels (use these exact names when they fit):**
${repo_labels:-No labels found — suggest reasonable defaults.}

$(if [ -n "$user_instructions" ]; then
echo "**User instructions (interpret naturally — filter, scope, or adjust based on this):**"
echo "$user_instructions"
echo ""
fi)

$(if [ -n "$feedback" ]; then
echo "**User feedback on previous generation (incorporate these changes):**"
echo "$feedback"
echo ""
fi)

$(if [ -n "$previous_deferrals" ]; then
echo "**Previously deferred items (from earlier planning sessions — pick up items that are now in scope, re-defer items that aren't):**"
echo "$previous_deferrals"
echo ""
fi)

$(if [ -n "$prior_coverage" ]; then
echo "**Prior iteration coverage checklist (carry this forward — codebase state does not change between iterations):**"
echo "This is the coverage analysis from the previous generation. Use it to:"
echo "- Retain codebase state findings (what already exists vs. needs to be created)"
echo "- Identify any ADR features that were covered before but are now missing — those are regressions, not deliberate removals"
echo "- Carry forward 'pre-existing' vs. 'needs creation' classifications for all models, schemas, and migrations"
echo ""
echo "$prior_coverage"
echo ""
fi)

**Step 1 — Sub-feature Inventory and Coverage Analysis (do this FIRST, before generating issues):**

**Part A — Sub-feature decomposition:**
Before deciding on issue structure, extract all distinct implementable units from the spec section(s):
- Every data entity, including join tables with their own fields (a join table with application-level fields is a sub-entity, not just a foreign key)
- Every endpoint or CRUD operation — CRUD on a related entity is never automatically bundled with the parent entity's issue
- Every query pattern that differs in complexity from basic CRUD: filters that span join tables, aggregate queries, cross-domain lookups, user-profile-dependent queries
- Every cross-domain feature (touches 2+ modules/domains — flag it with [CROSS-DOMAIN])
- Every multi-user data pattern where data has both per-user ownership AND aggregate/shared visibility (e.g., ratings, likes, follows — flag it with [MULTI-USER])

For each flagged item, explicitly decide: own issue or bundled? If bundled, state which issue absorbs it and confirm that issue's scope boundary mentions it.

**Part B — Coverage checklist:**
For each feature, entity, endpoint, or requirement in the relevant section(s):
1. Confirm it will be covered by an issue you're about to generate, OR
2. Mark it as explicitly deferred with the target phase/issue where it belongs

If "Previously deferred items" were provided above, check each one:
- If it's now in scope for this planning session, mark it ✅ PICKED UP and generate an issue for it
- If it's still out of scope, re-defer it with ⏭️ (it will be carried forward automatically)

After your analysis, output the coverage checklist:
\`\`\`
COVERAGE:
- ✅ Feature X → Issue "Title Y"
- ✅ Entity Z (join table with own fields) → Issue "Title W" [own issue — relationship complexity]
- ✅ [CROSS-DOMAIN] Ad-hoc creation flow → Issue "Title V" [own issue — touches inventory + recipes]
- ✅ [MULTI-USER] Ratings CRUD → Issue "Title U" (per-user) + Issue "Title T" (aggregate query)
- ✅ PICKED UP: Previously deferred item → Issue "Title Z"
- ⏭️ Feature Q → Deferred to Phase N (reason: depends on entity from Phase M)
- ⏭️ UI for feature X → Deferred to Phase F (backend-first strategy across phases 1C-1G)
\`\`\`

This ensures nothing is silently dropped. If the doc mentions an entity, endpoint, data model, or user flow, it must appear in either an issue or a deferral note. **Deferrals MUST include a target phase — a bare "separate issue" with no target is not acceptable.**

**Step 2 — Issue Generation Rules:**
- Generate well-structured issues following the runbook template exactly (no fixed min/max — generate as many as the spec requires)
- Time estimates use Fibonacci scale: 15min, 30min, 45min, 1hr, 2hr
- Any issue that would take >$max_estimate MUST be split into smaller issues
- Dependencies must reflect actual code dependencies, not issue ordering. Use \`#PREV\` ONLY when an issue genuinely depends on the immediately preceding issue's code. Use \`After #N\` to reference any specific issue. Use \`After #N (can run in parallel with #M)\` when multiple issues share a common dependency but not each other
- First issue should have \`Dependencies: None\`
- Prefer parallel-friendly ordering: infrastructure → data models → then group parallelizable issues together (e.g., independent endpoints that all depend on the same CRUD base)
- Include specific, real file paths from the project (based on context)
- **"Files to Read" must only list files that currently exist.** If a file is created by a dependency issue, do not list it there — reference the dependency issue in "Related Issues" instead
- Acceptance criteria must have verification commands
- Done definitions must be concrete and bounded (no "when it works" or "when it's clean")
- Scope boundaries must have explicit DO / DO NOT
- If user instructions mention specific sections/phases, ONLY generate issues for those
- If user instructions exclude something, skip it entirely

**Issue sizing guidance:**
- If two issues share the same file, router, or schema AND together total ≤2hr, consider merging them into one issue. Separate PRs for 20 lines of code in the same file add overhead without value.
- If an issue contains both a trivial part (e.g., GET endpoint) and a non-trivial part (e.g., complex CRUD with relationships), consider splitting them. The trivial part ships fast; the complex part gets proper scope.
- When a field references an entity/table that doesn't exist yet, state the interim approach explicitly (e.g., "store as JSON array for now, formalize FK relationship in Phase X").
- **Cross-domain complexity**: If a feature touches 2+ distinct modules/domains (e.g., both inventory and recipes), give it its own issue with explicit scope boundaries for which domain(s) it modifies. Do not bury it inside the simpler CRUD issue for one of those domains.
- **Multi-user data entities** [MULTI-USER]: If an entity has per-user ownership AND aggregate/shared visibility (e.g., ratings, likes, follows), the issue(s) MUST cover both: (a) per-user CRUD operations and (b) the aggregate query pattern (e.g., average rating, count). These can be one issue if ≤2hr combined, but both patterns must be explicitly called out in acceptance criteria — not left as implied.
- **Shared item operations inherit read visibility.** If an entity uses a shareability model (shared/personal/reserved) and shared items are visible to all users in read endpoints, then non-destructive operations on shared items (consume, purchase, mark-as-done) MUST also be accessible to any authenticated user — not just the owner. Only destructive operations (update, delete) should be owner-restricted. If the ADR or spec says "shared items are accessible/visible to all," that visibility extends to consume-like operations. Do NOT default consume endpoints to owner-only 404 when the read model allows shared access.
- **Complex filter patterns**: If filtering requires joining multiple tables or cross-referencing a user's profile data (e.g., "show recipes compatible with my dietary restrictions"), give it its own issue. Do not bundle complex, multi-join filters with basic list endpoints — they have different scope, test complexity, and failure modes.

**Completeness checks:**
- If the doc describes a data entity with its own fields/relationships (not just a column on an existing model), it needs its own CRUD issue or an explicit deferral.
- If the doc bundles UI/UX with API for a feature, generate both backend AND frontend issues, or add a deferral note with an explicit target phase (e.g., "frontend deferred to Phase 2"). A deferral with no target phase is a gap — treat it like a missing issue.
- If the plan creates a role/permission system, include a note about how the first privileged user gets bootstrapped (seed data, self-registration, migration, etc.).
- For each DO NOT in scope boundaries, prefer "deferred to Phase X / Issue Y" over bare "separate issue" when the phase/location is known from the doc.
- If any entity in scope has data that is both privately owned (per-user write) and shared/aggregate-visible (multi-user read), explicitly call out both the per-user CRUD and the aggregate query/display pattern — either within one issue's acceptance criteria or split into two issues.
- If the doc describes a feature as architecturally interesting or "the most complex part of this phase," bias toward giving it its own issue regardless of estimated time. Architectural novelty is a complexity signal independent of hours.

**Step 3 — Pre-Output Audit (complete every check before writing any ---ISSUE--- block):**

**A. No standalone test issue.**
Every feature issue must list its test file under "Files to Modify" and include its own test criteria in "Acceptance Criteria." If you have written or are about to write an issue whose sole purpose is "write/add tests for all endpoints" — STOP and delete it. Tests ship with the feature that implements the endpoint. There is nothing left for a test-only issue to do once every feature issue already includes its test file and criteria. If any test criteria are unique (not already in a feature issue), move them into the relevant feature issue now.

**B. Error code consistency (cross-issue audit).**
Before writing your first issue, determine: does the existing codebase use 403 or 404 for ownership/permission failures on update and delete? Apply that exact code across every issue in this batch. After drafting all issues, scan every acceptance criterion that mentions a status code. If any two issues use different codes for the same scenario (one says 403, another says 404 for "non-owner tries to modify"), fix them to match before outputting.

**C. Real dependency graph — not a linear chain.**
\`#PREV\` means "depends on the immediately preceding issue." Do NOT default to \`#PREV\` for every issue. Before writing dependencies, sketch the actual graph:
- What is the true root issue? (Usually: schemas or migrations.)
- Which issues depend ONLY on the root? They can be done in parallel — list them as "After #[root title]", not "After #PREV".
- Which issues depend on each other directly? Only those get explicit sequential references.

Correct:
\`\`\`
#1 schemas → #2 CRUD → #3 filters   (depends: #2 only, parallel with #4 and #5)
                     → #4 ingredients (depends: #2 only, parallel with #3 and #5)
                     → #5 ratings     (depends: #2 only, parallel with #3 and #4)
                     → #6 ad-hoc      (depends: #2 and #4)
\`\`\`

Incorrect:
\`\`\`
#1 → #2 → #3 → #4 → #5 → #6  (pure linear chain — almost always wrong)
\`\`\`

When an issue can run in parallel with others after a shared dependency, say so explicitly in the Dependencies field: "After #2 (can run in parallel with #3, #4)".

**Narrative dependencies are not code dependencies.** A dependency must mean "this issue literally cannot be implemented without the other issue code existing first." UX flow ordering ("completes the shopping flow") or thematic grouping ("both deal with purchasing") are NOT dependencies. If Issue B only needs the models/endpoints from Issue A to compile and run, it depends on A. If Issue B could be implemented and tested independently with only the base CRUD in place, it does not depend on anything beyond that base CRUD -- even if the user story flows A to B.

**D. Read access model explicitly stated.**
For every entity with a list endpoint (GET /entities), state in the acceptance criteria whether it returns:
- Only the current user's items (user-scoped reads), OR
- All items regardless of creator (global/shared reads)

Do not leave this implicit. If the read model for this entity differs from a related entity in the same phase, call out the difference explicitly so the implementer does not cargo-cult the wrong query filter.

**E. System-managed fields in update schemas.**
Scan each entity model for fields managed by later-phase system logic (counters like \`times_cooked\`, computed scores, auto-timestamps). For each such field, add a criterion to the schema issue: "Field X is excluded from the Update schema (system-managed — write logic deferred to Phase Y)."

**F. Deferral validity and simpler versions.**
Before deferring a feature, ask: does it actually depend on something from the later phase, or does it only touch models that already exist?

- A feature that touches two existing models (cross-domain) is NOT a reason for deferral — it is a reason for its own issue. Give it its own issue with explicit scope boundaries for which domains it modifies. "Touches multiple models" ≠ "deferred to Phase N."
- A feature is only deferrable if it depends on a model, endpoint, or system that will not exist until a later phase. If all required models already exist, it belongs in the current phase.
- **ADR-explicit features are NOT deferrable to later phases.** If the ADR doc explicitly lists a feature under the current phase (e.g., "Phase 1F includes purchase check-off with inventory auto-update"), that feature belongs in this phase -- even if a more advanced version exists in a later phase. The basic/bridge version ships now; only the advanced version (daily reconciliation, consumption tracking, etc.) defers. Misclassifying a current-phase feature as a later-phase feature is a coverage gap, not a deferral.
- For a legitimately deferred feature, ask: does a simpler version exist that requires none of the later phase dependencies? If yes, include the simpler version and defer only the full version.
- A "simpler version" of a filter means filtering by a value stored in the entity's own fields — no joins to user profiles or other entities. For example: \`?has_variation=vegan\` checks a JSON key on the recipe itself (simple, current phase). \`?dietary_compatible=true\` that compares recipe variation_groups against a user's dietary_profile JSON field is a cross-domain filter — it is NOT a simpler version; it is the full version with a user-profile join. If no simpler version genuinely exists, the deferral stands as-is — do not bundle the full version into a 1-hour filter issue.

**G. Time estimate calibration.**
Use these baselines before setting TIME fields:
- Pure schema/model work (no endpoints): 0.5–1hr
- Basic CRUD router (5 endpoints + tests): 1.5–2hr
- Filter/search extensions on existing list endpoint: 0.5–1hr
- Nested resource CRUD (e.g., /parent/{id}/children): 1.5–2hr — account for permission inheritance, relationship loading, and edge cases; do NOT estimate 1hr
- Cross-domain transactional endpoints (touches 2+ modules with atomic rollback): 2hr minimum
- Aggregate query endpoints (averages, counts, summaries): add 0.5hr to the base estimate
- Compound issues (single + bulk endpoint + conditional validation + cross-domain bridge): add 0.5hr per additional concern. An issue with purchase + unpurchase + bulk purchase + optional inventory creation + conditional field validation (required-if-flag) is 1.5-2hr, not 1hr. Count the distinct behaviors and test paths, not just the endpoint count.

**G2. Schema field defaults for phased features.**
If an enum field only has one valid value in the current phase (e.g., source can only be "manual" because all other sources are system-generated and deferred), it should default to that value in the Create schema -- not be required. Users should not be forced to pass a constant on every request. Later phases add the other enum values via system-generated code paths, not user input.

**H. Acceptance criteria deduplication.**
After drafting all issues, scan for criteria that describe the same behavior across multiple issues (e.g., "all recipe tests pass" in both a feature issue and a separate test issue). Each criterion must appear in exactly one issue.

**I. ADR coverage regression check (feedback iterations only).**
If a prior iteration coverage checklist was provided above, compare the current issue set against it. Every feature that had a ✅ entry in the prior checklist must either have a corresponding issue in the current set OR appear in the deferrals list with an explanation. A feature that was covered before and is simply absent now is a regression — not a deliberate scope change. Do not silently drop ADR bullets between iterations. If the user's feedback caused a feature to be removed, it must appear in deferrals with the note "(removed per user feedback)".

**J. Codebase state carry-forward (feedback iterations only).**
If a prior iteration identified an artifact (model, schema, migration, router) as already existing in the codebase, that finding stands — codebase state does not change between plan iterations. Do NOT re-scope a pre-existing artifact as "create from scratch" in the feedback pass. If in doubt, re-read the relevant file using your available tools before deciding. Scope pre-existing artifacts as "verify and extend," note what already exists in the description, and do not include migration work for tables that are already in the migration history.

**K. Architectural pattern compliance (CRITICAL — check this for EVERY CRUD issue).**
If the project context (CLAUDE.md) or the existing issues mention a service layer, router-to-service pattern, or service files (e.g., auth_service.py, grocery_service.py), then EVERY new CRUD issue MUST include the corresponding service file in "Files to Modify" (e.g., src/services/prepared_food_service.py). The router is a thin delegation layer; business logic goes in the service. This is a hard rule, not a suggestion. Do NOT write "DO NOT: Create service layer" in scope boundaries — if a service layer exists anywhere in the project, new domains follow the same pattern. Fat routers that exist without services are tech debt, not the convention. When the project has both patterns, always follow the service-layer pattern.

**L. Schema reuse over ceremony.**
Before defining a new response schema, check if an existing response schema already carries the same fields. A dedicated MarkPurchasedResponse that returns the same fields as ItemResponse (just with updated values) is unnecessary -- reuse the existing schema. Only create new response schemas when the shape of the returned data genuinely differs from existing schemas. State which existing schema to reuse in the acceptance criteria.

**M. Bulk operation consideration.**
For any single-item mutation endpoint (purchase, archive, delete, status change), ask: will users commonly perform this action on multiple items in quick succession? If yes (e.g., marking 10 grocery items as purchased after a shopping trip), include a bulk variant in the same issue. A bulk endpoint accepting a list of IDs with the same per-item logic is about 15 minutes of additional work and dramatically improves real-world usability. Do not defer bulk variants to separate issues when they are trivial extensions of the single-item logic.

**N. Schema ownership completeness.**
For every issue in the final set, identify each Pydantic schema, model, or artifact it assumes will exist at implementation time. Verify that each one is either:
- Already present in the codebase (confirmed by prior coverage checklist or direct file read), OR
- Explicitly created by a named earlier issue in the current set

If an issue references a schema that doesn't exist and no prior issue creates it, add the schema work to the most logical earlier issue and note it in that issue's acceptance criteria. Do not leave ownership gaps.

**O. Coverage checklist integrity (CRITICAL).**
The coverage checklist is a post-generation audit, not a pre-generation plan. Every issue title referenced in a ✅ line (e.g., \`✅ Feature X → Issue "Title Y"\`) MUST match an actual ---ISSUE--- block title in the output. After drafting all issues, scan every ✅ line in the checklist. If a checklist line references a title that does not appear in any ---ISSUE--- block, either fix the checklist to reference the correct issue title or flag the gap as a missing issue. A checklist that references phantom issues is worse than no checklist — it hides coverage gaps.

**P. Output-field provenance flagging.**
For any issue that produces or transforms structured data, scan the output fields. For each field, ask: does its source come from an external system (a third-party API, a remote service, a feed), or is it otherwise non-obvious (derived from multiple sources, computed under a non-trivial rule, etc.)?

- If **no flagged fields**: do nothing. Do not include any provenance section.
- If **any flagged field**: include a \`**Field provenance:**\` section in that issue's BODY listing ONLY the flagged fields, each with:
  - source (specific external system or derivation description), and
  - one of: \`verified-available\` (a fixture or test data path exists confirming the field is actually returned), \`UNVERIFIED\` (no fixture — field presence assumed but not confirmed), or \`derived\` (with the formula or rule).

Do not include provenance entries for fields whose source is a local file already listed in the issue's "Files to Read" section — those are obvious-source fields and a table of obvious fields will be rejected as low-signal noise. A provenance section that only documents local-file-sourced fields defeats the purpose of the section. When in doubt about whether a field source is obvious: if its origin requires no explanation beyond "it's in the input file," omit it.

**Output format (follow EXACTLY — coverage checklist first, then issues):**

First output the COVERAGE checklist (see Step 1).

Then output each issue in this format:

---ISSUE---
TITLE: [Phase N] Verb noun - specific component
LABELS: phase-N,category,priority-level
TIME: Xmin or Xhr
BODY:
**Description**:
1-2 sentences on what and why.

**Claude Context**:
Files to Read:
- path/to/file (what to look for)

Files to Modify:
- path/to/file

Related Issues: #N (if applicable)

**Acceptance Criteria**:
- [ ] Specific criterion: \`verification command\`
- [ ] Another criterion: \`test command\`
- [ ] Documentation updated (if applicable): specify which docs

**Verification Commands**:
\`\`\`bash
command to verify
\`\`\`

**Done Definition**: One concrete sentence.

**Scope Boundary**:
- DO: specific actions in scope
- DO NOT: specific actions out of scope (with deferral target when known, e.g., "Phase 2 / Issue title")

**Dependencies**: After #N / After #N (can run in parallel with #M, #P) / None
---END---

Generate the coverage checklist and all issues now. Remember: each issue exactly once, then STOP after the final ---END---.
PROMPT_EOF
)

  # Dry-run prompt dump: when RITE_PLAN_DRYRUN_DUMP_PROMPT=1 is set, emit the
  # assembled prompt to stdout and exit immediately (no provider call).
  # Used for sentinel testing: verify that auto-discovered docs appear in the prompt.
  if [ "${RITE_PLAN_DRYRUN_DUMP_PROMPT:-}" = "1" ]; then
    printf '%s\n' "$prompt"
    rm -f "$temp_file"
    echo ""
    return 0
  fi

  # Stream output to terminal (via stderr so it's visible) while capturing to file.
  # Without tee, $(...) swallows all output and the screen appears frozen.
  local attempt=0
  local max_attempts=2
  local claude_stderr
  claude_stderr=$(mktemp)

  # Log prompt size for debugging
  local prompt_lines
  prompt_lines=$(echo "$prompt" | wc -l | tr -d ' ')
  print_info "Prompt: ${prompt_lines} lines" >&2

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))

    # Use streaming prompt for real-time output visibility
    provider_run_streaming_prompt "$prompt" "" 2>"$claude_stderr" \
      | awk '
          # Truncate output on first duplicate issue (Claude sometimes regenerates the full set).
          # Buffer each ---ISSUE--- block; only emit on ---END--- if title is new.
          /^---ISSUE---$/ { in_issue = 1; buf = $0 "\n"; title = ""; next }
          in_issue {
            buf = buf $0 "\n"
            if ($0 ~ /^TITLE: /) {
              title = substr($0, 8)
              if (title in seen) { exit }
              seen[title] = 1
            }
            if ($0 == "---END---") { in_issue = 0; printf "%s", buf; buf = "" }
            next
          }
          { print }
        ' \
      | tee "$temp_file" >&2

    local exit_code=${PIPESTATUS[0]:-$?}

    # Timeout: fail immediately rather than retrying (each retry costs up to 1800s)
    if [ "$exit_code" -eq 124 ]; then
      print_warning "Provider stderr:" >&2
      cat "$claude_stderr" >&2
      print_error "Provider streaming prompt timed out (exit 124) — aborting plan-issues" >&2
      rm -f "$claude_stderr" "$temp_file"
      return 1
    fi

    # Log any Claude CLI errors
    if [ -s "$claude_stderr" ]; then
      print_warning "Provider stderr:" >&2
      cat "$claude_stderr" >&2
    fi

    if [ -s "$temp_file" ]; then
      print_info "Generated $(wc -l < "$temp_file" | tr -d ' ') lines of output" >&2
      break
    fi

    if [ $attempt -lt $max_attempts ]; then
      print_warning "Empty response from provider (exit code: $exit_code), retrying..." >&2
      sleep 3
    fi
  done

  rm -f "$claude_stderr"

  if [ ! -s "$temp_file" ]; then
    print_error "Claude returned empty response after $max_attempts attempts" >&2
    rm -f "$temp_file"
    echo ""
    return 1
  fi

  # Normalize structural markers before any parsing.
  # jq -rj (join mode) emits text chunks with no added newlines, so markers can
  # be concatenated with surrounding text: "...text---ISSUE---TITLE: ..."
  # Force markers onto their own lines, then clean up any trailing content.
  local normalized
  normalized=$(mktemp)
  sed \
    -e 's/---ISSUE---/\
---ISSUE---\
/g' \
    -e 's/---END---/\
---END---\
/g' \
    "$temp_file" > "$normalized"
  mv "$normalized" "$temp_file"

  # Detect unverified external integrations (deterministic — no LLM calls).
  # Emits WARNING lines to stderr and prepends spike-issue prerequisites for
  # any host or package referenced in issue bodies that is not grounded in the
  # repo's fixture directories or dependency manifests.
  # Must run BEFORE _dedup_issues so injected spike issues are subject to
  # deduplication on re-runs (avoids duplicate spike titles when run twice).
  _detect_unverified_integrations "$temp_file"

  # Deduplicate issues — Claude sometimes repeats the full issue set.
  # Keep only the first occurrence of each issue (by title).
  # Runs after _detect_unverified_integrations so spike issues are also deduped.
  _dedup_issues "$temp_file"

  # Validate coverage checklist integrity: every ✅ line that references
  # an issue title must match an actual ---ISSUE--- block in the output.
  _validate_coverage "$temp_file"

  # Post-generation lint: catch known anti-patterns that Claude keeps generating
  _lint_issues "$temp_file"

  # Post-generation provenance lint: catch low-signal or UNVERIFIED provenance tables
  # Capture exit code explicitly — a non-zero return (low-signal gate) must not
  # silently kill generate_issues under set -e when called via command substitution.
  _prov_lint_rc=0
  _lint_provenance_flags "$temp_file" || _prov_lint_rc=$?
  if [ "$_prov_lint_rc" -ne 0 ]; then
    # Gate fired: low-signal provenance detected. Return non-zero so the caller
    # (plan_issues) can surface the failure via its "if [ -z "$issues_file" ]" guard.
    rm -f "$temp_file"
    return "$_prov_lint_rc"
  fi

  echo "$temp_file"
}

# =============================================================================
# Lint generated issues for known anti-patterns
# =============================================================================

_lint_issues() {
  local issues_file="$1"
  local warnings=0

  # Detect if project uses service layer pattern by checking the actual filesystem.
  # This is authoritative — if service files exist on disk, the project uses services.
  # Don't rely on prompt context or generated output (circular dependency).
  _has_services=false
  _project_root="${RITE_PROJECT_ROOT:-.}"
  for _svc_dir in "$_project_root/src/services" "$_project_root/services" "$_project_root/backend/src/services" "$_project_root/app/services"; do
    if ls "$_svc_dir"/*_service.py 2>/dev/null | head -1 > /dev/null 2>&1 || \
       ls "$_svc_dir"/*Service.* 2>/dev/null | head -1 > /dev/null 2>&1; then
      _has_services=true
      break
    fi
  done

  if [ "$_has_services" = true ]; then
    # Anti-pattern 1: "DO NOT: Create service layer"
    if grep -qi "DO NOT.*service layer\|DO NOT.*create.*service" "$issues_file"; then
      print_warning "Removing 'DO NOT create service layer' scope boundaries" >&2
      portable_sed_i '/DO NOT.*[Cc]reate.*service layer/d; /DO NOT.*service.layer/d' "$issues_file"
      warnings=$((warnings + 1))
    fi

    # Anti-pattern 2: CRUD issue without service file in Files to Modify.
    # Detect CRUD issues (title contains CRUD, endpoint, or issue has router in Files to Modify)
    # and check if they list a corresponding service file.
    _lint_file=$(mktemp)
    _in_issue=false
    _issue_block=""
    _issue_title=""
    _has_router=false
    _has_service=false

    while IFS= read -r line; do
      if [[ "$line" == "---ISSUE---" ]]; then
        _in_issue=true
        _issue_block="$line"$'\n'
        _issue_title=""
        _has_router=false
        _has_service=false
        continue
      fi
      if [ "$_in_issue" = true ]; then
        _issue_block+="$line"$'\n'
        [[ "$line" =~ ^TITLE:\ (.+) ]] && _issue_title="${BASH_REMATCH[1]}"
        echo "$line" | grep -qiE "routers/.*\.py|router.*\.py" && _has_router=true
        echo "$line" | grep -qiE "services/.*\.py|service.*\.py" && _has_service=true

        if [[ "$line" == "---END---" ]]; then
          _in_issue=false
          if [ "$_has_router" = true ] && [ "$_has_service" = false ]; then
            # Extract router name to derive service name
            # Extract router name from "Files to Modify" section only (not "Files to Read"
            # which may reference other routers as patterns)
            # Stop at blank line OR next markdown section (**, ##, Related)
            _router_name=$(echo "$_issue_block" | sed -n '/Files to Modify/,/^\*\*\|^##\|^Related\|^$/p' | grep -oiE 'routers/[a-z_]+\.py' | head -1 | sed 's|routers/||; s|\.py||' || true)
            if [ -n "$_router_name" ]; then
              _service_file="src/services/${_router_name}_service.py"
              print_info "Adding $_service_file to '$_issue_title'" >&2
              # Insert service file after the router line in Files to Modify
              _issue_block=$(echo "$_issue_block" | sed "s|routers/${_router_name}.py|routers/${_router_name}.py\n- ${_service_file} (create — router delegates to service)|" || true)
              warnings=$((warnings + 1))
            fi
          fi
          printf '%s' "$_issue_block" >> "$_lint_file"
          _issue_block=""
        fi
      else
        printf '%s\n' "$line" >> "$_lint_file"
      fi
    done < "$issues_file"
    mv "$_lint_file" "$issues_file"
  fi

  if [ "$warnings" -gt 0 ]; then
    print_info "Fixed $warnings issue(s) in post-generation lint" >&2
  fi
}

# =============================================================================
# Lint provenance flags: catch low-signal or unverified field provenance entries
#
# Deterministic (no LLM calls). Reads the issues file and for each ---ISSUE---
# block that contains a "**Field provenance:**" section:
#
#   1. Extract the list of files named in "Files to Read" for that issue.
#   2. For each provenance entry, check whether the source string matches
#      a file path already listed in "Files to Read". If it does, the entry
#      is obvious-source and counts toward the low-signal threshold.
#   3. If obvious-source entry count > RITE_PLAN_PROVENANCE_MAX_OBVIOUS (default 0)
#      emit WARNING and return non-zero unless RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1.
#   4. For each provenance entry marked UNVERIFIED, emit WARNING (defense-in-depth
#      signal — not a gate; the run continues).
#
# The "Files to Read" heuristic is best-effort: a source string is considered
# obvious if any basename from "Files to Read" appears in the source string.
# =============================================================================

_lint_provenance_flags() {
  local issues_file="$1"
  local max_obvious="${RITE_PLAN_PROVENANCE_MAX_OBVIOUS:-0}"
  local allow_obvious="${RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS:-0}"

  # Validate that max_obvious is a non-negative integer.
  case "$max_obvious" in
    ''|*[!0-9]*)
      print_info "Provenance lint: RITE_PLAN_PROVENANCE_MAX_OBVIOUS='$max_obvious' is not a valid integer — using default 0" >&2
      max_obvious=0
      ;;
  esac

  local _found_low_signal=false
  local _total_unverified=0
  local _prov_lint_exit=0

  # Parse file block by block. We need to extract per-issue context so we can
  # compare provenance source strings against that issue's "Files to Read".
  # Strategy: collect each ---ISSUE--- ... ---END--- block as a unit, then
  # analyse the block in-memory (no temp files needed — blocks are small).
  local _in_issue=false
  local _issue_block=""
  local _issue_title=""

  while IFS= read -r _line; do
    if [ "$_line" = "---ISSUE---" ]; then
      _in_issue=true
      _issue_block=""
      _issue_title=""
      continue
    fi

    if [ "$_in_issue" = true ]; then
      _issue_block="${_issue_block}${_line}"$'\n'

      # Capture title for warning messages
      case "$_line" in
        TITLE:\ *)
          _issue_title="${_line#TITLE: }"
          ;;
      esac

      if [ "$_line" = "---END---" ]; then
        _in_issue=false

        # Only process issues that have a provenance section
        if ! echo "$_issue_block" | grep -qF "**Field provenance:**"; then
          _issue_block=""
          continue
        fi

        # ---------------------------------------------------------------
        # Extract "Files to Read" basenames for this issue.
        # Lines under "Files to Read:" up to the next blank line or "Files
        # to Modify:" header are file paths; take their basenames.
        # ---------------------------------------------------------------
        local _files_to_read_basenames=""
        local _in_files_to_read=false
        while IFS= read -r _fline; do
          if echo "$_fline" | grep -qF "Files to Read:"; then
            _in_files_to_read=true
            continue
          fi
          if [ "$_in_files_to_read" = true ]; then
            # Stop at blank line, "Files to Modify:", "Related Issues:", or any other header
            case "$_fline" in
              ""|"Files to Modify:"*|"Related Issues:"*|"**"*|"##"*)
                _in_files_to_read=false
                continue
                ;;
            esac
            # Extract the path (first token on bullet line, strip "- " prefix)
            _fpath=$(echo "$_fline" | sed 's/^[[:space:]]*-[[:space:]]*//' | awk '{print $1}' || true)
            if [ -n "$_fpath" ]; then
              _basename=$(basename "$_fpath" 2>/dev/null || echo "$_fpath")
              _files_to_read_basenames="${_files_to_read_basenames}${_basename}"$'\n'
            fi
          fi
        done <<< "$_issue_block"

        # ---------------------------------------------------------------
        # Extract provenance entries from the "**Field provenance:**" section.
        # Format: "- fieldname: source — verified-available|UNVERIFIED|derived"
        # We capture from the "**Field provenance:**" line to the next "**" header
        # or "---END---".
        # ---------------------------------------------------------------
        local _in_prov=false
        local _obvious_count=0

        while IFS= read -r _pline; do
          if echo "$_pline" | grep -qF "**Field provenance:**"; then
            _in_prov=true
            continue
          fi

          if [ "$_in_prov" = true ]; then
            # Stop at next markdown header or empty block boundary
            case "$_pline" in
              "**"*|"##"*|"---END---")
                _in_prov=false
                ;;
              "- "*|"  - "*)
                # This is a provenance entry line.
                # Check if UNVERIFIED
                if echo "$_pline" | grep -qF "UNVERIFIED"; then
                  _total_unverified=$((_total_unverified + 1))
                  print_warning "Provenance lint: UNVERIFIED field provenance in '${_issue_title}': ${_pline}" >&2
                fi

                # Check if source is obvious: does any filename from "Files to Read"
                # appear in the provenance entry line?
                if [ -n "$_files_to_read_basenames" ]; then
                  local _is_obvious=false
                  while IFS= read -r _bn; do
                    [ -z "$_bn" ] && continue
                    if echo "$_pline" | grep -qF "$_bn"; then
                      _is_obvious=true
                      break
                    fi
                  done <<< "$_files_to_read_basenames"

                  if [ "$_is_obvious" = true ]; then
                    _obvious_count=$((_obvious_count + 1))
                  fi
                fi
                ;;
            esac
          fi
        done <<< "$_issue_block"

        # ---------------------------------------------------------------
        # Evaluate obvious-source threshold for this issue.
        # ---------------------------------------------------------------
        if [ "$_obvious_count" -gt "$max_obvious" ]; then
          _found_low_signal=true
          print_warning "Provenance lint: low-signal provenance entries in '${_issue_title}': ${_obvious_count} obvious-source field(s) (sources named in 'Files to Read'). A table of obvious fields trains readers to skim; omit obvious-source entries. Set RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1 to suppress this check." >&2
        fi

        _issue_block=""
      fi
    fi
  done < "$issues_file"

  # Fail the run if low-signal provenance was found and allow flag is not set.
  if [ "$_found_low_signal" = true ] && [ "$allow_obvious" != "1" ]; then
    _prov_lint_exit=1
  fi

  if [ "$_total_unverified" -gt 0 ]; then
    print_info "Provenance lint: ${_total_unverified} UNVERIFIED field(s) flagged — pair with integration fixtures to confirm availability" >&2
  fi

  return "$_prov_lint_exit"
}

# =============================================================================
# Validate coverage checklist against emitted issues
# =============================================================================

_validate_coverage() {
  local issues_file="$1"

  # Extract checklist ✅ lines with issue title references
  local checklist_titles
  checklist_titles=$(sed '/^---ISSUE---$/q' "$issues_file" | \
    grep "✅" | grep -oE '→ Issue "([^"]+)"' | sed 's/→ Issue "//; s/"$//' | sort -u || true)

  if [ -z "$checklist_titles" ]; then
    return 0
  fi

  # Extract actual issue titles from ---ISSUE--- blocks and build a canonical
  # index (lowercase + whitespace-trimmed) — same normalization as _dedup_issues.
  # Each canonical title is stored on its own line in _canon_index.
  local _canon_index=""
  while IFS= read -r _raw_title; do
    local _canon
    _canon=$(echo "$_raw_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' || true)
    if [ -n "$_canon" ]; then
      _canon_index="${_canon_index}${_canon}"$'\n'
    fi
  done < <(grep "^TITLE:" "$issues_file" | sed 's/^TITLE: //' || true)

  # For each checklist title, canonicalize and look up in the index.
  # Unmatched titles are orphans — strip them from the checklist and emit a WARNING.
  local _orphan_count=0
  local _filtered_file
  _filtered_file=$(mktemp)

  # Copy full file to filtered; we'll strip orphan checklist lines in-place.
  cp "$issues_file" "$_filtered_file"

  while IFS= read -r ref_title; do
    [ -z "$ref_title" ] && continue
    local _ref_canon
    _ref_canon=$(echo "$ref_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' || true)

    # Skip entries that canonicalize to empty (whitespace/punctuation-only titles):
    # grep -qxF "" matches every line, so an empty _ref_canon would never be an orphan.
    [ -z "$_ref_canon" ] && continue

    # Check whether the canonical title is a whole-line match in the index.
    # -x (whole-line) provides parity with _dedup_issues which uses [ "$seen" = "$current_title" ]
    # (exact equality). Without -x, a checklist title that is a substring of an emitted
    # title would be falsely treated as matched, silently swallowing a genuine orphan.
    if echo "$_canon_index" | grep -qxF "$_ref_canon"; then
      continue  # Matched — leave the checklist line as-is
    fi

    # Unmatched: emit WARNING and strip the orphaned ✅ checklist line.
    print_warning "coverage checklist references \"$ref_title\" — no matching issue emitted; stripping orphan" >&2
    _orphan_count=$((_orphan_count + 1))

    # Remove the checklist line that references this title from the output file.
    # grep -vF uses fixed-string (not regex) matching so titles containing /
    # or other sed regex metacharacters cannot produce syntax errors or delete
    # the wrong line.
    local _needle="→ Issue \"$ref_title\""
    grep -vF "$_needle" "$_filtered_file" > "${_filtered_file}.tmp" && mv "${_filtered_file}.tmp" "$_filtered_file" || true
  done <<< "$checklist_titles"

  if [ "$_orphan_count" -gt 0 ]; then
    mv "$_filtered_file" "$issues_file"
  else
    rm -f "$_filtered_file"
  fi

  # _dedup_issues is the single source of truth for deduplication after reconciliation.
  _dedup_issues "$issues_file"
}

# =============================================================================
# Save deferred items to .rite/deferrals.log for future planning sessions
# =============================================================================

# =============================================================================
# Extract deferral statements from user feedback and persist them
# =============================================================================

_save_plan_feedback() {
  local feedback="$1"
  local feedback_file="$2"

  mkdir -p "$(dirname "$feedback_file")"

  local date_str
  date_str=$(date '+%Y-%m-%d')

  {
    echo "# Plan Feedback — Corrections from Previous Sessions"
    echo "# Updated: $date_str"
    echo "# Loaded automatically on next 'rite plan' run."
    echo "# Edit or remove entries that are no longer relevant."
    echo ""
    echo "$feedback"
  } > "$feedback_file"

  local line_count
  line_count=$(echo "$feedback" | wc -l | tr -d ' ')
  print_info "Saved $line_count lines of plan corrections to $(basename "$feedback_file")"
}

_persist_feedback_deferrals() {
  local feedback="$1"
  local deferrals_file="$2"
  local date_str
  date_str=$(date '+%Y-%m-%d')

  # Match lines like "defer snack suggestion to Phase 3A" or "drop the snack endpoint"
  # Extract what's being deferred using common phrasing patterns
  local new_deferrals=""
  while IFS= read -r line; do
    # Skip empty lines
    [ -z "$line" ] && continue
    # Match "defer X to Phase Y" patterns
    if echo "$line" | grep -qiE "(defer|deferred|drop|remove|cut|kill|skip|exclude)"; then
      new_deferrals="${new_deferrals}
- ⏭️ (user feedback, $date_str) $line"
    fi
  done <<< "$feedback"

  if [ -z "$new_deferrals" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$deferrals_file")"

  # Create header if file doesn't exist
  if [ ! -f "$deferrals_file" ]; then
    {
      echo "# Deferred Items"
      echo "# These items were deferred during planning and will be loaded as"
      echo "# context in the next 'rite plan' session."
      echo ""
    } > "$deferrals_file"
  fi

  # Append feedback-based deferrals (avoid duplicates)
  while IFS= read -r deferral_line; do
    [ -z "$deferral_line" ] && continue
    # Check if a substantially similar deferral already exists
    _check_text=$(echo "$deferral_line" | sed 's/^- ⏭️ ([^)]*) //' || true)
    if ! grep -qiF "$_check_text" "$deferrals_file" 2>/dev/null; then
      echo "$deferral_line" >> "$deferrals_file"
    fi
  done <<< "$new_deferrals"

  # Reload for current session
  previous_deferrals=$(cat "$deferrals_file")
}

_save_deferrals() {
  local issues_file="$1"
  local deferrals_file="$2"

  # Extract deferred items from coverage checklist (before first ---ISSUE---)
  local deferred
  deferred=$(sed '/^---ISSUE---$/q' "$issues_file" | grep -E "^- ⏭️" || true)

  # Extract source doc names from the issues (use first TITLE's phase/bracket prefix)
  local source_hint=""
  source_hint=$(grep -m1 "^TITLE:" "$issues_file" | sed 's/^TITLE: //' | grep -oE '^\[.*?\]' || true)

  local date_str
  date_str=$(date '+%Y-%m-%d')

  mkdir -p "$(dirname "$deferrals_file")"

  # Preserve user-feedback deferrals (lines with "user feedback" marker)
  local feedback_deferrals=""
  if [ -f "$deferrals_file" ]; then
    feedback_deferrals=$(grep "user feedback" "$deferrals_file" || true)
  fi

  if [ -z "$deferred" ] && [ -z "$feedback_deferrals" ]; then
    if [ -f "$deferrals_file" ]; then
      rm -f "$deferrals_file"
      print_info "All previous deferrals resolved"
    fi
    return 0
  fi

  # Write current deferrals + preserved feedback deferrals
  {
    echo "# Deferred Items"
    echo "# Updated: $date_str ${source_hint:+(from $source_hint planning)}"
    echo "#"
    echo "# These items were deferred during planning and will be loaded as"
    echo "# context in the next 'rite plan' session. Items that are picked up"
    echo "# (turned into issues) are automatically removed."
    echo ""
    [ -n "$deferred" ] && echo "$deferred"
    [ -n "$feedback_deferrals" ] && echo "$feedback_deferrals"
  } > "$deferrals_file"

  local count
  count=$(echo "$deferred" | wc -l | tr -d ' ')
  print_info "Saved $count deferral(s) to $(basename "$deferrals_file")"
}

# =============================================================================
# Detect unverified external integrations (deterministic — zero LLM calls)
#
# For each ---ISSUE--- block, extract:
#   - Hostnames from URLs (https?://hostname)
#   - Package/SDK names from import statements (Python and Node supported)
#
# Build the "grounded" set from the project:
#   - Hostnames: subdirectory names under RITE_PLAN_FIXTURE_GLOB paths
#   - Packages: names from requirements.txt, pyproject.toml, package.json,
#     go.mod, Cargo.toml
#
# For each ungrounded candidate:
#   - Emit WARNING to stderr
#   - Prepend a spike-issue block to the file
#   - Rewrite every downstream issue body to add "Blocked by: #SPIKE-<name>"
#     in its Dependencies section (placeholder filled by create_issues)
#
# Controlled by:
#   RITE_PLAN_SKIP_INTEGRATION_CHECK=1  — bypass this pass entirely
#   RITE_PLAN_FIXTURE_GLOB              — custom additional fixture directory path (single path, no brace expansion)
# =============================================================================

# _extract_packages_for_language: pluggable per-language import extractor.
# Prints one package name per line to stdout.
# Usage: echo "$issue_body" | _extract_packages_for_language <lang>
# Supported languages: python, node
_extract_packages_for_language() {
  local lang="$1"
  case "$lang" in
    python)
      # Match: import foo, from foo import bar, from foo.bar import baz
      # Capture the top-level module name only (before the first '.')
      grep -oE '^\s*(import|from)\s+[a-zA-Z_][a-zA-Z0-9_]*' | \
        sed 's/^[[:space:]]*//' | \
        sed 's/^import[[:space:]]\+//; s/^from[[:space:]]\+//' | \
        grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*' || true
      ;;
    node)
      # Match: require('foo'), require("foo"), from 'foo', from "foo"
      # Capture bare package names only (no relative paths starting with . or /)
      grep -oE "(require\(['\"][^'\"./][^'\"]*['\"]|from[[:space:]]+['\"][^'\"./][^'\"]*['\"])" | \
        grep -oE "['\"][^'\"./][^'\"]*['\"]" | \
        sed "s/['\"]//g" || true
      ;;
    *)
      # Unknown language — no extraction (returns nothing)
      ;;
  esac
}

# _detect_project_language: infer primary language from project manifests.
# Prints "python", "node", or "" (unknown) to stdout.
_detect_project_language() {
  local project_root="${RITE_PROJECT_ROOT:-.}"
  # Check manifest files first (authoritative).
  # Avoid "ls *.py" glob checks — head always exits 0 so it looks like a match
  # even on an empty directory under set -euo pipefail.
  if [ -f "$project_root/requirements.txt" ] || [ -f "$project_root/pyproject.toml" ]; then
    echo "python"
  elif [ -f "$project_root/package.json" ]; then
    echo "node"
  else
    echo ""
  fi
}

# _build_grounded_packages: collect packages from dependency manifests.
# Prints one package name per line (lowercased) to stdout.
_build_grounded_packages() {
  local project_root="${RITE_PROJECT_ROOT:-.}"

  # Python: requirements.txt — lines like "requests==2.28.0" or "requests>=2" or "requests"
  if [ -f "$project_root/requirements.txt" ]; then
    grep -oE '^[a-zA-Z_][a-zA-Z0-9_.-]*' "$project_root/requirements.txt" | \
      tr '[:upper:]' '[:lower:]' || true
  fi

  # Python: pyproject.toml — [project].dependencies or [tool.poetry.dependencies]
  if [ -f "$project_root/pyproject.toml" ]; then
    # Match quoted package names (e.g. "requests>=2", 'flask')
    grep -oE '"[a-zA-Z_][a-zA-Z0-9_.-]*[^"]*"' "$project_root/pyproject.toml" | \
      grep -oE '^"[a-zA-Z_][a-zA-Z0-9_.-]*' | \
      sed 's/^"//' | tr '[:upper:]' '[:lower:]' || true
  fi

  # Node: package.json — dependencies and devDependencies
  if [ -f "$project_root/package.json" ]; then
    # Extract package names from "dependencies" and "devDependencies" blocks.
    # Use awk to parse line-by-line: start at "dependencies", stop at a
    # closing brace at indentation level 1 (the end of the deps block).
    # Avoids literal '}' in grep patterns (which confuse brace-depth extractors).
    awk '
      /"dependencies"[[:space:]]*:/ { in_deps=1; next }
      /"devDependencies"[[:space:]]*:/ { in_deps=1; next }
      in_deps && /^[[:space:]]*[^ \t].*:/ && !/^[[:space:]]*"/ { in_deps=0; next }
      in_deps && /^[[:space:]]*"[a-zA-Z@]/ {
        gsub(/^[[:space:]]*"/, ""); gsub(/".*/, "")
        if (length($0) > 0) print tolower($0)
      }
    ' "$project_root/package.json" || true
  fi

  # Go: go.mod — "require" block entries like: github.com/foo/bar v1.2.3
  if [ -f "$project_root/go.mod" ]; then
    grep -oE '^\s+[a-zA-Z][a-zA-Z0-9./_-]+ v' "$project_root/go.mod" | \
      sed 's/[[:space:]]//g; s/v$//' | tr '[:upper:]' '[:lower:]' || true
  fi

  # Rust: Cargo.toml — [dependencies] section
  if [ -f "$project_root/Cargo.toml" ]; then
    # Use awk to extract dep names from [dependencies] block.
    # Avoids literal '}' / '[' in grep patterns.
    awk '
      /^\[dependencies\]/ { in_deps=1; next }
      in_deps && /^\[/ { in_deps=0; next }
      in_deps && /^[a-zA-Z_]/ { gsub(/[[:space:]]*=.*/, ""); print tolower($0) }
    ' "$project_root/Cargo.toml" || true
  fi
}

# _build_grounded_hosts: collect hostnames from fixture directory names.
# Prints one hostname per line (lowercased) to stdout.
_build_grounded_hosts() {
  local project_root="${RITE_PROJECT_ROOT:-.}"
  # RITE_PLAN_FIXTURE_GLOB accepts a single directory path (optionally with a
  # trailing /** or /*).  It does NOT support brace expansion — the default
  # covers the two conventional fixture directories directly in the loop below.
  # If you need a custom path set RITE_PLAN_FIXTURE_GLOB to a single base path,
  # e.g. "test/vcr_cassettes/**".
  local fixture_glob="${RITE_PLAN_FIXTURE_GLOB:-}"

  # Always scan the two conventional fixture directories, then also scan any
  # custom path supplied via RITE_PLAN_FIXTURE_GLOB (if it differs from the
  # defaults).  Walk one level: strip trailing /** or /* to get the base dir.
  local _dir _name
  # Portable dedup that works on bash 3.2 (no mapfile builtin).
  # Using while-read instead of "for _dir in $(...)" prevents word-splitting
  # on paths that contain spaces (SC2086 enforced rule).
  local _dirs_tmp
  _dirs_tmp=$(mktemp)
  for _base in fixtures tests/fixtures; do
    [ -d "$project_root/$_base" ] && echo "$project_root/$_base" >> "$_dirs_tmp" || true
  done
  # Honour RITE_PLAN_FIXTURE_GLOB if it was overridden to a custom path.
  if [ -n "$fixture_glob" ]; then
    local _custom_base
    _custom_base=$(echo "$fixture_glob" | sed 's|/\*\*$||; s|/\*$||' || true)
    if [ -n "$_custom_base" ] && [ "$_custom_base" != "fixtures" ] && [ "$_custom_base" != "tests/fixtures" ]; then
      [ -d "$project_root/$_custom_base" ] && echo "$project_root/$_custom_base" >> "$_dirs_tmp" || true
    fi
  fi
  sort -u "$_dirs_tmp" > "${_dirs_tmp}.sorted" && mv "${_dirs_tmp}.sorted" "$_dirs_tmp" || true
  while IFS= read -r _dir; do
    if [ -d "$_dir" ]; then
      for _entry in "$_dir"/*/; do
        [ -d "$_entry" ] || continue
        _name=$(basename "$_entry")
        echo "$_name" | tr '[:upper:]' '[:lower:]'
      done
      # Also capture top-level fixture files like sample.json → parent dir is already listed
      # Check for json/yaml files directly under fixtures/ (e.g. fixtures/api.example.com.json)
      for _entry in "$_dir"/*.json "$_dir"/*.yaml "$_dir"/*.yml; do
        [ -f "$_entry" ] || continue
        _name=$(basename "$_entry")
        _name="${_name%.*}"  # strip extension
        # Only treat it as a hostname if it looks like a domain (contains a dot)
        echo "$_name" | grep -q '\.' && echo "$_name" | tr '[:upper:]' '[:lower:]' || true
      done
    fi
  done < "$_dirs_tmp"
  rm -f "$_dirs_tmp"
}

# _sanitize_spike_key: convert a host/package name to a safe placeholder key.
# Replaces dots and slashes with hyphens, strips non-alphanumeric (except hyphen).
# Used both when emitting the spike and when rewriting downstream issue bodies.
_sanitize_spike_key() {
  echo "$1" | tr '.' '-' | tr '/' '-' | sed 's/[^a-zA-Z0-9-]//g' | tr '[:upper:]' '[:lower:]' || true
}

_detect_unverified_integrations() {
  local issues_file="$1"

  # Escape hatch: skip pass entirely
  if [ "${RITE_PLAN_SKIP_INTEGRATION_CHECK:-0}" = "1" ]; then
    return 0
  fi

  local project_root="${RITE_PROJECT_ROOT:-.}"
  # TAB_CHAR used as field separator in candidates temp file (tab is safe in filenames
  # we store; cut -f splits on it portably on both BSD and GNU).
  local TAB_CHAR
  TAB_CHAR=$(printf '\t')

  # Detect project language for package extraction
  local lang
  lang=$(_detect_project_language)

  # Build grounded sets (newline-separated, lowercased)
  local grounded_packages grounded_hosts
  grounded_packages=$(_build_grounded_packages | sort -u || true)
  grounded_hosts=$(_build_grounded_hosts | sort -u || true)

  # Collect all issue bodies concatenated (for extraction pass)
  # We parse block-by-block so we can track which issues reference which candidates.
  # Two-pass approach:
  #   Pass 1: collect all ungrounded candidates across all issues
  #   Pass 2: prepend spike issues + rewrite dependent issue Dependencies sections

  # Pass 1: extract candidates per issue block
  # We store results in a temp file: "candidate<TAB>issue_body_contains_it"
  local candidates_file
  candidates_file=$(mktemp)

  local _in_issue=false
  local _issue_body=""

  while IFS= read -r line; do
    if [[ "$line" == "---ISSUE---" ]]; then
      _in_issue=true
      _issue_body=""
      continue
    fi
    if [[ "$line" == "---END---" ]]; then
      _in_issue=false
      if [ -n "$_issue_body" ]; then
        # Extract hostnames from URLs in this issue body.
        # grep captures the full scheme+host (no path chars in char class).
        # Strip scheme with two sed passes (https:// and http://) — avoids
        # \? which is GNU sed only and silently fails on BSD sed (macOS).
        local _hosts
        _hosts=$(echo "$_issue_body" | grep -oE 'https?://[a-zA-Z0-9.-]+' | \
          sed 's|https://||; s|http://||' | tr '[:upper:]' '[:lower:]' | sort -u || true)
        # Extract packages from import statements
        local _pkgs=""
        if [ -n "$lang" ]; then
          _pkgs=$(echo "$_issue_body" | _extract_packages_for_language "$lang" | \
            tr '[:upper:]' '[:lower:]' | sort -u || true)
        fi
        # Check each host against grounded set
        if [ -n "$_hosts" ]; then
          while IFS= read -r _host; do
            [ -z "$_host" ] && continue
            if ! echo "$grounded_hosts" | grep -qxF "$_host" 2>/dev/null; then
              echo "host${TAB_CHAR}$_host" >> "$candidates_file"
            fi
          done <<< "$_hosts"
        fi
        # Check each package against grounded set
        if [ -n "$_pkgs" ]; then
          while IFS= read -r _pkg; do
            [ -z "$_pkg" ] && continue
            # Normalise hyphens vs underscores (Python convention: requests-toolbelt vs requests_toolbelt)
            local _pkg_norm
            _pkg_norm=$(echo "$_pkg" | tr '_' '-')
            local _grounded_norm
            _grounded_norm=$(echo "$grounded_packages" | tr '_' '-')
            if ! echo "$_grounded_norm" | grep -qxF "$_pkg_norm" 2>/dev/null; then
              echo "pkg${TAB_CHAR}$_pkg" >> "$candidates_file"
            fi
          done <<< "$_pkgs"
        fi
      fi
      continue
    fi
    if [ "$_in_issue" = true ]; then
      _issue_body+="$line"$'\n'
    fi
  done < "$issues_file"

  # De-duplicate the candidates file (same host/pkg may appear in multiple issues)
  local unique_candidates
  unique_candidates=$(sort -u "$candidates_file" || true)
  rm -f "$candidates_file"

  # If no unverified candidates, nothing to do
  if [ -z "$unique_candidates" ]; then
    return 0
  fi

  # Pass 2: for each ungrounded candidate, emit a WARNING and build a spike block.
  # Spike blocks are collected then prepended to the file in a single rewrite.
  local spikes_block=""
  # seen_spike_keys: newline-separated list of keys already emitted in this pass.
  # Deduplicates by sanitized key so that two candidates that collapse to the
  # same key (e.g. "foo.bar" and "foo-bar" → "foo-bar") produce only one spike
  # issue and one spike-map entry.  Without this guard, the collision leaves an
  # unreferenced orphan spike and a broken downstream dependency.
  local seen_spike_keys=""

  while IFS= read -r _candidate_line; do
    [ -z "$_candidate_line" ] && continue
    local _name
    _name=$(echo "$_candidate_line" | cut -f2)
    local _key
    _key=$(_sanitize_spike_key "$_name")

    print_warning "unverified external integration: $_name" >&2

    # Skip if a spike with this key was already emitted (key collision).
    # The downstream #SPIKE-<key> placeholder will resolve to the first spike.
    if echo "$seen_spike_keys" | grep -qxF "$_key" 2>/dev/null; then
      print_warning "spike key collision: '$_name' maps to key '$_key' which is already emitted — skipping duplicate spike" >&2
      continue
    fi
    seen_spike_keys="${seen_spike_keys}${_key}
"

    # Build spike issue block
    spikes_block+="---ISSUE---
TITLE: spike: capture $_name sample for grounding
LABELS: spike, tech-debt
TIME: 30min
BODY:
## Background

An emitted issue references \`$_name\` but no real API sample exists in the
repo's fixture directories. The downstream implementation would be built
against a hallucinated contract.

## Task

Make one real call to \`$_name\`. Capture a secret-scrubbed sample to
\`fixtures/$_name/\`. Document per-field provenance (what each returned field
means, whether it is stable across calls, any fields that contain secrets
that must be scrubbed before committing).

## Acceptance Criteria

- [ ] Sample exists at \`fixtures/$_name/\`
- [ ] Each field in the sample has a one-line provenance comment in the
  adjacent \`README.md\` (or inline in the JSON as a \`_comment\` key)
- [ ] No secrets (tokens, credentials, PII) are present in the committed sample

## Scope Boundary

**DO**: Capture one representative real response. Scrub secrets. Document fields.
**DO NOT**: Implement client code, write tests, or validate the sample against
a schema — those are the downstream issue's responsibility.
---END---
"
  done <<< "$unique_candidates"

  if [ -z "$spikes_block" ]; then
    return 0
  fi

  # Prepend spike blocks to the issues file (before any existing ---ISSUE--- blocks
  # but after the preamble/coverage-checklist section).
  local rewritten
  rewritten=$(mktemp)

  local _preamble_done=false

  while IFS= read -r line; do
    if [ "$_preamble_done" = false ] && [[ "$line" == "---ISSUE---" ]]; then
      # First issue block encountered — write spike blocks first, then this line
      _preamble_done=true
      printf '%s\n' "$spikes_block" >> "$rewritten"
      printf '%s\n' "$line" >> "$rewritten"
      continue
    fi
    printf '%s\n' "$line" >> "$rewritten"
  done < "$issues_file"

  # If file had no ---ISSUE--- blocks, append spikes at end
  if [ "$_preamble_done" = false ]; then
    printf '%s\n' "$spikes_block" >> "$rewritten"
  fi

  mv "$rewritten" "$issues_file"

  # Pass 3: rewrite downstream issue Dependencies sections to reference spike placeholders.
  # For each spike key, replace/add "Blocked by: #SPIKE-<key>" in issues that contain
  # the original name (host or package).
  local _spike_rewritten
  _spike_rewritten=$(mktemp)
  local _in_issue=false
  local _current_block=""

  while IFS= read -r line; do
    if [[ "$line" == "---ISSUE---" ]]; then
      _in_issue=true
      _current_block="$line"$'\n'
      continue
    fi
    if [ "$_in_issue" = true ]; then
      _current_block+="$line"$'\n'
      if [[ "$line" == "---END---" ]]; then
        _in_issue=false
        # Check if this is a spike issue itself (don't self-reference)
        local _is_spike=false
        echo "$_current_block" | grep -q "^TITLE: spike: " && _is_spike=true

        if [ "$_is_spike" = false ]; then
          # For each ungrounded candidate, check if this issue body references it.
          # If so, inject "Blocked by: #SPIKE-<key>" into the **Dependencies** line.
          while IFS= read -r _candidate_line; do
            [ -z "$_candidate_line" ] && continue
            local _name _key
            _name=$(echo "$_candidate_line" | cut -f2)
            _key=$(_sanitize_spike_key "$_name")
            local _placeholder="#SPIKE-$_key"

            # Check if block references the candidate in its extraction context,
            # not as a bare substring.  This prevents common words (e.g. "requests")
            # from matching unrelated prose ("incoming requests").
            #   host candidates  → must appear inside a URL scheme (https?://)
            #   package candidates → must appear in an import/require statement
            local _ctype
            _ctype=$(echo "$_candidate_line" | cut -f1)
            local _context_match=false
            if [ "$_ctype" = "host" ]; then
              # Match only when the name appears after a URL scheme, anchored to
              # the start of the hostname (avoids foo.example.com matching example.com).
              echo "$_current_block" | grep -qiE "https?://(www\.)?$(echo "$_name" | sed 's/\./\\./g')" && _context_match=true
            else
              # pkg: match import/require patterns only
              echo "$_current_block" | grep -qiE "(import|require|from)[[:space:]]+(\"|\\')?${_name}(\"|\\'|[[:space:]]|$)" && _context_match=true
            fi
            if [ "$_context_match" = true ]; then
              # Check if block already has a Dependencies line
              if echo "$_current_block" | grep -q "^\*\*Dependencies\*\*:"; then
                # Append to existing Dependencies line
                _current_block=$(echo "$_current_block" | \
                  sed "s|^\(\*\*Dependencies\*\*:.*\)|\1, Blocked by: ${_placeholder}|" || true)
              else
                # Insert a Dependencies line before ---END---
                # BSD sed (macOS) does not interpret \n in replacement strings;
                # use a shell substitution to insert the literal newline portably.
                _current_block="${_current_block%---END---
}"
                _current_block="${_current_block}**Dependencies**: Blocked by: ${_placeholder}
---END---
"
              fi
            fi
          done <<< "$unique_candidates"
        fi
        printf '%s' "$_current_block" >> "$_spike_rewritten"
        _current_block=""
      fi
    else
      # Preamble line
      printf '%s\n' "$line" >> "$_spike_rewritten"
    fi
  done < "$issues_file"

  mv "$_spike_rewritten" "$issues_file"
}

# =============================================================================
# Deduplicate ---ISSUE--- blocks by title, in-place
# =============================================================================

_dedup_issues() {
  local file="$1"
  local deduped
  deduped=$(mktemp)

  local in_issue=false
  local current_block=""
  local current_title=""
  local -a seen_titles=()
  local preamble_done=false

  while IFS= read -r line; do
    if [[ "$line" == "---ISSUE---" ]]; then
      in_issue=true
      preamble_done=true
      current_block="$line"$'\n'
      current_title=""
      continue
    fi

    if [ "$in_issue" = true ]; then
      current_block+="$line"$'\n'

      if [[ "$line" =~ ^TITLE:\ (.+) ]]; then
        # Normalize: trim whitespace, lowercase for comparison
        current_title="${BASH_REMATCH[1]}"
        current_title=$(echo "$current_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' || true)
      fi

      if [[ "$line" == "---END---" ]]; then
        in_issue=false

        # Check if this title was already seen
        local is_dup=false
        for seen in "${seen_titles[@]+"${seen_titles[@]}"}"; do
          if [ "$seen" = "$current_title" ]; then
            is_dup=true
            break
          fi
        done

        if [ "$is_dup" = false ]; then
          seen_titles+=("$current_title")
          printf '%s' "$current_block" >> "$deduped"
        fi
        current_block=""
      fi
    else
      # Preamble (coverage checklist etc.) — only keep content before first issue
      if [ "$preamble_done" = false ]; then
        printf '%s\n' "$line" >> "$deduped"
      fi
    fi
  done < "$file"

  local original_count
  local deduped_count
  original_count=$(grep -c "^---ISSUE---$" "$file" || true)
  deduped_count=$(grep -c "^---ISSUE---$" "$deduped" || true)

  if [ "$original_count" -ne "$deduped_count" ]; then
    print_warning "Removed $((original_count - deduped_count)) duplicate issue(s) (${original_count} → ${deduped_count})" >&2
    mv "$deduped" "$file"
  else
    rm -f "$deduped"
  fi
}

# =============================================================================
# Display generated issues
# =============================================================================

display_issues() {
  local issues_file="$1"
  local issue_num=0
  local total_time_min=0

  echo ""
  print_header "Generated Issues"

  # Count issues first
  local total_issues
  total_issues=$(grep -c "^---ISSUE---$" "$issues_file" || true)

  # Parse and display
  while IFS= read -r line; do
    if [[ "$line" == "---ISSUE---" ]]; then
      issue_num=$((issue_num + 1))
      if [ $issue_num -gt 1 ]; then
        echo ""
      fi
      echo -e "  ${CYAN}[$issue_num/$total_issues]${NC}"
    elif [[ "$line" == "---END---" ]]; then
      continue
    elif [[ "$line" =~ ^TITLE:\ (.+) ]]; then
      echo -e "  ${BLUE}${BASH_REMATCH[1]}${NC}"
    elif [[ "$line" =~ ^\*\*Description\*\*:\ ?(.+) ]]; then
      echo -e "  ${DIM}${BASH_REMATCH[1]}${NC}"
    elif [[ "$line" =~ ^LABELS:\ (.+) ]]; then
      echo -e "  ${DIM}Labels: ${BASH_REMATCH[1]}${NC}"
    elif [[ "$line" =~ ^TIME:\ (.+) ]]; then
      local time_str="${BASH_REMATCH[1]}"
      echo -e "  ${DIM}Time: ${time_str}${NC}"

      # Accumulate total time — handle "2hr", "45min", "1.5hr", "1hr 30min"
      if [[ "$time_str" =~ ([0-9]+\.[0-9]+)hr ]]; then
        # Decimal hours (e.g., 1.5hr) — convert via string manipulation (bash has no float math)
        local whole_hrs="${BASH_REMATCH[1]%%.*}"
        local frac="${BASH_REMATCH[1]#*.}"
        # .5 → 30min, .25 → 15min, .75 → 45min (single digit after decimal)
        local frac_min=$(( (frac * 60) / (10 ** ${#frac}) ))
        total_time_min=$((total_time_min + whole_hrs * 60 + frac_min))
      else
        # Integer hours and/or minutes — check both (not elif, handles "1hr 30min")
        if [[ "$time_str" =~ ([0-9]+)hr ]]; then
          total_time_min=$((total_time_min + ${BASH_REMATCH[1]} * 60))
        fi
        if [[ "$time_str" =~ ([0-9]+)min ]]; then
          total_time_min=$((total_time_min + ${BASH_REMATCH[1]}))
        fi
      fi
    elif [[ "$line" =~ ^\*\*Done\ Definition\*\*:\ (.+) ]]; then
      echo -e "  ${DIM}Done: ${BASH_REMATCH[1]}${NC}"
    elif [[ "$line" =~ ^\*\*Dependencies\*\*:\ (.+) ]]; then
      echo -e "  ${DIM}Deps: ${BASH_REMATCH[1]}${NC}"
    fi
  done < "$issues_file"

  echo ""
  # Format total time
  local total_hours=$((total_time_min / 60))
  local remaining_min=$((total_time_min % 60))
  local time_display=""
  if [ $total_hours -gt 0 ] && [ $remaining_min -gt 0 ]; then
    time_display="${total_hours}hr ${remaining_min}min"
  elif [ $total_hours -gt 0 ]; then
    time_display="${total_hours}hr"
  else
    time_display="${total_time_min}min"
  fi

  print_info "$issue_num issues, estimated total: $time_display"

  # Show deferred items from coverage checklist (lines before first ---ISSUE---)
  local deferred
  deferred=$(sed '/^---ISSUE---$/q' "$issues_file" | grep -E "^- ⏭️" || true)
  if [ -n "$deferred" ]; then
    echo ""
    print_info "Deferred to later phases:"
    echo "$deferred" | while IFS= read -r dline; do
      echo "  ${dline#- ⏭️ }"
    done
  fi
}

# =============================================================================
# Create issues in GitHub
# =============================================================================

create_issues() {
  local issues_file="$1"
  local -a created_numbers=()
  local current_title=""
  local current_labels=""
  local current_body=""
  local current_time=""
  local in_body=false
  local prev_issue_num=""
  # spike_map_file: stores "#SPIKE-<key>=<real-issue-number>" lines.
  # Used to rewrite #SPIKE-<key> placeholders in downstream issue bodies after
  # the spike issue is created.  Bash 3.2 compatible (no associative arrays).
  local spike_map_file
  spike_map_file=$(mktemp)

  print_header "Creating Issues"

  while IFS= read -r line; do
    if [[ "$line" == "---ISSUE---" ]]; then
      current_title=""
      current_labels=""
      current_body=""
      current_time=""
      in_body=false
    elif [[ "$line" == "---END---" ]]; then
      if [ -n "$current_title" ]; then
        # Replace #PREV with actual previous issue number
        if [ -n "$prev_issue_num" ]; then
          current_body="${current_body//#PREV/#$prev_issue_num}"
        else
          current_body="${current_body//After #PREV/None}"
          current_body="${current_body//Blocked by: #PREV/None}"
        fi

        # Replace #SPIKE-<key> placeholders with actual issue numbers from the map.
        # Iterate through each recorded spike mapping and apply the substitution.
        if [ -s "$spike_map_file" ]; then
          while IFS='=' read -r _placeholder _spike_num; do
            [ -z "$_placeholder" ] && continue
            current_body="${current_body//${_placeholder}/#${_spike_num}}"
          done < "$spike_map_file"
        fi

        # Post-substitution sweep: remove any surviving unresolvable #SPIKE-<key>
        # placeholders (can occur when a candidate matched via a false substring hit
        # before the -F fix, or when a spike was emitted but its map entry was never
        # recorded due to a title mismatch). Strip the whole "Blocked by: #SPIKE-…"
        # clause rather than leaving a broken reference in the created issue.
        current_body=$(echo "$current_body" | \
          sed 's|,\? *Blocked by: #SPIKE-[a-zA-Z0-9-]*||g; s|^[[:space:]]*Blocked by: #SPIKE-[a-zA-Z0-9-]*[[:space:]]*$||g' || true)
        # Clean up an empty Dependencies line that results from stripping all refs
        current_body=$(echo "$current_body" | \
          sed 's|^\*\*Dependencies\*\*:[[:space:]]*$||g' || true)

        # Prepend time estimate to body
        if [ -n "$current_time" ]; then
          current_body="**Time Estimate**: ${current_time}"$'\n\n'"${current_body}"
        fi

        print_status "Creating: $current_title"

        # Ensure labels exist (silently create if missing)
        local -a gh_args=()
        if [ -n "$current_labels" ]; then
          IFS=',' read -ra LABEL_ARRAY <<< "$current_labels"
          for label in "${LABEL_ARRAY[@]}"; do
            label=$(echo "$label" | xargs)  # trim whitespace
            gh_safe label create "$label" --force < /dev/null &>/dev/null || true
          done
          gh_args+=(--label "$current_labels")
        fi

        # Write body to temp file to avoid shell interpretation of backticks,
        # $(), and other metacharacters in verification commands / code blocks.
        # Passing via --body "$var" or echo "$var" | --body-file - both risk
        # expansion inside the command substitution that captures issue_url.
        local body_file
        body_file=$(mktemp)
        printf '%s' "$current_body" > "$body_file"

        local issue_url gh_exit
        issue_url=$(gh_safe issue create \
          --title "$current_title" \
          "${gh_args[@]}" \
          --body-file "$body_file" < /dev/null 2>&1) && gh_exit=0 || gh_exit=$?
        rm -f "$body_file"

        if [ $gh_exit -eq 0 ]; then
          local issue_num
          issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$' || true)
          created_numbers+=("$issue_num")
          print_success "Created #$issue_num"

          # If this is a spike issue, record its placeholder → real number mapping
          # so downstream issues get the correct "Blocked by: #<N>" reference.
          # Title format: "spike: capture <name> sample for grounding"
          # Spike issues do NOT update prev_issue_num — they are prepended
          # prerequisites and are not part of the sequential #PREV dependency
          # chain the planner authored among the real (non-spike) issues.
          if [[ "$current_title" =~ ^spike:\ capture\ (.+)\ sample\ for\ grounding$ ]]; then
            local _spike_name="${BASH_REMATCH[1]}"
            local _spike_key
            _spike_key=$(_sanitize_spike_key "$_spike_name")
            echo "#SPIKE-${_spike_key}=${issue_num}" >> "$spike_map_file"
          else
            # Only non-spike issues advance the #PREV pointer.
            prev_issue_num="$issue_num"
          fi
        else
          print_error "Failed: $issue_url"
        fi
      fi
    elif [[ "$line" =~ ^TITLE:\ (.+) ]]; then
      current_title="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^LABELS:\ (.+) ]]; then
      current_labels="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^TIME:\ (.+) ]]; then
      current_time="${BASH_REMATCH[1]}"
    elif [[ "$line" == BODY:* ]]; then
      in_body=true
      # Capture anything after "BODY:" on the same line
      local after_body="${line#BODY:}"
      after_body="${after_body# }"  # trim leading space
      if [ -n "$after_body" ]; then
        current_body="$after_body"$'\n'
      fi
    elif [ "$in_body" = true ]; then
      current_body+="$line"$'\n'
    fi
  done < "$issues_file"

  # Summary
  echo ""
  print_header "Plan Complete"
  print_success "Created ${#created_numbers[@]} issues"
  echo ""

  print_info "Issue numbers:"
  for num in "${created_numbers[@]}"; do
    echo "  #$num"
  done

  echo ""
  print_info "Next steps:"
  if [ ${#created_numbers[@]} -le 3 ]; then
    echo "  rite ${created_numbers[*]}                    # Batch process all"
  else
    echo "  rite ${created_numbers[0]}                         # Start with first issue"
    echo "  rite ${created_numbers[*]}   # Batch process all"
  fi
  echo "  rite --status --by-label              # View by label/phase"
  echo ""

  # Cleanup spike map temp file
  rm -f "$spike_map_file"
}
