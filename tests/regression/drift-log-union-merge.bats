#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/drift-log.sh, lib/utils/conflict-resolver.sh
#
# Deterministic union merge for the append-only drift log (#1319).
#
# A drift-log conflict has exactly one correct resolution — union both sides,
# order by recorded: — so it needs no judgment and no provider call. Two of the
# three conflicts in dogfooding logs were this file (#1231 pr:1299, #1143
# pr:1312), each burning a 60-274s session.
#
# The load-bearing test here is "shared closing delimiter". When both sides
# append at the same spot, git emits a line-level hunk and DEDUPLICATES the
# closing delimiter, so the conflicted file has two openers and one closer.
# A first implementation parsed the conflicted file with markers stripped and
# silently DROPPED the first entry. Losing an append-only entry is the worst
# outcome available here, which is why entries are read from git's stage blobs
# (:2 ours, :3 theirs) where each side is a complete, well-formed log.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/markers.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$RITE_LIB_DIR/utils/drift-log.sh"
  set +u

  REPO="$BATS_TEST_TMPDIR/driftrepo"
  mkdir -p "$REPO/docs"
  cd "$REPO" || return 1
  git init -q .
  git config user.email t@t
  git config user.name t
  printf '# Sharkrite Drift Log\n\n---\n' > docs/sharkrite-drift-log.md
  git add -A && git commit -qm base
}

_entry() { # $1=pr $2=issue $3=iso
  printf '\n<!-- sharkrite-doc-drift pr:%s issue:%s recorded:%s -->\n**Changed files**: lib/core/f%s.sh\n<!-- /sharkrite-doc-drift -->\n' "$1" "$2" "$3" "$1"
}

# Build a two-sided conflict: side appends $1, main appends $2.
_make_conflict() {
  git checkout -qb side
  _entry "$1" "$1" "$3" >> docs/sharkrite-drift-log.md
  git commit -qam side
  git checkout -q -
  _entry "$2" "$2" "$4" >> docs/sharkrite-drift-log.md
  git commit -qam main
  git merge side >/dev/null 2>&1 || true
}

_count() { grep -c "sharkrite-doc-drift pr:[0-9]" docs/sharkrite-drift-log.md || true; }
_markers() { grep -cE '^<<<<<<< |^=======$|^>>>>>>> ' docs/sharkrite-drift-log.md || true; }

@test "shared closing delimiter: BOTH entries survive (no data loss)" {
  _make_conflict 1312 1304 "2026-10-19T00:02:00Z" "2026-10-18T20:55:12Z"
  # Confirm the fixture really is the shared-closer shape.
  [ "$(grep -c '<!-- /sharkrite-doc-drift -->' docs/sharkrite-drift-log.md)" -eq 1 ]
  [ "$(grep -c 'sharkrite-doc-drift pr:[0-9]' docs/sharkrite-drift-log.md)" -eq 2 ]

  run drift_log_union_merge "docs/sharkrite-drift-log.md"
  [ "$status" -eq 0 ]
  [ "$(_count)" -eq 2 ]
  [ "$(_markers)" -eq 0 ]
}

@test "entries are ordered by recorded:, not by side" {
  # side carries the LATER timestamp; main the earlier. Output must be
  # chronological regardless of which side contributed which.
  _make_conflict 1312 1304 "2026-10-19T00:02:00Z" "2026-10-18T20:55:12Z"
  drift_log_union_merge "docs/sharkrite-drift-log.md"

  local _order
  _order=$(grep -oE 'pr:[0-9]+' docs/sharkrite-drift-log.md | tr '\n' ' ')
  [ "$_order" = "pr:1304 pr:1312 " ]
}

@test "an entry present on both sides appears once" {
  # Same entry committed to both branches, plus one unique to each.
  _entry 1300 1300 "2026-10-17T00:00:00Z" >> docs/sharkrite-drift-log.md
  git commit -qam shared
  _make_conflict 1312 1304 "2026-10-19T00:02:00Z" "2026-10-18T20:55:12Z"

  drift_log_union_merge "docs/sharkrite-drift-log.md"
  [ "$(_count)" -eq 3 ]
  [ "$(grep -c 'pr:1300 ' docs/sharkrite-drift-log.md)" -eq 1 ]
}

@test "two different entries with the same timestamp both survive" {
  _make_conflict 2 1 "2026-10-01T00:00:00Z" "2026-10-01T00:00:00Z"
  drift_log_union_merge "docs/sharkrite-drift-log.md"
  [ "$(_count)" -eq 2 ]
}

@test "the canonical header is restored" {
  _make_conflict 1312 1304 "2026-10-19T00:02:00Z" "2026-10-18T20:55:12Z"
  drift_log_union_merge "docs/sharkrite-drift-log.md"
  grep -q '^# Sharkrite Drift Log$' docs/sharkrite-drift-log.md
  grep -q 'do not hand-edit entries' docs/sharkrite-drift-log.md
}

@test "falls back when there are no conflict stages (not a merge conflict)" {
  # Clean file, no merge in progress — nothing authoritative to union.
  run drift_log_union_merge "docs/sharkrite-drift-log.md"
  [ "$status" -ne 0 ]
}

@test "falls back when the conflict is in header prose, not entries" {
  git checkout -qb side
  printf 'side prose\n' >> docs/sharkrite-drift-log.md
  git commit -qam side
  git checkout -q -
  printf 'main prose\n' >> docs/sharkrite-drift-log.md
  git commit -qam main
  git merge side >/dev/null 2>&1 || true

  run drift_log_union_merge "docs/sharkrite-drift-log.md"
  [ "$status" -ne 0 ]
  # The conflicted file must be left untouched for the LLM resolver.
  grep -qE '^<<<<<<< ' docs/sharkrite-drift-log.md
}

@test "falls back on a missing file and on an empty argument" {
  run drift_log_union_merge "docs/nope.md"
  [ "$status" -ne 0 ]
  run drift_log_union_merge ""
  [ "$status" -ne 0 ]
}

@test "drift_log_relpath matches git's repo-relative path output" {
  _make_conflict 1312 1304 "2026-10-19T00:02:00Z" "2026-10-18T20:55:12Z"
  local _rel _u
  _rel=$(drift_log_relpath)
  _u=$(git diff --name-only --diff-filter=U | head -1)
  [ "$_rel" = "$_u" ]
}

@test "structural: the resolver never parses the conflicted file for entries" {
  # The data-loss regression. Entries must come from the stage blobs only.
  grep -q 'git show ":2:' "$RITE_LIB_DIR/utils/drift-log.sh"
  grep -q 'git show ":3:' "$RITE_LIB_DIR/utils/drift-log.sh"
  # No conflict-marker stripping in the extractor — that was the broken design.
  ! grep -q 'next.*<<<<<<<' "$RITE_LIB_DIR/utils/drift-log.sh"
}

@test "structural: conflict-resolver carries no sharkrite-* path literal" {
  # Rule 19 allowlists drift-log.sh as the format owner; the resolver matches
  # via drift_log_relpath so the literal lives in exactly one place.
  grep -q 'drift_log_relpath' "$RITE_LIB_DIR/utils/conflict-resolver.sh"
  ! grep -qE 'sharkrite-drift-log' "$RITE_LIB_DIR/utils/conflict-resolver.sh"
}
