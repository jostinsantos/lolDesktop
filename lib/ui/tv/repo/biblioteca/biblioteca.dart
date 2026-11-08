import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/library_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../../../data/services/settings_service.dart';
import '../../widgets/focusable.dart';
import '../main_home.dart';
import '../player/player.dart';
import '../contenido/contenido.dart';

/// Biblioteca del repo: historial (valores del player) + favoritos.
/// Flecha izquierda en el primer ítem de cada fila → menú lateral (como el slider de historial).
class RepoLibraryPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoLibraryPage({super.key, required this.repo});

  @override
  State<RepoLibraryPage> createState() => _RepoLibraryPageState();
}

class _RepoLibraryPageState extends State<RepoLibraryPage> {
  /// Historial del player: "contentId" → payload JSON.
  final Map<String, Map<String, dynamic>> _playerHist = {};
  static const String _playerId = 'dual_player_hls_ts_v1';

  @override
  void initState() {
    super.initState();
    _loadPlayerHistorial();
  }

  Future<void> _loadPlayerHistorial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final repoId = widget.repo.manifest.id;
      final map = <String, Map<String, dynamic>>{};

      final index = prefs.getStringList('continue_watching_index') ?? const <String>[];
      final keys = index.isNotEmpty
          ? index.where((k) => k.contains(repoId)).toList()
          : prefs
              .getKeys()
              .where((k) => k.startsWith('continue_watch_${repoId}_'))
              .toList();

      for (final key in keys) {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final m = Map<String, dynamic>.from(decoded);
          final cid = (m['contentId'] ?? '').toString();
          if (cid.isEmpty) continue;
          if ((m['repoId'] ?? '').toString() != repoId &&
              !key.contains(repoId)) {
            continue;
          }
          map[cid] = m;
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _playerHist
          ..clear()
          ..addAll(map);
      });
    } catch (e) {
      debugPrint('[RepoLibrary] hist: $e');
    }
  }

  Map<String, dynamic>? _pe(WatchEntry e) => _playerHist[e.contentId];

  double _progressOf(WatchEntry e) {
    final pe = _pe(e);
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
      return e.progress.clamp(0.0, 1.0);
    } catch (_) {
      return 0;
    }
  }

  String? _resumeCodeOf(WatchEntry e) {
    final pe = _pe(e);
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
    return 'S${se.toString().padLeft(2, '0')}E${ep.toString().padLeft(2, '0')}';
  }

  String? _imageOf(WatchEntry e) {
    final pe = _pe(e);
    if (pe != null) {
      for (final k in ['poster', 'backdrop', 'logo']) {
        final v = (pe[k] ?? '').toString();
        if (v.startsWith('http')) return v;
      }
    }
    return e.poster;
  }

  String _titleOf(WatchEntry e) {
    final pe = _pe(e);
    final t = (pe?['title'] ?? e.title).toString().trim();
    return t.isNotEmpty ? t : e.title;
  }

  Future<void> _openPlayer(BuildContext context, WatchEntry e) async {
    final prefs = context.read<RepoPrefs>();
    final isTv = context.read<SettingsService>().isTv;

    Map<String, dynamic>? pe = _pe(e);
    if (pe == null) {
      try {
        final sp = await SharedPreferences.getInstance();
        final raw = sp.getString('continue_watch_${e.repoId}_${e.contentId}');
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            pe = Map<String, dynamic>.from(decoded);
            _playerHist[e.contentId] = pe;
          }
        }
      } catch (_) {}
    }

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
        backdrop: backdrop != null && backdrop.isNotEmpty ? backdrop : null,
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
        loadRepo: widget.repo,
        preferredLanguage: prefs.preferredLanguage(widget.repo.manifest.id),
        isTv: isTv,
      ),
    ));

    if (mounted) await _loadPlayerHistorial();
  }

  void _goMenu(BuildContext context) {
    RepoNavScope.of(context)?.requestMenuFocus();
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryService>();
    final watching = lib.continueWatching(widget.repo.manifest.id);
    final favs = lib.favorites(widget.repo.manifest.id);

    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Text(
            'Historial · Continuar viendo',
            style: TextStyle(
                color: Colors.white70, fontWeight: FontWeight.w600),
          ),
        ),
        if (watching.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('Aún no hay historial',
                style: TextStyle(color: Colors.white38)),
          )
        else
          SizedBox(
            height: 148,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: watching.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final e = watching[i];
                final progress = _progressOf(e);
                final code = _resumeCodeOf(e);
                final img = _imageOf(e);
                final title = _titleOf(e);

                return Focusable(
                  isFirstInRow: i == 0,
                  onLeftEdge: () => _goMenu(context),
                  onTap: () => _openPlayer(context, e),
                  builder: (focused) => SizedBox(
                    width: 88,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 100),
                          width: 88,
                          height: 112,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color:
                                  focused ? Colors.white : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (img != null && img.isNotEmpty)
                                  CachedNetworkImage(
                                    imageUrl: img,
                                    fit: BoxFit.cover,
                                    memCacheWidth: 176,
                                  )
                                else
                                  Container(color: const Color(0xFF1A222D)),
                                // Barra progreso del player
                                if (progress > 0.02)
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 3,
                                      color: const Color(0xFFE50914),
                                      backgroundColor: Colors.white12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: focused ? Colors.white : Colors.white60,
                            fontSize: 10.5,
                          ),
                        ),
                        if (code != null)
                          Text(
                            code,
                            maxLines: 1,
                            style: TextStyle(
                              color: focused
                                  ? Colors.white70
                                  : Colors.white.withValues(alpha: 0.4),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Text(
            'Favoritos',
            style: TextStyle(
                color: Colors.white70, fontWeight: FontWeight.w600),
          ),
        ),
        if (favs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child:
                Text('Sin favoritos', style: TextStyle(color: Colors.white38)),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              // Columnas aproximadas (mismo criterio que maxCrossAxisExtent: 140)
              const maxExtent = 140.0;
              const spacing = 12.0;
              final cols = ((constraints.maxWidth + spacing) /
                      (maxExtent + spacing))
                  .floor()
                  .clamp(1, 12);

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  childAspectRatio: 0.65,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: favs.length,
                itemBuilder: (context, i) {
                  final e = favs[i];
                  // Primer elemento de cada fila → izquierda va al menú
                  final isLeftEdge = (i % cols) == 0;

                  return Focusable(
                    isFirstInRow: isLeftEdge,
                    onLeftEdge:
                        isLeftEdge ? () => _goMenu(context) : null,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DetailsPage(
                          repo: widget.repo,
                          itemId: e.contentId,
                        ),
                      ),
                    ),
                    builder: (focused) => AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: focused ? Colors.white : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: e.poster != null
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  CachedNetworkImage(
                                    imageUrl: e.poster!,
                                    fit: BoxFit.cover,
                                  ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    top: 0,
                                    height: 42,
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.white
                                                  .withValues(alpha: 0.22),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Container(color: const Color(0xFF1A222D)),
                      ),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }
}