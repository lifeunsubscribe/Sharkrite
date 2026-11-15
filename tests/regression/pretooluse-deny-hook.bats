#!/usr/bin/env bats
# sharkrite-test-covers: lib/hooks/claude-pretooluse-deny.sh, lib/providers/claude.sh::_claude_write_hook_settings|claude_provider_run_agentic_session
#
# The PreToolUse deny hook is the ENFORCED in-session backstop (the CLI ignores
# --disallowedTools under --output-format stream-json, which every dev/fix
# session uses). A security control with no tests is the gap this closes.
#
# Contract: reads a PreToolUse event JSON on stdin. For Bash tool calls whose
# command matches the denylist, emit {"hookSpecificOutput":{... "permissionDecision":
# "deny" ...}} and exit 0. All other calls → exit 0, NO output (allow). Other
# tools and malformed input fail open (allow).
#
# Write guard (freshup #597, 2026-11-15): the dev session edited the primary
# checkout by absolute path, found an empty diff at the end, and redid the work
# in its worktree — leaving the first set of edits in the operator's checkout.
# Edit/Write/MultiEdit/NotebookEdit aimed at the primary checkout from a
# linked-worktree session are denied with the worktree path to use instead.

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../../lib/hooks/claude-pretooluse-deny.sh"
}

# Emit the hook's stdout for a Bash command ($1) or a given tool ($2).
_hook() {
  printf '{"tool_name":"%s","tool_input":{"command":"%s"}}' "${2:-Bash}" "$1" | bash "$HOOK"
}
_denied() { echo "$1" | grep -q '"permissionDecision":"deny"'; }

# ---- DENY: workflow-owned git/gh ----
@test "deny: git commit" { run _hook "git commit -m x"; _denied "$output"; }
@test "deny: git push"   { run _hook "git push origin main"; _denied "$output"; }
@test "deny: gh pr create" { run _hook "gh pr create"; _denied "$output"; }
@test "deny: gh issue list" { run _hook "gh issue list"; _denied "$output"; }

# ---- DENY: test/lint runners (post-commit gate owns these) ----
@test "deny: bare make"  { run _hook "make"; _denied "$output"; }
@test "deny: make check" { run _hook "make check"; _denied "$output"; }
@test "deny: bats"       { run _hook "bats tests/"; _denied "$output"; }
@test "deny: pytest"     { run _hook "pytest"; _denied "$output"; }

# ---- DENY: destructive / network / credential ----
@test "deny: rm -rf"     { run _hook "rm -rf /tmp/x"; _denied "$output"; }
@test "deny: rm -fr"     { run _hook "rm -fr /tmp/x"; _denied "$output"; }
@test "deny: curl"       { run _hook "curl http://example.com"; _denied "$output"; }
@test "deny: wget"       { run _hook "wget http://example.com"; _denied "$output"; }
@test "deny: ssh"        { run _hook "ssh host"; _denied "$output"; }
@test "deny: scp"        { run _hook "scp a b"; _denied "$output"; }
@test "deny: env dump"   { run _hook "env"; _denied "$output"; }
@test "deny: printenv"   { run _hook "printenv"; _denied "$output"; }
@test "deny: /etc path"  { run _hook "cat /etc/passwd"; _denied "$output"; }
@test "deny: ssh key path" { run _hook "cat ~/.ssh/id_rsa"; _denied "$output"; }
@test "deny: shell rc path" { run _hook "cat ~/.zshrc"; _denied "$output"; }

# ---- ALLOW: sharkrite-lint.sh (explicitly permitted for in-session static analysis) ----
@test "allow: tools/sharkrite-lint.sh bare invocation"            { run _hook "tools/sharkrite-lint.sh"; [ -z "$output" ]; }
@test "allow: ./tools/sharkrite-lint.sh"                          { run _hook "./tools/sharkrite-lint.sh"; [ -z "$output" ]; }
@test "allow: SHARKRITE_LINT_ONLY=34 tools/sharkrite-lint.sh"    { run _hook "SHARKRITE_LINT_ONLY=34 tools/sharkrite-lint.sh"; [ -z "$output" ]; }
@test "allow: SHARKRITE_LINT_ONLY=34,35 tools/sharkrite-lint.sh" { run _hook "SHARKRITE_LINT_ONLY=34,35 tools/sharkrite-lint.sh"; [ -z "$output" ]; }

# Confirm make/bats remain denied even though sharkrite-lint.sh is allowed.
@test "deny: make check still denied when sharkrite-lint.sh is allowed" { run _hook "make check"; _denied "$output"; }
@test "deny: bats still denied when sharkrite-lint.sh is allowed"       { run _hook "bats tests/"; _denied "$output"; }

# Chained commands: the lint allowance must NOT bypass downstream deny rules.
@test "deny: sharkrite-lint.sh && bats (lint then bats)" {
  run _hook "tools/sharkrite-lint.sh && bats -r tests/"
  _denied "$output"
}
@test "deny: bats && sharkrite-lint.sh (bats then lint)" {
  run _hook "bats -r tests/ && tools/sharkrite-lint.sh"
  _denied "$output"
}
@test "deny: sharkrite-lint.sh; make check (lint then make)" {
  run _hook "tools/sharkrite-lint.sh; make check"
  _denied "$output"
}

# ---- ALLOW: read-only git + normal dev commands (no output) ----
@test "allow: git status" { run _hook "git status"; [ -z "$output" ]; }
@test "allow: git diff"   { run _hook "git diff"; [ -z "$output" ]; }
@test "allow: git log"    { run _hook "git log --oneline"; [ -z "$output" ]; }
@test "allow: git add"    { run _hook "git add ."; [ -z "$output" ]; }
@test "allow: bash -n"    { run _hook "bash -n x.sh"; [ -z "$output" ]; }
@test "allow: grep"       { run _hook "grep foo bar.txt"; [ -z "$output" ]; }
@test "allow: ls"         { run _hook "ls -la"; [ -z "$output" ]; }
@test "allow: echo"       { run _hook "echo hello"; [ -z "$output" ]; }

# ---- word-anchor edges (must NOT over-match) ----
@test "allow: 'makefile' does not trip the make rule" { run _hook "vim makefile"; [ -z "$output" ]; }
@test "allow: 'gherkin' does not trip the gh rule"     { run _hook "cat gherkin.txt"; [ -z "$output" ]; }

# ---- command-position anchoring: path/argument mentions must not deny (#994) ----
@test "allow: cp of a .bats path + bash -n (live FP, issue #976 fix session)" {
  run _hook "cp tests/regression/gate-flake-retry.bats /tmp/x.sh && bash -n /tmp/x.sh"
  [ -z "$output" ]
}
@test "allow: bash -n on a .bats path"    { run _hook "bash -n tests/regression/foo.bats"; [ -z "$output" ]; }
@test "allow: ls of a make-named path"    { run _hook "ls tests/lint/make-check.bats"; [ -z "$output" ]; }
@test "allow: grep in a .bats path"       { run _hook "grep -n foo tests/x.bats"; [ -z "$output" ]; }
@test "allow: git add of a .bats path"    { run _hook "git add tests/regression/foo.bats"; [ -z "$output" ]; }
@test "allow: quoted-argument runner mention" { run _hook "echo 'run bats later'"; [ -z "$output" ]; }
@test "allow: git log --grep 'make check'" { run _hook "git log --grep 'make check'"; [ -z "$output" ]; }
@test "allow: direct-exec of a test file is not the runner (deliberate)" {
  # ./tests/foo.bats flips deny->allow under the position anchor: the rule
  # targets `bats` the RUNNER; .bats files here are data (mode 644).
  run _hook "./tests/foo.bats"
  [ -z "$output" ]
}

# ---- command-position anchoring: runners at command position stay blocked (#994) ----
@test "deny: bats after &&"           { run _hook "cd x && bats tests/"; _denied "$output"; }
@test "deny: bats after ;"            { run _hook "echo hi; bats tests/"; _denied "$output"; }
@test "deny: bats after a pipe"       { run _hook "echo x | bats -"; _denied "$output"; }
@test "deny: env-prefixed bats"       { run _hook "env A=1 bats file.bats"; _denied "$output"; }
@test "deny: VAR=val-prefixed bats"   { run _hook "FOO=1 bats tests/"; _denied "$output"; }
@test "deny: command-prefixed bats"   { run _hook "command bats tests/"; _denied "$output"; }
@test "deny: bats inside \$( )"       { run _hook "out=\$(bats tests/)"; _denied "$output"; }
@test "deny: bats inside backticks"   { run _hook 'echo `bats tests/`'; _denied "$output"; }
@test "deny: bats in a subshell"      { run _hook "(bats tests/)"; _denied "$output"; }
@test "deny: npx bats"                { run _hook "npx bats tests/"; _denied "$output"; }
@test "deny: python -m pytest"        { run _hook "python3 -m pytest"; _denied "$output"; }
@test "deny: path-invoked bats"       { run _hook "/usr/local/bin/bats tests/"; _denied "$output"; }
@test "deny: node_modules bats"       { run _hook "./node_modules/.bin/bats tests/"; _denied "$output"; }
@test "deny: timeout-wrapped bats"    { run _hook "timeout 300 bats tests/"; _denied "$output"; }
@test "deny: gtimeout-wrapped bats"   { run _hook "gtimeout 300 bats tests/"; _denied "$output"; }
@test "deny: time-wrapped make"       { run _hook "time make check"; _denied "$output"; }
@test "deny: xargs bats"              { run _hook "echo tests/ | xargs bats"; _denied "$output"; }
@test "deny: nohup bats"              { run _hook "nohup bats tests/"; _denied "$output"; }
@test "deny: sudo make"               { run _hook "sudo make install"; _denied "$output"; }
@test "deny: multiline command, runner on line 2" {
  # printf leaves the literal \n in the JSON string; jq decodes it to a real
  # newline. grep is line-based, so line 2 anchors via ^.
  run _hook 'true\nbats tests/'
  _denied "$output"
}
@test "deny: VAR=val-prefixed env dump" { run _hook "FOO=1 env"; _denied "$output"; }

# ---- fail-open: non-Bash tools and malformed input ----
@test "allow: non-Bash tool is not gated (even a denylisted-looking command)" {
  run _hook "git commit" "Read"
  [ -z "$output" ]
}
@test "fail-open: malformed JSON → allow (exit 0, no deny)" {
  run bash -c 'printf "not json at all" | bash "'"$HOOK"'"'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"permissionDecision":"deny"'
}
@test "deny output is valid JSON" {
  run _hook "git commit -m x"
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

# ---- write guard: edits aimed at the primary checkout from a worktree session ----
# Build <tmp>/primary (a clone with one commit) and a linked worktree <tmp>/wt.
# BATS_TEST_TMPDIR is spelled through the /var symlink on macOS while git
# reports /private/var, so these fixtures exercise both spellings.
_wt_fixture() {
  PRIMARY="$BATS_TEST_TMPDIR/primary"
  WT="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$PRIMARY/src" "$PRIMARY/.rite"
  git -C "$PRIMARY" init -q
  git -C "$PRIMARY" config user.email t@t
  git -C "$PRIMARY" config user.name t
  echo base > "$PRIMARY/src/app.py"
  git -C "$PRIMARY" add src/app.py
  git -C "$PRIMARY" commit -qm base
  git -C "$PRIMARY" worktree add -q "$WT" -b feat/x
  ln -s "$PRIMARY/.rite" "$WT/.rite"
}
# Hook stdout for a write tool: $1 tool, $2 target path, $3 pinned session dir
# (empty = unset), $4 event cwd (optional).
_whook() {
  local _key="file_path"
  [ "$1" = "NotebookEdit" ] && _key="notebook_path"
  if [ -n "${3:-}" ]; then
    printf '{"tool_name":"%s","cwd":"%s","tool_input":{"%s":"%s"}}' "$1" "${4:-}" "$_key" "$2" \
      | _RITE_HOOK_SESSION_DIR="$3" bash "$HOOK"
  else
    printf '{"tool_name":"%s","cwd":"%s","tool_input":{"%s":"%s"}}' "$1" "${4:-}" "$_key" "$2" \
      | env -u _RITE_HOOK_SESSION_DIR bash "$HOOK"
  fi
}

@test "write guard: Edit on a primary-checkout file from a worktree session is denied, naming the worktree file" {
  _wt_fixture
  run _whook Edit "$PRIMARY/src/app.py" "$WT"
  [ "$status" -eq 0 ]
  _denied "$output"
  local _reason
  _reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$_reason" == *"/wt/src/app.py instead"* ]]
}

@test "write guard: Write, MultiEdit and NotebookEdit are gated the same way" {
  _wt_fixture
  run _whook Write "$PRIMARY/src/new_file.py" "$WT"; _denied "$output"
  run _whook MultiEdit "$PRIMARY/src/app.py" "$WT"; _denied "$output"
  run _whook NotebookEdit "$PRIMARY/notebooks/a.ipynb" "$WT"; _denied "$output"
}

@test "write guard: a new file in a directory that does not exist yet is still denied" {
  _wt_fixture
  run _whook Write "$PRIMARY/src/deep/new/dir/file.py" "$WT"
  _denied "$output"
  [[ "$output" == *"/wt/src/deep/new/dir/file.py instead"* ]]
}

@test "write guard: the physical spelling of the primary checkout is denied too" {
  _wt_fixture
  local _phys
  _phys=$(cd "$PRIMARY" && pwd -P)
  run _whook Edit "$_phys/src/app.py" "$WT"
  _denied "$output"
}

@test "write guard: edits inside the session's worktree are allowed" {
  _wt_fixture
  run _whook Edit "$WT/src/app.py" "$WT"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run _whook Write "$(cd "$WT" && pwd -P)/src/brand_new.py" "$WT"
  [ -z "$output" ]
}

@test "write guard: shared .rite state is writable through the worktree symlink and directly" {
  _wt_fixture
  run _whook Write "$WT/.rite/scratch.md" "$WT"
  [ -z "$output" ]
  run _whook Write "$PRIMARY/.rite/scratch.md" "$WT"
  [ -z "$output" ]
}

@test "write guard: a sibling name sharing the primary prefix is not the primary checkout" {
  _wt_fixture
  mkdir -p "$BATS_TEST_TMPDIR/primary-notes"
  run _whook Write "$BATS_TEST_TMPDIR/primary-notes/x.md" "$WT"
  [ -z "$output" ]
}

@test "write guard: a session launched in the primary checkout may edit it" {
  _wt_fixture
  run _whook Edit "$PRIMARY/src/app.py" "$PRIMARY"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "write guard: paths outside the repository are allowed" {
  _wt_fixture
  run _whook Write "$BATS_TEST_TMPDIR/elsewhere/notes.md" "$WT"
  [ -z "$output" ]
}

@test "write guard: the pinned launch directory wins over a drifted event cwd" {
  _wt_fixture
  # The model ran `cd` into the primary checkout: the event cwd says primary,
  # the pin still says worktree, so the edit is denied.
  run _whook Edit "$PRIMARY/src/app.py" "$WT" "$PRIMARY"
  _denied "$output"
}

@test "write guard: without a pin the event cwd identifies the worktree" {
  _wt_fixture
  run _whook Edit "$PRIMARY/src/app.py" "" "$WT"
  _denied "$output"
}

@test "write guard fail-open: non-repo session dir, missing dir, relative path, missing path" {
  _wt_fixture
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run _whook Edit "$PRIMARY/src/app.py" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run _whook Edit "$PRIMARY/src/app.py" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run _whook Edit "src/app.py" "$WT"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c 'printf "{\"tool_name\":\"Edit\",\"tool_input\":{}}" | _RITE_HOOK_SESSION_DIR="'"$WT"'" bash "'"$HOOK"'"'
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "write guard: Read of a primary-checkout file is not gated" {
  _wt_fixture
  run _whook Read "$PRIMARY/src/app.py" "$WT"
  [ -z "$output" ]
}

# ---- provider wiring: the hook only sees what the settings matcher routes to it ----
@test "settings: the PreToolUse matcher routes Bash and every file-writing tool to the hook" {
  run bash -c '
    set -euo pipefail
    export RITE_LIB_DIR="'"${BATS_TEST_DIRNAME}/../../lib"'"
    RITE_SOURCE_FUNCTIONS_ONLY=1 source "$RITE_LIB_DIR/providers/claude.sh" || true
    _f=$(_claude_write_hook_settings)
    jq -r ".hooks.PreToolUse[0].matcher" "$_f"
    rm -f "$_f"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "Bash|Edit|Write|MultiEdit|NotebookEdit" ]
}

@test "session: the CLI is launched with the launch directory pinned for the hook" {
  local _tmpdir="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$_tmpdir" "$BATS_TEST_TMPDIR/launch"
  cat > "$_tmpdir/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "${_RITE_HOOK_SESSION_DIR:-unset}" > "$PIN_OUT"
exit 0
STUB
  chmod +x "$_tmpdir/claude"
  run bash -c "
    set -euo pipefail
    export PATH='$_tmpdir:/usr/bin:/bin'
    export PIN_OUT='$BATS_TEST_TMPDIR/pin.out'
    export RITE_LIB_DIR='${BATS_TEST_DIRNAME}/../../lib'
    export _RITE_TIMEOUT_CHECKED=true
    RITE_SOURCE_FUNCTIONS_ONLY=1 source \"\$RITE_LIB_DIR/providers/claude.sh\" || true
    set +u; set +o pipefail
    run_with_timeout() { shift; \"\$@\"; }
    claude_provider_detect_cli
    _claude_write_hook_settings() { echo ''; }
    claude_provider_build_tool_restrictions() { echo 'none'; }
    claude_provider_resolve_model() { echo 'claude-sonnet-4-6'; }
    cd '$BATS_TEST_TMPDIR/launch'
    claude_provider_run_agentic_session 'test prompt' 10 true /dev/null
    echo \"leaked=\${_RITE_HOOK_SESSION_DIR:-unset}\"
  "
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/pin.out")" = "$(cd "$BATS_TEST_TMPDIR/launch" && pwd -P)" ]
  [[ "$output" == *"leaked=unset"* ]]
}
