# Sharkrite Roadmap

## Current Version (2.x)

### Core Features
- Issue -> Branch -> Development -> PR -> Review -> Merge lifecycle
- Claude Code integration for development work
- Automated PR review parsing (CRITICAL/HIGH/MEDIUM/LOW)
- Fix loops for critical issues
- Batch processing
- Session management
- Slack/email notifications

### Recent Additions
- GitHub workflow templates (`rite --init`)
- Base review instructions with severity format
- Workflow permission validation

---

## Planned: Theme System (3.x)

### Vision

Transform PR reviews from generic feedback to project-specific, expert-level analysis by automatically detecting and applying relevant review themes.

### How It Works

```
+------------------------------------------------------------------+
|                        BASE LAYER (always)                        |
|  Best practices - Security basics - Error handling - Bugs         |
+------------------------------------------------------------------+
|                    DETECTED THEMES (additive)                     |
|                                                                   |
|  Prisma detected?    -> + Database security checks                |
|  AWS CDK detected?   -> + Serverless patterns, IAM review        |
|  tenantId in schema? -> + Multi-tenant isolation checks           |
|  "HIPAA" in docs?    -> + Healthcare compliance checks            |
+------------------------------------------------------------------+

Result -> Customized pr-review-instructions.md
```

### Theme Detection Strategy

Each theme would have:
- **Detection rules**: file patterns, package names, code patterns
- **Review additions**: extra checks appended to pr-review-instructions.md
- **Severity overrides**: e.g., tenant isolation gaps -> always CRITICAL

#### Example Themes

| Theme | Detection | Adds to Review |
|-------|-----------|----------------|
| Multi-tenant | `tenantId` in schema, `tenant` in middleware | Tenant isolation checks, query filtering, data leakage |
| AWS/Serverless | `aws-cdk`, `serverless.yml`, Lambda handlers | Cold start patterns, IAM least-privilege, resource limits |
| Database (Prisma) | `prisma/schema.prisma`, `@prisma/client` | N+1 detection, migration safety, index review |
| Authentication | `passport`, `next-auth`, JWT patterns | Session management, token handling, RBAC |
| Healthcare/HIPAA | `HIPAA` in docs, PHI patterns | PHI exposure, audit logging, encryption at rest |
| Financial | `stripe`, `plaid`, PCI patterns | PCI compliance, transaction integrity, decimal handling |
| Real-time | `socket.io`, `ws`, WebSocket patterns | Connection lifecycle, reconnection, message ordering |

### Implementation Plan

#### Phase 1: Scanner Framework
```
lib/utils/theme-scanner.sh
  scan_codebase()        # Run all detection rules
  detect_theme()         # Check if theme applies
  generate_appendix()    # Create theme-specific review additions
  update_instructions()  # Append to pr-review-instructions.md
```

#### Phase 2: Theme Definitions
```
templates/themes/
  multi-tenant.yml
  aws-serverless.yml
  prisma-database.yml
  auth-security.yml
  ...
```

Each theme file:
```yaml
name: Multi-Tenant
version: 1
detection:
  files:
    - "**/schema.prisma"
  content_patterns:
    - "tenantId"
    - "organizationId"
  packages:
    - "@prisma/client"
  confidence_threshold: 2  # Need 2+ matches

review_additions:
  critical_checks:
    - "Every database query MUST filter by tenantId/organizationId"
    - "API endpoints MUST extract tenant from auth context, never from request body"
    - "File uploads MUST be namespaced by tenant"
  high_checks:
    - "Background jobs MUST maintain tenant context"
    - "Caching MUST include tenant in cache keys"
    - "Logging MUST include tenant identifier"
```

#### Phase 3: Smart Updates
- Re-scan on each `rite --init` (detect new themes)
- Show diff of what changed in review instructions
- Allow manual theme overrides: `rite config --themes add healthcare`

---
## Planned: Workflow Commands (3.x)

### Issue Dashboard (`rite status`)

**Free feature** — Project health at a glance.

```bash
rite status              # Dashboard overview
rite status --list       # All issues with descriptions
rite status 42           # Deep dive on specific issue
```

**Dashboard view (`rite status`):**
- Open issue count by priority (P0/P1/P2) and type (feature, bug, docs, debt)
- Assignment distribution
- Recent activity (merges, reviews, blocks)
- Suggested next actions based on priority

**List view (`rite status --list`):**
- All open issues with titles and brief descriptions
- Grouped by assignee and/or classification
- Status indicators (in progress, blocked, ready)

**Issue detail (`rite status 42`):**
- Full issue description
- Implementation progress markers
- Related PRs and their status
- Blockers and dependencies
- Time in current state

---

### Retroactive Review (`rite review`)

**Paid feature** — Audit already-merged code.

```bash
rite review --pr 42        # Review by PR number
rite review --issue 42     # Review by issue (finds associated PR)  
rite 42 --review-only      # Shorthand for --issue
```

**Use cases:**
- PRs merged before Sharkrite was set up
- Quick-merged PRs that skipped review
- Historical security audits
- Compliance documentation

**Flow:**
1. Fetch diff from closed/merged PR
2. Run full review with pr-review-instructions.md (+ detected themes)
3. Post findings as comment on the PR
4. If CRITICAL found → optionally create follow-up issue

---

### Codebase Scan (`rite scan`)

**Tiered feature** — Read-only analysis that finds problems and builds project knowledge.

```bash
rite scan backend/src/auth/         # Scan a specific directory
rite scan "src/**/*.ts"             # Scan by glob pattern
rite scan --security                # Security-focused scan
rite scan --dead-code               # Find unused exports, orphaned files
rite scan --alignment               # Check code against CLAUDE.md conventions
rite scan --docs                    # Generate/update project documentation
rite scan --docs --update           # Write suggested CLAUDE.md updates directly
rite scan backend/ --create-issues  # Create GitHub issues for findings
```

**How it differs from `rite review`:**

| | `rite review` | `rite scan` |
|---|---|---|
| Scope | Single PR diff | Directory / module / codebase |
| Trigger | PR number | Path or glob pattern |
| Context | What changed | What exists |
| Goal | Approve/reject PR | Surface improvements, gaps, debt |

**Focus modes:**

| Mode | What it finds |
|------|--------------|
| `--security` | OWASP top 10, hardcoded secrets, auth gaps, injection vectors |
| `--dead-code` | Unused exports, orphaned files, unreachable branches, stale dependencies |
| `--alignment` | Deviations from CLAUDE.md patterns, inconsistent naming, style drift |
| `--docs` | Undocumented patterns, missing CLAUDE.md sections, doc/code drift |
| `--dependencies` | Outdated deps, known CVEs, unused packages, version conflicts |
| (no flag) | All of the above, general health check |

**Read-only enforcement:**
Claude runs with maximum tool restrictions — no Write, Edit, or mutating Bash. Only Read, Glob, Grep, and read-only Bash (`ls`, `wc`, `npm ls`, `cat package.json`). The `--docs --update` flag is the single exception, allowing writes only to CLAUDE.md and docs/.

**Output:** Structured findings report (same severity system as reviews: CRITICAL/HIGH/MEDIUM/LOW), printed to stdout or saved to `.rite/scans/`. When `--create-issues` is passed, findings above a threshold become GitHub issues — feeding directly back into the `rite <issue>` workflow.

#### Documentation Generation (`rite scan --docs`)

This is where scan creates a feedback loop with the rest of Sharkrite:

```
  rite scan --docs
       │
       ▼
  Analyzes codebase structure, patterns, conventions
       │
       ▼
  Suggests CLAUDE.md additions:
    - Architectural patterns it detected
    - Conventions used but not documented
    - Common pitfalls it inferred from code
       │
       ▼
  Better CLAUDE.md
       │
       ▼
  Future `rite <issue>` sessions have more context
       │
       ▼
  Less scope creep, more accurate implementations
       │
       ▼
  `rite scan --alignment` detects less drift
```

**What `--docs` detects:**

- **Undocumented patterns**: "All API handlers follow `handler.ts` + `schema.ts` + `handler.test.ts` convention, but CLAUDE.md doesn't mention this"
- **Convention drift**: "CLAUDE.md says use `camelCase` for functions, but 12 files in `lib/utils/` use `snake_case`"
- **Missing architecture docs**: "No documentation for the multi-tenant query filtering pattern used in 23 files"
- **Stale docs**: "CLAUDE.md references `lib/auth/passport.ts` which was deleted in commit abc123"
- **Theme hints**: "Detected Prisma + multi-tenant patterns — consider adding the multi-tenant theme"

**Implementation:**

```
lib/core/scan-workflow.sh     # Main scan orchestrator
  - Parse target path/glob
  - Select focus mode prompt
  - Run Claude in read-only mode
  - Format and output findings
  - Optionally create issues

templates/scan/
  security.md                 # Security scan prompt
  dead-code.md                # Dead code scan prompt
  alignment.md                # Alignment scan prompt
  docs.md                     # Documentation scan prompt
  general.md                  # Combined scan prompt
```

**Free tier:** `--security`, `--dead-code`, `--alignment`, `--docs` (preview)
**Pro tier:** `--docs --update` (write changes), `--create-issues`, `--dependencies` (CVE database), scheduled scans

---

### Issue Generation (`rite plan`)

**Tiered feature** — Convert documentation to actionable issues.

```bash
rite plan docs/Phase-2.md          # Generate issues from spec
rite plan --preview                # Show what would be created
rite plan --roadmap docs/ROADMAP.md  # Parse roadmap format
```

**Free tier (`rite plan --preview`):**
- Parse documentation manually
- Preview generated issues in terminal
- Copy/paste to create manually

**Paid tier (`rite plan`):**
- Full issue generation with:
  - Titles and descriptions
  - Implementation details
  - Acceptance criteria / verification steps
  - Labels (feature, bug, docs, debt, phase)
  - Dependencies between issues
- Batch create via GitHub API
- Auto-detect doc changes and suggest new issues

**Advanced (`rite plan --roadmap`):**
- Parse phased roadmap documents
- Generate issues organized by phase
- Track phase completion
- Suggest next phase when current completes

---

## Feature Tiers (Revised)

| Feature | Free | Pro |
|---------|------|-----|
| Core workflow (issue → merge) | ✅ | ✅ |
| `rite status` (dashboard) | ✅ | ✅ |
| `rite status --list` | ✅ | ✅ |
| `rite status 42` (detail) | ✅ | ✅ |
| `rite plan --preview` | ✅ | ✅ |
| Base + standard themes | ✅ | ✅ |
| `rite scan` (security, dead-code, alignment, docs preview) | ✅ | ✅ |
| `rite scan --docs --update` (write CLAUDE.md) | ❌ | ✅ |
| `rite scan --create-issues` | ❌ | ✅ |
| `rite scan --dependencies` (CVE database) | ❌ | ✅ |
| Compliance themes (HIPAA, PCI, SOC2) | ❌ | ✅ |
| `rite review` (retroactive) | ❌ | ✅ |
| `rite plan` (full generation) | ❌ | ✅ |
| `rite plan --roadmap` | ❌ | ✅ |
| Interactive config UI | ❌ | ✅ |
| Team mode | ❌ | ✅ |

---

## Dogfooding: Using Sharkrite on Sharkrite

Once the theme system and issue generation are stable, Sharkrite development itself can use Sharkrite:

1. **Issues:** Create issues in the rite repo for new features
2. **Workflow:** Set up `.github/workflows/claude-code-review.yml` in rite repo
3. **Themes:** Detect "CLI tool" and "bash scripting" patterns
4. **Meta:** Use `rite plan docs/ROADMAP.md` to generate implementation issues

This closes the loop: Sharkrite improves Sharkrite.

---

## Future Ideas (4.x+)

### Review Learning
- Track which review findings get addressed vs. dismissed
- Adjust severity thresholds based on team behavior
- Suggest new detection rules based on frequently caught issues

### Multi-Repo Themes
- Organization-level theme configuration
- Shared review standards across projects
- Theme marketplace for common patterns

### IDE Integration
- Show review severity during development
- Pre-commit theme-aware checks
- Real-time security scanning based on detected themes
