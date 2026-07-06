# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 33: Unguarded array expansion in #!/bin/bash scripts (bash 3.2 set -u crash)
# (Rule numbers 31/32 are reserved by the in-flight provider-model-role branch.)
#
# On macOS system bash 3.2, expanding an EMPTY array via "${arr[@]}" under
# set -u crashes with "arr[@]: unbound variable". Live class: #266, #327, and
# the 2026-07-04 audit (`rite plan "<instructions>"` and `rite --status
# --by-label` both crashed). Canonical fix is the +idiom:
#   "${arr[@]+"${arr[@]}"}"
# or a ${#arr[@]} count-guard near the expansion.
#
# Heuristics (deliberately simple; suppress residual FPs inline):
#   - only #!/bin/bash files (env-bash files run under homebrew bash 4+)
#   - a line carrying the idiom marker `[@]+` is safe (the idiom's own inner
#     expansion would otherwise self-flag)
#   - an expansion is safe if a ${#name[@]} reference OR a non-empty literal
#     init `name=(x ...)` appears on the same line or within the previous 10
#     code lines (`name+=(...)` deliberately does NOT count — conditional
#     appends leave the array empty on the zero-iteration path)
#   - always-set bash specials excluded (BASH_SOURCE, FUNCNAME, PIPESTATUS, ...)
#   - heredoc bodies skipped (generated-child content is not this file's shell)
#
# Suppress: # sharkrite-lint disable EMPTY_ARRAY_EXPANSION_BASH32 - Reason: <text>
echo "Checking for unguarded empty-array expansions in #!/bin/bash scripts (bash 3.2)..."
for file in "${SHELL_FILES[@]}"; do
  head -1 "$file" 2>/dev/null | grep -q '^#!/bin/bash' || continue
  _r33_hits=$(awk '
    FNR == 1 { in_heredoc = 0; hd_marker = ""; ml_name = "" }
    {
      if (in_heredoc) {
        _c = $0; sub(/^[[:space:]]*/, "", _c)
        if (_c == hd_marker) in_heredoc = 0
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      if (index($0, "<<") > 0) {
        tok = $0; sub(/.*<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok); split(tok, _p, " ")
        if (length(_p[1]) > 0 && _p[1] ~ /^[A-Za-z_][A-Za-z_0-9]*$/) { hd_marker = _p[1]; in_heredoc = 1 }
      }
      line = $0
      # Record count-guards: ${#name[@]} anywhere on the line.
      tmp = line
      while (match(tmp, /\$\{#[A-Za-z_][A-Za-z0-9_]*\[@\]\}/)) {
        g = substr(tmp, RSTART + 3, RLENGTH - 7)
        guard[g] = FNR
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      # Record non-empty literal inits: name=(x ...). `+=` never matches this
      # regex (the + is outside [A-Za-z0-9_]), which is deliberate.
      tmp = line
      while (match(tmp, /[A-Za-z_][A-Za-z0-9_]*=\([^)[:space:]]/)) {
        seg = substr(tmp, RSTART, RLENGTH)
        split(seg, _q, /=\(/)
        guard[_q[1]] = FNR
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      # Multi-line literal init: `name=(` at end of line opens a static list
      # (REQUIRED_DIRS=( ... ) style). Nobody writes an EMPTY multi-line
      # literal, so treat it as a non-empty init — and keep the guard anchored
      # to the closing paren of the list by bumping it on every interior line,
      # so the 10-line window starts where the list ends, not where it opens.
      if (ml_name != "") {
        guard[ml_name] = FNR
        if (line ~ /^[[:space:]]*\)[[:space:];]*$/) ml_name = ""
      }
      if (match(line, /[A-Za-z_][A-Za-z0-9_]*=\([[:space:]]*$/)) {
        seg = substr(line, RSTART, RLENGTH)
        split(seg, _q2, /=\(/)
        guard[_q2[1]] = FNR
        ml_name = _q2[1]
      }
      # Lines already using the +idiom are safe as a whole.
      if (index(line, "[@]+") > 0) next
      # Flag plain expansions "${name[@]}" lacking a recent guard.
      tmp = line
      while (match(tmp, /"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"/)) {
        name = substr(tmp, RSTART + 3, RLENGTH - 8)
        tmp = substr(tmp, RSTART + RLENGTH)
        if (name == "BASH_SOURCE" || name == "FUNCNAME" || name == "PIPESTATUS" || \
            name == "BASH_REMATCH" || name == "COMP_WORDS" || name == "BASH_ARGV" || \
            name == "DIRSTACK") continue
        if ((name in guard) && FNR - guard[name] <= 10) continue
        print FNR "\t" name
      }
    }
  ' "$file" </dev/null 2>/dev/null || true)
  [ -z "$_r33_hits" ] && continue
  while IFS=$'\t' read -r _r33_line _r33_name; do
    [ -z "$_r33_line" ] && continue
    _r33_prev=$(sed -n "$((_r33_line - 1))p" "$file" 2>/dev/null || true)
    if echo "$_r33_prev" | grep -q 'sharkrite-lint disable EMPTY_ARRAY_EXPANSION_BASH32'; then
      continue
    fi
    print_violation "$file" "$_r33_line" "EMPTY_ARRAY_EXPANSION_BASH32" \
      "\"\${${_r33_name}[@]}\" without +idiom or nearby \${#${_r33_name}[@]} guard crashes bash 3.2 under set -u when the array is empty — use \"\${${_r33_name}[@]+\"\${${_r33_name}[@]}\"}\""
  done <<< "$_r33_hits"
done

