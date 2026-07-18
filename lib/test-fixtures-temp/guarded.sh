#!/bin/bash
# lib/test-fixtures-temp/guarded.sh - has canonical re-source guard
set -euo pipefail

if declare -f guarded_function >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

guarded_function() {
  echo "hello"
}
