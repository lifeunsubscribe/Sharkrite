#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-runners.sh::_expand_workspace_dirs|_changed_files_to_workspace_dirs|_node_workspace_runners_resolvable|_node_workspace_has_missing_entry_points|_node_build_workspace_packages
# tests/regression/workspace-pattern-expansion.bats
#
# Workspace-pattern expansion existed in four near-identical copies (#1351):
# _node_workspace_runners_resolvable, _node_workspace_has_missing_entry_points,
# _node_build_workspace_packages, _changed_files_to_workspace_dirs. Each nested
# a `case` inside a process substitution, which bash 3.2 cannot parse — so
# gate-runners.sh refused to load under macOS /bin/bash and took every caller
# with it (#1361 fallout; #1374/#1378 were the containment).
#
# One implementation now: _expand_workspace_dirs. It is the union of the four
# (the literal-path arm only one copy had), prunes node_modules in BOTH find
# arms (the bounded arm never did, so a vendored dep could surface as a
# workspace), keeps #1344's three-way exclusion, and always returns 0.
#
# Tests in this file:
#   PARSE
#     1. gate-runners.sh parses under real /bin/bash
#     2. exactly one implementation — no per-caller copy survives
#   BEHAVIOR (fixture monorepo)
#     3. packages/**   recurses to any depth
#     4. apps/*        is bounded to one level
#     5. packages/*-utils  suffix glob matches only *-utils
#     6. apps/*/pkg/**  mid-pattern * then ** reaches nested dirs (#1349)
#     7. tools/cli     literal path resolves
#     7. !packages/legacy  excludes the dir AND its subtree (#1344 three-way)
#     8. node_modules is pruned in the recursive arm
#     9. node_modules is pruned in the bounded arm (the fix)
#    10. output is deduplicated across overlapping patterns
#    11. no match → empty output, exit 0 (callers run it under set -e)
#   END TO END
#    12. _changed_files_to_workspace_dirs emits relative dirs with package.json
#        that contain a changed file, and nothing else

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GATE_RUNNERS="$REPO_ROOT/lib/utils/gate-runners.sh"

setup() {
  [ -f "$GATE_RUNNERS" ] || { echo "FATAL: $GATE_RUNNERS not found" >&2; return 1; }
  _fx=$(mktemp -d)
  for d in packages/alpha packages/beta packages/scope/nested packages/deep/a/b \
           packages/str-utils packages/fmt-utils packages/legacy packages/legacy/inner \
           apps/web apps/api apps/web/pkg/core apps/api/pkg/core tools/cli \
           packages/alpha/node_modules/evil packages/node_modules; do
    mkdir -p "$_fx/$d"; echo '{"name":"x"}' > "$_fx/$d/package.json"
  done
}

teardown() {
  [ -n "${_fx:-}" ] && rm -rf "$_fx" || true
}

# Expand $1 (newline-separated patterns) against the fixture; print rel paths.
_expand() {
  bash -c "
    set -uo pipefail
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    source '$GATE_RUNNERS'
    _expand_workspace_dirs '$_fx' \"\$1\" | sed 's#^$_fx/##'
  " _ "$1"
}

@test "parse: gate-runners.sh parses under real /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  /bin/bash -n "$GATE_RUNNERS" 2>/dev/null || {
    echo "FAIL: not parseable under /bin/bash:" >&2
    /bin/bash -n "$GATE_RUNNERS" 2>&1 | head -3 >&2
    return 1
  }
}

@test "parse: exactly one implementation survives" {
  _defs=$(grep -c '^_expand_workspace_dirs()' "$GATE_RUNNERS" || true)
  [ "$_defs" -eq 1 ] || { echo "FAIL: expected 1 definition, found $_defs" >&2; return 1; }
  _copies=$(grep -cE '_(nwr|nhme|nbwp)_' "$GATE_RUNNERS" || true)
  [ "$_copies" -eq 0 ] || {
    echo "FAIL: $_copies per-caller copy reference(s) remain:" >&2
    grep -nE '_(nwr|nhme|nbwp)_' "$GATE_RUNNERS" | head -5 >&2
    return 1
  }
  _calls=$(grep -c '_expand_workspace_dirs "' "$GATE_RUNNERS" || true)
  [ "$_calls" -ge 4 ] || { echo "FAIL: expected >=4 call sites, found $_calls" >&2; return 1; }
}

@test "packages/** recurses to any depth" {
  run _expand "packages/**"
  for d in packages/alpha packages/scope/nested packages/deep/a/b; do
    echo "$output" | grep -qx "$d" || { echo "FAIL: missing $d in: $output" >&2; return 1; }
  done
}

@test "apps/* is bounded to one level" {
  run _expand "apps/*"
  [ "$output" = "apps/api
apps/web" ] || { echo "FAIL: expected exactly apps/api + apps/web, got: $output" >&2; return 1; }
}

@test "packages/*-utils matches only *-utils" {
  run _expand "packages/*-utils"
  [ "$output" = "packages/fmt-utils
packages/str-utils" ] || { echo "FAIL: got: $output" >&2; return 1; }
}

@test "mid-pattern * with trailing ** reaches nested packages (#1349)" {
  # apps/*/pkg/** — the first literal segment is apps/, then a wildcard, then
  # more literal path, then **. Every old copy quoted the pre-** prefix as a
  # literal, so the mid-pattern * never expanded and this matched nothing.
  run _expand "apps/*/pkg/**"
  [ "$output" = "apps/api/pkg/core
apps/web/pkg/core" ] || {
    echo "FAIL: expected both */pkg/core dirs and nothing shallower; got: '$output'" >&2
    return 1
  }
}

@test "literal path resolves" {
  run _expand "tools/cli"
  [ "$output" = "tools/cli" ] || { echo "FAIL: got: $output" >&2; return 1; }
}

@test "!exclusion removes the dir and its subtree" {
  run _expand "packages/**
!packages/legacy"
  echo "$output" | grep -q "legacy" && {
    echo "FAIL: legacy or legacy/inner leaked past the exclusion: $output" >&2
    return 1
  }
  echo "$output" | grep -qx "packages/alpha" || { echo "FAIL: exclusion removed too much: $output" >&2; return 1; }
}

@test "node_modules is pruned in the recursive arm" {
  run _expand "packages/**"
  echo "$output" | grep -q "node_modules" && { echo "FAIL: vendored dir surfaced: $output" >&2; return 1; }
  return 0
}

@test "node_modules is pruned in the bounded arm" {
  # packages/node_modules has a package.json; the old bounded arm did not prune
  # and reported it as a workspace.
  run _expand "packages/*"
  echo "$output" | grep -q "node_modules" && {
    echo "FAIL: packages/node_modules reported as a workspace: $output" >&2
    return 1
  }
  return 0
}

@test "output is deduplicated across overlapping patterns" {
  run _expand "packages/**
packages/*-utils
packages/alpha"
  _n=$(printf '%s\n' "$output" | grep -cx "packages/alpha" || true)
  [ "$_n" -eq 1 ] || { echo "FAIL: packages/alpha appeared $_n times" >&2; return 1; }
  _u=$(printf '%s\n' "$output" | grep -cx "packages/str-utils" || true)
  [ "$_u" -eq 1 ] || { echo "FAIL: packages/str-utils appeared $_u times" >&2; return 1; }
}

@test "no match: empty output and exit 0" {
  run bash -c "
    set -euo pipefail
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    source '$GATE_RUNNERS'
    _out=\$(_expand_workspace_dirs '$_fx' 'nothing/here/*')
    echo \"status=\$? out='\$_out'\"
  "
  [ "$status" -eq 0 ] || { echo "FAIL: killed the caller under set -e: $output" >&2; return 1; }
  echo "$output" | grep -q "out=''" || { echo "FAIL: expected empty, got: $output" >&2; return 1; }
}

@test "end to end: _changed_files_to_workspace_dirs keeps only touched packages" {
  cat > "$_fx/package.json" <<'EOF'
{"workspaces":["packages/**","apps/*","tools/cli","!packages/legacy"]}
EOF
  run bash -c "
    set -uo pipefail
    export RITE_LIB_DIR='$REPO_ROOT/lib'
    source '$GATE_RUNNERS'
    _changed_files_to_workspace_dirs '$_fx' 'packages/beta/src.ts
apps/api/index.ts
packages/legacy/x.ts
packages/deep/a/b/y.ts'
  "
  [ "$status" -eq 0 ] || { echo "FAIL: exit $status: $output" >&2; return 1; }
  [ "$output" = "apps/api
packages/beta
packages/deep/a/b" ] || {
    echo "FAIL: expected apps/api, packages/beta, packages/deep/a/b (sorted, legacy excluded, alpha untouched); got: $output" >&2
    return 1
  }
}
