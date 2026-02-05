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
- PRs merged before Forge was set up
- Quick-merged PRs that skipped review
- Historical security audits
- Compliance documentation

**Flow:**
1. Fetch diff from closed/merged PR
2. Run full review with pr-review-instructions.md (+ detected themes)
3. Post findings as comment on the PR
4. If CRITICAL found → optionally create follow-up issue

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
| Codebase scanning | ✅ | ✅ |
| Compliance themes (HIPAA, PCI, SOC2) | ❌ | ✅ |
| `rite review` (retroactive) | ❌ | ✅ |
| `rite plan` (full generation) | ❌ | ✅ |
| `rite plan --roadmap` | ❌ | ✅ |
| Interactive config UI | ❌ | ✅ |
| Team mode | ❌ | ✅ |

---

## Dogfooding: Using Sharkrite on Sharkrite

Once the theme system and issue generation are stable, Sharkrite development itself can use Forge:

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
