#!/usr/bin/env bash

# Unattended security upgrades configuration
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Configuring automated unattended security upgrades..."
UNATTENDED_CONF="/etc/apt/apt.conf.d/52-hardening-unattended-upgrades"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "[DRY-RUN] Would create $UNATTENDED_CONF"
else
  cat > "$UNATTENDED_CONF" <<EOF
// Automatic security upgrades configured by scripts/gemeni-hardeing-pi.sh
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
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
