#!/bin/bash

FLAG_FILE="/boot/firstboot-done"
if [ -f "$FLAG_FILE" ]; then
  exit 0
fi

# Colors for better UX
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Clear screen for clean start
clear

# ASCII Art Banner
echo -e "${GREEN}"
cat << "EOF"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║    ███████╗███╗   ███╗██╗                                     ║
║    ██╔════╝████╗ ████║██║                                     ║
║    █████╗  ██╔████╔██║██║                                     ║
║    ██╔══╝  ██║╚██╔╝██║██║                                     ║
║    ██║     ██║ ╚═╝ ██║███████╗                                ║
║    ╚═╝     ╚═╝     ╚═╝╚══════╝                                ║
║                                                                ║
║                 ⚡ FEELIN' MOODY? ⚡                           ║
║                                                                ║
║              MOODY NODE - FIRST TIME SETUP                     ║
║         Bitcoin Full Node + Lightning + Nostr                  ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${BOLD}Welcome!${NC} Let's get your Moody Node up and running.\n"
echo "This will only take a few minutes..."
echo ""
echo -e "${BLUE}💡 Note:${NC} After setup, you'll access your node from ${BOLD}another device${NC}"
echo "   (phone, laptop, tablet) on the same WiFi network."
echo ""
sleep 3

# Enable all services on first boot
echo -e "${BLUE}🔧 Initializing system services...${NC}"
/usr/local/bin/enable-services.sh
echo -e "${GREEN}✓ Services enabled${NC}\n"
sleep 1

# Setup Mode Selection
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}SELECT SETUP MODE${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}[1] Simple Setup${NC} ${BLUE}(Recommended)${NC}"
echo "    Quick WiFi setup with smart defaults"
echo "    Perfect for most users"
echo ""
echo -e "${YELLOW}[2] Advanced Setup${NC}"
echo "    Customize storage, services, and network settings"
echo "    For experienced users"
echo ""

while true; do
    read -p "Choose mode (1 or 2): " SETUP_MODE
    case $SETUP_MODE in
        1|2) break;;
        *) echo -e "${RED}Please enter 1 or 2${NC}";;
    esac
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}WIFI CONFIGURATION${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

# WiFi Setup (both modes need this)
while true; do
    read -p "Enter your WiFi network name (SSID): " SSID
    if [ -n "$SSID" ]; then
        break
    else
        echo -e "${RED}SSID cannot be empty${NC}"
    fi
done

while true; do
    read -s -p "Enter your WiFi password: " WIFI_PSK
    echo ""
    if [ -n "$WIFI_PSK" ]; then
        read -s -p "Confirm WiFi password: " WIFI_PSK_CONFIRM
        echo ""
        if [ "$WIFI_PSK" = "$WIFI_PSK_CONFIRM" ]; then
            break
        else
            echo -e "${RED}Passwords don't match. Please try again.${NC}"
        fi
    else
        echo -e "${RED}Password cannot be empty${NC}"
    fi
done

echo -e "${GREEN}✓ WiFi credentials saved${NC}\n"

# Advanced Mode Configuration
if [ "$SETUP_MODE" = "2" ]; then
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}STORAGE CONFIGURATION${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Bitcoin blockchain size: ~500GB (and growing)"
    echo ""
    echo "[1] Full Node - Store entire blockchain (Recommended)"
    echo "    Requires: 1TB+ storage"
    echo "    Benefits: Full validation, supports all services"
    echo ""
    echo "[2] Pruned Node - Store recent blocks only"
    echo "    Requires: 50GB+ storage"
    echo "    Limitations: Cannot serve full blockchain history"
    echo ""

    while true; do
        read -p "Choose node type (1 or 2): " NODE_TYPE
        case $NODE_TYPE in
            1)
                PRUNE=0
                echo -e "${GREEN}✓ Full node selected${NC}\n"
                break
                ;;
            2)
                read -p "Enter pruning size in MB [default: 50000 = ~50GB]: " PRUNE
                PRUNE=${PRUNE:-50000}
                echo -e "${GREEN}✓ Pruned node selected (${PRUNE}MB)${NC}\n"
                break
                ;;
            *) echo -e "${RED}Please enter 1 or 2${NC}";;
        esac
    done

    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}OPTIONAL SERVICES${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Select which services to enable:"
    echo ""

    read -p "Enable Lightning Network? (y/N): " ENABLE_LND
    read -p "Enable Electrum Server? (y/N): " ENABLE_ELECTRUM
    read -p "Enable BTCPay Server? (y/N): " ENABLE_BTCPAY

    echo ""
else
    # Simple mode defaults
    PRUNE=0
    ENABLE_LND="y"
    ENABLE_ELECTRUM="y"
    ENABLE_BTCPAY="n"
fi

# Configure WiFi
echo -e "${BLUE}⚙️  Configuring WiFi connection...${NC}"

cat > /etc/wpa_supplicant/wpa_supplicant.conf << WIFI_CONFIG
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$SSID"
    psk="$WIFI_PSK"
}
WIFI_CONFIG

chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
echo -e "${GREEN}✓ WiFi configured${NC}\n"

# Update Bitcoin configuration (preserve RPC credentials from bootstrap script)
echo -e "${BLUE}⚙️  Configuring Bitcoin node...${NC}"

# Read existing RPC credentials if they exist
EXISTING_CONF="/home/bitcoin/.bitcoin/bitcoin.conf"
if [ -f "$EXISTING_CONF" ]; then
    RPC_USER=$(grep "^rpcuser=" "$EXISTING_CONF" | cut -d'=' -f2)
    RPC_PASS=$(grep "^rpcpassword=" "$EXISTING_CONF" | cut -d'=' -f2)
else
    # Fallback (should not happen if bootstrap ran correctly)
    RPC_USER="bitcoin"
    RPC_PASS="changeme"
fi

# Write complete configuration preserving RPC credentials
cat > "$EXISTING_CONF" << BITCOIN_CONFIG
server=1
daemon=1
txindex=1
rpcuser=$RPC_USER
rpcpassword=$RPC_PASS
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcport=8332
port=8333
prune=$PRUNE
dbcache=2048
maxconnections=40
maxuploadtarget=5000
blocksonly=0
listen=1
discover=1
upnp=1
natpmp=1
externalip=auto
debug=rpc
debug=net
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
BITCOIN_CONFIG

chown bitcoin:bitcoin "$EXISTING_CONF"
chmod 600 "$EXISTING_CONF"
echo -e "${GREEN}✓ Bitcoin node configured${NC}\n"

# Configure services based on user selection
if [ "$ENABLE_LND" != "y" ] && [ "$ENABLE_LND" != "Y" ]; then
    systemctl disable lnd.service 2>/dev/null || true
fi

if [ "$ENABLE_ELECTRUM" != "y" ] && [ "$ENABLE_ELECTRUM" != "Y" ]; then
    systemctl disable electrumx.service 2>/dev/null || true
fi

# Set hostname
echo -e "${BLUE}⚙️  Setting hostname to moody-node...${NC}"
hostnamectl set-hostname moody-node 2>/dev/null || echo "moody-node" > /etc/hostname
echo "127.0.1.1    moody-node" >> /etc/hosts
echo -e "${GREEN}✓ Hostname configured${NC}\n"

# Summary
clear
echo -e "${GREEN}"
cat << "EOF"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║                    ✓ SETUP COMPLETE!                          ║
║                  YOUR MOODY NODE IS READY                      ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}\n"

echo -e "${BOLD}Your Moody Node is configured!${NC}\n"
echo -e "The system will reboot to apply changes...\n"
echo -e "${BOLD}After reboot, access from your phone/laptop:${NC}"
echo ""
echo -e "  ${GREEN}🌐 Web Dashboard${NC}"
echo -e "     ${BLUE}http://moody-node.local:3000${NC}"
echo ""
echo -e "  ${GREEN}⚡ Nostr Client${NC}"
echo -e "     ${BLUE}http://moody-node.local:5173${NC}"
echo ""
echo -e "  ${GREEN}🔧 SSH Access${NC}"
echo -e "     ${BLUE}ssh pi@moody-node.local${NC}"
echo -e "     Password: ${YELLOW}raspberry${NC} ${RED}(change this!)${NC}"
echo ""
echo -e "${YELLOW}⚠️  Initial blockchain sync: 3-7 days${NC}"
echo -e "   Monitor progress on the dashboard"
echo ""

if [ "$ENABLE_BTCPAY" = "y" ] || [ "$ENABLE_BTCPAY" = "Y" ]; then
    echo -e "${BLUE}💡 BTCPay Server Setup:${NC}"
    echo "   Visit the dashboard and click 'Start BTCPay Server'"
    echo ""
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}         Feelin' Moody? Stack sats. ⚡${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

touch "$FLAG_FILE"
echo -e "${BOLD}Rebooting in 10 seconds...${NC}"
sleep 10
reboot