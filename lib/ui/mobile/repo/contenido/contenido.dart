import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../../../data/services/settings_service.dart';
import '../../widgets/focusable.dart';
import '../player/player.dart';
import '../../widgets/cached_poster.dart';
import '../../../shared/download_sheet.dart';
import '../../../../data/services/download_service.dart';
import '../../../../data/models/stream_server.dart';

/// Ficha de contenido móvil — mismo historial / reanudar / barras que TV.
class DetailsPage extends StatefulWidget {
  final InstalledRepo repo;
  final String itemId;
  final int? season;
  final int? episode;

  const DetailsPage({
    super.key,
    required this.repo,
    required this.itemId,
    this.season,
    this.episode,
  });

  @override
  State<DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<DetailsPage> {
  ContentItem? _item;
  bool _loading = true;
  int _seasonIndex = 0;
  int? _selectedEpisode;
  int _episodePage = 0;

  /// Historial LibraryService para este contenido.
  List<WatchEntry> _history = [];

  /// Progreso por episodio (player SharedPreferences + library).
  final Map<String, _EpProgress> _epProgress = {};

  int? _lastSeason;
  int? _lastEpisode;
  int _lastPositionMs = 0;
  int _lastDurationMs = 0;

  static String _epKey(int se, int ep) => 'S${se}E$ep';

  bool get _useEpPagination =>
      widget.repo.manifest.episodesPagination &&
      widget.repo.manifest.episodesPerPage > 0;

  int get _epPerPage => widget.repo.manifest.episodesPerPage.clamp(1, 200);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _loadPlayerHistorial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'continue_watch_${widget.repo.manifest.id}_${widget.itemId}';
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);

      // Aceptar historial de player TV o móvil dual.
      final pid = (map['playerId'] ?? map['player'] ?? '').toString();
      if (pid.isNotEmpty &&
          pid != 'dual_player_hls_ts_v1' &&
          pid != 'dual_player_hls_ts_mobile_v1' &&
          !pid.contains('dual_player')) {
        // Otro player: igual usamos posición si coincide contentId.
      }

      final se = (map['season'] as num?)?.toInt() ??
          (map['temporada'] as num?)?.toInt();
      final ep = (map['episode'] as num?)?.toInt() ??
          (map['episodio'] as num?)?.toInt();
      final pos = (map['positionMs'] as num?)?.toInt() ??
          (((map['segundo'] as num?)?.toInt() ?? 0) * 1000);
      final dur = (map['durationMs'] as num?)?.toInt() ??
          (((map['duration'] as num?)?.toInt() ??
                  (map['durationSec'] as num?)?.toInt() ??
                  0) *
              1000);

      if (se != null && ep != null && pos > 0) {
        _lastSeason = se;
        _lastEpisode = ep;
        _lastPositionMs = pos;
        _lastDurationMs = dur > 0 ? dur : 0;
        final p = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
        _epProgress[_epKey(se, ep)] = _EpProgress(
          positionMs: pos,
          durationMs: dur,
          progress: p,
        );
      }

      final list = map['episodeList'];
      if (list is List) {
        for (final e in list) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final s2 = (m['season'] as num?)?.toInt();
          final e2 = (m['episode'] as num?)?.toInt() ??
              (m['number'] as num?)?.toInt();
          final pMs = (m['positionMs'] as num?)?.toInt();
          final dMs = (m['durationMs'] as num?)?.toInt();
          if (s2 == null || e2 == null || pMs == null || pMs <= 0) continue;
          final d = dMs ?? 0;
          _epProgress[_epKey(s2, e2)] = _EpProgress(
            positionMs: pMs,
            durationMs: d,
            progress: d > 0 ? (pMs / d).clamp(0.0, 1.0) : 0.0,
          );
        }
      }
    } catch (e) {
      debugPrint('[DetailsMobile] loadPlayerHistorial: $e');
    }
  }

  void _mergeLibraryHistory(List<WatchEntry> hist) {
    for (final e in hist) {
      final se = _entrySeason(e);
      final ep = _entryEpisode(e);
      if (se == null || ep == null) continue;
      final pos = e.positionMs;
      if (pos <= 0) continue;
      double p = 0;
      try {
        p = (e as dynamic).progress as double? ?? 0.0;
      } catch (_) {
        p = 0;
      }
      int dur = 0;
      try {
        final d = (e as dynamic).durationMs;
        if (d is int) dur = d;
      } catch (_) {}
      if (p <= 0 && dur > 0) p = (pos / dur).clamp(0.0, 1.0);
      final key = _epKey(se, ep);
      final existing = _epProgress[key];
      if (existing == null || pos >= existing.positionMs) {
        _epProgress[key] = _EpProgress(
          positionMs: pos,
          durationMs: dur > 0 ? dur : existing?.durationMs ?? 0,
          progress: p > 0 ? p : (existing?.progress ?? 0),
        );
      }
    }

    if (hist.isNotEmpty) {
      final h = hist.first;
      final se = _entrySeason(h);
      final ep = _entryEpisode(h);
      if (se != null && ep != null) {
        if (_lastSeason == null ||
            h.positionMs >= _lastPositionMs ||
            (_lastSeason == se && _lastEpisode == ep)) {
          _lastSeason = se;
          _lastEpisode = ep;
          _lastPositionMs = h.positionMs;
          try {
            final d = (h as dynamic).durationMs;
            if (d is int && d > 0) _lastDurationMs = d;
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _refreshHistoryAndFocus() async {
    if (!mounted) return;
    final lib = context.read<LibraryService>();
    final all = lib.continueWatching(widget.repo.manifest.id);
    final hist = all.where((e) => e.contentId == widget.itemId).toList();

    await _loadPlayerHistorial();
    _mergeLibraryHistory(hist);

    setState(() {
      _history = hist;
      final item = _item;
      if (item != null && item.seasons.isNotEmpty) {
        final se = _lastSeason;
        final ep = _lastEpisode;
        if (se != null) {
          final idx = item.seasons.indexWhere((s) => s.number == se);
          if (idx >= 0) _seasonIndex = idx;
        }
        if (ep != null) {
          _selectedEpisode = ep;
          if (_useEpPagination) {
            final eps = item.seasons[_seasonIndex].episodes;
            final i = eps.indexWhere((e) => e.number == ep);
            if (i >= 0) _episodePage = i ~/ _epPerPage;
          }
        }
      }
    });
  }

  Future<void> _load() async {
    final item = await ContentService.instance.getDetails(
      widget.repo,
      widget.itemId,
      season: widget.season,
      episode: widget.episode,
    );
    if (!mounted) return;

    final lib = context.read<LibraryService>();
    final all = lib.continueWatching(widget.repo.manifest.id);
    final hist = all.where((e) => e.contentId == widget.itemId).toList();

    await _loadPlayerHistorial();
    _mergeLibraryHistory(hist);

    setState(() {
      _item = item;
      _loading = false;
      _history = hist;

      if (item != null && item.seasons.isNotEmpty) {
        int? se = widget.season ?? _lastSeason;
        int? ep = widget.episode ?? _lastEpisode;
        if (se == null && ep == null && hist.isNotEmpty) {
          final h = hist.first;
          se = _entrySeason(h);
          ep = _entryEpisode(h);
        }
        if (se != null) {
          final idx = item.seasons.indexWhere((s) => s.number == se);
          _seasonIndex = idx >= 0 ? idx : 0;
        }
        _selectedEpisode = ep;
        if (_useEpPagination && ep != null) {
          final eps = item.seasons[_seasonIndex].episodes;
          final i = eps.indexWhere((e) => e.number == ep);
          if (i >= 0) _episodePage = i ~/ _epPerPage;
        }
      }
    });
  }

  int? _entrySeason(WatchEntry e) {
    try {
      final d = e as dynamic;
      final v = d.season;
      if (v is int) return v;
    } catch (_) {}
    return null;
  }

  int? _entryEpisode(WatchEntry e) {
    try {
      final d = e as dynamic;
      final v = d.episode;
      if (v is int) return v;
    } catch (_) {}
    return null;
  }

  WatchEntry? get _latestEntry => _history.isEmpty ? null : _history.first;

  double _progressForEpisode(int seasonNum, int epNum) {
    final p = _epProgress[_epKey(seasonNum, epNum)];
    if (p != null && p.progress > 0) return p.progress.clamp(0.0, 1.0);
    for (final e in _history) {
      if (_entrySeason(e) == seasonNum && _entryEpisode(e) == epNum) {
        try {
          final pr = (e as dynamic).progress;
          if (pr is num && pr > 0) return pr.toDouble().clamp(0.0, 1.0);
        } catch (_) {}
        final pos = e.positionMs;
        int dur = 0;
        try {
          final d = (e as dynamic).durationMs;
          if (d is int) dur = d;
        } catch (_) {}
        if (pos > 0 && dur > 0) return (pos / dur).clamp(0.0, 1.0);
      }
    }
    return 0;
  }

  int _positionMsForEpisode(int seasonNum, int epNum) {
    final p = _epProgress[_epKey(seasonNum, epNum)];
    if (p != null && p.positionMs > 0) return p.positionMs;
    for (final e in _history) {
      if (_entrySeason(e) == seasonNum && _entryEpisode(e) == epNum) {
        return e.positionMs;
      }
    }
    return 0;
  }

  int? get _selectedSeasonNumber {
    final item = _item;
    if (item == null || item.seasons.isEmpty) return null;
    if (_seasonIndex < 0 || _seasonIndex >= item.seasons.length) return null;
    return item.seasons[_seasonIndex].number;
  }

  String? _episodeTitle() {
    final item = _item;
    if (item == null || !item.isSeries || item.seasons.isEmpty) return null;
    final season = item.seasons[_seasonIndex];
    final ep =
        season.episodes.where((e) => e.number == _selectedEpisode).toList();
    return ep.isEmpty ? null : ep.first.title;
  }

  String _formatMinutes(int positionMs) {
    final totalSec = (positionMs / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final mm = m % 60;
      return '${h}h ${mm.toString().padLeft(2, '0')}m';
    }
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String? get _resumeCode {
    final se = _lastSeason;
    final ep = _lastEpisode;
    if (se == null || ep == null) return null;
    return 'S${se.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}';
  }

  /// Lista plana de TODOS los episodios de TODAS las temporadas (igual que TV).
  List<Map<String, dynamic>> _buildFullEpisodeList(ContentItem item) {
    final out = <Map<String, dynamic>>[];
    for (final s in item.seasons) {
      for (final e in s.episodes) {
        final still = _epStill(e);
        out.add({
          'season': s.number,
          'episode': e.number,
          'number': e.number,
          'id': e.id,
          'title': e.title,
          if (still != null) 'still': still,
        });
      }
    }
    return out;
  }

  ({int? se, int? ep, String? id, String? title}) _computeNext({
    required ContentItem item,
    required int? season,
    required int? episode,
  }) {
    final list = _buildFullEpisodeList(item);
    if (season == null || episode == null || list.isEmpty) {
      return (se: null, ep: null, id: null, title: null);
    }
    final idx = list.indexWhere(
      (e) =>
          e['season'] == season &&
          (e['episode'] == episode || e['number'] == episode),
    );
    if (idx < 0 || idx + 1 >= list.length) {
      return (se: null, ep: null, id: null, title: null);
    }
    final n = list[idx + 1];
    return (
      se: (n['season'] as num?)?.toInt(),
      ep: (n['episode'] as num?)?.toInt() ?? (n['number'] as num?)?.toInt(),
      id: n['id']?.toString(),
      title: n['title']?.toString() ?? 'E${n['number']}',
    );
  }

  Future<void> _openPlayer({
    int? season,
    int? episode,
    String? episodeTitle,
    int? startPositionMs,
  }) async {
    final item = _item;
    if (item == null) return;

    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);
    final isTv = context.read<SettingsService>().isTv;

    final se = season ?? _selectedSeasonNumber;
    final ep = episode ?? _selectedEpisode;

    int pos = startPositionMs ?? 0;
    if (pos <= 0 && se != null && ep != null) {
      pos = _positionMsForEpisode(se, ep);
    }
    if (pos <= 0 && se == null && ep == null) {
      pos = _lastPositionMs > 0
          ? _lastPositionMs
          : (_latestEntry?.positionMs ?? 0);
    }

    final fullList =
        item.isSeries ? _buildFullEpisodeList(item) : <Map<String, dynamic>>[];
    final next = item.isSeries
        ? _computeNext(item: item, season: se, episode: ep)
        : (se: null, ep: null, id: null, title: null);

    final offline = DownloadService.instance.offlineServerFor(
      repoId: widget.repo.manifest.id,
      contentId: item.id,
      season: se,
      episode: ep,
    );
    final List<StreamServer> servers =
        offline != null ? <StreamServer>[offline] : const [];
    final playUrl = offline?.url ?? '';

    await Navigator.of(context).push<Map>(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          title: item.title,
          url: playUrl,
          repoId: widget.repo.manifest.id,
          contentId: item.id,
          poster: item.poster,
          backdrop: item.backdrop,
          logo: item.logo,
          contentType: item.type,
          servers: servers,
          season: se,
          episode: ep,
          episodeTitle: episodeTitle ?? _episodeTitle(),
          nextSeason: next.se,
          nextEpisode: next.ep,
          nextEpisodeId: next.id,
          nextEpisodeTitle: next.title,
          episodeList: fullList,
          loadRepo: offline != null ? null : widget.repo,
          preferredLanguage: prefLang,
          startPositionMs: pos,
          isTv: isTv,
        ),
      ),
    );

    if (mounted) {
      await _refreshHistoryAndFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0B0E14),
        body: ListView(
          children: const [
            SizedBox(height: 220, child: ColoredBox(color: Color(0xFF1A222D))),
            Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                      height: 24,
                      width: 200,
                      child: ColoredBox(color: Color(0xFF1A222D))),
                  SizedBox(height: 12),
                  SizedBox(
                      height: 14,
                      width: 120,
                      child: ColoredBox(color: Color(0xFF1A222D))),
                  SizedBox(height: 20),
                  SizedBox(height: 60, child: ColoredBox(color: Color(0xFF1A222D))),
                  SizedBox(height: 24),
                  SkeletonRow(height: 70, itemWidth: 120, count: 4),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final item = _item;
    if (item == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B0E14),
        body: Center(
            child:
                Text('No encontrado', style: TextStyle(color: Colors.white54))),
      );
    }

    final lib = context.watch<LibraryService>();
    final isFav = lib.isFavorite(widget.repo.manifest.id, item.id);

    // Etiqueta del botón principal (Reanudar S00E00 / tiempo / Ver ahora)
    String playLabel = item.isSeries ? 'VER AHORA' : 'VER AHORA';
    if (item.isSeries) {
      final code = _resumeCode;
      if (code != null && _lastPositionMs > 3000) {
        playLabel = 'REANUDAR $code';
      }
    } else {
      final pos = _lastPositionMs > 0
          ? _lastPositionMs
          : (_latestEntry?.positionMs ?? 0);
      if (pos > 5000) {
        playLabel = 'REANUDAR · ${_formatMinutes(pos)}';
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            backgroundColor: const Color(0xFF0B0E14),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: Icon(isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? const Color(0xFFE50914) : Colors.white),
                onPressed: () => lib.toggleFavorite(
                  repoId: widget.repo.manifest.id,
                  contentId: item.id,
                  title: item.title,
                  poster: item.poster,
                  type: item.type,
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: item.backdrop != null || item.poster != null
                  ? CachedNetworkImage(
                      imageUrl: item.backdrop ?? item.poster!,
                      fit: BoxFit.cover,
                    )
                  : Container(color: const Color(0xFF1A222D)),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.logo != null && item.logo!.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CachedNetworkImage(
                        imageUrl: item.logo!,
                        height: 48,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                        errorWidget: (_, __, ___) => Text(
                          item.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  else
                    Text(item.title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (item.year != null) item.year!,
                      item.isSeries ? 'Serie' : 'Película',
                      if (item.rating != null)
                        '★ ${item.rating!.toStringAsFixed(1)}',
                      ...item.genres.take(2),
                    ].join(' · '),
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  if (item.overview != null) ...[
                    const SizedBox(height: 12),
                    Text(item.overview!,
                        style: const TextStyle(
                            color: Colors.white70, height: 1.4)),
                  ],
                  const SizedBox(height: 20),

                  // Botón principal (película o reanudar serie)
                  Focusable(
                    onTap: () {
                      if (item.isSeries && item.seasons.isNotEmpty) {
                        int se;
                        int? ep;
                        if (_lastSeason != null &&
                            _lastEpisode != null &&
                            _lastPositionMs > 3000) {
                          se = _lastSeason!;
                          ep = _lastEpisode;
                          final idx =
                              item.seasons.indexWhere((s) => s.number == se);
                          if (idx >= 0) {
                            setState(() {
                              _seasonIndex = idx;
                              _selectedEpisode = ep;
                            });
                          }
                        } else {
                          se = item.seasons[_seasonIndex].number;
                          ep = _selectedEpisode ??
                              (item.seasons[_seasonIndex].episodes.isNotEmpty
                                  ? item.seasons[_seasonIndex].episodes.first
                                      .number
                                  : null);
                        }
                        if (ep != null) {
                          final pos = _positionMsForEpisode(se, ep);
                          _openPlayer(
                            season: se,
                            episode: ep,
                            startPositionMs: pos > 0 ? pos : null,
                          );
                        }
                      } else {
                        final pos = _lastPositionMs > 0
                            ? _lastPositionMs
                            : (_latestEntry?.positionMs ?? 0);
                        _openPlayer(
                            startPositionMs: pos > 0 ? pos : null);
                      }
                    },
                    builder: (f) => Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE50914),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: f ? Colors.white : Colors.transparent,
                            width: 2),
                      ),
                      child: Text(
                        playLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                  if (context.watch<SettingsService>().downloadsEnabled) ...[
                  const SizedBox(height: 10),
                  Focusable(
                    onTap: () {
                      int? se;
                      int? ep;
                      String? epTitle;
                      String? epId;
                      if (item.isSeries && item.seasons.isNotEmpty) {
                        se = item.seasons[_seasonIndex].number;
                        final eps = item.seasons[_seasonIndex].episodes;
                        final e = eps.isNotEmpty
                            ? eps.firstWhere(
                                (x) =>
                                    x.number ==
                                    (_selectedEpisode ?? eps.first.number),
                                orElse: () => eps.first,
                              )
                            : null;
                        ep = e?.number ?? _selectedEpisode;
                        epTitle = e?.title;
                        epId = e != null ? '${item.id}:$se:$ep' : null;
                      }
                      DownloadSheet.show(
                        context: context,
                        repo: widget.repo,
                        item: item,
                        season: se,
                        episode: ep,
                        episodeTitle: epTitle,
                        episodeId: epId,
                      );
                    },
                    builder: (f) => Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A222D),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: f ? Colors.white : Colors.white24, width: 1.5),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.download_rounded, color: Colors.white70, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'DESCARGAR',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ],

                  // Series: temporadas + episodios con barra de progreso
                  if (item.isSeries && item.seasons.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text('Temporadas',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: item.seasons.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          final s = item.seasons[i];
                          final sel = i == _seasonIndex;
                          return Focusable(
                            onTap: () => setState(() {
                              _seasonIndex = i;
                              _selectedEpisode = null;
                              _episodePage = 0;
                            }),
                            builder: (f) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: sel
                                    ? const Color(0xFFE50914)
                                    : const Color(0xFF1A222D),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: f
                                      ? const Color(0xFFFF2D2D)
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                              child: Text(s.name ?? 'T${s.number}',
                                  style: const TextStyle(color: Colors.white)),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Episodios · toca para reproducir',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(height: 8),
                    ..._buildEpisodeWidgets(item),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildEpisodeWidgets(ContentItem item) {
    final allEps = item.seasons[_seasonIndex].episodes;
    final seasonNum = item.seasons[_seasonIndex].number;
    final total = allEps.length;
    final usePag = _useEpPagination && total > _epPerPage;
    final per = _epPerPage;
    final totalPages = usePag ? ((total + per - 1) ~/ per) : 1;
    final page = usePag ? _episodePage.clamp(0, totalPages - 1) : 0;
    final start = usePag ? page * per : 0;
    final end = usePag ? (start + per).clamp(0, total) : total;
    final pageEps = allEps.sublist(start, end);

    final widgets = <Widget>[];
    if (usePag) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Focusable(
                onTap: page > 0
                    ? () => setState(() => _episodePage = page - 1)
                    : null,
                builder: (f) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: page > 0
                        ? const Color(0xFF1A222D)
                        : const Color(0xFF141A22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: f && page > 0
                          ? const Color(0xFFFF2D2D)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Icon(Icons.chevron_left,
                      color: page > 0 ? Colors.white : Colors.white24,
                      size: 22),
                ),
              ),
              Expanded(
                child: Text(
                  'Pág. ${page + 1} / $totalPages  ·  ${start + 1}–$end de $total',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              Focusable(
                onTap: page < totalPages - 1
                    ? () => setState(() => _episodePage = page + 1)
                    : null,
                builder: (f) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: page < totalPages - 1
                        ? const Color(0xFF1A222D)
                        : const Color(0xFF141A22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: f && page < totalPages - 1
                          ? const Color(0xFFFF2D2D)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Icon(Icons.chevron_right,
                      color: page < totalPages - 1
                          ? Colors.white
                          : Colors.white24,
                      size: 22),
                ),
              ),
            ],
          ),
        ),
      );
    }

    for (final ep in pageEps) {
      final sel = _selectedEpisode == ep.number;
      final isLast = _lastSeason == seasonNum && _lastEpisode == ep.number;
      final progress = _progressForEpisode(seasonNum, ep.number);

      widgets.add(
        Focusable(
          onTap: () async {
            setState(() => _selectedEpisode = ep.number);
            final pos = _positionMsForEpisode(seasonNum, ep.number);
            await _openPlayer(
              season: seasonNum,
              episode: ep.number,
              episodeTitle: ep.title,
              startPositionMs: pos > 0 ? pos : null,
            );
          },
          builder: (f) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: sel || isLast
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFF141A22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: f || sel
                    ? const Color(0xFFFF2D2D)
                    : (isLast
                        ? const Color(0xFFE50914).withValues(alpha: 0.5)
                        : Colors.transparent),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 100,
                    height: 56,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (ep.still != null)
                          CachedNetworkImage(
                              imageUrl: ep.still!, fit: BoxFit.cover)
                        else
                          Container(
                            color: const Color(0xFF1A222D),
                            child: Center(
                                child: Text('${ep.number}',
                                    style: const TextStyle(
                                        color: Colors.white54))),
                          ),
                        // Barra de progreso del capítulo
                        if (progress > 0.02)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: progress.clamp(0.0, 1.0),
                              minHeight: 3.5,
                              color: const Color(0xFFE50914),
                              backgroundColor: Colors.white12,
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
                    children: [
                      Text(
                        'E${ep.number} · ${ep.title ?? 'Episodio ${ep.number}'}',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight:
                              isLast ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                      if (ep.overview != null)
                        Text(
                          ep.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      if (progress > 0.02) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${(progress * 100).round()}% visto',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (context.watch<SettingsService>().downloadsEnabled)
                IconButton(
                  icon: const Icon(Icons.download_rounded, color: Colors.white70, size: 22),
                  tooltip: 'Descargar episodio',
                  onPressed: () {
                    DownloadSheet.show(
                      context: context,
                      repo: widget.repo,
                      item: item,
                      season: seasonNum,
                      episode: ep.number,
                      episodeTitle: ep.title,
                      episodeId: '${item.id}/${ep.number}',
                    );
                  },
                ),
                const Icon(Icons.play_circle_fill,
                    color: Color(0xFFE50914), size: 28),
              ],
            ),
          ),
        ),
      );
    }

    if (usePag && totalPages > 1) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Focusable(
                onTap: page > 0
                    ? () => setState(() => _episodePage = page - 1)
                    : null,
                builder: (f) => Text(
                  'Anterior',
                  style: TextStyle(
                    color: page > 0
                        ? const Color(0xFFE50914)
                        : Colors.white24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Focusable(
                onTap: page < totalPages - 1
                    ? () => setState(() => _episodePage = page + 1)
                    : null,
                builder: (f) => Text(
                  'Siguiente',
                  style: TextStyle(
                    color: page < totalPages - 1
                        ? const Color(0xFFE50914)
                        : Colors.white24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return widgets;
  }
}

class _EpProgress {
  final int positionMs;
  final int durationMs;
  final double progress;
  const _EpProgress({
    required this.positionMs,
    required this.durationMs,
    required this.progress,
  });
}

String? _epStill(dynamic e) {
  try {
    final v = e.still;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  try {
    final v = e.poster;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  try {
    final v = e.image;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  return null;
}