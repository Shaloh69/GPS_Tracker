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
      ..connect();
  }

  void joinDevice(String deviceId) {
    _socket?.emit('join:device', deviceId);
    debugPrint('[WS] Joined device:$deviceId');
  }

  void leaveDevice(String deviceId) {
    _socket?.emit('leave:device', deviceId);
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
      final data = raw as Map<dynamic, dynamic>;
      final deviceId = data['deviceId'] as String;
      final locRaw   = Map<String, dynamic>.from(data['location'] as Map);
      final location = DeviceLocation.fromJson(locRaw);
      _tracker.applyLiveLocation(deviceId, location);
    } catch (e) {
      debugPrint('[WS] location:update parse error: $e');
    }
  }
}
