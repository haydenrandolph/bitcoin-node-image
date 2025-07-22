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
# Required packages (except nodejs) with non-interactive flags
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y --no-install-recommends curl wget git ufw fail2ban tor iptables python3-pip python3-setuptools python3-wheel htop libevent-2.1-7 liberror-perl git-man sudo ca-certificates

# Clean up after package installation to free memory
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "🖥️ Step 4: Installing desktop environment..."
# ----------- Add desktop & browser for local HDMI experience -----------
# Try to install desktop packages, but don't fail if they're not available
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y --no-install-recommends xserver-xorg xinit raspberrypi-sys-mods chromium-browser unclutter || echo "Warning: Some desktop packages not available, continuing without desktop"

# Clean up after desktop installation
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "👤 Step 5: Setting up bitcoin user and desktop..."
# Autologin for the bitcoin user to desktop (only if lightdm is available)
if [ -f "/etc/lightdm/lightdm.conf" ]; then
  if ! grep -q "autologin-user=bitcoin" /etc/lightdm/lightdm.conf; then
    sed -i "s/^#*autologin-user=.*/autologin-user=bitcoin/" /etc/lightdm/lightdm.conf
  fi
fi

# Set Chromium to autostart in kiosk mode (only if desktop is available)
if command -v chromium-browser &> /dev/null; then
  mkdir -p /home/bitcoin/.config/lxsession/LXDE-pi/
  echo '@chromium-browser --kiosk --incognito --noerrdialogs --disable-infobars http://localhost:3000' >> /home/bitcoin/.config/lxsession/LXDE-pi/autostart
  echo '@unclutter -idle 1' >> /home/bitcoin/.config/lxsession/LXDE-pi/autostart
  echo "✅ Desktop autostart configured"
else
  echo "⚠️ Chromium not available, skipping desktop autostart"
  echo "📝 Note: Access the web interface at http://pi.local:3000 or via SSH port forwarding"
fi

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

echo "🟢 Step 6: Installing Node.js..."
# ----------- Install Node.js 20 LTS (for flotilla and backend) -----------
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y nodejs
npm install -g npm@latest

# Clean up after Node.js installation
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "🐳 Step 7: Installing Docker..."
# ----------- Install Docker and Docker Compose for BTCPay ----------------------
# Clear apt cache to free memory
apt-get clean
rm -rf /var/lib/apt/lists/*

# Install Docker using package manager instead of get-docker.sh script
echo "📦 Installing Docker from Debian repositories..."
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y docker.io docker-compose-plugin || echo "Warning: Docker installation failed, will try alternative method"

# If Docker installation failed, try alternative method
if ! command -v docker &> /dev/null; then
    echo "🔄 Trying alternative Docker installation method..."
    # Install Docker using snap (more reliable in chroot)
    apt-get install -y snapd
    snap install docker --classic || echo "Warning: Snap Docker installation failed"
fi

# Add bitcoin user to docker group if docker is available
if command -v docker &> /dev/null; then
    usermod -aG docker bitcoin
    echo "✅ Docker installed successfully"
else
    echo "⚠️ Docker installation failed, BTCPay may not work properly"
fi

echo "💰 Step 8: Setting up BTCPay Server..."
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

echo "📜 Step 9: Creating BTCPay startup script..."
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

echo "🪙 Step 10: Installing Bitcoin Core..."
# ----------- Install Bitcoin Core -----------------------------------------------
BITCOIN_VERSION=25.1
cd /tmp
wget https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz || echo "Warning: Bitcoin download failed"
tar -xvf bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz || echo "Warning: Bitcoin extraction failed"
install -m 0755 -o root -g root -t /usr/local/bin bitcoin-${BITCOIN_VERSION}/bin/* || echo "Warning: Bitcoin install failed"
rm -rf bitcoin-${BITCOIN_VERSION}*

echo "⚙️ Step 11: Setting up Bitcoin configuration..."
# Placeholder bitcoin.conf (patched at boot)
echo "server=1" > /home/bitcoin/.bitcoin/bitcoin.conf
echo "daemon=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "txindex=1" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcuser=REPLACE_USER" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcpassword=REPLACE_PASS" >> /home/bitcoin/.bitcoin/bitcoin.conf
echo "rpcallowip=127.0.0.1" >> /home/bitcoin/.bitcoin/bitcoin.conf

chown bitcoin:bitcoin /home/bitcoin/.bitcoin/bitcoin.conf
chmod 600 /home/bitcoin/.bitcoin/bitcoin.conf

echo "🔧 Step 12: Creating systemd services..."
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

systemctl enable bitcoind.service

echo "🔐 Step 13: Setting up bootstrap RPC credentials..."
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
    systemctl enable bootstrap-rpc-creds.service
else
    echo "❌ Bootstrap script is not executable or doesn't exist"
    echo "🔍 Debug: Script status: $(ls -la /usr/local/bin/bootstrap-rpc-creds.sh 2>/dev/null || echo 'NOT FOUND')"
    exit 1
fi

echo "🔧 Step 14: Setting up firstboot wizard..."
# ----------- Install firstboot wizard and enable systemd oneshot ---------------
install -m 0755 /boot/firstboot-setup.sh /usr/local/bin/firstboot-setup.sh
cat /boot/firstboot-setup.service > /etc/systemd/system/firstboot-setup.service
systemctl enable firstboot-setup.service

echo "🌐 Step 15: Installing Flotilla Nostr Web UI..."
# ----------- Install Flotilla Nostr Web UI and enable systemd service -----------
cd /home/bitcoin
if [ ! -d "/home/bitcoin/flotilla" ]; then
  sudo -u bitcoin git clone https://github.com/coracle-social/flotilla.git || echo "Warning: Flotilla clone failed"
fi

# Only proceed with npm install if the directory exists
if [ -d "/home/bitcoin/flotilla" ]; then
  cd /home/bitcoin/flotilla
  sudo -u bitcoin npm install || echo "Warning: Flotilla npm install failed"
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

systemctl enable flotilla.service

echo "🔌 Step 16: Installing Bitcoin Node API server..."
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

echo "🧹 Step 17: Final cleanup..."
# ------------------------------------------------------------------------------------

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*

# Add helpful access information
echo "🌐 Web Interface Access Information:"
echo "   - Local access: http://pi.local:3000"
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
sudo rm $ROOT/tmp/chroot-script.sh
rm /tmp/chroot-script.sh

# Step 9: Cleanup mounts and detach loop
sudo umount $ROOT/{dev,proc,sys,boot}
sudo umount $ROOT
sudo losetup -d "$LOOP"

echo "✅ Customization complete. Image is ready for compression."