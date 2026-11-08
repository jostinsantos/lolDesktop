import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/models/stream_server.dart';
import '../../../../data/models/stream_badges.dart';
import '../../../../data/models/repo_manifest.dart';
import 'cast_sheets.dart' show CastMediaType;
import 'cast_sheets.dart';
import 'player_transmission.dart';

/// Player dual:
/// - HLS / m3u8 / mp4 → video_player (video + audio correctos)
/// - TS / mpegts      → media_kit (pistas de audio y subtitulos embebidos)
class PlayerPage extends StatefulWidget {
  final String title;
  final String url;
  final String? repoId;
  final String? contentId;
  final String? poster;
  final String? backdrop;
  /// Logo de la marca/título. Si viene, se muestra en lugar del texto del título.
  final String? logo;
  final String contentType;
  final int startPositionMs;
  final Map<String, String>? headers;
  final List<StreamServer> servers;
  final int initialServerIndex;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final int? nextSeason;
  final int? nextEpisode;
  final String? nextEpisodeId;
  final String? nextEpisodeTitle;
  final List<Map<String, dynamic>> episodeList;
  final InstalledRepo? loadRepo;
  final String preferredLanguage;
  final bool isTv;

  const PlayerPage({
    super.key,
    required this.title,
    required this.url,
    this.repoId,
    this.contentId,
    this.poster,
    this.backdrop,
    this.logo,
    this.contentType = 'movie',
    this.startPositionMs = 0,
    this.headers,
    this.servers = const [],
    this.initialServerIndex = 0,
    this.season,
    this.episode,
    this.episodeTitle,
    this.nextSeason,
    this.nextEpisode,
    this.nextEpisodeId,
    this.nextEpisodeTitle,
    this.episodeList = const [],
    this.loadRepo,
    this.preferredLanguage = '',
    this.isTv = false,
  });

  /// Evita flip a vertical al pasar al siguiente capítulo (dispose vs init).
  static bool preserveLandscape = false;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const accent = Color(0xFFE50914);
  /// Identificador del player (historial continuar viendo).
  static const String playerId = 'dual_player_hls_ts_v1';
  /// Calidad HLS preferida en esta sesión de app (null = automática).
  static String? sessionHlsQuality;
  /// Cache de playlist de episodios por contenido (repoId|contentId).
  static final Map<String, List<Map<String, dynamic>>> _episodeListCache = {};
  /// Calidad real detectada cuando está en modo Automática.
  String? _hlsAutoActual;

  // Intro / outro (segmentos del repo)
  double? _introStartSec;
  double? _introEndSec;
  double? _outroStartSec;
  double? _outroEndSec;
  bool _introSkipped = false;
  bool _showSkipIntro = false;
  bool _showSkipOutro = false;
  int _skipIntroCountdown = 10;
  int _skipOutroCountdown = 10;
  Timer? _skipIntroTimer;
  Timer? _skipOutroTimer;
  bool _introArmed = false;
  bool _outroArmed = false;

  // HLS qualities
  List<({String label, String url})> _hlsQualities = [];
  String _hlsQualityLabel = 'Automática';
  bool _showQualities = false;
  bool _hlsMasterParsed = false;

  // External subs from repo
  List<ExternalSubtitle> _externalSubs = [];

  // Overlay de subtítulos externos (HLS/video_player y también TS)
  // NO cambia el motor: se pintan encima del vídeo como en players HLS nativos.
  final List<_SubCue> _subCues = [];
  String _overlaySubText = '';
  bool _subsEnabled = true;
  ExternalSubtitle? _activeExternalSub;

  // Estilo de subtítulos — mismas claves SharedPreferences que Configuración
  static const String _kSubFontSize = 'player_sub_font_size';
  static const String _kSubBottomPad = 'player_sub_bottom_pad';
  static const String _kSubColor = 'player_sub_color';
  static const String _kSubBold = 'player_sub_bold';
  static const String _kSubBg = 'player_sub_bg';
  static const String _kSubBorder = 'player_sub_border';
  static const String _kSubOffset = 'player_sub_offset';
  static const String _kHlsQuality = 'player_hls_quality';
  static const String _kLastAudioLang = 'player_last_audio_lang';
  static const String _kLastSubChoice = 'player_last_sub_choice';

  double _subFontSize = 28;
  double _subBottomPad = 28;
  Color _subColor = const Color(0xFFFFFFFF);
  bool _subBold = false;
  bool _subBg = true;
  double _subBorder = 1.5;
  bool _showSubStyle = false;
  double _subtitleOffsetSec = 0.0;

  // --- video_player (HLS / MP4) ---
  VideoPlayerController? _vp;

  // --- media_kit (TS) ---
  Player? _mk;
  VideoController? _mkVideo;
  final List<StreamSubscription> _mkSubs = [];

  bool _useMediaKit = false;

  bool _loading = true;
  bool _loadingStreams = false;
  bool _playing = false;
  bool _buffering = false;
  bool _showControls = true;
  bool _isDragging = false;
  bool _showServers = false;
  bool _nextPreloading = false;
  bool _nextPreloaded = false;
  List<StreamServer> _nextServers = const [];
  bool _showNextCta = false;
  bool _autoAdvanced = false;
  bool _alreadyMarkedWatched = false;
  bool _resumeApplied = false;
  Timer? _nextCtaTimer;
  bool _isInPip = false;

  bool _showTracks = false;
  bool _showEpisodes = false;
  int _episodesSeasonFilter = -1; // -1 = todas / auto
  String? _error;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Timer? _hideTimer;
  Timer? _progressTimer;

  late List<StreamServer> _servers;
  late int _serverIndex;
  StreamServer? get _current =>
      _servers.isEmpty ? null : _servers[_serverIndex.clamp(0, _servers.length - 1)];

  String? _langFilter;
  List<AudioTrack> _audioTracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  AudioTrack? _selectedAudio;
  SubtitleTrack? _selectedSubtitle;

  double _volume = 1.0; // 0..1 for video_player; media_kit uses 0..100 scaled
  bool _showVolumeHud = false;
  Timer? _volumeHudTimer;

  BoxFit _fit = BoxFit.contain;
  static const _fitModes = [
    BoxFit.contain,
    BoxFit.cover,
    BoxFit.fill,
    BoxFit.fitWidth,
    BoxFit.fitHeight,
  ];
  static const _fitLabels = ['Original', 'Expandir', 'Estirar', 'Ancho', 'Alto'];
  bool _showFitHud = false;
  Timer? _fitHudTimer;

  bool _isSpeedBoost = false;
  double _playbackRate = 1.0;
  bool _showSeekHud = false;
  int _seekHudSeconds = 0;
  Timer? _seekHudTimer;
  DateTime? _lastTapAt;
  Offset? _lastTapPos;
  Timer? _singleTapTimer;

  // ---- helpers de formato ----
  static bool isTsUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('.ts') ||
        u.contains('mpegts') ||
        u.contains('mpeg-ts') ||
        u.contains('format=ts') ||
        u.contains('type=ts') ||
        (u.contains('/ts/') && !u.contains('.m3u8'));
  }

  static bool isHlsUrl(String url, {bool isHlsFlag = false}) {
    if (isHlsFlag) return true;
    final u = url.toLowerCase();
    return u.contains('.m3u8') ||
        u.contains('application/x-mpegurl') ||
        u.contains('application/vnd.apple.mpegurl') ||
        u.contains('format=m3u8') ||
        u.contains('type=hls');
  }

  bool _isAudioOnlyUrl(String url, {StreamServer? server}) {
    if (server != null) {
      final extra = server.extra;
      if (extra['audioOnly'] == true || extra['audio'] == true) return true;
      final kind = '${extra['kind'] ?? extra['type'] ?? extra['media'] ?? ''}'.toLowerCase();
      if (kind.contains('audio') || kind == 'music' || kind == 'song') return true;
      final name = server.name.toLowerCase();
      if (name.contains('audio') ||
          name.contains('aac') ||
          name.contains('opus') ||
          name.contains('music')) {
        return true;
      }
      final lang = (server.language ?? '').toLowerCase();
      if (lang == 'audio' || lang == 'musica' || lang == 'música') return true;
    }
    final u = url.toLowerCase();
    if (u.contains('mime=audio') ||
        u.contains('audio%2f') ||
        u.contains('audio/mp4') ||
        u.contains('audio/webm') ||
        u.contains('audio/mpeg')) {
      return true;
    }
    // googlevideo progressive without m3u8 ≈ audio-only from YT Music
    if (u.contains('googlevideo.com') &&
        !u.contains('.m3u8') &&
        (u.contains('audio') || u.contains('acontainer') || u.contains('rn=') || u.contains('itag='))) {
      return true;
    }
    return false;
  }

  bool get _audioOnly {
    final s = _current;
    if (s != null) return _isAudioOnlyUrl(s.url, server: s);
    return _isAudioOnlyUrl(widget.url);
  }

  /// null = automático (HLS→video_player, TS→media_kit). true/false = forzado por usuario.
  bool? _forceMediaKit;

  bool _shouldUseMediaKit(String url, {bool isHlsFlag = false, StreamServer? server}) {
    // Forzado manual (botón del usuario)
    if (_forceMediaKit != null) return _forceMediaKit!;
    // HLS / m3u8 → SIEMPRE video_player
    if (isHlsUrl(url, isHlsFlag: isHlsFlag)) return false;
    // .ts / mpegts → SIEMPRE media_kit (audios embebidos)
    if (isTsUrl(url)) return true;
    if (_isAudioOnlyUrl(url, server: server ?? _current)) return true;
    return false;
  }

  Future<void> _toggleEngine() async {
    final currentlyMk = _useMediaKit;
    _forceMediaKit = !currentlyMk;
    final s = _current;
    if (s == null) return;
    final pos = _position.inMilliseconds;
    final label = _forceMediaKit! ? 'media_kit' : 'video_player';
    // toast via snack
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Motor: $label'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    await _openUrl(s.url, s.headers, isHlsFlag: s.isHls, skipQualityParse: true);
    if (pos > 1500) {
      try {
        if (_useMediaKit) {
          await _mk?.seek(Duration(milliseconds: pos));
        } else {
          await _vp?.seekTo(Duration(milliseconds: pos));
        }
      } catch (_) {}
    }
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    PlayerPage.preserveLandscape = false;
    WakelockPlus.enable();

    // Escuchar cambios de PiP desde nativo (MainActivity)
    const MethodChannel('com.lol.lite/intent').setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        final args = call.arguments;
        final inPip = args is Map && (args['isInPip'] == true);
        if (mounted && inPip != _isInPip) {
          setState(() {
            _isInPip = inPip;
            if (inPip) _showControls = false;
          });
        }
      }
      return null;
    });

    _servers = List.of(widget.servers);
    if (_servers.isEmpty && widget.url.isNotEmpty) {
      final u = widget.url;
      _servers = [
        StreamServer(
          url: u,
          name: 'Principal',
          headers: widget.headers ?? {},
          isHls: isHlsUrl(u),
        ),
      ];
    }
    _serverIndex =
        widget.initialServerIndex.clamp(0, (_servers.length - 1).clamp(0, 999));

    unawaited(_loadSubtitleStyleFromPrefs());
    unawaited(_hydrateEpisodeListCache());

    if (widget.loadRepo != null && widget.contentId != null) {
      _loadStreamsThenPlay();
    } else {
      _startCurrent();
    }
  }

  String? get _episodeCacheKey {
    final c = widget.contentId;
    if (c == null || c.isEmpty) return null;
    final r = widget.repoId ?? '';
    return 'player_episode_list_${r}_$c';
  }

  List<Map<String, dynamic>> _cachedEpisodeList = const [];
  List<Map<String, dynamic>> get _effectiveEpisodeList =>
      widget.episodeList.isNotEmpty ? widget.episodeList : _cachedEpisodeList;

  Future<void> _hydrateEpisodeListCache() async {
    final key = _episodeCacheKey;
    if (key == null) return;
    if (widget.episodeList.isNotEmpty) {
      final list = List<Map<String, dynamic>>.from(widget.episodeList);
      _episodeListCache[key] = list;
      _cachedEpisodeList = list;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(key, jsonEncode(list));
      } catch (e) {
        debugPrint('[Player] episodeList cache save: $e');
      }
      return;
    }
    final mem = _episodeListCache[key];
    if (mem != null && mem.isNotEmpty) {
      _cachedEpisodeList = List<Map<String, dynamic>>.from(mem);
      if (mounted) setState(() {});
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final list = <Map<String, dynamic>>[];
      for (final e in decoded) {
        if (e is Map) list.add(Map<String, dynamic>.from(e));
      }
      if (list.isEmpty) return;
      _episodeListCache[key] = list;
      _cachedEpisodeList = list;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[Player] episodeList cache load: $e');
    }
  }

  Future<void> _loadSubtitleStyleFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final font = prefs.getDouble(_kSubFontSize);
      final pad = prefs.getDouble(_kSubBottomPad);
      final color = prefs.getInt(_kSubColor);
      final bold = prefs.getBool(_kSubBold);
      final bg = prefs.getBool(_kSubBg);
      final border = prefs.getDouble(_kSubBorder);
      final offset = prefs.getDouble(_kSubOffset);
      final hls = prefs.getString(_kHlsQuality);
      if (!mounted) return;
      setState(() {
        if (font != null) _subFontSize = font.clamp(16, 48);
        if (pad != null) _subBottomPad = pad.clamp(8, 120);
        if (color != null) _subColor = Color(color);
        if (bold != null) _subBold = bold;
        if (bg != null) _subBg = bg;
        if (border != null) _subBorder = border.clamp(0, 4);
        if (offset != null) _subtitleOffsetSec = offset.clamp(-5, 5);
      });
      if (hls != null && hls.isNotEmpty) {
        sessionHlsQuality =
            (hls == 'auto' || hls == 'Automática') ? null : hls;
      }
    } catch (e) {
      debugPrint('[Player] load sub style prefs: $e');
    }
  }

  Future<void> _saveSubtitleStyleToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubFontSize, _subFontSize);
      await prefs.setDouble(_kSubBottomPad, _subBottomPad);
      await prefs.setInt(_kSubColor, _subColor.value);
      await prefs.setBool(_kSubBold, _subBold);
      await prefs.setBool(_kSubBg, _subBg);
      await prefs.setDouble(_kSubBorder, _subBorder);
      await prefs.setDouble(_kSubOffset, _subtitleOffsetSec);
      final q = sessionHlsQuality;
      await prefs.setString(
        _kHlsQuality,
        (q == null || q.isEmpty || q == 'Automática') ? 'auto' : q,
      );
    } catch (e) {
      debugPrint('[Player] save sub style prefs: $e');
    }
  }

  Future<void> _persistTrackChoice({
    String? audioLang,
    String? subChoice,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (audioLang != null && audioLang.isNotEmpty) {
        await prefs.setString(_kLastAudioLang, audioLang);
      }
      if (subChoice != null) {
        await prefs.setString(_kLastSubChoice, subChoice);
      }
    } catch (e) {
      debugPrint('[Player] persistTrackChoice: $e');
    }
  }

  Future<void> _restorePreferredTracks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastAudio = prefs.getString(_kLastAudioLang);
      final lastSub = prefs.getString(_kLastSubChoice);

      if (lastAudio != null &&
          lastAudio.isNotEmpty &&
          _audioTracks.isNotEmpty &&
          _mk != null) {
        final lower = lastAudio.toLowerCase();
        final match = _audioTracks.where((t) {
          final lang = (t.language ?? t.title ?? t.id).toLowerCase();
          return lang.contains(lower) || lower.contains(lang);
        }).toList();
        if (match.isNotEmpty) {
          await _mk!.setAudioTrack(match.first);
          if (mounted) setState(() => _selectedAudio = match.first);
        }
      }

      if (lastSub == 'off') {
        try {
          await _mk?.setSubtitleTrack(SubtitleTrack.no());
        } catch (_) {}
        await _clearExternalSubtitle();
      } else if (lastSub != null && lastSub.startsWith('external:')) {
        final key = lastSub.substring(9);
        final sub = _externalSubs
            .where((s) => s.url == key || s.label == key)
            .toList();
        if (sub.isNotEmpty) await _applyExternalSubtitle(sub.first);
      } else if (lastSub != null &&
          lastSub.startsWith('embedded:') &&
          _subtitleTracks.isNotEmpty &&
          _mk != null) {
        final id = lastSub.substring(9);
        final t = _subtitleTracks.where((s) => s.id == id).toList();
        if (t.isNotEmpty) {
          await _mk!.setSubtitleTrack(t.first);
          if (mounted) setState(() => _selectedSubtitle = t.first);
        }
      }
    } catch (e) {
      debugPrint('[Player] restorePreferredTracks: $e');
    }
  }

  @override
  void dispose() {
    try {
      const MethodChannel('com.lol.lite/intent').setMethodCallHandler(null);
    } catch (_) {}
    try {
      _saveProgressNow();
    } catch (_) {}
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _volumeHudTimer?.cancel();
    _fitHudTimer?.cancel();
    _seekHudTimer?.cancel();
    _skipIntroTimer?.cancel();
    _skipOutroTimer?.cancel();
    _nextCtaTimer?.cancel();
    _disposeEngines();
    WakelockPlus.disable();
    if (PlayerPage.preserveLandscape) {
      // Mantiene horizontal al ir al siguiente capítulo
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _disposeEngines() async {
    final vp = _vp;
    _vp = null;
    if (vp != null) {
      try {
        vp.removeListener(_onVpTick);
        await vp.dispose();
      } catch (_) {}
    }
    for (final s in _mkSubs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _mkSubs.clear();
    final mk = _mk;
    _mk = null;
    _mkVideo = null;
    if (mk != null) {
      try {
        await mk.dispose();
      } catch (_) {}
    }
  }

  Future<void> _loadStreamsThenPlay() async {
    setState(() {
      _loadingStreams = true;
      _loading = true;
      _error = null;
    });
    try {
      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        widget.contentId!,
        type: widget.contentType,
        season: widget.season,
        episode: widget.episode,
      );
      if (!mounted) return;
      _servers = list;
      var preferred = _pickPreferredServer(list);
      setState(() => _loadingStreams = false);
      if (_servers.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No hay servidores disponibles';
        });
        return;
      }
      // Auto-fallback: probar salud del preferido y saltar si 403/404
      preferred = await _firstHealthyServer(from: preferred);
      _serverIndex = preferred;
      await _startCurrent();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingStreams = false;
          _loading = false;
          _error = 'Error cargando servidores: $e';
        });
      }
    }
  }

  int _pickPreferredServer(List<StreamServer> list) {
    if (list.isEmpty) return 0;
    final pref = widget.preferredLanguage.trim().toLowerCase();
    if (pref.isEmpty) return 0;
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      if (lang.contains(pref) || pref.contains(lang)) return i;
    }
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      if (pref.startsWith('lat') && lang.contains('lat')) return i;
      if (pref.startsWith('cast') && lang.contains('cast')) return i;
      if (pref.startsWith('ing') &&
          (lang.contains('ing') || lang.contains('en'))) {
        return i;
      }
      if (pref.startsWith('sub') && lang.contains('sub')) return i;
    }
    return 0;
  }


  void _applySegmentsFromServer(StreamServer? s) {
    _introStartSec = null;
    _introEndSec = null;
    _outroStartSec = null;
    _outroEndSec = null;
    _introSkipped = false;
    _showSkipIntro = false;
    _showSkipOutro = false;
    _introArmed = false;
    _outroArmed = false;
    _skipIntroTimer?.cancel();
    _skipOutroTimer?.cancel();
    final seg = s?.segments;
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

  void _loadExternalSubs(StreamServer? s) {
    _externalSubs = List<ExternalSubtitle>.from(s?.subtitles ?? const []);
  }

  bool _inRange(double sec, double? start, double? end) {
    if (start == null || end == null) return false;
    return sec >= start && sec < end;
  }

  void _updateSkipButtons() {
    if (!_playing && _position.inMilliseconds < 500) return;
    final sec = _position.inMilliseconds / 1000.0;
    final inIntro = !_introSkipped &&
        _inRange(sec, _introStartSec, _introEndSec);
    final hasNext = widget.nextSeason != null && widget.nextEpisode != null;
    final totalMs = _duration.inMilliseconds;
    bool inOutro = false;
    if (hasNext) {
      if (_outroStartSec != null) {
        inOutro = sec >= _outroStartSec! &&
            (_outroEndSec == null || sec <= _outroEndSec!);
      } else if (totalMs > 0) {
        // Fallback 95% si no hay segmento outro
        inOutro = (_position.inMilliseconds / totalMs) >= 0.95;
      }
    }

    if (inIntro && !_introArmed) {
      _introArmed = true;
      _skipIntroCountdown = 10;
      setState(() => _showSkipIntro = true);
      _skipIntroTimer?.cancel();
      _skipIntroTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_skipIntroCountdown <= 1) {
          t.cancel();
          setState(() => _showSkipIntro = false);
        } else {
          setState(() => _skipIntroCountdown--);
        }
      });
    } else if (!inIntro && _showSkipIntro) {
      _skipIntroTimer?.cancel();
      setState(() => _showSkipIntro = false);
    }

    if (inOutro && !_outroArmed) {
      _outroArmed = true;
      _skipOutroCountdown = 10;
      setState(() => _showSkipOutro = true);
      _skipOutroTimer?.cancel();
      _skipOutroTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_skipOutroCountdown <= 1) {
          t.cancel();
          setState(() => _showSkipOutro = false);
        } else {
          setState(() => _skipOutroCountdown--);
        }
      });
    } else if (!inOutro && _showSkipOutro) {
      _skipOutroTimer?.cancel();
      setState(() => _showSkipOutro = false);
    }
  }

  Future<void> _skipIntro() async {
    final end = _introEndSec;
    if (end == null) return;
    final d = Duration(milliseconds: (end * 1000).round());
    if (_useMediaKit) {
      await _mk?.seek(d);
    } else {
      await _vp?.seekTo(d);
    }
    _skipIntroTimer?.cancel();
    if (mounted) {
      setState(() {
        _introSkipped = true;
        _showSkipIntro = false;
        _position = d;
      });
    }
  }

  Future<void> _skipOutroOrNext() async {
    _skipOutroTimer?.cancel();
    setState(() => _showSkipOutro = false);
    if (widget.nextSeason != null && widget.nextEpisode != null) {
      await _goNextEpisode(auto: false, usePreload: false);
    } else if (_outroEndSec != null) {
      final d = Duration(milliseconds: (_outroEndSec! * 1000).round());
      if (_useMediaKit) {
        await _mk?.seek(d);
      } else {
        await _vp?.seekTo(d);
      }
    }
  }

  /// Parsea master playlist HLS para calidades.
  Future<void> _parseHlsQualities(String url, Map<String, String> headers) async {
    _hlsQualities = [];
    _hlsMasterParsed = false;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(const SystemEncoding().decoder).join();
      client.close(force: true);
      if (!body.contains('#EXT-X-STREAM-INF')) {
        _hlsMasterParsed = true;
        return;
      }
      final lines = body.split('\n');
      final base = uri.resolve('.');
      final list = <({String label, String url})>[];
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
        String label = 'Auto';
        final resM = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
        final bwM = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        if (resM != null) {
          label = '${resM.group(2)}p';
        } else if (bwM != null) {
          final kb = (int.parse(bwM.group(1)!) / 1000).round();
          label = '${kb}kbps';
        }
        final nameM = RegExp(r'NAME="([^"]+)"').firstMatch(line);
        if (nameM != null) label = nameM.group(1)!;
        if (i + 1 < lines.length) {
          var next = lines[i + 1].trim();
          if (next.isEmpty || next.startsWith('#')) continue;
          final abs = base.resolve(next).toString();
          list.add((label: label, url: abs));
        }
      }
      // dedupe by label keep highest bandwidth first order
      final seen = <String>{};
      final dedup = <({String label, String url})>[];
      for (final q in list) {
        if (seen.add(q.label)) dedup.add(q);
      }
      if (mounted) {
        setState(() {
          _hlsQualities = dedup;
          _hlsMasterParsed = true;
          if (sessionHlsQuality != null) {
            final match = dedup.where((e) => e.label == sessionHlsQuality);
            if (match.isNotEmpty) {
              _hlsQualityLabel = match.first.label;
            } else {
              _hlsQualityLabel = 'Automática';
            }
          } else {
            _hlsQualityLabel = 'Automática';
            // En automática el player elige; mostramos la más alta del master como referencia
            _hlsAutoActual = dedup.isNotEmpty ? dedup.first.label : null;
          }
        });
      }
      if (sessionHlsQuality != null) {
        final match = dedup.where((e) => e.label == sessionHlsQuality).toList();
        if (match.isNotEmpty) {
          await _selectHlsQuality(match.first.label, match.first.url);
        }
      }
    } catch (e) {
      debugPrint('[Player] hls qualities: $e');
      _hlsMasterParsed = true;
    }
  }

  Future<void> _selectHlsQuality(String label, String? url) async {
    sessionHlsQuality = label == 'Automática' ? null : label;
    setState(() {
      _hlsQualityLabel = label;
      if (label == 'Automática') {
        _hlsAutoActual = _hlsQualities.isNotEmpty ? _hlsQualities.first.label : null;
      } else {
        _hlsAutoActual = null;
      }
      _showQualities = false;
    });
    unawaited(_saveSubtitleStyleToPrefs());
    if (url == null || label == 'Automática') {
      // volver al master del servidor actual
      final s = _current;
      if (s == null) return;
      final pos = _position.inMilliseconds;
      await _openUrl(s.url, s.headers, isHlsFlag: true, skipQualityParse: true);
      if (pos > 2000) {
        try {
          if (_useMediaKit) {
            await _mk?.seek(Duration(milliseconds: pos));
          } else {
            await _vp?.seekTo(Duration(milliseconds: pos));
          }
        } catch (_) {}
      }
      return;
    }
    final s = _current;
    final pos = _position.inMilliseconds;
    await _openUrl(url, s?.headers ?? {}, isHlsFlag: true, skipQualityParse: true);
    if (pos > 2000) {
      try {
        if (_useMediaKit) {
          await _mk?.seek(Duration(milliseconds: pos));
        } else {
          await _vp?.seekTo(Duration(milliseconds: pos));
        }
      } catch (_) {}
    }
  }

  /// Carga subtítulos externos del repo como overlay (sin cambiar de motor).
  Future<void> _applyExternalSubtitle(ExternalSubtitle sub) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 12);
      final uri = Uri.parse(sub.url);
      final req = await client.getUrl(uri);
      // headers del stream a veces sirven para CDNs de subs
      final s = _current;
      if (s != null) {
        s.headers.forEach((k, v) {
          try {
            req.headers.set(k, v);
          } catch (_) {}
        });
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      client.close(force: true);
      final body = utf8.decode(bytes, allowMalformed: true);
      final cues = _parseSubtitleContent(body);
      if (!mounted) return;
      setState(() {
        _subCues
          ..clear()
          ..addAll(cues);
        _activeExternalSub = sub;
        _subsEnabled = true;
        _overlaySubText = '';
      });
      _updateOverlaySubtitle();
      debugPrint('[Player] external sub loaded cues=${cues.length} ${sub.label}');
    } catch (e) {
      debugPrint('[Player] external sub: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cargar subtítulo: ${sub.label}')),
        );
      }
    }
  }

  Future<void> _clearExternalSubtitle() async {
    setState(() {
      _subCues.clear();
      _overlaySubText = '';
      _activeExternalSub = null;
      _subsEnabled = false;
    });
    // Si media_kit tenía track URI, quitarlo
    try {
      await _mk?.setSubtitleTrack(SubtitleTrack.no());
    } catch (_) {}
  }

  List<_SubCue> _parseSubtitleContent(String content) {
    final t = content.trimLeft();
    if (t.startsWith('WEBVTT') || t.contains('-->')) {
      return _parseVtt(content);
    }
    return _parseSrt(content);
  }

  List<_SubCue> _parseVtt(String content) {
    final cues = <_SubCue>[];
    final lines = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();
      i++;
      if (line.isEmpty || line.startsWith('WEBVTT') || line.startsWith('NOTE') || line.startsWith('STYLE')) {
        continue;
      }
      // optional cue id
      String timing = line;
      if (!line.contains('-->') && i < lines.length && lines[i].contains('-->')) {
        timing = lines[i].trim();
        i++;
      }
      if (!timing.contains('-->')) continue;
      final parts = timing.split('-->');
      if (parts.length < 2) continue;
      final start = _parseTs(parts[0].trim().split(' ').first);
      final end = _parseTs(parts[1].trim().split(' ').first);
      if (start == null || end == null) continue;
      final buf = StringBuffer();
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        if (buf.isNotEmpty) buf.writeln();
        buf.write(_stripTags(lines[i].trim()));
        i++;
      }
      final text = buf.toString().trim();
      if (text.isNotEmpty) {
        cues.add(_SubCue(start: start, end: end, text: text));
      }
    }
    return cues;
  }

  List<_SubCue> _parseSrt(String content) {
    final cues = <_SubCue>[];
    final blocks = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.isEmpty) continue;
      var idx = 0;
      if (RegExp(r'^\d+$').hasMatch(lines[0].trim())) idx = 1;
      if (idx >= lines.length) continue;
      final timing = lines[idx].trim();
      if (!timing.contains('-->')) continue;
      final parts = timing.split('-->');
      if (parts.length < 2) continue;
      final start = _parseTs(parts[0].trim().replaceAll(',', '.'));
      final end = _parseTs(parts[1].trim().replaceAll(',', '.').split(' ').first);
      if (start == null || end == null) continue;
      final text = lines.skip(idx + 1).map(_stripTags).join('\n').trim();
      if (text.isNotEmpty) {
        cues.add(_SubCue(start: start, end: end, text: text));
      }
    }
    return cues;
  }

  Duration? _parseTs(String raw) {
    var s = raw.trim();
    // 00:01:02.500 or 00:01:02,500 or 01:02.500
    s = s.replaceAll(',', '.');
    final m = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?').firstMatch(s);
    if (m == null) return null;
    final h = int.tryParse(m.group(1) ?? '0') ?? 0;
    final min = int.tryParse(m.group(2) ?? '0') ?? 0;
    final sec = int.tryParse(m.group(3) ?? '0') ?? 0;
    var ms = int.tryParse(m.group(4) ?? '0') ?? 0;
    if ((m.group(4) ?? '').length == 1) ms *= 100;
    if ((m.group(4) ?? '').length == 2) ms *= 10;
    return Duration(hours: h, minutes: min, seconds: sec, milliseconds: ms);
  }

  String _stripTags(String t) => t.replaceAll(RegExp(r'<[^>]*>'), '');

  void _updateOverlaySubtitle() {
    if (!_subsEnabled || _subCues.isEmpty) {
      if (_overlaySubText.isNotEmpty && mounted) {
        setState(() => _overlaySubText = '');
      }
      return;
    }
    final adjusted = _position +
        Duration(milliseconds: (_subtitleOffsetSec * 1000).round());
    String text = '';
    for (final c in _subCues) {
      if (adjusted >= c.start && adjusted <= c.end) {
        text = c.text;
        break;
      }
      if (adjusted < c.start) break;
    }
    if (text != _overlaySubText && mounted) {
      setState(() => _overlaySubText = text);
    }
  }


  Future<int> _resolveStartPositionMs() async {
    if (widget.startPositionMs > 1500) return widget.startPositionMs;
    if (widget.repoId == null || widget.contentId == null) {
      return widget.startPositionMs;
    }
    try {
      final entry = await loadHistorialEntry(
        repoId: widget.repoId!,
        contentId: widget.contentId!,
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
        debugPrint('[Player] resume from cache pos=${pos}ms');
        return pos;
      }
    } catch (e) {
      debugPrint('[Player] resolve start pos: $e');
    }
    return widget.startPositionMs;
  }

  Future<void> _startCurrent() async {
    final s = _current;
    if (s == null || s.url.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'No hay URL de video';
      });
      return;
    }
    _applySegmentsFromServer(s);
    _loadExternalSubs(s);
    await _openUrl(s.url, s.headers, isHlsFlag: s.isHls);
  }

  /// Une headers del servidor del repo (prioridad) + los del player + defaults.
  /// El repo debe devolver headers en getStreams para que la reproducción funcione.
  Map<String, String> _mergeHeaders(Map<String, String> fromServer) {
    final h = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
    };
    // Headers pasados al PlayerPage (fallback)
    if (widget.headers != null) {
      widget.headers!.forEach((k, v) {
        if (k.isNotEmpty && v.isNotEmpty) h[k] = v;
      });
    }
    // Headers del servidor/repo tienen prioridad (sobrescriben)
    fromServer.forEach((k, v) {
      if (k.isNotEmpty && v.isNotEmpty) h[k] = v;
    });
    try {
      final url = _current?.url ?? widget.url;
      final uri = Uri.parse(url);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        h.putIfAbsent('Referer', () => '${uri.scheme}://${uri.host}/');
        h.putIfAbsent('Origin', () => '${uri.scheme}://${uri.host}');
      }
    } catch (_) {}
    return h;
  }

  /// HEAD/GET rápido para detectar 403/404 antes de abrir el motor de vídeo.
  Future<bool> _probeServer(StreamServer s) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      client.idleTimeout = const Duration(seconds: 6);
      final uri = Uri.tryParse(s.url);
      if (uri == null) return false;
      final req = await client.openUrl('HEAD', uri).timeout(const Duration(seconds: 6));
      s.headers.forEach((k, v) => req.headers.set(k, v));
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 6));
      final code = res.statusCode;
      await res.drain<void>();
      client.close(force: true);
      if (code == 403 || code == 404 || code == 410 || code == 451) return false;
      // Algunos servidores no soportan HEAD → intentar GET parcial
      if (code == 405 || code == 501) {
        final client2 = HttpClient();
        client2.connectionTimeout = const Duration(seconds: 6);
        final req2 = await client2.openUrl('GET', uri).timeout(const Duration(seconds: 6));
        s.headers.forEach((k, v) => req2.headers.set(k, v));
        req2.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
        final res2 = await req2.close().timeout(const Duration(seconds: 6));
        final code2 = res2.statusCode;
        await res2.drain<void>();
        client2.close(force: true);
        return code2 < 400 || code2 == 206;
      }
      return code < 400;
    } catch (e) {
      debugPrint('[Player] probe fail: $e');
      // Si el probe falla por red, no descartar el servidor (puede ser CORS/HEAD bloqueado)
      return true;
    }
  }

  /// Elige el primer servidor que pase el probe; si ninguno, usa el índice actual.
  Future<int> _firstHealthyServer({int from = 0}) async {
    if (_servers.isEmpty) return 0;
    final n = _servers.length;
    for (var i = 0; i < n; i++) {
      final idx = (from + i) % n;
      final ok = await _probeServer(_servers[idx]);
      if (ok) return idx;
      debugPrint('[Player] server $idx unhealthy, trying next');
    }
    return from.clamp(0, n - 1);
  }

  Future<void> _openUrl(
    String url,
    Map<String, String> headers, {
    bool isHlsFlag = false,
    bool skipQualityParse = false,
    bool forceMediaKit = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
      _showServers = false;
      _showTracks = false;
      _showQualities = false;
      _audioTracks = [];
      _subtitleTracks = [];
      _selectedAudio = null;
      _selectedSubtitle = null;
    });

    await _disposeEngines();

    final isHls = isHlsUrl(url, isHlsFlag: isHlsFlag);
    // Regla fija: HLS → video_player | TS → media_kit
    // Solo se anula con botón manual (_forceMediaKit) o forceMediaKit=true.
    final useMk = forceMediaKit ||
        _shouldUseMediaKit(url, isHlsFlag: isHlsFlag, server: _current);
    _useMediaKit = useMk;
    debugPrint(
        '[Player] engine=${useMk ? "media_kit" : "video_player"} hls=$isHls ts=${isTsUrl(url)} url=$url');

    try {
      if (isHls && !skipQualityParse) {
        _parseHlsQualities(url, _mergeHeaders(headers));
      }
      if (useMk) {
        await _openWithMediaKit(url, headers);
      } else {
        await _openWithVideoPlayer(
          url,
          headers,
          isHls: isHls,
        );
      }
      // Subtítulos externos del repo → overlay (HLS y TS, sin cambiar motor)
      if (_externalSubs.isNotEmpty) {
        Future<void>.delayed(const Duration(milliseconds: 400), () async {
          if (!mounted) return;
          await _restorePreferredTracks();
          if (_activeExternalSub == null && _subsEnabled) {
            await _applyExternalSubtitle(_externalSubs.first);
          }
        });
      } else {
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          if (mounted) unawaited(_restorePreferredTracks());
        });
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = true;
      });
      _scheduleHide();
      _startProgressSaver();
    } catch (e) {
      debugPrint('[Player] open error: $e');
      final msg = e.toString();
      String friendly = msg;
      if (msg.contains('403')) {
        friendly =
            'HTTP 403 — el servidor bloqueo el acceso. Prueba otro servidor.';
      } else if (msg.contains('404')) {
        friendly = 'HTTP 404 — enlace no encontrado.';
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendly;
        });
        if (_servers.length > 1 &&
            (msg.contains('403') ||
                msg.contains('404') ||
                msg.contains('Source') ||
                msg.contains('error') ||
                msg.contains('HttpException'))) {
          Future<void>.delayed(const Duration(milliseconds: 400), () async {
            if (!mounted || _error == null) return;
            final next = await _firstHealthyServer(from: _serverIndex + 1);
            if (mounted && next != _serverIndex) _switchServer(next);
          });
        }
      }
    }
  }

  // ───────────────────── video_player (HLS / MP4) ─────────────────────
  Future<void> _openWithVideoPlayer(
    String url,
    Map<String, String> headers, {
    required bool isHls,
  }) async {
    final merged = _mergeHeaders(headers);
    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: merged,
      formatHint: isHls ? VideoFormat.hls : VideoFormat.other,
      videoPlayerOptions: VideoPlayerOptions(
        mixWithOthers: false,
        allowBackgroundPlayback: false,
      ),
    );
    _vp = ctrl;
    await ctrl.initialize().timeout(const Duration(seconds: 45));
    if (!_resumeApplied) {
      final startMs = await _resolveStartPositionMs();
      _resumeApplied = true;
      if (startMs > 1500) {
        await ctrl.seekTo(Duration(milliseconds: startMs));
        if (mounted) {
          setState(() => _position = Duration(milliseconds: startMs));
        }
      }
    }
    ctrl.addListener(_onVpTick);
    await ctrl.setVolume(_volume.clamp(0.0, 1.0));
    await ctrl.play();
    // Forzar play si se queda en pause (bug frecuente en HLS)
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!ctrl.value.isPlaying) {
      await ctrl.play();
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!ctrl.value.isPlaying) {
      await ctrl.play();
    }
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    setState(() {
      _duration = ctrl.value.duration;
      _playing = ctrl.value.isPlaying;
      _buffering = ctrl.value.isBuffering;
    });
  }

  void _onVpTick() {
    final c = _vp;
    if (c == null || !mounted) return;
    final v = c.value;
    // Forzar rebuild cuando HLS publica el tamaño (antes solo había audio)
    setState(() {
      if (!_isDragging) _position = v.position;
      _duration = v.duration;
      _onPlaybackProgress();
      _playing = v.isPlaying;
      _buffering = v.isBuffering;
    });
  }

  // ───────────────────── media_kit (TS) ─────────────────────
  Future<void> _openWithMediaKit(
    String url,
    Map<String, String> headers,
  ) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    // Mejor análisis del contenedor TS → más chance de descubrir audio/subs
    try {
      final platform = player.platform;
      if (platform != null) {
        await (platform as dynamic)
            .setProperty('demuxer-lavf-analyzeduration', '15');
        await (platform as dynamic)
            .setProperty('demuxer-lavf-probesize', '50000000');
        await (platform as dynamic).setProperty('sub-visibility', 'yes');
        await (platform as dynamic).setProperty('subs-with-matching-audio', 'yes');
      }
    } catch (e) {
      debugPrint('[Player] mk props: $e');
    }
    final video = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _mk = player;
    _mkVideo = video;

    _mkSubs.add(player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
    _mkSubs.add(player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _mkSubs.add(player.stream.position.listen((v) {
      if (mounted && !_isDragging) {
        setState(() => _position = v);
        _onPlaybackProgress();
      }
    }));
    _mkSubs.add(player.stream.duration.listen((v) {
      if (mounted) setState(() => _duration = v);
    }));
    _mkSubs.add(player.stream.error.listen((e) {
      if (e.toString().trim().isEmpty) return;
      debugPrint('[Player] mk error: $e');
    }));
    // Pistas: audio + subtitulos embebidos en TS (mismo criterio que mobile_player)
    void applyTracks(Tracks tracks) {
      if (!mounted) return;
      final audios = tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      final subs = tracks.subtitle
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      setState(() {
        _audioTracks = audios;
        _subtitleTracks = subs;
        if (_mk != null) {
          _selectedAudio = _mk!.state.track.audio;
          final cur = _mk!.state.track.subtitle;
          if (cur.id != 'auto' && cur.id != 'no') {
            _selectedSubtitle = cur;
          }
        }
      });
      debugPrint(
          '[Player] tracks audio=${audios.length} subtitles=${subs.length}');
      unawaited(_restorePreferredTracks());
    }

    _mkSubs.add(player.stream.tracks.listen(applyTracks));
    _mkSubs.add(player.stream.track.listen((track) {
      if (!mounted) return;
      setState(() {
        _selectedAudio = track.audio;
        final sub = track.subtitle;
        if (sub.id != 'auto' && sub.id != 'no') {
          _selectedSubtitle = sub;
        }
      });
    }));

    final media = Media(url, httpHeaders: _mergeHeaders(headers));
    await player.open(media, play: true);
    if (!_resumeApplied) {
      final startMs = await _resolveStartPositionMs();
      _resumeApplied = true;
      if (startMs > 1500) {
        await player.seek(Duration(milliseconds: startMs));
        if (mounted) {
          setState(() => _position = Duration(milliseconds: startMs));
        }
      }
    }
    await player.setVolume((_volume * 100).clamp(0.0, 100.0));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!player.state.playing) await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!player.state.playing) await player.play();

    // Algunos TS reportan pistas tarde: reintentar varias veces
    for (final sec in [1, 2, 4, 7]) {
      Future<void>.delayed(Duration(seconds: sec), () {
        if (!mounted || _mk == null) return;
        applyTracks(_mk!.state.tracks);
      });
    }

    if (!mounted) return;
    setState(() {
      _duration = player.state.duration;
      _playing = player.state.playing;
    });
  }

  Future<void> _switchServer(int index) async {
    if (index < 0 || index >= _servers.length) return;
    final pos = _position.inMilliseconds > 0
        ? _position.inMilliseconds
        : widget.startPositionMs;
    setState(() => _serverIndex = index);
    final s = _servers[index];
    _applySegmentsFromServer(s);
    _loadExternalSubs(s);
    await _openUrl(s.url, s.headers, isHlsFlag: s.isHls);
    if (pos > 2000) {
      try {
        if (_useMediaKit) {
          await _mk?.seek(Duration(milliseconds: pos));
        } else {
          await _vp?.seekTo(Duration(milliseconds: pos));
        }
      } catch (_) {}
    }
  }

  Future<void> _togglePlay() async {
    if (_useMediaKit) {
      final p = _mk;
      if (p == null) return;
      if (p.state.playing) {
        await p.pause();
      } else {
        await p.play();
      }
    } else {
      final c = _vp;
      if (c == null) return;
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        await c.play();
      }
    }
    _scheduleHide();
  }

  Future<void> _seekBy(int seconds) async {
    final next = _position + Duration(seconds: seconds);
    final clamped = next < Duration.zero
        ? Duration.zero
        : (_duration > Duration.zero && next > _duration ? _duration : next);
    if (_useMediaKit) {
      await _mk?.seek(clamped);
    } else {
      await _vp?.seekTo(clamped);
    }
    _scheduleHide();
  }

  void _setVolumeUi(double v01) {
    final nv = v01.clamp(0.0, 1.0);
    setState(() {
      _volume = nv;
      _showVolumeHud = true;
    });
    if (_useMediaKit) {
      _mk?.setVolume(nv * 100);
    } else {
      _vp?.setVolume(nv);
    }
    _volumeHudTimer?.cancel();
    _volumeHudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showVolumeHud = false);
    });
  }

  Future<void> _setRate(double rate) async {
    _playbackRate = rate;
    try {
      if (_useMediaKit) {
        await _mk?.setRate(rate);
      } else {
        await _vp?.setPlaybackSpeed(rate);
      }
    } catch (_) {}
  }

  void _cycleFit() {
    final i = _fitModes.indexOf(_fit);
    setState(() {
      _fit = _fitModes[(i + 1) % _fitModes.length];
      _showFitHud = true;
    });
    _fitHudTimer?.cancel();
    _seekHudTimer?.cancel();
    _fitHudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showFitHud = false);
    });
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          _playing &&
          !_isDragging &&
          !_showServers &&
          !_showTracks &&
          !_showQualities &&
          !_showSubStyle) {
        setState(() => _showControls = false);
      }
    });
  }

  void _startProgressSaver() {
    _progressTimer?.cancel();
    if (widget.repoId == null || widget.contentId == null) return;
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _saveProgressNow();
    });
  }

  String? get _historialCacheKey {
    final c = widget.contentId;
    if (c == null || c.isEmpty) return null;
    final r = widget.repoId ?? '';
    final se = widget.season;
    final ep = widget.episode;
    if (se != null && ep != null) {
      return 'continue_watch_${r}_${c}_s${se}_e$ep';
    }
    return 'continue_watch_${r}_$c';
  }

  static const String _continueIndexKey = 'continue_watching_index';

  void _saveProgressNow() {
    if (widget.repoId == null || widget.contentId == null) return;
    final posMs = _position.inMilliseconds;
    final durMs = _duration.inMilliseconds;
    final list = _effectiveEpisodeList;

    if (mounted) {
      try {
        final lib = context.read<LibraryService>();
        try {
          (lib as dynamic).saveProgress(
            repoId: widget.repoId!,
            contentId: widget.contentId!,
            title: widget.title,
            poster: widget.poster,
            type: widget.contentType,
            positionMs: posMs,
            durationMs: durMs,
            season: widget.season,
            episode: widget.episode,
          );
        } catch (_) {
          lib.saveProgress(
            repoId: widget.repoId!,
            contentId: widget.contentId!,
            title: widget.title,
            poster: widget.poster,
            type: widget.contentType,
            positionMs: posMs,
            durationMs: durMs,
          );
        }
      } catch (_) {}
    }

    unawaited(_saveHistorialToPrefs(
      positionMs: posMs,
      durationMs: durMs,
      episodeList: list,
    ));
  }

  Future<void> _saveProgressNowAsync() async {
    if (widget.repoId == null || widget.contentId == null) return;
    final posMs = _position.inMilliseconds;
    final durMs = _duration.inMilliseconds;
    final list = _effectiveEpisodeList;
    if (mounted) {
      try {
        final lib = context.read<LibraryService>();
        try {
          (lib as dynamic).saveProgress(
            repoId: widget.repoId!,
            contentId: widget.contentId!,
            title: widget.title,
            poster: widget.poster,
            type: widget.contentType,
            positionMs: posMs,
            durationMs: durMs,
            season: widget.season,
            episode: widget.episode,
          );
        } catch (_) {
          lib.saveProgress(
            repoId: widget.repoId!,
            contentId: widget.contentId!,
            title: widget.title,
            poster: widget.poster,
            type: widget.contentType,
            positionMs: posMs,
            durationMs: durMs,
          );
        }
      } catch (_) {}
    }
    await _saveHistorialToPrefs(
      positionMs: posMs,
      durationMs: durMs,
      episodeList: list,
    );
  }

  Future<void> _saveHistorialToPrefs({
    required int positionMs,
    required int durationMs,
    required List<Map<String, dynamic>> episodeList,
  }) async {
    final key = _historialCacheKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final listKey = _episodeCacheKey;
      if (listKey != null && episodeList.isNotEmpty) {
        _episodeListCache[listKey] =
            List<Map<String, dynamic>>.from(episodeList);
        await prefs.setString(listKey, jsonEncode(episodeList));
      }

      final normalizedEpisodes = <Map<String, dynamic>>[];
      for (final e in episodeList) {
        final se = (e['season'] as num?)?.toInt() ??
            (e['temporada'] as num?)?.toInt();
        final ep = (e['episode'] as num?)?.toInt() ??
            (e['number'] as num?)?.toInt() ??
            (e['episodio'] as num?)?.toInt();
        normalizedEpisodes.add({
          ...Map<String, dynamic>.from(e),
          if (se != null) 'season': se,
          if (ep != null) 'episode': ep,
          'title': (e['title'] ?? e['name'] ?? e['titulo'] ?? '').toString(),
          if (e['id'] != null) 'id': e['id'].toString(),
          if (e['still'] != null) 'still': e['still'],
          if (e['poster'] != null) 'poster': e['poster'],
          if (e['image'] != null) 'image': e['image'],
          if (e['thumbnail'] != null) 'thumbnail': e['thumbnail'],
        });
      }

      final payload = <String, dynamic>{
        'playerId': playerId,
        'player': playerId,
        'repoId': widget.repoId,
        'contentId': widget.contentId,
        'title': widget.title,
        'poster': widget.poster,
        'backdrop': widget.backdrop,
        'logo': widget.logo,
        'type': widget.contentType,
        'contentType': widget.contentType,
        'season': widget.season,
        'episode': widget.episode,
        'episodeTitle': widget.episodeTitle,
        'temporada': widget.season,
        'episodio': widget.episode,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'segundo': (positionMs / 1000).round(),
        'positionSec': (positionMs / 1000).round(),
        'duration': (durationMs / 1000).round(),
        'durationSec': (durationMs / 1000).round(),
        'episodeList': normalizedEpisodes,
        'nextSeason': widget.nextSeason,
        'nextEpisode': widget.nextEpisode,
        'nextEpisodeId': widget.nextEpisodeId,
        'nextEpisodeTitle': widget.nextEpisodeTitle,
        'updatedAt': DateTime.now().toIso8601String(),
        'timestamp': DateTime.now().toIso8601String(),
      };

      await prefs.setString(key, jsonEncode(payload));
      if (widget.season != null && widget.episode != null) {
        final seriesKey =
            'continue_watch_${widget.repoId}_${widget.contentId}';
        if (seriesKey != key) {
          await prefs.setString(seriesKey, jsonEncode(payload));
        }
      }
      final index = prefs.getStringList(_continueIndexKey) ?? <String>[];
      index.remove(key);
      index.insert(0, key);
      if (widget.season != null && widget.episode != null) {
        final seriesKey =
            'continue_watch_${widget.repoId}_${widget.contentId}';
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
      debugPrint('[Player] saveHistorial prefs: $e');
    }
  }

  static Future<Map<String, dynamic>?> loadHistorialEntry({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = <String>[];
      if (season != null && episode != null) {
        keys.add('continue_watch_${repoId}_${contentId}_s${season}_e$episode');
      }
      keys.add('continue_watch_${repoId}_$contentId');
      for (final key in keys) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> loadContinueWatching() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getStringList(_continueIndexKey) ?? const <String>[];
      final out = <Map<String, dynamic>>[];
      for (final key in index) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) out.add(Map<String, dynamic>.from(decoded));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  List<String> get _availableLanguages {
    final set = <String>{};
    for (final s in _servers) {
      final l = (s.language ?? '').trim();
      if (l.isNotEmpty) set.add(l);
    }
    return (set.toList()..sort());
  }

  List<int> get _filteredServerIndices {
    if (_langFilter == null || _langFilter!.isEmpty) {
      return List.generate(_servers.length, (i) => i);
    }
    final pref = _langFilter!.toLowerCase();
    final out = <int>[];
    for (var i = 0; i < _servers.length; i++) {
      final lang = (_servers[i].language ?? '').toLowerCase();
      if (lang.contains(pref) || pref.contains(lang)) out.add(i);
    }
    return out.isEmpty ? List.generate(_servers.length, (i) => i) : out;
  }


  void _onPlaybackProgress() {
    if (!mounted) return;
    _updateOverlaySubtitle();
    _updateSkipButtons();
    if (_duration.inMilliseconds <= 0) return;
    final ratio = _position.inMilliseconds / _duration.inMilliseconds;
    if (ratio >= 0.80) {
      _preloadNextEpisode();
    }
    // Marcar visto al 90% pero seguir guardando historial
    if (ratio >= 0.90) {
      unawaited(_markAsWatchedIfNeeded());
    }
    final hasNext = widget.nextSeason != null && widget.nextEpisode != null;
    if (hasNext && ratio >= 0.90) {
      if (!_showNextCta) {
        setState(() => _showNextCta = true);
        _nextCtaTimer?.cancel();
        _nextCtaTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          if (!_showControls) {
            setState(() => _showNextCta = false);
          }
        });
      }
    }
    if (hasNext && ratio >= 0.98 && !_autoAdvanced) {
      _autoAdvanced = true;
      _goNextEpisode(auto: true);
    }
  }

  Future<void> _markAsWatchedIfNeeded() async {
    if (_alreadyMarkedWatched) return;
    if (widget.repoId == null || widget.contentId == null) return;
    _alreadyMarkedWatched = true;
    try {
      final lib = context.read<LibraryService>();
      try {
        (lib as dynamic).markWatched(
          repoId: widget.repoId!,
          contentId: widget.contentId!,
          title: widget.title,
          poster: widget.poster,
          type: widget.contentType,
          season: widget.season,
          episode: widget.episode,
        );
      } catch (_) {
        try {
          (lib as dynamic).saveProgress(
            repoId: widget.repoId!,
            contentId: widget.contentId!,
            title: widget.title,
            poster: widget.poster,
            type: widget.contentType,
            positionMs: _duration.inMilliseconds > 0
                ? _duration.inMilliseconds
                : _position.inMilliseconds,
            durationMs: _duration.inMilliseconds,
            season: widget.season,
            episode: widget.episode,
            completed: true,
          );
        } catch (_) {
          lib.saveProgress(
            repoId: widget.repoId!,
            contentId: widget.contentId!,
            title: widget.title,
            poster: widget.poster,
            type: widget.contentType,
            positionMs: _duration.inMilliseconds > 0
                ? _duration.inMilliseconds
                : _position.inMilliseconds,
            durationMs: _duration.inMilliseconds,
          );
        }
      }
    } catch (e) {
      debugPrint('[Player] markWatched: $e');
    }
    await _saveProgressNowAsync();
  }

  Future<void> _preloadNextEpisode() async {
    if (_nextPreloading || _nextPreloaded) return;
    if (widget.loadRepo == null) return;
    if (widget.nextSeason == null || widget.nextEpisode == null) return;
    _nextPreloading = true;
    try {
      final id = widget.nextEpisodeId ?? widget.contentId ?? '';
      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        id,
        type: widget.contentType,
        season: widget.nextSeason,
        episode: widget.nextEpisode,
      );
      if (!mounted) return;
      _nextServers = list;
      _nextPreloaded = list.isNotEmpty;
    } catch (_) {
    } finally {
      _nextPreloading = false;
    }
  }

  Future<void> _goNextEpisode({bool auto = false, bool usePreload = false}) async {
    if (widget.nextSeason == null || widget.nextEpisode == null) return;
    final title = widget.nextEpisodeTitle ??
        'T${widget.nextSeason} E${widget.nextEpisode}';

    List<StreamServer> servers = const [];
    if (usePreload) {
      servers = List.of(_nextServers);
    }
    if (!mounted) return;

    int? nSe;
    int? nEp;
    String? nId;
    String? nTitle;
    final list = _effectiveEpisodeList;
    if (list.isNotEmpty) {
      final cur = list.indexWhere((e) {
        final se = (e['season'] as num?)?.toInt();
        final ep =
            (e['episode'] as num?)?.toInt() ?? (e['number'] as num?)?.toInt();
        return se == widget.nextSeason && ep == widget.nextEpisode;
      });
      if (cur >= 0 && cur + 1 < list.length) {
        final n = list[cur + 1];
        nSe = (n['season'] as num?)?.toInt() ?? widget.nextSeason;
        nEp =
            (n['episode'] as num?)?.toInt() ?? (n['number'] as num?)?.toInt();
        nId = n['id']?.toString();
        nTitle = n['title']?.toString();
      }
    }

    if (!mounted) return;
    PlayerPage.preserveLandscape = true;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    final url = servers.isNotEmpty ? servers.first.url : '';
    final hdrs = servers.isNotEmpty && servers.first.headers.isNotEmpty
        ? servers.first.headers
        : widget.headers;

    await _saveProgressNowAsync();
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PlayerPage(
          title: widget.title,
          url: url,
          repoId: widget.repoId,
          contentId: widget.contentId,
          poster: widget.poster,
          backdrop: widget.backdrop,
          logo: widget.logo,
          contentType: widget.contentType,
          servers: servers,
          season: widget.nextSeason,
          episode: widget.nextEpisode,
          episodeTitle: title,
          nextSeason: nSe,
          nextEpisode: nEp,
          nextEpisodeId: nId,
          nextEpisodeTitle: nTitle,
          episodeList: _effectiveEpisodeList.isNotEmpty
              ? _effectiveEpisodeList
              : widget.episodeList,
          loadRepo: widget.loadRepo,
          preferredLanguage: widget.preferredLanguage,
          isTv: widget.isTv,
          headers: hdrs,
          startPositionMs: 0,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  Future<void> _openEpisodeFromList({
    required int season,
    required int episode,
    String? episodeId,
    String? episodeTitle,
  }) async {
    final list = _effectiveEpisodeList;
    int? nSe;
    int? nEp;
    String? nId;
    String? nTitle;
    if (list.isNotEmpty) {
      final cur = list.indexWhere((e) {
        final se = (e['season'] as num?)?.toInt();
        final ep =
            (e['episode'] as num?)?.toInt() ?? (e['number'] as num?)?.toInt();
        return se == season && ep == episode;
      });
      if (cur >= 0 && cur + 1 < list.length) {
        final n = list[cur + 1];
        nSe = (n['season'] as num?)?.toInt();
        nEp =
            (n['episode'] as num?)?.toInt() ?? (n['number'] as num?)?.toInt();
        nId = n['id']?.toString();
        nTitle = n['title']?.toString();
      }
    }

    PlayerPage.preserveLandscape = true;
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await _saveProgressNowAsync();
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PlayerPage(
          title: widget.title,
          url: '',
          repoId: widget.repoId,
          contentId: widget.contentId,
          poster: widget.poster,
          backdrop: widget.backdrop,
          logo: widget.logo,
          contentType: widget.contentType,
          servers: const [],
          season: season,
          episode: episode,
          episodeTitle: episodeTitle,
          nextSeason: nSe,
          nextEpisode: nEp,
          nextEpisodeId: nId,
          nextEpisodeTitle: nTitle,
          episodeList: list.isNotEmpty ? list : widget.episodeList,
          loadRepo: widget.loadRepo,
          preferredLanguage: widget.preferredLanguage,
          isTv: widget.isTv,
          headers: widget.headers,
          startPositionMs: 0,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  String _qualityButtonLabel() {
    if (_hlsQualityLabel == 'Automática' || _hlsQualityLabel.startsWith('Automática')) {
      final actual = _hlsAutoActual;
      if (actual != null && actual.isNotEmpty) {
        return 'Automática ($actual)';
      }
      return 'Automática';
    }
    return _hlsQualityLabel;
  }

  String get _formatLabel {
    final s = _current;
    final u = (s?.url ?? widget.url).toLowerCase();
    if (isHlsUrl(u, isHlsFlag: s?.isHls ?? false)) return 'HLS';
    if (isTsUrl(u)) return 'TS';
    if (u.contains('.mp4')) return 'MP4';
    return 'Stream';
  }

  String get _subtitleLine {
    // Solo info de episodio / título secundario. Nunca HLS/TS ni motor.
    final parts = <String>[];
    if (widget.season != null && widget.episode != null) {
      parts.add('T${widget.season} · E${widget.episode}');
    } else if (widget.season != null) {
      parts.add('Temporada ${widget.season}');
    } else if (widget.episode != null) {
      parts.add('Episodio ${widget.episode}');
    }
    final et = (widget.episodeTitle ?? '').trim();
    if (et.isNotEmpty) parts.add(et);
    if (_selectedAudio != null &&
        (_selectedAudio!.language?.isNotEmpty == true ||
            _selectedAudio!.title?.isNotEmpty == true)) {
      parts.add(_trackLabel(_selectedAudio!));
    }
    return parts.join('  ·  ');
  }

  String _trackLabel(dynamic t) {
    if (t is AudioTrack) {
      final parts = <String>[];
      if (t.title != null && t.title!.isNotEmpty) parts.add(t.title!);
      if (t.language != null && t.language!.isNotEmpty) parts.add(t.language!);
      if (parts.isEmpty) parts.add('Pista ${t.id}');
      return parts.join(' / ');
    }
    if (t is SubtitleTrack) {
      final parts = <String>[];
      if (t.title != null && t.title!.isNotEmpty) parts.add(t.title!);
      if (t.language != null && t.language!.isNotEmpty) parts.add(t.language!);
      if (t.image == true) parts.add('imagen');
      if (parts.isEmpty) parts.add('Sub ${t.id}');
      return parts.join(' / ');
    }
    return '';
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// Solo .TS (media_kit) muestra audio/subtítulos. HLS solo servidores.
  bool get _hasTrackUi => _useMediaKit;

  // ───────────────────── UI ─────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            _togglePlay();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft) {
            _seekBy(-10);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            _seekBy(10);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp) {
            _setVolumeUi(_volume + 0.05);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowDown) {
            _setVolumeUi(_volume - 0.05);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.goBack) {
            if (_showServers || _showTracks) {
              setState(() {
                _showServers = false;
                _showTracks = false;
              });
              return KeyEventResult.handled;
            }
            { _saveProgressNow(); Navigator.maybePop(context); };
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            // Detección manual de doble toque para no retrasar el toque simple
            final now = DateTime.now();
            final pos = d.localPosition;
            final isDouble = _lastTapAt != null &&
                now.difference(_lastTapAt!) < const Duration(milliseconds: 280) &&
                _lastTapPos != null &&
                (pos - _lastTapPos!).distance < 60;
            if (isDouble) {
              _singleTapTimer?.cancel();
              _lastTapAt = null;
              _lastTapPos = null;
              final w = MediaQuery.sizeOf(context).width;
              final secs = pos.dx < w * 0.5 ? -10 : 10;
              _seekBy(secs);
              setState(() {
                _showSeekHud = true;
                _seekHudSeconds = secs;
              });
              _seekHudTimer?.cancel();
              _seekHudTimer = Timer(const Duration(milliseconds: 700), () {
                if (mounted) setState(() => _showSeekHud = false);
              });
              return;
            }
            _lastTapAt = now;
            _lastTapPos = pos;
            _singleTapTimer?.cancel();
            _singleTapTimer = Timer(const Duration(milliseconds: 260), () {
              if (!mounted) return;
              // Con panel lateral abierto no cerrar por toque en el vídeo;
              // el panel se cierra solo con su botón X o tocando la barrera.
              if (_showServers || _showTracks || _showQualities || _showSubStyle) {
                return;
              }
              setState(() => _showControls = !_showControls);
              if (_showControls) _scheduleHide();
            });
          },
          onLongPressStart: (d) {
            _singleTapTimer?.cancel();
            final w = MediaQuery.sizeOf(context).width;
            if (d.localPosition.dx >= w * 0.5) {
              setState(() => _isSpeedBoost = true);
              _setRate(2.0);
            }
          },
          onLongPressEnd: (_) {
            if (_isSpeedBoost) {
              setState(() => _isSpeedBoost = false);
              _setRate(1.0);
            }
          },
          onVerticalDragUpdate: (d) {
            if (d.localPosition.dx < MediaQuery.sizeOf(context).width * 0.5) {
              return;
            }
            _setVolumeUi(_volume - d.delta.dy / 300);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Vídeo siempre debajo
              if (!_loading && !_loadingStreams && _error == null)
                _buildVideoSurface(),
              if (_loading || _loadingStreams) _buildLoading(),
              if (_error != null) _buildError(),
              if (_buffering && !_loading && !_loadingStreams)
                const Center(
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                        color: accent, strokeWidth: 3),
                  ),
                ),
              // En PiP: solo el vídeo (sin botones ni controles)
              // Subtítulos externos (overlay, funciona con video_player HLS) — ocultos en PiP
              if (!_isInPip && _overlaySubText.isNotEmpty && _subsEnabled)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: _showControls ? 100 + _subBottomPad : _subBottomPad,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: 1,
                      duration: const Duration(milliseconds: 120),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _subBg
                                ? const Color(0x99000000)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _overlaySubText,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              height: 1.3,
                              fontSize: _subFontSize,
                              color: _subColor,
                              fontWeight:
                                  _subBold ? FontWeight.w800 : FontWeight.w500,
                              shadows: [
                                Shadow(
                                  offset: Offset(_subBorder, _subBorder),
                                  blurRadius: _subBorder * 1.5,
                                  color: Colors.black,
                                ),
                                Shadow(
                                  offset: Offset(
                                      -_subBorder * 0.6, -_subBorder * 0.6),
                                  blurRadius: _subBorder,
                                  color: const Color(0xCC000000),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_isInPip && _showVolumeHud) _volumeHud(),
              if (!_isInPip && _showFitHud) _fitHud(),
              if (!_isInPip && _showSeekHud) _seekHud(),
              if (!_isInPip && _isSpeedBoost) _speedHud(),
              // Controles: appbar sale hacia ARRIBA, barra/herramientas hacia ABAJO — ocultos en PiP
              if (!_isInPip && !_loading && !_loadingStreams && _error == null) ...[
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: AnimatedSlide(
                      offset: _showControls ? Offset.zero : const Offset(0, -0.15),
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: _controlsTop(),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: AnimatedSlide(
                      offset: _showControls ? Offset.zero : const Offset(0, 0.18),
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: _controlsBottom(),
                    ),
                  ),
                ),
                // Skip intro / outro (10 s con contador)
                if (_showSkipIntro)
                  Positioned(
                    left: 20,
                    bottom: _showControls ? 120 : 36,
                    child: _skipIntroBtn(),
                  ),
                if (_showSkipOutro)
                  Positioned(
                    right: 20,
                    bottom: _showControls ? 120 : 36,
                    child: _skipOutroBtn(),
                  ),
              ],
              if (_showServers) _serversPanel(),
              if (_showQualities) _qualitiesPanel(),
              if (_showSubStyle) _subStylePanel(),
              if (_showEpisodes) _episodesPanel(),
              if (_shouldShowNextCta) _nextEpisodeOverlay(),
              if (_showTracks) _tracksPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioArt() {
    final art = widget.backdrop ?? widget.poster;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (art != null && art.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(
                imageUrl: art,
                width: 220,
                height: 220,
                fit: BoxFit.cover,
                memCacheWidth: 440,
                errorWidget: (_, __, ___) => const Icon(
                  Icons.album_rounded,
                  color: Colors.white24,
                  size: 120,
                ),
              ),
            )
          else
            const Icon(Icons.album_rounded, color: Colors.white24, size: 120),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              widget.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Solo audio',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoSurface() {
    // Audio-only: arte + media_kit sin depender del Video widget
    if (_audioOnly) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildAudioArt(),
          // media_kit Video transparente mantiene el pipeline de audio
          if (_useMediaKit && _mkVideo != null)
            Opacity(
              opacity: 0,
              child: Video(
                controller: _mkVideo!,
                controls: NoVideoControls,
                fill: Colors.transparent,
              ),
            ),
        ],
      );
    }
    if (_useMediaKit && _mkVideo != null) {
      return Video(
        controller: _mkVideo!,
        controls: NoVideoControls,
        fill: Colors.black,
        fit: _fit,
        subtitleViewConfiguration: _subtitleViewConfig(),
      );
    }

    final c = _vp;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }

    // HLS a veces reporta size 0 hasta el primer frame → pantalla completa
    final sz = c.value.size;
    final hasSize = sz.width > 0 && sz.height > 0;

    if (!hasSize) {
      return ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(child: VideoPlayer(c)),
      );
    }

    // Patrón clásico y fiable: FittedBox + tamaño real del vídeo
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: FittedBox(
          fit: _fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: sz.width,
            height: sz.height,
            child: VideoPlayer(c),
          ),
        ),
      ),
    );
  }

  Widget _seekHud() {
    final back = _seekHudSeconds < 0;
    final secs = _seekHudSeconds.abs();
    return Align(
      alignment: back ? const Alignment(-0.55, 0) : const Alignment(0.55, 0),
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              back ? Icons.replay_10_rounded : Icons.forward_10_rounded,
              color: Colors.white,
              size: 28,
            ),
            Text(
              '${back ? '-' : '+'}${secs}s',
              style: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _speedHud() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fast_forward_rounded, color: Colors.white, size: 26),
            SizedBox(width: 8),
            Text('2x',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.backdrop != null || widget.poster != null)
          CachedNetworkImage(
            imageUrl: widget.backdrop ?? widget.poster!,
            fit: BoxFit.cover,
          ),
        ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                    color: accent, strokeWidth: 3.5),
              ),
              const SizedBox(height: 14),
              Text(
                _loadingStreams ? 'Cargando servidores…' : 'Cargando video…',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: accent, size: 56),
            const SizedBox(height: 12),
            const Text(
              'Error de reproduccion',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Error desconocido',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (_servers.isNotEmpty) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  if (_servers.length > 1) {
                    final next = (_serverIndex + 1) % _servers.length;
                    _switchServer(next);
                  } else {
                    setState(() {
                      _showServers = true;
                      _error = null;
                    });
                  }
                },
                icon: const Icon(Icons.dns, color: Colors.white),
                label: Text(
                    _servers.length > 1
                        ? 'Intentar otro servidor'
                        : 'Ver servidores',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(260, 46),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: () { _saveProgressNow(); Navigator.maybePop(context); },
              child:
                  const Text('Cerrar', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _volumeHud() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _volume <= 0
                  ? Icons.volume_off
                  : _volume < 0.4
                      ? Icons.volume_down
                      : Icons.volume_up,
              color: Colors.white,
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                value: _volume,
                color: accent,
                backgroundColor: Colors.white24,
                minHeight: 4,
              ),
            ),
            const SizedBox(width: 10),
            Text('${(_volume * 100).round()}%',
                style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _fitHud() {
    final i = _fitModes.indexOf(_fit);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(_fitLabels[i.clamp(0, _fitLabels.length - 1)],
            style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
    );
  }

  String _clockNow() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  String _endsAtLabel() {
    if (_duration.inSeconds <= 0) return '';
    final remaining = _duration - _position;
    if (remaining.inSeconds <= 0) return '';
    final end = DateTime.now().add(remaining);
    return 'Termina a las ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
  }

  Widget _metaBadge({required String label, IconData? icon, bool filled = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? accent.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: filled ? accent.withValues(alpha: 0.5) : Colors.white24,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: const TextStyle(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }


  Widget _skipIntroBtn() {
    final progress = (_skipIntroCountdown / 10.0).clamp(0.0, 1.0);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _skipIntro,
        child: Container(
          constraints: const BoxConstraints(minWidth: 140, maxWidth: 280),
          decoration: BoxDecoration(
            color: const Color(0xF2FFFFFF),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 10,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 14, 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.fast_forward_rounded,
                          color: Colors.white, size: 16),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Omitir intro',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2.5,
                  backgroundColor: Colors.black12,
                  valueColor: const AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _skipOutroBtn() {
    final hasNext = widget.nextSeason != null && widget.nextEpisode != null;
    final progress = (_skipOutroCountdown / 10.0).clamp(0.0, 1.0);
    final tag = hasNext
        ? 'T${widget.nextSeason} · E${widget.nextEpisode}'
        : 'Omitir outro';
    final et = (widget.nextEpisodeTitle ?? '').trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _skipOutroOrNext,
        child: Container(
          constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
          decoration: BoxDecoration(
            color: const Color(0xE6101218),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 10,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 12, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        hasNext
                            ? Icons.skip_next_rounded
                            : Icons.fast_forward_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasNext ? 'SIGUIENTE CAPÍTULO' : 'OMITIR OUTRO',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hasNext ? accent : Colors.white60,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            tag,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (hasNext && et.isNotEmpty)
                            Text(
                              et,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2.5,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isCurrentTs {
    final u = _current?.url ?? widget.url;
    return u.toLowerCase().contains('.ts') ||
        u.toLowerCase().contains('mpegts') ||
        u.toLowerCase().contains('mpeg-ts') ||
        u.toLowerCase().contains('format=ts');
  }

  /// Calidades disponibles entre servidores .ts (por campo quality).
  List<({String label, int index})> get _tsQualityOptions {
    final out = <({String label, int index})>[];
    final seen = <String>{};
    for (var i = 0; i < _servers.length; i++) {
      final s = _servers[i];
      final u = s.url.toLowerCase();
      final isTs = u.contains('.ts') ||
          u.contains('mpegts') ||
          u.contains('mpeg-ts') ||
          u.contains('format=ts');
      if (!isTs) continue;
      var q = (s.quality ?? '').trim();
      if (q.isEmpty) q = s.name.trim().isNotEmpty ? s.name.trim() : 'Calidad ${out.length + 1}';
      if (seen.add(q.toLowerCase())) {
        out.add((label: q, index: i));
      }
    }
    return out;
  }

  Future<void> _selectTsQuality(int serverIndex) async {
    if (serverIndex < 0 || serverIndex >= _servers.length) return;
    setState(() => _showQualities = false);
    await _switchServer(serverIndex);
  }

  Widget _qualitiesPanel() {
    // Panel TS: calidades desde servidores .ts
    if (_isCurrentTs && _tsQualityOptions.isNotEmpty) {
      return Positioned.fill(
        child: GestureDetector(
          onTap: () => setState(() => _showQualities = false),
          child: Container(
            color: Colors.black54,
            alignment: Alignment.centerRight,
            child: Material(
              color: const Color(0xFF1A1F2A),
              child: SizedBox(
                width: 280,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text('Calidad TS',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16)),
                    ),
                    for (final q in _tsQualityOptions)
                      ListTile(
                        selected: _serverIndex == q.index,
                        selectedTileColor: accent.withValues(alpha: 0.2),
                        title: Text(q.label,
                            style: const TextStyle(color: Colors.white)),
                        trailing: _serverIndex == q.index
                            ? const Icon(Icons.check, color: accent)
                            : null,
                        onTap: () => _selectTsQuality(q.index),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final autoLabel = _hlsAutoActual != null && _hlsAutoActual!.isNotEmpty
        ? 'Automática ($_hlsAutoActual)'
        : 'Automática';
    final items = <({String label, String? url, String id})>[
      (label: autoLabel, url: null, id: 'auto'),
      ..._hlsQualities.map((e) => (label: e.label, url: e.url, id: e.label)),
    ];
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showQualities = false),
        child: Container(
          color: Colors.black54,
          alignment: Alignment.centerRight,
          child: Material(
            color: const Color(0xFF1A1F2A),
            child: SizedBox(
              width: 280,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text('Calidad HLS',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16)),
                  ),
                  for (final q in items)
                    ListTile(
                      selected: (q.id == 'auto' &&
                              (_hlsQualityLabel == 'Automática' ||
                                  _hlsQualityLabel.startsWith('Automática'))) ||
                          (_hlsQualityLabel == q.label && q.id != 'auto'),
                      selectedTileColor: accent.withValues(alpha: 0.2),
                      title: Text(q.label,
                          style: const TextStyle(color: Colors.white)),
                      trailing: ((q.id == 'auto' &&
                                  (_hlsQualityLabel == 'Automática' ||
                                      _hlsQualityLabel.startsWith('Automática'))) ||
                              (_hlsQualityLabel == q.label && q.id != 'auto'))
                          ? const Icon(Icons.check, color: accent)
                          : null,
                      onTap: () => _selectHlsQuality(
                          q.id == 'auto' ? 'Automática' : q.label, q.url),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  Widget _subStylePanel() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showSubStyle = false),
        child: Container(
          color: Colors.black54,
          alignment: Alignment.centerRight,
          child: Material(
            color: const Color(0xFF1A1F2A),
            child: SizedBox(
              width: 320,
              child: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text('Subtítulos',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16)),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _showSubStyle = false),
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                    const Text('Tamaño', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    Slider(
                      value: _subFontSize,
                      min: 16,
                      max: 48,
                      activeColor: accent,
                      onChanged: (v) { setState(() => _subFontSize = v); unawaited(_saveSubtitleStyleToPrefs()); },
                    ),
                    Text('${_subFontSize.round()} px',
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 8),
                    const Text('Altura desde el borde inferior',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    Slider(
                      value: _subBottomPad,
                      min: 8,
                      max: 120,
                      activeColor: accent,
                      onChanged: (v) { setState(() => _subBottomPad = v); unawaited(_saveSubtitleStyleToPrefs()); },
                    ),
                    Text('${_subBottomPad.round()} px',
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 8),
                    const Text('Grosor del borde',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    Slider(
                      value: _subBorder,
                      min: 0,
                      max: 4,
                      divisions: 8,
                      activeColor: accent,
                      onChanged: (v) { setState(() => _subBorder = v); unawaited(_saveSubtitleStyleToPrefs()); },
                    ),
                    const SizedBox(height: 8),
                    const Text('Color', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final c in [
                          const Color(0xFFFFFFFF),
                          const Color(0xFFFFFF00),
                          const Color(0xFF00FFFF),
                          const Color(0xFF00FF00),
                          const Color(0xFFFFA0A0),
                        ])
                          GestureDetector(
                            onTap: () { setState(() => _subColor = c); unawaited(_saveSubtitleStyleToPrefs()); },
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _subColor == c ? accent : Colors.white24,
                                  width: _subColor == c ? 3 : 1,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Negrita', style: TextStyle(color: Colors.white)),
                      value: _subBold,
                      activeColor: accent,
                      onChanged: (v) { setState(() => _subBold = v); unawaited(_saveSubtitleStyleToPrefs()); },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fondo oscuro', style: TextStyle(color: Colors.white)),
                      value: _subBg,
                      activeColor: accent,
                      onChanged: (v) { setState(() => _subBg = v); unawaited(_saveSubtitleStyleToPrefs()); },
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: Colors.black,
                      child: Text(
                        'Vista previa de subtítulos',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: _subFontSize * 0.7,
                          color: _subColor,
                          fontWeight: _subBold ? FontWeight.w800 : FontWeight.w500,
                          backgroundColor:
                              _subBg ? const Color(0x99000000) : Colors.transparent,
                          shadows: [
                            Shadow(
                              offset: Offset(_subBorder, _subBorder),
                              blurRadius: _subBorder * 1.5,
                              color: Colors.black,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  SubtitleViewConfiguration _subtitleViewConfig() {
    return SubtitleViewConfiguration(
      style: TextStyle(
        height: 1.35,
        fontSize: _subFontSize,
        color: _subColor,
        fontWeight: _subBold ? FontWeight.w800 : FontWeight.w500,
        backgroundColor: _subBg ? const Color(0x99000000) : Colors.transparent,
        shadows: [
          Shadow(
            offset: Offset(_subBorder, _subBorder),
            blurRadius: _subBorder * 1.5,
            color: Colors.black,
          ),
          Shadow(
            offset: Offset(-_subBorder * 0.6, -_subBorder * 0.6),
            blurRadius: _subBorder,
            color: const Color(0xCC000000),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      padding: EdgeInsets.fromLTRB(16.0, 0.0, 16.0, _subBottomPad),
    );
  }



  static const _pipChannel = MethodChannel('com.lol.lite/channel');

  Future<void> _enterPictureInPicture() async {
    try {
      // Asegurar que el vídeo sigue en play
      if (_useMediaKit) {
        final p = _mk;
        if (p != null && !p.state.playing) await p.play();
      } else {
        final c = _vp;
        if (c != null && !c.value.isPlaying) await c.play();
      }
      final ok = await _pipChannel.invokeMethod<bool>('enterPip');
      if (ok != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Picture-in-Picture no disponible en este dispositivo'),
            backgroundColor: Color(0xFF1A222D),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo activar PiP: $e'),
            backgroundColor: const Color(0xFF1A222D),
          ),
        );
      }
    }
  }

  Future<void> _openCastShare() async {
    final s = _current;
    final url = s?.url ?? widget.url;
    if (url.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay URL de video para transmitir')),
        );
      }
      return;
    }
    final headers = <String, String>{
      ...?widget.headers,
      ...?s?.headers,
    };

    try {
      if (_useMediaKit) {
        await _mk?.pause();
      } else {
        await _vp?.pause();
      }
    } catch (_) {}

    
  }

  Widget _controlsTop() {
    // Solo atrás + reloj + termina (sin título: el título/logo va abajo)
    final ends = _endsAtLabel();
    return Stack(
      children: [
        const Positioned(
          top: 0, left: 0, right: 0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Colors.transparent],
                ),
              ),
              child: SizedBox(height: 72),
            ),
          ),
        ),
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () { _saveProgressNow(); Navigator.maybePop(context); },
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Picture-in-Picture',
                    onPressed: _enterPictureInPicture,
                    icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Transmitir',
                    onPressed: _openCastShare,
                    icon: const Icon(Icons.cast_rounded, color: Colors.white),
                  ),
                  Text(
                    _clockNow(),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (ends.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(
                      ends,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _controlsBottom() {
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final s = _current;
    final quality = (s?.quality != null && s!.quality!.isNotEmpty) ? s.quality! : 'Auto';
    final lang = (s?.language != null && s!.language!.isNotEmpty)
        ? s.language!
        : (widget.preferredLanguage.isNotEmpty ? widget.preferredLanguage : '—');
    final repoName = widget.loadRepo?.manifest.name ?? widget.repoId ?? '';
    final epLine = _subtitleLine;
    final typeLabel = widget.contentType.toLowerCase().contains('tv') ||
            widget.contentType.toLowerCase().contains('series')
        ? 'Serie'
        : (widget.contentType.toLowerCase().contains('movie') ? 'Película' : widget.contentType);

    return Stack(
      children: [
        const Positioned(
          bottom: 0, left: 0, right: 0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xEE000000), Colors.transparent],
                ),
              ),
              child: SizedBox(height: 200),
            ),
          ),
        ),

        // BOTTOM: meta + progress + actions
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Título o logo (solo aquí, no en appbar)
                  if (widget.logo != null && widget.logo!.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      height: 32,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: CachedNetworkImage(
                          imageUrl: widget.logo!,
                          height: 32,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          placeholder: (_, __) =>
                              const SizedBox(height: 32, width: 1),
                          errorWidget: (_, __, ___) => Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 6)
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                      ),
                    ),
                  if (epLine.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      epLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // Badges de calidad + idioma con bandera
                  _serverBadgesRow(s, fallbackQuality: quality, fallbackLang: lang),
                  const SizedBox(height: 6),
                  // Año / tipo / via repo (sin HLS/TS ni motor)
                  Text(
                    [
                      typeLabel,
                      'via App',
                      if (repoName.isNotEmpty) repoName,
                    ].where((e) => e.toString().trim().isNotEmpty).join('  ·  '),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Progress (sin tiempos a los lados)
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3.5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                        elevation: 0,
                      ),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: const Color(0xFF4FC3F7),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                      thumbColor: Colors.white,
                      overlayColor: const Color(0xFF4FC3F7).withValues(alpha: 0.22),
                      trackShape: const RoundedRectSliderTrackShape(),
                    ),
                    child: Slider(
                      value: progress,
                      onChangeStart: (_) {
                        setState(() => _isDragging = true);
                        _hideTimer?.cancel();
                      },
                      onChanged: (v) {
                        if (_duration.inMilliseconds <= 0) return;
                        setState(() {
                          _position = Duration(
                            milliseconds: (v * _duration.inMilliseconds).round(),
                          );
                        });
                      },
                      onChangeEnd: (v) async {
                        setState(() => _isDragging = false);
                        if (_duration.inMilliseconds <= 0) return;
                        final d = Duration(
                          milliseconds: (v * _duration.inMilliseconds).round(),
                        );
                        if (_useMediaKit) {
                          await _mk?.seek(d);
                        } else {
                          await _vp?.seekTo(d);
                        }
                        _scheduleHide();
                      },
                    ),
                  ),

                  // Acciones (sin ±10: el doble toque lo hace)
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Play',
                                onPressed: _togglePlay,
                                icon: Icon(
                                  _playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Reiniciar',
                                onPressed: () async {
                                  if (_useMediaKit) {
                                    await _mk?.seek(Duration.zero);
                                  } else {
                                    await _vp?.seekTo(Duration.zero);
                                  }
                                  _scheduleHide();
                                },
                                icon: const Icon(Icons.replay_rounded,
                                    color: Colors.white, size: 24),
                              ),
                              // Audio / subtítulos: TS embebidos o HLS externos del repo
                              if (_useMediaKit || _externalSubs.isNotEmpty)
                                IconButton(
                                  tooltip: 'Audio / Subtítulos',
                                  onPressed: () => setState(() {
                                    _showTracks = true;
                                    _showServers = false;
                                    _showQualities = false;
                                    _showControls = true;
                                  }),
                                  icon: const Icon(Icons.closed_caption_rounded,
                                      color: Colors.white, size: 26),
                                ),
                              // Calidad HLS (variantes) o TS (servidores .ts por quality)
                              if (_hlsQualities.isNotEmpty ||
                                  isHlsUrl(_current?.url ?? widget.url,
                                      isHlsFlag: _current?.isHls ?? false) ||
                                  (_isCurrentTs && _tsQualityOptions.length > 1))
                                IconButton(
                                  tooltip: _isCurrentTs
                                      ? 'Calidad TS'
                                      : _qualityButtonLabel(),
                                  onPressed: () => setState(() {
                                    _showQualities = true;
                                    _showServers = false;
                                    _showTracks = false;
                                    _showControls = true;
                                  }),
                                  icon: const Icon(Icons.high_quality_rounded,
                                      color: Colors.white, size: 26),
                                ),
                              if (_servers.isNotEmpty)
                                IconButton(
                                  tooltip: 'Servidores',
                                  onPressed: () => setState(() {
                                    _showServers = true;
                                    _showTracks = false;
                                    _showQualities = false;
                                    _showControls = true;
                                  }),
                                  icon: const Icon(Icons.dns_rounded,
                                      color: Colors.white, size: 26),
                                ),
                              IconButton(
                                tooltip: _fitLabels[_fitModes.indexOf(_fit)
                                    .clamp(0, _fitLabels.length - 1)],
                                onPressed: _cycleFit,
                                icon: const Icon(Icons.aspect_ratio_rounded,
                                    color: Colors.white, size: 26),
                              ),
                              IconButton(
                                tooltip: 'Estilo subtítulos',
                                onPressed: () => setState(() {
                                  _showSubStyle = true;
                                  _showControls = true;
                                }),
                                icon: const Icon(Icons.text_fields_rounded,
                                    color: Colors.white, size: 24),
                              ),
                              if (_effectiveEpisodeList.isNotEmpty)
                                IconButton(
                                  tooltip: 'Capítulos',
                                  onPressed: () {
                                    final se = widget.season;
                                    setState(() {
                                      _showEpisodes = true;
                                      _showServers = false;
                                      _showTracks = false;
                                      _showQualities = false;
                                      _showSubStyle = false;
                                      _showControls = true;
                                      if (se != null) {
                                        _episodesSeasonFilter = se;
                                      } else {
                                        _episodesSeasonFilter = -1;
                                      }
                                    });
                                  },
                                  icon: const Icon(Icons.list_rounded,
                                      color: Colors.white, size: 26),
                                ),
                              if (_hasNextEpisode)
                                IconButton(
                                  tooltip: 'Siguiente capítulo',
                                  onPressed: () =>
                                      _goNextEpisode(usePreload: false),
                                  icon: const Icon(Icons.skip_next_rounded,
                                      color: Colors.white, size: 28),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Text(
                        '${_fmt(_position)} / ${_fmt(_duration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }


  bool get _hasNextEpisode =>
      widget.nextSeason != null && widget.nextEpisode != null;

  bool get _shouldShowNextCta {
    if (!_hasNextEpisode) return false;
    if (_duration.inMilliseconds <= 0) return false;
    final ratio = _position.inMilliseconds / _duration.inMilliseconds;
    if (_showControls) {
      return ratio >= 0.90 || _showNextCta;
    }
    return _showNextCta;
  }

  Widget _nextEpisodeOverlay() {
    final label = widget.nextEpisodeTitle?.isNotEmpty == true
        ? widget.nextEpisodeTitle!
        : 'T${widget.nextSeason} · E${widget.nextEpisode}';
    return Positioned(
      right: 16,
      bottom: _showControls ? 118 : 28,
      child: SafeArea(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _goNextEpisode(),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withValues(alpha: 0.85), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.25),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.skip_next_rounded, color: accent, size: 22),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Siguiente capítulo',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodesPanel() {
    final list = _effectiveEpisodeList;
    final seasons = <int>{};
    for (final e in list) {
      final se = (e['season'] as num?)?.toInt();
      if (se != null) seasons.add(se);
    }
    final seasonList = seasons.toList()..sort();
    final filter = _episodesSeasonFilter;
    final filtered = filter < 0
        ? list
        : list.where((e) => (e['season'] as num?)?.toInt() == filter).toList();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showEpisodes = false),
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
        GestureDetector(
          onTap: () {},
          child: Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: const Color(0xEE141A22),
              child: SafeArea(
                child: SizedBox(
                  width: 380,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Temporadas / Capítulos',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _showEpisodes = false),
                              icon: const Icon(Icons.close,
                                  color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      if (seasonList.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                FilterChip(
                                  label: const Text('Todas',
                                      style: TextStyle(fontSize: 12)),
                                  selected: filter < 0,
                                  onSelected: (_) => setState(
                                      () => _episodesSeasonFilter = -1),
                                  selectedColor: accent,
                                  backgroundColor: Colors.white10,
                                  checkmarkColor: Colors.white,
                                  labelStyle: TextStyle(
                                    color: filter < 0
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                const SizedBox(width: 6),
                                for (final s in seasonList) ...[
                                  FilterChip(
                                    label: Text('T$s',
                                        style: const TextStyle(fontSize: 12)),
                                    selected: filter == s,
                                    onSelected: (_) => setState(
                                        () => _episodesSeasonFilter = s),
                                    selectedColor: accent,
                                    backgroundColor: Colors.white10,
                                    checkmarkColor: Colors.white,
                                    labelStyle: TextStyle(
                                      color: filter == s
                                          ? Colors.white
                                          : Colors.white70,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  const SizedBox(width: 6),
                                ],
                              ],
                            ),
                          ),
                        ),
                      if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No hay lista de capítulos',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final e = filtered[i];
                              final se = (e['season'] as num?)?.toInt();
                              final ep = (e['episode'] as num?)?.toInt() ??
                                  (e['number'] as num?)?.toInt();
                              final id = e['id']?.toString();
                              final title = (e['title'] ?? '').toString();
                              final still = (e['still'] ?? e['poster'] ?? '')
                                  .toString();
                              final isCurrent = se == widget.season &&
                                  ep == widget.episode;
                              final code = se != null && ep != null
                                  ? 'T$se · E$ep'
                                  : (ep != null ? 'E$ep' : 'Capítulo');
                              return ListTile(
                                selected: isCurrent,
                                selectedTileColor:
                                    accent.withValues(alpha: 0.2),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                leading: still.startsWith('http')
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: CachedNetworkImage(
                                          imageUrl: still,
                                          width: 72,
                                          height: 42,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) =>
                                              Container(
                                            width: 72,
                                            height: 42,
                                            color: Colors.white10,
                                            alignment: Alignment.center,
                                            child: const Icon(
                                              Icons.play_arrow,
                                              color: Colors.white54,
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                      )
                                    : Container(
                                        width: 72,
                                        height: 42,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: Colors.white10,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          code,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                title: Text(
                                  title.isNotEmpty ? title : code,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                                subtitle: Text(
                                  code,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: isCurrent
                                    ? Icon(Icons.play_circle_fill,
                                        color: accent, size: 22)
                                    : const Icon(Icons.play_arrow_rounded,
                                        color: Colors.white38, size: 22),
                                onTap: () {
                                  if (se == null || ep == null) return;
                                  if (isCurrent) {
                                    setState(() => _showEpisodes = false);
                                    return;
                                  }
                                  _openEpisodeFromList(
                                    season: se,
                                    episode: ep,
                                    episodeId: id,
                                    episodeTitle:
                                        title.isNotEmpty ? title : null,
                                  );
                                },
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _serversPanel() {
    final langs = _availableLanguages;
    final indices = _filteredServerIndices;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showServers = false),
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
        GestureDetector(
          onTap: () {},
          child: Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: const Color(0xEE141A22),
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
                        child: Text(
                          langs.length > 1
                              ? 'Idioma / Calidad / Servidor'
                              : 'Calidad / Servidor',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        onPressed: () =>
                            setState(() => _showServers = false),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                if (langs.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _langChip('Todos', null),
                          const SizedBox(width: 6),
                          for (final l in langs) ...[
                            _langChip(l, l),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (_servers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Sin servidores',
                        style: TextStyle(color: Colors.white54)),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      itemCount: indices.length,
                      itemBuilder: (context, idx) {
                        final i = indices[idx];
                        final s = _servers[i];
                        final sel = i == _serverIndex;
                        return ListTile(
                          selected: sel,
                          selectedTileColor: accent.withValues(alpha: 0.2),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          leading: _langFlagAvatar(s),
                          title: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: _serverBadgesRow(s, compact: true),
                          ),
                          trailing: sel
                              ? Icon(Icons.check_circle, color: accent, size: 22)
                              : null,
                          onTap: () => _switchServer(i),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
        ),
      ],
    );
  }


  Widget _langFlagAvatar(StreamServer s) {
    final info = StreamBadgeCatalog.detectLanguage(s.language, s.name);
    if (info.flagUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CachedNetworkImage(
          imageUrl: info.flagUrl!,
          width: 28,
          height: 20,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _langFallbackChip(info.label),
        ),
      );
    }
    return _langFallbackChip(info.label);
  }

  Widget _langFallbackChip(String label) {
    final short = label.length <= 3
        ? label.toUpperCase()
        : label.substring(0, 3).toUpperCase();
    return Container(
      width: 28,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        short,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _serverBadgesRow(
    StreamServer? s, {
    String fallbackQuality = '',
    String fallbackLang = '',
    bool compact = false,
  }) {
    final text = StreamBadgeCatalog.haystack(
      name: s?.name,
      quality: s?.quality ??
          (fallbackQuality.isNotEmpty ? fallbackQuality : null),
      language: s?.language ??
          (fallbackLang.isNotEmpty ? fallbackLang : null),
      provider: s?.provider,
      extra: s?.extra,
    );
    final badges = StreamBadgeCatalog.matchBadges(text);
    final lang = StreamBadgeCatalog.detectLanguage(
      s?.language ?? (fallbackLang.isNotEmpty ? fallbackLang : null),
      s?.name,
    );

    final children = <Widget>[];

    children.add(
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (lang.flagUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: CachedNetworkImage(
                  imageUrl: lang.flagUrl!,
                  width: 18,
                  height: 12,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: 5),
            ] else if (lang.code == 'sub') ...[
              const Icon(Icons.closed_caption, size: 12, color: Colors.white70),
              const SizedBox(width: 4),
            ],
            Text(
              lang.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    for (final b in badges) {
      children.add(const SizedBox(width: 6));
      children.add(
        Tooltip(
          message: b.name,
          child: CachedNetworkImage(
            imageUrl: b.imageUrl,
            height: compact ? 16 : 18,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                b.name,
                style: const TextStyle(color: Colors.white70, fontSize: 9),
              ),
            ),
          ),
        ),
      );
    }

    if (badges.isEmpty) {
      final raw = (s?.quality ?? fallbackQuality).trim();
      final q = StreamBadgeCatalog.normalizeQuality(raw);
      // No mostrar HLS/TS/Auto como "calidad"
      if (q.isNotEmpty) {
        // Reintentar match solo con calidad normalizada
        final again = StreamBadgeCatalog.matchBadges(q);
        if (again.isNotEmpty) {
          for (final b in again) {
            children.add(const SizedBox(width: 6));
            children.add(
              Tooltip(
                message: b.name,
                child: CachedNetworkImage(
                  imageUrl: b.imageUrl,
                  height: compact ? 16 : 18,
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => _metaBadge(label: b.name, filled: true),
                ),
              ),
            );
          }
        } else {
          children.add(const SizedBox(width: 6));
          children.add(_metaBadge(label: q, filled: true));
        }
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
  }

  Widget _langChip(String label, String? value) {
    final selected = _langFilter == value;
    return FilterChip(
      label: Text(label,
          style: TextStyle(
              color: selected ? Colors.white : Colors.white70, fontSize: 12)),
      selected: selected,
      onSelected: (_) => setState(() => _langFilter = value),
      selectedColor: accent,
      backgroundColor: Colors.white10,
      checkmarkColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _tracksPanel() {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showTracks = false),
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
        GestureDetector(
          onTap: () {},
          child: Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: const Color(0xEE141A22),
        child: SafeArea(
          child: SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Audio / Subtitulos',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        onPressed: () =>
                            setState(() => _showTracks = false),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      if (_audioTracks.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text('IDIOMA / AUDIO',
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1)),
                        ),
                        for (final t in _audioTracks)
                          ListTile(
                            selected: _selectedAudio?.id == t.id,
                            selectedTileColor: accent.withValues(alpha: 0.2),
                            leading: Icon(
                              Icons.audiotrack,
                              color: _selectedAudio?.id == t.id
                                  ? accent
                                  : Colors.white54,
                            ),
                            title: Text(_trackLabel(t),
                                style: const TextStyle(color: Colors.white)),
                            onTap: () async {
                              await _mk?.setAudioTrack(t);
                              setState(() => _selectedAudio = t);
                              unawaited(_persistTrackChoice(
                                audioLang: t.language ?? t.title ?? t.id,
                              ));
                            },
                          ),
                      ],
                      // Subtitulos: siempre mostrar seccion en TS
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text('SUBTITULOS',
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1)),
                      ),
                      ListTile(
                        selected: _selectedSubtitle == null ||
                            _selectedSubtitle?.id == 'no',
                        selectedTileColor: accent.withValues(alpha: 0.2),
                        leading: const Icon(Icons.subtitles_off,
                            color: Colors.white54),
                        title: const Text('Sin subtitulos',
                            style: TextStyle(color: Colors.white)),
                        onTap: () async {
                          await _mk?.setSubtitleTrack(SubtitleTrack.no());
                          setState(
                              () => _selectedSubtitle = SubtitleTrack.no());
                          await _clearExternalSubtitle();
                          unawaited(_persistTrackChoice(subChoice: 'off'));
                        },
                      ),
                      if (_subtitleTracks.isEmpty && _externalSubs.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Text(
                            'No hay subtítulos embebidos ni del repositorio.',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ),
                      for (final t in _subtitleTracks)
                        ListTile(
                          selected: _selectedSubtitle?.id == t.id,
                          selectedTileColor: accent.withValues(alpha: 0.2),
                          leading: Icon(
                            Icons.subtitles,
                            color: _selectedSubtitle?.id == t.id
                                ? accent
                                : Colors.white54,
                          ),
                          title: Text(_trackLabel(t),
                              style: const TextStyle(color: Colors.white)),
                          subtitle: const Text('Embebido',
                              style: TextStyle(color: Colors.white38, fontSize: 11)),
                          onTap: () async {
                            await _mk?.setSubtitleTrack(t);
                            setState(() => _selectedSubtitle = t);
                            unawaited(
                                _persistTrackChoice(subChoice: 'embedded:${t.id}'));
                          },
                        ),
                      if (_externalSubs.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('DEL REPOSITORIO',
                              style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1)),
                        ),
                        ListTile(
                          selected: !_subsEnabled || _activeExternalSub == null,
                          selectedTileColor: accent.withValues(alpha: 0.15),
                          leading: const Icon(Icons.subtitles_off,
                              color: Colors.white54),
                          title: const Text('Sin subtítulos externos',
                              style: TextStyle(color: Colors.white)),
                          onTap: _clearExternalSubtitle,
                        ),
                        for (final sub in _externalSubs)
                          ListTile(
                            selected: _activeExternalSub?.url == sub.url &&
                                _subsEnabled,
                            selectedTileColor: accent.withValues(alpha: 0.2),
                            leading: Icon(
                              Icons.subtitles,
                              color: _activeExternalSub?.url == sub.url
                                  ? accent
                                  : Colors.white54,
                            ),
                            title: Text(sub.label,
                                style: const TextStyle(color: Colors.white)),
                            subtitle: Text(sub.lang.toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 11)),
                            onTap: () async {
                              await _applyExternalSubtitle(sub);
                              unawaited(_persistTrackChoice(
                                  subChoice: 'external:${sub.url}'));
                            },
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
      ],
    );
  }
}

class _SubCue {
  final Duration start;
  final Duration end;
  final String text;
  const _SubCue({required this.start, required this.end, required this.text});
}