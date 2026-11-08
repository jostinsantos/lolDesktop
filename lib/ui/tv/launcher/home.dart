import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/repo_prefs.dart';
import '../../../data/services/content_service.dart';
import '../../../data/services/settings_service.dart';
import '../../../data/models/repo_manifest.dart';
import '../repo/main_home.dart';
import 'comunidad_repos.dart';
import 'config.dart';
import 'buscar.dart';
import '../widgets/focusable.dart';
import '../widgets/glass.dart';
import '../repo/player/player.dart';
import 'downloads_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  TMDB (fondos)
// ─────────────────────────────────────────────────────────────────────────────

class _Tmdb {
  static const _key = 'a2d9bbed370d9f678e34006f8750a5a5';
  static const _base = 'https://api.themoviedb.org/3';

  static Future<Map<String, dynamic>?> _get(String path,
      [Map<String, String> q = const {}]) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse('$_base$path')
          .replace(queryParameters: {'api_key': _key, ...q});
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<String>> backdrops() async {
    final rnd = Random();
    final page = '${1 + rnd.nextInt(3)}';
    final lists = await Future.wait([
      _get('/movie/top_rated', {'page': page}),
      _get('/tv/top_rated', {'page': page}),
      _get('/movie/now_playing'),
      _get('/tv/on_the_air'),
    ]);
    const types = ['movie', 'tv', 'movie', 'tv'];
    final cands = <MapEntry<String, int>>[];
    for (var i = 0; i < lists.length; i++) {
      final res = lists[i]?['results'];
      if (res is! List) continue;
      for (final r in res.take(12)) {
        if (r is Map && r['id'] is int) {
          cands.add(MapEntry(types[i], r['id'] as int));
        }
      }
    }
    cands.shuffle(rnd);
    final picked = cands.take(18).toList();
    final urls = await Future.wait(picked.map((c) async {
      final j = await _get(
          '/${c.key}/${c.value}/images', {'include_image_language': 'null'});
      final raw = j?['backdrops'];
      if (raw is! List) return null;
      final bd = raw
          .whereType<Map>()
          .where((b) =>
              b['iso_639_1'] == null &&
              ((b['width'] as num?) ?? 0) >= 1280)
          .toList();
      if (bd.isEmpty) return null;
      bd.sort((a, b) => ((b['vote_average'] as num?) ?? 0)
          .compareTo((a['vote_average'] as num?) ?? 0));
      final path = bd.first['file_path'];
      // w1280 = buena calidad HD para fondos rotativos (original es demasiado pesado)
      return path is String ? 'https://image.tmdb.org/t/p/w1280$path' : null;
    }));
    return urls.whereType<String>().toSet().toList()..shuffle(rnd);
  }
}

class _TmdbBackground extends StatefulWidget {
  final double dim;
  final HomeBgMode mode;
  final String fixedUrl;
  final double blur;
  const _TmdbBackground({
    this.dim = 0,
    this.mode = HomeBgMode.tmdb,
    this.fixedUrl = '',
    this.blur = 16,
  });
  @override
  State<_TmdbBackground> createState() => _TmdbBackgroundState();
}

class _TmdbBackgroundState extends State<_TmdbBackground> {
  static List<String>? _cachedTmdb;
  static List<String>? _cachedLol;
  static const Duration interval = Duration(seconds: 14);
  List<String> _urls = const [];
  int _idx = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _TmdbBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode ||
        oldWidget.fixedUrl != widget.fixedUrl) {
      _timer?.cancel();
      _init();
    }
  }

  Future<void> _init() async {
    final mode = widget.mode;
    if (mode == HomeBgMode.fixed || mode == HomeBgMode.custom) {
      final url = widget.fixedUrl.trim();
      if (url.isEmpty) {
        if (mounted) setState(() => _urls = const []);
        return;
      }
      try {
        await precacheImage(CachedNetworkImageProvider(url), context);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _urls = [url];
        _idx = 0;
      });
      return;
    }

    List<String> urls;
    if (mode == HomeBgMode.lol) {
      urls = _cachedLol ?? await _loadLolBackdrops();
      if (urls.isNotEmpty) _cachedLol = urls;
    } else {
      urls = _cachedTmdb ?? await _Tmdb.backdrops();
      if (urls.isNotEmpty) _cachedTmdb = urls;
    }
    if (!mounted || urls.isEmpty) return;
    try {
      await precacheImage(CachedNetworkImageProvider(urls.first), context);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _urls = urls;
      _idx = 0;
    });
    _timer?.cancel();
    if (urls.length > 1) {
      _timer = Timer.periodic(interval, (_) => _next());
    }
  }

  Future<List<String>> _loadLolBackdrops() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(
          'https://raw.githubusercontent.com/LOLapptv/addons/main/backdrop_manifest.json'));
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        client.close(force: true);
        return [];
      }
      final body = await res.transform(utf8.decoder).join();
      client.close(force: true);
      final j = jsonDecode(body);
      if (j is! Map) return [];
      final cats = j['categories'];
      if (cats is! List) return [];
      final out = <String>[];
      for (final c in cats) {
        if (c is! Map) continue;
        final items = c['items'];
        if (items is! List) continue;
        for (final u in items) {
          if (u is String && u.startsWith('http')) out.add(u);
        }
      }
      out.shuffle(Random());
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> _next() async {
    if (!mounted || _urls.length < 2) return;
    final n = (_idx + 1) % _urls.length;
    try {
      await precacheImage(CachedNetworkImageProvider(_urls[n]), context);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _idx = n);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const tint = Color(0xFF0E1E3A);
    final blur = widget.blur.clamp(0.0, 40.0);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1B3358), Color(0xFF0A1424)],
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 1600),
            child: _urls.isEmpty
                ? const SizedBox.shrink(key: ValueKey('none'))
                : SizedBox.expand(
                    key: ValueKey(_urls[_idx]),
                    child: blur > 0.5
                        ? ImageFiltered(
                            imageFilter: ImageFilter.blur(
                                sigmaX: blur, sigmaY: blur, tileMode: TileMode.clamp),
                            child: CachedNetworkImage(
                              imageUrl: _urls[_idx],
                              fit: BoxFit.cover,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              errorWidget: (_, __, ___) => const SizedBox.shrink(),
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: _urls[_idx],
                            fit: BoxFit.cover,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            errorWidget: (_, __, ___) => const SizedBox.shrink(),
                          ),
                  ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tint.withValues(alpha: 0.30 + widget.dim),
                  tint.withValues(alpha: 0.38 + widget.dim),
                  Colors.black.withValues(alpha: 0.62 + widget.dim * 0.5),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  LAUNCHER
// ─────────────────────────────────────────────────────────────────────────────

class LauncherHome extends StatefulWidget {
  const LauncherHome({super.key});
  @override
  State<LauncherHome> createState() => _LauncherHomeState();
}

class _LauncherHomeState extends State<LauncherHome> {
  final _focusScope = FocusScopeNode();
  final Map<String, List<Map<String, dynamic>>> _newsByRepo = {};
  final Map<String, String> _repoNames = {};
  final Map<String, String> _repoNewsStyle = {};
  bool _loadingNews = false;

  /// false = vista principal (historial + dock), true = vista de novedades
  bool _newsMode = false;
  final FocusNode _dockFocus = FocusNode(debugLabel: 'dock_first');
  final FocusNode _newsFirstFocus = FocusNode(debugLabel: 'news_first');
  final FocusNode _historyFirstFocus = FocusNode(debugLabel: 'history_first');
  final FocusNode _toolsFirstFocus = FocusNode(debugLabel: 'tools_first');

  RepoManager? _manager;
  String _lastRepoSignature = '';
  bool _loadingNewsJob = false;
  int _newsGen = 0;

  final Map<String, Map<String, dynamic>> _playerHistorial = {};

  static const String _continueIndexKey = 'continue_watching_index';
  static const String _favAppsKey = 'launcher_favorite_apps';

  Set<String> _favAppIds = {};

  /// Long-press 3 s en remoto para favoritos (no abrir repo).
  Timer? _appLongPressTimer;
  bool _appLongPressFired = false;
  String? _appLongPressRepoId;

  /// Hay ítems de historial visibles (para ↑ desde apps).
  bool _hasHistory = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _manager = context.read<RepoManager>();
      _manager?.addListener(_onReposChanged);
      _lastRepoSignature = _repoSignature(_manager);
      _loadFavoriteApps();
      _loadPlayerHistorial();
      _loadNews();
      // Foco inicial: primera app del dock
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dockFocus.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _appLongPressTimer?.cancel();
    _manager?.removeListener(_onReposChanged);
    _dockFocus.dispose();
    _newsFirstFocus.dispose();
    _historyFirstFocus.dispose();
    _toolsFirstFocus.dispose();
    _focusScope.dispose();
    super.dispose();
  }

  String _repoSignature(RepoManager? m) {
    if (m == null) return '';
    final ids = m.enabled.map((r) => r.manifest.id).toList()..sort();
    return ids.join('|');
  }

  void _onReposChanged() {
    if (!mounted) return;
    final sig = _repoSignature(_manager);
    if (sig == _lastRepoSignature) return;
    _lastRepoSignature = sig;
    _loadNews(forceRefresh: false);
  }

  Future<void> _loadFavoriteApps() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_favAppsKey) ?? const <String>[];
      if (!mounted) return;
      setState(() => _favAppIds = list.toSet());
    } catch (_) {}
  }

  Future<void> _toggleFavoriteApp(String repoId) async {
    final next = Set<String>.from(_favAppIds);
    if (next.contains(repoId)) {
      next.remove(repoId);
    } else {
      next.add(repoId);
    }
    setState(() => _favAppIds = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_favAppsKey, next.toList());
    } catch (_) {}
  }

  Future<void> _showAppFavoriteDialog(InstalledRepo repo) async {
    final id = repo.manifest.id;
    final isFav = _favAppIds.contains(id);
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
            title: Text(
              isFav ? 'Quitar de favoritos' : 'Añadir a favoritos',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: Text(
              isFav
                  ? '¿Quitar "${repo.manifest.name}" del inicio de aplicaciones?'
                  : '¿Colocar "${repo.manifest.name}" al inicio de aplicaciones?',
              style: const TextStyle(color: Colors.white70),
            ),
            actionsAlignment: MainAxisAlignment.end,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar',
                    style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  isFav ? 'Quitar' : 'Favorito',
                  style: const TextStyle(
                    color: Color(0xFFE50914),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (ok == true && mounted) {
      await _toggleFavoriteApp(id);
    }
  }

  void _startAppLongPress(InstalledRepo repo) {
    _appLongPressTimer?.cancel();
    _appLongPressFired = false;
    _appLongPressRepoId = repo.manifest.id;
    _appLongPressTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_appLongPressRepoId == repo.manifest.id) {
        _appLongPressFired = true;
        _showAppFavoriteDialog(repo);
      }
    });
  }

  void _cancelAppLongPress(
      {required InstalledRepo repo, required bool openIfShort}) {
    _appLongPressTimer?.cancel();
    _appLongPressTimer = null;
    final wasShort =
        !_appLongPressFired && _appLongPressRepoId == repo.manifest.id;
    _appLongPressRepoId = null;
    if (openIfShort && wasShort) {
      _openRepo(repo);
    }
    _appLongPressFired = false;
  }

  Future<void> _loadPlayerHistorial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getStringList(_continueIndexKey) ?? const <String>[];
      final map = <String, Map<String, dynamic>>{};

      final keys = index.isNotEmpty
          ? index
          : prefs
              .getKeys()
              .where((k) => k.startsWith('continue_watch_'))
              .toList();

      for (final key in keys) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final m = Map<String, dynamic>.from(decoded);
          final repoId = (m['repoId'] ?? '').toString();
          final contentId = (m['contentId'] ?? '').toString();
          if (repoId.isEmpty || contentId.isEmpty) continue;

          final mapKey = '$repoId|$contentId';
          final existing = map[mapKey];
          if (existing == null) {
            map[mapKey] = m;
          } else {
            final tNew = (m['updatedAt'] ?? m['timestamp'] ?? '').toString();
            final tOld = (existing['updatedAt'] ?? existing['timestamp'] ?? '')
                .toString();
            if (tNew.compareTo(tOld) >= 0) {
              map[mapKey] = m;
            }
          }
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _playerHistorial
          ..clear()
          ..addAll(map);
      });
    } catch (e) {
      debugPrint('[Launcher] loadPlayerHistorial: $e');
    }
  }

  Map<String, dynamic>? _playerEntry(String repoId, String contentId) {
    return _playerHistorial['$repoId|$contentId'];
  }

  List<WatchEntry> _dedupeWatching(List<WatchEntry> watching) {
    final seen = <String>{};
    final out = <WatchEntry>[];
    for (final e in watching) {
      final key = '${e.repoId}|${e.contentId}';
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(e);
    }
    return out;
  }

  double _progressOf(WatchEntry e) {
    final pe = _playerEntry(e.repoId, e.contentId);
    if (pe != null) {
      final pos = (pe['positionMs'] as num?)?.toInt() ??
          (((pe['segundo'] as num?)?.toInt() ?? 0) * 1000);
      final dur = (pe['durationMs'] as num?)?.toInt() ??
          (((pe['duration'] as num?)?.toInt() ??
                  (pe['durationSec'] as num?)?.toInt() ??
                  0) *
              1000);
      if (pos > 0 && dur > 0) return (pos / dur).clamp(0.0, 1.0);
    }
    try {
      final p = e.progress;
      if (p > 0) return p.clamp(0.0, 1.0);
    } catch (_) {}
    return 0;
  }

  String? _resumeCodeOf(WatchEntry e) {
    final pe = _playerEntry(e.repoId, e.contentId);
    int? se;
    int? ep;
    if (pe != null) {
      se = (pe['season'] as num?)?.toInt() ??
          (pe['temporada'] as num?)?.toInt();
      ep = (pe['episode'] as num?)?.toInt() ??
          (pe['episodio'] as num?)?.toInt();
    }
    if (se == null || ep == null) {
      try {
        final d = e as dynamic;
        if (d.season is int) se = d.season as int;
        if (d.episode is int) ep = d.episode as int;
      } catch (_) {}
    }
    if (se == null || ep == null) return null;
    return 'T$se · E$ep';
  }

  String? _episodeTitleOf(WatchEntry e) {
    final pe = _playerEntry(e.repoId, e.contentId);
    if (pe != null) {
      final t = (pe['episodeTitle'] ?? '').toString().trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  String? _imageOf(WatchEntry e) {
    final pe = _playerEntry(e.repoId, e.contentId);
    if (pe != null) {
      for (final k in ['backdrop', 'poster', 'logo']) {
        final v = (pe[k] ?? '').toString();
        if (v.startsWith('http')) return v;
      }
    }
    return e.poster;
  }

  String _titleOf(WatchEntry e) {
    final pe = _playerEntry(e.repoId, e.contentId);
    if (pe != null) {
      final t = (pe['title'] ?? '').toString().trim();
      if (t.isNotEmpty) return t;
    }
    return e.title;
  }

  Future<void> _loadNews({bool forceRefresh = false}) async {
    if (_loadingNewsJob && !forceRefresh) return;
    _loadingNewsJob = true;
    final gen = ++_newsGen;
    final manager = context.read<RepoManager>();
    if (manager.enabled.isEmpty) {
      if (mounted && gen == _newsGen) {
        setState(() {
          _newsByRepo.clear();
          _repoNames.clear();
          _repoNewsStyle.clear();
          _loadingNews = false;
        });
      }
      _loadingNewsJob = false;
      return;
    }
    if (mounted) setState(() => _loadingNews = true);

    final byRepo = <String, List<Map<String, dynamic>>>{};
    final names = <String, String>{};
    final styles = <String, String>{};

    final results = await Future.wait(manager.enabled.map((repo) async {
      try {
        final items = await ContentService.instance
            .getNews(repo, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 12),
                onTimeout: () => const <Map<String, dynamic>>[]);
        if (items.isEmpty) return null;
        final id = repo.manifest.id;
        return (
          id: id,
          name: repo.manifest.name,
          style: repo.manifest.newsImageStyle,
          items: items.take(14).map((n) {
            return {...n, '_repoName': repo.manifest.name, '_repoId': id};
          }).toList(),
        );
      } catch (_) {
        return null;
      }
    }));
    for (final r in results) {
      if (r == null) continue;
      names[r.id] = r.name;
      styles[r.id] = r.style;
      byRepo[r.id] = r.items;
    }

    if (!mounted || gen != _newsGen) {
      _loadingNewsJob = false;
      return;
    }
    setState(() {
      _newsByRepo
        ..clear()
        ..addAll(byRepo);
      _repoNames
        ..clear()
        ..addAll(names);
      _repoNewsStyle
        ..clear()
        ..addAll(styles);
      _loadingNews = false;
    });
    _loadingNewsJob = false;
  }

  String _styleForItem(String repoId, Map n) {
    final raw = (n['imageStyle'] ?? n['style'] ?? n['card'] ?? n['layout'] ?? '')
        .toString()
        .toLowerCase();
    if (raw.contains('banner') ||
        raw.contains('back') ||
        raw.contains('horizontal') ||
        raw == 'wide') {
      return 'banner';
    }
    if (raw.contains('poster') || raw.contains('vertical')) return 'poster';
    return _repoNewsStyle[repoId] ?? 'poster';
  }

  String _imageForNews(Map n, String style) {
    if (style == 'banner') {
      final v =
          (n['banner'] ?? n['backdrop'] ?? n['image'] ?? n['poster'] ?? '')
              .toString();
      if (v.isNotEmpty) return v;
    }
    return (n['poster'] ?? n['image'] ?? n['backdrop'] ?? n['banner'] ?? '')
        .toString();
  }

  void _openRepo(InstalledRepo repo) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RepoMainHome(repo: repo)));
  }

  Future<void> _openContinue(WatchEntry e) async {
    final manager = context.read<RepoManager>();
    final prefs = context.read<RepoPrefs>();
    InstalledRepo? repo;
    for (final r in manager.installed) {
      if (r.manifest.id == e.repoId) {
        repo = r;
        break;
      }
    }
    if (repo == null) return;
    final lang = prefs.preferredLanguage(repo.manifest.id);

    final pe = _playerEntry(e.repoId, e.contentId) ??
        await _loadOneHistorial(e.repoId, e.contentId);

    final title = (pe?['title'] ?? e.title).toString();
    final poster = (pe?['poster'] ?? e.poster)?.toString();
    final backdrop = (pe?['backdrop'] ?? pe?['poster'] ?? e.poster)?.toString();
    final logo = (pe?['logo'] ?? '')?.toString();
    final type = (pe?['type'] ?? pe?['contentType'] ?? e.type).toString();
    final pos = (pe?['positionMs'] as num?)?.toInt() ??
        (((pe?['segundo'] as num?)?.toInt() ?? 0) * 1000);
    final startMs = pos > 0 ? pos : e.positionMs;

    final season = (pe?['season'] as num?)?.toInt() ??
        (pe?['temporada'] as num?)?.toInt();
    final episode = (pe?['episode'] as num?)?.toInt() ??
        (pe?['episodio'] as num?)?.toInt();
    final episodeTitle = (pe?['episodeTitle'] ?? '').toString();
    final nextSeason = (pe?['nextSeason'] as num?)?.toInt();
    final nextEpisode = (pe?['nextEpisode'] as num?)?.toInt();
    final nextEpisodeId = pe?['nextEpisodeId']?.toString();
    final nextEpisodeTitle = pe?['nextEpisodeTitle']?.toString();

    List<Map<String, dynamic>> episodeList = const [];
    final rawList = pe?['episodeList'];
    if (rawList is List) {
      episodeList = rawList
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        title: title,
        url: '',
        repoId: e.repoId,
        contentId: e.contentId,
        poster: poster,
        backdrop: backdrop?.isNotEmpty == true ? backdrop : null,
        logo: logo != null && logo.isNotEmpty ? logo : null,
        contentType: type,
        startPositionMs: startMs,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle.isNotEmpty ? episodeTitle : null,
        nextSeason: nextSeason,
        nextEpisode: nextEpisode,
        nextEpisodeId: nextEpisodeId,
        nextEpisodeTitle: nextEpisodeTitle,
        episodeList: episodeList,
        loadRepo: repo,
        preferredLanguage: lang,
        isTv: true,
      ),
    ));

    if (mounted) await _loadPlayerHistorial();
  }

  Future<Map<String, dynamic>?> _loadOneHistorial(
      String repoId, String contentId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'continue_watch_${repoId}_$contentId';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final m = Map<String, dynamic>.from(decoded);
        _playerHistorial['$repoId|$contentId'] = m;
        return m;
      }
    } catch (_) {}
    return null;
  }

  List<InstalledRepo> _orderedApps(List<InstalledRepo> apps) {
    final favs = <InstalledRepo>[];
    final rest = <InstalledRepo>[];
    for (final a in apps) {
      if (_favAppIds.contains(a.manifest.id)) {
        favs.add(a);
      } else {
        rest.add(a);
      }
    }
    return [...favs, ...rest];
  }

  bool _pageSwitching = false;

  /// Transición vertical SOLO aquí (no hay PageView → el foco no mueve scroll).
  Future<void> _goNews() async {
    if (_newsMode || _pageSwitching) return;
    _pageSwitching = true;
    setState(() => _newsMode = true);
    await Future<void>.delayed(const Duration(milliseconds: 380));
    if (!mounted) {
      _pageSwitching = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _newsFirstFocus.requestFocus();
    });
    _pageSwitching = false;
  }

  Future<void> _goHome() async {
    if (!_newsMode || _pageSwitching) return;
    _pageSwitching = true;
    setState(() => _newsMode = false);
    await Future<void>.delayed(const Duration(milliseconds: 380));
    if (!mounted) {
      _pageSwitching = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dockFocus.requestFocus();
    });
    _pageSwitching = false;
  }

  /// Solo KeyDown de flecha abajo (no KeyRepeat ni otras teclas).
  bool _isArrowDownPress(KeyEvent e) =>
      e is KeyDownEvent &&
      e is! KeyRepeatEvent &&
      e.logicalKey == LogicalKeyboardKey.arrowDown;

  bool _isArrowUpPress(KeyEvent e) =>
      e is KeyDownEvent &&
      e is! KeyRepeatEvent &&
      e.logicalKey == LogicalKeyboardKey.arrowUp;

  bool _isArrowLeftPress(KeyEvent e) =>
      e is KeyDownEvent &&
      e is! KeyRepeatEvent &&
      e.logicalKey == LogicalKeyboardKey.arrowLeft;

  bool _isArrowRightPress(KeyEvent e) =>
      e is KeyDownEvent &&
      e is! KeyRepeatEvent &&
      e.logicalKey == LogicalKeyboardKey.arrowRight;

  bool _isSelectKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.space;

  /// ↑ desde cualquier app del dock → primer ítem del historial (si hay).
  void _focusHistoryFromApps() {
    if (!_hasHistory || _newsMode || _pageSwitching) return;
    void tryFocus() {
      if (mounted && _historyFirstFocus.canRequestFocus) {
        _historyFirstFocus.requestFocus();
      }
    }
    tryFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
  }

  /// ↑ desde historial → primera herramienta del header.
  void _focusToolsFromHistory() {
    if (_newsMode || _pageSwitching) return;
    void tryFocus() {
      if (mounted && _toolsFirstFocus.canRequestFocus) {
        _toolsFirstFocus.requestFocus();
      }
    }
    tryFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
  }

  /// ↓ desde herramientas → historial (si hay) o dock.
  void _focusDownFromTools() {
    if (_newsMode || _pageSwitching) return;
    if (_hasHistory) {
      _focusHistoryFromApps();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dockFocus.requestFocus();
      });
      if (_dockFocus.canRequestFocus) _dockFocus.requestFocus();
    }
  }

  /// ↓ desde cualquier app del dock → primer ítem del primer slider de novedades.
  KeyEventResult _onDockKey(FocusNode node, KeyEvent e) {
    if (_pageSwitching || _newsMode) return KeyEventResult.ignored;
    if (_isArrowDownPress(e)) {
      unawaited(_goNews());
      return KeyEventResult.handled;
    }
    if (_isArrowUpPress(e)) {
      if (_hasHistory) {
        _focusHistoryFromApps();
      } else {
        _focusToolsFromHistory();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onFirstNewsKey(FocusNode node, KeyEvent e) {
    if (_pageSwitching || !_newsMode) return KeyEventResult.ignored;
    if (_isArrowUpPress(e)) {
      unawaited(_goHome());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onNewsBackKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || e is KeyRepeatEvent) return KeyEventResult.ignored;
    if (!_newsMode || _pageSwitching) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.goBack ||
        e.logicalKey == LogicalKeyboardKey.escape ||
        e.logicalKey == LogicalKeyboardKey.browserBack) {
      unawaited(_goHome());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<RepoManager>();
    final lib = context.watch<LibraryService>();
    final apps = _orderedApps(manager.enabled);
    final watching = _dedupeWatching(lib.continueWatchingAll());
    _hasHistory = watching.isNotEmpty;

    return PopScope(
      canPop: !_newsMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _newsMode) unawaited(_goHome());
      },
      child: FocusScope(
        node: _focusScope,
        child: Scaffold(
          backgroundColor: kTvBg,
          body: Stack(
            children: [
              Positioned.fill(
                child: Builder(
                  builder: (ctx) {
                    final s = ctx.watch<SettingsService>();
                    return _TmdbBackground(
                      dim: (_newsMode ? 0.18 : 0.0) + s.homeBgDim,
                      mode: s.homeBgMode,
                      fixedUrl: s.homeBgUrl,
                      blur: s.homeBgBlur,
                    );
                  },
                ),
              ),
              SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Home: se desliza hacia arriba al ir a novedades
                    AnimatedSlide(
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.easeOutCubic,
                      offset: _newsMode ? const Offset(0, -1) : Offset.zero,
                      child: IgnorePointer(
                        ignoring: _newsMode,
                        child: _homePage(apps, watching),
                      ),
                    ),
                    // Novedades: entra desde abajo solo con ↓ explícito
                    AnimatedSlide(
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.easeOutCubic,
                      offset: _newsMode ? Offset.zero : const Offset(0, 1),
                      child: IgnorePointer(
                        ignoring: !_newsMode,
                        child: _newsPage(),
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

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Clock(),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                _IconBtn(
                  Icons.search_rounded,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const GlobalSearchPage())),
                  focusNode: _toolsFirstFocus,
                  onArrowDown: _focusDownFromTools,
                  isFirst: true,
                ),
                const SizedBox(width: 10),
                _IconBtn(
                  Icons.public_rounded,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CommunityPage())),
                  onArrowDown: _focusDownFromTools,
                ),
                const SizedBox(width: 10),
                _IconBtn(
                  Icons.download_rounded,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const TvDownloadsPage())),
                  onArrowDown: _focusDownFromTools,
                ),
                const SizedBox(width: 10),
                _IconBtn(
                  Icons.settings_rounded,
                  () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const GlobalSettingsPage())),
                  onArrowDown: _focusDownFromTools,
                  isLast: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _homePage(List<InstalledRepo> apps, List<WatchEntry> watching) {
    return Column(
      children: [
        _header(),
        Expanded(
          child: Column(
            children: [
              const Spacer(),
              if (watching.isNotEmpty)
                SizedBox(
                  height: 110,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 8),
                    itemCount: watching.length.clamp(0, 18),
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, i) {
                      final e = watching[i];
                      final progress = _progressOf(e);
                      final code = _resumeCodeOf(e);
                      final epTitle = _episodeTitleOf(e);
                      final count = watching.length.clamp(0, 18);
                      final isFirst = i == 0;
                      final isLast = i == count - 1;
                      String? subtitle;
                      if (code != null) {
                        subtitle = epTitle != null && epTitle.isNotEmpty
                            ? '$code · $epTitle'
                            : code;
                      } else if (progress > 0.02) {
                        subtitle = '${(progress * 100).round()}%';
                      }
                      // ↑ historial → herramientas del header
                      // ↓ historial → primera app del dock
                      // ← / → en extremos se queda
                      // El focusNode va en el Focus externo; el visual usa
                      // Focus.of(ctx).hasFocus (no el Focusable interno).
                      return Focus(
                        focusNode: isFirst ? _historyFirstFocus : null,
                        onKeyEvent: (node, event) {
                          if (_isArrowUpPress(event)) {
                            _focusToolsFromHistory();
                            return KeyEventResult.handled;
                          }
                          if (_isArrowDownPress(event)) {
                            _dockFocus.requestFocus();
                            return KeyEventResult.handled;
                          }
                          if (isFirst && _isArrowLeftPress(event)) {
                            return KeyEventResult.handled;
                          }
                          if (isLast && _isArrowRightPress(event)) {
                            return KeyEventResult.handled;
                          }
                          if (event is KeyDownEvent &&
                              event is! KeyRepeatEvent &&
                              _isSelectKey(event.logicalKey)) {
                            _openContinue(e);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Builder(
                          builder: (ctx) {
                            final f = Focus.of(ctx).hasFocus;
                            return GestureDetector(
                              onTap: () => _openContinue(e),
                              child: _WideCard(
                                width: 158,
                                height: 88,
                                imageUrl: _imageOf(e),
                                title: _titleOf(e),
                                subtitle: subtitle,
                                progress: progress > 0.02 ? progress : null,
                                focused: f,
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              _dock(apps, compact: false, autofocusFirst: true),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ],
    );
  }

  Widget _newsPage() {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // Solo Back / Escape → home. ↑ NO global: solo el primer slider.
        return _onNewsBackKey(node, event);
      },
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24, top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _newsRows(),
        ),
      ),
    );
  }

  List<Widget> _newsRows() {
    if (_newsByRepo.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: _loadingNews
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: kTvAccent))
                : Text('Sin novedades',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13)),
          ),
        ),
      ];
    }
    final rows = <Widget>[];
    var entryIndex = 0;
    for (final entry in _newsByRepo.entries) {
      final repoId = entry.key;
      final items = entry.value;
      final repoName = _repoNames[repoId] ?? repoId;
      final defaultStyle = _repoNewsStyle[repoId] ?? 'poster';
      final isBanner = defaultStyle == 'banner';
      final rowH = isBanner ? 100.0 : 124.0;
      final isFirstRow = entryIndex == 0;
      entryIndex++;

      rows.add(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('NOVEDADES · $repoName'),
          SizedBox(
            height: rowH,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 6),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final n = items[i];
                final style = _styleForItem(repoId, n);
                final banner = style == 'banner';
                final title = (n['title'] ?? n['text'] ?? '').toString();
                final img = _imageForNews(n, style);
                final isFirstItem = i == 0;
                final isLastItem = i == items.length - 1;
                void openNews() {
                  final mgr = context.read<RepoManager>();
                  InstalledRepo? repo;
                  for (final r in mgr.installed) {
                    if (r.manifest.id == repoId) {
                      repo = r;
                      break;
                    }
                  }
                  if (repo != null) _openRepo(repo);
                }

                final isFirst = isFirstRow && i == 0;
                if (isFirst) {
                  // Primer ítem del primer slider: ↑ → apps
                  return Focus(
                    focusNode: _newsFirstFocus,
                    onKeyEvent: (node, event) {
                      final up = _onFirstNewsKey(node, event);
                      if (up == KeyEventResult.handled) return up;
                      if (isFirstItem && _isArrowLeftPress(event)) {
                        return KeyEventResult.handled;
                      }
                      if (isLastItem && _isArrowRightPress(event)) {
                        return KeyEventResult.handled;
                      }
                      if (event is KeyDownEvent) {
                        final k = event.logicalKey;
                        if (k == LogicalKeyboardKey.select ||
                            k == LogicalKeyboardKey.enter ||
                            k == LogicalKeyboardKey.space) {
                          openNews();
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Builder(
                      builder: (ctx) {
                        final f = Focus.of(ctx).hasFocus;
                        return GestureDetector(
                          onTap: openNews,
                          child: _NewsCard(
                            width: banner ? 150.0 : 78.0,
                            height: banner ? 84.0 : 108.0,
                            imageUrl: img.isEmpty ? null : img,
                            title: title.isNotEmpty ? title : 'Novedad',
                            focused: f,
                          ),
                        );
                      },
                    ),
                  );
                }
                // Resto del primer slider: ↑ también vuelve a apps
                // Otros sliders: ↑ NO vuelve (solo navegación normal entre filas)
                return Focus(
                  onKeyEvent: (node, event) {
                    if (isFirstRow && _isArrowUpPress(event)) {
                      unawaited(_goHome());
                      return KeyEventResult.handled;
                    }
                    if (isFirstItem && _isArrowLeftPress(event)) {
                      return KeyEventResult.handled;
                    }
                    if (isLastItem && _isArrowRightPress(event)) {
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Focusable(
                    autofocus: false,
                    onTap: openNews,
                    builder: (f) => _NewsCard(
                      width: banner ? 150.0 : 78.0,
                      height: banner ? 84.0 : 108.0,
                      imageUrl: img.isEmpty ? null : img,
                      title: title.isNotEmpty ? title : 'Novedad',
                      focused: f,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ));
    }
    return rows;
  }

  /// Dock centrado, ancho acotado, scrolleable. Solo iconos (sin título debajo).
  Widget _dock(List<InstalledRepo> apps,
      {required bool compact, required bool autofocusFirst}) {
    final icon = compact ? 40.0 : 48.0;
    final gap = 10.0;
    final hPad = 14.0;
    final vPad = 10.0;
    final dockH = icon + vPad * 2;
    final itemSlot = icon + gap;
    final contentW = (apps.length + 1) * itemSlot - gap + hPad * 2;

    return LayoutBuilder(builder: (context, c) {
      final maxW = (c.maxWidth * 0.55).clamp(200.0, c.maxWidth - 80);
      final w = contentW < maxW ? contentW : maxW;

      return Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              width: w,
              height: dockH,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                color: Colors.black.withValues(alpha: 0.32),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 1,
                ),
              ),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _onDockKey,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                      horizontal: hPad, vertical: vPad),
                  itemCount: apps.length + 1,
                  separatorBuilder: (_, __) => SizedBox(width: gap),
                  itemBuilder: (context, i) {
                    if (i == apps.length) {
                      return Focus(
                        onKeyEvent: (node, event) {
                          // ↓ → primer elemento del primer slider de novedades
                          if (_isArrowDownPress(event) && !_newsMode) {
                            unawaited(_goNews());
                            return KeyEventResult.handled;
                          }
                          // ↑ → historial (o herramientas si no hay historial)
                          if (_isArrowUpPress(event)) {
                            if (_hasHistory) {
                              _focusHistoryFromApps();
                            } else {
                              _focusToolsFromHistory();
                            }
                            return KeyEventResult.handled;
                          }
                          // Último ítem (Añadir): → se queda
                          if (_isArrowRightPress(event)) {
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Focusable(
                          autofocus: autofocusFirst && apps.isEmpty,
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const CommunityPage())),
                          builder: (f) => _AppIcon(
                            size: icon,
                            label: 'Añadir',
                            isAdd: true,
                            focused: f,
                          ),
                        ),
                      );
                    }
                    final repo = apps[i];
                    final isFav = _favAppIds.contains(repo.manifest.id);
                    final isFirstApp = i == 0;
                    if (isFirstApp) {
                      return Focus(
                        focusNode: _dockFocus,
                        onKeyEvent: (node, event) {
                          // ↓ → primer elemento del primer slider de novedades
                          if (_isArrowDownPress(event) && !_newsMode) {
                            unawaited(_goNews());
                            return KeyEventResult.handled;
                          }
                          // ↑ → historial (o herramientas si no hay historial)
                          if (_isArrowUpPress(event)) {
                            if (_hasHistory) {
                              _focusHistoryFromApps();
                            } else {
                              _focusToolsFromHistory();
                            }
                            return KeyEventResult.handled;
                          }
                          // ← en primera app → se queda
                          if (_isArrowLeftPress(event)) {
                            return KeyEventResult.handled;
                          }
                          // Long-press 3 s → favoritos; corta → abrir repo
                          if (event is KeyDownEvent &&
                              event is! KeyRepeatEvent &&
                              _isSelectKey(event.logicalKey)) {
                            _startAppLongPress(repo);
                            return KeyEventResult.handled;
                          }
                          if (event is KeyUpEvent &&
                              _isSelectKey(event.logicalKey)) {
                            _cancelAppLongPress(
                                repo: repo, openIfShort: true);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Builder(
                          builder: (ctx) {
                            final f = Focus.of(ctx).hasFocus;
                            return GestureDetector(
                              onTap: () => _openRepo(repo),
                              onLongPress: () =>
                                  _showAppFavoriteDialog(repo),
                              child: _AppIcon(
                                size: icon,
                                label: repo.manifest.name,
                                iconUrl: repo.manifest.icon,
                                focused: f,
                                favorite: isFav,
                              ),
                            );
                          },
                        ),
                      );
                    }
                    return Focus(
                      onKeyEvent: (node, event) {
                        // ↓ → novedades (primer ítem del primer slider)
                        if (_isArrowDownPress(event) && !_newsMode) {
                          unawaited(_goNews());
                          return KeyEventResult.handled;
                        }
                        // ↑ → historial (o herramientas si no hay historial)
                        if (_isArrowUpPress(event)) {
                          if (_hasHistory) {
                            _focusHistoryFromApps();
                          } else {
                            _focusToolsFromHistory();
                          }
                          return KeyEventResult.handled;
                        }
                        if (event is KeyDownEvent &&
                            event is! KeyRepeatEvent &&
                            _isSelectKey(event.logicalKey)) {
                          _startAppLongPress(repo);
                          return KeyEventResult.handled;
                        }
                        if (event is KeyUpEvent &&
                            _isSelectKey(event.logicalKey)) {
                          _cancelAppLongPress(
                              repo: repo, openIfShort: true);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Focusable(
                        autofocus: false,
                        onTap: () => _openRepo(repo),
                        builder: (f) => GestureDetector(
                          onLongPress: () => _showAppFavoriteDialog(repo),
                          child: _AppIcon(
                            size: icon,
                            label: repo.manifest.name,
                            iconUrl: repo.manifest.icon,
                            focused: f,
                            favorite: isFav,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 10, 28, 2),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.3)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Widgets
// ─────────────────────────────────────────────────────────────────────────────

class _FadeIn extends StatelessWidget {
  final Widget child;
  const _FadeIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 14), child: c),
      ),
      child: child,
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  String get _greeting {
    final h = _now.hour;
    if (h >= 6 && h < 12) return 'Buenos días';
    if (h >= 12 && h < 20) return 'Buenas tardes';
    return 'Buenas noches';
  }

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('HH:mm').format(_now);
    String date;
    try {
      date = DateFormat('EEEE d MMMM', 'es').format(_now).toUpperCase();
    } catch (_) {
      date = DateFormat('EEEE d MMMM').format(_now).toUpperCase();
    }
    const shadow = [Shadow(color: Colors.black38, blurRadius: 12)];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(time,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 48,
                height: 1.0,
                fontWeight: FontWeight.w200,
                shadows: shadow)),
        const SizedBox(width: 16),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(date,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      letterSpacing: 1.2,
                      shadows: shadow)),
              const SizedBox(height: 2),
              Text(
                _greeting,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.6,
                  shadows: shadow,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final VoidCallback? onArrowDown;
  final bool isFirst;
  final bool isLast;

  const _IconBtn(
    this.icon,
    this.onTap, {
    this.focusNode,
    this.onArrowDown,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent || event is KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.arrowDown) {
          onArrowDown?.call();
          return KeyEventResult.handled;
        }
        // ↑ en herramientas: no hay nada más arriba
        if (k == LogicalKeyboardKey.arrowUp) {
          return KeyEventResult.handled;
        }
        if (isFirst && k == LogicalKeyboardKey.arrowLeft) {
          return KeyEventResult.handled;
        }
        if (isLast && k == LogicalKeyboardKey.arrowRight) {
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.space) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final f = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: f
                    ? Colors.white.withValues(alpha: 0.28)
                    : Colors.black.withValues(alpha: 0.28),
                border: Border.all(
                  color: f ? Colors.white : Colors.white.withValues(alpha: 0.12),
                  width: f ? 2 : 1,
                ),
              ),
              child: Icon(icon,
                  size: 17, color: f ? Colors.white : Colors.white70),
            ),
          );
        },
      ),
    );
  }
}

/// Solo imagen + borde de foco. Sin título debajo (evita overflow).
class _AppIcon extends StatelessWidget {
  final double size;
  final String label;
  final String? iconUrl;
  final bool isAdd;
  final bool focused;
  final bool favorite;

  const _AppIcon({
    required this.size,
    required this.label,
    this.iconUrl,
    this.isAdd = false,
    required this.focused,
    this.favorite = false,
  });

  Widget _letter() => Center(
        child: Text(
          label.isNotEmpty ? label[0].toUpperCase() : '?',
          style: TextStyle(
            color: focused ? Colors.white : Colors.white54,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedScale(
        scale: focused ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 140),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.26),
            color: focused
                ? Colors.white.withValues(alpha: 0.18)
                : kTvCard.withValues(alpha: 0.9),
            border: Border.all(
              color: focused
                  ? Colors.white
                  : (favorite
                      ? kTvAccent.withValues(alpha: 0.85)
                      : Colors.transparent),
              width: focused ? 2.5 : (favorite ? 1.5 : 0),
            ),
            boxShadow: focused
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              isAdd
                  ? Icon(Icons.add_rounded,
                      size: size * 0.48,
                      color: focused ? Colors.white : Colors.white54)
                  : (iconUrl != null && iconUrl!.isNotEmpty)
                      ? CachedNetworkImage(
                          imageUrl: iconUrl!,
                          fit: BoxFit.cover,
                          memCacheWidth: 160,
                          errorWidget: (_, __, ___) => _letter(),
                        )
                      : _letter(),
              if (favorite && !isAdd)
                const Positioned(
                  right: 4,
                  top: 4,
                  child: Icon(Icons.star_rounded, size: 13, color: kTvAccent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Historial: título/subtítulo encima de la imagen. Foco = contorno.
class _WideCard extends StatelessWidget {
  final double width;
  final double height;
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double? progress;
  final bool focused;

  const _WideCard({
    required this.width,
    required this.height,
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.progress,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: focused ? 1.04 : 1.0,
      duration: const Duration(milliseconds: 120),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: focused ? Colors.white : Colors.white.withValues(alpha: 0.12),
            width: focused ? 2.5 : 1,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.28),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (imageUrl != null && imageUrl!.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: imageUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: (width * 2).round(),
                  errorWidget: (_, __, ___) => const ColoredBox(color: kTvCard),
                )
              else
                const ColoredBox(color: kTvCard),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x99000000),
                      Color(0x00000000),
                      Color(0xB3000000),
                    ],
                    stops: [0, 0.42, 1],
                  ),
                ),
              ),
              Positioned(
                left: 10,
                top: 8,
                right: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          shadows: const [
                            Shadow(color: Colors.black54, blurRadius: 3)
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (progress != null && progress! > 0.02)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.white24,
                    color: kTvAccent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Novedades: título encima de la imagen. Foco = solo contorno.
class _NewsCard extends StatelessWidget {
  final double width;
  final double height;
  final String? imageUrl;
  final String title;
  final bool focused;

  const _NewsCard({
    required this.width,
    required this.height,
    this.imageUrl,
    required this.title,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: focused ? 1.04 : 1.0,
      duration: const Duration(milliseconds: 120),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: focused
                ? Colors.white
                : Colors.white.withValues(alpha: 0.10),
            width: focused ? 2.5 : 1,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.28),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (imageUrl != null && imageUrl!.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: imageUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: (width * 2).round(),
                  errorWidget: (_, __, ___) =>
                      const ColoredBox(color: kTvCard),
                )
              else
                const ColoredBox(color: kTvCard),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xAA000000),
                      Color(0x00000000),
                      Color(0x99000000),
                    ],
                    stops: [0, 0.4, 1],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
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