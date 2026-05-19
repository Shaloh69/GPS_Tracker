class DeviceLocation {
  final int id;
  final String deviceId;
  final double lat;
  final double lng;
  final double? speed;
  final double? course;
  final double? altitude;
  final int? satellites;
  final double? hdop;
  final DateTime? gpsTimestamp;
  final DateTime createdAt;

  const DeviceLocation({
    required this.id,
    required this.deviceId,
    required this.lat,
    required this.lng,
    this.speed,
    this.course,
    this.altitude,
    this.satellites,
    this.hdop,
    this.gpsTimestamp,
    required this.createdAt,
  });

  factory DeviceLocation.fromJson(Map<String, dynamic> j) => DeviceLocation(
        id:           (j['id'] as num?)?.toInt() ?? 0,
        deviceId:     j['device_id'] as String? ?? '',
        lat:          (j['lat'] as num).toDouble(),
        lng:          (j['lng'] as num).toDouble(),
        speed:        (j['speed'] as num?)?.toDouble(),
        course:       (j['course'] as num?)?.toDouble(),
        altitude:     (j['altitude'] as num?)?.toDouble(),
        satellites:   (j['satellites'] as num?)?.toInt(),
        hdop:         (j['hdop'] as num?)?.toDouble(),
        gpsTimestamp: j['gps_timestamp'] != null
            ? DateTime.tryParse(j['gps_timestamp'] as String)
            : null,
        createdAt: DateTime.parse(
            (j['created_at'] ?? j['location_at']) as String),
      );

  String get speedLabel =>
      speed != null ? '${speed!.toStringAsFixed(1)} km/h' : '--';

  String get altitudeLabel =>
      altitude != null ? '${altitude!.toStringAsFixed(0)} m' : '--';

  String get coordsLabel =>
      '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
}
