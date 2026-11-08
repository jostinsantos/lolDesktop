import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../../../data/services/repo_prefs.dart';
import '../../widgets/focusable.dart';
import '../../widgets/cached_poster.dart';
import '../contenido/contenido.dart';
import '../player/player.dart';
import '../player/playertvoline_mobil.dart';
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
  final Map<String, int> _heroIndex = {};
  Timer? _heroTimer;
  bool _adsShown = false;

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
    setState(() {
      _allRows = normalized;
      _loading = false;
      _visibleRows = [];
      _revealIndex = 0;
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
        builder: (_) => PlayerMobileOnlinePage(
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

    return RefreshIndicator(
      color: const Color(0xFFE50914),
      backgroundColor: const Color(0xFF1A222D),
      onRefresh: () => _load(refresh: true),
      child: _loading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 16),
                SkeletonRow(height: 200, itemWidth: 280, count: 3),
                SizedBox(height: 20),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(height: 14, width: 120, child: ColoredBox(color: Color(0xFF1A222D))),
                ),
                SizedBox(height: 8),
                SkeletonRow(height: 160, itemWidth: 110, count: 6),
                SizedBox(height: 20),
                SkeletonRow(height: 160, itemWidth: 110, count: 6),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                for (final row in _visibleRows) ...[
                  if (row.type == HomeRowType.hero) _buildHero(row, wide),
                  if (row.type == HomeRowType.banner) _buildBanner(row, wide),
                  if (row.type == HomeRowType.row) _buildSecondary(row, posterW, wide),
                  if (row.type == HomeRowType.catalog) _buildCatalogRow(row, posterW, wide),
                ],
                // skeletons de filas aún no reveladas
                if (_visibleRows.length < _allRows.length)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: SkeletonRow(height: 150, itemWidth: 110, count: 5),
                  ),
              ],
            ),
    );
  }

  Widget _buildHero(HomeRow row, bool wide) {
    final items = row.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final ctrl = _heroControllers[row.id] ?? PageController();
    final h = wide ? 280.0 : 200.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (row.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(row.title, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
          ),
        SizedBox(
          height: h,
          child: PageView.builder(
            controller: ctrl,
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _heroIndex[row.id] = i),
            itemBuilder: (context, i) {
              final item = items[i];
              final image = item.backdrop ?? item.poster;
              return Focusable(
                onTap: () => _openItem(item),
                builder: (focused) => AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  margin: EdgeInsets.fromLTRB(wide ? 20 : 12, 8, wide ? 20 : 12, 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedPoster.backdrop(image, height: h),
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
                          child: Text(item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: wide ? 20 : 16,
                                  fontWeight: FontWeight.bold)),
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
    );
  }

  Widget _buildBanner(HomeRow row, bool wide) {
    final img = row.bannerImage ??
        (row.items.isNotEmpty ? (row.items.first.backdrop ?? row.items.first.poster) : null);
    if (img == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 10, wide ? 20 : 12, 10),
      child: Focusable(
        onTap: () {
          if (row.items.isNotEmpty) _openItem(row.items.first);
        },
        builder: (focused) => AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: wide ? 100.0 : 80.0,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedPoster.backdrop(img, height: wide ? 100 : 80),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondary(HomeRow row, double posterW, bool wide) {
    final useBackdrop = row.imageStyle == 'backdrop';
    final h = useBackdrop ? (wide ? 140.0 : 110.0) : posterW * 1.5;
    final w = useBackdrop ? (wide ? 220.0 : 160.0) : posterW;

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
                onTap: () => _openItem(item),
                builder: (focused) => AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: w,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: useBackdrop
                        ? CachedPoster.backdrop(img, height: h)
                        : CachedPoster.poster(img, width: w, height: h),
                  ),
                ),
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
                onTap: () => _openItem(ContentItem(
                  id: item.id,
                  title: item.title,
                  poster: item.poster,
                  backdrop: item.backdrop,
                  type: 'catalog',
                )),
                builder: (focused) => AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: wide ? 260.0 : 200.0,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
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
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
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
    );
  }
}