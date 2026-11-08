import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../../../data/services/repo_prefs.dart';
import '../contenido/contenido.dart';
import '../player/player.dart';
import 'catalogo_individual.dart';
import '../../widgets/h_scroller.dart';

const _bg = Color(0xFF0B0D10);
const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

String formatTitle(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  var t = raw.trim();
  t = t.replaceAll(RegExp(r'<[^>]*>'), '');
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  return t;
}

/// Home del repo — misma lógica que TV.
class RepoHomePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoHomePage({super.key, required this.repo});

  @override
  State<RepoHomePage> createState() => _RepoHomePageState();
}

class _RepoHomePageState extends State<RepoHomePage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<HomeRow> _structureRows = [];
  List<HomeRow> _visibleRows = [];
  bool _loading = true;
  bool _loadingRow = false;
  bool _legacyFullHome = true;
  String? _error;
  int _loadIndex = 0;
  Timer? _revealTimer;
  final Map<String, PageController> _heroControllers = {};
  final Map<String, int> _heroIndex = {};
  Timer? _heroTimer;

  Color get _repoAccent {
    try {
      return widget.repo.manifest.accentColor;
    } catch (_) {
      return _accent;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _heroTimer?.cancel();
    for (final c in _heroControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh) {
      setState(() {
        _loading = true;
        _error = null;
        _visibleRows = [];
        _structureRows = [];
        _loadIndex = 0;
        _loadingRow = false;
      });
    }
    _revealTimer?.cancel();
    _heroTimer?.cancel();

    try {
      // Carga progresiva igual que móvil
      final progressive = await ContentService.instance.getHomeProgressive(
        widget.repo,
        forceRefresh: refresh,
      );
      if (!mounted) return;

      final normalized = <HomeRow>[];
      for (var i = 0; i < progressive.rows.length; i++) {
        var r = progressive.rows[i];
        if (i == 0 && r.type == HomeRowType.row) {
          r = HomeRow(
            id: r.id,
            title: r.title,
            type: HomeRowType.hero,
            items: r.items,
            imageStyle: 'backdrop',
            bannerImage: r.bannerImage,
            bannerUrl: r.bannerUrl,
            catalogId: r.catalogId,
          );
        }

        final items = r.items
            .map((e) => ContentItem(
                  id: e.id,
                  title: formatTitle(e.title),
                  poster: e.poster,
                  backdrop: e.backdrop,
                  logo: e.logo,
                  overview: e.overview,
                  type: e.type,
                  rating: e.rating,
                  year: e.year,
                  genres: e.genres,
                  seasons: e.seasons,
                  season: e.season,
                  episode: e.episode,
                  tmdbId: e.tmdbId,
                  imdbId: e.imdbId,
                  segments: e.segments,
                  extra: e.extra,
                ))
            .toList();

        normalized.add(HomeRow(
          id: r.id,
          title: r.title,
          type: r.type,
          items: items,
          bannerImage: r.bannerImage,
          bannerUrl: r.bannerUrl,
          catalogId: r.catalogId,
          imageStyle: r.imageStyle,
        ));

        if (r.type == HomeRowType.hero) {
          _heroControllers.putIfAbsent(r.id, () => PageController());
          _heroIndex[r.id] = 0;
        }
      }

      setState(() {
        _structureRows = normalized;
        _legacyFullHome = progressive.legacy;
        _loading = false;
        _error = null;
        _visibleRows = [];
        _loadIndex = 0;
      });

      unawaited(_loadNextRow());
      _startHeroAutoplay();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Carga fila a fila (API real o revelar del legado), igual que móvil.
  Future<void> _loadNextRow() async {
    if (!mounted || _loadingRow) return;
    if (_loadIndex >= _structureRows.length) return;

    _loadingRow = true;
    final skeleton = _structureRows[_loadIndex];

    HomeRow loaded = skeleton;
    if (!_legacyFullHome || skeleton.items.isEmpty) {
      try {
        final page = await ContentService.instance.loadHomeRow(
          widget.repo,
          rowId: skeleton.id,
          catalogId: skeleton.catalogId,
          page: 1,
          fallbackItems: skeleton.items,
        );
        final items = page.items
            .map((e) => ContentItem(
                  id: e.id,
                  title: formatTitle(e.title),
                  poster: e.poster,
                  backdrop: e.backdrop,
                  logo: e.logo,
                  overview: e.overview,
                  type: e.type,
                  rating: e.rating,
                  year: e.year,
                  genres: e.genres,
                  seasons: e.seasons,
                  season: e.season,
                  episode: e.episode,
                  tmdbId: e.tmdbId,
                  imdbId: e.imdbId,
                  segments: e.segments,
                  extra: e.extra,
                ))
            .toList();
        loaded = HomeRow(
          id: skeleton.id,
          title: skeleton.title,
          type: skeleton.type,
          items: items.isNotEmpty ? items : skeleton.items,
          bannerImage: skeleton.bannerImage,
          bannerUrl: skeleton.bannerUrl,
          catalogId: skeleton.catalogId,
          imageStyle: skeleton.imageStyle,
        );
      } catch (e) {
        debugPrint('[Home] load row ${skeleton.id}: $e');
        loaded = skeleton;
      }
    }

    if (!mounted) return;
    setState(() {
      _visibleRows = [..._visibleRows, loaded];
      _loadIndex++;
      _loadingRow = false;
    });

    if (loaded.type == HomeRowType.hero) {
      _heroControllers.putIfAbsent(loaded.id, () => PageController());
      _heroIndex[loaded.id] = 0;
    }

    if (_loadIndex < _structureRows.length) {
      _revealTimer?.cancel();
      _revealTimer = Timer(const Duration(milliseconds: 220), () {
        unawaited(_loadNextRow());
      });
    }
  }

  void _startHeroAutoplay() {
    _heroTimer?.cancel();
    _heroTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      for (final entry in _heroControllers.entries) {
        HomeRow? row;
        for (final r in _visibleRows) {
          if (r.id == entry.key) {
            row = r;
            break;
          }
        }
        if (row == null || row.items.length < 2) continue;
        final ctrl = entry.value;
        if (!ctrl.hasClients) continue;
        final next = ((_heroIndex[entry.key] ?? 0) + 1) % row.items.length;
        _heroIndex[entry.key] = next;
        ctrl.animateToPage(next, duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
      }
    });
  }

  void _openItem(ContentItem item) {
    if (item.type == 'catalog') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CatalogDetailPage(repo: widget.repo, catalogId: item.id, title: item.title),
      ));
      return;
    }

    if (item.isChannel) {
      final prefs = context.read<RepoPrefs>();
      final prefLang = widget.repo.userConfig['preferred_language'] ??
          prefs.preferredLanguage(widget.repo.manifest.id);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DesktopPlayerPage(
          title: item.currentProgram != null ? '${item.title} · ${item.currentProgram}' : item.title,
          repo: widget.repo,
          contentId: item.id,
          poster: item.poster,
          backdrop: item.backdrop,
          contentType: item.type,
          preferredLanguage: prefLang,
        ),
      ));
      return;
    }

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
    ));
  }

  void _openCatalogRow(HomeRow row) {
    final id = row.catalogId ?? row.id;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CatalogDetailPage(
        repo: widget.repo,
        catalogId: id,
        title: row.title.isNotEmpty ? row.title : 'Catálogo',
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _load(refresh: true),
              style: FilledButton.styleFrom(backgroundColor: _repoAccent),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (!_loading && _structureRows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_filter_outlined, size: 56, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('Este repositorio no devolvió contenido', style: TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _load(refresh: true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Actualizar'),
              style: FilledButton.styleFrom(backgroundColor: _repoAccent),
            ),
          ],
        ),
      );
    }

    final heroRows = _visibleRows.where((r) => r.type == HomeRowType.hero).toList();
    final otherRows = _visibleRows.where((r) => r.type != HomeRowType.hero).toList();

    return RefreshIndicator(
      color: _repoAccent,
      backgroundColor: _card,
      onRefresh: () => _load(refresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          for (final row in heroRows) _buildHero(row),
          // Sube las filas secundarias para fundirse con el final del hero
          if (otherRows.isNotEmpty)
            Transform.translate(
              offset: const Offset(0, -72),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in otherRows) ...[
                    if (row.type == HomeRowType.banner) _buildBanner(row),
                    if (row.type == HomeRowType.row) _buildRow(row),
                    if (row.type == HomeRowType.catalog) _buildCatalogRow(row),
                  ],
                ],
              ),
            ),
          if (_loadIndex < _structureRows.length || _loadingRow)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(color: _accent, strokeWidth: 2)),
            ),
        ],
      ),
    );
  }

  Widget _buildHero(HomeRow row) {
    if (row.items.isEmpty) return const SizedBox.shrink();
    final ctrl = _heroControllers.putIfAbsent(row.id, () => PageController());
    final screenH = MediaQuery.sizeOf(context).height;
    // Hero superior ~70% de la pantalla
    final h = (screenH * 0.70).clamp(440.0, 720.0);

    return SizedBox(
      height: h,
      child: PageView.builder(
        controller: ctrl,
        itemCount: row.items.length,
        onPageChanged: (i) => setState(() => _heroIndex[row.id] = i),
        itemBuilder: (context, i) {
          final item = row.items[i];
          final bg = item.backdrop ?? item.poster;
          return _HeroSlide(
            item: item,
            bg: bg,
            accent: _repoAccent,
            heroHeight: h,
            onTap: () => _openItem(item),
          );
        },
      ),
    );
  }

  Widget _buildBanner(HomeRow row) {
    final img = row.bannerImage ??
        (row.items.isNotEmpty ? (row.items.first.backdrop ?? row.items.first.poster) : null);
    if (img == null || img.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: GestureDetector(
        onTap: () {
          if (row.items.isNotEmpty) {
            _openItem(row.items.first);
          } else if (row.catalogId != null) {
            _openCatalogRow(row);
          }
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 21 / 6,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: img,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(color: const Color(0xFF12151C)),
                ),
                if (row.title.isNotEmpty)
                  Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black.withValues(alpha: 0.65), Colors.transparent],
                      ),
                    ),
                    child: Text(
                      row.title,
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(HomeRow row) {
    if (row.items.isEmpty) return const SizedBox.shrink();
    final wide = row.imageStyle == 'backdrop';
    final cardW = wide ? 240.0 : 140.0;
    final cardH = wide ? 140.0 : 210.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  row.title.isNotEmpty ? row.title : 'Contenido',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              if (row.items.length > 10)
                TextButton(
                  onPressed: () => _openCatalogRow(row),
                  child: Text('Ver todo', style: TextStyle(color: _repoAccent)),
                ),
            ],
          ),
        ),
        HScroller(
          height: cardH + 40,
          itemCount: row.items.length,
          itemExtent: cardW,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemBuilder: (context, i) {
            final item = row.items[i];
            return _PosterCard(
              item: item,
              width: cardW,
              height: cardH,
              wide: wide,
              accent: _repoAccent,
              onTap: () => _openItem(item),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCatalogRow(HomeRow row) {
    if (row.items.isNotEmpty) return _buildRow(row);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Material(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openCatalogRow(row),
          child: Container(
            height: 88,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(Icons.folder_open_rounded, color: _repoAccent, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    row.title.isNotEmpty ? row.title : 'Catálogo',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroSlide extends StatefulWidget {
  final ContentItem item;
  final String? bg;
  final Color accent;
  final double heroHeight;
  final VoidCallback onTap;

  const _HeroSlide({
    required this.item,
    required this.bg,
    required this.accent,
    required this.heroHeight,
    required this.onTap,
  });

  @override
  State<_HeroSlide> createState() => _HeroSlideState();
}

class _HeroSlideState extends State<_HeroSlide> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final metaParts = <String>[];
    if (item.year != null && item.year!.isNotEmpty) metaParts.add(item.year!);
    if (item.type.isNotEmpty) {
      final t = item.type.toLowerCase();
      if (t.contains('series') || t.contains('show') || t == 'tv') {
        metaParts.add('Series');
      } else if (t.contains('movie') || t.contains('film')) {
        metaParts.add('Movie');
      } else {
        metaParts.add(item.type);
      }
    }
    if (item.genres.isNotEmpty) {
      metaParts.add(item.genres.take(3).join(' · '));
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.bg != null && widget.bg!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: widget.bg!,
                fit: BoxFit.cover,
                alignment: const Alignment(0.3, 0),
                errorWidget: (_, __, ___) =>
                    Container(color: const Color(0xFF12151C)),
              )
            else
              Container(color: const Color(0xFF12151C)),
            // Gradiente izquierdo (texto legible)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xE00B0D10),
                    Color(0x880B0D10),
                    Color(0x330B0D10),
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.28, 0.55, 0.85],
                ),
              ),
            ),
            // Parte inferior: fade en el 40% bajo → termina transparente (se funde)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: widget.heroHeight * 0.40,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x000B0D10), // 0% transparente arriba del fade
                      Color(0x660B0D10),
                      Color(0xCC0B0D10),
                      Color(0xFF0B0D10), // se funde con el fondo de la app
                    ],
                    stops: [0.0, 0.35, 0.70, 1.0],
                  ),
                ),
              ),
            ),
            // Ligero oscurecido al hover
            if (_hover)
              ColoredBox(color: Colors.black.withValues(alpha: 0.12)),
            Positioned(
              left: 48,
              bottom: 56,
              right: MediaQuery.sizeOf(context).width * 0.38,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.logo != null && item.logo!.isNotEmpty)
                    ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: 320, maxHeight: 90),
                      child: CachedNetworkImage(
                        imageUrl: item.logo!,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                        errorWidget: (_, __, ___) => Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.05,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    )
                  else
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.05,
                        letterSpacing: 0.5,
                      ),
                    ),
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      metaParts.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Colors.white.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if ((item.overview ?? '').isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      item.overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: Colors.white.withValues(alpha: 0.85),
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterCard extends StatefulWidget {
  final ContentItem item;
  final double width;
  final double height;
  final bool wide;
  final Color accent;
  final VoidCallback onTap;

  const _PosterCard({
    required this.item,
    required this.width,
    required this.height,
    required this.wide,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final img = widget.wide ? (item.backdrop ?? item.poster) : (item.poster ?? item.backdrop);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _hover ? widget.accent.withValues(alpha: 0.6) : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: img != null && img.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: img,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(color: const Color(0xFF12151C)),
                        errorWidget: (_, __, ___) => Container(
                          color: const Color(0xFF12151C),
                          child: const Icon(Icons.movie_outlined, color: Colors.white12),
                        ),
                      )
                    : Container(
                        color: const Color(0xFF12151C),
                        child: const Icon(Icons.movie_outlined, color: Colors.white12),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white, height: 1.25),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
