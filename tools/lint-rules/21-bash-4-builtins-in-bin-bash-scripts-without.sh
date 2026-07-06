# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 21: bash 4+ builtins in #!/bin/bash scripts without a version guard
#
# `mapfile`, `readarray`, and `declare -A` are bash 4.0+ features. Scripts with
# a `#!/bin/bash` shebang run under macOS system bash 3.2 when executed directly
# (e.g., as a CLI entrypoint) and will crash at the bash-4+ line without the
# self-re-exec guard pattern established in batch-process-issues.sh:69-77.
#
# Live crash (2026-06-04): rite --undo <N> with follow-up issues exploded:
#   /bin/bash: line 133: mapfile: command not found
# Root cause: undo-workflow.sh used mapfile for deduplication but lacked the
# bash-version guard present in batch-process-issues.sh. Fixed in issue #327.
#
# A file is EXEMPT when it contains a functional BASH_VERSINFO version-
# comparison guard: BASH_VERSINFO[<index>] used with a comparison operator
# and a version number on the same line. Bare mentions of BASH_VERSINFO in
# comments or diagnostic output do NOT exempt the file.
#
# Canonical guard shapes (from the codebase):
#   [ "${BASH_VERSINFO[0]}" -lt 4 ]   (test builtin numeric comparison)
#   (( BASH_VERSINFO[0] < 4 ))        (arithmetic conditional)
#
# The rule ONLY fires on #!/bin/bash scripts — not #!/usr/bin/env bash ones.
# The latter let the user's PATH pick the bash binary, so Homebrew bash 5.x
# is typically found first. Only #!/bin/bash is pinned to macOS's 3.2 binary.
#
# Suppression: add on the line immediately before the bash-4+ builtin:
#   # sharkrite-lint disable BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT - reason: <text>
echo "Checking for bash 4+ builtins in #!/bin/bash scripts without a version guard..."

for file in "${SHELL_FILES[@]}"; do
  # Only flag files with #!/bin/bash shebang (not #!/usr/bin/env bash)
  first_line=$(head -1 "$file" 2>/dev/null || true)
  if ! echo "$first_line" | grep -qE '^#!/bin/bash'; then
    continue
  fi

  # Exempt: file has a functional BASH_VERSINFO version-comparison guard.
  #
  # Two bugs to avoid in this check:
  #
  #   1. Comment lines must NOT grant exemption: a comment documenting the
  #      guard pattern (e.g. "# if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then")
  #      contains the full pattern and would exempt a file with no real guard
  #      if we scan all lines.  Fix: strip comment lines before matching.
  #
  #   2. Redirects to numeric filenames must NOT grant exemption: the
  #      arithmetic-operator alternative "[<>=!][=]?[[:space:]]*[0-9]" also
  #      matches shell redirect syntax like ">2" (stdout to file named "2").
  #      A diagnostic line such as `echo "${BASH_VERSINFO[0]}" >2` would
  #      incorrectly exempt the file.  Fix: anchor the arithmetic form to a
  #      "(( " prefix so it only matches inside arithmetic conditionals,
  #      where ">" is always a comparison, never a redirect.
  #
  # Two passes — one per canonical guard shape:
  #
  #   Shape 1 (test builtin):   [ "${BASH_VERSINFO[0]}" -lt 4 ]
  #   Shape 2 (arithmetic):     (( BASH_VERSINFO[0] < 4 ))
  #
  # Comment lines (^[[:space:]]*#) are stripped before both passes so that
  # commented-out guards do not trigger the exemption.
  _non_comment_lines=$(grep -v '^[[:space:]]*#' "$file" 2>/dev/null || true)
  # Shape 1: test-builtin numeric comparison (-lt/-gt/-le/-ge/-eq/-ne)
  # No redirect ambiguity: -lt etc. are unambiguous comparison keywords.
  if echo "$_non_comment_lines" | grep -qE 'BASH_VERSINFO\[[0-9]+\][^#]*(-lt|-gt|-le|-ge|-eq|-ne)[[:space:]]+[0-9]'; then
    continue
  fi
  # Shape 2: arithmetic conditional — anchored to "((" so ">" means comparison,
  # not redirect.  Inside "(( ))", "<" and ">" are always arithmetic operators.
  if echo "$_non_comment_lines" | grep -qE '\(\([^)]*BASH_VERSINFO\[[0-9]+\][^)]*[<>][=]?[[:space:]]*[0-9]'; then
    continue
  fi

  # Check each line for bash-4+ builtins: mapfile, readarray, declare -A
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # Check for suppression comment on the preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT'; then
      continue
    fi

    # Detect mapfile or readarray (array-population builtins, bash 4+ only)
    if echo "$line_content" | grep -qE '\b(mapfile|readarray)\b'; then
      print_violation "$file" "$line_num" "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" \
        "'mapfile'/'readarray' is a bash 4+ builtin — crashes on macOS system bash 3.2. Add a BASH_VERSINFO re-exec guard (see batch-process-issues.sh:69-77) or replace with a portable while-read loop"
    fi

    # Detect declare -A / declare -gA / declare -Ar / local -A (associative arrays, bash 4+ only)
    if echo "$line_content" | grep -qE '\bdeclare\s+-[a-zA-Z]*A[a-zA-Z]*\b|\blocal\s+-[a-zA-Z]*A[a-zA-Z]*\b'; then
      print_violation "$file" "$line_num" "BASH_4_BUILTIN_IN_BIN_BASH_SCRIPT" \
        "'declare/local -A' (associative array) is bash 4+ only — crashes on macOS system bash 3.2. Add a BASH_VERSINFO re-exec guard (see batch-process-issues.sh:69-77)"
    fi
  done < <(grep -nE '(mapfile|readarray|declare\s+-[a-zA-Z]*A|local\s+-[a-zA-Z]*A)' "$file" 2>/dev/null || true)
done

