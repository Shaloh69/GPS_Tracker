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
        id:       j['id']        as String,
        name:     j['name']      as String,
        isActive: (j['is_active'] as int? ?? 1) == 1,
        isOnline: (j['is_online'] as int? ?? 0) == 1,
        lastSeen: j['last_seen'] != null
            ? DateTime.tryParse(j['last_seen'] as String)
            : null,
        latestLocation: j['lat'] != null
            ? DeviceLocation.fromJson(j)
            : null,
      );

  Device copyWith({bool? isOnline, DeviceLocation? latestLocation}) => Device(
        id:              id,
        name:            name,
        isActive:        isActive,
        isOnline:        isOnline ?? this.isOnline,
        lastSeen:        lastSeen,
        latestLocation:  latestLocation ?? this.latestLocation,
      );
}
