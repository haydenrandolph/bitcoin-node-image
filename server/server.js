// server.js
const express = require('express');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { exec } = require('child_process');
const BitcoinClient = require('bitcoin-core');
const nostrTools = require('nostr-tools');
const { generatePrivateKey, getPublicKey, nip19 } = nostrTools;

const app = express();
app.use(express.json());

// ---- Load Bitcoin RPC credentials ----
function loadRpcCreds() {
  try {
    const credsFile = fs.readFileSync('/home/bitcoin/rpc-credentials.txt', 'utf-8');
    const lines = credsFile.split('\n');
    const user = lines.find(l => l.startsWith('RPC Username')).split(': ')[1].trim();
    const pass = lines.find(l => l.startsWith('RPC Password')).split(': ')[1].trim();
    return { user, pass };
  } catch (err) {
    return { user: 'bitcoin', pass: 'changeme' }; // fallback for early boot
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

// --------- Bitcoin Endpoints ---------
app.get('/api/bitcoin/status', async (req, res) => {
  try {
    const info = await client.getBlockchainInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.get('/api/bitcoin/blockchain-info', async (req, res) => {
  try {
    const info = await client.getBlockchainInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.get('/api/bitcoin/network-info', async (req, res) => {
  try {
    const info = await client.getNetworkInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.get('/api/bitcoin/mempool-info', async (req, res) => {
  try {
    const info = await client.getMempoolInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.get('/api/bitcoin/mining-info', async (req, res) => {
  try {
    const info = await client.getMiningInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.get('/api/bitcoin/peer-info', async (req, res) => {
  try {
    const info = await client.getPeerInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.get('/api/bitcoin/wallet-info', async (req, res) => {
  try {
    const info = await client.getWalletInfo();
    res.json(info);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --------- Settings/Advanced ---------
const settingsPath = '/home/bitcoin/settings.json';

function getSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
  } catch {
    return {};
  }
}
function saveSettings(obj) {
  fs.writeFileSync(settingsPath, JSON.stringify(obj, null, 2));
}

app.get('/api/settings/advanced', (req, res) => {
  res.json(getSettings());
});
app.post('/api/settings/advanced', (req, res) => {
  saveSettings(req.body);
  res.json({ success: true });
});
app.get('/api/settings/validation', (req, res) => {
  // TODO: implement real validation logic
  res.json({ valid: true, issues: [] });
});

// --------- Nostr Identity Management ---------
const nostrIdentityPath = '/home/bitcoin/nostr-identity.json';

function loadNostrIdentity() {
  try {
    return JSON.parse(fs.readFileSync(nostrIdentityPath, 'utf-8'));
  } catch {
    return null;
  }
}

function saveNostrIdentity(identity) {
  fs.writeFileSync(nostrIdentityPath, JSON.stringify(identity, null, 2), { mode: 0o600 });
}

app.get('/api/nostr/identity', (req, res) => {
  const identity = loadNostrIdentity();
  if (!identity) return res.json({ pubkey: null, privkey: null, status: 'no identity yet' });
  res.json({ pubkey: identity.pubkey, privkey: !!identity.privkey, npub: nip19.npubEncode(identity.pubkey), status: 'ok' });
});

app.post('/api/nostr/identity/generate', (req, res) => {
  const privkey = generatePrivateKey();
  const pubkey = getPublicKey(privkey);
  const identity = { pubkey, privkey };
  saveNostrIdentity(identity);
  res.json({
    pubkey,
    npub: nip19.npubEncode(pubkey),
    nsec: nip19.nsecEncode(privkey),
    privkey: true
  });
});

app.post('/api/nostr/identity/import', (req, res) => {
  let { privkey } = req.body;
  try {
    if (privkey.startsWith('nsec')) privkey = nip19.decode(privkey).data;
    if (!/^[0-9a-f]{64}$/i.test(privkey)) throw new Error('Invalid private key');
    const pubkey = getPublicKey(privkey);
    const identity = { pubkey, privkey };
    saveNostrIdentity(identity);
    res.json({ success: true, pubkey, npub: nip19.npubEncode(pubkey) });
  } catch (e) {
    res.status(400).json({ success: false, error: e.message });
  }
});

// --------- Nostr Relay Management ---------
const nostrRelaysPath = '/home/bitcoin/nostr-relays.json';

function getRelays() {
  try {
    return JSON.parse(fs.readFileSync(nostrRelaysPath, 'utf-8'));
  } catch { return ["wss://relay.nostr.band", "wss://nostr-pub.wellorder.net"]; }
}
function saveRelays(relays) {
  fs.writeFileSync(nostrRelaysPath, JSON.stringify(relays, null, 2));
}

app.get('/api/nostr/relays', (req, res) => {
  res.json({ relays: getRelays() });
});
app.post('/api/nostr/relays/add', (req, res) => {
  const relays = getRelays();
  if (!req.body.url || relays.includes(req.body.url)) return res.json({ success: false });
  relays.push(req.body.url);
  saveRelays(relays);
  res.json({ success: true, relays });
});
app.delete('/api/nostr/relays/:relay', (req, res) => {
  let relays = getRelays();
  relays = relays.filter(url => url !== req.params.relay);
  saveRelays(relays);
  res.json({ success: true, relays });
});

// --------- System Info ---------
app.get('/api/system/info', (req, res) => {
  res.json({
    cpu: os.cpus(),
    mem: os.freemem(),
    totalmem: os.totalmem(),
    load: os.loadavg(),
    disk: null, // TODO: implement df -h parsing or similar
    uptime: os.uptime(),
    hostname: os.hostname(),
  });
});
app.get('/api/system/version', (req, res) => {
  res.json({ version: "0.1.0", api: "v1" });
});
app.get('/api/system/logs', (req, res) => {
  exec('tail -n 100 /var/log/syslog', (err, stdout, stderr) => {
    if (err) return res.status(500).json({ error: err.message });
    res.type('text/plain').send(stdout);
  });
});

// --------- Health ---------
app.get('/api/health/detailed', (req, res) => {
  res.json({ bitcoin: true, nostr: true, system: true });
});
app.get('/api/health/bitcoin', async (req, res) => {
  try {
    const info = await client.getBlockchainInfo();
    res.json({ healthy: !!info });
  } catch (err) {
    res.status(500).json({ healthy: false, error: err.message });
  }
});
app.get('/api/health/nostr', (req, res) => {
  const relays = getRelays();
  res.json({ healthy: relays.length > 0, relays });
});

// --------- Serve static UI files if present (in /ui) ---------
app.use(express.static(path.join(__dirname, 'ui'))); // e.g., React build output

// --------- Start server ---------
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Bitcoin/Nostr Node API server running on port ${PORT}`);
});
