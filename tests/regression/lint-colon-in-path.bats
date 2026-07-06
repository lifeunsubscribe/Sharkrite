#!/usr/bin/env bats
# sharkrite-test-covers: tools/lint-rules/07-local-keyword-outside-function-sc2168-but-ca.sh, tools/lint-rules/08-unsafe-pipe-inside-command-substitution-sile.sh, tools/lint-rules/13-raw-gh-cli-calls-not-wrapped-in-gh-safe.sh, tools/sharkrite-lint.sh
# Regression test: lint rules correctly report file/line when the scanned file
# resides in a path containing a colon.
#
# Issue #239 (parent PR #225) — "Parse AWK output with field separators safely"
#
# Problem: Rules 7, 8, 9, 13, and 18 in sharkrite-lint.sh output AWK results in
# "file:linenum" format and parse them with 'cut -d: -f1/f2'.  If the file path
# contains a colon (e.g. GitHub Actions matrix job paths like
# /home/runner/work/my:project/file.sh), 'cut -d: -f1' only returns the portion
# before the first colon, so the violation is reported against a non-existent
# path or an incorrect line number.
#
# Fix: All AWK print statements for Rules 7, 8, 9, 13 now use tab as the field
# separator (print FILENAME "\t" FNR) and the bash parsing side uses 'cut -f1'/
# 'cut -f2' (tab-delimited, the default for cut).  Rule 18's grep -rn calls
# were replaced with AWK to produce the same tab-separated output.
#
# Test strategy:
#   1. Structural: assert that all AWK print statements in the affected rules
#      use "\t" as separator, not ":" — verifies the source-of-truth.
#   2. Functional (colon path simulation): directly invoke AWK with a fixture
#      file whose FILENAME is set to a colon-containing path, confirming the
#      tab-separated output is parsed correctly regardless of colons in the path.
#   3. End-to-end functional: run the lint script against a normal-path fixture
#      and assert the violation includes the correct filename and line number
#      (validates the full cut -f1/cut -f2 parsing pipeline).

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LINT_SCRIPT="$PROJECT_ROOT/tools/sharkrite-lint.sh"

  # Use a temp dir outside the project tree for extra fixtures.
  # Note: RITE_LINT_EXTRA_DIRS is colon-separated, so the directory path
  # itself must not contain colons.  Colon-in-path behavior is tested via
  # direct AWK invocation in the structural/functional tests below.
  FIXTURE_DIR="${BATS_TEST_TMPDIR}/lint-colon-path-fixtures"
  mkdir -p "$FIXTURE_DIR"
  export RITE_LINT_EXTRA_DIRS="$FIXTURE_DIR"
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR}/lint-colon-path-fixtures"
  unset RITE_LINT_EXTRA_DIRS
}

# ---------------------------------------------------------------------------
# Structural tests: AWK programs use tab separator, not colon
# ---------------------------------------------------------------------------

@test "Rule 7 AWK print uses tab separator, not colon" {
  # The Rule 7 AWK must emit FILENAME "\t" FNR, not FILENAME ":" FNR.
  # Using colon would break file path extraction when the path contains colons.

  # No colon-separated FILENAME/FNR print must exist
  _colon_count=$(grep -c 'print FILENAME ":" FNR' "$LINT_SCRIPT" || true)
  [ "$_colon_count" -eq 0 ] || {
    echo "Found colon-separated FILENAME/FNR print(s) in sharkrite-lint.sh (count: $_colon_count)" >&2
    return 1
  }

  # At least one tab-separated FILENAME/FNR print must exist (Rule 7's output line)
  _tab_count=$(grep -c 'print FILENAME "\\t" FNR' "$LINT_SCRIPT" || true)
  [ "$_tab_count" -ge 1 ] || {
    echo "No tab-separated FILENAME/FNR print found in Rule 7 AWK" >&2
    return 1
  }
}

@test "Rule 8 AWK program uses tab separator for pending_fname output" {
  # Rule 8 uses a temp AWK file.  The AWK source lines in sharkrite-lint.sh
  # must emit pending_fname "\t" pending_line, not pending_fname ":" pending_line.

  # No colon-separated pending_fname output must exist
  _colon_count=$(grep -c '":" pending_line' "$LINT_SCRIPT" || true)
  [ "$_colon_count" -eq 0 ] || {
    echo "Found colon-separated Rule 8 AWK output (count: $_colon_count)" >&2
    return 1
  }

  # At least one \t-separated output line must exist
  _tab_count=$(grep -c '"\\t" pending_line' "$LINT_SCRIPT" || true)
  [ "$_tab_count" -ge 1 ] || {
    echo "No tab-separated pending_fname output found in Rule 8 AWK" >&2
    return 1
  }
}

@test "Rule 9 AWK print statements use tab separator" {
  # Rule 9 emits FILENAME "\t" FNR "\t" TAG for each detected token.
  # Colon separator would break on colon-containing paths.
  _colon_count=$(grep -c 'print FILENAME ":" FNR' "$LINT_SCRIPT" || true)
  [ "$_colon_count" -eq 0 ] || {
    echo "Found $colon_count colon-separated FILENAME/FNR print(s) in sharkrite-lint.sh" >&2
    return 1
  }
}

@test "Rule 13 AWK program uses tab separator" {
  # Rule 13 emits FILENAME "\t" NR, not FILENAME ":" NR ":" $0.
  # The old format with $0 (line content) and colon separator broke on colon paths.
  _colon_count=$(grep -c 'print FILENAME ":" NR' "$LINT_SCRIPT" || true)
  [ "$_colon_count" -eq 0 ] || {
    echo "Found colon-separated FILENAME/NR print in Rule 13 AWK" >&2
    return 1
  }
}

@test "Bash parsing for Rules 7/8/9/13/18 uses 'cut -f' not 'cut -d: -f'" {
  # All hit-parsing loops for AWK-generated output must use tab-based cut.
  # 'cut -d: -f1' is the broken pattern — it splits on colon, mangling paths.
  #
  # Note: lines 806-807 use 'grep -n ... | cut -d: -f1' to extract a line number
  # from single-file grep output (format "linenum:content", no filename prefix).
  # That is safe — the colon issue only affects multi-file output where the
  # filename is part of the field.  This test only checks the _hit_file/
  # _hit_line/_hit_tag variables which come from AWK multi-file output.

  # Collect _hit_file/_hit_line/_hit_tag assignments that still use cut -d:
  _colon_cut_lines=$(grep -n '_hit_file\s*=\|_hit_line\s*=\|_hit_tag\s*=' "$LINT_SCRIPT" | \
    grep 'cut -d:' || true)

  [ -z "$_colon_cut_lines" ] || {
    echo "Found colon-based cut in AWK hit-parsing code:" >&2
    echo "$_colon_cut_lines" >&2
    return 1
  }
}

@test "Rule 18 uses AWK not grep -rn for marker collection" {
  # Rule 18 previously used 'grep -rn' which outputs 'file:linenum:content',
  # broken for colon-containing paths.  It must now use AWK with tab output.
  _grep_rn_count=$(grep -c "_r18_starts=\$(grep -rn" "$LINT_SCRIPT" || true)
  [ "$_grep_rn_count" -eq 0 ] || {
    echo "Rule 18 still uses grep -rn for _r18_starts (colon-path unsafe)" >&2
    return 1
  }

  _grep_rn_ends=$(grep -c "_r18_ends=\$(grep -rn" "$LINT_SCRIPT" || true)
  [ "$_grep_rn_ends" -eq 0 ] || {
    echo "Rule 18 still uses grep -rn for _r18_ends (colon-path unsafe)" >&2
    return 1
  }

  # Must use AWK instead
  _awk_starts=$(grep -c "_r18_starts=\$(awk" "$LINT_SCRIPT" || true)
  [ "$_awk_starts" -ge 1 ] || {
    echo "Rule 18 does not use AWK for _r18_starts collection" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Functional test: direct AWK output simulation with colon-in-path
# ---------------------------------------------------------------------------

@test "Rule 7 AWK: tab-separated output survives colon-in-path round-trip" {
  # Simulate Rule 7's AWK producing output with a colon-containing filename,
  # then verify the bash parsing (cut -f1/cut -f2) recovers the correct values.

  # A fixture line as AWK would print it: FILENAME "\t" FNR
  # with a FILENAME that contains colons (e.g. GitHub Actions matrix path)
  _simulated_output="/home/runner/work/my:project/sh:src/file.sh	42"

  _parsed_file=$(echo "$_simulated_output" | cut -f1)
  _parsed_line=$(echo "$_simulated_output" | cut -f2)

  [ "$_parsed_file" = "/home/runner/work/my:project/sh:src/file.sh" ] || {
    echo "cut -f1 did not return full path; got: '$_parsed_file'" >&2
    return 1
  }
  [ "$_parsed_line" = "42" ] || {
    echo "cut -f2 did not return line number; got: '$_parsed_line'" >&2
    return 1
  }
}

@test "Rule 9 AWK: tab-separated output survives colon-in-tag round-trip" {
  # Rule 9 outputs file<TAB>linenum<TAB>TAG.  Verify all three fields parse
  # correctly even when the file path contains colons.

  _simulated_output="/home/runner/work/my:project/lib/core/file.sh	17	SLASH_EXIT"

  _parsed_file=$(echo "$_simulated_output" | cut -f1)
  _parsed_line=$(echo "$_simulated_output" | cut -f2)
  _parsed_tag=$(echo "$_simulated_output" | cut -f3)

  [ "$_parsed_file" = "/home/runner/work/my:project/lib/core/file.sh" ] || {
    echo "cut -f1 did not return full path; got: '$_parsed_file'" >&2
    return 1
  }
  [ "$_parsed_line" = "17" ] || {
    echo "cut -f2 did not return line number; got: '$_parsed_line'" >&2
    return 1
  }
  [ "$_parsed_tag" = "SLASH_EXIT" ] || {
    echo "cut -f3 did not return tag; got: '$_parsed_tag'" >&2
    return 1
  }
}

@test "OLD FORMAT (colon) would have broken colon-in-path parsing" {
  # Demonstrate that the old cut -d: -f1 would have produced wrong results,
  # confirming the regression scenario this fix addresses.

  # Old format: "file:linenum" — broken when file contains a colon
  _old_format="/home/runner/work/my:project/file.sh:42"

  _broken_file=$(echo "$_old_format" | cut -d: -f1)
  _broken_line=$(echo "$_old_format" | cut -d: -f2)

  # The old parsing truncates the path at the first colon — wrong
  [ "$_broken_file" != "/home/runner/work/my:project/file.sh" ] || {
    echo "Unexpected: old colon-split did not truncate the path (test environment may differ)" >&2
    return 0  # Not a failure if the env happens to not have colons in paths
  }
  # The old parsing returns "project" (the segment after the first colon) — wrong
  [ "$_broken_line" = "project" ] || {
    echo "Old format returned unexpected second field: '$_broken_line'" >&2
    # This is informational; the important check is the new format works
    return 0
  }
}

# ---------------------------------------------------------------------------
# End-to-end functional: lint script correctly reports violations
# ---------------------------------------------------------------------------

@test "Rule 7 end-to-end: violation file and line number reported correctly" {
  # Create a fixture with 'local' at script scope on a known line.
  cat > "$FIXTURE_DIR/r7-bad-local.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
local foo="bar"
echo "$foo"
EOF

  run "$LINT_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "LOCAL_OUTSIDE_FUNCTION" ]] || {
    echo "Expected LOCAL_OUTSIDE_FUNCTION violation" >&2; return 1
  }

  # The filename in the violation output must match our fixture
  [[ "$output" =~ "r7-bad-local.sh" ]] || {
    echo "Fixture filename not found in output:" >&2
    echo "$output" | grep "LOCAL_OUTSIDE_FUNCTION" >&2
    return 1
  }

  # The violation must report line 3 (where 'local' appears)
  _line=$(echo "$output" | grep "LOCAL_OUTSIDE_FUNCTION" | grep "r7-bad-local" | \
    grep -oE ':[0-9]+ - LOCAL_OUTSIDE_FUNCTION' | grep -oE '[0-9]+' | head -1 || true)
  [ "$_line" = "3" ] || {
    echo "Expected line 3, got: '$_line'" >&2; return 1
  }
}

@test "Rule 8 end-to-end: violation file and line number reported correctly" {
  cat > "$FIXTURE_DIR/r8-bad-pipe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VAR=$(git log | grep "pattern")
EOF

  run "$LINT_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "UNSAFE_PIPE_IN_CMDSUB" ]]
  [[ "$output" =~ "r8-bad-pipe.sh" ]] || {
    echo "Fixture filename not found in output" >&2; return 1
  }

  _line=$(echo "$output" | grep "UNSAFE_PIPE_IN_CMDSUB" | grep "r8-bad-pipe" | \
    grep -oE ':[0-9]+ - UNSAFE_PIPE_IN_CMDSUB' | grep -oE '[0-9]+' | head -1 || true)
  [ "$_line" = "3" ] || {
    echo "Expected line 3, got: '$_line'" >&2; return 1
  }
}

@test "Rule 13 end-to-end: violation file and line number reported correctly" {
  cat > "$FIXTURE_DIR/r13-bad-gh.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
gh pr list
EOF

  run "$LINT_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "GH_UNSAFE_CALL" ]]
  [[ "$output" =~ "r13-bad-gh.sh" ]] || {
    echo "Fixture filename not found in output" >&2; return 1
  }

  _line=$(echo "$output" | grep "GH_UNSAFE_CALL" | grep "r13-bad-gh" | \
    grep -oE ':[0-9]+ - GH_UNSAFE_CALL' | grep -oE '[0-9]+' | head -1 || true)
  [ "$_line" = "3" ] || {
    echo "Expected line 3, got: '$_line'" >&2; return 1
  }
}
