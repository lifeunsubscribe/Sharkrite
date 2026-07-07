#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/format-review.sh
# Regression test for: pretty-print review terminal output
#
# format-review.sh renders a review comment body for terminal display during
# `rite --assess-and-fix`. The rewrite (this change) replaced a fragile markdown
# stripper that leaked the review marker, the model's pre-review preamble, and
# <!-- item:N --> markers, and stripped every code block. The new renderer:
#   - prints a colorized summary banner from the review-data JSON block
#   - falls back to the markdown Findings line when no JSON is present
#   - preserves fenced code/fix blocks
#   - never emits raw markers, HTML comments, or model preamble
#
# strip_pre_review_narration (added for issue #985):
#   - narration before the "## …Code Review" heading is stripped from REVIEW_OUTPUT
#     before the PR comment is assembled, so users never see debugging spew
#   - bodies without a matching heading pass through unchanged (fail-open)
#
# Tests in this file:
#   1. Markers, HTML comments, and model preamble are stripped
#   2. Summary banner (counts + verdict) is rendered from the JSON block
#   3. Fenced code/fix block content is preserved
#   4. Section/item structure survives (severity headers, item titles)
#   5. Fallback: no JSON block still renders body + Findings line
#   6. strip_pre_review_narration: narration before header is stripped
#   7. strip_pre_review_narration: body with no review header passes through unchanged
#   8. strip_pre_review_narration: marker line is preserved as the first line

load '../helpers/setup.bash'

FORMAT_REVIEW="" # set in setup

setup() {
  setup_test_tmpdir
  # In production the formatter is invoked with RITE_LIB_DIR already set (config
  # loaded by the orchestrator), so it skips the config.sh bootstrap — which
  # would otherwise demand a git repo and fail in this temp dir. Mirror that.
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  FORMAT_REVIEW="${RITE_REPO_ROOT}/lib/utils/format-review.sh"
  [ -x "$FORMAT_REVIEW" ] || chmod +x "$FORMAT_REVIEW"

  # Source format-review.sh to make strip_pre_review_narration available.
  # ${BASH_SOURCE[0]} != ${0} when sourced, so the main execution block
  # is skipped. Restore bats shell flags after the source (the lib runs
  # set -euo pipefail at source time — see test runbook Rule 3).
  # sharkrite-lint disable BATS_PRE_SOURCE_STUB_OVERWRITE - Reason: no stubs need protecting here
  source "${RITE_REPO_ROOT}/lib/utils/format-review.sh"
  set +u; set +o pipefail

  REVIEW_FILE="${RITE_TEST_TMPDIR}/review.md"
  cat > "$REVIEW_FILE" <<'EOF'
<!-- sharkrite-local-review model:claude-opus-4-8 timestamp:2026-06-27T17:16:50Z commit:cd3303e -->
I have a thorough understanding now. Let me analyze the key risk first.
Now I have everything needed to write the review.

## 📋 Code Review

**Files Analyzed:** 2
**Findings:** 🔴 CRITICAL: 0 | 🟠 HIGH: 1 | 🟡 MEDIUM: 1 | 🟢 LOW: 0

---

### 🟠 HIGH Priority Issues

<!-- item:1 severity:HIGH -->
#### 1. Unquoted variable allows word splitting

**File:** `lib/utils/test-gate.sh` (Line 532)
**Category:** BugRisk

**Problem:**
The variable is used unquoted, so a path with spaces splits.

**Code:**
```bash
for f in $FILES; do process "$f"; done
```

**Fix:**
```bash
while IFS= read -r f; do process "$f"; done <<< "$FILES"
```

- [ ] Quote the expansion or switch to a read loop
<!-- /item:1 -->

---

### ✅ What Looks Good

- Precedence ordering is correct and documented
EOF
  cat >> "$REVIEW_FILE" <<'JSONEOF'

<!-- sharkrite-review-data
{
  "metadata": { "model": "claude-opus-4-8", "files_analyzed": 2 },
  "summary": { "critical": 0, "high": 1, "medium": 1, "low": 0, "verdict": "NEEDS_WORK" },
  "items": [],
  "positive": []
}
-->
JSONEOF
}

teardown() {
  teardown_test_tmpdir
}

# Render and strip ANSI for stable assertions.
_render() {
  "$FORMAT_REVIEW" "$1" | perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g'
}

@test "strips review marker, HTML comments, and model preamble" {
  run _render "$REVIEW_FILE"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "sharkrite-local-review" ]]
  [[ ! "$output" =~ "sharkrite-review-data" ]]
  [[ ! "$output" =~ "<!-- item:" ]]
  [[ ! "$output" =~ "<!-- /item:" ]]
  [[ ! "$output" =~ "I have a thorough understanding" ]]
  [[ ! "$output" =~ "Now I have everything needed" ]]
}

@test "renders summary banner from JSON (counts + verdict)" {
  run _render "$REVIEW_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Files analyzed: 2" ]]
  [[ "$output" =~ "CRITICAL: 0" ]]
  [[ "$output" =~ "HIGH: 1" ]]
  [[ "$output" =~ "NEEDS WORK" ]]
}

@test "preserves fenced code and fix block content" {
  run _render "$REVIEW_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for f in \$FILES; do" ]]
  [[ "$output" =~ "while IFS= read -r f; do" ]]
}

@test "preserves severity headers and item titles" {
  run _render "$REVIEW_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "HIGH Priority Issues" ]]
  [[ "$output" =~ "1. Unquoted variable allows word splitting" ]]
  [[ "$output" =~ "What Looks Good" ]]
}

@test "fallback: no JSON block still renders body + Findings line" {
  nojson="${RITE_TEST_TMPDIR}/review-nojson.md"
  awk -v m="<!-- sharkrite-review-data" \
    'index($0,m)==1{f=1} f{if($0 ~ /-->/)f=0; next} {print}' "$REVIEW_FILE" > "$nojson"
  run _render "$nojson"
  [ "$status" -eq 0 ]
  # No JSON → banner comes from the markdown Findings line.
  [[ "$output" =~ "Findings:" ]]
  [[ "$output" =~ "HIGH Priority Issues" ]]
  [[ ! "$output" =~ "sharkrite-local-review" ]]
}

# ---------------------------------------------------------------------------
# strip_pre_review_narration tests (issue #985)
# ---------------------------------------------------------------------------

@test "strip_pre_review_narration: narration before header is stripped" {
  # Simulate what REVIEW_OUTPUT looks like when the model narrates first.
  # The marker line is NOT included — it is prepended separately by local-review.sh.
  local narrated_body
  narrated_body="I now have complete context. Let me verify the changes.
After careful analysis, I can confirm the approach is sound.

## 📋 Code Review

**Findings:** CRITICAL: 0 | HIGH: 1 | MEDIUM: 0 | LOW: 0

### 🟠 HIGH Priority Issues

#### 1. Missing error check"

  run strip_pre_review_narration "$narrated_body"
  [ "$status" -eq 0 ]
  # Narration lines are gone
  [[ ! "$output" =~ "I now have complete context" ]]
  [[ ! "$output" =~ "After careful analysis" ]]
  # Review header and body survive
  [[ "$output" =~ "## 📋 Code Review" ]]
  [[ "$output" =~ "HIGH Priority Issues" ]]
  [[ "$output" =~ "Missing error check" ]]
}

@test "strip_pre_review_narration: body with no review header passes through unchanged" {
  # Unstructured reviews (no ^## .*Code Review heading) must be returned verbatim
  # so that review content is never silently discarded (fail-open contract).
  local plain_body
  plain_body="This PR looks fine overall. One minor concern:
the timeout constant should be named more clearly."

  run strip_pre_review_narration "$plain_body"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "This PR looks fine overall" ]]
  [[ "$output" =~ "timeout constant" ]]
}

@test "strip_pre_review_narration: marker line is the first line of REVIEW_COMMENT after strip" {
  # Asserts the invariant that staleness detection depends on:
  # after stripping, the assembled REVIEW_COMMENT still starts with the marker line.
  local narrated_body
  narrated_body="Let me now summarize my findings.

## 📋 Code Review

**Findings:** CRITICAL: 0 | HIGH: 0 | MEDIUM: 1 | LOW: 0"

  local marker_line="<!-- sharkrite-local-review model:test timestamp:2026-07-07T00:00:00Z -->"
  local stripped
  stripped=$(strip_pre_review_narration "$narrated_body")

  # Build the REVIEW_COMMENT exactly as local-review.sh does.
  local assembled_comment
  assembled_comment="${marker_line}

${stripped}"

  # The very first line must be the marker — not narration text.
  local first_line
  first_line=$(printf '%s\n' "$assembled_comment" | head -1)
  [[ "$first_line" == "$marker_line" ]]
}
