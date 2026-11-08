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

/// Un programa de la guía (EPG) de un canal.
class EpgProgram {
  final String title;
  final DateTime start;
  final DateTime end;
  final String description;

  const EpgProgram({
    required this.title,
    required this.start,
    required this.end,
    this.description = '',
  });

  bool isOn(DateTime now) => !now.isBefore(start) && now.isBefore(end);

  /// Construye un programa desde un JSON del repo (acepta varios nombres de
  /// campo y formatos: ISO-8601, epoch en segundos/ms y XMLTV).
  static EpgProgram? fromMap(Map m) {
    String? pickS(List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      return null;
    }

    dynamic pickD(List<String> keys) {
      for (final k in keys) {
        if (m[k] != null) return m[k];
      }
      return null;
    }

    final title = pickS(['title', 'name', 'programme', 'program']);
    final start = _parse(pickD(['start', 'start_time', 'startTime', 'begin']));
    final end = _parse(pickD(['end', 'stop', 'end_time', 'endTime']));
    if (title == null || start == null || end == null) return null;
    return EpgProgram(
      title: title,
      start: start,
      end: end,
      description:
          pickS(['description', 'desc', 'synopsis', 'summary']) ?? '',
    );
  }

  static DateTime? _parse(dynamic v) {
    if (v == null) return null;
    if (v is num) {
      final n = v.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        n < 100000000000 ? n * 1000 : n,
        isUtc: true,
      ).toLocal();
    }
    final s = v.toString().trim();
    final asInt = int.tryParse(s);
    if (asInt != null && s.length != 14) return _parse(asInt);
    final x = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-]\d{4})?$')
        .firstMatch(s);
    if (x != null) {
      var d = DateTime.utc(
        int.parse(x.group(1)!),
        int.parse(x.group(2)!),
        int.parse(x.group(3)!),
        int.parse(x.group(4)!),
        int.parse(x.group(5)!),
        int.parse(x.group(6)!),
      );
      final tz = x.group(7);
      if (tz != null) {
        final sign = tz.startsWith('-') ? -1 : 1;
        final h = int.parse(tz.substring(1, 3));
        final mi = int.parse(tz.substring(3, 5));
        d = d.subtract(Duration(minutes: sign * (h * 60 + mi)));
      }
      return d.toLocal();
    }
    return DateTime.tryParse(s)?.toLocal();
  }
}

/// Player de canales en vivo (TV). Solo media_kit.
/// Sin barra de progreso, sin pausa (stream continuo).
class PlayerTvOnlinePage extends StatefulWidget {
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

  /// Guía de programación ya cargada (opcional).
  final List<EpgProgram> epg;

  /// Cargador de guía (opcional). Se llama una vez al abrir el canal.
  /// Si el repo no trae guía, devuelve lista vacía y no se muestra nada.
  final Future<List<EpgProgram>> Function()? epgLoader;

  const PlayerTvOnlinePage({
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
    this.epg = const [],
    this.epgLoader,
  });

  @override
  State<PlayerTvOnlinePage> createState() => _PlayerTvOnlinePageState();
}

class _PlayerTvOnlinePageState extends State<PlayerTvOnlinePage>
    with WidgetsBindingObserver {
  static const accent = Color(0xFFE50914);
  static const _ua =
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36';

  late final Player _player;
  late final VideoController _video;
  late final Widget _videoView;
  late final Future<void> _tuned;
  final List<StreamSubscription> _subs = [];

  bool _loading = true;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  bool _showControls = true;
  bool _showServers = false;
  bool _showAudio = false;
  bool _showEpg = false;

  late List<StreamServer> _servers;
  late int _serverIndex;
  List<AudioTrack> _audioTracks = [];
  AudioTrack? _selectedAudio;
  List<EpgProgram> _epg = [];

  // --- Control de salud del stream ---
  int _gen = 0; // invalida callbacks de aperturas anteriores
  int _failures = 0;
  bool _started = false;
  bool _closing = false;
  bool _fetching = false;
  bool _audioPicked = false;
  bool _wasPaused = false;
  DateTime _lastRecover = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _openedAt = DateTime.now();
  DateTime _lastProgressAt = DateTime.now();
  DateTime? _bufferingSince;
  Duration _lastPos = Duration.zero;
  bool _everAdvanced = false;
  Timer? _watchdog;

  final FocusNode _rootFocus = FocusNode();
  final FocusNode _btnFocus = FocusNode();
  Timer? _hideTimer;

  bool get _anyPanel => _showServers || _showAudio || _showEpg;

  StreamServer? get _current => _servers.isEmpty
      ? null
      : _servers[_serverIndex.clamp(0, _servers.length - 1).toInt()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();

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
    _serverIndex = widget.initialServerIndex
        .clamp(0, (_servers.length - 1).clamp(0, 9999).toInt())
        .toInt();
    _epg = _sortedEpg(widget.epg);

    _initPlayer();
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) => _watchdogTick());
    unawaited(_loadEpg());

    if (widget.loadRepo != null &&
        widget.contentId != null &&
        widget.contentId!.isNotEmpty) {
      unawaited(_loadStreamsThenPlay());
    } else {
      unawaited(_openCurrent());
    }
  }

  // ---------------------------------------------------------------------------
  // Player: se crea UNA sola vez y se reutiliza al cambiar de fuente
  // (recrearlo en cada cambio es lo que causa parpadeos y crashes de textura).
  // ---------------------------------------------------------------------------
  void _initPlayer() {
    _player = Player(
      configuration: PlayerConfiguration(
        title: widget.title,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _videoView = RepaintBoundary(
      child: Video(
        controller: _video,
        controls: NoVideoControls,
        fit: BoxFit.contain,
        fill: Colors.black,
        resumeUponEnteringForegroundMode: true,
      ),
    );

    _subs.add(_player.stream.playing.listen((v) {
      if (!mounted || v == _playing) return;
      setState(() => _playing = v);
    }));
    _subs.add(_player.stream.buffering.listen((v) {
      _bufferingSince = v ? (_bufferingSince ?? DateTime.now()) : null;
      if (!mounted || v == _buffering) return;
      setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.position.listen((pos) {
      if (pos != _lastPos) {
        _lastPos = pos;
        _lastProgressAt = DateTime.now();
        if (pos > Duration.zero) {
          _everAdvanced = true;
          _started = true;
        }
      }
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (!mounted || e.toString().isEmpty) return;
      debugPrint('[LiveTV] error: $e');
      unawaited(_recover('error: $e'));
    }));
    _subs.add(_player.stream.tracks.listen((tracks) {
      if (!mounted) return;
      final audios = tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      if (audios.isEmpty) return;
      if (audios.length != _audioTracks.length) {
        setState(() => _audioTracks = audios);
      }
      final stillValid = _selectedAudio != null &&
          audios.any((t) => t.id == _selectedAudio!.id);
      if (!_audioPicked || !stillValid) {
        _audioPicked = true;
        unawaited(_selectBestAudio(audios));
      }
    }));

    _tuned = _tune(_player);
  }

  /// Ajustes de mpv para IPTV: reconexión automática, downmix a estéreo
  /// (evita "sin audio" por AC3/EAC3/5.1), tolerancia a errores y
  /// sincronía por audio con descarte de frames para no trabarse.
  Future<void> _tune(Player p) async {
    final props = <String, String>{
      'cache': 'yes',
      'cache-secs': '30',
      'demuxer-max-bytes': '48MiB',
      'demuxer-max-back-bytes': '8MiB',
      'demuxer-readahead-secs': '20',
      'network-timeout': '15',
      'tls-verify': 'no',
      'stream-lavf-o':
          'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5',
      'demuxer-lavf-o': 'fflags=+discardcorrupt',
      'demuxer-lavf-analyzeduration': '3',
      'hls-bitrate': 'max',
      'audio-channels': 'stereo',
      'ad-lavc-downmix': 'yes',
      'audio-normalize-downmix': 'yes',
      'video-sync': 'audio',
      'framedrop': 'vo',
      'sub-auto': 'no',
      'sid': 'no',
    };
    final dynamic plat = p.platform;
    for (final e in props.entries) {
      try {
        await plat.setProperty(e.key, e.value);
      } catch (_) {
        // Plataforma sin soporte para esa opción: se ignora.
      }
    }
    try {
      await p.setVolume(100);
    } catch (_) {}
  }

  Map<String, String> _buildHeaders(Map<String, String> serverHeaders) {
    final h = <String, String>{...serverHeaders};
    if (widget.headers != null) {
      for (final e in widget.headers!.entries) {
        h.putIfAbsent(e.key, () => e.value);
      }
    }
    final hasUa = h.keys.any((k) => k.toLowerCase() == 'user-agent');
    if (!hasUa) h['User-Agent'] = _ua;
    return h;
  }

  Future<void> _loadStreamsThenPlay() async {
    _fetching = true;
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
        _closeNoPlay('No hay fuentes de transmisión');
        return;
      }
      _servers = list;
      _serverIndex = _pickPreferred(list);
      _fetching = false;
      await _openCurrent();
    } catch (e) {
      _closeNoPlay('Error cargando transmisión');
    } finally {
      _fetching = false;
    }
  }

  List<String> _aliases(String pref) {
    final p = pref.trim().toLowerCase();
    if (p.isEmpty) return const [];
    if (p.startsWith('es') || p.contains('span') || p.contains('espa')) {
      return const ['es', 'spa', 'spanish', 'español', 'espanol', 'latino', 'castellano'];
    }
    if (p.startsWith('en') || p.contains('engl') || p.contains('ingl')) {
      return const ['en', 'eng', 'english', 'inglés', 'ingles'];
    }
    if (p.startsWith('pt') || p.contains('port')) {
      return const ['pt', 'por', 'portuguese', 'português', 'portugues'];
    }
    return [p];
  }

  bool _langMatch(String text, List<String> aliases) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty || aliases.isEmpty) return false;
    for (final a in aliases) {
      if (t == a) return true;
      if (a.length > 2 && t.contains(a)) return true;
      if (a.length <= 2 && RegExp('(^|[^a-z])$a([^a-z]|\$)').hasMatch(t)) {
        return true;
      }
    }
    return false;
  }

  int _pickPreferred(List<StreamServer> list) {
    final al = _aliases(widget.preferredLanguage);
    if (list.isEmpty || al.isEmpty) return 0;
    for (var i = 0; i < list.length; i++) {
      if (_langMatch(list[i].language ?? '', al)) return i;
    }
    return 0;
  }

  // ---------------------------------------------------------------------------
  // Apertura / recuperación
  // ---------------------------------------------------------------------------
  Future<void> _openCurrent() async {
    final s = _current;
    if (s == null) {
      _closeNoPlay('Sin URL de transmisión');
      return;
    }
    final gen = ++_gen;
    _audioPicked = false;
    _started = false;
    _lastPos = Duration.zero;
    _everAdvanced = false;
    _openedAt = DateTime.now();
    _lastProgressAt = _openedAt;
    _bufferingSince = null;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _buffering = true;
        _audioTracks = [];
        _selectedAudio = null;
      });
    }
    try {
      await _tuned;
      if (gen != _gen || !mounted) return;
      await _player.open(
        Media(s.url, httpHeaders: _buildHeaders(s.headers)),
        play: true,
      );
      if (gen != _gen || !mounted) return;
      setState(() => _loading = false);
      _scheduleHide();
      _focusButtons();
    } catch (e) {
      if (gen != _gen || !mounted) return;
      debugPrint('[LiveTV] open failed: $e');
      await _recover('open: $e', force: true);
    }
  }

  /// La fuente actual NO logró arrancar: prueba la siguiente; si ya se
  /// probaron todas, cierra el player. Una vez que empezó a reproducir,
  /// NUNCA se recarga (se ignoran errores, buffering y "completed").
  Future<void> _recover(String reason, {bool force = false}) async {
    if (!mounted || _fetching || _closing || _started) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastRecover) < const Duration(seconds: 3)) {
      return;
    }
    _lastRecover = now;
    _failures++;
    debugPrint('[LiveTV] fuente fallida #$_failures ($reason)');

    if (_servers.isEmpty || _failures >= _servers.length) {
      _closeNoPlay('No se pudo reproducir este canal');
      return;
    }
    _serverIndex = (_serverIndex + 1) % _servers.length;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
            'Probando otra fuente… (${_serverIndex + 1}/${_servers.length})'),
        duration: const Duration(seconds: 2),
      ));
    await _openCurrent();
  }

  void _closeNoPlay(String msg) {
    if (_closing || !mounted) return;
    _closing = true;
    _gen++;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ));
    Navigator.of(context).pop();
  }

  void _watchdogTick() {
    if (!mounted || _fetching || _closing || _started) return;
    if (_everAdvanced || ((_player.state.width ?? 0) > 0 && _playing)) {
      _started = true;
      return;
    }
    if (DateTime.now().difference(_openedAt) > const Duration(seconds: 25)) {
      unawaited(_recover('timeout sin reproducir', force: true));
    }
  }

  // ---------------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------------
  Future<void> _selectBestAudio(List<AudioTrack> audios) async {
    if (audios.isEmpty) return;
    final al = _aliases(widget.preferredLanguage);
    AudioTrack? pick;
    if (al.isNotEmpty) {
      for (final t in audios) {
        if (_langMatch(t.language ?? '', al) ||
            _langMatch(t.title ?? '', al)) {
          pick = t;
          break;
        }
      }
    }
    pick ??= audios.first;
    try {
      await _player.setAudioTrack(pick);
      await _player.setVolume(100);
      if (mounted) setState(() => _selectedAudio = pick);
    } catch (e) {
      debugPrint('[LiveTV] setAudioTrack: $e');
    }
  }

  Future<void> _switchServer(int i) async {
    if (i < 0 || i >= _servers.length) return;
    _failures = 0;
    setState(() {
      _serverIndex = i;
      _showServers = false;
    });
    _returnFocus();
    await _openCurrent();
  }

  // ---------------------------------------------------------------------------
  // EPG
  // ---------------------------------------------------------------------------
  List<EpgProgram> _sortedEpg(List<EpgProgram> l) {
    final c = List<EpgProgram>.of(l)
      ..sort((a, b) => a.start.compareTo(b.start));
    return c;
  }

  Future<void> _loadEpg() async {
    if (_epg.isNotEmpty || widget.epgLoader == null) return;
    try {
      final l = await widget.epgLoader!();
      if (!mounted || l.isEmpty) return;
      setState(() => _epg = _sortedEpg(l));
    } catch (e) {
      debugPrint('[LiveTV] epg: $e');
    }
  }

  void _openEpg() {
    if (_epg.isEmpty) return;
    _hideTimer?.cancel();
    setState(() {
      _showEpg = true;
      _showServers = false;
      _showAudio = false;
      _showControls = false;
    });
  }

  void _closePanels() {
    setState(() {
      _showServers = false;
      _showAudio = false;
      _showEpg = false;
    });
    _returnFocus();
    if (_showControls) _scheduleHide();
  }

  // ---------------------------------------------------------------------------
  // UI helpers
  // ---------------------------------------------------------------------------
  void _focusButtons() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_showControls && _btnFocus.context != null) {
        _btnFocus.requestFocus();
      } else {
        _rootFocus.requestFocus();
      }
    });
  }

  void _returnFocus() => _focusButtons();

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _anyPanel) return;
      setState(() => _showControls = false);
      _rootFocus.requestFocus();
    });
  }

  void _showUi() {
    setState(() => _showControls = true);
    _scheduleHide();
    _focusButtons();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _watchdog?.cancel();
    _rootFocus.dispose();
    _btnFocus.dispose();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    unawaited(_player.dispose());
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack) {
      if (_anyPanel) {
        _closePanels();
        return KeyEventResult.handled;
      }
      if (_showControls) {
        setState(() => _showControls = false);
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }

    // Con un panel abierto, las flechas las maneja el propio panel.
    if (_anyPanel) return KeyEventResult.ignored;

    // Flecha abajo => ficha de programación (si el repo trae guía).
    if (key == LogicalKeyboardKey.arrowDown && _epg.isNotEmpty) {
      _openEpg();
      return KeyEventResult.handled;
    }

    if (!_showControls &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _showUi();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !(_anyPanel || _showControls),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_anyPanel) {
          _closePanels();
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
                _videoView,
                if (!_everAdvanced && (widget.backdrop != null || widget.poster != null) && _loading)
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
                if (_showEpg)
                  _EpgPanel(
                    channelTitle: widget.title,
                    programs: _epg,
                    onClose: _closePanels,
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
            const Icon(Icons.wifi_tethering_error,
                color: Colors.white54, size: 48),
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
                _textBtn(
                  'Reintentar',
                  autofocus: true,
                  primary: true,
                  onTap: () {
                    _failures = 0;
                    unawaited(_openCurrent());
                  },
                ),
                if (_servers.length > 1)
                  _textBtn(
                    'Otra fuente',
                    onTap: () {
                      final n = (_serverIndex + 1) % _servers.length;
                      unawaited(_switchServer(n));
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _textBtn(String label,
      {required VoidCallback onTap,
      bool autofocus = false,
      bool primary = false}) {
    return Focus(
      autofocus: autofocus,
      onKeyEvent: (n, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.select ||
            e.logicalKey == LogicalKeyboardKey.enter) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (ctx) {
        final f = Focus.of(ctx).hasFocus;
        return GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: f ? Colors.white : (primary ? accent : Colors.white12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: f ? accent : Colors.transparent, width: 2),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: f ? Colors.black : Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _liveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
    );
  }

  Widget _controlsOverlay() {
    final hasServers = _servers.length > 1;
    final hasAudio = _audioTracks.length > 1;
    return Positioned.fill(
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
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 0),
                child: Row(
                  children: [
                    // El badge vive dentro de los controles: se oculta con ellos.
                    _liveBadge(),
                    const SizedBox(width: 12),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Row(
                  children: [
                    if (hasServers)
                      _tvBtn(
                        focusNode: _btnFocus,
                        icon: Icons.dns_rounded,
                        onTap: () => setState(() {
                          _showServers = true;
                          _showAudio = false;
                        }),
                      ),
                    if (hasServers) const SizedBox(width: 12),
                    if (hasAudio)
                      _tvBtn(
                        focusNode: hasServers ? null : _btnFocus,
                        icon: Icons.audiotrack_rounded,
                        onTap: () => setState(() {
                          _showAudio = true;
                          _showServers = false;
                        }),
                      ),
                    const Spacer(),
                    if (_epg.isNotEmpty)
                      GestureDetector(
                        onTap: _openEpg,
                        child: Row(
                          children: [
                            Icon(Icons.keyboard_arrow_down_rounded,
                                color: Colors.white.withValues(alpha: 0.8)),
                            const SizedBox(width: 4),
                            Text(
                              'Programación',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
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
      onClose: _closePanels,
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
                if ((_servers[i].quality ?? '').isNotEmpty)
                  _servers[i].quality!,
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
      onClose: _closePanels,
      children: [
        for (final t in _audioTracks)
          ListTile(
            autofocus: _selectedAudio?.id == t.id,
            selected: _selectedAudio?.id == t.id,
            selectedTileColor: Colors.white10,
            leading: Icon(Icons.audiotrack,
                color: _selectedAudio?.id == t.id ? accent : Colors.white54),
            title: Text(
              t.title?.isNotEmpty == true ? t.title! : (t.language ?? t.id),
              style: TextStyle(
                color: _selectedAudio?.id == t.id ? accent : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () async {
              try {
                await _player.setAudioTrack(t);
                if (!mounted) return;
                setState(() => _selectedAudio = t);
                _closePanels();
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

/// Ficha de programación: tira horizontal con el programa actual centrado.
/// ◄ ► para moverse por el resto de la guía, ▲ / Atrás para cerrar.
class _EpgPanel extends StatefulWidget {
  final String channelTitle;
  final List<EpgProgram> programs;
  final VoidCallback onClose;

  const _EpgPanel({
    required this.channelTitle,
    required this.programs,
    required this.onClose,
  });

  @override
  State<_EpgPanel> createState() => _EpgPanelState();
}

class _EpgPanelState extends State<_EpgPanel> {
  static const accent = Color(0xFFE50914);
  static const double _cardW = 300;
  static const double _gap = 16;
  static const double _extent = _cardW + _gap;

  late final ScrollController _sc;
  final FocusNode _focus = FocusNode();
  Timer? _tick;
  int _sel = 0;

  int _nowIndex() {
    final now = DateTime.now();
    final p = widget.programs;
    for (var i = 0; i < p.length; i++) {
      if (p[i].isOn(now)) return i;
    }
    for (var i = 0; i < p.length; i++) {
      if (p[i].start.isAfter(now)) return i;
    }
    return p.isEmpty ? 0 : p.length - 1;
  }

  @override
  void initState() {
    super.initState();
    _sel = _nowIndex();
    _sc = ScrollController(initialScrollOffset: _sel * _extent);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sc.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _select(int i) {
    final n = widget.programs.length;
    if (n == 0) return;
    final v = i.clamp(0, n - 1).toInt();
    setState(() => _sel = v);
    if (_sc.hasClients) {
      _sc.animateTo(
        v * _extent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final progs = widget.programs;
    final now = DateTime.now();
    final sel = progs[_sel];
    final screenW = MediaQuery.of(context).size.width;
    final sidePad = ((screenW - _extent) / 2).clamp(0.0, 4000.0).toDouble();

    return Positioned.fill(
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          color: Colors.black45,
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: Focus(
              focusNode: _focus,
              onKeyEvent: (n, e) {
                if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                final k = e.logicalKey;
                if (k == LogicalKeyboardKey.arrowLeft) {
                  _select(_sel - 1);
                  return KeyEventResult.handled;
                }
                if (k == LogicalKeyboardKey.arrowRight) {
                  _select(_sel + 1);
                  return KeyEventResult.handled;
                }
                if (k == LogicalKeyboardKey.arrowUp) {
                  widget.onClose();
                  return KeyEventResult.handled;
                }
                if (k == LogicalKeyboardKey.arrowDown ||
                    k == LogicalKeyboardKey.select ||
                    k == LogicalKeyboardKey.enter) {
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored; // Atrás lo cierra el root
              },
              child: Material(
                color: const Color(0xF2101620),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 14, 16, 8),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_view_day_rounded,
                                color: Colors.white70, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Programación · ${widget.channelTitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                            IconButton(
                              onPressed: widget.onClose,
                              icon: const Icon(Icons.close,
                                  color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 104,
                        child: ListView.builder(
                          controller: _sc,
                          scrollDirection: Axis.horizontal,
                          itemExtent: _extent,
                          padding: EdgeInsets.symmetric(horizontal: sidePad),
                          itemCount: progs.length,
                          itemBuilder: (_, i) =>
                              _card(progs[i], i == _sel, now, i),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 12, 32, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sel.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_hm(sel.start)} - ${_hm(sel.end)}',
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 12),
                            ),
                            if (sel.description.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                sel.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    height: 1.3),
                              ),
                            ],
                          ],
                        ),
                      ),
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

  Widget _card(EpgProgram p, bool selected, DateTime now, int index) {
    final live = p.isOn(now);
    final past = p.end.isBefore(now);
    double progress = 0;
    if (live) {
      final total = p.end.difference(p.start).inSeconds;
      if (total > 0) {
        progress =
            (now.difference(p.start).inSeconds / total).clamp(0.0, 1.0).toDouble();
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _gap / 2, vertical: 4),
      child: GestureDetector(
        onTap: () => _select(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? accent : Colors.white12,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Opacity(
            opacity: past && !selected ? 0.5 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${_hm(p.start)} - ${_hm(p.end)}',
                      style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    if (live)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text('AHORA',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                if (live)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      color: accent,
                      backgroundColor: Colors.white12,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}