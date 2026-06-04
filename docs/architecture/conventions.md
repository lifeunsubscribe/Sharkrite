# Sharkrite Conventions Catalog

**Auto-appended on merge — do not hand-edit.**

To add a convention, include a `<!-- sharkrite-convention -->` block in your PR body:

```
<!-- sharkrite-convention -->
title: Your convention title
rule: One-sentence statement of the rule
why: Why this rule exists / what goes wrong without it
example: |
  # BAD
  ...
  # GOOD
  ...
references: <commit-sha>, #<issue>, #<pr>
<!-- /sharkrite-convention -->
```

The merge automation extracts the block and appends a rendered entry below.
Entries are append-only; each entry's `references` field links to the issue(s) and
commit(s) that surfaced or fixed the pattern.

---

## no-keyword-matching

**Rule:** Never use grep/substring matching to decide downstream behavior on text that could be conversational or self-documenting.

**Why:** Issue and PR bodies routinely document marker formats and decision vocabulary as examples. A bare `grep -q "sharkrite-parent-pr:"` matches a body that only mentions the marker as documentation — the inner extraction then returns empty and `set -e + pipefail` kills the script silently with no error message.

**Example:**
```bash
# BAD: outer guard without format anchor — matches documentation placeholders
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi

# GOOD: outer guard requires digits — rejects all placeholder text
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi
```

**References:** 206f2be, #34, #74, #90, #92

---

## local-outside-function

**Rule:** `local` only works inside functions — never use it in main script body.

**Why:** Scripts like `batch-process-issues.sh` and `assess-and-resolve.sh` run logic directly in the main script body, not inside functions. Using `local` there crashes with `local: can only be used in a function`. Under `set -e`, this crash is silent from the caller's perspective — the script just dies with no useful message.

**Example:**
```bash
# BAD: crashes in main script body
local dep_state=""

# GOOD: plain assignment (prefix with _ to signal local-ish scope)
_dep_state=""
```

**References:** #92, #93

---

## defensive-sourcing-must-be-idempotent

**Rule:** Every file in `lib/` must be safe to source multiple times under `set -euo pipefail`.

**Why:** Sourcing a file twice without a guard can crash via `readonly` re-assignment, re-run interactive logic, or re-execute initialization code. The canonical guard prevents this. Live failures from missing or wrong guards: `assess-documentation.sh` (2026-05-31, #61), `issue-lock.sh` (2026-05-31, #69), `stash-manager.sh` (2026-06-01), `claude.sh` (2026-06-01).

**Example:**
```bash
# BAD: no guard — second source re-executes everything
set -euo pipefail
readonly MY_CONSTANT="value"  # crashes on second source

# GOOD: function-library guard
set -euo pipefail
if declare -f my_canonical_function >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi
readonly MY_CONSTANT="value"  # only runs once

# GOOD: orchestrator guard (for files with top-level executable code)
if [ "${_RITE_MY_SCRIPT_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_MY_SCRIPT_LOADED=true
```

**References:** #61, #69, 2267841, 93c7ddd

---

## set-e-pipefail-grep-silent-death

**Rule:** Under `set -euo pipefail`, a pipeline inside `$()` that exits non-zero kills the script silently. Always append `|| true` when empty-match is expected.

**Why:** When `grep`, `awk`, `sed`, `head`, or `tail` find no match (exit 1), the command substitution propagates exit 1, and `set -e` kills the script with no error output. The bug is invisible until someone traces the execution manually.

**Example:**
```bash
# BAD: silently kills script if grep finds no match
VAR=$(echo "$text" | grep "pattern")
VAR=$(git worktree list | grep "branch" | awk '{print $1}')

# GOOD: empty-match is expected, continue gracefully
VAR=$(echo "$text" | grep "pattern" || true)
VAR=$(git worktree list | grep "branch" | awk '{print $1}' || true)

# GOOD: empty-match is an ERROR, fail with clear message
VAR=$(echo "$text" | grep "required-field" || {
  echo "ERROR: required field not found" >&2
  exit 1
})
```

**References:** 206f2be, #34, #90

---

## structured-header-matching

**Rule:** Always match structured assessment headers (`^### .* - STATE`), never bare keywords.

**Why:** Assessment output uses `### Title - STATE` format. A bare keyword like `ACTIONABLE_NOW` also appears in reasoning text ("this was the previous ACTIONABLE_NOW item that was fixed"), producing inflated counts that cause the fix loop to re-run unnecessarily.

**Example:**
```bash
# BAD: matches "ACTIONABLE_NOW" anywhere, including reasoning text
COUNT=$(echo "$output" | grep -c "ACTIONABLE_NOW" || true)

# GOOD: matches only the structured classification headers
COUNT=$(echo "$output" | grep -c "^### .* - ACTIONABLE_NOW" || true)
```

**References:** #92

---

## grep-c-output-vs-exit-code

**Rule:** `grep -c` always outputs a count (even "0") but returns exit code 1 when count is 0. Use `|| true` to suppress the exit code — never `|| echo "0"`.

**Why:** `grep -c "pattern" || echo "0"` produces "0\n0" — grep outputs "0" (the count), then `|| echo "0"` adds a second "0". The result is a string "0\n0", not the integer 0, which breaks numeric comparisons silently. `grep -o` is different — it outputs nothing on no match, so `|| echo "0"` is correct there.

**Example:**
```bash
# BAD: produces "0\n0" double output
COUNT=$(echo "$text" | grep -c "pattern" || echo "0")

# GOOD: grep -c already outputs the count, just suppress the exit code
COUNT=$(echo "$text" | grep -c "pattern" || true)
```

**References:** #90, #92

---

## marker-must-anchor-format

**Rule:** Any `grep -q` guard for a structured marker must include a format anchor (e.g., `[0-9]+`) in the same pattern. Never use bare-prefix guards.

**Why:** Without a format anchor, any issue body that *documents* the marker format as an example will match the guard. The inner extraction then returns empty. Under `set -e + pipefail`, this kills the batch silently. Live failure: issue #34 batch run died at Processing Issue #34 whose body listed `sharkrite-parent-pr:N` as a documentation example (2026-05-31).

**Example:**
```bash
# BAD: bare-prefix guard — matches documentation examples
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi

# GOOD: format-anchored guard
if echo "$ISSUE_BODY" | grep -qE "sharkrite-parent-pr:[0-9]+"; then
  PARENT_PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi
```

**References:** 206f2be, #34, #90
