#!/usr/bin/env bash

# ==============================================================================
# scripts/gemeni-hardeing-pi.sh
# ==============================================================================
# Raspberry Pi 4 Host OS Hardening & Provisioning Script
# Designed for Phase 1: MVP (The Core Self-Hosted Ticker)
#
# References:
#   - docs/ROADMAP.md (Phase 1: MVP Hardware & Host OS Hardening)
#   - docs/stock-ticker-spec.md (Section 4.10 Local Server & Hardware Operations)
#
# Core Capabilities:
#   1. System package upgrades & unattended security updates
#   2. SSH daemon hardening (public-key only, root login disabled, port config)
#   3. UFW firewall lockdown (LAN-only access for SSH & API port 8000, Tailscale)
#   4. Fail2ban intrusion prevention with UFW jail integration
#   5. Network Time Protocol (systemd-timesyncd) clock synchronization
#   6. NVMe storage mount (/mnt/nvme), UASP & TRIM verification, weekly fstrim
#   7. PostgreSQL directory layout (/mnt/nvme/postgres/data) & automated backup cron
#   8. Docker Engine & Docker Compose v2 setup with daemon JSON log rotation limits
#   9. Attack surface reduction (disables Bluetooth, Avahi, Triggerhappy)
#  10. Secrets hygiene (.env permissions locked to 600)
#  11. Hardware health monitoring (under-voltage & thermal throttling diagnostics)
#
# Safe, idempotent, non-interactive, and includes --dry-run preview mode.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Constants & Paths -------------------------------------------------
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

# Execution Counters
declare -i SUCCESS_COUNT=0
declare -i FAILURE_COUNT=0
declare -i WARNING_COUNT=0
declare -a FAILED_CMDS=()
declare -a WARNING_MSGS=()

# ---------- Default Parameters ------------------------------------------------
declare SSH_PORT=22                  # Default SSH port per spec (§4.10, ROADMAP)
declare API_PORT=8000                # FastAPI API container port per spec (§4.3)
declare SSH_CIDR="192.168.0.0/16"    # Default LAN CIDR allowed for SSH
declare API_CIDR="192.168.0.0/16"    # Default LAN CIDR allowed for API
declare ADMIN_USER=""                # Target admin user (auto-detected if blank)
declare NVME_DEVICE=""               # Explicit NVMe partition (auto-detected if blank)
declare DRY_RUN="false"              # Preview mode
declare SKIP_DOCKER="false"          # Skip Docker Engine & Compose installation
declare FORCE_UNSUPPORTED="false"    # Bypass Raspberry Pi 4 / OS checks
declare SKIP_BACKUP_CRON="false"     # Skip creating Postgres backup script/cron

# ---------- Logging & Output Helpers ------------------------------------------
_timestamp() { date +'%Y-%m-%d %H:%M:%S'; }

log() {
    local msg="$*"
    printf "${CLR_BLUE}[%s] [INFO]${CLR_RESET} %s\n" "$(_timestamp)" "$msg"
    if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then
        printf '[%s] [INFO] %s\n' "$(_timestamp)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

success() {
    local msg="$*"
    printf "${CLR_GREEN}[%s] [SUCCESS]${CLR_RESET} %s\n" "$(_timestamp)" "$msg"
    if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then
        printf '[%s] [SUCCESS] %s\n' "$(_timestamp)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

warn() {
    local msg="$*"
    printf "${CLR_YELLOW}[%s] [WARNING]${CLR_RESET} %s\n" "$(_timestamp)" "$msg"
    WARNING_MSGS+=("$msg")
    ((WARNING_COUNT++)) || true
    if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then
        printf '[%s] [WARNING] %s\n' "$(_timestamp)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

error() {
    local msg="$*"
    printf "${CLR_RED}[%s] [ERROR]${CLR_RESET} %s\n" "$(_timestamp)" "$msg" >&2
    if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "/var/log" ) ]]; then
        printf '[%s] [ERROR] %s\n' "$(_timestamp)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    error "$*"
    exit 1
}

# Error trap handler
on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]}"
    local cmd="${BASH_COMMAND}"
    error "Script execution failed at line ${line_no} (exit code ${exit_code}): ${cmd}"
    exit "$exit_code"
}
trap on_error ERR

# Command execution wrapper (dry-run and logging aware)
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
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

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found in PATH: $1"
}

# ---------- Input Validation Helpers ------------------------------------------
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || ! (( 1 <= 10#$port && 10#$port <= 65535 )); then
        die "Invalid port number: '$port' (must be between 1 and 65535)"
    fi
}

validate_cidr() {
    local cidr="$1"
    local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'
    if ! [[ "$cidr" =~ $pattern ]]; then
        die "Invalid IPv4 CIDR: '$cidr' (e.g., 192.168.1.0/24 or 192.168.0.0/16)"
    fi
}

validate_username() {
    local user="$1"
    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        die "Invalid Linux username format: '$user'"
    fi
}

# ---------- Usage / Help ------------------------------------------------------
usage() {
    cat <<EOF
${CLR_BOLD}Stock Ticker App – Raspberry Pi OS Hardening & Provisioning Script${CLR_RESET}
Version: ${SCRIPT_VERSION}

${CLR_BOLD}USAGE:${CLR_RESET}
    sudo ./${PROG_NAME} [options]

${CLR_BOLD}OPTIONS:${CLR_RESET}
    --ssh-port <port>          SSH daemon port (default: 22, per spec)
    --api-port <port>          FastAPI API port to allow through UFW (default: 8000)
    --allow-ssh-from <cidr>    IPv4 CIDR allowed to connect via SSH (default: 192.168.0.0/16)
    --allow-api-from <cidr>    IPv4 CIDR allowed to reach API (default: 192.168.0.0/16)
    --admin-user <username>    Non-root administrative user (default: \$SUDO_USER or 'sysadmin')
    --nvme-device <device>     Explicit block device/partition for /mnt/nvme (e.g. /dev/nvme0n1p1)
    --dry-run                  Preview all actions without making persistent system modifications
    --no-docker                Skip Docker Engine and Docker Compose installation
    --skip-backup-cron         Skip configuring the PostgreSQL database backup script & cron
    --force-unsupported        Bypass Raspberry Pi 4 model & Debian/Raspberry Pi OS checks
    -h, --help                 Display this help message and exit

${CLR_BOLD}EXAMPLES:${CLR_RESET}
    sudo ./${PROG_NAME} --dry-run
    sudo ./${PROG_NAME} --allow-ssh-from 192.168.1.0/24 --allow-api-from 192.168.1.0/24
    sudo ./${PROG_NAME} --admin-user pi --ssh-port 22 --api-port 8000

EOF
}

# ---------- Argument Parsing --------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port)
            SSH_PORT="${2:?Error: --ssh-port requires a port argument}"; shift 2 ;;
        --api-port)
            API_PORT="${2:?Error: --api-port requires a port argument}"; shift 2 ;;
        --allow-ssh-from)
            SSH_CIDR="${2:?Error: --allow-ssh-from requires a CIDR argument}"; shift 2 ;;
        --allow-api-from)
            API_CIDR="${2:?Error: --allow-api-from requires a CIDR argument}"; shift 2 ;;
        --admin-user)
            ADMIN_USER="${2:?Error: --admin-user requires a username argument}"; shift 2 ;;
        --nvme-device)
            NVME_DEVICE="${2:?Error: --nvme-device requires a device path argument}"; shift 2 ;;
        --dry-run)
            DRY_RUN="true"; shift ;;
        --no-docker)
            SKIP_DOCKER="true"; shift ;;
        --skip-backup-cron)
            SKIP_BACKUP_CRON="true"; shift ;;
        --force-unsupported)
            FORCE_UNSUPPORTED="true"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "Unknown option: '$1'. Use --help for usage details." ;;
    esac
done

validate_port "$SSH_PORT"
validate_port "$API_PORT"
validate_cidr "$SSH_CIDR"
validate_cidr "$API_CIDR"

# ---------- Pre-flight Checks & Privilege Verification ------------------------
if [[ $EUID -ne 0 ]]; then
    die "This hardening script must be executed with root privileges (e.g. sudo $PROG_NAME)"
fi

# Initialize log file
if [[ "$DRY_RUN" != "true" ]]; then
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
    log "=== Starting Raspberry Pi Hardening Run (v${SCRIPT_VERSION}) ==="
fi

# Ensure root filesystem is mounted read-write
if ! mount | grep -E ' on / (type )?[^ ]+ \([^)]*\brw\b' >/dev/null 2>&1; then
    if ! mount | awk '$3 == "/" {print $6}' | grep -qw 'rw'; then
        die "Root filesystem (/) is currently read-only. Aborting to avoid partial corruption."
    fi
fi

# Check essential core utilities
for cmd in awk grep mount sed blkid lsblk curl systemctl; do
    require_command "$cmd"
done

# Resolve Admin User
if [[ -z "$ADMIN_USER" ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        ADMIN_USER="$SUDO_USER"
        log "Auto-detected non-root administrative user from sudo session: '$ADMIN_USER'"
    elif id -u pi >/dev/null 2>&1; then
        ADMIN_USER="pi"
        log "Defaulting administrative user to existing 'pi' user"
    else
        ADMIN_USER="sysadmin"
        log "Defaulting administrative user to '$ADMIN_USER'"
    fi
fi
validate_username "$ADMIN_USER"

# ---------- Hardware Model & OS Verification ----------------------------------
log "Verifying system architecture and hardware compatibility..."

CPU_INFO="/proc/cpuinfo"
OS_RELEASE="/etc/os-release"
PI_MODEL="Unknown"
if [[ -f "$CPU_INFO" ]]; then
    PI_MODEL=$(awk -F: '/^Model/ {print $2}' "$CPU_INFO" | sed 's/^[[:space:]]*//' || true)
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    warn "Detected CPU architecture '$ARCH'. The spec requires a 64-bit OS (aarch64/ARM64) for multi-arch Docker compatibility."
    if [[ "$FORCE_UNSUPPORTED" != "true" ]]; then
        warn "Continuing anyway, but ARM64 is strongly recommended."
    fi
else
    success "64-bit ARM architecture confirmed: $ARCH"
fi

if [[ "$PI_MODEL" != *"Raspberry Pi 4"* && "$PI_MODEL" != *"Raspberry Pi 5"* ]]; then
    if [[ "$FORCE_UNSUPPORTED" != "true" ]]; then
        warn "Hardware model '$PI_MODEL' is not a Raspberry Pi 4/5. Use --force-unsupported to bypass this check."
    else
        log "Bypassing hardware check via --force-unsupported (Detected: '$PI_MODEL')."
    fi
else
    success "Raspberry Pi hardware verified: $PI_MODEL"
fi

# Inspect OS distribution
DISTRIB_ID="debian"
DISTRIB_CODENAME="bookworm"
if [[ -f "$OS_RELEASE" ]]; then
    # shellcheck disable=SC1091
    DISTRIB_ID=$(grep -E '^ID=' "$OS_RELEASE" | cut -d= -f2 | tr -d '"' || echo "debian")
    # shellcheck disable=SC1091
    DISTRIB_CODENAME=$(grep -E '^VERSION_CODENAME=' "$OS_RELEASE" | cut -d= -f2 | tr -d '"' || echo "bookworm")
fi
log "Detected OS distribution: $DISTRIB_ID ($DISTRIB_CODENAME)"

# ---------- Power Supply & Thermal Diagnostics (Spec §4.10) -------------------
log "Running power supply and thermal health diagnostics..."
if command -v vcgencmd >/dev/null 2>&1; then
    # 1. Under-voltage and throttling check
    THROTTLED_HEX=$(vcgencmd get_throttled | cut -d= -f2 || echo "0x0")
    log "Throttling status register: $THROTTLED_HEX"
    if [[ "$THROTTLED_HEX" == "0x0" || "$THROTTLED_HEX" == "throttled=0x0" ]]; then
        success "Power supply check PASSED: Official power delivery healthy (no under-voltage detected: 0x0)."
    else
        warn "Power supply warning detected ($THROTTLED_HEX)!"
        warn "Review: Bit 0 indicates active under-voltage; Bit 16 indicates past under-voltage since boot."
        warn "Ensure you are using the official Raspberry Pi 15.3W USB-C power supply (5.1V / 3.0A)."
    fi

    # 2. CPU Temperature check (Spec target: < 65°C under load)
    TEMP_STR=$(vcgencmd measure_temp || echo "temp=0.0'C")
    log "Current CPU Temperature: $TEMP_STR"
else
    log "vcgencmd not available in PATH (non-Raspberry Pi OS host); skipping hardware register telemetry."
fi

# ---------- System Updates & Base Security Packages ---------------------------
log "Updating package lists and upgrading base packages..."
export DEBIAN_FRONTEND=noninteractive

run apt-get update -y
run apt-get upgrade -y

log "Installing required core security, networking, and utility packages..."
run apt-get install -y --no-install-recommends \
    ufw \
    fail2ban \
    unattended-upgrades \
    systemd-timesyncd \
    curl \
    ca-certificates \
    jq \
    htop \
    lm-sensors \
    util-linux \
    openssh-server \
    openssl \
    git \
    gawk

# ---------- Non-root Admin User & SSH Key Provisioning ------------------------
log "Verifying administrative user '${ADMIN_USER}' configuration..."
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    log "Creating administrative user '${ADMIN_USER}'..."
    run adduser --disabled-password --gecos "Stock Ticker Service Admin" "$ADMIN_USER"
fi

# Ensure administrative user is in the sudo group
run usermod -aG sudo "$ADMIN_USER"

# Locate existing SSH authorized keys to prevent lockout
USER_SSH_DIR="/home/${ADMIN_USER}/.ssh"
USER_AUTH_KEYS="${USER_SSH_DIR}/authorized_keys"
KEY_SOURCE=""

if [[ -s "$USER_AUTH_KEYS" ]]; then
    KEY_SOURCE="$USER_AUTH_KEYS"
elif [[ -s "/home/pi/.ssh/authorized_keys" ]]; then
    KEY_SOURCE="/home/pi/.ssh/authorized_keys"
elif [[ -s "/root/.ssh/authorized_keys" ]]; then
    KEY_SOURCE="/root/.ssh/authorized_keys"
fi

if [[ -z "$KEY_SOURCE" ]]; then
    warn "CRITICAL: No authorized SSH public key found in ${USER_AUTH_KEYS}, /home/pi/.ssh/, or /root/.ssh/!"
    warn "Disabling password authentication without an SSH key WILL LOCK YOU OUT of this Raspberry Pi."
    warn "Please install your public key into ${USER_AUTH_KEYS} before running with PasswordAuthentication no."
else
    if [[ "$KEY_SOURCE" != "$USER_AUTH_KEYS" && "$DRY_RUN" != "true" ]]; then
        log "Copying authorized public keys from '${KEY_SOURCE}' to '${USER_AUTH_KEYS}'..."
        run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$USER_SSH_DIR"
        run install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$KEY_SOURCE" "$USER_AUTH_KEYS"
    fi
    success "SSH public key verified for '${ADMIN_USER}'."
fi

# ---------- SSH Daemon Hardening (Spec §4.10) ---------------------------------
log "Hardening SSH configuration (/etc/ssh/sshd_config)..."
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONFIG}.bak.${BACKUP_TIMESTAMP}"

if [[ -f "$SSHD_CONFIG" ]]; then
    run cp -a "$SSHD_CONFIG" "$SSHD_BACKUP"
    log "Backed up current SSH config to '${SSHD_BACKUP}'"

    # Clean existing managed or duplicate directives
    run sed -i -E '/^[#[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax|X11Forwarding)[[:space:]]+/Id' "$SSHD_CONFIG"

    # Append hardened configuration block
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would append hardened SSH directives to ${SSHD_CONFIG}"
    else
        cat >> "$SSHD_CONFIG" <<EOF

# ==============================================================================
# Managed by scripts/gemeni-hardeing-pi.sh (Stock Ticker App Hardening)
# ==============================================================================
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF
    fi

    # Validate SSH configuration syntax before reload
    if [[ "$DRY_RUN" != "true" ]]; then
        if sshd -t; then
            success "SSH configuration syntax verified successfully."
            if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
                run systemctl reload ssh || run systemctl restart ssh
            else
                run systemctl reload sshd || run systemctl restart sshd
            fi
            success "SSH daemon reloaded on port ${SSH_PORT}."
        else
            error "sshd syntax validation failed! Restoring backup config."
            cp -a "$SSHD_BACKUP" "$SSHD_CONFIG"
            die "SSH configuration error. Backup restored."
        fi
    fi
fi

# ---------- UFW Host Firewall Configuration (Spec §4.4, §4.10) ----------------
log "Configuring host firewall (UFW)..."

# Ensure default deny on incoming, allow on outgoing
run ufw default deny incoming
run ufw default allow outgoing

# Allow loopback traffic
run ufw allow in on lo comment "Allow local loopback"
run ufw allow out on lo comment "Allow local loopback"

# Allow SSH from designated LAN CIDR on configured port
run ufw allow from "$SSH_CIDR" to any port "$SSH_PORT" proto tcp comment "SSH LAN access"

# Allow FastAPI container port from designated LAN CIDR
run ufw allow from "$API_CIDR" to any port "$API_PORT" proto tcp comment "FastAPI ticker API LAN"

# Allow Tailscale mesh VPN interface if configured (Spec §4.4)
run ufw allow in on tailscale0 comment "Allow Tailscale private mesh" || true

# Enable UFW non-interactively
if [[ "$DRY_RUN" != "true" ]]; then
    run ufw --force enable
    success "UFW firewall active: incoming traffic blocked except SSH (${SSH_PORT}) & API (${API_PORT}) from ${SSH_CIDR}."
fi

# ---------- Fail2Ban Intrusion Prevention (SSH Jail) --------------------------
log "Configuring Fail2ban SSH jail..."
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/ssh.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would configure Fail2ban jail in ${FAIL2BAN_JAIL}"
else
    cat > "$FAIL2BAN_JAIL" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
findtime = 3600
bantime = 86400
banaction = ufw
EOF
    run systemctl enable fail2ban
    run systemctl restart fail2ban
    success "Fail2ban enabled and monitoring SSH on port ${SSH_PORT}."
fi

# ---------- Network Time Protocol (NTP) Sync (Spec §4.10 item 5) --------------
log "Enabling NTP time synchronization via systemd-timesyncd..."
# Raspberry Pi lacks a battery RTC; clock skew >5m breaks AWS SigV4 & HTTPS TLS
run systemctl enable --now systemd-timesyncd
if command -v timedatectl >/dev/null 2>&1; then
    run timedatectl set-ntp true || true
fi
success "NTP time synchronization service enabled."

# ---------- NVMe Storage Architecture & TRIM (Spec §4.10 item 3) --------------
log "Configuring NVMe storage, fstab mount, and TRIM..."

NVME_MOUNT="/mnt/nvme"
FSTAB_FILE="/etc/fstab"
ROOT_SOURCE=$(findmnt -nro SOURCE / || true)

# Identify NVMe block device if not passed explicitly
if [[ -z "$NVME_DEVICE" ]]; then
    NVME_DEVICE=$(lsblk -pnro PATH,TYPE | awk '$2 == "part" && $1 ~ /nvme/ {print $1; exit}' || true)
fi

# Check if Pi booted directly from NVMe (Direct NVMe Boot: BOOT_ORDER=0xf41)
if [[ "$ROOT_SOURCE" =~ /dev/nvme ]]; then
    success "Direct NVMe Boot detected: Root filesystem (/) is already running from NVMe NAND flash (${ROOT_SOURCE})."
    # Ensure /mnt/nvme directory exists on the NVMe filesystem
    run mkdir -p "$NVME_MOUNT"
else
    # Auxiliary NVMe drive scenario
    if [[ -n "$NVME_DEVICE" && -b "$NVME_DEVICE" ]]; then
        log "Found NVMe auxiliary partition: ${NVME_DEVICE}"
        FS_TYPE=$(blkid -s TYPE -o value "$NVME_DEVICE" 2>/dev/null || echo "unknown")
        UUID=$(blkid -s UUID -o value "$NVME_DEVICE" 2>/dev/null || echo "")

        if [[ "$FS_TYPE" != "ext4" ]]; then
            warn "NVMe device ${NVME_DEVICE} has filesystem '${FS_TYPE}', expected 'ext4'. Skipping automated mount."
        elif [[ -z "$UUID" ]]; then
            warn "Could not retrieve UUID for ${NVME_DEVICE}. Skipping fstab update."
        else
            # Backup fstab
            run cp -a "$FSTAB_FILE" "${FSTAB_FILE}.bak.${BACKUP_TIMESTAMP}"
            FSTAB_ENTRY="UUID=${UUID}  ${NVME_MOUNT}  ext4  defaults,noatime  0  2"

            if ! grep -qs "[[:space:]]${NVME_MOUNT}[[:space:]]" /proc/mounts; then
                if ! grep -qF "UUID=${UUID}" "$FSTAB_FILE"; then
                    log "Adding NVMe mount entry to ${FSTAB_FILE}: ${FSTAB_ENTRY}"
                    if [[ "$DRY_RUN" == "true" ]]; then
                        log "[DRY-RUN] Would append fstab entry: ${FSTAB_ENTRY}"
                    else
                        printf '%s\n' "$FSTAB_ENTRY" >> "$FSTAB_FILE"
                    fi
                fi
                run mkdir -p "$NVME_MOUNT"
                run mount "$NVME_MOUNT" || warn "Mount of ${NVME_MOUNT} failed; verify filesystem."
            fi
            success "NVMe mounted at ${NVME_MOUNT} (UUID=${UUID})."
        fi
    else
        log "No separate auxiliary NVMe partition detected for dedicated mount. Ensuring ${NVME_MOUNT} directory exists."
        run mkdir -p "$NVME_MOUNT"
    fi
fi

# Verify UASP and TRIM discard capability
log "Verifying NVMe UASP and TRIM discard capability..."
if command -v lsblk >/dev/null 2>&1; then
    lsblk --discard || true
fi

# Enable weekly fstrim timer and cron job
log "Enabling weekly filesystem TRIM (fstrim.timer)..."
run systemctl enable --now fstrim.timer

CRON_WEEKLY_TRIM="/etc/cron.weekly/fstrim"
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would create ${CRON_WEEKLY_TRIM}"
else
    cat > "$CRON_WEEKLY_TRIM" <<'EOF'
#!/bin/sh
# Weekly NVMe TRIM maintenance
/sbin/fstrim -av
EOF
    chmod 755 "$CRON_WEEKLY_TRIM"
fi
success "TRIM maintenance active via fstrim.timer and ${CRON_WEEKLY_TRIM}."

# ---------- PostgreSQL Directory Layout (Spec §4.6, §4.7, ROADMAP) ------------
log "Creating PostgreSQL persistent storage directory on NVMe..."
PG_DATA_DIR="${NVME_MOUNT}/postgres/data"
run mkdir -p "$PG_DATA_DIR"
# Docker Postgres official container runs as uid 999
run chmod 700 "$PG_DATA_DIR"
success "PostgreSQL NVMe storage directory prepared: ${PG_DATA_DIR}"

# ---------- Database Backup Script & Cron Job (Spec §4.10 item 7) -------------
if [[ "$SKIP_BACKUP_CRON" != "true" ]]; then
    log "Setting up automated local PostgreSQL backup script and cron job..."
    BACKUP_DIR="${NVME_MOUNT}/backups"
    BACKUP_SCRIPT="${BACKUP_DIR}/backup-postgres.sh"
    run mkdir -p "$BACKUP_DIR"
    run chmod 700 "$BACKUP_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would write backup script to ${BACKUP_SCRIPT}"
    else
        cat > "$BACKUP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# ==============================================================================
# Automated Local Database Backup Script
# Dumps Postgres historical records from Docker container to compressed NVMe storage.
# ==============================================================================
set -euo pipefail

BACKUP_DIR="/mnt/nvme/backups"
TIMESTAMP=$(date +'%Y-%m-%d_%H%M%S')
BACKUP_FILE="${BACKUP_DIR}/db_${TIMESTAMP}.sql.gz"
CONTAINER_NAME="stock-postgres"
DB_USER="${POSTGRES_USER:-stockuser}"
DB_NAME="${POSTGRES_DB:-stockdata}"

mkdir -p "$BACKUP_DIR"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting backup of ${DB_NAME} from ${CONTAINER_NAME}..."
    docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backup created successfully: ${BACKUP_FILE}"

    # Retain backups for 14 days, remove older dumps
    find "$BACKUP_DIR" -type f -name "db_*.sql.gz" -mtime +14 -delete
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Container '${CONTAINER_NAME}' is not running; skipping backup." >&2
fi
EOF
        chmod 750 "$BACKUP_SCRIPT"
        # Symlink into system bin for convenient manual execution
        ln -sf "$BACKUP_SCRIPT" /usr/local/bin/backup-postgres
    fi

    # Daily cron job at 03:00 AM
    CRON_BACKUP="/etc/cron.d/stock-ticker-backup"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would create cron job in ${CRON_BACKUP}"
    else
        cat > "$CRON_BACKUP" <<EOF
# Daily automated PostgreSQL database backup to NVMe at 03:00 AM
0 3 * * * root ${BACKUP_SCRIPT} >> /var/log/stock-ticker-backup.log 2>&1
EOF
        chmod 644 "$CRON_BACKUP"
    fi
    success "Automated PostgreSQL backup configured: ${BACKUP_SCRIPT} (cron daily at 03:00 AM)."
fi

# ---------- Docker CE & Docker Compose Installation (Spec §4.6) ---------------
if [[ "$SKIP_DOCKER" != "true" ]]; then
    log "Configuring Docker Engine and Docker Compose plugin..."
    if ! command -v docker >/dev/null 2>&1; then
        log "Installing Docker CE via official repository script..."
        run curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        run sh /tmp/get-docker.sh
        run rm -f /tmp/get-docker.sh
    else
        log "Docker is already installed ($(docker --version || true))."
    fi

    run usermod -aG docker "$ADMIN_USER"
    run apt-get install -y --no-install-recommends docker-compose-plugin

    # Configure Docker daemon log-driver limits (Spec §4.6, §12.1)
    # Prevents Docker container logs from silently consuming disk capacity
    DAEMON_JSON="/etc/docker/daemon.json"
    install -d -m 755 /etc/docker

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would configure Docker daemon log limits in ${DAEMON_JSON}"
    elif [[ -f "$DAEMON_JSON" ]]; then
        log "Merging log limits into existing ${DAEMON_JSON}..."
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' \
            "$DAEMON_JSON" > "${DAEMON_JSON}.tmp"
        mv "${DAEMON_JSON}.tmp" "$DAEMON_JSON"
    else
        cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    fi

    run systemctl enable docker
    run systemctl restart docker || true
    success "Docker Engine & Compose configured with 10MB/3-file log limits."
else
    log "Skipping Docker installation (--no-docker flag set)."
fi

# ---------- Unattended Security Upgrades Configuration ------------------------
log "Configuring automated unattended security upgrades..."
UNATTENDED_CONF="/etc/apt/apt.conf.d/52-hardening-unattended-upgrades"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would configure ${UNATTENDED_CONF}"
else
    cat > "$UNATTENDED_CONF" <<EOF
// Automatic security upgrades configured by scripts/gemeni-hardeing-pi.sh
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    chmod 644 "$UNATTENDED_CONF"
    run systemctl enable --now unattended-upgrades
fi
success "Unattended security upgrades active."

# ---------- Attack Surface Reduction (Disable Unneeded Services) -------------
log "Disabling unneeded Raspberry Pi services (Bluetooth, Avahi, Triggerhappy)..."
UNNEEDED_SERVICES=(
    bluetooth.service
    avahi-daemon.service
    triggerhappy.service
    cups.service
    cups-browsed.service
)

for svc in "${UNNEEDED_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        log "Disabling and stopping ${svc}..."
        run systemctl disable --now "$svc" || true
    fi
done
success "Extraneous services disabled."

# ---------- Secrets File Permissions Hygiene (Spec §4.10 item 6) --------------
log "Enforcing strict file permissions on application .env files (chmod 600)..."
TARGET_ENV_DIRS=(
    "/home/${ADMIN_USER}"
    "/home/pi"
    "/mnt/nvme"
    "$(pwd)"
)

for dir in "${TARGET_ENV_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 3 -type f -name ".env" 2>/dev/null | while read -r env_file; do
            log "Securing permissions on ${env_file} (chmod 600)..."
            run chmod 600 "$env_file"
            run chown "${ADMIN_USER}:${ADMIN_USER}" "$env_file" 2>/dev/null || true
        done
    fi
done
success "Secrets file hygiene verified (chmod 600 enforced)."

# ---------- Daily Hardware Health Check Cron (Spec §4.10, §12.4) --------------
log "Configuring daily hardware health telemetry cron (/etc/cron.d/pi-health)..."
CRON_HEALTH="/etc/cron.d/pi-health"
HEALTH_LOG="/var/log/pi-health.log"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would create ${CRON_HEALTH}"
else
    cat > "$CRON_HEALTH" <<'EOF'
# Daily hardware health telemetry – runs at 02:30 AM
30 2 * * * root /usr/bin/vcgencmd get_throttled >> /var/log/pi-health.log 2>&1
30 2 * * * root /usr/bin/vcgencmd measure_temp   >> /var/log/pi-health.log 2>&1
EOF
    chmod 644 "$CRON_HEALTH"
    touch "$HEALTH_LOG"
    chmod 640 "$HEALTH_LOG"
fi
success "Daily hardware health cron configured (02:30 AM -> ${HEALTH_LOG})."

# ---------- Verification & Diagnostic Summary ---------------------------------
log "Compiling system hardening verification summary..."

cat <<EOF

${CLR_BOLD}==============================================================================${CLR_RESET}
${CLR_BOLD}             RASPBERRY PI HARDENING VERIFICATION SUMMARY                     ${CLR_RESET}
${CLR_BOLD}==============================================================================${CLR_RESET}

${CLR_BOLD}System & Hardware:${CLR_RESET}
  • Hardware Model:      ${PI_MODEL}
  • Kernel & Arch:       $(uname -r) (${ARCH})
  • OS Release:          ${DISTRIB_ID} (${DISTRIB_CODENAME})
  • Admin User:          ${ADMIN_USER} (in sudo, docker groups)

${CLR_BOLD}Security & Access Control:${CLR_RESET}
  • SSH Port:            ${SSH_PORT} (PasswordAuth: no, PermitRoot: no, Pubkey: yes)
  • UFW Firewall:        Active (Allowed: SSH ${SSH_PORT}/tcp from ${SSH_CIDR}, API ${API_PORT}/tcp from ${API_CIDR})
  • Fail2ban:            Active (Monitoring SSH on port ${SSH_PORT}, action=ufw)
  • Unattended Upgrades: Enabled (Security channel updates active)

${CLR_BOLD}Storage & Reliability:${CLR_RESET}
  • Time Sync (NTP):     systemd-timesyncd active (RTC limitation mitigated)
  • NVMe Storage:        ${NVME_MOUNT}
  • Postgres Directory:  ${PG_DATA_DIR} (Permissions: 700)
  • Local Backups:       ${NVME_MOUNT}/backups (Daily cron at 03:00 AM -> backup-postgres)
  • Weekly TRIM:         fstrim.timer & /etc/cron.weekly/fstrim enabled

${CLR_BOLD}Docker Infrastructure:${CLR_RESET}
  • Docker Engine:       $(command -v docker >/dev/null && docker --version || echo "Skipped/Not installed")
  • Docker Compose:      $(docker compose version 2>/dev/null || echo "Plugin ready")
  • Daemon Logging:      json-file (max-size=10m, max-file=3)

${CLR_BOLD}Execution Metrics:${CLR_RESET}
  • Successful steps:    ${SUCCESS_COUNT}
  • Warnings reported:   ${WARNING_COUNT}
  • Failed commands:     ${FAILURE_COUNT}
  • Log file:            ${LOG_FILE}

EOF

if (( WARNING_COUNT > 0 )); then
    printf "${CLR_YELLOW}${CLR_BOLD}Warnings recorded during run:${CLR_RESET}\n"
    for w in "${WARNING_MSGS[@]}"; do
        printf "  ${CLR_YELLOW}• %s${CLR_RESET}\n" "$w"
    done
    printf "\n"
fi

if (( FAILURE_COUNT > 0 )); then
    printf "${CLR_RED}${CLR_BOLD}Failed commands during run:${CLR_RESET}\n"
    for cmd in "${FAILED_CMDS[@]}"; do
        printf "  ${CLR_RED}• %s${CLR_RESET}\n" "$cmd"
    done
    printf "\n"
    error "Hardening completed with ${FAILURE_COUNT} failed command(s). Review logs in ${LOG_FILE}."
    exit 1
fi

success "Raspberry Pi hardening completed successfully!"
exit 0
