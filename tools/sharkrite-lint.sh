#!/usr/bin/env bash
# Sharkrite custom lint rules
# Catches bash anti-patterns that shellcheck doesn't detect
#
# Exit codes:
#   0 - All checks passed
#   1 - Lint violations found

set -euo pipefail

# Color output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track violations
VIOLATIONS=0

# Print error with file and line number
print_violation() {
  local file=$1
  local line=$2
  local rule=$3
  local message=$4

  echo -e "${RED}✗${NC} $file:$line - $rule: $message"
  ((VIOLATIONS++))
}

# Print warning (informational, doesn't fail build)
print_warning() {
  local file=$1
  local line=$2
  local rule=$3
  local message=$4

  echo -e "${YELLOW}⚠${NC} $file:$line - $rule: $message"
}

echo "Running Sharkrite custom lint rules..."
echo ""

# Find all shell scripts
SHELL_FILES=$(find "$PROJECT_ROOT/bin" "$PROJECT_ROOT/lib" -type f \( -name "*.sh" -o -path "*/bin/rite*" \) 2>/dev/null)

# Rule 1: grep -c with || echo "0" (produces double zero)
echo "Checking for 'grep -c ... || echo \"0\"' pattern..."
for file in $SHELL_FILES; do
  # Match: grep -c <pattern> || echo "0"
  # This is wrong because grep -c always outputs a count
  while IFS=: read -r line_num line_content; do
    if echo "$line_content" | grep -qE 'grep\s+-c.*\|\|\s*echo\s+"0"'; then
      print_violation "$file" "$line_num" "GREP_C_ECHO_ZERO" \
        "grep -c already outputs '0', use || true instead of || echo \"0\""
    fi
  done < <(grep -n 'grep -c' "$file" 2>/dev/null || true)
done

# Rule 2: git push without explicit refspec (dangerous in automation)
echo "Checking for 'git push' without explicit refspec..."
for file in $SHELL_FILES; do
  while IFS=: read -r line_num line_content; do
    # Skip if it's a comment
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: git push (without branch/refspec)
    # Allow: git push origin <branch>, git push -u, git push --force-with-lease
    if echo "$line_content" | grep -qE 'git\s+push\s*$' || \
       echo "$line_content" | grep -qE 'git\s+push\s+(--[a-z-]+\s*)+$'; then
      # Check if this is NOT followed by a refspec
      if ! echo "$line_content" | grep -qE 'git\s+push.*origin'; then
        print_violation "$file" "$line_num" "GIT_PUSH_NO_REFSPEC" \
          "git push without explicit refspec/branch is dangerous in automation"
      fi
    fi
  done < <(grep -n 'git push' "$file" 2>/dev/null || true)
done

# Rule 3: eval with GitHub API data (security risk)
echo "Checking for 'eval' with potentially untrusted data..."
for file in $SHELL_FILES; do
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: eval with variables that might contain GitHub data
    if echo "$line_content" | grep -qE '\beval\s+.*\$'; then
      # Check if the variable name suggests GitHub/API data
      if echo "$line_content" | grep -qiE '\$(gh|api|response|body|pr_|issue_|json)'; then
        print_warning "$file" "$line_num" "EVAL_UNTRUSTED_DATA" \
          "eval with GitHub API data detected - verify input sanitization"
      fi
    fi
  done < <(grep -n 'eval' "$file" 2>/dev/null || true)
done

# Rule 4: Unquoted heredoc in command substitution
echo "Checking for unquoted heredoc in command substitution..."
for file in $SHELL_FILES; do
  # Match: $(cat <<EOF or $(... <<EOF without quotes
  # Safe: $(cat <<'EOF' or $(cat << 'EOF' with space before quote
  while IFS=: read -r line_num line_content; do
    # Check for suppression comment on previous line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*UNQUOTED_HEREDOC'; then
      continue
    fi

    if echo "$line_content" | grep -qE '\$\([^)]*<<[^)]*(EOF|END|HEREDOC)' && \
       ! echo "$line_content" | grep -qE "<<\s*'"; then
      print_violation "$file" "$line_num" "UNQUOTED_HEREDOC_CMDSUB" \
        "Unquoted heredoc in command substitution - use <<'EOF' to prevent expansion"
    fi
  done < <(grep -n '<<.*EOF' "$file" 2>/dev/null || true)
done

# Rule 5: BSD-only sed -i without GNU fallback
echo "Checking for BSD-only 'sed -i' without GNU fallback..."
for file in $SHELL_FILES; do
  while IFS=: read -r line_num line_content; do
    # Skip comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi
    # Match: sed -i '' (BSD format)
    if echo "$line_content" | grep -qE "sed\s+-i\s+''"; then
      # Check if there's a GNU fallback in the same file
      if ! grep -q 'sed --version' "$file" 2>/dev/null; then
        print_violation "$file" "$line_num" "BSD_SED_NO_FALLBACK" \
          "BSD sed -i '' detected without GNU fallback check"
      fi
    fi
  done < <(grep -n "sed -i" "$file" 2>/dev/null || true)
done

# Rule 6: PIPESTATUS after || true or non-pipeline
echo "Checking for PIPESTATUS misuse..."
for file in $SHELL_FILES; do
  # Read file content to check context
  file_content=$(cat "$file")

  # Find all PIPESTATUS usages
  while IFS=: read -r line_num line_content; do
    # Get previous line for context
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || echo "")

    # Check if previous line has || true (which destroys PIPESTATUS)
    if echo "$prev_line" | grep -qE '\|\|\s*true\s*$'; then
      print_violation "$file" "$line_num" "PIPESTATUS_AFTER_OR_TRUE" \
        "PIPESTATUS used after '|| true' - PIPESTATUS is lost/stale"
    fi

    # Check if PIPESTATUS is used but there's no pipe on the previous line
    # Exception: if it's inside a fallback like ${PIPESTATUS[0]:-$?}
    if ! echo "$line_content" | grep -qE '\$\{PIPESTATUS\[0\]:-'; then
      if ! echo "$prev_line" | grep -qE '\|'; then
        # Could be a false positive if the pipe is 2+ lines up, but flag it
        print_warning "$file" "$line_num" "PIPESTATUS_NO_PIPELINE" \
          "PIPESTATUS referenced but no pipe found on previous line - verify context"
      fi
    fi
  done < <(grep -n 'PIPESTATUS\[' "$file" 2>/dev/null || true)
done

# Rule 7: local keyword outside function (SC2168 - but catch our own)
echo "Checking for 'local' outside function scope..."
for file in $SHELL_FILES; do
  # Parse the file to check if 'local' is inside a function
  # Simple heuristic: if there's no 'function' or '() {' before 'local', it's wrong

  in_function=0
  brace_depth=0

  while IFS= read -r line; do
    line_num=$((${line_num:-0} + 1))

    # Track function definitions
    if echo "$line" | grep -qE '^\s*(function\s+\w+|^\s*\w+\s*\(\))'; then
      in_function=1
    fi

    # Track braces (functions end with })
    open_braces=$(echo "$line" | grep -o '{' | wc -l || echo 0)
    close_braces=$(echo "$line" | grep -o '}' | wc -l || echo 0)
    brace_depth=$((brace_depth + open_braces - close_braces))

    if [ $brace_depth -eq 0 ]; then
      in_function=0
    fi

    # Check for 'local' outside function
    if echo "$line" | grep -qE '^\s*local\s+\w+' && [ $in_function -eq 0 ]; then
      # Skip if it's in a comment or example
      if ! echo "$line" | grep -qE '^\s*#'; then
        print_violation "$file" "$line_num" "LOCAL_OUTSIDE_FUNCTION" \
          "'local' keyword used outside function (only works inside functions)"
      fi
    fi
  done < "$file"

  # Reset for next file
  line_num=0
done

echo ""
echo "----------------------------------------"
if [ $VIOLATIONS -eq 0 ]; then
  echo -e "${GREEN}✓${NC} All custom lint checks passed!"
  exit 0
else
  echo -e "${RED}✗${NC} Found $VIOLATIONS violation(s)"
  exit 1
fi
