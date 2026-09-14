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

set -u -o pipefail
IFS=$'\n\t'

# ---------------------------  Helpers  ------------------------------
log()    { printf '[%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*"; }
error()  { printf '[%s] ERROR: %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*" >&2; }
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] $*"
        ((SUCCESS_COUNT++))
    else
        log "Executing: $*"
        if "$@"; then
            log "SUCCESS: $*"
            ((SUCCESS_COUNT++))
        else
            log "FAILURE: $*"
            ((FAILURE_COUNT++))
            FAILED_CMDS+=("$*")
        fi
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
declare -i SUCCESS_COUNT=0
declare -i FAILURE_COUNT=0
declare -a FAILED_CMDS=()
declare SSH_PORT=2222
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
# ---------------------------  Environment validation ----------------------------
# Ensure we are running on Raspberry Pi 4 with Debian trixie
PI_MODEL=$(awk -F: '/^Model/ {print $2}' /proc/cpuinfo | xargs)
if [[ "$PI_MODEL" != *"Raspberry Pi 4"* ]]; then
    log "Warning: Detected model '$PI_MODEL' – script is intended for Raspberry Pi 4."
fi
OS_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
if [[ "$OS_CODENAME" != "trixie" ]]; then
    log "Warning: Detected OS codename '$OS_CODENAME' – script is intended for Debian trixie."
fi
# Set distribution identifiers for unattended-upgrades configuration
DISTRIB_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
DISTRIB_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
# Export variables expected by the sed replacement later
export distro_id="$DISTRIB_ID"
export distro_codename="$DISTRIB_CODENAME"



run apt-get update -y
# Install prerequisite packages required by the project

# Install prerequisite packages required by the project
run apt-get install -y wpasupplicant netplan.io

run apt-get install -y git
run apt-get install -y python3 python3-pip
run apt-get install -y openssl
run apt-get install -y iptables-persistent
run apt-get install -y htop lm-sensors
run apt-get install -y postfix

# ---------------------------  SSH hardening  ----------------------
SSHD_CONF="/etc/ssh/sshd_config"
# Change SSH port
run sed -i '/^Port 22$/d' "$SSHD_CONF"   # remove any old explicit Port 22 line
run sed -i "s/^#Port .*/Port $SSH_PORT/" "$SSHD_CONF"
# Ensure the port line exists (in case it was missing)
run grep -q "^Port $SSH_PORT" "$SSHD_CONF" || run echo "Port $SSH_PORT" >> "$SSHD_CONF"
# Remove any existing global PasswordAuthentication / PermitRootLogin lines (avoid affecting Match blocks)
sed -i '/^PasswordAuthentication /d' "$SSHD_CONF"
sed -i '/^PermitRootLogin /d' "$SSHD_CONF"
# Append the hardened settings at the end of the file
printf '\nPasswordAuthentication no\nPermitRootLogin no\n' >>"$SSHD_CONF"
run systemctl restart ssh
# Prevent password login for the pi account
run passwd -l pi >/dev/null 2>&1 || true

# ----------------------------------------------------------------------
# Create a non‑root admin user that reuses the existing SSH public key
# ----------------------------------------------------------------------
# Define the name of the admin user (adjust if you prefer a different name)
NEW_ADMIN_USER="sysadmin"
# Create the user if it does not already exist (no password, no interactive prompt)
if ! id -u "$NEW_ADMIN_USER" >/dev/null 2>&1; then
    run adduser --disabled-password --gecos "" "$NEW_ADMIN_USER"
    # Copy the authorized_keys from the existing 'pi' account (the boot account)
    if [ -f "/home/pi/.ssh/authorized_keys" ]; then
        run mkdir -p "/home/$NEW_ADMIN_USER/.ssh"
        run cp "/home/pi/.ssh/authorized_keys" "/home/$NEW_ADMIN_USER/.ssh/"
        run chown -R "$NEW_ADMIN_USER:$NEW_ADMIN_USER" "/home/$NEW_ADMIN_USER/.ssh"
        run chmod 700 "/home/$NEW_ADMIN_USER/.ssh"
        run chmod 600 "/home/$NEW_ADMIN_USER/.ssh/authorized_keys"
    fi
    # Grant sudo privileges (allows admin actions without full root login)
    run usermod -aG sudo "$NEW_ADMIN_USER"
    # Also add the new admin to the docker group (so it can manage containers)
    # Deferred addition to docker group until Docker is installed (handled later)
fi

# ---------------------------  Firewall (ufw)  --------------------
run apt-get install -y ufw
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow from "$SSH_CIDR" to any port $SSH_PORT proto tcp
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
sed -i "s|//\"${distro_id}:${distro_codename}-security\";|\"${distro_id}:${distro_codename}-security\";|g" \
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
    # Add the default pi (or sysadmin) user to the docker group – now that Docker is installed
    run usermod -aG docker $NEW_ADMIN_USER
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
log "\n=== Execution Summary ==="
log "Successful commands: $SUCCESS_COUNT"
log "Failed commands: $FAILURE_COUNT"
if (( FAILURE_COUNT > 0 )); then
    log "Failed command list:"
    for cmd in "${FAILED_CMDS[@]}"; do
        log "  - $cmd"
    done
fi
log "Hardening script completed."
