import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Estado global de UI de arranque / cierre (spinner).
class AppLifecycleUi {
  AppLifecycleUi._();
  static final ValueNotifier<bool> isBooting = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> isClosing = ValueNotifier<bool>(false);
  static final ValueNotifier<String> statusText =
      ValueNotifier<String>('Cargando...');

  static void setBooting(bool v, [String? msg]) {
    isBooting.value = v;
    if (msg != null) statusText.value = msg;
  }

  static void setClosing([String msg = 'Cerrando...']) {
    isClosing.value = true;
    statusText.value = msg;
  }
}

/// Gestión Windows:
/// - Minimizar: normal (barra de tareas).
/// - Cerrar (X) + "Cerrar a la bandeja" ON → bandeja con icono de la app.
/// - Cerrar (X) + opción OFF → mata procesos y sale limpio.
class DesktopWindowController with WindowListener, TrayListener {
  DesktopWindowController._();
  static final DesktopWindowController instance = DesktopWindowController._();

  bool _closeToTray = true;
  bool _started = false;
  bool _trayReady = false;
  bool _exiting = false;
  String? _resolvedIconPath;

  Future<void> init() async {
    if (_started) return;
    if (kIsWeb || !Platform.isWindows) return;
    _started = true;

    final prefs = await SharedPreferences.getInstance();
    _closeToTray = prefs.getBool('close_to_tray') ?? true;

    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    // Preparar icono en disco (ruta absoluta) para la bandeja
    await _prepareIconFile();
    await _initTray();
  }

  /// Copia el icono de assets a un archivo temporal con ruta absoluta.
  /// tray_manager en Windows necesita path real, no asset virtual.
  Future<void> _prepareIconFile() async {
    try {
      final candidates = <String>[];

      // 1) Junto al .exe (instalación Inno / portable)
      try {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        candidates.addAll([
          '$exeDir${Platform.pathSeparator}app_icon.ico',
          '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}tray_icon.ico',
          '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}images${Platform.pathSeparator}tray_icon.ico',
        ]);
      } catch (_) {}

      // 2) Assets empaquetados relativos
      candidates.addAll([
        'assets/tray_icon.ico',
        'assets/app_icon.ico',
        r'windows\runner\resources\app_icon.ico',
      ]);

      for (final c in candidates) {
        final f = File(c);
        if (await f.exists() && await f.length() > 100) {
          _resolvedIconPath = f.absolute.path;
          debugPrint('[DesktopWindow] icon found: $_resolvedIconPath');
          break;
        }
      }

      // 3) Extraer desde AssetBundle a carpeta temporal
      if (_resolvedIconPath == null) {
        for (final asset in [
          'assets/tray_icon.ico',
          'assets/app_icon.ico',
        ]) {
          try {
            final data = await rootBundle.load(asset);
            final bytes = data.buffer.asUint8List();
            if (bytes.length < 100) continue;
            final tmp = await getTemporaryDirectory();
            final out = File(
                '${tmp.path}${Platform.pathSeparator}lollite_tray_icon.ico');
            await out.writeAsBytes(bytes, flush: true);
            _resolvedIconPath = out.absolute.path;
            debugPrint('[DesktopWindow] icon from asset $asset → $_resolvedIconPath');
            break;
          } catch (e) {
            debugPrint('[DesktopWindow] asset $asset: $e');
          }
        }
      }

      // 4) Último recurso: copiar app_icon.ico del runner si existe en disco
      if (_resolvedIconPath == null) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final runnerIco = File(
            '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}app_icon.ico');
        // Algunos builds copian el ico al root de data
      }
    } catch (e) {
      debugPrint('[DesktopWindow] prepareIcon: $e');
    }
  }

  Future<void> _initTray() async {
    try {
      if (_resolvedIconPath == null) {
        await _prepareIconFile();
      }
      final iconPath = _resolvedIconPath;
      if (iconPath == null || !await File(iconPath).exists()) {
        debugPrint('[DesktopWindow] SIN ICONO para bandeja');
        // Intentar igual con path de asset (a veces funciona en debug)
        await trayManager.setIcon('assets/tray_icon.ico');
      } else {
        await trayManager.setIcon(iconPath);
      }
      await trayManager.setToolTip('LOL Lite');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Mostrar LOL Lite'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Salir'),
      ]));
      trayManager.addListener(this);
      _trayReady = true;
      debugPrint('[DesktopWindow] tray listo icon=$iconPath');
    } catch (e) {
      debugPrint('[DesktopWindow] tray init error: $e');
      _trayReady = false;
    }
  }

  Future<void> reloadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _closeToTray = prefs.getBool('close_to_tray') ?? true;
  }

  Future<void> setCloseToTray(bool value) async {
    _closeToTray = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('close_to_tray', value);
  }

  Future<void> setStartWithWindows(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('start_with_windows', enabled);
    if (!Platform.isWindows) return;

    try {
      final exe = Platform.resolvedExecutable;
      if (enabled) {
        await Process.run('reg', [
          'add',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'LolLiteDesktop',
          '/t',
          'REG_SZ',
          '/d',
          '"$exe"',
          '/f',
        ]);
      } else {
        await Process.run('reg', [
          'delete',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'LolLiteDesktop',
          '/f',
        ]);
      }
    } catch (e) {
      debugPrint('[DesktopWindow] startup registry: $e');
    }
  }

  Future<void> refreshStartupRegistration() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('start_with_windows') ?? false;
    if (enabled) await setStartWithWindows(true);
  }

  Future<void> _goToTray() async {
    try {
      if (!_trayReady) await _initTray();
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
    } catch (e) {
      debugPrint('[DesktopWindow] goToTray: $e');
    }
  }

  Future<void> showFromTray() async {
    try {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await windowManager.setAlwaysOnTop(false);
    } catch (e) {
      debugPrint('[DesktopWindow] showFromTray: $e');
    }
  }

  Future<void> exitApp() async {
    if (_exiting) return;
    _exiting = true;
    AppLifecycleUi.setClosing('Cerrando...');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    try {
      await trayManager.destroy();
    } catch (_) {}

    await _killAllRelatedProcesses();

    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}

    exit(0);
  }

  Future<void> _killAllRelatedProcesses() async {
    if (!Platform.isWindows) return;
    try {
      final myPid = pid;
      try {
        await Process.run('taskkill', ['/F', '/T', '/PID', '$myPid'],
                runInShell: true)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
      try {
        await Process.run(
                'taskkill', ['/F', '/IM', 'lollite.exe', '/T'],
                runInShell: true)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    } catch (e) {
      debugPrint('[DesktopWindow] kill: $e');
    }
  }

  @override
  void onWindowClose() async {
    if (_exiting) return;
    if (_closeToTray) {
      await _goToTray();
    } else {
      await exitApp();
    }
  }

  @override
  void onWindowRestore() async {
    await windowManager.setSkipTaskbar(false);
  }

  @override
  void onWindowFocus() async {
    await windowManager.setSkipTaskbar(false);
  }

  @override
  void onTrayIconMouseDown() => showFromTray();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        showFromTray();
        break;
      case 'exit':
        exitApp();
        break;
    }
  }
}
