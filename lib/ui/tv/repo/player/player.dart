import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/models/stream_server.dart';
import '../../../../data/models/stream_badges.dart';
import '../../../../data/models/repo_manifest.dart';

enum _VideoFitMode { original, ratio16_9, ratio21_9, ratio16_10, ratio4_3 }

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

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const accent = Color(0xFFE50914);
  /// Identificador único de este player (HLS/video_player + TS/media_kit).
  /// El historial "continuar viendo" lo guarda para que el mismo player lo reconozca.
  static const String playerId = 'dual_player_hls_ts_v1';
  /// Calidad HLS preferida en esta sesión de app (null = automática).
  static String? sessionHlsQuality;
  /// Cache de playlist de episodios por contenido (repoId|contentId).
  static final Map<String, List<Map<String, dynamic>>> _episodeListCache = {};
  /// Calidad real detectada cuando está en modo Automática.
  String? _hlsAutoActual;

  // Wakelock: evita el protector de pantalla de Android TV mientras se reproduce.
  Timer? _wakelockTimer;
  /// true cuando este player va a ser reemplazado por otro (pushReplacement),
  /// para no desactivar el wakelock que ya tomó el nuevo player.
  bool _navigatingToNextPlayer = false;

  // Intro / outro (segmentos del repo)
  double? _introStartSec;
  double? _introEndSec;
  double? _outroStartSec;
  double? _outroEndSec;
  bool _introSkipped = false;
  bool _showSkipIntro = false;
  bool _showSkipOutro = false;
  /// Tras 10s se auto-oculta; solo vuelve con controles.
  bool _skipIntroAutoHidden = false;
  bool _skipOutroAutoHidden = false;
  int _skipIntroCountdown = 10;
  int _skipOutroCountdown = 10;
  Timer? _skipIntroTimer;
  Timer? _skipOutroTimer;
  bool _introArmed = false;
  bool _outroArmed = false;
  final FocusNode _skipIntroFocus = FocusNode(debugLabel: 'skip_intro');
  final FocusNode _skipOutroFocus = FocusNode(debugLabel: 'skip_outro');
  final FocusNode _skipNextFocus = FocusNode(debugLabel: 'skip_next');
  bool _nextCtaShownOnce = false;

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

  // Estilo de subtítulos (ajustable) — mismas claves SharedPreferences que Configuración
  static const String _kSubFontSize = 'player_sub_font_size';
  static const String _kSubBottomPad = 'player_sub_bottom_pad';
  static const String _kSubColor = 'player_sub_color';
  static const String _kSubBold = 'player_sub_bold';
  static const String _kSubBg = 'player_sub_bg';
  static const String _kSubBorder = 'player_sub_border';
  static const String _kSubOffset = 'player_sub_offset';
  static const String _kHlsQuality = 'player_hls_quality';
  static const String _kLastAudioLang = 'player_last_audio_lang';
  static const String _kLastSubChoice = 'player_last_sub_choice'; // off | embedded:id | external:url

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
  /// Posición de historial a forzar en media_kit (.ts); se reaplica si el demuxer resetea a 0.
  int? _resumeTargetMs;
  bool _resumeConfirmed = false;
  /// Posición visual mientras se mantiene ←/→ (scrub sin seek hasta soltar).
  int? _scrubTargetMs;
  Timer? _scrubCommitTimer;
  Timer? _nextCtaTimer;

  bool _showTracks = false;
  String? _error;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Timer? _hideTimer;
  Timer? _progressTimer;

  // --- TV: foco, back en 2 pasos, pantalla de espera ---
  final FocusNode _rootFocus = FocusNode();
  final FocusNode _playFocus = FocusNode();
  final FocusNode _progressFocus = FocusNode();
  final FocusNode _panelFocus = FocusNode();
  DateTime? _pausedAt;
  Timer? _idleTimer;
  bool _showIdleScreen = false;
  bool _awaitingExitConfirm = false;
  /// Permite un pop real tras confirmar "Salir" (PopScope canPop=false lo bloqueaba).
  bool _forcePop = false;

  // TV: fila de foco en controles (0 oculto, 1 seek, 2 acciones, 3 temporadas, 4 episodios)
  int _tvFocusRow = 2;
  bool _showEpisodesPanel = false;
  int _panelSeason = 0; // número de temporada seleccionada en el panel
  final ScrollController _seasonScrollCtrl = ScrollController();
  final ScrollController _episodeScrollCtrl = ScrollController();
  final List<FocusNode> _seasonFocusNodes = [];
  final List<FocusNode> _episodeFocusNodes = [];

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

  // Dimensiones / aspecto (como player TV)
  _VideoFitMode _fitMode = _VideoFitMode.original;
  bool _showFitHud = false;
  Timer? _fitHudTimer;

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

  bool _isSpeedBoost = false;
  double _playbackRate = 1.0;
  bool _showSeekHud = false;
  int _seekHudSeconds = 0;
  Timer? _seekHudTimer;
  DateTime? _lastTapAt;
  Offset? _lastTapPos;
  Timer? _singleTapTimer;

  /// Solo barra de progreso (sin botones) al seek con flechas y controles ocultos.
  bool _showProgressOnly = false;
  Timer? _progressOnlyTimer;

  /// Aceleración al mantener ←/→ en la barra de progreso.
  int _seekHoldCount = 0;
  DateTime? _seekHoldStartedAt;
  Timer? _seekHoldResetTimer;

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

  /// Mantiene la pantalla encendida (evita el protector de Android TV).
  void _keepScreenAwake() {
    WakelockPlus.enable();
    _wakelockTimer?.cancel();
    _wakelockTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted) return;
      try {
        if (_playing) {
          await WakelockPlus.enable();
        }
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepScreenAwake();

    // TV: inicia reproduciendo sin controles visibles
    if (widget.isTv) {
      _showControls = false;
    }

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

  /// Carga estilo de subtítulos + calidad HLS desde las mismas claves que Configuración.
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
        sessionHlsQuality = (hls == 'auto' || hls == 'Automática') ? null : hls;
      }
    } catch (e) {
      debugPrint('[Player] load sub style prefs: $e');
    }
  }

  /// Guarda estilo de subtítulos (mismas claves que GlobalSettingsPage).
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

      if (lastSub == null || lastSub.isEmpty || lastSub == 'off') {
        // No forzar off al abrir; solo si el usuario lo eligió explícitamente
        if (lastSub == 'off') {
          try {
            await _mk?.setSubtitleTrack(SubtitleTrack.no());
          } catch (_) {}
          await _clearExternalSubtitle();
        }
      } else if (lastSub.startsWith('external:')) {
        final key = lastSub.substring(9);
        final sub = _externalSubs
            .where((s) => s.url == key || s.label == key)
            .toList();
        if (sub.isNotEmpty) {
          await _applyExternalSubtitle(sub.first);
        }
      } else if (lastSub.startsWith('embedded:') &&
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

  String? get _episodeCacheKey {
    final c = widget.contentId;
    if (c == null || c.isEmpty) return null;
    final r = widget.repoId ?? '';
    return 'player_episode_list_${r}_$c';
  }

  /// Lista efectiva: widget o recuperada de SharedPreferences / memoria.
  List<Map<String, dynamic>> _cachedEpisodeList = const [];
  List<Map<String, dynamic>> get _effectiveEpisodeList =>
      widget.episodeList.isNotEmpty ? widget.episodeList : _cachedEpisodeList;

  /// Guarda y recupera la playlist de capítulos (SharedPreferences + memoria).
  Future<void> _hydrateEpisodeListCache() async {
    final key = _episodeCacheKey;
    if (key == null) return;

    // 1) Viene del widget → persistir
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

    // 2) Memoria de sesión
    final mem = _episodeListCache[key];
    if (mem != null && mem.isNotEmpty) {
      _cachedEpisodeList = List<Map<String, dynamic>>.from(mem);
      if (mounted) setState(() {});
      return;
    }

    // 3) Disco (SharedPreferences)
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

  @override
  void dispose() {
    // Si saltamos al siguiente capítulo, el progreso ya se guardó con
    // _saveProgressNowAsync(). No reescribir o el historial queda en el anterior.
    if (!_navigatingToNextPlayer) {
      try {
        _saveProgressNow();
      } catch (_) {}
    }
    // No usar context aquí (puede fallar / notificar durante dispose).
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _volumeHudTimer?.cancel();
    _fitHudTimer?.cancel();
    _seekHudTimer?.cancel();
    _skipIntroTimer?.cancel();
    _skipOutroTimer?.cancel();
    _nextCtaTimer?.cancel();
    _idleTimer?.cancel();
    _progressOnlyTimer?.cancel();
    _seekHoldResetTimer?.cancel();
    _scrubCommitTimer?.cancel();
    _wakelockTimer?.cancel();
    _rootFocus.dispose();
    _playFocus.dispose();
    _progressFocus.dispose();
    _panelFocus.dispose();
    _skipIntroFocus.dispose();
    _skipOutroFocus.dispose();
    _skipNextFocus.dispose();
    for (final n in _seasonFocusNodes) {
      n.dispose();
    }
    for (final n in _episodeFocusNodes) {
      n.dispose();
    }
    _seasonScrollCtrl.dispose();
    _episodeScrollCtrl.dispose();
    _disposeEngines();
    // No deshabilitar si otro PlayerPage ya tomó el control (pushReplacement)
    if (!_navigatingToNextPlayer) {
      WakelockPlus.disable();
    }
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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

  String? get _serversCacheKey {
    final repo = widget.repoId ?? widget.loadRepo?.manifest.id;
    final cid = widget.contentId;
    if (repo == null || repo.isEmpty || cid == null || cid.isEmpty) return null;
    final se = widget.season;
    final ep = widget.episode;
    if (se != null && ep != null) {
      return 'player_servers_cache_${repo}_${cid}_s${se}_e$ep';
    }
    return 'player_servers_cache_${repo}_$cid';
  }

  static const Duration _serversCacheTtl = Duration(hours: 12);

  Future<List<StreamServer>?> _loadServersFromCache() async {
    final key = _serversCacheKey;
    if (key == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final savedAt = DateTime.tryParse('${map['savedAt'] ?? ''}');
      if (savedAt == null) return null;
      if (DateTime.now().difference(savedAt) > _serversCacheTtl) {
        await prefs.remove(key);
        return null;
      }
      final list = map['servers'];
      if (list is! List || list.isEmpty) return null;
      final out = <StreamServer>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final s = _streamServerFromCacheMap(m);
        if (s != null && s.url.isNotEmpty) out.add(s);
      }
      if (out.isEmpty) return null;
      debugPrint('[Player] servers cache hit (${out.length}) key=$key');
      return out;
    } catch (e) {
      debugPrint('[Player] servers cache load: $e');
      return null;
    }
  }

  Future<void> _saveServersToCache(List<StreamServer> servers) async {
    final key = _serversCacheKey;
    if (key == null || servers.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = servers.map(_streamServerToCacheMap).toList();
      await prefs.setString(
        key,
        jsonEncode({
          'savedAt': DateTime.now().toIso8601String(),
          'servers': encoded,
        }),
      );
      debugPrint('[Player] servers cache saved (${servers.length}) key=$key');
    } catch (e) {
      debugPrint('[Player] servers cache save: $e');
    }
  }

  Map<String, dynamic> _streamServerToCacheMap(StreamServer s) {
    try {
      final dyn = (s as dynamic).toJson;
      if (dyn is Function) {
        final j = dyn();
        if (j is Map) return Map<String, dynamic>.from(j);
      }
    } catch (_) {}
    final headers = <String, String>{};
    try {
      final h = s.headers;
      h.forEach((k, v) {
        if (k.isNotEmpty) headers[k] = v;
      });
    } catch (_) {}
    String? provider;
    try {
      provider = (s as dynamic).provider?.toString();
    } catch (_) {}
    return {
      'url': s.url,
      'name': s.name,
      'headers': headers,
      'isHls': s.isHls,
      'language': s.language,
      'quality': s.quality,
      if (provider != null) 'provider': provider,
    };
  }

  StreamServer? _streamServerFromCacheMap(Map<String, dynamic> m) {
    try {
      try {
        final fromJson = (StreamServer as dynamic).fromJson;
        if (fromJson is Function) {
          final s = fromJson(m);
          if (s is StreamServer) return s;
        }
      } catch (_) {}
      final url = (m['url'] ?? '').toString();
      if (url.isEmpty) return null;
      final headersRaw = m['headers'];
      final headers = <String, String>{};
      if (headersRaw is Map) {
        headersRaw.forEach((k, v) {
          if (k != null && v != null) headers['$k'] = '$v';
        });
      }
      // Constructor mínimo (url/name/headers/isHls); resto vía toJson/fromJson si existe.
      try {
        return StreamServer(
          url: url,
          name: (m['name'] ?? 'Servidor').toString(),
          headers: headers,
          isHls: m['isHls'] == true ||
              isHlsUrl(url, isHlsFlag: m['isHls'] == true),
          language: m['language']?.toString(),
          quality: m['quality']?.toString(),
        );
      } catch (_) {
        return StreamServer(
          url: url,
          name: (m['name'] ?? 'Servidor').toString(),
          headers: headers,
          isHls: m['isHls'] == true ||
              isHlsUrl(url, isHlsFlag: m['isHls'] == true),
        );
      }
    } catch (e) {
      debugPrint('[Player] stream from cache: $e');
      return null;
    }
  }

  Future<void> _loadStreamsThenPlay() async {
    setState(() {
      _loadingStreams = true;
      _loading = true;
      _error = null;
    });
    try {
      // 1) Caché local 12h (por contenido / capítulo)
      final cached = await _loadServersFromCache();
      if (cached != null && cached.isNotEmpty) {
        if (!mounted) return;
        _servers = cached;
        var preferred = _pickPreferredServer(cached);
        setState(() => _loadingStreams = false);
        preferred = await _firstHealthyServer(from: preferred);
        if (!mounted) return;
        _serverIndex = preferred;
        unawaited(_probeRemainingServersInBackground(playingIndex: preferred));
        await _startCurrent();
        // Refresco silencioso en background (renueva caché)
        unawaited(_refreshServersInBackground());
        return;
      }

      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        widget.contentId!,
        type: widget.contentType,
        season: widget.season,
        episode: widget.episode,
      );
      if (!mounted) return;
      _servers = list;
      if (list.isNotEmpty) unawaited(_saveServersToCache(list));
      var preferred = _pickPreferredServer(list);
      setState(() => _loadingStreams = false);
      if (_servers.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No hay servidores disponibles';
        });
        return;
      }
      // Arrancar con el primer servidor válido lo antes posible;
      // el resto se sigue validando en segundo plano.
      preferred = await _firstHealthyServer(from: preferred);
      if (!mounted) return;
      _serverIndex = preferred;
      unawaited(_probeRemainingServersInBackground(playingIndex: preferred));
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

  Future<void> _refreshServersInBackground() async {
    if (widget.loadRepo == null || widget.contentId == null) return;
    try {
      final list = await ContentService.instance.getStreams(
        widget.loadRepo!,
        widget.contentId!,
        type: widget.contentType,
        season: widget.season,
        episode: widget.episode,
      );
      if (!mounted || list.isEmpty) return;
      await _saveServersToCache(list);
      // Actualizar lista sin interrumpir reproducción si el actual sigue vivo
      final currentUrl = _current?.url;
      final ordered = <StreamServer>[];
      if (currentUrl != null) {
        final match = list.where((s) => s.url == currentUrl).toList();
        if (match.isNotEmpty) ordered.add(match.first);
      }
      for (final s in list) {
        if (currentUrl != null && s.url == currentUrl) continue;
        ordered.add(s);
      }
      if (!mounted || ordered.isEmpty) return;
      setState(() {
        _servers = ordered;
        _serverIndex = 0;
      });
    } catch (e) {
      debugPrint('[Player] refresh servers bg: $e');
    }
  }

  /// Tras poner el servidor actual en reproducción, valida el resto en background
  /// y reordena la lista dejando primero los sanos (sin tocar el que ya suena).
  Future<void> _probeRemainingServersInBackground({required int playingIndex}) async {
    if (_servers.length <= 1) return;
    final n = _servers.length;
    final healthy = <int>[];
    final unhealthy = <int>[];
    for (var i = 0; i < n; i++) {
      if (!mounted) return;
      if (i == playingIndex) {
        healthy.add(i);
        continue;
      }
      final ok = await _probeServer(_servers[i]);
      if (!mounted) return;
      if (ok) {
        healthy.add(i);
      } else {
        unhealthy.add(i);
        debugPrint('[Player] bg probe: server $i unhealthy');
      }
    }
    if (!mounted || healthy.isEmpty) return;
    // Reordenar: actual primero, luego otros sanos, al final los fallidos.
    final ordered = <StreamServer>[];
    final current = _servers[playingIndex];
    ordered.add(current);
    for (final i in healthy) {
      if (i == playingIndex) continue;
      ordered.add(_servers[i]);
    }
    for (final i in unhealthy) {
      ordered.add(_servers[i]);
    }
    if (!mounted) return;
    setState(() {
      _servers = ordered;
      _serverIndex = 0;
    });
    unawaited(_saveServersToCache(ordered));
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
    _skipIntroAutoHidden = false;
    _skipOutroAutoHidden = false;
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

  bool get _inIntroZone {
    if (_introSkipped) return false;
    if (_introStartSec == null || _introEndSec == null) return false;
    final sec = _position.inMilliseconds / 1000.0;
    return _inRange(sec, _introStartSec, _introEndSec);
  }

  /// Outro / siguiente: segmento del repo (2ª mitad) o, si no viene en el repo, ≥ 90%.
  bool get _inOutroZone {
    // Sin siguiente capítulo y sin outro del repo no hay nada que omitir.
    if (!_hasNextEpisode && _outroEndSec == null && _outroStartSec == null) {
      return false;
    }
    final totalMs = _duration.inMilliseconds;
    if (totalMs < 5000) return false; // aún sin duración real
    final sec = _position.inMilliseconds / 1000.0;
    final totalSec = totalMs / 1000.0;
    final ratio = _position.inMilliseconds / totalMs;

    // Segmento del repo solo si empieza en la segunda mitad del vídeo
    if (_outroStartSec != null && _outroStartSec! >= totalSec * 0.5) {
      final end = _outroEndSec ?? totalSec;
      return sec >= _outroStartSec! && sec <= end;
    }
    // Sin segmento de repo → a partir del 90%
    return ratio >= 0.90;
  }

  /// Primeros 10s a pantalla completa (sin controles), o con controles si sigue en zona.
  bool get _introBtnVisible {
    if (_showProgressOnly || _showEpisodesPanel) return false;
    if (!_inIntroZone || !_introArmed) return false;
    if (_showControls) return true; // en controles siempre si estamos en zona
    return _showSkipIntro && !_skipIntroAutoHidden; // sin controles: solo 10s iniciales
  }

  /// Outro y "siguiente capítulo" son el MISMO botón (10s auto-hide sin controles).
  bool get _outroBtnVisible {
    if (_showProgressOnly || _showEpisodesPanel) return false;
    if (!_inOutroZone || !_outroArmed) return false;
    if (_showControls) return true;
    return _showSkipOutro && !_skipOutroAutoHidden;
  }

  /// Progreso 1→0 de la barra de auto-hide (10s).
  double get _skipIntroHideProgress =>
      (_skipIntroCountdown / 10.0).clamp(0.0, 1.0);
  double get _skipOutroHideProgress =>
      (_skipOutroCountdown / 10.0).clamp(0.0, 1.0);

  void _updateSkipButtons() {
    if (!_playing && _position.inMilliseconds < 500) return;
    final inIntro = _inIntroZone;
    final inOutro = _inOutroZone;

    if (inIntro && !_introArmed) {
      _introArmed = true;
      _skipIntroAutoHidden = false;
      _skipIntroCountdown = 10;
      setState(() => _showSkipIntro = true);
      _focusSkipIfVisible();
      _skipIntroTimer?.cancel();
      _skipIntroTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_skipIntroCountdown <= 1) {
          t.cancel();
          // Auto-ocultar: solo vuelve con controles
          _releaseSkipFocus(_skipIntroFocus);
          setState(() {
            _skipIntroAutoHidden = true;
            _showSkipIntro = false;
          });
        } else {
          setState(() => _skipIntroCountdown--);
        }
      });
    } else if (!inIntro) {
      if (_showSkipIntro || _introArmed || _skipIntroAutoHidden) {
        _skipIntroTimer?.cancel();
        _releaseSkipFocus(_skipIntroFocus);
        if (mounted) {
          setState(() {
            _showSkipIntro = false;
            _introArmed = false;
            _skipIntroAutoHidden = false;
          });
        }
      }
    }

    if (inOutro && !_outroArmed) {
      _outroArmed = true;
      _skipOutroAutoHidden = false;
      _skipOutroCountdown = 10;
      setState(() => _showSkipOutro = true);
      _focusSkipIfVisible();
      _skipOutroTimer?.cancel();
      _skipOutroTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_skipOutroCountdown <= 1) {
          t.cancel();
          _releaseSkipFocus(_skipOutroFocus);
          setState(() {
            _skipOutroAutoHidden = true;
            _showSkipOutro = false;
          });
        } else {
          setState(() => _skipOutroCountdown--);
        }
      });
    } else if (!inOutro) {
      if (_showSkipOutro || _outroArmed || _skipOutroAutoHidden) {
        _skipOutroTimer?.cancel();
        _releaseSkipFocus(_skipOutroFocus);
        if (mounted) {
          setState(() {
            _showSkipOutro = false;
            _outroArmed = false;
            _skipOutroAutoHidden = false;
          });
        }
      }
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
    _releaseSkipFocus(_skipIntroFocus);
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
    _releaseSkipFocus(_skipOutroFocus);
    _releaseSkipFocus(_skipNextFocus);
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


  /// Lee historial en cache de ESTE contenido/episodio y devuelve positionMs.
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
      // No reanudar si ya estaba casi terminado (>= 95%)
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
          // Preferir la elección guardada; si no hay, usar el primero del repo
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
        // TV: mantener controles ocultos al iniciar
        if (widget.isTv) _showControls = false;
      });
      if (!widget.isTv) _scheduleHide();
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
    final wasPlaying = _playing;
    // Forzar rebuild cuando HLS publica el tamaño (antes solo había audio)
    setState(() {
      if (!_isDragging) _position = v.position;
      _duration = v.duration;
      _onPlaybackProgress();
      _playing = v.isPlaying;
      _buffering = v.isBuffering;
    });
    if (wasPlaying != v.isPlaying) {
      _onPlayingChanged(v.isPlaying);
    }
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
      if (mounted) {
        setState(() => _playing = v);
        _onPlayingChanged(v);
      }
    }));
    _mkSubs.add(player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _mkSubs.add(player.stream.position.listen((v) {
      if (mounted && !_isDragging) {
        setState(() => _position = v);
        _onPlaybackProgress();
        // Si el TS vuelve solo al inicio tras reanudar, forzar de nuevo.
        if (_resumeTargetMs != null &&
            !_resumeConfirmed &&
            v.inMilliseconds < 2500 &&
            _resumeTargetMs! > 3000) {
          unawaited(_applyMediaKitResume(player));
        }
      }
    }));
    _mkSubs.add(player.stream.duration.listen((v) {
      if (mounted) setState(() => _duration = v);
      if (v.inMilliseconds > 2000 &&
          _resumeTargetMs != null &&
          !_resumeConfirmed) {
        unawaited(_applyMediaKitResume(player));
      }
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
      // Restaurar preferencia de audio/subtítulo guardada
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
        _resumeTargetMs = startMs;
        _resumeConfirmed = false;
        // Esperar a que media_kit tenga duración real (si no, el seek se pierde al analizar el TS).
        for (var i = 0; i < 40; i++) {
          if (!mounted || _mk != player) break;
          if (player.state.duration.inMilliseconds > 2000) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await _applyMediaKitResume(player, force: true);
        // Reintentos: el demuxer TS a menudo vuelve a 0 tras el primer seek.
        for (final delayMs in [500, 1200, 2500, 4500]) {
          Future<void>.delayed(Duration(milliseconds: delayMs), () {
            if (!mounted || _mk != player) return;
            unawaited(_applyMediaKitResume(player));
          });
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

  /// media_kit + TS: el seek de historial a menudo se pierde cuando termina
  /// el análisis del demuxer. Reaplica hasta confirmar posición cercana al target.
  Future<void> _applyMediaKitResume(Player player, {bool force = false}) async {
    final target = _resumeTargetMs;
    if (target == null || target < 1500) return;
    if (_resumeConfirmed && !force) return;
    if (!mounted || _mk != player) return;
    try {
      final pos = player.state.position.inMilliseconds;
      final dur = player.state.duration.inMilliseconds;
      if (dur > 0 && target >= dur - 1000) {
        // Casi al final → no forzar
        _resumeConfirmed = true;
        _resumeTargetMs = null;
        return;
      }
      // Ya estamos cerca del punto de historial
      if (!force && (pos - target).abs() < 2500) {
        _resumeConfirmed = true;
        _resumeTargetMs = null;
        if (mounted) setState(() => _position = Duration(milliseconds: pos));
        return;
      }
      // Solo re-seek si seguimos al inicio o muy lejos del target
      if (force || pos < 3000 || (pos - target).abs() > 4000) {
        debugPrint('[Player] mk resume seek → ${target}ms (from ${pos}ms)');
        await player.seek(Duration(milliseconds: target));
        if (mounted) {
          setState(() => _position = Duration(milliseconds: target));
        }
        // Comprobar un poco después
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (!mounted || _mk != player || _resumeTargetMs == null) return;
          final p = player.state.position.inMilliseconds;
          if ((p - target).abs() < 3000) {
            _resumeConfirmed = true;
            _resumeTargetMs = null;
          }
        });
      }
    } catch (e) {
      debugPrint('[Player] mk resume seek error: $e');
    }
  }

  Future<void> _switchServer(int index) async {
    if (index < 0 || index >= _servers.length) return;
    final pos = _position.inMilliseconds > 0
        ? _position.inMilliseconds
        : widget.startPositionMs;
    // No reaplicar historial de apertura al cambiar de servidor
    _resumeTargetMs = null;
    _resumeConfirmed = true;
    setState(() => _serverIndex = index);
    final s = _servers[index];
    _applySegmentsFromServer(s);
    _loadExternalSubs(s);
    await _openUrl(s.url, s.headers, isHlsFlag: s.isHls);
    if (pos > 2000) {
      try {
        if (_useMediaKit && _mk != null) {
          _resumeTargetMs = pos;
          _resumeConfirmed = false;
          await _applyMediaKitResume(_mk!, force: true);
          for (final delayMs in [600, 1500, 3000]) {
            Future<void>.delayed(Duration(milliseconds: delayMs), () {
              if (!mounted || _mk == null) return;
              unawaited(_applyMediaKitResume(_mk!));
            });
          }
        } else {
          await _vp?.seekTo(Duration(milliseconds: pos));
        }
      } catch (_) {}
    }
  }

  Future<void> _togglePlay() async {
    bool nowPlaying = _playing;
    if (_useMediaKit) {
      final p = _mk;
      if (p == null) return;
      if (p.state.playing) {
        await p.pause();
        nowPlaying = false;
        _onPlayingChanged(false);
      } else {
        await p.play();
        nowPlaying = true;
        _onPlayingChanged(true);
      }
    } else {
      final c = _vp;
      if (c == null) return;
      if (c.value.isPlaying) {
        await c.pause();
        nowPlaying = false;
        _onPlayingChanged(false);
      } else {
        await c.play();
        nowPlaying = true;
        _onPlayingChanged(true);
      }
    }
    if (widget.isTv) {
      // En TV: al pausar se muestran controles con foco en play
      if (!nowPlaying) {
        _showTvControls(focusPlay: true);
      }
    } else {
      _scheduleHide();
    }
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
    if (!_showProgressOnly) {
      _scheduleHide();
    }
  }

  /// Scrub visual con aceleración al mantener ←/→.
  /// NO hace seek inmediato: solo mueve el puntero. El seek real se hace
  /// cuando el usuario deja de pulsar (timer de commit).
  void _scrubByAccelerated(int direction) {
    final now = DateTime.now();
    if (_seekHoldStartedAt == null ||
        now.difference(_seekHoldStartedAt!) > const Duration(milliseconds: 600)) {
      _seekHoldCount = 0;
      _seekHoldStartedAt = now;
      _scrubTargetMs = _position.inMilliseconds;
    }
    _seekHoldCount++;
    final step = _seekHoldCount <= 2
        ? 5
        : (_seekHoldCount <= 5
            ? 10
            : (_seekHoldCount <= 12 ? 20 : 30));
    final secs = direction < 0 ? -step : step;
    final durMs = _duration.inMilliseconds;
    final base = _scrubTargetMs ?? _position.inMilliseconds;
    var next = base + (secs * 1000);
    if (next < 0) next = 0;
    if (durMs > 0 && next > durMs) next = durMs;
    _scrubTargetMs = next;

    setState(() {
      _position = Duration(milliseconds: next);
      _isDragging = true;
      _showSeekHud = true;
      _seekHudSeconds = secs;
    });
    _seekHudTimer?.cancel();
    _seekHudTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showSeekHud = false);
    });

    // Confirmar seek solo al soltar (sin teclas nuevas ~450ms)
    _scrubCommitTimer?.cancel();
    _scrubCommitTimer = Timer(const Duration(milliseconds: 450), () {
      unawaited(_commitScrub());
    });

    _seekHoldResetTimer?.cancel();
    _seekHoldResetTimer = Timer(const Duration(milliseconds: 700), () {
      _seekHoldCount = 0;
      _seekHoldStartedAt = null;
    });
  }

  Future<void> _commitScrub() async {
    final target = _scrubTargetMs;
    _scrubTargetMs = null;
    if (target == null) {
      if (mounted) setState(() => _isDragging = false);
      return;
    }
    final d = Duration(milliseconds: target);
    try {
      if (_useMediaKit) {
        await _mk?.seek(d);
      } else {
        await _vp?.seekTo(d);
      }
    } catch (e) {
      debugPrint('[Player] commitScrub: $e');
    }
    if (mounted) {
      setState(() {
        _position = d;
        _isDragging = false;
      });
    }
  }

  /// Seek inmediato (doble toque móvil, etc.).
  Future<void> _seekByAccelerated(int direction) async {
    final now = DateTime.now();
    if (_seekHoldStartedAt == null ||
        now.difference(_seekHoldStartedAt!) > const Duration(milliseconds: 450)) {
      _seekHoldCount = 0;
      _seekHoldStartedAt = now;
    }
    _seekHoldCount++;
    final step = _seekHoldCount <= 3
        ? 10
        : (_seekHoldCount <= 8 ? 20 : 30);
    final secs = direction < 0 ? -step : step;
    await _seekBy(secs);
    setState(() {
      _showSeekHud = true;
      _seekHudSeconds = secs;
    });
    _seekHudTimer?.cancel();
    _seekHudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showSeekHud = false);
    });
    _seekHoldResetTimer?.cancel();
    _seekHoldResetTimer = Timer(const Duration(milliseconds: 400), () {
      _seekHoldCount = 0;
      _seekHoldStartedAt = null;
    });
  }

  /// Muestra solo la barra de progreso y hace scrub visual.
  /// El seek real ocurre al soltar (commit del scrub).
  void _showProgressOnlyAndSeek(int direction) {
    _progressOnlyTimer?.cancel();
    if (!_showProgressOnly || !_showControls) {
      setState(() {
        _showProgressOnly = true;
        _showControls = true;
        _showEpisodesPanel = false;
        _showServers = false;
        _showTracks = false;
        _showQualities = false;
        _showSubStyle = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _progressFocus.requestFocus();
      });
    }
    _scrubByAccelerated(direction);
    _progressOnlyTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      unawaited(_commitScrub());
      setState(() {
        _showProgressOnly = false;
        if (widget.isTv) {
          _showControls = false;
        }
      });
      if (widget.isTv && mounted) {
        _rootFocus.requestFocus();
        _focusSkipIfVisible();
      }
    });
  }

  void _dismissProgressOnly() {
    _progressOnlyTimer?.cancel();
    if (_showProgressOnly) {
      setState(() => _showProgressOnly = false);
    }
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
    setState(() {
      final values = _VideoFitMode.values;
      _fitMode = values[(_fitMode.index + 1) % values.length];
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
    // En TV los controles NO se ocultan solos; solo con back / OK.
    if (widget.isTv) {
      _hideTimer?.cancel();
      if (!_showControls) setState(() => _showControls = true);
      return;
    }
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

  void _onPlayingChanged(bool playing) {
    if (playing) {
      WakelockPlus.enable();
    }
    if (!widget.isTv) return;
    // Banner idle propio (1 min en pausa). WakelockPlus evita el protector nativo de Android TV.
    _idleTimer?.cancel();
    if (playing) {
      _pausedAt = null;
      if (_showIdleScreen && mounted) {
        setState(() => _showIdleScreen = false);
      }
    } else {
      _pausedAt = DateTime.now();
      _idleTimer = Timer(const Duration(minutes: 1), () {
        if (!mounted) return;
        if (!_playing) {
          setState(() {
            _showIdleScreen = true;
            _showControls = false;
            _showServers = false;
            _showTracks = false;
            _showQualities = false;
            _showSubStyle = false;
          });
        }
      });
    }
  }

  void _dismissIdleScreen() {
    if (!_showIdleScreen) return;
    setState(() => _showIdleScreen = false);
  }

  void _showTvControls({bool focusPlay = false}) {
    _dismissIdleScreen();
    _progressOnlyTimer?.cancel();
    setState(() {
      _showControls = true;
      _showProgressOnly = false;
      _awaitingExitConfirm = false;
    });
    if (focusPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playFocus.requestFocus();
      });
    }
  }

  void _hideTvControls() {
    _progressOnlyTimer?.cancel();
    setState(() {
      _showControls = false;
      _showProgressOnly = false;
      _showServers = false;
      _showTracks = false;
      _showQualities = false;
      _showSubStyle = false;
      _showEpisodesPanel = false;
      _tvFocusRow = 2;
      _awaitingExitConfirm = false;
    });
    _rootFocus.requestFocus();
    _focusSkipIfVisible();
  }

  Future<void> _confirmExitTv() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return FocusScope(
          autofocus: true,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1A1F2A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              'Salir del reproductor',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
            content: const Text(
              '¿Quieres salir de la reproducción?',
              style: TextStyle(color: Colors.white70),
            ),
            actionsAlignment: MainAxisAlignment.end,
            actions: [
              _TvDialogButton(
                label: 'Cancelar',
                autofocus: true,
                primary: false,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              const SizedBox(width: 8),
              _TvDialogButton(
                label: 'Salir',
                autofocus: false,
                primary: true,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    setState(() => _awaitingExitConfirm = false);
    if (_playing) WakelockPlus.enable();
    if (ok == true) {
      _saveProgressNow();
      // PopScope tiene canPop:false; hay que autorizar el pop explícitamente.
      _forcePop = true;
      if (mounted) {
        Navigator.of(context).pop();
      }
    } else {
      _playFocus.requestFocus();
    }
  }

  /// Menú TV centrado con foco real (showDialog = nuevo FocusScope).
  Future<void> _showTvMenu({
    required String title,
    required List<_TvMenuEntry> entries,
  }) async {
    if (!mounted) return;
    _rootFocus.unfocus();
    _playFocus.unfocus();
    _progressFocus.unfocus();

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (ctx) {
        return FocusScope(
          autofocus: true,
          child: Center(
            child: Material(
              color: const Color(0xFF1A1F2A),
              borderRadius: BorderRadius.circular(16),
              elevation: 16,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 440,
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          if (e.isHeader) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                              child: Text(
                                e.label,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1,
                                ),
                              ),
                            );
                          }
                          return _TvMenuTile(
                            label: e.label,
                            subtitle: e.subtitle,
                            selected: e.selected,
                            autofocus: e.autofocus,
                            leading: e.leading,
                            onActivate: () {
                              Navigator.pop(ctx);
                              e.onSelect?.call();
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
        );
      },
    );

    if (mounted) {
      _playFocus.requestFocus();
    }
    if (mounted && _playing) WakelockPlus.enable();
  }

  Future<void> _openServersMenu() async {
    final langs = _availableLanguages;
    final indices = _filteredServerIndices;
    final entries = <_TvMenuEntry>[];
    if (_servers.isEmpty) {
      entries.add(const _TvMenuEntry(label: 'Sin servidores', isHeader: true));
    } else {
      for (var idx = 0; idx < indices.length; idx++) {
        final i = indices[idx];
        final s = _servers[i];
        final sel = i == _serverIndex;
        entries.add(_TvMenuEntry(
          label: s.name,
          subtitle: (s.language ?? s.quality ?? '').toString(),
          selected: sel,
          autofocus: idx == 0,
          onSelect: () => _switchServer(i),
        ));
      }
    }
    await _showTvMenu(
      title: langs.length > 1 ? 'Idioma / Servidor' : 'Servidores',
      entries: entries,
    );
  }

  bool get _isCurrentTs {
    final u = _current?.url ?? widget.url;
    return isTsUrl(u);
  }

  List<({String label, int index})> get _tsQualityOptions {
    final out = <({String label, int index})>[];
    final seen = <String>{};
    for (var i = 0; i < _servers.length; i++) {
      final s = _servers[i];
      if (!isTsUrl(s.url)) continue;
      var q = (s.quality ?? '').trim();
      if (q.isEmpty) {
        q = s.name.trim().isNotEmpty ? s.name.trim() : 'Calidad ${out.length + 1}';
      }
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

  Future<void> _openQualitiesMenu() async {
    // TS: listar calidades de servidores .ts
    if (_isCurrentTs && _tsQualityOptions.isNotEmpty) {
      final entries = <_TvMenuEntry>[
        for (var i = 0; i < _tsQualityOptions.length; i++)
          _TvMenuEntry(
            label: _tsQualityOptions[i].label,
            selected: _serverIndex == _tsQualityOptions[i].index,
            autofocus: i == 0 || _serverIndex == _tsQualityOptions[i].index,
            onSelect: () => _selectTsQuality(_tsQualityOptions[i].index),
          ),
      ];
      await _showTvMenu(title: 'Calidad TS', entries: entries);
      return;
    }

    final autoLabel = _hlsAutoActual != null && _hlsAutoActual!.isNotEmpty
        ? 'Automática ($_hlsAutoActual)'
        : 'Automática';
    final entries = <_TvMenuEntry>[
      _TvMenuEntry(
        label: autoLabel,
        selected: _hlsQualityLabel == 'Automática' ||
            _hlsQualityLabel.startsWith('Automática'),
        autofocus: true,
        onSelect: () => _selectHlsQuality('Automática', null),
      ),
      for (final q in _hlsQualities)
        _TvMenuEntry(
          label: q.label,
          selected: _hlsQualityLabel == q.label,
          onSelect: () => _selectHlsQuality(q.label, q.url),
        ),
    ];
    await _showTvMenu(title: 'Calidad HLS', entries: entries);
  }

  Future<void> _openTracksMenu() async {
    final entries = <_TvMenuEntry>[];
    var first = true;
    if (_audioTracks.isNotEmpty) {
      entries.add(const _TvMenuEntry(label: 'IDIOMA / AUDIO', isHeader: true));
      for (final t in _audioTracks) {
        entries.add(_TvMenuEntry(
          label: _trackLabel(t),
          selected: _selectedAudio?.id == t.id,
          autofocus: first,
          onSelect: () async {
            await _mk?.setAudioTrack(t);
            setState(() => _selectedAudio = t);
            unawaited(_persistTrackChoice(
              audioLang: t.language ?? t.title ?? t.id,
            ));
          },
        ));
        first = false;
      }
    }
    entries.add(const _TvMenuEntry(label: 'SUBTÍTULOS', isHeader: true));
    entries.add(_TvMenuEntry(
      label: 'Sin subtítulos',
      selected: _selectedSubtitle == null || _selectedSubtitle?.id == 'no',
      autofocus: first,
      onSelect: () async {
        await _mk?.setSubtitleTrack(SubtitleTrack.no());
        setState(() => _selectedSubtitle = SubtitleTrack.no());
        await _clearExternalSubtitle();
        unawaited(_persistTrackChoice(subChoice: 'off'));
      },
    ));
    first = false;
    for (final t in _subtitleTracks) {
      entries.add(_TvMenuEntry(
        label: _trackLabel(t),
        subtitle: 'Embebido',
        selected: _selectedSubtitle?.id == t.id,
        onSelect: () async {
          await _mk?.setSubtitleTrack(t);
          setState(() => _selectedSubtitle = t);
          unawaited(_persistTrackChoice(subChoice: 'embedded:${t.id}'));
        },
      ));
    }
    if (_externalSubs.isNotEmpty) {
      entries.add(const _TvMenuEntry(label: 'DEL REPOSITORIO', isHeader: true));
      for (final sub in _externalSubs) {
        entries.add(_TvMenuEntry(
          label: sub.label,
          subtitle: sub.lang.toUpperCase(),
          selected: _activeExternalSub?.url == sub.url && _subsEnabled,
          onSelect: () async {
            await _applyExternalSubtitle(sub);
            unawaited(_persistTrackChoice(subChoice: 'external:${sub.url}'));
          },
        ));
      }
    }
    await _showTvMenu(title: 'Audio / Subtítulos', entries: entries);
  }


  void _startProgressSaver() {
    _progressTimer?.cancel();
    if (widget.repoId == null || widget.contentId == null) return;
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _saveProgressNow();
    });
  }

  /// Clave de historial "continuar viendo" (SharedPreferences).
  String? get _historialCacheKey {
    final c = widget.contentId;
    if (c == null || c.isEmpty) return null;
    final r = widget.repoId ?? '';
    // Historial independiente por episodio (no por serie completa)
    final se = widget.season;
    final ep = widget.episode;
    if (se != null && ep != null) {
      return 'continue_watch_${r}_${c}_s${se}_e$ep';
    }
    return 'continue_watch_${r}_$c';
  }

  static const String _continueIndexKey = 'continue_watching_index';

  /// Guarda progreso + metadatos + lista de capítulos para reabrir desde historial
  /// sin pasar por la ficha de contenido.
  void _saveProgressNow() {
    if (widget.repoId == null || widget.contentId == null) return;
    if (!mounted) return;

    final posMs = _position.inMilliseconds;
    final durMs = _duration.inMilliseconds;
    final list = _effectiveEpisodeList;

    // 1) LibraryService (si existe en el árbol)
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

    // 2) SharedPreferences: historial completo para "continuar viendo"
    unawaited(_saveHistorialToPrefs(
      positionMs: posMs,
      durationMs: durMs,
      episodeList: list,
    ));
  }

  /// Igual que [_saveProgressNow] pero espera a SharedPreferences (para cambio de capítulo).
  Future<void> _saveProgressNowAsync() async {
    if (widget.repoId == null || widget.contentId == null) return;
    final posMs = _position.inMilliseconds;
    final durMs = _duration.inMilliseconds;
    final list = _effectiveEpisodeList;

    try {
      if (mounted) {
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
      }
    } catch (_) {}

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

      // También refrescar cache de lista de episodios
      final listKey = _episodeCacheKey;
      if (listKey != null && episodeList.isNotEmpty) {
        _episodeListCache[listKey] = List<Map<String, dynamic>>.from(episodeList);
        await prefs.setString(listKey, jsonEncode(episodeList));
      }

      // Normalizar episodeList: título, temporada, número de capítulo en cada ítem.
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
        // Identificador del player que generó este historial
        'playerId': _PlayerPageState.playerId,
        'player': _PlayerPageState.playerId,
        'repoId': widget.repoId,
        'contentId': widget.contentId,
        'title': widget.title,
        'poster': widget.poster,
        'backdrop': widget.backdrop,
        'logo': widget.logo,
        'type': widget.contentType,
        'contentType': widget.contentType,
        // Capítulo actual (series)
        'season': widget.season,
        'episode': widget.episode,
        'episodeTitle': widget.episodeTitle,
        'temporada': widget.season,
        'episodio': widget.episode,
        // Progreso: ms + segundo exacto donde se quedó
        'positionMs': positionMs,
        'durationMs': durationMs,
        'segundo': (positionMs / 1000).round(),
        'positionSec': (positionMs / 1000).round(),
        'duration': (durationMs / 1000).round(),
        'durationSec': (durationMs / 1000).round(),
        // Playlist completa (título / temporada / capítulo por ítem)
        'episodeList': normalizedEpisodes,
        // Siguiente (si se conoce)
        'nextSeason': widget.nextSeason,
        'nextEpisode': widget.nextEpisode,
        'nextEpisodeId': widget.nextEpisodeId,
        'nextEpisodeTitle': widget.nextEpisodeTitle,
        'updatedAt': DateTime.now().toIso8601String(),
        'timestamp': DateTime.now().toIso8601String(),
      };

      await prefs.setString(key, jsonEncode(payload));

      // Alias a nivel de contenido (Home busca por repo|contentId)
      if (widget.season != null && widget.episode != null) {
        final seriesKey =
            'continue_watch_${widget.repoId}_${widget.contentId}';
        if (seriesKey != key) {
          await prefs.setString(seriesKey, jsonEncode(payload));
        }
      }

      // Índice ordenado por más reciente (para home / continuar viendo)
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
      // Limitar tamaño del historial
      while (index.length > 80) {
        final removed = index.removeLast();
        await prefs.remove(removed);
      }
      await prefs.setStringList(_continueIndexKey, index);
    } catch (e) {
      debugPrint('[Player] saveHistorial prefs: $e');
    }
  }

  /// Lee un item de "continuar viendo" desde SharedPreferences.
  static Future<Map<String, dynamic>?> loadHistorialEntry({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Historial por capítulo: cada episodio es independiente.
      if (season != null && episode != null) {
        final epKey =
            'continue_watch_${repoId}_${contentId}_s${season}_e$episode';
        final raw = prefs.getString(epKey);
        if (raw == null || raw.isEmpty) return null;
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        return null;
      }
      // Película / sin episodio → clave de contenido
      final seriesKey = 'continue_watch_${repoId}_$contentId';
      final raw = prefs.getString(seriesKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// Lista completa de "continuar viendo" (más reciente primero).
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
    // Precarga silenciosa de servidores del siguiente capítulo (no se usa al pulsar)
    if (ratio >= 0.80) {
      _preloadNextEpisode();
    }
    // Al 90% marcar como visto pero seguir guardando historial
    if (ratio >= 0.90) {
      unawaited(_markAsWatchedIfNeeded());
    }
    // Outro / siguiente capítulo: solo el botón (zona outro del repo o ≥90%).
    // NO auto-avanzar ni auto-pulsar: el usuario debe activar el botón a mano.
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
    // Siempre persistir historial aunque esté marcado visto
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

    // Por defecto NO usar precarga: el nuevo player carga sus servidores.
    List<StreamServer> servers = const [];
    if (usePreload) {
      servers = List.of(_nextServers);
    }
    if (!mounted) return;

    // Siguiente-del-siguiente usando la lista completa de TODAS las temporadas
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
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (!mounted) return;

    final url = servers.isNotEmpty ? servers.first.url : '';
    final hdrs = servers.isNotEmpty && servers.first.headers.isNotEmpty
        ? servers.first.headers
        : widget.headers;

    // Guardar progreso del capítulo actual ANTES de saltar (await para no perder historial).
    await _saveProgressNowAsync();
    if (!mounted) return;

    _navigatingToNextPlayer = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PlayerPage(
          title: widget.title,
          url: url,
          repoId: widget.repoId,
          // Siempre el id del título (getStreams usa season/episode)
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
          episodeList: _effectiveEpisodeList.isNotEmpty ? _effectiveEpisodeList : widget.episodeList,
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

  /// Agrupa episodeList por temporada: {seasonNum: [episodes...]}.
  Map<int, List<Map<String, dynamic>>> get _episodesBySeason {
    final map = <int, List<Map<String, dynamic>>>{};
    for (final e in _effectiveEpisodeList) {
      final se = (e['season'] as num?)?.toInt() ?? 1;
      map.putIfAbsent(se, () => []).add(e);
    }
    return map;
  }

  List<int> get _seasonNumbers {
    final keys = _episodesBySeason.keys.toList()..sort();
    return keys;
  }

  void _rebuildSeasonFocusNodes() {
    for (final n in _seasonFocusNodes) {
      n.dispose();
    }
    _seasonFocusNodes
      ..clear()
      ..addAll(List.generate(_seasonNumbers.length, (_) => FocusNode()));
  }

  void _rebuildEpisodeFocusNodes(int seasonNum) {
    for (final n in _episodeFocusNodes) {
      n.dispose();
    }
    final eps = _episodesBySeason[seasonNum] ?? const [];
    _episodeFocusNodes
      ..clear()
      ..addAll(List.generate(eps.length, (_) => FocusNode()));
  }

  void _openEpisodesPanel() {
    if (_effectiveEpisodeList.isEmpty) return;
    final seasons = _seasonNumbers;
    if (seasons.isEmpty) return;
    // Orden natural de la lista (no reordenar ni poner el actual al inicio).
    // Solo se mueve el FOCO y el scroll hasta el capítulo en reproducción.
    var se = widget.season ?? seasons.first;
    if (!seasons.contains(se)) se = seasons.first;
    _panelSeason = se;
    _rebuildSeasonFocusNodes();
    _rebuildEpisodeFocusNodes(se);

    final eps = _episodesBySeason[se] ?? const [];
    var epIdx = 0;
    if (widget.episode != null) {
      final j = eps.indexWhere((e) {
        final n = (e['episode'] as num?)?.toInt() ??
            (e['number'] as num?)?.toInt();
        return n == widget.episode;
      });
      if (j >= 0) epIdx = j;
    }

    setState(() {
      _showEpisodesPanel = true;
      _showControls = true;
      _tvFocusRow = 4;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_episodeFocusNodes.isEmpty) return;
      final idx = epIdx.clamp(0, _episodeFocusNodes.length - 1);
      _episodeFocusNodes[idx].requestFocus();
      // Centrar el capítulo actual en el carrusel sin alterar el orden.
      // Así se puede navegar a anteriores (←) y posteriores (→).
      if (_episodeScrollCtrl.hasClients) {
        const cardApprox = 148.0;
        final viewport = _episodeScrollCtrl.position.viewportDimension;
        final target = (idx * cardApprox) - (viewport / 2) + (cardApprox / 2);
        final offset =
            target.clamp(0.0, _episodeScrollCtrl.position.maxScrollExtent);
        _episodeScrollCtrl.animateTo(
          offset,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Lleva el foco y la vista al PRIMER episodio de la temporada seleccionada.
  void _focusFirstEpisode() {
    if (_episodeScrollCtrl.hasClients) {
      _episodeScrollCtrl.jumpTo(0);
    }
    setState(() => _tvFocusRow = 4);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _episodeFocusNodes.isEmpty) return;
      _episodeFocusNodes.first.requestFocus();
      if (_episodeScrollCtrl.hasClients) {
        _episodeScrollCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _selectPanelSeason(int seasonNum) {
    _panelSeason = seasonNum;
    _rebuildEpisodeFocusNodes(seasonNum);
    // Al cambiar de temporada la lista de episodios vuelve al inicio.
    if (_episodeScrollCtrl.hasClients) {
      _episodeScrollCtrl.jumpTo(0);
    }
    setState(() => _tvFocusRow = 3);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final seasons = _seasonNumbers;
      final si = seasons.indexOf(seasonNum);
      if (si >= 0 && si < _seasonFocusNodes.length) {
        _seasonFocusNodes[si].requestFocus();
      }
    });
  }

  Future<void> _playEpisodeFromList(Map<String, dynamic> e) async {
    final se = (e['season'] as num?)?.toInt();
    final ep = (e['episode'] as num?)?.toInt() ?? (e['number'] as num?)?.toInt();
    final id = e['id']?.toString();
    final title = e['title']?.toString() ?? 'E$ep';
    if (se == null || ep == null) return;

    // Calcular next
    int? nSe, nEp;
    String? nId, nTitle;
    final list = _effectiveEpisodeList;
    final cur = list.indexWhere((x) {
      final xs = (x['season'] as num?)?.toInt();
      final xe =
          (x['episode'] as num?)?.toInt() ?? (x['number'] as num?)?.toInt();
      return xs == se && xe == ep;
    });
    if (cur >= 0 && cur + 1 < list.length) {
      final n = list[cur + 1];
      nSe = (n['season'] as num?)?.toInt();
      nEp = (n['episode'] as num?)?.toInt() ?? (n['number'] as num?)?.toInt();
      nId = n['id']?.toString();
      nTitle = n['title']?.toString();
    }

    await _saveProgressNowAsync();
    if (!mounted) return;
    _navigatingToNextPlayer = true;
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
          season: se,
          episode: ep,
          episodeTitle: title,
          nextSeason: nSe,
          nextEpisode: nEp,
          nextEpisodeId: nId,
          nextEpisodeTitle: nTitle,
          episodeList: _effectiveEpisodeList.isNotEmpty ? _effectiveEpisodeList : widget.episodeList,
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

  void _handleSystemBack() {
    if (!widget.isTv) {
      unawaited(_saveProgressNowAsync());
      _forcePop = true;
      Navigator.of(context).pop();
      return;
    }
    if (_showEpisodesPanel) {
      setState(() {
        _showEpisodesPanel = false;
        _tvFocusRow = 2;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playFocus.requestFocus();
      });
      return;
    }
    final panelOpen =
        _showServers || _showTracks || _showQualities || _showSubStyle;
    if (panelOpen) {
      setState(() {
        _showServers = false;
        _showTracks = false;
        _showQualities = false;
        _showSubStyle = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playFocus.requestFocus();
      });
      return;
    }
    if (_showControls) {
      _hideTvControls();
      return;
    }
    _confirmExitTv();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _forcePop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_forcePop) return;
        _handleSystemBack();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: (node, event) {
          final isDown = event is KeyDownEvent;
          final isRepeat = event is KeyRepeatEvent;
          if (!isDown && !isRepeat) return KeyEventResult.ignored;
          final key = event.logicalKey;

          // —— TV: manejo específico ——
          if (widget.isTv) {
            final panelOpen = _showServers ||
                _showTracks ||
                _showQualities ||
                _showSubStyle;

            // Menú abierto: solo gestionar Back aquí; el resto lo maneja el menú
            if (panelOpen) {
              if (isDown &&
                  (key == LogicalKeyboardKey.escape ||
                      key == LogicalKeyboardKey.goBack ||
                      key == LogicalKeyboardKey.browserBack)) {
                setState(() {
                  _showServers = false;
                  _showTracks = false;
                  _showQualities = false;
                  _showSubStyle = false;
                });
                // Devolver foco a Play
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _playFocus.requestFocus();
                });
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            }

            // Cualquier tecla cierra la pantalla de espera
            if (_showIdleScreen) {
              if (!isDown) return KeyEventResult.ignored;
              _dismissIdleScreen();
              _showTvControls(focusPlay: true);
              return KeyEventResult.handled;
            }

            // Back / Escape
            if (isDown &&
                (key == LogicalKeyboardKey.escape ||
                    key == LogicalKeyboardKey.goBack ||
                    key == LogicalKeyboardKey.browserBack)) {
              if (_showProgressOnly) {
                _dismissProgressOnly();
                setState(() => _showControls = false);
                _rootFocus.requestFocus();
                _focusSkipIfVisible();
                return KeyEventResult.handled;
              }
              if (_showServers ||
                  _showTracks ||
                  _showQualities ||
                  _showSubStyle) {
                setState(() {
                  _showServers = false;
                  _showTracks = false;
                  _showQualities = false;
                  _showSubStyle = false;
                });
                return KeyEventResult.handled;
              }
              if (_showControls) {
                _hideTvControls();
                return KeyEventResult.handled;
              }
              // Controles ocultos → confirmación de salida
              _confirmExitTv();
              return KeyEventResult.handled;
            }

            // OK / Select / Enter / Space
            if (isDown &&
                (key == LogicalKeyboardKey.select ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.space ||
                    key == LogicalKeyboardKey.mediaPlayPause)) {
              if (_showProgressOnly) {
                _dismissProgressOnly();
                setState(() => _showControls = false);
                _rootFocus.requestFocus();
                _focusSkipIfVisible();
                return KeyEventResult.handled;
              }
              if (_showControls &&
                  !_showServers &&
                  !_showTracks &&
                  !_showQualities &&
                  !_showSubStyle) {
                // Con controles visibles y sin panel: ocultar
                _hideTvControls();
                return KeyEventResult.handled;
              }
              if (!_showControls) {
                // Sin controles: pausar y mostrar controles con foco en play
                if (_playing) {
                  _togglePlay();
                } else {
                  _showTvControls(focusPlay: true);
                }
                return KeyEventResult.handled;
              }
              // Si hay panel abierto, dejar que el foco interno maneje
              return KeyEventResult.ignored;
            }

            // Flecha arriba → controles / barra / botones omitir intro·outro
            if (isDown && key == LogicalKeyboardKey.arrowUp) {
              if (_showProgressOnly) {
                _dismissProgressOnly();
                setState(() => _showControls = false);
                _rootFocus.requestFocus();
                _focusSkipIfVisible();
                return KeyEventResult.handled;
              }
              if (!_showControls) {
                _showTvControls(focusPlay: false);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _progressFocus.requestFocus();
                });
              } else if (_progressFocus.hasFocus) {
                // Desde la barra: subir a omitir intro / outro·siguiente
                if (!_focusSkipFromControls()) {
                  // Sin botones flotantes → cerrar controles
                  _hideTvControls();
                }
              } else {
                // Desde botones de acción: ir a skip si está visible, si no a la barra
                if (!_focusSkipFromControls()) {
                  _progressFocus.requestFocus();
                }
              }
              return KeyEventResult.handled;
            }

            // Flecha abajo → controles / acciones / panel episodios
            if (isDown && key == LogicalKeyboardKey.arrowDown) {
              if (_showProgressOnly) {
                // Expandir a controles completos con foco en play
                _dismissProgressOnly();
                setState(() {
                  _showProgressOnly = false;
                  _showControls = true;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _playFocus.requestFocus();
                });
                return KeyEventResult.handled;
              }
              if (!_showControls) {
                _showTvControls(focusPlay: true);
                setState(() => _tvFocusRow = 2);
              } else if (_showEpisodesPanel && _tvFocusRow == 3) {
                // De temporadas → primer episodio de esa temporada
                _focusFirstEpisode();
              } else if (_showControls &&
                  !_showEpisodesPanel &&
                  _effectiveEpisodeList.isNotEmpty) {
                _openEpisodesPanel();
              } else {
                _playFocus.requestFocus();
              }
              return KeyEventResult.handled;
            }

            // Izquierda / derecha con controles ocultos: solo barra de progreso + seek acelerado.
            if ((!_showControls || _showProgressOnly) &&
                !_showServers &&
                !_showTracks &&
                !_showQualities &&
                !_showSubStyle &&
                !_showEpisodesPanel) {
              if (key == LogicalKeyboardKey.arrowLeft) {
                _showProgressOnlyAndSeek(-1);
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowRight) {
                _showProgressOnlyAndSeek(1);
                return KeyEventResult.handled;
              }
            }

            // Sin volumen en TV
            return KeyEventResult.ignored;
          }

          // —— Móvil / no-TV (comportamiento original) ——
          if (!isDown) return KeyEventResult.ignored;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            _togglePlay();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft) {
            unawaited(_seekByAccelerated(-1));
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            unawaited(_seekByAccelerated(1));
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
            Navigator.maybePop(context);
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
              if (_showServers || _showTracks) {
                setState(() {
                  _showServers = false;
                  _showTracks = false;
                });
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
            // Sin control de volumen por gesto en TV
            if (widget.isTv) return;
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
              // Subtítulos externos (overlay, funciona con video_player HLS)
              if (_overlaySubText.isNotEmpty && _subsEnabled)
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
                          child: _outlinedSubText(
                            _overlaySubText,
                            fontSize: _subFontSize,
                            color: _subColor,
                            bold: _subBold,
                            borderWidth: _subBorder,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_showVolumeHud) _volumeHud(),
              if (_showFitHud) _fitHud(),
              if (_showSeekHud) _seekHud(),
              if (_isSpeedBoost) _speedHud(),
              // Controles: appbar sale hacia ARRIBA, barra/herramientas hacia ABAJO
              // En modo solo-progreso no mostramos appbar ni botones.
              if (!_loading && !_loadingStreams && _error == null) ...[
                AnimatedOpacity(
                  opacity: (_showControls && !_showProgressOnly) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_showControls ||
                        _showProgressOnly ||
                        (_showServers ||
                            _showTracks ||
                            _showQualities ||
                            _showSubStyle),
                    child: ExcludeFocus(
                      excluding: _showProgressOnly ||
                          (_showServers ||
                              _showTracks ||
                              _showQualities ||
                              _showSubStyle),
                      child: AnimatedSlide(
                        offset: (_showControls && !_showProgressOnly)
                            ? Offset.zero
                            : const Offset(0, -0.15),
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: _controlsTop(),
                      ),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: IgnorePointer(
                    ignoring: !_showControls ||
                        (_showServers ||
                            _showTracks ||
                            _showQualities ||
                            _showSubStyle),
                    child: ExcludeFocus(
                      excluding: (!_showProgressOnly &&
                          (_showServers ||
                              _showTracks ||
                              _showQualities ||
                              _showSubStyle)),
                      child: AnimatedSlide(
                        offset: _showControls
                            ? Offset.zero
                            : const Offset(0, 0.18),
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: _controlsBottom(),
                      ),
                    ),
                  ),
                ),
                // Skip intro / outro·siguiente: 10s en pantalla, luego solo con controles.
                // Nunca encima de la vista de capítulos.
                if (!_showEpisodesPanel && _introBtnVisible)
                  Positioned(
                    right: 16,
                    bottom: _showControls ? 110 : 28,
                    child: _skipIntroBtn(),
                  ),
                if (!_showEpisodesPanel && _outroBtnVisible)
                  Positioned(
                    right: 16,
                    bottom: _showControls ? 110 : 28,
                    child: _skipOutroBtn(),
                  ),
              ],
              // Menús TV se abren con showDialog (foco real)
              if (!widget.isTv && _showServers) _serversPanel(),
              if (!widget.isTv && _showQualities) _qualitiesPanel(),
              // Sub style: dialog en _openSubStyleMenu
              if (!widget.isTv && _showTracks) _tracksPanel(),
              // Pantalla de espera TV (pausado > 1 min)
              if (widget.isTv && _showIdleScreen) _tvIdleScreen(),
            ],
          ), // Stack
        ), // GestureDetector
      ), // Focus
      ), // Scaffold
    ); // PopScope
  }

  /// Franja de temporadas + episodios integrada DENTRO de los controles
  /// (mismo patrón que la otra app: baja el foco, no flota encima).
  Widget _buildEpisodesStrip() {
    final seasons = _seasonNumbers;
    final eps = _episodesBySeason[_panelSeason] ?? const [];
    final hasImages = eps.any((e) {
      for (final k in ['still', 'poster', 'image', 'thumbnail', 'thumb']) {
        final v = e[k]?.toString() ?? '';
        if (v.startsWith('http')) return true;
      }
      return false;
    });
    final cardH = hasImages ? 88.0 : 56.0;
    final cardW = hasImages ? 156.0 : 132.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        // Tabs temporada
        SizedBox(
          height: 36,
          child: ListView.separated(
            controller: _seasonScrollCtrl,
            scrollDirection: Axis.horizontal,
            itemCount: seasons.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final se = seasons[i];
              final selected = se == _panelSeason;
              final node =
                  i < _seasonFocusNodes.length ? _seasonFocusNodes[i] : null;
              return Focus(
                focusNode: node,
                onFocusChange: (v) {
                  if (v) {
                    setState(() {});
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_seasonScrollCtrl.hasClients) return;
                      const chipApprox = 110.0;
                      final viewport =
                          _seasonScrollCtrl.position.viewportDimension;
                      final target =
                          (i * chipApprox) - (viewport / 2) + (chipApprox / 2);
                      final offset = target.clamp(
                        0.0,
                        _seasonScrollCtrl.position.maxScrollExtent,
                      );
                      _seasonScrollCtrl.animateTo(
                        offset,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                      );
                    });
                  }
                },
                onKeyEvent: (n, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  final seasons = _seasonNumbers;
                  final idx = seasons.indexOf(se);
                  if (key == LogicalKeyboardKey.select ||
                      key == LogicalKeyboardKey.enter) {
                    _selectPanelSeason(se);
                    _focusFirstEpisode();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowRight) {
                    if (idx >= 0 && idx + 1 < seasons.length) {
                      _seasonFocusNodes[idx + 1].requestFocus();
                      _selectPanelSeason(seasons[idx + 1]);
                    }
                    // sin más temporadas → mantener foco aquí
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowLeft) {
                    if (idx > 0) {
                      _seasonFocusNodes[idx - 1].requestFocus();
                      _selectPanelSeason(seasons[idx - 1]);
                    }
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowDown) {
                    _focusFirstEpisode();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowUp) {
                    setState(() {
                      _showEpisodesPanel = false;
                      _tvFocusRow = 2;
                    });
                    _playFocus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.escape ||
                      key == LogicalKeyboardKey.goBack ||
                      key == LogicalKeyboardKey.browserBack) {
                    setState(() {
                      _showEpisodesPanel = false;
                      _tvFocusRow = 2;
                    });
                    _playFocus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.handled;
                },
                child: Builder(
                  builder: (ctx) {
                    final hasFocus = Focus.of(ctx).hasFocus;
                    return GestureDetector(
                      onTap: () => _selectPanelSeason(se),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: hasFocus
                              ? Colors.white
                              : (selected
                                  ? Colors.white.withValues(alpha: 0.16)
                                  : Colors.white.withValues(alpha: 0.06)),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: hasFocus
                                ? const Color(0xFFE50914)
                                : (selected
                                    ? accent.withValues(alpha: 0.65)
                                    : Colors.white24),
                            width: hasFocus ? 2.5 : 1.2,
                          ),
                          boxShadow: hasFocus
                              ? [
                                  BoxShadow(
                                    color: const Color(0xFFE50914)
                                        .withValues(alpha: 0.4),
                                    blurRadius: 10,
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          'Temporada $se',
                          style: TextStyle(
                            color: hasFocus ? Colors.black : Colors.white,
                            fontWeight: selected || hasFocus
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // Episodios
        SizedBox(
          height: cardH,
          child: ListView.separated(
            controller: _episodeScrollCtrl,
            scrollDirection: Axis.horizontal,
            itemCount: eps.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final e = eps[i];
              final epNum = (e['episode'] as num?)?.toInt() ??
                  (e['number'] as num?)?.toInt() ??
                  (i + 1);
              final title = (e['title']?.toString() ?? '').trim();
              String? thumb;
              for (final k in ['still', 'poster', 'image', 'thumbnail', 'thumb']) {
                final v = e[k]?.toString() ?? '';
                if (v.startsWith('http')) {
                  thumb = v;
                  break;
                }
              }
              final isCurrent =
                  widget.season == _panelSeason && widget.episode == epNum;
              final node =
                  i < _episodeFocusNodes.length ? _episodeFocusNodes[i] : null;

              return Focus(
                focusNode: node,
                onFocusChange: (v) {
                  if (v) {
                    setState(() {});
                    // Auto-scroll horizontal para que el foco no se pierda fuera de vista.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_episodeScrollCtrl.hasClients) return;
                      final cardApprox = cardW + 8.0;
                      final viewport =
                          _episodeScrollCtrl.position.viewportDimension;
                      final target = (i * cardApprox) -
                          (viewport / 2) +
                          (cardApprox / 2);
                      final offset = target.clamp(
                        0.0,
                        _episodeScrollCtrl.position.maxScrollExtent,
                      );
                      _episodeScrollCtrl.animateTo(
                        offset,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                      );
                    });
                  }
                },
                onKeyEvent: (n, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.select ||
                      key == LogicalKeyboardKey.enter) {
                    _playEpisodeFromList(e);
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowRight) {
                    if (i + 1 < _episodeFocusNodes.length) {
                      _episodeFocusNodes[i + 1].requestFocus();
                    }
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowLeft) {
                    if (i > 0) {
                      _episodeFocusNodes[i - 1].requestFocus();
                    }
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowUp) {
                    setState(() => _tvFocusRow = 3);
                    final seasons = _seasonNumbers;
                    final si = seasons.indexOf(_panelSeason);
                    if (si >= 0 && si < _seasonFocusNodes.length) {
                      _seasonFocusNodes[si].requestFocus();
                    }
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.escape ||
                      key == LogicalKeyboardKey.goBack ||
                      key == LogicalKeyboardKey.browserBack) {
                    setState(() {
                      _showEpisodesPanel = false;
                      _tvFocusRow = 2;
                    });
                    _playFocus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.handled;
                },
                child: Builder(
                  builder: (ctx) {
                    final hasFocus = Focus.of(ctx).hasFocus;
                    return GestureDetector(
                      onTap: () => _playEpisodeFromList(e),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: cardW,
                        height: cardH,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: hasFocus
                                ? Colors.white
                                : (isCurrent ? accent : Colors.white12),
                            width: hasFocus ? 2.5 : (isCurrent ? 2 : 1),
                          ),
                          boxShadow: hasFocus
                              ? [
                                  BoxShadow(
                                    color: Colors.white.withValues(alpha: 0.35),
                                    blurRadius: 10,
                                    spreadRadius: 0.5,
                                  ),
                                ]
                              : null,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: (hasImages && thumb != null)
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedNetworkImage(
                                    imageUrl: thumb,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 320,
                                    errorWidget: (_, __, ___) =>
                                        Container(color: const Color(0xFF1A1A1A)),
                                  ),
                                  const DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Color(0xBB000000),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 7,
                                    right: 7,
                                    bottom: 5,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'E$epNum',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 12,
                                          ),
                                        ),
                                        if (title.isNotEmpty)
                                          Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white.withValues(alpha: 0.75),
                                              fontSize: 10,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.play_circle_fill_rounded,
                                      size: 20,
                                      color: accent,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            'E$epNum',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                            ),
                                          ),
                                          if (title.isNotEmpty)
                                            Text(
                                              title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white.withValues(alpha: 0.55),
                                                fontSize: 10,
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
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tvIdleScreen() {
    final art = widget.backdrop ?? widget.poster;
    final epParts = <String>[];
    if (widget.season != null && widget.episode != null) {
      epParts.add('T${widget.season} · E${widget.episode}');
    }
    final et = (widget.episodeTitle ?? '').trim();
    if (et.isNotEmpty) epParts.add(et);

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _dismissIdleScreen();
          _showTvControls(focusPlay: true);
        },
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
            // Gradiente esquina inferior izquierda → centro (negro → transparente)
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
            // Título + episodio
            Positioned(
              left: 48,
              bottom: 56,
              right: 48,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.logo != null && widget.logo!.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: widget.logo!,
                      height: 48,
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      errorWidget: (_, __, ___) => Text(
                        widget.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
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
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Pulsa cualquier botón para continuar',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
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
      // media_kit: usar aspect ratio forzado vía SizedBox + FittedBox
      return _buildAspectVideoSurface(
        child: Video(
          controller: _mkVideo!,
          controls: NoVideoControls,
          fill: Colors.black,
          fit: BoxFit.fill,
          subtitleViewConfiguration: _subtitleViewConfig(),
        ),
        // media_kit no expone size igual; original = contain nativo
        nativeAspect: null,
      );
    }

    final c = _vp;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }

    final sz = c.value.size;
    final hasSize = sz.width > 0 && sz.height > 0;
    if (!hasSize) {
      return ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(child: VideoPlayer(c)),
      );
    }

    return _buildAspectVideoSurface(
      child: VideoPlayer(c),
      nativeAspect: sz.width / sz.height,
      nativeWidth: sz.width,
      nativeHeight: sz.height,
    );
  }

  /// Superficie de vídeo con aspecto forzado (Original / 16:9 / 21:9 / …).
  Widget _buildAspectVideoSurface({
    required Widget child,
    double? nativeAspect,
    double? nativeWidth,
    double? nativeHeight,
  }) {
    final forced = _forcedAspectRatio;
    final targetAspect = forced ?? nativeAspect;

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;
          if (maxW <= 0 || maxH <= 0) {
            return const ColoredBox(color: Colors.black);
          }

          // Original sin tamaño nativo → llenar
          if (targetAspect == null) {
            return SizedBox.expand(child: child);
          }

          late final double frameW;
          late final double frameH;
          if (maxW / maxH > targetAspect) {
            frameH = maxH;
            frameW = frameH * targetAspect;
          } else {
            frameW = maxW;
            frameH = frameW / targetAspect;
          }

          final vw = nativeWidth ?? frameW;
          final vh = nativeHeight ?? frameH;

          return Center(
            child: SizedBox(
              width: frameW,
              height: frameH,
              child: FittedBox(
                fit: BoxFit.fill,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: vw,
                  height: vh,
                  child: child,
                ),
              ),
            ),
          );
        },
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
              onPressed: () => Navigator.maybePop(context),
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
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(_fitModeLabel,
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

  /// Botón de acción TV (estilo app TV): fondo blanco + icono negro al foco.
  Widget _tvActionBtn({
    FocusNode? focusNode,
    required IconData icon,
    required VoidCallback onActivate,
    double size = 40,
  }) {
    if (!widget.isTv) {
      return IconButton(
        onPressed: onActivate,
        icon: Icon(icon, color: Colors.white, size: 24),
      );
    }
    return Focus(
      focusNode: focusNode,
      canRequestFocus: true,
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          // Subir a intro/outro·siguiente si está visible; si no, a la barra
          if (!_focusSkipFromControls()) {
            _progressFocus.requestFocus();
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          if (_effectiveEpisodeList.isNotEmpty) {
            _openEpisodesPanel();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: onActivate,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hasFocus
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: hasFocus ? Colors.white : Colors.white24,
                  width: hasFocus ? 2.5 : 1.2,
                ),
                boxShadow: hasFocus
                    ? [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.45),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                icon,
                size: 22,
                color: hasFocus ? Colors.black : Colors.white,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Compat: wrappers antiguos que pasaban IconButton como child.
  Widget _tvFocusable({
    FocusNode? focusNode,
    required Widget child,
    VoidCallback? onActivate,
  }) {
    if (!widget.isTv) return child;
    return Focus(
      focusNode: focusNode,
      canRequestFocus: true,
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (onActivate != null &&
            (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space)) {
          onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          _progressFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: hasFocus
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: hasFocus ? Colors.white : Colors.white24,
                width: hasFocus ? 2.5 : 1.2,
              ),
              boxShadow: hasFocus
                  ? [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.4),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  foregroundColor: hasFocus ? Colors.black : Colors.white,
                ),
              ),
              child: ExcludeFocus(child: child),
            ),
          );
        },
      ),
    );
  }

  void _openPanel(void Function() open) {
    // Quitar foco de botones detrás antes de montar el menú
    _rootFocus.unfocus();
    _playFocus.unfocus();
    _progressFocus.unfocus();
    open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Prioridad: primer ListTile con autofocus dentro del FocusScope
      _panelFocus.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final scope = FocusScope.of(context);
        // Mover al primer hijo enfocable del menú
        scope.nextFocus();
      });
    });
  }


  /// Mueve el foco al botón flotante visible (intro o outro·siguiente).
  /// Devuelve true si había botón y se solicitó el foco.
  bool _focusSkipFromControls() {
    if (_showEpisodesPanel) return false;
    if (_introBtnVisible) {
      _skipIntroFocus.requestFocus();
      return true;
    }
    if (_outroBtnVisible) {
      _skipOutroFocus.requestFocus();
      return true;
    }
    return false;
  }

  /// Foco en el botón flotante (omitir intro / outro·siguiente) cuando aparece
  /// con los controles ocultos: así basta pulsar OK.
  void _focusSkipIfVisible() {
    if (!widget.isTv) return;
    void tryFocus() {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (_showControls || _showProgressOnly || _showIdleScreen) return;
      if (_showServers ||
          _showTracks ||
          _showQualities ||
          _showSubStyle ||
          _showEpisodesPanel) {
        return;
      }
      _focusSkipFromControls();
    }

    // Un frame para montar el widget + otro por si el setState aún no pintó.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      tryFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
    });
  }

  void _releaseSkipFocus(FocusNode node) {
    if (node.hasFocus && mounted) {
      _rootFocus.requestFocus();
    }
  }

  /// Miniatura del siguiente capítulo (si el repo la trae).
  String? get _nextEpisodeThumb {
    final ns = widget.nextSeason;
    final ne = widget.nextEpisode;
    if (ns == null || ne == null) return null;
    for (final e in _effectiveEpisodeList) {
      final se = (e['season'] as num?)?.toInt() ?? 1;
      final ep =
          (e['episode'] as num?)?.toInt() ?? (e['number'] as num?)?.toInt();
      if (se == ns && ep == ne) {
        for (final k in ['still', 'poster', 'image', 'thumbnail', 'thumb']) {
          final v = e[k]?.toString() ?? '';
          if (v.startsWith('http')) return v;
        }
        return null;
      }
    }
    return null;
  }

  /// Contenedor común de los botones flotantes (mismo estilo y mismo lugar).
  Widget _skipShell({
    required FocusNode focusNode,
    required VoidCallback onActivate,
    required double hideProgress,
    required bool showTimerBar,
    required Widget Function(bool hasFocus) content,
    double minWidth = 120,
    double maxWidth = 300,
  }) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          onActivate();
          return KeyEventResult.handled;
        }
        // Con controles visibles ↓ baja a la barra; con controles ocultos
        // el resto de teclas las maneja el root (mostrar controles, seek, back).
        if (key == LogicalKeyboardKey.arrowDown && _showControls) {
          _progressFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: onActivate,
            child: AnimatedScale(
              scale: hasFocus ? 1.04 : 1.0,
              alignment: Alignment.bottomRight,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                constraints:
                    BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: hasFocus ? Colors.white : const Color(0xE6101218),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: hasFocus
                        ? const Color(0xFFE50914)
                        : Colors.white.withValues(alpha: 0.28),
                    width: hasFocus ? 2.5 : 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: hasFocus
                          ? const Color(0xFFE50914).withValues(alpha: 0.45)
                          : Colors.black.withValues(alpha: 0.35),
                      blurRadius: hasFocus ? 14 : 8,
                      spreadRadius: hasFocus ? 1 : 0,
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    content(hasFocus),
                    if (showTimerBar)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: hideProgress,
                          minHeight: 2,
                          backgroundColor: hasFocus
                              ? Colors.black.withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.14),
                          valueColor: const AlwaysStoppedAnimation<Color>(accent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _skipChip({
    required FocusNode focusNode,
    required String label,
    required VoidCallback onActivate,
    required double hideProgress,
    required bool showTimerBar,
    IconData icon = Icons.fast_forward_rounded,
  }) {
    return _skipShell(
      focusNode: focusNode,
      onActivate: onActivate,
      hideProgress: hideProgress,
      showTimerBar: showTimerBar,
      content: (hasFocus) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasFocus
                    ? accent
                    : Colors.white.withValues(alpha: 0.16),
              ),
              child: Icon(icon, size: 15, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasFocus ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Botón "Siguiente capítulo" con miniatura (si la hay) y datos del capítulo.
  Widget _nextEpisodeCard({
    required FocusNode focusNode,
    required VoidCallback onActivate,
    required double hideProgress,
    required bool showTimerBar,
  }) {
    final thumb = _nextEpisodeThumb;
    final tag = 'T${widget.nextSeason} · E${widget.nextEpisode}';
    final et = (widget.nextEpisodeTitle ?? '').trim();
    return _skipShell(
      focusNode: focusNode,
      onActivate: onActivate,
      hideProgress: hideProgress,
      showTimerBar: showTimerBar,
      minWidth: 200,
      maxWidth: 340,
      content: (hasFocus) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 5, 12, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (thumb != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 96,
                  height: 54,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: thumb,
                        fit: BoxFit.cover,
                        memCacheWidth: 240,
                        errorWidget: (_, __, ___) =>
                            Container(color: const Color(0xFF1A1A1A)),
                      ),
                      Container(color: Colors.black.withValues(alpha: 0.22)),
                      Center(
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: 0.55),
                            border: Border.all(color: Colors.white70, width: 1),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hasFocus
                      ? accent
                      : Colors.white.withValues(alpha: 0.16),
                ),
                child: const Icon(Icons.skip_next_rounded,
                    color: Colors.white, size: 18),
              ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SIGUIENTE CAPÍTULO',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: hasFocus ? accent : Colors.white60,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: hasFocus ? Colors.black : Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (et.isNotEmpty)
                    Text(
                      et,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasFocus ? Colors.black54 : Colors.white70,
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
    );
  }

  Widget _skipIntroBtn() {
    final showBar = !_skipIntroAutoHidden && _showSkipIntro;
    return _skipChip(
      focusNode: _skipIntroFocus,
      label: 'Omitir intro',
      onActivate: _skipIntro,
      hideProgress: _skipIntroHideProgress,
      showTimerBar: showBar,
      icon: Icons.fast_forward_rounded,
    );
  }

  Widget _skipOutroBtn() {
    final showBar = !_skipOutroAutoHidden && _showSkipOutro;
    if (_hasNextEpisode) {
      return _nextEpisodeCard(
        focusNode: _skipOutroFocus,
        onActivate: _skipOutroOrNext,
        hideProgress: _skipOutroHideProgress,
        showTimerBar: showBar,
      );
    }
    return _skipChip(
      focusNode: _skipOutroFocus,
      label: 'Omitir outro',
      onActivate: _skipOutroOrNext,
      hideProgress: _skipOutroHideProgress,
      showTimerBar: showBar,
      icon: Icons.fast_forward_rounded,
    );
  }

  Widget _centeredMenu({
    required String title,
    required VoidCallback onClose,
    required List<Widget> children,
  }) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {},
            // FocusScope captura todo el mando mientras el menú está abierto
            child: FocusScope(
              autofocus: true,
              // Impide que el foco vuelva a los controles de detrás
              canRequestFocus: true,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Focus(
                  focusNode: _panelFocus,
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.escape ||
                        key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.browserBack) {
                      onClose();
                      return KeyEventResult.handled;
                    }
                    // Dejar ↑↓←→ y OK al traversal / ListTiles
                    return KeyEventResult.ignored;
                  },
                  child: Material(
                    color: const Color(0xFF1A1F2A),
                    borderRadius: BorderRadius.circular(16),
                    elevation: 12,
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        listTileTheme: const ListTileThemeData(
                          selectedColor: Colors.white,
                          textColor: Colors.white,
                          iconColor: Colors.white70,
                        ),
                        focusColor: Colors.white,
                        highlightColor: Colors.white24,
                      ),
                      child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 420,
                        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 17,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: onClose,
                                  icon: const Icon(Icons.close,
                                      color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.only(bottom: 16),
                              children: children,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ), // Theme
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _qualitiesPanel() {
    final autoLabel = _hlsAutoActual != null && _hlsAutoActual!.isNotEmpty
        ? 'Automática ($_hlsAutoActual)'
        : 'Automática';
    final items = <({String label, String? url, String id})>[
      (label: autoLabel, url: null, id: 'auto'),
      ..._hlsQualities.map((e) => (label: e.label, url: e.url, id: e.label)),
    ];
    return _centeredMenu(
      title: 'Calidad HLS',
      onClose: () => setState(() => _showQualities = false),
      children: [
        for (var i = 0; i < items.length; i++)
          ListTile(
            autofocus: widget.isTv && i == 0,
            focusColor: Colors.white12,
            selected: (items[i].id == 'auto' &&
                    (_hlsQualityLabel == 'Automática' ||
                        _hlsQualityLabel.startsWith('Automática'))) ||
                (_hlsQualityLabel == items[i].label && items[i].id != 'auto'),
            selectedTileColor: Colors.white.withValues(alpha: 0.08),
            title: Text(
              items[i].label,
              style: TextStyle(
                color: ((items[i].id == 'auto' &&
                            (_hlsQualityLabel == 'Automática' ||
                                _hlsQualityLabel.startsWith('Automática'))) ||
                        (_hlsQualityLabel == items[i].label &&
                            items[i].id != 'auto'))
                    ? accent
                    : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: ((items[i].id == 'auto' &&
                        (_hlsQualityLabel == 'Automática' ||
                            _hlsQualityLabel.startsWith('Automática'))) ||
                    (_hlsQualityLabel == items[i].label &&
                        items[i].id != 'auto'))
                ? const Icon(Icons.check, color: accent, size: 20)
                : null,
            onTap: () => _selectHlsQuality(
                items[i].id == 'auto' ? 'Automática' : items[i].label,
                items[i].url),
          ),
      ],
    );
  }


  Widget _outlinedSubText(
    String text, {
    required double fontSize,
    required Color color,
    required bool bold,
    required double borderWidth,
    double height = 1.3,
  }) {
    final weight = bold ? FontWeight.w800 : FontWeight.w500;
    final base = TextStyle(
      height: height,
      fontSize: fontSize,
      fontWeight: weight,
    );
    // Borde real por letra (stroke negro), no sombra.
    final bw = borderWidth.clamp(0.0, 6.0);
    if (bw <= 0.05) {
      return Text(
        text,
        textAlign: TextAlign.center,
        style: base.copyWith(color: color),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = bw * 2
              ..color = Colors.black,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: base.copyWith(color: color),
        ),
      ],
    );
  }

  /// Estilo de subtítulos: mismo patrón que audio/servidores (showDialog).
  Future<void> _openSubStyleMenu() async {
    if (!mounted) return;
    _rootFocus.unfocus();
    _playFocus.unfocus();
    _progressFocus.unfocus();

    const colors = <Color>[
      Color(0xFFFFFFFF),
      Color(0xFFFFFF00),
      Color(0xFF00FFFF),
      Color(0xFF00FF00),
      Color(0xFFFFA0A0),
    ];

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialog) {
            void apply(VoidCallback fn) {
              setState(fn);
              setDialog(() {});
              unawaited(_saveSubtitleStyleToPrefs());
            }

            Widget stepTile({
              required String label,
              required String display,
              required VoidCallback onDec,
              required VoidCallback onInc,
              bool autofocus = false,
            }) {
              return Focus(
                autofocus: autofocus,
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.arrowLeft ||
                      key == LogicalKeyboardKey.mediaRewind) {
                    onDec();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowRight ||
                      key == LogicalKeyboardKey.mediaFastForward) {
                    onInc();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Builder(
                  builder: (ctx) {
                    final focused = Focus.of(ctx).hasFocus;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: focused
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: focused
                              ? const Color(0xFFE50914)
                              : Colors.transparent,
                          width: focused ? 2.5 : 0,
                        ),
                        boxShadow: focused
                            ? [
                                BoxShadow(
                                  color: const Color(0xFFE50914)
                                      .withValues(alpha: 0.35),
                                  blurRadius: 10,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                color: focused ? Colors.black : Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          Icon(Icons.remove_rounded,
                              size: 20,
                              color:
                                  focused ? Colors.black54 : Colors.white38),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 72,
                            child: Text(
                              display,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: focused
                                    ? const Color(0xFFE50914)
                                    : Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.add_rounded,
                              size: 20,
                              color:
                                  focused ? Colors.black54 : Colors.white38),
                        ],
                      ),
                    );
                  },
                ),
              );
            }

            Widget toggleTile({
              required String label,
              required bool value,
              required ValueChanged<bool> onChanged,
            }) {
              return Focus(
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final key = event.logicalKey;
                  if (key == LogicalKeyboardKey.select ||
                      key == LogicalKeyboardKey.enter ||
                      key == LogicalKeyboardKey.space) {
                    onChanged(!value);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Builder(
                  builder: (ctx) {
                    final focused = Focus.of(ctx).hasFocus;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: focused
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: focused
                              ? const Color(0xFFE50914)
                              : Colors.transparent,
                          width: focused ? 2.5 : 0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                color: focused ? Colors.black : Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          Switch(
                            value: value,
                            activeColor: const Color(0xFFE50914),
                            onChanged: onChanged,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            }

            return FocusScope(
              autofocus: true,
              child: Center(
                child: Material(
                  color: const Color(0xFF1A1F2A),
                  borderRadius: BorderRadius.circular(16),
                  elevation: 16,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 440,
                      maxHeight: MediaQuery.sizeOf(dialogCtx).height * 0.78,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Estilo de subtítulos',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 17,
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () => Navigator.pop(dialogCtx),
                                icon: const Icon(Icons.close,
                                    color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 16),
                            children: [
                              stepTile(
                                label: 'Tamaño',
                                display: '${_subFontSize.round()} px',
                                autofocus: true,
                                onDec: () => apply(() => _subFontSize =
                                    (_subFontSize - 2).clamp(16, 48)),
                                onInc: () => apply(() => _subFontSize =
                                    (_subFontSize + 2).clamp(16, 48)),
                              ),
                              stepTile(
                                label: 'Altura inferior',
                                display: '${_subBottomPad.round()} px',
                                onDec: () => apply(() => _subBottomPad =
                                    (_subBottomPad - 4).clamp(8, 120)),
                                onInc: () => apply(() => _subBottomPad =
                                    (_subBottomPad + 4).clamp(8, 120)),
                              ),
                              stepTile(
                                label: 'Grosor del borde',
                                display: _subBorder.toStringAsFixed(1),
                                onDec: () => apply(() => _subBorder =
                                    (_subBorder - 0.5).clamp(0.0, 4.0)),
                                onInc: () => apply(() => _subBorder =
                                    (_subBorder + 0.5).clamp(0.0, 4.0)),
                              ),
                              stepTile(
                                label: 'Offset temporal',
                                display:
                                    '${_subtitleOffsetSec >= 0 ? '+' : ''}${_subtitleOffsetSec.toStringAsFixed(1)} s',
                                onDec: () => apply(() => _subtitleOffsetSec =
                                    (_subtitleOffsetSec - 0.1)
                                        .clamp(-5.0, 5.0)),
                                onInc: () => apply(() => _subtitleOffsetSec =
                                    (_subtitleOffsetSec + 0.1)
                                        .clamp(-5.0, 5.0)),
                              ),
                              const Padding(
                                padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
                                child: Text(
                                  'COLOR',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16),
                                child: Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    for (final c in colors)
                                      Focus(
                                        onKeyEvent: (node, event) {
                                          if (event is! KeyDownEvent) {
                                            return KeyEventResult.ignored;
                                          }
                                          final key = event.logicalKey;
                                          if (key ==
                                                  LogicalKeyboardKey.select ||
                                              key ==
                                                  LogicalKeyboardKey.enter ||
                                              key ==
                                                  LogicalKeyboardKey.space) {
                                            apply(() => _subColor = c);
                                            return KeyEventResult.handled;
                                          }
                                          return KeyEventResult.ignored;
                                        },
                                        child: Builder(
                                          builder: (ctx) {
                                            final focused =
                                                Focus.of(ctx).hasFocus;
                                            final sel =
                                                _subColor.value == c.value;
                                            return GestureDetector(
                                              onTap: () =>
                                                  apply(() => _subColor = c),
                                              child: Container(
                                                width: 40,
                                                height: 40,
                                                decoration: BoxDecoration(
                                                  color: c,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: focused
                                                        ? const Color(
                                                            0xFFE50914)
                                                        : (sel
                                                            ? Colors.white
                                                            : Colors
                                                                .white24),
                                                    width: focused || sel
                                                        ? 3
                                                        : 1,
                                                  ),
                                                  boxShadow: focused
                                                      ? [
                                                          BoxShadow(
                                                            color: const Color(
                                                                    0xFFE50914)
                                                                .withValues(
                                                                    alpha:
                                                                        0.4),
                                                            blurRadius: 8,
                                                          ),
                                                        ]
                                                      : null,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              toggleTile(
                                label: 'Negrita',
                                value: _subBold,
                                onChanged: (v) =>
                                    apply(() => _subBold = v),
                              ),
                              toggleTile(
                                label: 'Fondo oscuro',
                                value: _subBg,
                                onChanged: (v) => apply(() => _subBg = v),
                              ),
                              const SizedBox(height: 12),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _subBg
                                            ? const Color(0x99000000)
                                            : Colors.transparent,
                                        borderRadius:
                                            BorderRadius.circular(4),
                                      ),
                                      child: _outlinedSubText(
                                        'Vista previa de subtítulos',
                                        fontSize: _subFontSize * 0.7,
                                        color: _subColor,
                                        bold: _subBold,
                                        borderWidth: _subBorder,
                                      ),
                                    ),
                                  ),
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
          },
        );
      },
    );

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playFocus.requestFocus();
      });
    }
  }

  /// Fila TV sin Slider: ↑/↓ navega entre filas, ←/→ baja/sube el valor.
  Widget _tvStepTile({
    required String label,
    required String display,
    required VoidCallback onDec,
    required VoidCallback onInc,
    bool autofocus = false,
  }) {
    return Focus(
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.mediaRewind) {
          onDec();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.mediaFastForward) {
          onInc();
          return KeyEventResult.handled;
        }
        // ↑/↓ no se consumen → FocusTraversal navega al siguiente control
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final hasFocus = Focus.of(ctx).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: hasFocus
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasFocus ? Colors.white : Colors.white12,
                width: hasFocus ? 2.5 : 1,
              ),
              boxShadow: hasFocus
                  ? [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.28),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: hasFocus ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Icon(Icons.remove_rounded,
                    size: 20,
                    color: hasFocus ? Colors.white : Colors.white38),
                const SizedBox(width: 8),
                SizedBox(
                  width: 72,
                  child: Text(
                    display,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: hasFocus ? accent : Colors.white54,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.add_rounded,
                    size: 20,
                    color: hasFocus ? Colors.white : Colors.white38),
              ],
            ),
          );
        },
      ),
    );
  }

  SubtitleViewConfiguration _subtitleViewConfig() {
    final bw = _subBorder.clamp(0.0, 6.0);
    // Borde negro por letra (stroke). media_kit pinta con TextStyle.
    final style = TextStyle(
      height: 1.35,
      fontSize: _subFontSize,
      color: _subColor,
      fontWeight: _subBold ? FontWeight.w800 : FontWeight.w500,
      backgroundColor: _subBg ? const Color(0x99000000) : Colors.transparent,
      // Fallback de contorno: sombras de 0 blur en 8 direcciones = borde negro
      shadows: bw <= 0.05
          ? null
          : [
              for (final o in <Offset>[
                Offset(-bw, -bw),
                Offset(0, -bw),
                Offset(bw, -bw),
                Offset(-bw, 0),
                Offset(bw, 0),
                Offset(-bw, bw),
                Offset(0, bw),
                Offset(bw, bw),
              ])
                Shadow(offset: o, blurRadius: 0, color: Colors.black),
            ],
    );
    return SubtitleViewConfiguration(
      style: style,
      textAlign: TextAlign.center,
      padding: EdgeInsets.fromLTRB(16.0, 0.0, 16.0, _subBottomPad),
    );
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
                  if (!widget.isTv)
                    IconButton(
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _clockNow(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      if (ends.isNotEmpty)
                        Text(
                          ends,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
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
        : (widget.contentType.toLowerCase().contains('movie')
            ? 'Película'
            : widget.contentType);

    // Modo "bajó a capítulos": solo navegación de temporadas/episodios
    final episodesMode =
        widget.isTv && _showEpisodesPanel && _effectiveEpisodeList.isNotEmpty;
    final progressOnly = _showProgressOnly && !episodesMode;

    return Stack(
      children: [
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xF2000000), Color(0x99000000), Colors.transparent],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
              child: SizedBox(
                height: episodesMode ? 260 : (progressOnly ? 72 : 200),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: episodesMode
                    ? _buildEpisodesNavLayer(progress)
                    : progressOnly
                        ? _buildProgressOnlyLayer(progress)
                        : _buildMainControlsLayer(
                            progress: progress,
                            quality: quality,
                            lang: lang,
                            repoName: repoName,
                            epLine: epLine,
                            typeLabel: typeLabel,
                            s: s,
                          ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Solo barra de progreso + tiempo (sin botones ni título).
  Widget _buildProgressOnlyLayer(double progress) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildProgressSlider(progress),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${_fmt(_position)} / ${_fmt(_duration)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Capa principal: título, badges, seek, botones.
  Widget _buildMainControlsLayer({
    required double progress,
    required String quality,
    required String lang,
    required String repoName,
    required String epLine,
    required String typeLabel,
    required StreamServer? s,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.logo != null && widget.logo!.isNotEmpty)
          // Alineado a la izquierda desde el primer frame (evita flash al centro)
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
                placeholder: (_, __) => const SizedBox(height: 32, width: 1),
                errorWidget: (_, __, ___) => Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
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
        _serverBadgesRow(s, fallbackQuality: quality, fallbackLang: lang),
        const SizedBox(height: 6),
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
        _buildProgressSlider(progress),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    children: [
                      _tvActionBtn(
                        focusNode: _playFocus,
                        icon: _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        onActivate: _togglePlay,
                        size: 44,
                      ),
                      const SizedBox(width: 6),
                      _tvActionBtn(
                        icon: Icons.replay_rounded,
                        onActivate: () async {
                          if (_useMediaKit) {
                            await _mk?.seek(Duration.zero);
                          } else {
                            await _vp?.seekTo(Duration.zero);
                          }
                          _scheduleHide();
                        },
                      ),
                      if (_useMediaKit || _externalSubs.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _tvActionBtn(
                          icon: Icons.closed_caption_rounded,
                          onActivate: _openTracksMenu,
                        ),
                      ],
                      if (_hlsQualities.isNotEmpty ||
                          isHlsUrl(_current?.url ?? widget.url,
                              isHlsFlag: _current?.isHls ?? false) ||
                          (_isCurrentTs && _tsQualityOptions.length > 1)) ...[
                        const SizedBox(width: 6),
                        _tvActionBtn(
                          icon: Icons.high_quality_rounded,
                          onActivate: _openQualitiesMenu,
                        ),
                      ],
                      if (_servers.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _tvActionBtn(
                          icon: Icons.dns_rounded,
                          onActivate: _openServersMenu,
                        ),
                      ],
                      const SizedBox(width: 6),
                      _tvActionBtn(
                        icon: _fitModeIcon,
                        onActivate: _cycleFit,
                      ),
                      if (_subtitleTracks.isNotEmpty ||
                          _externalSubs.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _tvActionBtn(
                          icon: Icons.text_fields_rounded,
                          onActivate: _openSubStyleMenu,
                        ),
                      ],
                      if (_hasNextEpisode) ...[
                        const SizedBox(width: 6),
                        _tvActionBtn(
                          icon: Icons.skip_next_rounded,
                          onActivate: () =>
                              _goNextEpisode(usePreload: false),
                        ),
                      ],
                      if (!widget.isTv)
                        IconButton(
                          tooltip: _useMediaKit
                              ? 'Motor: media_kit'
                              : 'Motor: video_player',
                          onPressed: _toggleEngine,
                          icon: Icon(
                            _useMediaKit
                                ? Icons.memory_rounded
                                : Icons.play_circle_outline_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                    ],
                  ),
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
    );
  }

  /// Capa de navegación de capítulos: sustituye herramientas (efecto “bajar”).
  Widget _buildEpisodesNavLayer(double progress) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.season != null && widget.episode != null
              ? 'T${widget.season} · E${widget.episode}${widget.episodeTitle != null && widget.episodeTitle!.isNotEmpty ? '  ·  ${widget.episodeTitle}' : ''}'
              : widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        _buildEpisodesStrip(),
      ],
    );
  }

  Widget _buildProgressSlider(double progress, {bool compact = false}) {
    return Focus(
      focusNode: compact ? null : _progressFocus,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (!widget.isTv) return KeyEventResult.ignored;
        final isDown = event is KeyDownEvent;
        final isRepeat = event is KeyRepeatEvent;
        if (!isDown && !isRepeat) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft) {
          _scrubByAccelerated(-1);
          if (_showProgressOnly) {
            _progressOnlyTimer?.cancel();
            _progressOnlyTimer = Timer(const Duration(seconds: 3), () {
              if (!mounted) return;
              unawaited(_commitScrub());
              setState(() {
                _showProgressOnly = false;
                _showControls = false;
              });
              _rootFocus.requestFocus();
              _focusSkipIfVisible();
            });
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          _scrubByAccelerated(1);
          if (_showProgressOnly) {
            _progressOnlyTimer?.cancel();
            _progressOnlyTimer = Timer(const Duration(seconds: 3), () {
              if (!mounted) return;
              unawaited(_commitScrub());
              setState(() {
                _showProgressOnly = false;
                _showControls = false;
              });
              _rootFocus.requestFocus();
              _focusSkipIfVisible();
            });
          }
          return KeyEventResult.handled;
        }
        if (!isDown) return KeyEventResult.ignored;
        if (key == LogicalKeyboardKey.arrowUp) {
          if (_showProgressOnly) {
            // En modo solo barra no hay botones arriba
            return KeyEventResult.handled;
          }
          if (_focusSkipFromControls()) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          if (_showProgressOnly) {
            _dismissProgressOnly();
            setState(() {
              _showControls = true;
              _showProgressOnly = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _playFocus.requestFocus();
            });
            return KeyEventResult.handled;
          }
          _playFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListenableBuilder(
        listenable: _progressFocus,
        builder: (ctx, _) {
          // Al enfocar: solo cambia a rojo, mismo tamaño (sin salto visual).
          final hasFocus = widget.isTv && _progressFocus.hasFocus && !compact;
          final thumbR = compact ? 4.0 : 6.0;
          return SliderTheme(
            data: SliderThemeData(
              trackHeight: compact ? 2.5 : 3.5,
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: thumbR,
                elevation: 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
              activeTrackColor: const Color(0xFF4FC3F7),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
              thumbColor: hasFocus ? const Color(0xFFE50914) : Colors.white,
              overlayColor: Colors.transparent,
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
                final ms = (v * _duration.inMilliseconds).round();
                setState(() {
                  _position = Duration(milliseconds: ms);
                  _scrubTargetMs = ms;
                  _isDragging = true;
                });
              },
              onChangeEnd: (v) async {
                setState(() {
                  _isDragging = false;
                  _scrubTargetMs = null;
                });
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
          );
        },
      ),
    );
  }

  bool get _hasNextEpisode =>
      widget.nextSeason != null && widget.nextEpisode != null;

  /// Ya no hay CTA separado: outro y siguiente son el mismo botón (_outroBtnVisible).
  bool get _shouldShowNextCta => false;

  Widget _serversPanel() {
    final langs = _availableLanguages;
    final indices = _filteredServerIndices;
    final title =
        langs.length > 1 ? 'Idioma / Calidad / Servidor' : 'Calidad / Servidor';
    final children = <Widget>[
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
        for (var idx = 0; idx < indices.length; idx++)
          Builder(
            builder: (context) {
              final i = indices[idx];
              final s = _servers[i];
              final sel = i == _serverIndex;
              return ListTile(
                autofocus: widget.isTv && idx == 0,
                focusColor: Colors.white12,
                selected: sel,
                selectedTileColor: Colors.white.withValues(alpha: 0.08),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: _langFlagAvatar(s),
                title: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: sel ? accent : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _serverBadgesRow(s, compact: true),
                ),
                trailing: sel
                    ? const Icon(Icons.check_circle, color: accent, size: 20)
                    : null,
                onTap: () => _switchServer(i),
              );
            },
          ),
    ];
    return _centeredMenu(
      title: title,
      onClose: () => setState(() => _showServers = false),
      children: children,
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
    final children = <Widget>[
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
        for (var ai = 0; ai < _audioTracks.length; ai++)
          ListTile(
            autofocus: widget.isTv && ai == 0,
            focusColor: Colors.white12,
            selected: _selectedAudio?.id == _audioTracks[ai].id,
            selectedTileColor: Colors.white.withValues(alpha: 0.08),
            leading: Icon(
              Icons.audiotrack,
              color: _selectedAudio?.id == _audioTracks[ai].id
                  ? accent
                  : Colors.white54,
            ),
            title: Text(
              _trackLabel(_audioTracks[ai]),
              style: TextStyle(
                color: _selectedAudio?.id == _audioTracks[ai].id
                    ? accent
                    : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () async {
              await _mk?.setAudioTrack(_audioTracks[ai]);
              setState(() => _selectedAudio = _audioTracks[ai]);
              unawaited(_persistTrackChoice(
                audioLang: _audioTracks[ai].language ??
                    _audioTracks[ai].title ??
                    _audioTracks[ai].id,
              ));
            },
          ),
      ],
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
        autofocus: widget.isTv && _audioTracks.isEmpty,
        focusColor: Colors.white12,
        selected:
            _selectedSubtitle == null || _selectedSubtitle?.id == 'no',
        selectedTileColor: Colors.white.withValues(alpha: 0.08),
        leading:
            const Icon(Icons.subtitles_off, color: Colors.white54),
        title: const Text('Sin subtitulos',
            style: TextStyle(color: Colors.white)),
        onTap: () async {
          await _mk?.setSubtitleTrack(SubtitleTrack.no());
          setState(() => _selectedSubtitle = SubtitleTrack.no());
          await _clearExternalSubtitle();
          unawaited(_persistTrackChoice(subChoice: 'off'));
        },
      ),
      if (_subtitleTracks.isEmpty && _externalSubs.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'No hay subtítulos embebidos ni del repositorio.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      for (final t in _subtitleTracks)
        ListTile(
          focusColor: Colors.white12,
          selected: _selectedSubtitle?.id == t.id,
          selectedTileColor: Colors.white.withValues(alpha: 0.08),
          leading: Icon(
            Icons.subtitles,
            color: _selectedSubtitle?.id == t.id ? accent : Colors.white54,
          ),
          title: Text(
            _trackLabel(t),
            style: TextStyle(
              color: _selectedSubtitle?.id == t.id ? accent : Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: const Text('Embebido',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
          onTap: () async {
            await _mk?.setSubtitleTrack(t);
            setState(() => _selectedSubtitle = t);
            unawaited(_persistTrackChoice(subChoice: 'embedded:${t.id}'));
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
          focusColor: Colors.white12,
          selected: !_subsEnabled || _activeExternalSub == null,
          selectedTileColor: Colors.white.withValues(alpha: 0.08),
          leading:
              const Icon(Icons.subtitles_off, color: Colors.white54),
          title: const Text('Sin subtítulos externos',
              style: TextStyle(color: Colors.white)),
          onTap: _clearExternalSubtitle,
        ),
        for (final sub in _externalSubs)
          ListTile(
            focusColor: Colors.white12,
            selected:
                _activeExternalSub?.url == sub.url && _subsEnabled,
            selectedTileColor: Colors.white.withValues(alpha: 0.08),
            leading: Icon(
              Icons.subtitles,
              color: _activeExternalSub?.url == sub.url
                  ? accent
                  : Colors.white54,
            ),
            title: Text(sub.label,
                style: TextStyle(
                  color: _activeExternalSub?.url == sub.url
                      ? accent
                      : Colors.white,
                  fontWeight: FontWeight.w600,
                )),
            subtitle: Text(sub.lang.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white38, fontSize: 11)),
            onTap: () async {
              await _applyExternalSubtitle(sub);
              unawaited(_persistTrackChoice(subChoice: 'external:${sub.url}'));
            },
          ),
      ],
    ];
    return _centeredMenu(
      title: 'Audio / Subtítulos',
      onClose: () => setState(() => _showTracks = false),
      children: children,
    );
  }
}


class _TvMenuEntry {
  final String label;
  final String? subtitle;
  final bool selected;
  final bool autofocus;
  final bool isHeader;
  final Widget? leading;
  final VoidCallback? onSelect;
  const _TvMenuEntry({
    required this.label,
    this.subtitle,
    this.selected = false,
    this.autofocus = false,
    this.isHeader = false,
    this.leading,
    this.onSelect,
  });
}

/// Ítem de menú TV con foco visible (fondo blanco + texto negro).
class _TvMenuTile extends StatefulWidget {
  final String label;
  final String? subtitle;
  final bool selected;
  final bool autofocus;
  final Widget? leading;
  final VoidCallback onActivate;
  const _TvMenuTile({
    required this.label,
    this.subtitle,
    this.selected = false,
    this.autofocus = false,
    this.leading,
    required this.onActivate,
  });
  @override
  State<_TvMenuTile> createState() => _TvMenuTileState();
}

class _TvMenuTileState extends State<_TvMenuTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || widget.selected;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) {
        setState(() => _focused = v);
        if (v) {
          // Auto-scroll al ítem enfocado
          Scrollable.ensureVisible(
            context,
            alignment: 0.4,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onActivate,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white
                : (widget.selected
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused
                  ? const Color(0xFFE50914)
                  : (widget.selected ? Colors.white38 : Colors.transparent),
              width: _focused ? 2.5 : (widget.selected ? 1 : 0),
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: const Color(0xFFE50914).withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _focused ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.trim().isNotEmpty)
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _focused
                              ? Colors.black54
                              : Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.selected)
                Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: _focused
                      ? const Color(0xFFE50914)
                      : const Color(0xFFE50914),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botón de diálogo TV con foco visible.
class _TvDialogButton extends StatefulWidget {
  final String label;
  final bool primary;
  final bool autofocus;
  final VoidCallback onPressed;
  const _TvDialogButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });
  @override
  State<_TvDialogButton> createState() => _TvDialogButtonState();
}

class _TvDialogButtonState extends State<_TvDialogButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bg = _focused
        ? Colors.white
        : (widget.primary
            ? const Color(0xFFE50914).withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.10));
    final fg = _focused
        ? Colors.black
        : Colors.white;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 1.5,
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

class _SubCue {
  final Duration start;
  final Duration end;
  final String text;
  const _SubCue({required this.start, required this.end, required this.text});
}