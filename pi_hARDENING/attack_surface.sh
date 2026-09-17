#!/usr/bin/env bash

# Attack surface reduction – disable unneeded services
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Disabling unneeded Raspberry Pi services (Bluetooth, Avahi, Triggerhappy, CUPS)..."
UNNEEDED_SERVICES=(
  bluetooth.service
  avahi-daemon.service
  triggerhappy.service
  cups.service
  cups-browsed.service
)
for svc in "${UNNEEDED_SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc" 2>&1 || systemctl is-enabled --quiet "$svc" 2>&1; then
    log "Disabling and stopping $svc..."
    run systemctl disable --now "$svc" || true
  fi
done
success "Extraneous services disabled."
