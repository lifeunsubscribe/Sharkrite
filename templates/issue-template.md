## Title
[Phase N] Verb noun - specific component

## Labels
`phase-N`, `category`, `priority-level`

Categories: `infrastructure`, `backend`, `frontend`, `database`, `testing`, `docs`, `security`, `devops`
Priority: `priority-high`, `priority-medium`, `priority-low`

## Time Estimate
15min | 30min | 45min | 1hr | 2hr (if >2hr, decompose into smaller issues)

## Description
What needs to be done and why (1-2 sentences).

## Claude Context
Files to Read:
- `path/to/relevant/file` (what to look for)
- `path/to/another/file`

Files to Modify:
- `path/to/file`

Related Issues: #N (if applicable)

## Acceptance Criteria
- [ ] Criterion with verification: `command to verify`
- [ ] Another criterion: `test command`
- [ ] Documentation updated (if applicable): specify which docs

## Verification Commands
```bash
npm test -- specific.test.ts
curl localhost:3000/endpoint | jq .field
```

## Done Definition
One sentence. The human reads this and knows whether to stop iterating.

## Scope Boundary
- DO: specific actions in scope
- DO NOT: specific actions out of scope

## Dependencies
After: #N
Blocked by: #N
None
