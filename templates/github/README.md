# GitHub Workflows

Automated workflows for Claude Code integration with Forge.

## Workflows

### claude-code-review.yml
Automatic PR reviews using Claude Code Action.

**Triggers:** PR opened or updated
**Output:** Structured review with CRITICAL/HIGH/MEDIUM/LOW findings
**Used by:** Forge's assess-and-resolve flow

### claude-interactive.yml (optional)
Respond to @claude mentions in issues and PR comments.

### pr-merged-notification.yml (optional)
Send Slack notifications when PRs are merged.

## Setup

1. Install Claude GitHub App on your repo
2. Get OAuth token: `claude auth login --github`
3. Add `CLAUDE_CODE_OAUTH_TOKEN` to repo Settings > Secrets > Actions
4. (Optional) Add `SLACK_WEBHOOK` secret for merge notifications

## Customization

Edit `.github/claude-code/pr-review-instructions.md` to customize:
- Severity criteria
- Review focus areas
- Project-specific checks

As your project grows, Forge can automatically append theme-specific checks
(multi-tenant, AWS patterns, compliance requirements, etc.)

## Troubleshooting

**Reviews not appearing?**
- Token may have expired (~90 days) -- regenerate it
- Check workflow ran in Actions tab
- Verify `pull-requests: write` permission is set

**Wrong severity classifications?**
- Edit pr-review-instructions.md to adjust criteria
- Run `rite config --themes` to see detected patterns
