#!/usr/bin/env bats
# sharkrite-test-covers: lib/core/claude-workflow.sh
# Sharkrite routes venv bootstrap around a broken/hanging system python3 via
# resolve_working_python. Live trigger (2026-06-26): a self-exec'ing python3
# wrapper made `python3 -m venv` hang the dev session for ~30 min.

setup() {
  export RITE_LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
  export RITE_SOURCE_FUNCTIONS_ONLY=1
  source "${RITE_LIB_DIR}/utils/config.sh" 2>/dev/null || true
  source "${RITE_LIB_DIR}/utils/logging.sh" 2>/dev/null || true
  source "${RITE_LIB_DIR}/core/claude-workflow.sh"
  SHIM=$(mktemp -d); export SHIM
}
teardown() { rm -rf "${SHIM:-}"; }

@test "resolve_working_python skips a HANGING python3 and returns a working one" {
  command -v /usr/bin/python3 >/dev/null 2>&1 || command -v python3.13 >/dev/null 2>&1 \
    || skip "no fallback python available to resolve to"
  # A broken python3 first on PATH that HANGS (like the self-exec wrapper).
  cat > "$SHIM/python3" <<'EOF'
#!/bin/bash
sleep 999
EOF
  chmod +x "$SHIM/python3"
  _saved="$PATH"; export PATH="$SHIM:$PATH"
  _start=$(date +%s)
  run resolve_working_python
  _elapsed=$(( $(date +%s) - _start ))
  export PATH="$_saved"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "python3" ]      # did NOT pick the hanging bare python3 shim
  [ "$_elapsed" -lt 30 ]          # bounded — didn't wait on the 999s sleep
}

@test "resolve_working_python honors RITE_PYTHON override (tried first)" {
  command -v /usr/bin/python3 >/dev/null 2>&1 || skip "no /usr/bin/python3 on this host"
  run env RITE_PYTHON=/usr/bin/python3 bash -c "
    export RITE_LIB_DIR='$RITE_LIB_DIR' RITE_SOURCE_FUNCTIONS_ONLY=1
    source '$RITE_LIB_DIR/core/claude-workflow.sh'
    resolve_working_python"
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/bin/python3" ]
}

@test "structural: venv bootstrap uses the resolved interpreter, not bare python3" {
  grep -q '_venv_py=$(resolve_working_python' "${RITE_LIB_DIR}/core/claude-workflow.sh"
  grep -q 'run_with_timeout "$_pip_timeout" "$_venv_py" -m venv' "${RITE_LIB_DIR}/core/claude-workflow.sh"
  # The old unbounded bare-python3 venv creation must be gone.
  ! grep -qE '^\s*if ! python3 -m venv \.venv' "${RITE_LIB_DIR}/core/claude-workflow.sh"
}
