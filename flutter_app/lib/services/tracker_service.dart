import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import '../models/device.dart';
import '../models/location.dart';
import 'api_service.dart';

class TrackerService extends ChangeNotifier {
  final ApiService _api;

  List<Device> _devices = [];
  bool _loading = false;
  String? _error;

  /// Trailing positions per device — last 20 GPS fixes kept for trail rendering.
  final Map<String, List<LatLng>> _trails = {};

  /// Id of the device whose location was most recently updated via WebSocket.
  String? _lastUpdatedDeviceId;

  TrackerService(this._api);

  List<Device> get devices              => _devices;
  bool         get loading              => _loading;
  String?      get error                => _error;
  String?      get lastUpdatedDeviceId  => _lastUpdatedDeviceId;

  List<LatLng> getTrail(String deviceId) => _trails[deviceId] ?? const [];

  // ── Devices ───────────────────────────────────────────────────────────────
  Future<void> fetchDevices() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await _api.get('/tracker/devices');
      _devices = (res['data'] as List)
          .map((j) => Device.fromJson(j as Map<String, dynamic>))
          .toList();
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Could not reach server';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> createDevice(String name, {String? apiKey}) async {
    final body = <String, dynamic>{'name': name};
    if (apiKey != null) body['api_key'] = apiKey;
    final res = await _api.post('/tracker/devices', body);
    final device = Device.fromJson(res['data'] as Map<String, dynamic>);
    _devices.insert(0, device);
    notifyListeners();
    return res['data'] as Map<String, dynamic>;
  }

  Future<void> deleteDevice(String deviceId) async {
    await _api.delete('/tracker/devices/$deviceId');
    _devices.removeWhere((d) => d.id == deviceId);
    notifyListeners();
  }

  // Called by SocketService when a real-time location update arrives
  void applyLiveLocation(String deviceId, DeviceLocation location) {
    final idx = _devices.indexWhere((d) => d.id == deviceId);
    if (idx == -1) return;
    _devices[idx] = _devices[idx].copyWith(
      isOnline: true,
      latestLocation: location,
      lastSeen: DateTime.now(),
    );
    // Append to trail (keep last 20 positions)
    final trail = _trails.putIfAbsent(deviceId, () => []);
    trail.add(LatLng(location.lat, location.lng));
    if (trail.length > 20) trail.removeAt(0);
    _lastUpdatedDeviceId = deviceId;
    notifyListeners();
  }

  void markDeviceOnline(String deviceId, bool online) {
    final idx = _devices.indexWhere((d) => d.id == deviceId);
    if (idx == -1) return;
    _devices[idx] = _devices[idx].copyWith(isOnline: online);
    notifyListeners();
  }

  // ── Location history ──────────────────────────────────────────────────────
  Future<List<DeviceLocation>> fetchHistory(
    String deviceId, {
    int limit = 200,
  }) async {
    final res = await _api.get(
      '/tracker/locations/$deviceId?limit=$limit',
    );
    return (res['data'] as List)
        .map((j) => DeviceLocation.fromJson(j as Map<String, dynamic>))
        .toList();
  }
}
