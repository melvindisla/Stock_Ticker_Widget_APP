#!/usr/bin/env bash

# Master orchestrator – calls all component scripts in order
set -Eeuo pipefail
IFS=$'\n\t'

# Determine script directory (assumed same dir as this file)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common for shared vars & argument parsing utilities
source "${SCRIPT_DIR}/common.sh"

# ---------- Argument Parsing (same as original) ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-port) SSH_PORT="${2:?Error: --ssh-port requires a port argument}"; shift 2 ;;
    --api-port) API_PORT="${2:?Error: --api-port requires a port argument}"; shift 2 ;;
    --allow-ssh-from) SSH_CIDR="${2:?Error: --allow-ssh-from requires a CIDR argument}"; shift 2 ;;
    --allow-api-from) API_CIDR="${2:?Error: --allow-api-from requires a CIDR argument}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:?Error: --admin-user requires a username argument}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --no-docker) SKIP_DOCKER="true"; shift ;;
    --skip-backup-cron) SKIP_BACKUP_CRON="true"; shift ;;
    --force-unsupported) FORCE_UNSUPPORTED="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# Validate required params
validate_port "${SSH_PORT:-22}"
validate_port "${API_PORT:-8000}"
validate_cidr "${SSH_CIDR:-192.168.0.0/16}"
validate_cidr "${API_CIDR:-192.168.0.0/16}"

# Export variables for child scripts
export SSH_PORT API_PORT SSH_CIDR API_CIDR ADMIN_USER DRY_RUN SKIP_DOCKER SKIP_BACKUP_CRON FORCE_UNSUPPORTED

# ---------- Pre‑flight checks ----------
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (e.g., sudo $0)"
fi

# Basic environment detection (kept from original)
PI_MODEL="Unknown"
if [[ -f /proc/cpuinfo ]]; then
  PI_MODEL=$(awk -F: '/^Model/ {print $2}' /proc/cpuinfo | sed 's/^[[:space:]]*//')
fi
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "${FORCE_UNSUPPORTED}" != "true" ]]; then
  warn "Non‑ARM64 architecture detected ($ARCH)."
fi
if [[ "$PI_MODEL" != *"Raspberry Pi 4"* && "$PI_MODEL" != *"Raspberry Pi 5"* && "${FORCE_UNSUPPORTED}" != "true" ]]; then
  warn "Unexpected hardware model: $PI_MODEL"
fi

# Detect OS distribution
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  DISTRIB_ID=$ID
  DISTRIB_CODENAME=$VERSION_CODENAME
else
  DISTRIB_ID="debian"
  DISTRIB_CODENAME="bookworm"
fi
log "Detected OS: $DISTRIB_ID ($DISTRIB_CODENAME)"

# ---------- Sequential execution of component scripts ----------
run "${SCRIPT_DIR}/system_updates.sh"
run "${SCRIPT_DIR}/admin_ssh.sh"
run "${SCRIPT_DIR}/firewall_fail2ban.sh"
run "${SCRIPT_DIR}/time_trim.sh"
run "${SCRIPT_DIR}/postgres_backup.sh"
run "${SCRIPT_DIR}/docker_install.sh"
run "${SCRIPT_DIR}/unattended_upgrades.sh"
run "${SCRIPT_DIR}/attack_surface.sh"
run "${SCRIPT_DIR}/secrets_hygiene.sh"
run "${SCRIPT_DIR}/hardware_health_cron.sh"
run "${SCRIPT_DIR}/summary.sh"
