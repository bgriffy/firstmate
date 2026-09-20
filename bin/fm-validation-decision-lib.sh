# shellcheck shell=bash
# Shared vocabulary for the deferred no-mistakes validation decision.
# Usage: . bin/fm-validation-decision-lib.sh   (no FM_* setup required)
#
# bin/fm-validation-decision.sh owns the lifecycle and is the only writer of
# every record named here; this file exists so the scripts that must agree with
# it - bin/fm-brief.sh and bin/fm-promote.sh (which contract a worker receives),
# bin/fm-spawn.sh (what the task record starts as), bin/fm-crew-state.sh and
# bin/fm-teardown.sh (how a pending decision reads) - share one spelling
# instead of restating it. docs/configuration.md "Automatic no-mistakes
# validation" owns the operator-facing preference contract.
#
# PREFERENCE. config/no-mistakes-auto holds one whitespace-trimmed token.
# Absent or `on` is automatic validation, which is every home's behavior before
# this preference existed; `off` defers the run-or-skip choice to the captain
# after implementation. Any other content, or a path that is not a readable
# regular file, is an error the caller must refuse on: a preference Firstmate
# cannot read is never quietly treated as either answer.
#
# TASK RECORD. state/<id>.meta carries `validation_decision=` for a task whose
# contract deferred the choice: `pending` from spawn or promotion until the
# captain answers, then `run` or `skip`. A task with no such line is an
# automatic task. `validation_head=` is the commit the pending decision was
# opened against, and `validation_answer_sent=1` records that the recorded
# answer reached the worker's steering inbox.
#
# BRIEF CONTRACT. A deferred ship brief records
# `Delivery contract: mode=no-mistakes validation=deferred`. The LAST delivery
# contract line in a brief is the current one, because an answered decision and
# a scout promotion both append a superseding contract rather than rewrite the
# original.

# shellcheck disable=SC2034 # Shared constants, read by the sourcing scripts.
FM_VALIDATION_PREFERENCE_FILE='no-mistakes-auto'
FM_VALIDATION_DECISION_KEY='validation-decision'
FM_VALIDATION_BRIEF_HEADING='# Current validation decision contract'

# Print this home's preference as `on` or `off`. Returns 1 with a diagnostic on
# stderr when the preference cannot be read as one of those two values.
fm_validation_auto_read() {  # <config-dir>
  local file="$1/$FM_VALIDATION_PREFERENCE_FILE" value
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'on\n'
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/$FM_VALIDATION_PREFERENCE_FILE must be a readable regular file holding one of: on, off" >&2
    return 1
  fi
  value=$(tr -d '[:space:]' <"$file") || {
    echo "error: config/$FM_VALIDATION_PREFERENCE_FILE could not be read" >&2
    return 1
  }
  case "$value" in
    on|off) printf '%s\n' "$value" ;;
    *)
      echo "error: config/$FM_VALIDATION_PREFERENCE_FILE holds '$value'; accepted values are: on (always run no-mistakes, the default when the file is absent), off (ask the captain after implementation)" >&2
      return 1
      ;;
  esac
}

# Replace this home's preference atomically: the new value is written beside
# the target and renamed over it, so a failed write leaves the current choice
# intact rather than a torn file.
fm_validation_auto_write() {  # <config-dir> <on|off>
  local config=$1 value=$2 target tmp
  case "$value" in
    on|off) ;;
    *) echo "error: the automatic no-mistakes preference must be on or off (got '$value')" >&2; return 1 ;;
  esac
  target="$config/$FM_VALIDATION_PREFERENCE_FILE"
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    echo "error: config/$FM_VALIDATION_PREFERENCE_FILE is not a regular file; refusing to replace it" >&2
    return 1
  fi
  mkdir -p "$config" || { echo "error: cannot create $config" >&2; return 1; }
  tmp=$(mktemp "$config/.$FM_VALIDATION_PREFERENCE_FILE.XXXXXX") || {
    echo "error: cannot stage config/$FM_VALIDATION_PREFERENCE_FILE" >&2
    return 1
  }
  if ! printf '%s\n' "$value" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$target"; then
    rm -f -- "$tmp"
    echo "error: cannot publish config/$FM_VALIDATION_PREFERENCE_FILE; the previous value is unchanged" >&2
    return 1
  fi
}

# Resolve which contract a ship task receives: `auto` or `deferred`. Only a
# no-mistakes task can defer, because the deferred choice is whether to run
# no-mistakes at all. An explicit per-task value wins over the home preference,
# which is how a current captain instruction for one task is honored without
# flipping the standing preference.
fm_validation_resolve() {  # <config-dir> <mode> [<explicit: auto|deferred>]
  local config=$1 mode=$2 explicit=${3:-} auto
  case "$explicit" in
    '') ;;
    auto|deferred) ;;
    *) echo "error: --validation must be auto or deferred (got '$explicit')" >&2; return 1 ;;
  esac
  if [ "$mode" != no-mistakes ]; then
    if [ "$explicit" = deferred ]; then
      echo "error: --validation deferred applies only to --mode no-mistakes; mode=$mode never runs no-mistakes, so there is no run-or-skip choice to defer" >&2
      return 1
    fi
    printf 'auto\n'
    return 0
  fi
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  auto=$(fm_validation_auto_read "$config") || return 1
  if [ "$auto" = off ]; then
    printf 'deferred\n'
  else
    printf 'auto\n'
  fi
}

# The brief's CURRENT delivery contract line, or nothing when it records none.
fm_validation_brief_contract_line() {  # <brief>
  [ -f "$1" ] || return 0
  sed -n 's/^Delivery contract: \(mode=.*\)$/\1/p' "$1" | tail -n 1
}

# The delivery mode that current contract line records.
fm_validation_brief_mode() {  # <brief>
  local line
  line=$(fm_validation_brief_contract_line "$1")
  line=${line#mode=}
  printf '%s\n' "${line%% *}"
}

# `deferred` when the current contract line defers validation, else `auto`.
fm_validation_brief_validation() {  # <brief>
  case " $(fm_validation_brief_contract_line "$1") " in
    *' validation=deferred '*) printf 'deferred\n' ;;
    *) printf 'auto\n' ;;
  esac
}

# The task record's decision state: pending, run, skip, or nothing for an
# automatic task. The last line wins, matching every other meta reader.
fm_validation_meta_decision() {  # <meta>
  [ -f "$1" ] || return 0
  sed -n 's/^validation_decision=//p' "$1" | tail -n 1
}
