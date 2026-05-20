import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../models/device.dart';
import '../../services/auth_service.dart';
import '../../services/tracker_service.dart';
import '../../services/socket_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_background.dart';
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final tracker = context.read<TrackerService>();
    final auth    = context.read<AuthService>();
    final socket  = context.read<SocketService>();

    await tracker.fetchDevices();
    if (!mounted) return;

    if (!socket.connected && auth.accessToken != null) {
      socket.connect(auth.accessToken!);
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
    }
    socket.joinAll(tracker.devices.map((d) => d.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final auth    = context.watch<AuthService>();
    final tracker = context.watch<TrackerService>();

    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: RefreshIndicator(
            color: AppColors.blue500,
            backgroundColor: AppColors.surfaceCard,
            onRefresh: () async {
              await tracker.fetchDevices();
              if (!mounted) return;
              context.read<SocketService>().joinAll(
                tracker.devices.map((d) => d.id).toList(),
              );
            },
            child: CustomScrollView(
              slivers: [
                // ── App bar ──────────────────────────────────────────────
                SliverAppBar(
                  backgroundColor: Colors.transparent,
                  floating: true,
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('TraceX',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 22)),
                      Text('Hello, ${auth.user?.displayName ?? ''}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.blue300)),
                    ],
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.logout_rounded),
                      tooltip: 'Sign out',
                      onPressed: () async {
                        context.read<SocketService>().disconnect();
                        await context.read<AuthService>().logout();
                      },
                    ),
                  ],
                ),

                // ── Live map ─────────────────────────────────────────────
                if (!tracker.loading)
                  SliverToBoxAdapter(
                    child: _LiveMapCard(
                      devices: tracker.devices,
                    ).animate().fadeIn(duration: 400.ms),
                  ),

                // ── Stats row ────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: _StatsRow(devices: tracker.devices)
                      .animate()
                      .fadeIn(duration: 400.ms)
                      .slideY(begin: 0.1),
                ),

                // ── Loading / error / list ────────────────────────────────
                if (tracker.loading)
                  const SliverFillRemaining(
                    child: Center(
                        child: CircularProgressIndicator(
                            color: AppColors.blue500)),
                  )
                else if (tracker.error != null)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off,
                              size: 48, color: AppColors.blue700),
                          const SizedBox(height: 12),
                          Text(tracker.error!,
                              style: const TextStyle(
                                  color: AppColors.blue300)),
                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: tracker.fetchDevices,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (tracker.devices.isEmpty)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.location_off_rounded,
                              size: 64, color: AppColors.blue800),
                          const SizedBox(height: 16),
                          const Text('No devices yet',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Text('Tap + to register your first ESP32',
                              style: TextStyle(
                                  color: Colors.white.withAlpha(128))),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) => _DeviceCard(
                          device: tracker.devices[i],
                          index: i,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DeviceDetailScreen(
                                  deviceId: tracker.devices[i].id),
                            ),
                          ),
                          onReset: () =>
                              _confirmReset(tracker.devices[i]),
                        ),
                        childCount: tracker.devices.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final added = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
          );
          if (added == true && mounted) {
            final tracker = context.read<TrackerService>();
            await tracker.fetchDevices();
            context.read<SocketService>().joinAll(
              tracker.devices.map((d) => d.id).toList(),
            );
          }
        },
        backgroundColor: AppColors.blue500,
        icon: const Icon(Icons.add),
        label: const Text('Add Device'),
      ),
    );
  }

  Future<void> _confirmReset(Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.restart_alt, color: AppColors.red, size: 22),
            const SizedBox(width: 8),
            const Text('Reset Device',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '"${device.name}" will be removed from your account.',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
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
                      'The ESP32 will also reset — it will forget its '
                      'Wi-Fi credentials and QR code, then reopen the '
                      'setup portal. You will need to re-pair it.',
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
            child: const Text('Cancel'),
          ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Reset failed: $e')),
          );
        }
      }
    }
  }
}

// ── Live Map Card ─────────────────────────────────────────────────────────────
class _LiveMapCard extends StatelessWidget {
  final List<Device> devices;
  const _LiveMapCard({required this.devices});

  @override
  Widget build(BuildContext context) {
    final located = devices
        .where((d) => d.latestLocation != null)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 260,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0x19FFFFFF)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: located.isEmpty
              ? _EmptyMapPlaceholder(hasDevices: devices.isNotEmpty)
              : _MapView(located: located),
        ),
      ),
    );
  }
}

class _EmptyMapPlaceholder extends StatelessWidget {
  final bool hasDevices;
  const _EmptyMapPlaceholder({required this.hasDevices});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0D1730),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined,
                size: 48, color: AppColors.blue800),
            const SizedBox(height: 12),
            Text(
              hasDevices
                  ? 'Waiting for GPS fix…'
                  : 'No devices registered',
              style: const TextStyle(
                  color: AppColors.blue600, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapView extends StatelessWidget {
  final List<Device> located;
  const _MapView({required this.located});

  @override
  Widget build(BuildContext context) {
    final points = located
        .map((d) => LatLng(
            d.latestLocation!.lat, d.latestLocation!.lng))
        .toList();

    final isSingle = points.length == 1;

    return FlutterMap(
      key: ValueKey(located.map((d) => d.id).join()),
      options: isSingle
          ? MapOptions(
              initialCenter: points.first,
              initialZoom: 15,
              interactionOptions:
                  const InteractionOptions(flags: InteractiveFlag.all),
            )
          : MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(points),
                padding: const EdgeInsets.all(48),
              ),
              interactionOptions:
                  const InteractionOptions(flags: InteractiveFlag.all),
            ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.tracex',
        ),
        MarkerLayer(
          markers: located.map((device) {
            final loc = device.latestLocation!;
            return Marker(
              point: LatLng(loc.lat, loc.lng),
              width: 130,
              height: 62,
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DeviceDetailScreen(deviceId: device.id),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: device.isOnline
                            ? AppColors.green
                            : AppColors.blue700,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: (device.isOnline
                                    ? AppColors.green
                                    : AppColors.blue700)
                                .withAlpha(100),
                            blurRadius: 6,
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
                    Icon(
                      Icons.location_on_rounded,
                      color: device.isOnline
                          ? AppColors.green
                          : AppColors.blue500,
                      size: 30,
                      shadows: [
                        Shadow(
                          color: (device.isOnline
                                  ? AppColors.green
                                  : AppColors.blue500)
                              .withAlpha(120),
                          blurRadius: 8,
                        ),
                      ],
                    ),
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

// ── Stats row ─────────────────────────────────────────────────────────────────
class _StatsRow extends StatelessWidget {
  final List<Device> devices;
  const _StatsRow({required this.devices});

  @override
  Widget build(BuildContext context) {
    final online = devices.where((d) => d.isOnline).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _Stat(
              label: 'Total',
              value: '${devices.length}',
              color: AppColors.blue400),
          const SizedBox(width: 12),
          _Stat(
              label: 'Online',
              value: '$online',
              color: AppColors.green),
          const SizedBox(width: 12),
          _Stat(
              label: 'Offline',
              value: '${devices.length - online}',
              color: AppColors.blue700),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x19FFFFFF)),
        ),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            Text(label,
                style: const TextStyle(
                    color: AppColors.blue300, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── Device card ───────────────────────────────────────────────────────────────
class _DeviceCard extends StatelessWidget {
  final Device device;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onReset;

  const _DeviceCard({
    required this.device,
    required this.index,
    required this.onTap,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final loc = device.latestLocation;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: device.isOnline
                  ? AppColors.green.withAlpha(80)
                  : const Color(0x19FFFFFF),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (device.isOnline
                          ? AppColors.green
                          : AppColors.blue800)
                      .withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.location_on_rounded,
                  color: device.isOnline
                      ? AppColors.green
                      : AppColors.blue700,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
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
                                  fontSize: 15),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: (device.isOnline
                                    ? AppColors.green
                                    : AppColors.blue800)
                                .withAlpha(30),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            device.isOnline ? 'ONLINE' : 'OFFLINE',
                            style: TextStyle(
                              color: device.isOnline
                                  ? AppColors.green
                                  : AppColors.blue600,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (loc != null) ...[
                      Text(loc.coordsLabel,
                          style: const TextStyle(
                              color: AppColors.blue300, fontSize: 12)),
                      const SizedBox(height: 2),
                      Text(
                        '${loc.speedLabel}  ·  ${loc.satellites ?? '--'} sats',
                        style: const TextStyle(
                            color: AppColors.blue600, fontSize: 11),
                      ),
                    ] else
                      const Text('No location data yet',
                          style: TextStyle(
                              color: AppColors.blue700, fontSize: 12)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.access_time_rounded,
                            size: 11, color: AppColors.blue600),
                        const SizedBox(width: 3),
                        Text(
                          'Last seen: ${_timeAgo(device.lastSeen)}',
                          style: const TextStyle(
                              color: AppColors.blue600, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.chevron_right,
                      color: AppColors.blue600),
                  const SizedBox(height: 8),
                  Tooltip(
                    message: 'Reset & Remove',
                    child: InkWell(
                      onTap: onReset,
                      borderRadius: BorderRadius.circular(8),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.restart_alt,
                            color: AppColors.red, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ).animate().fadeIn(delay: (index * 60).ms).slideY(begin: 0.05),
    );
  }
}
