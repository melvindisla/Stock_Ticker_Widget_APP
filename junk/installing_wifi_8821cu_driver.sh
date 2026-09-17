#!/usr/bin/env bash

# --------------------------------------------------------------
# 8821cu Wi‑Fi driver installer for Raspberry Pi
# --------------------------------------------------------------
# This script is intended to be executed **once** on the target Pi.
# It performs a full, non‑interactive installation of the Realtek 8821CU
# driver from https://github.com/morrownr/8821cu-20210916.git and then
# configures the Pi to use any Wi‑Fi credentials that already exist in
# /etc/wpa_supplicant/wpa_supplicant.conf.
# --------------------------------------------------------------

set -euo pipefail

# Capture any pre‑existing Wi‑Fi interfaces (internal adapters) so we can disable them later
EXISTING_IFACES=$(ls /sys/class/net | grep '^wlan' || true)

log()   { echo -e "\e[32m[+] $*\e[0m"; }
error() { echo -e "\e[31m[!] $*\e[0m" >&2; exit 1; }

# ---- 0. Antenna detection -------------------------------------------------
check_antenna() {
    # Identify the USB device (replace with the exact ID if known)
    USB_ID=$(lsusb -d 0bda:8179 || true)   # 0bda:8179 is a common ID for 8821CU
    if [[ -z "$USB_ID" ]]; then
        error "Realtek 8821CU USB dongle not found – insert the device."
    fi

    # Load the module briefly to expose the net interface (if not already)
    sudo modprobe -r 8821cu || true
    sudo modprobe 8821cu
    sleep 1   # give udev a moment

    # Use nmcli to list devices and find the one belonging to the 8821CU driver
    IFACE=$(nmcli device status | awk '/8821cu/ {print $1}')
    if [[ -z "$IFACE" ]]; then
        # Fallback to generic wlan detection
        IFACE=$(ls /sys/class/net | grep -E '^wlan[0-9]+$' | head -n1)
    fi
    if [[ -z "$IFACE" ]]; then
        error "No wlan interface appeared after loading 8821cu."
    fi

    # Primary antenna check (sysfs)
    ANT_PATH="/sys/class/net/${IFACE}/device/antenna"
    if [[ -f "$ANT_PATH" ]]; then
        ANT=$(cat "$ANT_PATH")
        if [[ "$ANT" -eq 0 ]]; then
            error "Antenna not detected on $IFACE – attach external antenna."
        fi
        log "Antenna detected (sysfs) on $IFACE."
        echo "$IFACE" > /tmp/8821cu_iface
        return
    fi

    # Fallback using iw
    if command -v iw >/dev/null; then
        ANT_INFO=$(iw dev "$IFACE" info 2>/dev/null || true)
        if echo "$ANT_INFO" | grep -q 'antenna:.*0'; then
            error "Antenna not reported by iw – attach antenna."
        else
            log "Antenna detected (iw) on $IFACE."
            echo "$IFACE" > /tmp/8821cu_iface
            return
        fi
    fi

    # Final fallback – ensure the radio isn’t hard‑blocked
    if rfkill list wifi | grep -q 'Hard blocked: yes'; then
        error "Wi‑Fi radio hard‑blocked – check hardware switch/antenna."
    fi

    log "Antenna detection inconclusive – proceeding anyway."
    echo "$IFACE" > /tmp/8821cu_iface
}

# ---- 1. Disable internal Wi‑Fi adapters -------------------------------------
disable_internal_wifi() {
    for i in $EXISTING_IFACES; do
        # Skip the newly created external adapter (will be disabled later if it matches)
        if [[ -f /tmp/8821cu_iface ]] && [[ "$i" == "$(cat /tmp/8821cu_iface)" ]]; then
            continue
        fi
        log "Disabling internal Wi‑Fi interface $i"
        sudo ip link set "$i" down || true
        sudo rfkill block wifi || true
    done
}


# 1. Install required build packages (non‑interactive) – unconditional
log "Updating apt cache…"
sudo apt-get update -y
log "Installing build dependencies…"
sudo apt-get install -y \
    git dkms raspberrypi-kernel-headers build-essential bc \
    raspberrypi-sys-mods network-manager
# Ensure NetworkManager is running
sudo systemctl enable NetworkManager.service
sudo systemctl start NetworkManager.service

# 2. Clone the driver repository – always fresh
DRIVER_DIR="/usr/src/8821cu-20210916"
log "Cloning the driver repository…"
sudo rm -rf "$DRIVER_DIR"
sudo git clone https://github.com/morrownr/8821cu-20210916.git "$DRIVER_DIR"

# Run antenna detection before building the driver
check_antenna
# Capture the detected interface name for later use
IFACE=$(cat /tmp/8821cu_iface)
# Disable any internal Wi‑Fi adapters (leaving only the external one active)
disable_internal_wifi


# 3. Build and install the driver via DKMS
log "Building and installing the driver (DKMS)…"
cd "$DRIVER_DIR"
# The repository supplies a helper that registers the module with DKMS
sudo ./install-driver.sh

# 42. Ensure the module loads on every boot – always create config
MODULE_CONF="/etc/modules-load.d/8821cu.conf"
log "Creating $MODULE_CONF to auto‑load the module…"
echo "8821cu" | sudo tee "$MODULE_CONF" >/dev/null

# ---- 2. Connect to saved Wi‑Fi network using NetworkManager -------------------
connect_saved_network() {
    # Retrieve SSID and PSK from the existing wpa_supplicant config
    # Assume the first network block is the target (common in simple setups)
    SSID=$(awk -F'=' '/ssid=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
    PSK=$(awk -F'=' '/psk=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")

    if [[ -z "$SSID" || -z "$PSK" ]]; then
        error "Could not extract SSID/PSK from $WPA_CONF"
    fi

    log "Creating NetworkManager connection for SSID '$SSID' on $IFACE"
    # Delete any pre‑existing connection with the same name to avoid duplicates
    sudo nmcli connection delete "$SSID" >/dev/null 2>&1 || true
    sudo nmcli device wifi rescan ifname "$IFACE"
    sudo nmcli connection add type wifi ifname "$IFACE" con-name "$SSID" ssid "$SSID" \
        -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK"
    sudo nmcli connection up "$SSID"
    log "NetworkManager connection activated for $SSID"
}


# 6. Re‑use existing Wi‑Fi credentials – assume file exists
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
log "Restarting wpa_supplicant to apply existing network blocks…"
sudo wpa_cli -i "$IFACE" reconfigure || true
sudo systemctl restart wpa_supplicant.service

# Connect using NetworkManager (if available)
connect_saved_network

# 7. Wait for an IP address on the external interface – unconditional
log "Waiting for DHCP lease on $IFACE…"
for i in {1..30}; do
    IP=$(ip -4 addr show "$IFACE" | awk '/inet/ {print $2}')
    [[ -n "$IP" ]] && break
    sleep 1
done
if [[ -z "$IP" ]]; then
    error "Failed to obtain an IP address on $IFACE. Check dmesg and wpa_supplicant logs."
else
    log "Wi‑Fi connected – $IP"
fi

log "Installation complete. No reboot is required, but you may reboot to ensure a clean state."

echo "If you encounter issues, inspect the driver via 'dmesg | grep 8821cu' and review /var/log/syslog."

exit 0
