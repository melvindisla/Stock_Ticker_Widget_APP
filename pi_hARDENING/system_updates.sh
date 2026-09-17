#!/usr/bin/env bash

# System updates and base security packages
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Updating package lists and upgrading base packages..."
export DEBIAN_FRONTEND=noninteractive
run apt-get update -y
run apt-get upgrade -y

log "Installing required core security, networking, and utility packages..."
run apt-get install -y --no-install-recommends \
    ufw \
    fail2ban \
    unattended-upgrades \
    systemd-timesyncd \
    curl \
    ca-certificates \
    jq \
    htop \
    lm-sensors \
    util-linux \
    openssh-server \
    openssl \
    git \
    gawk
