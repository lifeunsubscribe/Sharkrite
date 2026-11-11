#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-review-issues.sh, lib/core/assess-and-resolve.sh, lib/utils/scratchpad-manager.sh::create_tech_debt_issues, lib/utils/reconcile-followups.sh::_reconcile_pool|reconcile_batch_followups
#
# Deferred-findings pool — integration contract at the four filing sites.
# Structural tests pin the routing (what goes to the pool, what stays an
# individual issue); the reconcile test exercises _reconcile_pool against a
# real git fixture with stubbed classifier and gh.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  ARI="$RITE_LIB_DIR/core/assess-review-issues.sh"
  AAR="$RITE_LIB_DIR/core/assess-and-resolve.sh"
  SPM="$RITE_LIB_DIR/utils/scratchpad-manager.sh"
  RCF="$RITE_LIB_DIR/utils/reconcile-followups.sh"
}

# ── assess-review-issues.sh (per-item LATER path) ───────────────────────────

@test "per-item LATER path: non-security findings are routed to followup_pool_append before the dedup stages" {
  pool=$(grep -n 'followup_pool_append "${PR_NUMBER:-}" "${RITE_ISSUE_NUMBER:-}"' "$ARI" | head -1 | cut -d: -f1)
  stage1=$(grep -n '# Stage 1: fuzzy title match against cached issue list' "$ARI" | head -1 | cut -d: -f1)
  [ -n "$pool" ] && [ -n "$stage1" ] && [ "$pool" -lt "$stage1" ]
}

@test "per-item LATER path: security findings bypass the pool (security floor)" {
  grep -q 'if followup_pool_enabled && ! echo "${ITEM_CATEGORY:-}" | grep -qi "security"; then' "$ARI"
}

@test "per-item LATER path: pool failure falls through to the individual issue (no silent drop)" {
  grep -q 'Pool unavailable — filing individually' "$ARI"
}

@test "per-item LATER path: pool number is passed back so assess-and-resolve skips its rollup" {
  awk '/followup_pool_append "\$\{PR_NUMBER:-\}"/{f=1} f&&/RITE_PER_ITEM_ISSUES_FILE/{found=1} /# Stage 1: fuzzy/{exit} END{exit !found}' "$ARI"
}

@test "per-item LATER path: PR body Follow-up Issues section lists the pool" {
  grep -q -- '- Pooled: ${POOLED_ISSUES:-none}' "$ARI"
}

@test "assessment prompt: NOW bar is the three classes and names the regression clause" {
  grep -q 'ONLY these three classes qualify' "$ARI"
  grep -q 'A REGRESSION THIS PR INTRODUCED' "$ARI"
  ! grep -q 'Quick fixes (<30min) that a reasonable engineer would include' "$ARI"
  ! grep -q 'Changes in the SAME file/module that are directly related' "$ARI"
  # SCOPE BAR (#791) untouched
  grep -q "SCOPE BAR (the issue's OWN acceptance criteria are never deferrable):" "$ARI"
}

# ── assess-and-resolve.sh (per-finding loop) ────────────────────────────────

@test "per-finding loop: ACTIONABLE_LATER headers go to the pool; NOW headers do not" {
  grep -q '\*" - ACTIONABLE_LATER"\*)' "$AAR"
  # the pool call is inside that case arm, after the [GATE] skip
  gate=$(grep -n "'### \[GATE\]'\*)" "$AAR" | head -1 | cut -d: -f1)
  pool=$(grep -n 'followup_pool_append "${PR_NUMBER:-}" "${ISSUE_NUMBER:-}"' "$AAR" | head -1 | cut -d: -f1)
  [ -n "$gate" ] && [ -n "$pool" ] && [ "$gate" -lt "$pool" ]
}

@test "per-finding loop: security findings bypass the pool" {
  awk '/ - ACTIONABLE_LATER"\*\)/{f=1} f&&/grep -qi "security"/{found=1; exit} END{exit !found}' "$AAR"
}

@test "assess-and-resolve sources the pool library in its functions-only region" {
  src=$(grep -n 'source "$RITE_LIB_DIR/utils/followup-pool.sh"' "$AAR" | head -1 | cut -d: -f1)
  guard=$(grep -n 'RITE_SOURCE_FUNCTIONS_ONLY:-}" = "1"' "$AAR" | head -1 | cut -d: -f1)
  [ -n "$src" ] && [ -n "$guard" ] && [ "$src" -lt "$guard" ]
}

# ── scratchpad-manager.sh (encountered issues) ──────────────────────────────

@test "encountered issues are pooled with the origin issue as source; individual create is the fallback" {
  pool=$(grep -n 'followup_pool_append "" "${origin_number:-}"' "$SPM" | head -1 | cut -d: -f1)
  create=$(grep -n 'gh_safe issue create --title "$issue_title"' "$SPM" | head -1 | cut -d: -f1)
  [ -n "$pool" ] && [ -n "$create" ] && [ "$pool" -lt "$create" ]
  grep -q 'Pool unavailable — filing encountered issue individually' "$SPM"
}

# ── reconcile-followups.sh ──────────────────────────────────────────────────

@test "reconcile routes pool issues to _reconcile_pool by marker before the per-issue tiers" {
  route=$(grep -n '_reconcile_pool "$_fu_num" "$_issue_body"' "$RCF" | head -1 | cut -d: -f1)
  tier1=$(grep -n 'Tier 1: deterministic filter' "$RCF" | head -1 | cut -d: -f1)
  [ -n "$route" ] && [ -n "$tier1" ] && [ "$route" -lt "$tier1" ]
}

@test "_reconcile_pool: resolved entry is moved out, unchanged file is skipped with zero LLM calls, counts reported" {
  export RITE_STATE_DIR="$BATS_TEST_TMPDIR/state"; mkdir -p "$RITE_STATE_DIR"
  export RITE_PROJECT_ROOT="$BATS_TEST_TMPDIR/repo"; mkdir -p "$RITE_PROJECT_ROOT"
  git -C "$RITE_PROJECT_ROOT" init -q
  git -C "$RITE_PROJECT_ROOT" config user.email t@t; git -C "$RITE_PROJECT_ROOT" config user.name t
  mkdir -p "$RITE_PROJECT_ROOT/lib"; echo a > "$RITE_PROJECT_ROOT/lib/a.sh"; echo b > "$RITE_PROJECT_ROOT/lib/b.sh"
  git -C "$RITE_PROJECT_ROOT" add .; git -C "$RITE_PROJECT_ROOT" commit -qm base
  sha=$(git -C "$RITE_PROJECT_ROOT" rev-parse --short HEAD)
  echo a2 > "$RITE_PROJECT_ROOT/lib/a.sh"; git -C "$RITE_PROJECT_ROOT" commit -qam change-a
  git -C "$RITE_PROJECT_ROOT" branch -q target

  source "$RITE_LIB_DIR/utils/followup-pool.sh"
  source "$RCF"
  set +u; set +o pipefail
  _diag() { :; }
  print_warning() { :; }
  CLASSIFY_CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CLASSIFY_CALLS"
  _classify_finding() { echo "$1" >> "$CLASSIFY_CALLS"; echo resolved; }
  _get_code_region() { echo region; }
  POOL_BODY_FILE="$BATS_TEST_TMPDIR/pool.body"
  cat > "$POOL_BODY_FILE" <<B
<!-- sharkrite-followup-pool:run-x -->
intro

## Entries

### Changed file finding
<!-- sharkrite-pool-entry:k-changed --><!-- sharkrite-finding-location:lib/a.sh:1 --><!-- sharkrite-finding-sha:${sha} -->
- **Finding:** a

### Unchanged file finding
<!-- sharkrite-pool-entry:k-same --><!-- sharkrite-finding-location:lib/b.sh:1 --><!-- sharkrite-finding-sha:${sha} -->
- **Finding:** b

## Resolved during run

B
  STATE_FILE="$BATS_TEST_TMPDIR/pool.state"; echo open > "$STATE_FILE"
  gh_safe() {
    case "$1 $2" in
      "issue view") cat "$POOL_BODY_FILE" ;;
      "issue edit") shift 2; while [ $# -gt 0 ]; do case "$1" in --body-file) cp "$2" "$POOL_BODY_FILE"; shift 2;; *) shift;; esac; done ;;
      "issue close") echo closed > "$STATE_FILE" ;;
    esac
  }
  out=$(_reconcile_pool 900 "$(cat "$POOL_BODY_FILE")" target triage-model)
  [ "$out" = "1 0 0 1 1" ]
  [ "$(wc -l < "$CLASSIFY_CALLS" | tr -d ' ')" = "1" ]
  grep -q '^900/k-changed$' "$CLASSIFY_CALLS"
  grep -qF -- '- ~~Changed file finding~~ — resolved in' "$POOL_BODY_FILE"
  grep -q '^### Unchanged file finding$' "$POOL_BODY_FILE"
  ! grep -q '^### Changed file finding$' "$POOL_BODY_FILE"
  [ "$(cat "$STATE_FILE")" = open ]
}

@test "all three call sites consult the operator toggle before pooling (disabled pool is silent)" {
  grep -q 'if followup_pool_enabled && ! echo "${ITEM_CATEGORY:-}"' "$ARI"
  grep -q 'followup_pool_enabled && \\' "$AAR"
  grep -q 'RITE_FOLLOWUP_POOL:-true}" != "false"' "$SPM"
  grep -q '^# RITE_FOLLOWUP_POOL=false' "$RITE_REPO_ROOT/config/project.conf.example"
}
