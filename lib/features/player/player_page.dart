import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/tmdb_apis.dart';
import '../servers/servers_modal.dart';
import 'hls_proxy.dart'; // ← ajusta la ruta si lo mueves

const _kAccent = Color(0xFFE50914);

enum _VideoFitMode { contain, cover, fill, fitWidth, fitHeight }

/// Player Windows (media_kit → libmpv), con proxy HLS local estilo Nuvio.
///
/// IMPORTANTE: en Windows el vídeo sale negro si Impeller está activo.
/// Lanza siempre:
///   flutter run -d windows --no-enable-impeller
/// o:
///   flutter config --no-enable-impeller
///
/// Flujo HLS (igual que Nuvio Desktop):
///  1. Si la URL es m3u8 → se arranca [HlsProxyServer].
///  2. El player abre `http://127.0.0.1:<port>/playlist?u=...`.
///  3. El proxy reescribe la playlist y limpia segmentos con cabecera
///     de imagen falsa (tiktokcdn, etc.) hasta el sync byte 0x47.
///  4. MP4 / streams directos van sin proxy.
class PlayerPage extends StatefulWidget {
  final String videoUrl;
  final int idcontenido;
  final int? tmdbId;
  final int? temporada;
  final int? capitulo;
  final String tipo;
  final String titulo;
  final Map<String, String>? headers;
  final String? imdbId;
  final String? backdropUrl;

  const PlayerPage({
    super.key,
    required this.videoUrl,
    required this.idcontenido,
    this.tmdbId,
    this.temporada,
    this.capitulo,
    required this.tipo,
    required this.titulo,
    this.headers,
    this.imdbId,
    this.backdropUrl,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  Player? _player;
  VideoController? _videoController;

  HlsProxyServer? _hlsProxy;
  String? _playUrl; // URL final abierta (proxied o directa)
  bool _usingProxy = false;

  bool _loading = true;
  bool _showControls = true;
  bool _error = false;
  String? _errorMsg;
  Timer? _hideTimer;
  bool _seeking = false;
  double _seekValue = 0;
  bool _useHwAccel = true;

  String? _backdropUrl;
  String? _imdbId;
  String _displayTitle = '';
  String? _logoUrl;

  double? _introStart;
  double? _introEnd;
  double? _outroStart;
  bool _showSkipIntro = false;
  bool _skipIntroDismissed = false;
  bool _showNextPrompt = false;
  bool _nextDismissed = false;

  bool _isFullscreen = false;
  _VideoFitMode _fitMode = _VideoFitMode.contain;

  List<dynamic> _temporadas = const [];
  List<dynamic> _episodiosTemporada = const [];
  int _selectedSeasonNumber = 1;
  bool _loadingEpisodes = false;
  bool _showBottomPanel = false;

  bool _preloadTriggered = false;

  final List<StreamSubscription> _subs = [];

  bool get _isTv {
    final t = widget.tipo.toLowerCase();
    return t == 'tv' || t == 'serie' || t == 'series';
  }

  // ─── Fit helpers ───────────────────────────────────────────────────────

  BoxFit get _currentBoxFit {
    switch (_fitMode) {
      case _VideoFitMode.contain:
        return BoxFit.contain;
      case _VideoFitMode.cover:
        return BoxFit.cover;
      case _VideoFitMode.fill:
        return BoxFit.fill;
      case _VideoFitMode.fitWidth:
        return BoxFit.fitWidth;
      case _VideoFitMode.fitHeight:
        return BoxFit.fitHeight;
    }
  }

  String get _fitModeLabel {
    switch (_fitMode) {
      case _VideoFitMode.contain:
        return 'Original';
      case _VideoFitMode.cover:
        return 'Expandir';
      case _VideoFitMode.fill:
        return 'Estirar';
      case _VideoFitMode.fitWidth:
        return 'Ancho';
      case _VideoFitMode.fitHeight:
        return 'Alto';
    }
  }

  IconData get _fitModeIcon {
    switch (_fitMode) {
      case _VideoFitMode.contain:
        return Icons.fit_screen_rounded;
      case _VideoFitMode.cover:
        return Icons.aspect_ratio_rounded;
      case _VideoFitMode.fill:
        return Icons.open_in_full_rounded;
      case _VideoFitMode.fitWidth:
        return Icons.swap_horiz_rounded;
      case _VideoFitMode.fitHeight:
        return Icons.swap_vert_rounded;
    }
  }

  void _cycleFitMode() {
    setState(() {
      final values = _VideoFitMode.values;
      _fitMode = values[(_fitMode.index + 1) % values.length];
    });
    _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    try {
      final next = !_isFullscreen;
      await windowManager.setFullScreen(next);
      if (mounted) setState(() => _isFullscreen = next);
    } catch (e) {
      debugPrint('[LOL+] No se pudo cambiar pantalla completa: $e');
    }
    _scheduleHide();
  }

  // ─── Lifecycle ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}

    _displayTitle = widget.titulo;
    _backdropUrl = widget.backdropUrl;
    _imdbId = widget.imdbId;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();

    if (Platform.isWindows && !kIsWeb) {
      debugPrint(
        '[LOL+] Si el vídeo sale negro: flutter run -d windows --no-enable-impeller',
      );
    }

    _syncFullscreenState();
    _createPlayer(hw: true);
    _selectedSeasonNumber = widget.temporada ?? 1;
    _loadMeta();
    _loadLogo();
    _initPlayer();
  }

  Future<void> _syncFullscreenState() async {
    try {
      final fs = await windowManager.isFullScreen();
      if (mounted) setState(() => _isFullscreen = fs);
    } catch (_) {}
  }

  void _createPlayer({required bool hw}) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();

    try {
      _player?.dispose();
    } catch (_) {}

    _useHwAccel = hw;
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'LOL+',
        bufferSize: 64 * 1024 * 1024, // 64 MB — mejor para HLS remoto
      ),
    );
    _videoController = VideoController(
      _player!,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hw,
        hwdec: hw ? 'auto' : 'no',
      ),
    );

    final p = _player!;

    _subs.add(p.stream.error.listen((e) {
      if (!mounted || e.toString().isEmpty) return;
      final low = e.toString().toLowerCase();
      if (low.contains('audio')) {
        debugPrint('media_kit audio: $e');
        return;
      }
      if (low.contains('warning') || low.contains('deprecated')) return;
      debugPrint('media_kit error: $e');
    }));

    _subs.add(p.stream.position.listen((_) {
      if (!mounted || _seeking) return;
      _updateSkipVisibility();
      setState(() {});
      final sec = p.state.position.inSeconds;
      if (sec > 0 && sec % 5 == 0) {
        SharedPreferences.getInstance()
            .then((prefs) => prefs.setInt(_progressKey(), sec));
      }

      final dur = p.state.duration.inMilliseconds;
      if (dur > 0) {
        final progress = p.state.position.inMilliseconds / dur;
        if (progress >= 0.90) _maybePreloadNextMeta();
      }
    }));

    _subs.add(p.stream.playing.listen((_) {
      if (mounted) setState(() {});
    }));

    _subs.add(p.stream.width.listen((w) {
      if (mounted && w != null && w > 0) setState(() {});
    }));
    _subs.add(p.stream.height.listen((h) {
      if (mounted && h != null && h > 0) setState(() {});
    }));
    _subs.add(p.stream.videoParams.listen((_) {
      if (mounted) setState(() {});
    }));
  }

  /// Tuning demuxer estilo Nuvio: más margen para CDNs lentos / HLS raros.
  /// Evita el caso "solo audio" cuando el demuxer abandona el vídeo demasiado pronto.
  Future<void> _applyDemuxerTuning() async {
    final player = _player;
    if (player == null) return;
    try {
      final native = player.platform as dynamic;
      await native.setProperty('demuxer-lavf-probesize', '50000000');
      await native.setProperty('demuxer-lavf-analyzeduration', '30');
      await native.setProperty('demuxer-lavf-probe-info', 'yes');
      await native.setProperty('demuxer-lavf-o', 'allowed_extensions=ALL');
      await native.setProperty('hls-bitrate', 'max');
      await native.setProperty('network-timeout', '30');
      await native.setProperty(
        'stream-lavf-o',
        'reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1',
      );
      // Preferir siempre una pista de vídeo si existe
      await native.setProperty('vid', 'auto');
      await native.setProperty('aid', 'auto');
      // No descartar streams "raros"
      await native.setProperty('demuxer-mkv-subtitle-preroll', 'yes');
    } catch (e) {
      debugPrint('[LOL+] no se pudieron aplicar props de demuxer: $e');
    }
  }

  /// Lista pistas detectadas (debug "solo audio").
  Future<void> _logTracks() async {
    final p = _player;
    if (p == null) return;
    try {
      final tracks = p.state.tracks;
      debugPrint(
        '[LOL+] tracks video=${tracks.video.length} '
        'audio=${tracks.audio.length} sub=${tracks.subtitle.length}',
      );
      for (final v in tracks.video) {
        debugPrint('[LOL+]   V: id=${v.id} codec=${v.codec} w=${v.w} h=${v.h}');
      }
      for (final a in tracks.audio) {
        debugPrint('[LOL+]   A: id=${a.id} codec=${a.codec}');
      }
    } catch (e) {
      debugPrint('[LOL+] no se pudieron listar tracks: $e');
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    try {
      _player?.dispose();
    } catch (_) {}

    // Parar proxy HLS
    final proxy = _hlsProxy;
    _hlsProxy = null;
    if (proxy != null) {
      unawaited(proxy.stop());
    }

    if (_isFullscreen) {
      try {
        windowManager.setFullScreen(false);
      } catch (_) {}
    }
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ─── Meta / TMDB ───────────────────────────────────────────────────────

  Future<void> _loadMeta() async {
    try {
      final tmdbId = widget.tmdbId ?? widget.idcontenido;
      final key = await TmdbApis.getApiKey();
      final lang = await TmdbApis.getLanguage();
      final path = _isTv ? '/tv/$tmdbId' : '/movie/$tmdbId';
      final uri = Uri.parse('https://api.themoviedb.org/3$path').replace(
        queryParameters: {
          'api_key': key,
          'language': lang,
          'append_to_response': 'external_ids',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200 || !mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      final backdrop = data['backdrop_path']?.toString();
      String? bd;
      if (backdrop != null && backdrop.isNotEmpty) {
        bd = backdrop.startsWith('http')
            ? backdrop
            : 'https://image.tmdb.org/t/p/w1280$backdrop';
      }

      final ext = data['external_ids'];
      String? imdb;
      if (ext is Map) imdb = ext['imdb_id']?.toString();
      imdb ??= data['imdb_id']?.toString();

      final seasons = data['seasons'];
      final temporadas = <dynamic>[];
      if (_isTv && seasons is List) {
        for (final s in seasons) {
          if (s is Map && (s['season_number'] ?? 0) is num) {
            final n = (s['season_number'] as num).toInt();
            if (n <= 0) continue;
            temporadas.add({
              'numero': n,
              'nombre': s['name']?.toString() ?? 'Temporada $n',
              'episode_count': (s['episode_count'] as num?)?.toInt() ?? 0,
            });
          }
        }
      }

      setState(() {
        if (bd != null) _backdropUrl = bd;
        if (imdb != null && imdb.isNotEmpty) _imdbId = imdb;
        final title = (data['title'] ?? data['name'] ?? '').toString();
        if (title.isNotEmpty) _displayTitle = title;
        if (temporadas.isNotEmpty) _temporadas = temporadas;
      });

      if (_isTv && _temporadas.isNotEmpty) {
        final hasSelected = _temporadas.any(
          (t) => t is Map && t['numero'] == _selectedSeasonNumber,
        );
        if (!hasSelected) {
          _selectedSeasonNumber =
              (_temporadas.first as Map)['numero'] as int? ?? 1;
        }
        _loadEpisodesForSeason(_selectedSeasonNumber);
      }

      if (_imdbId != null && _imdbId!.isNotEmpty) {
        _loadSkipSegments(_imdbId!);
      }
    } catch (_) {}
  }

  Future<void> _loadLogo() async {
    try {
      final tmdbId = widget.tmdbId ?? widget.idcontenido;
      final key = await TmdbApis.getApiKey();
      final lang = await TmdbApis.getLanguage();
      final shortLang = lang.split('-').first;
      final path = _isTv ? '/tv/$tmdbId/images' : '/movie/$tmdbId/images';
      final uri = Uri.parse('https://api.themoviedb.org/3$path').replace(
        queryParameters: {
          'api_key': key,
          'include_image_language': '$shortLang,en,null',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200 || !mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final logos = data['logos'];
      if (logos is! List || logos.isEmpty) return;

      Map? best;
      for (final l in logos) {
        if (l is! Map) continue;
        final iso = l['iso_639_1'];
        if (iso == shortLang) {
          best = l;
          break;
        }
      }
      best ??= logos.firstWhere(
        (l) => l is Map && l['iso_639_1'] == 'en',
        orElse: () => logos.first,
      ) as Map?;

      final filePath = best?['file_path']?.toString();
      if (filePath == null || filePath.isEmpty || !mounted) return;
      setState(() {
        _logoUrl = 'https://image.tmdb.org/t/p/w500$filePath';
      });
    } catch (_) {}
  }

  Future<void> _loadEpisodesForSeason(int seasonNumber) async {
    if (!_isTv) return;
    setState(() => _loadingEpisodes = true);
    try {
      final tmdbId = widget.tmdbId ?? widget.idcontenido;
      final key = await TmdbApis.getApiKey();
      final lang = await TmdbApis.getLanguage();
      final uri = Uri.parse(
        'https://api.themoviedb.org/3/tv/$tmdbId/season/$seasonNumber',
      ).replace(queryParameters: {'api_key': key, 'language': lang});
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() => _loadingEpisodes = false);
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final eps = data['episodes'];
      final list = <dynamic>[];
      if (eps is List) {
        for (final e in eps) {
          if (e is Map) {
            list.add({
              'numero': e['episode_number'],
              'titulo': e['name']?.toString() ?? '',
              'still_path': e['still_path']?.toString(),
            });
          }
        }
      }
      setState(() {
        _episodiosTemporada = list;
        _loadingEpisodes = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingEpisodes = false);
    }
  }

  void _selectSeason(int seasonNumber) {
    if (seasonNumber == _selectedSeasonNumber) return;
    setState(() {
      _selectedSeasonNumber = seasonNumber;
      _episodiosTemporada = const [];
    });
    _loadEpisodesForSeason(seasonNumber);
  }

  void _playEpisode(int seasonNumber, int episodeNumber) {
    final tmdbId = widget.tmdbId ?? widget.idcontenido;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: ServidoresModal(
            idcontenido: widget.idcontenido,
            tmdbId: tmdbId,
            temporada: seasonNumber,
            capitulo: episodeNumber,
            tipo: 'tv',
            titulo: widget.titulo,
            backdropUrl: _backdropUrl,
            fromPlayer: true,
          ),
        ),
      ),
    );
  }

  void _maybePreloadNextMeta() {
    if (_preloadTriggered || !_isTv) return;
    _preloadTriggered = true;
    debugPrint(
      '[LOL+] cerca del final: precarga de metadatos del siguiente capítulo',
    );
  }

  Future<void> _loadSkipSegments(String imdbId) async {
    try {
      final params = <String, String>{
        'imdb_id': imdbId,
        'segment_type': 'intro',
      };
      if (_isTv && widget.temporada != null) {
        params['season'] = '${widget.temporada}';
        params['episode'] = '${widget.capitulo ?? 1}';
      }
      final uri = Uri.https('api.introdb.app', '/segments', params);
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || !mounted) return;
      final data = jsonDecode(res.body);
      if (data is! Map) return;

      final intro = data['intro'];
      if (intro is Map) {
        final start = intro['start_sec'];
        final end = intro['end_sec'];
        if (start is num && end is num) {
          setState(() {
            _introStart = start.toDouble();
            _introEnd = end.toDouble();
          });
        }
      }
      final outro = data['outro'];
      if (outro is Map) {
        final start = outro['start_sec'];
        if (start is num) {
          setState(() => _outroStart = start.toDouble());
        }
      }
    } catch (_) {}
  }

  // ─── Headers / HLS detection / proxy ───────────────────────────────────

  Map<String, String> _headers() => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Connection': 'keep-alive',
        ...?widget.headers,
      };

  bool _looksLikeHls(String url) {
    final u = url.toLowerCase().trim();
    if (u.isEmpty) return false;
    if (u.contains('.m3u8') || u.contains('.m3u')) return true;
    if (u.contains('format=m3u8') ||
        u.contains('type=m3u8') ||
        u.contains('ext=m3u8')) {
      return true;
    }
    if (u.contains('/playlist') ||
        u.contains('/master.m3u') ||
        u.contains('/index.m3u') ||
        u.contains('/hls/')) {
      return true;
    }
    return false;
  }

  /// Arranca el proxy HLS y devuelve la URL de entrada (o null si falla).
  Future<String?> _proxyEntry(String original) async {
    try {
      _hlsProxy ??= HlsProxyServer(extraHeaders: _headers());
      if (!_hlsProxy!.isRunning) {
        await _hlsProxy!.start();
      }
      final entry = _hlsProxy!.buildEntryUrl(original);
      debugPrint('[LOL+] HLS proxy entry → $entry');
      debugPrint('[LOL+]   origen: $original');
      return entry;
    } catch (e) {
      debugPrint('[LOL+] no se pudo arrancar proxy: $e');
      return null;
    }
  }

  /// Abre [url] en el player, aplica tuning y espera frame de vídeo.
  /// Devuelve true si hay dimensiones de vídeo > 0.
  Future<bool> _openAndWaitVideo({
    required String url,
    required Map<String, String> headers,
    required bool hw,
    Duration wait = const Duration(seconds: 12),
  }) async {
    if (_player == null || hw != _useHwAccel) {
      _createPlayer(hw: hw);
    }
    final p = _player!;
    try {
      await p.open(Media(url, httpHeaders: headers), play: false);
    } catch (e) {
      debugPrint('[LOL+] open falló: $e');
      return false;
    }

    await _applyDemuxerTuning();
    try {
      await p.setVideoTrack(VideoTrack.auto());
    } catch (_) {}
    try {
      await p.setAudioTrack(AudioTrack.auto());
    } catch (_) {}
    try {
      await p.setVolume(100);
    } catch (_) {}

    await _tryResume();
    await p.play();

    try {
      await p.stream.width
          .firstWhere((w) => w != null && w > 0)
          .timeout(wait);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ─── Init / open media ─────────────────────────────────────────────────
  //
  // Estrategia (importante para CDNs tipo morencius que cuelgan a package:http):
  //   1) Abrir URL DIRECTA con libmpv + headers (stack de red de mpv, no Dart).
  //   2) Si no hay vídeo y es HLS → reintentar vía proxy local (strip cabeceras).
  //   3) Si sigue sin vídeo en Windows → software decode.

  Future<void> _initPlayer() async {
    final url = widget.videoUrl.trim();
    if (url.isEmpty) {
      setState(() {
        _loading = false;
        _error = true;
        _errorMsg = 'URL vacía';
      });
      return;
    }

    if (_player == null) return;

    try {
      setState(() {
        _loading = true;
        _error = false;
      });

      final headers = _headers();
      final isHls = _looksLikeHls(url);

      // ── 1) DIRECTO con libmpv ──────────────────────────────────────────
      debugPrint('[LOL+] intento DIRECTO: $url');
      _usingProxy = false;
      _playUrl = url;
      bool gotVideo = await _openAndWaitVideo(
        url: url,
        headers: headers,
        hw: true,
      );

      if (!mounted) return;
      await _logTracks();
      debugPrint(
        '[LOL+] directo size=${_player?.state.width}x${_player?.state.height} '
        'gotVideo=$gotVideo',
      );

      // ── 2) Si falla y es HLS → PROXY (strip cabeceras falsas) ──────────
      if (!gotVideo && isHls) {
        debugPrint('[LOL+] sin vídeo en directo → intento PROXY HLS');
        try {
          await _player?.stop();
        } catch (_) {}

        final entry = await _proxyEntry(url);
        if (entry != null) {
          _usingProxy = true;
          _playUrl = entry;
          // Localhost: headers vacíos (el proxy usa extraHeaders al origen)
          gotVideo = await _openAndWaitVideo(
            url: entry,
            headers: const {},
            hw: true,
          );
          if (!mounted) return;
          await _logTracks();
          debugPrint(
            '[LOL+] proxy size=${_player?.state.width}x${_player?.state.height} '
            'gotVideo=$gotVideo',
          );
        }
      }

      // ── 3) Software decode en Windows ──────────────────────────────────
      if (!gotVideo && Platform.isWindows && _useHwAccel) {
        debugPrint('[LOL+] sin frame → reintento software decode');
        try {
          await _player?.stop();
        } catch (_) {}

        final tryUrl = _playUrl ?? url;
        final tryHeaders = _usingProxy ? <String, String>{} : headers;
        gotVideo = await _openAndWaitVideo(
          url: tryUrl,
          headers: tryHeaders,
          hw: false,
        );
        if (!mounted) return;
        await _logTracks();

        if (gotVideo) {
          debugPrint('[LOL+] vídeo OK en software decode');
        } else {
          debugPrint(
            '[LOL+] sin vídeo. Comprueba:\n'
            '  1) flutter run -d windows --no-enable-impeller\n'
            '  2) Si proxy timeout → el CDN bloquea package:http; '
            'el modo DIRECTO debería bastar si el token es válido\n'
            '  3) tracks con codec=null → stream no abrió (403/timeout)',
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _loading = false;
        // No marcar error si hay audio aunque no haya vídeo todavía;
        // el usuario puede cambiar servidor.
        _error = false;
      });
      _scheduleHide();
    } catch (e, st) {
      debugPrint('[LOL+] _initPlayer error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorMsg = e.toString();
      });
    }
  }

  Future<void> _tryResume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sec = prefs.getInt(_progressKey());
      if (sec != null && sec > 5) {
        final pos = Duration(seconds: sec);
        final dur = _player?.state.duration ?? Duration.zero;
        if (dur == Duration.zero || pos < dur) {
          await _player?.seek(pos);
        }
      }
    } catch (_) {}
  }

  String _progressKey() {
    final t = widget.temporada ?? 0;
    final c = widget.capitulo ?? 0;
    return 'progress_${widget.idcontenido}_T${t}_C$c';
  }

  // ─── Skip intro / next ─────────────────────────────────────────────────

  void _updateSkipVisibility() {
    final p = _player;
    if (p == null) return;
    final pos = p.state.position.inMilliseconds / 1000.0;
    final dur = p.state.duration.inMilliseconds / 1000.0;

    bool showIntro = false;
    if (_introStart != null && _introEnd != null && !_skipIntroDismissed) {
      showIntro = pos >= _introStart! && pos <= _introEnd!;
    }

    bool showNext = false;
    if (_isTv && !_nextDismissed && dur > 0) {
      final threshold = _outroStart ?? (dur * 0.95);
      showNext = pos >= threshold;
    }

    if (showIntro != _showSkipIntro || showNext != _showNextPrompt) {
      _showSkipIntro = showIntro;
      _showNextPrompt = showNext;
    }
  }

  void _skipIntro() {
    final end = _introEnd;
    if (end == null) return;
    _player?.seek(Duration(milliseconds: (end * 1000).round()));
    setState(() {
      _skipIntroDismissed = true;
      _showSkipIntro = false;
    });
  }

  void _skipOutroOrNext() {
    if (_isTv) {
      _playNextEpisode();
    } else {
      final dur = _player?.state.duration ?? Duration.zero;
      _player?.seek(dur);
      setState(() {
        _nextDismissed = true;
        _showNextPrompt = false;
      });
    }
  }

  void _playNextEpisode() {
    final season = widget.temporada ?? 1;
    final nextEp = (widget.capitulo ?? 1) + 1;
    final tmdbId = widget.tmdbId ?? widget.idcontenido;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: ServidoresModal(
            idcontenido: widget.idcontenido,
            tmdbId: tmdbId,
            temporada: season,
            capitulo: nextEp,
            tipo: 'tv',
            titulo: widget.titulo,
            backdropUrl: _backdropUrl,
            fromPlayer: true,
          ),
        ),
      ),
    );
  }

  void _changeServer() {
    final tmdbId = widget.tmdbId ?? widget.idcontenido;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: ServidoresModal(
            idcontenido: widget.idcontenido,
            tmdbId: tmdbId,
            temporada: widget.temporada,
            capitulo: widget.capitulo,
            tipo: widget.tipo,
            titulo: widget.titulo,
            backdropUrl: _backdropUrl,
            fromPlayer: true,
          ),
        ),
      ),
    );
  }

  // ─── Controls helpers ──────────────────────────────────────────────────

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _showControls && !(_player?.state.playing == false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    if (p.state.playing) {
      p.pause();
    } else {
      p.play();
      _scheduleHide();
    }
    setState(() {});
  }

  void _seekRelative(int seconds) {
    final p = _player;
    if (p == null) return;
    var target = p.state.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final dur = p.state.duration;
    if (dur > Duration.zero && target > dur) target = dur;
    p.seek(target);
    _scheduleHide();
  }

  Future<void> _toggleHw() async {
    final url = _playUrl ?? widget.videoUrl.trim();
    if (url.isEmpty) return;
    final pos = _player?.state.position ?? Duration.zero;
    final mediaHeaders = _usingProxy ? <String, String>{} : _headers();

    _createPlayer(hw: !_useHwAccel);
    setState(() => _loading = true);
    try {
      await _player!.open(Media(url, httpHeaders: mediaHeaders), play: false);
      await _applyDemuxerTuning();
      try {
        await _player!.setVideoTrack(VideoTrack.auto());
      } catch (_) {}
      try {
        await _player!.setAudioTrack(AudioTrack.auto());
      } catch (_) {}
      if (pos > const Duration(seconds: 2)) {
        await _player!.seek(pos);
      }
      await _player!.play();
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = true;
        _errorMsg = e.toString();
      });
    }
  }

  void _toggleBottomPanel() {
    setState(() => _showBottomPanel = !_showBottomPanel);
    if (_showBottomPanel) {
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = _player;
    final vc = _videoController;

    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) {
          if (!_showControls) setState(() => _showControls = true);
          _scheduleHide();
        },
        child: GestureDetector(
          onTap: _toggleControls,
          onDoubleTapDown: (d) {
            final w = MediaQuery.sizeOf(context).width;
            if (d.localPosition.dx < w / 2) {
              _seekRelative(-10);
            } else {
              _seekRelative(10);
            }
          },
          behavior: HitTestBehavior.opaque,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Vídeo
              if (vc != null && !_error)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Video(
                      controller: vc,
                      controls: NoVideoControls,
                      fill: Colors.black,
                      fit: _currentBoxFit,
                      alignment: Alignment.center,
                    ),
                  ),
                ),

              // Backdrop mientras carga / error
              if ((_loading || _error) &&
                  _backdropUrl != null &&
                  _backdropUrl!.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: _backdropUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) =>
                      const ColoredBox(color: Colors.black),
                ),
              if ((_loading || _error) && _backdropUrl != null)
                const ColoredBox(color: Colors.black54),

              if (_loading)
                const Center(
                  child: CircularProgressIndicator(color: _kAccent),
                ),

              if (_error)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _errorMsg ?? 'No se pudo reproducir',
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _kAccent,
                        ),
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = false;
                          });
                          _initPlayer();
                        },
                        child: const Text('Reintentar'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                        ),
                        onPressed: _changeServer,
                        child: const Text('Cambiar servidor'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          'Volver',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_showSkipIntro && !_loading && !_error)
                Positioned(
                  right: 32,
                  bottom: _showBottomPanel ? 270 : 100,
                  child: _ActionChip(
                    label: 'Omitir intro',
                    icon: Icons.skip_next,
                    onTap: _skipIntro,
                  ),
                ),

              if (_showNextPrompt && !_loading && !_error)
                Positioned(
                  right: 32,
                  bottom: _showBottomPanel ? 270 : 100,
                  child: _ActionChip(
                    label: _isTv ? 'Siguiente capítulo' : 'Omitir créditos',
                    icon: Icons.skip_next,
                    onTap: _skipOutroOrNext,
                    onDismiss: () {
                      setState(() {
                        _nextDismissed = true;
                        _showNextPrompt = false;
                      });
                    },
                  ),
                ),

              if (_showControls && !_loading && !_error && p != null)
                _buildControls(p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(Player p) {
    final pos = p.state.position;
    final dur = p.state.duration;
    final playing = p.state.playing;

    final double maxMs =
        dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    final double rawPos = pos.inMilliseconds.toDouble();
    final double value =
        (_seeking ? _seekValue : rawPos).clamp(0.0, maxMs).toDouble();

    return Stack(
      children: [
        // Gradientes
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.75),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 150,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withOpacity(0.9),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),

        // Barra superior
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                Expanded(
                  child: Row(
                    children: [
                      if (_logoUrl != null && _logoUrl!.isNotEmpty) ...[
                        CachedNetworkImage(
                          imageUrl: _logoUrl!,
                          height: 30,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          errorWidget: (_, __, ___) => Text(
                            _displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ] else
                        Flexible(
                          child: Text(
                            _displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (_isTv && widget.temporada != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          'T$_selectedSeasonNumber · E${widget.capitulo ?? 1}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Ajustar imagen: $_fitModeLabel',
                  onPressed: _cycleFitMode,
                  icon: Icon(_fitModeIcon, color: Colors.white70),
                ),
                if (_isTv && _temporadas.isNotEmpty)
                  IconButton(
                    tooltip: 'Capítulos',
                    onPressed: _toggleBottomPanel,
                    icon: Icon(
                      Icons.playlist_play_rounded,
                      color: _showBottomPanel ? _kAccent : Colors.white70,
                    ),
                  ),
                IconButton(
                  tooltip: _isFullscreen
                      ? 'Salir de pantalla completa'
                      : 'Pantalla completa',
                  onPressed: _toggleFullscreen,
                  icon: Icon(
                    _isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white70,
                  ),
                ),
                IconButton(
                  tooltip: _useHwAccel
                      ? 'Probar software decode'
                      : 'Probar hardware decode',
                  onPressed: _toggleHw,
                  icon: Icon(
                    _useHwAccel ? Icons.memory : Icons.developer_board,
                    color: Colors.white70,
                  ),
                ),
                IconButton(
                  onPressed: _changeServer,
                  icon: const Icon(Icons.dns_outlined, color: Colors.white70),
                ),
                if (_isTv)
                  IconButton(
                    onPressed: _playNextEpisode,
                    icon: const Icon(Icons.skip_next, color: Colors.white70),
                  ),
              ],
            ),
          ),
        ),

        // Centro play / seek
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoundBtn(
                icon: Icons.replay_10,
                size: 44,
                onTap: () => _seekRelative(-10),
              ),
              const SizedBox(width: 28),
              _RoundBtn(
                icon: playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
                size: 68,
                onTap: _togglePlay,
              ),
              const SizedBox(width: 28),
              _RoundBtn(
                icon: Icons.forward_10,
                size: 44,
                onTap: () => _seekRelative(10),
              ),
            ],
          ),
        ),

        // Panel episodios
        if (_showBottomPanel && _isTv && _temporadas.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 70,
            child: _buildEpisodesPanel(),
          ),

        // Barra de progreso
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      _fmt(Duration(milliseconds: value.round())),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: _kAccent,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: _kAccent,
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        min: 0.0,
                        max: maxMs,
                        value: value,
                        onChangeStart: (_) => setState(() => _seeking = true),
                        onChanged: (v) => setState(() => _seekValue = v),
                        onChangeEnd: (v) {
                          setState(() => _seeking = false);
                          p.seek(Duration(milliseconds: v.round()));
                          _scheduleHide();
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      _fmt(dur),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodesPanel() {
    return Container(
      height: 190,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.85),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              itemCount: _temporadas.length,
              itemBuilder: (ctx, i) {
                final temp = _temporadas[i] as Map;
                final num = temp['numero'] as int;
                final isSelected = num == _selectedSeasonNumber;
                return GestureDetector(
                  onTap: () => _selectSeason(num),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? _kAccent.withOpacity(0.2)
                          : Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isSelected ? _kAccent : Colors.transparent,
                        width: 1.2,
                      ),
                    ),
                    child: Text(
                      temp['nombre']?.toString() ?? 'Temporada $num',
                      style: TextStyle(
                        color: isSelected ? _kAccent : Colors.white70,
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _loadingEpisodes
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: _kAccent,
                        strokeWidth: 2.4,
                      ),
                    ),
                  )
                : _episodiosTemporada.isEmpty
                    ? const Center(
                        child: Text(
                          'Sin episodios',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _episodiosTemporada.length,
                        itemBuilder: (ctx, i) {
                          final ep = _episodiosTemporada[i] as Map;
                          final num = ep['numero'];
                          final titulo = ep['titulo']?.toString() ?? '';
                          final still = ep['still_path']?.toString();
                          final stillUrl = (still != null && still.isNotEmpty)
                              ? 'https://image.tmdb.org/t/p/w300$still'
                              : null;
                          final isActual = _isTv &&
                              _selectedSeasonNumber ==
                                  (widget.temporada ?? -1) &&
                              num == (widget.capitulo ?? -1);

                          return GestureDetector(
                            onTap: () {
                              if (num is int) {
                                _playEpisode(_selectedSeasonNumber, num);
                              }
                            },
                            child: Container(
                              width: 160,
                              margin: const EdgeInsets.only(right: 10, top: 8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isActual
                                      ? _kAccent
                                      : Colors.transparent,
                                  width: 1.5,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (stillUrl != null)
                                      CachedNetworkImage(
                                        imageUrl: stillUrl,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, __, ___) =>
                                            ColoredBox(
                                          color: Colors.grey[900]!,
                                        ),
                                      )
                                    else
                                      ColoredBox(color: Colors.grey[900]!),
                                    const DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.transparent,
                                            Color(0xD9000000),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (isActual)
                                      const Positioned(
                                        top: 4,
                                        left: 4,
                                        child: Icon(
                                          Icons.play_circle_fill,
                                          color: _kAccent,
                                          size: 18,
                                        ),
                                      ),
                                    Positioned(
                                      bottom: 5,
                                      left: 6,
                                      right: 6,
                                      child: Text(
                                        '$num · $titulo',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets auxiliares ──────────────────────────────────────────────────

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  const _RoundBtn({
    required this.icon,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.75),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              if (onDismiss != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onDismiss,
                  child: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 18,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}