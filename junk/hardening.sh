#!/usr/bin/env bash

# ----------------------------------------------------------------------
# hardening.sh – Raspberry Pi OS (64‑bit) hardening & initial setup
# ----------------------------------------------------------------------
# This script is intended to be run_sudo non‑interactively (e.g. CI/CD, provisioning)
# It is idempotent – safe to run_sudo multiple times.
# ----------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------  Helpers  ------------------------------
log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
error() { printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

die() { error "$*"; exit 1; }

on_error() {
    local exit_code=$?
    error "Failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
    exit "$exit_code"
}

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )) || die "Invalid port: $1"
}

validate_cidr() {
    # Basic CIDR format check
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || die "Invalid IPv4 CIDR format: $1"
    # Split IP and verify each octet is 0-255
    IFS='/' read -r ip prefix <<< "$1"
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( o >=0 && o <=255 )) || die "Invalid IPv4 CIDR octet in $1"
    done
}

run_sudo() {
    if [[ "$DRY_RUN" == "true" ]]; then
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
declare -r PROG_NAME="${0##*/}"
declare -i SUCCESS_COUNT=0 FAILURE_COUNT=0
declare -a FAILED_CMDS=()
declare SSH_PORT=2222
declare API_PORT=8000                 # Port the API container will expose
declare SSH_CIDR="192.168.0.0/16"     # Allowed CIDR for SSH
declare API_CIDR="192.168.0.0/16"     # Allowed CIDR for the API

declare DRY_RUN="false"
declare SKIP_DOCKER="false"
declare FORCE_UNSUPPORTED="false"
declare CURRENT_USER="${SUDO_USER:-$(logname)}"

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
    --api-port <port>          Port to open for the API (default: 8000)
    --allow-ssh-from <cidr>    CIDR range allowed to SSH (default: 192.168.0.0/16)
    --allow-api-from <cidr>    CIDR range allowed to access the API

    --dry-run_sudo             Show actions without executing them
    --no-docker                Skip Docker installation
    --force-unsupported        Continue on non‑Raspberry Pi 4 / non‑Trixie systems
    -h, --help                 Show this help
EOF
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

validate_port "$SSH_PORT"
validate_port "$API_PORT"
validate_cidr "$SSH_CIDR"
validate_cidr "$API_CIDR"
[[ -n "$CURRENT_USER" && "$CURRENT_USER" != "root" ]] || die "Invalid invoking user: $CURRENT_USER"

# ---------------------------  Sudo availability check  ---------------------------
if ! sudo -n true 2>/dev/null; then
    die "User $CURRENT_USER must have password‑less sudo privileges (or run_sudo the script with sudo)."
fi


require_command awk
require_command grep
require_command mount
require_command sed

if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry-run_sudo mode: no system changes will be made."
fi

# Ensure the root filesystem is mounted read‑write (required for config changes)
if ! mount | grep ' / ' | grep -q '\brw\b'; then
    error "Root filesystem is read‑only – aborting to avoid partial changes."
    exit 1
fi

# Back up fstab before any modification (timestamped backup)
run_sudo cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"

# ---------------------------  Environment validation ----------------------------
# Ensure we are running on Raspberry Pi 4 with Debian trixie
PI_MODEL=$(awk -F: '/^Model/ {print $2}' /proc/cpuinfo | xargs)
if [[ "$PI_MODEL" != *"Raspberry Pi 4"* ]]; then
    [[ "$FORCE_UNSUPPORTED" == "true" ]] || die "Detected model '$PI_MODEL'; use --force-unsupported to override"
    log "Warning: continuing on unsupported model '$PI_MODEL'."
fi
OS_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
if [[ "$OS_CODENAME" != "trixie" ]]; then
    [[ "$FORCE_UNSUPPORTED" == "true" ]] || die "Detected OS '$OS_CODENAME'; use --force-unsupported to override"
    log "Warning: continuing on unsupported OS '$OS_CODENAME'."
fi
# Distribution identifiers for unattended‑upgrades configuration
DISTRIB_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
DISTRIB_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
export DEBIAN_FRONTEND=noninteractive
run_sudo apt-get update
run_sudo apt-get install -y --no-install-recommends \
    wpasupplicant netplan.io git python3 python3-pip openssl \
    iptables-persistent htop lm-sensors curl ca-certificates \
    openssh-server ufw fail2ban unattended-upgrades jq gawk

# ---------------------------  SSH hardening  ----------------------
SSHD_CONF="/etc/ssh/sshd_config"
run_sudo cp -a "$SSHD_CONF" "$SSHD_CONF.bak.$(date +%Y%m%d%H%M%S)"

# Ensure the invoking user has an authorized SSH key
if [[ ! -s "/home/$CURRENT_USER/.ssh/authorized_keys" ]]; then
    die "No authorized SSH key found for $CURRENT_USER; aborting"
fi
run_sudo usermod -aG sudo "$CURRENT_USER"

# Remove previously managed directives
run_sudo sed -i -E '/^[#[:space:]]*Port[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*PermitRootLogin[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*PasswordAuthentication[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*PubkeyAuthentication[[:space:]]+/d' "$SSHD_CONF"
run_sudo sed -i -E '/^[#[:space:]]*AllowUsers[[:space:]]+/d' "$SSHD_CONF"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] append SSH settings to $SSHD_CONF"
else
    printf '\n# Managed by %s\nPort %s\nPermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers %s\n' \
        "$PROG_NAME" "$SSH_PORT" "$CURRENT_USER" >>"$SSHD_CONF"
fi
# Reload ssh service (covers both possible unit names)
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run_sudo systemctl reload ssh
else
    run_sudo systemctl reload sshd
fi

# ---------------------------  Firewall (ufw)  --------------------
run_sudo apt-get install -y ufw
run_sudo ufw default deny incoming
run_sudo ufw default allow outgoing
run_sudo ufw allow from "$SSH_CIDR" to any port "$SSH_PORT" proto tcp
run_sudo ufw allow from "$API_CIDR" to any port "$API_PORT" proto tcp
# Recommendation: Test the firewall rule (e.g., nc -z <host> $SSH_PORT) to confirm the SSH port is reachable.
if ufw status | grep -q '^Status: inactive'; then
    run_sudo ufw --force enable
fi

# ---------------------------  Fail2Ban (SSH jail)  -----------------
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] write /etc/fail2ban/jail.d/ssh.conf for port $SSH_PORT"
else
    cat > /etc/fail2ban/jail.d/ssh.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = \%(sshd_log)s
maxretry = 5
bantime = 3600
EOF
fi
run_sudo systemctl restart fail2ban

# ---------------------------  Unattended upgrades  -----------------
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] configure unattended security upgrades for $DISTRIB_ID:$DISTRIB_CODENAME"
else
    cat >/etc/apt/apt.conf.d/52-hardening-unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "${DISTRIB_ID}:${DISTRIB_CODENAME}-security";
};
EOF
    apt-get -o DPkg::Options::=--force-confold -s upgrade >/dev/null
fi
run_sudo systemctl enable --now unattended-upgrades

# ---------------------------  Disable unneeded services ----------
DISABLE_SERVICES=(avahi-daemon bluetooth triggerhappy)
for svc in "${DISABLE_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc"; then
        run_sudo systemctl disable --now "$svc"
    fi
done

# ---------------------------  NTP sync  ---------------------------
run_sudo systemctl enable --now systemd-timesyncd



# ---------------------------  Docker (optional)  -----------------
if [[ "$SKIP_DOCKER" != "true" ]]; then
    if ! command -v docker >/dev/null 2>&1; then
        run_sudo curl --fail --silent --show-error --location https://get.docker.com --output /tmp/get-docker.sh
        run_sudo sh /tmp/get-docker.sh
        run_sudo rm -f /tmp/get-docker.sh
    fi
    run_sudo usermod -aG docker "$CURRENT_USER"
    DOCKER_DAEMON_CONF="/etc/docker/daemon.json"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY‑RUN] configure Docker log limits in $DOCKER_DAEMON_CONF"
    elif [[ -f "$DOCKER_DAEMON_CONF" ]]; then
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$DOCKER_DAEMON_CONF" >"$DOCKER_DAEMON_CONF.tmp"
        cp -a "$DOCKER_DAEMON_CONF" "${DOCKER_DAEMON_CONF}.bak.$(date +%s)" && mv "$DOCKER_DAEMON_CONF.tmp" "$DOCKER_DAEMON_CONF"
    else
        install -d -m 755 /etc/docker
        cat > "$DOCKER_DAEMON_CONF" <<'EOF'
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
        dockerd --validate --config-file="$DOCKER_DAEMON_CONF"
    fi
    run_sudo systemctl enable --now docker
    run_sudo systemctl restart docker
else
    log "--no-docker flag set; Docker installation skipped"
fi

# ---------------------------  Secrets file perms  -----------------
for env_file in "/home/pi/.env" "/home/$CURRENT_USER/.env"; do
    if [[ -f "$env_file" ]]; then
        run_sudo chmod 600 "$env_file"
    fi
done

# ---------------------------  Cron health check  -----------------
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY‑RUN] write /etc/cron.d/pi-health"
else
    cat >/etc/cron.d/pi-health <<'EOF'
# Daily hardware-health logging – 02:30
30 2 * * * root /usr/bin/vcgencmd get_throttled >> /var/log/pi-health.log 2>&1
30 2 * * * root /usr/bin/vcgencmd measure_temp   >> /var/log/pi-health.log 2>&1
EOF
    chmod 644 /etc/cron.d/pi-health
    touch /var/log/pi-health.log
    chmod 640 /var/log/pi-health.log
fi

# ---------------------------  Summary verification  -------------
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
log "Hardening script completed successfully."
