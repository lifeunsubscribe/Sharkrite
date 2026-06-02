#!/bin/bash
set -euo pipefail

ISSUE_BODY="some body"
# sharkrite-lint disable BARE_MARKER_GREP - intentional bad-pattern fixture for lint regression
if echo "$ISSUE_BODY" | grep -qE "sharkrite-follow-up:"; then
  echo "found"
fi
