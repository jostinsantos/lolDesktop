import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/services/settings_service.dart';
import '../data/services/cast_controller.dart';
import '../ui/tv/main.dart';
import '../ui/mobile/main.dart';
import '../ui/mode_select_page.dart';
import '../ui/shared/update_banner.dart';
import '../ui/shared/download_progress_overlay.dart';
import 'app_theme.dart';

/// Clave global del Navigator (Overlay) para dialogs del UpdateGate.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class NuvioApp extends StatelessWidget {
  const NuvioApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    // Permitir que la notificación de Cast reabra la pantalla de control
    CastController.instance.navigatorKey = appNavigatorKey;

    return MaterialApp(
      title: 'Nuvio',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      builder: (context, child) {
        return UpdateGate(
          navigatorKey: appNavigatorKey,
          child: DownloadProgressOverlay(
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: !settings.hasChosenMode
          ? const ModeSelectPage()
          : (settings.isTv ? const TvAppRoot() : const MobileAppRoot()),
    );
  }
}
