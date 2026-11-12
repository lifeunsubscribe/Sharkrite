#!/usr/bin/env bats
# sharkrite-test-covers: lib/utils/gate-verdict.sh::_gate_verdict_cache_path|_gate_verdict_cache_hit|_gate_verdict_cache_store, lib/utils/test-gate.sh::run_test_gate
#
# Gate verdict reuse on identical trees (2026-11-11).
#
# Live: batch 20261111-095317 ran the targeted gate twice per resumed issue on
# the same tree — post-rebase verification, then the Phase 2 initial gate ~60s
# later. 82-175s each, the first one serial. A PASS is a pure function of
# (tree, diff base), so it is keyed on exactly that pair and reused.
#
# Guards: key is the TREE hash (amend with identical content hits; any content
# change misses); only passing, non-skipped verdicts are stored; a cached hit
# refreshes head_sha to the current HEAD for the #986 SHA-pin check; an
# unresolvable diff base bypasses the cache.

setup() {
  RITE_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"; export RITE_REPO_ROOT
  export RITE_LIB_DIR="$RITE_REPO_ROOT/lib"
  export RITE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$REPO" "$RITE_STATE_DIR"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  echo base > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm base
  git -C "$REPO" branch -q base-mark
  echo change > "$REPO/f"; git -C "$REPO" commit -qam change
  source "$RITE_LIB_DIR/utils/gate-verdict.sh"
  set +u; set +o pipefail
  OUT="${BATS_TEST_TMPDIR}/gate.json"
}

_pass_json()  { printf '{"lint":[],"tests":[],"exit_code":0,"head_sha":"%s"}\n' "$1" > "$OUT"; }
_fail_json()  { printf '{"lint":[],"tests":[{"file":"bats","test_name":"x","reason":"assertion failed"}],"exit_code":1,"head_sha":"%s"}\n' "$1" > "$OUT"; }
_skip_json()  { printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true,"reason":"missing_deps"}\n' > "$OUT"; }

@test "cache path: keyed on HEAD tree + resolved base commit, under RITE_STATE_DIR/gate-verdicts" {
  run _gate_verdict_cache_path "$REPO" base-mark
  [ "$status" -eq 0 ]
  tree=$(git -C "$REPO" rev-parse 'HEAD^{tree}'); base=$(git -C "$REPO" rev-parse base-mark)
  [ "$output" = "$RITE_STATE_DIR/gate-verdicts/${tree}-${base}.json" ]
}

@test "cache path: unresolvable diff base (range form / missing ref) returns 1 and prints nothing" {
  run _gate_verdict_cache_path "$REPO" "origin/main...abc123"
  [ "$status" -eq 1 ]; [ -z "$output" ]
  run _gate_verdict_cache_path "$REPO" "no/such/ref"
  [ "$status" -eq 1 ]; [ -z "$output" ]
}

@test "store then hit: passing verdict is reused and head_sha refreshed to current HEAD" {
  cache=$(_gate_verdict_cache_path "$REPO" base-mark)
  _pass_json "oldsha"
  _gate_verdict_cache_store "$cache" "$OUT"
  [ -f "$cache" ]
  rm -f "$OUT"
  run _gate_verdict_cache_hit "$cache" "$OUT" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r .head_sha "$OUT")" = "$(git -C "$REPO" rev-parse HEAD)" ]
  [ "$(jq -r .cached "$OUT")" = "true" ]
  [ "$(jq -r .exit_code "$OUT")" = "0" ]
}

@test "failing verdict is never stored" {
  cache=$(_gate_verdict_cache_path "$REPO" base-mark)
  _fail_json "sha"
  _gate_verdict_cache_store "$cache" "$OUT"
  [ ! -f "$cache" ]
}

@test "skipped verdict (missing_deps) is never stored" {
  cache=$(_gate_verdict_cache_path "$REPO" base-mark)
  _skip_json
  _gate_verdict_cache_store "$cache" "$OUT"
  [ ! -f "$cache" ]
}

@test "hit refuses a cache file that is not a clean pass (defence against hand-edited state)" {
  cache="$RITE_STATE_DIR/gate-verdicts/x-y.json"; mkdir -p "$(dirname "$cache")"
  printf '{"lint":[],"tests":[],"exit_code":1}\n' > "$cache"
  run _gate_verdict_cache_hit "$cache" "$OUT" "$REPO"
  [ "$status" -eq 1 ]
  printf '{"lint":[],"tests":[],"exit_code":0,"skipped":true}\n' > "$cache"
  run _gate_verdict_cache_hit "$cache" "$OUT" "$REPO"
  [ "$status" -eq 1 ]
}

@test "tree semantics: amend with identical content keeps the key (hit); content change changes it (miss)" {
  k1=$(_gate_verdict_cache_path "$REPO" base-mark)
  git -C "$REPO" commit -q --amend -m "same tree, new message"
  k2=$(_gate_verdict_cache_path "$REPO" base-mark)
  [ "$k1" = "$k2" ]
  echo more >> "$REPO/f"; git -C "$REPO" commit -qam more
  k3=$(_gate_verdict_cache_path "$REPO" base-mark)
  [ "$k1" != "$k3" ]
}

@test "different diff base → different key (selection depends on the base)" {
  git -C "$REPO" branch -q other-base HEAD~1
  echo x > "$REPO/g"; git -C "$REPO" add g; git -C "$REPO" commit -qm g
  git -C "$REPO" branch -q newer-base
  k1=$(_gate_verdict_cache_path "$REPO" base-mark)
  k2=$(_gate_verdict_cache_path "$REPO" newer-base)
  [ "$k1" != "$k2" ]
}

@test "empty cache path (bypass) is a no-op for both hit and store" {
  _pass_json "sha"
  run _gate_verdict_cache_hit "" "$OUT" "$REPO"
  [ "$status" -eq 1 ]
  _gate_verdict_cache_store "" "$OUT"
  [ ! -d "$RITE_STATE_DIR/gate-verdicts" ]
}

@test "structural: run_test_gate consults the cache before any runner and stores after the verdict" {
  gate="$RITE_LIB_DIR/utils/test-gate.sh"
  hit_line=$(grep -n '_gate_verdict_cache_hit' "$gate" | head -1 | cut -d: -f1)
  make_line=$(grep -n 'LINT_GATE_SELECTION' "$gate" | head -1 | cut -d: -f1)
  store_line=$(grep -n '_gate_verdict_cache_store' "$gate" | head -1 | cut -d: -f1)
  diag_line=$(grep -n '_diag "TEST_GATE outcome=\${_outcome}' "$gate" | head -1 | cut -d: -f1)
  [ -n "$hit_line" ] && [ -n "$make_line" ] && [ "$hit_line" -lt "$make_line" ]
  [ -n "$store_line" ] && [ -n "$diag_line" ] && [ "$store_line" -gt "$diag_line" ]
  grep -q 'cached=true' "$gate"
}
