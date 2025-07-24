const express = require('express');
const fs = require('fs');
const os = require('os');
const { exec } = require('child_process');
const bodyParser = require('body-parser');
const path = require('path');
const BitcoinClient = require('bitcoin-core');
const app = express();
app.use(bodyParser.json());

const BITCOIN_CONF = '/home/bitcoin/.bitcoin/bitcoin.conf';
const WIFI_CONF = '/etc/wpa_supplicant/wpa_supplicant.conf';
const BTCPAY_SCRIPT = '/home/bitcoin/btcpayserver/start-btcpay.sh';
const NOSTR_IDENTITY = '/home/bitcoin/nostr-identity.json';

// --- Bitcoin Core Credentials Loader ---
function loadRpcCreds() {
  try {
    const credsFile = fs.readFileSync('/home/bitcoin/rpc-credentials.txt', 'utf-8');
    const lines = credsFile.split('\n');
    const user = lines.find(l => l.startsWith('RPC Username')).split(': ')[1].trim();
    const pass = lines.find(l => l.startsWith('RPC Password')).split(': ')[1].trim();
    return { user, pass };
  } catch (err) {
    return { user: 'bitcoin', pass: 'changeme' };
  }
}
const creds = loadRpcCreds();
const client = new BitcoinClient({
  network: 'mainnet',
  username: creds.user,
  password: creds.pass,
  host: '127.0.0.1',
  port: 8332,
});

// --- WiFi config ---
app.post('/api/config/wifi', (req, res) => {
  const { ssid, psk } = req.body;
  const wifiContent = `
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${ssid}"
    psk="${psk}"
}
  `.trim();
  fs.writeFileSync(WIFI_CONF, wifiContent);
  exec('sudo systemctl restart wpa_supplicant && sudo dhclient wlan0', err => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ success: true });
  });
});

// --- Bitcoin.conf update ---
app.post('/api/config/bitcoin', (req, res) => {
  let conf = '';
  for (let key in req.body) {
    conf += `${key}=${req.body[key]}\n`;
  }
  fs.writeFileSync(BITCOIN_CONF, conf);
  exec('sudo systemctl restart bitcoind', err => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ success: true });
  });
});

// --- Bitcoin Status Endpoints ---
app.get('/api/bitcoin/status', async (req, res) => {
  try { const info = await client.getBlockchainInfo(); res.json(info); }
  catch (err) { res.status(500).json({ error: err.message }); }
});
app.get('/api/bitcoin/network-info', async (req, res) => {
  try { const info = await client.getNetworkInfo(); res.json(info); }
  catch (err) { res.status(500).json({ error: err.message }); }
});

// --- Nostr Key Management (Stub, add nostr-tools logic) ---
app.get('/api/config/nostr', (req, res) => {
  try {
    const identity = JSON.parse(fs.readFileSync(NOSTR_IDENTITY, 'utf-8'));
    res.json(identity);
  } catch {
    res.json({ pubkey: null, npub: null });
  }
});
app.post('/api/config/nostr/generate', (req, res) => {
  // TODO: Use nostr-tools to generate keypair, save as NOSTR_IDENTITY
  res.json({ success: false, message: "Implement key generation" });
});

// --- BTCPay Setup/Run ---
app.post('/api/config/btcpay', (req, res) => {
  // You can allow setting BTCPAY_HOST, etc, from UI; for now, just launch setup script
  exec(`sudo -u bitcoin ${BTCPAY_SCRIPT}`, err => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ success: true });
  });
});

// --- Lightning Network Status ---
app.get('/api/lightning/status', async (req, res) => {
  try {
    exec('systemctl is-active lnd', (err, stdout) => {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ status: stdout.trim() });
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- Electrum Server Status ---
app.get('/api/electrum/status', async (req, res) => {
  try {
    exec('systemctl is-active electrumx', (err, stdout) => {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ status: stdout.trim() });
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- System Info ---
app.get('/api/system/info', (req, res) => {
  const { exec } = require('child_process');
  
  // Get disk usage
  exec('df -h / | tail -1', (err, stdout) => {
    const diskInfo = stdout.trim().split(/\s+/);
    
    // Get service status
    exec('systemctl is-active bitcoind lnd electrumx btcnode-api flotilla', (err, services) => {
      const serviceStatus = services.trim().split('\n');
      
      res.json({
        cpu: os.cpus(),
        mem: os.freemem(),
        totalmem: os.totalmem(),
        load: os.loadavg(),
        uptime: os.uptime(),
        hostname: os.hostname(),
        disk: {
          total: diskInfo[1],
          used: diskInfo[2],
          available: diskInfo[3],
          usage: diskInfo[4]
        },
        services: {
          bitcoind: serviceStatus[0],
          lnd: serviceStatus[1],
          electrumx: serviceStatus[2],
          btcnode_api: serviceStatus[3],
          flotilla: serviceStatus[4]
        }
      });
    });
  });
});

// --- Serve fallback Nostr interface ---
app.use('/nostr-fallback', express.static('/home/bitcoin/nostr-fallback'));

// --- Serve UI files ---
app.use(express.static(path.join(__dirname, 'ui')));
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Bitcoin Node API server running on port ${PORT}`);
});
