#!/bin/bash
set -euo pipefail

ISSUE_BODY="some body"
if echo "$ISSUE_BODY" | grep -qE "sharkrite-follow-up:"; then
  echo "found"
fi
