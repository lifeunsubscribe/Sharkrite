# Sourced by tools/sharkrite-lint.sh (the driver) — not standalone.
# Shares the driver shell: SHELL_FILES, VIOLATIONS, print_violation, colors.

# Rule 24: Bare $VAR reference for known optional config variables in lib/utils/*.sh
#
# Config variables in the EMAIL_*, SLACK_*, RITE_EMAIL_*, AWS_*, SNS_*, and
# RITE_SNS_* families are optional (not guaranteed to be set by the caller).
# Under `set -u`, a bare `$VAR` reference (without braces or a default) when the
# variable is unset crashes the script immediately with "VAR: unbound variable"
# before any error handling can run.
#
# Live bug (2026-06-06): notifications.sh send_email() crashed with
# "EMAIL_ADDRESS: unbound variable" — wrong variable name AND bare reference.
# This caused PR #302 to be reported as failed even though the merge had already
# succeeded. See issue #313.
#
# SNS_TOPIC_ARN / RITE_SNS_* added in issue #377: send_sms() uses bare
# $SNS_TOPIC_ARN (a module-local alias for RITE_SNS_TOPIC_ARN). Without this
# rule covering the SNS_* family, future bare references bypass detection entirely.
# The existing suppression in notifications.sh remains valid (module-local alias
# initialized safely at load time via SNS_TOPIC_ARN="${RITE_SNS_TOPIC_ARN:-}").
#
# What this rule flags:
#   FLAGGED: $EMAIL_ADDRESS          (no braces — crashes under set -u when unset)
#   FLAGGED: $RITE_EMAIL_FROM        (no braces)
#   FLAGGED: $SLACK_WEBHOOK          (no braces — even if checked in prior guard,
#                                     the bare form is fragile: future moves break it)
#   FLAGGED: $SNS_TOPIC_ARN          (no braces — same crash class as EMAIL_ADDRESS)
#   FLAGGED: $RITE_SNS_TOPIC_ARN     (no braces)
#   PASSES:  ${EMAIL_NOTIFICATION_ADDRESS:-}   (safe: default to empty)
#   PASSES:  ${RITE_EMAIL_FROM:-}              (safe: default to empty)
#   PASSES:  ${AWS_PROFILE:-default}           (safe: explicit default)
#   PASSES:  ${SNS_TOPIC_ARN:-}               (safe: default to empty)
#   PASSES:  ${RITE_SNS_TOPIC_ARN:-}          (safe: default to empty)
#
# Note: ${VAR} without :- is NOT flagged by this rule. While technically unsafe
# under set -u, ${VAR} is also caught by shellcheck SC2168 (used-before-set).
# This rule focuses on the fully-bare $VAR pattern that is the most common
# source of the crash class described in issue #313.
#
# Scope: lib/utils/*.sh only (config-consuming utility layer).
#
# Suppression: place on the line immediately before the flagged code:
#   # sharkrite-lint disable BARE_VAR_REFERENCE - Reason: variable is always set by <caller>
echo "Checking for bare config-var references (EMAIL_*, SLACK_*, RITE_EMAIL_*, AWS_*, SNS_*, RITE_SNS_*) in lib/utils/*.sh..."

# Build the candidate file list from SHELL_FILES filtered to lib/utils/ paths.
# This reuses the RITE_LINT_EXTRA_DIRS expansion already applied to SHELL_FILES,
# so fixture directories injected via that env var are scanned correctly —
# matching the behavior of all other per-subset rules (e.g. Rule 16 LIB_FILES).
# The filter matches any path ending in /lib/utils/*.sh (both project tree and fixtures).
_r24_utils_files=()
for _f in "${SHELL_FILES[@]}"; do
  if [[ "$_f" == */lib/utils/*.sh ]]; then
    _r24_utils_files+=("$_f")
  fi
done

for file in "${_r24_utils_files[@]}"; do
  while IFS=: read -r line_num line_content; do
    # Skip full-line comments
    if echo "$line_content" | grep -qE '^\s*#'; then
      continue
    fi

    # We flag ONLY bare $VAR (no braces at all) for the config-var families.
    # Pattern: $VARNAME where VARNAME starts with EMAIL_, SLACK_, RITE_EMAIL_, AWS_,
    # SNS_, or RITE_SNS_ and the $ is NOT followed by { (which would indicate a brace
    # expansion like ${VAR:-}).
    # The negative lookahead is simulated by matching $VAR then filtering out ${...} forms.
    #
    # Technique: strip all ${...} brace expansions from the line, then check if
    # any bare $VAR from the config families remains.
    _stripped_line=$(echo "$line_content" | sed 's/\${[^}]*}//g' || true)
    if ! echo "$_stripped_line" | grep -qE '\$(EMAIL_|SLACK_|RITE_EMAIL_|AWS_|SNS_|RITE_SNS_)[A-Z_]+'; then
      continue
    fi

    # Check for suppression comment on preceding line
    prev_line_num=$((line_num - 1))
    prev_line=$(sed -n "${prev_line_num}p" "$file" 2>/dev/null || true)
    if echo "$prev_line" | grep -qE '#.*sharkrite-lint.*disable.*BARE_VAR_REFERENCE'; then
      continue
    fi

    print_violation "$file" "$line_num" "BARE_VAR_REFERENCE" \
      "bare \$VAR reference for optional config variable — use \${VAR:-} to prevent 'unbound variable' crash under set -u (see: issue #313, notifications.sh EMAIL_ADDRESS bug)"
  done < <(grep -nE '\$(EMAIL_|SLACK_|RITE_EMAIL_|AWS_|SNS_|RITE_SNS_)[A-Z_]+' "$file" 2>/dev/null || true)
done

