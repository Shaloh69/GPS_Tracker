import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../constants.dart';
import '../models/location.dart';
import 'tracker_service.dart';

class SocketService extends ChangeNotifier {
  final TrackerService _tracker;

  io.Socket? _socket;
  bool _connected = false;

  SocketService(this._tracker);

  bool get connected => _connected;

  void connect(String accessToken) {
    if (_socket != null) return;

    _socket = io.io(
      kSocketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': accessToken})
          .disableAutoConnect()
          .build(),
    );

    _socket!
      ..onConnect((_) {
        _connected = true;
        notifyListeners();
        debugPrint('[WS] Connected');
      })
      ..onDisconnect((_) {
        _connected = false;
        notifyListeners();
        debugPrint('[WS] Disconnected');
      })
      ..onConnectError((e) => debugPrint('[WS] Error: $e'))
      ..on('location:update', _onLocationUpdate)
      ..on('device:status', _onDeviceStatus)
      ..connect();
  }

  // Join a single device room
  void joinDevice(String deviceId) {
    _socket?.emit('join:device', {'deviceId': deviceId});
    debugPrint('[WS] Joined device:$deviceId');
  }

  // Join all device rooms at once (home screen)
  void joinAll(List<String> deviceIds) {
    for (final id in deviceIds) {
      _socket?.emit('join:device', {'deviceId': id});
    }
    if (deviceIds.isNotEmpty) {
      debugPrint('[WS] Joined ${deviceIds.length} device rooms');
    }
  }

  void leaveDevice(String deviceId) {
    _socket?.emit('leave:device', {'deviceId': deviceId});
    debugPrint('[WS] Left device:$deviceId');
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _connected = false;
    notifyListeners();
  }

  void _onLocationUpdate(dynamic raw) {
    try {
      final data     = raw as Map<dynamic, dynamic>;
      final deviceId = data['deviceId'] as String;
      final locRaw   = Map<String, dynamic>.from(data['location'] as Map);
      final location = DeviceLocation.fromJson(locRaw);
      _tracker.applyLiveLocation(deviceId, location);
    } catch (e) {
      debugPrint('[WS] location:update parse error: $e');
    }
  }

  void _onDeviceStatus(dynamic raw) {
    try {
      final data     = raw as Map<dynamic, dynamic>;
      final deviceId = data['deviceId'] as String;
      final isOnline = data['isOnline'] as bool? ?? false;
      _tracker.markDeviceOnline(deviceId, isOnline);
    } catch (e) {
      debugPrint('[WS] device:status parse error: $e');
    }
  }
}
