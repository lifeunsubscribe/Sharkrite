#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/36-undocumented-rite-var-read-in-lib.sh, tools/sharkrite-lint.sh, tools/lint-rules/21-bash-4-builtins-in-bin-bash-scripts-without.sh
# Regression test for Rule 36 ledger isolation.
#
# Verifies that running the Rule 36 lint fragment does NOT mutate the tracked
# ledger or config examples on disk, and that RITE_CLAUDE_TIMEOUT_PROMPT
# (the regressed variable from issue #1605) passes Rule 36 without violation.
#
# Motivation (issue #1605): a macOS-only CI failure for RITE_CLAUDE_TIMEOUT_PROMPT
# suggested possible allowlist corruption — either during the lint run itself or
# from a bats test that left the ledger in a modified state. This test makes the
# invariant checkable: the ledger must be byte-identical after any lint execution.

setup() {
  LINT_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/sharkrite-lint.sh"
  LEDGER="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/lint-rules/36-undocumented-rite-var.ledger"
  PROJ_CONF="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/config/project.conf.example"
  RITE_CONF="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/config/rite.conf.example"

  # Capture checksums before any lint run (computed once per test via setup()).
  LEDGER_BEFORE=$(md5 -q "$LEDGER" 2>/dev/null || md5sum "$LEDGER" | awk '{print $1}')
  PROJ_CONF_BEFORE=$(md5 -q "$PROJ_CONF" 2>/dev/null || md5sum "$PROJ_CONF" | awk '{print $1}')
  RITE_CONF_BEFORE=$(md5 -q "$RITE_CONF" 2>/dev/null || md5sum "$RITE_CONF" | awk '{print $1}')
}

@test "ledger is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  # 0 = no violations, 1 = violations found; anything higher means the linter
  # failed to run (e.g. exit 127 = script not found) — files would be identical
  # trivially, so the checksum assertion would pass vacuously.
  [ "$status" -le 1 ]
  local after
  after=$(md5 -q "$LEDGER" 2>/dev/null || md5sum "$LEDGER" | awk '{print $1}')
  [ "$LEDGER_BEFORE" = "$after" ]
}

@test "project.conf.example is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  [ "$status" -le 1 ]
  local after
  after=$(md5 -q "$PROJ_CONF" 2>/dev/null || md5sum "$PROJ_CONF" | awk '{print $1}')
  [ "$PROJ_CONF_BEFORE" = "$after" ]
}

@test "rite.conf.example is byte-identical after running Rule 36 in isolation" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  [ "$status" -le 1 ]
  local after
  after=$(md5 -q "$RITE_CONF" 2>/dev/null || md5sum "$RITE_CONF" | awk '{print $1}')
  [ "$RITE_CONF_BEFORE" = "$after" ]
}

@test "ledger contains RITE_CLAUDE_TIMEOUT_PROMPT (the regressed var)" {
  grep -qxF "RITE_CLAUDE_TIMEOUT_PROMPT" "$LEDGER"
}

@test "RITE_CLAUDE_TIMEOUT_PROMPT passes Rule 36 in isolation (the regressed case)" {
  # Plant a fixture that reads RITE_CLAUDE_TIMEOUT_PROMPT in a lib/ path.
  # Rule 36 must NOT fire for it since the var is in the ledger.
  local fixture_dir="${BATS_TEST_TMPDIR}/r36-isolation/lib/utils"
  mkdir -p "$fixture_dir"
  cat > "$fixture_dir/timeout-consumer.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${_RITE_R36_ISOL_LOADED:-}" = "true" ]; then return 0 2>/dev/null || true; fi
_RITE_R36_ISOL_LOADED=true
consume_timeout() {
  local t="${RITE_CLAUDE_TIMEOUT_PROMPT:-600}"
  echo "$t"
}
EOF

  # Positive control: a deliberately undocumented var that MUST fire a violation.
  # Without this, the test passes vacuously if RITE_LINT_EXTRA_DIRS injection
  # or the */lib/*.sh filter regresses — the linter scans nothing, produces no
  # output, and [ -z "$violations" ] is satisfied without proving anything.
  cat > "$fixture_dir/undocumented-consumer.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
positive_control_fn() {
  echo "${RITE_UNDOCUMENTED_TEST_VAR_R36:-}"
}
EOF

  # Run with an adversarial locale to prove LC_ALL=C pins inside the linter hold.
  # If the sort -u calls lose their LC_ALL=C, a non-C collation can collapse
  # allowlist entries and produce false positives for ledgered vars like
  # RITE_CLAUDE_TIMEOUT_PROMPT — the original macOS-only CI failure (issue #1605).
  local _locale
  _locale=$(locale -a 2>/dev/null | grep -iE '^en_US\.(UTF-?8|utf8)$' | head -1 || true)
  if [ -z "$_locale" ]; then
    skip "en_US.UTF-8 locale not available — cannot test locale-pinning on this system"
  fi

  LC_ALL="$_locale" RITE_LINT_EXTRA_DIRS="${BATS_TEST_TMPDIR}/r36-isolation/lib/utils" \
    SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"

  # Positive control must fire (proves injection and filter are working).
  local positive
  positive=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" | grep "undocumented-consumer" || true)
  [ -n "$positive" ]

  # Regressed var must NOT fire (it is in the ledger).
  local violations
  violations=$(echo "$output" | grep "UNDOCUMENTED_RITE_VAR" | grep "timeout-consumer" || true)
  [ -z "$violations" ]
}

# ---------------------------------------------------------------------------
# Diagnostics on first violation (issue #1633)
#
# The macOS-only false positive (#1605, then PR #1625, then main run
# 42502587335 — a different allowlisted var each time) has never been caught
# with evidence of what the allowlist contained. Rule 36 now prints a
# `# rule36-diag:` block to stderr on the FIRST violation of a run: environment,
# per-source allowlist counts, the flagged var's presence in each source, and
# the full combined list. These pin that contract.
# ---------------------------------------------------------------------------

@test "rule36-diag block is printed exactly once on violation, with per-source membership for the flagged var" {
  local fixture_dir="${BATS_TEST_TMPDIR}/r36-diag/lib/utils"
  mkdir -p "$fixture_dir"
  # Two undocumented vars in two files: proves the block is single-shot, not per-violation.
  cat > "$fixture_dir/probe-a.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
probe_a() { echo "${RITE_R36_DIAG_PROBE_ALPHA:-}"; }
EOF
  cat > "$fixture_dir/probe-b.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
probe_b() { echo "${RITE_R36_DIAG_PROBE_BETA:-}"; }
EOF

  RITE_LINT_EXTRA_DIRS="${BATS_TEST_TMPDIR}/r36-diag/lib/utils" \
    SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"

  # Both probes fire (positive control), and the run reports violations.
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "UNDOCUMENTED_RITE_VAR.*RITE_R36_DIAG_PROBE_ALPHA"
  echo "$output" | grep -q "UNDOCUMENTED_RITE_VAR.*RITE_R36_DIAG_PROBE_BETA"

  # Exactly one block, despite two violations.
  local begins ends
  begins=$(echo "$output" | grep -c '^# rule36-diag: begin' || true)
  ends=$(echo "$output" | grep -c '^# rule36-diag: end$' || true)
  [ "$begins" -eq 1 ]
  [ "$ends" -eq 1 ]

  # Environment fields present.
  echo "$output" | grep -q '^# rule36-diag: bash='
  echo "$output" | grep -q '^# rule36-diag: LANG='
  echo "$output" | grep -q '^# rule36-diag: PATH='
  echo "$output" | grep -q '^# rule36-diag: tool grep='
  echo "$output" | grep -q '^# rule36-diag: tool sort='

  # Allowlist shape: non-zero counts for all three sets.
  local counts
  counts=$(echo "$output" | grep '^# rule36-diag: documented_set entries=' || true)
  [ -n "$counts" ]
  echo "$counts" | grep -qE 'documented_set entries=[1-9][0-9]*'
  echo "$counts" | grep -qE 'ledger_entries entries=[1-9][0-9]*'
  echo "$counts" | grep -qE 'allowed_set entries=[1-9][0-9]* bytes=[1-9][0-9]* cksum=[0-9]+'

  # The flagged var (whichever probe fired first) is absent from every source — that
  # is the honest reading for a genuinely undocumented var, and it is the line that
  # will tell us, on a real macOS false positive, WHICH source lost the entry.
  echo "$output" | grep -qE '^# rule36-diag: var RITE_R36_DIAG_PROBE_(ALPHA|BETA) in documented_set=0 ledger_entries=0 allowed_set=0$'

  # The dump is there and contains a known ledgered var.
  echo "$output" | grep -q '^# rule36-diag: allowed_set dump follows$'
  echo "$output" | grep -qx 'RITE_CLAUDE_TIMEOUT_PROMPT'
}

@test "rule36-diag prints nothing on a clean run (zero behavior change)" {
  SHARKRITE_LINT_ONLY=36 run bash "$LINT_SCRIPT"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'rule36-diag'
}

# ---------------------------------------------------------------------------
# Root cause of the macOS false positive (issue #1633)
#
# The driver runs under `set -o pipefail`. `printf '%s\n' "$allowed" | grep -qxF`
# has a producer process: when grep -q matches in an early chunk and exits,
# the still-writing printf takes SIGPIPE and the pipeline returns 141, so an
# allowlisted var reads as "not in the allowlist". bash's printf emits the 3 KB
# allowlist as several write()s on macOS (1 KB stdio buffers) and as one on
# Linux — hence macOS-only, one random var per run, never on an idle dev box.
# A here-string has no producer process. These pin the mechanism and the fix.
# ---------------------------------------------------------------------------

@test "pipefail turns a producer|grep -q early exit into rc 141; a here-string does not" {
  # Mechanism, not a bash curiosity: this is exactly what the membership
  # check did on macOS CI. The producer keeps writing until a write fails,
  # so the late write is guaranteed to land after grep has exited — no
  # fixed sleep to lose the race on a loaded runner (bounded at ~10s; grep
  # exits on its first line, so normally one or two iterations).
  run bash -c 'set -o pipefail; { printf "RITE_A\n"; i=0; while [ $i -lt 200 ]; do sleep 0.05; printf "RITE_B\n" || exit 141; i=$((i+1)); done; } | grep -qxF RITE_A'
  [ "$status" -eq 141 ]
  run bash -c 'set -o pipefail; v=$(printf "RITE_A\nRITE_B\n"); grep -qxF RITE_A <<< "$v"'
  [ "$status" -eq 0 ]
}

@test "allowlist membership and the other multi-line lint guards use here-strings, not producer|grep -q" {
  local rules_dir
  rules_dir="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/tools/lint-rules"
  local r36="$rules_dir/36-undocumented-rite-var-read-in-lib.sh"
  local r21="$rules_dir/21-bash-4-builtins-in-bin-bash-scripts-without.sh"

  # Rule 36: the membership check is a here-string against the allowlist.
  grep -qF 'grep -qxF "$_r36_var_name" <<< "$_r36_allowed_set"' "$r36"
  ! grep -E '"\$_r36_allowed_set" \| grep -q' "$r36"

  # Driver: the bats-only targeted-scope probe reads RITE_LINT_FILES via here-string.
  grep -qF "grep -qE '\\.bats\$' <<< \"\$RITE_LINT_FILES\"" "$LINT_SCRIPT"
  ! grep -E '"\$RITE_LINT_FILES" \| grep -q' "$LINT_SCRIPT"

  # Rule 21: both whole-file guard scans are here-strings.
  [ "$(grep -c '<<< "$_non_comment_lines"' "$r21")" -eq 2 ]
  ! grep -E 'echo "\$_non_comment_lines" \| grep -q' "$r21"
}
