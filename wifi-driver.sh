#!/usr/bin/env bash
#
# Non-Interactive Driver Installation & Switch Script
# Target Device: Realtek RTL8811CU / RTL8821CU (USB ID: 0bda:c811)
# Target Repository: https://github.com/morrownr/8821cu-20210916
#

set -e

KERNEL_VERSION=$(uname -r)

echo "========================================="
echo " 1. Target Kernel Version: $KERNEL_VERSION"
echo "========================================="
sudo apt update

# Install build tools, usb-modeswitch (required for 0bda:c811), and exact matching kernel headers
echo "==> Installing build dependencies and linux-headers-$KERNEL_VERSION..."
sudo apt install -y build-essential dkms git bc usb-modeswitch "linux-headers-$KERNEL_VERSION"

echo "========================================="
echo " 2. Fetching Driver Source Code"
echo "========================================="
REPO_URL="https://github.com/morrownr/8821cu-20210916.git"
CLONE_DIR="8821cu-20210916"

if [ -d "$CLONE_DIR" ]; then
    echo "==> Driver folder exists. Pulling latest updates..."
    cd "$CLONE_DIR"
    git pull
else
    echo "==> Cloning driver repository..."
    git clone "$REPO_URL"
    cd "$CLONE_DIR"
fi

echo "========================================="
echo " 3. Compiling & Installing Driver (Silent Mode)"
echo "========================================="
# Automatically inputs 'n' for both interactive prompts
printf 'n\nn\n' | sudo bash install-driver.sh

echo "========================================="
echo " 4. Configuring USB 3.0 Performance Mode"
echo "========================================="
DRIVER_CONF="/etc/modprobe.d/8821cu.conf"
if [ -f "$DRIVER_CONF" ]; then
    sudo sed -i 's/options 8821cu rtw_switch_usb_mode=.*/options 8821cu rtw_switch_usb_mode=1/' "$DRIVER_CONF" || \
    echo "options 8821cu rtw_switch_usb_mode=1" | sudo tee -a "$DRIVER_CONF"
fi

echo "========================================="
echo " 5. Disabling Onboard Wi-Fi (wlan0)"
echo "========================================="
CONFIG_TXT="/boot/firmware/config.txt"
[ ! -f "$CONFIG_TXT" ] && CONFIG_TXT="/boot/config.txt"

if ! grep -q "dtoverlay=disable-wifi" "$CONFIG_TXT"; then
    echo "==> Disabling onboard Wi-Fi in $CONFIG_TXT..."
    echo "" | sudo tee -a "$CONFIG_TXT"
    echo "# Disable onboard Wi-Fi to force 0bda:c811 USB adapter" | sudo tee -a "$CONFIG_TXT"
    echo "dtoverlay=disable-wifi" | sudo tee -a "$CONFIG_TXT"
fi

echo "========================================="
echo " Installation Complete!"
echo " Please reboot your Raspberry Pi now."
echo "========================================="