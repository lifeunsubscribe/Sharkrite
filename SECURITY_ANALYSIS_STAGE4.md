# Security Analysis Report: Tag-Index Stage 4 Implementation

**Date:** 2026-06-27  
**Analysis Scope:** Input validation, shell injection risks, and filesystem access patterns  
**Severity Threshold:** HIGH and above  

---

## Executive Summary

The tag-index system (Stage 4) processes untrusted GitHub issue data (body text, label names) in three new functions:
1. `build_relevant_prior_art()` — resolves tags from issue body/labels and injects catalog sections into dev prompts
2. `lookup_tag_pointers()` — retrieves pointer lines from tag-index based on tag names
3. `slice_section()` — extracts and truncates catalog sections by heading text
4. `relevance_grep()` — searches codebase for referenced functions/paths from issue body

**Findings:** Three security improvements (no critical vulnerabilities). All untrusted input is properly escaped before regex interpolation and is never passed to dynamic execution contexts. Filesystem access is bounded to `docs/architecture/` and `lib/bin/` directories.

---

## Finding 1: ERE Metacharacter Escaping in Label-Derived Tags (Input Validation - GOOD)

**File:** `lib/core/claude-workflow.sh`  
**Function:** `build_relevant_prior_art()`  
**Lines:** 1254–1261  

**Context:**
GitHub issue labels (untrusted) are used to derive candidate tags for the tag-index lookup. Each label is compared against tag-index headings using grep with an ERE (Extended Regular Expression) pattern.

**Code snippet:**
```bash
1254│      while IFS= read -r _lbl; do
1255│        [ -z "$_lbl" ] && continue
1256│        # Check if this label has a corresponding ## heading in tag-index.md
1257│        local _lbl_lc _lbl_escaped
1258│        _lbl_lc=$(echo "$_lbl" | tr '[:upper:]' '[:lower:]')
1259│        # Escape ERE metacharacters in the label before interpolating into the regex
1260│        _lbl_escaped=$(printf '%s' "$_lbl_lc" | sed 's/[.+*?^${}()|[\\]/\\&/g' || true)
1261│        if grep -qiE "^## ${_lbl_escaped}[[:space:]]*$" "$tag_index_file" 2>/dev/null; then
```

**Security Assessment:** PASS  
- **Threat model:** A malicious label name (e.g., "auth.*" or "test)foo") could cause unintended regex matches if passed directly to `grep -qiE`.
- **Mitigation:** Line 1260 escapes all ERE metacharacters (`.[+*?^${}()|[\`) using sed before interpolation into the grep pattern (line 1261). The escaped value is then interpolated safely into a literal pattern context: `^## ${_lbl_escaped}...`. This prevents regex wildcard matching.
- **Verification:** Sed replacement `s/[.+*?^${}()|[\\]/\\&/g` matches all ERE metacharacters; the backslash escape is properly handled by the `\\&` replacement (which produces a literal backslash + matched character in sed's output).

**Recommendations:** No changes required. This pattern is correctly defensive.

---

## Finding 2: Keyword-Grep Path C: Missing Validation Before Regex Interpolation (Input Validation - IMPROVEMENT)

**File:** `lib/core/claude-workflow.sh`  
**Function:** `build_relevant_prior_art()` — Path C  
**Lines:** 1276–1304  

**Context:**
When explicit tags are not provided and labels don't match any tag headings, the system attempts to derive tags by keyword-matching issue body text against tag-index heading names. Each heading extracted from tag-index is escaped and then used in a word-boundary regex against the issue body.

**Code snippet:**
```bash
1281│      while IFS= read -r _heading; do
1282│        # Strip the "## " prefix
1283│        _heading="${_heading#\#\# }"
1284│        _heading="${_heading%"${_heading##*[![:space:]]}"}"  # rtrim
1285│        [ -z "$_heading" ] && continue
1286│        _heading_lc=$(echo "$_heading" | tr '[:upper:]' '[:lower:]')
1287│        # Check if the lowercase heading appears as a whole word in issue body or title.
1288│        # Escape ERE metacharacters first; wrap in \b word-boundary anchors so short
1289│        # headings like "auth" don't match mid-word in "authentication".
1290│        local _heading_escaped
1291│        _heading_escaped=$(printf '%s' "$_heading_lc" | sed 's/[.+*?^${}()|[\\]/\\&/g' || true)
1292│        if echo "$issue_body" | tr '[:upper:]' '[:lower:]' | grep -qE "(^|[^a-z0-9_])${_heading_escaped}([^a-z0-9_]|$)" 2>/dev/null; then
```

**Security Assessment:** PASS (with note)  
- **Threat model:** A tag-index heading containing ERE metacharacters could cause unintended regex matches in line 1292 if not properly escaped.
- **Mitigation:** Line 1291 escapes ERE metacharacters in `_heading_lc` before interpolation. However, the heading text comes from **tag-index.md**, which is a trusted repository file (manually maintained by maintainers, not a user input vector like GitHub issue bodies).
- **Control flow distinction:** Path A (explicit tags in issue body) and Path B (GitHub labels) both involve untrusted input and are properly escaped. Path C derives candidate tags from tag-index headings, which are trusted. The escaping is defensive-in-depth and is correct.
- **Verification:** Same sed pattern as Finding 1; escaping is identical and correct.

**Recommendations:** No changes required. The escaping is defensive and correct even though the source (tag-index headings) is trusted. This is a good practice.

---

## Finding 3: `slice_section()` - Heading Input from Untrusted Pointer Data (Input Validation - GOOD)

**File:** `lib/utils/tag-index.sh`  
**Function:** `slice_section()`  
**Lines:** 737–821  

**Context:**
`slice_section()` is called from `build_relevant_prior_art()` with a heading name extracted from a pointer line. Pointers are stored in tag-index.md (trusted file), but the function must handle untrusted input defensively.

**Call chain (from `claude-workflow.sh`):**
```bash
1320│    while IFS= read -r _ptr; do
1326│    if [[ "$_ptr" =~ (.+)[[:space:]]→[[:space:]](.+)$ ]]; then
1329│        _ptr_heading="${BASH_REMATCH[2]}"  # Extracted from pointer in tag-index.md
1355│      _section=$(slice_section "$_full_catalog_path" "$_ptr_heading" 5120 || true)
```

**Code snippet from `slice_section()`:**
```bash
757│  local catalog_file="$1"
758│  local heading="$2"
759│  local max_bytes="${3:-5120}"
760│
762│  [ -z "$catalog_file" ] && return 0
763│  [ -z "$heading" ]      && return 0
764│  [ -f "$catalog_file" ] || return 0
765│
766│  # Normalise target heading for comparison (lowercase, collapse spaces/dashes)
767│  local norm_target
768│  norm_target=$(echo "$heading" | tr '[:upper:]' '[:lower:]' | tr -s ' -' ' ')
```

**Security Assessment:** PASS  
- **Threat model 1 - Pathname traversal:** A malicious heading containing `../` could theoretically be used to construct a path traversal payload in line 819 when building the truncation notice. However, `$heading` is only used in:
  - Line 768: lowercase/normalize transformation (safe, produces only lowercase+spaces/dashes)
  - Line 812: creates an anchor by lowercasing, space→hyphen, and stripping non-alphanumeric chars: `tr -cd 'a-z0-9-'` — this is inherently safe
  - Line 819: interpolated into the truncation URL: `→ see full: %s#%s` where `%s` (catalog_file) is a path and `%s` (anchor) is a safe slug
  - Never used to construct shell commands or file paths
- **Threat model 2 - Bash regex DoS:** The function uses `[[ =~ ]]` with a user-supplied pattern (line 776: `^##[[:space:]]+(.+)$`) but the pattern is **not** user-supplied; it's a hardcoded H2 detector. The comparison in line 785 (`[ "$norm_this" = "$norm_target" ]`) is a string equality check, not a regex, so it's safe.
- **Threat model 3 - File selection:** The `catalog_file` parameter is user-controlled (passed from `claude-workflow.sh`), but is validated on line 764 (`[ -f "$catalog_file" ] || return 0`). The caller constructs paths under `docs/architecture/` (lines 1342–1349 in `claude-workflow.sh`), and `slice_section()` only reads, never writes.

**Verification:**
- Line 812 anchor derivation: `echo "$heading" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-'` produces only lowercase letters, digits, and hyphens — safe to interpolate
- Line 819 interpolation: uses `printf '%s\n...'` which is safe; no shell evaluation

**Recommendations:** No changes required.

---

## Finding 4: `relevance_grep()` - Untrusted Issue Text with Fixed-String Search (Input Validation - GOOD)

**File:** `lib/utils/relevance-grep.sh`  
**Lines:** 113–172  

**Context:**
`relevance_grep()` extracts file paths and backticked symbols from issue body text (untrusted), then uses fixed-string grep (`--fixed-strings` flag with rg, or `-F` flag with grep fallback) to search for them in the codebase.

**Code snippet:**
```bash
43│  _grep_symbol() {
44│    local symbol="$1"
45│    shift
46│    local dirs=("$@")
47│
48│    [ "${#dirs[@]}" -eq 0 ] && return 0
49│    [ -z "$symbol" ] && return 0
50│
51│    local results=""
52│
53│    if command -v rg >/dev/null 2>&1; then
54│      # rg --no-heading gives "file:line:content" — strip content, keep "file:line"
55│      results=$(rg --fixed-strings --line-number --no-heading \
56│        --max-count 3 "$symbol" "${dirs[@]}" 2>/dev/null \
57│        | head -3 \
58│        | sed 's/\(:[0-9]*\):.*/\1/' \
59│        || true)
60│    else
61│      # grep -rn fallback
62│      results=$(grep -rnF "$symbol" "${dirs[@]}" 2>/dev/null \
63│        | head -3 \
63│        | sed 's/\(:[0-9]*\):.*/\1/' \
65│        || true)
66│    fi
```

**Security Assessment:** PASS  
- **Threat model - Shell injection via grep pattern:** If symbols from issue text were passed as regex patterns (unescaped) to `grep -E`, a malicious symbol like `.*` or `$(rm -rf /)` could cause unintended matches or code execution. However:
  - Line 55: `--fixed-strings` flag on rg treats the input as a literal string, not a regex
  - Line 62: `-F` flag on grep treats the input as a literal string
  - No interpolation into a shell command; the symbol is passed as an argument
- **Threat model - Path traversal via extracted symbols:** Extracted file paths (lines 71–81) are limited by regex to `[a-zA-Z0-9_/][a-zA-Z0-9_/-]*\.(sh|md|conf|bats)` — this prevents `../` sequences and only allows specific file extensions. Directories to search are hardcoded to `lib/` and `bin/` (lines 121–122).

**Code analysis:**
```bash
71│  _extract_file_paths() {
76│    printf '%s' "$text" | grep -oE '[a-zA-Z0-9_/][a-zA-Z0-9_/-]*\.(sh|md|conf|bats)' || true
```
- The regex disallows `../` because `[a-zA-Z0-9_/-]` does not include `.` as the first character after the initial sequence. This prevents traversal paths like `../../../etc/passwd`.
- Extraction is literal pattern matching, not vulnerable to regex DoS because the pattern is hardcoded, not user-derived.

**Recommendations:** No changes required.

---

## Finding 5: Filesystem Scope - Bounded to `docs/architecture/` and `lib/bin/` (Infra - GOOD)

**Files:**  
- `lib/core/claude-workflow.sh` (lines 1210–1213, 1342–1349)
- `lib/utils/tag-index.sh` (lines 38–40, 121–122)
- `lib/utils/relevance-grep.sh` (lines 119–123)

**Context:**
Multiple functions accept user-derived paths (via heading names, pointer extraction, file path extraction) that could theoretically reference arbitrary files. The system bounds filesystem access to specific directories.

**Code analysis:**

**`build_relevant_prior_art()` catalog file resolution (claude-workflow.sh:1342–1349):**
```bash
1342│      case "$_ptr_file" in
1343│        conventions.md)       _full_catalog_path="$conventions_file" ;;
1344│        encountered-issues.md) _full_catalog_path="$encountered_file" ;;
1345│        behavioral-design.md) _full_catalog_path="$behavioral_file" ;;
1346│        *)
1347│          # Try as a path relative to docs/architecture/
1348│          _full_catalog_path="${project_root}/docs/architecture/${_ptr_file}"
```

The default case (line 1348) constructs paths under `${project_root}/docs/architecture/`. However, `_ptr_file` is extracted from a pointer line in the trusted tag-index.md file, so this is a low-risk issue.

**`relevance_grep()` directory bounds (relevance-grep.sh:119–123):**
```bash
119│  # Directories to search — only descend into lib/ and bin/
120│  local search_dirs=()
121│  [ -d "${project_root}/lib" ] && search_dirs+=("${project_root}/lib")
122│  [ -d "${project_root}/bin" ] && search_dirs+=("${project_root}/bin")
```

Grep searches are hard-bounded to `lib/` and `bin/` subdirectories. The `${symbol}` passed to grep is never evaluated as a path; it's a fixed-string search term.

**Security Assessment:** PASS  
- No user-supplied paths are used to construct `cd` commands or shell redirects
- Catalog files are validated to exist before reading (lines 764, 1352)
- Search directories are enumerated explicitly, not constructed from user input
- `relevance_grep()` result processing (lines 56–58, 62–64) only extracts file:line prefixes via sed, which are safe

**Recommendations:** No changes required.

---

## Finding 6: Silent Fallback Chain Behavior (Design - GOOD)

**File:** `lib/core/claude-workflow.sh`  
**Function:** `build_relevant_prior_art()` — fallback chain (lines 1220–1304)  

**Context:**
The function implements a four-path fallback mechanism for tag resolution:
1. Path A: Explicit `<!-- sharkrite-issue-tags -->` block in issue body
2. Path B: Derive tags from GitHub issue labels
3. Path C: Keyword-grep issue body against tag-index headings
4. Fallback: Return empty (caller loads full catalog)

**Code analysis:**
```bash
1226│  if echo "$issue_body" | grep -qF '<!-- sharkrite-issue-tags -->'; then
1240│  if [ -z "$resolved_tags" ] && [ -n "$issue_number" ] && [ "$_has_index" = true ]; then
1276│  if [ -z "$resolved_tags" ] && [ "$_has_index" = true ]; then
1372│  if [ -z "$prior_art_sections" ] && [ -z "$grep_hits" ]; then
1373│    return 0
```

All paths follow a "fail-safe silent return" pattern: if a path produces no results, the function either tries the next path or returns empty (line 1373), triggering a fallback to the full-catalog behavior.

**Security Assessment:** PASS  
- Each path is guarded by `[ -z "$resolved_tags" ]` to prevent overwriting a successful match
- Errors are silently swallowed with `|| true`, preventing script termination
- No path mutates filesystem or calls external commands with user input
- The marker search (line 1226) uses `grep -qF`, which is fixed-string safe

**Recommendations:** No changes required.

---

## Finding 7: Potential Issue - Untrusted Heading in `slice_section()` Anchor Generation (Input Validation - REVIEW)

**File:** `lib/utils/tag-index.sh`  
**Function:** `slice_section()` — anchor generation  
**Lines:** 810–819  

**Context:**
When a section exceeds `MAX_BYTES`, the function generates a truncation URL with a Markdown anchor:
```bash
812│    anchor=$(echo "$heading" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
819│    printf '%s\n...\n→ see full: %s#%s\n' "$truncated" "$catalog_file" "$anchor"
```

The anchor is derived from the input heading and interpolated into a URL string that will be injected into a Claude Code prompt.

**Security Assessment:** PASS (with note)  
- **Threat model 1 - Markdown injection:** The anchor is used as a fragment identifier in a Markdown URL. Even if `$heading` contains malicious Markdown (e.g., `**bold**` or `](http://attacker.com)`), the anchor derivation strips all non-alphanumeric characters (line 812: `tr -cd 'a-z0-9-'`), producing a safe slug.
- **Threat model 2 - Prompt injection:** The output of `slice_section()` is injected into a Claude Code prompt (line 2628 in `claude-workflow.sh`). However, the anchor is a safe slug and cannot contain quotes, backticks, or other special characters that could escape a string context.
- **Source of input:** The heading parameter comes from a pointer extracted from tag-index.md (trusted), not directly from issue body (untrusted).

**Verification:**
- Line 812 transformation: `tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-'`
  - Lowercases all characters
  - Replaces spaces with hyphens
  - Strips all characters except lowercase letters, digits, and hyphens
  - Output is guaranteed to be safe for URL fragments and Markdown

**Recommendations:** No changes required.

---

## Finding 8: `echo` Usage in Non-Sh Context (Code Style - MINOR)

**File:** `lib/utils/tag-index.sh`  
**Functions:** `_ti_extract_ptr_heading()`, `_ti_is_heading_pointed()`, `_ti_count_orphans_in_file()`, etc.  
**Example:** Line 149  

**Context:**
Several functions use `echo` to return values:
```bash
149│  echo "$heading"
164│  echo "$heading" | tr '[:upper:]' '[:lower:]' | tr -s ' -' ' '
```

**Issue:**
The CLAUDE.md guidance (`lib/utils/tag-index.sh` lines 189–191) explicitly states:
> "Uses printf '%s' instead of echo to avoid the echo round-trip, which would mangle pointer text containing backslashes, $() sequences, or other special characters that echo may interpret or expand."

However, several helper functions still use `echo` for return values.

**Security Assessment:** LOW  
- This affects only local helper functions that operate on normalized text (tag names, headings, counts), not untrusted user input
- The CLAUDE.md note refers specifically to pointer text (which may contain backslashes), which is handled correctly via `printf '%s'` in `_ti_build_pointer_text()`
- Heading names extracted from markdown are safe for `echo`

**Recommendations:**
For consistency with the stated principle and defensive robustness, consider replacing `echo` with `printf '%s\n'` in lines:
- 149 (`_ti_extract_ptr_heading()`)
- 164 (`_ti_is_heading_pointed()`) — uses `echo` in a piped context (already safe)
- 224 (`_ti_count_orphans_in_file()`)

This is a style improvement, not a security fix.

---

## Summary Table

| Finding | File | Line | Severity | Status | Recommendation |
|---------|------|------|----------|--------|-----------------|
| 1 | `claude-workflow.sh` | 1260 | — | PASS | No changes |
| 2 | `claude-workflow.sh` | 1291 | — | PASS | No changes |
| 3 | `tag-index.sh` | 768–819 | — | PASS | No changes |
| 4 | `relevance-grep.sh` | 55–65 | — | PASS | No changes |
| 5 | Multiple | 1210–1349 | — | PASS | No changes |
| 6 | `claude-workflow.sh` | 1220–1304 | — | PASS | No changes |
| 7 | `tag-index.sh` | 810–819 | — | PASS | No changes |
| 8 | `tag-index.sh` | 149, 224 | LOW | STYLE | Optional: replace `echo` with `printf '%s\n'` for consistency |

---

## Conclusions

**No critical or high-severity vulnerabilities found.**

All untrusted inputs (GitHub issue body text, label names, pointer lines) are properly validated before use:
- Regex metacharacters are escaped before ERE pattern interpolation
- Fixed-string grep (`-F` / `--fixed-strings`) is used for symbol searches
- Filesystem access is bounded to `docs/architecture/` and `lib/bin/` directories
- All path constructions include existence checks
- Safe character set restrictions are applied to extracted symbols (file paths limited to alphanumeric, slashes, hyphens)

The implementation follows the security-by-design principles documented in CLAUDE.md, including:
- Input validation before regex interpolation (Finding 1, 2)
- Bounded filesystem scope (Finding 5)
- Silent fallback behavior (Finding 6)
- Fixed-string search for untrusted patterns (Finding 4)

**Optional improvement:** Replace `echo` with `printf '%s\n'` in three helper functions (Finding 8) for consistency with the pointer-handling principle documented in CLAUDE.md (line 189).
