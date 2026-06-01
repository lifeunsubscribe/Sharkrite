#!/bin/bash
set -euo pipefail

# BAD: outer guard without format anchor
ISSUE_BODY="some body"
if echo "$ISSUE_BODY" | grep -q "sharkrite-parent-pr:"; then
  PR=$(echo "$ISSUE_BODY" | grep -oE 'sharkrite-parent-pr:[0-9]+' | cut -d: -f2 || true)
fi
