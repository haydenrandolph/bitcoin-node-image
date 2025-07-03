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

# Step 7: Copy bootstrap script before chroot
sudo cp "$BOOTSTRAP_RPC" $ROOT/boot/bootstrap-rpc-creds.sh
sudo chmod +x $ROOT/boot/bootstrap-rpc-creds.sh

# Step 8: Chroot customization
sudo chroot $ROOT /bin/bash <<'EOF'
set -e

echo "📦 Updating packages (no kernel bloat)..."
apt update

# Prevent bloated kernel header upgrades
apt-mark hold linux-headers-* linux-image-* rpi-eeprom || true

# Graceful upgrade and cleanup
apt upgrade -y || true
apt --fix-broken install -y || true

# Required packages
apt install -y --no-install-recommends \
    curl wget git ufw fail2ban tor iptables \
    python3-pip python3-setuptools python3-wheel htop libevent-2.1-7 liberror-perl git-man

echo "🪙 Installing Bitcoin Core..."
BITCOIN_VERSION=25.1
cd /tmp
wget https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz
tar -xvf bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz
install -m 0755 -o root -g root -t /usr/local/bin bitcoin-${BITCOIN_VERSION}/bin/*
rm -rf bitcoin-${BITCOIN_VERSION}*

# Add bitcoin user
adduser --disabled-password --gecos "" bitcoin
mkdir -p /home/bitcoin/.bitcoin
chown -R bitcoin:bitcoin /home/bitcoin/.bitcoin

# Placeholder bitcoin.conf (patched at boot)
cat <<CONF >/home/bitcoin/.bitcoin/bitcoin.conf
server=1
daemon=1
txindex=1
rpcuser=REPLACE_USER
rpcpassword=REPLACE_PASS
rpcallowip=127.0.0.1
CONF

chown bitcoin:bitcoin /home/bitcoin/.bitcoin/bitcoin.conf
chmod 600 /home/bitcoin/.bitcoin/bitcoin.conf

# bitcoind systemd service
cat <<SERVICE >/etc/systemd/system/bitcoind.service
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
SERVICE

systemctl enable bitcoind.service

# Bootstrap RPC credentials service
install -m 0755 /boot/bootstrap-rpc-creds.sh /usr/local/bin/bootstrap-rpc-creds.sh

cat <<RPC >/etc/systemd/system/bootstrap-rpc-creds.service
[Unit]
Description=Bootstrap RPC Credentials for Bitcoin
After=network.target
Before=bitcoind.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bootstrap-rpc-creds.sh

[Install]
WantedBy=multi-user.target
RPC

systemctl enable bootstrap-rpc-creds.service

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

# Step 9: Cleanup mounts and detach loop
sudo umount $ROOT/{dev,proc,sys,boot}
sudo umount $ROOT
sudo losetup -d "$LOOP"

echo "✅ Customization complete. Image is ready for compression."