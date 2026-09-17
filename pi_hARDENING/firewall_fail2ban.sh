#!/usr/bin/env bash

# UFW firewall and Fail2Ban configuration
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Configuring host firewall (UFW)..."
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow in on lo comment "Allow local loopback"
run ufw allow out on lo comment "Allow local loopback"
run ufw allow from "${SSH_CIDR}" to any port "${SSH_PORT}" proto tcp comment "SSH LAN access"
run ufw allow from "${API_CIDR}" to any port "${API_PORT}" proto tcp comment "FastAPI ticker API LAN"
run ufw allow in on tailscale0 comment "Allow Tailscale private mesh" || true
if [[ "${DRY_RUN}" != "true" ]]; then
  run ufw --force enable
  success "UFW firewall active"
fi

# Fail2Ban SSH jail
log "Configuring Fail2Ban SSH jail..."
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/ssh.conf"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "[DRY-RUN] Would create $FAIL2BAN_JAIL"
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
  success "Fail2Ban enabled monitoring SSH on port ${SSH_PORT}."
fi
