#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/conflict-resolver.sh
# tests/regression/conflict-marker-false-positives.bats
#
# Regression tests for conflict-marker false-positive detection.
#
# Bug: conflict-resolver.sh Step 6 Check 2 used '^(=======)' which matched
# any line starting with '=======' — including markdown setext underlines
# (e.g. "========") and doc separators (e.g. "=======foo"). This caused
# a correctly-resolved file to be flagged as unresolved, aborting a good
# resolution.
#
# Fix: tightened the regex to:
#   ^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]])
#
# This file tests the check-2 regex specifically, independently of a full
# resolver run. That isolation keeps the tests fast and focused.

load '../helpers/setup.bash'
load '../helpers/git-fixtures.bash'

# ---------------------------------------------------------------------------
# Setup helpers
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  BARE_REMOTE=$(create_bare_remote "origin")
  FIXTURE_REPO=$(create_fixture_repo "$BARE_REMOTE")

  export RITE_PROJECT_ROOT="$FIXTURE_REPO"
  export RITE_DATA_DIR=".rite"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"
  export RITE_LOG_FILE="/dev/null"
  unset RITE_VERBOSE

  cd "$FIXTURE_REPO"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: run the same grep used by conflict-resolver.sh Check 2 against
# a given string (via stdin).  Returns 0 if the grep matched (i.e. a conflict
# marker was detected), non-zero otherwise.
# ---------------------------------------------------------------------------
_has_conflict_marker() {
  grep -qE '^(<<<<<<<[[:space:]]|=======$|>>>>>>>[[:space:]])' "$1" 2>/dev/null
}

# ===========================================================================
# TRUE POSITIVES — real conflict markers must still be detected
# ===========================================================================

@test "conflict-marker check: detects real open-marker '<<<<<<< HEAD'" {
  printf '<<<<<<< HEAD\nsome content\n' > test_file.txt
  _has_conflict_marker test_file.txt
}

@test "conflict-marker check: detects real separator '======='" {
  printf '=======\n' > test_file.txt
  _has_conflict_marker test_file.txt
}

@test "conflict-marker check: detects real close-marker '>>>>>>> branch'" {
  printf '>>>>>>> some-branch\n' > test_file.txt
  _has_conflict_marker test_file.txt
}

@test "conflict-marker check: detects full conflict block" {
  printf '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature/x\n' > test_file.txt
  _has_conflict_marker test_file.txt
}

# ===========================================================================
# FALSE POSITIVES — these must NOT be flagged as conflict markers
# ===========================================================================

@test "conflict-marker check: does NOT flag markdown setext underline (8 equals)" {
  printf 'Heading\n========\n' > test_file.md
  ! _has_conflict_marker test_file.md
}

@test "conflict-marker check: does NOT flag long doc separator (20 equals)" {
  printf '====================\n' > test_file.txt
  ! _has_conflict_marker test_file.txt
}

@test "conflict-marker check: does NOT flag '=======' followed by text (e.g. doc separator)" {
  printf '=======foo\n' > test_file.txt
  ! _has_conflict_marker test_file.txt
}

@test "conflict-marker check: does NOT flag '=======  ' (trailing spaces after separator)" {
  # A setext underline may have trailing spaces; git conflict separator does not
  printf '=======  \n' > test_file.txt
  ! _has_conflict_marker test_file.txt
}

@test "conflict-marker check: does NOT flag '<<<<<<<' without trailing space (bare 7 <)" {
  # Real markers always have a space + branch; a bare '<<<<<<< ' should also match,
  # but bare '<<<<<<<' with no space is not a real conflict marker
  printf '<<<<<<<\n' > test_file.txt
  ! _has_conflict_marker test_file.txt
}

@test "conflict-marker check: does NOT flag '>>>>>>>' without trailing space (bare 7 >)" {
  printf '>>>>>>>\n' > test_file.txt
  ! _has_conflict_marker test_file.txt
}

# ===========================================================================
# RESOLVER INTEGRATION: resolved file with setext underlines passes Check 2
#
# This simulates the actual bug: Claude resolves a conflict in a .md file
# that uses setext-style headings (======= underlines). With the old regex
# the resolver would abort the good resolution, returning 1. With the fix
# it accepts the resolved file and returns 0.
# ===========================================================================

@test "resolver: accepts resolved file containing setext-style '=======' heading underline" {
  local BRANCH_NAME="fix/setext-false-positive-$$"

  # Create a markdown file with a setext heading (=======) on main
  cat > docs.md <<'EOF'
My Section
=======
Some content here.
EOF
  git add docs.md
  git commit -m "Add docs with setext heading on main" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Feature branch: modify docs.md differently (creates a conflict)
  git checkout -b "$BRANCH_NAME" main >/dev/null 2>&1
  cat > docs.md <<'EOF'
My Section
=======
Branch added this line.
EOF
  git add docs.md
  git commit -m "Branch modifies docs" >/dev/null 2>&1

  # Advance origin/main with conflicting docs.md content
  git checkout main >/dev/null 2>&1
  cat > docs.md <<'EOF'
My Section
=======
Main added this line instead.
EOF
  git add docs.md
  git commit -m "Main modifies docs (conflicts with branch)" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  # Return to feature branch
  git checkout "$BRANCH_NAME" >/dev/null 2>&1

  # Abort pattern used by real callers
  git merge origin/main --no-edit 2>/dev/null || true
  git merge --abort 2>/dev/null || true

  source "$RITE_LIB_DIR/utils/conflict-resolver.sh"

  # Provider stub: resolves the conflict while PRESERVING the setext underline
  provider_run_agentic_session() {
    local _conflicted
    _conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      # Write resolved content that still has the setext '=======' underline
      cat > "$_f" <<'RESOLVED'
My Section
=======
Resolved: kept branch intent, setext heading preserved.
RESOLVED
      git add "$_f"
    done <<< "$_conflicted"
    return 0
  }
  load_provider() { return 0; }

  local result=0
  attempt_claude_merge_resolution \
    --branch-name "$BRANCH_NAME" \
    --merge-target "origin/main" 2>/dev/null || result=$?

  # With the fix, the resolver must return 0 (success) even though the
  # resolved file still contains '=======' as a setext heading underline.
  [ "$result" -eq 0 ]
}
