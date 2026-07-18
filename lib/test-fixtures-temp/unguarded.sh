#!/bin/bash
# lib/test-fixtures-temp/unguarded.sh - no re-source guard (fixture for lint test)
set -euo pipefail

some_function() {
  echo "hello"
}
