import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../widgets/focusable.dart';
import '../../widgets/cached_poster.dart';
import '../contenido/contenido.dart';
import '../main_home.dart';
import '../player/player.dart';
import '../player/playertvoline_tv.dart';
import 'catalogo_page.dart';
import 'catalogo_individual.dart';

/// Home del repo: carga progresiva fila a fila + skeleton + pull-to-refresh.
class RepoHomePage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoHomePage({super.key, required this.repo});

  @override
  State<RepoHomePage> createState() => _RepoHomePageState();
}

class _RepoHomePageState extends State<RepoHomePage> {
  List<HomeRow> _allRows = [];
  List<HomeRow> _visibleRows = [];
  bool _loading = true;
  int _revealIndex = 0;
  Timer? _revealTimer;
  final Map<String, PageController> _heroControllers = {};
  final ScrollController _scroll = ScrollController();
  final Map<String, int> _heroIndex = {};
  Timer? _heroTimer;
  bool _adsShown = false;
  bool _didAutoFocus = false;
  bool _scrolledTopForFirst = false;

  /// Imagen de fondo dinámica según el elemento enfocado.
  String? _bgImage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh) {
      setState(() {
        _loading = true;
        _visibleRows = [];
        _revealIndex = 0;
      });
    }
    _revealTimer?.cancel();
    final rows = await ContentService.instance.getHome(widget.repo, forceRefresh: refresh);
    final normalized = <HomeRow>[];
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
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
      // títulos limpios
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
    if (!mounted) return;

    // Imagen inicial del primer hero (o primera fila)
    String? initialBg;
    if (normalized.isNotEmpty) {
      final first = normalized.firstWhere(
        (r) => r.type == HomeRowType.hero && r.items.isNotEmpty,
        orElse: () => normalized.first,
      );
      if (first.items.isNotEmpty) {
        initialBg = first.items.first.backdrop ?? first.items.first.poster;
      }
    }

    setState(() {
      _allRows = normalized;
      _loading = false;
      _visibleRows = [];
      _revealIndex = 0;
      if (initialBg != null) _bgImage = initialBg;
    });
    _maybeShowAds();
    _revealNext();
    _startHeroAutoplay();
  }

  void _revealNext() {
    _revealTimer?.cancel();
    if (_revealIndex >= _allRows.length) return;
    setState(() {
      _visibleRows = _allRows.sublist(0, _revealIndex + 1);
      _revealIndex++;
    });
    if (_revealIndex < _allRows.length) {
      _revealTimer = Timer(const Duration(milliseconds: 120), _revealNext);
    }
  }

  void _startHeroAutoplay() {
    _heroTimer?.cancel();
    _heroTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted) return;
      for (final r in _allRows.where((e) => e.type == HomeRowType.hero)) {
        final c = _heroControllers[r.id];
        if (c == null || !c.hasClients || r.items.length < 2) continue;
        final next = ((_heroIndex[r.id] ?? 0) + 1) % r.items.length;
        _heroIndex[r.id] = next;
        c.animateToPage(next, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
      }
    });
  }

  /// Actualiza el fondo con la imagen del elemento enfocado.
  void _setFocusedImage(String? image) {
    if (image == null || image == _bgImage) return;
    setState(() => _bgImage = image);
  }

  Future<void> _maybeShowAds() async {
    if (_adsShown || !mounted) return;
    _adsShown = true;
    try {
      final prefs = context.read<RepoPrefs>();
      final repoId = widget.repo.manifest.id;
      // Solo la primera vez que se entra al repo
      if (prefs.adsShown(repoId)) {
        // Aun así refrescar y guardar el aviso para Configuración
        final ads = await ContentService.instance.getAds(widget.repo);
        if (ads.isNotEmpty) {
          final a = ads.first;
          await prefs.saveLastAd(
            repoId,
            title: (a['title'] ?? a['name'] ?? 'Aviso').toString(),
            message: (a['message'] ?? a['body'] ?? a['text'] ?? a['description'] ?? '').toString(),
            image: (a['image'] ?? a['imageUrl'] ?? a['poster'] ?? a['banner'] ?? '').toString(),
            url: (a['url'] ?? a['link'] ?? a['href'] ?? '').toString(),
          );
        }
        return;
      }
      final ads = await ContentService.instance.getAds(widget.repo);
      if (!mounted || ads.isEmpty) return;
      final a = ads.first;
      final title = (a['title'] ?? a['name'] ?? 'Aviso').toString();
      final message = (a['message'] ?? a['body'] ?? a['text'] ?? a['description'] ?? '').toString();
      final image = (a['image'] ?? a['imageUrl'] ?? a['poster'] ?? a['banner'] ?? '').toString();
      final url = (a['url'] ?? a['link'] ?? a['href'] ?? '').toString();
      await prefs.saveLastAd(repoId, title: title, message: message, image: image, url: url);
      await prefs.setAdsShown(repoId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          final accent = widget.repo.manifest.accentColor;
          return Dialog(
            backgroundColor: const Color(0xFF1A1F2A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (image.isNotEmpty)
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Image.network(image, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(height: 120)),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 48, 8),
                        child: Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                      ),
                      if (message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(message,
                              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.35)),
                        ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Row(
                          children: [
                            const Spacer(),
                            if (url.isNotEmpty)
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: accent),
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Ver'),
                              )
                            else
                              FilledButton(
                                style: FilledButton.styleFrom(backgroundColor: accent),
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Entendido'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Cerrar',
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _heroTimer?.cancel();
    for (final c in _heroControllers.values) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _openItem(ContentItem item) {
    if (item.type == 'catalog') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CatalogDetailPage(repo: widget.repo, catalogId: item.id, title: item.title),
      ));
      return;
    }
    // Canales en vivo: player media_kit dedicado (sin barra de progreso).
    if (item.isChannel) {
      final prefs = context.read<RepoPrefs>();
      final prefLang = widget.repo.userConfig['preferred_language'] ??
          prefs.preferredLanguage(widget.repo.manifest.id);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerTvOnlinePage(
          title: item.currentProgram != null
              ? '${item.title} · ${item.currentProgram}'
              : item.title,
          url: '',
          repoId: widget.repo.manifest.id,
          contentId: item.id,
          poster: item.poster,
          backdrop: item.backdrop,
          logo: item.logo,
          contentType: item.type,
          servers: const [],
          preferredLanguage: prefLang,
          loadRepo: widget.repo,
        ),
      ));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final posterW = context.watch<RepoPrefs>().posterWidth(widget.repo.manifest.id);
    final wide = MediaQuery.sizeOf(context).width > 700;
    final firstContentRowId = () {
      for (final r in _visibleRows) {
        if (r.type == HomeRowType.row) return r.id;
      }
      return null;
    }();

    // ClipRect evita que el fondo/blur se pinte encima del menú lateral (56 px)
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          // ── 1. Fondo dinámico (solo dentro del área de contenido)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 600),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _bgImage != null
                    ? KeyedSubtree(
                        key: ValueKey(_bgImage),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return CachedPoster.backdrop(
                              _bgImage,
                              height: constraints.maxHeight,
                            );
                          },
                        ),
                      )
                    : const ColoredBox(
                        key: ValueKey('empty-bg'),
                        color: Color(0xFF0B0F14),
                      ),
              ),
            ),
          ),

          // ── 2. Overlay blur + oscurecimiento elegante
          Positioned.fill(
            child: IgnorePointer(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x73000000), // ~45%
                        Color(0x8C000000), // ~55%
                        Color(0xB3000000), // ~70%
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── 3. Contenido
          Positioned.fill(
            child: RefreshIndicator(
              color: const Color(0xFFE50914),
              backgroundColor: const Color(0xFF1A222D),
              onRefresh: () => _load(refresh: true),
              child: _loading
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 16),
                        SkeletonRow(height: 160, itemWidth: 200, count: 4),
                        const SizedBox(height: 20),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: SizedBox(height: 14, width: 120, child: ColoredBox(color: Color(0xFF1A222D))),
                        ),
                        const SizedBox(height: 8),
                        SkeletonRow(height: 120, itemWidth: 80, count: 7),
                        const SizedBox(height: 20),
                        SkeletonRow(height: 120, itemWidth: 80, count: 7),
                      ],
                    )
                  : ListView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 32),
                      children: [
                        for (final row in _visibleRows) ...[
                          if (row.type == HomeRowType.hero) _buildHero(row, wide),
                          if (row.type == HomeRowType.banner) _buildBanner(row, wide),
                          if (row.type == HomeRowType.row)
                            _buildSecondary(
                              row,
                              posterW,
                              wide,
                              isFirstContentSlider: row.id == firstContentRowId,
                            ),
                          if (row.type == HomeRowType.catalog) _buildCatalogRow(row, posterW, wide),
                        ],
                        // skeletons de filas aún no reveladas
                        if (_visibleRows.length < _allRows.length)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SkeletonRow(height: 120, itemWidth: 80, count: 6),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(HomeRow row, bool wide) {
    final items = row.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final ctrl = _heroControllers[row.id] ?? PageController();
    final h = 200.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: h,
          child: ExcludeFocus(
            child: PageView.builder(
              controller: ctrl,
              itemCount: items.length,
              onPageChanged: (i) {
                setState(() => _heroIndex[row.id] = i);
                final item = items[i];
                _setFocusedImage(item.backdrop ?? item.poster);
              },
              itemBuilder: (context, i) {
                final item = items[i];
                final image = item.backdrop ?? item.poster;
                return Focusable(
                  isFirstInRow: i == 0,
                  onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
                  onTap: () => _openItem(item),
                  builder: (focused) {
                    if (focused) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _setFocusedImage(item.backdrop ?? item.poster);
                      });
                    }
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: focused ? 16 : 10,
                            offset: Offset(0, focused ? 6 : 4),
                          ),
                          if (focused)
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.16),
                              blurRadius: 14,
                            ),
                        ],
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: focused ? 0.55 : 0.28),
                              Colors.white.withValues(alpha: focused ? 0.18 : 0.09),
                              Colors.white.withValues(alpha: focused ? 0.2 : 0.0),
                            ],
                            stops: const [0.0, 0.35, 1.0],
                          ),
                        ),
                        padding: EdgeInsets.all(focused ? 2.0 : 1.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(focused ? 10 : 11),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CachedPoster.backdrop(image, height: h),
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                height: 40,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.white.withValues(alpha: focused ? 0.16 : 0.08),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Color(0xCC000000)],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 14,
                                child: Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: wide ? 20 : 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBanner(HomeRow row, bool wide) {
    final img = row.bannerImage ??
        (row.items.isNotEmpty ? (row.items.first.backdrop ?? row.items.first.poster) : null);
    if (img == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 10, wide ? 20 : 12, 10),
      child: Focusable(
        isFirstInRow: true,
        onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
        onTap: () {
          if (row.items.isNotEmpty) _openItem(row.items.first);
        },
        builder: (focused) {
          if (focused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _setFocusedImage(img);
            });
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            height: 72.0,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.transparent, width: 0),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedPoster.backdrop(img, height: 72),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSecondary(
    HomeRow row,
    double posterW,
    bool wide, {
    bool isFirstContentSlider = false,
  }) {
    final useBackdrop = row.imageStyle == 'backdrop';
    final h = useBackdrop ? 100.0 : 120.0;
    final w = useBackdrop ? 170.0 : 80.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(row.title, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: h,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: row.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, j) {
              final item = row.items[j];
              final img = useBackdrop ? (item.backdrop ?? item.poster) : (item.poster ?? item.backdrop);
              return Focusable(
                autofocus: j == 0 && !_didAutoFocus,
                isFirstInRow: j == 0,
                onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
                onTap: () => _openItem(item),
                builder: (focused) {
                  if (focused) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;

                      _setFocusedImage(item.backdrop ?? item.poster);

                      if (!_didAutoFocus) setState(() => _didAutoFocus = true);
                      if (isFirstContentSlider &&
                          !_scrolledTopForFirst &&
                          _scroll.hasClients &&
                          _scroll.offset > 8) {
                        _scrolledTopForFirst = true;
                        _scroll.animateTo(
                          0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                        );
                      }
                      if (!isFirstContentSlider && _scrolledTopForFirst) {
                        _scrolledTopForFirst = false;
                      }
                    });
                  }
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: w,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: focused ? 14 : 8,
                          offset: Offset(0, focused ? 5 : 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: useBackdrop
                          ? CachedPoster.backdrop(img, height: h)
                          : CachedPoster.poster(img, width: w, height: h),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCatalogRow(HomeRow row, double posterW, bool wide) {
    final h = wide ? 90.0 : 72.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Expanded(
                  child: Text(row.title.isEmpty ? 'Catálogos' : row.title,
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600))),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CatalogsPage(repo: widget.repo),
                  ));
                },
                child: const Text('Ver todos', style: TextStyle(color: Color(0xFFE50914))),
              ),
            ],
          ),
        ),
        SizedBox(
          height: h,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: row.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, j) {
              final item = row.items[j];
              return Focusable(
                isFirstInRow: j == 0,
                onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
                onTap: () => _openItem(ContentItem(
                  id: item.id,
                  title: item.title,
                  poster: item.poster,
                  backdrop: item.backdrop,
                  type: 'catalog',
                )),
                builder: (focused) {
                  if (focused) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _setFocusedImage(item.backdrop ?? item.poster);
                    });
                  }
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 180.0,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.transparent, width: 0),
                      color: const Color(0xFF1A222D),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (item.backdrop != null || item.poster != null)
                            CachedPoster.backdrop(item.backdrop ?? item.poster, height: h),
                          Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            color: Colors.black38,
                            child: Text(item.title,
                                maxLines: 2,
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}