import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';

import '../../data/datasources/remote/tmdb/tmdb_content.dart';
import '../../data/datasources/remote/tmdb/tmdb_recommendations_api.dart';
import '../../supabase/guardados_service.dart';
import '../servers/servers_modal.dart';

const _kAccent = Color(0xFFE50914);
const _kBg = Color(0xFF0A0A0A);

/// Página de contenido (diseño TV adaptado a Windows).
/// Solo ratón + scroll. Sin FocusNode / mando.
/// Play / capítulo → ServidoresModal → player.
class PageContenido extends StatefulWidget {
  final int idcontenido;
  final int? tmdbId;
  final String? mediaType;

  const PageContenido({
    super.key,
    required this.idcontenido,
    this.tmdbId,
    this.mediaType,
  });

  @override
  State<PageContenido> createState() => _PageContenidoState();
}

class _PageContenidoState extends State<PageContenido> {
  final _tmdb = TmdbContentService();
  final _reco = TmdbRecommendationsService();

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;
  int _selectedSeasonIndex = 0;
  bool _isSaved = false;
  bool _overviewExpanded = false;

  List<Map<String, dynamic>> _recommendations = [];
  bool _recoLoading = false;

  int get _resolvedTmdbId =>
      widget.tmdbId ?? widget.idcontenido;

  String get _resolvedMediaType {
    final m = (widget.mediaType ?? 'movie').toLowerCase();
    if (m == 'tv' || m == 'serie' || m == 'series') return 'tv';
    return 'movie';
  }

  List<Map<String, dynamic>> get _seasons {
    final all = List<Map<String, dynamic>>.from(_data?['seasons'] ?? []);
    return all.where((s) {
      final n = (s['season_number'] as num?)?.toInt() ?? -1;
      final eps = List.from(s['episodes'] ?? []);
      return n > 0 && eps.isNotEmpty;
    }).toList();
  }

  List<Map<String, dynamic>> get _currentEpisodes {
    final seasons = _seasons;
    if (seasons.isEmpty) return [];
    final idx = _selectedSeasonIndex.clamp(0, seasons.length - 1);
    return List<Map<String, dynamic>>.from(seasons[idx]['episodes'] ?? []);
  }

  int get _currentSeasonNumber {
    final seasons = _seasons;
    if (seasons.isEmpty) return 1;
    final idx = _selectedSeasonIndex.clamp(0, seasons.length - 1);
    return (seasons[idx]['season_number'] as num?)?.toInt() ?? 1;
  }

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _tmdb.fetchContent(
        tmdbId: _resolvedTmdbId,
        mediaType: _resolvedMediaType,
      );
      if (!mounted) return;
      if (json['success'] == true && json['data'] != null) {
        setState(() {
          _data = Map<String, dynamic>.from(json['data'] as Map);
          _loading = false;
          _selectedSeasonIndex = 0;
        });
        _loadSaved();
        _loadRecommendations();
      } else {
        setState(() {
          _error = json['error']?.toString() ?? 'No se encontró el contenido';
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Sin conexión';
        _loading = false;
      });
    }
  }

  Future<void> _loadSaved() async {
    final saved = await GuardadosService.isSaved(widget.idcontenido);
    if (mounted) setState(() => _isSaved = saved);
  }

  Future<void> _toggleSaved() async {
    final item = {
      'idcontenido': widget.idcontenido,
      'tmdb_id': _resolvedTmdbId,
      'titulo': _title,
      'title': _title,
      'poster': _posterUrl,
      'poster_path': _posterUrl,
      'backdrop_path': _backdropUrl,
      'media_type': _resolvedMediaType,
      'type': _resolvedMediaType,
    };
    final result = await GuardadosService.toggle(item);
    if (mounted) setState(() => _isSaved = result);
  }

  Future<void> _loadRecommendations() async {
    setState(() => _recoLoading = true);
    try {
      final list = await _reco.fetchRecommendations(
        tmdbId: _resolvedTmdbId,
        mediaType: _resolvedMediaType,
      );
      if (!mounted) return;
      setState(() {
        _recommendations = list;
        _recoLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _recoLoading = false);
    }
  }

  String get _title {
    final d = _data;
    if (d == null) return '';
    return (d['title'] ?? d['name'] ?? '').toString();
  }

  String? get _backdropUrl {
    final path = _data?['backdrop_path'];
    return _img(path, size: 'w1280');
  }

  String? get _posterUrl {
    final path = _data?['poster_path'];
    return _img(path, size: 'w500');
  }

  String? get _logoUrl {
    final path = _data?['logo_path'];
    return _img(path, size: 'w500');
  }

  String? _img(dynamic path, {String size = 'w500'}) {
    if (path == null) return null;
    final s = path.toString();
    if (s.isEmpty) return null;
    if (s.startsWith('http')) return s;
    return 'https://image.tmdb.org/t/p/$size$s';
  }

  String get _overview => (_data?['overview'] ?? '').toString();

  String get _year {
    final d = (_data?['release_date'] ?? _data?['first_air_date'] ?? '')
        .toString();
    if (d.length >= 4) return d.substring(0, 4);
    return '';
  }

  String get _runtime {
    final d = _data;
    if (d == null) return '';
    if (_resolvedMediaType == 'movie') {
      final r = d['runtime'];
      if (r is num && r > 0) return '${r.toInt()} min';
    } else {
      final list = d['episode_run_time'];
      if (list is List && list.isNotEmpty) {
        final r = list.first;
        if (r is num) return '${r.toInt()} min';
      }
    }
    return '';
  }

  String get _rating {
    final v = _data?['vote_average'];
    if (v is num && v > 0) return v.toStringAsFixed(1);
    return '';
  }

  List<String> get _genres {
    final g = _data?['genres'];
    if (g is! List) return [];
    return g
        .whereType<Map>()
        .map((e) => (e['name'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .take(4)
        .toList();
  }

  // ── Servidores ──────────────────────────────────────────────────────────

  void _openServidores({int? temporada, int? capitulo}) {
    final tipo = _resolvedMediaType == 'tv' ? 'tv' : 'movie';
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => ServidoresModal(
        idcontenido: _resolvedTmdbId,
        tmdbId: _resolvedTmdbId,
        temporada: temporada,
        capitulo: capitulo,
        tipo: tipo,
        titulo: _title,
        backdropUrl: _backdropUrl,
        posterUrl: _posterUrl,
        logoUrl: _logoUrl,
      ),
    );
  }

  void _playMovie() => _openServidores();

  void _playEpisode(Map<String, dynamic> ep) {
    final epNum = (ep['episode_number'] as num?)?.toInt() ?? 1;
    _openServidores(temporada: _currentSeasonNumber, capitulo: epNum);
  }

  void _openRecommendation(Map<String, dynamic> item) {
    final id = item['id'];
    if (id == null) return;
    final tmdbId = int.tryParse(id.toString()) ?? 0;
    final mt = (item['media_type'] ?? _resolvedMediaType).toString();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PageContenido(
          idcontenido: tmdbId,
          tmdbId: tmdbId,
          mediaType: mt,
        ),
      ),
    );
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _kBg,
        body: Center(
          child: CircularProgressIndicator(color: _kAccent),
        ),
      );
    }
    if (_error != null || _data == null) {
      return Scaffold(
        backgroundColor: _kBg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? 'Error',
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _fetch,
                style: FilledButton.styleFrom(backgroundColor: _kAccent),
                child: const Text('Reintentar'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Volver'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _kBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop
          if (_backdropUrl != null)
            CachedNetworkImage(
              imageUrl: _backdropUrl!,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(color: _kBg),
            )
          else
            Container(color: _kBg),

          // Gradientes (estilo TV)
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withOpacity(0.92),
                  Colors.black.withOpacity(0.75),
                  Colors.black.withOpacity(0.35),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.35, 0.6, 1.0],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  _kBg,
                  _kBg.withOpacity(0.85),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.25, 0.55],
              ),
            ),
          ),

          // Contenido scrolleable
          CustomScrollView(
            slivers: [
              // Barra superior
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          tooltip: 'Volver',
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),

              // Hero info
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 12, 40, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Poster
                      if (_posterUrl != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: _posterUrl!,
                            width: 180,
                            height: 270,
                            fit: BoxFit.cover,
                          ),
                        ),
                      const SizedBox(width: 28),
                      // Info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Logo o título
                            if (_logoUrl != null)
                              CachedNetworkImage(
                                imageUrl: _logoUrl!,
                                height: 72,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                errorWidget: (_, __, ___) => Text(
                                  _title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              )
                            else
                              Text(
                                _title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            const SizedBox(height: 12),
                            // Meta
                            Wrap(
                              spacing: 12,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (_year.isNotEmpty)
                                  Text(_year,
                                      style: const TextStyle(
                                          color: Colors.white70)),
                                if (_runtime.isNotEmpty)
                                  Text(_runtime,
                                      style: const TextStyle(
                                          color: Colors.white70)),
                                if (_rating.isNotEmpty)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.star,
                                          color: Colors.amber, size: 16),
                                      const SizedBox(width: 4),
                                      Text(_rating,
                                          style: const TextStyle(
                                              color: Colors.white70)),
                                    ],
                                  ),
                                ..._genres.map(
                                  (g) => Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.white12,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(g,
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12)),
                                  ),
                                ),
                              ],
                            ),
                            if (_overview.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              GestureDetector(
                                onTap: () => setState(
                                    () => _overviewExpanded = !_overviewExpanded),
                                child: Text(
                                  _overview,
                                  maxLines: _overviewExpanded ? 20 : 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            // Botones
                            Row(
                              children: [
                                if (_resolvedMediaType == 'movie')
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _kAccent,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 24, vertical: 14),
                                    ),
                                    onPressed: _playMovie,
                                    icon: const Icon(Icons.play_arrow,
                                        size: 22),
                                    label: const Text('Reproducir',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                  )
                                else if (_currentEpisodes.isNotEmpty)
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _kAccent,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 24, vertical: 14),
                                    ),
                                    onPressed: () =>
                                        _playEpisode(_currentEpisodes.first),
                                    icon: const Icon(Icons.play_arrow,
                                        size: 22),
                                    label: Text(
                                      'T$_currentSeasonNumber E${(_currentEpisodes.first['episode_number'] as num?)?.toInt() ?? 1}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                const SizedBox(width: 12),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(
                                        color: Colors.white38),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 18, vertical: 14),
                                  ),
                                  onPressed: _toggleSaved,
                                  icon: Icon(
                                    _isSaved
                                        ? Icons.bookmark
                                        : Icons.bookmark_border,
                                    size: 20,
                                  ),
                                  label: Text(
                                      _isSaved ? 'Guardado' : 'Guardar'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Temporadas + episodios (solo series)
              if (_resolvedMediaType == 'tv' && _seasons.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 36, 40, 12),
                    child: Text(
                      'Temporadas',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 40,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      scrollDirection: Axis.horizontal,
                      itemCount: _seasons.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final s = _seasons[i];
                        final n =
                            (s['season_number'] as num?)?.toInt() ?? (i + 1);
                        final selected = i == _selectedSeasonIndex;
                        return ChoiceChip(
                          label: Text('T$n'),
                          selected: selected,
                          selectedColor: _kAccent,
                          backgroundColor: Colors.white12,
                          labelStyle: TextStyle(
                            color: selected ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                          onSelected: (_) {
                            setState(() => _selectedSeasonIndex = i);
                          },
                        );
                      },
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 20, 40, 10),
                    child: Text(
                      'Capítulos',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 200,
                    child: ScrollConfiguration(
                      behavior: const _EpisodesScrollBehavior(),
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        scrollDirection: Axis.horizontal,
                        itemCount: _currentEpisodes.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (_, i) {
                          final ep = _currentEpisodes[i];
                          return _EpisodeCard(
                            episode: ep,
                            onTap: () => _playEpisode(ep),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],

              // Recomendaciones
              if (_recommendations.isNotEmpty || _recoLoading) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 36, 40, 12),
                    child: Text(
                      'Recomendados',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 230,
                    child: _recoLoading
                        ? const Center(
                            child: CircularProgressIndicator(
                                color: _kAccent, strokeWidth: 2),
                          )
                        : ListView.separated(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 40),
                            scrollDirection: Axis.horizontal,
                            itemCount: _recommendations.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 12),
                            itemBuilder: (_, i) {
                              final item = _recommendations[i];
                              final title = (item['title'] ??
                                      item['name'] ??
                                      '')
                                  .toString();
                              final path = item['poster_path'];
                              final url = _img(path, size: 'w342');
                              return _HoverPoster(
                                title: title,
                                imageUrl: url,
                                onTap: () => _openRecommendation(item),
                              );
                            },
                          ),
                  ),
                ),
              ],

              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Widgets ───────────────────────────────────────────────────────────────

class _EpisodesScrollBehavior extends MaterialScrollBehavior {
  const _EpisodesScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

class _EpisodeCard extends StatefulWidget {
  final Map<String, dynamic> episode;
  final VoidCallback onTap;
  const _EpisodeCard({required this.episode, required this.onTap});

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final epNum = (ep['episode_number'] as num?)?.toInt() ?? 0;
    final name = (ep['name'] ?? 'Capítulo $epNum').toString();
    final still = ep['still_path']?.toString() ?? '';
    final url = still.isEmpty
        ? null
        : (still.startsWith('http')
            ? still
            : 'https://image.tmdb.org/t/p/w500$still');
    final overview = (ep['overview'] ?? '').toString();

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 280,
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFF1C1C24) : const Color(0xFF141418),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover ? _kAccent.withOpacity(0.6) : Colors.white10,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (url != null)
                      CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            Container(color: const Color(0xFF1C1C24)),
                      )
                    else
                      Container(color: const Color(0xFF1C1C24)),
                    if (_hover)
                      Container(
                        color: Colors.black45,
                        child: const Center(
                          child: Icon(Icons.play_circle_fill,
                              color: Colors.white, size: 48),
                        ),
                      ),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'E$epNum',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    if (overview.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HoverPoster extends StatefulWidget {
  final String title;
  final String? imageUrl;
  final VoidCallback onTap;
  const _HoverPoster({
    required this.title,
    required this.imageUrl,
    required this.onTap,
  });

  @override
  State<_HoverPoster> createState() => _HoverPosterState();
}

class _HoverPosterState extends State<_HoverPoster> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.imageUrl != null)
                          CachedNetworkImage(
                            imageUrl: widget.imageUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                Container(color: const Color(0xFF1C1C24)),
                          )
                        else
                          Container(color: const Color(0xFF1C1C24)),
                        if (_hover)
                          Container(
                            color: Colors.black45,
                            child: const Center(
                              child: Icon(Icons.play_circle_fill,
                                  color: Colors.white, size: 40),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}