# Tag Index System (PROPOSAL)

**Status:** design — not yet implemented.

## Purpose

Reduce noise in the Claude development prompt by loading only catalog entries (conventions, encountered-issues, ADRs, behavioral-design sections) that are relevant to the current issue. The tag index is a **router**, not a content store — it maps a tag to pointers into the existing documentation files.

## Design Principles

1. **Self-discovered, then reconciled.** Tags are assigned at write time (issue generation, PR-body convention blocks). New tags are reconciled against the existing index during post-merge doc assessment.
2. **No backfill.** Old conventions/encountered-issues stay untagged. The index grows from new entries; untagged entries are reachable via codebase grep and an always-load fallback.
3. **Catalog as map, not content.** Pointers anchor on heading text in the target doc — no duplicated prose, no line-range brittleness.
4. **No human-audited drift.** Reconciliation runs deterministically + via a sonnet pass that asks two structured questions; the user sees its summary in doc-assessment output but doesn't manually scan tag-index.md.

## Files

### `docs/architecture/tag-index.md` (new)

Markdown, one heading per tag, bullets are pointers.

```markdown
# Tag Index

**Auto-maintained — do not hand-edit.** See `docs/architecture/tag-index-system.md`.

---

## subshell

- conventions.md → Subshell variable loss
- encountered-issues.md → Subshell pipefail propagation
- behavioral-design.md → Phase Handoff cwd Invariants

## set-e

- conventions.md → grep -c pattern
- conventions.md → Silent death: pipelines inside $()
- encountered-issues.md → Bare-prefix marker grep

## gh-cli

- conventions.md → CWD after worktree removal
- behavioral-design.md → Network Calls During Closed-Issue Cleanup
```

Anchors are the heading text of the target section (case-insensitive match, dashes/spaces normalized).

### Extended YAML in PR-body convention blocks

```markdown
<!-- sharkrite-convention -->
title: Subshell variable loss
rule: ...
why: ...
example: |
  ...
references: abc1234, #99
tags: subshell, while-read, pipefail
new-tags:
  - while-read: One-line justification for the new tag (only required when introducing tags absent from tag-index.md)
<!-- /sharkrite-convention -->
```

- `tags:` — comma-separated, all must exist in tag-index.md *unless* listed under `new-tags:`.
- `new-tags:` — only required when proposing a tag not yet in the index. One-line justification per tag.

### Extended issue body (`rite plan` output)

```markdown
... existing issue body ...

<!-- sharkrite-issue-tags -->
tags: subshell, pipefail
<!-- /sharkrite-issue-tags -->
```

`rite plan` is taught to emit this block when generating issues; manual issues that lack the block degrade gracefully (see Failure Modes).

## Lifecycle

### Write (issue generation)
1. `rite plan` loads tag-index.md as context alongside the architectural doc.
2. Claude generates each issue + a `tags:` line, selecting from existing tags where possible.
3. New tags must be justified inline (one line each). User reviews proposed tags in the standard `rite plan` preview alongside issue content.

### Write (PR-body conventions)
1. Contributor (or fix-mode Claude) drafts a `sharkrite-convention` block.
2. The block declares `tags:` (and `new-tags:` if any are novel).
3. No client-side gate — drift reconciliation catches problems at merge time.

### Store (post-merge)
1. `update_conventions_from_marker` in `assess-documentation.sh` extracts the block as today, plus:
   - Append/accumulate pointers in tag-index.md for each tag.
   - If `new-tags:` are present, add a new heading to tag-index.md and run drift reconciliation (below).

### Read (`rite N` start)
1. Pre-Phase-1 step in `claude-workflow.sh`: extract issue tags from issue body.
2. For each tag, look up tag-index.md → collect pointer list.
3. For each pointer, slice the heading's section from the target doc.
4. Bundle as a "Relevant prior art" block injected into the dev prompt.
5. Plus the codebase-grep hardening layer (see below).

### Reconcile (drift, post-merge)

When `new-tags:` are added in a PR, the doc-assessment phase asks sonnet two structured questions:

1. **Similarity check:** "Given the new tag(s) `X, Y` and the existing tag list (...), are any of the new tags semantically equivalent or near-equivalent to an existing tag? Output JSON: `{ "merges": [{"from": "X", "into": "existing-Y", "confidence": 0.0-1.0}] }`. Only propose a merge at confidence ≥ 0.85."
2. **Coverage check:** "For each new tag `X`, scan the catalog files (conventions.md, encountered-issues.md, behavioral-design.md) for headings whose subject matter matches `X` but aren't currently pointed at by tag-index.md → `X`. Output JSON: `{ "missing_pointers": [{"tag": "X", "target": "conventions.md#heading"}] }`."

Behavior:
- Confidence ≥ 0.85 merges → auto-applied (rewrites tag-index.md + PR-body block reference).
- Missing pointers → auto-added to tag-index.md.
- Both actions logged in doc-assessment output as `tag-index: merged X into Y` / `tag-index: added X → conventions.md#heading`.

If the sonnet call fails or returns malformed JSON, the merge step is skipped and the new tag stays as-is (graceful degradation, never blocks the merge).

## Codebase Grep (hardening layer)

Runs alongside the tag-index lookup at `rite N` start. Surfaces existing usages from the live codebase for any:

- File path in the issue body matching `[a-z_/-]+\.(sh|md|conf|bats)`
- Backticked symbol matching `` `[a-z_]+\(\)` `` (function call) or `` `\$[A-Z_]+` `` (variable)

For each hit, runs `grep -rn` (or ripgrep if available) under `lib/` + `bin/`, captures top 3 callsites, formats as:

```
Existing usages of `foo()`:
  - lib/core/workflow-runner.sh:421
  - lib/utils/timeout.sh:78
```

Injected into the same "Relevant prior art" block as the tag-matched entries.

## CLI: `rite --tags`

Read-only command that prints the current state of the tag index.

```
$ rite --tags
Tag Index (24 tags, 67 pointers)

  subshell              (4 entries)
    → conventions.md → Subshell variable loss
    → encountered-issues.md → Subshell pipefail propagation
    → behavioral-design.md → Phase Handoff cwd Invariants
    → behavioral-design.md → Closed-Issue Cleanup Fallback Chain

  set-e                 (3 entries)
    → conventions.md → grep -c pattern
    ...

Untagged catalog entries: 27
  (use --tags --orphans to list)
```

Flags:
- `rite --tags` — full index
- `rite --tags <tag>` — pointers for a specific tag
- `rite --tags --orphans` — catalog entries with no tag pointers (helps spot what hasn't been routed yet)
- `rite --tags --history` — sonnet-merge log from doc-assessment runs (which new tags were merged/expanded over time)

## Failure Modes & Graceful Degradation

| Situation | Behavior |
|---|---|
| Issue body has no `sharkrite-issue-tags` block | Derive candidate tags from GitHub labels + keyword grep of title/body against tag-index headings. Load anything that matches. |
| No tags match at all | Fall through to codebase grep + always-load full catalog (current behavior). System never gets *worse* than today. |
| Sonnet drift-reconciliation call fails | Skip merge/coverage steps. New tag is preserved unmodified. Logged as warning, doc-assessment continues. |
| tag-index.md missing | Auto-create on first tagged PR (same pattern as conventions.md bootstrap). |
| Tag in PR block isn't in tag-index.md and isn't in `new-tags:` | Lint failure at PR creation (custom rule). Forces explicit justification. |

## Open Questions

1. **Where does the section-slicing happen?** Sliced text injected into Claude prompt is bytes; needs a budget. Cap at e.g. 5KB per relevant-prior-art block, with "..." truncation and a pointer to read the full doc if needed.
2. **`new-tags:` justification audit.** Does the post-merge doc-assessment show new-tag *justifications* in its summary so the user can spot bad reasoning, or only the merge/coverage results?
3. **encountered-issues.md auto-generation.** Closed-issue → encountered-issues entries are auto-generated. Should the originating issue's tags propagate, or should sonnet re-derive them at generation time?

## Non-Goals

- Backfill of existing untagged entries.
- A tag UI / web view. CLI is enough.
- Tags as a permission/access control mechanism. They're for relevance routing only.
