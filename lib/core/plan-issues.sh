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

# Source colors if not already loaded
if ! declare -f print_info &>/dev/null; then
  if [ -n "${RITE_LIB_DIR:-}" ]; then
    source "$RITE_LIB_DIR/utils/colors.sh"
  fi
fi

# Detect Claude CLI
_detect_claude_cmd() {
  if command -v claude &>/dev/null; then
    echo "claude"
  elif command -v claude-code &>/dev/null; then
    echo "claude-code"
  elif [ -f "$HOME/.claude/claude" ]; then
    echo "$HOME/.claude/claude"
  else
    echo ""
  fi
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

  # Check Claude CLI
  local claude_cmd
  claude_cmd=$(_detect_claude_cmd)
  if [ -z "$claude_cmd" ]; then
    print_error "Claude CLI not found"
    echo "Install: npm install -g @anthropic-ai/claude-code"
    exit 1
  fi

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
  existing_issues=$(gh issue list --state open --limit 50 --json number,title,labels \
    --jq '.[] | "#\(.number) \(.title) [\([.labels[].name] | join(", "))]"' 2>/dev/null || echo "")

  # Detect repo's existing labels for accurate label suggestions
  local repo_labels=""
  repo_labels=$(gh label list --limit 100 --json name --jq '.[].name' 2>/dev/null | tr '\n' ', ' || echo "")

  # Load previous deferrals for continuity across planning sessions
  local deferrals_file="$RITE_PROJECT_ROOT/$RITE_DATA_DIR/deferrals.log"
  local previous_deferrals=""
  if [ -f "$deferrals_file" ]; then
    previous_deferrals=$(cat "$deferrals_file")
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
  local issues_file
  issues_file=$(generate_issues "$claude_cmd" "$doc_content" "$project_context" \
    "$runbook_content" "$existing_issues" "$repo_labels" "$user_instructions" "$max_estimate" \
    "" "$previous_deferrals")

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

        # Capture coverage checklist from prior iteration before deleting the file.
        # This carries forward codebase state findings (what already exists vs needs creation)
        # so Claude doesn't re-scope pre-existing artifacts during the feedback pass.
        local prior_coverage=""
        prior_coverage=$(sed '/^---ISSUE---$/q' "$issues_file" | grep -v "^---ISSUE---$" || true)

        print_status "Regenerating with your feedback..."
        rm -f "$issues_file"
        issues_file=$(generate_issues "$claude_cmd" "$doc_content" "$project_context" \
          "$runbook_content" "$existing_issues" "$repo_labels" "$user_instructions" "$max_estimate" \
          "$feedback" "$previous_deferrals" "$prior_coverage")

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
  local claude_cmd="$1"
  local doc_content="$2"
  local project_context="$3"
  local runbook_content="$4"
  local existing_issues="$5"
  local repo_labels="$6"
  local user_instructions="$7"
  local max_estimate="$8"
  local feedback="${9:-}"
  local previous_deferrals="${10:-}"
  local prior_coverage="${11:-}"

  local temp_file
  temp_file=$(mktemp)

  print_status "Generating issue definitions with Claude..." >&2

  local prompt
  prompt=$(cat <<PROMPT_EOF
You are generating GitHub issues for a software project, following the Sharkrite issue runbook.

**Project Context (from CLAUDE.md):**
${project_context:-No project CLAUDE.md found — infer conventions from the architectural doc.}

**Architectural Document(s) to plan from:**
${doc_content:-No document provided — generate issues based on the user instructions below.}

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
- Use \`#PREV\` in dependencies to reference the previous issue in sequence
- First issue should have \`Dependencies: None\`
- Follow logical dependency order: infrastructure → data models → core logic → API → tests → docs
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
- For a legitimately deferred feature, ask: does a simpler version exist that requires none of the later phase's dependencies? If yes, include the simpler version and defer only the full version.
- A "simpler version" of a filter means filtering by a value stored in the entity's own fields — no joins to user profiles or other entities. For example: `?has_variation=vegan` checks a JSON key on the recipe itself (simple, current phase). `?dietary_compatible=true` that compares recipe variation_groups against a user's dietary_profile JSON field is a cross-domain filter — it is NOT a simpler version; it is the full version with a user-profile join. If no simpler version genuinely exists, the deferral stands as-is — do not bundle the full version into a 1-hour filter issue.

**G. Time estimate calibration.**
Use these baselines before setting TIME fields:
- Pure schema/model work (no endpoints): 0.5–1hr
- Basic CRUD router (5 endpoints + tests): 1.5–2hr
- Filter/search extensions on existing list endpoint: 0.5–1hr
- Nested resource CRUD (e.g., /parent/{id}/children): 1.5–2hr — account for permission inheritance, relationship loading, and edge cases; do NOT estimate 1hr
- Cross-domain transactional endpoints (touches 2+ modules with atomic rollback): 2hr minimum
- Aggregate query endpoints (averages, counts, summaries): add 0.5hr to the base estimate

**H. Acceptance criteria deduplication.**
After drafting all issues, scan for criteria that describe the same behavior across multiple issues (e.g., "all recipe tests pass" in both a feature issue and a separate test issue). Each criterion must appear in exactly one issue.

**I. ADR coverage regression check (feedback iterations only).**
If a prior iteration coverage checklist was provided above, compare the current issue set against it. Every feature that had a ✅ entry in the prior checklist must either have a corresponding issue in the current set OR appear in the deferrals list with an explanation. A feature that was covered before and is simply absent now is a regression — not a deliberate scope change. Do not silently drop ADR bullets between iterations. If the user's feedback caused a feature to be removed, it must appear in deferrals with the note "(removed per user feedback)".

**J. Codebase state carry-forward (feedback iterations only).**
If a prior iteration identified an artifact (model, schema, migration, router) as already existing in the codebase, that finding stands — codebase state does not change between plan iterations. Do NOT re-scope a pre-existing artifact as "create from scratch" in the feedback pass. If in doubt, re-read the relevant file using your available tools before deciding. Scope pre-existing artifacts as "verify and extend," note what already exists in the description, and do not include migration work for tables that are already in the migration history.

**K. Schema ownership completeness.**
For every issue in the final set, identify each Pydantic schema, model, or artifact it assumes will exist at implementation time. Verify that each one is either:
- Already present in the codebase (confirmed by prior coverage checklist or direct file read), OR
- Explicitly created by a named earlier issue in the current set

If an issue references a schema that doesn't exist and no prior issue creates it, add the schema work to the most logical earlier issue and note it in that issue's acceptance criteria. Do not leave ownership gaps.

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

Generate the coverage checklist and all issues now.
PROMPT_EOF
)

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

    # Use stream-json for real-time output visibility (--verbose required with stream-json)
    echo "$prompt" | "$claude_cmd" --print --verbose --dangerously-skip-permissions \
      --model "${RITE_REVIEW_MODEL:-claude-opus-4-5}" \
      --output-format stream-json 2>"$claude_stderr" \
      | jq --unbuffered -rj '
          if .type == "assistant" then
            (.message.content[]? |
              if .type == "text" then .text
              else empty end)
          elif .type == "result" then .result // empty
          else empty end
        ' \
      | tee "$temp_file" >&2

    local exit_code=${PIPESTATUS[0]:-$?}

    # Log any Claude CLI errors
    if [ -s "$claude_stderr" ]; then
      print_warning "Claude stderr:" >&2
      cat "$claude_stderr" >&2
    fi

    if [ -s "$temp_file" ]; then
      print_info "Generated $(wc -l < "$temp_file" | tr -d ' ') lines of output" >&2
      break
    fi

    if [ $attempt -lt $max_attempts ]; then
      print_warning "Empty response from Claude (exit code: $exit_code), retrying..." >&2
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
  # jq -rj (join mode) emits text chunks with no added newlines, so when Claude
  # outputs ---END--- immediately followed by commentary in the next streaming
  # event, they concatenate on the same line: "---END---Now I have a complete..."
  # This breaks the exact-match checks in dedup, display, and create_issues.
  # Strip anything after the marker on the same line to restore clean delimiters.
  local normalized
  normalized=$(mktemp)
  sed \
    -e 's/^---END---.*$/---END---/' \
    -e 's/^---ISSUE---.*$/---ISSUE---/' \
    "$temp_file" > "$normalized"
  mv "$normalized" "$temp_file"

  # Deduplicate issues — Claude sometimes repeats the full issue set.
  # Keep only the first occurrence of each issue (by title).
  _dedup_issues "$temp_file"

  echo "$temp_file"
}

# =============================================================================
# Save deferred items to .rite/deferrals.log for future planning sessions
# =============================================================================

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

  if [ -z "$deferred" ]; then
    # No deferrals — everything was picked up or nothing was deferred.
    # Clear the file so stale deferrals don't persist.
    if [ -f "$deferrals_file" ]; then
      rm -f "$deferrals_file"
      print_info "All previous deferrals resolved"
    fi
    return 0
  fi

  # Replace file with current deferrals only. Claude re-evaluates all prior
  # deferrals each session — picked-up items become ✅ and won't appear here.
  # Only the still-deferred ⏭️ items carry forward.
  {
    echo "# Deferred Items"
    echo "# Updated: $date_str ${source_hint:+(from $source_hint planning)}"
    echo "#"
    echo "# These items were deferred during planning and will be loaded as"
    echo "# context in the next 'rite plan' session. Items that are picked up"
    echo "# (turned into issues) are automatically removed."
    echo ""
    echo "$deferred"
  } > "$deferrals_file"

  local count
  count=$(echo "$deferred" | wc -l | tr -d ' ')
  print_info "Saved $count deferral(s) to $(basename "$deferrals_file")"
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
        current_title="${BASH_REMATCH[1]}"
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
  total_issues=$(grep -c "^---ISSUE---$" "$issues_file" || echo "0")

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
    elif [[ "$line" =~ ^LABELS:\ (.+) ]]; then
      echo -e "  ${DIM}Labels: ${BASH_REMATCH[1]}${NC}"
    elif [[ "$line" =~ ^TIME:\ (.+) ]]; then
      local time_str="${BASH_REMATCH[1]}"
      echo -e "  ${DIM}Time: ${time_str}${NC}"

      # Accumulate total time
      if [[ "$time_str" =~ ([0-9]+)hr ]]; then
        total_time_min=$((total_time_min + ${BASH_REMATCH[1]} * 60))
      elif [[ "$time_str" =~ ([0-9]+)min ]]; then
        total_time_min=$((total_time_min + ${BASH_REMATCH[1]}))
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
            gh label create "$label" --force &>/dev/null || true
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

        local issue_url
        issue_url=$(gh issue create \
          --title "$current_title" \
          "${gh_args[@]}" \
          --body-file "$body_file" 2>&1)

        local gh_exit=$?
        rm -f "$body_file"

        if [ $gh_exit -eq 0 ]; then
          local issue_num
          issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
          created_numbers+=("$issue_num")
          prev_issue_num="$issue_num"
          print_success "Created #$issue_num"
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
}
