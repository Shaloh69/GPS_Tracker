#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <TinyGPSPlus.h>
#include <ArduinoJson.h>
#include <HardwareSerial.h>

// ── Configuration ─────────────────────────────────────────────────────────────
#define WIFI_SSID       "YOUR_WIFI_SSID"
#define WIFI_PASSWORD   "YOUR_WIFI_PASSWORD"
#define SERVER_URL      "http://YOUR_SERVER_IP:4000/api/v1/tracker/location"
#define DEVICE_API_KEY  "YOUR_DEVICE_API_KEY"   // from POST /api/v1/tracker/devices

// GPS UART pins (UART2)
#define GPS_RX_PIN  21   // D21 ← GPS TXD
#define GPS_TX_PIN  22   // D22 → GPS RXD
#define GPS_BAUD_INIT  9600    // start at default NEO-6M baud
#define GPS_BAUD_FAST  115200  // switch to this for 10 Hz

// POST interval — send every N milliseconds (not every GPS fix, to save bandwidth)
#define POST_INTERVAL_MS  1000   // 1 second

// Onboard LED
#define LED_PIN  2

// ── UBX command helpers ───────────────────────────────────────────────────────

// Switch UART1 on NEO-6M to 115200 baud (UBX-CFG-PRT)
static const uint8_t UBX_SET_BAUD_115200[] = {
  0xB5, 0x62,             // UBX sync chars
  0x06, 0x00,             // CFG-PRT class/id
  0x14, 0x00,             // payload length 20
  0x01,                   // port ID = UART1
  0x00,                   // reserved
  0x00, 0x00,             // txReady
  0xD0, 0x08, 0x00, 0x00, // mode: 8N1
  0x00, 0xC2, 0x01, 0x00, // baudRate = 115200 (little-endian)
  0x07, 0x00,             // inProtoMask: UBX+NMEA+RTCM
  0x03, 0x00,             // outProtoMask: UBX+NMEA
  0x00, 0x00,             // flags
  0x00, 0x00,             // reserved
  0xC0, 0x7E              // checksum (A+B)
};

// Set measurement rate to 100 ms = 10 Hz (UBX-CFG-RATE)
static const uint8_t UBX_SET_RATE_10HZ[] = {
  0xB5, 0x62,
  0x06, 0x08,
  0x06, 0x00,
  0x64, 0x00,   // measRate = 100 ms
  0x01, 0x00,   // navRate = 1
  0x01, 0x00,   // timeRef = GPS
  0x7A, 0x12    // checksum
};

// Save configuration to flash (UBX-CFG-CFG)
static const uint8_t UBX_SAVE_CONFIG[] = {
  0xB5, 0x62,
  0x06, 0x09,
  0x0D, 0x00,
  0x00, 0x00, 0x00, 0x00,   // clearMask
  0xFF, 0xFF, 0x00, 0x00,   // saveMask  (all)
  0x00, 0x00, 0x00, 0x00,   // loadMask
  0x17,                      // deviceMask: BBR+Flash+EEPROM+SPI
  0x31, 0xBF                 // checksum
};

static void sendUBX(HardwareSerial &serial, const uint8_t *cmd, size_t len) {
  serial.write(cmd, len);
  serial.flush();
}

// ── Globals ───────────────────────────────────────────────────────────────────
TinyGPSPlus    gps;
HardwareSerial gpsSerial(2);   // UART2

unsigned long lastPostMs  = 0;
unsigned long lastFixMs   = 0;
bool          gpsReady    = false;

// ── WiFi helpers ─────────────────────────────────────────────────────────────
void connectWiFi() {
  Serial.printf("[WiFi] Connecting to %s", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    digitalWrite(LED_PIN, !digitalRead(LED_PIN));  // blink while connecting
  }
  Serial.printf("\n[WiFi] Connected — IP: %s\n", WiFi.localIP().toString().c_str());
  digitalWrite(LED_PIN, HIGH);
}

void ensureWiFi() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WiFi] Reconnecting…");
    WiFi.disconnect();
    connectWiFi();
  }
}

// ── GPS setup ────────────────────────────────────────────────────────────────
void configureGPS() {
  Serial.println("[GPS] Starting at 9600 baud…");
  gpsSerial.begin(GPS_BAUD_INIT, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(500);

  // 1 — Switch NEO-6M to 115200
  Serial.println("[GPS] Switching baud to 115200…");
  sendUBX(gpsSerial, UBX_SET_BAUD_115200, sizeof(UBX_SET_BAUD_115200));
  delay(100);

  // 2 — Reconnect at 115200
  gpsSerial.end();
  delay(50);
  gpsSerial.begin(GPS_BAUD_FAST, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  delay(200);

  // 3 — Set 10 Hz measurement rate
  Serial.println("[GPS] Setting 10 Hz rate…");
  sendUBX(gpsSerial, UBX_SET_RATE_10HZ, sizeof(UBX_SET_RATE_10HZ));
  delay(100);

  // 4 — Save to flash so it survives power cycle
  sendUBX(gpsSerial, UBX_SAVE_CONFIG, sizeof(UBX_SAVE_CONFIG));
  delay(200);

  Serial.println("[GPS] Configured. Waiting for satellite lock…");
}

// ── HTTP POST ─────────────────────────────────────────────────────────────────
void postLocation() {
  if (!gps.location.isValid() || !gps.location.isUpdated()) return;

  // Build JSON payload
  JsonDocument doc;
  doc["lat"]        = gps.location.lat();
  doc["lng"]        = gps.location.lng();
  doc["speed"]      = gps.speed.isValid()    ? gps.speed.kmph()         : JsonNull{};
  doc["course"]     = gps.course.isValid()   ? gps.course.deg()         : JsonNull{};
  doc["altitude"]   = gps.altitude.isValid() ? gps.altitude.meters()    : JsonNull{};
  doc["satellites"] = gps.satellites.isValid()? (int)gps.satellites.value() : JsonNull{};
  doc["hdop"]       = gps.hdop.isValid()     ? gps.hdop.hdop()          : JsonNull{};

  if (gps.date.isValid() && gps.time.isValid()) {
    char ts[25];
    snprintf(ts, sizeof(ts), "%04d-%02d-%02dT%02d:%02d:%02dZ",
      gps.date.year(), gps.date.month(), gps.date.day(),
      gps.time.hour(), gps.time.minute(), gps.time.second());
    doc["gps_timestamp"] = ts;
  }

  String payload;
  serializeJson(doc, payload);

  HTTPClient http;
  http.begin(SERVER_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-Api-Key", DEVICE_API_KEY);
  http.setTimeout(5000);

  int code = http.POST(payload);
  if (code == 201) {
    Serial.printf("[POST] OK  lat=%.6f lng=%.6f sats=%d spd=%.1f km/h\n",
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

// ── Arduino entry points ─────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("\n=== GPS Tracker Firmware ===");

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

  configureGPS();
  connectWiFi();

  lastPostMs = millis();
}

void loop() {
  // Feed all available GPS bytes to TinyGPS++
  while (gpsSerial.available()) {
    char c = gpsSerial.read();
    gps.encode(c);
  }

  // Warn if no NMEA data received at all in 5 s (wiring or baud issue)
  if (millis() > 5000 && gps.charsProcessed() < 10) {
    Serial.println("[GPS] WARNING: No NMEA data — check wiring (D21/D22)");
    delay(2000);
    return;
  }

  // Log satellite lock status periodically
  if (gps.location.isUpdated()) {
    lastFixMs = millis();
    if (!gpsReady) {
      gpsReady = true;
      Serial.printf("[GPS] First fix! Sats=%d\n",
        gps.satellites.isValid() ? (int)gps.satellites.value() : 0);
    }
  }

  // POST at configured interval
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
