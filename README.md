# 🦈 Sharkrite

**Automate your GitHub workflow end-to-end with Claude Code.**

Sharkrite takes a GitHub issue and runs the full development lifecycle — branch, develop, PR, review, fix, merge — so you can focus on architecture, not plumbing.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What it does

```
rite 42
```

That's it. Sharkrite will:

1. Create an isolated worktree and branch for the issue
2. Invoke Claude Code with full project context and security findings
3. Create a PR with acceptance criteria from the issue
4. Generate a code review, then assess findings by severity
5. Auto-fix critical issues (up to 3 cycles)
6. Merge when clean, save security findings for next time

In supervised mode, you approve each step. In auto mode, it runs unattended. Something go wrong? `rite 42 --undo` rolls back the PR, branch, and worktree.

---

## Quick start

### Prerequisites

- [git](https://git-scm.com/)
- [gh](https://cli.github.com/) — GitHub CLI
- [jq](https://jqlang.github.io/jq/) — JSON processor
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`

### Install

```bash
git clone https://github.com/lifeunsubscribe/sharkrite.git /tmp/sharkrite
cd /tmp/sharkrite && ./install.sh
```

### Initialize a project

```bash
cd your-repo
rite --init
```

This creates a `.rite/` directory with default config and a scratchpad for tracking security findings across PRs.

---

## Usage

```bash
# Full lifecycle — issue to merge (unsupervised by default)
rite 42

# Supervised mode — approve each phase
rite 42 --supervised

# Quick mode — develop + PR only, skip review/merge
rite 42 --quick

# Batch process multiple issues
rite 21 45 31

# Run by PR number (resolves linked issue)
rite --pr 72

# Auto-discover and process security follow-ups
rite --followup

# Undo a workflow — close PR, clean up branches and worktree
rite 42 --undo

# Dry run — see what would happen
rite 42 --dry-run
```

---

## How it works

```
         ┌─────────────────────────────────────┐
         │            rite 42                   │
         └──────────────┬──────────────────────┘
                        ▼
              ┌─────────────────┐
              │  Pre-flight     │  Validate credentials,
              │  checks         │  check session limits
              └────────┬────────┘
                       ▼
              ┌─────────────────┐
              │  Development    │  Claude Code works in
              │  (worktree)     │  isolated worktree with
              │                 │  scratchpad context
              └────────┬────────┘
                       ▼
              ┌─────────────────┐
              │  PR creation    │  Push commits, create PR,
              │  + review       │  generate code review
              └────────┬────────┘
                       ▼
              ┌─────────────────┐     ┌──────────────┐
              │  Review         │────▶│  Fix loop     │
              │  assessment     │     │  (up to 3x)   │
              │                 │◀────│               │
              └────────┬────────┘     └──────────────┘
                       ▼
              ┌─────────────────┐
              │  Merge +        │  Save security findings,
              │  cleanup        │  clean worktree
              └─────────────────┘
```

### Review assessment

Sharkrite categorizes every review finding:

- **ACTIONABLE_NOW** — Fix in this PR cycle (security issues, bugs)
- **ACTIONABLE_LATER** — Valid but deferred to a follow-up issue
- **DISMISSED** — Not worth tracking (style preferences, theoretical edge cases)

Critical findings trigger an automatic fix loop. Medium findings become follow-up GitHub issues. Low findings are batched into a single cleanup issue.

---

## Configuration

Layered config system — global defaults, project overrides, environment variables:

```
~/.config/rite/config  →  .rite/config  →  ENV vars
```

### Key settings

| Setting | Default | Description |
|---------|---------|-------------|
| `RITE_MAX_ISSUES_PER_SESSION` | 8 | Session issue limit |
| `RITE_MAX_SESSION_HOURS` | 4 | Session time limit |
| `RITE_MAX_RETRIES` | 3 | Fix loop attempts |
| `RITE_ASSESSMENT_TIMEOUT` | 300s | Claude assessment timeout |
| `WORKFLOW_MODE` | unsupervised | `supervised` or `unsupervised` |

See [config/project.conf.example](config/project.conf.example) for all options, or [docs/configuration.md](docs/configuration.md) for the full reference.

---

## Safety

Sharkrite uses a two-tier safety system: review sensitivity hints that sharpen the review, and hard gates that stop the merge.

### Review sensitivity

When changed files match sensitive patterns (auth, infrastructure, migrations, docs, expensive services, workflow scripts), the review prompt gets targeted guidance — "verify no changes to authentication flow" instead of a generic review. This makes the review more thorough without interrupting the workflow.

Patterns are configurable in `.rite/blockers.conf`. See [docs/configuration.md](docs/configuration.md) for details.

### Hard merge gates

Only content-aware conditions block a merge:

- **Critical review findings** — CRITICAL severity issues must be fixed or approved
- **Test/build failures** — non-zero exit from test suite
- **Session limits** — configurable issue count and time limits
- **AWS credentials expired** — deployment credentials invalid

### Security feedback loop

Security findings persist across PRs via the scratchpad:

```
PR review finds issue → saved to scratchpad → next Claude Code session
loads scratchpad → avoids repeating the same pattern
```

The last 5 PRs stay in "Recent Findings." The last 20 are archived.

---

## Project structure

```
sharkrite/
├── bin/rite                     # CLI entry point
├── lib/
│   ├── core/                    # Workflow phases
│   │   ├── workflow-runner.sh   # Central orchestrator
│   │   ├── claude-workflow.sh   # Claude Code development
│   │   ├── create-pr.sh        # PR creation + review
│   │   ├── local-review.sh     # Local review generation
│   │   ├── assess-and-resolve.sh
│   │   ├── assess-review-issues.sh
│   │   ├── assess-documentation.sh
│   │   ├── merge-pr.sh         # Merge + scratchpad update
│   │   └── batch-process-issues.sh
│   └── utils/                   # Shared libraries
│       ├── config.sh            # Layered config loader
│       ├── blocker-rules.sh     # Hard gates + review sensitivity
│       ├── scratchpad-manager.sh
│       ├── session-tracker.sh
│       └── ...
├── config/                      # Example configs
├── templates/                   # Init templates
├── docs/                        # Extended documentation
├── install.sh
└── uninstall.sh
```

---

## Uninstall

```bash
~/.rite/uninstall.sh
# Or from source:
./uninstall.sh
```

Removes runtime files and symlink. Prompts before removing config. Never touches project `.rite/` directories.

---

## Contributing

See [CONTRIBUTIONS.md](CONTRIBUTIONS.md).

```bash
git clone https://github.com/lifeunsubscribe/sharkrite.git
cd sharkrite
./install.sh  # Symlinks for live editing
```

---

## License

[MIT](LICENSE) — Sarah Wadley
