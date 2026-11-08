import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
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

enum _VideoFitMode { original, ratio16_9, ratio21_9, ratio16_10, ratio4_3 }

const _accent = Color(0xFFE50914);
const _panel = Color(0xE611141C);
const _card = Color(0xFF161A22);

bool isHlsUrl(String url, {bool isHlsFlag = false}) {
  if (isHlsFlag) return true;
  final u = url.toLowerCase();
  return u.contains('.m3u8') || u.contains('/hls/') || u.contains('format=m3u8');
}

bool isTsUrl(String url) {
  final u = url.toLowerCase();
  return u.contains('.ts') || u.contains('mpegts') || u.contains('mpeg-ts') || u.contains('format=ts');
}

/// Player Desktop — misma reproducción que ya funciona + UI estilo TV.
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
        final epKey =
            'continue_watch_${repoId}_${contentId}_s${season}_e$episode';
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
  List<StreamServer> _servers = [];
  bool _loadingStreams = true;
  String _loadingStatus = 'Buscando servidor…';
  String? _error;
  StreamServer? _selected;

  Player? _player;
  VideoController? _video;
  final List<StreamSubscription> _subs = [];

  bool _playing = false;
  bool _buffering = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isDragging = false;
  double _volume = 100;
  double? _hoverProgressFrac; // 0..1 sobre la barra
  Duration? _hoverProgressTime;

  // UI
  bool _showControls = true;
  Timer? _hideTimer;
  bool _showServers = false;
  bool _showEpisodes = false;
  bool _showTracks = false;
  bool _isFullscreen = false;

  _VideoFitMode _fitMode = _VideoFitMode.original;
  bool _showFitHud = false;
  Timer? _fitHudTimer;

  // Tracks (TS embebidos)
  List<AudioTrack> _audioTracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  AudioTrack? _selectedAudio;
  SubtitleTrack? _selectedSubtitle;

  // External subs (repo / HLS)
  List<ExternalSubtitle> _externalSubs = [];

  // Intro / outro
  double? _introStartSec;
  double? _introEndSec;
  double? _outroStartSec;
  double? _outroEndSec;
  bool _introSkipped = false;
  bool _showSkipIntro = false;
  bool _showSkipOutro = false;

  // Next episode preload
  bool _nextPreloaded = false;
  bool _showNextEpisode = false;

  bool _resumeApplied = false;
  bool _durationReady = false;
  Timer? _progressTimer;
  Timer? _idleTimer;
  Timer? _wakelockTimer;
  bool _showIdleScreen = false;
  static const _continueIndexKey = 'continue_watch_index';

  @override
  void initState() {
    super.initState();
    try {
      DownloadService.instance.setHideOverlay(true);
    } catch (_) {}
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}
    _keepScreenAwake();
    if (widget.localPath != null && widget.localPath!.trim().isNotEmpty) {
      _openLocal(widget.localPath!.trim());
    } else {
      _loadStreams();
    }
    _armHideTimer();
  }

  @override
  void dispose() {
    try {
      DownloadService.instance.setHideOverlay(false);
    } catch (_) {}
    // Siempre salir de fullscreen al cerrar el player (recupera la title bar)
    if (_isFullscreen) {
      _isFullscreen = false;
      try {
        unawaited(windowManager.setFullScreen(false));
      } catch (_) {}
    }
    _hideTimer?.cancel();
    _fitHudTimer?.cancel();
    _progressTimer?.cancel();
    _idleTimer?.cancel();
    _wakelockTimer?.cancel();
    try { WakelockPlus.disable(); } catch (_) {}
    _saveProgressNow();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    unawaited(_player?.dispose());
    _player = null;
    _video = null;
    super.dispose();
  }

  void _onUserActivity([_]) {
    if (!_showControls) setState(() => _showControls = true);
    _armHideTimer();
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    if (_showServers || _showEpisodes || _showTracks) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_showServers || _showEpisodes || _showTracks) return;
      setState(() => _showControls = false);
    });
  }

  double? get _forcedAspectRatio {
    switch (_fitMode) {
      case _VideoFitMode.original:
        return null;
      case _VideoFitMode.ratio16_9:
        return 16 / 9;
      case _VideoFitMode.ratio21_9:
        return 21 / 9;
      case _VideoFitMode.ratio16_10:
        return 16 / 10;
      case _VideoFitMode.ratio4_3:
        return 4 / 3;
    }
  }

  String get _fitModeLabel {
    switch (_fitMode) {
      case _VideoFitMode.original:
        return 'Original';
      case _VideoFitMode.ratio16_9:
        return '16:9';
      case _VideoFitMode.ratio21_9:
        return '21:9';
      case _VideoFitMode.ratio16_10:
        return '16:10';
      case _VideoFitMode.ratio4_3:
        return '4:3';
    }
  }

  IconData get _fitModeIcon {
    switch (_fitMode) {
      case _VideoFitMode.original:
        return Icons.fit_screen_rounded;
      case _VideoFitMode.ratio16_9:
        return Icons.crop_16_9_rounded;
      case _VideoFitMode.ratio21_9:
        return Icons.crop_landscape_rounded;
      case _VideoFitMode.ratio16_10:
        return Icons.crop_5_4_rounded;
      case _VideoFitMode.ratio4_3:
        return Icons.crop_portrait_rounded;
    }
  }

  void _cycleFitMode() {
    final values = _VideoFitMode.values;
    setState(() {
      _fitMode = values[(_fitMode.index + 1) % values.length];
      _showFitHud = true;
    });
    _fitHudTimer?.cancel();
    _fitHudTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showFitHud = false);
    });
    _onUserActivity();
  }

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
        if (servers.isEmpty) _error = 'No se encontraron servidores / streams';
      });

      if (_selected != null) {
        setState(() => _loadingStatus = 'Cargando vídeo…');
        await _openServer(_selected!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingStreams = false;
      });
    }
  }

  void _applySegments(StreamServer server) {
    _introStartSec = null;
    _introEndSec = null;
    _outroStartSec = null;
    _outroEndSec = null;
    _introSkipped = false;
    _showSkipIntro = false;
    _showSkipOutro = false;

    final seg = server.segments;
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

    bool inIntro = false;
    if (!_introSkipped && _introStartSec != null && _introEndSec != null) {
      inIntro = sec >= _introStartSec! && sec <= _introEndSec!;
    }

    bool inOutro = false;
    if (_outroStartSec != null && total > 0) {
      final end = _outroEndSec ?? total;
      if (_outroStartSec! >= total * 0.5) {
        inOutro = sec >= _outroStartSec! && sec <= end;
      }
    }

    // Preload / sugerir siguiente capítulo al 80%
    final hasNext = _hasNextEpisode;
    if (hasNext && total > 30 && sec / total >= 0.80) {
      if (!_nextPreloaded) _nextPreloaded = true;
      if (sec / total >= 0.92) _showNextEpisode = true;
    }

    if (_showSkipIntro != inIntro || _showSkipOutro != inOutro || _showNextEpisode) {
      setState(() {
        _showSkipIntro = inIntro;
        _showSkipOutro = inOutro;
      });
    }
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

  Future<void> _skipIntro() async {
    if (_introEndSec == null) return;
    final target = Duration(milliseconds: (_introEndSec! * 1000).round() + 300);
    await _player?.seek(target);
    setState(() {
      _introSkipped = true;
      _showSkipIntro = false;
    });
  }

  Future<void> _skipOutro() async {
    if (_hasNextEpisode) {
      _goToEpisode(_nextEpisode!);
      return;
    }
    if (_duration > Duration.zero) {
      await _player?.seek(_duration - const Duration(seconds: 1));
    }
    setState(() => _showSkipOutro = false);
  }

  void _goToEpisode(EpisodeInfo ep) {
    final durMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds;
    final almostDone = durMs > 0 && posMs / durMs >= 0.90;
    _saveProgressNow(forceFinished: almostDone);
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => DesktopPlayerPage(
        title: '${widget.title.split('·').first.trim()} · E${ep.number}',
        repo: widget.repo,
        contentId: widget.contentId,
        poster: widget.poster,
        backdrop: widget.backdrop,
        logo: widget.logo,
        contentType: widget.contentType,
        preferredLanguage: widget.preferredLanguage,
        season: widget.seasonNumber ?? widget.season,
        episode: ep.number,
        episodes: widget.episodes,
        seasonNumber: widget.seasonNumber ?? widget.season,
      ),
    ));
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

  /// Siguiente episodio YA DESCARGADO (mismo repo/content/season).
  DownloadItem? get _nextDownloadedEpisode {
    final season = widget.seasonNumber ?? widget.season;
    final ep = widget.episode;
    if (season == null || ep == null) return null;
    DownloadItem? best;
    try {
      for (final it in DownloadService.instance.items) {
        if (it.status != DownloadStatus.completed) continue;
        if (it.repoId != widget.repo.manifest.id) continue;
        if (it.contentId != widget.contentId &&
            !it.contentId.startsWith('${widget.contentId}:')) {
          continue;
        }
        if (it.season != season) continue;
        if (it.episode == null) continue;
        if (it.episode! <= ep) continue;
        if (best == null || it.episode! < best.episode!) best = it;
      }
    } catch (_) {}
    return best;
  }

  void _goToDownloaded(DownloadItem it) {
    final path = it.localPath;
    if (path == null || path.isEmpty) return;
    _saveProgressNow(forceFinished: true);
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => DesktopPlayerPage(
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
      ),
    ));
  }

  Future<void> _openLocal(String path) async {
    setState(() {
      _loadingStreams = false;
      _loadingStatus = 'Cargando vídeo…';
      _buffering = true;
      _error = null;
      _servers = [];
      _selected = null;
      _durationReady = false;
      _resumeApplied = false;
    });
    final url = path;
    debugPrint('[DesktopPlayer] open LOCAL $url');
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
      try {
        final platform = player.platform;
        if (platform != null) {
          await (platform as dynamic).setProperty('sub-visibility', 'yes');
        }
      } catch (_) {}

      final video = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );

      _subs.add(player.stream.playing.listen((v) {
        if (mounted) {
          setState(() => _playing = v);
          _onPlayingChanged(v);
        }
      }));
      _subs.add(player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }));
      _subs.add(player.stream.position.listen((v) {
        if (mounted && !_isDragging) {
          setState(() => _position = v);
          _updateSkipFlags();
        }
      }));
      _subs.add(player.stream.duration.listen((v) {
        if (mounted) {
          setState(() {
            _duration = v;
            if (v.inMilliseconds > 1000) _durationReady = true;
          });
        }
      }));
      _subs.add(player.stream.error.listen((e) {
        final msg = e.toString().trim();
        if (msg.isEmpty) return;
        debugPrint('[DesktopPlayer] local error: $msg');
      }));

      await player.open(Media(url), play: true);
      await player.setVolume(_volume);

      if (!mounted) {
        await player.dispose();
        return;
      }

      // Tracks embebidos (MKV/TS multi-audio/subs)
      _subs.add(player.stream.tracks.listen((tracks) {
        if (!mounted) return;
        final audios = tracks.audio.where((x) => x.id != 'auto' && x.id != 'no').toList();
        final subs = tracks.subtitle.where((x) => x.id != 'auto' && x.id != 'no').toList();
        setState(() {
          _audioTracks = audios;
          _subtitleTracks = subs;
        });
      }));

      // Subs externos: metadatos + archivos .srt/.vtt en la carpeta del vídeo
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
        final videoFile = File(path);
        final dir = videoFile.parent;
        if (await dir.exists()) {
          await for (final ent in dir.list(followLinks: false)) {
            if (ent is! File) continue;
            final low = ent.path.toLowerCase();
            if (!(low.endsWith('.srt') ||
                low.endsWith('.vtt') ||
                low.endsWith('.ass') ||
                low.endsWith('.ssa'))) {
              continue;
            }
            final key = ent.path.replaceAll(r'\', '/').toLowerCase();
            if (seen.contains(key)) continue;
            seen.add(key);
            final base = ent.uri.pathSegments.isNotEmpty
                ? ent.uri.pathSegments.last
                : 'Subtítulo';
            String lang = 'und';
            String label = base;
            final m = RegExp(
              r'([a-z]{2,3})\.(srt|vtt|ass|ssa)$',
              caseSensitive: false,
            ).firstMatch(base);
            if (m != null) {
              final g = m.group(1)!.toLowerCase();
              if (g != 'srt' && g != 'vtt' && g != 'ass' && g != 'ssa') {
                lang = g;
                label = 'Subtítulos (${lang.toUpperCase()})';
              } else {
                label = 'Subtítulo';
              }
            } else {
              label = base.replaceAll(
                  RegExp(r'\.(srt|vtt|ass|ssa)$', caseSensitive: false), '');
              if (label.isEmpty) label = 'Subtítulo';
            }
            external.add(ExternalSubtitle(
              lang: lang,
              label: label,
              url: Uri.file(ent.path).toString(),
            ));
          }
        }
      } catch (e) {
        debugPrint('[DesktopPlayer] scan subs: $e');
      }

      debugPrint('[DesktopPlayer] externalSubs=${external.length}');

      setState(() {
        _player = player;
        _video = video;
        _buffering = false;
        _externalSubs = external;
      });
      unawaited(_applyResume(player));
      _progressTimer?.cancel();
      _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        _saveProgressNow();
      });
      _armHideTimer();
    } catch (e) {
      debugPrint('[DesktopPlayer] local open failed: $e');
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo reproducir el archivo local: $e';
        _buffering = false;
        _loadingStreams = false;
      });
    }
  }

  Future<void> _openServer(StreamServer server) async {
    setState(() {
      _selected = server;
      _buffering = true;
      _loadingStatus = 'Cargando vídeo…';
      _error = null;
      _audioTracks = [];
      _subtitleTracks = [];
      _selectedAudio = null;
      _selectedSubtitle = null;
      _externalSubs = List.from(server.subtitles);
      _nextPreloaded = false;
      _showNextEpisode = false;
      _resumeApplied = false;
      _durationReady = false;
    });
    _applySegments(server);

    final url = server.url.trim();
    if (url.isEmpty) {
      setState(() => _error = 'URL de stream vacía');
      return;
    }

    debugPrint(
        '[DesktopPlayer] open hls=${isHlsUrl(url, isHlsFlag: server.isHls)} ts=${isTsUrl(url)} url=$url');

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

      try {
        final platform = player.platform;
        if (platform != null) {
          await (platform as dynamic).setProperty('demuxer-lavf-analyzeduration', '15');
          await (platform as dynamic).setProperty('demuxer-lavf-probesize', '50000000');
          await (platform as dynamic).setProperty('network-timeout', '60');
          await (platform as dynamic).setProperty('cache', 'yes');
          await (platform as dynamic).setProperty('cache-secs', '30');
          await (platform as dynamic).setProperty('tls-verify', 'no');
          await (platform as dynamic).setProperty('sub-visibility', 'yes');
          // Evitar doble capa de subtítulos (ASS nativo + overlay de texto)
          await (platform as dynamic).setProperty('sub-ass-override', 'force');
          // Preferencias de subtítulos (Ajustes)
          try {
            final prefs = await SharedPreferences.getInstance();
            final size = prefs.getDouble('sub_size') ?? 42;
            final margin = prefs.getDouble('sub_margin_y') ?? 18;
            final border = prefs.getDouble('sub_border') ?? 2;
            final bold = prefs.getBool('sub_bold') ?? true;
            final bg = prefs.getBool('sub_bg') ?? false;
            final color = prefs.getInt('sub_color') ?? 0xFFFFFFFF;
            await (platform as dynamic).setProperty('sub-font-size', size.toStringAsFixed(0));
            await (platform as dynamic).setProperty('sub-margin-y', margin.toStringAsFixed(0));
            await (platform as dynamic).setProperty('sub-border-size', border.toStringAsFixed(0));
            await (platform as dynamic).setProperty('sub-shadow-offset', '0');
            await (platform as dynamic).setProperty('sub-bold', bold ? 'yes' : 'no');
            await (platform as dynamic).setProperty('sub-color', '#${color.toRadixString(16).padLeft(8, '0')}');
            await (platform as dynamic).setProperty('sub-border-style', bg ? '4' : '1'); // 1=outline, 4=bg box
          } catch (_) {
            await (platform as dynamic).setProperty('sub-font-size', '42');
            await (platform as dynamic).setProperty('sub-margin-y', '18');
            await (platform as dynamic).setProperty('sub-border-size', '2');
            await (platform as dynamic).setProperty('sub-shadow-offset', '0');
          }
        }
      } catch (e) {
        debugPrint('[DesktopPlayer] mk props: $e');
      }

      // SOLO controles nuestros: sin controles nativos de media_kit
      final video = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );

      _subs.add(player.stream.playing.listen((v) {
        if (mounted) {
          setState(() => _playing = v);
          _onPlayingChanged(v);
        }
      }));
      _subs.add(player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }));
      _subs.add(player.stream.position.listen((v) {
        if (mounted && !_isDragging) {
          setState(() => _position = v);
          _updateSkipFlags();
        }
      }));
      _subs.add(player.stream.duration.listen((v) {
        if (mounted) {
          setState(() {
            _duration = v;
            if (v.inMilliseconds > 1000) _durationReady = true;
          });
        }
      }));
      _subs.add(player.stream.error.listen((e) {
        final msg = e.toString().trim();
        if (msg.isEmpty) return;
        debugPrint('[DesktopPlayer] error: $msg');
      }));
      _subs.add(player.stream.tracks.listen((tracks) {
        if (!mounted) return;
        final audios = tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
        final subs = tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
        setState(() {
          _audioTracks = audios;
          _subtitleTracks = subs;
          if (_player != null) {
            _selectedAudio = _player!.state.track.audio;
            final cur = _player!.state.track.subtitle;
            if (cur.id != 'auto' && cur.id != 'no') _selectedSubtitle = cur;
          }
        });
      }));

      final headers = <String, String>{...server.headers};
      headers.putIfAbsent(
        'User-Agent',
        () =>
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      );

      await player.open(
        Media(url, httpHeaders: headers.isEmpty ? null : headers),
        play: true,
      );
      await player.setVolume(_volume);

      if (!mounted) {
        await player.dispose();
        return;
      }

      setState(() {
        _player = player;
        _video = video;
        _buffering = false;
      });
      _armHideTimer();
      // Reanudar + guardar progreso (misma lógica que TV)
      unawaited(_applyResume(player));
      _progressTimer?.cancel();
      _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        _saveProgressNow();
      });
    } catch (e) {
      debugPrint('[DesktopPlayer] open failed: $e');
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo abrir el stream: $e';
        _buffering = false;
      });
    }
  }


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
      final pos = (entry['positionMs'] as num?)?.toInt() ??
          (((entry['segundo'] as num?)?.toInt() ?? 0) * 1000);
      final dur = (entry['durationMs'] as num?)?.toInt() ??
          (((entry['durationSec'] as num?)?.toInt() ??
                  (entry['duration'] as num?)?.toInt() ??
                  0) *
              1000);
      if (pos > 1500 && (dur <= 0 || pos < dur * 0.95)) {
        debugPrint('[DesktopPlayer] resume from cache pos=${pos}ms');
        return pos;
      }
    } catch (e) {
      debugPrint('[DesktopPlayer] resolve start pos: $e');
    }
    return widget.startPositionMs;
  }

  Future<void> _applyResume(Player player) async {
    if (_resumeApplied) return;
    _resumeApplied = true;
    final ms = await _resolveStartPositionMs();
    if (ms <= 1500) return;
    try {
      // Esperar un poco a que el demuxer tenga duración
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await player.seek(Duration(milliseconds: ms));
      debugPrint('[DesktopPlayer] seek resume → ${ms}ms');
    } catch (e) {
      debugPrint('[DesktopPlayer] resume seek: $e');
    }
  }

  void _saveProgressNow({bool forceFinished = false}) {
    if (!mounted) return;
    final posMs = _position.inMilliseconds;
    final durMs = _duration.inMilliseconds;
    if (posMs < 2000 && !forceFinished) return;

    // ≥90% = terminado (LibraryService ya lo quita de continuar viendo)
    final finished = forceFinished ||
        (durMs > 0 && posMs / durMs >= 0.90);

    // 1) LibraryService
    try {
      final lib = context.read<LibraryService>();
      lib.saveProgress(
        repoId: widget.repo.manifest.id,
        contentId: widget.contentId,
        title: widget.title,
        poster: widget.poster,
        type: widget.contentType,
        positionMs: finished && durMs > 0 ? durMs : posMs,
        durationMs: durMs,
      );
    } catch (e) {
      debugPrint('[DesktopPlayer] saveProgress lib: $e');
    }

    // 2) SharedPreferences
    unawaited(_saveHistorialToPrefs(
      positionMs: finished && durMs > 0 ? durMs : posMs,
      durationMs: durMs,
      finished: finished,
    ));
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

      final key = (season != null && episode != null)
          ? 'continue_watch_${repoId}_${contentId}_s${season}_e$episode'
          : 'continue_watch_${repoId}_$contentId';

      final payload = <String, dynamic>{
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
      };

      await prefs.setString(key, jsonEncode(payload));

      // Clave de serie también (último episodio visto)
      if (season != null && episode != null) {
        final seriesKey = 'continue_watch_${repoId}_$contentId';
        if (seriesKey != key) {
          await prefs.setString(seriesKey, jsonEncode(payload));
        }
      }

      final index = prefs.getStringList(_continueIndexKey) ?? <String>[];
      index.remove(key);
      index.insert(0, key);
      if (season != null && episode != null) {
        final seriesKey = 'continue_watch_${repoId}_$contentId';
        if (seriesKey != key) {
          index.remove(seriesKey);
          index.insert(0, seriesKey);
        }
      }
      while (index.length > 80) {
        final removed = index.removeLast();
        await prefs.remove(removed);
      }
      await prefs.setStringList(_continueIndexKey, index);
    } catch (e) {
      debugPrint('[DesktopPlayer] saveHistorial prefs: $e');
    }
  }


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
    if (playing) {
      try { WakelockPlus.enable(); } catch (_) {}
      _idleTimer?.cancel();
      if (_showIdleScreen && mounted) {
        setState(() => _showIdleScreen = false);
      }
    } else {
      _idleTimer?.cancel();
      _idleTimer = Timer(const Duration(minutes: 1), () {
        if (!mounted) return;
        if (!_playing) {
          setState(() {
            _showIdleScreen = true;
            _showControls = false;
            _showServers = false;
            _showTracks = false;
            _showEpisodes = false;
          });
        }
      });
    }
  }

  void _dismissIdleScreen() {
    if (!_showIdleScreen) return;
    setState(() => _showIdleScreen = false);
    setState(() => _showControls = true);
    _armHideTimer();
  }

  Widget _idleScreen() {
    final art = widget.backdrop ?? widget.poster;
    final epParts = <String>[];
    if (widget.season != null && widget.episode != null) {
      epParts.add('T${widget.season} · E${widget.episode}');
    }
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismissIdleScreen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (art != null && art.isNotEmpty)
              CachedNetworkImage(
                imageUrl: art,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black),
              )
            else
              const ColoredBox(color: Colors.black),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-1.0, 1.0),
                  radius: 1.35,
                  colors: [
                    Colors.black.withValues(alpha: 0.92),
                    Colors.black.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
            Positioned(
              left: 48,
              bottom: 56,
              right: 48,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.logo != null && widget.logo!.isNotEmpty)
                    SizedBox(
                      height: 48,
                      child: CachedNetworkImage(
                        imageUrl: widget.logo!,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                        errorWidget: (_, __, ___) => Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    )
                  else
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                      ),
                    ),
                  if (epParts.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      epParts.join('  ·  '),
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'En pausa · Haz clic para continuar',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClose() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161A22),
          title: const Text('Cerrar reproductor', style: TextStyle(color: Colors.white)),
          content: const Text(
            '¿Quieres salir? Se guardará tu progreso para continuar después.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Salir'),
            ),
          ],
        );
      },
    );
    if (ok == true && mounted) {
      _saveProgressNow();
      // PopScope bloquea el pop si canPop=false → habilitar y salir
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pop();
      });
    }
  }

  Rect? _windowBoundsBeforeSpecial;

  Future<void> _toggleFullscreen() async {
    try {
      if (_isFullscreen) {
        await windowManager.setFullScreen(false);
        setState(() => _isFullscreen = false);
      } else {
        // Salir de PiP si estaba
        if (_isPip) await _exitPip(restoreFullscreen: false);
        await windowManager.setFullScreen(true);
        setState(() => _isFullscreen = true);
      }
    } catch (e) {
      debugPrint('[DesktopPlayer] fullscreen: $e');
      // Fallback SystemChrome (poco efecto en Windows, pero no rompe)
      try {
        setState(() => _isFullscreen = !_isFullscreen);
        if (_isFullscreen) {
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        } else {
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
      } catch (_) {}
    }
  }

  bool _isPip = false;
  bool _allowPop = false;

  Future<void> _togglePip() async {
    try {
      if (_isPip) {
        await _exitPip();
      } else {
        // Guardar tamaño actual
        try {
          _windowBoundsBeforeSpecial = await windowManager.getBounds();
        } catch (_) {}
        if (_isFullscreen) {
          await windowManager.setFullScreen(false);
          setState(() => _isFullscreen = false);
        }
        // Ventana pequeña siempre encima
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setSize(const Size(420, 260));
        await windowManager.setAlignment(Alignment.bottomRight);
        setState(() => _isPip = true);
      }
    } catch (e) {
      debugPrint('[DesktopPlayer] pip: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PiP requiere package window_manager en pubspec'),
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
      debugPrint('[DesktopPlayer] exit pip: $e');
      setState(() => _isPip = false);
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  /// Hora actual del reloj + hora estimada de fin.
  String get _clockNow {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  String get _clockEnd {
    if (_duration == Duration.zero) return '--:--';
    final remaining = _duration - _position;
    if (remaining.isNegative) return _clockNow;
    final end = DateTime.now().add(remaining);
    return '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _confirmClose();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: _onUserActivity,
        cursor: _showControls ? SystemMouseCursors.basic : SystemMouseCursors.none,
        child: Listener(
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              final dy = signal.scrollDelta.dy;
              // rueda arriba (dy < 0) = subir volumen
              final next = (_volume + (dy < 0 ? 5 : -5)).clamp(0.0, 100.0);
              setState(() => _volume = next);
              _player?.setVolume(next);
              _onUserActivity();
            }
          },
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            // Click en el vídeo = play/pause
            final p = _player;
            if (p != null) {
              if (_playing) {
                p.pause();
              } else {
                p.play();
              }
            }
            // Mostrar controles un momento
            setState(() => _showControls = true);
            _armHideTimer();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // —— VIDEO (sin controles nativos) ——
              _buildVideo(),

              // —— GRADIENTES cuando hay controles ——
              if (_showControls) ...[
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 120,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xCC000000), Colors.transparent],
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 160,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xEE000000), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ],

              // —— TOP BAR (logo, título, reloj) ——
              if (_showControls && _durationReady) _topBar(),

              // —— SKIP INTRO / OUTRO ——
              if (_showSkipIntro)
                Positioned(
                  right: 28,
                  bottom: 120,
                  child: _skipButton('Omitir intro', Icons.skip_next_rounded, _skipIntro),
                ),
              if (_showSkipOutro)
                Positioned(
                  right: 28,
                  bottom: 120,
                  child: _skipButton(
                    _hasNextEpisode ? 'Siguiente capítulo' : 'Omitir créditos',
                    Icons.skip_next_rounded,
                    _skipOutro,
                  ),
                ),

              // —— NEXT EPISODE toast ——
              if (!_showSkipOutro &&
                  ((widget.localPath != null && _nextDownloadedEpisode != null) ||
                      (_showNextEpisode && _nextEpisode != null)))
                Positioned(
                  right: 28,
                  bottom: 120,
                  child: _skipButton(
                    widget.localPath != null && _nextDownloadedEpisode != null
                        ? 'Siguiente: E${_nextDownloadedEpisode!.episode}'
                        : 'Siguiente: E${_nextEpisode!.number}',
                    Icons.play_arrow_rounded,
                    () {
                      if (widget.localPath != null && _nextDownloadedEpisode != null) {
                        _goToDownloaded(_nextDownloadedEpisode!);
                      } else if (_nextEpisode != null) {
                        _goToEpisode(_nextEpisode!);
                      }
                    },
                  ),
                ),

              // —— BOTTOM CONTROLS ——
              if (_showControls && _durationReady) _bottomControls(),

              // —— PANELS ——
              // Fondo semi-invisible: click fuera cierra cualquier panel abierto
              if (_showServers || _showEpisodes || _showTracks)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _showServers = false;
                        _showEpisodes = false;
                        _showTracks = false;
                      });
                      _armHideTimer();
                    },
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
              if (_showServers) _serversPanel(),
              if (_showEpisodes) _episodesPanel(),
              if (_showTracks) _tracksPanel(),

              // Fit mode HUD
              if (_showFitHud)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _fitModeLabel,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                ),

              // Idle (1 min en pausa) como TV
              if (_showIdleScreen) _idleScreen(),

              // Buffering
              if (_buffering && _player != null && !_showIdleScreen)
                const Center(child: CircularProgressIndicator(color: _accent)),
            ],
          ),
        ),
        ),
      ),
    ),
    );
  }

  Widget _buildLoadingScreen() {
    final bg = widget.backdrop ?? widget.poster;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bg != null && bg.isNotEmpty)
          CachedNetworkImage(
            imageUrl: bg,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black),
          )
        else
          const ColoredBox(color: Colors.black),
        Container(color: Colors.black.withValues(alpha: 0.62)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(color: _accent, strokeWidth: 3),
              ),
              const SizedBox(height: 18),
              Text(
                _loadingStatus,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVideo() {
    // Carga / sin duración aún → pantalla con backdrop
    if (_error == null && (_loadingStreams || _player == null || !_durationReady)) {
      return _buildLoadingScreen();
    }
    if (_error != null && _player == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadStreams, child: const Text('Reintentar')),
          ],
        ),
      );
    }
    if (_video == null) {
      return const Center(child: Text('Selecciona un servidor', style: TextStyle(color: Colors.white54)));
    }

    final videoChild = Video(
      controller: _video!,
      controls: NoVideoControls,
      fill: Colors.black,
      fit: BoxFit.fill,
      // Subtítulos: más pequeños y pegados al borde inferior (evita estilo gigante por defecto)
      // Ocultamos el overlay de Flutter; solo se ven los subtítulos del motor (una fila)
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        style: TextStyle(fontSize: 0, color: Colors.transparent),
        padding: EdgeInsets.zero,
      ),
    );

    final forced = _forcedAspectRatio;
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;
          if (maxW <= 0 || maxH <= 0) {
            return const ColoredBox(color: Colors.black);
          }
          if (forced == null) {
            return SizedBox.expand(child: videoChild);
          }
          late final double frameW;
          late final double frameH;
          if (maxW / maxH > forced) {
            frameH = maxH;
            frameW = frameH * forced;
          } else {
            frameW = maxW;
            frameH = frameW / forced;
          }
          return Center(
            child: SizedBox(width: frameW, height: frameH, child: videoChild),
          );
        },
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Volver',
                onPressed: _confirmClose,
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 8),
              // Logo o título
              if (widget.logo != null && widget.logo!.isNotEmpty)
                SizedBox(
                  height: 36,
                  child: CachedNetworkImage(
                    imageUrl: widget.logo!,
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) => Text(
                      widget.title,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
              if (widget.logo != null) const Spacer(),
              // Hora actual · fin
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$_clockNow  ·  Fin $_clockEnd',
                  style: const TextStyle(color: Colors.white70, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomControls() {
    // En PiP solo botón salir
    if (_isPip) {
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
              onTap: () {
                _exitPip();
                _onUserActivity();
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text('Salir de PiP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1.0;
    final posMs = _position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress + hover time preview
            Row(
              children: [
                Text(_fmt(_position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final barW = constraints.maxWidth;
                      return MouseRegion(
                        onHover: (e) {
                          if (_duration.inMilliseconds <= 0 || barW <= 0) return;
                          final frac = (e.localPosition.dx / barW).clamp(0.0, 1.0);
                          final ms = (_duration.inMilliseconds * frac).round();
                          setState(() {
                            _hoverProgressFrac = frac;
                            _hoverProgressTime = Duration(milliseconds: ms);
                          });
                        },
                        onExit: (_) {
                          setState(() {
                            _hoverProgressFrac = null;
                            _hoverProgressTime = null;
                          });
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.5,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                activeTrackColor: _accent,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: _accent,
                              ),
                              child: Slider(
                                value: posMs,
                                max: maxMs,
                                onChangeStart: (_) {
                                  setState(() => _isDragging = true);
                                  _hideTimer?.cancel();
                                },
                                onChanged: (v) => setState(() => _position = Duration(milliseconds: v.toInt())),
                                onChangeEnd: (v) async {
                                  setState(() => _isDragging = false);
                                  await _player?.seek(Duration(milliseconds: v.toInt()));
                                  _armHideTimer();
                                },
                              ),
                            ),
                            if (_hoverProgressFrac != null && _hoverProgressTime != null)
                              Positioned(
                                left: (barW * _hoverProgressFrac! - 24).clamp(0.0, barW - 48),
                                top: -28,
                                child: IgnorePointer(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.black87,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: Text(
                                      _fmt(_hoverProgressTime!),
                                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Text(_fmt(_duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            // Buttons row
            Row(
              children: [
                _ctrlBtn(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  () {
                    final p = _player;
                    if (p == null) return;
                    _playing ? p.pause() : p.play();
                    _onUserActivity();
                  },
                  size: 36,
                ),
                _ctrlBtn(Icons.replay_10_rounded, () {
                  final n = _position - const Duration(seconds: 10);
                  _player?.seek(n < Duration.zero ? Duration.zero : n);
                  _onUserActivity();
                }),
                _ctrlBtn(Icons.forward_10_rounded, () {
                  _player?.seek(_position + const Duration(seconds: 10));
                  _onUserActivity();
                }),
                const SizedBox(width: 8),
                // Volume
                const Icon(Icons.volume_up_rounded, color: Colors.white54, size: 20),
                SizedBox(
                  width: 100,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      activeTrackColor: Colors.white70,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: _volume,
                      max: 100,
                      onChanged: (v) {
                        setState(() => _volume = v);
                        _player?.setVolume(v);
                        _onUserActivity();
                      },
                    ),
                  ),
                ),
                const Spacer(),
                // Capítulos
                if (widget.episodes != null && widget.episodes!.isNotEmpty)
                  _ctrlBtn(
                    Icons.playlist_play_rounded,
                    () {
                      setState(() {
                        _showEpisodes = !_showEpisodes;
                        if (_showEpisodes) {
                          _showServers = false;
                          _showTracks = false;
                        }
                      });
                      _onUserActivity();
                    },
                    active: _showEpisodes,
                    tooltip: 'Capítulos',
                  ),
                // Siguiente capítulo descargado
                if (widget.localPath != null && _nextDownloadedEpisode != null)
                  _ctrlBtn(
                    Icons.skip_next_rounded,
                    () => _goToDownloaded(_nextDownloadedEpisode!),
                    tooltip: 'Siguiente capítulo descargado',
                  ),
                // Audio / subs
                if (_audioTracks.isNotEmpty || _subtitleTracks.isNotEmpty || _externalSubs.isNotEmpty)
                  _ctrlBtn(
                    Icons.subtitles_rounded,
                    () {
                      setState(() {
                        _showTracks = !_showTracks;
                        if (_showTracks) {
                          _showServers = false;
                          _showEpisodes = false;
                        }
                      });
                      _onUserActivity();
                    },
                    active: _showTracks,
                    tooltip: 'Audio y subtítulos',
                  ),
                // Servidores
                _ctrlBtn(
                  Icons.dns_rounded,
                  () {
                    setState(() {
                      _showServers = !_showServers;
                      if (_showServers) {
                        _showEpisodes = false;
                        _showTracks = false;
                      }
                    });
                    _onUserActivity();
                  },
                  active: _showServers,
                  tooltip: 'Servidores',
                ),
                // Party / Sala
                _ctrlBtn(
                  Icons.groups_rounded,
                  () {
                    _onUserActivity();
                    _showCreatePartyDialog();
                  },
                  tooltip: 'Crear sala Party',
                ),
                // Ajustar tamaño (como TV)
                _ctrlBtn(
                  _fitModeIcon,
                  _cycleFitMode,
                  tooltip: 'Ajuste: $_fitModeLabel',
                ),
                // PiP (ventana pequeña siempre encima)
                _ctrlBtn(
                  _isPip ? Icons.picture_in_picture_alt_rounded : Icons.picture_in_picture_rounded,
                  () {
                    _togglePip();
                    _onUserActivity();
                  },
                  active: _isPip,
                  tooltip: _isPip ? 'Salir de PiP' : 'PiP',
                ),
                // Fullscreen
                _ctrlBtn(
                  _isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                  () {
                    _toggleFullscreen();
                    _onUserActivity();
                  },
                  active: _isFullscreen,
                  tooltip: 'Pantalla completa',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _ctrlBtn(IconData icon, VoidCallback onTap, {bool active = false, double size = 26, String? tooltip}) {
    final child = IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, color: active ? _accent : Colors.white, size: size),
    );
    return child;
  }

  Widget _skipButton(String label, IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.black, size: 22),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _serversPanel() {
    return Positioned(
      right: 16,
      bottom: 100,
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('Servidores', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      onPressed: () {
                        setState(() => _showServers = false);
                        _armHideTimer();
                      },
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _servers.length,
                  itemBuilder: (context, i) {
                    final s = _servers[i];
                    final active = s.url == _selected?.url;
                    final label = s.name.isNotEmpty ? s.name : (s.quality ?? 'S${i + 1}');
                    final sub = [s.language, s.quality, isHlsUrl(s.url, isHlsFlag: s.isHls) ? 'HLS' : (isTsUrl(s.url) ? 'TS' : null)]
                        .where((e) => e != null && '$e'.isNotEmpty)
                        .join(' · ');
                    return ListTile(
                      dense: true,
                      selected: active,
                      selectedTileColor: _accent.withValues(alpha: 0.15),
                      title: Text(label, style: TextStyle(color: active ? _accent : Colors.white, fontSize: 13.5)),
                      subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      onTap: () {
                        setState(() => _showServers = false);
                        _openServer(s);
                        _armHideTimer();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _episodesPanel() {
    final eps = widget.episodes ?? [];
    return Positioned(
      right: 16,
      bottom: 100,
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340, maxHeight: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('Capítulos', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      onPressed: () {
                        setState(() => _showEpisodes = false);
                        _armHideTimer();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: eps.length,
                  itemBuilder: (context, i) {
                    final ep = eps[i];
                    final active = ep.number == widget.episode;
                    return ListTile(
                      dense: true,
                      selected: active,
                      selectedTileColor: _accent.withValues(alpha: 0.15),
                      leading: ep.still != null && ep.still!.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 72,
                                height: 40,
                                child: CachedNetworkImage(imageUrl: ep.still!, fit: BoxFit.cover),
                              ),
                            )
                          : CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.white10,
                              child: Text('${ep.number}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ),
                      title: Text(
                        ep.title?.isNotEmpty == true ? ep.title! : 'Episodio ${ep.number}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: active ? _accent : Colors.white, fontSize: 13),
                      ),
                      onTap: () => _goToEpisode(ep),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tracksPanel() {
    final local = widget.localPath?.toLowerCase() ?? '';
    final isTs = (_selected != null && isTsUrl(_selected!.url)) ||
        local.endsWith('.ts') ||
        local.endsWith('.mkv') ||
        local.endsWith('.mp4') ||
        _audioTracks.isNotEmpty;
    return Positioned(
      right: 16,
      bottom: 100,
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 400),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Audio y subtítulos', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                        onPressed: () {
                          setState(() => _showTracks = false);
                          _armHideTimer();
                        },
                      ),
                    ],
                  ),
                ),
                // Audio (TS / MKV / multi-pista)
                if (_audioTracks.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('Audio', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  for (final t in _audioTracks)
                    ListTile(
                      dense: true,
                      selected: _selectedAudio?.id == t.id,
                      selectedTileColor: _accent.withValues(alpha: 0.12),
                      title: Text(
                        t.language ?? t.title ?? t.id,
                        style: TextStyle(
                          color: _selectedAudio?.id == t.id ? _accent : Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      onTap: () async {
                        await _player?.setAudioTrack(t);
                        setState(() => _selectedAudio = t);
                      },
                    ),
                ],
                // Subtítulos embebidos (TS)
                if (_subtitleTracks.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('Subtítulos (pista)', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  ListTile(
                    dense: true,
                    title: const Text('Desactivados', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    onTap: () async {
                      await _player?.setSubtitleTrack(SubtitleTrack.no());
                      setState(() => _selectedSubtitle = null);
                    },
                  ),
                  for (final t in _subtitleTracks)
                    ListTile(
                      dense: true,
                      selected: _selectedSubtitle?.id == t.id,
                      selectedTileColor: _accent.withValues(alpha: 0.12),
                      title: Text(
                        t.language ?? t.title ?? t.id,
                        style: TextStyle(
                          color: _selectedSubtitle?.id == t.id ? _accent : Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      onTap: () async {
                        await _player?.setSubtitleTrack(t);
                        setState(() => _selectedSubtitle = t);
                      },
                    ),
                ],
                // Subs externos del repo (HLS o TS)
                if (_externalSubs.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('Subtítulos (repo)', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  for (final s in _externalSubs)
                    ListTile(
                      dense: true,
                      title: Text(s.label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                      subtitle: Text(s.lang, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      onTap: () async {
                        // Cargar subtítulo externo por URL
                        try {
                          await _player?.setSubtitleTrack(
                            SubtitleTrack.uri(s.url, title: s.label, language: s.lang),
                          );
                          setState(() {});
                        } catch (e) {
                          debugPrint('[DesktopPlayer] external sub: $e');
                        }
                      },
                    ),
                ],
                if (_audioTracks.isEmpty && _subtitleTracks.isEmpty && _externalSubs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No hay pistas disponibles', style: TextStyle(color: Colors.white38)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Future<void> _showCreatePartyDialog() async {
    await PartyService.instance.init();
    if (!mounted) return;

    final usernameCtrl = TextEditingController(
      text: PartyService.instance.username ?? '',
    );
    final titleCtrl = TextEditingController(text: widget.title);
    bool isPublic = true;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF161A22),
              title: const Text('Crear sala Party',
                  style: TextStyle(color: Colors.white)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: usernameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Tu nombre de usuario',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                    ),
                    maxLength: 24,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Título de la sala',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                    ),
                    maxLength: 80,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sala pública',
                        style: TextStyle(color: Colors.white70)),
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
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Crear sala'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != true || !mounted) return;

    try {
      final name = usernameCtrl.text.trim();
      if (name.isNotEmpty) {
        await PartyService.instance.setUsername(name);
      }
      if (PartyService.instance.username == null ||
          PartyService.instance.username!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Necesitas un nombre de usuario')),
          );
        }
        return;
      }

      final room = await PartyService.instance.createRoom(
        title: titleCtrl.text.trim().isEmpty ? widget.title : titleCtrl.text.trim(),
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
        MaterialPageRoute(
          builder: (_) => PartyPlayerPage(room: room, repo: widget.repo),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al crear sala: $e')),
        );
      }
    }
  }
}
