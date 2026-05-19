# GPS Tracker

A full-stack real-time GPS tracking system built with **ESP32**, **Node.js/TypeScript**, and **Flutter**.

---

## System Overview

```
┌─────────────────┐        HTTP POST        ┌────────────────────┐
│   ESP32 DevKit  │ ──── X-Api-Key ───────► │  Node.js Server    │
│  + GPS6MV2      │   /api/v1/tracker/      │  Express + MySQL   │
│  (10 Hz, 115200)│      location           │  Socket.IO         │
└─────────────────┘                         └────────────────────┘
                                                      │
                                               Socket.IO event
                                             location:update
                                                      │
                                                      ▼
                                            ┌─────────────────────┐
                                            │   Flutter App       │
                                            │  Real-time Map View │
                                            │  Device Dashboard   │
                                            └─────────────────────┘
```

---

## Repository Structure

```
GPS_Tracker/
├── server/          Node.js + TypeScript backend
├── esp32/           PlatformIO firmware for ESP32
└── flutter_app/     Flutter mobile dashboard
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
  ┌───────────────┐           ┌──────────────────────┐
  │  VCC ─────────┼───────────┼─ 3.3V (or VUSB 5V)  │
  │  GND ─────────┼───────────┼─ GND                 │
  │  TXD ─────────┼───────────┼─ D21 / GPIO21  (RX)  │
  │  RXD ─────────┼───────────┼─ D22 / GPIO22  (TX)  │
  │               │           │                      │
  │  [GPS Antenna]│           │   [Wi-Fi Antenna]    │
  └───────────────┘           └──────────────────────┘
```

| GPS6MV2 Pin | ESP32 Pin | Notes |
|---|---|---|
| VCC | 3.3V or VUSB | Module has onboard LDO — either voltage works |
| GND | GND | Common ground |
| TXD | D21 (GPIO21) | GPS sends NMEA → ESP32 receives (UART RX) |
| RXD | D22 (GPIO22) | ESP32 sends config → GPS (UART TX) |

### GPS Configuration
The firmware automatically configures the NEO-6M on boot:
1. Switches UART to **115200 baud** (UBX-CFG-PRT)
2. Sets measurement rate to **10 Hz / 100 ms** (UBX-CFG-RATE)
3. Saves config to flash (UBX-CFG-CFG) — survives power cycles

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
| GET | `/api/v1/tracker/devices/:id` | JWT | Device details + latest location |
| DELETE | `/api/v1/tracker/devices/:id` | JWT | Remove device |

#### Location
| Method | Endpoint | Auth | Description |
|---|---|---|---|
| **POST** | `/api/v1/tracker/location` | `X-Api-Key` | **ESP32 pushes GPS fix** |
| GET | `/api/v1/tracker/locations/:id` | JWT | Location history (`?limit=100&from=&to=`) |
| GET | `/api/v1/tracker/locations/:id/latest` | JWT | Latest GPS fix |

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
users        — id, email, password_hash, name, role
refresh_tokens — id, user_id, token, expires_at
devices      — id, name, api_key, owner_id, is_active, is_online, last_seen
locations    — id, device_id, lat, lng, speed, course, altitude,
               satellites, hdop, gps_timestamp, created_at
```

---

## ESP32 Firmware

### Setup (PlatformIO)

1. Install [PlatformIO IDE](https://platformio.org/) (VS Code extension)
2. Open `esp32/` folder in VS Code
3. Edit `src/main.cpp` — fill in your credentials:

```cpp
#define WIFI_SSID       "YOUR_WIFI_SSID"
#define WIFI_PASSWORD   "YOUR_WIFI_PASSWORD"
#define SERVER_URL      "http://YOUR_SERVER_IP:4000/api/v1/tracker/location"
#define DEVICE_API_KEY  "..."   // from POST /api/v1/tracker/devices
```

4. Build & Upload: `PlatformIO: Upload` (Ctrl+Alt+U)
5. Monitor: `PlatformIO: Monitor` (Ctrl+Alt+S) at 115200 baud

### Libraries (`platformio.ini`)

```ini
lib_deps =
    mikalhart/TinyGPSPlus @ ^1.0.3
    bblanchon/ArduinoJson @ ^7.0.0
```

### Firmware Behavior

1. Boot → configures GPS to 10 Hz / 115200 baud (saved to flash)
2. Connect to Wi-Fi (auto-reconnect on drop)
3. Wait for satellite lock (LED blinks while acquiring)
4. Every **1 second** (`POST_INTERVAL_MS`): POST latest GPS fix to server
5. Server broadcasts fix to all subscribed Flutter clients via Socket.IO
6. LED solid ON = connected + posting; LED off = post failed

### Serial Monitor Output

```
=== GPS Tracker Firmware ===
[GPS] Switching baud to 115200…
[GPS] Setting 10 Hz rate…
[WiFi] Connecting to MyNetwork....
[WiFi] Connected — IP: 192.168.1.50
[GPS] First fix! Sats=7
[POST] OK  lat=10.720234 lng=122.562187 sats=7 spd=0.0 km/h
```

---

## Flutter App

### Tech Stack
- **Framework:** Flutter 3 / Dart 3
- **State:** Provider (ChangeNotifier)
- **Maps:** flutter_map (OpenStreetMap)
- **Real-time:** socket_io_client
- **Storage:** flutter_secure_storage (tokens), shared_preferences

### Setup

```bash
cd flutter_app
flutter pub get
```

Edit `lib/constants.dart`:

```dart
const String kBaseUrl   = 'http://YOUR_SERVER_IP:4000/api/v1';
const String kSocketUrl = 'http://YOUR_SERVER_IP:4000';
```

Run:
```bash
flutter run
```

### App Screens

| Screen | Description |
|---|---|
| **Login / Register** | JWT auth with token persistence |
| **Home (Device List)** | All devices, online/offline status, latest coords, stats |
| **Add Device** | Register ESP32 → one-time API key display with copy |
| **Device Detail** | Live map, pulsing marker, track polyline, info panel |

### App Flow

```
Login ──► Home Screen (device list)
              │
              ├── + FAB ──► Add Device ──► shows api_key (copy to firmware)
              │
              └── tap card ──► Device Detail
                                   │
                                   ├── Flutter Map (OpenStreetMap)
                                   ├── Pulsing live marker (green=online)
                                   ├── Track polyline (last 200 points)
                                   └── Info panel: coords / speed / sats / altitude
```

### Color Scheme — Ocean Blue

| Role | Color |
|---|---|
| Primary | `#3B82F6` (blue-500) |
| Deep navy | `#1E3A8A` (blue-900) |
| Gradient | navy → indigo → cyan |
| Background | `#080F1E` |
| Card | `#0D1730` |

---

## Quick Start (Full System)

```bash
# 1. Start MySQL and create database
mysql -u root -p < server/src/database/schema.sql

# 2. Start server
cd server && npm install && cp .env.example .env
# edit .env with your DB credentials
npm run dev

# 3. Register a user (curl or Postman)
curl -X POST http://localhost:4000/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"you@email.com","password":"yourpassword"}'

# 4. Register a device → copy the api_key
curl -X POST http://localhost:4000/api/v1/tracker/devices \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"Tracker-01"}'

# 5. Flash ESP32 with api_key, SSID, password, server IP

# 6. Run Flutter app
cd flutter_app && flutter run
```

---

## Technologies Used

| Layer | Technology |
|---|---|
| Microcontroller | ESP32 (Espressif, Xtensa LX6 dual-core) |
| GPS Module | u-blox NEO-6M (GPS6MV2) |
| Firmware Framework | PlatformIO + Arduino |
| GPS Library | TinyGPS++ |
| JSON (firmware) | ArduinoJson |
| Backend Language | TypeScript 5 |
| Backend Framework | Express.js 4 |
| Real-time | Socket.IO 4 |
| Database | MySQL 8 |
| Auth | JWT + bcrypt |
| Mobile Framework | Flutter 3 |
| Mobile State | Provider |
| Mobile Maps | flutter_map (OpenStreetMap) |
| Mobile Real-time | socket_io_client |

---

## License

MIT © 2026
