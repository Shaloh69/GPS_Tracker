import { Request } from 'express';

export interface AuthRequest extends Request {
  user?: {
    id: string;
    email: string;
    role: 'user' | 'admin';
  };
  device?: {
    id: string;
    name: string;
  };
}

export interface JwtPayload {
  id: string;
  email: string;
  role: 'user' | 'admin';
  type: 'access' | 'refresh';
}

export interface LocationPayload {
  lat: number;
  lng: number;
  speed?: number;
  course?: number;
  altitude?: number;
  satellites?: number;
  hdop?: number;
  gps_timestamp?: string;
}

export interface DeviceRow {
  id: string;
  name: string;
  api_key: string;
  owner_id: string | null;
  is_active: boolean;
  is_online: boolean;
  last_seen: Date | null;
  created_at: Date;
}

export interface LocationRow {
  id: number;
  device_id: string;
  lat: number;
  lng: number;
  speed: number | null;
  course: number | null;
  altitude: number | null;
  satellites: number | null;
  hdop: number | null;
  gps_timestamp: Date | null;
  created_at: Date;
}

export interface DeviceLocationEvent {
  deviceId: string;
  deviceName: string;
  location: LocationRow;
}
