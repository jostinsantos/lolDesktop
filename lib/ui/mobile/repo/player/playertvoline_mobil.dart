import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../../data/models/repo_manifest.dart';
import '../../../../data/models/stream_server.dart';
import '../../../../data/services/content_service.dart';

/// Player de canales en vivo (móvil). Solo media_kit.
/// Sin barra de progreso ni seek (stream continuo).
class PlayerMobileOnlinePage extends StatefulWidget {
  final String title;
  final String? repoId;
  final String? contentId;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final String contentType;
  final List<StreamServer> servers;
  final int initialServerIndex;
  final InstalledRepo? loadRepo;
  final String preferredLanguage;
  final Map<String, String>? headers;
  final String url;

  const PlayerMobileOnlinePage({
    super.key,
    required this.title,
    this.repoId,
    this.contentId,
    this.poster,
    this.backdrop,
    this.logo,
    this.contentType = 'channel',
    this.servers = const [],
    this.initialServerIndex = 0,
    this.loadRepo,
    this.preferredLanguage = '',
    this.headers,
    this.url = '',
  });

  @override
  State<PlayerMobileOnlinePage> createState() => _PlayerMobileOnlinePageState();
}

class _PlayerMobileOnlinePageState extends State<PlayerMobileOnlinePage> {
  static const accent = Color(0xFFE50914);

  Player? _player;
  VideoController? _video;
  final List<StreamSubscription> _subs = [];

  bool _loading = true;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  bool _showControls = true;
  bool _showServers = false;
  bool _showAudio = false;

  late List<StreamServer> _servers;
  late int _serverIndex;
  List<AudioTrack> _audioTracks = [];
  AudioTrack? _selectedAudio;

  final FocusNode _rootFocus = FocusNode();
  final FocusNode _playFocus = FocusNode();
  Timer? _hideTimer;
  Timer? _wakelockTimer;

  StreamServer? get _current =>
      _servers.isEmpty ? null : _servers[_serverIndex.clamp(0, _servers.length - 1)];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepAwake();
    _servers = List.of(widget.servers);
    if (_servers.isEmpty && widget.url.isNotEmpty) {
      _servers = [
        StreamServer(
          url: widget.url,
          name: 'Principal',
          headers: widget.headers ?? {},
          isHls: widget.url.toLowerCase().contains('.m3u8'),
        ),
      ];
    }
    _serverIndex =
        widget.initialServerIndex.clamp(0, (_servers.length - 1).clamp(0, 9999));

    if (widget.loadRepo != null &&
        widget.contentId != null &&
        widget.contentId!.isNotEmpty) {
      _loadStreamsThenPlay();
    } else {
      _startCurrent();
    }
  }

  void _keepAwake() {
    WakelockPlus.enable();
    _wakelockTimer?.cancel();
    _wakelockTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted) return;
      try {
        if (_playing) await WakelockPlus.enable();
      } catch (_) {}
    });
  }

  Future<void> _loadStreamsThenPlay() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        widget.contentId!,
        type: widget.contentType,
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
      _serverIndex = _pickPreferred(list);
      await _startCurrent();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Error cargando transmisión: $e';
        });
      }
    }
  }

  int _pickPreferred(List<StreamServer> list) {
    if (list.isEmpty) return 0;
    final pref = widget.preferredLanguage.trim().toLowerCase();
    if (pref.isEmpty) return 0;
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      if (lang.contains(pref) || pref.contains(lang)) return i;
    }
    return 0;
  }

  Future<void> _startCurrent() async {
    final s = _current;
    if (s == null) {
      setState(() {
        _loading = false;
        _error = 'Sin URL de transmisión';
      });
      return;
    }
    await _openUrl(s.url, s.headers);
  }

  Future<void> _openUrl(String url, Map<String, String> headers) async {
    setState(() {
      _loading = true;
      _error = null;
      _buffering = true;
      _audioTracks = [];
      _selectedAudio = null;
    });

    try {
      await _disposePlayer();
      final player = Player(
        configuration: PlayerConfiguration(
          title: widget.title,
          // buffer más generoso para live
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      final video = VideoController(player);
      _player = player;
      _video = video;

      _subs.add(player.stream.playing.listen((v) {
        if (!mounted) return;
        setState(() => _playing = v);
      }));
      _subs.add(player.stream.buffering.listen((v) {
        if (!mounted) return;
        setState(() => _buffering = v);
      }));
      _subs.add(player.stream.error.listen((e) {
        if (!mounted || e == null || e.toString().isEmpty) return;
        debugPrint('[LiveTV] error: $e');
        // Si falla, intentar siguiente servidor
        unawaited(_tryNextServerOnError(e.toString()));
      }));
      _subs.add(player.stream.tracks.listen((tracks) async {
        if (!mounted) return;
        final audios = tracks.audio;
        if (audios.isEmpty) return;
        setState(() {
          _audioTracks = List.of(audios);
        });
        await _selectBestAudio(audios);
      }));

      final hdrs = <String, String>{};
      if (headers.isNotEmpty) hdrs.addAll(headers);
      if (widget.headers != null) {
        for (final e in widget.headers!.entries) {
          hdrs.putIfAbsent(e.key, () => e.value);
        }
      }
      // Headers típicos de IPTV
      hdrs.putIfAbsent(
          'User-Agent',
          () =>
              'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36');
      hdrs.putIfAbsent('Connection', () => 'keep-alive');

      await player.open(
        Media(url, httpHeaders: hdrs),
        play: true,
      );

      if (!mounted) return;
      setState(() {
        _loading = false;
        _buffering = false;
        _playing = true;
      });
      _scheduleHide();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playFocus.requestFocus();
      });
    } catch (e) {
      debugPrint('[LiveTV] open failed: $e');
      if (!mounted) return;
      final advanced = await _tryNextServerOnError(e.toString());
      if (!advanced && mounted) {
        setState(() {
          _loading = false;
          _error = 'No se pudo reproducir: $e';
        });
      }
    }
  }

  Future<bool> _tryNextServerOnError(String err) async {
    if (_servers.length <= 1) return false;
    final next = (_serverIndex + 1) % _servers.length;
    if (next == widget.initialServerIndex && _serverIndex != next) {
      // ya dimos la vuelta
    }
    // Evitar bucle infinito: solo avanzar una vez por error de apertura
    if (_serverIndex + 1 >= _servers.length) return false;
    _serverIndex = _serverIndex + 1;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cambiando fuente… (${_serverIndex + 1}/${_servers.length})'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    await _startCurrent();
    return true;
  }

  Future<void> _selectBestAudio(List<AudioTrack> audios) async {
    if (_player == null || audios.isEmpty) return;
    final pref = widget.preferredLanguage.trim().toLowerCase();
    AudioTrack? pick;
    if (pref.isNotEmpty) {
      for (final t in audios) {
        final lang = (t.language ?? t.title ?? t.id).toLowerCase();
        if (lang.contains(pref) || pref.contains(lang)) {
          pick = t;
          break;
        }
      }
    }
    pick ??= audios.first;
    try {
      await _player!.setAudioTrack(pick);
      if (mounted) setState(() => _selectedAudio = pick);
    } catch (e) {
      debugPrint('[LiveTV] setAudioTrack: $e');
    }
  }

  Future<void> _switchServer(int i) async {
    if (i < 0 || i >= _servers.length) return;
    setState(() {
      _serverIndex = i;
      _showServers = false;
    });
    await _startCurrent();
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null) return;
    if (_playing) {
      await p.pause();
    } else {
      await p.play();
    }
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_showServers || _showAudio) return;
      setState(() => _showControls = false);
      _rootFocus.requestFocus();
    });
  }

  void _showUi() {
    setState(() => _showControls = true);
    _scheduleHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
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
    if (p != null) {
      try {
        await p.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _wakelockTimer?.cancel();
    _rootFocus.dispose();
    _playFocus.dispose();
    unawaited(_disposePlayer());
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack) {
      if (_showServers || _showAudio) {
        setState(() {
          _showServers = false;
          _showAudio = false;
        });
        return KeyEventResult.handled;
      }
      if (_showControls) {
        setState(() => _showControls = false);
        return KeyEventResult.handled;
      }
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (!_showControls &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _showUi();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !(_showServers || _showAudio || _showControls),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showServers || _showAudio) {
          setState(() {
            _showServers = false;
            _showAudio = false;
          });
          return;
        }
        if (_showControls) {
          setState(() => _showControls = false);
          return;
        }
        Navigator.of(context).maybePop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onRootKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_showControls) {
                setState(() => _showControls = false);
              } else {
                _showUi();
              }
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
                else if (widget.backdrop != null || widget.poster != null)
                  CachedNetworkImage(
                    imageUrl: (widget.backdrop ?? widget.poster)!,
                    fit: BoxFit.cover,
                    color: Colors.black54,
                    colorBlendMode: BlendMode.darken,
                  ),
                if (_loading || _buffering)
                  const Center(
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        color: accent,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                if (_error != null) _errorView(),
                if (_showControls && _error == null) _controlsOverlay(),
                if (_showServers) _serversPanel(),
                if (_showAudio) _audioPanel(),
                // Badge EN VIVO
                Positioned(
                  top: 16,
                  left: 20,
                  child: SafeArea(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
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
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_tethering_error, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              children: [
                Focus(
                  autofocus: true,
                  onKeyEvent: (n, e) {
                    if (e is! KeyDownEvent) return KeyEventResult.ignored;
                    if (e.logicalKey == LogicalKeyboardKey.select ||
                        e.logicalKey == LogicalKeyboardKey.enter) {
                      unawaited(_startCurrent());
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Builder(builder: (ctx) {
                    final f = Focus.of(ctx).hasFocus;
                    return GestureDetector(
                      onTap: () => unawaited(_startCurrent()),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                        decoration: BoxDecoration(
                          color: f ? Colors.white : accent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: f ? accent : Colors.transparent, width: 2),
                        ),
                        child: Text(
                          'Reintentar',
                          style: TextStyle(
                            color: f ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                if (_servers.length > 1)
                  GestureDetector(
                    onTap: () {
                      final n = (_serverIndex + 1) % _servers.length;
                      unawaited(_switchServer(n));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Otra fuente',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlsOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x99000000),
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
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      const SizedBox(width: 72), // espacio badge EN VIVO
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_current != null)
                        Text(
                          _current!.name,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                // Sin barra de progreso (live)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Row(
                    children: [
                      _tvBtn(
                        focusNode: _playFocus,
                        icon: _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        onTap: () => unawaited(_togglePlay()),
                      ),
                      const SizedBox(width: 12),
                      if (_servers.length > 1)
                        _tvBtn(
                          icon: Icons.dns_rounded,
                          onTap: () => setState(() {
                            _showServers = true;
                            _showAudio = false;
                          }),
                        ),
                      if (_servers.length > 1) const SizedBox(width: 12),
                      if (_audioTracks.length > 1)
                        _tvBtn(
                          icon: Icons.audiotrack_rounded,
                          onTap: () => setState(() {
                            _showAudio = true;
                            _showServers = false;
                          }),
                        ),
                      const Spacer(),
                      Text(
                        _playing ? 'EN EMISIÓN' : 'PAUSA',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tvBtn({
    FocusNode? focusNode,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (ctx) {
        final f = Focus.of(ctx).hasFocus;
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: f ? Colors.white : Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: f ? accent : Colors.white24,
                width: f ? 2.5 : 1,
              ),
            ),
            child: Icon(icon, color: f ? Colors.black : Colors.white, size: 26),
          ),
        );
      }),
    );
  }

  Widget _serversPanel() {
    return _sidePanel(
      title: 'Fuentes / Servidores',
      onClose: () => setState(() => _showServers = false),
      children: [
        for (var i = 0; i < _servers.length; i++)
          ListTile(
            autofocus: i == _serverIndex,
            selected: i == _serverIndex,
            selectedTileColor: Colors.white10,
            title: Text(_servers[i].name,
                style: TextStyle(
                    color: i == _serverIndex ? accent : Colors.white,
                    fontWeight: FontWeight.w600)),
            subtitle: Text(
              [
                if ((_servers[i].quality ?? '').isNotEmpty) _servers[i].quality!,
                if ((_servers[i].language ?? '').isNotEmpty)
                  _servers[i].language!,
              ].join(' · '),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: i == _serverIndex
                ? const Icon(Icons.check_circle, color: accent)
                : null,
            onTap: () => unawaited(_switchServer(i)),
          ),
      ],
    );
  }

  Widget _audioPanel() {
    return _sidePanel(
      title: 'Audio',
      onClose: () => setState(() => _showAudio = false),
      children: [
        for (final t in _audioTracks)
          ListTile(
            selected: _selectedAudio?.id == t.id,
            selectedTileColor: Colors.white10,
            leading: Icon(Icons.audiotrack,
                color: _selectedAudio?.id == t.id ? accent : Colors.white54),
            title: Text(
              t.title?.isNotEmpty == true
                  ? t.title!
                  : (t.language ?? t.id),
              style: TextStyle(
                color: _selectedAudio?.id == t.id ? accent : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () async {
              try {
                await _player?.setAudioTrack(t);
                setState(() {
                  _selectedAudio = t;
                  _showAudio = false;
                });
              } catch (_) {}
            },
          ),
      ],
    );
  }

  Widget _sidePanel({
    required String title,
    required VoidCallback onClose,
    required List<Widget> children,
  }) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          color: Colors.black54,
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () {},
            child: Material(
              color: const Color(0xF0141A22),
              child: SafeArea(
                child: SizedBox(
                  width: 360,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(title,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700)),
                            ),
                            IconButton(
                              onPressed: onClose,
                              icon: const Icon(Icons.close,
                                  color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: ListView(children: children)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
