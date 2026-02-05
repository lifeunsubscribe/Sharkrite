#!/bin/bash

# assess-documentation.sh - Pre-merge documentation completeness check
# Uses Claude CLI to assess if docs need updating based on code changes

set -euo pipefail

# Source forge configuration
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${RITE_LIB_DIR:-}" ]; then
  source "$_SCRIPT_DIR/../utils/config.sh"
fi

source "$RITE_LIB_DIR/utils/colors.sh"

PR_NUMBER="$1"
AUTO_MODE="${2:-}"

if [ -z "$PR_NUMBER" ]; then
  print_error "Usage: $0 <pr_number> [--auto]"
  exit 1
fi

# Check Claude CLI availability
if ! command -v claude &> /dev/null; then
  print_error "❌ Claude CLI not found"
  print_warning "Install: npm install -g @anthropic-ai/claude-cli"
  print_warning "Setup: claude setup-token"
  exit 1
fi

# Test Claude CLI
if ! echo "test" | claude --print --dangerously-skip-permissions &> /dev/null; then
  print_error "❌ Claude CLI not authenticated or not working"
  print_warning "Run: claude setup-token"
  exit 1
fi

print_header "📚 Assessing Documentation Completeness"

# Get PR details
PR_DATA=$(gh pr view "$PR_NUMBER" --json title,body,files,commits)
PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_BODY=$(echo "$PR_DATA" | jq -r '.body // ""')

print_info "PR #$PR_NUMBER: $PR_TITLE"

# Get changed files
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.files[].path' | grep -v '^docs/' | head -20)
FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | xargs)

print_info "Changed files (excluding docs/): $FILE_COUNT"

# Get commit messages for context
COMMIT_MESSAGES=$(echo "$PR_DATA" | jq -r '.commits[].messageHeadline' | head -10)

# Get current documentation structure
DOC_FILES=$(find docs/ -name "*.md" 2>/dev/null | sort || echo "")

# Get CLAUDE.md sections if it exists
CLAUDE_MD_SECTIONS=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_MD_SECTIONS=$(grep "^##" CLAUDE.md | head -30)
fi

# Get project README sections if available (configurable per project)
README_SECTIONS=""
if [ -n "${RITE_SCRIPTS_README:-}" ] && [ -f "$RITE_SCRIPTS_README" ]; then
  README_SECTIONS=$(grep "^##" "$RITE_SCRIPTS_README" | head -20)
elif [ -f "README.md" ]; then
  README_SECTIONS=$(grep "^##" README.md | head -20)
fi

# Get table of contents from each major doc to understand coverage
ARCHITECTURE_DOCS=""
for doc in docs/architecture/*.md; do
  if [ -f "$doc" ]; then
    ARCHITECTURE_DOCS="$ARCHITECTURE_DOCS\n$(basename "$doc"): $(grep "^#" "$doc" | head -5 | sed 's/^/  /')"
  fi
done

PROJECT_DOCS=""
for doc in docs/project/*.md; do
  if [ -f "$doc" ]; then
    PROJECT_DOCS="$PROJECT_DOCS\n$(basename "$doc"): $(grep "^#" "$doc" | head -5 | sed 's/^/  /')"
  fi
done

WORKFLOW_DOCS=""
for doc in docs/workflows/*.md; do
  if [ -f "$doc" ]; then
    WORKFLOW_DOCS="$WORKFLOW_DOCS\n$(basename "$doc"): $(grep "^#" "$doc" | head -5 | sed 's/^/  /')"
  fi
done

SECURITY_DOCS=""
for doc in docs/security/*.md; do
  if [ -f "$doc" ]; then
    SECURITY_DOCS="$SECURITY_DOCS\n$(basename "$doc"): $(grep "^#" "$doc" | head -5 | sed 's/^/  /')"
  fi
done

DEVELOPMENT_DOCS=""
for doc in docs/development/*.md; do
  if [ -f "$doc" ]; then
    DEVELOPMENT_DOCS="$DEVELOPMENT_DOCS\n$(basename "$doc"): $(grep "^#" "$doc" | head -5 | sed 's/^/  /')"
  fi
done

# Build assessment prompt
ASSESSMENT_PROMPT=$(cat <<EOF
You are reviewing a pull request to assess if documentation needs updating.

**PR Title:** $PR_TITLE

**PR Description:**
$PR_BODY

**Changed Files (excluding docs/):**
$CHANGED_FILES

**Recent Commits:**
$COMMIT_MESSAGES

**Existing Documentation Structure:**

Root-level docs:
- CLAUDE.md (main architecture guide): $(echo "$CLAUDE_MD_SECTIONS" | head -10 | tr '\n' ';')
$([ -n "$README_SECTIONS" ] && echo "- README.md (project overview): $(echo "$README_SECTIONS" | head -10 | tr '\n' ';')" || echo "")

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

**Check ALL documentation categories:**
1. **New scripts or automation** → project README or workflow docs
2. **New architectural patterns** → CLAUDE.md
3. **New workflows or CI/CD** → docs/workflows/
4. **Security patterns/vulnerabilities** → docs/security/
5. **New functions/resources** → CLAUDE.md or docs/architecture/
6. **Infrastructure changes** → docs/architecture/
7. **Database schema changes** → docs/architecture/
8. **New configuration/environment variables** → CLAUDE.md or docs/development/
9. **Testing strategy changes** → docs/development/
10. **Business/product changes** → docs/project/
11. **Documentation index changes** → docs/README.md

**Response Format:**
If documentation updates are needed, respond with:
NEEDS_UPDATE: <file1.md>, <file2.md>, <file3.md>
REASON: <Brief explanation of what needs updating>

If no documentation updates needed, respond with:
NO_UPDATE_NEEDED
REASON: <Brief explanation>

**Be strict:** Architectural changes, new patterns, new scripts, infrastructure changes ALWAYS need documentation.

**Examples of what needs docs:**
- New bash scripts → project README or workflow docs
- New error handling patterns → CLAUDE.md
- New rate limiting logic → CLAUDE.md + docs/security/
- New CI/CD workflows → docs/workflows/
- Database schema changes → docs/architecture/
- New AWS resources → docs/architecture/
- New feature tiers or access control → docs/project/
- Product roadmap changes → docs/project/

**Examples of what doesn't need docs:**
- Bug fixes to existing code (no pattern change)
- Updating existing tests (no new testing strategy)
- Refactoring without behavior change
- Minor version bumps
- Comment improvements
EOF
)

print_info "Running documentation assessment..."

# Run assessment
ASSESSMENT_OUTPUT=$(echo "$ASSESSMENT_PROMPT" | claude --print --dangerously-skip-permissions 2>&1)

if echo "$ASSESSMENT_OUTPUT" | grep -q "^NEEDS_UPDATE"; then
  DOCS_TO_UPDATE=$(echo "$ASSESSMENT_OUTPUT" | grep "^NEEDS_UPDATE:" | sed 's/NEEDS_UPDATE: //')
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //')

  print_warning "⚠️  Documentation updates recommended"
  echo ""
  print_info "Files to update: $DOCS_TO_UPDATE"
  print_info "Reason: $REASON"
  echo ""

  if [ "$AUTO_MODE" = "--auto" ]; then
    print_warning "⚠️  Documentation updates needed - applying updates now"

    # Get PR diff for context
    PR_DIFF=$(gh pr diff $PR_NUMBER | head -300)

    # For each file that needs updating, read current content and generate update
    IFS=',' read -ra FILES_ARRAY <<< "$DOCS_TO_UPDATE"
    UPDATED_FILES=()

    for doc_file in "${FILES_ARRAY[@]}"; do
      doc_file=$(echo "$doc_file" | xargs)  # trim whitespace

      if [ ! -f "$doc_file" ]; then
        print_warning "File not found: $doc_file, skipping"
        continue
      fi

      print_info "Updating $doc_file..."

      CURRENT_CONTENT=$(cat "$doc_file")

      UPDATE_PROMPT=$(cat <<EOF
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
EOF
)

      UPDATED_CONTENT=$(echo "$UPDATE_PROMPT" | claude --print --dangerously-skip-permissions 2>&1)

      if [ $? -eq 0 ] && [ -n "$UPDATED_CONTENT" ]; then
        # Verify update looks reasonable (not truncated)
        ORIGINAL_SIZE=$(echo "$CURRENT_CONTENT" | wc -l)
        NEW_SIZE=$(echo "$UPDATED_CONTENT" | wc -l)
        MIN_SIZE=$((ORIGINAL_SIZE * 80 / 100))

        if [ "$NEW_SIZE" -lt "$MIN_SIZE" ]; then
          print_error "Updated $doc_file too short ($NEW_SIZE lines vs $ORIGINAL_SIZE original), skipping"
          continue
        fi

        # Backup original
        cp "$doc_file" "${doc_file}.backup-$(date +%s)"

        # Apply update
        echo "$UPDATED_CONTENT" > "$doc_file"
        UPDATED_FILES+=("$doc_file")
        print_success "✓ Updated $doc_file"
      else
        print_error "Failed to generate update for $doc_file"
      fi
    done

    if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
      print_success "✓ Documentation updated: ${UPDATED_FILES[*]}"

      # Git add the updated docs
      git add "${UPDATED_FILES[@]}"

      # Commit doc updates
      git commit -m "docs: update documentation for PR #$PR_NUMBER

Auto-updated by doc assessment:
- Files: ${UPDATED_FILES[*]}
- Reason: $REASON

Related: #$PR_NUMBER" || print_warning "No changes to commit (docs may already be up to date)"

      # Send Slack notification
      if [ -n "${SLACK_WEBHOOK:-}" ]; then
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
      print_warning "No documentation files were updated"
    fi

    # Don't block merge - docs are updated
    exit 0
  else
    # Interactive mode: ask user
    echo ""
    read -p "Continue with merge anyway? (y/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
      print_info "Merge cancelled - update documentation first"
      exit 2
    fi
  fi
else
  print_success "✅ Documentation is up to date"
  REASON=$(echo "$ASSESSMENT_OUTPUT" | grep "^REASON:" | sed 's/REASON: //' || echo "No updates needed")
  print_info "$REASON"
fi

exit 0
