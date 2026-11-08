import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/repo_prefs.dart';
import '../../../data/services/settings_service.dart';
import '../../../data/services/download_service.dart';
import '../../../data/models/download_item.dart';
import '../../../ui/shared/download_sheet.dart';
import '../../../ui/shared/cast_sheet.dart';
import '../player/player.dart';

const _bg = Color(0xFF0B0D10);
const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _accent = Color(0xFFE50914);

/// Ficha de contenido — diseño alineado a TV (backdrop + info + capítulos).
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
  String? _error;
  int _seasonIndex = 0;
  bool _loadingSeason = false;
  final Set<int> _loadedSeasons = {};
  bool _showEpisodes = false;

  int? _watchPosMs;
  int? _watchDurMs;
  int? _watchSeason;
  int? _watchEpisode;
  bool _isFavorite = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final item = await ContentService.instance.getDetails(widget.repo, widget.itemId);
      if (!mounted) return;
      if (item == null) {
        setState(() {
          _error = 'No se pudo cargar el contenido';
          _loading = false;
        });
        return;
      }
      setState(() {
        _item = item;
        _loading = false;
        if (item.seasons.isNotEmpty && widget.season != null) {
          final idx = item.seasons.indexWhere((s) => s.number == widget.season);
          if (idx >= 0) _seasonIndex = idx;
        }
      });
      if (item.seasons.isNotEmpty) {
        await _ensureSeasonEpisodes(item.seasons[_seasonIndex].number);
      }
      await _loadWatchState();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _ensureSeasonEpisodes(int seasonNumber) async {
    if (_loadedSeasons.contains(seasonNumber) || _item == null) return;
    // Si la temporada ya trae episodios del primer getDetails, no re-pedir
    final existing = _item!.seasons.where((s) => s.number == seasonNumber);
    if (existing.isNotEmpty && existing.first.episodes.isNotEmpty) {
      _loadedSeasons.add(seasonNumber);
      return;
    }
    setState(() => _loadingSeason = true);
    try {
      final updated = await ContentService.instance.getDetails(
        widget.repo,
        widget.itemId,
        season: seasonNumber,
      );
      if (!mounted) return;
      if (updated != null) {
        setState(() {
          _item = updated;
          _loadedSeasons.add(seasonNumber);
          _loadingSeason = false;
        });
      } else {
        setState(() => _loadingSeason = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSeason = false);
    }
  }

  Future<void> _loadWatchState() async {
    try {
      final lib = context.read<LibraryService>();
      _isFavorite = lib.isFavorite(widget.repo.manifest.id, widget.itemId);

      final entry = await DesktopPlayerPage.loadHistorialEntry(
        repoId: widget.repo.manifest.id,
        contentId: widget.itemId,
      );
      if (entry != null) {
        final pos = (entry['positionMs'] as num?)?.toInt() ?? 0;
        final dur = (entry['durationMs'] as num?)?.toInt() ?? 0;
        final finished = entry['finished'] == true || (dur > 0 && pos / dur >= 0.9);
        if (!finished && pos > 1500) {
          _watchPosMs = pos;
          _watchDurMs = dur;
          _watchSeason = (entry['season'] as num?)?.toInt();
          _watchEpisode = (entry['episode'] as num?)?.toInt();
        } else {
          _watchPosMs = null;
          _watchDurMs = null;
          _watchSeason = null;
          _watchEpisode = null;
        }
      } else {
        final list = lib.continueWatching(widget.repo.manifest.id);
        for (final e in list) {
          if (e.contentId == widget.itemId &&
              e.positionMs > 1500 &&
              (e.durationMs <= 0 || e.positionMs / e.durationMs < 0.9)) {
            _watchPosMs = e.positionMs;
            _watchDurMs = e.durationMs;
            break;
          }
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[Details] watch: $e');
    }
  }

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _continueLabel() {
    final isSeries = (_item?.seasons.isNotEmpty ?? false) ||
        (_item?.type == 'series' || _item?.type == 'tv');
    if (_watchPosMs != null && _watchPosMs! > 1500) {
      if (isSeries && _watchSeason != null && _watchEpisode != null) {
        return 'Continuar T$_watchSeason E$_watchEpisode · ${_fmtMs(_watchPosMs!)}';
      }
      return 'Continuar · ${_fmtMs(_watchPosMs!)}';
    }
    return 'Ver ahora';
  }

  Future<void> _toggleFavorite() async {
    final item = _item;
    if (item == null) return;
    final lib = context.read<LibraryService>();
    await lib.toggleFavorite(
      repoId: widget.repo.manifest.id,
      contentId: item.id,
      title: item.title,
      poster: item.poster,
      type: item.type,
    );
    await _loadWatchState();
  }

  DownloadItem? _downloadStatusFor({int? season, int? episode}) {
    try {
      final svc = context.watch<DownloadService>();
      final id = widget.itemId;
      final repoId = widget.repo.manifest.id;
      for (final it in svc.items) {
        if (it.repoId != repoId || it.contentId != id) continue;
        if (season != null && episode != null) {
          if (it.season == season && it.episode == episode) return it;
        } else if (it.season == null || it.episode == null) {
          return it;
        }
      }
    } catch (_) {}
    return null;
  }

  Widget _downloadIconButton({
    required VoidCallback onPressed,
    int? season,
    int? episode,
  }) {
    final dl = _downloadStatusFor(season: season, episode: episode);
    final active = dl != null &&
        (dl.status == DownloadStatus.downloading ||
            dl.status == DownloadStatus.queued ||
            dl.status == DownloadStatus.converting);
    final done = dl != null && dl.status == DownloadStatus.completed;

    return IconButton.filled(
      onPressed: active ? null : onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.12),
      ),
      tooltip: active
          ? 'Descargando…'
          : done
              ? 'Ya descargado'
              : 'Descargar',
      icon: active
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
            )
          : Icon(
              done ? Icons.download_done_rounded : Icons.download_rounded,
              color: done ? const Color(0xFF4ADE80) : Colors.white,
            ),
    );
  }

  Future<void> _downloadItem({int? season, int? episode, String? episodeTitle, String? episodeId}) async {
    final item = _item;
    if (item == null) return;
    await DownloadSheet.show(
      context: context,
      repo: widget.repo,
      item: item,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeId: episodeId,
    );
  }

  Future<void> _transmitItem({int? season, int? episode, String? episodeTitle, String? episodeId}) async {
    final item = _item;
    if (item == null) return;
    await CastSheet.show(
      context: context,
      repo: widget.repo,
      item: item,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeId: episodeId,
    );
  }

  Future<void> _play({int? season, int? episode}) async {
    final item = _item;
    if (item == null) return;

    final prefs = context.read<RepoPrefs>();
    final prefLang = widget.repo.userConfig['preferred_language'] ??
        prefs.preferredLanguage(widget.repo.manifest.id);

    List<EpisodeInfo>? eps;
    int? seasonNum = season;
    if (item.seasons.isNotEmpty) {
      final idx = _seasonIndex.clamp(0, item.seasons.length - 1);
      eps = item.seasons[idx].episodes;
      seasonNum ??= item.seasons[idx].number;
    }

    int startMs = 0;
    try {
      final entry = await DesktopPlayerPage.loadHistorialEntry(
        repoId: widget.repo.manifest.id,
        contentId: item.id,
        season: seasonNum,
        episode: episode,
      );
      if (entry != null) {
        startMs = (entry['positionMs'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DesktopPlayerPage(
        title: season != null && episode != null
            ? '${item.title} · T$season E$episode'
            : item.title,
        repo: widget.repo,
        contentId: item.id,
        poster: item.poster,
        backdrop: item.backdrop,
        logo: item.logo,
        contentType: item.type,
        preferredLanguage: prefLang,
        season: seasonNum,
        episode: episode,
        episodes: eps,
        seasonNumber: seasonNum,
        startPositionMs: startMs,
      ),
    ));
    if (mounted) await _loadWatchState();
  }

  bool get _isSeries {
    final item = _item;
    if (item == null) return false;
    final typed = item.seasons.isNotEmpty || item.type == 'series' || item.type == 'tv';
    if (!typed) return false;
    var totalEps = 0;
    for (final s in item.seasons) {
      totalEps += s.episodes.length;
    }
    if (item.seasons.length == 1 && totalEps <= 1) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }
    if (_error != null || _item == null) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? 'Error', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    final item = _item!;
    try {
      context.watch<DownloadService>();
    } catch (_) {}

    if (_showEpisodes && _isSeries) {
      return _EpisodesView(
        item: item,
        seasonIndex: _seasonIndex,
        loadingSeason: _loadingSeason,
        onBack: () => setState(() => _showEpisodes = false),
        onSelectSeason: (i) {
          setState(() => _seasonIndex = i);
          _ensureSeasonEpisodes(item.seasons[i].number);
        },
        onPlayEpisode: (se, ep) => _play(season: se, episode: ep),
        onDownloadEpisode: context.watch<SettingsService>().downloadsEnabled
            ? (se, ep, title, id) => _downloadItem(
                  season: se,
                  episode: ep,
                  episodeTitle: title,
                  episodeId: id,
                )
            : null,
        onTransmitEpisode: null,
        downloadIconBuilder: context.watch<SettingsService>().downloadsEnabled
            ? (se, ep) {
                final dl = _downloadStatusFor(season: se, episode: ep);
                final active = dl != null &&
                    (dl.status == DownloadStatus.downloading ||
                        dl.status == DownloadStatus.queued ||
                        dl.status == DownloadStatus.converting);
                final done = dl != null && dl.status == DownloadStatus.completed;
                if (active) {
                  return const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white70),
                  );
                }
                return Icon(
                  done ? Icons.download_done_rounded : Icons.download_rounded,
                  color: done ? const Color(0xFF4ADE80) : Colors.white54,
                );
              }
            : null,
      );
    }

    final downloadsOn = context.watch<SettingsService>().downloadsEnabled;
    return _InfoView(
      item: item,
      isSeries: _isSeries,
      playLabel: _continueLabel(),
      isFavorite: _isFavorite,
      downloadsOn: downloadsOn,
      onBack: () => Navigator.of(context).maybePop(),
      onPlay: () async {
        if (_watchSeason != null && _watchEpisode != null) {
          await _play(season: _watchSeason, episode: _watchEpisode);
        } else {
          await _play();
        }
      },
      onFavorite: _toggleFavorite,
      downloadButton: downloadsOn && !_isSeries
          ? _downloadIconButton(onPressed: () => _downloadItem())
          : null,
      transmitButton: null,
      onEpisodes: _isSeries ? () => setState(() => _showEpisodes = true) : null,
    );
  }
}

/// Logo siempre anclado a la izquierda (sin saltar al centro mientras carga).
class _LeftLogo extends StatelessWidget {
  final String? logoUrl;
  final String title;
  final double height;

  const _LeftLogo({
    required this.logoUrl,
    required this.title,
    this.height = 72,
  });

  @override
  Widget build(BuildContext context) {
    final url = logoUrl?.trim() ?? '';
    // Ancho máximo estable a la izquierda; el contenido se alinea a start
    return SizedBox(
      height: height,
      width: 320,
      child: Align(
        alignment: Alignment.centerLeft,
        child: url.isEmpty
            ? Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              )
            : CachedNetworkImage(
                imageUrl: url,
                height: height,
                // Importante: no centrar el bitmap dentro del box
                alignment: Alignment.centerLeft,
                fit: BoxFit.contain,
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
              ),
      ),
    );
  }
}

/// Vista principal tipo TV: backdrop + gradiente + logo + botones.
class _InfoView extends StatelessWidget {
  final ContentItem item;
  final bool isSeries;
  final String playLabel;
  final bool isFavorite;
  final bool downloadsOn;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final Widget? downloadButton;
  final Widget? transmitButton;
  final VoidCallback? onEpisodes;

  const _InfoView({
    required this.item,
    required this.isSeries,
    required this.playLabel,
    required this.isFavorite,
    required this.downloadsOn,
    required this.onBack,
    required this.onPlay,
    required this.onFavorite,
    this.downloadButton,
    this.transmitButton,
    this.onEpisodes,
  });

  @override
  Widget build(BuildContext context) {
    final bgUrl = item.backdrop ?? item.poster;

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (bgUrl != null && bgUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: bgUrl,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const ColoredBox(color: _bg),
            )
          else
            const ColoredBox(color: _bg),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.2),
                  Colors.black.withValues(alpha: 0.5),
                  Colors.black.withValues(alpha: 0.94),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton(
                  tooltip: 'Volver',
                  onPressed: onBack,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                  ),
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 26),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 24, 48, 40),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo fijo a la izquierda (no salta al centro)
                      _LeftLogo(logoUrl: item.logo, title: item.title, height: 72),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 6,
                        children: [
                          if (item.year != null)
                            Text('${item.year}', style: const TextStyle(color: Colors.white70)),
                          if (item.rating != null)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
                                const SizedBox(width: 4),
                                Text(
                                  item.rating!.toStringAsFixed(1),
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                          Text(
                            item.type.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      if ((item.overview ?? '').isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          item.overview ?? '',
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            height: 1.4,
                            fontSize: 14.5,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: onPlay,
                            icon: const Icon(Icons.play_arrow_rounded, size: 26),
                            label: Text(playLabel),
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
                              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                              textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ),
                          if (onEpisodes != null)
                            OutlinedButton.icon(
                              onPressed: onEpisodes,
                              icon: const Icon(Icons.list_rounded),
                              label: const Text('Ver capítulos'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white38),
                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                              ),
                            ),
                          IconButton.filled(
                            onPressed: onFavorite,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withValues(alpha: 0.12),
                            ),
                            icon: Icon(
                              isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              color: isFavorite ? _accent : Colors.white,
                            ),
                            tooltip: isFavorite ? 'Quitar favorito' : 'Favorito',
                          ),
                          if (downloadButton != null) downloadButton!,
                          if (transmitButton != null) transmitButton!,
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

/// Vista de capítulos: AppBar principal + temporadas | episodios.
class _EpisodesView extends StatelessWidget {
  final ContentItem item;
  final int seasonIndex;
  final bool loadingSeason;
  final VoidCallback onBack;
  final ValueChanged<int> onSelectSeason;
  final void Function(int season, int episode) onPlayEpisode;
  final void Function(int season, int episode, String? title, String? id)? onDownloadEpisode;
  final void Function(int season, int episode, String? title, String? id)? onTransmitEpisode;
  final Widget Function(int season, int episode)? downloadIconBuilder;

  const _EpisodesView({
    required this.item,
    required this.seasonIndex,
    required this.loadingSeason,
    required this.onBack,
    required this.onSelectSeason,
    required this.onPlayEpisode,
    this.onDownloadEpisode,
    this.onTransmitEpisode,
    this.downloadIconBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final seasons = item.seasons;
    final safeIdx = seasonIndex.clamp(0, seasons.isEmpty ? 0 : seasons.length - 1);
    final season = seasons.isEmpty ? null : seasons[safeIdx];
    final eps = season?.episodes ?? const <EpisodeInfo>[];
    final bgUrl = item.backdrop ?? item.poster;

    return Scaffold(
      backgroundColor: _bg,
      // Barra principal de la ventana (siempre visible en capítulos)
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1116),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Volver',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
        ),
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (bgUrl != null && bgUrl.isNotEmpty)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: bgUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const ColoredBox(color: _bg),
              ),
            ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                color: Colors.black.withValues(alpha: 0.55),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Temporadas
              Container(
                width: 200,
                decoration: const BoxDecoration(
                  color: Color(0xCC0B0D10),
                  border: Border(right: BorderSide(color: _border)),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: seasons.length,
                  itemBuilder: (context, i) {
                    final s = seasons[i];
                    final active = i == safeIdx;
                    return ListTile(
                      selected: active,
                      selectedTileColor: _accent.withValues(alpha: 0.15),
                      title: Text(
                        'Temporada ${s.number}',
                        style: TextStyle(
                          color: active ? _accent : Colors.white,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      subtitle: s.name != null &&
                              s.name!.isNotEmpty &&
                              s.name != 'Temporada ${s.number}'
                          ? Text(
                              s.name!,
                              style: const TextStyle(color: Colors.white38, fontSize: 12),
                            )
                          : null,
                      onTap: () => onSelectSeason(i),
                    );
                  },
                ),
              ),
              // Episodios
              Expanded(
                child: loadingSeason
                    ? const Center(child: CircularProgressIndicator(color: _accent))
                    : eps.isEmpty
                        ? const Center(
                            child: Text('Sin episodios', style: TextStyle(color: Colors.white38)),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(20),
                            itemCount: eps.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, i) {
                              final ep = eps[i];
                              return Material(
                                color: _card,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => onPlayEpisode(season!.number, ep.number),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 40,
                                          height: 40,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(alpha: 0.06),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            '${ep.number}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        if (ep.still != null && ep.still!.isNotEmpty) ...[
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: SizedBox(
                                              width: 120,
                                              height: 68,
                                              child: CachedNetworkImage(
                                                imageUrl: ep.still!,
                                                fit: BoxFit.cover,
                                                errorWidget: (_, __, ___) =>
                                                    Container(color: const Color(0xFF12151C)),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                        ],
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                (ep.title != null && ep.title!.isNotEmpty)
                                                    ? ep.title!
                                                    : 'Episodio ${ep.number}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14.5,
                                                ),
                                              ),
                                              if ((ep.overview ?? '').isNotEmpty) ...[
                                                const SizedBox(height: 3),
                                                Text(
                                                  ep.overview!,
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12.5,
                                                    height: 1.3,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        if (onTransmitEpisode != null)
                                          IconButton(
                                            tooltip: 'Transmitir',
                                            onPressed: () => onTransmitEpisode!(
                                              season!.number,
                                              ep.number,
                                              ep.title,
                                              ep.id,
                                            ),
                                            icon: const Icon(Icons.cast_rounded, color: Colors.white54),
                                          ),
                                        if (onDownloadEpisode != null)
                                          IconButton(
                                            tooltip: 'Descargar',
                                            onPressed: () => onDownloadEpisode!(
                                              season!.number,
                                              ep.number,
                                              ep.title,
                                              ep.id,
                                            ),
                                            icon: downloadIconBuilder != null
                                                ? downloadIconBuilder!(season!.number, ep.number)
                                                : const Icon(Icons.download_rounded, color: Colors.white54),
                                          ),
                                        const Icon(
                                          Icons.play_circle_outline_rounded,
                                          color: Colors.white38,
                                          size: 28,
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
        ],
      ),
    );
  }
}