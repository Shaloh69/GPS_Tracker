import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum ToastType { success, error, warning, info }

void showToast(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
}) {
  final Color color;
  final IconData icon;
  switch (type) {
    case ToastType.success:
      color = AppColors.green;
      icon  = Icons.check_circle_rounded;
      break;
    case ToastType.error:
      color = AppColors.red;
      icon  = Icons.error_rounded;
      break;
    case ToastType.warning:
      color = AppColors.amber;
      icon  = Icons.warning_rounded;
      break;
    case ToastType.info:
      color = AppColors.blue400;
      icon  = Icons.info_rounded;
      break;
  }

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: AppColors.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: color.withAlpha(115), width: 1),
        ),
        content: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
}
