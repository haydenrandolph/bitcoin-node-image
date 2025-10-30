// Helper function for API calls with error handling
async function apiCall(url, options = {}) {
  try {
    const res = await fetch(url, options);
    const data = await res.json();

    if (!res.ok) {
      throw new Error(data.error || 'Request failed');
    }

    return { success: true, data };
  } catch (err) {
    console.error('API call failed:', err);
    return { success: false, error: err.message || 'Network error' };
  }
}

// WiFi form
document.getElementById('wifi-form').onsubmit = async (e) => {
  e.preventDefault();
  const resultDiv = document.getElementById('wifi-result');
  resultDiv.textContent = 'Updating WiFi...';

  const ssid = e.target.ssid.value;
  const psk = e.target.psk.value;

  if (!ssid || !psk) {
    resultDiv.textContent = 'Please fill in all fields';
    resultDiv.style.color = 'red';
    return;
  }

  if (psk.length < 8) {
    resultDiv.textContent = 'WiFi password must be at least 8 characters';
    resultDiv.style.color = 'red';
    return;
  }

  const result = await apiCall('/api/config/wifi', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ssid, psk })
  });

  if (result.success) {
    resultDiv.textContent = 'WiFi updated successfully! Reconnecting...';
    resultDiv.style.color = 'green';
  } else {
    resultDiv.textContent = `Error: ${result.error}`;
    resultDiv.style.color = 'red';
  }
};

// Bitcoin form
document.getElementById('btc-form').onsubmit = async (e) => {
  e.preventDefault();
  const resultDiv = document.getElementById('btc-result');
  resultDiv.textContent = 'Updating Bitcoin configuration...';

  let conf = {};
  for (const input of e.target.elements) {
    if (input.name && input.value) {
      conf[input.name] = input.value;
    }
  }

  const result = await apiCall('/api/config/bitcoin', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(conf)
  });

  if (result.success) {
    resultDiv.textContent = 'Bitcoin config updated! Node is restarting...';
    resultDiv.style.color = 'green';
    setTimeout(() => getBitcoinStatus(), 5000);
  } else {
    resultDiv.textContent = `Error: ${result.error}`;
    resultDiv.style.color = 'red';
  }
};
  
// BTCPay
document.getElementById('start-btcpay').onclick = async () => {
  const resultDiv = document.getElementById('btcpay-result');
  resultDiv.textContent = 'Starting BTCPay Server...';

  const result = await apiCall('/api/config/btcpay', { method: 'POST' });

  if (result.success) {
    resultDiv.textContent = 'BTCPay is launching (may take 1-2 mins)!';
    resultDiv.style.color = 'green';
  } else {
    resultDiv.textContent = `Error: ${result.error}`;
    resultDiv.style.color = 'red';
  }
};

// Nostr
async function getNostrIdentity() {
  const result = await apiCall('/api/config/nostr');
  const identityDiv = document.getElementById('nostr-identity');

  if (result.success && result.data.pubkey) {
    identityDiv.textContent = `Pubkey: ${result.data.pubkey}`;
  } else {
    identityDiv.textContent = 'No key yet';
  }
}

document.getElementById('generate-nostr').onclick = async () => {
  const result = await apiCall('/api/config/nostr/generate', { method: 'POST' });

  if (result.success) {
    getNostrIdentity();
  } else {
    alert(`Failed to generate key: ${result.error}`);
  }
};

// Bitcoin status
async function getBitcoinStatus() {
  const result = await apiCall('/api/bitcoin/status');
  const bitcoinDiv = document.getElementById('bitcoin');

  if (result.success) {
    const data = result.data;
    bitcoinDiv.innerHTML = `
      <b>Chain:</b> ${data.chain || 'Unknown'}<br>
      <b>Blocks:</b> ${data.blocks || 0}<br>
      <b>Sync Progress:</b> ${data.verificationprogress ? (data.verificationprogress * 100).toFixed(2) : 0}%<br>
    `;
  } else {
    bitcoinDiv.innerHTML = `<span style="color: red;">Error: ${result.error}</span>`;
  }
}

// Lightning status
async function getLightningStatus() {
  const result = await apiCall('/api/lightning/status');
  const lightningDiv = document.getElementById('lightning-status');

  if (result.success) {
    const status = result.data.status;
    lightningDiv.innerHTML = `
      <b>Status:</b> <span style="color: ${status === 'active' ? 'green' : 'red'}">${status}</span><br>
    `;
  } else {
    lightningDiv.innerHTML = `<span style="color: red;">Error: ${result.error}</span>`;
  }
}

// Electrum status
async function getElectrumStatus() {
  const result = await apiCall('/api/electrum/status');
  const electrumDiv = document.getElementById('electrum-status');

  if (result.success) {
    const status = result.data.status;
    electrumDiv.innerHTML = `
      <b>Status:</b> <span style="color: ${status === 'active' ? 'green' : 'red'}">${status}</span><br>
    `;
  } else {
    electrumDiv.innerHTML = `<span style="color: red;">Error: ${result.error}</span>`;
  }
}

// System info
async function getSystemInfo() {
  const result = await apiCall('/api/system/info');
  const systemDiv = document.getElementById('system-info');

  if (result.success) {
    const data = result.data;
    systemDiv.innerHTML = `
      <b>Hostname:</b> ${data.hostname}<br>
      <b>Uptime:</b> ${Math.floor(data.uptime / 3600)} hours<br>
      <b>Memory:</b> ${Math.round(data.mem / 1024 / 1024)} MB free / ${Math.round(data.totalmem / 1024 / 1024)} MB total<br>
      <b>Load Average:</b> ${data.load[0].toFixed(2)}, ${data.load[1].toFixed(2)}, ${data.load[2].toFixed(2)}<br>
      <b>Disk Usage:</b> ${data.disk.used} / ${data.disk.total} (${data.disk.usage})<br>
      <b>Services:</b><br>
      &nbsp;&nbsp;Bitcoin Core: <span style="color: ${data.services.bitcoind === 'active' ? 'green' : 'red'}">${data.services.bitcoind}</span><br>
      &nbsp;&nbsp;Lightning (LND): <span style="color: ${data.services.lnd === 'active' ? 'green' : 'red'}">${data.services.lnd}</span><br>
      &nbsp;&nbsp;Electrum Server: <span style="color: ${data.services.electrumx === 'active' ? 'green' : 'red'}">${data.services.electrumx}</span><br>
      &nbsp;&nbsp;Web API: <span style="color: ${data.services.btcnode_api === 'active' ? 'green' : 'red'}">${data.services.btcnode_api}</span><br>
      &nbsp;&nbsp;Flotilla: <span style="color: ${data.services.flotilla === 'active' ? 'green' : 'red'}">${data.services.flotilla}</span><br>
    `;
  } else {
    systemDiv.innerHTML = `<span style="color: red;">Error: ${result.error}</span>`;
  }
}

// Load data on page load, then refresh every 30 seconds
window.onload = () => {
  getBitcoinStatus();
  getNostrIdentity();
  getLightningStatus();
  getElectrumStatus();
  getSystemInfo();

  // Auto-refresh system info and status every 30 seconds
  setInterval(() => {
    getBitcoinStatus();
    getLightningStatus();
    getElectrumStatus();
    getSystemInfo();
  }, 30000);
};  