#!/usr/bin/env bats
# tests/regression/plan-unverified-integration.bats
# sharkrite-test-covers: lib/core/plan-issues.sh
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
#   Fixture Q — Dotless intermediate dir (e.g. "region") does NOT ground as hostname.
#   Fixture R — Dotted non-hostname dirs (e.g. "v1.2", "2024.01") do NOT ground as hostname.
#   Fixture S — Real hostname (api.example.com) nested under dotted version dir IS grounded.
#   Fixture X — Registrable-domain fixture (fixtures/foo.co/) grounds subdomain reference (api.foo.co).
#   Fixture Y — Both subdomains normalize to grounded registrable domain — no spike, no Blocked-by.
#   Fixture Z — Prefix-collision anchor: fixtures/api.foo.com/ grounded + ungrounded api.foo.co must NOT
#               inject Blocked-by into the foo.com issue (right-anchor regression guard).

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
  print_header()  { echo "=== $* ===" >&2; }

  # Color vars — empty so display_issues output is plain text in tests
  CYAN="" NC="" BLUE="" DIM=""

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

  # Also load _title_is_spike (used by display_issues for spike classification)
  local _ts_start _ts_end
  _ts_start=$(grep -n '^_title_is_spike()' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" | head -1 | cut -d: -f1)
  _ts_end=$(awk -v s="$_ts_start" 'NR > s && /^}$/{print NR; exit}' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")
  # shellcheck disable=SC1090
  eval "$(sed -n "${_ts_start},${_ts_end}p" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

  # Also load display_issues (preview display with spike-aware numbering)
  local _di_start _di_end
  _di_start=$(grep -n '^display_issues()' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh" | head -1 | cut -d: -f1)
  _di_end=$(awk -v s="$_di_start" 'NR > s && /^}$/{print NR; exit}' \
    "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")
  # shellcheck disable=SC1090
  eval "$(sed -n "${_di_start},${_di_end}p" "${RITE_REPO_ROOT}/lib/core/plan-issues.sh")"

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

  # Use a 2-label domain (simplefin.io) so normalization is identity — this
  # keeps the test focused on the basic "ungrounded host → spike" path.
  local issues_file="$RITE_TEST_TMPDIR/issues-b.txt"
  write_issues_file "$issues_file" \
    "Integrate with SimpleFIN" \
    "Call https://simplefin.io/accounts to fetch transaction data."

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
  grep -q "simplefin.io" "$stderr_out" || {
    echo "FAIL: WARNING does not mention 'simplefin.io'" >&2
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
  echo "$first_title" | grep -qi "spike: capture simplefin.io" || {
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
  # No fixtures or manifests so the host is ungrounded.
  # Use a 2-label domain so normalization is identity.
  local issues_file="$RITE_TEST_TMPDIR/issues-f.txt"
  write_issues_file "$issues_file" \
    "Add banking integration" \
    "Fetch data from https://bank-api.io/transactions endpoint."

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
  # No fixtures for this host. Use a 2-label domain so normalization is identity.
  local issues_file="$RITE_TEST_TMPDIR/issues-g.txt"
  write_issues_file "$issues_file" \
    "Build SimpleFIN client" \
    "Implement client code for https://simplefin.io/accounts endpoint."

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
  # Use a 2-label domain so normalization is identity.
  local issues_file="$RITE_TEST_TMPDIR/issues-h.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Integrate with payment gateway
LABELS: feature
TIME: 1hr
BODY:
Use https://payments-api.io/charge to charge customers.

**Dependencies**: After #PREV
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"

  # The downstream issue (block 2 after spike is prepended) must have exactly
  # 1 **Dependencies** line (no duplicate) AND it must contain the spike placeholder.

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

  # Assert the downstream Dependencies line actually contains the spike placeholder.
  # This is the acceptance criterion: the pass must rewrite the line with #SPIKE-<key>.
  local downstream_dep_line
  downstream_dep_line=$(awk '
    /^---ISSUE---/ { block++ }
    block==2 && /^\*\*Dependencies\*\*:/ { print; exit }
  ' "$issues_file")

  echo "$downstream_dep_line" | grep -q "#SPIKE-" || {
    echo "FAIL: downstream **Dependencies** line does not contain a #SPIKE- placeholder" >&2
    echo "  Dependencies line: $downstream_dep_line" >&2
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

# ---------------------------------------------------------------------------
# Fixture J: Python import name differs from distribution name (yaml / PyYAML)
#
# Issue body uses `import yaml` but the manifest has "PyYAML".
# _normalize_python_import_name maps yaml → pyyaml, which then matches the
# lowercased manifest entry "pyyaml".  No spike should be emitted.
# ---------------------------------------------------------------------------

@test "Fixture J: 'import yaml' with PyYAML in requirements.txt produces no spike" {
  echo "PyYAML==6.0" > "$RITE_TEST_TMPDIR/requirements.txt"

  local issues_file="$RITE_TEST_TMPDIR/issues-j.txt"
  write_issues_file "$issues_file" \
    "Parse YAML configuration" \
    "Use import yaml to load the configuration file and parse its contents."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit NO WARNING (yaml is grounded via PyYAML alias)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for 'import yaml' + PyYAML in manifest, got $warning_count" >&2
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
# Fixture K: Python import name differs from distribution name (bs4 / beautifulsoup4)
#
# Issue body uses `from bs4 import BeautifulSoup` but the manifest has
# "beautifulsoup4".  _normalize_python_import_name maps bs4 → beautifulsoup4.
# No spike should be emitted.
# ---------------------------------------------------------------------------

@test "Fixture K: 'from bs4 import ...' with beautifulsoup4 in requirements.txt produces no spike" {
  echo "beautifulsoup4==4.12.0" > "$RITE_TEST_TMPDIR/requirements.txt"

  local issues_file="$RITE_TEST_TMPDIR/issues-k.txt"
  write_issues_file "$issues_file" \
    "Scrape HTML pages" \
    "Use from bs4 import BeautifulSoup to parse the HTML response."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for 'from bs4' + beautifulsoup4 in manifest, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

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
# Fixture L: Node deep import subpath is trimmed (lodash/fp → lodash)
#
# Issue body uses require('lodash/fp') but package.json has bare "lodash".
# _trim_node_package_name strips "/fp" so the lookup matches "lodash".
# No spike should be emitted.
# ---------------------------------------------------------------------------

@test "Fixture L: require('lodash/fp') with lodash in package.json produces no spike" {
  cat > "$RITE_TEST_TMPDIR/package.json" <<'JSON'
{
  "name": "my-app",
  "dependencies": {
    "lodash": "^4.17.21"
  }
}
JSON

  local issues_file="$RITE_TEST_TMPDIR/issues-l.txt"
  write_issues_file "$issues_file" \
    "Use lodash functional utilities" \
    "Use require('lodash/fp') to access the functional programming helpers."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for require('lodash/fp') + lodash in manifest, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

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
# Fixture M: Scoped Node package with sub-path is trimmed (@scope/pkg/sub → @scope/pkg)
#
# Issue body uses require('@myorg/utils/helpers') but package.json has
# "@myorg/utils".  _trim_node_package_name strips "/helpers" leaving
# "@myorg/utils" which matches the manifest entry.  No spike should be emitted.
# ---------------------------------------------------------------------------

@test "Fixture M: require('@myorg/utils/helpers') with @myorg/utils in package.json produces no spike" {
  cat > "$RITE_TEST_TMPDIR/package.json" <<'JSON'
{
  "name": "my-app",
  "dependencies": {
    "@myorg/utils": "^1.0.0"
  }
}
JSON

  local issues_file="$RITE_TEST_TMPDIR/issues-m.txt"
  write_issues_file "$issues_file" \
    "Use internal utilities" \
    "Use require('@myorg/utils/helpers') to access the shared helper functions."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for '@myorg/utils/helpers' + @myorg/utils in manifest, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

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
# Fixture N: host grounded in a nested subdirectory — no spike
#
# Regression for the single-level walk bug: when RITE_PLAN_FIXTURE_GLOB was
# set (or even with the default fixtures/ directory), hosts nested more than
# one level deep were not discovered, producing false-positive spike issues.
#
# Project has:
#   fixtures/region/api.example.com/   (two levels deep under fixtures/)
# Issue body references https://api.example.com/
# Expected: recursive walk finds the host; no spike issued, exit 0.
# ---------------------------------------------------------------------------

@test "Fixture N: host nested two levels deep under fixtures/ is grounded (recursive walk)" {
  # Nest the fixture two levels: fixtures/region/api.example.com/
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/region/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/region/api.example.com/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-n.txt"
  write_issues_file "$issues_file" \
    "Integrate with external API" \
    "Call https://api.example.com/data to fetch results."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Recursive walk must have grounded the host — no WARNING should be emitted
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for host grounded at fixtures/region/api.example.com/, got $warning_count" >&2
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
# Fixture O: host nested under RITE_PLAN_FIXTURE_GLOB custom path — no spike
#
# Regression for the single-level walk bug with a custom RITE_PLAN_FIXTURE_GLOB.
# The config example advertised "test/vcr_cassettes/**" as supported; this test
# verifies that a host nested under that path is actually grounded.
#
# Project has:
#   test/vcr_cassettes/prod/api.example.com/   (nested under custom path)
# RITE_PLAN_FIXTURE_GLOB="test/vcr_cassettes/**"
# Issue body references https://api.example.com/
# Expected: recursive walk into the custom path grounds the host; no spike.
# ---------------------------------------------------------------------------

@test "Fixture O: host nested under RITE_PLAN_FIXTURE_GLOB custom path is grounded (recursive walk)" {
  mkdir -p "$RITE_TEST_TMPDIR/test/vcr_cassettes/prod/api.example.com"
  echo '{"status": "ok"}' > "$RITE_TEST_TMPDIR/test/vcr_cassettes/prod/api.example.com/response.json"

  export RITE_PLAN_FIXTURE_GLOB="test/vcr_cassettes/**"

  local issues_file="$RITE_TEST_TMPDIR/issues-o.txt"
  write_issues_file "$issues_file" \
    "Integrate with external API" \
    "Call https://api.example.com/data to fetch results."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  # Restore env
  unset RITE_PLAN_FIXTURE_GLOB

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs for host nested under RITE_PLAN_FIXTURE_GLOB custom path, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

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
# Fixture P: _strptime is NOT an explicit entry in _normalize_python_import_name
#
# Regression for the dead/redundant table entry removed in issue #429.
# _strptime is a Python stdlib internal (used by datetime.strptime internally).
# It must NOT have a dedicated case that echoes "_strptime" unchanged — that
# entry was identical to the default *) case and is dead code.
#
# This is a structural check: verify the normalization table contains no
# explicit "_strptime)" entry.  The default *) case already handles it.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Fixture Q: intermediate (non-hostname) directory names do NOT become grounded hosts
#
# Regression for the false-hostname bug: when the recursive directory walk
# encounters intermediate organizational directories like "region" or "prod"
# (which do not contain a dot), those names must NOT be added to the grounded-
# host set.  If they were, any issue that happened to reference e.g.
# https://region/... would be silently accepted as grounded (no spike issued),
# producing a false negative.
#
# Project has:
#   fixtures/region/api.example.com/   (two levels; "region" has no dot)
# Issue body references https://region/data  (single-label, no dot)
# Expected: "region" is NOT in the grounded set, so a spike IS emitted.
# ---------------------------------------------------------------------------

@test "Fixture Q: intermediate directory without dot does not ground a false hostname" {
  # Nest the fixture: fixtures/region/api.example.com/
  # "region" is the intermediate dir (no dot) — must NOT be grounded.
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/region/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/region/api.example.com/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-q.txt"
  write_issues_file "$issues_file" \
    "Fetch data from internal region endpoint" \
    "Call https://region/data to fetch results from the internal network."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # "region" has no dot — it must NOT be grounded, so a spike must be emitted.
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 2 ] || {
    echo "FAIL: expected 2 issues (1 spike + 1 original) because 'region' is not a valid hostname;" \
         "got $issue_count (intermediate dir was incorrectly grounded)" >&2
    cat "$issues_file" >&2
    false
  }

  # WARNING must name "region" as ungrounded
  grep -q "region" "$stderr_out" || {
    echo "FAIL: expected a WARNING mentioning 'region' as an ungrounded host" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture R: dotted non-hostname intermediate dirs do NOT become grounded hosts
#
# Regression for the residual gap left by Fixture Q's fix: the original
# dot-heuristic filtered out dotless dirs (e.g. "region") but still allowed
# any dotted name — including version strings and date segments like "v1.2"
# or "2024.01" — to enter the grounded-host set.
#
# Project has:
#   fixtures/v1.2/api.example.com/     ("v1.2" is a versioned intermediate dir)
#   fixtures/2024.01/api.example.com/  ("2024.01" is a date-versioned intermediate dir)
# Issue body references:
#   https://v1.2/resource   — version string, NOT a hostname
#   https://2024.01/events  — date string, NOT a hostname
# Expected: "v1.2" and "2024.01" are NOT in the grounded set (digit-only
# final label fails the hostname-shaped regex), so spikes ARE emitted.
# ---------------------------------------------------------------------------

@test "Fixture R: dotted version-string intermediate dirs do not ground as hostnames" {
  # Nest fixtures under versioned intermediate dirs — these contain dots but
  # are NOT valid hostnames (digit-only final labels).
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/v1.2/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/v1.2/api.example.com/sample.json"
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/2024.01/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/2024.01/api.example.com/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-r.txt"
  write_issues_file "$issues_file" \
    "Fetch versioned resource" \
    "Call https://v1.2/resource and https://2024.01/events to load data."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Both "v1.2" and "2024.01" have digit-only final labels — they must NOT be
  # grounded, so a spike must be emitted for each.
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 3 ] || {
    echo "FAIL: expected 3 issues (2 spikes + 1 original) because 'v1.2' and '2024.01'" \
         "are not valid hostnames; got $issue_count" \
         "(dotted non-hostname dirs were incorrectly grounded)" >&2
    cat "$issues_file" >&2
    false
  }

  # WARNING must name both ungrounded candidates
  grep -q "v1\.2" "$stderr_out" || {
    echo "FAIL: expected a WARNING mentioning 'v1.2' as an ungrounded host" >&2
    cat "$stderr_out" >&2
    false
  }
  grep -q "2024\.01" "$stderr_out" || {
    echo "FAIL: expected a WARNING mentioning '2024.01' as an ungrounded host" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture S: api.example.com is still grounded even when nested under a
# dotted non-hostname intermediate dir (v1.2/)
#
# Ensures the hostname-shaped regex fix doesn't regress the legitimate
# nested-grounding behaviour: the real hostname api.example.com (nested under
# the version dir v1.2/) must still be found and grounded.
# ---------------------------------------------------------------------------

@test "Fixture S: real hostname nested under dotted version dir is still grounded" {
  # fixtures/v1.2/api.example.com/ — "v1.2" is non-hostname but api.example.com is real.
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/v1.2/api.example.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/v1.2/api.example.com/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-s.txt"
  write_issues_file "$issues_file" \
    "Fetch data from API" \
    "Call https://api.example.com/v1.2/resource to get data."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # api.example.com IS a valid hostname and IS grounded — no spike should fire.
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 1 ] || {
    echo "FAIL: expected 1 issue (no spike) because api.example.com is grounded;" \
         "got $issue_count (real hostname nested under version dir was not found)" >&2
    cat "$issues_file" >&2
    cat "$stderr_out" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# display_issues preview numbering — spike-aware labels (acceptance criteria
# for issue #1151: "Show resolved dependency refs in plan preview")
# ---------------------------------------------------------------------------

# Helper: write a two-issue spike-injected issues file
_write_spike_issues_file() {
  local file="$1"
  cat > "$file" <<'FIXTURE'
---ISSUE---
TITLE: spike: capture api.example.com sample for grounding
LABELS: spike
TIME: 30min
**Description**: Capture sample fixture.
**Done Definition**: Fixture captured.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Integrate with external API
LABELS: feature,phase-1,priority-medium
TIME: 1hr
**Description**: Call the external API.
**Done Definition**: Integration works.
**Dependencies**: After #1
---END---
---ISSUE---
TITLE: Write integration tests
LABELS: feature,phase-1,priority-medium
TIME: 45min
**Description**: Write tests.
**Done Definition**: Tests pass.
**Dependencies**: After #1
---END---
FIXTURE
}

@test "display_issues: spike-injected preview labels spikes distinctly and numbers impl issues by non-spike ordinal" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spike-preview.txt"
  _write_spike_issues_file "$issues_file"

  local stdout_out stderr_out
  stdout_out=$(mktemp)
  stderr_out=$(mktemp)
  display_issues "$issues_file" >"$stdout_out" 2>"$stderr_out"
  local all_out
  all_out=$(cat "$stdout_out" "$stderr_out")

  # Spike issue must be labeled [spike 1/1], not [1/3]
  echo "$all_out" | grep -qF "[spike 1/1]" || {
    echo "FAIL: expected [spike 1/1] label for spike issue" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  # First implementation issue must be labeled [1/2] (non-spike ordinal denominator = 2)
  echo "$all_out" | grep -qF "[1/2]" || {
    echo "FAIL: expected [1/2] label for first implementation issue" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  # Second implementation issue must be labeled [2/2]
  echo "$all_out" | grep -qF "[2/2]" || {
    echo "FAIL: expected [2/2] label for second implementation issue" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  # Raw position label [1/3] must NOT appear (spikes removed from impl counter)
  echo "$all_out" | grep -qF "[1/3]" && {
    echo "FAIL: found raw position label [1/3] — spikes must not consume impl ordinal slots" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  } || true

  rm -f "$stdout_out" "$stderr_out"
}

@test "display_issues: spike-injected preview footer has note line about #N refs" {
  local issues_file="$RITE_TEST_TMPDIR/issues-spike-note.txt"
  _write_spike_issues_file "$issues_file"

  local stdout_out stderr_out
  stdout_out=$(mktemp)
  stderr_out=$(mktemp)
  display_issues "$issues_file" >"$stdout_out" 2>"$stderr_out"
  local all_out
  all_out=$(cat "$stdout_out" "$stderr_out")

  # Footer must contain the note about #N refs
  echo "$all_out" | grep -q "implementation issues only" || {
    echo "FAIL: expected note about '#N refs count implementation issues only'" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  echo "$all_out" | grep -q "rewritten to real issue numbers at creation" || {
    echo "FAIL: expected note about refs being rewritten at creation" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  rm -f "$stdout_out" "$stderr_out"
}

@test "display_issues: spike-free preview renders exactly as today (no note, same numbering)" {
  local issues_file="$RITE_TEST_TMPDIR/issues-no-spike.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Implement feature A
LABELS: feature,phase-1,priority-medium
TIME: 1hr
**Description**: Feature A.
**Done Definition**: Works.
**Dependencies**: None
---END---
---ISSUE---
TITLE: Implement feature B
LABELS: feature,phase-1,priority-medium
TIME: 45min
**Description**: Feature B.
**Done Definition**: Works.
**Dependencies**: After #1
---END---
FIXTURE

  local stdout_out stderr_out
  stdout_out=$(mktemp)
  stderr_out=$(mktemp)
  display_issues "$issues_file" >"$stdout_out" 2>"$stderr_out"
  local all_out
  all_out=$(cat "$stdout_out" "$stderr_out")

  # Issue 1: labeled [1/2] (same as today's [N/M] format)
  echo "$all_out" | grep -qF "[1/2]" || {
    echo "FAIL: expected [1/2] label for first issue in spike-free batch" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  # Issue 2: labeled [2/2]
  echo "$all_out" | grep -qF "[2/2]" || {
    echo "FAIL: expected [2/2] label for second issue in spike-free batch" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  }

  # No note line (spike-free batches must not print the note)
  echo "$all_out" | grep -q "implementation issues only" && {
    echo "FAIL: spike-free preview must not print the #N note line" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  } || true

  # No [spike …] labels
  echo "$all_out" | grep -qF "[spike" && {
    echo "FAIL: spike-free preview must not contain [spike ...] labels" >&2
    echo "--- display output ---" >&2
    echo "$all_out" >&2
    false
  } || true

  rm -f "$stdout_out" "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture T: two subdomains of one service produce exactly ONE spike
#
# Two issues reference different subdomains of the same registrable domain
# (api.authsvc.io and admin.authsvc.io → both normalize to authsvc.io).
# Expected: 3 issues total (1 spike for authsvc.io + 2 originals).
# The spike title and fixture path use the normalized domain.
# ---------------------------------------------------------------------------

@test "Fixture T: two subdomains of same service produce exactly one spike" {
  # No fixtures for authsvc.io subdomains
  local issues_file="$RITE_TEST_TMPDIR/issues-t.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Implement authentication
LABELS: feature
TIME: 1hr
BODY:
Call https://api.authsvc.io/token to obtain an access token.
---END---
---ISSUE---
TITLE: Implement admin panel
LABELS: feature
TIME: 1hr
BODY:
Call https://admin.authsvc.io/users to list users.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit exactly ONE WARNING (both subdomains collapse to one candidate)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 1 ] || {
    echo "FAIL: expected 1 WARNING (both subdomains → authsvc.io), got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNING must name the normalized registrable domain
  grep -q "authsvc.io" "$stderr_out" || {
    echo "FAIL: WARNING does not mention normalized domain 'authsvc.io'" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must have exactly 3 issues (1 spike + 2 originals — not 4)
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 3 ] || {
    echo "FAIL: expected 3 issues (1 spike + 2 originals), got $issue_count — subdomain dedup failed" >&2
    cat "$issues_file" >&2
    false
  }

  # Spike title must use the normalized domain (authsvc.io), not a subdomain
  local first_title
  first_title=$(grep "^TITLE:" "$issues_file" | head -1)
  echo "$first_title" | grep -qi "spike: capture authsvc.io" || {
    echo "FAIL: spike title does not use normalized domain 'authsvc.io': $first_title" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture U: every downstream issue referencing any subdomain variant gets
#            Blocked-by the single normalized-domain spike
#
# Two issues reference different subdomains (api.authsvc.io, admin.authsvc.io).
# After the pass, both must carry "Blocked by: #SPIKE-authsvc-io".
# ---------------------------------------------------------------------------

@test "Fixture U: all subdomain-variant issues get Blocked-by the single normalized spike" {
  local issues_file="$RITE_TEST_TMPDIR/issues-u.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Implement authentication
LABELS: feature
TIME: 1hr
BODY:
Call https://api.authsvc.io/token to obtain an access token.
---END---
---ISSUE---
TITLE: Implement admin panel
LABELS: feature
TIME: 1hr
BODY:
Call https://admin.authsvc.io/users to list users.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"

  # Extract all non-spike blocks (blocks 2 and 3 after spike prepended)
  local block2 block3
  block2=$(awk '/^---ISSUE---/{b++; buf=""} b==2{buf=buf"\n"$0} /^---END---/ && b==2{print buf; exit}' "$issues_file")
  block3=$(awk '/^---ISSUE---/{b++; buf=""} b==3{buf=buf"\n"$0} /^---END---/ && b==3{print buf; exit}' "$issues_file")

  # Both downstream blocks must reference the spike
  echo "$block2" | grep -q "#SPIKE-authsvc-io" || {
    echo "FAIL: first downstream issue (api.authsvc.io) missing #SPIKE-authsvc-io" >&2
    echo "--- block 2 ---" >&2
    echo "$block2" >&2
    cat "$issues_file" >&2
    false
  }

  echo "$block3" | grep -q "#SPIKE-authsvc-io" || {
    echo "FAIL: second downstream issue (admin.authsvc.io) missing #SPIKE-authsvc-io" >&2
    echo "--- block 3 ---" >&2
    echo "$block3" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture V: distinct registrable domains still produce distinct spikes
#
# One issue references two different registrable domains (svc-a.io, svc-b.io).
# Expected: 3 issues total (2 spikes + 1 original).
# ---------------------------------------------------------------------------

@test "Fixture V: distinct registrable domains produce distinct spikes" {
  local issues_file="$RITE_TEST_TMPDIR/issues-v.txt"
  write_issues_file "$issues_file" \
    "Integrate two services" \
    "Call https://api.svc-a.io/data and https://api.svc-b.io/data for results."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must emit two WARNINGs (one per distinct registrable domain)
  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 2 ] || {
    echo "FAIL: expected 2 WARNINGs for 2 distinct domains, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must have 3 issues (2 spikes + 1 original)
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 3 ] || {
    echo "FAIL: expected 3 issues (2 spikes + 1 original), got $issue_count" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture W: multi-part TLD (co.uk) — third label becomes registrable domain
#
# api.myservice.co.uk normalizes to myservice.co.uk (not co.uk).
# Expected: 1 spike titled "spike: capture myservice.co.uk ..." and the
# downstream issue gets Blocked-by #SPIKE-myservice-co-uk.
# ---------------------------------------------------------------------------

@test "Fixture W: co.uk multi-part TLD — registrable domain is third-from-right label + co.uk" {
  local issues_file="$RITE_TEST_TMPDIR/issues-w.txt"
  write_issues_file "$issues_file" \
    "Integrate with UK payment provider" \
    "Call https://api.myservice.co.uk/pay to initiate a payment."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # WARNING must name the normalized domain (not the raw subdomain)
  grep -q "myservice.co.uk" "$stderr_out" || {
    echo "FAIL: WARNING does not mention normalized domain 'myservice.co.uk'" >&2
    cat "$stderr_out" >&2
    false
  }

  # Must not produce a spike for bare 'co.uk' (that would be wrong)
  grep -q "spike: capture co.uk" "$issues_file" && {
    echo "FAIL: spike was created for bare 'co.uk' — multi-part TLD normalization is wrong" >&2
    cat "$issues_file" >&2
    false
  } || true

  # Spike title must use the registrable domain myservice.co.uk
  local first_title
  first_title=$(grep "^TITLE:" "$issues_file" | head -1)
  echo "$first_title" | grep -qi "spike: capture myservice.co.uk" || {
    echo "FAIL: spike title does not use 'myservice.co.uk': $first_title" >&2
    cat "$issues_file" >&2
    false
  }

  # Downstream issue must get Blocked-by the myservice.co.uk spike
  local downstream_block
  downstream_block=$(awk '/^---ISSUE---/{b++; buf=""} b==2{buf=buf"\n"$0} /^---END---/ && b==2{print buf; exit}' "$issues_file")
  echo "$downstream_block" | grep -q "#SPIKE-myservice-co-uk" || {
    echo "FAIL: downstream issue missing #SPIKE-myservice-co-uk" >&2
    echo "--- downstream block ---" >&2
    echo "$downstream_block" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture X: registrable-domain fixture (fixtures/foo.co/) grounds subdomain
#            reference — no spike
#
# Regression for Fix 1: Pass-1 previously compared the raw extracted host
# (api.foo.co) against the exact grounded-host set ({foo.co}) — an exact-match
# failure that re-emitted the spike forever even after grounding.
# Now both sides are normalized before comparison: api.foo.co → foo.co,
# which matches the fixture-directory entry foo.co.
# ---------------------------------------------------------------------------

@test "Fixture X: fixtures/foo.co/ grounds an issue referencing https://api.foo.co/ — no spike" {
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/foo.co"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/foo.co/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-x.txt"
  write_issues_file "$issues_file" \
    "Integrate with foo service" \
    "Call https://api.foo.co/v1/resource to fetch data."

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  local warning_count
  warning_count=$(grep -c "^WARNING:" "$stderr_out" || true)
  [ "$warning_count" -eq 0 ] || {
    echo "FAIL: expected 0 WARNINGs — api.foo.co normalizes to grounded foo.co, got $warning_count" >&2
    cat "$stderr_out" >&2
    false
  }

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
# Fixture Y: both subdomains normalize to the same grounded registrable domain —
#            no spike is created and neither issue acquires a Blocked-by
#
# fixtures/api.foo.co/ grounds api.foo.co; normalization maps api.foo.co and
# auth.foo.co to foo.co, which is in grounded_hosts_norm.  Pass-1 sees both
# subdomains as grounded → no candidate → no spike → no Blocked-by injection.
# Expected: 2 issues, neither has a Blocked-by.
# (Prefix-collision regression is covered by Fixture Z.)
# ---------------------------------------------------------------------------

@test "Fixture Y: issue referencing only grounded subdomain gets no spurious Blocked-by from sibling spike" {
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/api.foo.co"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/api.foo.co/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-y.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Implement foo API client
LABELS: feature
TIME: 1hr
BODY:
Call https://api.foo.co/data to fetch results.
---END---
---ISSUE---
TITLE: Add foo admin integration
LABELS: feature
TIME: 1hr
BODY:
Call https://auth.foo.co/admin to manage settings.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # api.foo.co and auth.foo.co both normalize to foo.co, which is grounded
  # via api.foo.co's fixture — no spike should be emitted.
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 2 ] || {
    echo "FAIL: expected 2 issues (no spike) — both subdomains ground to foo.co via api.foo.co fixture; got $issue_count" >&2
    cat "$issues_file" >&2
    false
  }

  # Neither issue should carry a Blocked-by dependency
  grep -q "Blocked by:" "$issues_file" && {
    echo "FAIL: found spurious 'Blocked by:' in issues file — grounded-only issue acquired spike dependency" >&2
    cat "$issues_file" >&2
    false
  } || true

  rm -f "$stderr_out"
}

# ---------------------------------------------------------------------------
# Fixture Z: prefix-collision anchor — fixtures/api.foo.com/ grounded +
#            ungrounded api.foo.co must NOT inject Blocked-by into foo.com issue
#
# Regression for the Pass-3 right-anchor fix: without the (/|$) suffix on the
# context regex, grep -oiE "https?://...foo\.co" matches https://api.foo.com
# because foo.co is a substring of foo.com.  The grounded foo.com issue would
# acquire a spurious "Blocked by: #SPIKE-foo-co".
#
# With the anchor, https://api.foo.com does NOT match foo\.co(/|$) (next char
# is 'm', not '/' or end-of-line), so _matched_hosts is empty → no injection.
# Expected: 3 issues (1 spike for foo.co + 2 originals); foo.com issue has no
# Blocked-by; foo.co issue has Blocked-by #SPIKE-foo-co.
# ---------------------------------------------------------------------------

@test "Fixture Z: prefix-collision anchor — foo.com issue does not acquire Blocked-by from foo.co spike" {
  mkdir -p "$RITE_TEST_TMPDIR/fixtures/api.foo.com"
  echo '{"data": "sample"}' > "$RITE_TEST_TMPDIR/fixtures/api.foo.com/sample.json"

  local issues_file="$RITE_TEST_TMPDIR/issues-z.txt"
  cat > "$issues_file" <<'FIXTURE'
---ISSUE---
TITLE: Integrate with foo.com service
LABELS: feature
TIME: 1hr
BODY:
Call https://api.foo.com/data to fetch results.
---END---
---ISSUE---
TITLE: Add foo.co admin integration
LABELS: feature
TIME: 1hr
BODY:
Call https://api.foo.co/admin to manage settings.
---END---
FIXTURE

  local stderr_out
  stderr_out=$(mktemp)
  _detect_unverified_integrations "$issues_file" 2>"$stderr_out"
  local exit_code=$?

  [ "$exit_code" -eq 0 ] || {
    echo "FAIL: expected exit 0, got $exit_code" >&2
    cat "$stderr_out" >&2
    false
  }

  # foo.co is ungrounded → exactly one spike for foo.co
  local issue_count
  issue_count=$(grep -c "^---ISSUE---$" "$issues_file" || true)
  [ "$issue_count" -eq 3 ] || {
    echo "FAIL: expected 3 issues (1 spike for foo.co + 2 originals), got $issue_count" >&2
    cat "$issues_file" >&2
    false
  }

  # Spike title must be for foo.co (prefix-collision must not produce a foo.com spike)
  local first_title
  first_title=$(grep "^TITLE:" "$issues_file" | head -1)
  echo "$first_title" | grep -qi "foo\.co" || {
    echo "FAIL: spike title does not reference foo.co: $first_title" >&2
    cat "$issues_file" >&2
    false
  }

  # The foo.com issue (block 2 after spike prepended) must NOT carry Blocked-by
  local foocom_block
  foocom_block=$(awk '/^---ISSUE---/{b++; buf=""} b==2{buf=buf"\n"$0} /^---END---/ && b==2{print buf; exit}' "$issues_file")
  echo "$foocom_block" | grep -q "Blocked by:" && {
    echo "FAIL: foo.com issue acquired spurious Blocked-by from foo.co spike (prefix-collision anchor broken)" >&2
    echo "--- foo.com block ---" >&2
    echo "$foocom_block" >&2
    cat "$issues_file" >&2
    false
  } || true

  # The foo.co issue (block 3) must carry Blocked-by #SPIKE-foo-co
  local fooco_block
  fooco_block=$(awk '/^---ISSUE---/{b++; buf=""} b==3{buf=buf"\n"$0} /^---END---/ && b==3{print buf; exit}' "$issues_file")
  echo "$fooco_block" | grep -q "#SPIKE-foo-co" || {
    echo "FAIL: foo.co issue missing #SPIKE-foo-co" >&2
    echo "--- foo.co block ---" >&2
    echo "$fooco_block" >&2
    cat "$issues_file" >&2
    false
  }

  rm -f "$stderr_out"
}

@test "Fixture P: _normalize_python_import_name has no dead _strptime table entry" {
  local plan_issues_sh="${RITE_REPO_ROOT}/lib/core/plan-issues.sh"

  # Count explicit _strptime case entries in the normalization function.
  # The function range is _normalize_python_import_name() to _trim_node_package_name().
  local _start _end
  _start=$(grep -n '^_normalize_python_import_name()' "$plan_issues_sh" | head -1 | cut -d: -f1)
  _end=$(grep -n '^_trim_node_package_name()' "$plan_issues_sh" | head -1 | cut -d: -f1)
  _end=$((_end - 1))

  local fn_body
  fn_body=$(sed -n "${_start},${_end}p" "$plan_issues_sh")

  # Must NOT contain an explicit _strptime case (it is dead — default *) handles it)
  local strptime_case_count
  strptime_case_count=$(echo "$fn_body" | grep -c '_strptime)' || true)

  [ "$strptime_case_count" -eq 0 ] || {
    echo "FAIL: _normalize_python_import_name has $strptime_case_count dead '_strptime)' case(s) — remove them; the default *) case is sufficient" >&2
    echo "$fn_body" | grep '_strptime)' >&2
    false
  }
}
