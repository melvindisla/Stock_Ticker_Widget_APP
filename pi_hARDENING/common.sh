#!/usr/bin/env bash

# Common library for Pi hardening scripts
set -Eeuo pipefail
IFS=$'\n\t'

# Constants (set by master before sourcing if needed)
readonly SCRIPT_VERSION="1.0.0"
readonly PROG_NAME="${0##*/}"
readonly LOG_FILE="/var/log/pi-hardening.log"
readonly BACKUP_TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"

# ANSI Color Codes
readonly CLR_RED='\033[0;31m'
readonly CLR_GREEN='\033[0;32m'
readonly CLR_YELLOW='\033[1;33m'
readonly CLR_BLUE='\033[0;34m'
readonly CLR_CYAN='\033[0;36m'
readonly CLR_BOLD='\033[1m'
readonly CLR_RESET='\033[0m'

# Execution Counters (inherited from master if exported)
declare -i SUCCESS_COUNT=${SUCCESS_COUNT:-0}
declare -i FAILURE_COUNT=${FAILURE_COUNT:-0}
declare -i WARNING_COUNT=${WARNING_COUNT:-0}
declare -a FAILED_CMDS=(${FAILED_CMDS[@]:-})
declare -a WARNING_MSGS=(${WARNING_MSGS[@]:-})

_timestamp() { date +'%Y-%m-%d %H:%M:%S'; }
log() {
  local msg="$*"
  printf "${CLR_BLUE}[%s] [INFO]${CLR_RESET} %s\n" "$( _timestamp )" "$msg"
  if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then
    printf '[%s] [INFO] %s\n' "$( _timestamp )" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}
success() { local msg="$*"; printf "${CLR_GREEN}[%s] [SUCCESS]${CLR_RESET} %s\n" "$( _timestamp )" "$msg"; if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then printf '[%s] [SUCCESS] %s\n' "$( _timestamp )" "$msg" >> "$LOG_FILE" 2>/dev/null || true; fi; ((SUCCESS_COUNT++)) || true; }
warn() { local msg="$*"; printf "${CLR_YELLOW}[%s] [WARNING]${CLR_RESET} %s\n" "$( _timestamp )" "$msg"; WARNING_MSGS+=("$msg"); ((WARNING_COUNT++)) || true; if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then printf '[%s] [WARNING] %s\n' "$( _timestamp )" "$msg" >> "$LOG_FILE" 2>/dev/null || true; fi; }
error() { local msg="$*"; printf "${CLR_RED}[%s] [ERROR]${CLR_RESET} %s\n" "$( _timestamp )" "$msg" >&2; if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then printf '[%s] [ERROR] %s\n' "$( _timestamp )" "$msg" >> "$LOG_FILE" 2>/dev/null || true; fi; }

die() { error "$*"; exit 1; }

on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]}"
  local cmd="${BASH_COMMAND}"
  error "Script execution failed at line ${line_no} (exit code ${exit_code}): ${cmd}"
  exit "$exit_code"
}
trap on_error ERR

run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf "${CLR_CYAN}[DRY-RUN] Would execute:${CLR_RESET}"
    printf ' %q' "$@"
    printf '\n'
    ((SUCCESS_COUNT++)) || true
    return 0
  fi
  log "Executing: $*"
  if "$@"; then
    ((SUCCESS_COUNT++)) || true
    return 0
  else
    local rc=$?
    warn "Command returned exit code ${rc}: $*"
    ((FAILURE_COUNT++)) || true
    FAILED_CMDS+=("$(printf '%q ' "$@")")
    return "$rc"
  fi
}

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found in PATH: $1"; }

validate_port() { local port="$1"; if ! [[ "$port" =~ ^[0-9]+$ ]] || ! (( 1 <= 10#$port && 10#$port <= 65535 )); then die "Invalid port number: '$port' (must be between 1 and 65535)"; fi; }
validate_cidr() { local cidr="$1"; local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'; if ! [[ "$cidr" =~ $pattern ]]; then die "Invalid IPv4 CIDR: '$cidr'"; fi; }
validate_username() { local user="$1"; if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then die "Invalid Linux username format: '$user'"; fi; }
