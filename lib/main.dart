import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'core/desktop_window.dart';

import 'core/storage/local_storage.dart';
import 'data/services/content_cache.dart';
import 'data/services/repo_manager.dart';
import 'data/services/library_service.dart';
import 'data/services/repo_prefs.dart';
import 'data/services/settings_service.dart';
import 'data/services/download_service.dart';
import 'data/services/ui_scale_service.dart';
import 'data/services/version_service.dart';
import 'ui/shared/download_progress_overlay.dart';
import 'ui/shared/update_banner.dart';

import 'launcher/home.dart';
import 'widgets/custom_title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(900, 560),
    center: true,
    backgroundColor: Color(0xFF0B0D10),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'LOL Lite',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setTitle('LOL Lite');
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const _BootstrapApp());
}

class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  Widget? _readyApp;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      AppLifecycleUi.setBooting(true, 'Iniciando...');

      MediaKit.ensureInitialized();
      await DesktopWindowController.instance.init();

      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
      ]);

      AppLifecycleUi.setBooting(true, 'Cargando datos...');

      final storage = LocalStorage();
      await storage.init();
      ContentCache.instance.bind(storage);

      final repoManager = RepoManager(storage);
      final libraryService = LibraryService(storage);
      final repoPrefs = RepoPrefs(storage);
      final settingsService = SettingsService(storage);

      try {
        DownloadService.instance.bind(storage);
        await DownloadService.instance.init();
      } catch (e) {
        debugPrint('[main] DownloadService.init: $e');
      }

      AppLifecycleUi.setBooting(true, 'Preparando...');

      await Future.wait([
        repoManager.init(),
        libraryService.init(),
        settingsService.load(),
        UiScaleService.instance.load(),
      ]);

      try {
        await settingsService.setMode(UiMode.desktop);
      } catch (_) {}

      if (!mounted) return;

      final app = MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: repoManager),
          ChangeNotifierProvider.value(value: libraryService),
          ChangeNotifierProvider.value(value: repoPrefs),
          ChangeNotifierProvider.value(value: settingsService),
          ChangeNotifierProvider.value(value: DownloadService.instance),
          ChangeNotifierProvider.value(value: UiScaleService.instance),
        ],
        child: const LolLiteDesktopApp(),
      );

      setState(() => _readyApp = app);
      AppLifecycleUi.setBooting(false);

      // Mensaje de actualización exitosa al reabrir
      Future<void>.delayed(const Duration(milliseconds: 700), () async {
        final msg = await VersionService.instance.consumeUpdateSuccessMessage();
        if (msg == null) return;
        final ctx = desktopNavigatorKey.currentContext;
        if (ctx == null || !ctx.mounted) return;
        await showDialog<void>(
          context: ctx,
          barrierDismissible: true,
          builder: (dCtx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1F2A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Color(0xFF4CAF50), size: 28),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Actualización instalada',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              msg.isEmpty
                  ? 'La actualización se instaló correctamente.'
                  : 'La actualización se instaló con éxito.\n\nVersión: $msg',
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE50914),
                ),
                onPressed: () => Navigator.pop(dCtx),
                child: const Text('Aceptar'),
              ),
            ],
          ),
        );
      });
    } catch (e, st) {
      debugPrint('[boot] $e\n$st');
      if (mounted) setState(() => _error = e.toString());
      AppLifecycleUi.setBooting(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF0B0D10),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Error al iniciar:\n$_error',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    if (_readyApp != null) return _readyApp!;

    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _SpinnerScreen(),
    );
  }
}

class _SpinnerScreen extends StatelessWidget {
  final String? fixedText;
  const _SpinnerScreen({this.fixedText});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D10),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/spiner.gif',
              width: 96,
              height: 96,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(0xFFE50914),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<String>(
              valueListenable: AppLifecycleUi.statusText,
              builder: (_, text, __) => Text(
                fixedText ?? text,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppSpinnerOverlay extends StatelessWidget {
  final Widget child;
  const AppSpinnerOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ValueListenableBuilder<bool>(
          valueListenable: AppLifecycleUi.isClosing,
          builder: (_, closing, __) {
            if (!closing) return const SizedBox.shrink();
            return const ColoredBox(
              color: Color(0xE00B0D10),
              child: _SpinnerScreen(fixedText: 'Cerrando...'),
            );
          },
        ),
      ],
    );
  }
}

final GlobalKey<NavigatorState> desktopNavigatorKey =
    GlobalKey<NavigatorState>();

class LolLiteDesktopApp extends StatelessWidget {
  const LolLiteDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LOL Lite',
      navigatorKey: desktopNavigatorKey,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE50914),
          brightness: Brightness.dark,
          primary: const Color(0xFFE50914),
          onPrimary: Colors.white,
          surface: const Color(0xFF0F1115),
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE50914),
            foregroundColor: Colors.white,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFE50914),
            foregroundColor: Colors.white,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white38),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
        ),
      ),
      builder: (context, child) {
        return ListenableBuilder(
          listenable: UiScaleService.instance,
          builder: (context, _) {
            final scale = UiScaleService.instance.scale;
            final media = MediaQuery.of(context);
            return AppSpinnerOverlay(
              child: MediaQuery(
                data: media.copyWith(
                  textScaler: TextScaler.linear(scale),
                ),
                child: Column(
                  children: [
                    CustomTitleBar(
                      title: 'LOL Lite',
                      backgroundColor: Colors.black,
                      navigatorKey: desktopNavigatorKey,
                    ),
                    Expanded(
                      child: UpdateGate(
                        navigatorKey: desktopNavigatorKey,
                        child: DownloadProgressOverlay(
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      home: const LauncherHome(),
    );
  }
}
