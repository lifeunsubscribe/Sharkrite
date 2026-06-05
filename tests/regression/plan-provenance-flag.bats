#!/usr/bin/env bats
# tests/regression/plan-provenance-flag.bats
#
# Regression tests for the flag-first provenance linting feature in plan-issues.sh.
#
# Feature: `rite plan` generated issues should only include a "**Field provenance:**"
# section when output fields come from external or non-obvious sources. The
# _lint_provenance_flags function runs deterministically (no LLM) after issue
# generation and:
#
#   1. Emits WARNING: for each UNVERIFIED provenance entry.
#   2. Fails the run (exit 1) when any provenance section has obvious-source
#      entries (source matches a file in "Files to Read") unless
#      RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1 is set.
#   3. Passes silently when provenance sections contain only external/derived fields.
#   4. Passes silently when no provenance section is present.
#
# Fixtures:
#   A — "load goals from goals.json" issue: NO provenance section → linter passes
#       silently with exit 0, zero WARNINGs.
#   B — "fetch transactions from SimpleFIN" issue: provenance section with only
#       SimpleFIN-sourced fields marked UNVERIFIED → linter emits one WARNING per
#       UNVERIFIED entry, exits 0 (UNVERIFIED is not a gate).
#   C — issue where every provenance entry source matches a file in "Files to Read":
#       linter emits WARNING and exits 1 unless RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1.
#
# Additional acceptance criteria:
#   D — _lint_provenance_flags makes zero provider_run calls (structural check).
#   E — prompt heredoc contains the "Output-field provenance flagging" instruction.

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract _lint_provenance_flags from plan-issues.sh using the same
# awk brace-depth technique used in plan-coverage-dedup.bats.
# No top-level plan-issues.sh code (network calls, prompts) runs.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  export RITE_LIB_DIR="${RITE_REPO_ROOT}/lib"

  # Stub print_* functions so output goes cleanly to stderr without terminal setup.
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }
  print_status()  { echo "STATUS: $*" >&2; }
  print_error()   { echo "ERROR: $*" >&2; }
  print_header()  { echo "HEADER: $*" >&2; }

  # Extract _lint_provenance_flags from plan-issues.sh.
  # The awk brace-depth tracker pulls each function body in full.
  eval "$(awk '
    /^_lint_provenance_flags\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

  # Reset env vars to defaults for each test
  unset RITE_PLAN_PROVENANCE_MAX_OBVIOUS
  unset RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Fixture A — load goals from goals.json
#
# Issue that reads from a local goals.json file and produces output fields
# sourced entirely from that file. No "**Field provenance:**" section is
# included (correct — all fields are obvious-source).
# Linter must: exit 0, emit zero WARNINGs.
# ---------------------------------------------------------------------------

@test "Fixture A: no provenance section — linter passes silently with exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-a.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Load savings goals from goals.json
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Read savings goals from the local goals.json config file and return them as a list.

**Claude Context**:
Files to Read:
- data/goals.json (goal definitions)

Files to Modify:
- src/goals.py

**Acceptance Criteria**:
- [ ] Goals loaded from goals.json: `python -m pytest tests/test_goals.py`

**Done Definition**: Done when goals load correctly and tests pass.

**Scope Boundary**:
- DO: read goals.json, return list
- DO NOT: fetch from external sources

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _lint_provenance_flags "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit zero WARNING lines
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNING lines, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture B — fetch transactions from SimpleFIN
#
# Issue that fetches transaction data from the SimpleFIN external API.
# Provenance section lists SimpleFIN-sourced fields as UNVERIFIED (no fixture).
# Linter must:
#   - emit one WARNING per UNVERIFIED entry (2 fields → 2 WARNINGs)
#   - exit 0 (UNVERIFIED is a signal, not a gate)
# ---------------------------------------------------------------------------

@test "Fixture B: UNVERIFIED provenance entries emit WARNINGs, exit 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-b.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Sync transactions from SimpleFIN API
LABELS: backend,priority-high
TIME: 2hr
BODY:
**Description**:
Fetch transaction history from the SimpleFIN financial data API and persist locally.

**Claude Context**:
Files to Read:
- src/sync/base.py (sync interface)
- docs/simplefin-api.md (API spec)

Files to Modify:
- src/sync/simplefin.py
- tests/sync/test_simplefin.py

**Field provenance:**
- `amount`: SimpleFIN API (`/transactions[].amount`) — UNVERIFIED (no fixture)
- `posted_date`: SimpleFIN API (`/transactions[].transacted_at`) — UNVERIFIED (no fixture)

**Acceptance Criteria**:
- [ ] Transactions fetched and stored: `python -m pytest tests/sync/test_simplefin.py`

**Done Definition**: Done when transactions sync and tests pass.

**Scope Boundary**:
- DO: fetch and store transactions
- DO NOT: implement budget calculations

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _lint_provenance_flags "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0 (UNVERIFIED is a warning, not a gate)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly 2 WARNING lines (one per UNVERIFIED field)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 2 ] || {
    echo "FAIL: expected 2 WARNING lines for 2 UNVERIFIED fields, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Each WARNING must mention UNVERIFIED
  local unverified_warning_count
  unverified_warning_count=$(grep -c "UNVERIFIED" "$stderr_out" || true)
  [ "$unverified_warning_count" -ge 2 ] || {
    echo "FAIL: expected at least 2 lines mentioning UNVERIFIED, got $unverified_warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNINGs must name the issue
  grep -q "Sync transactions from SimpleFIN API" "$stderr_out" || {
    echo "FAIL: WARNING does not mention the issue title" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture C — obvious-source provenance (low-signal table)
#
# Issue whose provenance section documents only fields sourced from local files
# already listed in "Files to Read". This is the cargo-cult case the issue
# was designed to eliminate.
#
# Linter must:
#   - emit WARNING about low-signal provenance
#   - exit 1 (gate — this is a reject)
#
# With RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1:
#   - must emit WARNING (still signals the problem)
#   - must exit 0 (allow override)
# ---------------------------------------------------------------------------

@test "Fixture C: obvious-source provenance emits WARNING and exits 1" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Load savings goals from goals.json
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Read savings goals from the local goals.json config file and return them as a list.

**Claude Context**:
Files to Read:
- data/goals.json (goal definitions)
- src/models.py (Goal model)

Files to Modify:
- src/goals.py

**Field provenance:**
- `name`: goals.json — obvious (local config file)
- `target_amount`: goals.json — obvious (local config file)

**Acceptance Criteria**:
- [ ] Goals loaded: `python -m pytest tests/test_goals.py`

**Done Definition**: Done when goals load correctly.

**Scope Boundary**:
- DO: read goals.json
- DO NOT: fetch external data

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_provenance_flags "$issues_file" 2>"$stderr_out" || exit_code=$?

  # Must exit 1 (low-signal provenance is a gate)
  [ "$exit_code" -eq 1 ] || {
    echo "FAIL: expected exit 1 for obvious-source provenance, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING about low-signal entries
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -ge 1 ] || {
    echo "FAIL: expected at least 1 WARNING for low-signal provenance, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNING must mention low-signal
  grep -qi "low-signal" "$stderr_out" || {
    echo "FAIL: WARNING does not mention 'low-signal'" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture C: obvious-source provenance with ALLOW_OBVIOUS=1 exits 0 but still warns" {
  local issues_file="$RITE_TEST_TMPDIR/issues-c-allow.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Load savings goals from goals.json
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Read savings goals from the local goals.json config file and return them as a list.

**Claude Context**:
Files to Read:
- data/goals.json (goal definitions)

Files to Modify:
- src/goals.py

**Field provenance:**
- `name`: goals.json — obvious (local config file)

**Acceptance Criteria**:
- [ ] Goals loaded: `python -m pytest tests/test_goals.py`

**Done Definition**: Done when goals load correctly.

**Scope Boundary**:
- DO: read goals.json
- DO NOT: fetch external data

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1 _lint_provenance_flags "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0 with the allow flag set
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0 with RITE_PLAN_PROVENANCE_ALLOW_OBVIOUS=1, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # But must still emit the WARNING (so engineers see it)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -ge 1 ] || {
    echo "FAIL: expected at least 1 WARNING even with ALLOW_OBVIOUS=1, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture D — mixed provenance: external fields (UNVERIFIED) only, no obvious ones
#
# Issue with provenance section containing only external-system fields.
# Linter must: emit WARNINGs for UNVERIFIED fields, exit 0 (not a gate).
# ---------------------------------------------------------------------------

@test "Fixture D: external-only provenance with UNVERIFIED exits 0 with WARNINGs" {
  local issues_file="$RITE_TEST_TMPDIR/issues-d.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Sync account balances from SimpleFIN
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Fetch current account balance data from SimpleFIN and store locally.

**Claude Context**:
Files to Read:
- src/sync/base.py (sync interface)

Files to Modify:
- src/sync/accounts.py

**Field provenance:**
- `balance`: SimpleFIN API (`/accounts[].balance`) — UNVERIFIED (no fixture)
- `currency`: SimpleFIN API (`/accounts[].currency`) — UNVERIFIED (no fixture)
- `running_balance`: derived — cumulative sum of transactions for account

**Acceptance Criteria**:
- [ ] Balances stored: `python -m pytest tests/sync/test_accounts.py`

**Done Definition**: Done when balances sync and tests pass.

**Scope Boundary**:
- DO: fetch and store account balances

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _lint_provenance_flags "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0 (only UNVERIFIED entries, no obvious-source ones)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly 2 WARNINGs (for the 2 UNVERIFIED fields; derived is not UNVERIFIED)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 2 ] || {
    echo "FAIL: expected 2 WARNING lines (2 UNVERIFIED fields), got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Acceptance criterion D: _lint_provenance_flags makes zero provider_run calls
# ---------------------------------------------------------------------------

@test "acceptance: _lint_provenance_flags contains no provider_run calls" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  local fn_body
  fn_body=$(awk '
    /^_lint_provenance_flags\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  local provider_call_count
  provider_call_count=$(echo "$fn_body" | grep -c "provider_run" || true)

  [ "$provider_call_count" -eq 0 ] || {
    echo "FAIL: _lint_provenance_flags contains $provider_call_count provider_run call(s)" >&2
    echo "$fn_body" | grep "provider_run" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance criterion E: generate_issues prompt contains provenance instruction
# ---------------------------------------------------------------------------

@test "acceptance: generate_issues prompt heredoc contains Output-field provenance flagging instruction" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  grep -q "Output-field provenance flagging" "$plan_issues_sh" || {
    echo "FAIL: 'Output-field provenance flagging' instruction not found in plan-issues.sh" >&2
    false
  }

  # Also verify the key concepts are present
  grep -q "UNVERIFIED" "$plan_issues_sh" || {
    echo "FAIL: 'UNVERIFIED' keyword not found in plan-issues.sh prompt" >&2
    false
  }

  grep -q "verified-available" "$plan_issues_sh" || {
    echo "FAIL: 'verified-available' keyword not found in plan-issues.sh prompt" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Acceptance: _lint_provenance_flags is called from generate_issues
# ---------------------------------------------------------------------------

@test "acceptance: _lint_provenance_flags is wired into generate_issues" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # Check that _lint_provenance_flags is called (not just defined)
  # Look for the call outside the function definition itself.
  # We do this by checking that the call appears in the generate_issues function body.
  local gen_fn_body
  gen_fn_body=$(awk '
    /^generate_issues\(\)/ { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="{") depth++
        if (c=="}") { depth--; if (depth==0) { print; in_fn=0; next } }
      }
      print; next
    }
  ' "$plan_issues_sh")

  echo "$gen_fn_body" | grep -q "_lint_provenance_flags" || {
    echo "FAIL: _lint_provenance_flags is not called within generate_issues()" >&2
    false
  }
}

# ---------------------------------------------------------------------------
# Fixture E — indented/nested **Field provenance:** (within Claude Context block)
#
# The runbook (docs/issue-runbook.md line 345) explicitly permits placing the
# provenance block "within the Claude Context block". This means the header
# line may be indented. The parser must detect and process it just like a
# column-0 header.
#
# Layout tested:
#   **Claude Context**:
#   Files to Read:
#   - docs/simplefin-api.md
#
#   **Field provenance:**            ← indented with leading spaces
#   - `amount`: SimpleFIN API — UNVERIFIED (no fixture)
#
# Linter must:
#   - detect the provenance section despite indentation
#   - emit one WARNING for the UNVERIFIED entry
#   - exit 0
# ---------------------------------------------------------------------------

@test "Fixture E: indented **Field provenance:** inside Claude Context is detected" {
  local issues_file="$RITE_TEST_TMPDIR/issues-e.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Sync exchange rates from forex API
LABELS: backend,priority-high
TIME: 1hr
BODY:
**Description**:
Fetch currency exchange rates from the forex API and persist locally.

**Claude Context**:
Files to Read:
- docs/forex-api.md (API spec)

Files to Modify:
- src/sync/forex.py

  **Field provenance:**
  - `rate`: Forex API (`/rates[].mid`) — UNVERIFIED (no fixture)
  - `currency_pair`: Forex API (`/rates[].pair`) — UNVERIFIED (no fixture)

**Acceptance Criteria**:
- [ ] Rates fetched: `python -m pytest tests/sync/test_forex.py`

**Done Definition**: Done when rates sync and tests pass.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _lint_provenance_flags "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0 (UNVERIFIED is a warning, not a gate)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly 2 WARNING lines (one per UNVERIFIED field)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 2 ] || {
    echo "FAIL: expected 2 WARNING lines for 2 UNVERIFIED fields in indented section, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Each WARNING must mention UNVERIFIED
  local unverified_warning_count
  unverified_warning_count=$(grep -c "UNVERIFIED" "$stderr_out" || true)
  [ "$unverified_warning_count" -ge 2 ] || {
    echo "FAIL: expected at least 2 lines mentioning UNVERIFIED, got $unverified_warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture E: indented **Field provenance:** with obvious-source entries exits 1" {
  local issues_file="$RITE_TEST_TMPDIR/issues-e-obvious.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Load goals from goals.json (nested provenance)
LABELS: backend,priority-medium
TIME: 30min
BODY:
**Description**:
Read savings goals from the local goals.json file.

**Claude Context**:
Files to Read:
- data/goals.json (goal definitions)

Files to Modify:
- src/goals.py

  **Field provenance:**
  - `name`: goals.json — obvious (local config file)

**Acceptance Criteria**:
- [ ] Goals loaded: `python -m pytest tests/test_goals.py`

**Done Definition**: Done when goals load correctly.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  local exit_code=0
  _lint_provenance_flags "$issues_file" 2>"$stderr_out" || exit_code=$?

  # Must exit 1 (obvious-source detected even though header was indented)
  [ "$exit_code" -eq 1 ] || {
    echo "FAIL: expected exit 1 for obvious-source in indented provenance section, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit a WARNING about low-signal entries
  grep -qi "low-signal" "$stderr_out" || {
    echo "FAIL: WARNING does not mention 'low-signal'" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Edge case: issue with no "Files to Read" section and provenance section
#
# When there are no Files to Read entries, no source can match a local file,
# so obvious-source detection is skipped. UNVERIFIED entries still warn.
# ---------------------------------------------------------------------------

@test "Edge: issue with provenance but no Files to Read — UNVERIFIED warns, exits 0" {
  local issues_file="$RITE_TEST_TMPDIR/issues-edge.txt"

  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Fetch exchange rates from external API
LABELS: backend,priority-low
TIME: 1hr
BODY:
**Description**:
Fetch currency exchange rates from a remote forex API.

**Claude Context**:
Files to Modify:
- src/forex.py

**Field provenance:**
- `rate`: Forex API (`/rates`) — UNVERIFIED (no fixture)

**Done Definition**: Done when rates are fetched and stored.

**Dependencies**: None
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _lint_provenance_flags "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0 (no obvious-source entries because no Files to Read to compare)
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must still warn about UNVERIFIED
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -ge 1 ] || {
    echo "FAIL: expected at least 1 WARNING for UNVERIFIED field, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}
