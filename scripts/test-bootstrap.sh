#!/bin/bash

# Simple test script to verify bootstrap-rpc-creds.sh works
echo "Testing bootstrap script..."

# Create a test bitcoin.conf
mkdir -p /tmp/test-bitcoin
cat > /tmp/test-bitcoin/bitcoin.conf << EOF
server=1
daemon=1
txindex=1
rpcuser=REPLACE_USER
rpcpassword=REPLACE_PASS
rpcallowip=127.0.0.1
EOF

# Copy the bootstrap script to a test location
cp scripts/bootstrap-rpc-creds.sh /tmp/test-bootstrap.sh
chmod +x /tmp/test-bootstrap.sh

# Test execution
echo "Testing script execution..."
/tmp/test-bootstrap.sh

echo "Test complete. Check /tmp/test-bitcoin/bitcoin.conf for changes." 