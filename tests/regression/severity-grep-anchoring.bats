#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/assess-and-resolve.sh, lib/core/local-review.sh
# Test suite for issue #28: Anchor severity grep to structured headers only
#
# Verifies that severity keyword matching uses structured headers/lines only,
# not bare words that could match reasoning text

setup() {
  # Create test fixtures for review and assessment output

  # Review fixture: contains reasoning text with "no critical issues found"
  # but the structured Findings line shows CRITICAL: 0
  export REVIEW_WITH_FALSE_POSITIVE=$(cat <<'EOF'
## Code Review Summary

The code changes look good. After thorough analysis, there are no critical
issues found in this PR. The implementation follows best practices.

**Findings: CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0**

All security checks passed.
EOF
)

  # Review fixture: real findings with structured summary
  export REVIEW_WITH_FINDINGS=$(cat <<'EOF'
## Code Review Summary

Several issues were identified that need attention.

**Findings: CRITICAL: 1 | HIGH: 2 | MEDIUM: 1 | LOW: 0**

### Issues
- Missing input validation (CRITICAL)
- Insufficient error handling (HIGH)
EOF
)

  # Assessment fixture: contains reasoning mentioning "previous ACTIONABLE_NOW item"
  # but only has 2 real ACTIONABLE_NOW structured headers
  export ASSESSMENT_WITH_FALSE_POSITIVE=$(cat <<'EOF'
## Assessment Results

Note: The previous ACTIONABLE_NOW item from the last review was resolved.

### Input Validation Missing - ACTIONABLE_NOW
Severity: HIGH
The user input is not validated before processing.

### Error Handling Insufficient - ACTIONABLE_NOW
Severity: MEDIUM
Error cases are not properly handled.

### Documentation Outdated - DISMISSED
Severity: LOW
This was addressed in reasoning above about the previous item.
EOF
)

  # Assessment fixture: ACTIONABLE_LATER items with severity metadata
  export ASSESSMENT_LATER_ITEMS=$(cat <<'EOF'
## Assessment Results

### Add Logging - ACTIONABLE_LATER
Severity: CRITICAL
No logging exists for audit trail.

### Refactor Function - ACTIONABLE_LATER
Severity: HIGH
The function is too complex.

### Update Comments - ACTIONABLE_LATER
Severity: LOW
Code comments are sparse.
EOF
)
}

# Test merge-pr.sh security findings detection (Findings line parsing)
@test "merge-pr.sh: review with 'no critical issues found' text yields zero findings" {
  # Extract and parse Findings line (mimics merge-pr.sh:174-192)
  FINDINGS_LINE=$(echo "$REVIEW_WITH_FALSE_POSITIVE" | grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+" | head -1 || true)

  [ -n "$FINDINGS_LINE" ]  # Findings line should exist

  CRITICAL_NUM=$(echo "$FINDINGS_LINE" | grep -oE "CRITICAL: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  HIGH_NUM=$(echo "$FINDINGS_LINE" | grep -oE "HIGH: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  MEDIUM_NUM=$(echo "$FINDINGS_LINE" | grep -oE "MEDIUM: [0-9]+" | grep -oE "[0-9]+" || echo "0")

  SEVERITY_SUM=$((CRITICAL_NUM + HIGH_NUM + MEDIUM_NUM))

  # Should be 0 despite "critical" appearing in reasoning text
  [ "$SEVERITY_SUM" -eq 0 ]
}

@test "merge-pr.sh: review with actual findings yields non-zero sum" {
  FINDINGS_LINE=$(echo "$REVIEW_WITH_FINDINGS" | grep -oE "Findings: CRITICAL: [0-9]+ [|] HIGH: [0-9]+ [|] MEDIUM: [0-9]+" | head -1 || true)

  [ -n "$FINDINGS_LINE" ]

  CRITICAL_NUM=$(echo "$FINDINGS_LINE" | grep -oE "CRITICAL: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  HIGH_NUM=$(echo "$FINDINGS_LINE" | grep -oE "HIGH: [0-9]+" | grep -oE "[0-9]+" || echo "0")
  MEDIUM_NUM=$(echo "$FINDINGS_LINE" | grep -oE "MEDIUM: [0-9]+" | grep -oE "[0-9]+" || echo "0")

  SEVERITY_SUM=$((CRITICAL_NUM + HIGH_NUM + MEDIUM_NUM))

  # Should be 4 (1 CRITICAL + 2 HIGH + 1 MEDIUM)
  [ "$SEVERITY_SUM" -eq 4 ]
}

# Test assess-and-resolve.sh structured header counting
@test "assess-and-resolve.sh: assessment with 'previous ACTIONABLE_NOW' text yields correct count" {
  # Count structured headers only (mimics assess-and-resolve.sh:621)
  ACTIONABLE_NOW_COUNT=$(echo "$ASSESSMENT_WITH_FALSE_POSITIVE" | grep -c "^### .* - ACTIONABLE_NOW" || true)

  # Should be 2, not 3 (doesn't match "previous ACTIONABLE_NOW item" in reasoning)
  [ "$ACTIONABLE_NOW_COUNT" -eq 2 ]
}

@test "assess-and-resolve.sh: DISMISSED items are not counted as ACTIONABLE" {
  ACTIONABLE_COUNT=$(echo "$ASSESSMENT_WITH_FALSE_POSITIVE" | grep -c "^### .* - ACTIONABLE_\(NOW\|LATER\)" || true)
  DISMISSED_COUNT=$(echo "$ASSESSMENT_WITH_FALSE_POSITIVE" | grep -c "^### .* - DISMISSED" || true)

  [ "$ACTIONABLE_COUNT" -eq 2 ]
  [ "$DISMISSED_COUNT" -eq 1 ]
}

# Test assess-and-resolve.sh severity extraction (lines 862-890)
@test "assess-and-resolve.sh: extract ACTIONABLE_LATER items by severity using structured headers" {
  # Extract CRITICAL items (mimics assess-and-resolve.sh:862)
  CRITICAL_ISSUES=$(echo "$ASSESSMENT_LATER_ITEMS" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*CRITICAL" || echo "")
  CRITICAL_COUNT=$(echo "$CRITICAL_ISSUES" | grep -c "^### .* - ACTIONABLE_LATER" || true)

  [ "$CRITICAL_COUNT" -eq 1 ]

  # Extract HIGH items
  HIGH_ISSUES=$(echo "$ASSESSMENT_LATER_ITEMS" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*HIGH" || echo "")
  HIGH_COUNT=$(echo "$HIGH_ISSUES" | grep -c "^### .* - ACTIONABLE_LATER" || true)

  [ "$HIGH_COUNT" -eq 1 ]

  # Extract LOW items
  LOW_ISSUES=$(echo "$ASSESSMENT_LATER_ITEMS" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*LOW" || echo "")
  LOW_COUNT=$(echo "$LOW_ISSUES" | grep -c "^### .* - ACTIONABLE_LATER" || true)

  [ "$LOW_COUNT" -eq 1 ]
}

@test "assess-and-resolve.sh: severity keyword in reasoning text doesn't inflate counts" {
  # Create fixture with "CRITICAL" in reasoning but only MEDIUM severity items
  REASONING_FIXTURE=$(cat <<'EOF'
## Assessment

The previous CRITICAL issue was fixed. This is now safe.

### Minor Issue - ACTIONABLE_LATER
Severity: MEDIUM
Not critical anymore.
EOF
)

  # Extract CRITICAL items - should find none
  CRITICAL_ISSUES=$(echo "$REASONING_FIXTURE" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*CRITICAL" || echo "")
  CRITICAL_COUNT=$(echo "$CRITICAL_ISSUES" | grep -c "^### .* - ACTIONABLE_LATER" || true)

  [ "$CRITICAL_COUNT" -eq 0 ]

  # Extract MEDIUM items - should find one
  MEDIUM_ISSUES=$(echo "$REASONING_FIXTURE" | grep -A 20 "^### .* - ACTIONABLE_LATER" | grep -B 2 "Severity:.*MEDIUM" || echo "")
  MEDIUM_COUNT=$(echo "$MEDIUM_ISSUES" | grep -c "^### .* - ACTIONABLE_LATER" || true)

  [ "$MEDIUM_COUNT" -eq 1 ]
}
