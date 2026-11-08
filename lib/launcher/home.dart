import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Contador local de aperturas de repos (persiste en SharedPreferences).
/// No depende de métodos nuevos en LibraryService.
class _RepoUsage {
  static const _key = 'repo_open_counts_v1';
  static final Map<String, int> _counts = {};
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getStringList(_key) ?? [];
      for (final e in raw) {
        final i = e.lastIndexOf(':');
        if (i > 0) {
          final id = e.substring(0, i);
          final n = int.tryParse(e.substring(i + 1)) ?? 0;
          _counts[id] = n;
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = _counts.entries.map((e) => '${e.key}:${e.value}').toList();
      await p.setStringList(_key, list);
    } catch (_) {}
  }

  static int count(String repoId) => _counts[repoId] ?? 0;

  static Future<void> record(String repoId) async {
    await load();
    _counts[repoId] = (_counts[repoId] ?? 0) + 1;
    await _save();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  DESIGN TOKENS – minimalista, profesional, con profundidad sutil
// ─────────────────────────────────────────────────────────────────────────────
const _bg = Color(0xFF0A0C0F);
const _sidebarBg = Color(0xFF0C0E12);
const _card = Color(0xFF141820);
const _cardHover = Color(0xFF1A1F28);
const _border = Color(0xFF1C222C);
const _borderSubtle = Color(0xFF181C24);
const _accent = Color(0xFFE50914);
const _accentSoft = Color(0x33E50914);
const _textMuted = Color(0x8AFFFFFF);
const _textFaint = Color(0x55FFFFFF);

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
    _RepoUsage.load();
  }

  @override
  void dispose() {
    LauncherNav.goToTab.removeListener(_onNavRequest);
    super.dispose();
  }

  void _onNavRequest() {
    final i = LauncherNav.goToTab.value;
    if (i == null || !mounted) return;
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
    // Registrar uso para ordenar por más usados (local, sin tocar LibraryService)
    _RepoUsage.record(repo.manifest.id);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RepoMainHome(repo: repo)),
    );
  }

  Future<void> _deleteRepo(InstalledRepo repo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Eliminar repositorio',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '¿Seguro que quieres desinstalar «${repo.manifest.name}»?\nSe eliminarán sus datos de biblioteca asociados.',
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await context.read<RepoManager>().uninstall(repo.manifest.id);
      try {
        await context.read<LibraryService>().clearRepoData(repo.manifest.id);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${repo.manifest.name} eliminado'),
            backgroundColor: _accent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
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
          _LauncherBackground(settings: settings),
          Row(
            children: [
              _Sidebar(
                items: _nav,
                selected: _navIndex,
                onSelect: (i) => setState(() => _navIndex = i),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header superior con glass
                    ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: Container(
                          height: 60,
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            border: const Border(
                              bottom: BorderSide(color: _borderSubtle),
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _nav[_navIndex].$2,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const Spacer(),
                              if (_navIndex == 0)
                                IconButton(
                                  tooltip: 'Actualizar repositorios',
                                  onPressed: _loadingRepos ? null : _refreshRepos,
                                  icon: _loadingRepos
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: _accent,
                                          ),
                                        )
                                      : const Icon(Icons.refresh_rounded,
                                          color: Colors.white60, size: 22),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: _body(installed),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
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
          onDelete: _deleteRepo,
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
//  SIDEBAR – limpia, con indicador activo sutil
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
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: 228,
          decoration: BoxDecoration(
            color: _sidebarBg.withValues(alpha: 0.78),
            border: const Border(right: BorderSide(color: _borderSubtle)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 26),
              // Logo
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/app_icon.ico',
                        width: 34,
                        height: 34,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Image.asset(
                          'assets/tray_icon.ico',
                          width: 34,
                          height: 34,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: _accent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.play_arrow_rounded,
                                color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Text(
                      'LOL Lite',
                      style: TextStyle(
                        fontSize: 17.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.4,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
              // Items
              ...List.generate(items.length, (i) {
                final active = i == selected;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: Material(
                    color: active ? _accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(11),
                      onTap: () => onSelect(i),
                      hoverColor: Colors.white.withValues(alpha: 0.04),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 13, vertical: 12),
                        child: Row(
                          children: [
                            Icon(
                              items[i].$1,
                              size: 21,
                              color: active ? _accent : Colors.white54,
                            ),
                            const SizedBox(width: 13),
                            Text(
                              items[i].$2,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight:
                                    active ? FontWeight.w600 : FontWeight.w500,
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
              const Padding(
                padding: EdgeInsets.only(bottom: 18),
                child: Text(
                  'Desktop • Windows',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5, color: Colors.white24),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HOME – REPOS INSTALADOS (ordenados por uso)
// ─────────────────────────────────────────────────────────────────────────────
class _HomeRepos extends StatefulWidget {
  final bool loading;
  final List<InstalledRepo> installed;
  final ValueChanged<InstalledRepo> onOpen;
  final ValueChanged<InstalledRepo> onDelete;
  final VoidCallback onGoCommunity;

  const _HomeRepos({
    super.key,
    required this.loading,
    required this.installed,
    required this.onOpen,
    required this.onDelete,
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
    _RepoUsage.load();
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

  /// Ordena repos: más usados primero (contador local en SharedPreferences).
  List<InstalledRepo> _sortedRepos() {
    final list = List<InstalledRepo>.from(widget.installed);
    list.sort((a, b) {
      final usageA = _RepoUsage.count(a.manifest.id);
      final usageB = _RepoUsage.count(b.manifest.id);
      if (usageA != usageB) return usageB.compareTo(usageA); // más usados primero
      return a.manifest.name
          .toLowerCase()
          .compareTo(b.manifest.name.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.installed.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    if (widget.installed.isEmpty) {
      return _EmptyState(onGoCommunity: widget.onGoCommunity);
    }

    final lib = context.watch<LibraryService>();
    final mgr = context.watch<RepoManager>();
    final continueWatching = lib.continueWatchingAll().take(12).toList();
    final installed = _sortedRepos();

    return CustomScrollView(
      slivers: [
        // ── Continuar viendo ──────────────────────────────────────────────
        if (continueWatching.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(28, 24, 28, 10),
              child: Text(
                'Continuar viendo',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: HScroller(
              height: 172,
              itemCount: continueWatching.length,
              itemExtent: 268,
              spacing: 12,
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
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ],

        // ── Título repos ──────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 14),
            child: Row(
              children: [
                const Text(
                  'Mis repositorios',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${installed.length}',
                    style:
                        const TextStyle(fontSize: 11.5, color: Colors.white54),
                  ),
                ),
                const Spacer(),
                Text(
                  'Más usados primero',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Grid de repos ─────────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
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
                  onDelete: () => widget.onDelete(repo),
                );
              },
              childCount: installed.length,
            ),
          ),
        ),

        // ── Novedades ─────────────────────────────────────────────────────
        if (_loadingNews && _newsByRepo.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _accent),
                ),
              ),
            ),
          )
        else if (_newsByRepo.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(28, 12, 28, 6),
              child: Text(
                'Novedades',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.2),
              ),
            ),
          ),
          for (final repo in installed) ...[
            if (_newsByRepo.containsKey(repo.manifest.id)) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 10, 28, 6),
                  child: Text(
                    repo.manifest.name,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white60),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: HScroller(
                  height: 190,
                  itemCount: _newsByRepo[repo.manifest.id]!.length,
                  itemExtent: 112,
                  itemBuilder: (context, i) {
                    final n = _newsByRepo[repo.manifest.id]![i];
                    final title =
                        (n['title'] ?? n['name'] ?? '').toString();
                    final poster = (n['poster'] ??
                            n['image'] ??
                            n['backdrop'] ??
                            '')
                        .toString();
                    final id =
                        (n['id'] ?? n['contentId'] ?? '').toString();
                    return SizedBox(
                      width: 112,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            if (id.isEmpty) return;
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  DetailsPage(repo: repo, itemId: id),
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
                                          errorWidget: (_, __, ___) =>
                                              Container(
                                                  color: const Color(
                                                      0xFF10131A)),
                                        )
                                      : Container(
                                          color: const Color(0xFF10131A)),
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25),
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
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
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
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.inbox_rounded,
                size: 36, color: Colors.white24),
          ),
          const SizedBox(height: 22),
          const Text(
            'No tienes repositorios instalados',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white),
          ),
          const SizedBox(height: 6),
          const Text(
            'Ve a Comunidad para descubrir e instalar repos',
            style: TextStyle(fontSize: 13.5, color: _textMuted),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onGoCommunity,
            icon: const Icon(Icons.explore_rounded, size: 18),
            label: const Text('Ir a Comunidad'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  REPO CARD – glass + hover + menú eliminar
// ─────────────────────────────────────────────────────────────────────────────
class _RepoCard extends StatefulWidget {
  final InstalledRepo repo;
  final bool hasUpdate;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RepoCard({
    required this.repo,
    required this.hasUpdate,
    required this.onTap,
    required this.onDelete,
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
      child: AnimatedScale(
        scale: _hover ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: _hover ? _cardHover : _card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hover
                  ? _accent.withValues(alpha: 0.45)
                  : _border,
              width: 1,
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: _accent.withValues(alpha: 0.10),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    )
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.onTap,
              onLongPress: widget.onDelete,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(13)),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (logo != null && logo.isNotEmpty)
                            CachedNetworkImage(
                              imageUrl: logo,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: const Color(0xFF10131A)),
                              errorWidget: (_, __, ___) => _placeholder(),
                            )
                          else
                            _placeholder(),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 56,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.65),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (widget.hasUpdate)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _accent,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'UPDATE',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          // Botón eliminar (aparece en hover)
                          if (_hover)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Material(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: widget.onDelete,
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: Icon(Icons.delete_outline_rounded,
                                        size: 16, color: Colors.white70),
                                  ),
                                ),
                              ),
                            ),
                          if (!widget.repo.enabled)
                            Positioned.fill(
                              child: ColoredBox(
                                color: Colors.black.withValues(alpha: 0.55),
                                child: const Center(
                                  child: Icon(Icons.block_rounded,
                                      color: Colors.white54, size: 28),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            m.description.isNotEmpty
                                ? m.description
                                : (m.author.isNotEmpty
                                    ? m.author
                                    : 'Sin descripción'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5,
                                color: _textMuted,
                                height: 1.3),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Text(
                                'v${m.version}',
                                style: const TextStyle(
                                    fontSize: 10.5, color: Colors.white38),
                              ),
                              if (!widget.repo.enabled) ...[
                                const SizedBox(width: 6),
                                const Text(
                                  'Desactivado',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: Colors.orangeAccent),
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
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF10131A),
      child: const Center(
        child: Icon(Icons.apps_rounded, size: 36, color: Colors.white12),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  CONTINUE WATCHING CARD
// ─────────────────────────────────────────────────────────────────────────────
class _ContinueCard extends StatelessWidget {
  final dynamic entry;
  final VoidCallback onTap;

  const _ContinueCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress as double? ?? 0.0;
    final poster = entry.poster as String?;

    return SizedBox(
      width: 268,
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
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (poster != null && poster.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: poster,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              Container(color: const Color(0xFF10131A)),
                        )
                      else
                        Container(color: const Color(0xFF10131A)),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          valueColor:
                              const AlwaysStoppedAnimation(_accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                child: Text(
                  entry.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
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
        ColoredBox(color: Colors.black.withValues(alpha: 0.32 + dim * 0.5)),
      ],
    );
  }
}
