import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../../services/tracker_service.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/app_toast.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});
  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final MobileScannerController _scanner = MobileScannerController();
  final ImagePicker _picker = ImagePicker();
  bool _scanned      = false;
  bool _registering  = false;
  bool _analyzingImg = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  // ── Camera scan ───────────────────────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (_scanned || _registering) return;
    final raw = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue
        : null;
    if (raw == null) return;
    _handleRaw(raw);
  }

  // ── Gallery pick + analyze ────────────────────────────────────────────────

  Future<void> _pickFromGallery() async {
    if (_scanned || _registering || _analyzingImg) return;

    XFile? file;
    try {
      file = await _picker.pickImage(source: ImageSource.gallery);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open gallery', type: ToastType.error);
      }
      return;
    }
    if (file == null) return; // user cancelled

    setState(() => _analyzingImg = true);
    try {
      final capture = await _scanner.analyzeImage(file.path);
      if (!mounted) return;
      final raw = (capture?.barcodes.isNotEmpty ?? false)
          ? capture!.barcodes.first.rawValue
          : null;
      if (raw == null) {
        showToast(context, 'No QR code found in image', type: ToastType.error);
        return;
      }
      _handleRaw(raw);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Failed to read image', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _analyzingImg = false);
    }
  }

  // ── Shared logic ──────────────────────────────────────────────────────────

  void _handleRaw(String raw) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(raw)) {
      showToast(context, 'Not a valid TraceX QR code', type: ToastType.error);
      return;
    }
    setState(() => _scanned = true);
    _scanner.stop();
    _showNameDialog(raw);
  }

  Future<void> _showNameDialog(String scannedKey) async {
    final nameCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Name Your Device',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: AppColors.green, size: 18),
                const SizedBox(width: 8),
                Text(
                  'QR scanned successfully!',
                  style: TextStyle(
                      color: Colors.white.withAlpha(178), fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Device name',
                hintText: 'e.g. Bike Tracker',
                prefixIcon:
                    Icon(Icons.devices_other, color: AppColors.blue400),
              ),
              onSubmitted: (_) {
                if (nameCtrl.text.trim().isNotEmpty) Navigator.pop(ctx, true);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.blue400)),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Register'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _register(scannedKey, nameCtrl.text.trim());
    } else {
      if (mounted) setState(() => _scanned = false);
      _scanner.start();
    }
    nameCtrl.dispose();
  }

  Future<void> _register(String apiKey, String name) async {
    setState(() => _registering = true);
    try {
      await context
          .read<TrackerService>()
          .createDevice(name, apiKey: apiKey);
      if (mounted) {
        showToast(context, '$name registered!', type: ToastType.success);
        Navigator.pop(context, true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        showToast(context, e.message, type: ToastType.error);
        setState(() { _scanned = false; _registering = false; });
        _scanner.start();
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not reach server. Check your connection.',
            type: ToastType.error);
        setState(() { _scanned = false; _registering = false; });
        _scanner.start();
      }
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context, false),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                    const SizedBox(width: 4),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Device',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                        ),
                        Text(
                          'Scan the QR from your ESP32 portal',
                          style:
                              TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Camera view
              Expanded(
                child: Stack(
                  children: [
                    MobileScanner(
                      controller: _scanner,
                      onDetect: _onDetect,
                    ),
                    // Corner-bracket scan overlay
                    Center(
                      child: SizedBox(
                        width: 220,
                        height: 220,
                        child: CustomPaint(painter: _ScanOverlay()),
                      ),
                    ),
                    // Analyzing image overlay
                    if (_analyzingImg)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(color: AppColors.blue400),
                              SizedBox(height: 14),
                              Text('Reading QR from image…',
                                  style: TextStyle(color: Colors.white70)),
                            ],
                          ),
                        ),
                      ),
                    // Registering overlay
                    if (_registering)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: CircularProgressIndicator(
                              color: AppColors.blue400),
                        ),
                      ),
                  ],
                ),
              ),

              // Upload from gallery button
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: (_scanned || _registering || _analyzingImg)
                        ? null
                        : _pickFromGallery,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Upload QR from Gallery'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.blue300,
                      side: const BorderSide(color: AppColors.blue700),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ),

              // Instruction footer
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                child: Text(
                  'Connect to your ESP32 hotspot (GPS-Tracker-Setup),\n'
                  'open http://192.168.4.1, then scan or upload the QR shown there.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withAlpha(115), fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Corner-bracket overlay drawn over the camera feed
class _ScanOverlay extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double len = 28;
    final paint = Paint()
      ..color = AppColors.blue400
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;

    // Top-left
    canvas.drawLine(Offset(0, len), Offset.zero, paint);
    canvas.drawLine(Offset.zero, Offset(len, 0), paint);
    // Top-right
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);
    // Bottom-left
    canvas.drawLine(Offset(0, h - len), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);
    // Bottom-right
    canvas.drawLine(Offset(w - len, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h - len), Offset(w, h), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}
