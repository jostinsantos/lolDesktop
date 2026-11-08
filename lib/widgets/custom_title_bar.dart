import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Barra de título Windows: fondo negro sólido, botones de ventana.
/// Va en MaterialApp.builder (fuera del Navigator) → NO usar Tooltip (requiere Overlay).
class CustomTitleBar extends StatefulWidget {
  final String title;
  final Color? backgroundColor;
  final double height;
  final VoidCallback? onBack;
  final GlobalKey<NavigatorState>? navigatorKey;

  const CustomTitleBar({
    super.key,
    this.title = 'LOL Lite',
    this.backgroundColor,
    this.height = 36,
    this.onBack,
    this.navigatorKey,
  });

  @override
  State<CustomTitleBar> createState() => _CustomTitleBarState();
}

class _CustomTitleBarState extends State<CustomTitleBar> with WindowListener {
  bool _isMaximized = false;
  bool _isFullscreen = false;
  DateTime? _forceShowUntil;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_refresh(forceShow: false));
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_refresh(forceShow: false));
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refresh({required bool forceShow}) async {
    try {
      final m = await windowManager.isMaximized();
      final f = await windowManager.isFullScreen();
      if (!mounted) return;

      final inForceShow = _forceShowUntil != null &&
          DateTime.now().isBefore(_forceShowUntil!);

      setState(() {
        _isMaximized = m;
        if (forceShow || inForceShow) {
          _isFullscreen = false;
        } else {
          _isFullscreen = f;
        }
      });
    } catch (_) {
      if (mounted && forceShow) {
        setState(() => _isFullscreen = false);
      }
    }
  }

  void _forceShowBar({int ms = 1500}) {
    _forceShowUntil = DateTime.now().add(Duration(milliseconds: ms));
    if (mounted) setState(() => _isFullscreen = false);
    unawaited(_refresh(forceShow: true));
    Future<void>.delayed(Duration(milliseconds: ms + 50), () {
      if (mounted) unawaited(_refresh(forceShow: false));
    });
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
    _forceShowBar();
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted) setState(() => _isFullscreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _forceShowBar(ms: 2000);
  }

  @override
  void onWindowRestore() {
    _forceShowBar();
  }

  @override
  void onWindowFocus() {
    _forceShowBar(ms: 800);
  }

  @override
  void onWindowResize() {
    unawaited(_refresh(forceShow: false));
  }

  Future<void> _onBack() async {
    if (widget.onBack != null) {
      widget.onBack!();
      return;
    }
    final nav = widget.navigatorKey?.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    try {
      final n = Navigator.of(context);
      if (n.canPop()) n.pop();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_isFullscreen) return const SizedBox.shrink();

    // Fondo opaco sólido (sin blur / transparencia)
    final bg = widget.backgroundColor ?? const Color(0xFF000000);

    return Material(
      color: bg,
      elevation: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => windowManager.startDragging(),
        onDoubleTap: () async {
          if (_isMaximized) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
        },
        child: Container(
          height: widget.height,
          color: bg,
          child: Row(
            children: [
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.asset(
                  'assets/app_icon.ico',
                  width: 18,
                  height: 18,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Image.asset(
                    'assets/tray_icon.ico',
                    width: 18,
                    height: 18,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 18,
                      height: 18,
                      color: const Color(0xFFE50914),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                widget.title,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _WinBtn(
                icon: Icons.arrow_back_rounded,
                onTap: _onBack,
              ),
              _WinBtn(
                icon: Icons.remove,
                onTap: () => windowManager.minimize(),
              ),
              _WinBtn(
                icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
                iconSize: _isMaximized ? 12 : 16,
                onTap: () async {
                  if (_isMaximized) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
              ),
              _WinBtn(
                icon: Icons.close,
                isClose: true,
                onTap: () => windowManager.close(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WinBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;
  final double iconSize;

  const _WinBtn({
    required this.icon,
    required this.onTap,
    this.isClose = false,
    this.iconSize = 16,
  });

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = !_hover
        ? Colors.transparent
        : (widget.isClose ? const Color(0xFFE81123) : Colors.white12);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 36,
          color: bg,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
