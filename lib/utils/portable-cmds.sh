#!/usr/bin/env bash
# lib/utils/portable-cmds.sh
# Portable wrappers for BSD/GNU command flag differences
#
# Sharkrite runs on macOS (BSD toolchain) and Linux CI (GNU toolchain).
# Three commands have incompatible flag syntax:
#   - sed -i: BSD requires an explicit backup suffix (sed -i ''), GNU forbids it
#   - stat:   BSD uses -f "%m" for mtime, GNU uses -c "%Y"
#   - xargs:  Always pair with find -print0 to handle spaces in filenames
#
# Usage: source this file, then call the helper functions.
#
# Detection strategy: mirrors the existing date-helpers.sh pattern —
# `sed --version` exits 0 on GNU, nonzero on BSD.

# portable_sed_i — in-place sed edit, portable across BSD and GNU
#
# Args:
#   $1...$((N-1)): sed expression arguments (e.g., "s|foo|bar|", -e "...", -e "...")
#   $N:            the file to edit in-place (last argument)
#
# Usage:
#   portable_sed_i "s|foo|bar|" file.txt
#   portable_sed_i -e "s|a|b|" -e "s|c|d|" file.txt
#
# On GNU (Linux): sed -i "s|foo|bar|" file.txt
# On BSD (macOS): sed -i '' "s|foo|bar|" file.txt
portable_sed_i() {
  # Detect GNU vs BSD sed once per call (same pattern as date-helpers.sh)
  if sed --version >/dev/null 2>&1; then
    # GNU sed (Linux) — no backup suffix needed
    sed -i "$@"
  else
    # BSD sed (macOS) — empty string means no backup file
    sed -i '' "$@"
  fi
}

# portable_stat_mtime — return the mtime of a file as Unix epoch seconds
#
# Args:
#   $1: file path
#
# Output: epoch seconds as a decimal integer, or "0" on failure
#
# On GNU (Linux): stat -c "%Y" FILE
# On BSD (macOS): stat -f "%m" FILE
#
# Usage:
#   mtime=$(portable_stat_mtime /path/to/file)
portable_stat_mtime() {
  local file="$1"

  if stat --version >/dev/null 2>&1; then
    # GNU stat (Linux) — %Y = mtime in epoch seconds
    stat -c "%Y" "$file" 2>/dev/null || echo "0"
  else
    # BSD stat (macOS) — %m = mtime in epoch seconds
    stat -f "%m" "$file" 2>/dev/null || echo "0"
  fi
}

# portable_find_max_mtime — return the most recent mtime (epoch seconds) from
# a list of files passed on stdin, one path per line (NUL-delimited via -print0).
#
# Replaces the pattern:
#   find ... | xargs stat -f "%m" 2>/dev/null | sort -rn | head -1
#
# Usage (pair find's -print0 with this function):
#   LAST_MODIFIED=$(find "$dir" -type f -print0 2>/dev/null \
#     | portable_find_max_mtime || true)
#   [ "${LAST_MODIFIED:-0}" = "0" ] && LAST_MODIFIED=""
#
# Use || true (not || echo "0") — the function already returns "0" on empty
# input; || echo "0" would produce a double "0" via grep -c style confusion.
#
# Returns "0" when no files are found or all stat calls fail.
portable_find_max_mtime() {
  local max_mtime=0
  local mtime

  # Read NUL-delimited paths from stdin (produced by find -print0).
  # Using read -r -d '' (NUL delimiter) handles filenames with spaces,
  # newlines, and special characters without invoking xargs.
  while IFS= read -r -d '' filepath; do
    mtime=$(portable_stat_mtime "$filepath")
    if [ "$mtime" -gt "$max_mtime" ] 2>/dev/null; then
      max_mtime="$mtime"
    fi
  done

  echo "$max_mtime"
}
