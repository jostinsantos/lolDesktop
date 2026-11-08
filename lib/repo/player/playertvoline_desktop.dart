import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/models/repo_manifest.dart';
import '../../data/models/stream_server.dart';
import '../../data/services/content_service.dart';
import '../../data/services/library_service.dart';

/// Player de canales en vivo (desktop): guía, PiP, pantalla completa, rueda = volumen.
class PlayerDesktopOnlinePage extends StatefulWidget {
  final String title;
  final String? repoId;
  final String? contentId;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final String contentType;
  final List<StreamServer> servers;
  final InstalledRepo? loadRepo;
  final String preferredLanguage;
  final List<HomeRow> categories;
  final int initialCategoryIndex;
  final int initialChannelIndex;

  const PlayerDesktopOnlinePage({
    super.key,
    required this.title,
    this.repoId,
    this.contentId,
    this.poster,
    this.backdrop,
    this.logo,
    this.contentType = 'channel',
    this.servers = const [],
    this.loadRepo,
    this.preferredLanguage = '',
    this.categories = const [],
    this.initialCategoryIndex = 0,
    this.initialChannelIndex = 0,
  });

  @override
  State<PlayerDesktopOnlinePage> createState() =>
      _PlayerDesktopOnlinePageState();
}

class _PlayerDesktopOnlinePageState extends State<PlayerDesktopOnlinePage> {
  static const accent = Color(0xFFE50914);

  Player? _player;
  VideoController? _video;
  final List<StreamSubscription> _subs = [];

  bool _loading = true;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  bool _showControls = true;
  bool _showGuide = false;
  bool _isPip = false;
  bool _isFullscreen = false;
  double _volume = 100;
  String _clock = '';

  late List<StreamServer> _servers;
  int _serverIndex = 0;

  late String _title;
  late String? _contentId;
  late String? _poster;
  late String? _backdrop;
  late String? _logo;
  late String _contentType;

  late int _catIndex;
  late int _channelIndex;
  late List<HomeRow> _categories;
  /// Generación de carga: evita que una respuesta vieja pise la categoría actual.
  int _channelsLoadGen = 0;

  /// Canales de la categoría actual (carga progresiva, igual que Live page).
  List<ContentItem> _visibleChannels = [];
  int _channelPage = 0;
  bool _loadingChannels = false;
  bool _hasMoreChannels = true;
  final _channelScroll = ScrollController();
  static const _kPageSize = 30;

  Timer? _hideTimer;
  Timer? _clockTimer;
  Rect? _windowBoundsBeforeSpecial;

  List<ContentItem> get _channels => _visibleChannels;

  HomeRow? get _currentCategory {
    if (_categories.isEmpty ||
        _catIndex < 0 ||
        _catIndex >= _categories.length) {
      return null;
    }
    return _categories[_catIndex];
  }

  StreamServer? get _current =>
      _servers.isEmpty ? null : _servers[_serverIndex.clamp(0, _servers.length - 1)];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _title = widget.title;
    _contentId = widget.contentId;
    _poster = widget.poster;
    _backdrop = widget.backdrop;
    _logo = widget.logo;
    _contentType = widget.contentType;
    _categories = List.of(widget.categories);
    _catIndex = widget.initialCategoryIndex.clamp(
        0, (_categories.isEmpty ? 0 : _categories.length - 1));
    _channelIndex = widget.initialChannelIndex;
    _servers = List.of(widget.servers);
    _channelScroll.addListener(_onChannelScroll);
    // Si la categoría inicial ya trae items (desde Live page), úsalos.
    final initialCat = _currentCategory;
    if (initialCat != null && initialCat.items.isNotEmpty) {
      _visibleChannels = List.of(initialCat.items);
      _hasMoreChannels = false;
      _channelPage = 1;
      if (_channelIndex >= _visibleChannels.length) _channelIndex = 0;
    } else {
      unawaited(_resetAndLoadChannels());
    }
    _tickClock();
    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _tickClock());
    if (widget.loadRepo != null &&
        _contentId != null &&
        _contentId!.isNotEmpty) {
      unawaited(_loadStreamsThenPlay());
    } else if (_servers.isNotEmpty) {
      unawaited(_startCurrent());
    } else {
      _loading = false;
      _error = 'Sin URL de transmisión';
    }
  }

  void _tickClock() {
    final n = DateTime.now();
    final h = n.hour.toString().padLeft(2, '0');
    final m = n.minute.toString().padLeft(2, '0');
    if (!mounted) return;
    setState(() => _clock = '$h:$m');
  }

  Future<void> _loadStreamsThenPlay() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        _contentId!,
        type: _contentType,
      );
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No hay fuentes de transmisión';
        });
        return;
      }
      _servers = list;
      _serverIndex = 0;
      await _startCurrent();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Error: $e';
        });
      }
    }
  }

  Future<void> _startCurrent() async {
    final s = _current;
    if (s == null) {
      setState(() {
        _loading = false;
        _error = 'Sin URL';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _buffering = true;
    });
    try {
      await _disposePlayer();
      final player = Player(
        configuration: PlayerConfiguration(
          title: _title,
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      _player = player;
      _video = VideoController(player);
      _subs.add(player.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }));
      _subs.add(player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }));
      final hdrs = Map<String, String>.from(s.headers);
      hdrs.putIfAbsent(
        'User-Agent',
        () =>
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
      );
      await player.setVolume(_volume);
      await player.open(Media(s.url, httpHeaders: hdrs), play: true);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _buffering = false;
        _playing = true;
      });
      _scheduleHide();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo reproducir: $e';
      });
    }
  }

  Future<void> _switchChannel(ContentItem item, int cat, int ch) async {
    setState(() {
      _catIndex = cat;
      _channelIndex = ch;
      _contentId = item.id;
      _title = item.currentProgram != null
          ? '${item.title} · ${item.currentProgram}'
          : item.title;
      _poster = item.poster;
      _backdrop = item.backdrop;
      _logo = item.logo;
      _contentType = item.type;
      _showGuide = false;
    });
    if (widget.loadRepo != null) await _loadStreamsThenPlay();
  }

  Future<void> _toggleFav() async {
    final id = _contentId;
    final repoId = widget.repoId;
    if (id == null || repoId == null) return;
    await context.read<LibraryService>().toggleFavorite(
          repoId: repoId,
          contentId: id,
          title: _title,
          poster: _logo ?? _poster,
          type: _contentType.isNotEmpty ? _contentType : 'channel',
        );
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _showGuide) return;
      setState(() => _showControls = false);
    });
  }

  void _onActivity() {
    if (!_showControls) setState(() => _showControls = true);
    _scheduleHide();
  }

  void _onScrollVolume(PointerScrollEvent e) {
    final dy = e.scrollDelta.dy;
    final next = (_volume + (dy < 0 ? 5 : -5)).clamp(0.0, 100.0);
    setState(() => _volume = next);
    unawaited(_player?.setVolume(next) ?? Future.value());
    _onActivity();
  }

  Future<void> _toggleFullscreen() async {
    try {
      if (_isFullscreen) {
        await windowManager.setFullScreen(false);
        setState(() => _isFullscreen = false);
      } else {
        if (_isPip) await _exitPip(restoreFullscreen: false);
        await windowManager.setFullScreen(true);
        setState(() => _isFullscreen = true);
      }
      _onActivity();
    } catch (e) {
      debugPrint('[LiveDesktop] fullscreen: $e');
      try {
        setState(() => _isFullscreen = !_isFullscreen);
      } catch (_) {}
    }
  }

  Future<void> _togglePip() async {
    try {
      if (_isPip) {
        await _exitPip();
      } else {
        try {
          _windowBoundsBeforeSpecial = await windowManager.getBounds();
        } catch (_) {}
        if (_isFullscreen) {
          await windowManager.setFullScreen(false);
          setState(() => _isFullscreen = false);
        }
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setSize(const Size(420, 260));
        await windowManager.setAlignment(Alignment.bottomRight);
        setState(() {
          _isPip = true;
          _showGuide = false;
          _showControls = true;
        });
      }
    } catch (e) {
      debugPrint('[LiveDesktop] pip: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PiP requiere package window_manager'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _exitPip({bool restoreFullscreen = false}) async {
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(800, 500));
      if (_windowBoundsBeforeSpecial != null) {
        await windowManager.setBounds(_windowBoundsBeforeSpecial!);
      } else {
        await windowManager.setSize(const Size(1280, 720));
        await windowManager.center();
      }
      setState(() => _isPip = false);
      if (restoreFullscreen) {
        await windowManager.setFullScreen(true);
        setState(() => _isFullscreen = true);
      }
    } catch (e) {
      debugPrint('[LiveDesktop] exit pip: $e');
      setState(() => _isPip = false);
    }
  }

  Future<void> _disposePlayer() async {
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    final p = _player;
    _player = null;
    _video = null;
    try {
      await p?.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _channelScroll.removeListener(_onChannelScroll);
    _channelScroll.dispose();
    _hideTimer?.cancel();
    _clockTimer?.cancel();
    if (_isPip) {
      unawaited(() async {
        try {
          await windowManager.setAlwaysOnTop(false);
          await windowManager.setMinimumSize(const Size(800, 500));
          if (_windowBoundsBeforeSpecial != null) {
            await windowManager.setBounds(_windowBoundsBeforeSpecial!);
          }
        } catch (_) {}
      }());
    }
    if (_isFullscreen) {
      unawaited(windowManager.setFullScreen(false));
    }
    unawaited(_disposePlayer());
    WakelockPlus.disable();
    super.dispose();
  }

  void _onChannelScroll() {
    if (!_hasMoreChannels || _loadingChannels) return;
    if (!_channelScroll.hasClients) return;
    final max = _channelScroll.position.maxScrollExtent;
    final pos = _channelScroll.position.pixels;
    if (pos >= max - 160) {
      unawaited(_loadMoreChannels());
    }
  }

  Future<void> _resetAndLoadChannels() async {
    _channelPage = 0;
    _visibleChannels = [];
    _hasMoreChannels = true;
    await _loadMoreChannels();
  }

  Future<void> _selectGuideCategory(int i) async {
    if (i < 0 || i >= _categories.length) return;
    if (i == _catIndex && _visibleChannels.isNotEmpty) return;
    _channelsLoadGen++;
    final gen = _channelsLoadGen;
    setState(() {
      _catIndex = i;
      _channelIndex = 0;
      _visibleChannels = [];
      _channelPage = 0;
      _hasMoreChannels = true;
      _loadingChannels = false;
    });
    await _loadMoreChannels(forceGen: gen);
    // Al cambiar de categoría, como en Live page: seleccionar y reproducir el 1.º canal.
    if (!mounted || gen != _channelsLoadGen) return;
    if (_visibleChannels.isNotEmpty) {
      final first = _visibleChannels[0];
      setState(() {
        _channelIndex = 0;
        _contentId = first.id;
        _title = first.currentProgram != null && first.currentProgram!.isNotEmpty
            ? '${first.title} · ${first.currentProgram}'
            : first.title;
        _poster = first.poster;
        _backdrop = first.backdrop;
        _logo = first.logo;
        _contentType = first.type.isNotEmpty ? first.type : 'channel';
      });
      if (widget.loadRepo != null) {
        unawaited(_loadStreamsThenPlay());
      }
    }
  }

  Future<void> _loadMoreChannels({int? forceGen}) async {
    if (_loadingChannels || !_hasMoreChannels) return;
    final cat = _currentCategory;
    final gen = forceGen ?? _channelsLoadGen;
    if (cat == null) {
      setState(() {
        _hasMoreChannels = false;
        _loadingChannels = false;
      });
      return;
    }

    if (cat.id == 'favorites') {
      if (gen != _channelsLoadGen) return;
      setState(() {
        _visibleChannels = List.from(cat.items);
        _hasMoreChannels = false;
        _loadingChannels = false;
        _channelPage = 1;
      });
      return;
    }

    // Preferir carga por API (igual que Live page). Si no hay repo, pagina items locales.
    final repo = widget.loadRepo;
    setState(() => _loadingChannels = true);
    final nextPage = _channelPage + 1;

    try {
      if (repo != null) {
        final page = await ContentService.instance.loadLiveCategory(
          repo,
          categoryId: cat.id,
          catalogId: cat.catalogId,
          page: nextPage,
          fallbackItems: cat.items,
        );
        if (!mounted || gen != _channelsLoadGen) return;
        setState(() {
          final existing = _visibleChannels.map((e) => e.id).toSet();
          final fresh =
              page.items.where((e) => !existing.contains(e.id)).toList();
          // Si es la 1.ª página de una categoría nueva y la API no trajo nada,
          // usar items embebidos de la categoría (si existen).
          if (fresh.isEmpty && nextPage == 1 && cat.items.isNotEmpty) {
            _visibleChannels = List.from(cat.items);
            _channelPage = 1;
            _hasMoreChannels = false;
          } else {
            _visibleChannels = [..._visibleChannels, ...fresh];
            _channelPage = nextPage;
            _hasMoreChannels =
                page.hasMore && (page.items.isNotEmpty || nextPage == 1);
            if (page.items.isEmpty && nextPage > 1) _hasMoreChannels = false;
          }
          _loadingChannels = false;
        });
      } else {
        final all = cat.items;
        final start = _channelPage * _kPageSize;
        if (start >= all.length) {
          if (gen != _channelsLoadGen) return;
          setState(() {
            _hasMoreChannels = false;
            _loadingChannels = false;
          });
          return;
        }
        final end = (start + _kPageSize).clamp(0, all.length);
        if (gen != _channelsLoadGen) return;
        setState(() {
          _visibleChannels = [..._visibleChannels, ...all.sublist(start, end)];
          _channelPage = nextPage;
          _hasMoreChannels = end < all.length;
          _loadingChannels = false;
        });
      }
    } catch (e) {
      debugPrint('[LiveDesktop] load channels ${cat.id} p$nextPage: $e');
      if (!mounted || gen != _channelsLoadGen) return;
      final all = cat.items;
      final start = _channelPage * _kPageSize;
      if (start >= all.length) {
        setState(() {
          _hasMoreChannels = false;
          _loadingChannels = false;
        });
        return;
      }
      final end = (start + _kPageSize).clamp(0, all.length);
      setState(() {
        _visibleChannels = [..._visibleChannels, ...all.sublist(start, end)];
        _channelPage = nextPage;
        _hasMoreChannels = end < all.length;
        _loadingChannels = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repoId = widget.repoId ?? '';
    final isFav = _contentId != null &&
        repoId.isNotEmpty &&
        context.watch<LibraryService>().isFavorite(repoId, _contentId!);

    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_showGuide) {
              setState(() => _showGuide = false);
              return;
            }
            if (_isPip) {
              unawaited(_exitPip());
              return;
            }
            if (_isFullscreen) {
              unawaited(_toggleFullscreen());
              return;
            }
            Navigator.of(context).maybePop();
          },
          const SingleActivator(LogicalKeyboardKey.keyG): () {
            if (_isPip) return;
            if (_categories.isNotEmpty) {
              final opening = !_showGuide;
              setState(() => _showGuide = opening);
              if (opening &&
                  _visibleChannels.isEmpty &&
                  !_loadingChannels) {
                unawaited(_resetAndLoadChannels());
              }
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyF): () {
            unawaited(_toggleFullscreen());
          },
        },
        child: Focus(
          autofocus: true,
          child: Listener(
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) _onScrollVolume(signal);
            },
            child: MouseRegion(
              onHover: (_) => _onActivity(),
              child: GestureDetector(
                onTap: () {
                  if (_showGuide) return;
                  setState(() => _showControls = !_showControls);
                  if (_showControls) _scheduleHide();
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_video != null)
                      Video(
                        controller: _video!,
                        controls: NoVideoControls,
                        fit: BoxFit.contain,
                      )
                    else if ((_backdrop ?? _poster) != null)
                      CachedNetworkImage(
                        imageUrl: (_backdrop ?? _poster)!,
                        fit: BoxFit.cover,
                        color: Colors.black54,
                        colorBlendMode: BlendMode.darken,
                      ),
                    if (_loading || _buffering)
                      const Center(
                        child: CircularProgressIndicator(
                            color: accent, strokeWidth: 3),
                      ),
                    if (_error != null)
                      Center(
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.white70)),
                      ),
                    if (_isPip && _showControls) _pipExitButton(),
                    if (!_isPip && _showControls && _error == null) ...[
                      _topOverlays(),
                      _bottomControls(isFav),
                    ],
                    if (!_isPip && _showGuide) _guide(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Badge EN VIVO (izq) + reloj del sistema (der) — se ocultan con controles.
  Widget _topOverlays() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'EN VIVO',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                _clock,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                  shadows: [
                    Shadow(color: Colors.black87, blurRadius: 6),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pipExitButton() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 10,
      child: Center(
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => unawaited(_exitPip()),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.picture_in_picture_alt_rounded,
                      color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Salir de PiP',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomControls(bool isFav) {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x66000000),
              Colors.transparent,
              Color(0xCC000000),
            ],
            stops: [0, 0.35, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 44, 12, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${_volume.round()}%',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Row(
                  children: [
                    if (_categories.isNotEmpty)
                      _ctrlBtn(
                        icon: Icons.list_alt_rounded,
                        label: 'Canales',
                        onTap: () {
                          setState(() {
                            _showGuide = true;
                            _showControls = false;
                          });
                          if (_visibleChannels.isEmpty && !_loadingChannels) {
                            unawaited(_resetAndLoadChannels());
                          }
                        },
                      ),
                    if (_categories.isNotEmpty) const SizedBox(width: 10),
                    _ctrlBtn(
                      icon: isFav ? Icons.favorite : Icons.favorite_border,
                      label: isFav ? 'Favorito' : 'Fav',
                      filled: isFav,
                      onTap: () => unawaited(_toggleFav()),
                    ),
                    const SizedBox(width: 10),
                    _ctrlBtn(
                      icon: Icons.picture_in_picture_alt_rounded,
                      label: 'PiP',
                      onTap: () => unawaited(_togglePip()),
                    ),
                    const SizedBox(width: 10),
                    _ctrlBtn(
                      icon: _isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      label: _isFullscreen ? 'Salir' : 'Pantalla completa',
                      filled: true,
                      onTap: () => unawaited(_toggleFullscreen()),
                    ),
                    const Spacer(),
                    Text(
                      _playing ? 'EN EMISIÓN' : 'CARGANDO…',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ctrlBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: filled ? accent : Colors.white24,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _guide() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.72),
        child: Row(
          children: [
            SizedBox(
              width: 220,
              child: Material(
                color: const Color(0xFF0E1218),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('Categorías',
                                style: TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w700)),
                          ),
                          IconButton(
                            tooltip: 'Cerrar guía',
                            icon: const Icon(Icons.close,
                                color: Colors.white54, size: 20),
                            onPressed: () =>
                                setState(() => _showGuide = false),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _categories.length,
                        itemBuilder: (_, i) {
                          final sel = i == _catIndex;
                          return ListTile(
                            selected: sel,
                            selectedTileColor: accent.withValues(alpha: 0.35),
                            title: Text(
                              _categories[i].title,
                              style: TextStyle(
                                color: sel ? Colors.white : Colors.white70,
                                fontWeight:
                                    sel ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            onTap: () => unawaited(_selectGuideCategory(i)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 340,
              child: Material(
                color: const Color(0xFF12161E),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Text(
                        _loadingChannels && _channels.isEmpty
                            ? 'Cargando canales…'
                            : _channels.isEmpty
                                ? 'Canales'
                                : '${_channels.length} canales',
                        style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: _loadingChannels && _channels.isEmpty
                          ? const Center(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: accent),
                              ),
                            )
                          : _channels.isEmpty
                              ? const Center(
                                  child: Text('Sin canales',
                                      style: TextStyle(color: Colors.white38)))
                              : ListView.builder(
                                  controller: _channelScroll,
                                  itemCount: _channels.length +
                                      (_loadingChannels ? 1 : 0),
                                  itemBuilder: (_, i) {
                                    if (i >= _channels.length) {
                                      return const Padding(
                                        padding:
                                            EdgeInsets.symmetric(vertical: 16),
                                        child: Center(
                                          child: SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2, color: accent),
                                          ),
                                        ),
                                      );
                                    }
                                    final item = _channels[i];
                                    final sel = i == _channelIndex;
                                    return ListTile(
                                      selected: sel,
                                      selectedTileColor:
                                          accent.withValues(alpha: 0.35),
                                      leading: ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: SizedBox(
                                          width: 48,
                                          height: 32,
                                          child: (item.logo ?? item.poster) !=
                                                  null
                                              ? CachedNetworkImage(
                                                  imageUrl: (item.logo ??
                                                      item.poster)!,
                                                  fit: BoxFit.cover,
                                                )
                                              : Container(color: Colors.white12),
                                        ),
                                      ),
                                      title: Text(
                                        item.title,
                                        style: TextStyle(
                                          color: sel
                                              ? Colors.white
                                              : Colors.white70,
                                          fontWeight: sel
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                      onTap: () => unawaited(
                                          _switchChannel(item, _catIndex, i)),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
              ),
            ),
            // Click fuera de las pestañas → cierra el panel
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showGuide = false),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}