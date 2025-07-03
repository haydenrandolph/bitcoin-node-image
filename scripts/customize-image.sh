#!/bin/bash
set -e

IMAGE=$1
BOOTSTRAP_RPC=$2

LOOP=$(sudo kpartx -av "$IMAGE" | head -n1 | cut -d' ' -f3 | sed 's/p[0-9]//')
echo "Loop device is: /dev/mapper/${LOOP}"

# Give loop partitions a moment to settle
sleep 5

BOOT="/mnt/pi_boot"
ROOT="/mnt/pi_root"
mkdir -p $BOOT $ROOT

# Ensure the loop devices exist
ls -l /dev/mapper/${LOOP}*

# Mount partitions explicitly
sudo mount "/dev/mapper/${LOOP}p2" $ROOT
sudo mount "/dev/mapper/${LOOP}p1" $ROOT/boot

sudo cp /usr/bin/qemu-aarch64-static $ROOT/usr/bin/
sudo mount --bind /dev $ROOT/dev
sudo mount --bind /proc $ROOT/proc
sudo mount --bind /sys $ROOT/sys

# Chroot customization
sudo chroot $ROOT /bin/bash <<'EOF'
apt update && apt upgrade -y
apt install -y curl wget ufw fail2ban tor git python3-pip htop

BITCOIN_VERSION=25.1
cd /tmp
wget https://bitcoin.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz
tar -xvf bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz
install -m 0755 -o root -g root -t /usr/local/bin bitcoin-${BITCOIN_VERSION}/bin/*
rm -rf bitcoin-${BITCOIN_VERSION}*

adduser --disabled-password --gecos "" bitcoin
mkdir -p /home/bitcoin/.bitcoin
chown bitcoin:bitcoin /home/bitcoin/.bitcoin

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

# Setup Bitcoin service
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

# Security setup
ufw allow ssh
ufw allow 8333
ufw enable
systemctl enable fail2ban

install -m 0755 /boot/bootstrap-rpc-creds.sh /usr/local/bin/bootstrap-rpc-creds.sh

# Bootstrap service
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

apt clean
EOF

sudo cp "$BOOTSTRAP_RPC" $ROOT/boot/bootstrap-rpc-creds.sh

# Cleanup mounts
sudo umount $ROOT/{dev,proc,sys,boot}
sudo umount $ROOT
sudo kpartx -dv "$IMAGE"