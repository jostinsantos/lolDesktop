import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/github_service.dart';
import '../../shared/install_repo_dialog.dart';
import '../widgets/focusable.dart';
import '../widgets/tv_keyboard.dart';
import '../widgets/glass.dart';

/// Comunidad TV – cards compactas, solo borde blanco al foco.
/// Al tocar una tarjeta se abre una vista de detalle (no modal).
class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  List<CommunityRepoItem> _items = [];
  bool _loading = true;
  String? _error;
  final Map<String, String?> _iconCache = {};

  static const _accent = Color(0xFFE50914);

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
      final list = await context.read<RepoManager>().fetchCommunity();
      if (mounted) {
        setState(() {
          _items = list;
          _loading = false;
        });
        _prefetchIcons(list);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _prefetchIcons(List<CommunityRepoItem> list) async {
    final mgr = context.read<RepoManager>();
    final limit = list.length > 20 ? 20 : list.length;
    for (var i = 0; i < limit; i++) {
      final item = list[i];
      if (!mounted) return;
      if (_iconCache.containsKey(item.repo)) continue;
      try {
        final icon = await mgr.peekIcon(item.repo);
        if (!mounted) return;
        setState(() => _iconCache[item.repo] = icon);
      } catch (_) {
        _iconCache[item.repo] = null;
      }
    }
  }

  bool _isInstalled(String userRepo) {
    final installed = context.read<RepoManager>().installed;
    final key = userRepo.toLowerCase();
    return installed.any((r) {
      final repo = (r.manifest.repo).toLowerCase();
      final id = r.manifest.id.toLowerCase();
      return repo == key || id == key.replaceAll('/', '-');
    });
  }

  String? _imageFor(CommunityRepoItem item) {
    final cached = _iconCache[item.repo];
    if (cached != null && cached.isNotEmpty) return cached;
    final installed = context.read<RepoManager>().installed;
    for (final r in installed) {
      if (r.manifest.repo.toLowerCase() == item.repo.toLowerCase()) {
        if (r.manifest.icon != null && r.manifest.icon!.isNotEmpty) return r.manifest.icon;
      }
    }
    return item.avatarUrl;
  }

  String _cleanName(String? name, String repo) {
    final raw = (name ?? repo.split('/').last).trim();
    return raw
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  void _openRepo(String userRepo, {String? fallbackAvatar, String? name}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => CommunityRepoDetailPage(
              userRepo: userRepo,
              fallbackAvatar: fallbackAvatar,
              initialName: name,
            ),
          ),
        )
        .then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _openAddInput() async {
    final text = await TvKeyboard.show(
      context,
      initial: '',
      hint: 'usuario/repo',
      title: 'Añadir repositorio',
    );
    if (text != null && text.trim().isNotEmpty) {
      _openRepo(text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<RepoManager>();

    return Scaffold(
      backgroundColor: kTvBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 20, 36, 12),
              child: Row(
                children: [
                  const Text(
                    'Comunidad',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _TvFocusButton(
                    onTap: _openAddInput,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, size: 20, color: Colors.white),
                        SizedBox(width: 6),
                        Text(
                          'Añadir repo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: _accent),
                      ),
                    )
                  : _error != null
                      ? Center(
                          child: Text(_error!, style: const TextStyle(color: Colors.white54, fontSize: 15)),
                        )
                      : _items.isEmpty
                          ? const Center(
                              child: Text(
                                'No hay repos en la comunidad',
                                style: TextStyle(color: Colors.white54, fontSize: 15),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(28, 6, 28, 28),
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 148,
                                mainAxisSpacing: 14,
                                crossAxisSpacing: 14,
                                childAspectRatio: 0.82,
                              ),
                              itemCount: _items.length,
                              itemBuilder: (context, i) {
                                final item = _items[i];
                                final installed = _isInstalled(item.repo);
                                final img = _imageFor(item);
                                final displayName = _cleanName(item.name, item.repo);

                                return _RepoCard(
                                  autofocus: i == 0,
                                  name: displayName,
                                  subtitle: installed ? 'Instalado' : item.repo,
                                  isInstalled: installed,
                                  imageUrl: img,
                                  onTap: () => _openRepo(
                                    item.repo,
                                    fallbackAvatar: item.avatarUrl,
                                    name: item.name,
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Card compacta – SOLO borde blanco al foco
class _RepoCard extends StatefulWidget {
  final bool autofocus;
  final String name;
  final String subtitle;
  final bool isInstalled;
  final String? imageUrl;
  final VoidCallback onTap;

  const _RepoCard({
    required this.autofocus,
    required this.name,
    required this.subtitle,
    required this.isInstalled,
    required this.imageUrl,
    required this.onTap,
  });

  @override
  State<_RepoCard> createState() => _RepoCardState();
}

class _RepoCardState extends State<_RepoCard> {
  bool _focused = false;
  static const _accent = Color(0xFFE50914);

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: const Color(0xFF1C232C),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2.2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: widget.imageUrl != null && widget.imageUrl!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.imageUrl!,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _letter(widget.name),
                      )
                    : _letter(widget.name),
              ),
              const SizedBox(height: 8),
              Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _focused ? Colors.white : Colors.white.withValues(alpha: 0.9),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.isInstalled
                      ? _accent.withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.35),
                  fontSize: 10,
                  fontWeight: widget.isInstalled ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _letter(String name) {
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.white.withValues(alpha: 0.08),
      ),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: const TextStyle(color: Colors.white70, fontSize: 20, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Vista de detalle – botones al lado del logo/título + info scrolleable
class CommunityRepoDetailPage extends StatefulWidget {
  final String userRepo;
  final String? fallbackAvatar;
  final String? initialName;

  const CommunityRepoDetailPage({
    super.key,
    required this.userRepo,
    this.fallbackAvatar,
    this.initialName,
  });

  @override
  State<CommunityRepoDetailPage> createState() => _CommunityRepoDetailPageState();
}

class _CommunityRepoDetailPageState extends State<CommunityRepoDetailPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  dynamic _preview;
  bool _isInstalled = false;
  String? _installedId;

  final ScrollController _scrollController = ScrollController();

  static const _accent = Color(0xFFE50914);

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final mgr = context.read<RepoManager>();
      final preview = await mgr.previewFromGithub(widget.userRepo);
      final installed = mgr.installed;
      final key = widget.userRepo.toLowerCase();

      String? id;
      bool found = false;
      for (final r in installed) {
        if (r.manifest.repo.toLowerCase() == key ||
            r.manifest.id.toLowerCase() == key.replaceAll('/', '-')) {
          found = true;
          id = r.manifest.id;
          break;
        }
      }

      if (mounted) {
        setState(() {
          _preview = preview;
          _isInstalled = found;
          _installedId = id;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _cleanName(String? name) {
    final raw = (name ?? widget.userRepo.split('/').last).trim();
    return raw
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  Future<void> _install() async {
    if (_preview == null) return;
    setState(() => _busy = true);
    try {
      final mgr = context.read<RepoManager>();
      await mgr.installFromPreview(_preview);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Instalado: ${_preview.manifest.name}')),
        );
        setState(() {
          _isInstalled = true;
          _installedId = _preview.manifest.id;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    if (_installedId == null) return;
    setState(() => _busy = true);
    try {
      await context.read<RepoManager>().uninstall(_installedId!);
      try {
        await context.read<LibraryService>().clearRepoData(_installedId!);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Desinstalado: ${widget.userRepo}')),
        );
        setState(() {
          _isInstalled = false;
          _installedId = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _busy = true);
    try {
      await _loadInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Información actualizada desde el repositorio')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _preview?.manifest;
    final displayName = _cleanName(manifest?.name ?? widget.initialName);
    final iconUrl = manifest?.icon?.isNotEmpty == true ? manifest!.icon : widget.fallbackAvatar;

    return Scaffold(
      backgroundColor: kTvBg,
      body: SafeArea(
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: _accent),
                ),
              )
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white54, fontSize: 15),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      // ─── CABECERA: Logo + Título + Botones ───
                      Padding(
                        padding: const EdgeInsets.fromLTRB(36, 24, 36, 20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: iconUrl != null && iconUrl.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: iconUrl,
                                      width: 80,
                                      height: 80,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, __, ___) => _bigLetter(displayName),
                                    )
                                  : _bigLetter(displayName),
                            ),
                            const SizedBox(width: 22),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    displayName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 24,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.userRepo,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.45),
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (_isInstalled) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: _accent.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        'Instalado',
                                        style: TextStyle(
                                          color: _accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 20),
                            if (_busy)
                              const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: _accent),
                              )
                            else
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!_isInstalled)
                                    _ActionButton(
                                      label: 'Instalar',
                                      icon: Icons.download_rounded,
                                      primary: true,
                                      autofocus: true,
                                      onTap: _install,
                                    )
                                  else ...[
                                    _ActionButton(
                                      label: 'Desinstalar',
                                      icon: Icons.delete_outline_rounded,
                                      danger: true,
                                      onTap: _uninstall,
                                    ),
                                    const SizedBox(width: 12),
                                    _ActionButton(
                                      label: 'Buscar actualización',
                                      icon: Icons.refresh_rounded,
                                      autofocus: true,
                                      onTap: _checkUpdate,
                                    ),
                                  ],
                                ],
                              ),
                          ],
                        ),
                      ),

                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 36),
                        color: Colors.white.withValues(alpha: 0.08),
                      ),

                      // ─── BLOQUE DE INFORMACIÓN (scrolleable) ───
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(36, 24, 36, 40),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Descripción
                              if (manifest?.description != null &&
                                  manifest!.description!.trim().isNotEmpty) ...[
                                _sectionTitle('Descripción'),
                                const SizedBox(height: 8),
                                Text(
                                  manifest.description!,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.78),
                                    fontSize: 15,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 28),
                              ],

                              // Información general (solo campos que existen)
                              _sectionTitle('Información'),
                              const SizedBox(height: 12),
                              _infoRow('Repositorio', widget.userRepo),
                              if (manifest?.version != null)
                                _infoRow('Versión', manifest!.version.toString()),
                              if (manifest?.id != null)
                                _infoRow('ID', manifest!.id),
                              if (manifest?.author != null)
                                _infoRow('Autor', manifest!.author.toString()),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigLetter(String name) {
    return Container(
      width: 80,
      height: 80,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.08),
      ),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 32,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Botones con foco limpio
class _TvFocusButton extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _TvFocusButton({required this.onTap, required this.child});

  @override
  State<_TvFocusButton> createState() => _TvFocusButtonState();
}

class _TvFocusButtonState extends State<_TvFocusButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.white.withValues(alpha: 0.07),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final bool autofocus;

  const _ActionButton({
    required this.label,
    required this.icon,
    this.onTap,
    this.primary = false,
    this.danger = false,
    this.autofocus = false,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;

    Color bg;
    Color fg;
    if (widget.primary) {
      bg = _focused ? Colors.white : const Color(0xFFE50914);
      fg = _focused ? Colors.black : Colors.white;
    } else if (widget.danger) {
      bg = _focused ? Colors.white : Colors.red.shade900.withValues(alpha: 0.7);
      fg = _focused ? Colors.black : Colors.white;
    } else {
      bg = _focused ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.07);
      fg = Colors.white;
    }

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (!enabled) return KeyEventResult.ignored;
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: bg,
              border: Border.all(
                color: _focused ? Colors.white : Colors.transparent,
                width: 2.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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