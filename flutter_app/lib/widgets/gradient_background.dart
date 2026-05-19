import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class GradientBackground extends StatelessWidget {
  final Widget child;
  const GradientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Base gradient
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.surface,
                Color(0xFF0F1B35),
                AppColors.surface,
              ],
            ),
          ),
        ),
        // Decorative orbs
        Positioned(
          top: -80, right: -60,
          child: _Orb(color: AppColors.indigo.withAlpha(50), size: 280),
        ),
        Positioned(
          bottom: 100, left: -80,
          child: _Orb(color: AppColors.blue500.withAlpha(35), size: 240),
        ),
        Positioned(
          bottom: -40, right: 60,
          child: _Orb(color: AppColors.cyan.withAlpha(30), size: 180),
        ),
        child,
      ],
    );
  }
}

class _Orb extends StatelessWidget {
  final Color color;
  final double size;
  const _Orb({required this.color, required this.size});

  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
        ),
      );
}
