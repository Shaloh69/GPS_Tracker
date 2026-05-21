import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
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
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
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

  // Smooth-pan animation
  late final AnimationController _panAnim;
  LatLng? _panFrom, _panTo;

  // Silent reconnect
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
    });
  }

  @override
  void dispose() {
    _panAnim.dispose();
    _reconnectTimer?.cancel();
    try {
      context.read<TrackerService>().removeListener(_onTrackerUpdate);
    } catch (_) {}
    super.dispose();
  }

  // ── Map pan helpers ───────────────────────────────────────────────────────

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

  // ── Tracker update callback ───────────────────────────────────────────────

  void _onTrackerUpdate() {
    if (!mounted) return;
    final tracker = context.read<TrackerService>();
    final lastId  = tracker.lastUpdatedDeviceId;
    if (lastId == null || !_followedDevices.contains(lastId)) return;
    final matches = tracker.devices.where((d) => d.id == lastId);
    if (matches.isEmpty) return;
    final loc = matches.first.latestLocation;
    if (loc != null) _animateTo(LatLng(loc.lat, loc.lng));
  }

  // ── Reconnect timer ───────────────────────────────────────────────────────

  void _startReconnect() {
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final socket = context.read<SocketService>();
      final auth   = context.read<AuthService>();
      // SocketService.connect() handles reconnecting the socket;
      // rooms are rejoined automatically inside its onConnect callback.
      if (!socket.connected && auth.accessToken != null) {
        socket.connect(auth.accessToken!);
      }
    });
  }

  // ── Data load ─────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final tracker = context.read<TrackerService>();
    final auth    = context.read<AuthService>();
    final socket  = context.read<SocketService>();
    await tracker.fetchDevices();
    if (!mounted) return;
    // Register rooms BEFORE connecting — SocketService sends join:device events
    // inside onConnect, so there is no race against the handshake delay.
    socket.joinAll(tracker.devices.map((d) => d.id).toList());
    if (auth.accessToken != null) socket.connect(auth.accessToken!);
  }

  // ── Follow toggle ─────────────────────────────────────────────────────────

  void _toggleFollow(String deviceId) {
    setState(() {
      if (_followedDevices.contains(deviceId)) {
        _followedDevices.remove(deviceId);
      } else {
        _followedDevices
          ..clear()
          ..add(deviceId);
        // Immediately pan to this device
        final matches = context.read<TrackerService>()
            .devices.where((d) => d.id == deviceId);
        if (matches.isNotEmpty) {
          final loc = matches.first.latestLocation;
          if (loc != null) _animateTo(LatLng(loc.lat, loc.lng));
        }
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
      // joinAll adds new rooms; if connected, emits immediately
      socket.joinAll(tracker.devices.map((d) => d.id).toList());
    }
  }

  // ── Reset dialog ──────────────────────────────────────────────────────────

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
            Text('Reset Device',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"${device.name}" will be removed from your account.',
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.red.withAlpha(60)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: AppColors.amber, size: 16),
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
              .showSnackBar(SnackBar(content: Text('Reset failed: $e')));
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
            // ── Top bar ────────────────────────────────────────────────────
            _TopBar(
              userName: auth.user?.displayName ?? '',
              isConnected: socket.connected,
              onLogout: () async {
                context.read<SocketService>().disconnect();
                await context.read<AuthService>().logout();
              },
            ),

            // ── Map + overlay ──────────────────────────────────────────────
            Expanded(
              child: Stack(
                children: [
                  // Map (full remaining area)
                  if (tracker.loading)
                    const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.blue500))
                  else if (located.isEmpty)
                    _EmptyMap(hasDevices: tracker.devices.isNotEmpty)
                  else
                    _LiveMap(
                      located: located,
                      tracker: tracker,
                      mapController: _mapController,
                    ),

                  // Bottom collapsible panel
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
                      onTap: (d) => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              DeviceDetailScreen(deviceId: d.id),
                        ),
                      ),
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

  const _TopBar({
    required this.userName,
    required this.isConnected,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF080F1E),
        border: Border(
          bottom: BorderSide(color: Colors.white.withAlpha(15)),
        ),
      ),
      child: Row(
        children: [
          // Logo dot
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E3A8A), Color(0xFF3B82F6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: AppColors.blue500.withAlpha(80),
                  blurRadius: 8,
                ),
              ],
            ),
            child: const Icon(Icons.location_on_rounded,
                color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('TraceX',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        letterSpacing: 0.3)),
                Text('Hello, $userName',
                    style: const TextStyle(
                        color: AppColors.blue300,
                        fontSize: 11)),
              ],
            ),
          ),
          // Connection status dot
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isConnected ? AppColors.green : AppColors.red,
              boxShadow: [
                BoxShadow(
                  color: (isConnected ? AppColors.green : AppColors.red)
                      .withAlpha(120),
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

// ── Empty map placeholder ─────────────────────────────────────────────────────

class _EmptyMap extends StatelessWidget {
  final bool hasDevices;
  const _EmptyMap({required this.hasDevices});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0B1426),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined,
                size: 56, color: AppColors.blue800),
            const SizedBox(height: 14),
            Text(
              hasDevices ? 'Waiting for GPS fix…' : 'No devices registered',
              style: const TextStyle(color: AppColors.blue600, fontSize: 15),
            ),
          ],
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

  const _LiveMap({
    required this.located,
    required this.tracker,
    required this.mapController,
  });

  @override
  Widget build(BuildContext context) {
    final points = located
        .map((d) => LatLng(d.latestLocation!.lat, d.latestLocation!.lng))
        .toList();

    final isSingle = points.length == 1;

    return FlutterMap(
      mapController: mapController,
      options: isSingle
          ? MapOptions(initialCenter: points.first, initialZoom: 15)
          : MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(points),
                padding: const EdgeInsets.fromLTRB(48, 48, 48, 120),
              ),
            ),
      children: [
        // Dark map tiles (CARTO Dark Matter)
        TileLayer(
          urlTemplate:
              'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c', 'd'],
          tileProvider: CancellableNetworkTileProvider(),
          userAgentPackageName: 'com.tracex.app',
        ),

        // Trail dots — fading circles showing last GPS positions
        CircleLayer(
          circles: located.expand((d) {
            final trail = tracker.getTrail(d.id);
            if (trail.length < 2) return <CircleMarker>[];
            final color =
                d.isOnline ? AppColors.green : AppColors.blue500;
            return trail.asMap().entries.map((e) {
              final progress = (e.key + 1) / trail.length;
              return CircleMarker(
                point: e.value,
                radius: 3.5 * progress,
                useRadiusInMeter: false,
                color: color.withAlpha((180 * progress).round()),
                borderStrokeWidth: 0,
              );
            });
          }).toList(),
        ),

        // Combined pin + pulse ring markers.
        // Marker aligned bottomCenter → bottom of widget = GPS coordinate.
        // Stack layout (bottom = GPS coord):
        //   • _PulseRing in SizedBox(44,44) with bottom:0 → ring center is
        //     22 px above GPS coord, which is exactly the pin-head centre.
        //   • Column(mainAxisAlignment.end) → icon tip at GPS coord.
        MarkerLayer(
          markers: located.asMap().entries.map((entry) {
            final i      = entry.key;
            final device = entry.value;
            final loc    = device.latestLocation!;
            final pinColor =
                device.isOnline ? AppColors.green : AppColors.blue500;

            return Marker(
              point: LatLng(loc.lat, loc.lng),
              width: 120,
              // label(22) + gap(4) + icon(32) = 58, +14 breathing room = 72
              height: 72,
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DeviceDetailScreen(deviceId: device.id),
                  ),
                ),
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    // Pulse ring: bottom edge at GPS coord → center at pin head
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: _PulseRing(color: pinColor),
                        ),
                      ),
                    ),
                    // Label + pin — content pinned to bottom, tip at GPS coord
                    Column(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: pinColor.withAlpha(220),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: pinColor.withAlpha(100),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            device.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Icon(Icons.location_on_rounded,
                            color: pinColor, size: 32),
                      ],
                    )
                        .animate(delay: (i * 80).ms)
                        .scale(
                            begin: const Offset(0, 0),
                            duration: 420.ms,
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

// Pulsing ring widget — stateful so it can repeat its animation independently
class _PulseRing extends StatefulWidget {
  final Color color;
  const _PulseRing({required this.color});
  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _scale   = Tween<double>(begin: 0.2, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween<double>(begin: 0.9, end: 0.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 44 * _scale.value,
        height: 44 * _scale.value,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: widget.color.withValues(alpha: _opacity.value),
            width: 2,
          ),
        ),
      ),
    );
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
    final maxExpandHeight = MediaQuery.of(context).size.height * 0.48;
    final listHeight      = (devices.length * 72.0 + 16).clamp(0.0, maxExpandHeight - 68);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      height: expanded ? 68 + listHeight : 68,
      decoration: BoxDecoration(
        color: const Color(0xF2080F1E),  // ~94% opaque
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: Colors.white.withAlpha(25)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(120),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Panel header (always visible) ──────────────────────────────
          GestureDetector(
            onTap: onToggleExpand,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              height: 68,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    // Drag handle + label
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
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

                    // Online chip
                    _StatChip(
                        count: online,
                        label: 'online',
                        color: AppColors.green),
                    const SizedBox(width: 8),
                    _StatChip(
                        count: offline,
                        label: 'offline',
                        color: AppColors.blue600),

                    const Spacer(),

                    // Add device button
                    GestureDetector(
                      onTap: onAdd,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.blue500.withAlpha(80),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, color: Colors.white, size: 15),
                            SizedBox(width: 4),
                            Text('Add',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Expand chevron
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

          // ── Expanded device list ───────────────────────────────────────
          if (expanded)
            Expanded(
              child: devices.isEmpty
                  ? Center(
                      child: Text(
                        'No devices registered',
                        style: TextStyle(
                            color: Colors.white.withAlpha(100),
                            fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      physics: const BouncingScrollPhysics(),
                      itemCount: devices.length,
                      itemBuilder: (ctx, i) => _DeviceRow(
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
  const _StatChip(
      {required this.count, required this.label, required this.color});

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
            width: 6,
            height: 6,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: color.withAlpha(120), blurRadius: 4)
                ]),
          ),
          const SizedBox(width: 5),
          Text('$count $label',
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Device row (inside expanded panel) ───────────────────────────────────────

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
                // Status dot
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    boxShadow: [
                      BoxShadow(
                          color: dotColor.withAlpha(120), blurRadius: 5)
                    ],
                  ),
                ),
                // Device info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(device.name,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Text(
                            device.isOnline ? 'ONLINE' : 'OFFLINE',
                            style: TextStyle(
                                color: dotColor,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5),
                          ),
                        ],
                      ),
                      if (loc != null)
                        Text(
                          '${loc.coordsLabel}  ·  ${_timeAgo(device.lastSeen)}',
                          style: const TextStyle(
                              color: AppColors.blue400,
                              fontSize: 10),
                        )
                      else
                        const Text('No location yet',
                            style: TextStyle(
                                color: AppColors.blue700, fontSize: 10)),
                    ],
                  ),
                ),
                // Follow toggle
                Tooltip(
                  message: isFollowed ? 'Stop following' : 'Follow on map',
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: Icon(
                      isFollowed
                          ? Icons.my_location_rounded
                          : Icons.location_searching_rounded,
                      size: 18,
                      color: isFollowed
                          ? AppColors.blue400
                          : AppColors.blue700,
                    ),
                    onPressed: onFollow,
                  ),
                ),
                // Reset
                Tooltip(
                  message: 'Reset & Remove',
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: const Icon(Icons.restart_alt,
                        color: AppColors.red, size: 18),
                    onPressed: onReset,
                  ),
                ),
              ],
            ),
          ),
        ),
      )
          .animate(delay: (index * 50).ms)
          .fadeIn(duration: 200.ms)
          .slideY(begin: 0.06, duration: 200.ms),
    );
  }
}
