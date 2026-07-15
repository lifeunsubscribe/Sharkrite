#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-documentation.sh
# tests/regression/conventions-catalog-commit.bats
#
# Regression tests for commit_catalog_files() in assess-documentation.sh.
#
# The function:
#   1. Is a no-op when the main worktree HEAD is not on main/master (skips with
#      one info line so user's feature checkouts are never polluted).
#   2. Is a no-op when neither catalog file has changes (empty git status).
#   3. Stages and commits exactly docs/architecture/conventions.md and
#      docs/architecture/tag-index.md when they have changes.
#   4. Handles an untracked tag-index.md (created for the first time).
#   5. Treats push failure as non-fatal: rolls back the commit so local main
#      stays fast-forwardable, prints a push-failed warning, returns 0.
#
# Tests:
#   (a) appended conventions entry → commit created, contains only catalog paths
#   (b) untracked tag-index.md    → added and committed
#   (c) no catalog changes        → no commit created
#   (d) push failure              → non-fatal, commit rolled back, exit 0
#      (d1) no remote configured   → push fails, commit rolled back
#      (d2) remote advanced (non-ff) → push rejected, commit rolled back, local main stays ff-able
#   (e) non-default branch        → skip with info line, no commit

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract commit_catalog_files() from assess-documentation.sh via awk
# without running any top-level script code, then initialise a fake git repo
# in the test tmpdir so git operations have a target.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Minimal docs directory structure the catalogs live in.
  mkdir -p "${RITE_TEST_TMPDIR}/docs/architecture"

  # Seed conventions.md (committed baseline).
  cat > "${RITE_TEST_TMPDIR}/docs/architecture/conventions.md" <<'EOF'
# Conventions Catalog

**Auto-appended on merge — do not hand-edit.**

---

## seed-convention

**Rule:** Seed entry for testing.

**Why:** Provides baseline.

**References:** #1

---
EOF

  # Initialise a git repo so commit_catalog_files() has a real git repo to
  # work with.  Tests can override the branch after setup() returns.
  git -C "$RITE_TEST_TMPDIR" init -q
  git -C "$RITE_TEST_TMPDIR" config user.email "test@example.com"
  git -C "$RITE_TEST_TMPDIR" config user.name "Test"
  # Also suppress advice messages that can leak into output assertions.
  git -C "$RITE_TEST_TMPDIR" config advice.detachedHead false
  # .gitignore the .rite/ dir so it never shows up in `git status --porcelain`
  # output and confuses the catalog-change detection.
  printf '.rite/\n' > "${RITE_TEST_TMPDIR}/.gitignore"
  git -C "$RITE_TEST_TMPDIR" add .
  git -C "$RITE_TEST_TMPDIR" commit -q -m "Initial commit"

  # Rename the initial branch to 'main' so the default-branch guard passes.
  # The name varies between git versions (master vs main); force it to main.
  git -C "$RITE_TEST_TMPDIR" checkout -q -b main 2>/dev/null || \
    git -C "$RITE_TEST_TMPDIR" branch -m main 2>/dev/null || true

  # Set up a bare clone as "origin" so commit_catalog_files() can push
  # successfully in tests that verify a commit is retained after push.
  # Tests that need push to fail can remove the remote first.
  local _bare_dir="${BATS_TEST_TMPDIR}/origin-bare.git"
  git clone --bare -q "$RITE_TEST_TMPDIR" "$_bare_dir"
  git -C "$RITE_TEST_TMPDIR" remote add origin "$_bare_dir"

  # Stubs for print_info / print_warning so they do not produce ANSI noise.
  print_info()    { echo "INFO: $*" ; }
  print_warning() { echo "WARN: $*" ; }
  export -f print_info print_warning

  # Extract commit_catalog_files() from assess-documentation.sh via awk —
  # the same function-extraction harness as conventions-marker-append.bats.
  eval "$(awk '
    /^commit_catalog_files[(][)]/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/assess-documentation.sh")"

  set +u; set +o pipefail  # bats needs its own error handling — leaked strict mode from sourced libs swallows failing tests; keep -e for bats failure detection
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: count commits in the test repo
# ---------------------------------------------------------------------------
commit_count() {
  git -C "$RITE_TEST_TMPDIR" rev-list --count HEAD 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Test (a): appended conventions entry → commit created, staged paths only
# ---------------------------------------------------------------------------

@test "(a) conventions.md changed: commit created containing only catalog paths" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local before_count
  before_count=$(commit_count)

  # Append a new entry (simulates update_conventions_from_marker output).
  cat >> "$conventions_file" <<'EOF'

## new-convention-for-commit-test

**Rule:** Always use git -C for cwd-independent ops.

**Why:** The script may cd into a feature worktree.

**References:** #99

---
EOF

  # The file must be dirty (modified, not staged).
  run git -C "$RITE_TEST_TMPDIR" status --porcelain -- "docs/architecture/conventions.md"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  commit_catalog_files "99"

  # Exactly one new commit must have been created.
  local after_count
  after_count=$(commit_count)
  [ "$after_count" -eq $((before_count + 1)) ]

  # The commit must contain exactly the conventions.md path (tag-index.md
  # does not exist in this test, so only one catalog file changed).
  local changed_paths
  changed_paths=$(git -C "$RITE_TEST_TMPDIR" diff-tree --no-commit-id -r --name-only HEAD)
  echo "$changed_paths" | grep -q "docs/architecture/conventions.md"

  # No unrelated paths must be present in the commit.
  local path_count
  path_count=$(echo "$changed_paths" | grep -cv "docs/architecture/" || true)
  [ "$path_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test (b): untracked tag-index.md → added and committed
# ---------------------------------------------------------------------------

@test "(b) untracked tag-index.md: added to index and committed" {
  local tag_index_file="${RITE_TEST_TMPDIR}/docs/architecture/tag-index.md"
  local before_count
  before_count=$(commit_count)

  # Create tag-index.md for the first time (untracked state — "??" in porcelain).
  cat > "$tag_index_file" <<'EOF'
# Tag Index

**Auto-maintained — do not hand-edit.**

---

## set-e

- conventions.md → new-convention-for-commit-test

---
EOF

  # Confirm it is untracked.
  run git -C "$RITE_TEST_TMPDIR" status --porcelain -- "docs/architecture/tag-index.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "??"* ]]

  commit_catalog_files "100"

  # A new commit must exist.
  local after_count
  after_count=$(commit_count)
  [ "$after_count" -eq $((before_count + 1)) ]

  # The commit must contain tag-index.md.
  git -C "$RITE_TEST_TMPDIR" diff-tree --no-commit-id -r --name-only HEAD | \
    grep -q "docs/architecture/tag-index.md"
}

# ---------------------------------------------------------------------------
# Test (c): no catalog changes → no commit created
# ---------------------------------------------------------------------------

@test "(c) no catalog changes: no commit created" {
  local before_count
  before_count=$(commit_count)

  # Deliberately leave both catalog files clean (no changes since last commit).
  run git -C "$RITE_TEST_TMPDIR" status --porcelain \
    -- "docs/architecture/conventions.md" "docs/architecture/tag-index.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  commit_catalog_files "42"

  # No new commit.
  local after_count
  after_count=$(commit_count)
  [ "$after_count" -eq "$before_count" ]
}

# ---------------------------------------------------------------------------
# Test (d): push failure → non-fatal, commit rolled back, local main stays
#           fast-forwardable.  Two cases:
#   (d1) no remote configured at all
#   (d2) remote has advanced out-of-band (non-fast-forward rejection)
# ---------------------------------------------------------------------------

@test "(d) push failure: non-fatal, commit rolled back, local main stays fast-forwardable, returns 0" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"

  # --- Case (d1): no remote --- #
  # Remove the origin set up in setup() so push fails with "no remote".
  git -C "$RITE_TEST_TMPDIR" remote remove origin 2>/dev/null || true

  # Append a change so commit_catalog_files has something to commit.
  echo "" >> "$conventions_file"
  echo "## push-fail-d1" >> "$conventions_file"

  local count_before_d1
  count_before_d1=$(commit_count)

  # Must return 0 even though push fails.
  run commit_catalog_files "101"
  [ "$status" -eq 0 ]

  # Output must mention push failure (new message does not say "local only").
  echo "$output" | grep -qi "push failed"

  # Commit must have been rolled back so local main is not left diverged.
  local count_after_d1
  count_after_d1=$(commit_count)
  [ "$count_after_d1" -eq "$count_before_d1" ]

  # The catalog change must still be present as uncommitted working-tree state
  # (reset --soft restores the staged index; conventions.md is modified again).
  run git -C "$RITE_TEST_TMPDIR" status --porcelain -- "docs/architecture/conventions.md"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  # --- Case (d2): remote has advanced (non-fast-forward rejection) --- #
  # Re-add origin so we can simulate a remote that is ahead of local main.
  local _bare_dir="${BATS_TEST_TMPDIR}/origin-bare-d2.git"
  git clone --bare -q "$RITE_TEST_TMPDIR" "$_bare_dir"
  git -C "$RITE_TEST_TMPDIR" remote add origin "$_bare_dir"

  # Advance origin/main out-of-band by directly pushing a commit to the bare
  # repo, making local main non-fast-forwardable.
  local _extra_dir="${BATS_TEST_TMPDIR}/extra-clone"
  git clone -q "$_bare_dir" "$_extra_dir" 2>/dev/null
  git -C "$_extra_dir" config user.email "other@example.com"
  git -C "$_extra_dir" config user.name "Other"
  echo "# remote-only change" >> "$_extra_dir/docs/architecture/conventions.md"
  git -C "$_extra_dir" add "docs/architecture/conventions.md"
  git -C "$_extra_dir" commit -q -m "remote-only commit"
  git -C "$_extra_dir" push -q origin main 2>/dev/null

  # Now local main is behind origin/main — push would be non-fast-forward.
  # Verify origin is ahead.
  git -C "$RITE_TEST_TMPDIR" fetch -q origin main 2>/dev/null
  run git -C "$RITE_TEST_TMPDIR" merge-base --is-ancestor FETCH_HEAD HEAD
  # FETCH_HEAD (origin/main) is NOT an ancestor of HEAD (local main) → exit 1
  [ "$status" -eq 1 ]

  # Append a catalog change so commit_catalog_files has something to commit.
  echo "## push-fail-d2" >> "$conventions_file"

  local count_before_d2
  count_before_d2=$(commit_count)

  run commit_catalog_files "102"
  [ "$status" -eq 0 ]

  # Output must mention push failure.
  echo "$output" | grep -qi "push failed"

  # Most importantly: local main must NOT be left with a non-ff commit.
  # After the rollback, local main must still be fast-forwardable to origin/main
  # (i.e. local HEAD is an ancestor of FETCH_HEAD, or equal to it).
  git -C "$RITE_TEST_TMPDIR" fetch -q origin main 2>/dev/null
  run git -C "$RITE_TEST_TMPDIR" merge-base --is-ancestor HEAD FETCH_HEAD
  # HEAD (local) IS an ancestor of FETCH_HEAD (origin) → exit 0
  [ "$status" -eq 0 ]

  local count_after_d2
  count_after_d2=$(commit_count)
  [ "$count_after_d2" -eq "$count_before_d2" ]
}

# ---------------------------------------------------------------------------
# Test (e): non-default branch → skip with info line, no commit
# ---------------------------------------------------------------------------

@test "(e) non-default branch: skip with one info line, no commit created" {
  local conventions_file="${RITE_TEST_TMPDIR}/docs/architecture/conventions.md"
  local before_count
  before_count=$(commit_count)

  # Move the main worktree to a feature branch (not main/master).
  git -C "$RITE_TEST_TMPDIR" checkout -q -b "feat/some-feature"

  # Append a change — if the branch guard were absent this would be committed.
  echo "" >> "$conventions_file"
  echo "## should-not-be-committed" >> "$conventions_file"

  run commit_catalog_files "102"

  # Must return 0.
  [ "$status" -eq 0 ]

  # Must print one info line about the branch.
  echo "$output" | grep -qi "feat/some-feature"

  # No new commit must have been created.
  local after_count
  after_count=$(commit_count)
  [ "$after_count" -eq "$before_count" ]

  # Switch back to main so teardown is clean.
  git -C "$RITE_TEST_TMPDIR" checkout -q main
}
