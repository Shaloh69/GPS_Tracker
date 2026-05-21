import 'location.dart';

class Device {
  final String id;
  final String name;
  final bool isActive;
  final bool isOnline;
  final DateTime? lastSeen;
  final DeviceLocation? latestLocation;

  const Device({
    required this.id,
    required this.name,
    required this.isActive,
    required this.isOnline,
    this.lastSeen,
    this.latestLocation,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id:       j['id'] as String,
        name:     j['name'] as String,
        isActive: (j['is_active'] as int? ?? 1) == 1,
        isOnline: (j['is_online'] as int? ?? 0) == 1,
        lastSeen: j['last_seen'] != null
            ? DateTime.tryParse(j['last_seen'] as String)
            : null,
        latestLocation: j['lat'] != null
            ? DeviceLocation(
                id:           (j['loc_id'] as num?)?.toInt() ?? 0,
                deviceId:     j['id'] as String,
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
                createdAt: DateTime.tryParse(
                    ((j['location_at'] ?? j['created_at']) as String?) ?? '') ??
                    DateTime.now(),
              )
            : null,
      );

  Device copyWith({
    String? name,
    bool? isOnline,
    DeviceLocation? latestLocation,
    DateTime? lastSeen,
  }) =>
      Device(
        id:             id,
        name:           name ?? this.name,
        isActive:       isActive,
        isOnline:       isOnline ?? this.isOnline,
        lastSeen:       lastSeen ?? this.lastSeen,
        latestLocation: latestLocation ?? this.latestLocation,
      );
}
