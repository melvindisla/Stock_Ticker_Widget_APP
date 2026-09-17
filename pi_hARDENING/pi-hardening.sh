#!/usr/bin/env bash
# --------------------------------------------------------------
# hardening_and_wifi_setup.sh – Combined system hardening and 8821CU Wi‑Fi driver setup
# --------------------------------------------------------------
# This script performs the Raspberry Pi OS hardening steps (SSH hardening,
# firewall, fail2ban, unattended upgrades, NVMe mount, Docker, etc.) and then
# installs the Realtek 8821CU Wi‑Fi driver, verifies the external antenna, connects
# to the Wi‑Fi network using saved credentials, pings Google for verification, and
# finally disables any internal Wi‑Fi adapters.
# --------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------  Helpers  ------------------------------
log()   { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
error(){ printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

die()   { error "$*"; exit 1; }

on_error() {
    local rc=$?
    error "Failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
    exit $rc
}
trap on_error ERR

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

run_sudo() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY‑RUN] sudo $*"
        ((SUCCESS_COUNT+=1))
    else
        log "Executing with sudo: $*"
        if sudo "$@"; then
            ((SUCCESS_COUNT+=1))
        else
            log "FAILURE (sudo): $*"
            ((FAILURE_COUNT+=1))
            FAILED_CMDS+=("$(printf '%q ' "$@")")
            return 1
        fi
    fi
}

# ---------------------------  Defaults  ----------------------------
wait_for_apt() {
    # Wait until no other process holds the dpkg/apt lock.
    while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \> /dev/null 2\>\&1; do
        log "Waiting for other apt processes to release the lock..."
        sleep 5
done
}

declare -r PROG_NAME="${0##*/}"
declare -i SUCCESS_COUNT=0 FAILURE_COUNT=0
declare -a FAILED_CMDS=()
# Hardening defaults (can be overridden via CLI)
SSH_PORT=2222
API_PORT=8000
SSH_CIDR="192.168.0.0/16"
API_CIDR="192.168.0.0/16"
DRY_RUN="false"
SKIP_DOCKER="false"
FORCE_UNSUPPORTED="false"
TARGET_USER="${SUDO_USER:-$(logname)}"

# ---------------------------  Parse args  ---------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --ssh-port)         SSH_PORT="${2:?missing value}"; shift 2 ;;
        --api-port)         API_PORT="${2:?missing value}"; shift 2 ;;
        --allow-ssh-from)   SSH_CIDR="${2:?missing value}"; shift 2 ;;
        --allow-api-from)   API_CIDR="${2:?missing value}"; shift 2 ;;
        --dry-run)          DRY_RUN="true"; shift ;;
        --no-docker)        SKIP_DOCKER="true"; shift ;;
        --force-unsupported) FORCE_UNSUPPORTED="true"; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: $PROG_NAME [options]

    --ssh-port <port>          SSH port (default: 2222)
    --api-port <port>          API port (default: 8000)
    --allow-ssh-from <cidr>    CIDR range allowed to SSH (default: 192.168.0.0/16)
    --allow-api-from <cidr>    CIDR range allowed to access the API
    --dry-run                  Show actions without executing them
    --no-docker                Skip Docker installation
    --force-unsupported        Continue on non‑Raspberry Pi 4 / non‑Trixie systems
    -h, --help                 Show this help
EOF
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------  Validations ---------------------------
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )) || die "Invalid port: $1"; }
validate_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "Invalid CIDR: $1"; }

validate_port "$SSH_PORT"
validate_port "$API_PORT"
validate_cidr "$SSH_CIDR"
validate_cidr "$API_CIDR"



TARGET_USER="${SUDO_USER:-$(logname)}"



# ---------------------------  Required commands ---------------------------

require_command grep
require_command mount
require_command sed
require_command nmcli
require_command ping
require_command ip
require_command iw
require_command rfkill
require_command lsusb
require_command modprobe
require_command cat


if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry‑run mode: no system changes will be made."
fi

# ---------------------------  Hardening steps (as in hardening.sh) ---------------------------
# Ensure rootfs is writable
if ! mount | grep ' / ' | grep -q '\brw\b'; then
    error "Root filesystem is read‑only – aborting."
    exit 1
fi

run_sudo cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"

# Verify we are on Raspberry Pi 4 & Debian trixie
PI_MODEL=$(awk -F: '/^Model/ {print $2}' /proc/cpuinfo | xargs)
if [[ "$PI_MODEL" != *"Raspberry Pi 4"* ]]; then
    if [[ "$FORCE_UNSUPPORTED" != "true" ]]; then
        die "Detected model '$PI_MODEL'; use --force-unsupported to override"
    fi
    log "Warning: continuing on unsupported model '$PI_MODEL'."
fi
OS_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
if [[ "$OS_CODENAME" != "trixie" ]]; then
    if [[ "$FORCE_UNSUPPORTED" != "true" ]]; then
        die "Detected OS '$OS_CODENAME'; use --force-unsupported to override"
    fi
    log "Warning: continuing on unsupported OS '$OS_CODENAME'."
fi
DISTRIB_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
DISTRIB_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
export DEBIAN_FRONTEND=noninteractive
run_sudo apt-get update
run_sudo apt-get install -y --no-install-recommends \
    wpasupplicant netplan.io git python3 python3-pip openssl \
    htop lm-sensors curl ca-certificates bc \
    openssh-server ufw fail2ban unattended-upgrades jq gawk

# SSH hardening
SSHD_CONF="/etc/ssh/sshd_config"
run_sudo cp -a "$SSHD_CONF" "$SSHD_CONF.bak.$(date +%Y%m%d%H%M%S)"
if [[ ! -s "/home/$TARGET_USER/.ssh/authorized_keys" ]]; then
    die "No authorized SSH key found for $TARGET_USER; aborting"
fi
run_sudo usermod -aG sudo "$TARGET_USER"
# Clean old directives
run_sudo sed -i -E '/^[#[:space:]]*Port[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*PermitRootLogin[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*PasswordAuthentication[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*PubkeyAuthentication[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*AllowUsers[[:space:]]+/d' "$SSHD_CONF"
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] append SSH settings to $SSHD_CONF"
else
    printf '\n# Managed by %s\nPort %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\n' \
        "$PROG_NAME" "$SSH_PORT" "$TARGET_USER" | sudo tee -a "$SSHD_CONF" >/dev/null
fi
# Reload SSH service
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run_sudo systemctl reload ssh
else
    run_sudo systemctl reload sshd
fi

# UFW firewall
run_sudo apt-get install -y --no-install-recommends ufw
run_sudo ufw default deny incoming
run_sudo ufw default allow outgoing
run_sudo ufw allow from "$SSH_CIDR" to any port "$SSH_PORT" proto tcp
run_sudo ufw allow from "$API_CIDR" to any port "$API_PORT" proto tcp
if ufw status | grep -q '^Status: inactive'; then
    run_sudo ufw --force enable
fi

# Fail2Ban (SSH jail)
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] write /etc/fail2ban/jail.d/ssh.conf for port $SSH_PORT"
else
    cat > /etc/fail2ban/jail.d/ssh.conf <<'EOF'
[sshd]
enabled = true
port = $SSH_PORT
logpath = \%(sshd_log)s
maxretry = 5
bantime = 3600
EOF
fi
run_sudo systemctl restart fail2ban

# Unattended upgrades
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] configure unattended upgrades for $DISTRIB_ID:$DISTRIB_CODENAME"
else
    cat >/etc/apt/apt.conf.d/52-hardening-unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "${DISTRIB_ID}:${DISTRIB_CODENAME}-security";
};
EOF
    # Simulate upgrade to verify config (dry‑run)
    apt-get -o DPkg::Options::=--force-confold -s upgrade >/dev/null
fi
run_sudo systemctl enable --now unattended-upgrades

# Disable unneeded services
for svc in avahi-daemon bluetooth triggerhappy; do
    if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc"; then
        run_sudo systemctl disable --now "$svc"
    fi
done

# NTP sync
run_sudo systemctl enable --now systemd-timesyncd


# Docker (optional)
if [[ "$SKIP_DOCKER" != "true" ]]; then

    if ! command -v docker >/dev/null 2>&1; then
        run_sudo curl --fail --silent --show-error --location https://get.docker.com --output /tmp/get-docker.sh
        run_sudo sh /tmp/get-docker.sh
        run_sudo rm -f /tmp/get-docker.sh
    fi
    run_sudo usermod -aG docker "$TARGET_USER"
    DOCKER_DAEMON_CONF="/etc/docker/daemon.json"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY‑RUN] configure Docker log limits in $DOCKER_DAEMON_CONF"
    elif [[ -f "$DOCKER_DAEMON_CONF" ]]; then
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$DOCKER_DAEMON_CONF" >"$DOCKER_DAEMON_CONF.tmp"
        run_sudo cp -a "$DOCKER_DAEMON_CONF" "${DOCKER_DAEMON_CONF}.bak.$(date +%s)"
        run_sudo mv "$DOCKER_DAEMON_CONF.tmp" "$DOCKER_DAEMON_CONF"
    else
        run_sudo install -d -m 755 /etc/docker
        cat >"$DOCKER_DAEMON_CONF" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    fi
    if [[ "$DRY_RUN" != "true" ]]; then
        run_sudo dockerd --validate --config-file="$DOCKER_DAEMON_CONF"
    fi
    run_sudo systemctl enable --now docker
    run_sudo systemctl restart docker
else
    log "--no-docker flag set; Docker installation skipped"
fi

# Secrets file permissions
for env_file in "/home/pi/.env" "/home/$TARGET_USER/.env"; do
    if [[ -f "$env_file" ]]; then
        run_sudo chmod 600 "$env_file"
    fi
done

# Cron health check
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] write /etc/cron.d/pi-health"
else
    cat >/etc/cron.d/pi-health <<'EOF'
# Daily hardware-health logging – 02:30
30 2 * * * root /usr/bin/vcgencmd get_throttled >> /var/log/pi-health.log 2>&1
30 2 * * * root /usr/bin/vcgencmd measure_temp   >> /var/log/pi-health.log 2>&1
EOF
    run_sudo chmod 644 /etc/cron.d/pi-health
    run_sudo touch /var/log/pi-health.log
    run_sudo chmod 640 /var/log/pi-health.log
fi

# ---------------------------  Wi‑Fi driver & adapter setup ---------------------------
# Install build tools required for the driver (already present from hardening, but ensure network‑manager present)
run_sudo apt-get install -y network-manager
run_sudo systemctl enable --now NetworkManager.service

MODULE_CONF="/etc/modules-load.d/8821cu.conf"
if [[ -f "$MODULE_CONF" ]]; then
    log "8821cu driver already installed, skipping clone/build."
else
    DRIVER_DIR="/usr/src/8821cu-20210916"
    log "Cloning 8821CU driver repository..."
    sudo rm -rf "$DRIVER_DIR"
    sudo git clone https://github.com/morrownr/8821cu-20210916.git "$DRIVER_DIR"
    
    log "Building and installing driver via DKMS..."
    cd "$DRIVER_DIR"
    sudo ./install-driver.sh
    # Ensure module loads on boot
    echo "8821cu" | sudo tee "$MODULE_CONF" >/dev/null
fi

# Ensure module loads on boot
MODULE_CONF="/etc/modules-load.d/8821cu.conf"
echo "8821cu" | sudo tee "$MODULE_CONF" >/dev/null

# Helper: antenna detection and interface capture
check_antenna() {
    # Wait for the USB dongle to appear (vendor:product 0bda:8179)
    local timeout=60   # seconds
    local elapsed=0
    while ! lsusb -d 0bda:8179 >/dev/null 2>&1; do
        if (( elapsed >= timeout )); then
            die "Realtek 8821CU USB dongle not detected after waiting $timeout seconds – please ensure it is plugged in"
        fi
        log "Waiting for 8821CU USB dongle to be inserted... ($((timeout-elapsed))s remaining)"
        sleep 5
        ((elapsed+=5))
    done
    USB_ID=$(lsusb -d 0bda:8179 || true)   # Now we know it exists
    sudo modprobe -r 8821cu || true
    sudo modprobe 8821cu
    sleep 1
    IFACE=$(nmcli device status | awk '/8821cu/ {print $1}')
    if [[ -z "$IFACE" ]]; then
        IFACE=$(ls /sys/class/net | grep -E '^wlan[0-9]+' | head -n1)
    fi
    # Capture internal wifi interfaces (do not disable yet)
    EXISTING_IFACES=$(ls /sys/class/net | grep '^wlan' || true)

# Run detection
check_antenna
IFACE=$(cat /tmp/8821cu_iface)

# Bring up external interface
log "Bringing up $IFACE"
sudo ip link set "$IFACE" up

# Connect using saved credentials (wpa_supplicant.conf)
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
SSID=$(awk -F'=' '/ssid=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
PSK=$(awk -F'=' '/psk=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
if [[ -z "$SSID" || -z "$PSK" ]]; then
    die "Could not read SSID/PSK from $WPA_CONF"
fi
log "Creating NetworkManager connection for SSID '$SSID' on $IFACE"
sudo nmcli connection delete "$SSID" >/dev/null 2>&1 || true
sudo nmcli device wifi rescan ifname "$IFACE"
sudo nmcli connection add type wifi ifname "$IFACE" con-name "$SSID" ssid "$SSID" \
    -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK"
sudo nmcli connection up "$SSID"

# Wait for IP
log "Waiting for DHCP lease on $IFACE..."
for i in {1..30}; do
    IP=$(ip -4 addr show "$IFACE" | awk '/inet/ {print $2}')
    [[ -n "$IP" ]] && break
    sleep 1
done
if [[ -z "$IP" ]]; then
    die "Failed to obtain an IP address on $IFACE"
fi
log "Wi‑Fi connected – $IP"

# Verify connectivity via ping
log "Pinging google.com to verify external adapter connectivity..."
if ping -c 3 -I "$IFACE" google.com >/dev/null 2>&1; then
    log "Ping successful – external adapter is working."
    # Disable internal adapters now
    for dev in $EXISTING_IFACES; do
        if [[ "$dev" == "$IFACE" ]]; then continue; fi
        log "Disabling internal Wi‑Fi interface $dev"
        sudo ip link set "$dev" down || true
    done
    sudo rfkill block wifi || true
else
    die "Ping to google.com failed – external adapter may not be functional."
fi

# ---------------------------  Summary verification ---------------------------
log "=== Verification Summary ==="
run_sudo ufw status verbose
if command -v docker >/dev/null 2>&1; then
    run_sudo docker info
fi
run_sudo systemctl is-active fail2ban
run_sudo grep -E '^(Port|PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|AllowUsers) ' "$SSHD_CONF"
log "\n=== Execution Summary ==="
log "Successful commands: $SUCCESS_COUNT"
log "Failed commands: $FAILURE_COUNT"
if (( FAILURE_COUNT > 0 )); then
    log "Failed command list:"
    for cmd in "${FAILED_CMDS[@]}"; do
        log "  - $cmd"
    done
fi
log "Script completed successfully."

exit 0
    if [[ -z "$IFACE" ]]; then
        die "No wlan interface appeared after loading 8821cu."
    fi
    # Antenna check via sysfs if available
    ANT_PATH="/sys/class/net/${IFACE}/device/antenna"
    if [[ -f "$ANT_PATH" ]]; then
        ANT=$(cat "$ANT_PATH")
        if [[ "$ANT" -eq 0 ]]; then
            die "Antenna not detected on $IFACE – attach external antenna."
        fi
        log "Antenna detected (sysfs) on $IFACE."
    else
        # Fallback using iw
        if command -v iw >/dev/null; then
            ANT_INFO=$(iw dev "$IFACE" info 2>/dev/null || true)
            if echo "$ANT_INFO" | grep -q 'antenna:.*0'; then
                die "Antenna not reported by iw – attach antenna."
            else
                log "Antenna detected (iw) on $IFACE."
            fi
        fi
    fi
    echo "$IFACE" > /tmp/8821cu_iface
}

# Capture internal wifi interfaces (do not disable yet)
EXISTING_IFACES=$(ls /sys/class/net | grep '^wlan' || true)

# Run detection
check_antenna
IFACE=$(cat /tmp/8821cu_iface)

# Bring up external interface
log "Bringing up $IFACE"
sudo ip link set "$IFACE" up

# Connect using saved credentials (wpa_supplicant.conf)
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
SSID=$(awk -F'=' '/ssid=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
PSK=$(awk -F'=' '/psk=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
if [[ -z "$SSID" || -z "$PSK" ]]; then
    die "Could not read SSID/PSK from $WPA_CONF"
fi
log "Creating NetworkManager connection for SSID '$SSID' on $IFACE"
sudo nmcli connection delete "$SSID" >/dev/null 2>&1 || true
sudo nmcli device wifi rescan ifname "$IFACE"
sudo nmcli connection add type wifi ifname "$IFACE" con-name "$SSID" ssid "$SSID" \
    -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK"
sudo nmcli connection up "$SSID"

# Wait for IP
log "Waiting for DHCP lease on $IFACE..."
for i in {1..30}; do
    IP=$(ip -4 addr show "$IFACE" | awk '/inet/ {print $2}')
    [[ -n "$IP" ]] && break
    sleep 1
done
if [[ -z "$IP" ]]; then
    die "Failed to obtain an IP address on $IFACE"
fi
log "Wi‑Fi connected – $IP"

# Verify connectivity via ping
log "Pinging google.com to verify external adapter connectivity..."
if ping -c 3 -I "$IFACE" google.com >/dev/null 2>&1; then
    log "Ping successful – external adapter is working."
    # Disable internal adapters now
    for dev in $EXISTING_IFACES; do
        if [[ "$dev" == "$IFACE" ]]; then continue; fi
        log "Disabling internal Wi‑Fi interface $dev"
        sudo ip link set "$dev" down || true
    done
    sudo rfkill block wifi || true
else
    die "Ping to google.com failed – external adapter may not be functional."
fi

# ---------------------------  Summary verification ---------------------------
log "=== Verification Summary ==="
run_sudo ufw status verbose
if command -v docker >/dev/null 2>&1; then
    run_sudo docker info
fi
run_sudo systemctl is-active fail2ban
run_sudo grep -E '^(Port|PasswordAuthentication|PermitRootLogin|PubkeyAuthentication|AllowUsers) ' "$SSHD_CONF"
log "\n=== Execution Summary ==="
log "Successful commands: $SUCCESS_COUNT"
log "Failed commands: $FAILURE_COUNT"
if (( FAILURE_COUNT > 0 )); then
    log "Failed command list:"
    for cmd in "${FAILED_CMDS[@]}"; do
        log "  - $cmd"
    done
fi
log "Script completed successfully."

exit 0
