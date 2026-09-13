#!/usr/bin/env bash
# ----------------------------------------------------------------------
# hardening.sh – Raspberry Pi OS (64-bit) hardening & initial setup
# ----------------------------------------------------------------------
# Features (all idempotent):
#   • System update & upgrade
#   • SSH: key-only, root login disabled
#   • ufw firewall: allow SSH from a configurable CIDR, allow API port
#   • Fail2Ban (SSH jail)
#   • Unattended security upgrades
#   • Disable unneeded services (Bluetooth, Avahi, triggerhappy)
#   • Enable NTP (systemd-timesyncd)
#   • NVMe mount detection + weekly fstrim
#   • Docker CE + Docker-Compose v2 (optional skip)
#   • Docker daemon JSON-file logging limits
#   • Secure permissions for /home/pi/.env
#   • Daily hardware-health cron (throttling & temperature)
#   • Dry-run mode for preview
# ----------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# ---------------------------  Helpers  ------------------------------
log()    { printf '[%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*"; }
error()  { printf '[%s] ERROR: %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*" >&2; }
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] $*"
    else
        log "Executing: $*"
        "$@"
    fi
}
ensure_line_in_file() {
    local file=$1 regex=$2 line=$3
    if grep -qE "$regex" "$file"; then
        sed -i -E "s|$regex.*|$line|" "$file"
    else
        echo "$line" >>"$file"
    fi
}

# ---------------------------  Defaults  ----------------------------
declare -r PROG_NAME="${0##*/}"
declare API_PORT=8000                 # Port the API container will expose
declare SSH_CIDR="192.168.0.0/16"     # Allowed CIDR for SSH
declare DRY_RUN="false"
declare SKIP_DOCKER="false"

# ---------------------------  Parse args  ---------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-port)        API_PORT="${2:?missing value}"; shift 2 ;;
        --allow-ssh-from)  SSH_CIDR="${2:?missing value}"; shift 2 ;;
        --dry-run)         DRY_RUN="true"; shift ;;
        --no-docker)       SKIP_DOCKER="true"; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: $PROG_NAME [options]

  --api-port <port>          Port to open for the API (default: 8000)
  --allow-ssh-from <cidr>    CIDR range allowed to SSH (default: 192.168.0.0/16)
  --dry-run                  Show actions without executing them
  --no-docker                Skip Docker installation
  -h, --help                 Show this help
EOF
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------  Root check  ---------------------------
if [[ $EUID -ne 0 ]]; then
    error "Run the script as root (e.g. sudo $PROG_NAME)"
    exit 1
fi

# Ensure the root filesystem is mounted read‑write (required for config changes)
if ! mount | grep ' / ' | grep -q '\brw\b'; then
    error "Root filesystem is read‑only – aborting to avoid partial changes."
    exit 1
fi

# Back up fstab before any modification (use timestamped backup)
cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
# ---------------------------  Update system  ----------------------
run apt-get update -y
run apt-get upgrade -y

# ---------------------------  SSH hardening  ----------------------
SSHD_CONF="/etc/ssh/sshd_config"
# Remove any existing global PasswordAuthentication / PermitRootLogin lines (avoid affecting Match blocks)
sed -i '/^PasswordAuthentication /d' "$SSHD_CONF"
sed -i '/^PermitRootLogin /d' "$SSHD_CONF"
# Append the hardened settings at the end of the file
printf '\nPasswordAuthentication no\nPermitRootLogin no\n' >>"$SSHD_CONF"
run systemctl restart ssh
# Prevent password login for the pi account
run passwd -l pi >/dev/null 2>&1 || true

# ---------------------------  Firewall (ufw)  --------------------
run apt-get install -y ufw
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow from "$SSH_CIDR" to any port 22 proto tcp
run ufw allow "${API_PORT}/tcp"
if ufw status | grep -q inactive; then
    run ufw --force enable
fi

# ---------------------------  Fail2Ban (SSH jail)  -----------------
run apt-get install -y fail2ban
cat >/etc/fail2ban/jail.d/ssh.conf <<'EOF'
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
maxretry = 5
bantime = 3600
EOF
run systemctl restart fail2ban

# ---------------------------  Unattended upgrades  -----------------
run apt-get install -y unattended-upgrades
# Enable security-only upgrades (Bullseye/Bookworm)
sed -i 's|//"${distro_id}:${distro_codename}-security";|"${distro_id}:${distro_codename}-security";|g' \
    /etc/apt/apt.conf.d/50unattended-upgrades
run systemctl enable --now unattended-upgrades

# ---------------------------  Disable unneeded services ----------
DISABLE_SERVICES=(
    avahi-daemon
    bluetooth
    triggerhappy
)
for svc in "${DISABLE_SERVICES[@]}"; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        log "Disabling $svc"
        run systemctl disable --now "$svc"
    fi
done

# ---------------------------  NTP sync  ---------------------------
run systemctl enable --now systemd-timesyncd

# ---------------------------  NVMe mount & TRIM  -----------------
NVME_DEVICE=$(lsblk -o NAME,TYPE -dn | grep -E '^nvme' | head -n1 || true)
if [[ -n "$NVME_DEVICE" ]]; then
    MOUNTPOINT="/mnt/nvme"
    # Use UUID for a stable fstab entry (prevents breakage if device name changes)
    UUID=$(blkid -s UUID -o value "/dev/$NVME_DEVICE" 2>/dev/null || true)
    if [[ -n "$UUID" ]]; then
        FSTAB_LINE="UUID=$UUID  $MOUNTPOINT  ext4  defaults,noatime  0  2"
    else
        FSTAB_LINE="/dev/$NVME_DEVICE  $MOUNTPOINT  ext4  defaults,noatime  0  2"
    fi
    if ! grep -qs "$MOUNTPOINT" /proc/mounts; then
        if ! grep -q "$MOUNTPOINT" /etc/fstab; then
            echo "$FSTAB_LINE" >>/etc/fstab
        fi
        run mkdir -p "$MOUNTPOINT"
        run mount "$MOUNTPOINT"
    fi
    run systemctl enable --now fstrim.timer
else
    log "NVMe device not detected – skipping mount / TRIM steps"
fi

# ---------------------------  Docker (optional)  -----------------
if [[ "$SKIP_DOCKER" != "true" ]]; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    run sh /tmp/get-docker.sh
    # Add the default pi user to the docker group
    run usermod -aG docker pi
    # Install Docker Compose v2 plugin (Debian/Ubuntu package)
    run apt-get install -y docker-compose-plugin
    # Configure Docker daemon JSON-file logging limits (merge with existing if present)
    DOCKER_DAEMON_CONF="/etc/docker/daemon.json"
    if [[ -f "$DOCKER_DAEMON_CONF" ]]; then
        # Use jq (install if missing) to merge new logging options
        if ! command -v jq >/dev/null 2>&1; then
            run apt-get install -y jq
        fi
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$DOCKER_DAEMON_CONF" >"$DOCKER_DAEMON_CONF.tmp" && mv "$DOCKER_DAEMON_CONF.tmp" "$DOCKER_DAEMON_CONF"
    else
        cat >"$DOCKER_DAEMON_CONF" <<'EOF2'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF2
    fi
    run systemctl restart docker
else
    log "--no-docker flag set – Docker installation skipped"
fi

# ---------------------------  Secrets file perms  -----------------
if [[ -f /home/pi/.env ]]; then
    run chmod 600 /home/pi/.env
fi

# ---------------------------  Hardware health cron  -------------
cat >/etc/cron.d/pi-health <<'EOF'
# Daily hardware-health logging – 02:30
30 2 * * * root /usr/bin/vcgencmd get_throttled >> /var/log/pi-health.log 2>&1
30 2 * * * root /usr/bin/vcgencmd measure_temp   >> /var/log/pi-health.log 2>&1
EOF

# ---------------------------  Summary verification  -------------
log "=== Verification Summary ==="
run ufw status verbose
if command -v docker >/dev/null 2>&1; then
    run docker info | grep -E 'Storage Driver|Logging Driver'
fi
run systemctl status fail2ban | head -n 10
run grep -E 'PasswordAuthentication|PermitRootLogin' /etc/ssh/sshd_config

log "Hardening script completed."
