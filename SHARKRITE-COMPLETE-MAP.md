# Sharkrite Codebase - Complete Module Map

**Project:** AI-powered GitHub workflow automation CLI  
**Language:** Pure bash, uses Claude Code for development and review  
**Root:** `/Users/sarahtime/Dev/sharkrite`  
**Total Lines:** ~24,000 (production code)  
**Generated:** 2026-05-26  

---

## Table of Contents

1. [Directory Structure](#directory-structure)
2. [Entry Points](#entry-points)
3. [Core Modules](#core-modules)
4. [Utility Modules](#utility-modules)
5. [Provider Modules](#provider-modules)
6. [Configuration Variables](#configuration-variables)
7. [Workflow Phases](#workflow-phases)
8. [Source Dependencies](#source-dependencies)
9. [Data Flow Patterns](#data-flow-patterns)
10. [Safety System](#safety-system)
11. [Critical Shell Conventions](#critical-shell-conventions)

---

## Directory Structure

### bin/ (1,629 lines)
**Purpose:** CLI entrypoints and executables

- `rite` (1,355 lines) - Primary CLI dispatcher
- `rite-health-report` (274 lines) - Operational health reporting

### lib/core/ (14,928 lines)
**Purpose:** Workflow orchestration and phase execution

12 core modules implementing workflow phases 1-5:
- `workflow-runner.sh` (2,263) - Main orchestrator
- `claude-workflow.sh` (2,638) - Dev/fix sessions
- `plan-issues.sh` (2,033) - Issue generation
- `merge-pr.sh` (1,573) - PR merge & cleanup
- `batch-process-issues.sh` (1,304) - Batch orchestration
- `assess-and-resolve.sh` (1,222) - Review assessment driver
- `assess-documentation.sh` (1,065) - Doc assessment
- `assess-review-issues.sh` (1,013) - Core assessment logic
- `bootstrap-docs.sh` (551) - Doc setup
- `undo-workflow.sh` (459) - Workflow cleanup
- `local-review.sh` (418) - Review generation
- `create-pr.sh` (389) - PR creation

### lib/utils/ (7,610 lines)
**Purpose:** Shared utilities and helpers

25 utility modules for common functions:
- `config.sh` (304) - Configuration loader
- `blocker-rules.sh` (542) - Safety gates & sensitivity detection
- `divergence-handler.sh` (629) - Branch divergence handling
- `post-merge-verify.sh` (537) - Post-merge verification
- `stale-branch.sh` (427) - Stale branch detection
- `session-tracker.sh` (421) - Session state management
- `scratchpad-manager.sh` (463) - Scratchpad lifecycle
- `issue-assessor.sh` (517) - Issue classification
- `normalize-issue.sh` (408) - Input normalization
- `validate-setup.sh` (470) - Setup validation
- Plus: pr-detection, pr-summary, notifications, logging, colors, labels, timeout, etc.

### lib/providers/ (725 lines)
**Purpose:** Provider abstraction for multi-LLM support

- `provider-interface.sh` (138) - Abstraction dispatcher (17-function contract)
- `claude.sh` (392) - Claude Code provider (primary)
- `gemini.sh` (195) - Gemini provider (skeleton)

### config/ (3 example files)
- `rite.conf.example` - Global config template
- `project.conf.example` - Project config template
- `blockers.conf.example` - Blocker pattern template

### templates/ (documentation & GitHub)
- `gitignore` - .gitignore patterns
- `issue-template.md` - GitHub issue template
- `scratchpad.md` - Scratchpad template
- `github/` - PR templates, review instructions, GitHub Actions workflows

### docs/ (architecture & guides)
- `architecture/behavioral-design.md` - Design decisions & behavioral contracts
- `architecture/encountered-issues-system.md` - Out-of-scope issue handling
- `configuration.md` - Configuration guide
- `review-system.md` - Review architecture
- `issue-runbook.md` - Issue structure guide
- `troubleshooting.md` - Troubleshooting guide
- `research/rtk-assessment.md` - Token optimization research

---

## Entry Points

### bin/rite (1,355 lines)

**Primary CLI dispatcher with modes:**

```
rite <issue>                Full lifecycle (default, unsupervised)
rite <issue> dev-and-pr     Phase 1-2 (dev + PR only)
rite <issue> review         Phase 2 (generate review)
rite <issue> assess         Phase 3 (assess + fix loop, up to 3 retries)
rite <issue> status         Read-only workflow state
rite <issue> undo           Cleanup (close PR, delete artifacts)
rite status                 Repo-wide status overview
rite status --by-label      Status grouped by label
rite plan [doc]             Generate issues from architectural doc
rite init                   Initialize .rite/ in project
rite health-report          Operational health report
rite --dry-run <...>        Print plan without executing
rite "description"          Create issue from multi-word description
```

**Flags:**
- `--supervised` - Interactive mode (approve gates manually)
- `--auto` - Unsupervised mode (default)
- `--bypass-blockers` - Skip hard merge gates (unsupervised only)
- `--verbose` - Extra detail
- `--no-log` - Disable logging
- `--log=FILE` - Custom log path
- `--pr NUMBER` - Run by PR number instead of issue
- `--dry-run` - Print execution plan

**Config loading order (highest priority wins):**
1. Environment variables (RITE_*)
2. Project config (~/.rite/config)
3. Global config (~/.config/rite/config, ~/.riterc)
4. Defaults (defined in lib/utils/config.sh)

### bin/rite-health-report (274 lines)

**Operational health report generation**

```
rite health-report          Generate and display now
rite health-report --latest Show most recent report
rite --rtk-report           Alias for health-report
```

Collects diagnostic logs, rtk stats, recent changes.  
Runs as launchd job on Mondays at 9:07 AM.

---

## Core Modules (lib/core/)

### workflow-runner.sh (2,263 lines)

**Main orchestrator, phases 1-5, retry loop**

Entry point for full lifecycle workflows. Coordinates all phases.

**Phases:**
1. Development (claude-workflow.sh)
2. Push/PR + Review (create-pr.sh, local-review.sh)
3. Assessment loop (assess-and-resolve.sh)
4. Merge (merge-pr.sh)
5. Completion (notifications, cleanup)

**Sources:** colors, logging, notifications, blocker-rules, session-tracker, pr-summary, normalize-issue, pr-detection, issue-assessor, gh-retry, provider-interface

### claude-workflow.sh (2,638 lines)

**Claude Code session (dev work + fix mode)**

Implements Phase 1 (development) and fix-review loops.

**Modes:**
- Development: Initial implementation of issue fix
- Fix-review: Responds to assessment findings, up to 3 iterations

**Sources:** session-tracker, issue-assessor, provider-interface, logging

**Key:** Runs Claude Code agentic sessions with tool restrictions (no git commit, gh pr create, etc.)

### assess-and-resolve.sh (1,222 lines)

**Review loop driver, three-state assessment**

Calls assess-review-issues.sh, routes based on findings:
- ACTIONABLE_NOW: Loop (fix), retry up to 3 times
- ACTIONABLE_LATER: Create follow-up issue
- DISMISSED: Ready to merge

**Sources:** colors, logging, blocker-rules, provider-interface

### batch-process-issues.sh (1,304 lines)

**Batch processing for multiple issues**

Runs workflow-runner.sh sequentially for each issue.

Filters issues by:
- Explicit list: `rite 1 2 3 4 5`
- Label: `rite --label tech-debt`
- Max 8 per session (RITE_MAX_ISSUES_PER_SESSION)

### create-pr.sh (389 lines)

**PR creation, push, early sensitivity detection**

Phase 2: Creates/updates PR on GitHub, detects sensitive changes.

### local-review.sh (418 lines)

**Generate code review via Claude**

Phase 2b: Generates focused review comment on PR.

**Sources:** colors, logging, blocker-rules, provider-interface

Injects sensitivity hints from blocker detection.

### assess-review-issues.sh (1,013 lines)

**Three-state assessment of review findings**

Core assessment logic. Outputs to stdout (pipe-friendly).

**States:**
- `### Issue Title - ACTIONABLE_NOW` - Fix immediately
- `### Issue Title - ACTIONABLE_LATER` - Create follow-up
- `### Issue Title - DISMISSED` - Not relevant

**Sources:** colors, logging

### merge-pr.sh (1,573 lines)

**PR merge, cleanup worktree, post-merge verification**

Phase 5: Merges PR, runs post-merge tests, deletes worktree.

### plan-issues.sh (2,033 lines)

**Issue generation from architectural docs**

Analyzes architectural docs (ADRs, design docs, roadmaps).  
Claude generates structured issues, user approves/adjusts, creates on GitHub.

**Supports:** Natural language filtering, preview mode, customizable time estimates.

### undo-workflow.sh (459 lines)

**Workflow cleanup: close PR, delete branch/worktree**

Reverses workflow changes for restarting.

### assess-documentation.sh (1,065 lines)

**Assessment of documentation changes**

Checks for doc consistency, completeness, relevance.

### bootstrap-docs.sh (551 lines)

**Documentation setup for new projects**

Initializes doc structure, creates internal docs directory.

---

## Utility Modules (lib/utils/)

### config.sh (304 lines)

**Configuration loader with priority cascade**

**Variables defined:**

**Paths & Directories:**
- `RITE_PROJECT_ROOT` = $(git rev-parse --show-toplevel)
- `RITE_PROJECT_NAME` = $(basename $RITE_PROJECT_ROOT)
- `RITE_INSTALL_DIR` = $HOME/.rite
- `RITE_LIB_DIR` = $RITE_INSTALL_DIR/lib
- `RITE_DATA_DIR` = .rite
- `RITE_WORKTREE_BASE` = $HOME/Dev/rite-wt
- `RITE_WORKTREE_DIR` = $RITE_WORKTREE_BASE/<abbrev>-wt
- `RITE_INTERNAL_DOCS_DIR` = $RITE_PROJECT_ROOT/.rite/docs
- `SCRATCHPAD_FILE` = $RITE_PROJECT_ROOT/.rite/scratch.md
- `SESSION_STATE_FILE` = /tmp/rite-session-state-<project-name>.json

**Session Limits:**
- `RITE_MAX_ISSUES_PER_SESSION` = 8
- `RITE_MAX_SESSION_HOURS` = 4
- `RITE_MAX_RETRIES` = 3
- `RITE_ASSESSMENT_TIMEOUT` = 120 (seconds)
- `RITE_STALE_BRANCH_THRESHOLD` = 10 (commits)

**Workflow Mode:**
- `WORKFLOW_MODE` = supervised

**Notifications (opt-in):**
- `RITE_NOTIFICATIONS` = false
- `RITE_AWS_PROFILE` = default
- `RITE_SNS_TOPIC_ARN` = ""
- `RITE_EMAIL_FROM` = ""
- `SLACK_WEBHOOK` = ""
- `EMAIL_NOTIFICATION_ADDRESS` = ""

**Models & Timeout:**
- `RITE_CLAUDE_TIMEOUT` = 7200 (seconds, 2 hours)
- `RITE_CLAUDE_MODEL` = claude-sonnet-4-5 (dev)
- `RITE_REVIEW_MODEL` = claude-opus-4-5 (review)

**Providers (per-phase):**
- `RITE_DEV_PROVIDER` = claude (agentic dev/fix)
- `RITE_REVIEW_PROVIDER` = claude (reviews, assessments)
- `RITE_UTILITY_PROVIDER` = claude (classify, normalize, health)
- `RITE_GEMINI_DEV_MODEL` = gemini-2.5-pro
- `RITE_GEMINI_REVIEW_MODEL` = gemini-2.5-pro

**Planning:**
- `RITE_PLAN_DOCS` = "" (space-separated project-relative paths)
- `RITE_PLAN_MAX_ESTIMATE` = 2hr

**Testing:**
- `RITE_SKIP_TESTS` = false
- `RITE_TEST_CMD` = "" (auto-detected)
- `RITE_TEST_TIMEOUT` = 120 (seconds)

**Project Context (for review calibration):**
- `RITE_PROJECT_CONTEXT` = "" (free-form description)

**Dry Run:**
- `RITE_DRY_RUN` = false (parsed before config)

**Blocker Patterns:**
- `BLOCKER_INFRASTRUCTURE_PATHS` = infrastructure/|cdk/|terraform/|cloudformation/|\.github/workflows/|\.claude/
- `BLOCKER_MIGRATION_PATHS` = prisma/migrations/|migrations/|db/migrate/|alembic/
- `BLOCKER_AUTH_PATHS` = auth/|Auth|authentication|authorization|cognito|oauth
- `BLOCKER_DOC_PATHS` = Technical-Specs|Architecture|CLAUDE.md|ARCHITECTURE.md
- `BLOCKER_PROTECTED_SCRIPTS` = workflow-runner.sh|claude-workflow.sh|merge-pr.sh|create-pr.sh|batch-process-issues.sh
- `BLOCKER_EXPENSIVE_SERVICES` = \brds\b|\baurora\b|\bnatgateway\b|\bnat_gateway\b|\bec2\b|\bfargate\b|\bsagemaker\b|\bredshift\b

**Key function:** `safe_source()` - Sources config files with syntax validation.

### blocker-rules.sh (542 lines)

**Hard gates + review sensitivity detection**

**Two-tier safety:**
1. **Review Sensitivity (non-blocking):** Detected paths trigger focused review
2. **Hard Merge Gates (blocking):** CRITICAL findings, test failures, session limits

**Blocks merge if:**
- CRITICAL review findings
- Test/build failures (non-zero exit)
- Session limits exceeded
- AWS credentials expired
- Supervised mode: interactive approval required
- Unsupervised mode: stops unless `--bypass-blockers`

### pr-detection.sh (232 lines)

**PR/worktree/review state detection utilities**

**Functions:**
- `detect_pr_for_issue()` - Find open PR for issue
- `detect_worktree_for_pr()` - Find local worktree for PR branch
- `detect_review_state()` - Check review existence & currency

Uses local git timestamps when worktree available (avoids API eventual consistency).

### divergence-handler.sh (629 lines)

**Branch divergence detection, classification, resolution**

Handles stale branches:
- **Below threshold:** Auto merge origin/main into feature branch
- **At/above threshold (auto):** Close PR with summary, cleanup, restart fresh
- **At/above threshold (supervised):** Prompt with 4 options

### stale-branch.sh (427 lines)

**Stale branch detection and handling**

Threshold: `RITE_STALE_BRANCH_THRESHOLD` (default: 10 commits behind main)

### post-merge-verify.sh (537 lines)

**Post-merge test verification + failure attribution**

Runs test suite after merge, attributes failures to PR changes.

### conflict-resolver.sh (255 lines)

**Claude-assisted merge conflict resolution**

Uses Claude to resolve merge conflicts automatically.

### issue-assessor.sh (517 lines)

**Issue state classification and metadata extraction**

Extracts and classifies issue metadata for assessment and routing.

### normalize-issue.sh (408 lines)

**Issue input normalization**

**Functions:**
- `normalize_existing_issue()` - Fetch from GitHub, cleanup title
- `normalize_piped_input()` - Claude generates structured issue from text

### validate-setup.sh (470 lines)

**Project setup validation**

Checks:
- .rite/ directory structure
- Config files present
- GitHub auth
- Claude CLI available

### session-tracker.sh (421 lines)

**Session state management**

Tracks workflow progress across retries.

### scratchpad-manager.sh (463 lines)

**Scratchpad state management**

Manages findings, encountered issues, security notes.

### notifications.sh (264 lines)

**Slack/SNS/email notifications (opt-in per project)**

Opt-in via `RITE_NOTIFICATIONS=true`.

### logging.sh (217 lines)

**Structured logging with [phase], [diag] prefixes**

Used for diagnostic data aggregation in health reports.

### colors.sh (37 lines)

**ANSI color constants**

RED, GREEN, YELLOW, NC (no color).

### Other utilities:

- `repo-status.sh` (709) - Repo-wide status display
- `pr-summary.sh` (119) - PR diff/commit summary
- `gh-retry.sh` (98) - GitHub CLI retry wrapper
- `labels.sh` (33) - GitHub label management
- `review-helper.sh` (111) - Review utility functions
- `review-assessment.sh` (67) - Assessment formatting
- `cleanup-worktrees.sh` (193) - Worktree cleanup
- `format-review.sh` (230) - Review formatting
- `timeout.sh` (108) - Cross-platform timeout detection
- `create-followup-issues.sh` (219) - Generate follow-up issues

---

## Provider Modules (lib/providers/)

### provider-interface.sh (138 lines)

**Provider abstraction dispatcher**

**17-function interface contract:**
- `provider_detect_cli()` - Detect & locate CLI
- `provider_validate_cli()` - Verify auth
- `provider_run_agentic_session()` - Dev/fix sessions
- `provider_run_prompt()` - Text-in/text-out
- `provider_run_prompt_with_timeout()` - With timeout
- `provider_run_health_check()` - Health check
- `provider_check_api_quota()` - Quota monitoring
- `provider_session_preamble()` - Pre-session setup
- `provider_exit_instructions()` - Exit guidance
- `provider_dev_session_preamble()` - Dev session setup
- `provider_dev_exit_instructions()` - Dev exit guidance
- `provider_stream_format()` - Output format
- `provider_error_patterns()` - Error detection
- `provider_disallowed_tools()` - Tool restrictions
- `provider_allowed_tools()` - Tool allowlist
- `provider_get_model()` - Model info
- `provider_list_models()` - Available models

**Core function:** `load_provider(name)` aliases provider-specific functions to generic `provider_*` namespace.

### claude.sh (392 lines)

**Claude Code CLI provider (primary)**

Implements all 17 interface functions.

**Models:**
- Development: claude-sonnet-4-5 (RITE_CLAUDE_MODEL)
- Review/Assessment: claude-opus-4-5 (RITE_REVIEW_MODEL)

**CLI:** `claude` or `claude-code`

### gemini.sh (195 lines)

**Gemini CLI provider (skeleton)**

Interface contract defined, functionality TBD.

**Models:**
- gemini-2.5-pro (both dev and review)

---

## Workflow Phases

### Phase 1: Development

**Script:** lib/core/claude-workflow.sh  
**Provider:** RITE_DEV_PROVIDER (default: claude)  
**Input:** ISSUE_NUMBER, WORK_DESCRIPTION  
**Output:** Code changes in worktree  
**Exit codes:** 0 (success), 1 (fail), 5 (quota)  

Claude implements fix in agentic session. Can loop if assessment finds issues.

### Phase 2: Push/PR

**Script:** lib/core/create-pr.sh  
**Input:** Worktree with commits  
**Output:** PR created/updated on GitHub  
**Exit codes:** 0 (success), 1 (fail), 2 (exists)  

Pushes commits, creates/updates PR, detects sensitivity areas.

### Phase 2b: Review Generation

**Script:** lib/core/local-review.sh  
**Provider:** RITE_REVIEW_PROVIDER (default: claude)  
**Input:** PR diff  
**Output:** Review comment posted to PR  

Generates focused code review. Sensitivity hints injected from blocker detection.

### Phase 3: Assessment Loop (up to 3 retries)

**Scripts:** lib/core/assess-review-issues.sh + assess-and-resolve.sh  
**Provider:** RITE_REVIEW_PROVIDER  
**Input:** Review findings  
**Output:** Three-state assessment (ACTIONABLE_NOW, ACTIONABLE_LATER, DISMISSED)  

1. assess-review-issues.sh classifies findings
2. assess-and-resolve.sh routes:
   - ACTIONABLE_NOW → fix (loop up to 3x)
   - ACTIONABLE_LATER → create follow-up issue
   - DISMISSED → ready to merge

### Phase 4: Merge

**Script:** lib/core/merge-pr.sh  
**Input:** PR with passing review  
**Output:** PR merged, branch deleted, worktree cleaned  

Post-merge: Run tests, attribute failures.

### Phase 5: Completion

Notifications, cleanup, health tracking.

---

## Source Dependencies

### bin/rite
→ config.sh (first, loads all defaults)  
→ colors.sh  
→ normalize-issue.sh  
→ pr-detection.sh  
→ repo-status.sh (status mode)  
→ plan-issues.sh (plan mode)  
→ provider-interface.sh (--init)  

### lib/core/workflow-runner.sh
→ notifications.sh, blocker-rules.sh, session-tracker.sh, pr-summary.sh, normalize-issue.sh,  
  pr-detection.sh, issue-assessor.sh, gh-retry.sh, provider-interface.sh, colors.sh, logging.sh

### lib/core/claude-workflow.sh
→ session-tracker.sh, issue-assessor.sh, provider-interface.sh, logging.sh

### lib/core/local-review.sh
→ colors.sh, logging.sh, blocker-rules.sh, provider-interface.sh

### lib/core/assess-and-resolve.sh
→ colors.sh, logging.sh, blocker-rules.sh, provider-interface.sh

### lib/core/assess-review-issues.sh
→ colors.sh, logging.sh

### lib/core/merge-pr.sh
→ notifications.sh, post-merge-verify.sh, blocker-rules.sh, create-followup-issues.sh, provider-interface.sh

### lib/core/plan-issues.sh
→ colors.sh, logging.sh, labels.sh, normalize-issue.sh, blocker-rules.sh, provider-interface.sh

### lib/core/undo-workflow.sh
→ pr-detection.sh, colors.sh, logging.sh

### lib/utils/blocker-rules.sh
→ colors.sh (print_warning, print_info), logging.sh (optional)

### lib/utils/normalize-issue.sh
→ provider-interface.sh, colors.sh, logging.sh

### lib/utils/validate-setup.sh
→ colors.sh, logging.sh

### lib/providers/claude.sh
→ colors.sh, logging.sh, timeout.sh

### lib/providers/gemini.sh
→ colors.sh, logging.sh, timeout.sh

---

## Data Flow Patterns

### Assessment Output (Pipe-friendly)

```
assess-review-issues.sh → stdout (assessment data) + stderr (display)
assess-and-resolve.sh captures stdout, decides: exit 0 (merge) or exit 2 (loop)
workflow-runner.sh captures exit codes and stdout for fix mode
```

### Review Sensitivity

```
create-pr.sh → detects sensitive paths (informational)
local-review.sh → injects hints into review prompt
.rite/blockers.conf → BLOCKER_* pattern variables
```

### Exit Code Semantics

- `0` = Success, ready to proceed
- `1` = Failure, manual intervention needed
- `2` = Loop needed (fixes found, re-review required)
- `3` = Review stale, route back to Phase 2
- `5` = Provider usage cap reached (blocks batch)
- `10` = Stale branch restart, skip resume state
- `124` = Timeout (from gtimeout/timeout)
- `127` = Command not found

### Config Loading Order

1. config.sh defaults
2. ~/.config/rite/config (global, optional)
3. ~/.riterc (convenience, optional)
4. $RITE_PROJECT_ROOT/.rite/config (project, optional)
5. $RITE_PROJECT_ROOT/.rite/blockers.conf (blockers, optional)
6. Environment variables (RITE_*) — override all

### Logging

Structured `[phase]` and `[diag]` lines logged to `RITE_LOG_FILE`.  
Used by health-report for aggregation and diagnostics.  
Auto-pruned: keeps last 20 logs, deletes older.

---

## Safety System (Two-tier)

### Tier 1: Review Sensitivity Hints (non-blocking)

**Detected paths:**
- Infrastructure (infrastructure/, cdk/, terraform/, .github/workflows/)
- Migrations (prisma/migrations/, migrations/)
- Auth (auth/, authentication/, cognito/, oauth)
- Docs (CLAUDE.md, ARCHITECTURE.md)
- Expensive services (RDS, Aurora, EC2, Fargate, etc.)

**Effect:** Injected into review prompt, not a hard gate.

### Tier 2: Hard Merge Gates (blocking)

**Blocks merge if:**
- CRITICAL review findings
- Test/build failures (non-zero exit)
- Session limits exceeded
- AWS credentials expired
- Blocker approvals not recorded

**Supervised mode:** Interactive `read -p` prompt  
**Unsupervised mode:** Stops workflow (unless `--bypass-blockers`)

### Stale Branch Handling

- **Below threshold:** Auto merge origin/main into feature branch
- **At/above threshold (auto):** Close PR, cleanup, restart fresh
- **At/above threshold (supervised):** Prompt with 4 options

Threshold: `RITE_STALE_BRANCH_THRESHOLD` (default: 10 commits)

---

## Critical Shell Conventions

### grep -c behavior

```bash
# BAD: produces "0\n0" (grep outputs "0", then || echo "0" adds another)
COUNT=$(echo "$text" | grep -c "pattern" || echo "0")

# GOOD: grep -c already outputs the count, just suppress exit code
COUNT=$(echo "$text" | grep -c "pattern" || true)
```

grep -c always outputs a count (even "0") but returns exit code 1 when count is 0.

### Structured header matching

```bash
# BAD: matches "ACTIONABLE_NOW" anywhere, including reasoning text
COUNT=$(echo "$output" | grep -c "ACTIONABLE_NOW" || true)

# GOOD: matches only the structured classification headers
COUNT=$(echo "$output" | grep -c "^### .* - ACTIONABLE_NOW" || true)
```

Assessment output uses `### Title - STATE` format for classification.

### Review severity parsing

```bash
# BAD: "CRITICAL:" matches metadata lines like "Findings: [CRITICAL: 0 | ...]"
COUNT=$(echo "$output" | grep -ciE "CRITICAL:" || true)

# GOOD: parse the structured Findings line
FINDINGS=$(echo "$output" | grep -oE "CRITICAL: [0-9]+ \| HIGH: [0-9]+" | head -1)
```

### Unbound variables with set -u

```bash
# BAD: crashes if WORKTREE_PATH was never assigned
if [ -z "$WORKTREE_PATH" ]; then

# GOOD: default-value syntax satisfies set -u
if [ -z "${WORKTREE_PATH:-}" ]; then
```

All scripts use `set -euo pipefail`. Unset variables crash before error handling.

### Exported env vars vs function definitions

Exported variables survive subprocesses. Function definitions don't.  
Don't use env var as skip guard for `source` if child processes need the functions.

### PIPESTATUS survival

```bash
# BAD: PIPESTATUS is from outer shell, not the pipe inside $()
OUTPUT=$(cmd1 | cmd2)
EXIT_CODE=${PIPESTATUS[0]}

# GOOD: capture exit code via temp file inside pipeline
_exit_file=$(mktemp)
OUTPUT=$(cmd1 | { cmd2; echo $? > "$_exit_file"; } | cmd3)
EXIT_CODE=$(cat "$_exit_file")
rm -f "$_exit_file"
```

PIPESTATUS doesn't survive `$()` command substitution (runs in subshell).

### local keyword usage

```bash
# BAD: crashes in main script body
local dep_state=""

# GOOD: plain assignment (prefix with _ to signal local-ish scope)
_dep_state=""
```

`local` only works inside functions. Main script body must use plain assignment.

### git push explicit refspec

```bash
# BAD: pushes to whatever upstream is configured (may be origin/main)
git push

# GOOD: explicit remote and branch
git push origin "$BRANCH_NAME"
```

Always specify explicit refspec to avoid pushing to wrong upstream.

### .gitignore and symlinks

Use `.rite` (no trailing slash).  
`.rite/` only matches directories, but in worktrees `.rite` is a symlink (git mode 120000 = file).

---

## Provider Agnosticism (Critical Rules)

All review, assessment, and planning prompts are **provider-agnostic plain Markdown**.  
Provider-specific behavior isolated in `lib/providers/<name>.sh` behind 17-function interface.

### Rules:

- No prompt may contain provider-specific instructions (Claude `/exit`, tool_use, `--disallowedTools`)
- Provider-specific instructions go in preamble functions
- Model names are metadata only, never instructional text
- Error patterns, tool restrictions, streaming format all provider-specific
- Per-phase provider selection: `RITE_DEV_PROVIDER`, `RITE_REVIEW_PROVIDER`, `RITE_UTILITY_PROVIDER`

### Prompt Design:

1. **Sharkrite identity:** "You are running inside a Sharkrite workflow session"
2. **Git/GH prohibition:** Enforced via BOTH prompt AND `--disallowedTools`
3. **TodoWrite restriction:** Blocked, causes performative "phases" instead of work
4. **Explicit exit:** Supervised mode needs `/exit`, auto mode uses `--print`
5. **No open-ended questions:** Directives, not "Ready to start?"

---

## Token Optimization: rtk (Trial)

**Status:** Trial (installed 2026-03-24)  
**Tool:** rtk — CLI proxy that compresses terminal output before Claude Code sees it

### What rtk affects:

- ONLY Claude Code Bash tool calls
- Sharkrite's own scripts call git/gh/jq directly — rtk never touches them
- Phase 1 (development) is where savings happen: git status, git diff, test runs, grep, cat, ls
- Phases 2-5 unaffected: all Sharkrite gh calls use --json which rtk passes unfiltered
- stdin piping (fix-review mode) unaffected: hook only rewrites command strings

### Configuration:

```
~/.config/rtk/config.toml              Global config (exclusions, tracking, limits)
.rtk/filters.toml                      Project-local filter overrides
~/.claude/hooks/rtk-rewrite.sh        The PreToolUse hook (created by rtk init)
```

### Excluded commands:

cat, head, tail — rtk rewrites these to `rtk read` which strips code comments.  
This can cause Claude to write code that doesn't match existing commenting style.

### Health report thresholds:

- Fix iterations avg > 2.0 → WARNING
- Any phase failing > 30% → WARNING
- Phase 1 duration avg > 20 min → WATCH
- rtk savings < 30% → WATCH

If rtk causes token waste: `rtk init --global --uninstall && brew uninstall rtk`

---

## Templates (templates/)

### gitignore
- Purpose: Patterns appended to project root .gitignore by `rite --init`
- Contains: .rite patterns (scratch.md, session-state/, logs/, etc.)
- Committed: NO

### issue-template.md
- Purpose: Reference template for manually created issues
- Committed: YES (as .rite/issue-template.md)
- Sections: Title, Labels, Time Estimate, Description, Claude Context, Acceptance Criteria, Verification Commands, Done Definition, Scope Boundary, Dependencies

### github/PULL_REQUEST_TEMPLATE.md
- Purpose: GitHub PR template
- Committed: YES (as .github/PULL_REQUEST_TEMPLATE.md)

### github/claude-code/pr-review-instructions.md
- Purpose: Instructions for Claude Code during local review
- Committed: YES (as .github/claude-code/pr-review-instructions.md)

### github/workflows/pr-merged-notification.yml
- Purpose: GitHub Actions workflow for Slack merge notifications
- Committed: OPTIONAL (created by --init if user approves)

---

## End of Module Map

**Total Production Code:** 24,000 lines  
**Documentation:** 8,000+ lines  
**Configuration Examples:** 3 files  

Generated: 2026-05-26
