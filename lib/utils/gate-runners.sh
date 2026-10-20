#!/bin/bash
# lib/utils/gate-runners.sh — Runner helpers: node/pytest detection, workspace bootstrap, gate status
#
# Extracted from lib/utils/test-gate.sh (issue #1236). Contains node/pytest
# runner detection, workspace helpers, and _gate_status/_dir_rel utilities.
# Sourced by test-gate.sh before run_test_gate.

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
# Sentinel is _node_pkg_manager (not _gate_status: _gate_status is stub-attractive
# in gate-flake-retry.bats and a pre-source stub would skip the whole file silently).
if declare -f _node_pkg_manager >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_self_dir/config.sh"
fi

source "$RITE_LIB_DIR/utils/logging.sh"

# ---------------------------------------------------------------------------
# _normalize_node_test_output — synthesize TAP "not ok" lines from jest/vitest
# failure output.
#
# The gate's failure plumbing is TAP-only: the test_count diag greps "^not ok "
# and the tests[] JSON loop feeds _parse_bats_failure_line (^not ok N ). Jest
# and vitest never emit TAP, so a real node test failure yielded test_count=0
# and an empty tests[] array — assess-and-resolve.sh then fired only the
# generic "no parseable findings" item and the fix session investigated blind
# (LeadFlow PR #587: 53+ real failures, test_count=0).
#
# Rather than teach every consumer a second format, append deduped synthetic
# "not ok N - <workspace>: <file>: <test>" lines to the raw output file — the
# same trick the workspace-build failure path uses — so all existing ^not ok
# plumbing picks the failures up unchanged. Forcing jest --json/reporters is
# not viable: rite only controls the root `npm test`; per-workspace runner
# flags live in each target repo's package.json (LeadFlow mixes jest+vitest).
#
# Patterns (ANSI-stripped first):
#   jest suite     : "FAIL <path>[ (N.N s)]" at column 0
#   jest per-test  : "  ● <suite> › <test>" — the › separator is required
#                    (jest also emits bullet noise without it, e.g.
#                    "● Cannot log after tests are done.")
#   vitest suite   : " FAIL  <path> [ <path> ]" (leading whitespace)
#   vitest per-test: " FAIL  <path> > <suite> > <test>"
#   fallback       : a "Tests/Test Files/Test Suites: N failed" summary when
#                    no per-line pattern matched (fully-silenced reporters)
# Workspace attribution: "> pkg@ver test" banners name the block; a trailing
# "npm error location <abs>" upgrades the prefix to the project-relative dir.
# A suite entry is dropped when per-test entries exist for the same file.
#
# Args: $1 = raw tests output file (synthetic lines APPENDED in place;
#            numbering continues after any existing "not ok" lines)
#       $2 = project_root (optional — relativizes npm error location paths)
# Returns 0 always; leaves the file untouched when nothing matched (the
# assess-side no-findings synthetic block remains the final backstop).
# ---------------------------------------------------------------------------
_normalize_node_test_output() {
  local raw_file="$1"
  local norm_root="${2:-}"
  [ -s "$raw_file" ] || return 0

  local _norm_cap=50
  local _norm_stripped _norm_extracted
  _norm_stripped=$(mktemp "/tmp/rite_gate_norm_strip_$$_XXXXXX")
  _norm_extracted=$(mktemp "/tmp/rite_gate_norm_desc_$$_XXXXXX")
  # ANSI-strip first (same expression as _sanitize_json_value): npm piped
  # output is normally plain, but some reporters force color.
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b//g' "$raw_file" > "$_norm_stripped" || true

  awk -v root="$norm_root" '
    function flush(   i, pfx, out) {
      pfx = (wsdir != "") ? wsdir : wsname
      for (i = 1; i <= n; i++) {
        if (typ[i] == "suite" && hasdetail[fil[i]]) continue
        out = (pfx != "") ? pfx ": " buf[i] : buf[i]
        if (!(out in seen)) { seen[out] = 1; print out }
      }
      n = 0; wsdir = ""
      for (i in hasdetail) delete hasdetail[i]
    }
    # workspace banner: "> pkg@version test" — starts a new attribution block
    /^> [^ ]+@[^ ]+ test$/ {
      flush()
      wsname = $2; sub(/@[^@]*$/, "", wsname)
      cursuite = ""
      next
    }
    # npm error location — closes the failing workspace block; prefer the
    # project-relative directory over the package name when derivable
    /^npm error location / {
      if (root != "" && index($4, root "/") == 1)
        wsdir = substr($4, length(root) + 2)
      flush()
      next
    }
    # jest suite failure at column 0; path guard rejects the bare word FAIL
    # in code snippets (real paths contain "/" or .test./.spec.)
    substr($0, 1, 5) == "FAIL " {
      p = $2
      if (p ~ /\// || p ~ /\.(test|spec)\./) {
        cursuite = p
        n++; buf[n] = p ": test suite failed"; typ[n] = "suite"; fil[n] = p
      }
      next
    }
    # jest per-test bullet — file comes from the preceding suite FAIL line
    /^[[:space:]]*● / && / › / {
      t = $0
      sub(/^[[:space:]]*● /, "", t)
      n++; typ[n] = "test"
      if (cursuite != "") { buf[n] = cursuite ": " t; hasdetail[cursuite] = 1 }
      else buf[n] = t
      next
    }
    # vitest lines: leading whitespace + FAIL + path, then "[" (suite) or ">"
    # (per-test — the description already carries the file)
    /^[[:space:]]+FAIL[[:space:]]/ {
      p = $2
      if (p ~ /\// || p ~ /\.(test|spec)\./) {
        if ($3 == ">") {
          t = $0
          sub(/^[[:space:]]+FAIL[[:space:]]+/, "", t)
          n++; buf[n] = t; typ[n] = "test"; hasdetail[p] = 1
        } else if ($3 == "[") {
          n++; buf[n] = p ": test suite failed"; typ[n] = "suite"; fil[n] = p
        }
      }
      next
    }
    END { flush() }
  ' "$_norm_stripped" > "$_norm_extracted" || true

  # Fallback: fully-silenced reporters fail with only a summary line — carry
  # it so the finding at least names the failure counts. Requires >=1 failed
  # (a passing "N passed" summary never matches).
  if [ ! -s "$_norm_extracted" ]; then
    grep -E '^[[:space:]]*(Test Suites|Test Files|Tests):?[[:space:]]+[1-9][0-9]* failed' "$_norm_stripped" \
      | sed 's/^[[:space:]]*//' | tr -s ' ' > "$_norm_extracted" || true
  fi

  local _norm_total _norm_n _norm_desc
  _norm_total=$(grep -c "" "$_norm_extracted" || true)
  if [ "$_norm_total" -gt 0 ]; then
    # Numbering continues after existing not-ok lines (e.g. the synthetic
    # workspace-build failure line appended above the npm test run).
    _norm_n=$(grep -c "^not ok " "$raw_file" || true)
    while IFS= read -r _norm_desc; do
      [ -n "$_norm_desc" ] || continue
      _norm_n=$(( _norm_n + 1 ))
      printf 'not ok %d - %s\n' "$_norm_n" "$_norm_desc" >> "$raw_file"
    done < <(head -n "$_norm_cap" "$_norm_extracted")
    # Cap bounds the assessment prompt size; note the overflow explicitly.
    if [ "$_norm_total" -gt "$_norm_cap" ]; then
      _norm_n=$(( _norm_n + 1 ))
      printf 'not ok %d - ... and %d more test failure(s) truncated — see the gate log for full output\n' \
        "$_norm_n" $(( _norm_total - _norm_cap )) >> "$raw_file"
    fi
    echo "[test-gate] normalized ${_norm_total} jest/vitest failure(s) into TAP findings"
  fi
  rm -f "${_norm_stripped:-}" "${_norm_extracted:-}"
  return 0
}

# ---------------------------------------------------------------------------
# _node_flavored_test_context — true when a RITE_TEST_COMMAND run is expected
# to produce jest/vitest output (node runner named in the command, or the
# repo is an npm package).
# Args: $1 = project_root, $2 = test command string
# ---------------------------------------------------------------------------
_node_flavored_test_context() {
  local ctx_root="$1"
  local ctx_cmd="${2:-}"
  case "$ctx_cmd" in
    # *npm* also covers pnpm; *node* also covers nodemon
    *npm*|*npx*|*yarn*|*jest*|*vitest*|*node*) return 0 ;;
  esac
  [ -f "$ctx_root/package.json" ]
}

# ---------------------------------------------------------------------------
# _classify_pytest_outcome — classify a pytest run into one of four outcomes.
#
# Args: $1=exit_code  $2=raw_output (the captured stdout+stderr of the run)
# Stdout: one of
#   passed             — exit 0, tests ran and all passed
#   failed             — real failure: a test failed, assertion error, or collection error
#   skipped:no_tests   — exit 5 with no collection-error signature
#   skipped:missing_deps — anchored ModuleNotFoundError with no FAILED/AssertionError
#
# Precedence (guards stated explicitly to prevent the v1 false-skip bug):
#   1. Collection errors → failed  (exit 2 OR error-signature in output)
#      A collection-breaking regression must never be silenced.
#   2. Real test failure present → failed
#      A traceback that mentions ModuleNotFoundError is still a real failure if
#      FAILED/AssertionError appears anywhere — the loose-grep bug from v1.
#   3. Missing-dep signature AND no FAILED/AssertionError → skipped:missing_deps
#      Two sub-cases (both must be absent of FAILED/AssertionError to reach here):
#      3a. Pytest-formatted error: `^E\s+` prefix — e.g. "E  ModuleNotFoundError: No module named 'mymodule'"
#          The anchor matches only pytest's error-line prefix, not arbitrary body text.
#      3b. Python-interpreter error — `python3 -m pytest` with pytest uninstalled exits 1 and prints:
#            "/usr/bin/python3: No module named pytest"
#          No `^E` prefix. Matched by bare "No module named '?pytest'?" pattern.
#   4. Exit 5 (no tests collected) → skipped:no_tests
#   5. Default → failed  (conservative: unknown non-zero exit is a real problem)
# ---------------------------------------------------------------------------
_classify_pytest_outcome() {
  local _exit_code="$1"
  local _output="$2"

  # 1. Passed cleanly.
  if [ "$_exit_code" -eq 0 ]; then
    echo "passed"
    return 0
  fi

  # 2. Collection-breaking error: exit 2 OR output signature.
  # Exit 2 = "interrupted / collection error" in pytest's exit-code table.
  # The output signature covers cases where pytest prints the collection error
  # but exits with a code other than 2 (e.g. some plugin wrappers).
  if [ "$_exit_code" -eq 2 ] \
     || echo "$_output" | grep -qE '(errors during collection|ERROR collecting)'; then
    echo "failed"
    return 0
  fi

  # 3. Real test failure present (FAILED line or AssertionError).
  # Must be checked BEFORE the missing-dep check: a traceback that mentions
  # ModuleNotFoundError inside a test that also raises AssertionError is still
  # a real failure and must NOT be silently skipped (the v1 false-skip bug).
  if echo "$_output" | grep -qE '(^FAILED |AssertionError)'; then
    echo "failed"
    return 0
  fi

  # 4. Missing-dep signature — two sub-cases.
  #
  # 4a. Pytest-formatted error lines (`^E\s+` prefix).
  # `^E\s+` matches only pytest's error-prefix column (pytest prints error lines
  # as "E  <exception>").  This excludes ModuleNotFoundError buried in arbitrary
  # body text (docstrings, logging, comments reproduced in tracebacks).
  # "No module named" on a pytest error line covers both:
  #   E  ModuleNotFoundError: No module named 'pytest'
  #   E  ImportError: No module named 'mymodule'
  if echo "$_output" | grep -qE '^E[[:space:]]+(ModuleNotFoundError|.*No module named)'; then
    echo "skipped:missing_deps"
    return 0
  fi

  # 4b. Python-interpreter "no module named pytest" — missing-runner case.
  # When pytest itself is not installed, `python3 -m pytest` never reaches pytest
  # and the interpreter prints a bare line (no ^E prefix):
  #   /usr/bin/python3: No module named pytest
  # This is NOT formatted by pytest, so 4a's ^E anchor never matches.
  # The pattern is: a line of the form "<word>: No module named '?pytest'?"
  # We anchor on "No module named" followed by optional-quote "pytest" optional-quote
  # (covers both `pytest` and `pytest.__main__` variants).  The preceding checks
  # (collection-error, FAILED, AssertionError) guarantee we only reach here when
  # there is no real test failure — so matching this narrow pattern is safe.
  if echo "$_output" | grep -qE "No module named '?pytest'?"; then
    echo "skipped:missing_deps"
    return 0
  fi

  # 5. No tests collected — pytest exit code 5.
  if [ "$_exit_code" -eq 5 ]; then
    echo "skipped:no_tests"
    return 0
  fi

  # Default: conservative — treat unknown non-zero exit as a real failure so
  # we never silently hide an unrecognised problem.
  echo "failed"
}

# ---------------------------------------------------------------------------
# _resolve_node_test_runner — extract the test runner binary name (issue #807)
# Args: $1=project_root
# Echoes the first executable token of package.json's .scripts.test, resolving
# one level of `npm run <X>` / `npm test` delegation. Echoes "" when no runner
# name can be extracted (caller then falls back to the .bin-non-empty heuristic).
#
# Examples:
#   "jest --ci"            -> jest
#   "mocha tests/"         -> mocha
#   "vitest run"           -> vitest
#   "npm run test:unit"    -> (resolves .scripts."test:unit"'s first token)
#   "node ./run.js && jest"-> node   (first token; conservative)
# ---------------------------------------------------------------------------
_resolve_node_test_runner() {
  local _pr="$1"
  local _pkg="$_pr/package.json"
  [ -f "$_pkg" ] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }

  local _script
  _script=$(jq -r '.scripts.test // ""' "$_pkg" 2>/dev/null || echo "")
  [ -n "$_script" ] || { echo ""; return 0; }

  # First whitespace-delimited token of the test script.
  local _first
  _first=$(printf '%s\n' "$_script" | awk '{print $1}' || echo "")
  [ -n "$_first" ] || { echo ""; return 0; }

  # Delegation: `npm run <X>` / `npm test` / `npm run-script <X>` — resolve one
  # level by reading the delegated script's first token. Cheap, single-pass; if
  # it delegates again we just return that token (no deeper recursion).
  if [ "$_first" = "npm" ]; then
    local _second _target _delegated _dtok
    _second=$(printf '%s\n' "$_script" | awk '{print $2}' || echo "")
    if [ "$_second" = "test" ]; then
      # `npm test` inside the test script — recursion would loop; bail to heuristic.
      echo ""
      return 0
    fi
    if [ "$_second" = "run" ] || [ "$_second" = "run-script" ]; then
      _target=$(printf '%s\n' "$_script" | awk '{print $3}' || echo "")
    else
      _target="$_second"
    fi
    if [ -n "$_target" ]; then
      _delegated=$(jq -r --arg k "$_target" '.scripts[$k] // ""' "$_pkg" 2>/dev/null || echo "")
      _dtok=$(printf '%s\n' "$_delegated" | awk '{print $1}' || echo "")
      # Avoid re-emitting another npm delegation token (keep it cheap / one-level).
      if [ -n "$_dtok" ] && [ "$_dtok" != "npm" ]; then
        echo "$_dtok"
        return 0
      fi
    fi
    # Could not cheaply resolve the delegation — fall back to heuristic.
    echo ""
    return 0
  fi

  echo "$_first"
}

# ---------------------------------------------------------------------------
# _node_runner_resolvable — is the node test runner present? (issue #807)
# Args: $1=project_root $2=runner_name (may be empty)
# Returns 0 (resolvable) / 1 (not resolvable).
#
# Resolvable when:
#   - runner_name is known AND ( node_modules/.bin/<runner> is executable
#     OR `command -v <runner>` succeeds on PATH ); OR
#   - runner_name is unknown (extraction failed) AND node_modules/.bin exists
#     and is non-empty (heuristic fallback).
# ---------------------------------------------------------------------------
_node_runner_resolvable() {
  local _pr="$1"
  local _runner="${2:-}"
  local _bindir="$_pr/node_modules/.bin"

  if [ -n "$_runner" ]; then
    if [ -x "$_bindir/$_runner" ]; then
      return 0
    fi
    if command -v "$_runner" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  # Unknown runner — heuristic: .bin exists and is non-empty.
  if [ -d "$_bindir" ] && [ -n "$(ls -A "$_bindir" 2>/dev/null || true)" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# _node_desymlink_node_modules — remove node_modules symlinks before install
# Args: $1=project_root
#
# Belt-and-suspenders defense kept for pre-existing worktrees. Worktree
# creation no longer symlinks node_modules (#844), but older worktrees may
# still carry the link. npm ci resolves THROUGH a symlink: its pre-reify rm
# step readdirs the target and recursively deletes each entry — destroying the
# symlink's target — then replaces the link with a real dir (npm install
# reifies the same way). Removing the LINK first (plain `rm` on the link path
# — never rm -rf, never a trailing slash) makes npm build a worktree-local
# real dir and leaves the target intact.
#
# Called ONLY inside the bootstrap branch: repos whose runners already
# resolve never install, so any surviving symlink's disk-space benefit is
# preserved.  Real dirs and absent paths are no-ops; dangling symlinks are
# removed the same way ([ -L ] is true for them, plain rm succeeds).
# ---------------------------------------------------------------------------
_node_desymlink_node_modules() {
  local _pr="$1"
  local _sink="${_gate_raw_sink:-/dev/null}"
  local _nm
  for _nm in "$_pr/node_modules" "$_pr/backend/node_modules"; do
    if [ -L "$_nm" ]; then
      echo "[test-gate] $_nm is a symlink — removing the link before install so npm cannot destroy its target" >> "$_sink"
      rm "$_nm"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# _node_pkg_manager — which package manager owns this node project? (issue #1097)
# Args: $1=project_root
# Echoes "pnpm" or "npm".
#
# pnpm signals (any one suffices): pnpm-lock.yaml, pnpm-workspace.yaml, or
# package.json `.packageManager` beginning "pnpm@" (corepack pin).
# Everything else is npm. npm must NEVER be run against a pnpm repo: npm
# ignores pnpm-workspace.yaml (workspace packages are left uninstalled and
# unlinked) and writes a stray package-lock.json into the worktree.
# ---------------------------------------------------------------------------
_node_pkg_manager() {
  local _pr="$1"
  if [ -f "$_pr/pnpm-lock.yaml" ] || [ -f "$_pr/pnpm-workspace.yaml" ]; then
    echo "pnpm"
    return 0
  fi
  if [ -f "$_pr/package.json" ] && command -v jq >/dev/null 2>&1; then
    local _pm_field
    _pm_field=$(jq -r '.packageManager // ""' "$_pr/package.json" 2>/dev/null || true)
    case "$_pm_field" in
      pnpm@*) echo "pnpm"; return 0 ;;
    esac
  fi
  echo "npm"
}

# ---------------------------------------------------------------------------
# _node_workspace_patterns — emit workspace glob patterns, one per line (#1097)
# Args: $1=project_root
# Sources, in priority order:
#   - pnpm-workspace.yaml `packages:` list (quotes and trailing comments
#     stripped; parsing stops at the next top-level key)
#   - package.json `.workspaces` (array OR {packages:[...]} object form) via jq
# Echoes nothing when neither source yields patterns.
# ---------------------------------------------------------------------------
_node_workspace_patterns() {
  local _pr="$1"
  if [ -f "$_pr/pnpm-workspace.yaml" ]; then
    # BSD+GNU-portable: select the packages: block (range ends at the next
    # top-level key), keep "- pattern" entries, strip list dash/quotes/comments.
    sed -n '/^packages:/,/^[A-Za-z_]/p' "$_pr/pnpm-workspace.yaml" 2>/dev/null \
      | grep -E '^[[:space:]]*-[[:space:]]*' \
      | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/#.*$//; s/["'"'"']//g; s/[[:space:]]*$//' \
      | grep -v '^$' || true
    return 0
  fi
  [ -f "$_pr/package.json" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then $w[]
      elif ($w | type) == "object" then (($w.packages // [])[])
      else empty end
  ' "$_pr/package.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _provision_pytest_testmon — ensure pytest-testmon is installed in the repo
# venv for per-cycle scoped gating (#1127 / #975).
# Args: $1=project_root  $2=sink (log file, default /dev/null)
# Returns: 0 = testmon available  1 = no venv found, or install failed
#
# Venv detection order mirrors post-merge-verify.sh:256-264 verbatim.
# conda/poetry envs fall through to return 1 (the caller runs unscoped —
# the degraded path covers them without special-casing).
# Never edits requirements*.txt or creates a venv — venv-only install,
# analogous to how _node_install_deps never edits package.json.
# ---------------------------------------------------------------------------
_provision_pytest_testmon() {
  local _pr="$1"
  local _sink="${2:-/dev/null}"

  # Detect venv by pip binary — same order as post-merge-verify.sh:256-264.
  local _pip=""
  if [ -f "$_pr/.venv/bin/pip" ]; then _pip="$_pr/.venv/bin/pip"
  elif [ -f "$_pr/venv/bin/pip" ]; then _pip="$_pr/venv/bin/pip"
  elif [ -f "$_pr/env/bin/pip" ]; then _pip="$_pr/env/bin/pip"
  elif [ -n "${RITE_PROJECT_ROOT:-}" ] && [ -f "$RITE_PROJECT_ROOT/.venv/bin/pip" ]; then
    _pip="$RITE_PROJECT_ROOT/.venv/bin/pip"
  fi

  if [ -z "$_pip" ]; then
    echo "[test-gate] pytest-testmon: no venv found (.venv, venv, env) — skipping provision" >> "$_sink"
    return 1
  fi

  local _venv_python="${_pip%/pip}/python"

  # Probe: already installed?
  if "$_venv_python" -c "import testmon" >/dev/null 2>&1; then
    return 0
  fi

  echo "[test-gate] pytest-testmon: not found in venv — installing (best-effort)..." >> "$_sink"
  # Bounded timeout: a stalled PyPI connection must not block the gate indefinitely.
  local _pip_timeout=120
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_pip_timeout" "$_pip" install -q pytest-testmon >> "$_sink" 2>&1 || true
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$_pip_timeout" "$_pip" install -q pytest-testmon >> "$_sink" 2>&1 || true
  else
    "$_pip" install -q pytest-testmon >> "$_sink" 2>&1 || true
  fi

  # Re-probe: confirm install landed
  if "$_venv_python" -c "import testmon" >/dev/null 2>&1; then
    echo "[test-gate] pytest-testmon: installed successfully" >> "$_sink"
    return 0
  fi

  echo "[test-gate] pytest-testmon: install did not make testmon importable" >> "$_sink"
  return 1
}

# ---------------------------------------------------------------------------
# _node_install_deps — package-manager-aware dependency install (issue #1097)
# Args: $1=project_root  $2=sink file for installer output (default /dev/null)
# Best-effort by contract (mirrors the historical inline npm block): a failed
# install is caught by the exit-127 hard-block when the runner stays
# unresolvable, not by aborting here. Callers run _node_desymlink_node_modules
# first.
# ---------------------------------------------------------------------------
_node_install_deps() {
  local _pr="$1"
  local _sink="${2:-/dev/null}"
  local _pm
  _pm=$(_node_pkg_manager "$_pr")
  if [ "$_pm" = "pnpm" ]; then
    if ! command -v pnpm >/dev/null 2>&1; then
      echo "[test-gate] pnpm project detected but pnpm is not on PATH — skipping dependency bootstrap. Install pnpm (e.g. corepack enable); npm is never run against a pnpm repo (it ignores pnpm-workspace.yaml and writes a stray package-lock.json)." >> "$_sink"
      return 0
    fi
    if [ -f "$_pr/pnpm-lock.yaml" ]; then
      # --frozen-lockfile mirrors `npm ci`; fall back to a plain install when
      # the lockfile is out of sync with package.json (the ci→install split).
      (cd "$_pr" && pnpm install --frozen-lockfile --silent) >> "$_sink" 2>&1 \
        || (cd "$_pr" && pnpm install --silent) >> "$_sink" 2>&1 || true
    else
      (cd "$_pr" && pnpm install --silent) >> "$_sink" 2>&1 || true
    fi
    return 0
  fi
  if [ -f "$_pr/package-lock.json" ]; then
    (cd "$_pr" && npm ci --silent) >> "$_sink" 2>&1 || true
  else
    (cd "$_pr" && npm install --silent) >> "$_sink" 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# _node_is_workspaces_monorepo — is this an npm-workspaces monorepo? (issue #818)
# Args: $1=project_root
# Returns 0 (yes) / 1 (no).
#
# Detection (either signal is sufficient):
#   - root package.json has a non-empty `.workspaces` (array OR {packages:[...]}
#     object form) via jq; OR
#   - the root `.scripts.test` contains `--workspaces` (e.g.
#     `npm run test --workspaces --if-present`).
#
# Conservative: with no jq or no package.json it returns 1 (not a workspaces
# monorepo) so the single-package #807 path is preserved unchanged.
# ---------------------------------------------------------------------------
_node_is_workspaces_monorepo() {
  local _pr="$1"
  local _pkg="$_pr/package.json"

  # pnpm workspaces (issue #1097): pnpm-workspace.yaml with >=1 pattern is a
  # monorepo signal independent of package.json .workspaces (pnpm repos don't
  # set that key) and needs no jq.
  if [ -f "$_pr/pnpm-workspace.yaml" ]; then
    local _pnpm_patterns
    _pnpm_patterns=$(_node_workspace_patterns "$_pr")
    if [ -n "$_pnpm_patterns" ]; then
      return 0
    fi
  fi

  [ -f "$_pkg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Non-empty .workspaces — accept both the array form and the object form
  # ({"packages":[...]}). `values` normalises both to a list; length>0 confirms.
  local _ws_count
  _ws_count=$(jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then ($w | length)
      elif ($w | type) == "object" then (($w.packages // []) | length)
      else 0 end
  ' "$_pkg" 2>/dev/null || echo 0)
  [ -n "$_ws_count" ] || _ws_count=0
  if [ "$_ws_count" -gt 0 ] 2>/dev/null; then
    return 0
  fi

  # Fallback signal: the root test script delegates across workspaces.
  local _script
  _script=$(jq -r '.scripts.test // ""' "$_pkg" 2>/dev/null || echo "")
  case "$_script" in
    *--workspaces*) return 0 ;;
  esac

  return 1
}

# ---------------------------------------------------------------------------
# _node_workspace_runners_resolvable — do ALL workspace test runners resolve?
# Args: $1=project_root  (issue #818)
# Returns 0 (every workspace runner resolves) / 1 (at least one is unresolvable,
# OR we could not positively confirm — bootstrap when in doubt).
#
# For each workspace directory (expanded from the root .workspaces globs) that
# has a package.json with a .scripts.test runner, the runner is considered
# resolvable when it is executable in ANY of:
#   - the workspace's own node_modules/.bin/<runner>
#   - the hoisted root node_modules/.bin/<runner>  (npm hoists shared bins)
#   - on PATH (`command -v <runner>`)
#
# Deliberately strict: a workspace whose runner cannot be positively confirmed
# makes the whole set unresolvable → caller bootstraps (correctness over a
# redundant install). Object-form `.workspaces` ({"packages":[...]}) is
# supported. If no workspace globs or no jq, returns 1 (bootstrap).
# ---------------------------------------------------------------------------
_node_workspace_runners_resolvable() {
  local _pr="$1"
  local _root_pkg="$_pr/package.json"
  [ -f "$_root_pkg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local _root_bin="$_pr/node_modules/.bin"

  # Expand the workspace glob patterns to concrete directories. jq emits one
  # pattern per line (array or object form); the shell expands each glob.
  # Workspace patterns from pnpm-workspace.yaml or package.json (issue #1097).
  local _patterns
  _patterns=$(_node_workspace_patterns "$_pr")
  [ -n "$_patterns" ] || return 1

  local _saw_any_ws=false
  local _pattern _dir _pkg _runner _ws_bin
  while IFS= read -r _pattern; do
    [ -n "$_pattern" ] || continue
    # Expand the glob relative to the project root. `set -f` is NOT used here;
    # patterns like `packages/*` must expand. A non-matching glob yields the
    # literal pattern, which we filter out with the `-d` test below.
    for _dir in "$_pr/"$_pattern; do
      [ -d "$_dir" ] || continue
      _pkg="$_dir/package.json"
      [ -f "$_pkg" ] || continue
      _saw_any_ws=true
      _runner=$(_resolve_node_test_runner "$_dir")
      # Unknown workspace runner (no test script, or unresolvable extraction) —
      # we cannot positively confirm it. Treat as unresolvable → bootstrap.
      [ -n "$_runner" ] || return 1
      _ws_bin="$_dir/node_modules/.bin"
      if [ -x "$_ws_bin/$_runner" ]; then
        continue
      fi
      if [ -x "$_root_bin/$_runner" ]; then
        continue
      fi
      if command -v "$_runner" >/dev/null 2>&1; then
        continue
      fi
      # This workspace's runner is not resolvable anywhere → bootstrap.
      return 1
    done
  done <<EOF
$_patterns
EOF

  # If no workspace package.json was found at all, we cannot confirm anything —
  # bootstrap rather than assume (correctness over a redundant install).
  [ "$_saw_any_ws" = "true" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _node_workspace_has_missing_entry_points — does any workspace package have a
# compiled entry point that does not yet exist on disk? (issue #822)
# Args: $1=project_root
# Returns 0 (at least one package has a missing entry point AND a build script)
#         1 (all entry points present, or no buildable packages found)
#
# Checks the `main` and `exports` (string form) fields of each workspace
# package.json.  If the resolved path does not exist on disk AND the package
# defines a `.scripts.build`, the workspace needs a build step before tests.
#
# This is the root cause of the LeadFlow 2026-06-30→07-01 outage:
#   shared/package.json → "main": "./dist/index.js"
#   shared/dist/ is gitignored and was never built in the worktree
#   → every test that imports @leadflow/shared failed with "Failed to resolve import"
# ---------------------------------------------------------------------------
_node_workspace_has_missing_entry_points() {
  local _pr="$1"
  local _root_pkg="$_pr/package.json"
  [ -f "$_root_pkg" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Workspace patterns from pnpm-workspace.yaml or package.json (issue #1097).
  local _patterns
  _patterns=$(_node_workspace_patterns "$_pr")
  [ -n "$_patterns" ] || return 1

  local _found_missing=false
  local _pattern _dir _pkg _entry _build_script
  while IFS= read -r _pattern; do
    [ -n "$_pattern" ] || continue
    for _dir in "$_pr/"$_pattern; do
      [ -d "$_dir" ] || continue
      _pkg="$_dir/package.json"
      [ -f "$_pkg" ] || continue

      # Only care about packages that define a build script.
      _build_script=$(jq -r '.scripts.build // ""' "$_pkg" 2>/dev/null || echo "")
      [ -n "$_build_script" ] || continue

      # Check main field first.
      _entry=$(jq -r '.main // ""' "$_pkg" 2>/dev/null || echo "")
      if [ -n "$_entry" ] && [ ! -e "$_dir/$_entry" ]; then
        _found_missing=true
        break 2
      fi

      # Check exports field (string form only — object/array forms are more
      # complex; treat them as "unknown" and skip rather than mis-parse).
      _entry=$(jq -r 'if (.exports | type) == "string" then .exports else "" end' "$_pkg" 2>/dev/null || echo "")
      if [ -n "$_entry" ] && [ ! -e "$_dir/$_entry" ]; then
        _found_missing=true
        break 2
      fi
    done
  done <<EOF
$_patterns
EOF

  [ "$_found_missing" = "true" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _node_build_workspace_packages — build workspace packages whose compiled
# entry points are missing.  (issue #822)
# Args: $1=project_root  $2=gate_raw_sink (log file path)
# Returns 0 (all needed builds succeeded or nothing to build)
#         1 (at least one build failed — caller must surface as blocking)
#
# For each workspace package whose entry point is absent:
#   1. Remove stale tsconfig.tsbuildinfo (incremental state can make `tsc
#      --build` a no-op when dist/ is deleted but the buildinfo remains).
#   2. Run `npm run build -w <pkg-name>` so only the affected package is built.
#      Output goes to the gate raw sink; failures are loud (non-zero return).
# ---------------------------------------------------------------------------
_node_build_workspace_packages() {
  local _pr="$1"
  local _sink="${2:-/dev/stdout}"
  local _root_pkg="$_pr/package.json"
  [ -f "$_root_pkg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local _patterns
  _patterns=$(jq -r '
    (.workspaces // empty) as $w
    | if ($w | type) == "array" then $w[]
      elif ($w | type) == "object" then (($w.packages // [])[])
      else empty end
  ' "$_root_pkg" 2>/dev/null || echo "")
  [ -n "$_patterns" ] || return 0

  local _any_failed=false
  local _pattern _dir _pkg _entry _build_script _pkg_name _entry_exports
  while IFS= read -r _pattern; do
    [ -n "$_pattern" ] || continue
    for _dir in "$_pr/"$_pattern; do
      [ -d "$_dir" ] || continue
      _pkg="$_dir/package.json"
      [ -f "$_pkg" ] || continue

      _build_script=$(jq -r '.scripts.build // ""' "$_pkg" 2>/dev/null || echo "")
      [ -n "$_build_script" ] || continue

      _entry=$(jq -r '.main // ""' "$_pkg" 2>/dev/null || echo "")
      _entry_exports=$(jq -r 'if (.exports | type) == "string" then .exports else "" end' "$_pkg" 2>/dev/null || echo "")

      # Determine if this package needs a build: either the main or string-form
      # exports entry point is absent.
      local _needs_build=false
      if [ -n "$_entry" ] && [ ! -e "$_dir/$_entry" ]; then
        _needs_build=true
      elif [ -n "$_entry_exports" ] && [ ! -e "$_dir/$_entry_exports" ]; then
        _needs_build=true
      fi
      [ "$_needs_build" = "true" ] || continue

      _pkg_name=$(jq -r '.name // ""' "$_pkg" 2>/dev/null || echo "")
      if [ -z "$_pkg_name" ]; then
        echo "[test-gate] WARNING: workspace package at '$_dir' has no 'name' field — cannot run targeted build; skipping" >> "$_sink"
        continue
      fi

      # Remove stale tsconfig.tsbuildinfo to prevent tsc --build from treating
      # a deleted dist/ as "already up to date" and producing a no-op build.
      local _buildinfo="$_dir/tsconfig.tsbuildinfo"
      if [ -f "$_buildinfo" ]; then
        echo "[test-gate] Removing stale $(_dir_rel "$_pr" "$_buildinfo") to prevent tsc --build no-op" >> "$_sink"
        rm -f "$_buildinfo" || true
      fi
      # Also remove root-level tsconfig.tsbuildinfo that may reference the package.
      local _root_buildinfo="$_pr/tsconfig.tsbuildinfo"
      if [ -f "$_root_buildinfo" ]; then
        echo "[test-gate] Removing stale root tsconfig.tsbuildinfo to prevent tsc --build no-op" >> "$_sink"
        rm -f "$_root_buildinfo" || true
      fi

      echo "[test-gate] Building workspace package '$_pkg_name' (entry point missing: ${_entry:-$_entry_exports})..." >> "$_sink"
      local _build_exit_file _build_exit
      _build_exit_file=$(mktemp "/tmp/rite_gate_build_exit_${PR_NUMBER:-0}_$$_XXXXXX")
      { (cd "$_pr" && npm run build -w "$_pkg_name" 2>&1); echo $? > "$_build_exit_file"; } >> "$_sink" || true
      _build_exit=$(cat "$_build_exit_file" 2>/dev/null || echo "1")
      rm -f "$_build_exit_file"
      if [ "$_build_exit" -ne 0 ]; then
        echo "[test-gate] ERROR: build of workspace package '$_pkg_name' failed (exit $_build_exit)" >> "$_sink"
        _any_failed=true
      else
        echo "[test-gate] workspace package '$_pkg_name' built successfully" >> "$_sink"
      fi
    done
  done <<EOF
$_patterns
EOF

  [ "$_any_failed" = "false" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# _dir_rel — emit a path relative to a base, or the original if outside base.
# Used for terse log messages.
# ---------------------------------------------------------------------------
_dir_rel() {
  local _base="$1" _path="$2"
  echo "${_path#"$_base/"}"
}

# ---------------------------------------------------------------------------
# _gate_status — emit a [test-gate] progress line, routed by _gate_raw_sink.
#
# Reads the caller's `_gate_raw_sink` (bash dynamic scope):
#   - Summary mode (default): sink is RITE_LOG_FILE — progress lines buffer
#     there and only the compact digest reaches the terminal.
#   - Verbose + background: sink is RITE_LOG_FILE — avoids interleaving with
#     the concurrent review stream.
#   - Verbose + foreground: sink is /dev/stdout — live progress visible on the
#     terminal.
# The `:-/dev/stdout` default keeps it safe if ever called before the sink is
# set (e.g. in early-exit paths above run_test_gate).
# ---------------------------------------------------------------------------
_gate_status() {
  echo "$@" >> "${_gate_raw_sink:-/dev/stdout}"
}

# ---------------------------------------------------------------------------
# _maybe_warn_unscoped_suite — emit the scope warning + diag when applicable.
# Args: $1=duration_s $2=scope_warn_threshold $3=is_sharkrite
# Called from both the RITE_TEST_COMMAND path and the common tail so the
# format is guaranteed identical in both sites (behavioral-design.md → #495).
# ---------------------------------------------------------------------------
_maybe_warn_unscoped_suite() {
  local _duration="$1"
  local _scope_warn_threshold="$2"
  local _is_sharkrite="$3"
  if [ "$_is_sharkrite" = "false" ] \
      && [ "$_scope_warn_threshold" -gt 0 ] \
      && [ "$_duration" -ge "$_scope_warn_threshold" ]; then
    print_warning "[test-gate] This repo runs its full test suite every fix cycle (${_duration}s); scoped selection would pay only the diff — see sharkrite #975 / framework-native options (jest --findRelatedTests, vitest related, pytest --testmon)"
    _diag "GATE_SCOPE_UNSCOPED duration_s=${_duration} pr=${PR_NUMBER:-?}"
  fi
}

# ---------------------------------------------------------------------------
# _detect_workspace_runner — detect test runner for a workspace package (#975)
# Args: $1=ws_dir (absolute path)
# Returns: "jest" | "vitest" | "unknown" on stdout.
# Priority: devDependencies/dependencies key > test-script first token.
# ---------------------------------------------------------------------------
_detect_workspace_runner() {
  local _dwr_dir="$1"
  local _dwr_pkg="$_dwr_dir/package.json"
  [ -f "$_dwr_pkg" ] || { echo "unknown"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "unknown"; return 0; }
  local _dwr_has_jest _dwr_has_vitest
  _dwr_has_jest=$(jq -r '((.devDependencies // {}) + (.dependencies // {})) | has("jest")' \
    "$_dwr_pkg" 2>/dev/null || echo "false")
  _dwr_has_vitest=$(jq -r '((.devDependencies // {}) + (.dependencies // {})) | has("vitest")' \
    "$_dwr_pkg" 2>/dev/null || echo "false")
  [ "$_dwr_has_jest" = "true" ] && { echo "jest"; return 0; }
  [ "$_dwr_has_vitest" = "true" ] && { echo "vitest"; return 0; }
  local _dwr_first
  _dwr_first=$(_resolve_node_test_runner "$_dwr_dir")
  case "${_dwr_first:-}" in
    jest|vitest) echo "$_dwr_first" ;;
    *) echo "unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# _changed_files_to_workspace_dirs — map diff paths to affected workspace dirs (#975)
# Args: $1=project_root  $2=changed_files (newline-separated, relative to root)
# Stdout: deduplicated workspace-relative dirs with at least one changed file.
# ---------------------------------------------------------------------------
_changed_files_to_workspace_dirs() {
  local _cfd_root="$1"
  local _cfd_files="$2"
  [ -n "$_cfd_files" ] || return 0
  local _cfd_patterns
  _cfd_patterns=$(_node_workspace_patterns "$_cfd_root")
  [ -n "$_cfd_patterns" ] || return 0

  # Split patterns into include (normal) and exclude (!-prefixed) lists.
  # Bash glob expansion is not used here because:
  #   1. ** without `set -o globstar` only matches one level — pnpm's dominant
  #      `packages/**` layout silently misses nested workspaces (e.g.
  #      packages/scope/component). find handles any depth correctly.
  #   2. !exclusion patterns like `!packages/legacy` would need to expand a path
  #      starting with `!`, which never matches a real directory — the exclusion
  #      semantics are lost entirely under glob expansion.
  local _cfd_include_pats="" _cfd_exclude_pats="" _cfd_p
  while IFS= read -r _cfd_p; do
    [ -n "$_cfd_p" ] || continue
    case "$_cfd_p" in
      !*) _cfd_exclude_pats="${_cfd_exclude_pats}${_cfd_p#!}"$'\n' ;;
      *)  _cfd_include_pats="${_cfd_include_pats}${_cfd_p}"$'\n' ;;
    esac
  done < <(printf '%s\n' "$_cfd_patterns")

  local _cfd_seen="" _cfd_pattern _cfd_dir _cfd_rel _cfd_base _cfd_dirs

  while IFS= read -r _cfd_pattern; do
    [ -n "$_cfd_pattern" ] || continue

    # Expand the include pattern using find rather than bash glob expansion so
    # that ** correctly matches any depth and * matches only one level.
    # Patterns typically take the form `packages/**`, `apps/*`, or a literal path.
    case "$_cfd_pattern" in
      *"**"*)
        # Strip from ** onward to get the base directory, e.g. packages/** → packages
        _cfd_base="${_cfd_root}/${_cfd_pattern%%\*\**}"
        _cfd_base="${_cfd_base%/}"
        [ -d "$_cfd_base" ] || continue
        _cfd_dirs=$(find "$_cfd_base" -mindepth 1 -type d 2>/dev/null || true)
        ;;
      *"*"*)
        # Single-level glob, e.g. packages/* → direct subdirs only
        _cfd_base="${_cfd_root}/${_cfd_pattern%%\**}"
        _cfd_base="${_cfd_base%/}"
        [ -d "$_cfd_base" ] || continue
        _cfd_dirs=$(find "$_cfd_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
        ;;
      *)
        # Literal path (no glob) — treat as an exact workspace directory
        _cfd_base="${_cfd_root}/${_cfd_pattern}"
        [ -d "$_cfd_base" ] || continue
        _cfd_dirs="$_cfd_base"
        ;;
    esac

    [ -n "$_cfd_dirs" ] || continue

    while IFS= read -r _cfd_dir; do
      [ -n "$_cfd_dir" ] || continue
      [ -d "$_cfd_dir" ] || continue
      [ -f "$_cfd_dir/package.json" ] || continue
      _cfd_rel="${_cfd_dir#"$_cfd_root/"}"

      # Skip directories that match a !exclusion pattern.
      local _cfd_excl _cfd_skip=false
      while IFS= read -r _cfd_excl; do
        [ -n "$_cfd_excl" ] || continue
        case "$_cfd_rel" in
          "$_cfd_excl"|"$_cfd_excl/"*) _cfd_skip=true; break ;;
        esac
      done < <(printf '%s\n' "${_cfd_exclude_pats:-}")
      [ "$_cfd_skip" = "true" ] && continue

      # Dedup across patterns
      case "$_cfd_seen" in *":${_cfd_rel}:"*) continue ;; esac

      if printf '%s\n' "$_cfd_files" | grep -q "^${_cfd_rel}/"; then
        echo "$_cfd_rel"
        _cfd_seen="${_cfd_seen}:${_cfd_rel}:"
      fi
    done < <(printf '%s\n' "$_cfd_dirs")

  done < <(printf '%s\n' "$_cfd_include_pats")
  return 0
}

# ---------------------------------------------------------------------------
# _node_scope_zero_tests — detect when a scoped test run selected 0 tests (#975)
# Args: $1=raw_output_file
# Sanity valve: when the scoped run produces 0 tests but non-test source was
# changed, the per-cycle path falls back to the workspace full suite.
# ---------------------------------------------------------------------------
_node_scope_zero_tests() {
  local _nszt_file="$1"
  [ -f "$_nszt_file" ] || return 0
  grep -qE '(No tests found|Tests:[[:space:]]+0 total|Test Suites:[[:space:]]+0 total|No test files found)' \
    "$_nszt_file" 2>/dev/null
}
