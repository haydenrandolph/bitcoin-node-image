// WiFi form
document.getElementById('wifi-form').onsubmit = async (e) => {
    e.preventDefault();
    const ssid = e.target.ssid.value, psk = e.target.psk.value;
    const res = await fetch('/api/config/wifi', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({ssid, psk}) });
    document.getElementById('wifi-result').textContent = res.ok ? "WiFi updated!" : "WiFi error!";
  };
  
  // Bitcoin form
  document.getElementById('btc-form').onsubmit = async (e) => {
    e.preventDefault();
    let conf = {};
    for (const input of e.target.elements) if (input.name && input.value) conf[input.name]=input.value;
    const res = await fetch('/api/config/bitcoin', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(conf) });
    document.getElementById('btc-result').textContent = res.ok ? "Bitcoin config updated!" : "Bitcoin config error!";
    if(res.ok) getBitcoinStatus();
  };
  
  // BTCPay
  document.getElementById('start-btcpay').onclick = async () => {
    const res = await fetch('/api/config/btcpay', {method:'POST'});
    document.getElementById('btcpay-result').textContent = res.ok ? "BTCPay is launching (may take 1-2 mins)!" : "BTCPay error!";
  };
  
  // Nostr
  async function getNostrIdentity() {
    const res = await fetch('/api/config/nostr'); const data = await res.json();
    document.getElementById('nostr-identity').textContent = data.pubkey ? `Pubkey: ${data.pubkey}` : "No key yet";
  }
  document.getElementById('generate-nostr').onclick = async () => {
    await fetch('/api/config/nostr/generate', {method:'POST'});
    getNostrIdentity();
  };
  
  async function getBitcoinStatus() {
    const res = await fetch('/api/bitcoin/status'); const data = await res.json();
    document.getElementById('bitcoin').innerHTML = `
      <b>Chain:</b> ${data.chain}<br>
      <b>Blocks:</b> ${data.blocks}<br>
      <b>Sync Progress:</b> ${(data.verificationprogress*100).toFixed(2)}%<br>
    `;
  }

  async function getSystemInfo() {
    const res = await fetch('/api/system/info'); const data = await res.json();
    document.getElementById('system-info').innerHTML = `
      <b>Hostname:</b> ${data.hostname}<br>
      <b>Uptime:</b> ${Math.floor(data.uptime / 3600)} hours<br>
      <b>Memory:</b> ${Math.round(data.mem / 1024 / 1024)} MB free / ${Math.round(data.totalmem / 1024 / 1024)} MB total<br>
      <b>Load Average:</b> ${data.load[0].toFixed(2)}, ${data.load[1].toFixed(2)}, ${data.load[2].toFixed(2)}<br>
    `;
  }

  window.onload = () => { getBitcoinStatus(); getNostrIdentity(); getSystemInfo(); };  