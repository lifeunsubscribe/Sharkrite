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

## No `sleep infinity` (BSD /bin/sleep rejects it)

**Rule:** Never use `sleep infinity` / `sleep inf`; use a large finite value like `sleep 2147483647`.

**Why:** GNU coreutils accepts `infinity`, but BSD/macOS /bin/sleep rejects any non-numeric duration and exits immediately (never sleeps) — hang simulators / hold-open patterns silently fail on macOS. Enforced by lint Rule 26 (SLEEP_INFINITY_NOT_PORTABLE).

**Example:**
```bash
# BAD
sleep infinity
# GOOD
sleep 2147483647   # ~68 years; both GNU and BSD accept
```

**References:** #707, #707

---

## tr cannot emit a multibyte UTF-8 replacement

**Rule:** Don't map a byte to a multibyte UTF-8 char with `tr`; use bash parameter expansion instead.

**Why:** tr is byte-oriented — a multibyte replacement (e.g. `tr '\n' '↵'`) emits only the first byte of the 3-byte char, producing garbage. Enforced by lint Rule 27 (TR_MULTIBYTE_REPLACEMENT).

**Example:**
```bash
# BAD
vis=$(printf '%s' "$x" | tr '\n' '↵')
# GOOD
vis="${x//$'\n'/↵}"
```

**References:** #707, #707

---

## BSD `date -jf` parsing a UTC timestamp needs `-u`

**Rule:** When parsing a Z/UTC timestamp to epoch with BSD `date -jf "...Z" +%s`, include `-u`.

**Why:** Without `-u`, BSD date parses the input in local time (the trailing Z is a literal), skewing the epoch by the local offset. Enforced by lint Rule 28 (BSD_DATE_PARSE_Z_WITHOUT_U).

**Example:**
```bash
# BAD
date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s
# GOOD
date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s
```

**References:** #707, #707

---

## Escape `/` inside an awk regex character class

**Rule:** Inside an awk `/regex/` literal, escape `/` within a character class — write `[^\/]`, not `[^/]`.

**Why:** BSD/macOS awk parses an unescaped `/` inside `[...]` as the regex-literal delimiter → "nonterminated character class", exit 2. Not auto-linted — the awk-literal context can't be established by a line-grep without false positives.

**Example:**
```bash
# BAD  (BSD awk: exit 2)
awk '/^diff --git a\/[^/]+\.md /'
# GOOD
awk '/^diff --git a\/[^\/]+\.md /'
```

**References:** #707, #707

---

## Guard bare RITE_* path vars under set -u

**Rule:** Reference optional RITE_* path vars as `${RITE_INSTALL_DIR:-}` (or with a default), never bare, in files sourceable standalone.

**Why:** A bare `$RITE_INSTALL_DIR` crashes under `set -u` when unset (standalone source), making fallback paths unreachable. Not auto-linted as a rule — too broad (17 false positives on the tree); watch for it in review.

**Example:**
```bash
# BAD
if [ -f "$RITE_INSTALL_DIR/templates/x.md" ]; then
# GOOD
if [ -f "${RITE_INSTALL_DIR:-}/templates/x.md" ]; then
```

**References:** #707, #707

---

## Variable-sentinel re-source guards for lib files that export -f

**Rule:** A lib/ file that `export -f`s any function MUST use a variable-sentinel re-source guard (`_RITE_<NAME>_LOADED`, deliberately NOT exported), never a function-sentinel guard.

**Why:** Subprocesses inherit `export -f`'d functions but not unexported variables. A function-sentinel guard sees the inherited stale function and short-circuits, so functions added after the parent started are never defined in the subprocess. The variable form re-sources against the current on-disk file. Enforced by lint rule FUNCTION_SENTINEL_GUARD_WITH_EXPORT_F; canonical example lib/utils/blocker-rules.sh; contract test tests/regression/blocker-rules-stale-inherited-functions.bats.

**Example:**
```bash
if [ "${_RITE_FOO_LOADED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_RITE_FOO_LOADED=true   # NO `export` — that defeats the whole point
```

**References:** #396, #396

---

## CRLF-robust grep - strip CR, never \r?

**Rule:** When a grep pattern anchors to end-of-line (`$`) for a marker that must be alone on its line, strip CR first (`tr -d '\r' < file | grep ...`) instead of relaxing the regex.

**Why:** CRLF files end the line with `<marker>\r` before the `$`, breaking the anchor. `\r?$` is NOT a fix - GNU grep -E treats `\r` as a literal `r` (only PCRE -P interprets it), so it silently no-ops on Linux/CI while appearing to work under CRLF-aware greps. CR-strip keeps the anchored regex unchanged and avoids false positives.

**Example:**
```bash
# BAD: silently matches nothing on GNU grep -E
grep -E '^=======\r?$' file
# GOOD
tr -d '\r' < file | grep -E '^=======$'
```

**References:** #698, #698

---

## Never auto-push WIP to a shared default branch

**Rule:** An interrupt/cleanup trap that auto-commits work-in-progress may push only to a feature branch, never main/master/detached HEAD; and arm such a trap only for real execution, never when the file is sourced for its functions.

**Why:** A trap firing on a default branch would publish half-done work to the shared branch; gate it on the branch name and leave changes uncommitted in the working tree there. A sourced-then-killed process (RITE_SOURCE_FUNCTIONS_ONLY=1 loads) must not trigger commit/push side effects it never owned.

**References:** #700, #700

---

## Array-fed awk/grep must never fall through to stdin

**Rule:** `awk '...' "${ARR[@]}"` (or grep) with an empty array passes zero file args and reads stdin - guard with `[ "${#ARR[@]}" -gt 0 ]` or redirect `</dev/null`.

**Why:** If stdin is an inherited tty the tool blocks forever. This is a deadlock class, not cosmetic - it wedged a full workflow run for 78 minutes.

**Example:**
```bash
# BAD: empty ARR → awk reads the inherited tty and hangs
awk '{print}' "${ARR[@]}"
# GOOD
[ "${#ARR[@]}" -gt 0 ] && awk '{print}' "${ARR[@]}"
```

**References:** #701, #701

---

## Lint-rule bats tests must scope to their rule

**Rule:** A test invoking tools/sharkrite-lint.sh MUST set SHARKRITE_LINT_ONLY=<NN> for the rule(s) its assertions name; unscoped is allowed only for a genuine all-rules sweep in a serial-marked file.

**Why:** Unscoped full scans under the gate's `bats --jobs 8` starve the CPU, exceed BATS_TEST_TIMEOUT, and hang the gate to its watchdog (live: batch 155134, 2026-07-18). A typo'd rule number fails loudly, so a stale scope cannot silently pass.

**Example:**
```bash
# GOOD
SHARKRITE_LINT_ONLY=34 run tools/sharkrite-lint.sh "$f"
```

**References:** #1088, #1088

---
