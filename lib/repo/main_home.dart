import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../data/models/repo_manifest.dart';
import 'home/home.dart';
import 'descubrir/descubrir.dart';
import 'buscar/buscar.dart';
import 'biblioteca/biblioteca.dart';
import 'config/config.dart';
import 'live/live.dart';

const _bg = Color(0xFF0B0D10);
const _accent = Color(0xFFE50914);

/// Shell del repositorio para Desktop — menú superior estilo streaming.
class RepoMainHome extends StatefulWidget {
  final InstalledRepo repo;
  const RepoMainHome({super.key, required this.repo});

  @override
  State<RepoMainHome> createState() => _RepoMainHomeState();
}

class _RepoMainHomeState extends State<RepoMainHome> {
  int _index = 0;
  late List<({String id, Widget page, IconData icon, IconData selectedIcon, String label})> _tabs;

  /// Tabs visibles en el menú (sin buscar ni ajustes: van en iconos de la barra).
  List<({String id, Widget page, IconData icon, IconData selectedIcon, String label})> get _navTabs =>
      _tabs.where((t) => t.id != 'search' && t.id != 'settings' && t.id != 'config').toList();

  @override
  void initState() {
    super.initState();
    _tabs = _buildTabs();
  }

  @override
  void didUpdateWidget(covariant RepoMainHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repo.manifest.id != widget.repo.manifest.id) {
      _tabs = _buildTabs();
      _index = 0;
    }
  }

  List<({String id, Widget page, IconData icon, IconData selectedIcon, String label})> _buildTabs() {
    final repo = widget.repo;
    final order = repo.manifest.resolvedTabs;
    final out = <({String id, Widget page, IconData icon, IconData selectedIcon, String label})>[];

    for (final id in order) {
      switch (id) {
        case 'home':
          out.add((
            id: id,
            page: RepoHomePage(repo: repo),
            icon: Icons.home_outlined,
            selectedIcon: Icons.home_rounded,
            label: 'Inicio',
          ));
        case 'discover':
          out.add((
            id: id,
            page: DiscoverPage(repo: repo),
            icon: Icons.explore_outlined,
            selectedIcon: Icons.explore_rounded,
            label: 'Descubrir',
          ));
        case 'search':
          out.add((
            id: id,
            page: RepoSearchPage(repo: repo),
            icon: Icons.search_rounded,
            selectedIcon: Icons.search_rounded,
            label: 'Buscar',
          ));
        case 'live':
          out.add((
            id: id,
            page: RepoLivePage(repo: repo),
            icon: Icons.live_tv_outlined,
            selectedIcon: Icons.live_tv_rounded,
            label: 'TV Online',
          ));
        case 'library':
          out.add((
            id: id,
            page: BibliotecaPage(repo: repo),
            icon: Icons.video_library_outlined,
            selectedIcon: Icons.video_library_rounded,
            label: 'Biblioteca',
          ));
        case 'settings':
        case 'config':
          out.add((
            id: id,
            page: RepoConfigPage(repo: repo),
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings_rounded,
            label: 'Ajustes',
          ));
      }
    }

    if (out.isEmpty) {
      out.addAll([
        (
          id: 'home',
          page: RepoHomePage(repo: repo),
          icon: Icons.home_outlined,
          selectedIcon: Icons.home_rounded,
          label: 'Inicio',
        ),
        (
          id: 'search',
          page: RepoSearchPage(repo: repo),
          icon: Icons.search_rounded,
          selectedIcon: Icons.search_rounded,
          label: 'Buscar',
        ),
        (
          id: 'library',
          page: BibliotecaPage(repo: repo),
          icon: Icons.video_library_outlined,
          selectedIcon: Icons.video_library_rounded,
          label: 'Biblioteca',
        ),
        (
          id: 'config',
          page: RepoConfigPage(repo: repo),
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings_rounded,
          label: 'Ajustes',
        ),
      ]);
    }

    // Asegurar que existan search y settings aunque el manifest no los liste
    // (accesibles por iconos de la barra).
    if (!out.any((t) => t.id == 'search')) {
      out.add((
        id: 'search',
        page: RepoSearchPage(repo: repo),
        icon: Icons.search_rounded,
        selectedIcon: Icons.search_rounded,
        label: 'Buscar',
      ));
    }
    if (!out.any((t) => t.id == 'settings' || t.id == 'config')) {
      out.add((
        id: 'config',
        page: RepoConfigPage(repo: repo),
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings_rounded,
        label: 'Ajustes',
      ));
    }

    return out;
  }

  void _goToId(String id) {
    final i = _tabs.indexWhere((t) => t.id == id || (id == 'settings' && t.id == 'config'));
    if (i >= 0) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final safeIndex = _index.clamp(0, tabs.length - 1);
    final m = widget.repo.manifest;
    final isHome = tabs[safeIndex].id == 'home';
    final navTabs = _navTabs;
    // Índice de la pestaña activa dentro del menú visible (puede ser -1 si estamos en search/settings)
    final navIndex = navTabs.indexWhere((t) => t.id == tabs[safeIndex].id);

    final topBar = _TopNavBar(
      repoName: m.name,
      repoIcon: m.icon,
      navTabs: navTabs,
      navIndex: navIndex,
      onSelectNav: (navI) {
        final id = navTabs[navI].id;
        final fullI = tabs.indexWhere((t) => t.id == id);
        if (fullI >= 0) setState(() => _index = fullI);
      },
      onBack: () => Navigator.of(context).maybePop(),
      onSearch: () => _goToId('search'),
      onSettings: () => _goToId('settings'),
      floating: isHome,
    );

    if (isHome) {
      // Home: contenido a pantalla completa + AppBar flotante con gradiente
      return Scaffold(
        backgroundColor: _bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: safeIndex,
                children: [for (final t in tabs) t.page],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: topBar,
            ),
          ],
        ),
      );
    }

    // Otras páginas: AppBar sólida + contenido debajo
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          topBar,
          Expanded(
            child: IndexedStack(
              index: safeIndex,
              children: [for (final t in tabs) t.page],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopNavBar extends StatelessWidget {
  final String repoName;
  final String? repoIcon;
  final List<({String id, Widget page, IconData icon, IconData selectedIcon, String label})> navTabs;
  final int navIndex;
  final ValueChanged<int> onSelectNav;
  final VoidCallback onBack;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  /// Solo en Home: gradiente negro → transparente (flotante sobre el hero).
  final bool floating;

  const _TopNavBar({
    required this.repoName,
    required this.repoIcon,
    required this.navTabs,
    required this.navIndex,
    required this.onSelectNav,
    required this.onBack,
    required this.onSearch,
    required this.onSettings,
    this.floating = false,
  });

  @override
  Widget build(BuildContext context) {
    final bar = SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Volver al launcher',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white70, size: 22),
            ),
            const SizedBox(width: 4),
            if (repoIcon != null && repoIcon!.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: repoIcon!,
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Text(
              repoName,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 18,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 28),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < navTabs.length; i++)
                      _NavTab(
                        label: navTabs[i].label,
                        selected: i == navIndex,
                        onTap: () => onSelectNav(i),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Buscar',
              onPressed: onSearch,
              icon: const Icon(Icons.search_rounded, color: Colors.white70, size: 22),
            ),
            IconButton(
              tooltip: 'Ajustes',
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined, color: Colors.white70, size: 22),
            ),
          ],
        ),
      ),
    );

    if (floating) {
      // ~10% superior negro puro; luego baja suave hasta 0% (transparente)
      return DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF000000), // negro puro
              Color(0xE6000000), // ~90%
              Color(0x80000000), // ~50%
              Color(0x33000000), // ~20%
              Color(0x00000000), // 0% transparente
            ],
            stops: [0.0, 0.10, 0.40, 0.70, 1.0],
          ),
        ),
        child: bar,
      );
    }

    // Resto de páginas: barra sólida
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0B0D10),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: bar,
    );
  }
}

class _NavTab extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavTab> createState() => _NavTabState();
}

class _NavTabState extends State<_NavTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final color = active ? Colors.white : (_hover ? Colors.white : Colors.white60);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  color: color,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14.5,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 2.5,
                width: active ? 22 : 0,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
