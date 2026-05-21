import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../constants.dart';
import '../models/location.dart';
import 'tracker_service.dart';

class SocketService extends ChangeNotifier {
  final TrackerService _tracker;

  io.Socket? _socket;
  bool _connected = false;

  // All device rooms registered so far — rejoined automatically on every connect
  final Set<String> _rooms = {};

  SocketService(this._tracker);

  bool get connected => _connected;

  void connect(String accessToken) {
    if (_socket != null) {
      // Socket already created — if it dropped, tell it to reconnect
      if (!_connected) _socket!.connect();
      return;
    }

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
        debugPrint('[WS] Connected — rejoining ${_rooms.length} rooms');
        // Rejoin all rooms on EVERY connect (initial connect AND reconnect)
        for (final id in _rooms) {
          _socket?.emit('join:device', id);
        }
      })
      ..onDisconnect((_) {
        _connected = false;
        notifyListeners();
        debugPrint('[WS] Disconnected');
      })
      ..onConnectError((e) => debugPrint('[WS] Connect error: $e'))
      ..on('location:update', _onLocationUpdate)
      ..on('device:status', _onDeviceStatus)
      ..connect();
  }

  // Track the room; emit immediately if already connected, or wait for onConnect
  void joinDevice(String deviceId) {
    _rooms.add(deviceId);
    if (_connected) {
      _socket?.emit('join:device', deviceId);
      debugPrint('[WS] Joined device:$deviceId');
    }
  }

  void joinAll(List<String> deviceIds) {
    for (final id in deviceIds) {
      _rooms.add(id);
      if (_connected) _socket?.emit('join:device', id);
    }
    debugPrint('[WS] joinAll — ${deviceIds.length} ids, connected: $_connected');
  }

  void leaveDevice(String deviceId) {
    _rooms.remove(deviceId);
    _socket?.emit('leave:device', deviceId);
    debugPrint('[WS] Left device:$deviceId');
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _connected = false;
    _rooms.clear();
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
      final isOnline = data['isOnline'] == true;
      _tracker.markDeviceOnline(deviceId, isOnline);
    } catch (e) {
      debugPrint('[WS] device:status parse error: $e');
    }
  }
}
