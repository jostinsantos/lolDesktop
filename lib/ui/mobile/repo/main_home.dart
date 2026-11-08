import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/repo_manifest.dart';
import 'home/home.dart';
import 'descubrir/descubrir.dart';
import 'buscar/buscar.dart';
import 'biblioteca/biblioteca.dart';
import 'config/config.dart';

/// Shell del repo en móvil (barra inferior según tabs del lol.json / capabilities).
class RepoMainHome extends StatefulWidget {
  final InstalledRepo repo;
  const RepoMainHome({super.key, required this.repo});

  @override
  State<RepoMainHome> createState() => _RepoMainHomeState();
}

class _RepoMainHomeState extends State<RepoMainHome> {
  int _index = 0;

  List<({String id, Widget page, NavigationDestination dest})> _buildTabs(
    InstalledRepo repo,
  ) {
    final order = repo.manifest.resolvedTabs;
    final out = <({String id, Widget page, NavigationDestination dest})>[];
    for (final id in order) {
      switch (id) {
        case 'home':
          out.add((
            id: id,
            page: RepoHomePage(repo: repo),
            dest: const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Inicio',
            ),
          ));
        case 'discover':
          out.add((
            id: id,
            page: RepoDiscoverPage(repo: repo),
            dest: const NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: 'Descubrir',
            ),
          ));
        case 'search':
          out.add((
            id: id,
            page: RepoSearchPage(repo: repo),
            dest: const NavigationDestination(
              icon: Icon(Icons.search),
              selectedIcon: Icon(Icons.search),
              label: 'Buscar',
            ),
          ));
        case 'library':
          out.add((
            id: id,
            page: RepoLibraryPage(repo: repo),
            dest: const NavigationDestination(
              icon: Icon(Icons.bookmark_border),
              selectedIcon: Icon(Icons.bookmark),
              label: 'Biblioteca',
            ),
          ));
        case 'settings':
          out.add((
            id: id,
            page: RepoSettingsPage(repo: repo),
            dest: const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Ajustes',
            ),
          ));
      }
    }
    if (out.isEmpty) {
      out.add((
        id: 'home',
        page: RepoHomePage(repo: repo),
        dest: const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Inicio',
        ),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.repo.manifest;
    final theme = m.theme.hasAny || m.color != null
        ? m.theme.toThemeData()
        : Theme.of(context);
    final bg = m.backgroundColor;
    final surface = m.surfaceColor;
    final accent = m.accentColor;

    final tabs = _buildTabs(widget.repo);
    if (_index >= tabs.length) _index = 0;

    final title = m.sectionLabel?.isNotEmpty == true ? m.sectionLabel! : m.name;

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: surface,
          title: Row(
            children: [
              if (m.icon != null && m.icon!.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: m.icon!,
                    width: 28,
                    height: 28,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(title, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        body: tabs[_index].page,
        bottomNavigationBar: NavigationBar(
          backgroundColor: surface,
          indicatorColor: accent.withValues(alpha: 0.25),
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [for (final t in tabs) t.dest],
        ),
      ),
    );
  }
}
