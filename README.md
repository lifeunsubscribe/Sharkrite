# Forge

**AI-powered GitHub workflow automation CLI — process issues end-to-end with Claude Code**

Forge automates the full lifecycle of GitHub issue development: branch creation, Claude Code development, PR creation, review assessment, fix loops, and merge — with intelligent blocker detection and security feedback loops.

---

## Quick Start

### Install

```bash
git clone <repo-url> /tmp/rite-install
cd /tmp/rite-install
./install.sh
```

This installs to `~/.rite/` and symlinks `forge` into `~/.local/bin/`.

### Prerequisites

- **git** — version control
- **gh** — GitHub CLI (`brew install gh`)
- **jq** — JSON parsing (`brew install jq`)
- **claude** — Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)

### Initialize a Project

```bash
cd your-repo
rite --init
```

Creates `.rite/` directory with default config and scratchpad.

### Usage

```bash
# Process single issue (full lifecycle: work → PR → review → fixes → merge)
rite 21

# Quick mode (work → PR only, skip review/merge)
rite 21 --quick

# Process multiple issues in batch
rite 21 45 31

# Auto-discover and process follow-up pairs
rite --followup

# Dry run (show what would happen without executing)
rite 21 --dry-run

# Help
rite --help
```

**Smart routing:**
- `rite 21` → Full lifecycle (workflow-runner.sh)
- `rite 21 --quick` → Work + PR only (claude-workflow.sh + create-pr.sh)
- `rite 21 45` → Batch mode (batch-process-issues.sh)
- `rite --followup` → Batch mode with follow-up filter

---

## How It Works

```
Issue #21 → workflow-runner.sh
              ↓
         Phase 1: claude-workflow.sh (development with Claude Code)
              ↓
         Phase 2: create-pr.sh (creates PR, waits for review)
              ↓
         Phase 3: assess-and-resolve.sh (assesses review)
              ↓
         CRITICAL found? → claude-workflow.sh --fix-review
              ↓                    ↓
         Loop up to 3x     Push fixes, wait for new review
              ↓
         Clean? → merge-pr.sh
              ↓
         Done. Security findings saved to scratchpad.
```

### Phases

1. **Pre-Start Checks** — Validate credentials, check session limits
2. **Claude Workflow** — Development with Claude Code in isolated worktree
3. **Create PR** — Create PR, wait for automated review with dynamic wait times
4. **Assess & Resolve** — Categorize review issues using Claude CLI (ACTIONABLE_NOW / ACTIONABLE_LATER / DISMISSED)
5. **Merge PR** — Merge if safe, update documentation, save security findings
6. **Completion** — Notifications, cleanup

---

## Configuration

Forge uses a layered config system:

```
Defaults → ~/.config/rite/config (global) → .rite/config (project) → Environment variables
```

### Project Config (`.rite/config`)

Created by `rite --init`. Key settings:

```bash
# Worktree base directory
RITE_WORKTREE_DIR="$HOME/Dev/worktrees/myproject"

# Session limits
RITE_MAX_ISSUES_PER_SESSION=8
RITE_MAX_SESSION_HOURS=4

# Claude assessment timeout (seconds)
RITE_ASSESSMENT_TIMEOUT=120
```

See [config/project.conf.example](config/project.conf.example) for all options.

### Global Config (`~/.config/rite/config`)

Settings that apply across all projects:

```bash
# Notifications
SLACK_WEBHOOK_URL="https://hooks.slack.com/..."
RITE_EMAIL_FROM="forge@example.com"

# AWS profile for notifications
RITE_AWS_PROFILE="default"
```

See [config/rite.conf.example](config/rite.conf.example) for all options.

### Blocker Rules (`.rite/blockers.conf`)

Customize which file patterns trigger blocker detection:

```bash
BLOCKER_INFRASTRUCTURE_PATHS="(cdk|cloudformation|terraform|pulumi)"
BLOCKER_MIGRATION_PATHS="(prisma/migrations|migrations/|alembic/)"
BLOCKER_AUTH_PATHS="(auth|cognito|jwt|oauth|session)"
```

See [config/blockers.conf.example](config/blockers.conf.example) for all patterns.

### Assessment Customization

Control how Claude assesses PR review issues:

1. **`.rite/assessment-prompt.md`** — Full custom assessment prompt (highest priority)
2. **`CLAUDE.md`** — Forge extracts security/conventions sections automatically
3. **Generic fallback** — Built-in assessment criteria from `templates/assessment-prompt.md`

---

## Project Structure

```
forge/
├── bin/rite                        # CLI entry point
├── lib/
│   ├── core/                        # Core workflow scripts
│   │   ├── workflow-runner.sh       # Central orchestrator (5 phases)
│   │   ├── claude-workflow.sh       # Claude Code development + worktree management
│   │   ├── create-pr.sh            # PR creation + review waiting
│   │   ├── assess-and-resolve.sh   # Review assessment + fix loop
│   │   ├── assess-review-issues.sh # Claude CLI issue categorization
│   │   ├── assess-documentation.sh # Pre-merge doc completeness check
│   │   ├── merge-pr.sh             # PR merge + scratchpad update
│   │   └── batch-process-issues.sh # Multi-issue batch processing
│   └── utils/                       # Shared libraries
│       ├── config.sh               # Layered configuration loader
│       ├── colors.sh               # Terminal colors and print helpers
│       ├── blocker-rules.sh        # 10 configurable blocker rules
│       ├── scratchpad-manager.sh   # Security feedback loop
│       ├── session-tracker.sh      # Session state and limits
│       ├── notifications.sh        # Slack/Email/SMS notifications
│       ├── format-review.sh        # Review content formatting
│       ├── create-followup-issues.sh # GitHub issue creation
│       ├── review-assessment.sh    # Assessment display helpers
│       ├── cleanup-worktrees.sh    # Worktree cleanup utility
│       └── validate-setup.sh       # Prerequisites validator
├── config/                          # Example configurations
│   ├── forge.conf.example          # Global config template
│   ├── project.conf.example        # Per-project config template
│   └── blockers.conf.example       # Blocker patterns template
├── templates/                       # Templates for rite --init
│   ├── scratchpad.md               # Scratchpad structure
│   ├── assessment-prompt.md        # Generic assessment criteria
│   └── gitignore                   # .rite/.gitignore template
├── install.sh                       # Installer (idempotent)
├── uninstall.sh                     # Uninstaller
└── README.md                        # This file
```

---

## Features

### 10 Blocker Rules

Prevents accidental bad merges. Each rule is configurable via `.rite/blockers.conf`:

1. **Infrastructure Changes** — CDK, IAM, CloudFormation, Terraform
2. **Database Migrations** — Prisma, Alembic, raw SQL migrations
3. **Authentication/Authorization** — Cognito, JWT, OAuth, session logic
4. **Architectural Documentation** — CLAUDE.md, architecture docs
5. **CRITICAL Issues in Review** — Security risks, data integrity
6. **Test/Build Failures** — Failed CI checks
7. **Expensive AWS Services** — RDS, Aurora, NAT Gateway, EC2
8. **Session Limits** — Configurable issue count and time limits
9. **AWS Credentials Expired** — SSO session timeout
10. **Protected Scripts Changed** — Workflow scripts modified

### Smart Worktree Management

- **Auto-detect**: Finds existing worktree for issue
- **Auto-navigate**: Switches to correct worktree
- **Auto-stash**: Stashes changes before navigation, pops when returning
- **Auto-cleanup**: Removes merged branches at limit

### Security Feedback Loop

Scratchpad tracks security findings across PRs:

1. PR review finds security issues
2. `merge-pr.sh` extracts findings to scratchpad
3. Next issue loads scratchpad into Claude Code context
4. Claude Code avoids repeating same patterns
5. Last 5 PRs in "Recent", last 20 in archive

### Review Generation

Reviews can come from two sources:

1. **Claude for GitHub App** — Automatic reviews on PR creation (requires app installation)
2. **Local Review** — Run Claude CLI locally to generate reviews

```bash
# Preview a review without posting
lib/core/local-review.sh 42

# Generate and post review to PR
lib/core/local-review.sh 42 --post

# Use in automation
lib/core/local-review.sh 42 --post --auto
```

Configure default method in `.rite/config`:
```bash
RITE_REVIEW_METHOD=local  # or "app" or "auto" (default)
```

### Smart Review Assessment

Uses Claude CLI for intelligent PR review filtering:

- **ACTIONABLE_NOW** — Fix in this PR: security issues, bugs, valid concerns within scope
- **ACTIONABLE_LATER** — Valid but out-of-scope, defer to tech-debt issue
- **DISMISSED** — Not worth tracking (style preferences, theoretical edge cases)

Each item shows severity, category, and reasoning for the decision.

#### Assessment Caching

Assessments are cached by SHA256 hash of review content + model for determinism:

```bash
# Cache location
.rite/assessment-cache/

# Cache is invalidated when:
# - New review is posted (local-review.sh --post)
# - PR is merged (merge-pr.sh)
```

#### Model Consistency

Reviews and assessments use the same model for consistent results:

```bash
# Configure in .rite/config or environment
RITE_REVIEW_MODEL=opus  # default

# Model is embedded in review metadata:
# <!-- sharkrite-local-review model:opus timestamp:... -->
```

### Fix Loop & Tech-Debt Flow

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

### Reopening Closed Issues

To run the PR loop on a previously closed issue:

```bash
rite review <issue-number>
```

This reopens the issue and runs the full workflow (work → PR → review → fixes → merge).

---

## Per-Project `.rite/` Directory

Created by `rite --init`:

```
.rite/
├── config              # Project settings (committed)
├── blockers.conf       # Blocker patterns (committed)
├── assessment-prompt.md # Custom assessment context (committed, optional)
├── .gitignore          # Ignores runtime files below
├── scratch.md          # Working notes + security findings (gitignored)
├── session-state/      # Session tracking JSON (gitignored)
└── *.log               # Runtime logs (gitignored)
```

**Committed**: `config`, `blockers.conf`, `assessment-prompt.md`
**Gitignored**: `scratch.md`, `session-state/`, `*.log`

---

## Troubleshooting

### "AWS credentials expired"
```bash
aws sso login --profile your-profile
```

### "Session limit reached"
```bash
# Check session state
cat .rite/session-state/current-session.json

# Clear manually (auto-resets after timeout)
rm .rite/session-state/current-session.json
```

### "Worktree limit exceeded"
```bash
# Auto-cleanup merged branches
rite cleanup-worktrees

# Or manual
git worktree list
git worktree remove /path/to/stale-worktree
```

### "Blocker detected"
```bash
# Resume scripts are auto-created
.resume/resume-ISSUE_NUMBER.sh
```

### "PR review not found"
- Ensure Claude for GitHub app is installed on the repo
- Review may still be running (wait longer)
- Check: `gh pr view PR_NUMBER`

---

## Uninstall

```bash
~/.rite/uninstall.sh
# Or if you have the source:
./uninstall.sh
```

Removes runtime and symlink. Prompts before removing config. Never touches project `.rite/` directories.

---

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RITE_WORKTREE_DIR` | Worktree base directory | `~/Dev/worktrees/$PROJECT` |
| `RITE_MAX_ISSUES_PER_SESSION` | Max issues per session | `8` |
| `RITE_MAX_SESSION_HOURS` | Max session duration (hours) | `4` |
| `RITE_ASSESSMENT_TIMEOUT` | Claude assessment timeout (seconds) | `120` |
| `RITE_AWS_PROFILE` | AWS profile for notifications | `default` |
| `RITE_BIN_DIR` | Override symlink location | `~/.local/bin` |
| `SLACK_WEBHOOK_URL` | Slack webhook for notifications | — |
| `RITE_EMAIL_FROM` | Email sender for notifications | — |
| `RITE_SNS_TOPIC_ARN` | AWS SNS topic for SMS | — |
