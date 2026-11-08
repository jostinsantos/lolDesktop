import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../data/services/repo_manager.dart';
import '../../data/services/library_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/content_service.dart';
import 'dart:ui';
import '../../data/models/repo_manifest.dart';

import '../repo/main_home.dart';
import '../repo/contenido/contenido.dart';
import '../widgets/h_scroller.dart';
import 'comunidad_repos.dart';
import 'config.dart';
import 'buscar.dart';
import 'downloads_page.dart';
import 'salas_page.dart';
import '../repo/player/player.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  COLORES (igual que TV)
// ─────────────────────────────────────────────────────────────────────────────
const _bg = Color(0xFF0B0D10);
const _sidebarBg = Color(0xFF0F1218);
const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _accent = Color(0xFFE50914);
const _textMuted = Color(0x99FFFFFF);


/// Navegación global del launcher (p. ej. overlay → pestaña Descargas).
class LauncherNav {
  static final ValueNotifier<int?> goToTab = ValueNotifier<int?>(null);
}


class LauncherHome extends StatefulWidget {
  const LauncherHome({super.key});

  @override
  State<LauncherHome> createState() => _LauncherHomeState();
}

class _LauncherHomeState extends State<LauncherHome> {
  int _navIndex = 0;
  bool _loadingRepos = false;

  final _nav = const [
    (Icons.home_rounded, 'Inicio'),
    (Icons.explore_rounded, 'Comunidad'),
    (Icons.groups_rounded, 'Salas'),
    (Icons.search_rounded, 'Buscar'),
    (Icons.download_rounded, 'Descargas'),
    (Icons.settings_rounded, 'Ajustes'),
  ];

  @override
  void initState() {
    super.initState();
    LauncherNav.goToTab.addListener(_onNavRequest);
  }

  @override
  void dispose() {
    LauncherNav.goToTab.removeListener(_onNavRequest);
    super.dispose();
  }

  void _onNavRequest() {
    final i = LauncherNav.goToTab.value;
    if (i == null || !mounted) return;
    // Aplicar en el siguiente frame por si venimos de popUntil del overlay
    final target = i.clamp(0, _nav.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _navIndex = target);
    });
    setState(() => _navIndex = target);
    LauncherNav.goToTab.value = null;
  }

  Future<void> _refreshRepos() async {
    setState(() => _loadingRepos = true);
    try {
      await context.read<RepoManager>().refreshAllContent();
    } catch (_) {}
    if (mounted) setState(() => _loadingRepos = false);
  }

  void _openRepo(InstalledRepo repo) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RepoMainHome(repo: repo)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final installed = context.watch<RepoManager>().installed;

    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Fondo global del launcher (imagen + blur + oscurecido)
          _LauncherBackground(settings: settings),
          Row(
        children: [
          // ── SIDEBAR FIJA ────────────────────────────────────────────────
          _Sidebar(
            items: _nav,
            selected: _navIndex,
            onSelect: (i) => setState(() => _navIndex = i),
          ),

          // ── CONTENIDO ───────────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header superior
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    border: const Border(bottom: BorderSide(color: _border)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _nav[_navIndex].$2,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      if (_navIndex == 0)
                        IconButton(
                          tooltip: 'Actualizar repositorios',
                          onPressed: _loadingRepos ? null : _refreshRepos,
                          icon: _loadingRepos
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _accent,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded, color: Colors.white70),
                        ),
                    ],
                  ),
                ),

                // Cuerpo
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _body(installed),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
        ], // Stack
      ),
    );
  }

  Widget _body(List<InstalledRepo> installed) {
    switch (_navIndex) {
      case 0:
        return _HomeRepos(
          key: const ValueKey('home'),
          loading: _loadingRepos,
          installed: installed,
          onOpen: _openRepo,
          onGoCommunity: () => setState(() => _navIndex = 1),
        );
      case 1:
        return const CommunityPage(key: ValueKey('community'));
      case 2:
        return const SalasPage(key: ValueKey('salas'));
      case 3:
        return const LauncherSearchPage(key: ValueKey('search'));
      case 4:
        return const DownloadsPage(key: ValueKey('downloads'));
      case 5:
        return const LauncherConfigPage(key: ValueKey('config'));
      default:
        return const SizedBox.shrink();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SIDEBAR
// ─────────────────────────────────────────────────────────────────────────────
class _Sidebar extends StatelessWidget {
  final List<(IconData, String)> items;
  final int selected;
  final ValueChanged<int> onSelect;

  const _Sidebar({
    required this.items,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: _sidebarBg.withValues(alpha: 0.82),
        border: const Border(right: BorderSide(color: _border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 28),

          // Logo
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/app_icon.ico',
                    width: 38,
                    height: 38,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Image.asset(
                      'assets/tray_icon.ico',
                      width: 38,
                      height: 38,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: _accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'LOL Lite',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.3,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),

          // Items
          ...List.generate(items.length, (i) {
            final active = i == selected;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Material(
                color: active ? _accent.withValues(alpha: 0.14) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onSelect(i),
                  hoverColor: Colors.white.withValues(alpha: 0.04),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    child: Row(
                      children: [
                        Icon(
                          items[i].$1,
                          size: 22,
                          color: active ? _accent : Colors.white60,
                        ),
                        const SizedBox(width: 14),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                            color: active ? Colors.white : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),

          const Spacer(),

          // Footer
          const Padding(
            padding: EdgeInsets.only(bottom: 20),
            child: Text(
              'Desktop • Windows',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.white24),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HOME – REPOS INSTALADOS
// ─────────────────────────────────────────────────────────────────────────────
class _HomeRepos extends StatefulWidget {
  final bool loading;
  final List<InstalledRepo> installed;
  final ValueChanged<InstalledRepo> onOpen;
  final VoidCallback onGoCommunity;

  const _HomeRepos({
    super.key,
    required this.loading,
    required this.installed,
    required this.onOpen,
    required this.onGoCommunity,
  });

  @override
  State<_HomeRepos> createState() => _HomeReposState();
}

class _HomeReposState extends State<_HomeRepos> {
  final Map<String, List<Map<String, dynamic>>> _newsByRepo = {};
  bool _loadingNews = false;

  @override
  void initState() {
    super.initState();
    
    _loadNews();
  }

  @override
  void didUpdateWidget(covariant _HomeRepos oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.installed.length != widget.installed.length) {
      _loadNews();
    }
  }

  Future<void> _loadNews() async {
    if (widget.installed.isEmpty) return;
    setState(() => _loadingNews = true);
    final map = <String, List<Map<String, dynamic>>>{};
    await Future.wait(widget.installed.map((repo) async {
      try {
        final items = await ContentService.instance.getNews(repo);
        if (items.isNotEmpty) map[repo.manifest.id] = items;
      } catch (e) {
        debugPrint('[LauncherHome] news ${repo.manifest.id}: $e');
      }
    }));
    if (!mounted) return;
    setState(() {
      _newsByRepo
        ..clear()
        ..addAll(map);
      _loadingNews = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.installed.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _accent),
      );
    }

    if (widget.installed.isEmpty) {
      return _EmptyState(onGoCommunity: widget.onGoCommunity);
    }

    final lib = context.watch<LibraryService>();
    final mgr = context.watch<RepoManager>();
    final continueWatching = lib.continueWatchingAll().take(12).toList();
    final installed = widget.installed;

    return CustomScrollView(
      slivers: [
        // ── Continuar viendo ──────────────────────────────────────────────
        if (continueWatching.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(32, 28, 32, 12),
              child: Text(
                'Continuar viendo',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: HScroller(
              height: 180,
              itemCount: continueWatching.length,
              itemExtent: 280,
              spacing: 14,
              itemBuilder: (context, i) {
                final entry = continueWatching[i];
                return _ContinueCard(
                  entry: entry,
                  onTap: () {
                    final repo = installed.cast<InstalledRepo?>().firstWhere(
                          (r) => r?.manifest.id == entry.repoId,
                          orElse: () => null,
                        );
                    if (repo == null) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DesktopPlayerPage(
                          title: entry.title ?? '',
                          repo: repo,
                          contentId: entry.contentId,
                          poster: entry.poster,
                          contentType: entry.type ?? 'movie',
                          startPositionMs: entry.positionMs ?? 0,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],

        // ── Título repos ──────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 16),
            child: Row(
              children: [
                const Text(
                  'Mis repositorios',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${installed.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.white60),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Grid de repos ─────────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 280,
              mainAxisSpacing: 18,
              crossAxisSpacing: 18,
              childAspectRatio: 0.78,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final repo = installed[i];
                final hasUpdate = mgr.hasUpdate(repo.manifest.id);
                return _RepoCard(
                  repo: repo,
                  hasUpdate: hasUpdate,
                  onTap: () => widget.onOpen(repo),
                );
              },
              childCount: installed.length,
            ),
          ),
        ),

        // ── Novedades (un slider por repo, como TV) ───────────────────────
        if (_loadingNews && _newsByRepo.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: _accent))),
            ),
          )
        else if (_newsByRepo.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(32, 20, 32, 8),
              child: Text(
                'Novedades',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
          ),
          for (final repo in installed) ...[
            if (_newsByRepo.containsKey(repo.manifest.id)) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
                  child: Text(
                    repo.manifest.name,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: HScroller(
                  height: 200,
                  itemCount: _newsByRepo[repo.manifest.id]!.length,
                  itemExtent: 120,
                  itemBuilder: (context, i) {
                    final n = _newsByRepo[repo.manifest.id]![i];
                    final title = (n['title'] ?? n['name'] ?? '').toString();
                    final poster = (n['poster'] ?? n['image'] ?? n['backdrop'] ?? '').toString();
                    final id = (n['id'] ?? n['contentId'] ?? '').toString();
                    return SizedBox(
                      width: 120,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            if (id.isEmpty) return;
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => DetailsPage(repo: repo, itemId: id),
                            ));
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: poster.isNotEmpty
                                      ? CachedNetworkImage(
                                          imageUrl: poster,
                                          fit: BoxFit.cover,
                                          errorWidget: (_, __, ___) => Container(color: const Color(0xFF12151C)),
                                        )
                                      : Container(color: const Color(0xFF12151C)),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
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
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ],

      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  EMPTY STATE
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final VoidCallback onGoCommunity;
  const _EmptyState({required this.onGoCommunity});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.inbox_rounded, size: 42, color: Colors.white24),
          ),
          const SizedBox(height: 24),
          const Text(
            'No tienes repositorios instalados',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ve a Comunidad para descubrir e instalar repos',
            style: TextStyle(fontSize: 14, color: _textMuted),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: onGoCommunity,
            icon: const Icon(Icons.explore_rounded, size: 20),
            label: const Text('Ir a Comunidad'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  REPO CARD
// ─────────────────────────────────────────────────────────────────────────────
class _RepoCard extends StatefulWidget {
  final InstalledRepo repo;
  final bool hasUpdate;
  final VoidCallback onTap;

  const _RepoCard({
    required this.repo,
    required this.hasUpdate,
    required this.onTap,
  });

  @override
  State<_RepoCard> createState() => _RepoCardState();
}

class _RepoCardState extends State<_RepoCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.repo.manifest;
    final logo = m.icon;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hover ? _accent.withValues(alpha: 0.55) : _border,
            width: 1.2,
          ),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.12),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  )
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo / imagen
                Expanded(
                  flex: 5,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (logo != null && logo.isNotEmpty)
                          CachedNetworkImage(
                            imageUrl: logo,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(color: const Color(0xFF12151C)),
                            errorWidget: (_, __, ___) => _placeholder(),
                          )
                        else
                          _placeholder(),

                        // Gradiente inferior
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 60,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.7),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Badge update
                        if (widget.hasUpdate)
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: _accent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'UPDATE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),

                        // Disabled
                        if (!widget.repo.enabled)
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.55),
                              child: const Center(
                                child: Icon(Icons.block_rounded, color: Colors.white54, size: 32),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Info
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          m.description.isNotEmpty
                              ? m.description
                              : (m.author.isNotEmpty ? m.author : 'Sin descripción'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: _textMuted, height: 1.3),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Text(
                              'v${m.version}',
                              style: const TextStyle(fontSize: 11, color: Colors.white38),
                            ),
                            if (!widget.repo.enabled) ...[
                              const SizedBox(width: 8),
                              const Text(
                                'Desactivado',
                                style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF12151C),
      child: const Center(
        child: Icon(Icons.apps_rounded, size: 42, color: Colors.white12),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  CONTINUE WATCHING CARD
// ─────────────────────────────────────────────────────────────────────────────
class _ContinueCard extends StatelessWidget {
  final dynamic entry; // WatchEntry
  final VoidCallback onTap;

  const _ContinueCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress as double? ?? 0.0;
    final poster = entry.poster as String?;

    return SizedBox(
      width: 280,
      child: Material(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (poster != null && poster.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: poster,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(color: const Color(0xFF12151C)),
                        )
                      else
                        Container(color: const Color(0xFF12151C)),
                      // Progress bar
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation(_accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Text(
                  entry.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
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


/// Fondo del launcher: imagen + blur + capa de oscurecido.
class _LauncherBackground extends StatelessWidget {
  final SettingsService settings;
  const _LauncherBackground({required this.settings});

  @override
  Widget build(BuildContext context) {
    final url = settings.homeBgUrl.trim();
    final blur = settings.homeBgBlur.clamp(0.0, 32.0);
    final dim = settings.homeBgDim.clamp(0.0, 0.85);
    final mode = settings.homeBgMode;

    Widget bg;
    final hasImage = url.isNotEmpty &&
        (mode == HomeBgMode.custom ||
            mode == HomeBgMode.fixed ||
            mode == HomeBgMode.lol ||
            mode == HomeBgMode.tmdb);
    // Desactivado = fixed + URL vacía
    if (mode == HomeBgMode.fixed && url.isEmpty) {
      bg = const ColoredBox(color: _bg);
    } else if (hasImage) {
      bg = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorWidget: (_, __, ___) => const ColoredBox(color: _bg),
      );
    } else {
      bg = const ColoredBox(color: _bg);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (blur > 0.5)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: bg,
          )
        else
          bg,
        // Oscurecido encima del fondo
        ColoredBox(color: Colors.black.withValues(alpha: 0.35 + dim * 0.5)),
      ],
    );
  }
}
