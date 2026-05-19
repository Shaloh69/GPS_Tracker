import 'package:flutter/foundation.dart';
import '../models/device.dart';
import '../models/location.dart';
import 'api_service.dart';

class TrackerService extends ChangeNotifier {
  final ApiService _api;

  List<Device> _devices = [];
  bool _loading = false;
  String? _error;

  TrackerService(this._api);

  List<Device> get devices  => _devices;
  bool         get loading  => _loading;
  String?      get error    => _error;

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

  Future<Map<String, dynamic>> createDevice(String name) async {
    final res = await _api.post('/tracker/devices', {'name': name});
    final device = Device.fromJson(res['data'] as Map<String, dynamic>);
    _devices.insert(0, device);
    notifyListeners();
    // Return full data including api_key (shown once)
    return res['data'] as Map<String, dynamic>;
  }

  Future<void> deleteDevice(String deviceId) async {
    await _api.delete('/tracker/devices/$deviceId');
    _devices.removeWhere((d) => d.id == deviceId);
    notifyListeners();
  }

  // Called by SocketService when a real-time update arrives
  void applyLiveLocation(String deviceId, DeviceLocation location) {
    final idx = _devices.indexWhere((d) => d.id == deviceId);
    if (idx == -1) return;
    _devices[idx] = _devices[idx].copyWith(
      isOnline: true,
      latestLocation: location,
      lastSeen: DateTime.now(),
    );
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
