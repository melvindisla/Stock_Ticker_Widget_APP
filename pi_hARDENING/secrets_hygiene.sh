#!/usr/bin/env bash

# Secrets file permission hygiene (.env files)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Enforcing strict permissions on .env files..."
TARGET_ENV_DIRS=(
  "/home/${ADMIN_USER}"
  "/home/pi"
  "/mnt/nvme"
  "$(pwd)"
)
for dir in "${TARGET_ENV_DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 3 -type f -name ".env" 2>&1 | while read -r env_file; do
      log "Securing $env_file (chmod 600)..."
      run chmod 600 "$env_file"
      run chown "${ADMIN_USER}:${ADMIN_USER}" "$env_file" 2>&1 || true
    done
  fi
done
success "Secrets file hygiene enforced."
