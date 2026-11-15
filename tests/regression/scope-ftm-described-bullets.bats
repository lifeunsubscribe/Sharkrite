#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/scope-checker.sh::_scope_path_tokens|_scope_donot_paths|parse_documentation_impact|check_scope_boundary|scope_boundary_is_enforceable
#
# Live (freshup batch 2026-11-12, Dace's report §3.1): 10 of 11 PRs carried a
# scope warning and 0 were real. Runbook "Files to Modify" bullets carry a
# description after the path — `src/schemas/recipe.py` (RecipeListResponse: …)
# — and the whole bullet was added as an allowed pattern, which never matches
# a changed file. Files named in the runbook's Documentation Impact section
# were flagged too. Contract: listed paths are allowed; only the remainder warns.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/utils/scope-checker.sh"
  set +u; set +o pipefail
  REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$REPO"; cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p src/schemas src/routers tests/routers docs
  for f in src/schemas/recipe.py src/schemas/feed.py src/routers/feed.py tests/routers/test_recipes.py \
           tests/routers/test_feed.py docs/handoff.md docs/FreshUp-ADR.md; do echo base > "$f"; done
  git add -A; git commit -qm base; git branch -M main
  git checkout -qb feat/x
  for f in src/schemas/recipe.py src/schemas/feed.py src/routers/feed.py tests/routers/test_recipes.py \
           tests/routers/test_feed.py docs/handoff.md docs/FreshUp-ADR.md; do echo change >> "$f"; done
  git commit -qam change
  BODY=$(cat <<'B'
**Claude Context**:
Files to Read:
- `src/models.py`

Files to Modify:
- `src/schemas/recipe.py` (`RecipeListResponse`: `source_url: Optional[str] = None`)
- `src/schemas/feed.py` (`RecipeCardSchema`: same two fields)
- `tests/routers/test_recipes.py`, `tests/services/test_feed_service.py` (extend)
- `docs/handoff.md` (the two gap rows → Closed, backend)

**Scope Boundary**:
- DO: add the two fields to both schemas, populate them with one extra query, test, and update the two gap rows
- DO NOT: touch the frontend

**Documentation Impact**:
Adds two response fields → `docs/handoff.md` rows set to Closed. Verified `docs/FreshUp-ADR.md` Section 0 names the schema — update that clause.
B
)
}

@test "tokens: described bullets yield their paths, comma-separated paths both, prose nothing" {
  run _scope_path_tokens <<< "$(parse_files_to_modify "$BODY")"
  [[ "$output" == *"src/schemas/recipe.py"* ]]
  [[ "$output" == *"tests/services/test_feed_service.py"* ]]
  [[ "$output" != *"recipelistresponse"* ]]
  [[ "$output" != *"source_url"* ]]
  run _scope_path_tokens <<< "$(parse_documentation_impact "$BODY")"
  [[ "$output" == *"docs/freshup-adr.md"* ]]
}

@test "check_scope_boundary: listed and documentation-impact files are in scope; only the unlisted remain" {
  run check_scope_boundary "$BODY" "$REPO" main
  [[ "$output" != *"src/schemas/recipe.py"* ]]
  [[ "$output" != *"src/schemas/feed.py"* ]]
  [[ "$output" != *"tests/routers/test_recipes.py"* ]]
  [[ "$output" != *"docs/handoff.md"* ]]
  [[ "$output" != *"docs/FreshUp-ADR.md"* && "$output" != *"docs/freshup-adr.md"* ]]
  [[ "$output" == *"src/routers/feed.py"* ]]
}

# ---------------------------------------------------------------------------
# DO NOT is enforced by path, never by prose word (freshup batch 2026-11-15,
# Dace's report section 3.2): "DO NOT: make chips clickable or link them to
# filters" flagged every frontend/ file because "on" is inside "frontend", and
# the listed themeRows.ts was flagged by the words "theme" and "rows".
# ---------------------------------------------------------------------------
_donot_body() { # $1 = the DO NOT bullet text
  cat <<B
**Claude Context**:
Files to Modify:
- \`src/schemas/recipe.py\` (two fields)
- \`src/schemas/feed.py\`
- \`tests/routers/test_recipes.py\`, \`tests/routers/test_feed.py\`
- \`docs/handoff.md\`, \`docs/FreshUp-ADR.md\`

**Scope Boundary**:
- DO: add the two fields under \`src/routers/\` and both schemas
- DO NOT: $1
B
}

@test "donot paths: a prose bullet names no path; a path inside prose is extracted; a lone path is kept" {
  run _scope_donot_paths <<< "rename the recipe schemas or reorder the feed on any router"
  [ -z "$output" ]
  run _scope_donot_paths <<< "change \`src/routers/feed.py\` or the card component"
  [ "$output" = "src/routers/feed.py" ]
  run _scope_donot_paths <<< "secret.sh"
  [ "$output" = "secret.sh" ]
  run _scope_donot_paths <<< "\`Lib/Core/\`"
  [ "$output" = "lib/core/" ]
}

@test "check_scope_boundary: prose DO NOT words never flag a file (recipe, schemas, feed, on)" {
  run check_scope_boundary "$(_donot_body "rename the recipe schemas or reorder the feed on any router")" "$REPO" main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_scope_boundary: a path named inside a prose DO NOT bullet is flagged despite a DO directory" {
  run check_scope_boundary "$(_donot_body "change \`src/routers/feed.py\` or the card component")" "$REPO" main
  [ "$status" -eq 1 ]
  [ "$output" = "VIOLATION: src/routers/feed.py" ]
}

@test "check_scope_boundary: a file named exactly in Files to Modify is in scope even when a DO NOT bullet mentions it" {
  run check_scope_boundary "$(_donot_body "change the validators in \`src/schemas/recipe.py\`")" "$REPO" main
  [ "$status" -eq 0 ]
  [[ "$output" != *"src/schemas/recipe.py"* ]]
}
