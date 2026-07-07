#!/usr/bin/env bats
# sharkrite-test-covers: lib/hooks/claude-pretooluse-deny.sh
#
# The PreToolUse deny hook is the ENFORCED in-session backstop (the CLI ignores
# --disallowedTools under --output-format stream-json, which every dev/fix
# session uses). A security control with no tests is the gap this closes.
#
# Contract: reads a PreToolUse event JSON on stdin. For Bash tool calls whose
# command matches the denylist, emit {"hookSpecificOutput":{... "permissionDecision":
# "deny" ...}} and exit 0. All other calls → exit 0, NO output (allow). Non-Bash
# tools and malformed input fail open (allow).

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
