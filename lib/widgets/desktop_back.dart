import 'package:flutter/material.dart';

/// Botón de volver pensado para ratón en desktop.
class DesktopBackButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Color? background;
  final Color? iconColor;

  const DesktopBackButton({
    super.key,
    this.onPressed,
    this.background,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? Colors.black.withOpacity(0.55),
      borderRadius: BorderRadius.circular(24),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onPressed ?? () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.arrow_back_rounded,
            color: iconColor ?? Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}

/// AppBar limpio para páginas secundarias de desktop.
PreferredSizeWidget desktopAppBar({
  required BuildContext context,
  required String title,
  List<Widget>? actions,
  VoidCallback? onBack,
}) {
  return AppBar(
    leading: Padding(
      padding: const EdgeInsets.only(left: 8),
      child: DesktopBackButton(onPressed: onBack),
    ),
    leadingWidth: 56,
    title: Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    ),
    actions: actions,
  );
}
