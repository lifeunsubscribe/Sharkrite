# Architecture Reference - Sharkrite Project

## Module Map

bin/ — CLI entrypoint and command dispatcher (1 file: rite)

lib/core/ — Workflow orchestration and core phases
- Implements 5-phase lifecycle: dev → PR → review → fixes → merge
- Primary orchestrators: workflow-runner.sh, claude-workflow.sh, plan-issues.sh
- Phase handlers: create-pr.sh, local-review.sh, assess-and-resolve.sh, merge-pr.sh
- Utilities: assess-review-issues.sh, assess-documentation.sh, bootstrap-docs.sh, batch-process-issues.sh, undo-workflow.sh

lib/providers/ — Model-agnostic provider abstraction
- provider-interface.sh: 17-function dispatcher interface contract
- claude.sh: Claude Code CLI provider (fully implemented)
- gemini.sh: Gemini CLI provider (skeleton/stub)

lib/utils/ — Shared utilities and cross-cutting concerns
- Configuration: config.sh, blocker-rules.sh, labels.sh
- PR/state detection: pr-detection.sh, issue-assessor.sh, divergence-handler.sh, stale-branch.sh
- Session management: session-tracker.sh, scratchpad-manager.sh, normalize-issue.sh
- Notifications: notifications.sh
- Helpers: colors.sh, logging.sh, timeout.sh, gh-retry.sh
- Review/conflict: review-helper.sh, conflict-resolver.sh, format-review.sh, review-assessment.sh
- PR summary: pr-summary.sh
- Post-merge: post-merge-verify.sh
- Repo info: repo-status.sh
- Validation: validate-setup.sh
- Cleanup: cleanup-worktrees.sh
- Issue creation: create-followup-issues.sh

## Key Files

/Users/sarahtime/Dev/sharkrite/bin/rite — CLI entrypoint (356 lines)
  Entry point for all commands. Handles:
  - Command routing (full, dev-and-pr, review-latest, assess-and-fix, status, undo, plan, health-report, init)
  - Issue input validation and normalization
  - Logging setup and PR detection
  - Orphan PR handling with stale branch detection
  - GitHub auth and Claude CLI preflight checks
  - Batch processing via filter labels (--label flag)

/Users/sarahtime/Dev/sharkrite/lib/core/workflow-runner.sh — Main orchestrator (2263 lines)
  Central state machine orchestrating all 5 phases:
  - Phase 1: Development (claude-workflow.sh)
  - Phase 2: Push/PR creation (create-pr.sh)
  - Phase 3: Review and assessment (assess-and-resolve.sh, local-review.sh)
  - Phase 4: Merge (merge-pr.sh)
  - Phase 5: Completion (notifications, cleanup)
  Features:
  - Graceful interrupt handling with session state save
  - Retry loop with configurable max retries
  - Stale branch detection and auto-merge main
  - Session limits (8 issues/4 hours per session)
  - Hard blocker gates (CRITICAL findings, tests, creds)
  - Resume capability on rerun

/Users/sarahtime/Dev/sharkrite/lib/core/claude-workflow.sh — Dev session orchestrator (2638 lines)
  Manages agentic sessions with Claude Code:
  - Worktree creation/navigation
  - Provider abstraction dispatch (dev vs fix modes)
  - Tool restrictions enforcement (--disallowedTools)
  - Timeout management
  - Fix-review mode for iterative assessment loop
  - Session state checkpoint on interrupt
  - Auto/supervised mode differentiation

/Users/sarahtime/Dev/sharkrite/lib/core/create-pr.sh — PR creation and pushing (389 lines)
  Handles PR lifecycle:
  - Existing PR detection and draft→ready transition
  - Sensitivity detection (infrastructure, migrations, auth, etc.)
  - Auto-push of committed changes
  - PR body generation with issue link
  - Draft vs ready-for-review state management
  - Exit codes for orchestrator routing

/Users/sarahtime/Dev/sharkrite/lib/core/local-review.sh — Code review generation (418 lines)
  Generates AI code reviews:
  - PR diff fetching and context building
  - Sensitivity area injection (path-based)
  - Provider-agnostic review prompts
  - Review posting as PR comments with markers
  - Structured output format (CRITICAL/HIGH/MEDIUM/LOW findings)
  - Model selection per review role

/Users/sarahtime/Dev/sharkrite/lib/core/assess-and-resolve.sh — Assessment driver (1222 lines)
  Routes review to fixes loop:
  - Assessment freshness checking
  - Issue categorization (ACTIONABLE_NOW/ACTIONABLE_LATER/DISMISSED)
  - Retry counting and limits
  - Exit codes: 0=done, 1=manual, 2=needs fixes, 3=stale review, 5=usage cap
  - Filtered stdout for assessment content (pipes to fix sessions)

/Users/sarahtime/Dev/sharkrite/lib/core/assess-review-issues.sh — Review assessment (1013 lines)
  AI-driven issue assessment:
  - Classifies review items into 3 states
  - Applies project context for calibration
  - Generates follow-up issue bodies
  - Provides fix effort metadata
  - Structured markdown output with ### Title - STATE format
  - Freshness detection vs. last assessment timestamp

/Users/sarahtime/Dev/sharkrite/lib/core/merge-pr.sh — PR merge workflow (1573 lines)
  Final merge phase:
  - Merge readiness validation
  - Conflict detection and auto-resolution (Claude-assisted)
  - Pre-merge updates (auto-merge main if <10 commits behind)
  - Merge strategy selection (squash default)
  - Post-merge verification (test suite)
  - Branch cleanup and worktree removal
  - Failure attribution and hotfix PR creation

/Users/sarahtime/Dev/sharkrite/lib/core/batch-process-issues.sh — Batch runner (1304 lines)
  Processes multiple issues in sequence:
  - Session limit enforcement (8 issues max, 4 hours max)
  - Filter support (--label, --milestone)
  - Per-issue workflow invocation
  - End-of-batch verification phase (full test suite)
  - Failure aggregation and hotfix PR creation
  - Comprehensive summary report
  - Progress tracking and notifications

/Users/sarahtime/Dev/sharkrite/lib/core/plan-issues.sh — Issue generation (2033 lines)
  Generates GitHub issues from architectural docs:
  - Document discovery and classification
  - Claude-driven issue creation from docs
  - Interactive approval workflow
  - Runbook template application
  - Label assignment (phase, category, priority)
  - Time estimation (Fibonacci, capped at 2hr)
  - Dependency chain setup

/Users/sarahtime/Dev/sharkrite/lib/core/assess-documentation.sh — Doc updates (1065 lines)
  Updates internal and project documentation:
  - Layer 1: Machine-optimized .rite/docs/
  - Layer 2: User project docs (if .rite/doc-sync.md exists)
  - Parallel provider calls for speed
  - Timeout per call (120s default)
  - Cross-document reconciliation

/Users/sarahtime/Dev/sharkrite/lib/core/bootstrap-docs.sh — Doc bootstrap (551 lines)
  One-time initialization of .rite/docs/:
  - Codebase analysis and reference extraction
  - Architecture overview generation
  - API surface mapping
  - Configuration defaults documentation
  - Testing framework reference

/Users/sarahtime/Dev/sharkrite/lib/core/undo-workflow.sh — Workflow cleanup (459 lines)
  Reverses a workflow:
  - PR detection (session state → body search → title matching)
  - Follow-up issue discovery
  - Branch/worktree cleanup
  - PR closure with summary comment
  - Session state removal
  - Merged PR protection (errors safely)

/Users/sarahtime/Dev/sharkrite/lib/providers/provider-interface.sh — Provider abstraction (138 lines)
  Dispatcher for model-agnostic operations:
  - 17-function interface contract
  - Dynamic function aliasing (provider_* namespace)
  - CLI detection and validation
  - Agentic session invocation
  - Text-in/text-out prompts
  - Tool restriction building
  - Error classification
  - Model resolution
  - Provider-specific preambles

/Users/sarahtime/Dev/sharkrite/lib/providers/claude.sh — Claude provider (392 lines)
  Claude Code CLI integration:
  - Detects CLI (claude or claude-code command)
  - Streaming filters (colored for dev, plain for planning)
  - Agentic session setup with tool restrictions
  - Timeout wrapping
  - Error detection (usage cap, rate limit, auth, network)
  - Tool restriction specs (--disallowedTools)
  - Prompt preambles (identity, git/gh prohibition)
  - Model selection (sonnet for dev, opus for review)

/Users/sarahtime/Dev/sharkrite/lib/providers/gemini.sh — Gemini provider skeleton (195 lines)
  Stub implementation for future Gemini CLI support:
  - All 17 functions stubbed
  - Error detection patterns (quota, rate limit, auth, network)
  - Preamble templates (Thresher identity)
  - Model selection (gemini-2.5-pro)
  - Requires: Gemini CLI research + implementation

/Users/sarahtime/Dev/sharkrite/lib/utils/config.sh — Configuration system (304 lines)
  Central config loader (priority: env > project > global > defaults):
  - Project detection (git root)
  - Installation path setup
  - Worktree directory management
  - Session limits and timeouts
  - Provider selection (RITE_DEV_PROVIDER, RITE_REVIEW_PROVIDER, RITE_UTILITY_PROVIDER)
  - Blocker path patterns
  - Test command detection
  - Project context injection (for review calibration)
  - Gitignore pattern ensuring
  - Backward-compat symlink creation

/Users/sarahtime/Dev/sharkrite/lib/utils/blocker-rules.sh — Safety gates (542 lines)
  Merge-blocking rules and sensitivity detection:
  - Hard merge gates (CRITICAL findings, test failures, session limits, AWS creds)
  - Sensitivity area detection (infrastructure, migrations, auth, docs, protected scripts)
  - Path-based classification
  - AWS project detection
  - Review prompts (informational, non-blocking)
  - Supervised mode approval caching

/Users/sarahtime/Dev/sharkrite/lib/utils/pr-detection.sh — State detection (232 lines)
  Finds and checks PR/worktree/review state:
  - PR lookup by issue number (body text search)
  - Worktree detection (git worktree list, local .rite/state/)
  - Review state checking (timestamps, currency vs commits)
  - Commit timestamp utilities (git + API fallback)
  - Local freshness validation

/Users/sarahtime/Dev/sharkrite/lib/utils/divergence-handler.sh — Branch divergence (629 lines)
  Handles branch staleness:
  - Commit count behind main detection
  - Classification: up-to-date, slightly behind, stale, critical
  - Auto-merge main (squash) if <10 commits behind
  - Supervised prompts for stale branches
  - Restart detection and branch cleanup
  - Rebase option for critical divergence
  - Forces full detection via git fetch

/Users/sarahtime/Dev/sharkrite/lib/utils/stale-branch.sh — Stale detection (427 lines)
  Detects and handles stale worktrees:
  - Threshold-based detection (default: 10 commits)
  - Supervised vs auto mode handling
  - Four options for supervised: restart, merge, continue, abort
  - Automatic closure and cleanup for auto mode
  - Issue linking on restart

/Users/sarahtime/Dev/sharkrite/lib/utils/issue-assessor.sh — Pre-launch state (517 lines)
  Detects issue state before workflow:
  - Checks if issue already closed
  - Detects active PR for issue
  - Validates issue ownership/access
  - Suggests resume if interrupted before
  - Checks for follow-up issues
  - Pre-flight validation

/Users/sarahtime/Dev/sharkrite/lib/utils/session-tracker.sh — Session state (421 lines)
  Manages workflow session lifecycle:
  - Saves/loads session state JSON (.rite/session-state-ISSUE.json)
  - Phase checkpoints with timestamps
  - Uncommitted changes detection
  - Auto-commit on interrupt
  - WIP message generation
  - Resume capability

/Users/sarahtime/Dev/sharkrite/lib/utils/normalize-issue.sh — Issue normalization (408 lines)
  Converts input to structured issue:
  - Numeric ID → fetch from GitHub
  - Text description → Claude-driven issue creation
  - Title cleanup and bash variable escaping
  - Interactive approval loop
  - Multi-line issue body formatting

/Users/sarahtime/Dev/sharkrite/lib/utils/repo-status.sh — Status display (709 lines)
  Repo-wide operational overview:
  - Lists all open issues with phase indicators
  - Worktree staleness display
  - PR state summaries
  - Recently closed issues
  - Grouping by label option
  - Rich formatting with progress indicators

/Users/sarahtime/Dev/sharkrite/lib/utils/post-merge-verify.sh — Post-merge testing (537 lines)
  Validates system after merge:
  - Full test suite execution
  - Test command detection (npm, pytest, make)
  - Timeout enforcement
  - Parallel test support (pytest-xdist)
  - Failure attribution (which PR caused it)
  - Hotfix PR creation on failure

/Users/sarahtime/Dev/sharkrite/lib/utils/conflict-resolver.sh — Merge conflict resolution (255 lines)
  Claude-assisted merge conflict handling:
  - Conflict detection (git diff --diff-filter=U)
  - File change summary with context
  - Claude conflict resolution prompting
  - Automatic resolution application
  - Commit and push on success
  - Cleanup on failure

/Users/sarahtime/Dev/sharkrite/lib/utils/scratchpad-manager.sh — Scratchpad lifecycle (463 lines)
  Manages .rite/scratch.md for security findings:
  - Load/save security findings
  - Issue-specific findings (pre-session context)
  - Encounter issue protocol (found during dev)
  - Cleanup after merge
  - YAML-style metadata blocks

/Users/sarahtime/Dev/sharkrite/lib/utils/notifications.sh — Notifications (264 lines)
  Sends notifications on workflow events:
  - Slack webhook support
  - Email support (SNS)
  - Workflow completion notifications
  - Merge notifications with summary
  - Opt-in per project (RITE_NOTIFICATIONS flag)

/Users/sarahtime/Dev/sharkrite/lib/utils/review-helper.sh — Review utilities (111 lines)
  Review method helpers:
  - Find existing review comment markers
  - Check review currency (vs last commit)
  - Parse model/timestamp from review headers

/Users/sarahtime/Dev/sharkrite/lib/utils/format-review.sh — Review formatting (230 lines)
  Formats review content:
  - Structured finding output (### Title - SEVERITY)
  - Summary line generation (CRITICAL: N | HIGH: N | ...)
  - Markdown list formatting
  - HTML comment markers (for detection)

/Users/sarahtime/Dev/sharkrite/lib/utils/create-followup-issues.sh — Follow-up creation (219 lines)
  Creates tech-debt/review follow-ups:
  - Issue body generation from assessment items
  - Parent PR linking (issue body markers)
  - Label assignment
  - Time estimate aggregation
  - Done definition generation

/Users/sarahtime/Dev/sharkrite/lib/utils/pr-summary.sh — PR metadata (119 lines)
  Generates PR body summaries:
  - Change summary (files, additions, deletions)
  - Commit list formatting
  - Issue link injection
  - Sensitivity area annotation

/Users/sarahtime/Dev/sharkrite/lib/utils/validate-setup.sh — Setup validation (470 lines)
  Pre-flight checks:
  - GitHub auth status
  - Claude CLI availability
  - jq/gh/git dependency checks
  - Worktree directory permissions
  - Git configuration validation

/Users/sarahtime/Dev/sharkrite/lib/utils/timeout.sh — Timeout utilities (108 lines)
  Cross-platform timeout handling:
  - GNU timeout vs BSD gtimeout detection
  - Fallback for missing timeout
  - Auto-install prompt (coreutils)
  - Timeout wrapper function

/Users/sarahtime/Dev/sharkrite/lib/utils/gh-retry.sh — GitHub CLI retries (98 lines)
  Retry wrapper for GitHub API calls:
  - Exponential backoff
  - Transient error detection
  - Max retry limit (default: 3)
  - Rate limit aware

/Users/sarahtime/Dev/sharkrite/lib/utils/colors.sh — Terminal colors (37 lines)
  ANSI color constants and print functions:
  - print_error, print_success, print_info, print_status, print_warning, print_header

/Users/sarahtime/Dev/sharkrite/lib/utils/logging.sh — Logging utilities (217 lines)
  Structured logging:
  - Diagnostic log entries ([diag] format)
  - Verbose output control
  - RITE_LOG_FILE management
  - ANSI stripping for logs

/Users/sarahtime/Dev/sharkrite/lib/utils/labels.sh — Label utilities (33 lines)
  GitHub label helpers:
  - Add label functions
  - Label formatting

/Users/sarahtime/Dev/sharkrite/lib/utils/review-assessment.sh — Assessment utilities (67 lines)
  Review assessment helpers:
  - State extraction from assessment output
  - Count parsing

/Users/sarahtime/Dev/sharkrite/lib/utils/cleanup-worktrees.sh — Worktree cleanup (193 lines)
  Cleans up old/merged worktrees:
  - Merged branch detection
  - Auto-cleanup on limits
  - Worktree removal

## Config Variables

Default values extracted from lib/utils/config.sh:

Installation & Paths:
RITE_INSTALL_DIR=$HOME/.rite — Installation directory
RITE_LIB_DIR=$RITE_INSTALL_DIR/lib — Library directory
RITE_DATA_DIR=.rite — Per-repo config/state directory
RITE_PROJECT_ROOT=$(git rev-parse --show-toplevel) — Project root
RITE_WORKTREE_BASE=$HOME/Dev/rite-wt — Worktrees base directory
RITE_WORKTREE_DIR=dynamic per project — Worktree subdirectory

Session Limits:
RITE_MAX_ISSUES_PER_SESSION=8 — Max batch issues
RITE_MAX_SESSION_HOURS=4 — Max session duration
RITE_MAX_RETRIES=3 — Max fix iterations per issue
RITE_ASSESSMENT_TIMEOUT=120 — Assessment call timeout (seconds)
RITE_STALE_BRANCH_THRESHOLD=10 — Commits behind before restart

Workflow:
WORKFLOW_MODE=supervised — supervised or unsupervised
RITE_DRY_RUN=false — Preview without executing
RITE_SKIP_TESTS=false — Skip pre-commit test gate
RITE_TEST_CMD="" — Custom test command (auto-detected)
RITE_TEST_TIMEOUT=120 — Test suite timeout (seconds)
RITE_CLAUDE_TIMEOUT=7200 — Session timeout (seconds, 2 hours)

Models:
RITE_CLAUDE_MODEL=claude-sonnet-4-5 — Dev model
RITE_REVIEW_MODEL=claude-opus-4-5 — Review model
RITE_GEMINI_DEV_MODEL=gemini-2.5-pro — Gemini dev model
RITE_GEMINI_REVIEW_MODEL=gemini-2.5-pro — Gemini review model

Providers:
RITE_DEV_PROVIDER=claude — Dev session provider
RITE_REVIEW_PROVIDER=claude — Review provider
RITE_UTILITY_PROVIDER=claude — Utility provider (classify, plan, etc.)

Planning:
RITE_PLAN_DOCS="" — Default architectural docs for issue generation
RITE_PLAN_MAX_ESTIMATE=2hr — Max estimate before requiring decomposition

Notifications:
RITE_NOTIFICATIONS=false — Enable/disable notifications
SLACK_WEBHOOK="" — Slack webhook URL
EMAIL_NOTIFICATION_ADDRESS="" — Email for notifications
RITE_SNS_TOPIC_ARN="" — AWS SNS topic
RITE_EMAIL_FROM="" — Email sender
RITE_AWS_PROFILE=default — AWS profile for SNS

Project Context:
RITE_PROJECT_CONTEXT="" — Deployment context for review calibration

Blocker Paths (sensitivity detection):
BLOCKER_INFRASTRUCTURE_PATHS=infrastructure/|cdk/|terraform/|cloudformation/|\.github/workflows/|\.claude/
BLOCKER_MIGRATION_PATHS=prisma/migrations/|migrations/|db/migrate/|alembic/
BLOCKER_AUTH_PATHS=auth/|Auth|authentication|authorization|cognito|oauth
BLOCKER_DOC_PATHS=Technical-Specs|Architecture|CLAUDE.md|ARCHITECTURE.md
BLOCKER_PROTECTED_SCRIPTS=workflow-runner.sh|claude-workflow.sh|merge-pr.sh|create-pr.sh|batch-process-issues.sh
BLOCKER_EXPENSIVE_SERVICES=\brds\b|\baurora\b|\bnatgateway\b|\bnat_gateway\b|\bec2\b|\bfargate\b|\bsagemaker\b|\bredshift\b

## Dependencies

Workflow orchestration:
bin/rite → lib/core/workflow-runner.sh — Main orchestration
workflow-runner.sh → claude-workflow.sh — Phase 1: dev
workflow-runner.sh → create-pr.sh — Phase 2: push/PR
workflow-runner.sh → local-review.sh → assess-review-issues.sh — Phase 3: review
workflow-runner.sh → assess-and-resolve.sh — Phase 3: assessment + fixes
workflow-runner.sh → merge-pr.sh — Phase 4: merge

Provider abstraction:
All core modules → lib/providers/provider-interface.sh → claude.sh or gemini.sh
local-review.sh → provider (run_prompt for review generation)
assess-review-issues.sh → provider (run_prompt for assessment)
plan-issues.sh → provider (run_streaming_prompt for issue generation)
merge-pr.sh → provider (run_uncached for Claude conflict resolution)
claude-workflow.sh → provider (run_agentic_session for dev/fix)

Shared utilities:
All modules → config.sh — Configuration loading
All modules → colors.sh, logging.sh — Output formatting
All modules → pr-detection.sh — State detection
workflow-runner.sh → blocker-rules.sh — Safety gates
workflow-runner.sh → divergence-handler.sh → stale-branch.sh — Branch staleness
workflow-runner.sh → session-tracker.sh — State checkpoints
create-pr.sh → pr-summary.sh — PR body generation
merge-pr.sh → post-merge-verify.sh — Test verification
merge-pr.sh → conflict-resolver.sh — Merge conflict resolution
assess-and-resolve.sh → create-followup-issues.sh — Follow-up creation
batch-process-issues.sh → post-merge-verify.sh — End-of-batch verification
All phase modules → notifications.sh — Notifications
All modules → scratchpad-manager.sh — Security findings

## Current State

Built components (substantial implementation, >100 lines):
- bin/rite — Main CLI (356 lines, fully implemented)
- lib/core/workflow-runner.sh (2263 lines)
- lib/core/claude-workflow.sh (2638 lines)
- lib/core/plan-issues.sh (2033 lines)
- lib/core/merge-pr.sh (1573 lines)
- lib/core/batch-process-issues.sh (1304 lines)
- lib/core/assess-and-resolve.sh (1222 lines)
- lib/core/assess-documentation.sh (1065 lines)
- lib/core/assess-review-issues.sh (1013 lines)
- lib/core/create-pr.sh (389 lines)
- lib/core/local-review.sh (418 lines)
- lib/core/bootstrap-docs.sh (551 lines)
- lib/core/undo-workflow.sh (459 lines)
- lib/providers/claude.sh (392 lines, fully implemented)
- lib/providers/provider-interface.sh (138 lines, fully implemented)
- lib/utils/ (all major utilities fully implemented)
  - config.sh (304 lines)
  - blocker-rules.sh (542 lines)
  - repo-status.sh (709 lines)
  - divergence-handler.sh (629 lines)
  - post-merge-verify.sh (537 lines)
  - scratchpad-manager.sh (463 lines)
  - session-tracker.sh (421 lines)
  - validate-setup.sh (470 lines)
  - issue-assessor.sh (517 lines)
  - stale-branch.sh (427 lines)
  - pr-detection.sh (232 lines)
  - All other utilities (<250 lines each, fully implemented)

Stubbed/Skeleton components (non-functional):
- lib/providers/gemini.sh (195 lines, all 17 functions stubbed)

Phase of development:
- Core: Maintenance + refinement phase
- Recent work (last 10 commits): Provider abstraction, test gating, doc assessment, cleanup improvements
- Latest commit (bd61485): "feat: provider abstraction layer for model-agnostic workflow execution"
- Feature status: Feature-complete for Claude provider; Gemini provider pending CLI research
- Status: Stable production build with 23k lines of shell, full 5-phase workflow automation

