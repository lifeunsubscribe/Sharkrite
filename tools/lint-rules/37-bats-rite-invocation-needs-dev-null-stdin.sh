# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 37: real-bin/rite invocations in .bats files must carry < /dev/null
#
# When a test executes the real `bin/rite` (via `bash <path>/rite` or
# `bash <path>/bin/rite`) WITHOUT redirecting stdin, a child that rite spawns
# can reach for the controlling terminal. Under the post-commit gate's
# `bats --jobs 8` run, that SIGTTIN-stops the whole bats process group, the
# gate's `tee` never sees EOF, and the run hangs until the 1800s whole-run
# watchdog kills it (GATE_TIMEOUT) — a 30-minute freeze that then fails the
# lap. This is the rite-804 class documented in gate-bats-sandbox.bats, and it
# recurred in #1031's target-branch-flag.bats (a 30-min hang, 2026-07-14).
# gate-bats-sandbox.bats only guards ONE file by name; this rule enforces the
# `< /dev/null` guard on EVERY test that drives rite.
#
# Flags a line that invokes `bash …/rite` at command position (start of line,
# or after `run` / `;` / `&&` / `||` / `|` / `(`) unless the line also carries
# `< /dev/null` (or `</dev/null`), pipes INTO the invocation (stdin is the pipe,
# not a tty), or feeds it a heredoc.
#
# Suppression (rare — e.g. a test that deliberately supplies interactive input):
#   # sharkrite-lint disable BATS_RITE_STDIN_GUARD - Reason: <why>
echo "Checking for real-bin/rite invocations in .bats files without a < /dev/null stdin guard..."

# Command-position anchor: rite is being EXECUTED, not merely named in a string
# assertion / grep / comment. `bash` sits at line start or just after a
# command separator or the bats `run` wrapper.
_r37_exec='(^|[;&|(]|run )[[:space:]]*bash[[:space:]]+"?[^"|]*/(bin/)?rite"?'

while IFS= read -r bats_file; do
  [ -z "$bats_file" ] && continue
  case "$bats_file" in
    *tests/helpers/*|*tests/fixtures/*) continue ;;
  esac

  while IFS=: read -r _r37_lno _r37_line; do
    [ -z "$_r37_lno" ] && continue
    # Skip full-line comments (a documented example, not an execution).
    case "$_r37_line" in [[:space:]]*\#*|\#*) continue ;; esac
    # Guard present on the line → safe.
    case "$_r37_line" in *"< /dev/null"*|*"</dev/null"*) continue ;; esac
    # Piped INTO rite (stdin is the pipe, not a tty) or fed a heredoc → safe.
    case "$_r37_line" in *"|"*bash*rite*|*"<<"*) continue ;; esac
    # Inline suppression on the immediately-preceding line.
    if [ "$_r37_lno" -gt 1 ]; then
      _r37_prev=$(sed -n "$((_r37_lno - 1))p" "$bats_file" 2>/dev/null || true)
      case "$_r37_prev" in *"sharkrite-lint disable BATS_RITE_STDIN_GUARD"*) continue ;; esac
    fi
    print_violation "$bats_file" "$_r37_lno" "BATS_RITE_STDIN_GUARD" \
      "real-bin/rite invocation without a '< /dev/null' stdin guard. Under the gate's bats --jobs 8 run a rite child can grab the tty, SIGTTIN-stops the bats process group, and the gate hangs to its 1800s watchdog (the rite-804 / #1031 freeze). Append '< /dev/null' to this invocation, or suppress with '# sharkrite-lint disable BATS_RITE_STDIN_GUARD - Reason: ...' on the line above."
  done < <(grep -nE "$_r37_exec" "$bats_file" 2>/dev/null || true)
done < <(find tests -name '*.bats' -type f 2>/dev/null || true)
