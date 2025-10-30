# FML Moody Node - Bitcoin Full Node

⚡ **Feelin' Moody? Stack sats.** ⚡

A pre-configured Raspberry Pi image that automatically sets up a complete Bitcoin full node with Lightning Network, Nostr client, and Electrum server. Built for non-technical users who want a plug-and-play Bitcoin node experience.

## Features

- **Bitcoin Core 25.1** - Full Bitcoin node with RPC access and transaction indexing
- **Lightning Network (LND)** - Lightning Network node for instant payments
- **Electrum Server** - ElectrumX server for wallet connectivity
- **BTCPay Server** - Complete Bitcoin payment processor
- **Flotilla** - Nostr social media client
- **Web Dashboard** - Management interface at `http://moody-node.local:3000`
- **WiFi Configuration** - Simple setup wizard with visual feedback
- **Automatic RPC Credentials** - Secure credential generation
- **Systemd Services** - All services run automatically on boot
- **Storage Monitoring** - Real-time disk usage and service status
- **Optimized for 1TB SSD** - Full node performance with fast sync
- **Plug & Play** - Perfect for non-technical users

## Quick Start

### Option 1: Download Pre-built Image

#### Easy Download Scripts

**For macOS/Linux:**
```bash
# Clone the repository
git clone https://github.com/your-repo/bitcoin-node-image.git
cd bitcoin-node-image

# Save your GCP service account key as gcp-service-account-key.json
# (This is the same key used in your GitHub Actions GCP_SA_KEY secret)

# Run the download script
./download-image.sh
```

**For Windows:**
```cmd
# Clone the repository
git clone https://github.com/your-repo/bitcoin-node-image.git
cd bitcoin-node-image

# Save your GCP service account key as gcp-service-account-key.json
# (This is the same key used in your GitHub Actions GCP_SA_KEY secret)

# Run the download script
download-image.bat
```

#### Manual Download

1. Download the latest image from our GCP storage:
   ```bash
   curl -L 'https://storage.googleapis.com/bitcoin-node-artifact-store/raspberry-pi-bitcoin-node_latest.img.xz' -o bitcoin-node.img.xz
   xz -d bitcoin-node.img.xz
   ```

2. Write to SD card:
   ```bash
   sudo dd if=bitcoin-node.img of=/dev/sdX bs=4M status=progress
   ```

3. Insert SD card into Raspberry Pi and boot

### Option 2: Build Your Own Image

See [GCP_SETUP.md](GCP_SETUP.md) for instructions on setting up automated builds with GitHub Actions.

## First Boot Setup

On first boot, connect:
- **Power cable** to the Moody Node
- **HDMI monitor** (temporarily, for WiFi setup)
- **USB keyboard** (temporarily, for WiFi setup)

The setup wizard will guide you through:

1. **Mode Selection**: Choose Simple (recommended) or Advanced setup
2. **WiFi Configuration**: Enter your network name and password
3. **Optional Services** (Advanced mode): Select which services to enable
4. **Automatic Configuration**: Secure credentials generated automatically

After setup completes, the system reboots and you can:
- **Disconnect monitor and keyboard** (no longer needed!)
- **Access from your phone/laptop** at `http://moody-node.local:3000`

### Default Credentials

- **SSH**: `pi` / `raspberry` - **Change this immediately!**
- **Bitcoin User**: `bitcoin` (system user, no login)
- **RPC Credentials**: Auto-generated, view via dashboard or `/home/bitcoin/rpc-credentials.txt`

## Web Dashboard

Access from any device on your network: `http://moody-node.local:3000`

Features:
- **Real-time Bitcoin sync status** - See blockchain download progress
- **WiFi management** - Update WiFi settings without monitor
- **Node configuration** - Adjust Bitcoin Core parameters
- **Lightning & Electrum status** - Monitor all services
- **System resources** - CPU, memory, disk usage
- **Nostr client access** - Link to Flotilla at `:5173`

## Services

### Bitcoin Core
- **Port**: 8332 (RPC), 8333 (P2P), 28332-28333 (ZMQ)
- **Data Directory**: `/home/bitcoin/.bitcoin`
- **Config**: `/home/bitcoin/.bitcoin/bitcoin.conf`
- **Features**: Full node, transaction indexing, ZMQ support

### Lightning Network (LND)
- **Port**: 9735 (P2P), 10009 (RPC), 8080 (REST)
- **Data Directory**: `/home/bitcoin/.lnd`
- **Config**: `/home/bitcoin/.lnd/lnd.conf`
- **Features**: Lightning payments, channel management

### Electrum Server
- **Port**: 50001 (TCP), 50002 (SSL)
- **Data Directory**: `/home/bitcoin/.electrumx`
- **Config**: `/home/bitcoin/.electrumx.env`
- **Features**: Wallet connectivity, transaction history

### BTCPay Server
- **URL**: `http://moody-node.local` (after setup via dashboard)
- **Setup Script**: `/home/bitcoin/btcpayserver/start-btcpay.sh`
- **Docker-based installation**

### Flotilla Nostr Client
- **URL**: `http://moody-node.local:5173`
- **Directory**: `/home/bitcoin/flotilla`
- **Purpose**: Decentralized social communication on Nostr

### Web API Server
- **Port**: 3000
- **URL**: `http://moody-node.local:3000`
- **Features**: Bitcoin status, WiFi config, Lightning/Electrum monitoring, system resources

## Configuration

### WiFi Setup
Configure WiFi in two ways:
1. **First boot wizard** (recommended) - Interactive setup with password confirmation
2. **Web dashboard** - `http://moody-node.local:3000` → WiFi Setup section
3. **Manual** (advanced) - Edit `/etc/wpa_supplicant/wpa_supplicant.conf`

### Bitcoin Configuration
Adjust node settings:
1. **Web dashboard** - Update max connections, dbcache, pruning
2. **Manual** (advanced) - Edit `/home/bitcoin/.bitcoin/bitcoin.conf`

**Note:** RPC credentials are auto-generated and preserved across config changes.

### RPC Access
View credentials:
1. **Web dashboard** - System info section
2. **SSH** - `cat /home/bitcoin/rpc-credentials.txt`
3. **Via API** - `http://moody-node.local:3000/api/bitcoin/status`

## Development

### Building Locally

1. Install dependencies:
   ```bash
   sudo apt-get install -y qemu-user-static binfmt-support kpartx xz-utils curl git parted
   ```

2. Download base image:
   ```bash
   curl -L -o raspios.img.xz https://downloads.raspberrypi.org/raspios_lite_arm64_latest
   unxz raspios.img.xz
   mv *.img raspi-custom.img
   ```

3. Run customization script:
   ```bash
   chmod +x scripts/customize-image.sh scripts/bootstrap-rpc-creds.sh
   sudo scripts/customize-image.sh raspi-custom.img scripts/bootstrap-rpc-creds.sh
   ```

### Scripts

- `scripts/customize-image.sh` - Main image customization script
- `scripts/bootstrap-rpc-creds.sh` - Generate secure RPC credentials
- `scripts/firstboot-setup.sh` - First boot configuration wizard
- `scripts/test-syntax.sh` - Test all shell scripts for syntax errors
- `download-image.sh` - Download latest image from GCP storage
- `download-image.bat` - Windows version of download script

### Authentication

To use the download scripts, you need to save your GCP service account key as `gcp-service-account-key.json` in the project root. This should be the same key used in your GitHub Actions `GCP_SA_KEY` secret.

### Server Components

- `server/server.js` - Express.js API server
- `server/ui/` - Web interface files
- `server/package.json` - Node.js dependencies

## Troubleshooting

### Common Issues

1. **Image too large for SD card**
   - Use a 32GB+ SD card
   - The image is ~8GB uncompressed

2. **Bitcoin Core won't start**
   - Check RPC credentials in `/home/bitcoin/rpc-credentials.txt`
   - Verify disk space: `df -h`

3. **Web interface not accessible**
   - Verify you're on the same WiFi network as the Moody Node
   - Try accessing via IP: Check router for device IP address
   - Check if service is running: `sudo systemctl status btcnode-api`
   - Verify port 3000 is open: `netstat -tlnp | grep 3000`
   - Try from SSH tunnel: `ssh -L 3000:localhost:3000 pi@moody-node.local`

4. **BTCPay Server issues**
   - Ensure Docker is installed: `docker --version`
   - Check BTCPay logs: `docker logs btcpayserver_btcpayserver_1`

5. **Hostname not resolving (moody-node.local)**
   - Some Android devices don't support mDNS/Bonjour
   - Use IP address instead (check your router)
   - Or install "Bonjour Browser" app to find the device

### Logs

```bash
# Bitcoin Core logs
sudo journalctl -u bitcoind -f

# Web API logs
sudo journalctl -u btcnode-api -f

# BTCPay logs
docker logs btcpayserver_btcpayserver_1

# System logs
sudo journalctl -f
```

## Security Considerations

**IMPORTANT - Do these first!**
1. ✅ **Change default SSH password**: `passwd` (current: raspberry)
2. ✅ **Set up firewall**: UFW is pre-installed, configure as needed
3. ✅ **Keep system updated**: `sudo apt update && sudo apt upgrade`
4. ✅ **Monitor disk space**: Bitcoin blockchain grows continuously
5. ✅ **Secure your network**: Use strong WiFi password, consider VPN for remote access
6. ✅ **Back up credentials**: Save `/home/bitcoin/rpc-credentials.txt` securely

## What's Included

- ⚡ **Lightning Network** - Instant Bitcoin payments & routing
- 🟣 **Nostr Client** - Decentralized social communication
- 💼 **Electrum Server** - Connect your own Bitcoin wallet
- 💰 **BTCPay Server** - Optional payment processor for merchants
- 📊 **Web Dashboard** - Monitor everything from your phone
- 🔐 **Auto RPC Credentials** - Secure by default

## FML - Feelin' Moody?

This is more than just a Bitcoin node. It's your gateway to financial sovereignty.

**Stack sats. Stay humble. Feelin' Moody.**

## Support

- Built with ❤️ by the FML team
- Questions? Issues? Check the GitHub repo
- Community: Join us on Nostr using your Moody Node! 