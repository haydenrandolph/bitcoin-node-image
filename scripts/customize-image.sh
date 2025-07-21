#!/bin/bash
set -e

IMAGE=$1
BOOTSTRAP_RPC=$2

# Step 1: Expand the image file (+3GB to be safe)
echo "🧩 Expanding image size by +3GB..."
truncate -s +3G "$IMAGE"

# Step 2: Map loop device
sudo losetup -fP "$IMAGE"
LOOP=$(sudo losetup -j "$IMAGE" | awk -F':' '{print $1}' | head -n1)
echo "🔁 Loop device: $LOOP"

# Step 3: Resize root partition (partition 2)
echo "🛠️ Resizing root partition..."
sudo parted "$LOOP" resizepart 2 100% <<< "Yes"

# Step 4: Filesystem check & resize
sleep 2
sudo e2fsck -f "${LOOP}p2" || true
sudo resize2fs "${LOOP}p2"

# Step 5: Mount partitions
BOOT="/mnt/pi_boot"
ROOT="/mnt/pi_root"
mkdir -p $BOOT $ROOT
sudo mount "${LOOP}p2" $ROOT
sudo mount "${LOOP}p1" $ROOT/boot

# Step 6: Prep for chroot
sudo cp /usr/bin/qemu-aarch64-static $ROOT/usr/bin/
sudo mount --bind /dev $ROOT/dev
sudo mount --bind /proc $ROOT/proc
sudo mount --bind /sys $ROOT/sys

# ----------- Copy scripts/server files for later chroot install -------------
sudo cp scripts/firstboot-setup.sh $ROOT/boot/firstboot-setup.sh
sudo cp scripts/firstboot-setup.service $ROOT/boot/firstboot-setup.service
sudo cp "$BOOTSTRAP_RPC" $ROOT/boot/bootstrap-rpc-creds.sh
sudo chmod +x $ROOT/boot/bootstrap-rpc-creds.sh

# Copy backend and systemd unit
sudo cp -r server $ROOT/boot/server
sudo cp scripts/btcnode-api.service $ROOT/boot/btcnode-api.service

# Step 8: Chroot customization
sudo chroot $ROOT /bin/bash <<'EOF'
set -e

# Prevent services from starting in chrooted apt operations
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive

echo "📦 Updating packages (no kernel bloat)..."
apt update

# Prevent bloated kernel header upgrades
apt-mark hold linux-headers-* linux-image-* rpi-eeprom || true

# Graceful upgrade and cleanup
apt upgrade -y || true
apt --fix-broken install -y || true

# Required packages (except nodejs)
apt install -y --no-install-recommends \
    curl wget git ufw fail2ban tor iptables \
    python3-pip python3-setuptools python3-wheel htop libevent-2.1-7 liberror-perl git-man sudo ca-certificates

# ----------- Add desktop & browser for local HDMI experience -----------
apt install -y --no-install-recommends xserver-xorg xinit raspberrypi-ui-mods chromium-browser unclutter

# Autologin for the bitcoin user to desktop
if ! grep -q "autologin-user=bitcoin" /etc/lightdm/lightdm.conf; then
  sed -i '/^#*autologin-user=/c\autologin-user=bitcoin' /etc/lightdm/lightdm.conf
fi

# Set Chromium to autostart in kiosk mode
mkdir -p /home/bitcoin/.config/lxsession/LXDE-pi/
echo '@chromium-browser --kiosk --incognito --noerrdialogs --disable-infobars http://localhost:3000' >> /home/bitcoin/.config/lxsession/LXDE-pi/autostart
echo '@unclutter -idle 1' >> /home/bitcoin/.config/lxsession/LXDE-pi/autostart

# ----------- Add bitcoin user if not exists ---------
if ! id bitcoin &>/dev/null; then
  adduser --disabled-password --gecos "" bitcoin
fi
# Always create home and give ownership just in case
mkdir -p /home/bitcoin
chown bitcoin:bitcoin /home/bitcoin
mkdir -p /home/bitcoin/.bitcoin
chown -R bitcoin:bitcoin /home/bitcoin/.bitcoin
mkdir -p /home/bitcoin/.config
chown -R bitcoin:bitcoin /home/bitcoin/.config

# ----------- Install Node.js 20 LTS (for flotilla and backend) -----------
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g npm@latest

# ----------- Install Docker and Docker Compose for BTCPay ----------------------
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker bitcoin
apt-get install -y docker-compose-plugin

# ----------- Clone BTCPayServer repo (docker, ARM-ready) ----------------------
sudo -u bitcoin mkdir -p /home/bitcoin/btcpayserver
cd /home/bitcoin/btcpayserver
if [ ! -d "/home/bitcoin/btcpayserver/btcpayserver-docker" ]; then
  sudo -u bitcoin git clone https://github.com/btcpayserver/btcpayserver-docker.git
fi
chown -R bitcoin:bitcoin /home/bitcoin/btcpayserver

# ----------- BTCPay easy startup script ---------------------------------------
cat <<'BTSH' >/home/bitcoin/btcpayserver/start-btcpay.sh
#!/bin/bash
cd /home/bitcoin/btcpayserver/btcpayserver-docker
export BTCPAY_HOST="pi.local"
export NBITCOIN_NETWORK="mainnet"
export BTCPAYGEN_CRYPTO1="btc"
export BTCPAYGEN_REVERSEPROXY="nginx"
export BTCPAYGEN_LIGHTNING="none"
. ./btcpay-setup.sh -i
BTSH
chmod +x /home/bitcoin/btcpayserver/start-btcpay.sh
chown bitcoin:bitcoin /home/bitcoin/btcpayserver/start-btcpay.sh
# -------------------------------------------------------------------------------

echo "🪙 Installing Bitcoin Core..."
BITCOIN_VERSION=25.1
cd /tmp
wget https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz
tar -xvf bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz
install -m 0755 -o root -g root -t /usr/local/bin bitcoin-${BITCOIN_VERSION}/bin/*
rm -rf bitcoin-${BITCOIN_VERSION}*

# Placeholder bitcoin.conf (patched at boot)
cat <<'BITCOIN_CONF' >/home/bitcoin/.bitcoin/bitcoin.conf
server=1
daemon=1
txindex=1
rpcuser=REPLACE_USER
rpcpassword=REPLACE_PASS
rpcallowip=127.0.0.1
BITCOIN_CONF

chown bitcoin:bitcoin /home/bitcoin/.bitcoin/bitcoin.conf
chmod 600 /home/bitcoin/.bitcoin/bitcoin.conf

# bitcoind systemd service
cat <<'BITCOIND_SERVICE' >/etc/systemd/system/bitcoind.service
[Unit]
Description=Bitcoin daemon
After=network.target

[Service]
ExecStart=/usr/local/bin/bitcoind -conf=/home/bitcoin/.bitcoin/bitcoin.conf -datadir=/home/bitcoin/.bitcoin
User=bitcoin
Group=bitcoin
Type=simple
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
BITCOIND_SERVICE

systemctl enable bitcoind.service

# Bootstrap RPC credentials service
install -m 0755 /boot/bootstrap-rpc-creds.sh /usr/local/bin/bootstrap-rpc-creds.sh

cat <<'BOOTSTRAP_RPC_SERVICE' >/etc/systemd/system/bootstrap-rpc-creds.service
[Unit]
Description=Bootstrap RPC Credentials for Bitcoin
After=network.target
Before=bitcoind.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bootstrap-rpc-creds.sh

[Install]
WantedBy=multi-user.target
BOOTSTRAP_RPC_SERVICE

systemctl enable bootstrap-rpc-creds.service

# ----------- Install firstboot wizard and enable systemd oneshot ---------------
install -m 0755 /boot/firstboot-setup.sh /usr/local/bin/firstboot-setup.sh
cat /boot/firstboot-setup.service > /etc/systemd/system/firstboot-setup.service
systemctl enable firstboot-setup.service

# ----------- Install Flotilla Nostr Web UI and enable systemd service -----------
cd /home/bitcoin
if [ ! -d "/home/bitcoin/flotilla" ]; then
  sudo -u bitcoin git clone https://github.com/coracle-social/flotilla.git
fi
cd /home/bitcoin/flotilla
sudo -u bitcoin npm install
sudo -u bitcoin npm run build
sed -i '/"start":/c\    "start": "vite preview --host 0.0.0.0",' package.json
cat <<'FLOTILLA_SERVICE' >/etc/systemd/system/flotilla.service
[Unit]
Description=Flotilla Nostr Web UI
After=network.target

[Service]
WorkingDirectory=/home/bitcoin/flotilla
ExecStart=/usr/bin/npm run start
User=bitcoin
Restart=always

[Install]
WantedBy=multi-user.target
FLOTILLA_SERVICE

systemctl enable flotilla.service

# ----------- Install Bitcoin Node API server (Express.js) ------------------------
mkdir -p /home/bitcoin/server
cp -r /boot/server/* /home/bitcoin/server/
chown -R bitcoin:bitcoin /home/bitcoin/server
cd /home/bitcoin/server
sudo -u bitcoin npm install

# Copy and enable systemd service
cp /boot/btcnode-api.service /etc/systemd/system/btcnode-api.service
systemctl enable btcnode-api.service

# Ensure correct ownership
chown -R bitcoin:bitcoin /home/bitcoin/server

# ------------------------------------------------------------------------------------

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

# Step 9: Cleanup mounts and detach loop
sudo umount $ROOT/{dev,proc,sys,boot}
sudo umount $ROOT
sudo losetup -d "$LOOP"

echo "✅ Customization complete. Image is ready for compression."