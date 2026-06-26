#!/usr/bin/env bash
# Date/time conversion utilities for Sharkrite
#
# All functions operate in UTC timezone to ensure consistent epoch comparisons
# across different systems and timezones.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f iso_to_epoch >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Convert ISO 8601 UTC timestamp to Unix epoch seconds
#
# Input:  2025-10-28T20:42:18Z (ISO 8601 UTC format)
# Output: 1761684138 (Unix epoch seconds)
#
# Handles both GNU date (Linux) and BSD date (macOS) automatically.
# Returns "0" on parse failure for consistent error handling.
#
# Usage:
#   epoch=$(iso_to_epoch "2025-10-28T20:42:18Z")
#
iso_to_epoch() {
  local iso_timestamp="$1"

  # Detect GNU vs BSD date
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux) - supports -d flag
    date -d "$iso_timestamp" "+%s" 2>/dev/null || echo "0"
  else
    # BSD date (macOS) - requires -u (interpret input as UTC), -j (don't set),
    # and -f (input format). Without -u the trailing Z is a literal and the
    # timestamp is parsed in local time, skewing the epoch by the local offset
    # (epoch_to_iso already uses -u; this keeps the pair symmetric).
    # Expected format: YYYY-MM-DDTHH:MM:SSZ
    date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$iso_timestamp" "+%s" 2>/dev/null || echo "0"
  fi
}

# Convert Unix epoch seconds to ISO 8601 UTC timestamp
#
# Input:  1761684138 (Unix epoch seconds)
# Output: 2025-10-28T20:42:18Z (ISO 8601 UTC format)
#
# Handles both GNU date (Linux) and BSD date (macOS) automatically.
# Returns empty string on conversion failure.
#
# Usage:
#   iso=$(epoch_to_iso "1761684138")
#
epoch_to_iso() {
  local epoch_seconds="$1"

  # Detect GNU vs BSD date
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux) - supports -d with @epoch syntax
    date -u -d "@${epoch_seconds}" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
  else
    # BSD date (macOS) - requires -r (seconds since epoch)
    date -u -r "$epoch_seconds" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
  fi
}

# Format ISO 8601 UTC timestamp for human-readable local display
#
# Input:  2025-10-28T20:42:18Z (ISO 8601 UTC format)
# Output: Oct 28, 2025 - 2:42 PM MT (local timezone with AM/PM)
#
# Converts from UTC to local timezone and formats for display.
# Returns the original timestamp if parsing fails.
#
# Usage:
#   display=$(iso_to_local_display "2025-10-28T20:42:18Z")
#
iso_to_local_display() {
  local iso_timestamp="$1"

  # Detect GNU vs BSD date
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux) - supports -d flag
    date -d "$iso_timestamp" "+%b %d, %Y - %-I:%M %p %Z" 2>/dev/null || echo "$iso_timestamp"
  else
    # BSD date (macOS) - requires manual component extraction
    # BSD date is picky about ISO format, so we parse components first
    local year month day time
    year=$(echo "$iso_timestamp" | cut -d'T' -f1 | cut -d'-' -f1)
    month=$(echo "$iso_timestamp" | cut -d'T' -f1 | cut -d'-' -f2)
    day=$(echo "$iso_timestamp" | cut -d'T' -f1 | cut -d'-' -f3)
    time=$(echo "$iso_timestamp" | cut -d'T' -f2 | cut -d'Z' -f1)

    # Parse into BSD date format (-j: don't set, -f: input format)
    date -j -f "%Y-%m-%d %H:%M:%S" "$year-$month-$day $time" "+%b %d, %Y - %-I:%M %p %Z" 2>/dev/null || echo "$iso_timestamp"
  fi
}
