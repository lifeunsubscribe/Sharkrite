# Sharkrite Development Guide

AI-powered GitHub workflow automation CLI. Pure bash, uses Claude Code for development and review.

**Mako** — the Claude Code assistant for this repo. Named after the fastest shark.

## Architecture

```
bin/rite                          # CLI entrypoint (arg parsing, dispatch)
lib/core/workflow-runner.sh       # Main orchestrator (phases 1-5, retry loop)
lib/core/claude-workflow.sh       # Claude Code session (dev work + fix mode)
lib/core/create-pr.sh             # PR creation, push, early sensitivity detection
lib/core/local-review.sh          # Generate code review via Claude
lib/core/assess-review-issues.sh  # Three-state assessment (NOW/LATER/DISMISSED)
lib/core/assess-and-resolve.sh    # Review loop driver (calls assess, decides action)
lib/core/merge-pr.sh              # Merge PR, cleanup worktree
lib/utils/blocker-rules.sh        # Hard gates + review sensitivity detection
lib/utils/config.sh               # Config loading, path setup
lib/utils/divergence-handler.sh   # Branch divergence detection, classification, resolution
lib/utils/pr-detection.sh         # PR/worktree/review state detection utilities
lib/utils/repo-status.sh          # Repo-wide status display (worktrees, phases, issues)
lib/utils/scratchpad-manager.sh   # Scratchpad lifecycle (security findings, encountered issues)
lib/utils/stale-branch.sh        # Stale branch detection, merge-main or close-and-restart
```

### Workflow Phases

1. **Development** — Claude implements the fix in a worktree
2. **Push/PR** — Push commits, create/update PR, detect review sensitivity areas
3. **Review/Assess Loop** — Generate review, assess findings, fix ACTIONABLE_NOW items (up to 3 retries)
4. **Merge** — Hard gate (CRITICAL findings only), then merge PR
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

## Safety System

Two-tier approach: review sensitivity hints + hard merge gates.

### Review Sensitivity Hints (path-based)

Path-based detectors (infrastructure, migrations, auth, docs, expensive services, protected scripts) inject focused review guidance into the review prompt. They do NOT block merges.

- Detected in `create-pr.sh` early checks (informational)
- Injected into review prompt by `local-review.sh` via `detect_sensitivity_areas()`
- Patterns configured in `.rite/blockers.conf` (same `BLOCKER_*` variables)

### Hard Merge Gates (content-aware)

Only content-aware and practical conditions block merges:

- **CRITICAL review findings** — requires fix or approval
- **Test/build failures** — non-zero exit from test suite
- **Session limits** — token/time limits reached
- **AWS credentials expired** — deployment credentials invalid
- **Supervised mode**: Interactive `read -p` prompt for approval
- **Unsupervised mode**: Stops workflow (unless `--bypass-blockers`)
- Approvals remembered per-issue via `has_approved_blocker()`

### Stale Branch Handling

When resuming an issue with an existing PR, the branch is checked against `origin/main`. Controlled by `RITE_STALE_BRANCH_THRESHOLD` (default: 10 commits).

- **Below threshold**: Merge `origin/main` into the feature branch (like GitHub "Update branch"), push. No force-push needed since history isn't rewritten. The final merge is a squash anyway.
- **At/above threshold (auto)**: Close PR with summary comment, cleanup branch/worktree, continue workflow fresh (no restart needed — falls through to development phase).
- **At/above threshold (supervised)**: Prompt with 4 options (restart recommended, merge, continue, abort).

Check runs in `workflow-runner.sh` after PR/worktree detection, before phase-skip logic. Returns exit code 10 to signal "restarted fresh" — caller resets all resume state variables.

## Phase Commands

Individual workflow phases can be run standalone via flags. All default to auto/unsupervised mode.

```bash
rite 42                    # Full lifecycle (phases 1-5)
rite 42 --status           # Read-only: show workflow state overview for issue
rite --status              # Repo-wide: worktrees, open issues with phases, recently closed
rite --status --by-label   # Repo-wide status grouped by label
rite 42 --dev-and-pr       # Phase 1-2: dev + PR only, skip review/merge
rite 42 --review-latest    # Phase 2 (review only): generate + post review
rite 42 --assess-and-fix   # Phase 3: assess review + fix loop (up to 3 retries)
rite 42 --undo             # Cleanup: close PR, delete branch/worktree
```

**`--status`** (per-issue) shows issue state, PR stats (files/lines/commits), review currency, assessment counts, follow-up issues, session state, logs, and suggests the next command to run.

**`--status`** (repo-wide, no issue number) shows all worktrees with staleness, open issues with workflow phase (Not started, Dev/PR, Needs review, Review stale, Needs fixes, Ready to merge), and recently closed issues with close dates. Use `--by-label` to group open issues by label.

**`--review-latest`** checks review staleness: no review → generates; stale → regenerates; current → prints existing review and exits (in supervised mode, prompts to re-review).

**`--assess-and-fix`** requires a current review. Handles the full fix loop internally: assess → fix → push → re-review → re-assess. Creates follow-up issues for ACTIONABLE_LATER items.

The full `rite <issue>` resume correctly detects state (via PR comments/commits) and skips completed phases, so running standalone commands then resuming with the full lifecycle works seamlessly.

### PR Detection (`lib/utils/pr-detection.sh`)

Shared utilities used by standalone commands and the orchestrator:

- `detect_pr_for_issue ISSUE_NUMBER` — finds PR by body text search (Closes #N)
- `detect_worktree_for_pr PR_NUMBER` — finds local worktree for PR branch
- `detect_review_state PR_NUMBER [WORKTREE_PATH]` — checks review existence and currency

Uses local git timestamps when worktree is available (avoids GitHub API eventual consistency).

## Follow-up Issue Template

Follow-up issues (tech-debt, review follow-ups) follow the structure in `templates/issue-template.md`:

- **Claude Context**: Changed files from the PR (auto-populated)
- **Acceptance Criteria**: Item-specific from assessment (e.g., `[HIGH] Fix input validation`)
- **Done Definition**: Generated from severity mix
- **Scope Boundary**: Static DO/DO NOT (address findings only)
- **Time Estimate**: Aggregated from Fix Effort metadata in assessment

**Note:** The template is a reference document. `assess-and-resolve.sh` and `assess-review-issues.sh` hardcode the issue body structure inline rather than loading the template file. `rite --init` copies it to `.rite/issue-template.md` but nothing reads it back. Customizing the local copy has no effect yet.

## Testing

```bash
# Install locally for testing
./install.sh

# Symlink for live editing
rm -rf ~/.rite/lib && ln -s $(pwd)/lib ~/.rite/lib

# Dry run
rite --dry-run

# Check issue state before running
rite 42 --status

# Test individual phases
rite 42 --dev-and-pr       # Dev + PR only
rite 42 --review-latest    # Review only
rite 42 --assess-and-fix   # Assess + fix loop

# Test full lifecycle
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

## Git Commits

- **No co-author lines.** Do not add `Co-Authored-By` to commit messages.

## Common Pitfalls

- **Subshell variable loss**: Variables set inside `while read | pipe` are lost. Use process substitution or temp files.
- **BSD vs GNU date**: macOS uses BSD date. Always handle both with `if date --version` detection.
- **PR comment markers**: Use `contains("<!-- sharkrite-local-review")` (no closing `-->`) because markers include attributes like `model:opus timestamp:...`.
- **Exit codes**: `assess-and-resolve.sh` uses exit 0 for "ready to merge", exit 1 for "manual intervention needed", exit 2 for "loop to fix", exit 3 for "review stale — route back to Phase 2".
- **RITE_ORCHESTRATED**: When `workflow-runner.sh` calls `claude-workflow.sh`, it sets `RITE_ORCHESTRATED=true`. This tells `claude-workflow.sh` to skip its internal PR/review workflow (create-pr.sh call) — those are handled by the orchestrator's Phase 2/3. Without this, reviews get generated twice.
- **Encountered Issues**: When discovering out-of-scope issues during development, follow the protocol in `docs/architecture/encountered-issues-system.md`
