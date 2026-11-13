#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/scope-checker.sh::_scope_path_tokens|parse_documentation_impact|check_scope_boundary|scope_boundary_is_enforceable
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
