# shellcheck shell=bash
# Shared .env-style file accessor.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers) and the optional typesafe.ai
# dispatch key (bin/fm-dispatch-resolve.sh) both resolve their value through
# fmx_env_get, so those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.
# It also owns the typed dispatch resolution on/off gate (fm_typed_provider,
# fm_typed_key below), shared by the resolver and bootstrap.

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fmx_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# fm_typed_provider <home>
# Print the typed dispatch resolution provider selector: TYPESAFE_API_PROVIDER
# from the environment, else from <home>/.env. Empty means the direct
# typesafe.ai path.
fm_typed_provider() {
  local provider=${TYPESAFE_API_PROVIDER:-}
  [ -n "$provider" ] || provider=$(fmx_env_get TYPESAFE_API_PROVIDER "$1/.env")
  printf '%s' "$provider"
}

# fm_typed_key <provider> <direct-key> <home>
# Print the bearer key that turns typed dispatch resolution on, or nothing when
# it is off. This is the single owner of that on/off gate, shared by
# bin/fm-dispatch-resolve.sh and the bootstrap crew-dispatch diagnostic.
# Provider "openrouter" reads only the macOS Keychain service
# $FM_OPENROUTER_KEYCHAIN_SERVICE; any other provider uses <direct-key>, else a
# TYPESAFE_API_KEY= line in <home>/.env.
FM_OPENROUTER_KEYCHAIN_SERVICE=openrouter-api-key
fm_typed_key() {
  local provider=$1 key=$2 home=$3
  if [ "$provider" = openrouter ]; then
    command -v security >/dev/null 2>&1 || return 0
    security find-generic-password -s "$FM_OPENROUTER_KEYCHAIN_SERVICE" -w 2>/dev/null || true
    return 0
  fi
  [ -n "$key" ] || key=$(fmx_env_get TYPESAFE_API_KEY "$home/.env")
  printf '%s' "$key"
}
