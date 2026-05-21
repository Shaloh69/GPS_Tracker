import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../services/auth_service.dart';
import '../../services/socket_service.dart';
import '../../services/tracker_service.dart';
import '../../theme/app_theme.dart';
import '../device/add_device_screen.dart';
import '../device/device_detail_screen.dart';

String _timeAgo(DateTime? dt) {
  if (dt == null) return 'Never';
  final d = DateTime.now().difference(dt.toLocal());
  if (d.inSeconds < 5)  return 'just now';
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours   < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

// ── Home Screen ───────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  final Set<String> _followedDevices = {};
  bool _panelExpanded = false;

  double _zoom = 15.0;
  Position? _userPosition;
  StreamSubscription<Position>? _locSub;

  late final AnimationController _panAnim;
  LatLng? _panFrom, _panTo;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    _panAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    )..addListener(_onPanTick);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TrackerService>().addListener(_onTrackerUpdate);
      _load();
      _startReconnect();
      _startLocationTracking();
      // Update _zoom whenever the map moves/zooms
      try {
        _mapController.mapEventStream.listen((_) {
          if (mounted) {
            try {
              setState(() => _zoom = _mapController.camera.zoom);
            } catch (_) {}
          }
        });
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _panAnim.dispose();
    _reconnectTimer?.cancel();
    _locSub?.cancel();
    try { context.read<TrackerService>().removeListener(_onTrackerUpdate); }
    catch (_) {}
    super.dispose();
  }

  // ── Pan animation ─────────────────────────────────────────────────────────

  void _onPanTick() {
    if (_panFrom == null || _panTo == null) return;
    final t = CurvedAnimation(parent: _panAnim, curve: Curves.easeInOut).value;
    try {
      _mapController.move(
        LatLng(
          _panFrom!.latitude  + (_panTo!.latitude  - _panFrom!.latitude)  * t,
          _panFrom!.longitude + (_panTo!.longitude - _panFrom!.longitude) * t,
        ),
        _mapController.camera.zoom,
      );
    } catch (_) {}
  }

  void _animateTo(LatLng target) {
    try {
      _panFrom = _mapController.camera.center;
      _panTo   = target;
      _panAnim.forward(from: 0.0);
    } catch (_) {}
  }

  // ── Tracker listener ──────────────────────────────────────────────────────

  void _onTrackerUpdate() {
    if (!mounted) return;
    final tracker = context.read<TrackerService>();
    final lastId  = tracker.lastUpdatedDeviceId;
    if (lastId == null || !_followedDevices.contains(lastId)) return;
    final match = tracker.devices.where((d) => d.id == lastId).firstOrNull;
    final loc = match?.latestLocation;
    if (loc != null) _animateTo(LatLng(loc.lat, loc.lng));
  }

  // ── Reconnect ─────────────────────────────────────────────────────────────

  void _startReconnect() {
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final socket = context.read<SocketService>();
      final auth   = context.read<AuthService>();
      if (!socket.connected && auth.accessToken != null) {
        socket.connect(auth.accessToken!);
      }
      // Mark devices offline if last_seen > 35 s ago
      context.read<TrackerService>().refreshOnlineStatus();
    });
  }

  // ── User location ─────────────────────────────────────────────────────────

  Future<void> _startLocationTracking() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;

      _locSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((pos) {
        if (mounted) setState(() => _userPosition = pos);
      });
    } catch (_) {}
  }

  // ── Data load ─────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final tracker = context.read<TrackerService>();
    final auth    = context.read<AuthService>();
    final socket  = context.read<SocketService>();
    await tracker.fetchDevices();
    if (!mounted) return;
    socket.joinAll(tracker.devices.map((d) => d.id).toList());
    if (auth.accessToken != null) socket.connect(auth.accessToken!);
  }

  // ── Follow toggle ─────────────────────────────────────────────────────────

  void _toggleFollow(String deviceId) {
    setState(() {
      if (_followedDevices.contains(deviceId)) {
        _followedDevices.remove(deviceId);
      } else {
        _followedDevices..clear()..add(deviceId);
        final match = context.read<TrackerService>()
            .devices.where((d) => d.id == deviceId).firstOrNull;
        final loc = match?.latestLocation;
        if (loc != null) _animateTo(LatLng(loc.lat, loc.lng));
      }
    });
  }

  // ── Add device ────────────────────────────────────────────────────────────

  Future<void> _addDevice() async {
    final tracker = context.read<TrackerService>();
    final socket  = context.read<SocketService>();
    final added   = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
    );
    if (added == true && mounted) {
      await tracker.fetchDevices();
      socket.joinAll(tracker.devices.map((d) => d.id).toList());
    }
  }

  // ── Device modal ──────────────────────────────────────────────────────────

  void _showDeviceModal(Device device) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DeviceModal(
        device: device,
        onDelete: () => _confirmReset(device),
        onViewHistory: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DeviceDetailScreen(deviceId: device.id),
          ),
        ),
      ),
    );
  }

  // ── Reset / delete dialog ─────────────────────────────────────────────────

  Future<void> _confirmReset(Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.restart_alt, color: AppColors.red, size: 22),
            SizedBox(width: 8),
            Text('Remove Device',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remove "${device.name}"?',
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.red.withAlpha(60)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: AppColors.amber, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The ESP32 will reset its Wi-Fi credentials and QR '
                      'code — you will need to re-pair it from scratch.',
                      style: TextStyle(color: AppColors.amber, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset & Remove'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      try {
        await context.read<TrackerService>().deleteDevice(device.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  double get _markerScale => (_zoom / 15.0).clamp(0.35, 1.3);

  @override
  Widget build(BuildContext context) {
    final auth    = context.watch<AuthService>();
    final tracker = context.watch<TrackerService>();
    final socket  = context.watch<SocketService>();
    final located = tracker.devices
        .where((d) => d.latestLocation != null)
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF080F1E),
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              userName: auth.user?.displayName ?? '',
              isConnected: socket.connected,
              onLogout: () async {
                context.read<SocketService>().disconnect();
                await context.read<AuthService>().logout();
              },
            ),
            Expanded(
              child: Stack(
                children: [
                  // Map — always rendered; empty state is an overlay on top
                  if (tracker.loading)
                    const Center(child: CircularProgressIndicator(color: AppColors.blue500))
                  else
                    _LiveMap(
                      located: located,
                      tracker: tracker,
                      mapController: _mapController,
                      markerScale: _markerScale,
                      userPosition: _userPosition,
                      onMarkerTap: _showDeviceModal,
                    ),

                  // Transparent "no devices / no fix" overlay
                  if (!tracker.loading && located.isEmpty)
                    _EmptyOverlay(hasDevices: tracker.devices.isNotEmpty),

                  // Off-screen directional arrows
                  if (located.isNotEmpty)
                    _OffscreenArrows(
                      located: located,
                      mapController: _mapController,
                      onTap: (d) => _animateTo(
                          LatLng(d.latestLocation!.lat, d.latestLocation!.lng)),
                    ),

                  // Collapsible bottom panel
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _BottomPanel(
                      expanded: _panelExpanded,
                      devices: tracker.devices,
                      followedDevices: _followedDevices,
                      onToggleExpand: () =>
                          setState(() => _panelExpanded = !_panelExpanded),
                      onAdd: _addDevice,
                      onTap: _showDeviceModal,
                      onReset: _confirmReset,
                      onFollow: _toggleFollow,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Top bar ───────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String userName;
  final bool isConnected;
  final VoidCallback onLogout;
  const _TopBar({required this.userName, required this.isConnected, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF080F1E),
        border: Border(bottom: BorderSide(color: Colors.white.withAlpha(15))),
      ),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E3A8A), Color(0xFF3B82F6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: AppColors.blue500.withAlpha(80), blurRadius: 8)],
            ),
            child: const Icon(Icons.location_on_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('TraceX',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700,
                        fontSize: 16, letterSpacing: 0.3)),
                Text('Hello, $userName',
                    style: const TextStyle(color: AppColors.blue300, fontSize: 11)),
              ],
            ),
          ),
          Container(
            width: 8, height: 8,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isConnected ? AppColors.green : AppColors.red,
              boxShadow: [
                BoxShadow(
                  color: (isConnected ? AppColors.green : AppColors.red).withAlpha(120),
                  blurRadius: 6,
                ),
              ],
            ),
          ).animate(onPlay: (c) => c.repeat(reverse: true))
              .fade(begin: 1, end: 0.3, duration: 1200.ms),
          IconButton(
            icon: const Icon(Icons.logout_rounded, size: 20),
            color: AppColors.blue400,
            tooltip: 'Sign out',
            onPressed: onLogout,
          ),
        ],
      ),
    );
  }
}

// ── Empty state overlay (sits on top of the always-visible map) ───────────────

class _EmptyOverlay extends StatelessWidget {
  final bool hasDevices;
  const _EmptyOverlay({required this.hasDevices});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(150),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withAlpha(25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasDevices ? Icons.gps_not_fixed : Icons.devices_other_rounded,
                size: 20,
                color: AppColors.blue400,
              ),
              const SizedBox(width: 10),
              Text(
                hasDevices ? 'Waiting for GPS fix…' : 'No devices registered',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Live map ──────────────────────────────────────────────────────────────────

class _LiveMap extends StatelessWidget {
  final List<Device> located;
  final TrackerService tracker;
  final MapController mapController;
  final double markerScale;
  final Position? userPosition;
  final void Function(Device) onMarkerTap;

  const _LiveMap({
    required this.located,
    required this.tracker,
    required this.mapController,
    required this.markerScale,
    required this.userPosition,
    required this.onMarkerTap,
  });

  @override
  Widget build(BuildContext context) {
    final points = located
        .map((d) => LatLng(d.latestLocation!.lat, d.latestLocation!.lng))
        .toList();
    final isSingle = points.length == 1;

    // Marker sizes scale with zoom
    final iconSize    = (22 * markerScale).clamp(8.0, 34.0);
    final ringSize    = (38 * markerScale).clamp(14.0, 56.0);
    final labelFont   = (9  * markerScale).clamp(6.0,  13.0);
    final mHeight     = iconSize + (labelFont + 7) + ringSize * 0.3;
    final mWidth      = (100 * markerScale).clamp(40.0, 130.0);

    // Default view when no devices have a location yet
    final MapOptions mapOptions = points.isEmpty
        ? MapOptions(
            initialCenter: userPosition != null
                ? LatLng(userPosition!.latitude, userPosition!.longitude)
                : const LatLng(10.3157, 123.8854), // fallback
            initialZoom: userPosition != null ? 14 : 10,
          )
        : isSingle
            ? MapOptions(initialCenter: points.first, initialZoom: 15)
            : MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints(points),
                  padding: const EdgeInsets.fromLTRB(48, 48, 48, 120),
                ),
              );

    return FlutterMap(
      mapController: mapController,
      options: mapOptions,
      children: [
        TileLayer(
          urlTemplate:
              'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c', 'd'],
          tileProvider: CancellableNetworkTileProvider(),
          userAgentPackageName: 'com.tracex.app',
        ),

        // Trail dots
        CircleLayer(
          circles: located.expand((d) {
            final trail = tracker.getTrail(d.id);
            if (trail.length < 2) return <CircleMarker>[];
            final color = d.isOnline ? AppColors.green : AppColors.blue500;
            return trail.asMap().entries.map((e) {
              final progress = (e.key + 1) / trail.length;
              return CircleMarker(
                point: e.value,
                radius: (3 * progress * markerScale).clamp(1.0, 5.0),
                useRadiusInMeter: false,
                color: color.withAlpha((160 * progress).round()),
                borderStrokeWidth: 0,
              );
            });
          }).toList(),
        ),

        // User location dot
        if (userPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(userPosition!.latitude, userPosition!.longitude),
                width: 24,
                height: 24,
                alignment: Alignment.center,
                child: const _UserLocationDot(),
              ),
            ],
          ),

        // Device markers — pin tip at GPS coord, ring around pin head
        MarkerLayer(
          markers: located.asMap().entries.map((entry) {
            final i      = entry.key;
            final device = entry.value;
            final loc    = device.latestLocation!;
            final color  = device.isOnline ? AppColors.green : AppColors.blue500;

            return Marker(
              point: LatLng(loc.lat, loc.lng),
              width: mWidth,
              height: mHeight,
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () => onMarkerTap(device),
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    // Pulse ring — center at pin head (~icon/2 * 0.65 above tip)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: SizedBox(
                          width: ringSize,
                          height: ringSize,
                          child: _PulseRing(color: color, size: ringSize),
                        ),
                      ),
                    ),
                    // Label + pin — column bottom-aligned → tip = GPS coord
                    Column(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: (6 * markerScale).clamp(3, 10),
                              vertical:   (2 * markerScale).clamp(1,  4)),
                          decoration: BoxDecoration(
                            color: color.withAlpha(210),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [BoxShadow(color: color.withAlpha(90), blurRadius: 5)],
                          ),
                          child: Text(
                            device.name,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: labelFont,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(height: (3 * markerScale).clamp(1, 5)),
                        Icon(Icons.location_on_rounded, color: color, size: iconSize),
                      ],
                    )
                        .animate(delay: (i * 60).ms)
                        .scale(
                            begin: const Offset(0, 0),
                            duration: 400.ms,
                            curve: Curves.elasticOut),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Pulsing ring ──────────────────────────────────────────────────────────────

class _PulseRing extends StatefulWidget {
  final Color color;
  final double size;
  const _PulseRing({required this.color, required this.size});
  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _scale   = Tween<double>(begin: 0.15, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween<double>(begin: 0.85, end: 0.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Center(
        child: Container(
          width:  widget.size * _scale.value,
          height: widget.size * _scale.value,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.color.withValues(alpha: _opacity.value),
              width: 2,
            ),
          ),
        ),
      ),
    );
  }
}

// ── User location dot ─────────────────────────────────────────────────────────

class _UserLocationDot extends StatelessWidget {
  const _UserLocationDot();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 22, height: 22,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x333B82F6),
          ),
        ).animate(onPlay: (c) => c.repeat(reverse: true))
            .scale(begin: const Offset(0.7, 0.7), end: const Offset(1.5, 1.5),
                   duration: 1400.ms)
            .fade(begin: 0.6, end: 0.0, duration: 1400.ms),
        Container(
          width: 12, height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF3B82F6),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Color(0x803B82F6), blurRadius: 6)],
          ),
        ),
      ],
    );
  }
}

// ── Off-screen directional arrows ────────────────────────────────────────────

class _OffscreenArrows extends StatelessWidget {
  final List<Device> located;
  final MapController mapController;
  final void Function(Device) onTap;

  const _OffscreenArrows({
    required this.located,
    required this.mapController,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final cx = w / 2;
      // Account for bottom panel (~68 px)
      final cy = (h - 68) / 2;

      final arrows = <Widget>[];

      for (final device in located) {
        if (device.latestLocation == null) continue;
        try {
          final latLng = LatLng(device.latestLocation!.lat, device.latestLocation!.lng);

          // Visibility check via camera bounds
          final bounds = mapController.camera.visibleBounds;
          if (bounds.contains(latLng)) continue;

          // Project to pixel space to get accurate screen direction
          final dPx = mapController.camera.project(latLng);
          final cPx = mapController.camera.project(mapController.camera.center);
          final dx = (dPx.x - cPx.x).toDouble();
          final dy = (dPx.y - cPx.y).toDouble();
          if (dx == 0 && dy == 0) continue;

          const margin = 32.0;
          final halfW = cx - margin;
          final halfH = cy - margin;
          final sX = dx.abs() > 0.001 ? halfW / dx.abs() : double.infinity;
          final sY = dy.abs() > 0.001 ? halfH / dy.abs() : double.infinity;
          final s  = min(sX, sY);

          final ax = (cx + dx * s).clamp(margin, w - margin);
          final ay = (cy + dy * s).clamp(margin, h - 68 - margin);

          final angle = atan2(dy, dx);
          final color = device.isOnline ? AppColors.green : AppColors.blue400;

          arrows.add(
            Positioned(
              left: ax - 18,
              top:  ay - 18,
              child: GestureDetector(
                onTap: () => onTap(device),
                child: Transform.rotate(
                  angle: angle,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: color.withAlpha(200),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withAlpha(100), width: 1.5),
                      boxShadow: [BoxShadow(color: color.withAlpha(80), blurRadius: 8)],
                    ),
                    child: const Icon(Icons.arrow_forward_rounded,
                        color: Colors.white, size: 16),
                  ),
                ),
              ),
            ),
          );
        } catch (_) {
          // Camera not ready
        }
      }

      return Stack(children: arrows);
    });
  }
}

// ── Bottom collapsible panel ──────────────────────────────────────────────────

class _BottomPanel extends StatelessWidget {
  final bool expanded;
  final List<Device> devices;
  final Set<String> followedDevices;
  final VoidCallback onToggleExpand;
  final VoidCallback onAdd;
  final ValueChanged<Device> onTap;
  final ValueChanged<Device> onReset;
  final ValueChanged<String> onFollow;

  const _BottomPanel({
    required this.expanded,
    required this.devices,
    required this.followedDevices,
    required this.onToggleExpand,
    required this.onAdd,
    required this.onTap,
    required this.onReset,
    required this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    final online  = devices.where((d) => d.isOnline).length;
    final offline = devices.length - online;
    final maxExpandH = MediaQuery.of(context).size.height * 0.48;
    final listH = (devices.length * 72.0 + 16).clamp(0.0, maxExpandH - 68);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      height: expanded ? 68 + listH : 68,
      decoration: BoxDecoration(
        color: const Color(0xF2080F1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: Colors.white.withAlpha(25))),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(120), blurRadius: 20,
              offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        children: [
          // Header row
          GestureDetector(
            onTap: onToggleExpand,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              height: 68,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 36, height: 4,
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(50),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const Text('Devices',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                      ],
                    ),
                    const SizedBox(width: 14),
                    _StatChip(count: online,  label: 'online',  color: AppColors.green),
                    const SizedBox(width: 8),
                    _StatChip(count: offline, label: 'offline', color: AppColors.blue600),
                    const Spacer(),
                    GestureDetector(
                      onTap: onAdd,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)]),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(color: AppColors.blue500.withAlpha(80), blurRadius: 8)
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, color: Colors.white, size: 15),
                            SizedBox(width: 4),
                            Text('Add',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 300),
                      child: const Icon(Icons.keyboard_arrow_up_rounded,
                          color: AppColors.blue400, size: 22),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Device list
          if (expanded)
            Expanded(
              child: devices.isEmpty
                  ? Center(
                      child: Text('No devices registered',
                          style: TextStyle(
                              color: Colors.white.withAlpha(100), fontSize: 13)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      physics: const BouncingScrollPhysics(),
                      itemCount: devices.length,
                      itemBuilder: (_, i) => _DeviceRow(
                        device: devices[i],
                        index: i,
                        isFollowed: followedDevices.contains(devices[i].id),
                        onTap: () => onTap(devices[i]),
                        onReset: () => onReset(devices[i]),
                        onFollow: () => onFollow(devices[i].id),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final int count;
  final String label;
  final Color color;
  const _StatChip({required this.count, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [BoxShadow(color: color.withAlpha(120), blurRadius: 4)],
            ),
          ),
          const SizedBox(width: 5),
          Text('$count $label',
              style: TextStyle(color: color, fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Device row ────────────────────────────────────────────────────────────────

class _DeviceRow extends StatelessWidget {
  final Device device;
  final int index;
  final bool isFollowed;
  final VoidCallback onTap;
  final VoidCallback onReset;
  final VoidCallback onFollow;

  const _DeviceRow({
    required this.device,
    required this.index,
    required this.isFollowed,
    required this.onTap,
    required this.onReset,
    required this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    final loc      = device.latestLocation;
    final dotColor = device.isOnline ? AppColors.green : AppColors.blue700;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(7),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: device.isOnline
                    ? AppColors.green.withAlpha(50)
                    : Colors.white.withAlpha(12),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    boxShadow: [BoxShadow(color: dotColor.withAlpha(120), blurRadius: 5)],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(device.name,
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.w600,
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Text(
                            device.isOnline ? 'ONLINE' : 'OFFLINE',
                            style: TextStyle(
                                color: dotColor, fontSize: 9,
                                fontWeight: FontWeight.w700, letterSpacing: 0.5),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      if (loc != null)
                        Text(
                          '${loc.lat.toStringAsFixed(5)}, ${loc.lng.toStringAsFixed(5)}',
                          style: const TextStyle(color: AppColors.blue600, fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        'Last seen  ${_timeAgo(device.lastSeen)}',
                        style: TextStyle(
                            color: device.isOnline
                                ? AppColors.green.withAlpha(160)
                                : AppColors.blue700,
                            fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                // Follow toggle
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(
                    isFollowed
                        ? Icons.my_location_rounded
                        : Icons.location_searching_rounded,
                    size: 18,
                    color: isFollowed ? AppColors.blue400 : AppColors.blue700,
                  ),
                  onPressed: onFollow,
                ),
                // Delete / reset
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.restart_alt, size: 18, color: AppColors.red),
                  onPressed: onReset,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Device detail modal ───────────────────────────────────────────────────────

class _DeviceModal extends StatefulWidget {
  final Device device;
  final VoidCallback onDelete;
  final VoidCallback onViewHistory;
  const _DeviceModal({
    required this.device,
    required this.onDelete,
    required this.onViewHistory,
  });

  @override
  State<_DeviceModal> createState() => _DeviceModalState();
}

class _DeviceModalState extends State<_DeviceModal> {
  late final TextEditingController _nameCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.device.name);
  }

  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    if (name == widget.device.name) { Navigator.pop(context); return; }
    setState(() => _saving = true);
    try {
      await context.read<TrackerService>().renameDevice(widget.device.id, name);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch for real-time updates (online status etc.)
    final device = context.watch<TrackerService>()
            .devices.where((d) => d.id == widget.device.id).firstOrNull
        ?? widget.device;
    final loc = device.latestLocation;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D1730),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Colors.white.withAlpha(20))),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(40),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),

            // Status row
            Row(
              children: [
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: device.isOnline ? AppColors.green : AppColors.blue700,
                    boxShadow: [
                      BoxShadow(
                        color: (device.isOnline ? AppColors.green : AppColors.blue700)
                            .withAlpha(120),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  device.isOnline ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: device.isOnline ? AppColors.green : AppColors.blue500,
                    fontSize: 13, fontWeight: FontWeight.w600,
                  ),
                ),
                if (device.lastSeen != null) ...[
                  const Spacer(),
                  Text(_timeAgo(device.lastSeen),
                      style: const TextStyle(
                          color: AppColors.blue600, fontSize: 11)),
                ],
              ],
            ),
            const SizedBox(height: 16),

            // Name text field
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                labelText: 'Device Name',
                labelStyle: const TextStyle(color: AppColors.blue400),
                filled: true,
                fillColor: Colors.white.withAlpha(8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(20)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(20)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.blue500),
                ),
                prefixIcon: const Icon(Icons.edit_outlined,
                    color: AppColors.blue400, size: 18),
              ),
            ),
            const SizedBox(height: 12),

            // Location info box
            if (loc != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withAlpha(15)),
                ),
                child: Column(
                  children: [
                    _InfoRow(Icons.my_location,  'GPS',        loc.coordsLabel),
                    if (loc.speed     != null)
                      _InfoRow(Icons.speed,       'Speed',      loc.speedLabel),
                    if (loc.satellites != null)
                      _InfoRow(Icons.satellite_alt, 'Satellites', '${loc.satellites}'),
                    if (loc.altitude  != null)
                      _InfoRow(Icons.terrain,     'Altitude',   loc.altitudeLabel),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Action buttons
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_outlined, size: 16),
                    label: const Text('Save Name'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.blue600,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onViewHistory();
                    },
                    icon: const Icon(Icons.history, size: 16),
                    label: const Text('History'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.blue400,
                      side: const BorderSide(color: AppColors.blue700),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onDelete();
                  },
                  icon: const Icon(Icons.delete_outline),
                  color: AppColors.red,
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.red.withAlpha(20),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 13, color: AppColors.blue400),
            const SizedBox(width: 7),
            Text('$label: ',
                style: const TextStyle(color: AppColors.blue400, fontSize: 11)),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11,
                      fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      );
}
