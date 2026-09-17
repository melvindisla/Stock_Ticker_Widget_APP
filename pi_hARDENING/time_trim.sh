#!/usr/bin/env bash

# NTP, TRIM, and NVMe (if present) handling – simplified to time sync and weekly trim
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Enabling NTP synchronization via systemd-timesyncd..."
run systemctl enable --now systemd-timesyncd
if command -v timedatectl >/dev/null 2>&1; then
  run timedatectl set-ntp true || true
fi
success "NTP time synchronization enabled"

# Weekly TRIM timer (kept even if NVMe not detected – safe no‑op)
log "Enabling weekly filesystem TRIM (fstrim.timer)..."
run systemctl enable --now fstrim.timer
CRON_WEEKLY_TRIM="/etc/cron.weekly/fstrim"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "[DRY-RUN] Would create $CRON_WEEKLY_TRIM"
else
  cat > "$CRON_WEEKLY_TRIM" <<'EOF'
#!/bin/sh
# Weekly NVMe TRIM maintenance
/sbin/fstrim -av
EOF
  chmod 755 "$CRON_WEEKLY_TRIM"
fi
success "TRIM maintenance active via fstrim.timer and $CRON_WEEKLY_TRIM"
