import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/version_service.dart';


/// Abre el mismo flujo de actualización (comprobar + modal) desde Config u otras pantallas.
/// [forceNotifyPatches]: si true, también considera parches aunque el switch esté off
/// (útil al pulsar "Verificar" manualmente).
Future<void> showAppUpdateFlow(
  BuildContext context, {
  bool forceNotifyPatches = true,
  bool showUpToDateSnack = true,
}) async {
  final settings = context.read<SettingsService>();
  final isTv = settings.isTv;

  // Loading corto
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => const Center(
      child: Card(
        color: Color(0xFF1A1F2A),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Color(0xFFE50914),
            ),
          ),
        ),
      ),
    ),
  );

  UpdateStatus status;
  try {
    status = await VersionService.instance.checkForUpdate(
      notifyPatches: forceNotifyPatches || settings.notifyPatches,
    );
  } catch (_) {
    status = UpdateStatus(
      requiresUpdate: false,
      hasVersionUpdate: false,
      hasPatchUpdate: false,
      latestVersion: null,
      message: 'Error al comprobar actualizaciones',
    );
  }

  if (context.mounted) {
    try {
      Navigator.of(context, rootNavigator: true).pop(); // cierra loading
    } catch (_) {}
  }
  if (!context.mounted) return;

  if (!status.requiresUpdate || status.latestVersion == null) {
    if (showUpToDateSnack) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(status.message),
          duration: const Duration(seconds: 3),
        ),
      );
      // TV a veces sin ScaffoldMessenger en esa ruta: dialog simple
      if (isTv && ScaffoldMessenger.maybeOf(context) == null) {
        await showDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1F2A),
            title: const Text('Actualizaciones',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            content: Text(status.message,
                style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        );
      }
    }
    return;
  }

  final info = status.latestVersion!;
  String? initialAbi;
  if (isTv) {
    initialAbi = VersionService.tvForcedAbi;
  } else {
    final last = await VersionService.instance.loadLastDownload();
    initialAbi = last?['abi'];
  }

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    builder: (ctx) {
      return _UpdateModal(
        status: status,
        info: info,
        isTv: isTv,
        initialAbi: initialAbi,
        onDismiss: () => Navigator.of(ctx).pop(),
        onDownload: (abi, url) async {
          Navigator.of(ctx).pop();
          await _downloadAndInstall(
            context,
            info: info,
            abi: abi,
            url: url,
            isTv: isTv,
          );
        },
      );
    },
  );
}

Future<void> _downloadAndInstall(
  BuildContext context, {
  required AppVersionInfo info,
  required String abi,
  required String url,
  required bool isTv,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1A1F2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Descargando actualización',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: Colors.white12,
              color: Color(0xFFE50914),
            ),
            const SizedBox(height: 14),
            Text('No cierres la app…',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          ],
        ),
      ),
    ),
  );

  try {
    // Desktop Windows: descarga + aplica sola y reinicia
    if (Platform.isWindows && !isTv) {
      final desktopUrl = VersionService.instance.resolveDesktopUrl(info) ?? url;
      final file =
          await VersionService.instance.downloadDesktopPackage(desktopUrl);
      if (context.mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }
      if (file == null) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Error al descargar la actualización')),
          );
        }
        return;
      }
      await VersionService.instance.saveLastDownload(
        abi: 'windows',
        version: info.version,
        parche: info.parche,
        url: desktopUrl,
      );
      await VersionService.instance.markUpdatePending(
        versionLabel: '${info.version} · ${info.parche}',
      );
      final ok = await VersionService.instance.applyDesktopUpdate(file);
      if (ok) {
        // Cierra la app para que el script/instalador reemplace y reinicie
        await Future<void>.delayed(const Duration(milliseconds: 800));
        exit(0);
      }
      if (context.mounted) {
        final detail = VersionService.instance.lastInstallError;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(detail == null || detail.isEmpty
                ? 'No se pudo aplicar la actualización'
                : detail),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return;
    }

    final finalUrl = isTv ? (info.urlApkArmeabi ?? url) : url;
    final file = await VersionService.instance.downloadApk(finalUrl);
    if (context.mounted) {
      try {
        Navigator.of(context, rootNavigator: true).pop();
      } catch (_) {}
    }
    if (file == null) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Error al descargar el APK')),
        );
      }
      return;
    }
    await VersionService.instance.saveLastDownload(
      abi: isTv ? VersionService.tvForcedAbi : abi,
      version: info.version,
      parche: info.parche,
      url: finalUrl,
    );
    final ok = await VersionService.instance.installApkFile(file.path);
    if (!ok && context.mounted) {
      final detail = VersionService.instance.lastInstallError;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            detail == null || detail.isEmpty
                ? 'No se pudo iniciar la instalación. Revisa el permiso “Instalar apps desconocidas”.'
                : 'No se pudo iniciar la instalación: $detail',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      try {
        Navigator.of(context, rootNavigator: true).pop();
      } catch (_) {}
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }
}


/// Envuelve toda la app.
/// - Cambio de VERSIÓN → siempre notifica (modal).
/// - Cambio de PARCHE → solo si [SettingsService.notifyPatches] está activo.
/// - TV: descarga solo url_apk_armeabi.
/// - Móvil: modal para elegir ABI; se guarda en caché la última elección.
class UpdateGate extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;
  const UpdateGate({super.key, required this.child, this.navigatorKey});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  /// Context con Overlay (Navigator). El context del builder NO tiene Overlay.
  BuildContext? get _overlayContext =>
      widget.navigatorKey?.currentContext;

  UpdateStatus? _status;
  bool _dismissed = false;
  bool _busy = false;
  double _progress = 0;
  String? _error;
  bool _modalShown = false;
  String? _selectedAbi;
  String? _selectedUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    final settings = context.read<SettingsService>();
    // Versión siempre; parches solo si el usuario lo tiene activo
    final s = await VersionService.instance.checkForUpdate(
      notifyPatches: settings.notifyPatches,
    );
    if (!mounted) return;
    setState(() => _status = s);

    if (s.requiresUpdate && !_modalShown && !_dismissed) {
      _modalShown = true;
      // Esperar a que el Navigator/Overlay esté montado (builder corre antes).
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted || _dismissed) return;
        if (_overlayContext != null) break;
      }
      if (!mounted || _dismissed || _overlayContext == null) return;
      await _showUpdateModal(s);
    }
  }

  Future<void> _showUpdateModal(UpdateStatus s) async {
    final info = s.latestVersion;
    if (info == null) return;
    final settings = context.read<SettingsService>();
    final isTv = settings.isTv;

    // TV / cache: forzar armeabi
    if (isTv) {
      final url = info.urlApkArmeabi ??
          VersionService.instance.resolveApkUrl(info, preferredAbi: 'armeabi');
      setState(() {
        _selectedAbi = VersionService.tvForcedAbi;
        _selectedUrl = url;
      });
    } else {
      // Móvil: recuperar última ABI de caché
      final last = await VersionService.instance.loadLastDownload();
      final abis = VersionService.instance.availableAbis(info);
      String? abi = last?['abi'];
      String? url;
      if (abi != null) {
        for (final a in abis) {
          if (a.id == abi) {
            url = a.url;
            break;
          }
        }
      }
      if (url == null && abis.isNotEmpty) {
        abi = abis.first.id;
        url = abis.first.url;
      }
      setState(() {
        _selectedAbi = abi;
        _selectedUrl = url;
      });
    }

    final dialogCtx = _overlayContext;
    if (!mounted || dialogCtx == null) return;
    await showDialog<void>(
      context: dialogCtx,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (ctx) {
        return _UpdateModal(
          status: s,
          info: info,
          isTv: isTv,
          initialAbi: _selectedAbi,
          onDismiss: () {
            Navigator.of(ctx).pop();
            if (mounted) setState(() => _dismissed = true);
          },
          onDownload: (abi, url) async {
            setState(() {
              _selectedAbi = abi;
              _selectedUrl = url;
            });
            Navigator.of(ctx).pop();
            await _install(abi: abi, url: url);
          },
        );
      },
    );
  }

  Future<void> _showNovedades() async {
    final info = _status?.latestVersion;
    if (info == null) return;
    final dialogCtx = _overlayContext;
    if (dialogCtx == null) return;
    await showDialog<void>(
      context: dialogCtx,
      useRootNavigator: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1F2A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Novedades · v${info.version}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Parche: ${info.parche}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
                ),
                const SizedBox(height: 12),
                if (info.novedades.isEmpty)
                  const Text('Sin notas de esta versión.', style: TextStyle(color: Colors.white70))
                else
                  ...info.novedades.map(
                    (n) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('•  ', style: TextStyle(color: Color(0xFFE50914))),
                          Expanded(
                            child: Text(n, style: const TextStyle(color: Colors.white70, height: 1.35)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar', style: TextStyle(color: Colors.white70)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _install({String? abi, String? url}) async {
    final info = _status?.latestVersion;
    if (info == null) return;

    final settings = context.read<SettingsService>();
    final isTv = settings.isTv;

    // Resolver URL final
    String? finalAbi = abi ?? _selectedAbi;
    String? finalUrl = url ?? _selectedUrl;

    if (isTv) {
      finalAbi = VersionService.tvForcedAbi;
      finalUrl = info.urlApkArmeabi ??
          VersionService.instance.resolveApkUrl(info, preferredAbi: 'armeabi');
    } else if (finalUrl == null || finalUrl.isEmpty) {
      finalUrl = VersionService.instance.resolveApkUrl(
        info,
        preferredAbi: finalAbi,
      );
    }

    if (finalUrl == null || finalUrl.isEmpty) {
      setState(() => _error = 'No hay URL de actualización disponible');
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });

    // Diálogo de progreso (foco-safe) mientras descarga
    final progressCtx = _overlayContext;
    if (progressCtx != null && mounted) {
      showDialog<void>(
        context: progressCtx,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (ctx) {
          return PopScope(
            canPop: false,
            child: AlertDialog(
              backgroundColor: const Color(0xFF1A1F2A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Descargando actualización',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: null,
                    minHeight: 4,
                    backgroundColor: Colors.white12,
                    color: const Color(0xFFE50914),
                  ),
                  const SizedBox(height: 14),
                  Text('No cierres la app…',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
                ],
              ),
            ),
          );
        },
      );
    }

    try {
      final isDesktop = Platform.isWindows && !isTv;
      late final File? file;
      if (isDesktop) {
        final desktopUrl =
            VersionService.instance.resolveDesktopUrl(info) ?? finalUrl!;
        finalUrl = desktopUrl;
        finalAbi = 'windows';
        file = await VersionService.instance.downloadDesktopPackage(
          desktopUrl,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        );
      } else {
        file = await VersionService.instance.downloadApk(
          finalUrl!,
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        );
      }
      // Cerrar diálogo de progreso
      final oc = _overlayContext;
      if (oc != null) {
        try {
          Navigator.of(oc, rootNavigator: true).pop();
        } catch (_) {}
      }

      if (file == null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = 'Error al descargar la actualización';
          });
          _snack('Error al descargar la actualización');
        }
        return;
      }

      await VersionService.instance.saveLastDownload(
        abi: finalAbi ?? 'unknown',
        version: info.version,
        parche: info.parche,
        url: finalUrl ?? '',
      );

      if (isDesktop) {
        await VersionService.instance.markUpdatePending(
        versionLabel: '${info.version} · ${info.parche}',
      );
      final ok = await VersionService.instance.applyDesktopUpdate(file);
        if (!mounted) return;
        setState(() => _busy = false);
        if (ok) {
          _snack('Actualizando… la app se cerrará y reiniciará sola');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          exit(0);
        }
        final detail = VersionService.instance.lastInstallError;
        final msg = (detail == null || detail.isEmpty)
            ? 'No se pudo aplicar la actualización'
            : detail;
        setState(() => _error = msg);
        _snack(msg);
        return;
      }

      final ok = await VersionService.instance.installApkFile(file.path);
      if (!mounted) return;
      setState(() => _busy = false);
      if (!ok) {
        final detail = VersionService.instance.lastInstallError;
        final msg = detail == null || detail.isEmpty
            ? 'No se pudo iniciar la instalación. Revisa el permiso “Instalar apps desconocidas”.'
            : 'No se pudo iniciar la instalación: $detail';
        setState(() => _error = msg);
        _snack(msg);
      }
    } catch (e) {
      final oc = _overlayContext;
      if (oc != null) {
        try {
          Navigator.of(oc, rootNavigator: true).pop();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
        _snack('Error: $e');
      }
    }
  }

  void _snack(String msg) {
    final c = _overlayContext;
    if (c == null) return;
    ScaffoldMessenger.maybeOf(c)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Solo modal al iniciar (sin barra superior).
    return widget.child;
  }
}

class _UpdateModal extends StatefulWidget {
  final UpdateStatus status;
  final AppVersionInfo info;
  final bool isTv;
  final String? initialAbi;
  final VoidCallback onDismiss;
  final void Function(String abi, String url) onDownload;

  const _UpdateModal({
    required this.status,
    required this.info,
    required this.isTv,
    required this.initialAbi,
    required this.onDismiss,
    required this.onDownload,
  });

  @override
  State<_UpdateModal> createState() => _UpdateModalState();
}

class _UpdateModalState extends State<_UpdateModal> {
  late String? _abi;
  final FocusNode _downloadFocus = FocusNode(debugLabel: 'update_download');
  final FocusNode _laterFocus = FocusNode(debugLabel: 'update_later');

  @override
  void initState() {
    super.initState();
    _abi = widget.isTv ? VersionService.tvForcedAbi : widget.initialAbi;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _downloadFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _downloadFocus.dispose();
    _laterFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final localV = VersionService.currentVersionName;
    final localP = VersionService.currentParche;
    final abis = VersionService.instance.availableAbis(info);
    final selected = abis.where((a) => a.id == _abi).toList();
    final url = selected.isNotEmpty
        ? selected.first.url
        : (widget.isTv
            ? (info.urlApkArmeabi ?? '')
            : (abis.isNotEmpty ? abis.first.url : ''));
    final abiId = selected.isNotEmpty
        ? selected.first.id
        : (widget.isTv
            ? VersionService.tvForcedAbi
            : (abis.isNotEmpty ? abis.first.id : 'arm64'));

    return FocusScope(
      autofocus: true,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1A1F2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFE50914).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.system_update_rounded,
                  color: Color(0xFFE50914), size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Actualización disponible',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 17),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: widget.isTv ? 420 : 320,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.status.message,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75), height: 1.35),
                ),
                const SizedBox(height: 14),
                _kv('Instalada', 'v$localV · parche $localP'),
                _kv('Nueva', 'v${info.version} · parche ${info.parche}'),
                if (widget.status.hasVersionUpdate) _badge('Cambio de versión'),
                if (widget.status.hasPatchUpdate && !widget.status.hasVersionUpdate)
                  _badge('Nuevo parche'),
                if (info.novedades.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Novedades',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...info.novedades.take(6).map(
                        (n) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('•  ',
                                  style: TextStyle(color: Color(0xFFE50914))),
                              Expanded(
                                child: Text(n,
                                    style: const TextStyle(
                                        color: Colors.white70, height: 1.3)),
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
                const SizedBox(height: 16),
                if (widget.isTv) ...[
                  Text(
                    'Paquete (TV)',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'ARMeabi (optimizado para Android TV)',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                  ),
                ] else ...[
                  Text(
                    'Elige la versión del APK',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (abis.isEmpty)
                    const Text('No hay paquetes disponibles',
                        style: TextStyle(color: Colors.white54))
                  else
                    ...abis.map((a) {
                      final sel = a.id == abiId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => setState(() => _abi = a.id),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: sel
                                    ? const Color(0xFFE50914)
                                        .withValues(alpha: 0.18)
                                    : Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: sel
                                      ? const Color(0xFFE50914)
                                      : Colors.transparent,
                                  width: 1.4,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    sel
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off,
                                    size: 18,
                                    color: sel
                                        ? const Color(0xFFE50914)
                                        : Colors.white38,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      a.label,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: sel
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          // Botones con foco visible (TV)
          _TvFocusButton(
            focusNode: _laterFocus,
            label: 'Más tarde',
            primary: false,
            onPressed: widget.onDismiss,
          ),
          const SizedBox(width: 8),
          _TvFocusButton(
            focusNode: _downloadFocus,
            label: 'Descargar',
            primary: true,
            enabled: url.isNotEmpty,
            onPressed: url.isEmpty
                ? null
                : () => widget.onDownload(abiId, url),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(k,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12)),
          ),
          Expanded(
            child: Text(v,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _badge(String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFE50914).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(t,
            style: const TextStyle(
                color: Color(0xFFFF8A80),
                fontSize: 11,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// Botón de diálogo con foco visible para TV (mando).
class _TvFocusButton extends StatefulWidget {
  final FocusNode focusNode;
  final String label;
  final bool primary;
  final bool enabled;
  final VoidCallback? onPressed;

  const _TvFocusButton({
    required this.focusNode,
    required this.label,
    required this.primary,
    this.enabled = true,
    required this.onPressed,
  });

  @override
  State<_TvFocusButton> createState() => _TvFocusButtonState();
}

class _TvFocusButtonState extends State<_TvFocusButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.onPressed != null;
    final bg = !enabled
        ? Colors.white.withValues(alpha: 0.06)
        : (_focused
            ? Colors.white
            : (widget.primary
                ? const Color(0xFFE50914)
                : Colors.white.withValues(alpha: 0.10)));
    final fg = !enabled
        ? Colors.white38
        : (_focused
            ? Colors.black
            : Colors.white);

    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (enabled &&
            (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space)) {
          widget.onPressed?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
