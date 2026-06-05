# Issue Generation Runbook
## Optimized for Sharkrite + Claude Code Workflows

### Purpose
Generate well-structured GitHub issues that Claude Code can execute efficiently with clear context boundaries, verification steps, and appropriate scope. This runbook is the quality standard for `rite plan` — Claude uses it to generate issues that work seamlessly with the sharkrite lifecycle (`rite <issue>` → dev → PR → review → assess → merge).

---

## Issue Template Structure

### Required Sections

1. **Title Format**: `[Phase X] Verb Noun - Specific Component`
   - Imperative mood, ≤50 characters (git subject line limit)
   - Examples: `[Phase 0] Configure billing alerts`, `[Phase 2] Add rate limiting to login endpoint`
   - No markdown formatting, no conventional commit prefixes

2. **Labels**: Always include three dimensions
   - Phase: `phase-0`, `phase-1`, `phase-2`, etc.
   - Category: `infrastructure`, `backend`, `frontend`, `database`, `testing`, `docs`, `security`, `devops`
   - Priority: `priority-high`, `priority-medium`, `priority-low`

3. **Time Estimate**: Fibonacci scale, hard cap at 2hr
   - `15min`, `30min`, `45min`, `1hr`, `2hr`
   - If an issue would take >2hr, it MUST be decomposed into smaller issues
   - High priority items: add 50% buffer

4. **Description**: 1-2 sentences explaining WHAT and WHY
   - First sentence: what needs to happen
   - Second sentence: why it matters (user impact, dependency, risk)

5. **Claude Context**: Specific file pointers for Claude's working memory
   ```
   Files to Read:
   - path/to/doc.md (what to look for)
   - path/to/interface.ts (relevant types)

   Files to Modify:
   - path/to/handler.ts
   - path/to/config.yaml

   Related Issues: #N (if applicable)
   ```

6. **Acceptance Criteria**: Checkboxes with verification commands
   ```
   - [ ] Specific criterion: `verification command`
   - [ ] Another criterion: `test command`
   - [ ] Documentation updated (if applicable): specify which docs
   ```

7. **Verification Commands**: Copy-paste-able commands a human (or Claude) can run to confirm the work. These are reference material, not auto-executed — feel free to include repro setup, shell pipelines, placeholders, and inline comments.
   ```bash
   npm test -- specific.test.ts
   curl localhost:3000/endpoint | jq .field
   ```

8. **Done Definition**: One sentence. A human reads this and knows whether to stop.

   Good examples:
   - "Done when the endpoint returns correct data for the 3 test cases in the issue"
   - "Done when all 6 acceptance criteria pass and CI is green"
   - "Done when the migration runs cleanly and the new columns appear in `prisma studio`"

   Anti-examples (never use these):
   - "Done when it works" (too vague)
   - "Done when all edge cases are handled" (unbounded)
   - "Done when code is clean and well-tested" (subjective, invites infinite polishing)

9. **Scope Boundary**: Explicit DO / DO NOT list
   ```
   - DO: implement the login endpoint with rate limiting
   - DO: add unit tests for the happy path and 3 error cases
   - DO NOT: refactor the auth middleware (separate issue)
   - DO NOT: add OAuth support (Phase 3)
   ```

10. **Dependencies**: Issue ordering within the plan
    - `After: #N` — should be done after issue N
    - `Blocked by: #N` — cannot start until N is complete
    - `None` — can start independently

---

## Issue Sizing Guidelines

### Good Size (30min-2hr per issue)
- Single endpoint or API handler
- One service layer function with tests
- Database migration + model changes
- Test suite for one feature
- Configuration for one service or tool
- Single component or page

### Too Large (must split)
- "Implement authentication system" → split into: register, login, verify, profile, tests
- "Set up cloud infrastructure" → split by service: database, auth, API gateway, CDN
- "Build data pipeline" → split into: ingestion, transformation, storage, monitoring
- "Add search feature" → split into: index setup, query API, UI, filters, pagination

### Context Window Optimization
- Each issue should reference ≤10 files
- Documentation references should target specific sections, not whole docs
- Include explicit file paths so Claude loads the right context
- Prefer modifying existing files over creating new ones

---

## Category Templates

### Infrastructure Issues
```markdown
**Title**: [Phase 0] Deploy database with connection pooling

**Labels**: `phase-0`, `infrastructure`, `priority-high`
**Time**: 1hr

**Description**:
Deploy the primary database with connection pooling configured for the expected workload. Required before any data model work can begin.

**Claude Context**:
Files to Read:
- docs/architecture.md (database section)
- infrastructure/config.yaml (existing setup)

Files to Modify:
- infrastructure/database.yaml
- .env.example (connection string)

**Acceptance Criteria**:
- [ ] Database accessible from application: `psql $DATABASE_URL -c '\dt'`
- [ ] Connection pooling configured: verify pool settings
- [ ] Environment variables documented in .env.example

**Done Definition**: Done when the app connects to the database and runs a query successfully.

**Scope Boundary**:
- DO: database deployment and connection config
- DO NOT: create application data models (separate issue)

**Dependencies**: None
```

### Backend / API Issues
```markdown
**Title**: [Phase 1] Implement login endpoint with rate limiting

**Labels**: `phase-1`, `backend`, `priority-high`
**Time**: 2hr

**Description**:
Create POST /auth/login with credential validation, token generation, and rate limiting. Users need to authenticate before accessing any protected resources.

**Claude Context**:
Files to Read:
- docs/api-spec.md (auth section)
- src/middleware/auth.ts (existing auth utilities)

Files to Modify:
- src/routes/auth/login.ts (create)
- src/routes/auth/login.test.ts (create)
- src/routes/index.ts (register route)

**Acceptance Criteria**:
- [ ] POST /auth/login accepts email/password: `npm test -- login.test.ts`
- [ ] Successful auth returns JWT tokens: verify token structure
- [ ] Failed auth returns 401 with error message
- [ ] Rate limiting after 5 failed attempts returns 429
- [ ] Tests cover happy path + 3 error cases

**Verification Commands**:
```bash
npm test -- login.test.ts
npm run dev &
curl -X POST http://localhost:3000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"TestPass123!"}'
```

**Done Definition**: Done when login returns valid tokens for correct credentials and 401/429 for invalid/excessive attempts.

**Scope Boundary**:
- DO: login endpoint, validation, rate limiting, tests
- DO NOT: registration, password reset, OAuth (separate issues)

**Dependencies**: After #N (database schema), After #M (auth middleware)
```

### Database / Data Model Issues
```markdown
**Title**: [Phase 1] Create user and tenant data models

**Labels**: `phase-1`, `database`, `priority-high`
**Time**: 45min

**Description**:
Define data models for users and tenants with proper relations and constraints. All subsequent API work depends on these models.

**Claude Context**:
Files to Read:
- docs/data-model.md (schema requirements)

Files to Modify:
- prisma/schema.prisma (or equivalent ORM config)
- migrations/ (new migration)

**Acceptance Criteria**:
- [ ] User model with required fields: email, hashedPassword, tenantId
- [ ] Tenant model with type enum
- [ ] Indexes on email and tenantId
- [ ] Migration runs without errors: `npx prisma migrate dev`
- [ ] Client generates cleanly: `npx prisma generate`

**Done Definition**: Done when migration applies cleanly and models appear in the database.

**Dependencies**: After #N (database setup)
```

### Testing Issues
```markdown
**Title**: [Phase 2] Add integration tests for auth flow

**Labels**: `phase-2`, `testing`, `priority-medium`
**Time**: 1hr

**Description**:
Create end-to-end tests covering the full authentication flow. Catches regressions before they reach production.

**Claude Context**:
Files to Read:
- tests/setup.ts (test infrastructure)
- src/routes/auth/*.ts (endpoints to test)

Files to Modify:
- tests/integration/auth-flow.test.ts (create)

**Acceptance Criteria**:
- [ ] Test registers new user → verifies → logs in → accesses profile
- [ ] Test rejects expired tokens with 401
- [ ] All tests pass: `npm run test:integration`

**Done Definition**: Done when the full auth flow test passes end-to-end.

**Dependencies**: After #N (login), After #M (register), After #K (profile)
```

### Documentation Issues
```markdown
**Title**: [Phase 2] Document API authentication flow

**Labels**: `phase-2`, `docs`, `priority-low`
**Time**: 30min

**Description**:
Document the authentication endpoints, token format, and error codes for API consumers.

**Claude Context**:
Files to Read:
- src/routes/auth/*.ts (implemented endpoints)
- src/middleware/auth.ts (token validation)

Files to Modify:
- docs/api-reference.md (auth section)

**Acceptance Criteria**:
- [ ] All auth endpoints documented with request/response examples
- [ ] Error codes listed with descriptions
- [ ] Token format and expiration documented

**Done Definition**: Done when a developer can read the docs and successfully authenticate without looking at source code.

**Dependencies**: After #N (integration tests — confirms the API is stable)
```

---

## Priority Guidelines

### High Priority (do first)
- Blocks other work (dependencies point here)
- Core infrastructure and data models
- Security and compliance requirements
- Required for MVP / current milestone
- Foundation that multiple issues build on

### Medium Priority (do alongside)
- Enhances existing functionality
- Verification and testing
- Non-blocking improvements
- Can parallelize with high priority work

### Low Priority (do last)
- Documentation polish
- Nice-to-have features
- Cleanup and refactoring
- Work that depends on everything else finishing first

---

## Issue Ordering Strategy

### Within a Phase
1. **Infrastructure first** — databases, auth services, cloud resources
2. **Data models and schemas** — the foundation everything queries
3. **Core API / business logic** — the primary functionality
4. **UI / frontend** — consumes the API
5. **Tests for implemented features** — confirms it all works
6. **Documentation updates** — captures the stable state

### Dependency Chain Example
```
[High] #10: Database setup
  ↓
[High] #11: User data model                ← depends on #10
  ↓
[High] #12: Registration endpoint           ← depends on #11
  ↓
[High] #13: Login endpoint                  ← depends on #11
  ↓
[Medium] #14: Email verification            ← depends on #12
  ↓
[Medium] #15: Profile endpoint              ← depends on #13
  ↓
[Medium] #16: Integration tests             ← depends on #12, #13, #15
  ↓
[Low] #17: API documentation                ← depends on #16 (stable API)
```

---

## Field Provenance Flagging

### When to include a provenance table

**Default: omit.** Most issues do not need a provenance table. A `**Field provenance:**` section is only warranted when a data-producing or data-transforming issue has at least one output field whose source is non-obvious.

A field source is **non-obvious** if:
- It comes from an **external system** (a third-party API, a remote feed, a payment processor, a financial data provider, etc.), OR
- It is **derived** from multiple inputs under a non-trivial rule (e.g., a running balance computed from a sequence of transactions, a score weighted across several columns).

A field source is **obvious** if its origin requires no explanation beyond "it's in the input file" — for example, reading a `name` field from `goals.json` and writing it to the output. Do not document obvious-source fields.

### Format

Add `**Field provenance:**` as a section inside the issue BODY (after the description, within the Claude Context block or as a standalone section):

```markdown
**Field provenance:**
- `amount`: SimpleFIN API (`/accounts` endpoint) — UNVERIFIED (no fixture)
- `running_balance`: derived — sum of all prior `amount` values for this account
- `institution_name`: SimpleFIN API (`/accounts[].org.name`) — verified-available (tests/fixtures/simplefin-accounts.json)
```

Each entry format: `` `field_name` ``: source description — `verified-available` / `UNVERIFIED` / `derived`

- **`verified-available`**: A fixture or test data file exists that confirms the field is actually returned by the source. Include the fixture path.
- **`UNVERIFIED`**: The field is expected from the external system but no fixture exists to confirm it. The post-generation linter emits a `WARNING:` for these — treat as a reminder to add a fixture before shipping.
- **`derived`**: The field is computed from other fields. Include the formula or rule.

### What the linter checks

After `rite plan` generates issues, `_lint_provenance_flags` runs deterministically (no LLM):

1. **UNVERIFIED warning**: Every `UNVERIFIED` entry emits `WARNING: Provenance lint: UNVERIFIED field provenance`. This is a signal, not a gate — the plan run continues.
2. **Low-signal rejection**: If a provenance entry's source matches a file already listed in the issue's "Files to Read", it is obvious-source. When the count of obvious-source entries exceeds `RITE_PLAN_PROVENANCE_MAX_OBVIOUS` (default 0), the linter fails the run. Override with `RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1` when you genuinely need the exception.

### Examples

**Correct — omit entirely** (loading goals from a local file):
```markdown
**Description**: Load savings goals from goals.json and display current progress.
```
No `**Field provenance:**` section needed — every field is local-file-obvious.

**Correct — flag external fields only** (SimpleFIN transaction sync):
```markdown
**Field provenance:**
- `amount`: SimpleFIN API (`/transactions[].amount`) — UNVERIFIED (no fixture)
- `posted_date`: SimpleFIN API (`/transactions[].transacted_at`) — UNVERIFIED (no fixture)
- `running_balance`: derived — cumulative sum of `amount` ordered by `posted_date`
```

**Incorrect — documenting obvious fields** (will be rejected by linter):
```markdown
**Field provenance:**
- `name`: goals.json — obvious (local file)
- `target_amount`: goals.json — obvious (local file)
```
These fields are sourced from `goals.json`, which is already in "Files to Read". The linter will flag this as low-signal and fail unless `RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1`.

---

## Anti-Patterns

### Vague Acceptance Criteria
```
BAD:
- [ ] Make it work
- [ ] Add tests
- [ ] Deploy

GOOD:
- [ ] Returns 200 with valid JWT: `curl localhost:3000/auth/login | jq .token`
- [ ] Rate limiting returns 429 after 5 attempts: run test script
- [ ] Tests achieve >80% coverage: `npm run test:coverage -- login.test.ts`
```

### Missing File Context
```
BAD:
Description: Implement login
(Claude doesn't know what files exist or where to put things)

GOOD:
Files to Read:
- src/middleware/auth.ts (token utilities)
- docs/api-spec.md (endpoint contract)

Files to Modify:
- src/routes/auth/login.ts (create new handler)
- src/routes/index.ts (register the route)
```

### Unbounded Scope
```
BAD:
Title: Implement entire authentication system
Time: 8hr+
(Too large, no clear stopping point)

GOOD:
Title: Implement login endpoint with rate limiting
Time: 2hr
(Registration, verification, profile are separate issues)
```

### Subjective Done Definitions
```
BAD:
- "Done when the code is clean" (who decides?)
- "Done when it's production-ready" (undefined)
- "Done when all edge cases are handled" (infinite)

GOOD:
- "Done when the 5 acceptance criteria pass"
- "Done when the endpoint handles the 3 documented error cases"
- "Done when CI is green and the migration applies cleanly"
```

---

## Using This Runbook

### With `rite plan`
```bash
# Generate issues from an architectural doc
rite plan docs/architecture/phase-2.md

# Natural language filtering
rite plan "phases 2-4 except the auth feature"

# Preview without creating
rite plan --preview docs/architecture/phase-2.md

# Use project default doc(s) when none specified
rite plan
rite plan "just the database stuff"
```

### Manual Issue Creation
Use this runbook as a reference when creating issues in the GitHub UI. Copy/paste the category template that fits.

### After Issues Are Created
```bash
rite 42                    # Full lifecycle for a single issue
rite 42 43 44              # Batch process multiple issues
rite --status              # See all issues and their workflow phase
rite --status --by-label   # Group by label (useful after plan generation)
```
