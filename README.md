# TraceX — Real-Time GPS Tracker

**v1.0.12** · Full-stack GPS tracking system built with **ESP32**, **Node.js/TypeScript**, and **Flutter**.

---

## System Overview

```
┌─────────────────┐        HTTP POST        ┌────────────────────┐
│   ESP32 DevKit  │ ──── X-Api-Key ───────► │  Node.js Server    │
│  + NEO-6M GPS   │   /api/v1/tracker/      │  Express + MySQL   │
│  (1 Hz / 9600)  │      location           │  Socket.IO         │
└─────────────────┘                         └────────────────────┘
                                                      │
                                               Socket.IO event
                                             location:update
                                                      │
                                                      ▼
                                            ┌─────────────────────┐
                                            │   TraceX Flutter    │
                                            │   Real-time Map     │
                                            │   Device Dashboard  │
                                            └─────────────────────┘
```

---

## Repository Structure

```
GPS_Tracker/
├── server/          Node.js + TypeScript backend
├── esp32/           PlatformIO firmware (ESP32 + NEO-6M)
└── flutter_app/     Flutter mobile dashboard (TraceX)
```

---

## Hardware

### Components

| Component | Description |
|---|---|
| ESP32 DevKit V1 (30-pin) | Microcontroller — Wi-Fi, dual-core, 3.3V GPIO |
| GPS6MV2 (NEO-6M) | u-blox NEO-6M GPS module, onboard LDO, NMEA output |
| Powerbank | USB 5V power supply |

### Wiring

```
  GPS6MV2 Module              ESP32 DevKit (30-pin)
  ┌──────────────┐            ┌──────────────────────┐
  │  VCC ────────┼────────────┼─ 3.3V (or VUSB 5V)  │
  │  GND ────────┼────────────┼─ GND                 │
  │  TXD ────────┼────────────┼─ GPIO21  (UART RX)   │
  │  RXD ────────┼────────────┼─ GPIO22  (UART TX)   │
  │  [Antenna]   │            │  [Wi-Fi Antenna]     │
  └──────────────┘            └──────────────────────┘
```

| GPS6MV2 Pin | ESP32 Pin | Notes |
|---|---|---|
| VCC | 3.3V or VUSB | Module has onboard LDO — either voltage works |
| GND | GND | Common ground |
| TXD | GPIO21 | GPS sends NMEA → ESP32 receives (UART RX) |
| RXD | GPIO22 | ESP32 sends config → GPS (UART TX) |

### GPS Configuration

On boot the firmware sends UBX commands to the NEO-6M:
1. Factory-clears saved config (UBX-CFG-CFG) to escape binary-only mode
2. Operates at **9600 baud** (stable factory default — not saved to flash)
3. Explicitly enables NMEA sentences: GGA, RMC, GSA, GSV
4. Sets measurement rate to **1 Hz**
5. Saves NMEA + rate config to module flash

---

## Server

### Tech Stack

- **Runtime:** Node.js 20+
- **Framework:** Express.js 4
- **Language:** TypeScript 5
- **Database:** MySQL 8
- **Real-time:** Socket.IO 4
- **Auth:** JWT (access + refresh tokens), bcrypt

### Setup

```bash
cd server
cp .env.example .env      # fill in DB credentials and JWT secret
npm install
npm run db:init           # creates tables in MySQL
npm run dev               # hot-reload dev server (port 4000)
```

### Environment Variables

```env
PORT=4000
DB_HOST=localhost
DB_PORT=3306
DB_USER=root
DB_PASSWORD=yourpassword
DB_NAME=gps_tracker
JWT_SECRET=your-long-random-secret
```

### API Reference

#### Authentication

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| POST | `/api/v1/auth/register` | — | Create user account |
| POST | `/api/v1/auth/login` | — | Login → access + refresh tokens |
| POST | `/api/v1/auth/refresh` | — | Refresh access token |
| POST | `/api/v1/auth/logout` | JWT | Revoke session |
| GET | `/api/v1/auth/me` | JWT | Current user profile |

#### Device Management

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| POST | `/api/v1/tracker/devices` | JWT | Register ESP32 → returns `api_key` |
| GET | `/api/v1/tracker/devices` | JWT | List your devices |
| PATCH | `/api/v1/tracker/devices/:id` | JWT | Rename device |
| DELETE | `/api/v1/tracker/devices/:id` | JWT | Remove device (triggers ESP32 reset) |

#### Location

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| **POST** | `/api/v1/tracker/location` | `X-Api-Key` | **ESP32 pushes GPS fix** |
| GET | `/api/v1/tracker/locations/:id` | JWT | Location history (`?limit=200`) |
| GET | `/api/v1/tracker/locations/:id/latest` | JWT | Latest GPS fix |

#### Heartbeat Ping

| Method | Endpoint | Auth | Description |
|---|---|---|---|
| POST | `/api/v1/tracker/ping` | `X-Api-Key` | ESP32 heartbeat (every 30 s) — keeps device marked online |

#### Health

```
GET /health  →  { "status": "ok", "timestamp": "..." }
```

### WebSocket Events

Connect with JWT:
```js
const socket = io("http://server:4000", {
  auth: { token: accessToken }
});
```

| Direction | Event | Payload | Description |
|---|---|---|---|
| Client → Server | `join:device` | `deviceId: string` | Subscribe to live updates |
| Client → Server | `leave:device` | `deviceId: string` | Unsubscribe |
| Server → Client | `location:update` | `{ deviceId, deviceName, location }` | New GPS fix |
| Server → Client | `joined:device` | `{ deviceId }` | Subscription confirmed |

### Database Schema

```sql
users          — id, email, password_hash, name, role
refresh_tokens — id, user_id, token, expires_at
devices        — id, name, api_key, owner_id, is_active, is_online, last_seen
locations      — id, device_id, lat, lng, speed, course, altitude,
                 satellites, hdop, gps_timestamp, created_at
```

---

## ESP32 Firmware

### Setup (PlatformIO)

1. Install [PlatformIO IDE](https://platformio.org/) (VS Code extension)
2. Open `esp32/` in VS Code
3. Build & Upload via `PlatformIO: Upload` (Ctrl+Alt+U)
4. Monitor via `PlatformIO: Monitor` at 115200 baud

**No hardcoded credentials** — Wi-Fi and pairing are configured through the built-in web portal.

### Libraries (`platformio.ini`)

```ini
lib_deps =
    mikalhart/TinyGPSPlus @ ^1.0.3
    bblanchon/ArduinoJson @ ^7.0.0
    ricmoo/QRCode @ ^0.0.1
```

### First-Time Setup Flow

```
Power on ESP32
      │
      ├─ No saved Wi-Fi ──► AP Mode: "GPS-Tracker-Setup" (192.168.4.1)
      │                          │
      │                     Open captive portal in browser
      │                          │
      │                     Scan networks → enter password → Save & Connect
      │                          │
      │                     ESP32 connects to Wi-Fi → switches to Tracking Mode
      │
      └─ Saved Wi-Fi found ──► Connect → Tracking Mode
```

### Captive Portal (`192.168.4.1`)

The ESP32 hosts a full web UI when in setup mode:

- **Wi-Fi scan** — lists nearby networks with signal strength bars
- **Credentials form** — SSID + password with show/hide toggle
- **Status card** — live connection state (connected / not connected / IP address)
- **QR code display** — SVG rendered on-device for app pairing
- **Download QR** — saves `.bmp` to phone via system download manager
- **Wiring reference** — NEO-6M pinout table built into the page
- **Reset button** — clears all NVS credentials and restarts into setup mode

> Hold the **BOOT button for 3 seconds** while in tracking mode to re-enter setup mode at any time.

### Pairing with TraceX App

1. In the setup portal, the QR code encodes the ESP32's 64-char hex API key
2. Open TraceX → tap **Add Device**
3. Either **scan the QR** with the camera or **upload a QR image** from gallery
4. App registers the key with the server and the device appears on the map

### Device Deletion Behavior

When a device is deleted from the app, the server stops accepting its API key. The ESP32 detects the `401` response on the **very next POST or ping** (within 1–3 seconds) and immediately:
1. Clears all NVS credentials (Wi-Fi + API key)
2. Restarts into setup AP mode with a freshly generated API key

### LED Status Patterns

| Pattern | Mode | Meaning |
|---|---|---|
| Off | `LED_OFF` | Idle / uninitialised |
| Slow blink — 800 ms on/off | `LED_SLOW` | Setup AP active, needs Wi-Fi config |
| Medium blink — 300 ms on/off | `LED_MEDIUM` | Wi-Fi connecting / reconnecting |
| Rapid toggle — 100 ms on/off | `LED_RAPID` | Wi-Fi connected, waiting for GPS fix |
| **3-burst** · · · + 1.1 s gap | `LED_TRIPLE` | **No Wi-Fi** (3 × 100 ms bursts + pause) |
| **2-burst** · · + 700 ms gap | `LED_GPS_FIX` | **GPS fix acquired**, about to start posting (2 × 100 ms + pause) |
| **2-burst** · · + 1.1 s gap | `LED_DOUBLE` | **Wi-Fi OK, server not responding** (2 × 100 ms + longer pause) |
| **1-pulse** · + 900 ms gap | `LED_PULSE` | **GPS + server OK** — normal operation |

All patterns use `millis() % period` — no phase tracking needed. A FreeRTOS 100 ms timer keeps the LED blinking even during blocking HTTP calls.

### Serial Monitor Output

```
=== TraceX GPS Firmware ===
[GPS] Sending factory config reset at 115200…
[GPS] Opening at 9600 baud  RX=GPIO21 TX=GPIO22
[GPS] ✓ Module responding at 9600 baud
[GPS] Enabling NMEA sentences (GGA, RMC, GSA, GSV)…
[GPS] Setting 1 Hz update rate…
[GPS] ✓ Config saved — 9600 baud NMEA, waiting for satellite fix…
[APP] Loaded API key: a1b2c3d4…
[WiFi] Connecting to MyNetwork..............
[WiFi] Connected — IP: 192.168.1.50  RSSI: -58 dBm  CH: 6
[PING] → https://…/ping  key: a1b2c3d4…
[PING] ✓ Online  heap: 210432 B
[GPS] ✓ NMEA data flowing — module is connected and communicating with ESP32
[GPS]   Waiting for satellite lock  (LED blinks 1/s when locked)
[GPS] ✓ First fix!  lat=10.720234 lng=122.562187  sats=7  hdop=1.20
[POST] ✓ lat=10.720234 lng=122.562187  sats=7  spd=0.0km/h  hdop=1.20  alt=12.3m
[SYS] Uptime: 30s  Heap: 209800B  WiFi: MyNetwork (-58dBm)  GPS: LOCKED  Sats: 7
```

---

## Flutter App (TraceX)

### Tech Stack

- **Framework:** Flutter 3 / Dart 3
- **State:** Provider (ChangeNotifier)
- **Maps:** flutter_map 7 (OpenStreetMap / CARTO dark tiles)
- **Real-time:** socket_io_client
- **Storage:** flutter_secure_storage (JWT tokens), shared_preferences
- **Location:** geolocator (user position dot on map)
- **QR:** mobile_scanner v7 (camera + gallery image analysis)
- **Gallery pick:** image_picker

### Setup

```bash
cd flutter_app
flutter pub get
```

Edit [lib/constants.dart](flutter_app/lib/constants.dart):

```dart
const String kBaseUrl   = 'http://YOUR_SERVER_IP:4000/api/v1';
const String kSocketUrl = 'http://YOUR_SERVER_IP:4000';
```

Run:

```bash
flutter run
```

### App Screens

| Screen | File | Description |
|---|---|---|
| **Login** | [screens/auth/login_screen.dart](flutter_app/lib/screens/auth/login_screen.dart) | JWT sign-in with version badge |
| **Register** | [screens/auth/register_screen.dart](flutter_app/lib/screens/auth/register_screen.dart) | New account creation |
| **Home** | [screens/home/home_screen.dart](flutter_app/lib/screens/home/home_screen.dart) | Live map + device panel |
| **Add Device** | [screens/device/add_device_screen.dart](flutter_app/lib/screens/device/add_device_screen.dart) | QR scan or gallery upload |
| **Device Detail** | [screens/device/device_detail_screen.dart](flutter_app/lib/screens/device/device_detail_screen.dart) | Full-screen map + location history |

### Home Screen Features

**Map (always visible)**
- Dark CARTO tile layer — rendered even with no devices registered
- Transparent pill overlay: "No devices registered" or "Waiting for GPS fix…" — does not block map pan/zoom (`IgnorePointer`)
- Off-screen directional arrows — tap to pan to a device outside the viewport
- User location dot (blue pulsing) — requires location permission

**Device markers**
- Pin tip anchored exactly at GPS coordinate
- Pulsing ring animation (green = online, blue = offline)
- Label chip with device name — scales with zoom level
- Trailing dots (last 20 positions) fade with age
- Tap marker → device modal

**Bottom panel** (collapsible)
- Online / offline counter — updated every 5 s via client-side staleness check (devices last seen > 35 s ago are marked offline without waiting for a WebSocket event)
- Device rows show: name, ONLINE/OFFLINE badge, GPS coordinates, **last seen timestamp** (green when online, muted blue when offline)
- Follow toggle — map auto-pans to a followed device on each live update
- Add button → Add Device screen

**Device modal** (bottom sheet, tap marker or row)
- Rename device (inline text field + Save)
- Live online status dot + last-seen timestamp
- GPS coordinates, speed, satellites, altitude info box
- View History → Device Detail screen
- Delete button → confirmation dialog (warns that ESP32 will reset and re-pair)

### Add Device Screen

Two pairing methods:
1. **Camera scan** — real-time QR scanner via `mobile_scanner`
2. **Upload from Gallery** — pick a photo via `image_picker`, decoded with `MobileScannerController.analyzeImage(path)`

Both extract the API key from the QR, POST to `/tracker/devices`, and show the one-time key in a dialog with a copy button.

### App Flow

```
Login ──► Home Screen (live map + device list)
              │
              ├── + Add ──► Add Device ──► Scan QR (camera)
              │                       └──► Upload QR image (gallery)
              │
              ├── tap marker or row ──► Device Modal
              │                            ├── Rename
              │                            ├── View History ──► Device Detail
              │                            └── Delete (→ ESP32 resets immediately)
              │
              └── follow toggle ──► map auto-pans on each live location update
```

### Color Scheme — Ocean Blue

| Role | Color |
|---|---|
| Primary | `#3B82F6` (blue-500) |
| Deep navy | `#1E3A8A` (blue-900) |
| Background | `#080F1E` |
| Card surface | `#0D1730` |
| Online | `#22C55E` (green) |
| Gradient | navy → indigo → cyan |

---

## Quick Start (Full System)

```bash
# 1. Start MySQL and create database
mysql -u root -p < server/src/database/schema.sql

# 2. Start server
cd server && npm install && cp .env.example .env
# edit .env — DB credentials + JWT_SECRET
npm run dev

# 3. Register a user
curl -X POST http://localhost:4000/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"you@email.com","password":"yourpassword","name":"Your Name"}'

# 4. Flash ESP32
# Upload firmware via PlatformIO
# Connect phone to "GPS-Tracker-Setup" Wi-Fi
# Open 192.168.4.1 in browser → enter home Wi-Fi → Save & Connect

# 5. Open TraceX app → Add Device → scan the QR from the ESP32 portal

# 6. Device appears on map and starts streaming live GPS fixes every second
```

---

## Technologies Used

| Layer | Technology |
|---|---|
| Microcontroller | ESP32 DevKit V1 (Espressif, Xtensa LX6 dual-core) |
| GPS Module | u-blox NEO-6M (GPS6MV2) |
| Firmware Framework | PlatformIO + Arduino |
| GPS Library | TinyGPS++ |
| QR Generation | ricmoo/QRCode (on-device SVG + BMP) |
| JSON (firmware) | ArduinoJson |
| Backend Language | TypeScript 5 |
| Backend Framework | Express.js 4 |
| Real-time | Socket.IO 4 |
| Database | MySQL 8 |
| Auth | JWT + bcrypt |
| Mobile Framework | Flutter 3 |
| Mobile State | Provider |
| Mobile Maps | flutter_map (OpenStreetMap / CARTO) |
| Mobile Real-time | socket_io_client |
| QR Scanning | mobile_scanner v7 |
| Gallery Pick | image_picker |

---

## Version History

| Version | Highlights |
|---|---|
| v1.0.12 | Client-side offline counter (35 s staleness), always-show map with transparent overlay, last-seen on device row |
| v1.0.11 | Upload QR from gallery (image_picker + analyzeImage) |
| v1.0.10 | Device modal, dynamic zoom-scaled markers, off-screen arrows, user location dot |
| v1.0.9 | WebSocket room tracking fix, reconnect fix, pin centering, login version badge |

---

## License

MIT © 2026
