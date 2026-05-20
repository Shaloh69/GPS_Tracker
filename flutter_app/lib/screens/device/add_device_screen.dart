import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../services/tracker_service.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/app_toast.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});
  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _form    = GlobalKey<FormState>();
  final _name    = TextEditingController();
  bool _loading  = false;
  String? _apiKey;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final data = await context.read<TrackerService>()
          .createDevice(_name.text.trim());
      setState(() {
        _apiKey = data['api_key'] as String;
      });
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, type: ToastType.error);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not reach server. Check your connection.',
            type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context, _apiKey != null),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const SizedBox(height: 8),
                const Text('Add Device',
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                const SizedBox(height: 4),
                Text('Register a new ESP32 GPS tracker',
                    style: TextStyle(
                        color: Colors.white.withAlpha(153), fontSize: 14)),
                const SizedBox(height: 32),

                if (_apiKey == null) ...[
                  Form(
                    key: _form,
                    child: TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Device name',
                        hintText: 'e.g. Tracker-01',
                        prefixIcon: Icon(Icons.devices_other,
                            color: AppColors.blue400),
                      ),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Name required' : null,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Register Device'),
                  ),
                ] else ...[
                  // Success — show API key
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.check_circle,
                                color: AppColors.green, size: 20),
                            const SizedBox(width: 8),
                            const Text('Device Created!',
                                style: TextStyle(
                                    color: AppColors.green,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Text('API Key',
                            style: TextStyle(
                                color: AppColors.blue300,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: const Color(0x28FFFFFF)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _apiKey!,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: AppColors.blue200,
                                      fontSize: 12),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy,
                                    size: 18, color: AppColors.blue400),
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: _apiKey!));
                                  showToast(context, 'API key copied to clipboard',
                                      type: ToastType.success);
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.amber.withAlpha(20),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppColors.amber.withAlpha(60)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: AppColors.amber, size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Copy this key now — it will not be shown again.',
                                  style: TextStyle(
                                      color: AppColors.amber,
                                      fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Paste into main.cpp:',
                            style: TextStyle(
                                color: AppColors.blue300,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '#define DEVICE_API_KEY  "$_apiKey"',
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                color: AppColors.cyan,
                                fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back to Devices'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
