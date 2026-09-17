#!/usr/bin/env bash

# Admin user creation and SSH key provisioning, plus SSH daemon hardening
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Resolve Admin User (expects ADMIN_USER, DRY_RUN, LOG_FILE, etc. from master)
if [[ -z "${ADMIN_USER}" ]]; then
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    ADMIN_USER="$SUDO_USER"
    log "Auto-detected admin user from sudo: $ADMIN_USER"
  elif id -u pi >/dev/null 2>&1; then
    ADMIN_USER="pi"
    log "Defaulting admin user to existing 'pi'"
  else
    ADMIN_USER="sysadmin"
    log "Defaulting admin user to '$ADMIN_USER'"
  fi
fi
validate_username "$ADMIN_USER"

# Ensure user exists
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  log "Creating admin user $ADMIN_USER..."
  run adduser --disabled-password --gecos "Stock Ticker Service Admin" "$ADMIN_USER"
fi
run usermod -aG sudo "$ADMIN_USER"

# SSH authorized_keys handling
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
  warn "No SSH public key found for admin user. Password auth disabled may lock you out!"
else
  if [[ "$KEY_SOURCE" != "$USER_AUTH_KEYS" && "${DRY_RUN}" != "true" ]]; then
    log "Copying authorized keys to $USER_AUTH_KEYS"
    run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$USER_SSH_DIR"
    run install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$KEY_SOURCE" "$USER_AUTH_KEYS"
  fi
  success "SSH public key verified for $ADMIN_USER"
fi

# SSH daemon hardening
log "Hardening SSH configuration (/etc/ssh/sshd_config)..."
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONFIG}.bak.${BACKUP_TIMESTAMP}"
if [[ -f "$SSHD_CONFIG" ]]; then
  run cp -a "$SSHD_CONFIG" "$SSHD_BACKUP"
  log "Backed up current SSH config to $SSHD_BACKUP"
  run sed -i -E '/^[#[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax|X11Forwarding)[[:space:]]+/Id' "$SSHD_CONFIG"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would append hardened SSH directives to $SSHD_CONFIG"
  else
    cat >> "$SSHD_CONFIG" <<EOF

# Managed by scripts/gemeni-hardeing-pi.sh (Stock Ticker App Hardening)
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
  if [[ "${DRY_RUN}" != "true" ]]; then
    if sshd -t; then
      success "SSH config syntax verified"
      if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        run systemctl reload ssh || run systemctl restart ssh
      else
        run systemctl reload sshd || run systemctl restart sshd
      fi
      success "SSH daemon reloaded on port ${SSH_PORT}."
    else
      error "sshd syntax validation failed! Restoring backup."
      cp -a "$SSHD_BACKUP" "$SSHD_CONFIG"
      die "SSH configuration error. Backup restored."
    fi
  fi
fi
