# Configuration

Sharkrite uses a layered config system — global defaults, project overrides, environment variables:

```
Defaults → ~/.config/rite/config (global) → .rite/config (project) → Environment variables
```

## Project Config (`.rite/config`)

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

See [config/project.conf.example](../config/project.conf.example) for all options.

## Global Config (`~/.config/rite/config`)

Settings that apply across all projects:

```bash
# Notifications
SLACK_WEBHOOK="https://hooks.slack.com/services/..."
EMAIL_NOTIFICATION_ADDRESS="you@example.com"

# AWS profile for notifications
RITE_AWS_PROFILE="default"
```

See [config/rite.conf.example](../config/rite.conf.example) for all options.

## Blocker Rules (`.rite/blockers.conf`)

Customize which file patterns trigger blocker detection:

```bash
BLOCKER_INFRASTRUCTURE_PATHS="(cdk|cloudformation|terraform|pulumi)"
BLOCKER_MIGRATION_PATHS="(prisma/migrations|migrations/|alembic/)"
BLOCKER_AUTH_PATHS="(auth|cognito|jwt|oauth|session)"
```

See [config/blockers.conf.example](../config/blockers.conf.example) for all patterns.

## Assessment Customization

Control how Claude assesses PR review issues:

1. **`.rite/assessment-prompt.md`** — Full custom assessment prompt (highest priority)
2. **`CLAUDE.md`** — Sharkrite extracts security/conventions sections automatically
3. **Generic fallback** — Built-in assessment criteria from `templates/assessment-prompt.md`

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RITE_WORKTREE_DIR` | Worktree base directory | `~/Dev/worktrees/$PROJECT` |
| `RITE_MAX_ISSUES_PER_SESSION` | Max issues per session | `8` |
| `RITE_MAX_SESSION_HOURS` | Max session duration (hours) | `4` |
| `RITE_MAX_RETRIES` | Fix loop attempts | `3` |
| `RITE_ASSESSMENT_TIMEOUT` | Claude assessment timeout (seconds) | `120` |
| `RITE_AWS_PROFILE` | AWS profile for notifications | `default` |
| `RITE_BIN_DIR` | Override symlink location | `~/.local/bin` |
| `WORKFLOW_MODE` | Default workflow mode | `unsupervised` |
| `SKIP_AWS_CHECK` | Skip AWS credential checks | `false` |
| `SLACK_WEBHOOK` | Slack webhook for notifications | — |
| `RITE_EMAIL_FROM` | Email sender for notifications | — |
| `RITE_SNS_TOPIC_ARN` | AWS SNS topic for SMS | — |

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
