import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../models/device.dart';
import '../../models/location.dart';
import '../../services/tracker_service.dart';
import '../../services/socket_service.dart';
import '../../theme/app_theme.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String deviceId;
  const DeviceDetailScreen({super.key, required this.deviceId});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  final _mapController = MapController();
  List<DeviceLocation> _history = [];
  bool _loadingHistory = true;
  bool _followDevice   = true;

  @override
  void initState() {
    super.initState();
    context.read<SocketService>().joinDevice(widget.deviceId);
    _loadHistory();
  }

  @override
  void dispose() {
    context.read<SocketService>().leaveDevice(widget.deviceId);
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final h = await context.read<TrackerService>()
          .fetchHistory(widget.deviceId, limit: 200);
      if (mounted) setState(() { _history = h; _loadingHistory = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Device? _device(TrackerService t) =>
      t.devices.where((d) => d.id == widget.deviceId).firstOrNull;

  void _moveToDevice(DeviceLocation loc) {
    if (_followDevice) {
      _mapController.move(LatLng(loc.lat, loc.lng), 16);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TrackerService>(
      builder: (ctx, tracker, _) {
        final device = _device(tracker);
        final loc    = device?.latestLocation;

        // Move map when new location arrives
        if (loc != null) _moveToDevice(loc);

        return Scaffold(
          backgroundColor: AppColors.surface,
          appBar: AppBar(
            title: Text(device?.name ?? 'Device'),
            backgroundColor: AppColors.surfaceLight,
            actions: [
              // Follow toggle
              IconButton(
                icon: Icon(
                  _followDevice ? Icons.my_location : Icons.location_searching,
                  color: _followDevice ? AppColors.blue400 : AppColors.blue700,
                ),
                tooltip: _followDevice ? 'Following' : 'Not following',
                onPressed: () => setState(() => _followDevice = !_followDevice),
              ),
              // Refresh history
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadHistory,
              ),
            ],
          ),
          body: Column(
            children: [
              // ── Map ────────────────────────────────────────────────────
              Expanded(
                flex: 3,
                child: _buildMap(loc),
              ),

              // ── Info panel ─────────────────────────────────────────────
              _InfoPanel(device: device, location: loc)
                  .animate()
                  .slideY(begin: 0.15, duration: 300.ms),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMap(DeviceLocation? loc) {
    final center = loc != null
        ? LatLng(loc.lat, loc.lng)
        : const LatLng(10.7202, 122.5621); // default: Iloilo

    // Build polyline from history (oldest → newest)
    final polyPoints = _history.reversed
        .map((h) => LatLng(h.lat, h.lng))
        .toList();
    if (loc != null) polyPoints.add(LatLng(loc.lat, loc.lng));

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: 15,
        onTap: (_, __) => setState(() => _followDevice = false),
      ),
      children: [
        // Tile layer
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.gps.tracker',
        ),

        // Track polyline
        if (polyPoints.length > 1)
          PolylineLayer(
            polylines: [
              Polyline(
                points: polyPoints,
                color: AppColors.blue500.withAlpha(180),
                strokeWidth: 3,
              ),
            ],
          ),

        // History dots
        CircleLayer(
          circles: _history.take(50).map((h) => CircleMarker(
            point: LatLng(h.lat, h.lng),
            radius: 3,
            color: AppColors.blue700.withAlpha(120),
            borderColor: AppColors.blue500.withAlpha(60),
            borderStrokeWidth: 1,
          )).toList(),
        ),

        // Current position marker
        if (loc != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(loc.lat, loc.lng),
                width: 48,
                height: 48,
                child: _PulsingMarker(isOnline: _device(
                    context.read<TrackerService>())?.isOnline ?? false),
              ),
            ],
          ),
      ],
    );
  }
}

// ── Pulsing map marker ────────────────────────────────────────────────────────
class _PulsingMarker extends StatelessWidget {
  final bool isOnline;
  const _PulsingMarker({required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final color = isOnline ? AppColors.green : AppColors.blue500;
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withAlpha(40),
          ),
        ).animate(onPlay: (c) => c.repeat())
            .scale(begin: const Offset(0.8, 0.8),
                   end: const Offset(1.3, 1.3),
                   duration: 1200.ms)
            .fadeOut(begin: 0.6, duration: 1200.ms),
        Container(
          width: 18, height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [BoxShadow(color: color.withAlpha(120), blurRadius: 8)],
          ),
        ),
      ],
    );
  }
}

// ── Info panel ────────────────────────────────────────────────────────────────
class _InfoPanel extends StatelessWidget {
  final Device? device;
  final DeviceLocation? location;
  const _InfoPanel({this.device, this.location});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceLight,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0x28FFFFFF),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          if (location == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Waiting for GPS fix…',
                  style: TextStyle(color: AppColors.blue600)),
            )
          else
            Column(
              children: [
                // Coordinates
                _Row(icon: Icons.my_location,
                    label: 'Coordinates', value: location!.coordsLabel),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _Chip(
                      icon: Icons.speed,
                      label: 'Speed',
                      value: location!.speedLabel,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _Chip(
                      icon: Icons.satellite_alt,
                      label: 'Satellites',
                      value: '${location!.satellites ?? '--'}',
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _Chip(
                      icon: Icons.terrain,
                      label: 'Altitude',
                      value: location!.altitudeLabel,
                    )),
                  ],
                ),
                const SizedBox(height: 8),
                _Row(
                  icon: Icons.access_time,
                  label: 'Last update',
                  value: _fmt(location!.createdAt),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Row({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 16, color: AppColors.blue400),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(
              color: AppColors.blue400, fontSize: 12)),
          Expanded(child: Text(value, style: const TextStyle(
              color: Colors.white, fontSize: 12,
              fontWeight: FontWeight.w500))),
        ],
      );
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Chip({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x19FFFFFF)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 16, color: AppColors.blue400),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13)),
            Text(label, style: const TextStyle(
                color: AppColors.blue600, fontSize: 10)),
          ],
        ),
      );
}
