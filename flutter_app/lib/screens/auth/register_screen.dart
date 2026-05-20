import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/app_toast.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form     = GlobalKey<FormState>();
  final _name     = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();
  bool _loading   = false;
  bool _obscure   = true;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await context.read<AuthService>().register(
            _email.text.trim(),
            _password.text,
            _name.text.trim().isEmpty ? null : _name.text.trim(),
          );
      if (mounted) {
        showToast(context, 'Account created! Welcome to TraceX.',
            type: ToastType.success);
        // Pop back to root — Consumer in main.dart auto-shows HomeScreen
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
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
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    const Text('Create Account',
                        style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    const SizedBox(height: 4),
                    Text('Start tracking your devices with TraceX',
                        style: TextStyle(
                            color: Colors.white.withAlpha(153), fontSize: 15)),
                    const SizedBox(height: 32),

                    TextFormField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Name (optional)',
                        prefixIcon: Icon(Icons.person_outline,
                            color: AppColors.blue400),
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined,
                            color: AppColors.blue400),
                      ),
                      validator: (v) =>
                          v == null || !v.contains('@')
                              ? 'Enter a valid email'
                              : null,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline,
                            color: AppColors.blue400),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _obscure
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: AppColors.blue400),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          v == null || v.length < 8
                              ? 'Minimum 8 characters'
                              : null,
                    ),
                    const SizedBox(height: 28),

                    ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Create Account'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
