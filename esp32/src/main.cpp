#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <HTTPClient.h>
#include <TinyGPSPlus.h>
#include <ArduinoJson.h>
#include <HardwareSerial.h>

// ── Pin config ────────────────────────────────────────────────────────────────
#define GPS_RX_PIN       21
#define GPS_TX_PIN       22
#define GPS_BAUD_INIT    9600
#define GPS_BAUD_FAST    115200
#define POST_INTERVAL_MS 1000
#define LED_PIN          2

// ── Server (hardcoded) ────────────────────────────────────────────────────────
#define SERVER_URL "https://gps-tracker-xw5w.onrender.com/api/v1/tracker/location"

// ── WiFi Manager config ───────────────────────────────────────────────────────
#define AP_SSID               "GPS-Tracker-Setup"
#define AP_PASS               ""
#define WIFI_CONNECT_TIMEOUT  15000
#define MAX_DEVICES           3

// ── App state ─────────────────────────────────────────────────────────────────
enum AppState { SETUP_MODE, TRACKING_MODE };
AppState appState = SETUP_MODE;

// ── Services ──────────────────────────────────────────────────────────────────
WebServer  webServer(80);
DNSServer  dnsServer;
Preferences prefs;
TinyGPSPlus gps;
HardwareSerial gpsSerial(2);

unsigned long lastPostMs = 0;
bool gpsReady = false;

// Credentials loaded from NVS
String savedSSID, savedPass;
String devName[MAX_DEVICES];
String devKey[MAX_DEVICES];
int    activeDevice = 0;  // index 0–2

// ── UBX GPS config commands ───────────────────────────────────────────────────
static const uint8_t UBX_SET_BAUD_115200[] = {
  0xB5,0x62,0x06,0x00,0x14,0x00,0x01,0x00,0x00,0x00,
  0xD0,0x08,0x00,0x00,0x00,0xC2,0x01,0x00,0x07,0x00,
  0x03,0x00,0x00,0x00,0x00,0x00,0xC0,0x7E
};
static const uint8_t UBX_SET_RATE_10HZ[] = {
  0xB5,0x62,0x06,0x08,0x06,0x00,0x64,0x00,0x01,0x00,0x01,0x00,0x7A,0x12
};
static const uint8_t UBX_SAVE_CONFIG[] = {
  0xB5,0x62,0x06,0x09,0x0D,0x00,0x00,0x00,0x00,0x00,
  0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x17,0x31,0xBF
};

static void sendUBX(HardwareSerial &s, const uint8_t *cmd, size_t len) {
  s.write(cmd, len); s.flush();
}

// ── NVS helpers ───────────────────────────────────────────────────────────────
void loadPrefs() {
  prefs.begin("gps-tracker", true);
  savedSSID    = prefs.getString("ssid", "");
  savedPass    = prefs.getString("pass", "");
  activeDevice = prefs.getInt("active_dev", 0);
  for (int i = 0; i < MAX_DEVICES; i++) {
    devName[i] = prefs.getString(("dev" + String(i) + "_name").c_str(), "");
    devKey[i]  = prefs.getString(("dev" + String(i) + "_key").c_str(),  "");
  }
  prefs.end();
}

void savePrefs(const String &ssid, const String &pass, int activeDev,
               String names[], String keys[]) {
  prefs.begin("gps-tracker", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.putInt("active_dev", activeDev);
  for (int i = 0; i < MAX_DEVICES; i++) {
    prefs.putString(("dev" + String(i) + "_name").c_str(), names[i]);
    prefs.putString(("dev" + String(i) + "_key").c_str(),  keys[i]);
  }
  prefs.end();
}

void clearPrefs() {
  prefs.begin("gps-tracker", false);
  prefs.clear();
  prefs.end();
}

// ── Web page ──────────────────────────────────────────────────────────────────
const char HTML_PAGE[] PROGMEM = R"rawhtml(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TraceX — Setup</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #080F1E;
    color: #E2E8F0;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 24px 16px 48px;
  }

  body::before, body::after {
    content: '';
    position: fixed;
    border-radius: 50%;
    pointer-events: none;
    z-index: 0;
  }
  body::before {
    width: 400px; height: 400px;
    top: -120px; right: -100px;
    background: radial-gradient(circle, rgba(99,102,241,.25) 0%, transparent 70%);
  }
  body::after {
    width: 350px; height: 350px;
    bottom: -60px; left: -80px;
    background: radial-gradient(circle, rgba(6,182,212,.18) 0%, transparent 70%);
  }

  .wrap { width: 100%; max-width: 480px; position: relative; z-index: 1; }

  .header { text-align: center; margin-bottom: 32px; }
  .header .icon {
    display: inline-flex; align-items: center; justify-content: center;
    width: 64px; height: 64px; border-radius: 18px;
    background: linear-gradient(135deg,#1E3A8A,#3B82F6);
    font-size: 30px; margin-bottom: 12px;
    box-shadow: 0 8px 24px rgba(59,130,246,.35);
  }
  .header h1 { font-size: 24px; font-weight: 700; color: #fff; }
  .header p  { font-size: 14px; color: #94A3B8; margin-top: 4px; }

  .server-badge {
    display: inline-flex; align-items: center; gap: 6px;
    background: rgba(34,197,94,.1); border: 1px solid rgba(34,197,94,.25);
    color: #4ADE80; font-size: 11px; font-family: monospace;
    padding: 5px 12px; border-radius: 50px; margin-top: 10px;
  }
  .server-badge .dot-green {
    width: 7px; height: 7px; border-radius: 50%; background: #22C55E;
    box-shadow: 0 0 6px rgba(34,197,94,.5);
  }

  .card {
    background: rgba(13,23,48,.85);
    border: 1px solid rgba(255,255,255,.1);
    border-radius: 20px;
    padding: 24px;
    margin-bottom: 16px;
    backdrop-filter: blur(12px);
  }
  .card-title {
    font-size: 13px; font-weight: 700; letter-spacing: .06em;
    color: #60A5FA; text-transform: uppercase; margin-bottom: 16px;
    display: flex; align-items: center; gap: 8px;
  }

  .btn-scan {
    display: flex; align-items: center; justify-content: center; gap: 8px;
    width: 100%; padding: 11px; border-radius: 12px; border: none; cursor: pointer;
    background: rgba(59,130,246,.15); color: #60A5FA;
    font-size: 14px; font-weight: 600; transition: all .2s;
    border: 1px solid rgba(59,130,246,.3);
  }
  .btn-scan:hover  { background: rgba(59,130,246,.25); }
  .btn-scan.spinning .scan-icon { animation: spin 1s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  .net-list { margin-top: 14px; display: flex; flex-direction: column; gap: 8px; }
  .net-item {
    display: flex; align-items: center; gap: 12px;
    padding: 12px 14px; border-radius: 12px; cursor: pointer;
    background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.07);
    transition: all .15s;
  }
  .net-item:hover  { background: rgba(59,130,246,.12); border-color: rgba(59,130,246,.35); }
  .net-item.active { background: rgba(59,130,246,.18); border-color: #3B82F6; }

  .bars { display: flex; align-items: flex-end; gap: 2px; height: 18px; }
  .bars span { width: 4px; border-radius: 2px; background: #1E40AF; transition: background .15s; }
  .bars span.lit  { background: #3B82F6; }
  .net-item.active .bars span.lit { background: #60A5FA; }

  .net-name { flex: 1; font-size: 14px; font-weight: 500; color: #E2E8F0; }
  .net-rssi { font-size: 11px; color: #64748B; }
  .lock { font-size: 13px; color: #475569; }

  .field { margin-bottom: 14px; }
  label { display: block; font-size: 12px; font-weight: 600; color: #94A3B8; margin-bottom: 6px; }
  .input-wrap { position: relative; }
  input[type=text], input[type=password] {
    width: 100%; padding: 11px 14px; border-radius: 12px;
    background: rgba(21,34,64,.9); border: 1px solid rgba(255,255,255,.1);
    color: #fff; font-size: 14px; outline: none; transition: border-color .2s;
  }
  input:focus { border-color: #3B82F6; box-shadow: 0 0 0 3px rgba(59,130,246,.15); }
  .eye {
    position: absolute; right: 12px; top: 50%; transform: translateY(-50%);
    cursor: pointer; color: #64748B; font-size: 16px; user-select: none;
    transition: color .2s;
  }
  .eye:hover { color: #94A3B8; }

  /* Device slots */
  .device-slot {
    border: 1px solid rgba(255,255,255,.08);
    border-radius: 14px;
    padding: 16px;
    margin-bottom: 12px;
    background: rgba(255,255,255,.02);
    transition: border-color .2s, background .2s;
  }
  .device-slot.active-slot {
    border-color: #3B82F6;
    background: rgba(59,130,246,.06);
  }
  .slot-header {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 12px;
  }
  .slot-label {
    font-size: 12px; font-weight: 700; color: #60A5FA; text-transform: uppercase; letter-spacing: .05em;
    display: flex; align-items: center; gap: 6px;
  }
  .active-badge {
    display: none; background: rgba(34,197,94,.15); border: 1px solid rgba(34,197,94,.3);
    color: #4ADE80; font-size: 10px; font-weight: 700; padding: 2px 8px;
    border-radius: 50px; letter-spacing: .04em;
  }
  .device-slot.active-slot .active-badge { display: inline-block; }
  .btn-activate {
    padding: 5px 12px; border-radius: 8px; border: 1px solid rgba(59,130,246,.4);
    background: rgba(59,130,246,.12); color: #60A5FA; font-size: 11px; font-weight: 600;
    cursor: pointer; transition: all .2s;
  }
  .btn-activate:hover { background: rgba(59,130,246,.25); }
  .device-slot.active-slot .btn-activate { display: none; }

  .row2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }

  .btn-connect {
    width: 100%; padding: 14px; border-radius: 14px; border: none; cursor: pointer;
    background: linear-gradient(135deg,#1D4ED8,#3B82F6);
    color: #fff; font-size: 15px; font-weight: 700; margin-top: 8px;
    transition: all .2s; box-shadow: 0 4px 16px rgba(59,130,246,.3);
    display: flex; align-items: center; justify-content: center; gap: 8px;
  }
  .btn-connect:hover  { transform: translateY(-1px); box-shadow: 0 6px 20px rgba(59,130,246,.4); }
  .btn-connect:active { transform: translateY(0); }
  .btn-connect:disabled { opacity: .5; cursor: not-allowed; transform: none; }

  .status-row {
    display: flex; align-items: center; gap: 10px;
    padding: 12px 14px; border-radius: 12px;
    background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.07);
    margin-bottom: 10px; font-size: 13px;
  }
  .dot { width: 9px; height: 9px; border-radius: 50%; flex-shrink: 0; background: #475569; }
  .dot.green { background: #22C55E; box-shadow: 0 0 8px rgba(34,197,94,.5); }
  .dot.blue  { background: #3B82F6; animation: pulse 1.4s ease-in-out infinite; }
  .dot.red   { background: #EF4444; }
  @keyframes pulse {
    0%,100% { box-shadow: 0 0 0 0 rgba(59,130,246,.5); }
    50%      { box-shadow: 0 0 0 5px rgba(59,130,246,0); }
  }
  .status-text { flex: 1; color: #CBD5E1; }
  .status-ip   { font-size: 12px; color: #60A5FA; font-family: monospace; }

  #toast {
    position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%) translateY(80px);
    background: rgba(13,23,48,.95); border: 1px solid rgba(255,255,255,.12);
    color: #E2E8F0; padding: 10px 20px; border-radius: 50px;
    font-size: 13px; font-weight: 500; transition: transform .3s ease;
    pointer-events: none; z-index: 99; white-space: nowrap;
    box-shadow: 0 8px 24px rgba(0,0,0,.4);
  }
  #toast.show { transform: translateX(-50%) translateY(0); }
  #toast.ok   { border-color: rgba(34,197,94,.4); }
  #toast.err  { border-color: rgba(239,68,68,.4); }

  .divider { height: 1px; background: rgba(255,255,255,.07); margin: 20px 0; }
  .reset-link {
    text-align: center; font-size: 12px; color: #475569; cursor: pointer;
    text-decoration: underline; text-underline-offset: 3px;
  }
  .reset-link:hover { color: #EF4444; }
</style>
</head>
<body>
<div class="wrap">

  <div class="header">
    <div class="icon">📍</div>
    <h1>TraceX</h1>
    <p>Wi-Fi &amp; Device Configuration</p>
    <div class="server-badge">
      <div class="dot-green"></div>
      gps-tracker-xw5w.onrender.com
    </div>
  </div>

  <!-- Status -->
  <div class="card">
    <div class="card-title">⚡ Current Status</div>
    <div id="statusRow" class="status-row">
      <div id="dot" class="dot"></div>
      <span id="statusText" class="status-text">Checking…</span>
      <span id="statusIp" class="status-ip"></span>
    </div>
  </div>

  <!-- Wi-Fi -->
  <div class="card">
    <div class="card-title">📶 Wi-Fi Networks</div>
    <button class="btn-scan" id="scanBtn" onclick="scanNetworks()">
      <span class="scan-icon">⟳</span> Scan for Networks
    </button>
    <div class="net-list" id="netList"></div>
  </div>

  <!-- Credentials -->
  <div class="card">
    <div class="card-title">🔐 Wi-Fi Credentials</div>
    <div class="field">
      <label>Wi-Fi Network (SSID)</label>
      <input type="text" id="ssid" placeholder="Select from scan or type manually">
    </div>
    <div class="field">
      <label>Wi-Fi Password</label>
      <div class="input-wrap">
        <input type="password" id="pass" placeholder="Password">
        <span class="eye" onclick="toggleField('pass')">👁</span>
      </div>
    </div>
  </div>

  <!-- Devices -->
  <div class="card">
    <div class="card-title">🛰 Devices <span style="color:#475569;font-size:11px;font-weight:500;text-transform:none;letter-spacing:0">(tap Activate to select)</span></div>

    <div id="slot0" class="device-slot">
      <div class="slot-header">
        <div class="slot-label">Device 1 <span class="active-badge">ACTIVE</span></div>
        <button class="btn-activate" onclick="setActive(0)">Activate</button>
      </div>
      <div class="field" style="margin-bottom:10px">
        <label>Device Name</label>
        <input type="text" id="dev0name" placeholder="e.g. Tracker-01">
      </div>
      <div class="field" style="margin-bottom:0">
        <label>API Key</label>
        <div class="input-wrap">
          <input type="password" id="dev0key" placeholder="64-character key from TraceX app">
          <span class="eye" onclick="toggleField('dev0key')">👁</span>
        </div>
      </div>
    </div>

    <div id="slot1" class="device-slot">
      <div class="slot-header">
        <div class="slot-label">Device 2 <span class="active-badge">ACTIVE</span></div>
        <button class="btn-activate" onclick="setActive(1)">Activate</button>
      </div>
      <div class="field" style="margin-bottom:10px">
        <label>Device Name</label>
        <input type="text" id="dev1name" placeholder="e.g. Tracker-02">
      </div>
      <div class="field" style="margin-bottom:0">
        <label>API Key</label>
        <div class="input-wrap">
          <input type="password" id="dev1key" placeholder="64-character key from TraceX app">
          <span class="eye" onclick="toggleField('dev1key')">👁</span>
        </div>
      </div>
    </div>

    <div id="slot2" class="device-slot">
      <div class="slot-header">
        <div class="slot-label">Device 3 <span class="active-badge">ACTIVE</span></div>
        <button class="btn-activate" onclick="setActive(2)">Activate</button>
      </div>
      <div class="field" style="margin-bottom:10px">
        <label>Device Name</label>
        <input type="text" id="dev2name" placeholder="e.g. Tracker-03">
      </div>
      <div class="field" style="margin-bottom:0">
        <label>API Key</label>
        <div class="input-wrap">
          <input type="password" id="dev2key" placeholder="64-character key from TraceX app">
          <span class="eye" onclick="toggleField('dev2key')">👁</span>
        </div>
      </div>
    </div>

    <button class="btn-connect" id="connectBtn" onclick="saveAndConnect()">
      🔗 Save &amp; Connect
    </button>
  </div>

  <div class="reset-link" onclick="resetDevice()">Reset all saved credentials</div>
</div>

<div id="toast"></div>

<script>
  let selectedSSID  = '';
  let activeSlot    = 0;

  function setActive(idx) {
    activeSlot = idx;
    for (let i = 0; i < 3; i++) {
      document.getElementById('slot' + i).classList.toggle('active-slot', i === idx);
    }
  }

  async function pollStatus() {
    try {
      const r = await fetch('/status');
      const d = await r.json();
      const dot = document.getElementById('dot');
      const txt = document.getElementById('statusText');
      const ip  = document.getElementById('statusIp');
      if (d.connected) {
        dot.className   = 'dot green';
        txt.textContent = 'Connected to ' + d.ssid;
        ip.textContent  = d.ip;
      } else {
        dot.className   = 'dot red';
        txt.textContent = 'Not connected';
        ip.textContent  = '';
      }
    } catch (_) {
      document.getElementById('dot').className        = 'dot red';
      document.getElementById('statusText').textContent = 'Setup mode (AP)';
      document.getElementById('statusIp').textContent  = '192.168.4.1';
    }
  }

  async function scanNetworks() {
    const btn  = document.getElementById('scanBtn');
    const list = document.getElementById('netList');
    btn.classList.add('spinning');
    btn.disabled = true;
    list.innerHTML = '<div style="text-align:center;color:#64748B;padding:12px;font-size:13px">Scanning…</div>';
    try {
      const r    = await fetch('/scan');
      const nets = await r.json();
      list.innerHTML = '';
      if (!nets.length) {
        list.innerHTML = '<div style="text-align:center;color:#64748B;padding:12px;font-size:13px">No networks found</div>';
        return;
      }
      nets.forEach(n => {
        const el = document.createElement('div');
        el.className = 'net-item' + (n.ssid === selectedSSID ? ' active' : '');
        el.innerHTML =
          '<div class="bars">' + signalBars(n.rssi) + '</div>' +
          '<span class="net-name">' + esc(n.ssid) + '</span>' +
          '<span class="net-rssi">' + n.rssi + ' dBm</span>' +
          (n.encrypted ? '<span class="lock">🔒</span>' : '<span class="lock" style="color:#22C55E">🔓</span>');
        el.onclick = () => selectNetwork(n.ssid, el);
        list.appendChild(el);
      });
    } catch(e) {
      list.innerHTML = '<div style="text-align:center;color:#EF4444;padding:12px;font-size:13px">Scan failed — retry</div>';
    } finally {
      btn.classList.remove('spinning');
      btn.disabled = false;
    }
  }

  function signalBars(rssi) {
    const strength = rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : 1;
    const heights  = ['6px','10px','14px','18px'];
    return heights.map((h,i) =>
      `<span style="height:${h}" class="${i < strength ? 'lit' : ''}"></span>`
    ).join('');
  }

  function selectNetwork(ssid, el) {
    selectedSSID = ssid;
    document.getElementById('ssid').value = ssid;
    document.querySelectorAll('.net-item').forEach(e => e.classList.remove('active'));
    el.classList.add('active');
    document.getElementById('pass').focus();
  }

  async function saveAndConnect() {
    const ssid = document.getElementById('ssid').value.trim();
    const pass = document.getElementById('pass').value;

    if (!ssid) { toast('Enter a Wi-Fi network name', 'err'); return; }

    // Collect all 3 device slots
    const devices = [];
    for (let i = 0; i < 3; i++) {
      devices.push({
        name: document.getElementById('dev' + i + 'name').value.trim(),
        key:  document.getElementById('dev' + i + 'key').value.trim()
      });
    }

    // Active slot must have a key
    if (!devices[activeSlot].key) {
      toast('Active device (Device ' + (activeSlot+1) + ') needs an API key', 'err');
      return;
    }

    const btn = document.getElementById('connectBtn');
    btn.disabled    = true;
    btn.textContent = '⏳ Saving…';

    try {
      const r = await fetch('/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ssid, pass, active_dev: activeSlot, devices })
      });
      if (r.ok) {
        toast('Saved! Connecting to ' + ssid + '…', 'ok');
        document.getElementById('dot').className        = 'dot blue';
        document.getElementById('statusText').textContent = 'Connecting to ' + ssid + '…';
        setTimeout(pollStatus, 3000);
        setTimeout(pollStatus, 7000);
        setTimeout(pollStatus, 12000);
      } else {
        toast('Save failed — try again', 'err');
      }
    } catch(_) {
      toast('Save failed — try again', 'err');
    } finally {
      btn.disabled    = false;
      btn.textContent = '🔗 Save & Connect';
    }
  }

  async function resetDevice() {
    if (!confirm('Clear all saved credentials? The device will restart in setup mode.')) return;
    await fetch('/reset', { method: 'POST' }).catch(() => {});
    toast('Credentials cleared — reconnecting to GPS-Tracker-Setup…', 'ok');
    setTimeout(() => location.reload(), 3000);
  }

  function toggleField(id) {
    const f = document.getElementById(id);
    f.type = f.type === 'password' ? 'text' : 'password';
  }

  function esc(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  let toastTimer;
  function toast(msg, type) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.className   = 'show ' + (type || '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.className = '', 3500);
  }

  (async () => {
    await pollStatus();
    try {
      const r = await fetch('/config');
      const d = await r.json();
      if (d.ssid) { document.getElementById('ssid').value = d.ssid; selectedSSID = d.ssid; }
      for (let i = 0; i < 3; i++) {
        if (d.devices && d.devices[i]) {
          document.getElementById('dev' + i + 'name').value = d.devices[i].name || '';
          document.getElementById('dev' + i + 'key').value  = d.devices[i].key  || '';
        }
      }
      setActive(d.active_dev || 0);
    } catch(_) { setActive(0); }
    await scanNetworks();
  })();
</script>
</body>
</html>
)rawhtml";

// ── Web server handlers ───────────────────────────────────────────────────────

void handleRoot() {
  webServer.send_P(200, "text/html", HTML_PAGE);
}

void handleScan() {
  int n = WiFi.scanNetworks();
  JsonDocument doc;
  JsonArray arr = doc.to<JsonArray>();
  for (int i = 0; i < n; i++) {
    JsonObject o = arr.add<JsonObject>();
    o["ssid"]      = WiFi.SSID(i);
    o["rssi"]      = WiFi.RSSI(i);
    o["encrypted"] = (WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
  }
  String out;
  serializeJson(doc, out);
  webServer.send(200, "application/json", out);
}

void handleStatus() {
  JsonDocument doc;
  doc["connected"] = (WiFi.status() == WL_CONNECTED);
  doc["ssid"]      = WiFi.SSID();
  doc["ip"]        = WiFi.localIP().toString();
  String out;
  serializeJson(doc, out);
  webServer.send(200, "application/json", out);
}

void handleConfig() {
  loadPrefs();
  JsonDocument doc;
  doc["ssid"]       = savedSSID;
  doc["active_dev"] = activeDevice;
  JsonArray devArr  = doc["devices"].to<JsonArray>();
  for (int i = 0; i < MAX_DEVICES; i++) {
    JsonObject o = devArr.add<JsonObject>();
    o["name"] = devName[i];
    o["key"]  = devKey[i];
  }
  String out;
  serializeJson(doc, out);
  webServer.send(200, "application/json", out);
}

void handleSave() {
  if (!webServer.hasArg("plain")) {
    webServer.send(400, "application/json", "{\"error\":\"No body\"}");
    return;
  }
  JsonDocument doc;
  if (deserializeJson(doc, webServer.arg("plain")) != DeserializationError::Ok) {
    webServer.send(400, "application/json", "{\"error\":\"Bad JSON\"}");
    return;
  }

  String ssid = doc["ssid"].as<String>();
  String pass = doc["pass"].as<String>();
  int    act  = doc["active_dev"] | 0;
  if (act < 0 || act >= MAX_DEVICES) act = 0;

  String names[MAX_DEVICES], keys[MAX_DEVICES];
  JsonArray devArr = doc["devices"].as<JsonArray>();
  for (int i = 0; i < MAX_DEVICES; i++) {
    names[i] = devArr[i]["name"].as<String>();
    keys[i]  = devArr[i]["key"].as<String>();
  }

  if (!ssid.length() || !keys[act].length()) {
    webServer.send(400, "application/json", "{\"error\":\"ssid and active device key required\"}");
    return;
  }

  savePrefs(ssid, pass, act, names, keys);
  webServer.send(200, "application/json", "{\"ok\":true}");

  Serial.printf("[WiFi] Trying saved credentials: %s\n", ssid.c_str());
  WiFi.begin(ssid.c_str(), pass.c_str());
}

void handleReset() {
  clearPrefs();
  webServer.send(200, "application/json", "{\"ok\":true}");
  delay(500);
  ESP.restart();
}

void handleCaptive() {
  webServer.sendHeader("Location", "http://192.168.4.1/", true);
  webServer.send(302, "text/plain", "");
}

void startAP() {
  WiFi.disconnect(true);
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASS);
  delay(200);

  Serial.printf("[AP] Started: SSID=%s  IP=192.168.4.1\n", AP_SSID);

  dnsServer.start(53, "*", IPAddress(192, 168, 4, 1));

  webServer.on("/",       HTTP_GET,  handleRoot);
  webServer.on("/scan",   HTTP_GET,  handleScan);
  webServer.on("/status", HTTP_GET,  handleStatus);
  webServer.on("/config", HTTP_GET,  handleConfig);
  webServer.on("/save",   HTTP_POST, handleSave);
  webServer.on("/reset",  HTTP_POST, handleReset);
  webServer.onNotFound(handleCaptive);
  webServer.begin();

  Serial.println("[AP] Web server running — open http://192.168.4.1 in a browser");
  appState = SETUP_MODE;
}

// ── WiFi STA ──────────────────────────────────────────────────────────────────
bool connectWiFi(const String &ssid, const String &pass) {
  Serial.printf("[WiFi] Connecting to %s", ssid.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), pass.c_str());

  unsigned long t = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - t > WIFI_CONNECT_TIMEOUT) {
      Serial.println("\n[WiFi] Timeout");
      return false;
    }
    delay(400);
    Serial.print(".");
    digitalWrite(LED_PIN, !digitalRead(LED_PIN));
  }
  Serial.printf("\n[WiFi] Connected — IP: %s\n", WiFi.localIP().toString().c_str());
  digitalWrite(LED_PIN, HIGH);
  return true;
}

void ensureWiFi() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WiFi] Reconnecting…");
    loadPrefs();
    connectWiFi(savedSSID, savedPass);
  }
}

// ── GPS config ────────────────────────────────────────────────────────────────
void configureGPS() {
  Serial.println("[GPS] Starting at 9600 baud…");
  gpsSerial.begin(GPS_BAUD_INIT, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(500);
  Serial.println("[GPS] Switching to 115200 baud…");
  sendUBX(gpsSerial, UBX_SET_BAUD_115200, sizeof(UBX_SET_BAUD_115200));
  delay(100);
  gpsSerial.end();
  delay(50);
  gpsSerial.begin(GPS_BAUD_FAST, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(200);
  Serial.println("[GPS] Setting 10 Hz rate…");
  sendUBX(gpsSerial, UBX_SET_RATE_10HZ, sizeof(UBX_SET_RATE_10HZ));
  delay(100);
  sendUBX(gpsSerial, UBX_SAVE_CONFIG, sizeof(UBX_SAVE_CONFIG));
  delay(200);
  Serial.println("[GPS] Configured. Waiting for satellite lock…");
}

// ── HTTP POST GPS fix ─────────────────────────────────────────────────────────
void postLocation() {
  if (!gps.location.isValid() || !gps.location.isUpdated()) return;

  JsonDocument doc;
  doc["lat"] = gps.location.lat();
  doc["lng"] = gps.location.lng();
  if (gps.speed.isValid())      doc["speed"]      = gps.speed.kmph();
  if (gps.course.isValid())     doc["course"]      = gps.course.deg();
  if (gps.altitude.isValid())   doc["altitude"]    = gps.altitude.meters();
  if (gps.satellites.isValid()) doc["satellites"]  = (int)gps.satellites.value();
  if (gps.hdop.isValid())       doc["hdop"]        = gps.hdop.hdop();
  if (gps.date.isValid() && gps.time.isValid()) {
    char ts[25];
    snprintf(ts, sizeof(ts), "%04d-%02d-%02dT%02d:%02d:%02dZ",
      gps.date.year(), gps.date.month(), gps.date.day(),
      gps.time.hour(), gps.time.minute(), gps.time.second());
    doc["gps_timestamp"] = ts;
  }

  String payload;
  serializeJson(doc, payload);

  loadPrefs();
  String activeKey = devKey[activeDevice];
  if (!activeKey.length()) {
    Serial.println("[POST] No API key configured");
    return;
  }

  HTTPClient http;
  http.begin(SERVER_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Api-Key", activeKey);
  http.setTimeout(5000);

  int code = http.POST(payload);
  if (code == 201) {
    Serial.printf("[POST] OK  dev=%s lat=%.6f lng=%.6f sats=%d spd=%.1f km/h\n",
      devName[activeDevice].length() ? devName[activeDevice].c_str() : "?",
      gps.location.lat(), gps.location.lng(),
      gps.satellites.isValid() ? (int)gps.satellites.value() : 0,
      gps.speed.isValid() ? gps.speed.kmph() : 0.0f);
    digitalWrite(LED_PIN, HIGH);
  } else {
    Serial.printf("[POST] FAIL HTTP %d\n", code);
    digitalWrite(LED_PIN, LOW);
  }
  http.end();
}

// ── Arduino entry points ──────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=== TraceX GPS Firmware ===");

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  configureGPS();
  loadPrefs();

  if (savedSSID.length() > 0 && connectWiFi(savedSSID, savedPass)) {
    appState = TRACKING_MODE;
    Serial.printf("[APP] Tracking mode — active device: %s (slot %d)\n",
      devName[activeDevice].length() ? devName[activeDevice].c_str() : "unnamed",
      activeDevice + 1);
  } else {
    Serial.println("[APP] No credentials or connection failed — starting setup AP");
    startAP();
  }

  lastPostMs = millis();
}

void loop() {
  while (gpsSerial.available()) gps.encode(gpsSerial.read());

  if (millis() > 5000 && gps.charsProcessed() < 10 && appState == TRACKING_MODE) {
    Serial.println("[GPS] WARNING: No NMEA data — check D21/D22 wiring");
    delay(2000);
    return;
  }

  if (gps.location.isUpdated() && !gpsReady) {
    gpsReady = true;
    Serial.printf("[GPS] First fix! Sats=%d\n",
      gps.satellites.isValid() ? (int)gps.satellites.value() : 0);
  }

  if (appState == SETUP_MODE) {
    dnsServer.processNextRequest();
    webServer.handleClient();

    static unsigned long ledMs = 0;
    if (millis() - ledMs > 800) { ledMs = millis(); digitalWrite(LED_PIN, !digitalRead(LED_PIN)); }

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("[APP] Connected via web UI — switching to tracking mode");
      webServer.stop();
      dnsServer.stop();
      appState = TRACKING_MODE;
    }
    return;
  }

  unsigned long now = millis();
  if (now - lastPostMs >= POST_INTERVAL_MS) {
    lastPostMs = now;
    ensureWiFi();
    if (gpsReady) {
      postLocation();
    } else {
      Serial.printf("[GPS] Waiting for fix… chars=%lu sats=%d\n",
        gps.charsProcessed(),
        gps.satellites.isValid() ? (int)gps.satellites.value() : 0);
    }
  }
}
