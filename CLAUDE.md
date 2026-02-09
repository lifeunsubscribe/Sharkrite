# Sharkrite Development Guide

AI-powered GitHub workflow automation CLI. Pure bash, uses Claude Code for development and review.

## Architecture

```
bin/rite                          # CLI entrypoint (arg parsing, dispatch)
lib/core/workflow-runner.sh       # Main orchestrator (phases 1-5, retry loop)
lib/core/claude-workflow.sh       # Claude Code session (dev work + fix mode)
lib/core/create-pr.sh             # PR creation, push, early blocker warnings
lib/core/local-review.sh          # Generate code review via Claude
lib/core/assess-review-issues.sh  # Three-state assessment (NOW/LATER/DISMISSED)
lib/core/assess-and-resolve.sh    # Review loop driver (calls assess, decides action)
lib/core/merge-pr.sh              # Merge PR, cleanup worktree
lib/utils/blocker-rules.sh        # Blocker detection functions
lib/utils/config.sh               # Config loading, path setup
```

### Workflow Phases

1. **Development** — Claude implements the fix in a worktree
2. **Push/PR** — Push commits, create/update PR, print blocker warnings
3. **Review/Assess Loop** — Generate review, assess findings, fix ACTIONABLE_NOW items (up to 3 retries)
4. **Merge** — Blocker gate (requires approval), then merge PR
5. **Completion** — Notifications, cleanup

### Data Flow

- `assess-review-issues.sh` outputs assessment to **stdout** (pipe-friendly)
- `assess-and-resolve.sh` captures stdout, decides to loop (exit 2) or merge (exit 0)
- `workflow-runner.sh` captures exit codes and stdout to pass review content to fix mode
- **stderr** is used for all user-facing output (print_info, print_warning, etc.)

## Shell Conventions

### grep -c pattern (CRITICAL)

`grep -c` always outputs a count (even "0") but returns exit code 1 when count is 0.

```bash
# BAD: produces "0\n0" (grep outputs "0", then || echo "0" adds another)
COUNT=$(echo "$text" | grep -c "pattern" || echo "0")

# GOOD: grep -c already outputs the count, just suppress the exit code
COUNT=$(echo "$text" | grep -c "pattern" || true)
```

`grep -o` is different — it outputs nothing on no match, so `|| echo "0"` is correct there.

### Structured header matching (CRITICAL)

Assessment output uses `### Title - STATE` format. Always match the structured header, never bare keywords.

```bash
# BAD: matches "ACTIONABLE_NOW" anywhere, including reasoning text like
# "This was the previous ACTIONABLE_NOW item that was fixed"
COUNT=$(echo "$output" | grep -c "ACTIONABLE_NOW" || true)

# GOOD: matches only the structured classification headers
COUNT=$(echo "$output" | grep -c "^### .* - ACTIONABLE_NOW" || true)
```

### Review severity parsing

The review outputs a `Findings: [CRITICAL: N | HIGH: N | ...]` summary line. Parse that instead of broad keyword matching.

```bash
# BAD: "CRITICAL:" matches metadata lines like "Findings: [CRITICAL: 0 | ...]"
COUNT=$(echo "$output" | grep -ciE "CRITICAL:" || true)

# GOOD: parse the structured Findings line
FINDINGS=$(echo "$output" | grep -oE "CRITICAL: [0-9]+ \| HIGH: [0-9]+" | head -1)
```

### .gitignore and symlinks

Use `.rite` (no trailing slash). `.rite/` only matches directories, but in worktrees `.rite` is a symlink (git mode 120000 = file).

## Blocker System

Blockers detect risky changes (auth, infra, migrations, etc.) and require human approval.

- **Early warning** in `create-pr.sh`: Non-blocking, just prints what was detected
- **Gate** in `phase_merge_pr`: Blocking, requires approval before merge proceeds
- **Supervised mode**: Interactive `read -p` prompt for approval
- **Unsupervised mode**: Stops workflow (unless `--bypass-blockers`)
- Approvals are remembered per-issue via `has_approved_blocker()`

## Testing

```bash
# Install locally for testing
./install.sh

# Symlink for live editing
rm -rf ~/.rite/lib && ln -s $(pwd)/lib ~/.rite/lib

# Dry run
rite --dry-run

# Test single phase
rite 42 --supervised
```

## Claude Session Prompt Design (CRITICAL)

The prompt passed to Claude Code in `claude-workflow.sh` must include:

1. **Sharkrite identity** — Claude doesn't know what tool invoked it. Without explicit context, it hallucinates names like "forge". The prompt must state: "You are running inside a Sharkrite (`rite`) workflow session."
2. **Git/GH prohibition** — Claude must NOT run `git commit`, `git push`, `gh pr create`, etc. The post-workflow script handles all of this. Enforce via **both** prompt instructions AND `--disallowedTools`. Prompt-only prohibition is insufficient — Claude ignores it. `--disallowedTools` is enforced by the CLI and cannot be bypassed. Both the main dev session and fix-review session must use it.
3. **Explicit exit instructions** — In supervised mode, Claude runs interactively and will sit idle forever after completing work unless told to `/exit`. Auto mode uses `--print` which auto-exits.
   - Supervised: "When all phases are complete, immediately exit with `/exit`"
   - Auto: `--print` handles exit; prompt says "session will end automatically"
4. **No "Ready to start?" or open-ended questions at end** — The prompt should end with a directive ("Begin with Phase 0"), not a question that invites Claude to wait for confirmation.

## Common Pitfalls

- **Subshell variable loss**: Variables set inside `while read | pipe` are lost. Use process substitution or temp files.
- **BSD vs GNU date**: macOS uses BSD date. Always handle both with `if date --version` detection.
- **PR comment markers**: Use `contains("<!-- sharkrite-local-review")` (no closing `-->`) because markers include attributes like `model:opus timestamp:...`.
- **Exit codes**: `assess-and-resolve.sh` uses exit 2 for "loop to fix", exit 0 for "ready to merge", exit 1 for "manual intervention needed".
- **RITE_ORCHESTRATED**: When `workflow-runner.sh` calls `claude-workflow.sh`, it sets `RITE_ORCHESTRATED=true`. This tells `claude-workflow.sh` to skip its internal PR/review workflow (create-pr.sh call) — those are handled by the orchestrator's Phase 2/3. Without this, reviews get generated twice.
