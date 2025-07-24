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
# Check available memory and system resources
echo "🔍 System resource check:"
echo "   Memory: $(free -h | grep Mem | awk '{print $2}') total, $(free -h | grep Mem | awk '{print $7}') available"
echo "   Disk: $(df -h / | tail -1 | awk '{print $2}') total, $(df -h / | tail -1 | awk '{print $4}') available"
echo "   Load: $(uptime | awk -F'load average:' '{print $2}')"

# Check if swap file already exists and is mounted
if [ -f /swapfile ] && swapon --show | grep -q /swapfile; then
    echo "🔧 Swap file already exists and is mounted, skipping creation..."
else
    # Create swap file if needed for memory-intensive operations
    if [ ! -f /swapfile ]; then
        echo "🔧 Creating 1GB swap file for memory-intensive operations..."
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

# Prevent services from starting in chrooted apt operations
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
export DEBIAN_FRONTEND=noninteractive

# Configure dpkg to use default options for configuration files
echo 'Dpkg::Options::="--force-confdef";' > /etc/apt/apt.conf.d/99force-confdef
echo 'Dpkg::Options::="--force-confold";' >> /etc/apt/apt.conf.d/99force-confdef

echo "📦 Step 2: Updating packages..."
apt update

# Prevent bloated kernel header upgrades
apt-mark hold linux-headers-* linux-image-* rpi-eeprom || true

# Graceful upgrade and cleanup with non-interactive flags
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y || true
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --fix-broken install -y || true

# Fix initramfs-tools configuration issue specifically
echo "🔧 Fixing initramfs-tools configuration..."
echo "Y" | DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

echo "📦 Step 3: Installing required packages..."
# Essential packages for Bitcoin node and enhanced features
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y --no-install-recommends \
    curl wget git ca-certificates \
    python3-pip \
    libevent-2.1-7 liberror-perl git-man || echo "Warning: Some packages failed to install"

# Clean up after package installation to free memory
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

echo "🔐 Step 3.5: Setting up SSH configuration..."
# Install SSH server without enabling it in chroot
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y openssh-server || echo "Warning: SSH installation failed"

# Configure SSH for better security (don't enable in chroot)
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

# Create SSH directories for users
mkdir -p /home/pi/.ssh
chown pi:pi /home/pi/.ssh
chmod 700 /home/pi/.ssh

echo "👤 Step 4: Setting up bitcoin user..."
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

# Create SSH directory for bitcoin user (after user is created)
mkdir -p /home/bitcoin/.ssh
chown bitcoin:bitcoin /home/bitcoin/.ssh
chmod 700 /home/bitcoin/.ssh

echo "🟢 Step 5: Installing Node.js..."
# ----------- Install Node.js 20 LTS (for API server and Flotilla) -----------
# Clear memory before Node.js installation
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

# Try official Node.js repository first
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || echo "Warning: Node.js repository setup failed"
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y nodejs || echo "Warning: Node.js installation failed"

# If Node.js installation failed, try from Debian repository
if ! command -v node &> /dev/null; then
    echo "🔄 Trying Node.js from Debian repository..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y nodejs || echo "Warning: Node.js installation completely failed"
fi

# Clean up after Node.js installation
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

echo "🐳 Step 6: Installing Docker..."
# ----------- Install Docker using official method ----------------------
# Clear apt cache to free memory
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

# Try installing Docker from Debian repository first (more memory efficient)
echo "📦 Installing Docker from Debian repository..."
apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y docker.io || echo "Warning: Docker installation failed"

# If that fails, try the official script as fallback
if ! command -v docker &> /dev/null; then
    echo "🔄 Trying official Docker installation script..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh --dry-run || sh get-docker.sh || echo "Warning: Docker installation failed"
    rm -f get-docker.sh
fi

# Add bitcoin user to docker group if docker is available
if command -v docker &> /dev/null; then
    usermod -aG docker bitcoin
    echo "✅ Docker installed successfully"
else
    echo "⚠️ Docker installation failed, BTCPay will need manual setup"
    echo "📝 Note: You can install Docker manually after first boot"
fi

# Clean up after Docker installation
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

echo "💰 Step 7: Setting up BTCPay Server..."
# ----------- Clone BTCPayServer repo (docker, ARM-ready) ----------------------
sudo -u bitcoin mkdir -p /home/bitcoin/btcpayserver
cd /home/bitcoin/btcpayserver
if [ ! -d "/home/bitcoin/btcpayserver/btcpayserver-docker" ]; then
  sudo -u bitcoin git clone https://github.com/btcpayserver/btcpayserver-docker.git || echo "Warning: BTCPay clone failed"
fi
chown -R bitcoin:bitcoin /home/bitcoin/btcpayserver

# Check if Docker is available for BTCPay
if ! command -v docker &> /dev/null; then
    echo "⚠️ Docker not available, BTCPay will need manual setup"
    echo "📝 Note: You can install Docker manually after first boot"
fi

echo "📜 Step 8: Creating BTCPay startup script..."
# ----------- BTCPay easy startup script ---------------------------------------
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
# -------------------------------------------------------------------------------

echo "🪙 Step 9: Installing Bitcoin Core..."
# ----------- Install Bitcoin Core -----------------------------------------------
# Clear memory before Bitcoin installation
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
# Full node bitcoin.conf optimized for 1TB NVMe SSD
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
# bitcoind systemd service
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

# Don't enable services in chroot - they'll be enabled on first boot
echo "📝 Note: Services will be enabled on first boot, not in chroot"

echo "⚡ Step 12: Installing Lightning Network (LND)..."
# ----------- Install Lightning Network (LND) ------------------------------------
# Clear memory before LND installation
apt-get clean
rm -rf /var/lib/apt/lists/*
sync

cd /tmp
LND_VERSION=v0.17.0-beta
wget https://github.com/lightningnetwork/lnd/releases/download/${LND_VERSION}/lnd-linux-arm64-v${LND_VERSION}.tar.gz || echo "Warning: LND download failed"
tar -xzf lnd-linux-arm64-v${LND_VERSION}.tar.gz || echo "Warning: LND extraction failed"
install -m 0755 -o root -g root -t /usr/local/bin lnd-linux-arm64-v${LND_VERSION}/* || echo "Warning: LND install failed"
rm -rf lnd-linux-arm64-v${LND_VERSION}*

# Create LND directory
mkdir -p /home/bitcoin/.lnd
chown -R bitcoin:bitcoin /home/bitcoin/.lnd

# LND configuration
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

# LND systemd service
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
# ----------- Install Electrum Server -------------------------------------------
cd /home/bitcoin
if [ ! -d "/home/bitcoin/electrumx" ]; then
  sudo -u bitcoin git clone https://github.com/spesmilo/electrumx.git || echo "Warning: ElectrumX clone failed"
fi

if [ -d "/home/bitcoin/electrumx" ]; then
  cd /home/bitcoin/electrumx
  sudo -u bitcoin python3 -m pip install --no-cache-dir -r requirements.txt || echo "Warning: ElectrumX requirements failed"
  
  # ElectrumX configuration
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
  
  # ElectrumX systemd service
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
# Bootstrap RPC credentials service
echo "🔍 Debug: Installing bootstrap script..."
ls -la /boot/bootstrap-rpc-creds.sh || echo "❌ Bootstrap script not found in /boot"
echo "🔍 Debug: File name check: $(basename /boot/bootstrap-rpc-creds.sh)"
echo "🔍 Debug: File name length: $(basename /boot/bootstrap-rpc-creds.sh | wc -c)"
install -m 0755 /boot/bootstrap-rpc-creds.sh /usr/local/bin/bootstrap-rpc-creds.sh
echo "🔍 Debug: Bootstrap script installed to /usr/local/bin/"
ls -la /usr/local/bin/bootstrap-rpc-creds.sh || echo "❌ Failed to install bootstrap script"
echo "🔍 Debug: Installed file name: $(basename /usr/local/bin/bootstrap-rpc-creds.sh)"

# Test the script execution
echo "🔍 Debug: Testing bootstrap script execution..."
echo "🔍 Debug: Script shebang: $(head -1 /usr/local/bin/bootstrap-rpc-creds.sh)"
echo "🔍 Debug: Script permissions: $(ls -la /usr/local/bin/bootstrap-rpc-creds.sh)"
/usr/local/bin/bootstrap-rpc-creds.sh || echo "❌ Bootstrap script execution failed"

# Create bootstrap service file using echo to avoid heredoc issues
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

# Verify the service file was created correctly
echo "🔍 Debug: Service file contents:"
cat /etc/systemd/system/bootstrap-rpc-creds.service

# Verify the script exists and is executable
echo "🔍 Debug: Verifying script exists and is executable..."
if [ -x "/usr/local/bin/bootstrap-rpc-creds.sh" ]; then
    echo "✅ Bootstrap script is executable"
else
    echo "❌ Bootstrap script is not executable or doesn't exist"
    echo "🔍 Debug: Script status: $(ls -la /usr/local/bin/bootstrap-rpc-creds.sh 2>/dev/null || echo 'NOT FOUND')"
    exit 1
fi

echo "🔧 Step 15: Setting up firstboot wizard..."
# ----------- Install firstboot wizard and enable systemd oneshot ---------------
install -m 0755 /boot/firstboot-setup.sh /usr/local/bin/firstboot-setup.sh
cat /boot/firstboot-setup.service > /etc/systemd/system/firstboot-setup.service

echo "🌐 Step 16: Installing Flotilla Nostr Web UI..."
# ----------- Install Flotilla Nostr Web UI and enable systemd service -----------
cd /home/bitcoin
if [ ! -d "/home/bitcoin/flotilla" ]; then
  sudo -u bitcoin git clone https://github.com/coracle-social/flotilla.git || echo "Warning: Flotilla clone failed"
fi

# Only proceed with npm install if the directory exists
if [ -d "/home/bitcoin/flotilla" ]; then
  cd /home/bitcoin/flotilla
  sudo -u bitcoin npm install --production --audit=false || echo "Warning: Flotilla npm install failed"
  sudo -u bitcoin npm run build || echo "Warning: Flotilla build failed"
else
  echo "⚠️ Flotilla directory not found, skipping npm install"
fi

# Update package.json start script if it exists
if [ -f "package.json" ]; then
  sed -i "s/\"start\":.*/\"start\": \"vite preview --host 0.0.0.0\",/" package.json || true
fi

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

echo "🔌 Step 17: Installing Bitcoin Node API server..."
# ----------- Install Bitcoin Node API server (Express.js) ------------------------
mkdir -p /home/bitcoin/server
cp -r /boot/server/* /home/bitcoin/server/
chown -R bitcoin:bitcoin /home/bitcoin/server
cd /home/bitcoin/server
sudo -u bitcoin npm install --production --audit=false

# Copy and enable systemd service
cp /boot/btcnode-api.service /etc/systemd/system/btcnode-api.service
chmod 644 /etc/systemd/system/btcnode-api.service

# Ensure correct ownership
chown -R bitcoin:bitcoin /home/bitcoin/server

echo "🧹 Step 18: Final cleanup..."
# ------------------------------------------------------------------------------------

# Aggressive memory cleanup
echo "🧹 Cleaning up memory and disk space..."

# Remove unnecessary packages to save space
apt-get autoremove -y
apt-get autoclean

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*

# Fix repository issues by removing problematic sources
if [ -f "/etc/apt/sources.list.d/bullseye-backports.list" ]; then
    rm /etc/apt/sources.list.d/bullseye-backports.list
fi

# Clean up temporary files
rm -rf /tmp/*
rm -rf /var/tmp/*
rm -rf /var/cache/apt/archives/*

# Force memory cleanup
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# Disable swap file to clean up
if [ -f /swapfile ]; then
    echo "🧹 Disabling swap file..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    # Remove swap entry from fstab
    sed -i '/\/swapfile/d' /etc/fstab
fi

# Create a script to enable services on first boot
echo "#!/bin/bash" > /usr/local/bin/enable-services.sh
echo "# Enable all services on first boot" >> /usr/local/bin/enable-services.sh
echo "systemctl enable ssh" >> /usr/local/bin/enable-services.sh
echo "systemctl enable bitcoind.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable lnd.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable electrumx.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable btcnode-api.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable flotilla.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable bootstrap-rpc-creds.service" >> /usr/local/bin/enable-services.sh
echo "systemctl enable firstboot-setup.service" >> /usr/local/bin/enable-services.sh
chmod +x /usr/local/bin/enable-services.sh

# Add helpful access information
echo "🌐 Web Interface Access Information:"
echo "   - Bitcoin Node API: http://pi.local:3000"
echo "   - Flotilla Nostr Client: http://pi.local:5173"
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