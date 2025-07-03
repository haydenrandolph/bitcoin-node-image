#!/bin/bash

# Generate secure random credentials
RPC_USER="user$(openssl rand -hex 4)"
RPC_PASS=$(openssl rand -hex 16)

CONF_FILE="/home/bitcoin/.bitcoin/bitcoin.conf"

# Replace placeholders with generated creds
sed -i "s/^rpcuser=.*/rpcuser=$RPC_USER/" $CONF_FILE
sed -i "s/^rpcpassword=.*/rpcpassword=$RPC_PASS/" $CONF_FILE

chown bitcoin:bitcoin $CONF_FILE
chmod 600 $CONF_FILE

# Save creds securely for user retrieval
echo -e "RPC Username: $RPC_USER\nRPC Password: $RPC_PASS" > /home/bitcoin/rpc-credentials.txt
chown bitcoin:bitcoin /home/bitcoin/rpc-credentials.txt
chmod 600 /home/bitcoin/rpc-credentials.txt

# Disable service after first run
systemctl disable bootstrap-rpc-creds.service