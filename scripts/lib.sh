#!/usr/bin/env bash
# lib.sh - shared helpers. Source this, do not execute it.
#
# Exit-code contract. Every audit in this repo uses these. An audit that
# cannot complete never returns 0; it returns a code that names the reason.
#
#   0   the audit ran to completion and the subject passed
#   1   the audit ran to completion and the subject FAILED policy
#  64   caller error (bad arguments)
#  70   a required tool was missing
#  71   nothing to audit (empty list) - the audit would have been vacuous
#  72   a value the audit needed could not be resolved
#  73   an exception outlived its expiry date
#  74   artefact verification failed
#  75   the audit aborted before completing

# shellcheck disable=SC2034  # the full table is the contract; each script uses a subset
EX_OK=0
EX_POLICY=1
EX_USAGE=64
EX_MISSING_TOOL=70
EX_NO_INPUT=71
EX_UNRESOLVABLE=72
EX_EXPIRED=73
EX_VERIFY=74
EX_INCOMPLETE=75

_AUDIT_NAME="unnamed-audit"
_AUDIT_COMPLETE=0

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
err()  { printf 'ERROR %s\n' "$*" >&2; }

# die <code> <message...>
die() {
  local code=$1; shift
  err "[$_AUDIT_NAME] $*"
  err "[$_AUDIT_NAME] exiting $code"
  _AUDIT_COMPLETE=1   # the failure itself is a completed outcome
  exit "$code"
}

# begin_audit <name> - installs a guard so that falling off the end of a
# script, or any unhandled error, can never be mistaken for success.
begin_audit() {
  _AUDIT_NAME=$1
  _AUDIT_COMPLETE=0
  trap '_audit_exit_guard' EXIT
  log "== $_AUDIT_NAME =="
}

# end_audit - call as the last statement of a successful script.
end_audit() {
  _AUDIT_COMPLETE=1
  log "== $_AUDIT_NAME: complete =="
}

# shellcheck disable=SC2317  # invoked via trap
_audit_exit_guard() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "$_AUDIT_COMPLETE" -ne 1 ]; then
    err "[$_AUDIT_NAME] audit exited 0 without reaching end_audit."
    err "[$_AUDIT_NAME] treating this as an incomplete audit, not a pass."
    exit "$EX_INCOMPLETE"
  fi
  exit "$rc"
}

need_tool() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "$EX_MISSING_TOOL" "required tool not found: $t"
  done
}

# require_nonempty <count> <what> - a check over a list must first prove the
# list is not empty, otherwise "no violations found" is meaningless.
require_nonempty() {
  local n=$1 what=$2
  case "$n" in
    ''|*[!0-9]*) die "$EX_UNRESOLVABLE" "could not count: $what (got '$n')" ;;
  esac
  [ "$n" -gt 0 ] || die "$EX_NO_INPUT" "empty list: $what - refusing to report a vacuous pass"
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# step_summary <file> - append to the GitHub job summary when running in CI.
step_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  cat "$1" >> "$GITHUB_STEP_SUMMARY"
}
