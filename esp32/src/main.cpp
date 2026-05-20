#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <HTTPClient.h>
#include <TinyGPSPlus.h>
#include <ArduinoJson.h>
#include <HardwareSerial.h>
#include "qrcode.h"

// ── Pin config ────────────────────────────────────────────────────────────────
#define GPS_RX_PIN       21
#define GPS_TX_PIN       22
#define GPS_BAUD_INIT    9600
#define GPS_BAUD_FAST    115200
#define POST_INTERVAL_MS 1000
#define LED_PIN          2

// ── Server ────────────────────────────────────────────────────────────────────
#define SERVER_URL       "https://gps-tracker-xw5w.onrender.com/api/v1/tracker/location"
#define PING_URL         "https://gps-tracker-xw5w.onrender.com/api/v1/tracker/ping"
#define PING_INTERVAL_MS 30000

// ── WiFi Manager config ───────────────────────────────────────────────────────
#define AP_SSID              "GPS-Tracker-Setup"
#define AP_PASS              ""
#define WIFI_CONNECT_TIMEOUT 15000
#define FORCE_AP_PIN         0    // GPIO0 = BOOT button on ESP32 DevKit

// ── App state ─────────────────────────────────────────────────────────────────
enum AppState { SETUP_MODE, TRACKING_MODE };
AppState appState = SETUP_MODE;

// ── Services ──────────────────────────────────────────────────────────────────
WebServer      webServer(80);
DNSServer      dnsServer;
Preferences    prefs;
TinyGPSPlus    gps;
HardwareSerial gpsSerial(2);

unsigned long lastPostMs   = 0;
unsigned long lastPingMs   = 0;
unsigned long lastSysMs    = 0;
unsigned long lastGpsLogMs = 0;
unsigned long bootHoldMs   = 0;
bool gpsReady              = false;
bool deviceRegistered      = false;
bool gpsNmeaStarted        = false; // true once NMEA chars start arriving

#define SYS_LOG_INTERVAL_MS  30000  // system health log every 30 s
#define GPS_LOG_INTERVAL_MS   5000  // GPS-waiting log every 5 s (not every 1 s)

// ── LED state machine ─────────────────────────────────────────────────────────
enum LedMode {
  LED_OFF,          // solid off
  LED_SLOW,         // 800 ms toggle  — setup / AP portal
  LED_MEDIUM,       // 300 ms toggle  — WiFi connecting / reconnecting
  LED_RAPID,        // 100 ms toggle  — tracking, waiting for GPS satellite fix
  LED_PULSE,        // 100 ms ON, 900 ms OFF per second — GPS locked + sending OK
};
volatile LedMode       ledMode    = LED_OFF;
volatile bool          ledState   = false;
volatile unsigned long ledLastMs  = 0;

void updateLed() {
  unsigned long now = millis();
  switch (ledMode) {
    case LED_OFF:
      digitalWrite(LED_PIN, LOW);
      break;
    case LED_SLOW:
      if (now - ledLastMs >= 800) {
        ledLastMs = now; ledState = !ledState;
        digitalWrite(LED_PIN, ledState);
      }
      break;
    case LED_MEDIUM:
      if (now - ledLastMs >= 300) {
        ledLastMs = now; ledState = !ledState;
        digitalWrite(LED_PIN, ledState);
      }
      break;
    case LED_RAPID:
      if (now - ledLastMs >= 100) {
        ledLastMs = now; ledState = !ledState;
        digitalWrite(LED_PIN, ledState);
      }
      break;
    case LED_PULSE:
      // brief 100 ms flash once per second
      if (ledState  && now - ledLastMs >= 100)  { ledLastMs = now; ledState = false; digitalWrite(LED_PIN, LOW);  }
      if (!ledState && now - ledLastMs >= 900)  { ledLastMs = now; ledState = true;  digitalWrite(LED_PIN, HIGH); }
      break;
  }
}

// FreeRTOS timer — keeps LED blinking even while HTTP calls block the main loop
static TimerHandle_t ledTimerH = NULL;
static void ledTimerCB(TimerHandle_t) { updateLed(); }

// NVS state
String savedSSID, savedPass, apiKey;

// ── UBX GPS config commands ───────────────────────────────────────────────────
static const uint8_t UBX_SET_BAUD_115200[] = {
  0xB5,0x62,0x06,0x00,0x14,0x00,0x01,0x00,0x00,0x00,
  0xD0,0x08,0x00,0x00,0x00,0xC2,0x01,0x00,0x07,0x00,
  0x03,0x00,0x00,0x00,0x00,0x00,0xC0,0x7E
};
// NEO-6M max is 5 Hz; 1 Hz is stable and sufficient for 1-s POST interval
static const uint8_t UBX_SET_RATE_1HZ[] = {
  0xB5,0x62,0x06,0x08,0x06,0x00,0xE8,0x03,0x01,0x00,0x01,0x00,0x01,0x39
};
static const uint8_t UBX_SAVE_CONFIG[] = {
  0xB5,0x62,0x06,0x09,0x0D,0x00,0x00,0x00,0x00,0x00,
  0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x17,0x31,0xBF
};
// UBX-CFG-MSG: explicitly enable NMEA GGA/RMC/GSA/GSV on UART1 at 1 Hz
// Checksums verified via Fletcher-8 over class+id+len+payload
static const uint8_t UBX_NMEA_GGA[] = {0xB5,0x62,0x06,0x01,0x03,0x00,0xF0,0x00,0x01,0xFB,0x10};
static const uint8_t UBX_NMEA_RMC[] = {0xB5,0x62,0x06,0x01,0x03,0x00,0xF0,0x04,0x01,0xFF,0x18};
static const uint8_t UBX_NMEA_GSA[] = {0xB5,0x62,0x06,0x01,0x03,0x00,0xF0,0x02,0x01,0xFD,0x14};
static const uint8_t UBX_NMEA_GSV[] = {0xB5,0x62,0x06,0x01,0x03,0x00,0xF0,0x03,0x01,0xFE,0x16};
// UBX-CFG-CFG: clear all saved config + reload factory defaults.
// clearMask=0xFFFF  saveMask=0  loadMask=0xFFFF  deviceMask=0x17 (BBR+Flash+EEPROM+SPI)
// This is the cure for the module being stuck in UBX-binary-only output mode:
// after this command it reverts to 9600-baud NMEA output (factory state).
static const uint8_t UBX_CFG_CLEAR[] = {
  0xB5,0x62,0x06,0x09,0x0D,0x00,
  0xFF,0xFF,0x00,0x00,  // clearMask
  0x00,0x00,0x00,0x00,  // saveMask
  0xFF,0xFF,0x00,0x00,  // loadMask
  0x17,                  // deviceMask
  0x2F,0xAE              // Fletcher-8 checksum
};

static void sendUBX(HardwareSerial &s, const uint8_t *cmd, size_t len) {
  s.write(cmd, len); s.flush();
}

// ── API key generation (hardware RNG → 64-char lowercase hex) ─────────────────
String generateApiKey() {
  String key;
  key.reserve(65);
  for (int i = 0; i < 8; i++) {
    char buf[9];
    snprintf(buf, sizeof(buf), "%08x", (unsigned int)esp_random());
    key += buf;
  }
  return key;
}

// ── NVS helpers ───────────────────────────────────────────────────────────────
void loadPrefs() {
  prefs.begin("gps-tracker", true);
  savedSSID = prefs.getString("ssid",    "");
  savedPass = prefs.getString("pass",    "");
  apiKey    = prefs.getString("api_key", "");
  prefs.end();

  if (apiKey.isEmpty()) {
    apiKey = generateApiKey();
    prefs.begin("gps-tracker", false);
    prefs.putString("api_key", apiKey);
    prefs.end();
    Serial.printf("[APP] Generated new API key: %s\n", apiKey.c_str());
  } else {
    Serial.printf("[APP] Loaded API key: %s…\n", apiKey.substring(0, 8).c_str());
  }
}

void savePrefs(const String &ssid, const String &pass) {
  prefs.begin("gps-tracker", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
  savedSSID = ssid;
  savedPass = pass;
}

void clearPrefs() {
  prefs.begin("gps-tracker", false);
  prefs.clear();
  prefs.end();
}

void clearWiFiPrefs() {
  prefs.begin("gps-tracker", false);
  prefs.remove("ssid");
  prefs.remove("pass");
  prefs.end();
  savedSSID = "";
  savedPass = "";
}

// ── HTML portal ───────────────────────────────────────────────────────────────
const char HTML_PAGE[] PROGMEM = R"rawhtml(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TraceX — Setup</title>
<style>
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#080F1E;color:#E2E8F0;min-height:100vh;display:flex;flex-direction:column;align-items:center;padding:24px 16px 48px}
  body::before,body::after{content:'';position:fixed;border-radius:50%;pointer-events:none;z-index:0}
  body::before{width:400px;height:400px;top:-120px;right:-100px;background:radial-gradient(circle,rgba(99,102,241,.25) 0%,transparent 70%)}
  body::after{width:350px;height:350px;bottom:-60px;left:-80px;background:radial-gradient(circle,rgba(6,182,212,.18) 0%,transparent 70%)}
  .wrap{width:100%;max-width:480px;position:relative;z-index:1}
  .header{text-align:center;margin-bottom:32px}
  .header .icon{display:inline-flex;align-items:center;justify-content:center;width:64px;height:64px;border-radius:18px;background:linear-gradient(135deg,#1E3A8A,#3B82F6);font-size:30px;margin-bottom:12px;box-shadow:0 8px 24px rgba(59,130,246,.35)}
  .header h1{font-size:24px;font-weight:700;color:#fff}
  .header p{font-size:14px;color:#94A3B8;margin-top:4px}
  .server-badge{display:inline-flex;align-items:center;gap:6px;background:rgba(34,197,94,.1);border:1px solid rgba(34,197,94,.25);color:#4ADE80;font-size:11px;font-family:monospace;padding:5px 12px;border-radius:50px;margin-top:10px}
  .dot-green{width:7px;height:7px;border-radius:50%;background:#22C55E;box-shadow:0 0 6px rgba(34,197,94,.5)}
  .card{background:rgba(13,23,48,.85);border:1px solid rgba(255,255,255,.1);border-radius:20px;padding:24px;margin-bottom:16px;backdrop-filter:blur(12px)}
  .card-title{font-size:13px;font-weight:700;letter-spacing:.06em;color:#60A5FA;text-transform:uppercase;margin-bottom:16px;display:flex;align-items:center;gap:8px}
  .btn-scan{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;padding:11px;border-radius:12px;border:1px solid rgba(59,130,246,.3);cursor:pointer;background:rgba(59,130,246,.15);color:#60A5FA;font-size:14px;font-weight:600;transition:all .2s}
  .btn-scan:hover{background:rgba(59,130,246,.25)}
  .btn-scan.spinning .scan-icon{animation:spin 1s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  .net-list{margin-top:14px;display:flex;flex-direction:column;gap:8px}
  .net-item{display:flex;align-items:center;gap:12px;padding:12px 14px;border-radius:12px;cursor:pointer;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.07);transition:all .15s}
  .net-item:hover{background:rgba(59,130,246,.12);border-color:rgba(59,130,246,.35)}
  .net-item.active{background:rgba(59,130,246,.18);border-color:#3B82F6}
  .bars{display:flex;align-items:flex-end;gap:2px;height:18px}
  .bars span{width:4px;border-radius:2px;background:#1E40AF;transition:background .15s}
  .bars span.lit{background:#3B82F6}
  .net-item.active .bars span.lit{background:#60A5FA}
  .net-name{flex:1;font-size:14px;font-weight:500;color:#E2E8F0}
  .net-rssi{font-size:11px;color:#64748B}
  .lock{font-size:13px;color:#475569}
  .field{margin-bottom:14px}
  label{display:block;font-size:12px;font-weight:600;color:#94A3B8;margin-bottom:6px}
  .input-wrap{position:relative}
  input[type=text],input[type=password]{width:100%;padding:11px 14px;border-radius:12px;background:rgba(21,34,64,.9);border:1px solid rgba(255,255,255,.1);color:#fff;font-size:14px;outline:none;transition:border-color .2s}
  input:focus{border-color:#3B82F6;box-shadow:0 0 0 3px rgba(59,130,246,.15)}
  .eye{position:absolute;right:12px;top:50%;transform:translateY(-50%);cursor:pointer;color:#64748B;font-size:16px;user-select:none;transition:color .2s}
  .eye:hover{color:#94A3B8}
  .btn-connect{width:100%;padding:14px;border-radius:14px;border:none;cursor:pointer;background:linear-gradient(135deg,#1D4ED8,#3B82F6);color:#fff;font-size:15px;font-weight:700;margin-top:8px;transition:all .2s;box-shadow:0 4px 16px rgba(59,130,246,.3);display:flex;align-items:center;justify-content:center;gap:8px}
  .btn-connect:hover{transform:translateY(-1px);box-shadow:0 6px 20px rgba(59,130,246,.4)}
  .btn-connect:active{transform:translateY(0)}
  .btn-connect:disabled{opacity:.5;cursor:not-allowed;transform:none}
  .status-row{display:flex;align-items:center;gap:10px;padding:12px 14px;border-radius:12px;background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.07);margin-bottom:10px;font-size:13px}
  .dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;background:#475569}
  .dot.green{background:#22C55E;box-shadow:0 0 8px rgba(34,197,94,.5)}
  .dot.blue{background:#3B82F6;animation:pulse 1.4s ease-in-out infinite}
  .dot.red{background:#EF4444}
  @keyframes pulse{0%,100%{box-shadow:0 0 0 0 rgba(59,130,246,.5)}50%{box-shadow:0 0 0 5px rgba(59,130,246,0)}}
  .status-text{flex:1;color:#CBD5E1}
  .status-ip{font-size:12px;color:#60A5FA;font-family:monospace}
  .qr-wrap{text-align:center}
  .qr-frame{display:inline-block;background:#fff;padding:14px;border-radius:14px;margin-bottom:14px;box-shadow:0 4px 20px rgba(0,0,0,.4)}
  .qr-hint{font-size:13px;color:#94A3B8;margin-bottom:14px;line-height:1.6}
  .qr-hint strong{color:#60A5FA}
  .key-box{background:rgba(21,34,64,.9);border:1px solid rgba(255,255,255,.1);border-radius:10px;padding:10px 14px;text-align:left;margin-bottom:12px}
  .key-label{display:block;font-size:10px;font-weight:700;color:#60A5FA;letter-spacing:.08em;margin-bottom:4px}
  .key-val{font-family:monospace;font-size:11px;color:#94A3B8;word-break:break-all}
  .btn-dl{width:100%;padding:10px;border-radius:12px;border:1px solid rgba(245,158,11,.35);background:rgba(245,158,11,.1);color:#F59E0B;font-size:13px;font-weight:600;cursor:pointer;transition:all .2s}
  .btn-dl:hover{background:rgba(245,158,11,.2)}
  .modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:200;align-items:center;justify-content:center;padding:20px}
  .modal-overlay.show{display:flex}
  .modal-box{background:#0D1730;border:1px solid rgba(255,255,255,.15);border-radius:20px;padding:24px;max-width:340px;width:100%}
  .modal-icon{font-size:36px;text-align:center;margin-bottom:12px}
  .modal-title{color:#fff;font-size:17px;font-weight:700;text-align:center;margin-bottom:8px}
  .modal-body{color:#94A3B8;font-size:13px;line-height:1.65;text-align:center;margin-bottom:20px}
  .modal-body strong{color:#F59E0B}
  .modal-row{display:flex;gap:10px}
  .btn-cancel{flex:1;padding:11px;border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(255,255,255,.05);color:#94A3B8;font-size:14px;cursor:pointer}
  .btn-dl-confirm{flex:1;padding:11px;border-radius:12px;border:none;background:linear-gradient(135deg,#92400E,#F59E0B);color:#fff;font-size:14px;font-weight:600;cursor:pointer;text-decoration:none;text-align:center;display:flex;align-items:center;justify-content:center;gap:6px}
  #toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%) translateY(80px);background:rgba(13,23,48,.95);border:1px solid rgba(255,255,255,.12);color:#E2E8F0;padding:10px 20px;border-radius:50px;font-size:13px;font-weight:500;transition:transform .3s ease;pointer-events:none;z-index:99;white-space:nowrap;box-shadow:0 8px 24px rgba(0,0,0,.4)}
  #toast.show{transform:translateX(-50%) translateY(0)}
  #toast.ok{border-color:rgba(34,197,94,.4)}
  #toast.err{border-color:rgba(239,68,68,.4)}
  .reset-link{text-align:center;font-size:12px;color:#475569;cursor:pointer;text-decoration:underline;text-underline-offset:3px}
  .btn-chrome{display:block;width:100%;margin-top:10px;padding:9px;border-radius:12px;border:1px solid rgba(99,102,241,.35);background:rgba(99,102,241,.1);color:#818CF8;font-size:12px;font-weight:600;text-align:center;text-decoration:none;cursor:pointer}
  .wire-table{width:100%;border-collapse:collapse;font-size:12px;margin-top:10px}
  .wire-table th{text-align:left;color:#60A5FA;font-weight:700;padding:6px 8px;border-bottom:1px solid rgba(255,255,255,.08)}
  .wire-table td{padding:6px 8px;border-bottom:1px solid rgba(255,255,255,.05);color:#CBD5E1;font-family:monospace}
  .wire-table tr:last-child td{border-bottom:none}
  .pin-esp{color:#34D399}.pin-gps{color:#F59E0B}.pin-note{color:#94A3B8;font-family:sans-serif;font-size:11px}
  .reset-link:hover{color:#EF4444}
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <div class="icon">&#128205;</div>
    <h1>TraceX</h1>
    <p>Wi-Fi Configuration &amp; Device Pairing</p>
    <div class="server-badge">
      <div class="dot-green"></div>
      gps-tracker-xw5w.onrender.com
    </div>
  </div>

  <div class="card">
    <div class="card-title">&#9889; Current Status</div>
    <div id="statusRow" class="status-row">
      <div id="dot" class="dot"></div>
      <span id="statusText" class="status-text">Checking...</span>
      <span id="statusIp" class="status-ip"></span>
    </div>
  </div>

  <div class="card">
    <div class="card-title">&#128246; Wi-Fi Networks</div>
    <button class="btn-scan" id="scanBtn" onclick="scanNetworks()">
      <span class="scan-icon">&#x27F3;</span> Scan for Networks
    </button>
    <div class="net-list" id="netList"></div>
  </div>

  <div class="card">
    <div class="card-title">&#128272; Wi-Fi Credentials</div>
    <div class="field">
      <label>Wi-Fi Network (SSID)</label>
      <input type="text" id="ssid" placeholder="Select from scan or type manually">
    </div>
    <div class="field">
      <label>Wi-Fi Password</label>
      <div class="input-wrap">
        <input type="password" id="pass" placeholder="Password">
        <span class="eye" onclick="toggleField('pass')">&#128065;</span>
      </div>
    </div>
    <button class="btn-connect" id="connectBtn" onclick="saveAndConnect()">
      &#128279; Save &amp; Connect
    </button>
  </div>

  <div class="card">
    <div class="card-title">&#128241; Pair with TraceX App</div>
    <div class="qr-wrap">
      <div class="qr-frame">
        <img src="/qr.svg" id="qrImg" alt="API Key QR Code" width="216" height="216">
      </div>
      <p class="qr-hint">Open <strong>TraceX</strong> app &#8594; <em>Add Device</em> &#8594; Scan this QR code to pair</p>
      <div class="key-box">
        <span class="key-label">API KEY</span>
        <code id="apiKeyText" class="key-val">Loading...</code>
      </div>
      <button class="btn-dl" onclick="showDlModal()">&#11015; Download QR Code</button>
      <a class="btn-chrome" href="intent://192.168.4.1/#Intent;scheme=http;package=com.android.chrome;end">&#127758; Captive portal? Tap to open in Chrome</a>
    </div>
  </div>

  <!-- Download warning modal -->
  <div class="modal-overlay" id="dlModal">
    <div class="modal-box">
      <div class="modal-icon">&#9888;</div>
      <div class="modal-title">Download QR Code</div>
      <div class="modal-body">
        <strong>Be careful!</strong> If you lose this QR code, a full ESP32 reset is required &#8212; the device will forget its Wi-Fi credentials and generate a brand-new key, requiring re-pairing from scratch.
      </div>
      <div class="modal-row">
        <button class="btn-cancel" onclick="closeDlModal()">Cancel</button>
        <a class="btn-dl-confirm" href="/qr.bmp" onclick="closeDlModal()">&#11015; Download QR Image</a>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-title">&#128268; GPS Wiring — NEO-6M &#8596; ESP32</div>
    <table class="wire-table">
      <tr><th>NEO-6M</th><th>ESP32 DevKit</th><th>Notes</th></tr>
      <tr><td class="pin-gps">VCC</td><td class="pin-esp">3.3V</td><td class="pin-note">or 5V if module has regulator</td></tr>
      <tr><td class="pin-gps">GND</td><td class="pin-esp">GND</td><td class="pin-note">common ground</td></tr>
      <tr><td class="pin-gps">TX</td><td class="pin-esp">GPIO 21</td><td class="pin-note">GPS sends NMEA → ESP32 RX</td></tr>
      <tr><td class="pin-gps">RX</td><td class="pin-esp">GPIO 22</td><td class="pin-note">ESP32 TX → GPS config</td></tr>
    </table>
    <p style="font-size:11px;color:#475569;margin-top:10px;line-height:1.6">
      Blue LED on NEO-6M: fast blink = searching &nbsp;&#8226;&nbsp; 1 pulse/s = satellite lock<br>
      Place antenna with clear sky view for faster fix.
    </p>
  </div>

  <div class="reset-link" onclick="resetDevice()">Reset all saved credentials</div>
</div>
<div id="toast"></div>

<script>
  var selectedSSID='';
  async function pollStatus(){
    try{
      var r=await fetch('/status'),d=await r.json();
      var dot=document.getElementById('dot'),txt=document.getElementById('statusText'),ip=document.getElementById('statusIp');
      if(d.connected){dot.className='dot green';txt.textContent='Connected to '+d.ssid;ip.textContent=d.ip;}
      else{dot.className='dot red';txt.textContent='Not connected';ip.textContent='';}
    }catch(_){
      document.getElementById('dot').className='dot red';
      document.getElementById('statusText').textContent='Setup mode (AP)';
      document.getElementById('statusIp').textContent='192.168.4.1';
    }
  }
  async function scanNetworks(){
    var btn=document.getElementById('scanBtn'),list=document.getElementById('netList');
    btn.classList.add('spinning');btn.disabled=true;
    list.innerHTML='<div style="text-align:center;color:#64748B;padding:12px;font-size:13px">Scanning...</div>';
    try{
      var r=await fetch('/scan'),nets=await r.json();
      list.innerHTML='';
      if(!nets.length){list.innerHTML='<div style="text-align:center;color:#64748B;padding:12px;font-size:13px">No networks found</div>';return;}
      nets.forEach(function(n){
        var el=document.createElement('div');
        el.className='net-item'+(n.ssid===selectedSSID?' active':'');
        el.innerHTML='<div class="bars">'+signalBars(n.rssi)+'</div><span class="net-name">'+esc(n.ssid)+'</span><span class="net-rssi">'+n.rssi+' dBm</span>'+(n.encrypted?'<span class="lock">&#128274;</span>':'<span class="lock" style="color:#22C55E">&#128275;</span>');
        el.onclick=function(){selectNetwork(n.ssid,el);};
        list.appendChild(el);
      });
    }catch(e){list.innerHTML='<div style="text-align:center;color:#EF4444;padding:12px;font-size:13px">Scan failed - retry</div>';}
    finally{btn.classList.remove('spinning');btn.disabled=false;}
  }
  function signalBars(rssi){
    var s=rssi>=-55?4:rssi>=-65?3:rssi>=-75?2:1,h=['6px','10px','14px','18px'];
    return h.map(function(v,i){return '<span style="height:'+v+'" class="'+(i<s?'lit':'')+'"></span>';}).join('');
  }
  function selectNetwork(ssid,el){
    selectedSSID=ssid;document.getElementById('ssid').value=ssid;
    document.querySelectorAll('.net-item').forEach(function(e){e.classList.remove('active');});
    el.classList.add('active');document.getElementById('pass').focus();
  }
  async function saveAndConnect(){
    var ssid=document.getElementById('ssid').value.trim(),pass=document.getElementById('pass').value;
    if(!ssid){toast('Enter a Wi-Fi network name','err');return;}
    var btn=document.getElementById('connectBtn');
    btn.disabled=true;btn.textContent='Saving...';
    try{
      var r=await fetch('/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:ssid,pass:pass})});
      if(r.ok){
        toast('Saved! Connecting to '+ssid+'...','ok');
        document.getElementById('dot').className='dot blue';
        document.getElementById('statusText').textContent='Connecting to '+ssid+'...';
        setTimeout(pollStatus,3000);setTimeout(pollStatus,7000);setTimeout(pollStatus,12000);
      }else{toast('Save failed - try again','err');}
    }catch(_){toast('Save failed - try again','err');}
    finally{btn.disabled=false;btn.textContent='🔗 Save & Connect';}
  }
  async function resetDevice(){
    if(!confirm('Clear all saved credentials? The device will restart in setup mode.'))return;
    await fetch('/reset',{method:'POST'}).catch(function(){});
    toast('Credentials cleared - reconnecting to GPS-Tracker-Setup...','ok');
    setTimeout(function(){location.reload();},3000);
  }
  function toggleField(id){var f=document.getElementById(id);f.type=f.type==='password'?'text':'password';}
  function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
  function showDlModal(){document.getElementById('dlModal').classList.add('show');}
  function closeDlModal(){document.getElementById('dlModal').classList.remove('show');}
  var toastTimer;
  function toast(msg,type){
    var el=document.getElementById('toast');el.textContent=msg;el.className='show '+(type||'');
    clearTimeout(toastTimer);toastTimer=setTimeout(function(){el.className='';},3500);
  }
  (async function(){
    await pollStatus();
    try{
      var r=await fetch('/config'),d=await r.json();
      if(d.ssid){document.getElementById('ssid').value=d.ssid;selectedSSID=d.ssid;}
      if(d.api_key){document.getElementById('apiKeyText').textContent=d.api_key;}
    }catch(_){}
    await scanNetworks();
  })();
</script>
</body>
</html>
)rawhtml";

// ── QR code SVG (served from /qr.svg) ────────────────────────────────────────
// Uses QR version 5 (37x37 matrix) with ECC_LOW — handles 64-byte hex key
void handleQRSvg() {
  Serial.printf("[WEB] /qr.svg requested  key: %s…\n", apiKey.substring(0, 8).c_str());
  const uint8_t version    = 5;
  const int     moduleSize = 6;
  const int     quietZone  = 4;

  uint8_t qrcodeData[qrcode_getBufferSize(version)];
  QRCode  qrcode;
  if (qrcode_initText(&qrcode, qrcodeData, version, ECC_LOW, apiKey.c_str()) != 0) {
    webServer.send(500, "text/plain", "QR generation failed");
    return;
  }

  int svgPx = (qrcode.size + 2 * quietZone) * moduleSize;

  webServer.setContentLength(CONTENT_LENGTH_UNKNOWN);
  webServer.send(200, "image/svg+xml", "");

  // Header
  String h;
  h.reserve(200);
  h  = F("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"");
  h += svgPx; h += F("\" height=\""); h += svgPx;
  h += F("\" viewBox=\"0 0 "); h += svgPx; h += ' '; h += svgPx; h += F("\">");
  h += F("<rect width=\"100%\" height=\"100%\" fill=\"#fff\"/><g fill=\"#000\">");
  webServer.sendContent(h);

  // One chunk per row
  for (uint8_t y = 0; y < qrcode.size; y++) {
    String row;
    row.reserve(qrcode.size * 28);
    for (uint8_t x = 0; x < qrcode.size; x++) {
      if (qrcode_getModule(&qrcode, x, y)) {
        row += F("<rect x=\"");
        row += (int)((x + quietZone) * moduleSize);
        row += F("\" y=\"");
        row += (int)((y + quietZone) * moduleSize);
        row += F("\" width=\"6\" height=\"6\"/>");
      }
    }
    if (row.length()) webServer.sendContent(row);
  }

  webServer.sendContent(F("</g></svg>"));
  webServer.sendContent("");  // end chunked
}

// ── QR code BMP download (/qr.bmp) ───────────────────────────────────────────
// 1-bit monochrome BMP (~9.6 KB). No JS canvas needed — Content-Disposition
// forces the system download manager even in Android captive-portal WebView.
void handleQRBmp() {
  Serial.printf("[WEB] /qr.bmp download  key: %s…  heap: %lu B\n",
    apiKey.substring(0, 8).c_str(), (unsigned long)ESP.getFreeHeap());
  const uint8_t version    = 5;
  const int     moduleSize = 6;
  const int     quietZone  = 4;

  uint8_t qrcodeData[qrcode_getBufferSize(version)];
  QRCode  qrcode;
  if (qrcode_initText(&qrcode, qrcodeData, version, ECC_LOW, apiKey.c_str()) != 0) {
    webServer.send(500, "text/plain", "QR generation failed");
    return;
  }

  const int imgPx     = (qrcode.size + 2 * quietZone) * moduleSize; // 270
  const int rowBytes  = (imgPx + 7) / 8;                            // 34
  const int rowStride = (rowBytes + 3) & ~3;                        // 36 (4-byte aligned)
  const int pixBytes  = rowStride * imgPx;                          // 9720
  const int fileSize  = 14 + 40 + 8 + pixBytes;                    // 9782

  // Combined file header (14) + DIB header (40) + colour table (8) = 62 bytes
  uint8_t hdr[62];
  memset(hdr, 0, 62);
  hdr[0]='B'; hdr[1]='M';
  hdr[2]=fileSize&0xFF;       hdr[3]=(fileSize>>8)&0xFF;
  hdr[4]=(fileSize>>16)&0xFF; hdr[5]=(fileSize>>24)&0xFF;
  hdr[10]=62;                   // pixel data offset
  hdr[14]=40;                   // DIB header size
  hdr[18]=imgPx&0xFF; hdr[19]=(imgPx>>8)&0xFF;  // width
  hdr[22]=imgPx&0xFF; hdr[23]=(imgPx>>8)&0xFF;  // height (positive = bottom-up)
  hdr[26]=1; hdr[28]=1;         // planes=1, bpp=1
  hdr[34]=pixBytes&0xFF;       hdr[35]=(pixBytes>>8)&0xFF;
  hdr[36]=(pixBytes>>16)&0xFF; hdr[37]=(pixBytes>>24)&0xFF;
  hdr[38]=0x13; hdr[39]=0x0B;  // X ppm (~72 DPI)
  hdr[42]=0x13; hdr[43]=0x0B;  // Y ppm
  hdr[46]=2;                    // colours used
  // Colour table: index 0 = black (0,0,0,0), index 1 = white
  hdr[58]=0xFF; hdr[59]=0xFF; hdr[60]=0xFF;

  webServer.sendHeader("Content-Disposition",
    "attachment; filename=\"TraceX_DeviceQR.bmp\"");
  webServer.setContentLength(fileSize);
  webServer.send(200, "image/bmp", "");

  WiFiClient client = webServer.client();
  client.write(hdr, 62);

  // Rows are stored bottom-to-top in BMP
  uint8_t row[36];
  for (int y = imgPx - 1; y >= 0; y--) {
    memset(row, 0xFF, rowStride); // default all-white
    for (int b = 0; b < rowBytes; b++) {
      uint8_t byte = 0xFF;
      for (int i = 7; i >= 0; i--) {
        int px = b * 8 + (7 - i);
        if (px < imgPx) {
          int qrX = px / moduleSize - quietZone;
          int qrY = y  / moduleSize - quietZone;
          if (qrX >= 0 && qrX < (int)qrcode.size &&
              qrY >= 0 && qrY < (int)qrcode.size &&
              qrcode_getModule(&qrcode, qrX, qrY)) {
            byte &= ~(1 << i); // dark → bit=0 → colour index 0 (black)
          }
        }
      }
      row[b] = byte;
    }
    client.write(row, rowStride);
  }
}

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
  JsonDocument doc;
  doc["ssid"]    = savedSSID;
  doc["api_key"] = apiKey;
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

  if (!ssid.length()) {
    webServer.send(400, "application/json", "{\"error\":\"ssid required\"}");
    return;
  }

  savePrefs(ssid, pass);
  webServer.send(200, "application/json", "{\"ok\":true}");

  Serial.printf("[WiFi] Trying: %s\n", ssid.c_str());
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

// ── Access-point + web server startup ────────────────────────────────────────
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
  webServer.on("/qr.svg", HTTP_GET,  handleQRSvg);
  webServer.on("/qr.bmp", HTTP_GET,  handleQRBmp);
  webServer.on("/save",   HTTP_POST, handleSave);
  webServer.on("/reset",  HTTP_POST, handleReset);
  webServer.onNotFound(handleCaptive);
  webServer.begin();

  Serial.println("[AP] Web server ready — open http://192.168.4.1");
  ledMode = LED_SLOW;
  appState = SETUP_MODE;
}

// ── WiFi STA ──────────────────────────────────────────────────────────────────
bool connectWiFi(const String &ssid, const String &pass) {
  Serial.printf("[WiFi] Connecting to %s", ssid.c_str());
  ledMode = LED_MEDIUM;
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), pass.c_str());

  unsigned long t = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - t > WIFI_CONNECT_TIMEOUT) {
      Serial.println("\n[WiFi] Timeout");
      ledMode = LED_OFF;
      return false;
    }
    // Keep LED updating during blocking wait
    unsigned long now = millis();
    if (now - ledLastMs >= 300) {
      ledLastMs = now; ledState = !ledState;
      digitalWrite(LED_PIN, ledState);
    }
    delay(50);
    if ((millis() - t) % 400 < 50) Serial.print(".");
  }
  Serial.printf("\n[WiFi] Connected — IP: %s  RSSI: %d dBm  CH: %d\n",
    WiFi.localIP().toString().c_str(), WiFi.RSSI(), WiFi.channel());
  return true;
}

void ensureWiFi() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WiFi] Reconnecting…");
    connectWiFi(savedSSID, savedPass);
    // Restore LED to correct tracking state after reconnect
    ledMode = gpsReady ? LED_PULSE : LED_RAPID;
  }
}

// ── GPS config ────────────────────────────────────────────────────────────────
void configureGPS() {
  // ── Step 1: Factory-clear at 115200 ──────────────────────────────────────────
  // The HW-248 backup battery keeps saved config alive across power cycles.
  // Diagnosis: ok=0 err=0 with chars growing = pure UBX binary output — the
  // module was saved in UBX-binary-only mode by a prior firmware run.
  // Fix: UBX-CFG-CFG clear wipes all saved config and reverts the module to
  // factory defaults (9600 baud, NMEA output).  Send at 115200 first in case
  // the module is stuck there; if it's already at 9600 the bytes arrive garbled
  // which is harmless — it means the module is already in the right state.
  Serial.println("[GPS] Sending factory config reset at 115200…");
  gpsSerial.begin(GPS_BAUD_FAST, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN, false, 2048U);
  delay(300);
  sendUBX(gpsSerial, UBX_CFG_CLEAR, sizeof(UBX_CFG_CLEAR));
  delay(700);  // module needs ~600 ms to apply defaults and switch baud to 9600
  gpsSerial.end(); delay(100);

  // ── Step 2: Open at 9600 (factory default — permanent operating baud) ────────
  // We no longer send UBX_SET_BAUD_115200 at all.  That command, when saved,
  // is what caused the stuck-in-UBX-binary state in the first place.
  Serial.printf("[GPS] Opening at 9600 baud  RX=GPIO%d TX=GPIO%d\n",
    GPS_RX_PIN, GPS_TX_PIN);
  gpsSerial.begin(GPS_BAUD_INIT, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN, false, 2048U);
  delay(500);

  // Second clear at 9600 catches modules that were stuck in UBX-binary at 9600
  sendUBX(gpsSerial, UBX_CFG_CLEAR, sizeof(UBX_CFG_CLEAR));
  delay(700);

  bool gotData = false;
  unsigned long t = millis();
  while (millis() - t < 2000) {
    if (gpsSerial.available()) { gotData = true; break; }
    delay(10);
  }
  if (!gotData) {
    Serial.println("[GPS] ✗ No data — check wiring:");
    Serial.println("[GPS]   NEO-6M TX -> GPIO21  |  NEO-6M RX -> GPIO22  |  VCC -> 3.3V  |  GND -> GND");
  } else {
    Serial.println("[GPS] ✓ Module responding at 9600 baud");
  }

  // ── Step 3: Enable NMEA sentences + 1 Hz rate + save ─────────────────────────
  Serial.println("[GPS] Enabling NMEA sentences (GGA, RMC, GSA, GSV)…");
  sendUBX(gpsSerial, UBX_NMEA_GGA, sizeof(UBX_NMEA_GGA)); delay(50);
  sendUBX(gpsSerial, UBX_NMEA_RMC, sizeof(UBX_NMEA_RMC)); delay(50);
  sendUBX(gpsSerial, UBX_NMEA_GSA, sizeof(UBX_NMEA_GSA)); delay(50);
  sendUBX(gpsSerial, UBX_NMEA_GSV, sizeof(UBX_NMEA_GSV)); delay(50);
  Serial.println("[GPS] Setting 1 Hz update rate…");
  sendUBX(gpsSerial, UBX_SET_RATE_1HZ, sizeof(UBX_SET_RATE_1HZ)); delay(100);
  sendUBX(gpsSerial, UBX_SAVE_CONFIG, sizeof(UBX_SAVE_CONFIG));    delay(200);
  Serial.println("[GPS] ✓ Config saved — 9600 baud NMEA, waiting for satellite fix…");
  Serial.println("[GPS]   LED off/solid = searching  |  LED blinks 1/s = fix acquired");
}

// ── Heartbeat ping ────────────────────────────────────────────────────────────
void pingServer() {
  if (apiKey.isEmpty()) return;
  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  http.begin(client, PING_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Api-Key", apiKey);
  http.setTimeout(5000);
  Serial.printf("[PING] → %s  key: %s…\n", PING_URL, apiKey.substring(0, 8).c_str());
  int code = http.POST("{}");

  if (code == 200) {
    deviceRegistered = true;
    Serial.printf("[PING] ✓ Online  heap: %lu B\n", (unsigned long)ESP.getFreeHeap());
  } else if (code == 401 || code == 404) {
    if (deviceRegistered) {
      Serial.printf("[PING] ✗ HTTP %d — device removed from app, clearing NVS & restarting\n", code);
      http.end();
      clearPrefs();
      delay(500);
      ESP.restart();
    } else {
      Serial.printf("[PING] ✗ HTTP %d — not registered yet, scan QR in TraceX app to pair\n", code);
    }
  } else {
    String body = http.getString();
    Serial.printf("[PING] ✗ HTTP %d  body: %.80s\n", code, body.c_str());
  }
  http.end();
}

// ── HTTP POST GPS fix ─────────────────────────────────────────────────────────
void postLocation() {
  if (!gps.location.isValid() || !gps.location.isUpdated()) return;
  if (apiKey.isEmpty()) {
    Serial.println("[POST] No API key");
    return;
  }

  JsonDocument doc;
  doc["lat"] = gps.location.lat();
  doc["lng"] = gps.location.lng();
  if (gps.speed.isValid())      doc["speed"]     = gps.speed.kmph();
  if (gps.course.isValid())     doc["course"]    = gps.course.deg();
  if (gps.altitude.isValid())   doc["altitude"]  = gps.altitude.meters();
  if (gps.satellites.isValid()) doc["satellites"] = (int)gps.satellites.value();
  if (gps.hdop.isValid())       doc["hdop"]      = gps.hdop.hdop();
  if (gps.date.isValid() && gps.time.isValid()) {
    char ts[25];
    snprintf(ts, sizeof(ts), "%04d-%02d-%02dT%02d:%02d:%02dZ",
      gps.date.year(), gps.date.month(), gps.date.day(),
      gps.time.hour(), gps.time.minute(), gps.time.second());
    doc["gps_timestamp"] = ts;
  }

  String payload;
  serializeJson(doc, payload);

  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  http.begin(client, SERVER_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Api-Key", apiKey);
  http.setTimeout(5000);

  int code = http.POST(payload);
  if (code == 201) {
    Serial.printf("[POST] ✓ lat=%.6f lng=%.6f  sats=%d  spd=%.1fkm/h  hdop=%.2f  alt=%.1fm\n",
      gps.location.lat(), gps.location.lng(),
      gps.satellites.isValid() ? (int)gps.satellites.value() : 0,
      gps.speed.isValid()    ? gps.speed.kmph()       : 0.0f,
      gps.hdop.isValid()     ? gps.hdop.hdop()        : 99.0f,
      gps.altitude.isValid() ? gps.altitude.meters()  : 0.0f);
    ledMode = LED_PULSE;
  } else {
    String body = http.getString();
    Serial.printf("[POST] ✗ HTTP %d  body: %.80s\n", code, body.c_str());
    ledMode = LED_RAPID;
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
  pinMode(FORCE_AP_PIN, INPUT_PULLUP);

  // Start LED timer — runs in FreeRTOS timer daemon so the LED keeps blinking
  // during blocking HTTP calls (ping, post) that freeze the main loop
  ledTimerH = xTimerCreate("led", pdMS_TO_TICKS(100), pdTRUE, NULL, ledTimerCB);
  if (ledTimerH) xTimerStart(ledTimerH, 0);

  configureGPS();
  loadPrefs();

  // Hold BOOT button at power-on → force setup portal
  if (digitalRead(FORCE_AP_PIN) == LOW) {
    Serial.println("[APP] BOOT button held — forcing setup mode");
    startAP();
  } else if (savedSSID.length() > 0 && connectWiFi(savedSSID, savedPass)) {
    appState = TRACKING_MODE;
    ledMode   = LED_RAPID;   // rapid flash until GPS locks
    Serial.printf("[APP] Tracking mode — key prefix: %s…\n", apiKey.substring(0, 8).c_str());
    Serial.println("[APP] Tip: hold BOOT button 3 s to return to setup mode");
    pingServer();
  } else {
    if (savedSSID.length() > 0) {
      // Had credentials but couldn't connect — forget them so portal starts clean
      Serial.printf("[APP] Could not connect to \"%s\" — forgetting WiFi credentials\n",
        savedSSID.c_str());
      clearWiFiPrefs();
    } else {
      Serial.println("[APP] No credentials saved — starting setup AP");
    }
    startAP();
  }

  lastPostMs = millis();
}

void loop() {
  // Drain GPS serial buffer and feed TinyGPS++.
  // First 30 complete sentences are printed raw so we can verify:
  //   • sentence prefix ($GP vs $GN)  • checksum validity  • fix fields
  {
    static uint8_t  nmeaDumpLeft = 30;
    static char     nmea_line[140];
    static uint8_t  nmea_pos = 0;

    while (gpsSerial.available()) {
      char c = gpsSerial.read();
      gps.encode(c);

      if (nmeaDumpLeft > 0) {
        if (c == '$') {
          nmea_pos = 0;
          nmea_line[nmea_pos++] = '$';
        } else if (nmea_pos > 0) {
          if (c != '\r' && nmea_pos < 138) nmea_line[nmea_pos++] = c;
          if (c == '\n') {
            nmea_line[nmea_pos - 1] = '\0';   // strip newline
            if (nmea_pos > 6) {               // skip noise / short fragments
              Serial.printf("[NMEA] %s\n", nmea_line);
              nmeaDumpLeft--;
            }
            nmea_pos = 0;
          }
        }
      }
    }
  }

  // First time NMEA chars arrive — GPS module is communicating
  if (!gpsNmeaStarted && gps.charsProcessed() > 10) {
    gpsNmeaStarted = true;
    Serial.println("[GPS] ✓ NMEA data flowing — module is connected and communicating with ESP32");
    Serial.println("[GPS]   Waiting for satellite lock  (LED blinks 1/s when locked)");
  }

  if (millis() > 5000 && gps.charsProcessed() < 10 && appState == TRACKING_MODE) {
    Serial.println("[GPS] ✗ No NMEA data received — check wiring:");
    Serial.println("[GPS]   NEO-6M TX → GPIO21  |  NEO-6M RX → GPIO22  |  VCC → 3.3V  |  GND → GND");
    delay(2000);
    return;
  }

  if (gps.location.isUpdated() && !gpsReady) {
    gpsReady = true;
    Serial.printf("[GPS] ✓ First fix!  lat=%.6f lng=%.6f  sats=%d  hdop=%.2f\n",
      gps.location.lat(), gps.location.lng(),
      gps.satellites.isValid() ? (int)gps.satellites.value() : 0,
      gps.hdop.isValid()       ? gps.hdop.hdop()             : 99.0f);
  }

  if (appState == SETUP_MODE) {
    dnsServer.processNextRequest();
    webServer.handleClient();
    updateLed();

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("[APP] Connected via web UI — switching to tracking mode");
      webServer.stop();
      dnsServer.stop();
      WiFi.softAPdisconnect(true); // stop AP so its network stack doesn't corrupt STA DNS
      WiFi.mode(WIFI_STA);
      delay(1000);                 // let DHCP/DNS settle before first HTTP call
      appState = TRACKING_MODE;
      ledMode  = LED_RAPID;
      pingServer();
    }
    return;
  }

  // BOOT button long-press (3 s) while tracking → re-enter setup portal
  if (digitalRead(FORCE_AP_PIN) == LOW) {
    if (bootHoldMs == 0) bootHoldMs = millis();
    if (millis() - bootHoldMs >= 3000) {
      bootHoldMs = 0;
      Serial.println("[APP] BOOT held 3 s — returning to setup mode");
      startAP();
      return;
    }
  } else {
    bootHoldMs = 0;
  }

  updateLed();

  unsigned long now = millis();

  // System health log every 30 s
  if (now - lastSysMs >= SYS_LOG_INTERVAL_MS) {
    lastSysMs = now;
    Serial.printf("[SYS] Uptime: %lus  Heap: %luB  WiFi: %s (%ddBm)  GPS: %s  Sats: %d\n",
      now / 1000,
      (unsigned long)ESP.getFreeHeap(),
      WiFi.status() == WL_CONNECTED ? WiFi.SSID().c_str() : "DOWN",
      WiFi.RSSI(),
      gpsReady ? "LOCKED" : "SEARCHING",
      gps.satellites.isValid() ? (int)gps.satellites.value() : 0);
  }

  // Heartbeat — keep device marked online every 10 s regardless of GPS fix
  if (now - lastPingMs >= PING_INTERVAL_MS) {
    lastPingMs = now;
    ensureWiFi();
    pingServer();
  }

  if (now - lastPostMs >= POST_INTERVAL_MS) {
    lastPostMs = now;
    ensureWiFi();
    if (gpsReady) {
      postLocation();
    } else {
      if (now - lastGpsLogMs >= GPS_LOG_INTERVAL_MS) {
        lastGpsLogMs = now;
        // ok=sentences parsed OK, err=checksum failures
        // ok=0+err=0 → binary UBX or no data; ok=0+err>0 → baud/noise; ok>0 → NMEA fine
        Serial.printf("[GPS] Waiting for fix…  chars=%lu  ok=%lu  err=%lu  sats=%d  hdop=%.2f\n",
          gps.charsProcessed(),
          gps.passedChecksum(),
          gps.failedChecksum(),
          gps.satellites.isValid() ? (int)gps.satellites.value() : 0,
          gps.hdop.isValid()       ? gps.hdop.hdop()             : 99.0f);
      }
    }
  }
}
