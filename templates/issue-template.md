<!-- sharkrite-issue-template
  This file is a REFERENCE template for manual issue authoring and `rite --init`
  setup. It is NOT loaded at runtime by the follow-up issue builder (assess-and-resolve.sh
  / assess-review-issues.sh). Those builders maintain the section structure inline,
  validated by tests/regression/followup-runbook-conformance.bats. Edit this file
  to update the human-readable reference; edit the builders to change generated output.
-->
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

**Dependencies**: After: #N / Blocked by: #N / None

## Bug Class Analysis
*(Required for bug-fix issues. Omit for feature/infra/docs issues.)*

1. **Specific failure mode observed:** [what exactly broke, with log evidence or reproduction steps]
2. **General bug class:** [what pattern is this an instance of?]
3. **Sibling instances:** [2-3 other places in the codebase where this same pattern exists, or "none — [reason why this code path is unique]"]
   - `file:line` — [same root cause, different trigger]
4. **Scope decision:** For each sibling: addressed by this fix (YES/NO)? If NO, why out of scope?
