#!/bin/bash

# Generate secure random credentials
RPC_USER="user$(openssl rand -hex 4)"
RPC_PASS=$(openssl rand -hex 16)

CONF_FILE="/home/bitcoin/.bitcoin/bitcoin.conf"

# Check if bitcoin.conf exists, create if not
if [ ! -f "$CONF_FILE" ]; then
    echo "Creating bitcoin.conf file..."
    mkdir -p /home/bitcoin/.bitcoin
    cat > "$CONF_FILE" << EOF
server=1
daemon=1
txindex=1
rpcuser=REPLACE_USER
rpcpassword=REPLACE_PASS
rpcallowip=127.0.0.1
dbcache=2048
maxconnections=40
maxuploadtarget=5000
blocksonly=0
listen=1
discover=1
upnp=1
natpmp=1
externalip=auto
rpcbind=127.0.0.1
rpcport=8332
port=8333
debug=rpc
debug=net
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
EOF
fi

# Replace placeholders with generated creds
sed -i "s/^rpcuser=.*/rpcuser=$RPC_USER/" "$CONF_FILE"
sed -i "s/^rpcpassword=.*/rpcpassword=$RPC_PASS/" "$CONF_FILE"

chown bitcoin:bitcoin "$CONF_FILE"
chmod 600 "$CONF_FILE"

# Update LND configuration with RPC credentials
LND_CONF="/home/bitcoin/.lnd/lnd.conf"
if [ -f "$LND_CONF" ]; then
    sed -i "s/bitcoind.rpcuser=REPLACE_USER/bitcoind.rpcuser=$RPC_USER/" "$LND_CONF"
    sed -i "s/bitcoind.rpcpass=REPLACE_PASS/bitcoind.rpcpass=$RPC_PASS/" "$LND_CONF"
    chown bitcoin:bitcoin "$LND_CONF"
    chmod 600 "$LND_CONF"
    echo "Updated LND configuration with RPC credentials"
else
    echo "LND configuration file not found, skipping"
fi

# Update ElectrumX configuration with RPC credentials
ELECTRUMX_ENV="/home/bitcoin/.electrumx.env"
if [ -f "$ELECTRUMX_ENV" ]; then
    sed -i "s|DAEMON_URL=http://REPLACE_USER:REPLACE_PASS@127.0.0.1:8332/|DAEMON_URL=http://$RPC_USER:$RPC_PASS@127.0.0.1:8332/|" "$ELECTRUMX_ENV"
    chown bitcoin:bitcoin "$ELECTRUMX_ENV"
    chmod 600 "$ELECTRUMX_ENV"
    echo "Updated ElectrumX configuration with RPC credentials"
else
    echo "ElectrumX configuration file not found, skipping"
fi

# Save creds securely for user retrieval
echo -e "RPC Username: $RPC_USER\nRPC Password: $RPC_PASS" > /home/bitcoin/rpc-credentials.txt
chown bitcoin:bitcoin /home/bitcoin/rpc-credentials.txt
chmod 600 /home/bitcoin/rpc-credentials.txt

echo "✅ RPC credentials generated and saved to /home/bitcoin/rpc-credentials.txt"
echo "Username: $RPC_USER"
echo "Password: $RPC_PASS"

# Disable service after first run
systemctl disable bootstrap-rpc-creds.service