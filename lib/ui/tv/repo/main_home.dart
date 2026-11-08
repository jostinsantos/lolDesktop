import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/repo_manifest.dart';
import 'home/home.dart';
import 'descubrir/descubrir.dart';
import 'buscar/buscar.dart';
import 'biblioteca/biblioteca.dart';
import 'config/config.dart';
import '../widgets/focusable.dart';
import '../widgets/glass.dart';


/// Permite a las páginas hijas pedir foco al menú lateral (flecha izquierda en primer ítem).
class RepoNavScope extends InheritedWidget {
  final VoidCallback requestMenuFocus;
  const RepoNavScope({super.key, required this.requestMenuFocus, required super.child});

  static RepoNavScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RepoNavScope>();

  @override
  bool updateShouldNotify(RepoNavScope old) => false;
}

/// Shell TV: sidebar minimal solo iconos. Sin AppBar. Sin texto en nav.
class RepoMainHome extends StatefulWidget {
  final InstalledRepo repo;
  const RepoMainHome({super.key, required this.repo});

  @override
  State<RepoMainHome> createState() => _RepoMainHomeState();
}

class _RepoMainHomeState extends State<RepoMainHome> {
  int _index = 0;
  final List<FocusNode> _sideNodes = [];
  int _sideIndex = 0;
  bool _exitDialogOpen = false;

  void _requestMenuFocus() {
    if (_sideNodes.isEmpty) return;
    final i = _sideIndex.clamp(0, _sideNodes.length - 1);
    _sideNodes[i].requestFocus();
  }

  Future<bool> _confirmExitRepo() async {
    if (_exitDialogOpen) return false;
    _exitDialogOpen = true;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return FocusScope(
          autofocus: true,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1A1F2A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              'Salir del repositorio',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
            content: Text(
              '¿Quieres salir de ${widget.repo.manifest.name}?',
              style: const TextStyle(color: Colors.white70),
            ),
            actionsAlignment: MainAxisAlignment.end,
            actions: [
              _TvConfirmButton(
                label: 'Cancelar',
                autofocus: true,
                primary: false,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              const SizedBox(width: 8),
              _TvConfirmButton(
                label: 'Salir',
                autofocus: false,
                primary: true,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );
      },
    );
    _exitDialogOpen = false;
    return ok == true;
  }

  List<({String id, Widget page, IconData icon, IconData selectedIcon})> _buildTabs(InstalledRepo repo) {
    final order = repo.manifest.resolvedTabs;
    final out = <({String id, Widget page, IconData icon, IconData selectedIcon})>[];
    for (final id in order) {
      switch (id) {
        case 'home':
          out.add((id: id, page: RepoHomePage(repo: repo), icon: Icons.home_outlined, selectedIcon: Icons.home_rounded));
        case 'discover':
          out.add((id: id, page: RepoDiscoverPage(repo: repo), icon: Icons.explore_outlined, selectedIcon: Icons.explore_rounded));
        case 'search':
          out.add((id: id, page: RepoSearchPage(repo: repo), icon: Icons.search_rounded, selectedIcon: Icons.search_rounded));
        case 'library':
          out.add((id: id, page: RepoLibraryPage(repo: repo), icon: Icons.bookmark_border_rounded, selectedIcon: Icons.bookmark_rounded));
        case 'settings':
          out.add((id: id, page: RepoSettingsPage(repo: repo), icon: Icons.settings_outlined, selectedIcon: Icons.settings_rounded));
      }
    }
    if (out.isEmpty) {
      out.add((id: 'home', page: RepoHomePage(repo: repo), icon: Icons.home_outlined, selectedIcon: Icons.home_rounded));
    }
    return out;
  }

  @override
  void dispose() {
    for (final n in _sideNodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.repo.manifest;
    final theme = m.theme.hasAny || m.color != null ? m.theme.toThemeData() : Theme.of(context);
    final bg = m.backgroundColor ?? kTvBg;
    final accent = m.accentColor ?? kTvAccent;
    final tabs = _buildTabs(widget.repo);
    if (_index >= tabs.length) _index = 0;

    return Theme(
      data: theme.copyWith(scaffoldBackgroundColor: bg),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          final leave = await _confirmExitRepo();
          if (leave && context.mounted) {
            Navigator.of(context).pop();
          }
        },
        child: Scaffold(
          backgroundColor: bg,
          body: SafeArea(
            child: Row(
              children: [
                // Sidebar minimal — solo iconos
                Container(
                  width: 56,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 12),
                      if (m.icon != null && m.icon!.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedNetworkImage(
                            imageUrl: m.icon!,
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => const SizedBox.shrink(),
                          ),
                        )
                      else
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.white10),
                          child: Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                        ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          itemCount: tabs.length,
                          itemBuilder: (context, i) {
                            final t = tabs[i];
                            final selected = i == _index;
                            while (_sideNodes.length <= i) {
                              _sideNodes.add(FocusNode(debugLabel: 'side_$i'));
                            }
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Focusable(
                                focusNode: _sideNodes[i],
                                autofocus: i == 0,
                                onTap: () {
                                  _sideIndex = i;
                                  setState(() => _index = i);
                                },
                                builder: (f) {
                                  if (f) _sideIndex = i;
                                  return AnimatedContainer(
                                    duration: const Duration(milliseconds: 140),
                                    height: 40,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: selected
                                          ? accent.withValues(alpha: 0.2)
                                          : f
                                              ? Colors.white.withValues(alpha: 0.08)
                                              : Colors.transparent,
                                    ),
                                    child: Icon(
                                      selected ? t.selectedIcon : t.icon,
                                      size: 20,
                                      color: (selected || f) ? Colors.white : Colors.white38,
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                      // Volver — también pide confirmación
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Focusable(
                          onTap: () async {
                            final leave = await _confirmExitRepo();
                            if (leave && context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          builder: (f) => Icon(Icons.arrow_back_rounded, size: 18, color: f ? Colors.white : Colors.white30),
                        ),
                      ),
                    ],
                  ),
                ),
                // Contenido — FocusScope separado; hijas pueden pedir foco al menú
                Expanded(
                  child: RepoNavScope(
                    requestMenuFocus: _requestMenuFocus,
                    child: FocusScope(
                      child: tabs[_index].page,
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
}

/// Botón de diálogo TV con foco real (borde al enfocar).
class _TvConfirmButton extends StatefulWidget {
  final String label;
  final bool autofocus;
  final bool primary;
  final VoidCallback onPressed;

  const _TvConfirmButton({
    required this.label,
    required this.autofocus,
    required this.primary,
    required this.onPressed,
  });

  @override
  State<_TvConfirmButton> createState() => _TvConfirmButtonState();
}

class _TvConfirmButtonState extends State<_TvConfirmButton> {
  late final FocusNode _node = FocusNode();

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: widget.primary
                    ? (focused ? const Color(0xFFE50914) : const Color(0xFFB20710))
                    : (focused ? Colors.white24 : Colors.white10),
                border: Border.all(
                  color: focused ? Colors.white : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
