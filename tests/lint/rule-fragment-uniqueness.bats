#!/usr/bin/env bats
# sharkrite-test-covers: tools/sharkrite-lint.sh
#
# The driver sources tools/lint-rules/*.sh in sort order with no dedup of the
# NN- prefix or the RULE_NAME strings. Two fragments sharing a number both load
# silently (helper/awk-tmp vars clobber; suppression becomes ambiguous) — a real
# collision happened between #1029's rule 36 and a new covers rule (#1023).
# These tests assert the invariant and the driver's fail-loud guard.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RULES_DIR="${RITE_REPO_ROOT}/tools/lint-rules"
  LINT_SCRIPT="${RITE_REPO_ROOT}/tools/sharkrite-lint.sh"
}

@test "invariant: every lint-rule fragment has a unique NN- number prefix" {
  _dups=$(ls "$RULES_DIR"/*.sh | sed -E 's#.*/([0-9]+)-.*#\1#' | sort | uniq -d)
  [ -z "$_dups" ] || {
    echo "FAIL: duplicate rule-fragment number(s): $_dups" >&2
    for _n in $_dups; do ls "$RULES_DIR/${_n}-"*.sh >&2; done
    return 1
  }
}

@test "invariant: no RULE_NAME is emitted by more than one fragment" {
  # Extract (RULE_NAME -> file) from single-line print_violation calls and flag
  # any name that appears in two different fragments. Best-effort (names on a
  # continuation line are not extracted), but catches the common case.
  _map=$(mktemp)
  for _f in "$RULES_DIR"/*.sh; do
    grep -oE 'print_violation "[^"]*" "[^"]*" "[A-Z][A-Z0-9_]+"' "$_f" 2>/dev/null \
      | grep -oE '"[A-Z][A-Z0-9_]+"$' | tr -d '"' | sort -u \
      | while IFS= read -r _name; do echo "$_name $(basename "$_f")"; done
  done > "$_map"
  _clashes=$(awk '{n[$1]=n[$1]" "$2; c[$1]++} END{for(k in c) if(c[k]>1) print k":"n[k]}' "$_map")
  rm -f "$_map"
  [ -z "$_clashes" ] || {
    echo "FAIL: RULE_NAME(s) defined in multiple fragments:" >&2
    echo "$_clashes" >&2
    return 1
  }
}

@test "structural: the driver has the fragment-number uniqueness guard" {
  grep -q 'uniq -d' "$LINT_SCRIPT"
  grep -q 'duplicate lint-rule fragment number' "$LINT_SCRIPT"
}

@test "behavioral: the guard logic detects a duplicate number in a fixture dir" {
  _d=$(mktemp -d)
  : > "$_d/36-alpha.sh"; : > "$_d/36-beta.sh"; : > "$_d/37-gamma.sh"
  _dups=$(ls "$_d"/*.sh | sed -E 's#.*/([0-9]+)-.*#\1#' | sort | uniq -d)
  rm -rf "$_d"
  [ "$_dups" = "36" ]
}

@test "behavioral: the guard passes on a fixture dir with unique numbers" {
  _d=$(mktemp -d)
  : > "$_d/40-a.sh"; : > "$_d/41-b.sh"; : > "$_d/42-c.sh"
  _dups=$(ls "$_d"/*.sh | sed -E 's#.*/([0-9]+)-.*#\1#' | sort | uniq -d)
  rm -rf "$_d"
  [ -z "$_dups" ]
}
