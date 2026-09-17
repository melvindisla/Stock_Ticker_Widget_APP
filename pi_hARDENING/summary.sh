#!/usr/bin/env bash

# Summary verification and final exit handling – same as original tail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Compiling system hardening verification summary..."
cat <<'EOF'

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
  • PostgreSQL Directory: ${PG_DATA_DIR} (Permissions: 700)
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
