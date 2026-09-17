#!/usr/bin/env bash

# Daily hardware health telemetry cron
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Configuring daily hardware health telemetry cron..."
CRON_HEALTH="/etc/cron.d/pi-health"
HEALTH_LOG="/var/log/pi-health.log"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "[DRY-RUN] Would create $CRON_HEALTH"
else
  cat > "$CRON_HEALTH" <<'EOF'
# Daily hardware health telemetry – runs at 02:30 AM
30 2 * * * root /usr/bin/vcgencmd get_throttled >> /var/log/pi-health.log 2>&1
30 2 * * * root /usr/bin/vcgencmd measure_temp   >> /var/log/pi-health.log 2>&1
EOF
  chmod 644 "$CRON_HEALTH"
  touch "$HEALTH_LOG"
  chmod 640 "$HEALTH_LOG"
fi
success "Daily hardware health cron configured."
