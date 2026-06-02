#!/usr/bin/env bash
# Stub assess-review-issues.sh: outputs MOCK_ASSESSMENT_FILE content to stdout.
set -euo pipefail
if [ -z "${MOCK_ASSESSMENT_FILE:-}" ] || [ ! -f "$MOCK_ASSESSMENT_FILE" ]; then
  echo "STUB ERROR: MOCK_ASSESSMENT_FILE not set or missing" >&2
  exit 1
fi
cat "$MOCK_ASSESSMENT_FILE"
exit 0
