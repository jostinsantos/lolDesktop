import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/models/stream_server.dart';
import '../../../data/services/content_service.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/repo_prefs.dart';
import '../../../data/services/download_service.dart';
import '../../../data/models/download_item.dart';
import '../../../data/services/party_service.dart';
import 'party_player.dart';

// ───────────────────────── Tokens ─────────────────────────
const _accent = Color(0xFFE50914);
const _accentDark = Color(0xFFB20710);
const _panelBg = Color(0xF20E1117);
const _card = Color(0xFF161A22);
const _line = Color(0xFF232A38);
const _fast = Duration(milliseconds: 160);
const _mid = Duration(milliseconds: 260);

const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

enum _Fit { original, cover, stretch, r16_9, r21_9, r4_3 }

enum _Panel { none, servers, episodes, tracks, settings }

enum _SkipMode { none, intro, outro, next }

String _fitLabel(_Fit f) {
  switch (f) {
    case _Fit.original:
      return 'Original';
    case _Fit.cover:
      return 'Rellenar';
    case _Fit.stretch:
      return 'Estirar';
    case _Fit.r16_9:
      return '16:9';
    case _Fit.r21_9:
      return '21:9';
    case _Fit.r4_3:
      return '4:3';
  }
}

IconData _fitIcon(_Fit f) {
  switch (f) {
    case _Fit.original:
      return Icons.fit_screen_rounded;
    case _Fit.cover:
      return Icons.zoom_out_map_rounded;
    case _Fit.stretch:
      return Icons.open_in_full_rounded;
    case _Fit.r16_9:
      return Icons.crop_16_9_rounded;
    case _Fit.r21_9:
      return Icons.crop_landscape_rounded;
    case _Fit.r4_3:
      return Icons.crop_portrait_rounded;
  }
}

double? _fitRatio(_Fit f) {
  switch (f) {
    case _Fit.r16_9:
      return 16 / 9;
    case _Fit.r21_9:
      return 21 / 9;
    case _Fit.r4_3:
      return 4 / 3;
    default:
      return null;
  }
}

BoxFit _fitBox(_Fit f) {
  switch (f) {
    case _Fit.original:
      return BoxFit.contain;
    case _Fit.cover:
      return BoxFit.cover;
    default:
      return BoxFit.fill;
  }
}

bool isHlsUrl(String url, {bool isHlsFlag = false}) {
  if (isHlsFlag) return true;
  final u = url.toLowerCase();
  return u.contains('.m3u8') || u.contains('/hls/') || u.contains('format=m3u8');
}

bool isTsUrl(String url) {
  final u = url.toLowerCase();
  return u.contains('.ts') || u.contains('mpegts') || u.contains('mpeg-ts') || u.contains('format=ts');
}

/// Player Desktop — UI moderna, teclado completo y herramientas de reproducción.
class DesktopPlayerPage extends StatefulWidget {
  final String title;
  final InstalledRepo repo;
  final String contentId;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final String contentType;
  final String? preferredLanguage;
  final int? season;
  final int? episode;
  final List<EpisodeInfo>? episodes;
  final int? seasonNumber;
  final int startPositionMs;

  /// Ruta local (descarga offline). Si viene, no busca streams.
  final String? localPath;

  const DesktopPlayerPage({
    super.key,
    required this.title,
    required this.repo,
    required this.contentId,
    this.poster,
    this.backdrop,
    this.logo,
    this.contentType = 'movie',
    this.preferredLanguage,
    this.season,
    this.episode,
    this.episodes,
    this.seasonNumber,
    this.startPositionMs = 0,
    this.localPath,
  });

  static Future<Map<String, dynamic>?> loadHistorialEntry({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (season != null && episode != null) {
        final epKey = 'continue_watch_${repoId}_${contentId}_s${season}_e$episode';
        final raw = prefs.getString(epKey);
        if (raw == null || raw.isEmpty) return null;
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        return null;
      }
      final seriesKey = 'continue_watch_${repoId}_$contentId';
      final raw = prefs.getString(seriesKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  @override
  State<DesktopPlayerPage> createState() => _DesktopPlayerPageState();
}

class _DesktopPlayerPageState extends State<DesktopPlayerPage> {
  // Estado compartido entre episodios consecutivos (mantiene fullscreen / PiP)
  static bool _pendingFullscreen = false;
  static bool _pendingPip = false;
  static Rect? _windowBoundsBeforePip;
  bool _handingOff = false;

  // Streams
  List<StreamServer> _servers = [];
  bool _loadingStreams = true;
  String _loadingStatus = 'Buscando servidor…';
  String? _error;
  String? _streamError;
  StreamServer? _selected;

  // Player
  Player? _player;
  VideoController? _video;
  final List<StreamSubscription> _subs = [];
  LibraryService? _lib;

  bool _playing = false;
  bool _buffering = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final _posN = ValueNotifier<Duration>(Duration.zero);
  final _bufN = ValueNotifier<Duration>(Duration.zero);
  final _hoverN = ValueNotifier<double?>(null);
  bool _isDragging = false;

  double _volume = 100;
  double _lastVolume = 100;
  double _speed = 1.0;
  Timer? _volSaveTimer;

  // UI
  final FocusNode _rootFocus = FocusNode(debugLabel: 'player-root');
  bool _showControls = true;
  Timer? _hideTimer;
  _Panel _panel = _Panel.none;
  bool _showHelp = false;
  bool _isFullscreen = false;
  bool _isPip = false;
  bool _volHover = false;
  _Fit _fit = _Fit.original;
  ScrollController? _epScroll;
  DateTime? _lastTap;

  // HUD
  IconData _hudIcon = Icons.info_outline_rounded;
  String _hudText = '';
  double? _hudValue;
  bool _hudVisible = false;
  Timer? _hudTimer;
  IconData? _flashIcon;
  int _flashTick = 0;

  // Tracks
  List<AudioTrack> _audioTracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  AudioTrack? _selectedAudio;
  SubtitleTrack? _selectedSubtitle;
  String? _selectedExternalSub;
  List<ExternalSubtitle> _externalSubs = [];

  // Intro / outro / siguiente
  double? _introStartSec;
  double? _introEndSec;
  double? _outroStartSec;
  double? _outroEndSec;
  bool _introSkipped = false;
  _SkipMode _skipMode = _SkipMode.none;
  DownloadItem? _nextDl;

  // Temporizador de apagado
  Timer? _sleepTimer;
  int _sleepChoice = 0; // 0 = off, -1 = fin del episodio, n = minutos

  // Ajustes extra
  final Set<String> _openGroups = {'speed'};
  double _subDelay = 0;
  double _subScale = 1.0;
  double _audioDelay = 0;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  bool _autoNext = true;
  bool _loopOn = false;

  bool _resumeApplied = false;
  bool _durationReady = false;
  Timer? _progressTimer;
  Timer? _idleTimer;
  Timer? _wakelockTimer;
  bool _showIdleScreen = false;
  static const _continueIndexKey = 'continue_watch_index';

  // ───────────────────────── Ciclo de vida ─────────────────────────
  @override
  void initState() {
    super.initState();
    try {
      DownloadService.instance.setHideOverlay(true);
    } catch (_) {}
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}
    try {
      _lib = context.read<LibraryService>();
    } catch (_) {}
    _isFullscreen = _pendingFullscreen;
    _isPip = _pendingPip;
    _pendingFullscreen = false;
    _pendingPip = false;
    _nextDl = _computeNextDownloaded();
    _keepScreenAwake();
    _boot();
    _armHideTimer();
  }

  Future<void> _boot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoNext = prefs.getBool('player_autonext') ?? true;
      final v = prefs.getDouble('player_volume');
      if (v != null) {
        _volume = v.clamp(0.0, 100.0);
        if (_volume > 0) _lastVolume = _volume;
      }
    } catch (_) {}
    if (!mounted) return;
    final local = widget.localPath?.trim() ?? '';
    if (local.isNotEmpty) {
      await _openLocal(local);
    } else {
      await _loadStreams();
    }
  }

  @override
  void dispose() {
    try {
      DownloadService.instance.setHideOverlay(false);
    } catch (_) {}
    if (!_handingOff) {
      if (_isPip) {
        unawaited(_restoreWindowFromPip());
      } else if (_isFullscreen) {
        try {
          unawaited(windowManager.setFullScreen(false));
        } catch (_) {}
      }
    }
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _progressTimer?.cancel();
    _idleTimer?.cancel();
    _wakelockTimer?.cancel();
    _sleepTimer?.cancel();
    _volSaveTimer?.cancel();
    try {
      WakelockPlus.disable();
    } catch (_) {}
    _saveProgressNow();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    unawaited(_player?.dispose());
    _player = null;
    _video = null;
    _epScroll?.dispose();
    _posN.dispose();
    _bufN.dispose();
    _hoverN.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  // ───────────────────────── Visibilidad de controles ─────────────────────────
  void _onUserActivity([PointerEvent? _]) {
    if (!_showControls) setState(() => _showControls = true);
    _armHideTimer();
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    // Mientras carga, está en pausa o hay un panel abierto, los controles se quedan
    if (_panel != _Panel.none || !_playing || !_durationReady || _isDragging) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _panel != _Panel.none || !_playing) return;
      setState(() => _showControls = false);
    });
  }

  // ───────────────────────── HUD ─────────────────────────
  void _hud(IconData icon, String text, {double? value}) {
    _hudTimer?.cancel();
    setState(() {
      _hudIcon = icon;
      _hudText = text;
      _hudValue = value;
      _hudVisible = true;
    });
    _hudTimer = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  void _flash(IconData icon) {
    setState(() {
      _flashIcon = icon;
      _flashTick++;
    });
  }

  // ───────────────────────── Carga de streams ─────────────────────────
  Future<void> _loadStreams() async {
    setState(() {
      _loadingStreams = true;
      _loadingStatus = 'Buscando servidor…';
      _error = null;
    });
    try {
      final servers = await ContentService.instance.getStreams(
        widget.repo,
        widget.contentId,
        type: widget.contentType,
        season: widget.season,
        episode: widget.episode,
      );
      if (!mounted) return;

      StreamServer? preferred;
      final lang = widget.preferredLanguage?.toLowerCase();
      if (lang != null && lang.isNotEmpty) {
        for (final s in servers) {
          final sl = (s.language ?? '').toLowerCase();
          if (sl.contains(lang) || lang.contains(sl)) {
            preferred = s;
            break;
          }
        }
      }

      setState(() {
        _servers = servers;
        _selected = preferred ?? (servers.isNotEmpty ? servers.first : null);
        _loadingStreams = false;
        if (servers.isEmpty) _error = 'No se encontraron servidores ni streams';
      });

      if (_selected != null) await _openServer(_selected!);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingStreams = false;
      });
    }
  }

  Future<void> _retry() async {
    final local = widget.localPath?.trim() ?? '';
    if (local.isNotEmpty) {
      await _openLocal(local);
    } else if (_selected != null && _servers.isNotEmpty) {
      await _openServer(_selected!);
    } else {
      await _loadStreams();
    }
  }

  Future<void> _openLocal(String path) async {
    setState(() {
      _loadingStreams = false;
      _servers = [];
      _selected = null;
    });
    await _openMedia(url: path, local: true);
  }

  Future<void> _openServer(StreamServer server) async {
    // Al cambiar de servidor se conserva el punto de reproducción
    final resume = _durationReady ? _position.inMilliseconds : null;
    setState(() => _selected = server);

    final url = server.url.trim();
    if (url.isEmpty) {
      setState(() => _error = 'La URL del stream está vacía');
      return;
    }
    final headers = <String, String>{...server.headers};
    headers.putIfAbsent(
      'User-Agent',
      () =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    );
    await _openMedia(url: url, headers: headers, server: server, resumeMs: resume);
  }

  /// Apertura única para streams y archivos locales.
  Future<void> _openMedia({
    required String url,
    Map<String, String>? headers,
    bool local = false,
    StreamServer? server,
    int? resumeMs,
  }) async {
    setState(() {
      _buffering = true;
      _loadingStatus = 'Cargando vídeo…';
      _error = null;
      _streamError = null;
      _audioTracks = [];
      _subtitleTracks = [];
      _selectedAudio = null;
      _selectedSubtitle = null;
      _selectedExternalSub = null;
      _externalSubs = server != null ? List.from(server.subtitles) : [];
      _durationReady = false;
      _resumeApplied = false;
      _skipMode = _SkipMode.none;
    });
    _applySegments(server);

    debugPrint('[Player] open local=$local hls=${isHlsUrl(url, isHlsFlag: server?.isHls ?? false)} url=$url');

    try {
      try {
        MediaKit.ensureInitialized();
      } catch (_) {}
      for (final s in _subs) {
        await s.cancel();
      }
      _subs.clear();
      await _player?.dispose();
      _player = null;
      _video = null;

      final player = Player(
        configuration: const PlayerConfiguration(
          title: 'LOL Lite',
          bufferSize: 32 * 1024 * 1024,
        ),
      );
      await _configurePlayer(player, local: local);

      final video = VideoController(
        player,
        configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
      );
      _listen(player);

      await player.open(
        Media(url, httpHeaders: (headers == null || headers.isEmpty) ? null : headers),
        play: true,
      );
      await player.setVolume(_volume);
      if (_speed != 1.0) await player.setRate(_speed);
      await _applyTweaks(player);

      if (!mounted) {
        await player.dispose();
        return;
      }

      final localSubs = local ? await _scanLocalSubs(url) : null;
      if (!mounted) return;
      setState(() {
        _player = player;
        _video = video;
        _buffering = false;
        if (localSubs != null) _externalSubs = localSubs;
      });
      unawaited(_applyResume(player, overrideMs: resumeMs));
      _progressTimer?.cancel();
      _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) => _saveProgressNow());
      _armHideTimer();
    } catch (e) {
      debugPrint('[Player] open failed: $e');
      if (!mounted) return;
      setState(() {
        _error = local ? 'No se pudo reproducir el archivo local: $e' : 'No se pudo abrir el stream: $e';
        _buffering = false;
        _loadingStreams = false;
      });
    }
  }

  Future<void> _configurePlayer(Player player, {required bool local}) async {
    final platform = player.platform;
    if (platform == null) return;
    Future<void> set(String k, String v) async {
      try {
        await (platform as dynamic).setProperty(k, v);
      } catch (_) {}
    }

    if (!local) {
      await set('demuxer-lavf-analyzeduration', '15');
      await set('demuxer-lavf-probesize', '50000000');
      await set('network-timeout', '60');
      await set('cache', 'yes');
      await set('cache-secs', '30');
      await set('tls-verify', 'no');
    }
    await set('sub-visibility', 'yes');
    await set('sub-ass-override', 'force');

    // Preferencias de subtítulos (Ajustes)
    try {
      final prefs = await SharedPreferences.getInstance();
      final size = prefs.getDouble('sub_size') ?? 42;
      final margin = prefs.getDouble('sub_margin_y') ?? 18;
      final border = prefs.getDouble('sub_border') ?? 2;
      final bold = prefs.getBool('sub_bold') ?? true;
      final bg = prefs.getBool('sub_bg') ?? false;
      final color = prefs.getInt('sub_color') ?? 0xFFFFFFFF;
      await set('sub-font-size', size.toStringAsFixed(0));
      await set('sub-margin-y', margin.toStringAsFixed(0));
      await set('sub-border-size', border.toStringAsFixed(0));
      await set('sub-shadow-offset', '0');
      await set('sub-bold', bold ? 'yes' : 'no');
      await set('sub-color', '#${color.toRadixString(16).padLeft(8, '0')}');
      await set('sub-border-style', bg ? '4' : '1');
    } catch (_) {
      await set('sub-font-size', '42');
      await set('sub-margin-y', '18');
      await set('sub-border-size', '2');
      await set('sub-shadow-offset', '0');
    }
  }

  void _listen(Player player) {
    _subs.add(player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
      _onPlayingChanged(v);
    }));
    _subs.add(player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(player.stream.position.listen((v) {
      if (!mounted || _isDragging) return;
      _position = v;
      _posN.value = v;
      // Streams en vivo sin duración: se considera listo tras 2 s reproduciendo
      if (!_durationReady && v.inMilliseconds > 2000) {
        setState(() => _durationReady = true);
        _armHideTimer();
      }
      _updateSkipFlags();
    }));
    _subs.add(player.stream.duration.listen((v) {
      if (!mounted) return;
      setState(() {
        _duration = v;
        if (v.inMilliseconds > 1000) _durationReady = true;
      });
      if (_durationReady) _armHideTimer();
    }));
    _subs.add(player.stream.buffer.listen((v) => _bufN.value = v));
    _subs.add(player.stream.completed.listen((v) {
      if (v && mounted) _onCompleted();
    }));
    _subs.add(player.stream.error.listen((e) {
      final msg = e.toString().trim();
      if (msg.isEmpty) return;
      debugPrint('[Player] error: $msg');
      // Solo avisar si falla al inicio (probablemente fatal)
      if (mounted && _position.inSeconds < 3 && _streamError == null) {
        setState(() => _streamError = msg);
      }
    }));
    _subs.add(player.stream.tracks.listen((tracks) {
      if (!mounted) return;
      final audios = tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
      final subs = tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
      setState(() {
        _audioTracks = audios;
        _subtitleTracks = subs;
        final p = _player;
        if (p != null) {
          _selectedAudio = p.state.track.audio;
          final cur = p.state.track.subtitle;
          if (cur.id != 'auto' && cur.id != 'no') _selectedSubtitle = cur;
        }
      });
    }));
  }

  Future<List<ExternalSubtitle>> _scanLocalSubs(String path) async {
    final external = <ExternalSubtitle>[];
    final seen = <String>{};

    final dl = _findDownloadForLocal(path);
    if (dl != null) {
      for (final s in dl.subtitles) {
        final lp = s.localPath;
        if (lp != null && lp.isNotEmpty) {
          seen.add(lp.replaceAll(r'\', '/').toLowerCase());
          external.add(ExternalSubtitle(
            lang: s.lang.isNotEmpty ? s.lang : 'und',
            label: s.label.isNotEmpty ? s.label : 'Subtítulo',
            url: lp.startsWith('file:') ? lp : Uri.file(lp).toString(),
          ));
        }
      }
    }

    try {
      final dir = File(path).parent;
      if (await dir.exists()) {
        await for (final ent in dir.list(followLinks: false)) {
          if (ent is! File) continue;
          final low = ent.path.toLowerCase();
          if (!(low.endsWith('.srt') || low.endsWith('.vtt') || low.endsWith('.ass') || low.endsWith('.ssa'))) {
            continue;
          }
          final key = ent.path.replaceAll(r'\', '/').toLowerCase();
          if (!seen.add(key)) continue;
          final base = ent.uri.pathSegments.isNotEmpty ? ent.uri.pathSegments.last : 'Subtítulo';
          String lang = 'und';
          String label;
          final m = RegExp(r'([a-z]{2,3})\.(srt|vtt|ass|ssa)$', caseSensitive: false).firstMatch(base);
          if (m != null && !{'srt', 'vtt', 'ass', 'ssa'}.contains(m.group(1)!.toLowerCase())) {
            lang = m.group(1)!.toLowerCase();
            label = 'Subtítulos (${lang.toUpperCase()})';
          } else {
            label = base.replaceAll(RegExp(r'\.(srt|vtt|ass|ssa)$', caseSensitive: false), '');
            if (label.isEmpty) label = 'Subtítulo';
          }
          external.add(ExternalSubtitle(lang: lang, label: label, url: Uri.file(ent.path).toString()));
        }
      }
    } catch (e) {
      debugPrint('[Player] scan subs: $e');
    }
    return external;
  }

  DownloadItem? _findDownloadForLocal(String path) {
    try {
      for (final it in DownloadService.instance.items) {
        if (it.localPath == path) return it;
      }
      final name = path.replaceAll('\\', '/').split('/').last;
      for (final it in DownloadService.instance.items) {
        final lp = it.localPath;
        if (lp != null && lp.replaceAll('\\', '/').endsWith(name)) return it;
      }
    } catch (_) {}
    return null;
  }

  // ───────────────────────── Segmentos / siguiente ─────────────────────────
  void _applySegments(StreamServer? server) {
    _introStartSec = null;
    _introEndSec = null;
    _outroStartSec = null;
    _outroEndSec = null;
    _introSkipped = false;
    final seg = server?.segments;
    if (seg == null) return;
    if (seg.intro != null && seg.intro!.length >= 2) {
      _introStartSec = seg.intro![0].toDouble();
      _introEndSec = seg.intro![1].toDouble();
    }
    if (seg.outro != null && seg.outro!.length >= 2) {
      _outroStartSec = seg.outro![0].toDouble();
      _outroEndSec = seg.outro![1].toDouble();
    }
  }

  void _updateSkipFlags() {
    final sec = _position.inMilliseconds / 1000.0;
    final total = _duration.inMilliseconds / 1000.0;

    var mode = _SkipMode.none;
    if (!_introSkipped && _introStartSec != null && _introEndSec != null && sec >= _introStartSec! && sec <= _introEndSec!) {
      mode = _SkipMode.intro;
    } else {
      final inOutro = _outroStartSec != null &&
          total > 0 &&
          _outroStartSec! >= total * 0.5 &&
          sec >= _outroStartSec! &&
          sec <= (_outroEndSec ?? total);
      final nearEnd = _hasNext && total > 30 && sec / total >= 0.92;
      if (_hasNext && (inOutro || nearEnd)) {
        mode = _SkipMode.next;
      } else if (inOutro) {
        mode = _SkipMode.outro;
      }
    }
    if (mode != _skipMode) setState(() => _skipMode = mode);
  }

  bool get _hasNextEpisode {
    final eps = widget.episodes;
    final cur = widget.episode;
    if (eps == null || cur == null) return false;
    return eps.any((e) => e.number == cur + 1);
  }

  EpisodeInfo? get _nextEpisode {
    final eps = widget.episodes;
    final cur = widget.episode;
    if (eps == null || cur == null) return null;
    for (final e in eps) {
      if (e.number == cur + 1) return e;
    }
    return null;
  }

  EpisodeInfo? get _currentEpisodeInfo {
    final eps = widget.episodes;
    final cur = widget.episode;
    if (eps == null || cur == null) return null;
    for (final e in eps) {
      if (e.number == cur) return e;
    }
    return null;
  }

  DownloadItem? _computeNextDownloaded() {
    if (widget.localPath == null) return null;
    final season = widget.seasonNumber ?? widget.season;
    final ep = widget.episode;
    if (season == null || ep == null) return null;
    DownloadItem? best;
    try {
      for (final it in DownloadService.instance.items) {
        if (it.status != DownloadStatus.completed) continue;
        if (it.repoId != widget.repo.manifest.id) continue;
        if (it.contentId != widget.contentId && !it.contentId.startsWith('${widget.contentId}:')) continue;
        if (it.season != season || it.episode == null || it.episode! <= ep) continue;
        if (best == null || it.episode! < best.episode!) best = it;
      }
    } catch (_) {}
    return best;
  }

  bool get _hasNext => widget.localPath != null ? _nextDl != null : _hasNextEpisode;

  Future<void> _skipIntro() async {
    if (_introEndSec == null) return;
    await _player?.seek(Duration(milliseconds: (_introEndSec! * 1000).round() + 300));
    setState(() {
      _introSkipped = true;
      _skipMode = _SkipMode.none;
    });
  }

  Future<void> _skipOutro() async {
    if (_hasNext) {
      _goNext();
      return;
    }
    if (_duration > Duration.zero) await _player?.seek(_duration - const Duration(seconds: 1));
    setState(() => _skipMode = _SkipMode.none);
  }

  /// Acción contextual (tecla I): omitir intro / créditos / ir al siguiente.
  void _contextAction() {
    switch (_skipMode) {
      case _SkipMode.intro:
        _skipIntro();
        break;
      case _SkipMode.outro:
        _skipOutro();
        break;
      case _SkipMode.next:
        _goNext();
        break;
      case _SkipMode.none:
        break;
    }
  }

  void _replaceWith(Widget page) {
    _handingOff = true;
    _pendingFullscreen = _isFullscreen;
    _pendingPip = _isPip;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => page));
  }

  void _goNext() {
    if (widget.localPath != null) {
      final d = _nextDl;
      if (d != null) _goToDownloaded(d);
      return;
    }
    final e = _nextEpisode;
    if (e != null) _goToEpisode(e);
  }

  void _goToEpisode(EpisodeInfo ep) {
    if (ep.number == widget.episode) {
      _closePanel();
      return;
    }
    final durMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds;
    _saveProgressNow(forceFinished: durMs > 0 && posMs / durMs >= 0.90);
    final season = widget.seasonNumber ?? widget.season;
    final base = widget.title.split('·').first.trim();
    _replaceWith(DesktopPlayerPage(
      title: season != null ? '$base · T$season E${ep.number}' : '$base · E${ep.number}',
      repo: widget.repo,
      contentId: widget.contentId,
      poster: widget.poster,
      backdrop: widget.backdrop,
      logo: widget.logo,
      contentType: widget.contentType,
      preferredLanguage: widget.preferredLanguage,
      season: season,
      episode: ep.number,
      episodes: widget.episodes,
      seasonNumber: season,
    ));
  }

  void _goToDownloaded(DownloadItem it) {
    final path = it.localPath;
    if (path == null || path.isEmpty) return;
    _saveProgressNow(forceFinished: true);
    _replaceWith(DesktopPlayerPage(
      title: it.displayTitle,
      repo: widget.repo,
      contentId: it.contentId,
      poster: it.poster ?? widget.poster,
      backdrop: widget.backdrop,
      logo: widget.logo,
      contentType: it.type,
      preferredLanguage: widget.preferredLanguage,
      season: it.season,
      episode: it.episode,
      episodes: widget.episodes,
      seasonNumber: it.season,
      localPath: path,
    ));
  }

  void _onCompleted() {
    if (_duration.inSeconds > 0 && _position.inMilliseconds < _duration.inMilliseconds * 0.8) return;
    if (_sleepChoice == -1) {
      _setSleep(0);
      _hud(Icons.bedtime_rounded, 'Temporizador: reproducción detenida');
      return;
    }
    if (_hasNext && _autoNext) _goNext();
  }

  // ───────────────────────── Reanudar / guardar ─────────────────────────
  Future<int> _resolveStartPositionMs() async {
    if (widget.startPositionMs > 1500) return widget.startPositionMs;
    try {
      final entry = await DesktopPlayerPage.loadHistorialEntry(
        repoId: widget.repo.manifest.id,
        contentId: widget.contentId,
        season: widget.season,
        episode: widget.episode,
      );
      if (entry == null) return widget.startPositionMs;
      final pos = (entry['positionMs'] as num?)?.toInt() ?? (((entry['segundo'] as num?)?.toInt() ?? 0) * 1000);
      final dur = (entry['durationMs'] as num?)?.toInt() ??
          (((entry['durationSec'] as num?)?.toInt() ?? (entry['duration'] as num?)?.toInt() ?? 0) * 1000);
      if (pos > 1500 && (dur <= 0 || pos < dur * 0.95)) return pos;
    } catch (e) {
      debugPrint('[Player] resolve start pos: $e');
    }
    return widget.startPositionMs;
  }

  Future<void> _applyResume(Player player, {int? overrideMs}) async {
    if (_resumeApplied) return;
    _resumeApplied = true;
    final ms = overrideMs ?? await _resolveStartPositionMs();
    if (ms <= 1500) return;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await player.seek(Duration(milliseconds: ms));
      if (mounted) _hud(Icons.history_rounded, 'Continuando desde ${_fmt(Duration(milliseconds: ms))}');
    } catch (e) {
      debugPrint('[Player] resume seek: $e');
    }
  }

  void _saveProgressNow({bool forceFinished = false}) {
    final posMs = _position.inMilliseconds;
    final durMs = _duration.inMilliseconds;
    if (posMs < 2000 && !forceFinished) return;
    final finished = forceFinished || (durMs > 0 && posMs / durMs >= 0.90);
    final savePos = finished && durMs > 0 ? durMs : posMs;

    try {
      _lib?.saveProgress(
        repoId: widget.repo.manifest.id,
        contentId: widget.contentId,
        title: widget.title,
        poster: widget.poster,
        type: widget.contentType,
        positionMs: savePos,
        durationMs: durMs,
      );
    } catch (e) {
      debugPrint('[Player] saveProgress lib: $e');
    }
    unawaited(_saveHistorialToPrefs(positionMs: savePos, durationMs: durMs, finished: finished));
  }

  Future<void> _saveHistorialToPrefs({
    required int positionMs,
    required int durationMs,
    bool finished = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final repoId = widget.repo.manifest.id;
      final contentId = widget.contentId;
      final season = widget.season;
      final episode = widget.episode;
      final hasEp = season != null && episode != null;

      final key = hasEp
          ? 'continue_watch_${repoId}_${contentId}_s${season}_e$episode'
          : 'continue_watch_${repoId}_$contentId';
      final seriesKey = 'continue_watch_${repoId}_$contentId';

      final payload = jsonEncode(<String, dynamic>{
        'repoId': repoId,
        'contentId': contentId,
        'title': widget.title,
        'poster': widget.poster,
        'backdrop': widget.backdrop,
        'type': widget.contentType,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'segundo': (positionMs / 1000).round(),
        'durationSec': (durationMs / 1000).round(),
        'season': season,
        'episode': episode,
        'finished': finished,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      await prefs.setString(key, payload);
      if (hasEp && seriesKey != key) await prefs.setString(seriesKey, payload);

      final index = prefs.getStringList(_continueIndexKey) ?? <String>[];
      index.remove(key);
      index.insert(0, key);
      if (hasEp && seriesKey != key) {
        index.remove(seriesKey);
        index.insert(0, seriesKey);
      }
      while (index.length > 80) {
        await prefs.remove(index.removeLast());
      }
      await prefs.setStringList(_continueIndexKey, index);
    } catch (e) {
      debugPrint('[Player] saveHistorial prefs: $e');
    }
  }

  // ───────────────────────── Pantalla / reposo ─────────────────────────
  void _keepScreenAwake() {
    try {
      WakelockPlus.enable();
    } catch (_) {}
    _wakelockTimer?.cancel();
    _wakelockTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted) return;
      try {
        if (_playing) await WakelockPlus.enable();
      } catch (_) {}
    });
  }

  void _onPlayingChanged(bool playing) {
    _idleTimer?.cancel();
    if (playing) {
      try {
        WakelockPlus.enable();
      } catch (_) {}
      if (_showIdleScreen) setState(() => _showIdleScreen = false);
      _armHideTimer();
    } else {
      _saveProgressNow();
      _hideTimer?.cancel();
      if (!_showControls) setState(() => _showControls = true);
      _idleTimer = Timer(const Duration(minutes: 1), () {
        if (!mounted || _playing) return;
        setState(() {
          _showIdleScreen = true;
          _showControls = false;
          _panel = _Panel.none;
        });
      });
    }
  }

  void _dismissIdleScreen() {
    if (!_showIdleScreen) return;
    setState(() {
      _showIdleScreen = false;
      _showControls = true;
    });
    _armHideTimer();
  }

  // ───────────────────────── Acciones de reproducción ─────────────────────────
  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    _flash(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded);
    p.playOrPause();
    _onUserActivity();
  }

  void _seekBy(Duration d) {
    final p = _player;
    if (p == null) return;
    var t = _position + d;
    if (t < Duration.zero) t = Duration.zero;
    if (_duration > Duration.zero && t > _duration) t = _duration;
    _position = t;
    _posN.value = t;
    p.seek(t);
    _hud(
      d.isNegative ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
      '${d.isNegative ? '−' : '+'}${d.inSeconds.abs()} s  ·  ${_fmt(t)}',
    );
    _onUserActivity();
  }

  void _seekToFrac(double f) {
    final p = _player;
    if (p == null || _duration <= Duration.zero) return;
    final t = Duration(milliseconds: (_duration.inMilliseconds * f.clamp(0.0, 1.0)).round());
    _position = t;
    _posN.value = t;
    p.seek(t);
    _hud(Icons.my_location_rounded, '${(f * 100).round()}%  ·  ${_fmt(t)}');
    _onUserActivity();
  }

  void _setVolume(double v, {bool hud = true}) {
    v = v.clamp(0.0, 100.0);
    if (v > 0) _lastVolume = v;
    setState(() => _volume = v);
    _player?.setVolume(v);
    _volSaveTimer?.cancel();
    _volSaveTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('player_volume', _volume);
      } catch (_) {}
    });
    if (hud) {
      _hud(
        v == 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
        v == 0 ? 'Silencio' : '${v.round()}%',
        value: v / 100,
      );
    }
    _onUserActivity();
  }

  void _toggleMute() => _setVolume(_volume == 0 ? (_lastVolume <= 0 ? 50 : _lastVolume) : 0);

  Future<void> _setSpeed(double s) async {
    setState(() => _speed = s);
    try {
      await _player?.setRate(s);
    } catch (_) {}
    _hud(Icons.speed_rounded, 'Velocidad ${s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toString()}x');
  }

  void _stepSpeed(int dir) {
    var i = _speeds.indexWhere((x) => (x - _speed).abs() < 0.01);
    if (i < 0) i = _speeds.indexOf(1.0);
    final n = (i + dir).clamp(0, _speeds.length - 1);
    _setSpeed(_speeds[n]);
  }

  void _setFit(_Fit f) {
    setState(() => _fit = f);
    _hud(_fitIcon(f), 'Imagen: ${_fitLabel(f)}');
  }

  void _cycleFit() => _setFit(_Fit.values[(_fit.index + 1) % _Fit.values.length]);

  void _setSleep(int choice) {
    _sleepTimer?.cancel();
    setState(() => _sleepChoice = choice);
    if (choice > 0) {
      _sleepTimer = Timer(Duration(minutes: choice), () {
        _player?.pause();
        if (mounted) {
          setState(() => _sleepChoice = 0);
          _hud(Icons.bedtime_rounded, 'Temporizador: en pausa');
        }
      });
      _hud(Icons.bedtime_rounded, 'Se pausará en $choice min');
    } else if (choice == -1) {
      _hud(Icons.bedtime_rounded, 'Se detendrá al terminar el episodio');
    }
  }

  // ───────────────────────── Ajustes extra ─────────────────────────
  Future<void> _setProp(String k, String v) async {
    try {
      final p = _player?.platform;
      if (p != null) await (p as dynamic).setProperty(k, v);
    } catch (_) {}
  }

  Future<void> _applyTweaks(Player player) async {
    final pl = player.platform;
    if (pl != null) {
      Future<void> set(String k, String v) async {
        try {
          await (pl as dynamic).setProperty(k, v);
        } catch (_) {}
      }

      if (_subDelay != 0) await set('sub-delay', _subDelay.toStringAsFixed(2));
      if (_subScale != 1.0) await set('sub-scale', _subScale.toStringAsFixed(2));
      if (_audioDelay != 0) await set('audio-delay', _audioDelay.toStringAsFixed(2));
      if (_brightness != 0) await set('brightness', _brightness.round().toString());
      if (_contrast != 0) await set('contrast', _contrast.round().toString());
      if (_saturation != 0) await set('saturation', _saturation.round().toString());
    }
    if (_loopOn) {
      try {
        await player.setPlaylistMode(PlaylistMode.single);
      } catch (_) {}
    }
  }

  double _round1(double v) => (v * 10).round() / 10;

  void _adjSubDelay(double d) {
    setState(() => _subDelay = _round1((_subDelay + d).clamp(-10.0, 10.0)));
    _setProp('sub-delay', _subDelay.toStringAsFixed(2));
  }

  void _adjSubScale(double d) {
    setState(() => _subScale = _round1((_subScale + d).clamp(0.5, 2.5)));
    _setProp('sub-scale', _subScale.toStringAsFixed(2));
  }

  void _adjAudioDelay(double d) {
    setState(() => _audioDelay = _round1((_audioDelay + d).clamp(-5.0, 5.0)));
    _setProp('audio-delay', _audioDelay.toStringAsFixed(2));
  }

  void _adjColor(String prop, int d) {
    double c(double v) => (v + d).clamp(-100, 100).toDouble();
    setState(() {
      if (prop == 'brightness') {
        _brightness = c(_brightness);
      } else if (prop == 'contrast') {
        _contrast = c(_contrast);
      } else {
        _saturation = c(_saturation);
      }
    });
    final v = prop == 'brightness' ? _brightness : (prop == 'contrast' ? _contrast : _saturation);
    _setProp(prop, v.round().toString());
  }

  void _resetColor() {
    setState(() {
      _brightness = 0;
      _contrast = 0;
      _saturation = 0;
    });
    _setProp('brightness', '0');
    _setProp('contrast', '0');
    _setProp('saturation', '0');
  }

  void _resetSubAudio() {
    setState(() {
      _subDelay = 0;
      _subScale = 1.0;
      _audioDelay = 0;
    });
    _setProp('sub-delay', '0');
    _setProp('sub-scale', '1');
    _setProp('audio-delay', '0');
  }

  Future<void> _toggleLoop() async {
    setState(() => _loopOn = !_loopOn);
    try {
      await _player?.setPlaylistMode(_loopOn ? PlaylistMode.single : PlaylistMode.none);
    } catch (_) {}
    _hud(Icons.repeat_one_rounded, _loopOn ? 'Repetir: activado' : 'Repetir: desactivado');
  }

  Future<void> _toggleAutoNext() async {
    setState(() => _autoNext = !_autoNext);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('player_autonext', _autoNext);
    } catch (_) {}
  }

  // ───────────────────────── Paneles ─────────────────────────
  void _openPanel(_Panel p) {
    if (_panel == p) {
      _closePanel();
      return;
    }
    if (p == _Panel.episodes) {
      final eps = widget.episodes ?? [];
      final idx = eps.indexWhere((e) => e.number == widget.episode);
      _epScroll?.dispose();
      _epScroll = ScrollController(initialScrollOffset: idx > 2 ? (idx - 2) * 82.0 : 0);
    }
    setState(() {
      _panel = p;
      _showControls = true;
    });
    _hideTimer?.cancel();
  }

  void _closePanel() {
    if (_panel == _Panel.none) return;
    setState(() => _panel = _Panel.none);
    _rootFocus.requestFocus();
    _armHideTimer();
  }

  // ───────────────────────── Ventana ─────────────────────────
  Future<void> _toggleFullscreen() async {
    try {
      if (_isFullscreen) {
        await windowManager.setFullScreen(false);
        if (mounted) setState(() => _isFullscreen = false);
      } else {
        if (_isPip) await _exitPip();
        await windowManager.setFullScreen(true);
        if (mounted) setState(() => _isFullscreen = true);
      }
    } catch (e) {
      debugPrint('[Player] fullscreen: $e');
      try {
        setState(() => _isFullscreen = !_isFullscreen);
        await SystemChrome.setEnabledSystemUIMode(
          _isFullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } catch (_) {}
    }
    _onUserActivity();
  }

  Future<void> _togglePip() async {
    _closePanel();
    try {
      if (_isPip) {
        await _exitPip();
      } else {
        try {
          _windowBoundsBeforePip = await windowManager.getBounds();
        } catch (_) {}
        if (_isFullscreen) {
          await windowManager.setFullScreen(false);
          setState(() => _isFullscreen = false);
        }
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setSize(const Size(420, 260));
        await windowManager.setAlignment(Alignment.bottomRight);
        setState(() => _isPip = true);
      }
    } catch (e) {
      debugPrint('[Player] pip: $e');
      _hud(Icons.error_outline_rounded, 'PiP no disponible en esta plataforma');
    }
  }

  Future<void> _restoreWindowFromPip() async {
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(800, 500));
      final b = _windowBoundsBeforePip;
      if (b != null) {
        await windowManager.setBounds(b);
      } else {
        await windowManager.setSize(const Size(1280, 720));
        await windowManager.center();
      }
    } catch (e) {
      debugPrint('[Player] restore window: $e');
    }
  }

  Future<void> _exitPip() async {
    await _restoreWindowFromPip();
    if (mounted) setState(() => _isPip = false);
  }

  Future<void> _exit() async {
    _saveProgressNow();
    if (mounted) await Navigator.of(context).maybePop();
  }

  // ───────────────────────── Formato ─────────────────────────
  String _fmt(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ───────────────────────── Teclado ─────────────────────────
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;

    if (k == LogicalKeyboardKey.escape) {
      if (repeat) return KeyEventResult.handled;
      if (_showHelp) {
        setState(() => _showHelp = false);
      } else if (_panel != _Panel.none) {
        _closePanel();
      } else if (_isFullscreen) {
        _toggleFullscreen();
      } else if (_isPip) {
        _exitPip();
      } else {
        _exit();
      }
      return KeyEventResult.handled;
    }

    if (_showHelp) {
      if (!repeat) setState(() => _showHelp = false);
      return KeyEventResult.handled;
    }

    // Atajos para abrir/cerrar paneles (válidos incluso con un panel abierto)
    if (!repeat) {
      if (k == LogicalKeyboardKey.keyC) {
        _openPanel(_Panel.tracks);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyE && (widget.episodes?.isNotEmpty ?? false)) {
        _openPanel(_Panel.episodes);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyV) {
        _openPanel(_Panel.servers);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyS) {
        _openPanel(_Panel.settings);
        return KeyEventResult.handled;
      }
    }

    // Con un panel abierto, flechas/Enter navegan por sus elementos
    if (_panel != _Panel.none) return KeyEventResult.ignored;

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ch = e.character;

    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(Duration(seconds: shift ? -30 : -10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(Duration(seconds: shift ? 30 : 10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume(_volume + 5);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume(_volume - 5);
      return KeyEventResult.handled;
    }

    if (repeat) return KeyEventResult.handled;

    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.keyK ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      _togglePlay();
    } else if (k == LogicalKeyboardKey.keyM) {
      _toggleMute();
    } else if (k == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
    } else if (k == LogicalKeyboardKey.keyN) {
      if (_hasNext) _goNext();
    } else if (k == LogicalKeyboardKey.keyI) {
      _contextAction();
    } else if (k == LogicalKeyboardKey.keyA) {
      _cycleFit();
    } else if (k == LogicalKeyboardKey.keyH || ch == '?') {
      setState(() => _showHelp = true);
    } else if (k == LogicalKeyboardKey.home) {
      _seekToFrac(0);
    } else if (ch == '<' || ch == ',') {
      _stepSpeed(-1);
    } else if (ch == '>' || ch == '.') {
      _stepSpeed(1);
    } else if (ch != null && ch.length == 1 && int.tryParse(ch) != null) {
      _seekToFrac(int.parse(ch) / 10);
    } else {
      return KeyEventResult.ignored;
    }
    _onUserActivity();
    return KeyEventResult.handled;
  }

  // ───────────────────────── Toques / ratón ─────────────────────────
  void _handleVideoTap(Offset pos, double width) {
    if (_showIdleScreen) {
      _dismissIdleScreen();
      return;
    }
    if (_panel != _Panel.none) {
      _closePanel();
      return;
    }
    final now = DateTime.now();
    final isDouble = _lastTap != null && now.difference(_lastTap!) < const Duration(milliseconds: 280);
    _lastTap = isDouble ? null : now;
    if (isDouble) {
      _player?.playOrPause(); // revierte el play/pausa del primer toque
      final f = width <= 0 ? 0.5 : pos.dx / width;
      if (f < 0.33) {
        _seekBy(const Duration(seconds: -10));
      } else if (f > 0.67) {
        _seekBy(const Duration(seconds: 10));
      } else {
        _toggleFullscreen();
      }
      return;
    }
    _togglePlay();
  }

  // ───────────────────────── Build ─────────────────────────
  @override
  Widget build(BuildContext context) {
    final controlsVisible = _showControls && !_isPip && !_showIdleScreen;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: _onUserActivity,
          cursor: (_showControls || _panel != _Panel.none) ? SystemMouseCursors.basic : SystemMouseCursors.none,
          child: Listener(
            onPointerSignal: (signal) {
              // La rueda solo ajusta el volumen sobre el vídeo (no con paneles abiertos)
              if (signal is PointerScrollEvent && _panel == _Panel.none && !_isPip) {
                _setVolume(_volume + (signal.scrollDelta.dy < 0 ? 5 : -5));
              }
            },
            child: LayoutBuilder(builder: (context, box) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _handleVideoTap(d.localPosition, box.maxWidth),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildVideo(),

                    // Degradados
                    _edgeGradient(top: true, visible: controlsVisible),
                    _edgeGradient(top: false, visible: controlsVisible && _durationReady),

                    _centerFlash(),
                    _topBar(controlsVisible),
                    _actionCard(controlsVisible),
                    _dock(controlsVisible),
                    _errorToast(),
                    _hudWidget(),

                    if (_isPip) _pipOverlay(),

                    // Paneles
                    _scrim(),
                    _panelLayer(context),

                    // Ayuda de atajos
                    _helpOverlay(),

                    if (_showIdleScreen) _idleScreen(),

                    // Buffering
                    if (_buffering && _player != null && !_showIdleScreen)
                      Center(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x99000000)),
                          padding: const EdgeInsets.all(16),
                          child: const CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _fade({required bool visible, required Widget child, Offset offset = const Offset(0, 0.15)}) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : offset,
        duration: _mid,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(opacity: visible ? 1 : 0, duration: _mid, child: child),
      ),
    );
  }

  Widget _edgeGradient({required bool top, required bool visible}) {
    return Positioned(
      top: top ? 0 : null,
      bottom: top ? null : 0,
      left: 0,
      right: 0,
      height: top ? 140 : 220,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: _mid,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: [Colors.black.withValues(alpha: top ? 0.75 : 0.88), Colors.transparent],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────── Vídeo / carga / error ─────────────────────────
  Widget _buildVideo() {
    if (_error != null) return _errorView();
    if (_loadingStreams || _player == null || _video == null || !_durationReady) return _loadingView();

    final videoChild = Video(
      controller: _video!,
      controls: NoVideoControls,
      fill: Colors.black,
      fit: _fitBox(_fit),
      // Solo se ven los subtítulos del motor (evita doble capa)
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        style: TextStyle(fontSize: 0, color: Colors.transparent),
        padding: EdgeInsets.zero,
      ),
    );

    final forced = _fitRatio(_fit);
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth <= 0 || c.maxHeight <= 0) return const SizedBox.shrink();
        if (forced == null) return SizedBox.expand(child: videoChild);
        double w, h;
        if (c.maxWidth / c.maxHeight > forced) {
          h = c.maxHeight;
          w = h * forced;
        } else {
          w = c.maxWidth;
          h = w / forced;
        }
        return Center(child: SizedBox(width: w, height: h, child: videoChild));
      }),
    );
  }

  Widget _brandTitle({double logoHeight = 56, double fontSize = 26}) {
    final logo = widget.logo;
    final base = widget.title.split('·').first.trim();
    final text = Text(
      base,
      maxLines: 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: fontSize,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        shadows: const [Shadow(color: Colors.black87, blurRadius: 12)],
      ),
    );
    if (logo == null || logo.isEmpty) return text;
    return SizedBox(
      height: logoHeight,
      child: CachedNetworkImage(
        imageUrl: logo,
        fit: BoxFit.contain,
        memCacheHeight: (logoHeight * 3).round(),
        errorWidget: (_, __, ___) => text,
      ),
    );
  }

  Widget _loadingView() {
    final bg = widget.backdrop ?? widget.poster;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bg != null && bg.isNotEmpty)
          CachedNetworkImage(
            imageUrl: bg,
            fit: BoxFit.cover,
            memCacheWidth: 1280,
            fadeInDuration: _mid,
            errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black),
          )
        else
          const ColoredBox(color: Colors.black),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 1.0,
              colors: [Colors.black.withValues(alpha: 0.55), Colors.black.withValues(alpha: 0.92)],
            ),
          ),
        ),
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _brandTitle(),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(color: _accent, strokeWidth: 3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _loadingStatus,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  if (_episodeLabel != null) ...[
                    const SizedBox(height: 6),
                    Text(_episodeLabel!, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorView() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _accent.withValues(alpha: 0.14),
                border: Border.all(color: _accent.withValues(alpha: 0.4)),
              ),
              child: const Icon(Icons.error_outline_rounded, color: _accent, size: 36),
            ),
            const SizedBox(height: 18),
            const Text(
              'No se pudo reproducir',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13.5, height: 1.4),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                _PillButton(label: 'Reintentar', icon: Icons.refresh_rounded, onTap: _retry, primary: true),
                if (_servers.length > 1)
                  _PillButton(
                    label: 'Cambiar servidor',
                    icon: Icons.dns_rounded,
                    onTap: () => _openPanel(_Panel.servers),
                  ),
                _PillButton(label: 'Volver', icon: Icons.arrow_back_rounded, onTap: _exit),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? get _episodeLabel {
    final s = widget.season ?? widget.seasonNumber;
    final e = widget.episode;
    if (s == null || e == null) return null;
    final t = _currentEpisodeInfo?.title;
    final head = 'Temporada $s · Episodio $e';
    return (t != null && t.isNotEmpty) ? '$head — $t' : head;
  }

  // ───────────────────────── Barra superior ─────────────────────────
  Widget _topBar(bool visible) {
    final sub = _episodeLabel;
    final base = widget.title.split('·').first.trim();
    final showLogo = widget.logo != null && widget.logo!.isNotEmpty;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _fade(
        visible: visible,
        offset: const Offset(0, -0.4),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 20, 0),
            child: Row(
              children: [
                _GlassBtn(icon: Icons.arrow_back_rounded, tooltip: 'Volver (Esc)', onTap: _exit),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showLogo)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            height: 32,
                            child: CachedNetworkImage(
                              imageUrl: widget.logo!,
                              fit: BoxFit.contain,
                              alignment: Alignment.centerLeft,
                              memCacheHeight: 96,
                              errorWidget: (_, __, ___) => _titleText(base),
                            ),
                          ),
                        )
                      else
                        _titleText(base),
                      if (sub != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_sleepChoice != 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _InfoPill(
                      icon: Icons.bedtime_rounded,
                      text: _sleepChoice == -1 ? 'Fin del episodio' : '$_sleepChoice min',
                    ),
                  ),
                if (_speed != 1.0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _InfoPill(icon: Icons.speed_rounded, text: '${_speed}x'),
                  ),
                if (_durationReady && _duration > Duration.zero && MediaQuery.of(context).size.width > 640)
                  ValueListenableBuilder<Duration>(
                    valueListenable: _posN,
                    builder: (_, pos, __) {
                      final rem = _duration - pos;
                      final end = DateTime.now().add(rem.isNegative ? Duration.zero : rem);
                      return _InfoPill(icon: Icons.schedule_rounded, text: 'Termina a las ${_hhmm(end)}');
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleText(String t) => Text(
        t,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: -0.2),
      );

  // ───────────────────────── Dock inferior ─────────────────────────
  Widget _dock(bool controlsVisible) {
    final w = MediaQuery.of(context).size.width;
    final compact = w < 820;
    final visible = controlsVisible && _durationReady;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: _fade(
        visible: visible,
        offset: const Offset(0, 0.3),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onUserActivity, // absorbe toques para no pausar al tocar el dock
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(compact ? 12 : 28, 0, compact ? 12 : 28, compact ? 8 : 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _progressBar(),
                  const SizedBox(height: 4),
                  _buttonsRow(compact),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _progressBar() {
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: ValueListenableBuilder<Duration>(
            valueListenable: _posN,
            builder: (_, pos, __) => Text(_fmt(pos), style: _timeStyle),
          ),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final barW = c.maxWidth;
            return MouseRegion(
              onHover: (e) {
                if (_duration.inMilliseconds <= 0 || barW <= 0) return;
                _hoverN.value = (e.localPosition.dx / barW).clamp(0.0, 1.0);
              },
              onExit: (_) => _hoverN.value = null,
              child: SizedBox(
                height: 30,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    ValueListenableBuilder<Duration>(
                      valueListenable: _posN,
                      builder: (_, pos, __) => ValueListenableBuilder<Duration>(
                        valueListenable: _bufN,
                        builder: (_, buf, __) {
                          final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1.0;
                          final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
                          final bufMs = buf.inMilliseconds.toDouble().clamp(posMs, maxMs);
                          return Focus(
                            canRequestFocus: false,
                            descendantsAreFocusable: false,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                activeTrackColor: _accent,
                                secondaryActiveTrackColor: Colors.white38,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                                overlayColor: _accent.withValues(alpha: 0.2),
                                trackShape: const RoundedRectSliderTrackShape(),
                              ),
                              child: Slider(
                                value: posMs,
                                max: maxMs,
                                secondaryTrackValue: bufMs,
                                onChangeStart: (_) {
                                  _isDragging = true;
                                  _hideTimer?.cancel();
                                },
                                onChanged: (v) {
                                  _position = Duration(milliseconds: v.toInt());
                                  _posN.value = _position;
                                },
                                onChangeEnd: (v) async {
                                  final t = Duration(milliseconds: v.toInt());
                                  await _player?.seek(t);
                                  _isDragging = false;
                                  _armHideTimer();
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    ValueListenableBuilder<double?>(
                      valueListenable: _hoverN,
                      builder: (_, f, __) {
                        if (f == null) return const SizedBox.shrink();
                        final t = Duration(milliseconds: (_duration.inMilliseconds * f).round());
                        return Positioned(
                          left: (barW * f - 30).clamp(0.0, (barW - 60).clamp(0.0, double.infinity)),
                          top: -32,
                          child: IgnorePointer(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                              decoration: BoxDecoration(
                                color: const Color(0xEE000000),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                _fmt(t),
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
        SizedBox(
          width: 52,
          child: Text(_fmt(_duration), textAlign: TextAlign.right, style: _timeStyle),
        ),
      ],
    );
  }

  static const _timeStyle = TextStyle(
    color: Colors.white70,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget _buttonsRow(bool compact) {
    final hasEpisodes = widget.episodes != null && widget.episodes!.isNotEmpty;
    final hasTracks = _audioTracks.isNotEmpty || _subtitleTracks.isNotEmpty || _externalSubs.isNotEmpty;

    return Row(
      children: [
        _CtrlBtn(
          icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: _playing ? 'Pausar (Espacio)' : 'Reproducir (Espacio)',
          onTap: _togglePlay,
          size: 32,
          filled: true,
        ),
        const SizedBox(width: 6),
        if (_hasNext) _CtrlBtn(icon: Icons.skip_next_rounded, tooltip: 'Siguiente (N)', onTap: _goNext, size: 26),
        if (!compact) ...[
          _CtrlBtn(
            icon: Icons.replay_10_rounded,
            tooltip: 'Retroceder 10 s (←)',
            onTap: () => _seekBy(const Duration(seconds: -10)),
          ),
          _CtrlBtn(
            icon: Icons.forward_10_rounded,
            tooltip: 'Adelantar 10 s (→)',
            onTap: () => _seekBy(const Duration(seconds: 10)),
          ),
        ],
        _volumeGroup(compact),
        const Spacer(),
        if (hasEpisodes)
          _CtrlBtn(
            icon: Icons.video_library_rounded,
            tooltip: 'Episodios (E)',
            onTap: () => _openPanel(_Panel.episodes),
            active: _panel == _Panel.episodes,
          ),
        if (hasTracks)
          _CtrlBtn(
            icon: Icons.subtitles_rounded,
            tooltip: 'Audio y subtítulos (C)',
            onTap: () => _openPanel(_Panel.tracks),
            active: _panel == _Panel.tracks,
          ),
        if (_servers.isNotEmpty)
          _CtrlBtn(
            icon: Icons.dns_rounded,
            tooltip: 'Servidores (V)',
            onTap: () => _openPanel(_Panel.servers),
            active: _panel == _Panel.servers,
          ),
        _CtrlBtn(
          icon: Icons.tune_rounded,
          tooltip: 'Ajustes (S)',
          onTap: () => _openPanel(_Panel.settings),
          active: _panel == _Panel.settings,
        ),
        _CtrlBtn(
          icon: _isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          tooltip: 'Pantalla completa (F)',
          onTap: _toggleFullscreen,
          active: _isFullscreen,
        ),
      ],
    );
  }

  Widget _volumeGroup(bool compact) {
    final icon = _volume == 0
        ? Icons.volume_off_rounded
        : (_volume < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
    return MouseRegion(
      onEnter: (_) => setState(() => _volHover = true),
      onExit: (_) => setState(() => _volHover = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CtrlBtn(icon: icon, tooltip: 'Silenciar (M)', onTap: _toggleMute),
          if (!compact)
            AnimatedSize(
              duration: _mid,
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: _volHover ? 104 : 0,
                child: _volHover
                    ? Focus(
                        canRequestFocus: false,
                        descendantsAreFocusable: false,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                            overlayShape: SliderComponentShape.noOverlay,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            value: _volume,
                            max: 100,
                            onChanged: (v) => _setVolume(v, hud: false),
                          ),
                        ),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  // ───────────────────────── Acción contextual (omitir / siguiente) ─────────────────────────
  Widget _actionCard(bool controlsVisible) {
    Widget? card;
    switch (_skipMode) {
      case _SkipMode.intro:
        card = _PillButton(
          key: const ValueKey('intro'),
          label: 'Omitir intro',
          icon: Icons.fast_forward_rounded,
          onTap: _skipIntro,
          primary: true,
          large: true,
        );
        break;
      case _SkipMode.outro:
        card = _PillButton(
          key: const ValueKey('outro'),
          label: 'Omitir créditos',
          icon: Icons.fast_forward_rounded,
          onTap: _skipOutro,
          primary: true,
          large: true,
        );
        break;
      case _SkipMode.next:
        card = _nextCard();
        break;
      case _SkipMode.none:
        break;
    }

    return AnimatedPositioned(
      duration: _mid,
      curve: Curves.easeOutCubic,
      right: 28,
      bottom: (controlsVisible && _durationReady) ? 118 : 36,
      child: AnimatedSwitcher(
        duration: _mid,
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.25, 0), end: Offset.zero).animate(a),
            child: c,
          ),
        ),
        child: card ?? const SizedBox.shrink(key: ValueKey('none')),
      ),
    );
  }

  Widget _nextCard() {
    final ep = _nextEpisode;
    final dl = _nextDl;
    final isLocal = widget.localPath != null && dl != null;
    final num = isLocal ? dl.episode : ep?.number;
    final name = isLocal ? dl.displayTitle : ((ep?.title != null && ep!.title!.isNotEmpty) ? ep.title! : 'Episodio $num');
    final still = isLocal ? null : ep?.still;

    return Material(
      key: const ValueKey('next'),
      color: const Color(0xF2161A22),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _goNext,
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 112,
                  height: 63,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (still != null && still.isNotEmpty)
                        CachedNetworkImage(imageUrl: still, fit: BoxFit.cover, memCacheWidth: 320)
                      else
                        const ColoredBox(color: Color(0xFF12151C)),
                      Center(
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black54, border: Border.all(color: Colors.white54)),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Siguiente · E$num',
                      style: const TextStyle(color: _accent, fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700, height: 1.2),
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

  // ───────────────────────── HUD / flash / toast ─────────────────────────
  Widget _centerFlash() {
    final icon = _flashIcon;
    if (icon == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Center(
        child: TweenAnimationBuilder<double>(
          key: ValueKey(_flashTick),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOut,
          builder: (_, v, __) => Opacity(
            opacity: (1 - v).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.7 + 0.55 * v,
              child: Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x99000000)),
                child: Icon(icon, color: Colors.white, size: 50),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hudWidget() {
    return Align(
      alignment: const Alignment(0, -0.72),
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _hudVisible ? 1 : 0,
          duration: _fast,
          child: AnimatedScale(
            scale: _hudVisible ? 1 : 0.92,
            duration: _fast,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xE6101319),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24)],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_hudIcon, color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    _hudText,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  if (_hudValue != null) ...[
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 96,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _hudValue!.clamp(0.0, 1.0),
                          minHeight: 5,
                          color: _accent,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorToast() {
    final show = _streamError != null && _player != null && _error == null;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 130,
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: _mid,
          child: Center(
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              decoration: BoxDecoration(
                color: const Color(0xF2161A22),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: _accent.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: _accent, size: 20),
                  const SizedBox(width: 8),
                  const Text('Problema al reproducir', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  if (_servers.length > 1)
                    _PillButton(
                      label: 'Cambiar servidor',
                      icon: Icons.dns_rounded,
                      onTap: () {
                        setState(() => _streamError = null);
                        _openPanel(_Panel.servers);
                      },
                      primary: true,
                    ),
                  IconButton(
                    onPressed: () => setState(() => _streamError = null),
                    icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pipOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_showControls,
        child: AnimatedOpacity(
          opacity: _showControls ? 1 : 0,
          duration: _fast,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0x44000000))),
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    _GlassBtn(icon: Icons.open_in_full_rounded, tooltip: 'Salir de PiP', onTap: _togglePip, size: 36),
                    const SizedBox(width: 6),
                    _GlassBtn(icon: Icons.close_rounded, tooltip: 'Cerrar', onTap: _exit, size: 36),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────── Paneles laterales ─────────────────────────
  Widget _scrim() {
    final open = _panel != _Panel.none;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !open,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _closePanel,
          child: AnimatedOpacity(
            opacity: open ? 1 : 0,
            duration: _mid,
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
      ),
    );
  }

  Widget _panelLayer(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final pw = w < 520 ? w * 0.92 : 390.0;
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      child: AnimatedSwitcher(
        duration: _mid,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (cur, prev) => Stack(
          alignment: Alignment.centerRight,
          children: [...prev, if (cur != null) cur],
        ),
        transitionBuilder: (child, anim) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(anim),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: _panel == _Panel.none
            ? const SizedBox.shrink(key: ValueKey('none'))
            : KeyedSubtree(
                key: ValueKey(_panel),
                child: SizedBox(
                  width: pw,
                  height: double.infinity,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: _panelBg,
                      border: Border(left: BorderSide(color: _line)),
                      boxShadow: [BoxShadow(color: Colors.black87, blurRadius: 40)],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: SafeArea(
                        left: false,
                        child: FocusScope(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _panelHeader(),
                              const Divider(height: 1, color: _line),
                              Expanded(child: _panelBody()),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _panelHeader() {
    late IconData icon;
    late String title;
    switch (_panel) {
      case _Panel.servers:
        icon = Icons.dns_rounded;
        title = 'Servidores';
        break;
      case _Panel.episodes:
        icon = Icons.video_library_rounded;
        title = 'Episodios';
        break;
      case _Panel.tracks:
        icon = Icons.subtitles_rounded;
        title = 'Audio y subtítulos';
        break;
      default:
        icon = Icons.tune_rounded;
        title = 'Ajustes';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
      child: Row(
        children: [
          Icon(icon, color: _accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          _GlassBtn(icon: Icons.close_rounded, tooltip: 'Cerrar (Esc)', onTap: _closePanel, size: 38),
        ],
      ),
    );
  }

  Widget _panelBody() {
    switch (_panel) {
      case _Panel.servers:
        return _serversBody();
      case _Panel.episodes:
        return _episodesBody();
      case _Panel.tracks:
        return _tracksBody();
      case _Panel.settings:
        return _settingsBody();
      case _Panel.none:
        return const SizedBox.shrink();
    }
  }

  Widget _serversBody() {
    if (_servers.isEmpty) {
      return const Center(child: Text('No hay servidores', style: TextStyle(color: Colors.white38)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _servers.length,
      itemBuilder: (context, i) {
        final s = _servers[i];
        final active = s.url == _selected?.url;
        final label = s.name.isNotEmpty ? s.name : (s.quality ?? 'Servidor ${i + 1}');
        final sub = [
          s.language,
          s.quality,
          isHlsUrl(s.url, isHlsFlag: s.isHls) ? 'HLS' : (isTsUrl(s.url) ? 'TS' : null),
        ].where((e) => e != null && '$e'.isNotEmpty).join(' · ');
        return _PanelTile(
          title: label,
          subtitle: sub.isEmpty ? null : sub,
          selected: active,
          leading: Icon(active ? Icons.check_circle_rounded : Icons.dns_rounded, color: active ? _accent : Colors.white38),
          onTap: () {
            _closePanel();
            if (!active) _openServer(s);
          },
        );
      },
    );
  }

  Widget _episodesBody() {
    final eps = widget.episodes ?? [];
    return ListView.builder(
      controller: _epScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemExtent: 82,
      itemCount: eps.length,
      itemBuilder: (context, i) {
        final ep = eps[i];
        final active = ep.number == widget.episode;
        return _PanelTile(
          title: (ep.title != null && ep.title!.isNotEmpty) ? ep.title! : 'Episodio ${ep.number}',
          subtitle: active ? 'Reproduciendo ahora' : (ep.overview != null && ep.overview!.isNotEmpty ? ep.overview : null),
          subtitleAccent: active,
          selected: active,
          leading: SizedBox(
            width: 96,
            height: 54,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ep.still != null && ep.still!.isNotEmpty)
                    CachedNetworkImage(imageUrl: ep.still!, fit: BoxFit.cover, memCacheWidth: 288)
                  else
                    const ColoredBox(color: Color(0xFF12151C)),
                  Positioned(
                    left: 6,
                    bottom: 4,
                    child: Text(
                      '${ep.number}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          onTap: () => _goToEpisode(ep),
        );
      },
    );
  }

  Widget _tracksBody() {
    final children = <Widget>[];

    if (_audioTracks.isNotEmpty) {
      children.add(const _SectionLabel('Audio'));
      for (final t in _audioTracks) {
        final sel = _selectedAudio?.id == t.id;
        children.add(_PanelTile(
          title: t.language ?? t.title ?? t.id,
          selected: sel,
          leading: Icon(sel ? Icons.check_circle_rounded : Icons.graphic_eq_rounded, color: sel ? _accent : Colors.white38),
          onTap: () async {
            await _player?.setAudioTrack(t);
            setState(() => _selectedAudio = t);
          },
        ));
      }
    }

    final hasSubs = _subtitleTracks.isNotEmpty || _externalSubs.isNotEmpty;
    if (hasSubs) {
      children.add(const _SectionLabel('Subtítulos'));
      final noneSel = _selectedSubtitle == null && _selectedExternalSub == null;
      children.add(_PanelTile(
        title: 'Desactivados',
        selected: noneSel,
        leading: Icon(noneSel ? Icons.check_circle_rounded : Icons.subtitles_off_rounded, color: noneSel ? _accent : Colors.white38),
        onTap: () async {
          await _player?.setSubtitleTrack(SubtitleTrack.no());
          setState(() {
            _selectedSubtitle = null;
            _selectedExternalSub = null;
          });
        },
      ));
      for (final t in _subtitleTracks) {
        final sel = _selectedExternalSub == null && _selectedSubtitle?.id == t.id;
        children.add(_PanelTile(
          title: t.language ?? t.title ?? t.id,
          subtitle: 'Pista del vídeo',
          selected: sel,
          leading: Icon(sel ? Icons.check_circle_rounded : Icons.closed_caption_rounded, color: sel ? _accent : Colors.white38),
          onTap: () async {
            await _player?.setSubtitleTrack(t);
            setState(() {
              _selectedSubtitle = t;
              _selectedExternalSub = null;
            });
          },
        ));
      }
      for (final s in _externalSubs) {
        final sel = _selectedExternalSub == s.url;
        children.add(_PanelTile(
          title: s.label,
          subtitle: s.lang,
          selected: sel,
          leading: Icon(sel ? Icons.check_circle_rounded : Icons.cloud_download_rounded, color: sel ? _accent : Colors.white38),
          onTap: () async {
            try {
              await _player?.setSubtitleTrack(SubtitleTrack.uri(s.url, title: s.label, language: s.lang));
              setState(() {
                _selectedExternalSub = s.url;
                _selectedSubtitle = null;
              });
            } catch (e) {
              debugPrint('[Player] external sub: $e');
            }
          },
        ));
      }
    }

    if (children.isEmpty) {
      return const Center(child: Text('No hay pistas disponibles', style: TextStyle(color: Colors.white38)));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 16), children: children);
  }

  String _signed(double v, String unit) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}$unit';

  Widget _group(String id, IconData icon, String title, String summary, Widget content) {
    final open = _openGroups.contains(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              focusColor: Colors.white.withValues(alpha: 0.14),
              hoverColor: Colors.white.withValues(alpha: 0.07),
              onTap: () => setState(() {
                if (open) {
                  _openGroups.remove(id);
                } else {
                  _openGroups.add(id);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                child: Row(
                  children: [
                    Icon(icon, color: open ? _accent : Colors.white54, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(summary, style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: _mid,
                      child: const Icon(Icons.expand_more_rounded, color: Colors.white38, size: 22),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: _mid,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(padding: const EdgeInsets.fromLTRB(0, 2, 0, 10), child: content)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _switch(bool v) => IgnorePointer(
        child: Switch(
          value: v,
          activeColor: _accent,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (_) {},
        ),
      );

  Widget _settingsBody() {
    const pad = EdgeInsets.symmetric(horizontal: 16);
    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 20),
      children: [
        _group(
          'speed',
          Icons.speed_rounded,
          'Velocidad',
          '${_speed}x',
          Padding(
            padding: pad,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in _speeds)
                  _OptionChip(
                    label: '${s}x',
                    selected: (s - _speed).abs() < 0.01,
                    autofocus: (s - _speed).abs() < 0.01,
                    onTap: () => _setSpeed(s),
                  ),
              ],
            ),
          ),
        ),
        _group(
          'image',
          _fitIcon(_fit),
          'Imagen',
          _fitLabel(_fit),
          Padding(
            padding: pad,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in _Fit.values)
                  _OptionChip(label: _fitLabel(f), icon: _fitIcon(f), selected: _fit == f, onTap: () => _setFit(f)),
              ],
            ),
          ),
        ),
        _group(
          'subs',
          Icons.closed_caption_rounded,
          'Subtítulos y audio',
          _subDelay != 0 || _subScale != 1.0 || _audioDelay != 0 ? 'Modificado' : '',
          Column(
            children: [
              _Stepper(
                label: 'Tamaño',
                value: '${(_subScale * 100).round()}%',
                onMinus: () => _adjSubScale(-0.1),
                onPlus: () => _adjSubScale(0.1),
              ),
              _Stepper(
                label: 'Retraso de subtítulos',
                value: _signed(_subDelay, ' s'),
                onMinus: () => _adjSubDelay(-0.1),
                onPlus: () => _adjSubDelay(0.1),
              ),
              _Stepper(
                label: 'Sincronía de audio',
                value: _signed(_audioDelay, ' s'),
                onMinus: () => _adjAudioDelay(-0.1),
                onPlus: () => _adjAudioDelay(0.1),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _OptionChip(label: 'Restablecer', icon: Icons.restart_alt_rounded, selected: false, onTap: _resetSubAudio),
                ),
              ),
            ],
          ),
        ),
        _group(
          'color',
          Icons.palette_rounded,
          'Color',
          _brightness != 0 || _contrast != 0 || _saturation != 0 ? 'Modificado' : '',
          Column(
            children: [
              _Stepper(
                label: 'Brillo',
                value: '${_brightness.round()}',
                onMinus: () => _adjColor('brightness', -5),
                onPlus: () => _adjColor('brightness', 5),
              ),
              _Stepper(
                label: 'Contraste',
                value: '${_contrast.round()}',
                onMinus: () => _adjColor('contrast', -5),
                onPlus: () => _adjColor('contrast', 5),
              ),
              _Stepper(
                label: 'Saturación',
                value: '${_saturation.round()}',
                onMinus: () => _adjColor('saturation', -5),
                onPlus: () => _adjColor('saturation', 5),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _OptionChip(label: 'Restablecer', icon: Icons.restart_alt_rounded, selected: false, onTap: _resetColor),
                ),
              ),
            ],
          ),
        ),
        _group(
          'sleep',
          Icons.bedtime_rounded,
          'Temporizador',
          _sleepChoice == 0 ? 'Apagado' : (_sleepChoice == -1 ? 'Fin del episodio' : '$_sleepChoice min'),
          Padding(
            padding: pad,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _OptionChip(label: 'Apagado', selected: _sleepChoice == 0, onTap: () => _setSleep(0)),
                for (final m in const [15, 30, 45, 60])
                  _OptionChip(label: '$m min', selected: _sleepChoice == m, onTap: () => _setSleep(m)),
                if (widget.episode != null)
                  _OptionChip(label: 'Fin del episodio', selected: _sleepChoice == -1, onTap: () => _setSleep(-1)),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Divider(height: 1, color: _line),
        ),
        if (widget.episodes != null && widget.episodes!.isNotEmpty)
          _PanelTile(
            title: 'Reproducir siguiente automáticamente',
            leading: const Icon(Icons.skip_next_rounded, color: Colors.white54),
            trailing: _switch(_autoNext),
            onTap: _toggleAutoNext,
          ),
        _PanelTile(
          title: 'Repetir',
          leading: const Icon(Icons.repeat_one_rounded, color: Colors.white54),
          trailing: _switch(_loopOn),
          onTap: _toggleLoop,
        ),
        _PanelTile(
          title: _isPip ? 'Salir de imagen en imagen' : 'Imagen en imagen',
          leading: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white54),
          onTap: _togglePip,
        ),
        _PanelTile(
          title: 'Crear sala Party',
          leading: const Icon(Icons.groups_rounded, color: Colors.white54),
          onTap: () {
            _closePanel();
            _showCreatePartyDialog();
          },
        ),
        _PanelTile(
          title: 'Atajos de teclado',
          leading: const Icon(Icons.keyboard_rounded, color: Colors.white54),
          onTap: () {
            _closePanel();
            setState(() => _showHelp = true);
          },
        ),
      ],
    );
  }

  // ───────────────────────── Ayuda de atajos ─────────────────────────
  Widget _helpOverlay() {
    const items = <(String, String)>[
      ('Espacio / K', 'Reproducir o pausar'),
      ('← →', 'Retroceder / adelantar 10 s'),
      ('Shift + ← →', '30 s'),
      ('↑ ↓', 'Volumen'),
      ('M', 'Silenciar'),
      ('F', 'Pantalla completa'),
      ('N', 'Siguiente episodio'),
      ('I', 'Omitir intro o créditos'),
      ('0 – 9', 'Saltar al 0 % – 90 %'),
      ('< >', 'Velocidad'),
      ('A', 'Cambiar ajuste de imagen'),
      ('C', 'Audio y subtítulos'),
      ('E', 'Episodios'),
      ('V', 'Servidores'),
      ('S', 'Ajustes'),
      ('Esc', 'Cerrar / salir'),
    ];
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_showHelp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showHelp = false),
          child: AnimatedOpacity(
            opacity: _showHelp ? 1 : 0,
            duration: _mid,
            child: ColoredBox(
              color: const Color(0xCC000000),
              child: Center(
                child: AnimatedScale(
                  scale: _showHelp ? 1 : 0.94,
                  duration: _mid,
                  curve: Curves.easeOutCubic,
                  child: Container(
                    width: 560,
                    constraints: const BoxConstraints(maxWidth: 560),
                    margin: const EdgeInsets.all(20),
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _line),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.keyboard_rounded, color: _accent),
                              SizedBox(width: 10),
                              Text(
                                'Atajos de teclado',
                                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          for (final (k, d) in items)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  Container(
                                    constraints: const BoxConstraints(minWidth: 110),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                                    ),
                                    child: Text(
                                      k,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(d, style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 10),
                          const Text(
                            'Toca dos veces a los lados para saltar 10 s, y al centro para pantalla completa.',
                            style: TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ───────────────────────── Pantalla de pausa ─────────────────────────
  Widget _idleScreen() {
    final art = widget.backdrop ?? widget.poster;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismissIdleScreen,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 600),
          builder: (_, v, child) => Opacity(opacity: v, child: child),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (art != null && art.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: art,
                  fit: BoxFit.cover,
                  memCacheWidth: 1600,
                  errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black),
                )
              else
                const ColoredBox(color: Colors.black),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-1.0, 1.0),
                    radius: 1.4,
                    colors: [
                      Colors.black.withValues(alpha: 0.94),
                      Colors.black.withValues(alpha: 0.55),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: 56,
                bottom: 60,
                right: 56,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: _brandTitle(logoHeight: 52, fontSize: 30)),
                    if (_episodeLabel != null) ...[
                      const SizedBox(height: 10),
                      Text(_episodeLabel!, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    ],
                    const SizedBox(height: 18),
                    const _InfoPill(icon: Icons.pause_circle_outline_rounded, text: 'En pausa · Toca para continuar'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────── Party ─────────────────────────
  Future<void> _showCreatePartyDialog() async {
    await PartyService.instance.init();
    if (!mounted) return;

    final usernameCtrl = TextEditingController(text: PartyService.instance.username ?? '');
    final titleCtrl = TextEditingController(text: widget.title);
    bool isPublic = true;

    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          counterStyle: const TextStyle(color: Colors.white30),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white12),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _accent),
          ),
        );

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Crear sala Party', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: usernameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: deco('Tu nombre de usuario'),
                  maxLength: 24,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: titleCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: deco('Título de la sala'),
                  maxLength: 80,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sala pública', style: TextStyle(color: Colors.white70)),
                  subtitle: Text(
                    isPublic
                        ? 'Cualquiera puede unirse con el código o desde Salas'
                        : 'Solo por código + aceptación del anfitrión',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  value: isPublic,
                  activeColor: _accent,
                  onChanged: (v) => setLocal(() => isPublic = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Crear sala'),
            ),
          ],
        ),
      ),
    );

    final name = usernameCtrl.text.trim();
    final roomTitle = titleCtrl.text.trim();
    usernameCtrl.dispose();
    titleCtrl.dispose();

    if (!mounted) return;
    _rootFocus.requestFocus();
    if (result != true) return;

    try {
      if (name.isNotEmpty) await PartyService.instance.setUsername(name);
      if (PartyService.instance.username == null || PartyService.instance.username!.isEmpty) {
        _hud(Icons.person_off_rounded, 'Necesitas un nombre de usuario');
        return;
      }

      final room = await PartyService.instance.createRoom(
        title: roomTitle.isEmpty ? widget.title : roomTitle,
        contentId: widget.contentId,
        repoId: widget.repo.manifest.id,
        contentType: widget.contentType,
        poster: widget.poster,
        backdrop: widget.backdrop,
        season: widget.season ?? widget.seasonNumber,
        episode: widget.episode,
        language: widget.preferredLanguage,
        isPublic: isPublic,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PartyPlayerPage(room: room, repo: widget.repo)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al crear sala: $e')));
      }
    }
  }
}

// ═════════════════════════ Widgets reutilizables ═════════════════════════

/// Botón de control del dock: sin foco (el teclado siempre controla el player).
class _CtrlBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool active;
  final bool filled;
  final double size;

  const _CtrlBtn({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.active = false,
    this.filled = false,
    this.size = 26,
  });

  @override
  State<_CtrlBtn> createState() => _CtrlBtnState();
}

class _CtrlBtnState extends State<_CtrlBtn> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final box = widget.size + (widget.filled ? 20 : 18);
    final scale = _down ? 0.9 : (_hover ? 1.08 : 1.0);

    Widget btn = AnimatedScale(
      scale: scale,
      duration: _fast,
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: _fast,
        width: box,
        height: box,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: widget.filled
              ? const LinearGradient(colors: [_accent, _accentDark], begin: Alignment.topLeft, end: Alignment.bottomRight)
              : null,
          color: widget.filled ? null : (_hover ? Colors.white.withValues(alpha: 0.14) : Colors.transparent),
          boxShadow: widget.filled
              ? [BoxShadow(color: _accent.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 4))]
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedSwitcher(
              duration: _fast,
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
              child: Icon(
                widget.icon,
                key: ValueKey(widget.icon),
                size: widget.size,
                color: widget.active ? _accent : Colors.white,
              ),
            ),
            if (widget.active && !widget.filled)
              Positioned(
                bottom: 3,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );

    btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: btn,
      ),
    );
    return widget.tooltip == null ? btn : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 500), child: btn);
  }
}

/// Botón circular de cristal (volver, cerrar…).
class _GlassBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  const _GlassBtn({required this.icon, required this.tooltip, required this.onTap, this.size = 44});

  @override
  State<_GlassBtn> createState() => _GlassBtnState();
}

class _GlassBtnState extends State<_GlassBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hover ? 1.08 : 1,
            duration: _fast,
            child: AnimatedContainer(
              duration: _fast,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: _hover ? 0.22 : 0.12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
              ),
              child: Icon(widget.icon, color: Colors.white, size: widget.size * 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final bool large;

  const _PillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.large = false,
  });

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.large ? 50.0 : 40.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.05 : 1,
          duration: _fast,
          child: Container(
            height: h,
            padding: EdgeInsets.symmetric(horizontal: widget.large ? 22 : 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(h),
              gradient: widget.primary
                  ? const LinearGradient(colors: [_accent, _accentDark], begin: Alignment.topLeft, end: Alignment.bottomRight)
                  : null,
              color: widget.primary ? null : Colors.white.withValues(alpha: 0.12),
              border: widget.primary ? null : Border.all(color: Colors.white.withValues(alpha: 0.22)),
              boxShadow: widget.primary
                  ? [BoxShadow(color: _accent.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: Colors.white, size: widget.large ? 24 : 20),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: widget.large ? 15 : 13.5,
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

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 16),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w700)),
    );
  }
}

/// Fila de panel: navegable con flechas + Enter, resalta el elemento activo.
class _PanelTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool subtitleAccent;
  final bool selected;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback onTap;

  const _PanelTile({
    required this.title,
    required this.onTap,
    this.selected = false,
    this.subtitle,
    this.subtitleAccent = false,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: selected ? _accent.withValues(alpha: 0.14) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? _accent.withValues(alpha: 0.6) : Colors.transparent, width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: selected,
          focusColor: Colors.white.withValues(alpha: 0.14),
          hoverColor: Colors.white.withValues(alpha: 0.07),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.9),
                          fontSize: 14,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: subtitleAccent ? _accent : Colors.white38,
                            fontSize: 12,
                            height: 1.25,
                            fontWeight: subtitleAccent ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _accent : Colors.white.withValues(alpha: 0.07),
      shape: StadiumBorder(
        side: BorderSide(color: selected ? _accent : Colors.white.withValues(alpha: 0.14)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        autofocus: autofocus,
        focusColor: Colors.white.withValues(alpha: 0.2),
        hoverColor: Colors.white.withValues(alpha: 0.1),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 16, color: Colors.white), const SizedBox(width: 6)],
              Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fila compacta: etiqueta, valor y botones − / +.
class _Stepper extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _Stepper({required this.label, required this.value, required this.onMinus, required this.onPlus});

  Widget _btn(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white.withValues(alpha: 0.08),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          focusColor: Colors.white.withValues(alpha: 0.2),
          hoverColor: Colors.white.withValues(alpha: 0.12),
          onTap: onTap,
          child: SizedBox(width: 34, height: 34, child: Icon(icon, color: Colors.white, size: 18)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13.5))),
          _btn(Icons.remove_rounded, onMinus),
          SizedBox(
            width: 66,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }
}