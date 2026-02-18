# Review System

## Review Sources

Reviews can come from two sources:

1. **Local Review** — Run Claude CLI locally to generate reviews (default)
2. **Claude for GitHub App** — Automatic reviews on PR creation (requires app installation)

### Local Review Command

Generate and post reviews without the Claude for GitHub app:

```bash
# Preview review (does not post)
lib/core/local-review.sh <pr-number>

# Generate and post to PR
lib/core/local-review.sh <pr-number> --post

# Automation mode (non-interactive)
lib/core/local-review.sh <pr-number> --post --auto
```

Configure the default review method in `.rite/config`:
```bash
RITE_REVIEW_METHOD=local  # or "app" or "auto" (default)
```

## Review Assessment

Uses Claude CLI for intelligent PR review filtering. Each finding is classified:

- **ACTIONABLE_NOW** — Fix in this PR: security issues, bugs, valid concerns within scope
- **ACTIONABLE_LATER** — Valid but out-of-scope, defer to a follow-up issue
- **DISMISSED** — Not worth tracking (style preferences, theoretical edge cases)

Each item shows severity, category, and reasoning for the decision.

### Assessment Caching

Assessments are cached by SHA256 hash of review content + model for determinism:

```bash
# Cache location
.rite/assessment-cache/

# Cache is invalidated when:
# - New review is posted (local-review.sh --post)
# - PR is merged (merge-pr.sh)
```

### Model Consistency

Reviews and assessments use the same model for consistent results:

```bash
# Configure in .rite/config or environment
RITE_REVIEW_MODEL=opus  # default

# Model is embedded in review metadata:
# <!-- sharkrite-local-review model:opus timestamp:... -->
```

## Fix Loop & Tech-Debt Flow

When ACTIONABLE_NOW items exist:

```
Loop (max 3 retries):
  1. Claude Code fixes ACTIONABLE_NOW items
  2. Commit and push
  3. New review generated
  4. Re-assess (same criteria every loop)
  5. If ACTIONABLE_NOW = 0 → exit loop
  6. If still has items → repeat

After max retries:
  - All ACTIONABLE_LATER items → tech-debt labeled issue
  - Remaining ACTIONABLE_NOW → also goes to tech-debt
  - Proceed to blocker check → merge or block
```

## Review Severity Parsing

The review outputs a `Findings: [CRITICAL: N | HIGH: N | ...]` summary line. The assessment system parses the structured Findings line rather than doing broad keyword matching.
