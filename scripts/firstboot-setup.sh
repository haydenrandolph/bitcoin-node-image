#!/bin/bash

FLAG_FILE="/boot/firstboot-done"
if [ -f "$FLAG_FILE" ]; then
  exit 0
fi

echo "==== Welcome to Your Pi Bitcoin Node ===="
echo "Let's get you set up for Wi-Fi and blockchain pruning!"
echo ""

# --- Wi-Fi setup ---
read -p "WiFi SSID: " SSID
read -s -p "WiFi Password: " WIFI_PSK
echo ""

# --- Prune setting ---
read -p "How many MB to prune blockchain to? [default: 2048]: " PRUNE
PRUNE=${PRUNE:-2048}

cat <<EOF | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$SSID"
    psk="$WIFI_PSK"
}
EOF

sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
sudo rfkill unblock wifi
sudo systemctl restart wpa_supplicant
sudo dhclient wlan0

cat <<EOF | sudo tee /home/bitcoin/.bitcoin/bitcoin.conf > /dev/null
server=1
rpcuser=bitcoin
rpcpassword=changeme
rpcallowip=127.0.0.1
prune=$PRUNE
dbcache=512
maxconnections=20
EOF

sudo chown -R bitcoin:bitcoin /home/bitcoin/.bitcoin

echo ""
echo "WiFi and Bitcoin configs are set. The system will reboot in 5 seconds to apply changes..."
touch "$FLAG_FILE"
sleep 5
sudo reboot