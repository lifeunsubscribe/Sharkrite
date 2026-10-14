#!/bin/bash
# lib/utils/gate-selection.sh — Gate test and lint selection by changed paths
#
# Split from lib/utils/test-gate.sh (issue #1236): selection concern layer.
# Provides: _select_tests_by_changed_paths, _select_lint_by_changed_paths,
#   _bats_file_matches_changed, _bats_file_is_serial, _parse_test_coverage_header,
#   _changed_functions_in_file, _expand_functions_with_callers, _compute_bats_jobs
#
# Usage:
#   source "$RITE_LIB_DIR/utils/gate-selection.sh"

set -euo pipefail

# Re-source guard: skip if already loaded (idempotent sourcing)
if declare -f _select_tests_by_changed_paths >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# Source config if not already loaded
if [ -z "${RITE_LIB_DIR:-}" ]; then
  _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_self_dir/config.sh"
fi

source "$RITE_LIB_DIR/utils/markers.sh"

# ---------------------------------------------------------------------------
# Test selection by changed paths (issue #462)
# ---------------------------------------------------------------------------
# Bats files declare coverage via a single-line header:
#   # sharkrite-test-covers: lib/core/foo.sh, lib/utils/bar.sh
# The gate intersects this with the commit's changed-file list and runs only
# the matching subset. Files WITHOUT a header are SKIPPED (post-#480 backfill;
# the MISSING_TEST_COVERAGE_HEADER lint rule enforces headers on new files).
#
# There are NO bats full-suite trigger paths: selection is always targeted.
# The trigger list (gate/lint/Makefile/helpers/fixtures changes forced all
# ~165 files) was removed 2026-06-12 — a full run costs hours per fix-loop
# iteration and drowned real findings in load-induced flake. The accepted
# coverage trade-off (helpers/fixtures/Makefile changes select few or zero
# bats files) is documented in behavioral-design.md → "Test Selection by
# Changed Paths"; issue #482 tracks the compensating periodic safety net.
# FORCE_FULL survives only for the no-diff degenerate case below.
#
# Override the diff base via RITE_TEST_GATE_DIFF_BASE (default: origin/main).
# ---------------------------------------------------------------------------

# Files whose change forces a full LINT scan (bats selection is never
# escalated — see above; a full lint scan costs seconds, not hours, so the
# escalation is kept here). A change to lib/utils/markers.sh is intentionally
# NOT a trigger —
# adding/renaming a constant doesn't change which existing files violate
# RAW_MARKER_LITERAL (literals live in the same files before and after).
_LINT_GATE_FULL_SUITE_TRIGGERS=(
  "tools/*-lint.sh"
  "Makefile"
)

# _select_lint_by_changed_paths — produce the lint scope plan
# Args: $1=changed_files (newline-separated relative paths), $2=project_root
# Stdout: one of
#   FORCE_FULL  — run lint over the full codebase
#   <newline-separated absolute paths> — targeted subset
#   (empty)     — no shell-source changes; caller should skip lint
# Returns 0 always (caller branches on stdout).
_select_lint_by_changed_paths() {
  local changed_files="$1"
  local project_root="$2"

  # No diff (e.g. brand-new branch with no upstream) → full scan, safer default.
  if [ -z "$changed_files" ]; then
    echo "FORCE_FULL"
    return 0
  fi

  # Full-scan trigger: lint rule change, Makefile change. Suppressed by
  # RITE_TEST_GATE_SKIP_TRIGGERS=true (used by post-merge-verify.sh: rebases
  # past main commits that touched lint rules or the Makefile would otherwise
  # force a full scan for changes main already validated through its own gate).
  if [ "${RITE_TEST_GATE_SKIP_TRIGGERS:-false}" != "true" ]; then
    local _trigger _changed
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      for _trigger in "${_LINT_GATE_FULL_SUITE_TRIGGERS[@]+"${_LINT_GATE_FULL_SUITE_TRIGGERS[@]}"}"; do
        # shellcheck disable=SC2254  # glob expansion in case is intentional
        case "$_changed" in
          $_trigger)
            echo "FORCE_FULL"
            return 0
            ;;
        esac
      done
    done <<< "$changed_files"
  fi

  # Emit absolute paths for changed files that look lint-eligible by path. The
  # final scope filter is the intersection inside sharkrite-lint.sh (it knows
  # exactly which files are in SHELL_FILES, including its own self-exclusion),
  # so this check just keeps the env-var compact and avoids passing obviously
  # irrelevant entries (docs, etc).
  #
  # tests/**/*.bats are lint-eligible: Rules 34/35 (BATS_PRE_SOURCE_STUB_OVERWRITE,
  # BATS_FILE_SCOPE_ENV_READ) target .bats files specifically. Without emitting
  # changed .bats paths here, those rules never run against changed test files
  # through the post-commit gate (the production path they were built for).
  # `tests/*.bats` alone spans every depth: in a `case` pattern `*` matches `/`,
  # so it already covers tests/regression/foo.bats et al. A separate
  # tests/*/*.bats would be redundant and trips shellcheck SC2221/2222 (#1015).
  while IFS= read -r _changed; do
    [ -z "$_changed" ] && continue
    case "$_changed" in
      bin/*|lib/*|tools/*|tests/*.bats)
        [ -f "$project_root/$_changed" ] && echo "$project_root/$_changed"
        ;;
    esac
  done <<< "$changed_files"

  # Explicit return so the function never inherits the [ -f ] exit code from
  # the final iteration — contract is "returns 0 always; caller branches on stdout".
  return 0
}

# ---------------------------------------------------------------------------
# Bats parallelism (--jobs N) — opt-in, gated by GNU parallel availability
# ---------------------------------------------------------------------------
# bats-core natively supports `--jobs N` for file-level parallelism via GNU
# parallel (or shenwei356/rush). Default model: parallel ACROSS .bats files,
# serial WITHIN each file. The within-file serial guarantee means a test that
# touches shared state (e.g. /tmp/sharkrite-config-rce in
# test_config_parser.bats) is safe so long as the *other* parallel files don't
# also touch the same path — which the codebase already avoids via
# BATS_TEST_TMPDIR / BATS_FILE_TMPDIR / setup_test_tmpdir helpers.
#
# Default behavior is auto-detection:
#   - parallel installed → use ncpu (no cap)
#   - parallel missing   → serial (1)
# Override via RITE_BATS_JOBS=N (any positive int wins; set 1 to force serial).
#
# History: capped at 4 in #510 to "keep load reasonable on shared/CI boxes". On
# multi-core dev boxes the cap defeated the optimization. Measured on an 8-core
# MBP, the 9-file post-merge subset took 24s at --jobs 4 vs 18s at --jobs 8
# (25% faster single batch). Two concurrent batches: uncapped was STILL faster
# per batch (33s vs 38s) — under oversubscription the OS keeps all cores busy,
# while the cap leaves cores idle whenever the suite hits a serially-bound
# file. GitHub Actions free runners have ~4 cores so auto-detect there still
# yields 4. Users on truly shared boxes can pin a lower value via
# RITE_BATS_JOBS=N.
# Census-based scaling (#1165): at ≥3 concurrent gates (count > 2) jobs are
# divided by the live gate count (floor, min 2) to prevent timing-sensitive
# tests from starving past BATS_TEST_TIMEOUT. At ≤2 gates the full-ncpu
# behaviour is preserved — the #510 result that uncapped beats capped even
# under two-batch oversubscription still holds.

# _census_live_gate_count — count active gate instances via the census dir.
# Each running gate registers its BASHPID (subshell PID, not $$) under
# ${RITE_LOCK_DIR}/gate-census/<pid>. Dead entries (kill -0 returns non-zero)
# are reaped in the same pass.
# Stdout: non-negative integer count of live gates (including this one).
_census_live_gate_count() {
  local _census_dir="${RITE_LOCK_DIR:-}/gate-census"
  [ -d "$_census_dir" ] || { echo 0; return 0; }
  local _count=0 _pid _entry
  while IFS= read -r _entry; do
    [ -z "$_entry" ] && continue
    _pid=$(basename "$_entry")
    # Validate: must be all digits (PID), skip non-PID filenames
    case "$_pid" in
      *[!0-9]*) continue ;;
    esac
    if kill -0 "$_pid" 2>/dev/null; then
      _count=$((_count + 1))
    else
      # Reap dead entry — scoped to the specific file, no glob
      rm -f "$_entry" 2>/dev/null || true
    fi
  done < <(find "$_census_dir" -maxdepth 1 -type f 2>/dev/null || true)
  echo "$_count"
}

# _compute_bats_jobs — compute the --jobs value for bats.
# Args: $1 (optional) — pre-computed live gate count from _census_live_gate_count.
#   When provided the census walk is skipped (avoids a second find). Absent → walks
#   the census dir directly (useful for standalone calls in tests).
_compute_bats_jobs() {
  local _census_count="${1:-}"
  # Explicit override wins unconditionally — census scaling is bypassed.
  if [ -n "${RITE_BATS_JOBS:-}" ]; then
    # Sanitize: must be a positive integer
    if echo "${RITE_BATS_JOBS}" | grep -qE '^[1-9][0-9]*$'; then
      echo "${RITE_BATS_JOBS}"
      return 0
    fi
    # Garbage value → fall through to auto-detection
  fi
  # Auto-detection requires GNU parallel (or rush) on PATH
  if ! command -v parallel >/dev/null 2>&1 && ! command -v rush >/dev/null 2>&1; then
    echo 1
    return 0
  fi
  local _ncpu
  _ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)
  # Census-based scaling: when ≤2 gates are active (including this one), use full
  # ncpu — preserves the #510 result that uncapped is faster than capped under
  # dual-batch load. At 3+ gates, divide to prevent BATS_TEST_TIMEOUT starvation.
  if [ -z "$_census_count" ]; then
    _census_count=$(_census_live_gate_count)
  fi
  local _jobs
  if [ "${_census_count:-0}" -le 2 ]; then
    _jobs="$_ncpu"
  else
    _jobs=$(( _ncpu / _census_count ))
    [ "$_jobs" -lt 2 ] && _jobs=2
  fi
  echo "$_jobs"
}

# _parse_test_coverage_header — extract the sharkrite-test-covers paths
# Looks in the first 15 lines for `# sharkrite-test-covers: <paths>`.
# Returns the comma-separated path list, or empty string if no header.
#
# A path may carry an optional function scope:
#     lib/utils/test-gate.sh::_compute_bats_jobs|_bats_file_is_serial
# which selects this test only when the diff touches one of those top-level
# functions.  A bare path keeps file-level behavior.  Rationale: test-gate.sh
# is ~2900 lines / 34 functions and 29 bats files declare it, so a 20-line
# change selected all 29 — which both wasted time and created the parallel
# load that made gate-invoking tests flake.
_parse_test_coverage_header() {
  local bats_file="$1"
  local _header
  _header=$(head -15 "$bats_file" 2>/dev/null \
    | grep -E "^# ${RITE_MARKER_TEST_COVERS}:" \
    | head -1 || true)
  if [ -z "$_header" ]; then
    echo ""
    return 0
  fi
  # Strip prefix and trailing whitespace
  echo "$_header" | sed -E "s/^# ${RITE_MARKER_TEST_COVERS}:[[:space:]]*//; s/[[:space:]]*$//" || true
}

# _bats_file_is_serial — return 0 if the file carries the sharkrite-gate-serial hint
# Looks in the first 15 lines for `# sharkrite-gate-serial` (no value, presence-only).
# Files with this hint run without --jobs (sequential) while the rest of the selection
# runs in parallel. Hint is a scheduling signal, not an exclusion — selected files always run.
# Returns: 0 (serial hint present) or 1 (run in parallel / no hint)
_bats_file_is_serial() {
  local bats_file="$1"
  head -15 "$bats_file" 2>/dev/null \
    | grep -qE "^# ${RITE_MARKER_GATE_SERIAL}([[:space:]]|$)"
}

# _expand_functions_with_callers — widen a changed-function set to its callers
# Args: $1=source file path; stdin=newline-separated function names
# Stdout: the input set plus every function that (transitively) calls one of them
#
# Why: attribution is syntactic — it reports the function whose body the diff
# touched. A test scoped to `run_test_gate` must still run when a helper that
# `run_test_gate` calls is edited, or scoping would silently deselect real
# coverage. Expanding UPWARD through callers is the direction that preserves
# that: edit a callee → its callers are implicated → tests naming those callers
# are selected. The reverse (expanding downward) would over-select without
# protecting anything.
_expand_functions_with_callers() {
  local _file="$1"
  local _seed_file
  _seed_file=$(mktemp "/tmp/rite_fnexp_seed_$$_XXXXXX")
  cat > "$_seed_file"
  [ -s "$_seed_file" ] || { rm -f "$_seed_file"; return 0; }

  awk -v SEED="$_seed_file" '
    # Collect each top-level function body keyed by name.
    /^[a-z_][a-z0-9_]*\(\)[[:space:]]*\{/ {
      fn = $1; sub(/\(\).*/, "", fn)
      depth = 1; names[fn] = 1; next
    }
    fn != "" {
      body[fn] = body[fn] "\n" $0
      d = gsub(/\{/, "{"); depth += d
      d = gsub(/\}/, "}"); depth -= d
      if (depth <= 0) fn = ""
      next
    }
    END {
      while ((getline s < SEED) > 0) if (s != "") changed[s] = 1
      # Fixpoint: a function whose body references a changed function is itself
      # implicated. Bounded by the function count, so it always terminates.
      do {
        added = 0
        for (f in names) {
          if (f in changed) continue
          for (c in changed) {
            if (body[f] ~ ("(^|[^A-Za-z0-9_])" c "([^A-Za-z0-9_]|$)")) {
              changed[f] = 1; added = 1; break
            }
          }
        }
      } while (added)
      for (k in changed) print k
    }
  ' "$_file" 2>/dev/null || true
  rm -f "$_seed_file"
}

# _changed_functions_in_file — top-level shell function names touched by the diff
# Args: $1=project-relative file path, $2=project_root
# Stdout: newline-separated function names, or empty when attribution is not
#         possible (no diff, non-shell file, or a change outside any function).
#
# Empty output means "unattributable" and callers MUST fail safe by selecting
# the file's covering tests — precision is an optimization, never a filter that
# can hide a real regression.
#
# Attribution rule: a changed line inside `name() { ... }` belongs to `name`.
# A changed line in the comment block immediately above a definition (only
# comments/blanks between) also belongs to that function, since that block
# documents it — without this, a comment touch-up would deselect every test.
_changed_functions_in_file() {
  local _rel="$1" _root="$2"
  case "$_rel" in
    *.sh|*.bash) ;;
    *) echo ""; return 0 ;;
  esac
  # sharkrite-lint disable RAW_ORIGIN_MAIN_REF - Reason: cold-start default for direct/CI invocation; run_workflow seeds origin/<target> per #1037, operator env (RITE_TEST_GATE_DIFF_BASE) still wins. Over-selecting against main errs safe here — an unattributable diff falls back to file-level selection.
  local _base="${RITE_TEST_GATE_DIFF_BASE:-origin/main}"
  local _hunks
  _hunks=$(git -C "$_root" diff -U0 "${_base}...HEAD" -- "$_rel" 2>/dev/null \
    | grep -oE '^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)?' || true)
  [ -z "$_hunks" ] && { echo ""; return 0; }

  # Expand each hunk's +start[,count] into the concrete changed line numbers.
  local _lines_file
  _lines_file=$(mktemp "/tmp/rite_fnscope_lines_$$_XXXXXX")
  printf '%s\n' "$_hunks" | awk '
    {
      plus = $3                     # "+start[,count]"
      sub(/^\+/, "", plus)
      n = index(plus, ",")
      if (n > 0) { start = substr(plus, 1, n-1) + 0; count = substr(plus, n+1) + 0 }
      else       { start = plus + 0; count = 1 }
      if (count == 0) { print start; next }   # pure deletion: attribute to the site
      for (i = 0; i < count; i++) print start + i
    }' > "$_lines_file" 2>/dev/null || true

  [ -s "$_lines_file" ] || { rm -f "$_lines_file"; echo ""; return 0; }

  local _out
  _out=$(awk -v WANT="$_lines_file" '
    # Pass 1 is implicit: record per-line enclosing function and definition lines.
    /^[a-z_][a-z0-9_]*\(\)[[:space:]]*\{/ {
      fn = $1; sub(/\(\).*/, "", fn)
      depth = 1; map[NR] = fn; defline[NR] = fn; next
    }
    fn != "" {
      d = gsub(/\{/, "{"); depth += d
      d = gsub(/\}/, "}"); depth -= d
      map[NR] = fn
      if (depth <= 0) fn = ""
      next
    }
    { map[NR] = ""; iscomment[NR] = ($0 ~ /^[[:space:]]*(#|$)/) ? 1 : 0 }
    END {
      while ((getline ln < WANT) > 0) {
        if (ln in map && map[ln] != "") { seen[map[ln]] = 1; continue }
        # Comment block directly above a definition → attribute to that function.
        attached = ""
        for (j = ln; j <= ln + 25; j++) {
          if (j in defline) { attached = defline[j]; break }
          if (!(j in iscomment) || iscomment[j] != 1) break
        }
        if (attached != "") { seen[attached] = 1; continue }
        unattributable = 1
      }
      if (unattributable) exit 0            # emit nothing → caller fails safe
      for (k in seen) print k
    }
  ' "$_root/$_rel" 2>/dev/null || true)
  rm -f "$_lines_file"
  # Widen to callers so editing a helper still selects tests that exercise the
  # functions calling it (see _expand_functions_with_callers).
  printf '%s\n' "$_out" | grep -vE '^$' \
    | _expand_functions_with_callers "$_root/$_rel" || true
}

# _bats_file_matches_changed — decide if a single bats file should run
# Args: $1=bats_file_path, $2=changed_files (newline-separated)
# Returns: 0 (include) or 1 (skip)
#
# Default behavior changed after the all-files backfill landed (#480):
# headerless files are now SKIPPED, not included. The previous "headerless
# = always include" fallback gave the conservative-safe answer when most
# files lacked headers, but it also defeated the optimization (95%+ of
# files still ran every time). With 100% header coverage as the new
# baseline, missing headers are treated as missing coverage signal —
# enforce via the MISSING_TEST_COVERAGE_HEADER lint rule in sharkrite-lint.sh.
_bats_file_matches_changed() {
  local bats_file="$1"
  local changed_files="$2"
  local _header
  _header=$(_parse_test_coverage_header "$bats_file")
  if [ -z "$_header" ]; then
    # No header → exclude (new default; rule enforces backfill on new files)
    return 1
  fi
  # Header is comma-separated; iterate each pattern.
  # set -f disables filesystem glob expansion during the split — without it,
  # a header like `lib/utils/*.sh` would be expanded against the filesystem
  # immediately, replacing the pattern with the list of currently-matching files.
  # The case statement below needs the literal pattern to do glob matching against
  # the (different) changed-file list.
  set -f
  local IFS=','
  # shellcheck disable=SC2086  # word-splitting on $_header is intentional
  set -- $_header
  unset IFS
  set +f
  local _pattern _changed _path_pat _fn_list _fn _changed_fns
  for _pattern in "$@"; do
    # Trim surrounding whitespace
    _pattern="${_pattern# }"
    _pattern="${_pattern% }"
    [ -z "$_pattern" ] && continue
    # Optional function scope: `path::fn_a|fn_b` narrows the match to changes
    # inside the named top-level functions.  A bare `path` keeps file-level
    # behavior exactly as before (every existing header is unaffected).
    _path_pat="${_pattern%%::*}"
    _fn_list=""
    case "$_pattern" in
      *::*) _fn_list="${_pattern#*::}" ;;
    esac
    while IFS= read -r _changed; do
      [ -z "$_changed" ] && continue
      # shellcheck disable=SC2254  # glob expansion in case is intentional
      case "$_changed" in
        $_path_pat)
          [ -z "$_fn_list" ] && return 0          # file-level header: match as before
          _changed_fns=$(_changed_functions_in_file "$_changed" "${RITE_PROJECT_ROOT:-.}")
          # Unattributable change (top-level edit, no diff, non-shell file) →
          # fail safe: behave exactly like a file-level header.
          [ -z "$_changed_fns" ] && return 0
          local _fns=()
          IFS='|' read -r -a _fns <<< "$_fn_list"
          for _fn in "${_fns[@]+"${_fns[@]}"}"; do
            _fn="${_fn# }"; _fn="${_fn% }"
            [ -z "$_fn" ] && continue
            if printf '%s\n' "$_changed_fns" | grep -qxF "$_fn"; then
              return 0
            fi
          done
          ;;
      esac
    done <<< "$changed_files"
  done
  return 1
}

# _select_tests_by_changed_paths — produce the bats invocation plan
# Args: $1=changed_files (newline-separated), $2=project_root
# Stdout: one of
#   FORCE_FULL                              — run full suite (no diff computable ONLY)
#   <newline-separated list of bats files>  — targeted subset, relative to project_root
#   (empty)                                 — diff exists but no covered tests; caller skips bats
# Returns 0 always (caller handles empty/full).
# There are no path-based full-suite triggers — selection is always targeted
# (trigger list removed 2026-06-12; see the section header above).
_select_tests_by_changed_paths() {
  local changed_files="$1"
  local project_root="$2"

  # No diff → run full suite (degenerate but safe; e.g. brand-new branch, no
  # upstream). post-merge-verify.sh's main-broken check deliberately exploits
  # this: it sets RITE_TEST_GATE_DIFF_BASE=HEAD so the diff is empty and the
  # full suite validates main itself. Do not remove without giving that caller
  # an explicit force-full mechanism.
  if [ -z "$changed_files" ]; then
    echo "FORCE_FULL"
    return 0
  fi

  # Walk every bats file and decide inclusion. Output is relative paths so the
  # caller can `cd "$project_root" && bats <relative-paths>`.
  #
  # First rule (obvious-case shortcut): if the file IS itself in the diff, run
  # it. The sharkrite-test-covers header lists SOURCE paths, not test paths —
  # without this check, editing a .bats file would match no header anywhere,
  # the selection would come back empty, and the edited file's own tests
  # would never run for the very change that touched them.
  (cd "$project_root" && find tests -name "*.bats" -type f 2>/dev/null) \
    | while IFS= read -r _rel; do
        # Exclude concurrency tests from the (parallel) gate. They spawn processes
        # that rendezvous at file-based barriers; under `bats --jobs` the box is
        # oversubscribed and the barriers throw false timeouts (verified: the suite
        # passes serially, exit 0, but produces ~77 "Barrier timeout" failures under
        # --jobs 8). They give the parallel gate NO reliable signal — and a flaky
        # failure here cascades: it fails the gate → triggers the post-merge
        # main-broken FULL-suite check → which flakes again. Real coverage of these
        # race tests comes from a serial context (the full-suite safety net /
        # running `bats tests/concurrency/` directly), not the parallel gate.
        case "$_rel" in tests/concurrency/*) continue ;; esac
        if echo "$changed_files" | grep -Fxq "$_rel"; then
          echo "$_rel"
          continue
        fi
        if _bats_file_matches_changed "$project_root/$_rel" "$changed_files"; then
          echo "$_rel"
        fi
      done
}
