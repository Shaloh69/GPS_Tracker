CREATE DATABASE IF NOT EXISTS gps_tracker;
USE gps_tracker;

-- ── Users ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id            VARCHAR(36)  PRIMARY KEY DEFAULT (UUID()),
  email         VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  name          VARCHAR(255),
  role          ENUM('user','admin') NOT NULL DEFAULT 'user',
  created_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- ── Refresh Tokens ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id         VARCHAR(36)  PRIMARY KEY DEFAULT (UUID()),
  user_id    VARCHAR(36)  NOT NULL,
  token      TEXT         NOT NULL,
  expires_at TIMESTAMP    NOT NULL,
  created_at TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- ── Devices (ESP32 trackers) ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS devices (
  id         VARCHAR(36)  PRIMARY KEY DEFAULT (UUID()),
  name       VARCHAR(255) NOT NULL,
  api_key    VARCHAR(64)  UNIQUE NOT NULL,
  owner_id   VARCHAR(36),
  is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
  is_online  BOOLEAN      NOT NULL DEFAULT FALSE,
  last_seen  TIMESTAMP    NULL,
  created_at TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE SET NULL,
  INDEX idx_api_key (api_key)
);

-- ── Locations ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS locations (
  id            BIGINT       AUTO_INCREMENT PRIMARY KEY,
  device_id     VARCHAR(36)  NOT NULL,
  lat           DOUBLE       NOT NULL,
  lng           DOUBLE       NOT NULL,
  speed         FLOAT,                    -- km/h
  course        FLOAT,                    -- degrees 0–360
  altitude      FLOAT,                    -- meters
  satellites    TINYINT UNSIGNED,
  hdop          FLOAT,                    -- horizontal dilution of precision
  gps_timestamp TIMESTAMP    NULL,        -- time reported by GPS chip
  created_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
  INDEX idx_device_time (device_id, created_at DESC)
);
