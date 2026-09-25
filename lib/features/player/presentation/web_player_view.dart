import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

/// Web player Windows — usa [webview_windows] (WebView2).
/// Misma UX que el WebView móvil: atrás con fade, menú salir / cambiar servidor.
class WebPlayerView extends StatefulWidget {
  final int idcontenido;
  final int? tmdbId;
  final int? temporada;
  final int? capitulo;
  final String servidorUrl;
  final String servidorNombre;
  final String tipo;
  final String titulo;
  final String? idioma;
  final String? backdropUrl;
  final String? posterUrl;
  final VoidCallback? onChangeServer;

  const WebPlayerView({
    super.key,
    required this.idcontenido,
    this.tmdbId,
    this.temporada,
    this.capitulo,
    required this.servidorUrl,
    required this.servidorNombre,
    required this.tipo,
    required this.titulo,
    this.idioma,
    this.backdropUrl,
    this.posterUrl,
    this.onChangeServer,
  });

  @override
  State<WebPlayerView> createState() => _WebPlayerViewState();
}

class _WebPlayerViewState extends State<WebPlayerView> {
  final WebviewController _controller = WebviewController();

  bool _ready = false;
  bool _loading = true;
  String? _error;
  bool _exitDialogOpen = false;

  double _backOpacity = 1.0;
  Timer? _fadeTimer;
  static const _fadeStep = Duration(milliseconds: 120);
  static const _fadeInterval = Duration(milliseconds: 80);
  static const _minOpacity = 0.12;

  StreamSubscription? _loadingSub;
  StreamSubscription? _errorSub;

  int get _resolvedTmdbId =>
      (widget.tmdbId != null && widget.tmdbId! > 0)
          ? widget.tmdbId!
          : widget.idcontenido;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_initWebView());
    unawaited(_saveWebPlayerCache());
    _startBackFade();
  }

  Future<void> _initWebView() async {
    final url = widget.servidorUrl.trim();
    if (url.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'URL de servidor vacía';
        });
      }
      return;
    }

    if (!Platform.isWindows) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'webview_windows solo está disponible en Windows';
        });
      }
      return;
    }

    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(Colors.black);
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      _loadingSub = _controller.loadingState.listen((state) {
        if (!mounted) return;
        if (state == LoadingState.navigationCompleted) {
          setState(() {
            _loading = false;
            _ready = true;
          });
          unawaited(_tryAutoPlay());
        } else if (state == LoadingState.loading) {
          setState(() => _loading = true);
        }
      });

      // Algunos builds exponen onLoadError / errors
      try {
        _errorSub = _controller.onLoadError.listen((err) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _error = err.toString();
          });
        });
      } catch (_) {}

      await _controller.loadUrl(url);
      if (mounted) {
        setState(() {
          _ready = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'WebView2: $e\n\n¿Tienes instalado Microsoft Edge WebView2 Runtime?';
        });
      }
    }
  }

  Future<void> _tryAutoPlay() async {
    try {
      await _controller.executeScript('''
        (function() {
          try {
            document.querySelectorAll('video').forEach(function(v) {
              v.muted = false;
              v.setAttribute('playsinline', '');
              var p = v.play();
              if (p && p.catch) p.catch(function(){});
            });
          } catch(e) {}
          try {
            var sels = [
              'button[aria-label*="play" i]',
              'button[title*="play" i]',
              '.vjs-big-play-button',
              '.ytp-large-play-button',
              '.play-button', '.btn-play'
            ];
            for (var s of sels) {
              var els = document.querySelectorAll(s);
              for (var el of els) {
                var r = el.getBoundingClientRect();
                if (r.width > 20 && r.height > 20) { el.click(); return; }
              }
            }
          } catch(e) {}
        })();
      ''');
    } catch (_) {}
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    _loadingSub?.cancel();
    _errorSub?.cancel();
    _controller.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _startBackFade() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(_fadeInterval, (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final next = (_backOpacity - 0.035).clamp(_minOpacity, 1.0);
      if (next == _backOpacity) {
        t.cancel();
        return;
      }
      setState(() => _backOpacity = next);
    });
  }

  void _wakeBackButton() {
    setState(() => _backOpacity = 1.0);
    _startBackFade();
  }

  String _getCacheKey() {
    if (widget.tipo.toLowerCase() == 'tv' &&
        widget.temporada != null &&
        widget.capitulo != null) {
      return 'cachePlayer_${widget.idcontenido}_T${widget.temporada}_C${widget.capitulo}';
    }
    return 'cachePlayer_${widget.idcontenido}';
  }

  String _getCacheKeyRapido() {
    if (widget.tipo.toLowerCase() == 'tv' &&
        widget.temporada != null &&
        widget.capitulo != null) {
      return 'cachePlayerRapido_${widget.idcontenido}_T${widget.temporada}_C${widget.capitulo}';
    }
    return 'cachePlayerRapido_${widget.idcontenido}';
  }

  Future<void> _saveWebPlayerCache({int segundo = 0}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _getCacheKey(),
        jsonEncode({
          'idcontenido': widget.idcontenido,
          'tmdbId': _resolvedTmdbId,
          'temporada': widget.temporada,
          'capitulo': widget.capitulo,
          'segundo': segundo,
          'titulo': widget.titulo,
          'tipo': widget.tipo,
          'videoUrl': widget.servidorUrl,
          'servidorNombre': widget.servidorNombre,
          'idioma': widget.idioma,
          'webplayer': true,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
      await prefs.setString(
        _getCacheKeyRapido(),
        jsonEncode({
          'idcontenido': widget.idcontenido,
          'temporada': widget.temporada,
          'capitulo': widget.capitulo,
          'segundo': segundo,
          'webplayer': true,
        }),
      );
    } catch (_) {}
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(widget.servidorUrl);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _requestExit() async {
    if (_exitDialogOpen) return;
    _exitDialogOpen = true;

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ExitSheet(
        title: widget.titulo,
        servidor: widget.servidorNombre,
        onContinue: () => Navigator.of(ctx).pop('continue'),
        onExit: () => Navigator.of(ctx).pop('exit'),
        onChangeServer: () => Navigator.of(ctx).pop('server'),
      ),
    );

    _exitDialogOpen = false;
    if (!mounted) return;

    switch (result) {
      case 'exit':
        await _saveWebPlayerCache();
        if (mounted) Navigator.of(context).pop();
        break;
      case 'server':
        if (widget.onChangeServer != null) {
          widget.onChangeServer!();
        } else {
          await _saveWebPlayerCache();
          if (mounted) Navigator.of(context).pop('change_server');
        }
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_exitDialogOpen) return;
        _requestExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          onHover: (_) => _wakeBackButton(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // WebView2
              if (_error == null && _ready)
                Webview(_controller)
              else if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.white38, size: 48),
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14),
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFE50914)),
                          onPressed: _openExternal,
                          icon: const Icon(Icons.open_in_browser),
                          label: const Text('Abrir en navegador'),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _error = null;
                              _loading = true;
                              _ready = false;
                            });
                            unawaited(_initWebView());
                          },
                          child: const Text('Reintentar',
                              style: TextStyle(color: Colors.white70)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Volver',
                              style: TextStyle(color: Colors.white54)),
                        ),
                      ],
                    ),
                  ),
                )
              else
                const ColoredBox(color: Colors.black),

              if (_loading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    color: Color(0x99FFFFFF),
                    minHeight: 2,
                  ),
                ),

              // Botón atrás
              Positioned(
                top: MediaQuery.paddingOf(context).top + 12,
                left: 14,
                child: GestureDetector(
                  onTap: () {
                    _wakeBackButton();
                    _requestExit();
                  },
                  child: AnimatedOpacity(
                    opacity: _backOpacity,
                    duration: _fadeStep,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.18),
                              width: 0.8,
                            ),
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              Positioned(
                top: MediaQuery.paddingOf(context).top + 16,
                left: 70,
                right: 16,
                child: AnimatedOpacity(
                  opacity: _backOpacity,
                  duration: _fadeStep,
                  child: Text(
                    widget.titulo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExitSheet extends StatelessWidget {
  final String title;
  final String servidor;
  final VoidCallback onContinue;
  final VoidCallback onExit;
  final VoidCallback onChangeServer;

  const _ExitSheet({
    required this.title,
    required this.servidor,
    required this.onContinue,
    required this.onExit,
    required this.onChangeServer,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0E0E10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title.isNotEmpty ? title : 'Reproductor',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (servidor.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                servidor,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 22),
            _row('Seguir viendo', Icons.play_arrow_rounded, onContinue),
            const SizedBox(height: 8),
            _row('Cambiar servidor', Icons.dns_outlined, onChangeServer),
            const SizedBox(height: 8),
            _row('Salir', Icons.close_rounded, onExit, dim: true),
          ],
        ),
      ),
    );
  }

  Widget _row(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool dim = false,
  }) {
    return Material(
      color: Colors.white.withValues(alpha: dim ? 0.04 : 0.07),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: Colors.white.withValues(alpha: dim ? 0.45 : 0.9),
              ),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: dim ? 0.5 : 0.95),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}