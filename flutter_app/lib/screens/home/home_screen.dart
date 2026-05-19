import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../../models/device.dart';
import '../../services/auth_service.dart';
import '../../services/tracker_service.dart';
import '../../services/socket_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_background.dart';
import '../device/add_device_screen.dart';
import '../device/device_detail_screen.dart';

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
    await context.read<TrackerService>().fetchDevices();
    // Connect socket after devices loaded
    final auth   = context.read<AuthService>();
    final socket = context.read<SocketService>();
    if (!socket.connected && auth.accessToken != null) {
      socket.connect(auth.accessToken!);
    }
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
            onRefresh: tracker.fetchDevices,
            child: CustomScrollView(
              slivers: [
                // ── App bar ──────────────────────────────────────────────
                SliverAppBar(
                  backgroundColor: Colors.transparent,
                  floating: true,
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('GPS Tracker',
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
                              style: const TextStyle(color: AppColors.blue300)),
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
                          onDelete: () => _confirmDelete(tracker.devices[i]),
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
          if (added == true) tracker.fetchDevices();
        },
        backgroundColor: AppColors.blue500,
        icon: const Icon(Icons.add),
        label: const Text('Add Device'),
      ),
    );
  }

  Future<void> _confirmDelete(Device device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        title: const Text('Delete Device',
            style: TextStyle(color: Colors.white)),
        content: Text('Remove "${device.name}" and all its location history?',
            style: const TextStyle(color: AppColors.blue200)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.red)),
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
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
    }
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          _Stat(label: 'Total',  value: '${devices.length}',
              color: AppColors.blue400),
          const SizedBox(width: 12),
          _Stat(label: 'Online', value: '$online',
              color: AppColors.green),
          const SizedBox(width: 12),
          _Stat(label: 'Offline', value: '${devices.length - online}',
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
  const _Stat({required this.label, required this.value, required this.color});

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
  final VoidCallback onDelete;

  const _DeviceCard({
    required this.device,
    required this.index,
    required this.onTap,
    required this.onDelete,
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
              // Status indicator
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: (device.isOnline ? AppColors.green : AppColors.blue800)
                      .withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.location_on_rounded,
                  color: device.isOnline ? AppColors.green : AppColors.blue700,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(device.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 15)),
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
                    if (loc != null)
                      Text(loc.coordsLabel,
                          style: const TextStyle(
                              color: AppColors.blue300, fontSize: 12))
                    else
                      const Text('No location data yet',
                          style: TextStyle(
                              color: AppColors.blue700, fontSize: 12)),
                    if (loc != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${loc.speedLabel}  ·  ${loc.satellites ?? '--'} sats',
                        style: const TextStyle(
                            color: AppColors.blue600, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),

              // Actions
              Column(
                children: [
                  const Icon(Icons.chevron_right,
                      color: AppColors.blue600),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: onDelete,
                    child: const Icon(Icons.delete_outline,
                        color: AppColors.red, size: 18),
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
