import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/settings_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../widgets/focusable.dart';
import '../../widgets/glass.dart';
import '../player/player.dart';
import '../../../shared/download_sheet.dart';
import '../../../../data/services/download_service.dart';
import '../../../../data/models/stream_server.dart';

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

class _DetailsPageState extends State<DetailsPage> with WidgetsBindingObserver {
  ContentItem? _item;
  bool _loading = true;
  bool _showEpisodes = false;
  int _seasonIndex = 0;
  int? _selectedEpisode;

  List<WatchEntry> _history = [];

  final Map<String, _EpProgress> _epProgress = {};

  int? _lastSeason;
  int? _lastEpisode;
  int _lastPositionMs = 0;
  int _lastDurationMs = 0;

  final Set<int> _loadedSeasonNumbers = {};
  bool _loadingSeason = false;
  bool _refreshingHistory = false;

  static String _epKey(int se, int ep) => 'S${se}E$ep';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshHistoryAndFocus());
    }
  }

  Future<void> _loadPlayerHistorial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final repoId = widget.repo.manifest.id;
      final contentId = widget.itemId;

      final seriesKey = 'continue_watch_${repoId}_$contentId';
      final keys = <String>{seriesKey};

      final index = prefs.getStringList('continue_watching_index') ?? const [];
      for (final k in index) {
        if (k.startsWith('continue_watch_${repoId}_$contentId')) {
          keys.add(k);
        }
      }
      // Preferencias pueden guardar claves por episodio: ..._s2_e5
      for (final k in prefs.getKeys()) {
        if (k.startsWith('continue_watch_${repoId}_$contentId')) {
          keys.add(k);
        }
      }

      int bestPos = -1;
      String bestUpdated = '';

      for (final key in keys) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final map = Map<String, dynamic>.from(decoded);

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
          final updated =
              (map['updatedAt'] ?? map['timestamp'] ?? '').toString();

          if (se != null && ep != null && pos > 0) {
            final p = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
            final k = _epKey(se, ep);
            final existing = _epProgress[k];
            if (existing == null || pos >= existing.positionMs) {
              _epProgress[k] = _EpProgress(
                positionMs: pos,
                durationMs: dur > 0 ? dur : existing?.durationMs ?? 0,
                progress: p,
              );
            }

            final isNewer = updated.isNotEmpty && updated.compareTo(bestUpdated) > 0;
            if (isNewer || (updated.isEmpty && pos >= bestPos)) {
              if (updated.isNotEmpty) bestUpdated = updated;
              bestPos = pos;
              _lastSeason = se;
              _lastEpisode = ep;
              _lastPositionMs = pos;
              _lastDurationMs = dur > 0 ? dur : _lastDurationMs;
            }
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
              if (s2 == null || e2 == null || pMs == null || pMs <= 0) {
                continue;
              }
              final d = dMs ?? 0;
              final k = _epKey(s2, e2);
              final existing = _epProgress[k];
              if (existing == null || pMs >= existing.positionMs) {
                _epProgress[k] = _EpProgress(
                  positionMs: pMs,
                  durationMs: d > 0 ? d : existing?.durationMs ?? 0,
                  progress: d > 0 ? (pMs / d).clamp(0.0, 1.0) : 0.0,
                );
              }
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[Details] loadPlayerHistorial: $e');
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
    if (!mounted || _refreshingHistory) return;
    _refreshingHistory = true;
    try {
      // Limpiar para no quedar con progreso viejo en memoria
      _epProgress.clear();
      _lastSeason = null;
      _lastEpisode = null;
      _lastPositionMs = 0;
      _lastDurationMs = 0;

      final lib = context.read<LibraryService>();
      // Si LibraryService expone reload/refresh, intentarlo
      try {
        await (lib as dynamic).reload?.call();
      } catch (_) {}
      try {
        await (lib as dynamic).refresh?.call();
      } catch (_) {}

      final all = lib.continueWatching(widget.repo.manifest.id);
      final hist = all.where((e) => e.contentId == widget.itemId).toList();

      await _loadPlayerHistorial();
      _mergeLibraryHistory(hist);

      if (!mounted) return;
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
          if (ep != null) _selectedEpisode = ep;
        }
      });
    } finally {
      _refreshingHistory = false;
    }
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

    _epProgress.clear();
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
        _selectedEpisode = ep ??
            (item.seasons[_seasonIndex].episodes.isNotEmpty
                ? item.seasons[_seasonIndex].episodes.first.number
                : null);
      }
    });
  }

  Future<void> _ensureSeasonLoaded(int seasonIndex) async {
    final item = _item;
    if (item == null || item.seasons.isEmpty) return;
    if (seasonIndex < 0 || seasonIndex >= item.seasons.length) return;
    final season = item.seasons[seasonIndex];
    final num = season.number;
    if (_loadedSeasonNumbers.contains(num)) return;
    if (season.episodes.isNotEmpty) {
      _loadedSeasonNumbers.add(num);
      return;
    }

    if (_loadingSeason) return;
    setState(() => _loadingSeason = true);
    try {
      final refreshed = await ContentService.instance.getDetails(
        widget.repo,
        widget.itemId,
        season: num,
      );
      if (!mounted) return;
      if (refreshed != null) {
        final merged = _mergeSeasonIntoItem(item, refreshed, num);
        setState(() {
          _item = merged;
          _loadedSeasonNumbers.add(num);
          _loadingSeason = false;
        });
      } else {
        setState(() {
          _loadedSeasonNumbers.add(num);
          _loadingSeason = false;
        });
      }
    } catch (e) {
      debugPrint('[Details] ensureSeasonLoaded: $e');
      if (mounted) {
        setState(() {
          _loadedSeasonNumbers.add(num);
          _loadingSeason = false;
        });
      }
    }
  }

  ContentItem _mergeSeasonIntoItem(
    ContentItem base,
    ContentItem incoming,
    int seasonNumber,
  ) {
    try {
      final incHas = incoming.seasons.any(
        (s) => s.number == seasonNumber && s.episodes.isNotEmpty,
      );
      if (incHas && incoming.seasons.length >= base.seasons.length) {
        return incoming;
      }
      if (incHas) return incoming;
    } catch (_) {}
    return incoming.seasons.isNotEmpty ? incoming : base;
  }

  Future<void> _openEpisodesView() async {
    final item = _item;
    if (item == null || !item.isSeries) return;
    await _refreshHistoryAndFocus();
    await _ensureSeasonLoaded(_seasonIndex);
    if (!mounted) return;
    setState(() => _showEpisodes = true);
  }

  Future<void> _onSeasonSelected(int i) async {
    setState(() {
      _seasonIndex = i;
      final item = _item;
      if (item != null &&
          item.seasons.isNotEmpty &&
          i >= 0 &&
          i < item.seasons.length) {
        _selectedEpisode = item.seasons[i].episodes.isNotEmpty
            ? item.seasons[i].episodes.first.number
            : null;
      }
    });
    await _ensureSeasonLoaded(i);
    // Al cambiar temporada, refrescar progreso de capítulos
    unawaited(_refreshHistoryAndFocus());
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

  WatchEntry? _entryFor({int? season, int? episode}) {
    for (final e in _history) {
      final s = _entrySeason(e);
      final ep = _entryEpisode(e);
      if (season != null && episode != null) {
        if (s == season && ep == episode) return e;
      } else if (season == null && episode == null) {
        if (s == null && ep == null) return e;
        return e;
      }
    }
    if (season == null && episode == null && _history.isNotEmpty) {
      return _history.first;
    }
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

    final se = season ?? _selectedSeasonNumber;
    final ep = episode ?? _selectedEpisode;

    int pos = startPositionMs ?? 0;
    if (pos <= 0 && se != null && ep != null) {
      pos = _positionMsForEpisode(se, ep);
    }
    if (pos <= 0) {
      final entry = _entryFor(season: se, episode: ep) ??
          (se == null && ep == null ? _latestEntry : null);
      pos = entry?.positionMs ?? 0;
    }

    final fullList =
        item.isSeries ? _buildFullEpisodeList(item) : <Map<String, dynamic>>[];
    final next = item.isSeries
        ? _computeNext(item: item, season: se, episode: ep)
        : (se: null, ep: null, id: null, title: null);

    // Reproducir offline si hay descarga completada
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
          isTv: true,
        ),
      ),
    );

    // Al volver del player: historial fresco sin cerrar la ficha
    if (!mounted) return;
    await _refreshHistoryAndFocus();
    if (!mounted) return;
    if (item.isSeries) {
      // Mantener / mostrar capítulos con barras actualizadas
      await _ensureSeasonLoaded(_seasonIndex);
      if (mounted) setState(() => _showEpisodes = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: kTvBg,
        body: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2, color: kTvAccent),
          ),
        ),
      );
    }
    final item = _item;
    if (item == null) {
      return const Scaffold(
        backgroundColor: kTvBg,
        body: Center(
          child: Text('No encontrado', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    if (_showEpisodes && item.isSeries) {
      return _EpisodesView(
        item: item,
        seasonIndex: _seasonIndex,
        selectedEpisode: _selectedEpisode,
        progressFor: _progressForEpisode,
        loadingSeason: _loadingSeason,
        onSeason: (i) => _onSeasonSelected(i),
        onEpisode: (ep) {
          setState(() => _selectedEpisode = ep.number);
          final se = item.seasons[_seasonIndex].number;
          final pos = _positionMsForEpisode(se, ep.number);
          _openPlayer(
            season: se,
            episode: ep.number,
            episodeTitle: ep.title,
            startPositionMs: pos > 0 ? pos : null,
          );
        },
        onDownloadEpisode: (ep) {
          final se = item.seasons[_seasonIndex].number;
          DownloadSheet.show(
            context: context,
            repo: widget.repo,
            item: item,
            season: se,
            episode: ep.number,
            episodeTitle: ep.title,
            episodeId: '${item.id}/${ep.number}',
          );
        },
        onBack: () {
          unawaited(_refreshHistoryAndFocus());
          setState(() => _showEpisodes = false);
        },
      );
    }

    String playLabel = 'Ver ahora';
    if (item.isSeries) {
      final code = _resumeCode;
      if (code != null && _lastPositionMs > 3000) {
        playLabel = 'Reanudar $code';
      }
    } else {
      final pos = _lastPositionMs > 0
          ? _lastPositionMs
          : (_latestEntry?.positionMs ?? 0);
      if (pos > 5000) {
        playLabel = 'Reanudar · ${_formatMinutes(pos)}';
      }
    }

    return _InfoView(
      item: item,
      repo: widget.repo,
      playLabel: playLabel,
      onPlay: () {
        if (item.isSeries && item.seasons.isNotEmpty) {
          int se;
          int? ep;
          if (_lastSeason != null &&
              _lastEpisode != null &&
              _lastPositionMs > 3000) {
            se = _lastSeason!;
            ep = _lastEpisode;
            final idx = item.seasons.indexWhere((s) => s.number == se);
            if (idx >= 0) _seasonIndex = idx;
            _selectedEpisode = ep;
          } else {
            se = item.seasons[_seasonIndex].number;
            ep = _selectedEpisode ??
                (item.seasons[_seasonIndex].episodes.isNotEmpty
                    ? item.seasons[_seasonIndex].episodes.first.number
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
          _openPlayer(startPositionMs: pos > 0 ? pos : null);
        }
      },
      onEpisodes: item.isSeries ? () => _openEpisodesView() : null,
      onDownload: () {
        // Película completa, o episodio seleccionado si es serie
        int? se;
        int? ep;
        String? epTitle;
        String? epId;
        if (item.isSeries && item.seasons.isNotEmpty) {
          se = item.seasons[_seasonIndex].number;
          final eps = item.seasons[_seasonIndex].episodes;
          final e = eps.isNotEmpty
              ? eps.firstWhere(
                  (x) => x.number == (_selectedEpisode ?? eps.first.number),
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
    );
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

class _InfoView extends StatelessWidget {
  final ContentItem item;
  final InstalledRepo repo;
  final String playLabel;
  final VoidCallback onPlay;
  final VoidCallback? onEpisodes;
  final VoidCallback? onDownload;

  const _InfoView({
    required this.item,
    required this.repo,
    required this.playLabel,
    required this.onPlay,
    this.onEpisodes,
    this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final downloadsOn = context.watch<SettingsService>().downloadsEnabled;
    final isFav = lib.isFavorite(repo.manifest.id, item.id);
    final bgUrl = item.backdrop ?? item.poster;

    return Scaffold(
      backgroundColor: kTvBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (bgUrl != null)
            CachedNetworkImage(
              imageUrl: bgUrl,
              fit: BoxFit.cover,
              memCacheWidth: 1280,
            )
          else
            const ColoredBox(color: kTvBg),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.15),
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0.92),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 24, 48, 36),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.logo != null && item.logo!.isNotEmpty)
                        SizedBox(
                          width: double.infinity,
                          height: 68,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: CachedNetworkImage(
                              imageUrl: item.logo!,
                              height: 68,
                              fit: BoxFit.contain,
                              alignment: Alignment.centerLeft,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              placeholder: (_, __) =>
                                  const SizedBox(height: 68, width: 1),
                              errorWidget: (_, __, ___) => Text(
                                item.title,
                                textAlign: TextAlign.left,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Text(
                          item.title,
                          textAlign: TextAlign.left,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      const SizedBox(height: 10),
                      Text(
                        [
                          if (item.year != null) item.year!,
                          item.isSeries ? 'Serie' : 'Película',
                          if (item.rating != null)
                            '★ ${item.rating!.toStringAsFixed(1)}',
                          ...item.genres.take(3),
                        ].join('  ·  '),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                      if (item.overview != null &&
                          item.overview!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          item.overview!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 13.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          Focusable(
                            autofocus: true,
                            onTap: onPlay,
                            builder: (f) => _ActionBtn(
                              icon: Icons.play_arrow_rounded,
                              label: playLabel,
                              primary: true,
                              focused: f,
                            ),
                          ),
                          if (onEpisodes != null)
                            Focusable(
                              onTap: onEpisodes,
                              builder: (f) => _ActionBtn(
                                icon: Icons.list_rounded,
                                label: 'Ver capítulos',
                                primary: false,
                                focused: f,
                              ),
                            ),
                          Focusable(
                            onTap: () => lib.toggleFavorite(
                              repoId: repo.manifest.id,
                              contentId: item.id,
                              title: item.title,
                              poster: item.poster,
                              type: item.type,
                            ),
                            builder: (f) => _ActionBtn(
                              icon: isFav
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              label: isFav ? 'En lista' : 'Mi lista',
                              primary: false,
                              focused: f,
                              iconOnly: true,
                            ),
                          ),
                          if (onDownload != null && !item.isSeries && downloadsOn)
                            Focusable(
                              onTap: onDownload,
                              builder: (f) => _ActionBtn(
                                icon: Icons.download_rounded,
                                label: 'Descargar',
                                primary: false,
                                focused: f,
                                iconOnly: true,
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
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final bool focused;
  final bool iconOnly;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.primary,
    required this.focused,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: iconOnly
          ? const EdgeInsets.all(12)
          : const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: primary
            ? (focused ? Colors.white : Colors.white.withValues(alpha: 0.92))
            : (focused
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: focused
              ? (primary ? const Color(0xFFE50914) : Colors.white)
              : Colors.transparent,
          width: focused ? 2.5 : 0,
        ),
      ),
      child: iconOnly
          ? Icon(icon, size: 22, color: primary ? Colors.black : Colors.white)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: primary ? Colors.black : Colors.white),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: primary ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
    );
  }
}

class _EpisodesView extends StatelessWidget {
  final ContentItem item;
  final int seasonIndex;
  final int? selectedEpisode;
  final double Function(int seasonNum, int epNum) progressFor;
  final bool loadingSeason;
  final ValueChanged<int> onSeason;
  final void Function(dynamic ep) onEpisode;
  final void Function(dynamic ep)? onDownloadEpisode;
  final VoidCallback? onBack;

  const _EpisodesView({
    required this.item,
    required this.seasonIndex,
    required this.selectedEpisode,
    required this.progressFor,
    required this.loadingSeason,
    required this.onSeason,
    required this.onEpisode,
    this.onDownloadEpisode,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final seasons = item.seasons;
    final season = seasons[seasonIndex.clamp(0, seasons.length - 1)];
    final eps = season.episodes;
    final bgUrl = item.backdrop ?? item.poster;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        onBack?.call();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (bgUrl != null)
              Opacity(
                opacity: 0.22,
                child: CachedNetworkImage(
                  imageUrl: bgUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 1280,
                ),
              ),
            Container(color: Colors.black.withValues(alpha: 0.84)),
            SafeArea(
              child: Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 28, 12, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.logo != null && item.logo!.isNotEmpty)
                            SizedBox(
                              width: double.infinity,
                              height: 40,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: CachedNetworkImage(
                                  imageUrl: item.logo!,
                                  height: 40,
                                  fit: BoxFit.contain,
                                  alignment: Alignment.centerLeft,
                                  fadeInDuration: Duration.zero,
                                  fadeOutDuration: Duration.zero,
                                  placeholder: (_, __) =>
                                      const SizedBox(height: 40, width: 1),
                                  errorWidget: (_, __, ___) => Text(
                                    item.title,
                                    textAlign: TextAlign.left,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else
                            Text(
                              item.title,
                              textAlign: TextAlign.left,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            [
                              if (item.year != null) '${item.year}',
                              if (item.seasons.isNotEmpty)
                                '${item.seasons.length} Temporadas',
                            ].join('  ·  '),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Expanded(
                            child: ListView.builder(
                              itemCount: seasons.length,
                              itemBuilder: (context, i) {
                                final s = seasons[i];
                                final sel = i == seasonIndex;
                                return Focusable(
                                  onTap: () => onSeason(i),
                                  builder: (f) => Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(4),
                                      color: (sel || f)
                                          ? Colors.white.withValues(alpha: 0.10)
                                          : Colors.transparent,
                                      border: Border.all(
                                        color: f
                                            ? Colors.white
                                            : (sel
                                                ? const Color(0xFFE50914)
                                                    .withValues(alpha: 0.7)
                                                : Colors.transparent),
                                        width: f ? 2.5 : 1.2,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'Temporada ${s.number}',
                                            style: TextStyle(
                                              color: (sel || f)
                                                  ? Colors.white
                                                  : Colors.white54,
                                              fontSize: 14,
                                              fontWeight: sel
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          s.episodes.isEmpty
                                              ? '…'
                                              : '${s.episodes.length} eps',
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.35),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: loadingSeason && eps.isEmpty
                        ? const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFE50914),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(8, 28, 28, 24),
                            itemCount: eps.length,
                            itemBuilder: (context, i) {
                              final e = eps[i];
                              final thumb =
                                  _epStill(e) ?? item.backdrop ?? item.poster;
                              final progress =
                                  progressFor(season.number, e.number);
                              final isRecent = e.number == selectedEpisode;

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Focusable(
                                      autofocus: isRecent,
                                      onTap: () => onEpisode(e),
                                      builder: (f) => AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 120),
                                        width: 168,
                                        height: 94,
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                            color: f
                                                ? Colors.white
                                                : (isRecent
                                                    ? const Color(0xFFE50914)
                                                        .withValues(alpha: 0.7)
                                                    : Colors.transparent),
                                            width: f ? 2.5 : 1.5,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(5),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              thumb != null
                                                  ? CachedNetworkImage(
                                                      imageUrl: thumb,
                                                      fit: BoxFit.cover,
                                                      memCacheWidth: 336,
                                                    )
                                                  : Container(
                                                      color: const Color(
                                                          0xFF1A1A1A),
                                                    ),
                                              if (progress > 0.02)
                                                Positioned(
                                                  left: 0,
                                                  right: 0,
                                                  bottom: 0,
                                                  child:
                                                      LinearProgressIndicator(
                                                    value: progress.clamp(
                                                        0.0, 1.0),
                                                    minHeight: 3.5,
                                                    color: const Color(
                                                        0xFFE50914),
                                                    backgroundColor:
                                                        Colors.white12,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            e.title?.isNotEmpty == true
                                                ? '${e.number}. ${e.title}'
                                                : 'Episodio ${e.number}',
                                            style: TextStyle(
                                              color: isRecent
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (_epOverview(e) != null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              _epOverview(e)!,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white
                                                    .withValues(alpha: 0.48),
                                                fontSize: 12,
                                                height: 1.35,
                                              ),
                                            ),
                                          ],
                                          if (progress > 0.02) ...[
                                            const SizedBox(height: 6),
                                            Text(
                                              '${(progress * 100).round()}% visto',
                                              style: TextStyle(
                                                color: Colors.white
                                                    .withValues(alpha: 0.4),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (onDownloadEpisode != null && context.watch<SettingsService>().downloadsEnabled) ...[
                                      const SizedBox(width: 8),
                                      Focusable(
                                        onTap: () => onDownloadEpisode!(e),
                                        builder: (df) => Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(8),
                                            color: df
                                                ? Colors.white.withValues(alpha: 0.15)
                                                : Colors.white.withValues(alpha: 0.06),
                                            border: Border.all(
                                              color: df ? Colors.white : Colors.transparent,
                                              width: 2,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.download_rounded,
                                            color: df ? Colors.white : Colors.white54,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
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

String? _epOverview(dynamic e) {
  try {
    final v = e.overview;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  try {
    final v = e.description;
    if (v is String && v.isNotEmpty) return v;
  } catch (_) {}
  return null;
}