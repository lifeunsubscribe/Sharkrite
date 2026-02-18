# Troubleshooting

## "AWS credentials expired"

```bash
aws sso login --profile your-profile
```

Or skip AWS checks entirely for non-AWS projects:
```bash
# In .rite/config
SKIP_AWS_CHECK=true
```

## "Session limit reached"

```bash
# Check session state
cat .rite/session-state/current-session.json

# Clear manually (auto-resets after timeout)
rm .rite/session-state/current-session.json
```

## "Worktree limit exceeded"

```bash
# Auto-cleanup merged branches
rite cleanup-worktrees

# Or manual
git worktree list
git worktree remove /path/to/stale-worktree
```

## "Blocker detected"

In supervised mode, you'll be prompted to approve or reject.

In unsupervised mode, the workflow stops. Use `--bypass-blockers` to continue (sends Slack warnings):
```bash
rite 42 --bypass-blockers
```

## "PR review not found"

- Check Claude CLI is authenticated (`claude`)
- Review may still be running — check logs for progress
- Check PR status: `gh pr view <PR_NUMBER>`

## Uninstall

```bash
~/.rite/uninstall.sh
# Or if you have the source:
./uninstall.sh
```

Removes runtime files and symlink. Prompts before removing config. Never touches project `.rite/` directories.

## Smart Worktree Management

Sharkrite manages worktrees automatically:

- **Auto-detect**: Finds existing worktree for an issue
- **Auto-navigate**: Switches to correct worktree
- **Auto-stash**: Stashes changes before navigation, pops when returning
- **Auto-cleanup**: Removes merged branches at limit
