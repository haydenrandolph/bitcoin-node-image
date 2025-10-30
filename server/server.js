const express = require('express');
const fs = require('fs');
const os = require('os');
const { exec } = require('child_process');
const { promisify } = require('util');
const path = require('path');
const BitcoinClient = require('bitcoin-core');

const execAsync = promisify(exec);
const app = express();

// Use Express built-in JSON parser (body-parser is deprecated)
app.use(express.json());

// Input validation helpers
function isValidSSID(ssid) {
  // SSID: 1-32 characters, printable ASCII
  return typeof ssid === 'string' && ssid.length > 0 && ssid.length <= 32 && /^[\x20-\x7E]+$/.test(ssid);
}

function isValidWiFiPassword(psk) {
  // WPA password: 8-63 characters
  return typeof psk === 'string' && psk.length >= 8 && psk.length <= 63;
}

function isValidBitcoinConfigValue(value) {
  // Allow only alphanumeric, dash, dot, underscore
  return typeof value === 'string' && /^[a-zA-Z0-9\-._]+$/.test(value);
}

function sanitizeShellArg(arg) {
  // Escape single quotes for shell safety
  return arg.replace(/'/g, "'\\''");
}

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
app.post('/api/config/wifi', async (req, res) => {
  try {
    const { ssid, psk } = req.body;

    // Validate inputs
    if (!isValidSSID(ssid)) {
      return res.status(400).json({ error: 'Invalid SSID format' });
    }

    if (!isValidWiFiPassword(psk)) {
      return res.status(400).json({ error: 'Invalid WiFi password (must be 8-63 characters)' });
    }

    // Use wpa_passphrase to generate secure config (prevents injection)
    const { stdout } = await execAsync(`wpa_passphrase '${sanitizeShellArg(ssid)}' '${sanitizeShellArg(psk)}'`);

    const wifiContent = `country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

${stdout}`;

    fs.writeFileSync(WIFI_CONF, wifiContent, { mode: 0o600 });

    // Restart networking
    await execAsync('sudo systemctl restart wpa_supplicant && sudo dhclient wlan0');
    res.json({ success: true });
  } catch (err) {
    console.error('WiFi config error:', err);
    res.status(500).json({ error: 'Failed to configure WiFi' });
  }
});

// --- Bitcoin.conf update ---
app.post('/api/config/bitcoin', async (req, res) => {
  try {
    // Whitelist of allowed config keys
    const allowedKeys = ['maxconnections', 'dbcache', 'prune', 'maxuploadtarget'];

    // Read existing config to preserve RPC credentials
    let existingConfig = {};
    if (fs.existsSync(BITCOIN_CONF)) {
      const content = fs.readFileSync(BITCOIN_CONF, 'utf-8');
      content.split('\n').forEach(line => {
        const [key, value] = line.split('=');
        if (key && value) {
          existingConfig[key.trim()] = value.trim();
        }
      });
    }

    // Validate and update only allowed keys
    for (let key in req.body) {
      if (!allowedKeys.includes(key)) {
        return res.status(400).json({ error: `Config key '${key}' is not allowed` });
      }

      const value = req.body[key];
      if (!isValidBitcoinConfigValue(value) && value !== '') {
        return res.status(400).json({ error: `Invalid value for '${key}'` });
      }

      existingConfig[key] = value;
    }

    // Write config preserving all settings
    let confContent = '';
    for (let key in existingConfig) {
      confContent += `${key}=${existingConfig[key]}\n`;
    }

    fs.writeFileSync(BITCOIN_CONF, confContent, { mode: 0o600 });
    await execAsync('sudo systemctl restart bitcoind');
    res.json({ success: true });
  } catch (err) {
    console.error('Bitcoin config error:', err);
    res.status(500).json({ error: 'Failed to update Bitcoin configuration' });
  }
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
app.get('/api/system/info', async (req, res) => {
  try {
    // Run both commands in parallel for better performance
    const [diskResult, servicesResult] = await Promise.all([
      execAsync('df -h / | tail -1'),
      execAsync('systemctl is-active bitcoind lnd electrumx btcnode-api flotilla')
    ]);

    const diskInfo = diskResult.stdout.trim().split(/\s+/);
    const serviceStatus = servicesResult.stdout.trim().split('\n');

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
  } catch (err) {
    console.error('System info error:', err);
    res.status(500).json({ error: 'Failed to get system information' });
  }
});

// --- Serve fallback Nostr interface ---
app.use('/nostr-fallback', express.static('/home/bitcoin/nostr-fallback'));

// --- Serve UI files ---
app.use(express.static(path.join(__dirname, 'ui')));
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Bitcoin Node API server running on port ${PORT}`);
});
