#!/usr/bin/env bash

# ---------------------------------------------------------------
# hardening-pi.sh – Raspberry Pi OS (64‑bit) hardening & setup
# ---------------------------------------------------------------
# Idempotent script designed for automated execution (CI/CD, provisioning).
# Inspired by `hardening.sh` and `harden-droplet.sh`.
# ---------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Version ------------------------------------------------
declare -r VERSION="1.0.0"

# ---------- Helper functions --------------------------------------
log()   { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
error() { printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
 die()   { error "$*"; exit 1; }

on_error() {
    local rc=$?
    error "Failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
    exit "$rc"
}
trap on_error ERR

# ---------- Command verification -----------------------------------
require_commands() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

# ---------- Defaults ----------------------------------------------
declare -r PROG_NAME="${0##*/}"
declare -i SUCCESS_COUNT=0 FAILURE_COUNT=0
declare -a FAILED_CMDS=()

declare SSH_PORT=2222                # SSH listening port (changed from 22 to 2222)
declare API_PORT=8000                # API container port
declare SSH_CIDR="192.168.0.0/16"     # CIDR allowed to SSH (local LAN)
declare API_CIDR="192.168.0.0/16"     # CIDR allowed to reach API
declare ADMIN_USER="sysadmin"        # Non‑root admin user (will be whitelisted in AllowUsers)
declare NVME_DEVICE=""               # Optional NVMe device (e.g. /dev/nvme0n1p2)
declare DRY_RUN="false"              # Set to "true" for preview only
declare SKIP_DOCKER="false"          # Skip Docker installation
declare SKIP_FSTRIM="false"          # Skip enabling weekly fstrim (keep false for default)
declare FORCE_UNSUPPORTED="false"    # Bypass Pi‑model / OS checks

# ---------- Argument parsing ---------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --ssh-port)          SSH_PORT="${2:?missing value}"; shift 2;;
        --api-port)          API_PORT="${2:?missing value}"; shift 2;;
        --allow-ssh-from)    SSH_CIDR="${2:?missing value}"; shift 2;;
        --allow-api-from)    API_CIDR="${2:?missing value}"; shift 2;;
        --admin-user)        ADMIN_USER="${2:?missing value}"; shift 2;;
        --nvme-device)       NVME_DEVICE="${2:?missing value}"; shift 2;;
        --dry-run)           DRY_RUN="true"; shift;;
        --no-docker)         SKIP_DOCKER="true"; shift;;
        --force-unsupported) FORCE_UNSUPPORTED="true"; shift;;
        -h|--help)
            cat <<'EOF'
Usage: $PROG_NAME [options]
  --ssh-port <port>          SSH port (default: 2222)
  --api-port <port>          API container port (default: 8000)
  --allow-ssh-from <cidr>    CIDR allowed to SSH (default: 192.168.0.0/16)
  --allow-api-from <cidr>    CIDR allowed to reach API (default: 192.168.0.0/16)
  --admin-user <name>        Non‑root admin user (default: sysadmin)
  --nvme-device <device>     NVMe device to mount (optional)
  --dry-run                  Preview actions without applying them
  --no-docker                Skip Docker installation
  --force-unsupported        Bypass Pi‑model / OS checks
  -h, --help                 Show this help and exit
EOF
            exit 0;;
        *) error "Unknown option: $1"; exit 1;;
    esac
done

# ---------- Validation helpers ------------------------------------
validate_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )) || die "Invalid port: $1"; }
validate_cidr() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "Invalid CIDR: $1"; }

validate_port "$SSH_PORT"; validate_port "$API_PORT"
validate_cidr "$SSH_CIDR"; validate_cidr "$API_CIDR"
[[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid admin username: $ADMIN_USER"

# ---------- Root check -------------------------------------------
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (e.g. sudo $PROG_NAME)"
fi

# ---------- Required commands -------------------------------------
require_commands awk grep mount sed apt-get systemctl ufw curl jq

# ---------- run helper (dry‑run aware) ----------------------------
run() {
    if [[ $DRY_RUN == "true" ]]; then
        log "[DRY‑RUN] $*"
        ((SUCCESS_COUNT++))
    else
        log "Executing: $*"
        if "$@"; then
            ((SUCCESS_COUNT++))
        else
            log "FAILURE: $*"
            ((FAILURE_COUNT++))
            FAILED_CMDS+=("$(printf '%q ' "$@")")
            return 1
        fi
    fi
}

# ---------- System update & upgrade ------------------------------
run apt-get update -y
run apt-get upgrade -y

# ---------- Core package installation ----------------------------
run apt-get install -y --no-install-recommends \
    wpasupplicant netplan.io git python3 python3-pip openssl \
    iptables-persistent htop lm-sensors curl ca-certificates \
    openssh-server ufw fail2ban unattended-upgrades jq gawk util-linux

# ---------- Admin user & SSH key --------------------------------
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    run adduser --disabled-password --gecos "" "$ADMIN_USER"
fi
# Abort if no key is present for the new admin
if [[ ! -s "/home/pi/.ssh/authorized_keys" && ! -s "/home/$ADMIN_USER/.ssh/authorized_keys" ]]; then
    die "No authorized SSH key found for $ADMIN_USER; aborting"
fi
if [[ ! -s "/home/$ADMIN_USER/.ssh/authorized_keys" && $DRY_RUN != "true" ]]; then
    run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
    run install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" \
        "/home/pi/.ssh/authorized_keys" "/home/$ADMIN_USER/.ssh/authorized_keys"
fi
run usermod -aG sudo "$ADMIN_USER"

# ---------- Firewall (ufw) – must precede SSH reload ------------
run ufw default deny incoming
run ufw default allow outgoing

# Allow SSH from the defined LAN CIDR and also from localhost (prevents lock‑out during reload)
run ufw allow from "$SSH_CIDR" to any port "$SSH_PORT" proto tcp
run ufw allow from "127.0.0.1" to any port "$SSH_PORT" proto tcp
run ufw allow from "$API_CIDR" to any port "$API_PORT" proto tcp
if ufw status | grep -q '^Status: inactive'; then
    run ufw --force enable
fi

# ---------- SSH hardening ----------------------------------------
SSHD_CONF="/etc/ssh/sshd_config"
run cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
# Remove previously managed directives
run sed -i -E '/^[#[:space:]]*Port[[:space:]]+/d' "$SSHD_CONF"
run sed -i -E '/^[#[:space:]]*PermitRootLogin[[:space:]]+/d' "$SSHD_CONF"
run sed -i -E '/^[#[:space:]]*PasswordAuthentication[[:space:]]+/d' "$SSHD_CONF"
run sed -i -E '/^[#[:space:]]*PubkeyAuthentication[[:space:]]+/d' "$SSHD_CONF"
run sed -i -E '/^[#[:space:]]*AllowUsers[[:space:]]+/d' "$SSHD_CONF"
if [[ $DRY_RUN == "true" ]]; then
    log "[DRY‑RUN] would append SSH settings to $SSHD_CONF"
else
    printf '\n# Managed by %s\nPort %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\n' \
        "$PROG_NAME" "$SSH_PORT" "$ADMIN_USER" >> "$SSHD_CONF"
fi
# Verify that the SSH daemon configuration is valid before reloading.
# If validation fails we restore the backup and abort, preventing a broken sshd.
run sshd -t || { cp "${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)" "$SSHD_CONF"; die "Invalid SSH config – backup restored"; }
# Reload SSH daemon
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run systemctl reload ssh
else
    run systemctl reload sshd
fi
# Verify connectivity before we finish (best‑effort)
if ! nc -z localhost "$SSH_PORT" >/dev/null 2>&1; then
    log "Warning: SSH port $SSH_PORT does not appear reachable locally"
fi

# ---------- Fail2Ban (SSH jail) ---------------------------------
if [[ $DRY_RUN == "true" ]]; then
    log "[DRY‑RUN] would write /etc/fail2ban/jail.d/ssh.conf (port $SSH_PORT)"
else
    # Add a temporary fail2ban whitelist for the current IP (prevents accidental ban during first login)
# The script resolves the outward IP at runtime; if it cannot be determined the line is omitted.
CURRENT_IP=$(curl -s https://ifconfig.me || true)
if [[ -n "$CURRENT_IP" ]]; then
    # Insert ignoreip into the jail config before creating/restarting the service
    FAIL2BAN_CONF="/etc/fail2ban/jail.d/ssh.conf"
    if grep -q "ignoreip" "$FAIL2BAN_CONF"; then
        # Append to existing ignoreip line
        sed -i -E "s/(ignoreip[[:space:]]*=[[:space:]]*)/\1$CURRENT_IP,/" "$FAIL2BAN_CONF"
    else
        # Add a new ignoreip line after the [sshd] header
        sed -i "/\[sshd\]/a ignoreip = $CURRENT_IP" "$FAIL2BAN_CONF"
    fi
fi
fi
run systemctl restart fail2ban

# ---------- Unattended upgrades -----------------------------------
if [[ $DRY_RUN == "true" ]]; then
    log "[DRY‑RUN] configure unattended security upgrades for $DISTRIB_ID:$DISTRIB_CODENAME"
else
    cat > /etc/apt/apt.conf.d/52-hardening-unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${DISTRIB_ID}:${DISTRIB_CODENAME}-security";
};
EOF
    apt-get -o DPkg::Options::=--force-confold -s upgrade >/dev/null
fi
run systemctl enable --now unattended-upgrades

# ---------- Disable unneeded services ----------------------------
for svc in avahi-daemon bluetooth triggerhappy; do
    if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc"; then
        run systemctl disable --now "$svc"
    fi
done

# ---------- Enable NTP -------------------------------------------
run systemctl enable --now systemd-timesyncd

# ---------- NVMe mount & weekly fstrim ---------------------------
if [[ -z "$NVME_DEVICE" ]]; then
    NVME_DEVICE=$(lsblk -pnro PATH,TYPE | awk '$2 == "part" && $1 ~ /nvme/ {print $1; exit}')
fi
if [[ -n "$NVME_DEVICE" ]]; then
    [[ -b "$NVME_DEVICE" ]] || die "NVMe device $NVME_DEVICE is not a block device"
    ROOT_SOURCE=$(findmnt -nro SOURCE /)
    [[ "$NVME_DEVICE" != "$ROOT_SOURCE" ]] || die "NVMe device is the root filesystem"
    MOUNTPOINT="/mnt/nvme"
    UUID=$(blkid -s UUID -o value "$NVME_DEVICE")
    [[ $(blkid -s TYPE -o value "$NVME_DEVICE") == "ext4" ]] || die "NVMe $NVME_DEVICE is not ext4"
    if ! grep -qs "[[:space:]]${MOUNTPOINT}[[:space:]]" /proc/mounts; then
        if ! grep -qF "UUID=$UUID" /etc/fstab; then
            printf 'UUID=%s  %s  ext4  defaults,noatime  0  2\n' "$UUID" "$MOUNTPOINT" >> /etc/fstab
        fi
        run mkdir -p "$MOUNTPOINT"
        run mount "$MOUNTPOINT"
    fi
    if [[ $SKIP_FSTRIM != "true" && -n "$NVME_DEVICE" ]]; then
    run systemctl enable --now fstrim.timer
fi
fi

# ---------- Docker (optional) -------------------------------------
if [[ $SKIP_DOCKER != "true" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        run curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        run sh /tmp/get-docker.sh
        run rm -f /tmp/get-docker.sh
    fi
    run usermod -aG docker "$ADMIN_USER"
    run apt-get install -y docker-compose-plugin
    # Docker daemon logging limits
    DAEMON_CONF="/etc/docker/daemon.json"
    if [[ -f $DAEMON_CONF ]]; then
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$DAEMON_CONF" > "${DAEMON_CONF}.tmp"
        run mv "${DAEMON_CONF}.tmp" "$DAEMON_CONF"
    else
        install -d -m 755 /etc/docker
        cat > "$DAEMON_CONF" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    fi
    run systemctl enable --now docker
    run systemctl restart docker
fi

# ---------- Secure .env files -------------------------------------
for env_file in "/home/$ADMIN_USER/.env" "/home/pi/.env"; do
    [[ -f $env_file ]] && run chmod 600 "$env_file"
    done

# ---------- Hardware health cron ---------------------------------
if [[ $DRY_RUN == "true" ]]; then
    log "[DRY‑RUN] would create /etc/cron.d/pi-health"
else
    cat >/etc/cron.d/pi-health <<'EOF'
# Daily hardware‑health logging – 02:30
30 2 * * * root /usr/bin/vcgencmd get_throttled >> /var/log/pi-health.log 2>&1
30 2 * * * root /usr/bin/vcgencmd measure_temp   >> /var/log/pi-health.log 2>&1
EOF
    run chmod 644 /etc/cron.d/pi-health
    run touch /var/log/pi-health.log
    run chmod 640 /var/log/pi-health.log
fi

# ---------- Verification summary ---------------------------------
log "=== Verification Summary ==="
run ufw status verbose
if command -v docker >/dev/null 2>&1; then
    run docker info
fi
run systemctl is-active fail2ban
run grep -E '^(Port|PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|AllowUsers) ' "$SSHD_CONF"
log "=== Execution Summary ==="
log "Successful commands: $SUCCESS_COUNT"
log "Failed commands: $FAILURE_COUNT"
if (( FAILURE_COUNT > 0 )); then
    log "Failed command list:"
    for cmd in "${FAILED_CMDS[@]}"; do
        log "  - $cmd"
    done
fi
log "Hardening script completed – version $VERSION"
