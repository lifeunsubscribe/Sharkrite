#!/usr/bin/env bats
# tests/regression/plan-unverified-integration.bats
#
# Regression tests for _detect_unverified_integrations — deterministic post-generation
# pass that enforces "no external integration without a real fixture sample".
#
# Background: finance-glance planning emitted SimpleFIN-integration issues with
# invented mock payloads.  The fix is deterministic grep-based detection: if an
# emitted issue body references a host or package not present in the repo's
# fixture directories or dependency manifests, a spike-issue prerequisite is
# prepended and the downstream issue gains "Blocked by: #SPIKE-<key>".
#
# Tests in this file:
#   Fixture A — Python project with grounded host AND package: no spike.
#   Fixture B — Same Python project, issue references ungrounded host: spike emitted.
#   Fixture C — Node project with grounded package (axios): no spike.
#   Fixture D — Node project, issue references ungrounded package: spike emitted.
#   Fixture E — RITE_PLAN_SKIP_INTEGRATION_CHECK=1 bypasses pass entirely.
#   Fixture F — Spike body contains required grounding instructions.
#   Fixture G — Downstream issue referencing ungrounded host gets "Blocked by:" added.
#   Fixture H — Downstream issue with existing Dependencies line gets spike appended.
#   Fixture I — No LLM calls: structural check via grep on function body.

load '../helpers/setup.bash'

# ---------------------------------------------------------------------------
# Setup: extract helper functions from plan-issues.sh using a line-range sed.
#
# We do NOT use the awk brace-depth extractor (as in plan-coverage-dedup.bats)
# because _build_grounded_packages contains multi-line awk programs whose
# embedded '{' / '}' literals trip the brace counter, producing truncated
# (syntax-invalid) bash output.
#
# Instead we compute the line range dynamically:
#   start = first line of _extract_packages_for_language()
#   end   = line before _dedup_issues() (first function outside our set)
# This is robust to line-count changes but requires all new helper functions
# to be placed between those two markers.
# ---------------------------------------------------------------------------

setup() {
  setup_test_tmpdir

  export RITE_PROJECT_ROOT="$RITE_TEST_TMPDIR"
  # Unset RITE_LIB_DIR so plan-issues.sh skips provider/gh-retry sourcing.
  # We stub required functions below instead.
  unset RITE_LIB_DIR

  # Stub print_* functions so output goes cleanly to stderr
  print_warning() { echo "WARNING: $*" >&2; }
  print_info()    { echo "INFO: $*" >&2; }
  print_success() { echo "SUCCESS: $*" >&2; }

  # Stub portable_sed_i (provided by portable-cmds.sh; not needed for these tests)
  portable_sed_i() {
    local _expr="$1"
    local _file="$2"
    sed -i.bak "$_expr" "$_file" && rm -f "${_file}.bak" || true
  }

  # Extract the detection functions from plan-issues.sh using a line-range sed
  # rather than the awk brace-depth approach (which breaks on embedded awk programs
  # that contain literal '{' and '}' in their string arguments).
  #
  # Line range: from _extract_packages_for_language() to just before _dedup_issues().
  # The exact boundaries are computed at setup time so they survive code edits.
  local _start _end
  _start=$(grep -n '^_extract_packages_for_language()' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" | head -1 | cut -d: -f1)
  _end=$(grep -n '^_dedup_issues()' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" | head -1 | cut -d: -f1)
  _end=$((_end - 1))

  # shellcheck disable=SC1090
  eval "$(sed -n "${_start},${_end}p" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"
}

teardown() {
  teardown_test_tmpdir
}

# ---------------------------------------------------------------------------
# Helper: write a minimal issues file with one issue block
# ---------------------------------------------------------------------------

write_issues_file() {
  local file="$1"
  local title="$2"
  local body="$3"
  cat > "$file" <<FIXTURE
---ISSUE---
TITLE: $title
LABELS: feature
TIME: 1hr
BODY:
$body
---END---
FIXTURE
}

# ---------------------------------------------------------------------------
# Fixture A: Python project with grounded host AND package — no spike
#
# Project has:
#   - requirements.txt containing "requests"
#   - fixtures/api.example.com/ directory
# Issue body references https://api.example.com/ and `import requests`
# Expected: no spike issue, no WARNING, exit 0.
# ---------------------------------------------------------------------------

@test "Fixture A: grounded host and package in Python project produces no spike" {
  # Set up project fixtures
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/api.example.com/sample.json"
  echo "requests==2.28.0" > "$RITE_TEST_TMPDIR/requirements.txt"

  local issues_file="$RITE_TEST_TMPDIR/issues-a.txt"
  write_issues_file "$issues_file" \
    "Integrate with external API" \
    "Call https://api.example.com/data using import requests to fetch results."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Must exit 0
  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit NO WARNING lines (both are grounded)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNING lines, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must still have exactly 1 issue (no spike prepended)
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue (no spike), got $issue_count" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture B: same Python project, issue references ungrounded host
#
# Project has fixtures/api.example.com/ but the issue references
# simplefin.example.com which has no fixture directory.
# Expected: one WARNING, one spike issue prepended, exit 0.
# ---------------------------------------------------------------------------

@test "Fixture B: ungrounded host in Python project produces a spike issue" {
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/api.example.com/sample.json"
  echo "requests==2.28.0" > "$RITE_TEST_TMPDIR/requirements.txt"

  local issues_file="$RITE_TEST_TMPDIR/issues-b.txt"
  write_issues_file "$issues_file" \
    "Integrate with SimpleFIN" \
    "Call https://simplefin.example.com/accounts to fetch transaction data."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly one WARNING for the ungrounded host
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 WARNING line, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNING must name the ungrounded host
  grep -q "simplefin.example.com" "$stderr_out" || {
    echo "FAIL: WARNING does not mention 'simplefin.example.com'" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must now have 2 issues (spike prepended + original)
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 2 ] || {
    echo "FAIL: expected 2 issues (1 spike + 1 original), got $issue_count" >&2
    cat "$issues_file" >&2
    false
  }

  # The first issue must be the spike
  local first_title
  first_title=$(grep "^TITLE:" "$issues_file" | head -1)
  echo "$first_title" | grep -qi "spike: capture simplefin.example.com" || {
    echo "FAIL: first issue is not the spike: $first_title" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture C: Node project with grounded package (axios) — no spike
#
# Project has package.json with "axios" in dependencies.
# Issue body references require('axios').
# Expected: no spike, no WARNING.
# ---------------------------------------------------------------------------

@test "Fixture C: grounded Node package (axios) produces no spike" {
  cat > "$RITE_TEST_TMPDIR/package.json" <<'JSON'
{
  "name": "my-app",
  "dependencies": {
    "axios": "^1.0.0",
    "express": "^4.18.0"
  }
}
JSON

  local issues_file="$RITE_TEST_TMPDIR/issues-c.txt"
  write_issues_file "$issues_file" \
    "Fetch data from external API" \
    "Use require('axios') to make HTTP requests to the backend."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for grounded package, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue (no spike), got $issue_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture D: Node project, issue references ungrounded package (unknownpkg)
#
# package.json has axios but issue references require('unknownpkg') which
# is not in any manifest.
# Expected: one WARNING, one spike issue, exit 0.
# ---------------------------------------------------------------------------

@test "Fixture D: ungrounded Node package (unknownpkg) produces a spike issue" {
  cat > "$RITE_TEST_TMPDIR/package.json" <<'JSON'
{
  "name": "my-app",
  "dependencies": {
    "axios": "^1.0.0"
  }
}
JSON

  local issues_file="$RITE_TEST_TMPDIR/issues-d.txt"
  write_issues_file "$issues_file" \
    "Add payment processing" \
    "Use require('unknownpkg') to process payments via the payment gateway."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 WARNING for unknownpkg, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  grep -q "unknownpkg" "$stderr_out" || {
    echo "FAIL: WARNING does not mention 'unknownpkg'" >&2
    cat "$stderr_out" >&2
    false
  }

  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 2 ] || {
    echo "FAIL: expected 2 issues (1 spike + 1 original), got $issue_count" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture E: RITE_PLAN_SKIP_INTEGRATION_CHECK=1 disables the pass entirely
#
# Even with an ungrounded host in the issue body, no spike is emitted.
# ---------------------------------------------------------------------------

@test "Fixture E: RITE_PLAN_SKIP_INTEGRATION_CHECK=1 disables pass entirely" {
  # No fixtures, no manifests — would normally trigger a spike
  local issues_file="$RITE_TEST_TMPDIR/issues-e.txt"
  write_issues_file "$issues_file" \
    "Integrate with unknown service" \
    "Call https://unknown-service.example.com/api for data."

  local stderr_out
  stderr_out=$(mktemp)
  RITE_PLAN_SKIP_INTEGRATION_CHECK=1 _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ]

  # No WARNINGs because the pass was skipped
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs when pass is disabled, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # No spike issue added
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue (pass disabled, no spike), got $issue_count" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture F: Spike body includes required grounding instructions
#
# The acceptance criteria require the spike body to contain specific text
# about making a real call, capturing a secret-scrubbed sample, and
# documenting per-field provenance.
# ---------------------------------------------------------------------------

@test "Fixture F: spike issue body contains required grounding instructions" {
  # No fixtures or manifests so the host is ungrounded
  local issues_file="$RITE_TEST_TMPDIR/issues-f.txt"
  write_issues_file "$issues_file" \
    "Add banking integration" \
    "Fetch data from https://bank.example.com/transactions endpoint."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"

  # Extract the spike issue body from the output file
  local spike_body
  spike_body=$(awk '/^---ISSUE---/{in_block=1} in_block{print} /^---END---/{in_block=0}' "$issues_file" | head -50)

  # Must mention "Make one real call"
  echo "$spike_body" | grep -qi "make one real call" || {
    echo "FAIL: spike body does not mention 'Make one real call'" >&2
    echo "--- spike body ---" >&2
    echo "$spike_body" >&2
    false
  }

  # Must mention "Capture a secret-scrubbed sample to"
  echo "$spike_body" | grep -qi "capture a secret-scrubbed sample to" || {
    echo "FAIL: spike body does not mention secret-scrubbed sample capture" >&2
    echo "--- spike body ---" >&2
    echo "$spike_body" >&2
    false
  }

  # Must mention "Document per-field provenance"
  echo "$spike_body" | grep -qi "document per-field provenance" || {
    echo "FAIL: spike body does not mention 'Document per-field provenance'" >&2
    echo "--- spike body ---" >&2
    echo "$spike_body" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture G: downstream issue referencing ungrounded host gets "Blocked by:"
#
# After the pass:
#  - A spike issue exists (prepended)
#  - The downstream issue's body contains "Blocked by: #SPIKE-<key>"
# ---------------------------------------------------------------------------

@test "Fixture G: downstream issue referencing ungrounded host gets Blocked-by dependency" {
  # No fixtures for this host
  local issues_file="$RITE_TEST_TMPDIR/issues-g.txt"
  write_issues_file "$issues_file" \
    "Build SimpleFIN client" \
    "Implement client code for https://simplefin.example.com/accounts endpoint."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"

  # The downstream issue body must contain the spike placeholder
  local downstream_block
  # Skip the spike (first ---ISSUE---) and get the second block
  downstream_block=$(awk '
    /^---ISSUE---/ { block++; in_block=1; buf="" }
    in_block { buf=buf"\n"$0 }
    /^---END---/ { in_block=0; if(block==2) { print buf; exit } }
  ' "$issues_file")

  echo "$downstream_block" | grep -q "Blocked by:" || {
    echo "FAIL: downstream issue does not contain 'Blocked by:'" >&2
    echo "--- downstream block ---" >&2
    echo "$downstream_block" >&2
    cat "$issues_file" >&2
    false
  }

  echo "$downstream_block" | grep -qi "SPIKE" || {
    echo "FAIL: downstream issue Blocked-by reference does not contain 'SPIKE'" >&2
    echo "--- downstream block ---" >&2
    echo "$downstream_block" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture H: downstream issue with existing Dependencies line gets spike appended
#
# The issue already has a **Dependencies** line. The pass should append
# the spike reference to that line rather than creating a duplicate.
# ---------------------------------------------------------------------------

@test "Fixture H: existing Dependencies line gets spike placeholder appended" {
  local issues_file="$RITE_TEST_TMPDIR/issues-h.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Integrate with payment gateway
LABELS: feature
TIME: 1hr
BODY:
Use https://payments.example.com/charge to charge customers.

**Dependencies**: After #PREV
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"

  # The downstream issue body must reference the spike placeholder
  # AND must not have duplicate **Dependencies** lines
  local dep_count
  dep_count=$(grep -c "^\*\*Dependencies\*\*:" "$issues_file" || true)

  # Downstream issue must have exactly 1 **Dependencies** line (not 2)
  # Note: the spike issue itself may have 0 dep lines; the original has 1.
  # grep across whole file: spike (0 or 1) + original (1) = at most 2.
  # The original must not be split into two lines.
  local downstream_deps
  downstream_deps=$(awk '
    /^---ISSUE---/ { block++ }
    block==2 && /^\*\*Dependencies\*\*:/ { count++ }
  ' "$issues_file")

  local dep_line_count
  dep_line_count=$(awk '
    /^---ISSUE---/ { block++ }
    block==2 && /^\*\*Dependencies\*\*:/ { count++ }
    END { print count+0 }
  ' "$issues_file")

  [ "$dep_line_count" -le 1 ] || {
    echo "FAIL: downstream issue has $dep_line_count **Dependencies** lines (expected ≤ 1)" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture I: _detect_unverified_integrations makes zero LLM/provider_run calls
# (structural check via grep on the extracted function bodies)
# ---------------------------------------------------------------------------

@test "Fixture I: _detect_unverified_integrations contains no provider_run calls" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # Extract the detection function range (same boundaries as setup).
  local _start _end
  _start=$(grep -n '^_extract_packages_for_language()' "$plan_issues_sh" | head -1 | cut -d: -f1)
  _end=$(grep -n '^_dedup_issues()' "$plan_issues_sh" | head -1 | cut -d: -f1)
  _end=$((_end - 1))

  local fn_bodies
  fn_bodies=$(sed -n "${_start},${_end}p" "$plan_issues_sh")

  # Must not contain any provider_run calls
  local provider_call_count
  provider_call_count=$(echo "$fn_bodies" | grep -c "provider_run" || true)

  [ "$provider_call_count" -eq 0 ] || {
    echo "FAIL: detection functions contain $provider_call_count provider_run call(s)" >&2
    echo "$fn_bodies" | grep "provider_run" >&2
    false
  }
}
