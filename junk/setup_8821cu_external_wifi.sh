#!/usr/bin/env bash
# --------------------------------------------------------------
# Simple installer for the Realtek 8821CU Wi‑Fi driver on a Raspberry Pi.
# It builds the driver, disables the built‑in Wi‑Fi antenna, and
# connects the new USB adapter using the credentials already stored in
# /etc/wpa_supplicant/wpa_supplicant.conf.
# --------------------------------------------------------------

set -euo pipefail

log() { echo -e "\e[32m[+] $*\e[0m"; }
error() { echo -e "\e[31m[!] $*\e[0m" >&2; exit 1; }

# ---------- 1. Install required packages ----------
log "Updating package index..."
sudo apt-get update -y
log "Installing build tools and NetworkManager..."
sudo apt-get install -y \
    git dkms raspberrypi-kernel-headers build-essential bc \
    raspberrypi-sys-mods network-manager

# Ensure NetworkManager is active
sudo systemctl enable NetworkManager.service
sudo systemctl start NetworkManager.service

# ---------- 2. Clone and build the driver ----------
DRIVER_DIR="/usr/src/8821cu-20210916"
log "Cloning the driver repository..."
sudo rm -rf "$DRIVER_DIR"
sudo git clone https://github.com/morrownr/8821cu-20210916.git "$DRIVER_DIR"

log "Building and installing the driver via DKMS..."
cd "$DRIVER_DIR"
sudo ./install-driver.sh   # registers with DKMS and builds

# Ensure the module loads on every boot
MODULE_CONF="/etc/modules-load.d/8821cu.conf"
echo "8821cu" | sudo tee "$MODULE_CONF" >/dev/null

# ---------- 3. Detect the external interface ----------
# Load the module to expose the device (if not already loaded)
sudo modprobe -r 8821cu || true
sudo modprobe 8821cu
sleep 1

# Use nmcli to find the interface belonging to the 8821cu driver
IFACE=$(nmcli device status | awk '/8821cu/ {print $1}')
if [[ -z "$IFACE" ]]; then
    # Fallback to the first wlan* interface that appears
    IFACE=$(ls /sys/class/net | grep -E '^wlan[0-9]+$' | head -n1)
fi
if [[ -z "$IFACE" ]]; then
    error "External 8821CU Wi‑Fi interface not found after driver installation."
fi
log "External adapter detected as $IFACE"

# ---------- 4. Prepare list of internal Wi‑Fi adapters (do not disable yet) ----------
# Capture all wlan interfaces; we will disable them only after the external adapter is confirmed operational.
EXISTING_IFACES=$(ls /sys/class/net | grep '^wlan' || true)
# (No disabling occurs here.)

# ---------- Helper to disable internal adapters after success ----------
disable_internal_wifi() {
    for dev in $EXISTING_IFACES; do
        # Skip the external adapter we just set up
        if [[ "$dev" == "$IFACE" ]]; then
            continue
        fi
        log "Disabling internal Wi‑Fi interface $dev"
        sudo ip link set "$dev" down || true
    done
    # Block the radio for any remaining internal adapters
    sudo rfkill block wifi || true
}

# ---------- 5. Bring up the external adapter ----------
log "Bringing up $IFACE"
sudo ip link set "$IFACE" up

# ---------- 6. Connect using saved credentials ----------
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
# Extract the first SSID/PSK block (common in simple setups)
SSID=$(awk -F'=' '/ssid=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
PSK=$(awk -F'=' '/psk=/{gsub(/"/,"",$2); print $2; exit}' "$WPA_CONF")
if [[ -z "$SSID" || -z "$PSK" ]]; then
    error "Could not read SSID/PSK from $WPA_CONF"
fi

log "Creating NetworkManager connection for SSID '$SSID' on $IFACE"
sudo nmcli connection delete "$SSID" >/dev/null 2>&1 || true
sudo nmcli device wifi rescan ifname "$IFACE"
sudo nmcli connection add type wifi ifname "$IFACE" con-name "$SSID" ssid "$SSID" \
    -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK"
sudo nmcli connection up "$SSID"

# ---------- 7. Wait for IP address ----------
log "Waiting for DHCP lease on $IFACE..."
for i in {1..30}; do
    IP=$(ip -4 addr show "$IFACE" | awk '/inet/ {print $2}')
    [[ -n "$IP" ]] && break
    sleep 1
done
if [[ -z "$IP" ]]; then
    error "Failed to obtain an IP address on $IFACE"
fi
log "Wi‑Fi connected – $IP"

log "Pinging google.com to verify external adapter connectivity..."
if ping -c 3 -I "$IFACE" google.com > /dev/null 2>&1; then
    log "Ping successful – external adapter is working."
    # Disable internal adapters after successful verification
    disable_internal_wifi
else
    error "Ping to google.com failed – external adapter may not be functional."
fi

log "Installation and configuration complete."
exit 0
