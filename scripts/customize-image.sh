#!/bin/bash
set -e

IMAGE=$1
BOOTSTRAP_RPC=$2

# Validate parameters
echo "🔍 Debug: IMAGE=$IMAGE"
echo "🔍 Debug: BOOTSTRAP_RPC=$BOOTSTRAP_RPC"

if [ -z "$IMAGE" ] || [ -z "$BOOTSTRAP_RPC" ]; then
    echo "Usage: $0 <image_file> <bootstrap_rpc_script>"
    echo "Example: $0 raspi-custom.img scripts/bootstrap-rpc-creds.sh"
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo "Error: Image file '$IMAGE' not found"
    exit 1
fi

if [ ! -f "$BOOTSTRAP_RPC" ]; then
    echo "Error: Bootstrap RPC script '$BOOTSTRAP_RPC' not found"
    exit 1
fi

# Host memory tip for large images:
echo "💡 If your system has low RAM, add swap BEFORE running this script:"
echo "    sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"

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
echo "📁 Copying scripts to image..."
sudo cp scripts/firstboot-setup.sh $ROOT/boot/firstboot-setup.sh
sudo cp scripts/firstboot-setup.service $ROOT/boot/firstboot-setup.service
echo "📋 Copying bootstrap script: $BOOTSTRAP_RPC"
echo "🔍 Debug: Source file exists: $(ls -la "$BOOTSTRAP_RPC" 2>/dev/null || echo 'NOT FOUND')"
sudo cp "$BOOTSTRAP_RPC" $ROOT/boot/bootstrap-rpc-creds.sh || echo "Warning: Failed to copy bootstrap script"
echo "🔍 Debug: Target file exists: $(ls -la $ROOT/boot/bootstrap-rpc-creds.sh 2>/dev/null || echo 'NOT FOUND')"
sudo chmod +x $ROOT/boot/bootstrap-rpc-creds.sh

# Verify the file was copied correctly
echo "🔍 Debug: Verifying bootstrap script copy..."
if [ -f "$ROOT/boot/bootstrap-rpc-creds.sh" ]; then
    echo "✅ Bootstrap script copied successfully"
    echo "🔍 Debug: File permissions: $(ls -la $ROOT/boot/bootstrap-rpc-creds.sh)"
    echo "🔍 Debug: File content preview: $(head -1 $ROOT/boot/bootstrap-rpc-creds.sh)"
else
    echo "❌ Failed to copy bootstrap script"
    exit 1
fi

# Copy backend and systemd unit
sudo cp -r server $ROOT/boot/server
sudo cp scripts/btcnode-api.service $ROOT/boot/btcnode-api.service

# Step 8: Chroot customization
echo "🚀 Starting chroot customization..."

# Create a temporary script for chroot execution
cat > /tmp/chroot-script.sh << 'CHROOT_SCRIPT_EOF'
#!/bin/bash
set -e

echo "🔧 Step 1: Setting up chroot environment..."
echo "🔍 System resource check:"
echo "   Memory: $(free -h | grep Mem | awk '{print $2}') total, $(free -h | grep Mem | awk '{print $7}') available"
echo "   Disk: $(df -h / | tail -1 | awk '{print $2}') total, $(df -h / | tail -1 | awk '{print $4}') available"
echo "   Load: $(uptime | awk -F'load average:' '{print $2}')"

# Memory optimization for APT
echo 'APT::Acquire::Languages "none";' > /etc/apt/apt.conf.d/99translations
echo 'Acquire::Queue-Mode "access";' > /etc/apt/apt.conf.d/99parallel
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

# Prevent services from starting in chrooted apt operations
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive

echo 'Dpkg::Options::="--force-confdef";' > /etc/apt/apt.conf.d/99force-confdef
echo 'Dpkg::Options::="--force-confold";' >> /etc/apt/apt.conf.d/99force-confdef

echo "📦 Step 2: Updating packages..."
apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=false update

# Prevent bloated kernel header upgrades
apt-mark hold linux-headers-* linux-image-* rpi-eeprom || true

# Small batch upgrades
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y || true
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --fix-broken install -y || true

echo "🔧 Fixing initramfs-tools configuration..."
echo "Y" | DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# Minimal package install in small batches:
echo "📦 Step 3: Installing required packages (in small batches)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl wget || echo "Warning: curl/wget failed"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates || echo "Warning: git/ca-certificates failed"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-pip || echo "Warning: pip failed"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libevent-2.1-7 liberror-perl git-man || echo "Warning: event/error-perl/git-man failed"
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

echo "🔐 Step 3.5: Setting up SSH configuration..."
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server || echo "Warning: SSH install failed"
mkdir -p /etc/ssh/sshd_config.d
echo "Port 22" > /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "Protocol 2" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "HostKey /etc/ssh/ssh_host_rsa_key" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "HostKey /etc/ssh/ssh_host_ecdsa_key" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "HostKey /etc/ssh/ssh_host_ed25519_key" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "UsePrivilegeSeparation yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "KeyRegenerationInterval 3600" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "ServerKeyBits 1024" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "SyslogFacility AUTH" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "LogLevel INFO" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "LoginGraceTime 120" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "PermitRootLogin no" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "StrictModes yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "RSAAuthentication yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "AuthorizedKeysFile %h/.ssh/authorized_keys" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "IgnoreRhosts yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "RhostsRSAAuthentication no" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "HostbasedAuthentication no" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "X11Forwarding yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "X11DisplayOffset 10" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "PrintMotd no" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "PrintLastLog yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "AcceptEnv LANG LC_*" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config.d/bitcoin-node.conf
echo "UsePAM yes" >> /etc/ssh/sshd_config.d/bitcoin-node.conf

mkdir -p /home/pi/.ssh
chown pi:pi /home/pi/.ssh
chmod 700 /home/pi/.ssh

echo "👤 Step 4: Setting up bitcoin user..."
if ! id bitcoin &>/dev/null; then
  adduser --disabled-password --gecos "" bitcoin
fi
mkdir -p /home/bitcoin
chown bitcoin:bitcoin /home/bitcoin
mkdir -p /home/bitcoin/.bitcoin
chown -R bitcoin:bitcoin /home/bitcoin/.bitcoin
mkdir -p /home/bitcoin/.config
chown -R bitcoin:bitcoin /home/bitcoin/.config
mkdir -p /home/bitcoin/.ssh
chown bitcoin:bitcoin /home/bitcoin/.ssh
chmod 700 /home/bitcoin/.ssh

echo "🟢 Step 5: Installing Node.js (memory-optimized)..."
apt-get clean
rm -rf /var/lib/apt/lists/*
sync
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || echo "Warning: Node.js repo setup failed"
apt-get clean
rm -rf /var/lib/apt/lists/*
sync
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs || echo "Warning: Node.js install failed"

if ! command -v node &> /dev/null; then
    echo "🔄 Trying Node.js from Debian repository..."
    apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=false update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs || echo "Warning: Node.js install failed"
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

echo "🐳 Step 6: Installing Docker (memory-optimized)..."
apt-get clean
rm -rf /var/lib/apt/lists/*
sync
echo "📦 Installing Docker from Debian repository..."
apt-get -o Acquire::Languages=none -o Acquire::GzipIndexes=false update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || echo "Warning: Docker install failed"

if ! command -v docker &> /dev/null; then
    echo "🔄 Trying official Docker installation script..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh --dry-run || sh get-docker.sh || echo "Warning: Docker installation failed"
    rm -f get-docker.sh
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

echo "💰 Step 7: Setting up BTCPay Server..."
sudo -u bitcoin mkdir -p /home/bitcoin/btcpayserver
cd /home/bitcoin/btcpayserver
if [ ! -d "/home/bitcoin/btcpayserver/btcpayserver-docker" ]; then
  sudo -u bitcoin git clone https://github.com/btcpayserver/btcpayserver-docker.git || echo "Warning: BTCPay clone failed"
fi
chown -R bitcoin:bitcoin /home/bitcoin/btcpayserver

if ! command -v docker &> /dev/null; then
    echo "⚠️ Docker not available, BTCPay will need manual setup"
    echo "📝 Note: You can install Docker manually after first boot"
fi

echo "#!/bin/bash" > /home/bitcoin/btcpayserver/start-btcpay.sh
echo "cd /home/bitcoin/btcpayserver/btcpayserver-docker" >> /home/bitcoin/btcpayserver/start-btcpay.sh
echo 'export BTCPAY_HOST="pi.local"' >> /home/bitcoin/btcpayserver/start-btcpay.sh
echo 'export NBITCOIN_NETWORK="mainnet"' >> /home/bitcoin/btcpayserver/start-btcpay.sh
echo 'export BTCPAYGEN_CRYPTO1="btc"' >> /home/bitcoin/btcpayserver/start-btcpay.sh
echo 'export BTCPAYGEN_REVERSEPROXY="nginx"' >> /home/bitcoin/btcpayserver/start-btcpay.sh
echo 'export BTCPAYGEN_LIGHTNING="none"' >> /home/bitcoin/btcpayserver/start-btcpay.sh
echo ". ./btcpay-setup.sh -i" >> /home/bitcoin/btcpayserver/start-btcpay.sh
chmod +x /home/bitcoin/btcpayserver/start-btcpay.sh
chown bitcoin:bitcoin /home/bitcoin/btcpayserver/start-btcpay.sh

echo "🪙 Step 9: Installing Bitcoin Core..."
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

BITCOIN_VERSION=25.1
cd /tmp
wget https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz || echo "Warning: Bitcoin download failed"
tar -xvf bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz || echo "Warning: Bitcoin extraction failed"
install -m 0755 -o root -g root -t /usr/local/bin bitcoin-${BITCOIN_VERSION}/bin/* || echo "Warning: Bitcoin install failed"
rm -rf bitcoin-${BITCOIN_VERSION}*

echo "⚙️ Step 10: Setting up Bitcoin configuration..."
echo "server=1" > /home/bitcoin/.bitcoin/bitcoin.conf
echo "daemon=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "txindex=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcuser=REPLACE_USER" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcpassword=REPLACE_PASS" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcallowip=127.0.0.1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "dbcache=2048" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "maxconnections=40" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "maxuploadtarget=5000" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "blocksonly=0" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "listen=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "discover=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "upnp=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "natpmp=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "externalip=auto" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcbind=127.0.0.1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcport=8332" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "port=8333" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "debug=rpc" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "debug=net" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "zmqpubrawblock=tcp://127.0.0.1:28332" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "zmqpubrawtx=tcp://127.0.0.1:28333" >> /home/bitcoin/.bitcoin/bitcoin.conf

chown bitcoin:bitcoin /home/bitcoin/.bitcoin/bitcoin.conf
chmod 600 /home/bitcoin/.bitcoin/bitcoin.conf

echo "🔧 Step 11: Creating systemd services..."
echo "[Unit]" > /etc/systemd/system/bitcoind.service
echo "Description=Bitcoin daemon" >> /etc/systemd/system/bitcoind.service
echo "After=network.target" >> /etc/systemd/system/bitcoind.service
echo "" >> /etc/systemd/system/bitcoind.service
echo "[Service]" >> /etc/systemd/system/bitcoind.service
echo "ExecStart=/usr/local/bin/bitcoind -conf=/home/bitcoin/.bitcoin/bitcoin.conf -datadir=/home/bitcoin/.bitcoin" >> /etc/systemd/system/bitcoind.service
echo "User=bitcoin" >> /etc/systemd/system/bitcoind.service
echo "Group=bitcoin" >> /etc/systemd/system/bitcoind.service
echo "Type=simple" >> /etc/systemd/system/bitcoind.service
echo "Restart=always" >> /etc/systemd/system/bitcoind.service
echo "RestartSec=10" >> /etc/systemd/system/bitcoind.service
echo "" >> /etc/systemd/system/bitcoind.service
echo "[Install]" >> /etc/systemd/system/bitcoind.service
echo "WantedBy=multi-user.target" >> /etc/systemd/system/bitcoind.service

echo "📝 Note: Services will be enabled on first boot, not in chroot"

echo "⚡ Step 12: Installing Lightning Network (LND)..."
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

cd /tmp
LND_VERSION=v0.17.0-beta
wget https://github.com/lightningnetwork/lnd/releases/download/${LND_VERSION}/lnd-linux-arm64-v${LND_VERSION}.tar.gz || echo "Warning: LND download failed"
tar -xzf lnd-linux-arm64-v${LND_VERSION}.tar.gz || echo "Warning: LND extraction failed"
install -m 0755 -o root -g root -t /usr/local/bin lnd-linux-arm64-v${LND_VERSION}/* || echo "Warning: LND install failed"
rm -rf lnd-linux-arm64-v${LND_VERSION}*

mkdir -p /home/bitcoin/.lnd
chown -R bitcoin:bitcoin /home/bitcoin/.lnd

echo "[Application Options]" > /home/bitcoin/.lnd/lnd.conf
echo "datadir=/home/bitcoin/.lnd" >> /home/bitcoin/.lnd/lnd.conf
echo "logdir=/home/bitcoin/.lnd/logs" >> /home/bitcoin/.lnd/lnd.conf
echo "maxlogfiles=3" >> /home/bitcoin/.lnd/lnd.conf
echo "maxlogfilesize=10" >> /home/bitcoin/.lnd/lnd.conf
echo "tlscertpath=/home/bitcoin/.lnd/tls.cert" >> /home/bitcoin/.lnd/lnd.conf
echo "tlskeypath=/home/bitcoin/.lnd/tls.key" >> /home/bitcoin/.lnd/lnd.conf
echo "listen=0.0.0.0:9735" >> /home/bitcoin/.lnd/lnd.conf
echo "rpclisten=127.0.0.1:10009" >> /home/bitcoin/.lnd/lnd.conf
echo "restlisten=127.0.0.1:8080" >> /home/bitcoin/.lnd/lnd.conf
echo "externalhosts=auto" >> /home/bitcoin/.lnd/lnd.conf
echo "alias=BitcoinNode" >> /home/bitcoin/.lnd/lnd.conf
echo "color=#3399FF" >> /home/bitcoin/.lnd/lnd.conf
echo "" >> /home/bitcoin/.lnd/lnd.conf
echo "[Bitcoin]" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoin.active=1" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoin.mainnet=1" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoin.node=bitcoind" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoind.rpcuser=REPLACE_USER" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoind.rpcpass=REPLACE_PASS" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoind.rpchost=127.0.0.1:8332" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332" >> /home/bitcoin/.lnd/lnd.conf
echo "bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333" >> /home/bitcoin/.lnd/lnd.conf

chown bitcoin:bitcoin /home/bitcoin/.lnd/lnd.conf
chmod 600 /home/bitcoin/.lnd/lnd.conf

echo "[Unit]" > /etc/systemd/system/lnd.service
echo "Description=LND Lightning Network Daemon" >> /etc/systemd/system/lnd.service
echo "After=bitcoind.service" >> /etc/systemd/system/lnd.service
echo "Requires=bitcoind.service" >> /etc/systemd/system/lnd.service
echo "" >> /etc/systemd/system/lnd.service
echo "[Service]" >> /etc/systemd/system/lnd.service
echo "ExecStart=/usr/local/bin/lnd --configfile=/home/bitcoin/.lnd/lnd.conf" >> /etc/systemd/system/lnd.service
echo "User=bitcoin" >> /etc/systemd/system/lnd.service
echo "Group=bitcoin" >> /etc/systemd/system/lnd.service
echo "Type=simple" >> /etc/systemd/system/lnd.service
echo "Restart=always" >> /etc/systemd/system/lnd.service
echo "RestartSec=10" >> /etc/systemd/system/lnd.service
echo "" >> /etc/systemd/system/lnd.service
echo "[Install]" >> /etc/systemd/system/lnd.service
echo "WantedBy=multi-user.target" >> /etc/systemd/system/lnd.service

echo "🔌 Step 13: Installing Electrum Server..."
cd /home/bitcoin
if [ ! -d "/home/bitcoin/electrumx" ]; then
  sudo -u bitcoin git clone https://github.com/spesmilo/electrumx.git || echo "Warning: ElectrumX clone failed"
fi

if [ -d "/home/bitcoin/electrumx" ]; then
  cd /home/bitcoin/electrumx
  sudo -u bitcoin python3 -m pip install --no-cache-dir -r requirements.txt || echo "Warning: ElectrumX requirements failed"
  
  echo "DB_DIRECTORY=/home/bitcoin/.electrumx" > /home/bitcoin/.electrumx.env
  echo "DAEMON_URL=http://REPLACE_USER:REPLACE_PASS@127.0.0.1:8332/" >> /home/bitcoin/.electrumx.env
  echo "COIN=Bitcoin" >> /home/bitcoin/.electrumx.env
  echo "NET=mainnet" >> /home/bitcoin/.electrumx.env
  echo "HOST=0.0.0.0" >> /home/bitcoin/.electrumx.env
  echo "TCP_PORT=50001" >> /home/bitcoin/.electrumx.env
  echo "SSL_PORT=50002" >> /home/bitcoin/.electrumx.env
  echo "SSL_CERTFILE=/home/bitcoin/.electrumx/cert.pem" >> /home/bitcoin/.electrumx.env
  echo "SSL_KEYFILE=/home/bitcoin/.electrumx/key.pem" >> /home/bitcoin/.electrumx.env
  echo "LOG_LEVEL=info" >> /home/bitcoin/.electrumx.env
  echo "MAX_SEND=1000000" >> /home/bitcoin/.electrumx.env
  echo "MAX_RECV=1000000" >> /home/bitcoin/.electrumx.env
  echo "MAX_SUBS=100000" >> /home/bitcoin/.electrumx.env
  echo "BANDWIDTH_LIMIT=2000000" >> /home/bitcoin/.electrumx.env
  
  mkdir -p /home/bitcoin/.electrumx
  chown -R bitcoin:bitcoin /home/bitcoin/.electrumx
  chown bitcoin:bitcoin /home/bitcoin/.electrumx.env
  chmod 600 /home/bitcoin/.electrumx.env
  
  echo "[Unit]" > /etc/systemd/system/electrumx.service
  echo "Description=ElectrumX Server" >> /etc/systemd/system/electrumx.service
  echo "After=bitcoind.service" >> /etc/systemd/system/electrumx.service
  echo "Requires=bitcoind.service" >> /etc/systemd/system/electrumx.service
  echo "" >> /etc/systemd/system/electrumx.service
  echo "[Service]" >> /etc/systemd/system/electrumx.service
  echo "WorkingDirectory=/home/bitcoin/electrumx" >> /etc/systemd/system/electrumx.service
  echo "ExecStart=/usr/bin/python3 /home/bitcoin/electrumx/electrumx_server" >> /etc/systemd/system/electrumx.service
  echo "User=bitcoin" >> /etc/systemd/system/electrumx.service
  echo "Group=bitcoin" >> /etc/systemd/system/electrumx.service
  echo "Type=simple" >> /etc/systemd/system/electrumx.service
  echo "Restart=always" >> /etc/systemd/system/electrumx.service
  echo "RestartSec=10" >> /etc/systemd/system/electrumx.service
  echo "EnvironmentFile=/home/bitcoin/.electrumx.env" >> /etc/systemd/system/electrumx.service
  echo "" >> /etc/systemd/system/electrumx.service
  echo "[Install]" >> /etc/systemd/system/electrumx.service
  echo "WantedBy=multi-user.target" >> /etc/systemd/system/electrumx.service
fi

echo "🔐 Step 14: Setting up bootstrap RPC credentials..."
ls -la /boot/bootstrap-rpc-creds.sh || echo "❌ Bootstrap script not found in /boot"
echo "🔍 Debug: File name check: $(basename /boot/bootstrap-rpc-creds.sh)"
echo "🔍 Debug: File name length: $(basename /boot/bootstrap-rpc-creds.sh | wc -c)"
install -m 0755 /boot/bootstrap-rpc-creds.sh /usr/local/bin/bootstrap-rpc-creds.sh
echo "🔍 Debug: Bootstrap script installed to /usr/local/bin/"
ls -la /usr/local/bin/bootstrap-rpc-creds.sh || echo "❌ Failed to install bootstrap script"
echo "🔍 Debug: Installed file name: $(basename /usr/local/bin/bootstrap-rpc-creds.sh)"

echo "🔍 Debug: Testing bootstrap script execution..."
echo "🔍 Debug: Script shebang: $(head -1 /usr/local/bin/bootstrap-rpc-creds.sh)"
echo "🔍 Debug: Script permissions: $(ls -la /usr/local/bin/bootstrap-rpc-creds.sh)"
/usr/local/bin/bootstrap-rpc-creds.sh || echo "❌ Bootstrap script execution failed"

echo "[Unit]" > /etc/systemd/system/bootstrap-rpc-creds.service
echo "Description=Bootstrap RPC Credentials for Bitcoin" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "After=network.target" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "Before=bitcoind.service" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "[Service]" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "Type=oneshot" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "ExecStart=/usr/local/bin/bootstrap-rpc-creds.sh" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "[Install]" >> /etc/systemd/system/bootstrap-rpc-creds.service
echo "WantedBy=multi-user.target" >> /etc/systemd/system/bootstrap-rpc-creds.service

cat /etc/systemd/system/bootstrap-rpc-creds.service

if [ -x "/usr/local/bin/bootstrap-rpc-creds.sh" ]; then
    echo "✅ Bootstrap script is executable"
else
    echo "❌ Bootstrap script is not executable or doesn't exist"
    echo "🔍 Debug: Script status: $(ls -la /usr/local/bin/bootstrap-rpc-creds.sh 2>/dev/null || echo 'NOT FOUND')"
    exit 1
fi

echo "🔧 Step 15: Setting up firstboot wizard..."
install -m 0755 /boot/firstboot-setup.sh /usr/local/bin/firstboot-setup.sh
cat /boot/firstboot-setup.service > /etc/systemd/system/firstboot-setup.service

# Ensure timeout command is available
if ! command -v timeout &> /dev/null; then
  echo "⚠️ timeout command not found, installing coreutils..."
  apt-get install -y coreutils || echo "Warning: Failed to install coreutils"
fi

echo "🌐 Step 16: Installing Flotilla Nostr Web UI..."
echo "   Note: Flotilla may fail to build due to missing dependencies."
echo "   If build fails, the system will continue without Flotilla."
echo "   You can manually install it later if needed."
cd /home/bitcoin
if [ ! -d "/home/bitcoin/flotilla" ]; then
  sudo -u bitcoin git clone https://github.com/coracle-social/flotilla.git || echo "Warning: Flotilla clone failed"
fi

if [ -d "/home/bitcoin/flotilla" ]; then
  cd /home/bitcoin/flotilla
  echo "🔍 Debug: Flotilla directory found, checking package.json..."
  
  if [ -f "package.json" ]; then
    echo "🔍 Debug: package.json found, checking build scripts..."
    cat package.json | grep -E '"scripts"' -A 10 || echo "No scripts section found"
    
    # Install all dependencies (including dev dependencies needed for build)
    echo "📦 Installing Flotilla dependencies..."
    echo "   This may take several minutes..."
    timeout 600 sudo -u bitcoin npm install --audit=false || echo "Warning: Flotilla npm install failed (timeout or error)"
    
    # Check if build script exists
    if grep -q '"build"' package.json; then
      echo "🔨 Attempting to build Flotilla..."
      echo "   This may take several minutes..."
      timeout 900 sudo -u bitcoin npm run build || echo "Warning: Flotilla build failed (timeout or error)"
      
      # Check if build created output directory
      if [ -d "dist" ] || [ -d "build" ]; then
        echo "✅ Build succeeded, updating start script for production..."
        if [ -f "package.json" ]; then
          sed -i 's/"start":.*/"start": "vite preview --host 0.0.0.0",/' package.json || true
        fi
      else
        echo "🔄 Build failed, trying alternative approach with dev server..."
        # Try alternative approach - install only production deps and use dev server
        timeout 300 sudo -u bitcoin npm install --production --audit=false || echo "Warning: Flotilla production install failed"
        
        # Update package.json to use dev server instead of build
        if [ -f "package.json" ]; then
          sed -i 's/"start":.*/"start": "vite --host 0.0.0.0",/' package.json || true
          sed -i 's/"dev":.*/"dev": "vite --host 0.0.0.0",/' package.json || true
        fi
        
        # If still failing, create a simple alternative
        if [ ! -f "package.json" ] || ! grep -q '"start"' package.json; then
          echo "⚠️ Flotilla installation completely failed, creating simple alternative..."
          # Remove the problematic Flotilla directory
          cd /home/bitcoin
          rm -rf flotilla
          echo "✅ Removed problematic Flotilla installation"
        fi
      fi
    else
      echo "⚠️ No build script found, using dev server..."
      # No build script, use dev server
      if [ -f "package.json" ]; then
        sed -i 's/"start":.*/"start": "vite --host 0.0.0.0",/' package.json || true
      fi
    fi
  else
    echo "⚠️ package.json not found in Flotilla directory"
  fi
else
  echo "⚠️ Flotilla directory not found, skipping npm install"
fi

# Create a simple fallback Nostr web interface if Flotilla fails
echo "🔧 Creating fallback Nostr web interface..."
mkdir -p /home/bitcoin/nostr-fallback
cat > /home/bitcoin/nostr-fallback/index.html << 'NOSTR_FALLBACK_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nostr Client - Bitcoin Node</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #1a1a1a; color: #fff; }
        .container { max-width: 800px; margin: 0 auto; }
        .header { text-align: center; margin-bottom: 30px; }
        .section { background: #2a2a2a; padding: 20px; margin: 20px 0; border-radius: 8px; }
        .input-group { margin: 10px 0; }
        input, textarea { width: 100%; padding: 10px; margin: 5px 0; background: #333; color: #fff; border: 1px solid #555; border-radius: 4px; }
        button { background: #007bff; color: white; padding: 10px 20px; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #0056b3; }
        .status { padding: 10px; margin: 10px 0; border-radius: 4px; }
        .success { background: #28a745; }
        .error { background: #dc3545; }
        .info { background: #17a2b8; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🟢 Nostr Client - Bitcoin Node</h1>
            <p>Simple Nostr client for your Bitcoin node</p>
        </div>
        
        <div class="section">
            <h2>📝 Create Note</h2>
            <div class="input-group">
                <textarea id="noteContent" placeholder="Enter your note content..." rows="4"></textarea>
            </div>
            <button onclick="createNote()">📤 Publish Note</button>
            <div id="noteStatus"></div>
        </div>
        
        <div class="section">
            <h2>🔍 Search Notes</h2>
            <div class="input-group">
                <input type="text" id="searchQuery" placeholder="Enter search terms...">
            </div>
            <button onclick="searchNotes()">🔍 Search</button>
            <div id="searchResults"></div>
        </div>
        
        <div class="section">
            <h2>⚙️ Configuration</h2>
            <div class="input-group">
                <label>Relay URL:</label>
                <input type="text" id="relayUrl" value="wss://relay.damus.io" placeholder="Enter relay URL">
            </div>
            <div class="input-group">
                <label>Private Key (hex):</label>
                <input type="password" id="privateKey" placeholder="Enter your private key">
            </div>
            <button onclick="saveConfig()">💾 Save Configuration</button>
            <div id="configStatus"></div>
        </div>
        
        <div class="section">
            <h2>📊 Status</h2>
            <div id="connectionStatus" class="status info">Not connected to relay</div>
            <button onclick="connectToRelay()">🔌 Connect to Relay</button>
        </div>
    </div>
    
    <script>
        let relay = null;
        let connected = false;
        
        function showStatus(elementId, message, type = 'info') {
            const element = document.getElementById(elementId);
            element.textContent = message;
            element.className = `status ${type}`;
        }
        
        function connectToRelay() {
            const relayUrl = document.getElementById('relayUrl').value;
            if (!relayUrl) {
                showStatus('connectionStatus', 'Please enter a relay URL', 'error');
                return;
            }
            
            try {
                relay = new WebSocket(relayUrl);
                relay.onopen = () => {
                    connected = true;
                    showStatus('connectionStatus', 'Connected to relay', 'success');
                };
                relay.onclose = () => {
                    connected = false;
                    showStatus('connectionStatus', 'Disconnected from relay', 'error');
                };
                relay.onerror = (error) => {
                    connected = false;
                    showStatus('connectionStatus', 'Connection error: ' + error.message, 'error');
                };
            } catch (error) {
                showStatus('connectionStatus', 'Failed to connect: ' + error.message, 'error');
            }
        }
        
        function createNote() {
            if (!connected) {
                showStatus('noteStatus', 'Please connect to a relay first', 'error');
                return;
            }
            
            const content = document.getElementById('noteContent').value;
            if (!content) {
                showStatus('noteStatus', 'Please enter note content', 'error');
                return;
            }
            
            // Simple note creation (in a real implementation, you'd use proper Nostr libraries)
            const note = {
                kind: 1,
                content: content,
                created_at: Math.floor(Date.now() / 1000),
                tags: []
            };
            
            showStatus('noteStatus', 'Note created (demo mode - not actually sent)', 'success');
        }
        
        function searchNotes() {
            if (!connected) {
                showStatus('searchResults', 'Please connect to a relay first', 'error');
                return;
            }
            
            const query = document.getElementById('searchQuery').value;
            if (!query) {
                showStatus('searchResults', 'Please enter search terms', 'error');
                return;
            }
            
            showStatus('searchResults', `Searching for: "${query}" (demo mode)`, 'info');
        }
        
        function saveConfig() {
            const relayUrl = document.getElementById('relayUrl').value;
            const privateKey = document.getElementById('privateKey').value;
            
            if (relayUrl && privateKey) {
                showStatus('configStatus', 'Configuration saved (demo mode)', 'success');
            } else {
                showStatus('configStatus', 'Please fill in all fields', 'error');
            }
        }
    </script>
</body>
</html>
NOSTR_FALLBACK_EOF

chown -R bitcoin:bitcoin /home/bitcoin/nostr-fallback
echo "✅ Fallback Nostr interface created at /home/bitcoin/nostr-fallback/index.html"

# Only create Flotilla service if the directory exists and has a package.json
if [ -d "/home/bitcoin/flotilla" ] && [ -f "/home/bitcoin/flotilla/package.json" ]; then
  echo "[Unit]" > /etc/systemd/system/flotilla.service
  echo "Description=Flotilla Nostr Web UI" >> /etc/systemd/system/flotilla.service
  echo "After=network.target btcnode-api.service" >> /etc/systemd/system/flotilla.service
  echo "" >> /etc/systemd/system/flotilla.service
  echo "[Service]" >> /etc/systemd/system/flotilla.service
  echo "WorkingDirectory=/home/bitcoin/flotilla" >> /etc/systemd/system/flotilla.service
  echo "ExecStart=/usr/bin/npm run start" >> /etc/systemd/system/flotilla.service
  echo "User=bitcoin" >> /etc/systemd/system/flotilla.service
  echo "Restart=always" >> /etc/systemd/system/flotilla.service
  echo "" >> /etc/systemd/system/flotilla.service
  echo "[Install]" >> /etc/systemd/system/flotilla.service
  echo "WantedBy=multi-user.target" >> /etc/systemd/system/flotilla.service
  echo "✅ Flotilla service created"
else
  echo "⚠️ Flotilla service not created (directory or package.json not found)"
fi

echo "🔌 Step 17: Installing Bitcoin Node API server..."
mkdir -p /home/bitcoin/server
cp -r /boot/server/* /home/bitcoin/server/
chown -R bitcoin:bitcoin /home/bitcoin/server
cd /home/bitcoin/server
sudo -u bitcoin npm install --production --audit=false || echo "Warning: Bitcoin Node API npm install failed"

cp /boot/btcnode-api.service /etc/systemd/system/btcnode-api.service
chmod 644 /etc/systemd/system/btcnode-api.service
chown -R bitcoin:bitcoin /home/bitcoin/server

echo "🧹 Step 18: Final cleanup..."
apt-get autoremove -y
apt-get autoclean
apt-get clean
rm -rf /var/lib/apt/lists/*

if [ -f "/etc/apt/sources.list.d/bullseye-backports.list" ]; then
    rm /etc/apt/sources.list.d/bullseye-backports.list
fi

rm -rf /tmp/*
rm -rf /var/tmp/*
rm -rf /var/cache/apt/archives/*

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

echo "🔧 Note: No swap file cleanup needed (swap files not created in chroot)"

echo "#!/bin/bash" > /usr/local/bin/enable-services.sh
echo "# Enable all services on first boot" >> /usr/local/bin/enable-services.sh
echo "systemctl enable ssh" >> /usr/local/bin/enable-services.sh
echo "systemctl enable bitcoind.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable lnd.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable electrumx.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable btcnode-api.service" >> /usr/local/bin/enable-services.sh
echo "# Conditionally enable Flotilla if it exists" >> /usr/local/bin/enable-services.sh
echo "if [ -f '/etc/systemd/system/flotilla.service' ]; then" >> /usr/local/bin/enable-services.sh
echo "  systemctl enable flotilla.service" >> /usr/local/bin/enable-services.sh
echo "fi" >> /usr/local/bin/enable-services.sh
echo "systemctl enable bootstrap-rpc-creds.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable firstboot-setup.service" >> /usr/local/bin/enable-services.sh
chmod +x /usr/local/bin/enable-services.sh

echo "🌐 Web Interface Access Information:"
echo "   - Bitcoin Node API: http://pi.local:3000"
if [ -d "/home/bitcoin/flotilla" ] && [ -f "/home/bitcoin/flotilla/package.json" ]; then
  echo "   - Flotilla Nostr Client: http://pi.local:5173"
else
  echo "   - Flotilla Nostr Client: Not installed (build issues)"
  echo "   - Fallback Nostr Interface: http://pi.local:3000/nostr-fallback"
fi
echo "   - BTCPay Server: http://pi.local (after setup)"
echo "   - SSH access: ssh pi@pi.local (password: raspberry)"
echo "   - SSH port forward: ssh -L 3000:localhost:3000 pi@pi.local"
echo "   - Default credentials: pi/raspberry"
echo "   - Bitcoin user: bitcoin (no password)"

echo "✅ Chroot customization complete!"
CHROOT_SCRIPT_EOF

# Copy the script to the chroot environment and execute it
sudo cp /tmp/chroot-script.sh $ROOT/tmp/chroot-script.sh
sudo chmod +x $ROOT/tmp/chroot-script.sh
sudo chroot $ROOT /tmp/chroot-script.sh

# Clean up the temporary script
sudo rm -f $ROOT/tmp/chroot-script.sh
rm -f /tmp/chroot-script.sh

# Step 9: Cleanup mounts and detach loop
sudo umount $ROOT/{dev,proc,sys,boot}
sudo umount $ROOT
sudo losetup -d "$LOOP"

echo "✅ Customization complete. Image is ready for compression."
