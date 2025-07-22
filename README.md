# Bitcoin Node Raspberry Pi Image

A pre-configured Raspberry Pi OS image that automatically sets up a complete Bitcoin node with additional services including BTCPay Server, Flotilla Nostr client, and a web-based management interface.

## Features

- **Bitcoin Core 25.1** - Full Bitcoin node with RPC access and transaction indexing
- **Lightning Network (LND)** - Lightning Network node for instant payments
- **Electrum Server** - ElectrumX server for wallet connectivity
- **BTCPay Server** - Complete Bitcoin payment processor
- **Flotilla** - Nostr social media client
- **Web Dashboard** - Management interface at `http://pi.local:3000`
- **WiFi Configuration** - Easy network setup
- **Automatic RPC Credentials** - Secure credential generation
- **Systemd Services** - All services run automatically on boot
- **Storage Monitoring** - Real-time disk usage and service status
- **Optimized for 1TB NVMe SSD** - Full node performance with fast sync

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

On first boot, the system will:

1. **Generate secure RPC credentials** for Bitcoin Core
2. **Start the web interface** at `http://pi.local:3000`
3. **Enable all services** (Bitcoin Core, BTCPay, Flotilla)

### Default Credentials

- **SSH**: `pi` / `raspberry`
- **Bitcoin User**: `bitcoin` (no password)
- **RPC Credentials**: Generated automatically, stored in `/home/bitcoin/rpc-credentials.txt`

## Web Interface

Access the management dashboard at `http://pi.local:3000` to:

- Configure WiFi settings
- Adjust Bitcoin node parameters
- Start BTCPay Server
- Generate Nostr keys
- Monitor system status

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
- **URL**: `http://pi.local` (after setup)
- **Setup Script**: `/home/bitcoin/btcpayserver/start-btcpay.sh`
- **Docker-based installation**

### Flotilla Nostr Client
- **URL**: `http://pi.local:5173`
- **Directory**: `/home/bitcoin/flotilla`

### Web API Server
- **Port**: 3000
- **URL**: `http://pi.local:3000`
- **Features**: Bitcoin status, WiFi config, system monitoring

## Configuration

### WiFi Setup
```bash
# Via web interface at http://pi.local:3000
# Or manually edit /etc/wpa_supplicant/wpa_supplicant.conf
```

### Bitcoin Configuration
```bash
# Via web interface or edit /home/bitcoin/.bitcoin/bitcoin.conf
# Key settings: prune, dbcache, maxconnections
```

### RPC Access
```bash
# Get credentials from /home/bitcoin/rpc-credentials.txt
# Or use the web interface to view them
```

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
   - Check if service is running: `sudo systemctl status btcnode-api`
   - Verify port 3000 is open: `netstat -tlnp | grep 3000`

4. **BTCPay Server issues**
   - Ensure Docker is installed: `docker --version`
   - Check BTCPay logs: `docker logs btcpayserver_btcpayserver_1`

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

- Change default SSH password
- Use firewall rules (UFW is pre-installed)
- Keep system updated: `sudo apt update && sudo apt upgrade`
- Monitor disk space for Bitcoin blockchain
- Consider using a VPN for remote access

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `scripts/test-syntax.sh`
5. Submit a pull request

## License

This project is open source. See individual component licenses for details.

## Support

- GitHub Issues: [Create an issue](https://github.com/your-repo/issues)
- Documentation: Check the scripts and configuration files
- Community: Bitcoin and BTCPay Server communities 