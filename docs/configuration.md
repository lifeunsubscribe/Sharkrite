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
RITE_MAX_SESSION_HOURS=12   # Cumulative active work hours (not wall-clock)
RITE_MAX_ISSUE_HOURS=4      # Per-issue cap — fires if a single issue runs >4h

# Claude assessment timeout (seconds)
RITE_ASSESSMENT_TIMEOUT=300

# Doc assessment model (default: sonnet for structured pattern matching tasks).
# Doc reconciliation is "did this diff change API surface X? Update accordingly" —
# pattern matching and structured comparison, sonnet's sweet spot.
# Use claude-opus-4-8 only if you need deeper reasoning on large diffs.
# Fully independent of RITE_REVIEW_MODEL (code review stays on opus regardless).
RITE_DOC_ASSESSMENT_MODEL=claude-sonnet-4-6

# Issue planning model (default: opus). `rite plan` generates issues from ADRs —
# the highest-stakes reasoning stage (it must honor ADRs and never hallucinate
# fixtures), so it defaults to opus. Its OWN var, independent of RITE_REVIEW_MODEL:
# moving review off opus must not silently downgrade planning. Before this var
# existed, plan-issues.sh passed "" and rode RITE_REVIEW_MODEL invisibly.
RITE_PLAN_MODEL=claude-opus-4-8

# Documentation assessment outer timeout (seconds).
# Caps the total wall-clock wait for the post-merge doc assessment subprocess.
# With doc_assessment on sonnet: typical ~90-120s (fan-out ~30s, reconcile ~30s,
# validate ~30s). 300s gives headroom for big diffs without firing on normal runs.
# If the timeout fires, completed sub-assessments are preserved; incomplete ones
# are skipped. Doc updates are not a merge blocker.
RITE_DOC_ASSESSMENT_TIMEOUT=300
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

## Sensitivity Patterns (`.rite/blockers.conf`)

These patterns control which file paths trigger review sensitivity hints. When matched, the review prompt gets targeted guidance for that area (e.g., "verify no changes to authentication flow"). They do not block merges.

```bash
BLOCKER_INFRASTRUCTURE_PATHS="(cdk|cloudformation|terraform|pulumi)"
BLOCKER_MIGRATION_PATHS="(prisma/migrations|migrations/|alembic/)"
BLOCKER_AUTH_PATHS="(auth|cognito|jwt|oauth|session)"
```

The `BLOCKER_` variable prefix is a legacy name — these patterns now drive review focus, not merge gates.

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
| `RITE_MAX_SESSION_HOURS` | Max **cumulative active work** hours per session (not wall-clock). Fires when the sum of per-issue tracked durations crosses this threshold. A zombie state file from a prior run contributes 0 to this counter. | `12` |
| `RITE_MAX_ISSUE_HOURS` | Max hours for a **single issue**. Fires when a single `rite N` invocation exceeds this threshold — protects against fix-loop runaway and yak-shaves. | `4` |
| `RITE_MAX_RETRIES` | Fix loop attempts | `3` |
| `RITE_ASSESSMENT_TIMEOUT` | Claude assessment timeout (seconds) for the review-issue assessment phase | `300` |
| `RITE_PLAN_MODEL` | Claude model for `rite plan` issue generation. Defaults to opus: planning is the highest-stakes reasoning stage (honor ADRs, don't hallucinate fixtures). Its own var, fully independent of `RITE_REVIEW_MODEL` — so moving review off opus can't silently downgrade planning. | `claude-opus-4-8` |
| `RITE_DOC_ASSESSMENT_MODEL` | Claude model for doc assessment tasks (security, arch, api, ADR reconciliation). Defaults to sonnet: doc reconciliation is structured pattern matching ("did this diff change API surface X?"), sonnet's sweet spot. Fully independent of `RITE_REVIEW_MODEL` — changing one does not affect the other. Override to `claude-opus-4-8` only if you need deeper reasoning on unusually large diffs. | `claude-sonnet-4-6` |
| `RITE_TRIAGE_MODEL` | Claude model for narrow classification (trivial-vs-substantive diff triage; doc auto-discovery categorization). Defaults to haiku: bucket classification, not deep reasoning. Independent of every other model var. | `claude-haiku-4-5` |
| `RITE_DOC_ASSESSMENT_TIMEOUT` | Outer wall-clock cap (seconds) on the post-merge doc assessment subprocess. With doc_assessment on sonnet: typical ~90-120s (4 parallel sub-assessments ~30s + reconcile ~30s + validate ~30s). 300s provides headroom for big diffs and slow API responses without firing on normal runs. On timeout: completed sub-assessments are preserved and reported; incomplete ones are skipped. Workflow continues regardless. | `300` |
| `RITE_AWS_PROFILE` | AWS profile for notifications | `default` |
| `RITE_BIN_DIR` | Override symlink location | `~/.local/bin` |
| `RITE_LOCK_DIR` | Directory for per-issue lock files. **Must be local storage** — stale lock reclamation uses `kill -0` which is only valid within a single host/PID namespace. Do not point this at NFS/shared storage. | `$RITE_PROJECT_ROOT/.rite/locks` |
| `WORKFLOW_MODE` | Default workflow mode | `unsupervised` |
| `SKIP_AWS_CHECK` | Skip AWS credential checks | `false` |
| `SLACK_WEBHOOK` | Slack webhook for notifications | — |
| `RITE_EMAIL_FROM` | Email sender for notifications | — |
| `RITE_SNS_TOPIC_ARN` | AWS SNS topic for SMS | — |

### Session limit semantics (issue #283)

Two separate caps protect against runaway LLM usage:

**`RITE_MAX_ISSUE_HOURS`** (per-issue cap, default: 4h)
Fires when a single issue has been running longer than this threshold. Indicates Claude is likely stuck in a fix loop or yak-shave. Message: `"Issue #N has been running >4h — likely stuck in fix loop or yak-shave."` To continue: `rite N --bypass-blockers`.

**`RITE_MAX_SESSION_HOURS`** (cumulative cap, default: 12h)
Fires when the sum of per-issue tracked durations in this session crosses this threshold. "Cumulative active work" means the sum of `end_time - start_time` for each issue that ran in this invocation. Wall-clock age of the session state file does NOT count — a 40-hour-old zombie state file from a prior crash contributes 0 to this counter.

Example scenarios:
- 3 issues × 2h each = 6h cumulative → no cap (< 12h)
- 1 issue running for 5h → per-issue cap fires (> 4h)
- 6 issues × 2h each = 12h cumulative → session cap fires on the 7th issue
- Zombie state file from 2 days ago + fresh invocation → 0h cumulative, no cap fires

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
