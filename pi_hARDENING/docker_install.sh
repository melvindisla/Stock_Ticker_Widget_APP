#!/usr/bin/env bash

# Docker Engine and Compose installation + daemon log limits
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ "${SKIP_DOCKER}" == "true" ]]; then
  log "Skipping Docker installation (--no-docker flag set)."
  exit 0
fi

log "Configuring Docker Engine and Docker Compose..."
if ! command -v docker >/dev/null 2>&1; then
  run curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  run sh /tmp/get-docker.sh
  run rm -f /tmp/get-docker.sh
else
  log "Docker already installed: $(docker --version || true)"
fi

run usermod -aG docker "${ADMIN_USER}"
run apt-get install -y --no-install-recommends docker-compose-plugin

# Daemon JSON log limits
DAEMON_JSON="/etc/docker/daemon.json"
install -d -m 755 /etc/docker
if [[ "${DRY_RUN}" == "true" ]]; then
  log "[DRY-RUN] Would configure Docker daemon log limits in $DAEMON_JSON"
elif [[ -f "$DAEMON_JSON" ]]; then
  log "Merging log limits into existing $DAEMON_JSON"
  jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' "$DAEMON_JSON" > "${DAEMON_JSON}.tmp"
  mv "${DAEMON_JSON}.tmp" "$DAEMON_JSON"
else
  cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
fi

run systemctl enable docker
run systemctl restart docker || true
success "Docker Engine & Compose configured with log limits."
