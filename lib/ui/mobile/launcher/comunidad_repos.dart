import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/library_service.dart';
import '../../../data/services/github_service.dart';
import '../../shared/install_repo_dialog.dart';
import '../widgets/focusable.dart';

class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  List<CommunityRepoItem> _items = [];
  bool _loading = true;
  String? _error;
  final _repoController = TextEditingController();
  bool _busy = false;
  final Map<String, String?> _iconCache = {};

  static const _accent = Color(0xFFE50914);
  static const _bg = Color(0xFF070A10);
  static const _card = Color(0xFF121820);

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

  String? _installedId(String userRepo) {
    final installed = context.read<RepoManager>().installed;
    final key = userRepo.toLowerCase();
    for (final r in installed) {
      if (r.manifest.repo.toLowerCase() == key) return r.manifest.id;
      if (r.manifest.id.toLowerCase() == key.replaceAll('/', '-')) return r.manifest.id;
    }
    return null;
  }

  String? _imageFor(CommunityRepoItem item) {
    final cached = _iconCache[item.repo];
    if (cached != null && cached.isNotEmpty) return cached;
    final installed = context.read<RepoManager>().installed;
    for (final r in installed) {
      if (r.manifest.repo.toLowerCase() == item.repo.toLowerCase()) {
        if (r.manifest.icon != null && r.manifest.icon!.isNotEmpty) {
          return r.manifest.icon;
        }
      }
    }
    return item.avatarUrl;
  }

  Future<void> _install(String userRepo, {String? fallbackAvatar}) async {
    setState(() => _busy = true);
    try {
      final mgr = context.read<RepoManager>();
      final preview = await mgr.previewFromGithub(userRepo);
      if (!mounted) return;
      final ok = await showInstallRepoDialog(
        context,
        manifest: preview.manifest,
        contract: preview.contract,
        userRepo: userRepo,
        fallbackAvatarUrl: fallbackAvatar,
      );
      if (ok != true) return;
      await mgr.installFromPreview(preview);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Instalado: ${preview.manifest.name}')),
        );
        setState(() {});
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

  Future<void> _uninstall(String userRepo) async {
    final id = _installedId(userRepo);
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A222D),
        title: const Text('Desinstalar', style: TextStyle(color: Colors.white)),
        content: Text('¿Quitar $userRepo?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desinstalar', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await context.read<RepoManager>().uninstall(id);
      try {
        await context.read<LibraryService>().clearRepoData(id);
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Desinstalado: $userRepo')));
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _repoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<RepoManager>();
    final width = MediaQuery.sizeOf(context).width;
    // Siempre al menos 2 por fila; 3 en pantallas anchas / TV
    final cross = width >= 900 ? 3 : 2;

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Fondos con glow
          Positioned(
            top: -80,
            right: -40,
            child: _blob(const Color(0xFFE50914).withValues(alpha: 0.18), 220),
          ),
          Positioned(
            bottom: 40,
            left: -60,
            child: _blob(const Color(0xFF5B8CFF).withValues(alpha: 0.12), 260),
          ),
          SafeArea(
            child: Column(
              children: [
                _header(),
                _installBar(),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator(color: _accent))
                      : _error != null
                          ? Center(
                              child: Text(_error!,
                                  style: const TextStyle(color: Colors.white54)),
                            )
                          : _items.isEmpty
                              ? const Center(
                                  child: Text('No hay repos en la comunidad',
                                      style: TextStyle(color: Colors.white54)),
                                )
                              : GridView.builder(
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: cross,
                                    mainAxisSpacing: 14,
                                    crossAxisSpacing: 14,
                                    childAspectRatio: cross >= 3 ? 1.15 : 0.92,
                                  ),
                                  itemCount: _items.length,
                                  itemBuilder: (context, i) {
                                    final item = _items[i];
                                    final installed = _isInstalled(item.repo);
                                    final img = _imageFor(item);
                                    return Focusable(
                                      onTap: () {
                                        if (installed) {
                                          _uninstall(item.repo);
                                        } else {
                                          _install(item.repo, fallbackAvatar: item.avatarUrl);
                                        }
                                      },
                                      builder: (f) => _RepoCard(
                                        item: item,
                                        imageUrl: img,
                                        installed: installed,
                                        focused: f,
                                        busy: _busy,
                                      ),
                                    );
                                  },
                                ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blob(Color color, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white70),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Comunidad',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                Text(
                  'Repos con icono, contrato y un toque',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _installBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _repoController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'usuario/repo  ·  ej. org/mi-addon',
                      hintStyle: TextStyle(color: Colors.white30),
                      border: InputBorder.none,
                      isDense: true,
                      prefixIcon: Icon(Icons.link_rounded, color: Colors.white38, size: 20),
                      prefixIconConstraints: BoxConstraints(minWidth: 36),
                    ),
                    onSubmitted: (v) {
                      if (v.contains('/')) _install(v.trim());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _busy
                      ? null
                      : () {
                          final v = _repoController.text.trim();
                          if (v.contains('/')) _install(v);
                        },
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Instalar'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RepoCard extends StatelessWidget {
  final CommunityRepoItem item;
  final String? imageUrl;
  final bool installed;
  final bool focused;
  final bool busy;

  const _RepoCard({
    required this.item,
    required this.imageUrl,
    required this.installed,
    required this.focused,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final glow = installed
        ? const Color(0xFF3DDC97).withValues(alpha: focused ? 0.45 : 0.2)
        : const Color(0xFFE50914).withValues(alpha: focused ? 0.55 : 0.22);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: glow,
            blurRadius: focused ? 28 : 16,
            spreadRadius: focused ? 1 : 0,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: focused
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.08),
                width: focused ? 1.6 : 1,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.10),
                  const Color(0xFF121820).withValues(alpha: 0.92),
                  const Color(0xFF0B1018).withValues(alpha: 0.98),
                ],
              ),
            ),
            child: Stack(
              children: [
                // Brillo superior
                Positioned(
                  top: -30,
                  right: -20,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          (installed ? const Color(0xFF3DDC97) : const Color(0xFFE50914))
                              .withValues(alpha: 0.25),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _avatar(),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.repo,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.45),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (item.stars > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFFC857)),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${item.stars}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Text(
                          item.description.isNotEmpty
                              ? item.description
                              : 'Repositorio de la comunidad listo para instalar.',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.62),
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _chip(
                            installed ? 'Instalado' : 'Disponible',
                            installed ? const Color(0xFF3DDC97) : Colors.white54,
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              gradient: LinearGradient(
                                colors: installed
                                    ? [
                                        Colors.white.withValues(alpha: 0.12),
                                        Colors.white.withValues(alpha: 0.06),
                                      ]
                                    : [
                                        const Color(0xFFE50914),
                                        const Color(0xFFB20710),
                                      ],
                              ),
                              boxShadow: installed
                                  ? null
                                  : [
                                      BoxShadow(
                                        color: const Color(0xFFE50914).withValues(alpha: 0.35),
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                            ),
                            child: Text(
                              installed ? 'Quitar' : 'Instalar',
                              style: TextStyle(
                                color: installed ? Colors.white70 : Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
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
      ),
    );
  }

  Widget _avatar() {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: imageUrl != null && imageUrl!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: imageUrl!,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => _letter(),
              )
            : _letter(),
      ),
    );
  }

  Widget _letter() {
    return Container(
      color: const Color(0xFF1A222D),
      alignment: Alignment.center,
      child: Text(
        item.name.isNotEmpty ? item.name[0].toUpperCase() : '?',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
