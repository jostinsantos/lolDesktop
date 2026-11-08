import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../data/services/repo_manager.dart';
import '../../data/services/library_service.dart';
import '../../data/services/github_service.dart';
import '../../data/models/repo_manifest.dart';
import '../../ui/shared/install_repo_dialog.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

String displayTitle(String? s) {
  if (s == null || s.isEmpty) return '';
  final cleaned = s
      .replaceAll('-', ' ')
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return '';
  return cleaned.split(' ').map((w) {
    if (w.isEmpty) return w;
    return '${w[0].toUpperCase()}${w.length > 1 ? w.substring(1) : ''}';
  }).join(' ');
}

String displayAuthor(String? repo) {
  if (repo == null || repo.isEmpty) return '';
  final parts = repo.split('/');
  return parts.isNotEmpty ? parts.first : repo;
}

class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key});

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  List<CommunityRepoItem> _items = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  final _searchCtrl = TextEditingController();
  final Map<String, String?> _iconCache = {};
  final Map<String, String> _nameCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<RepoManager>().fetchCommunity();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
      unawaited(_prefetchIcons(list));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _prefetchIcons(List<CommunityRepoItem> list) async {
    final mgr = context.read<RepoManager>();
    final limit = list.length > 30 ? 30 : list.length;
    for (var i = 0; i < limit; i++) {
      if (!mounted) return;
      final item = list[i];
      if (_iconCache.containsKey(item.repo)) continue;
      try {
        final icon = await mgr.peekIcon(item.repo);
        if (!mounted) return;
        setState(() => _iconCache[item.repo] = icon ?? item.avatarUrl);
      } catch (_) {
        _iconCache[item.repo] = item.avatarUrl;
      }
    }
  }

  String _titleFor(CommunityRepoItem item) {
    final cached = _nameCache[item.repo];
    if (cached != null && cached.isNotEmpty) return displayTitle(cached);
    return displayTitle(item.name);
  }

  bool _isInstalled(String userRepo) {
    final installed = context.read<RepoManager>().installed;
    final key = userRepo.toLowerCase();
    return installed.any((r) {
      final id = r.manifest.id.toLowerCase();
      final source = r.sourceUrl.toLowerCase();
      final repoField = r.manifest.repo.toLowerCase();
      return id == key ||
          source.contains(key) ||
          key.contains(id) ||
          repoField == key;
    });
  }

  List<CommunityRepoItem> get _filtered {
    if (_query.trim().isEmpty) return _items;
    final q = _query.toLowerCase();
    return _items.where((e) {
      return e.name.toLowerCase().contains(q) ||
          e.repo.toLowerCase().contains(q) ||
          _titleFor(e).toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _install(CommunityRepoItem item) async {
    final mgr = context.read<RepoManager>();
    final title = _titleFor(item);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const Center(child: CircularProgressIndicator(color: _accent)),
    );

    try {
      final preview = await mgr.previewFromGithub(item.repo);
      if (!mounted) return;
      Navigator.of(context).pop();

      final n = (preview.manifest.name ?? '').toString().trim();
      if (n.isNotEmpty) {
        setState(() => _nameCache[item.repo] = n);
      }

      final ok = await showInstallRepoDialog(
        context,
        manifest: preview.manifest,
        contract: preview.contract,
        userRepo: item.repo,
        fallbackAvatarUrl: item.avatarUrl,
      );

      if (ok == true && mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              const Center(child: CircularProgressIndicator(color: _accent)),
        );
        try {
          await mgr.installFromPreview(preview);
          if (!mounted) return;
          Navigator.of(context).pop();
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$title instalado'),
              backgroundColor: _accent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } catch (e) {
          if (!mounted) return;
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al instalar: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _uninstall(CommunityRepoItem item) async {
    final mgr = context.read<RepoManager>();
    final key = item.repo.toLowerCase();
    final title = _titleFor(item);
    InstalledRepo? match;
    for (final r in mgr.installed) {
      final id = r.manifest.id.toLowerCase();
      final source = r.sourceUrl.toLowerCase();
      final repoField = r.manifest.repo.toLowerCase();
      if (id == key ||
          source.contains(key) ||
          key.contains(id) ||
          repoField == key) {
        match = r;
        break;
      }
    }
    if (match == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Desinstalar repositorio',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '¿Seguro que quieres desinstalar «$title»?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar',
                style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desinstalar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await mgr.uninstall(match.manifest.id);
      try {
        await context.read<LibraryService>().clearRepoData(match.manifest.id);
      } catch (_) {}
      if (mounted) setState(() {});
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Reintentar')),
          ],
        ),
      );
    }

    final list = _filtered;
    final width = MediaQuery.sizeOf(context).width;
    final cross = width >= 1200
        ? 4
        : width >= 900
            ? 3
            : 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Buscar repositorios…',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon:
                  const Icon(Icons.search_rounded, color: Colors.white38),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded,
                          color: Colors.white38),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
          child: Text(
            '${list.length} repositorio${list.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text(
                    'No se encontraron repositorios',
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 36),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cross,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // Compactas: logo + título + botón
                    childAspectRatio: cross >= 3 ? 1.7 : 1.55,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final item = list[i];
                    return _CommunityCard(
                      title: _titleFor(item),
                      author: displayAuthor(item.repo),
                      iconUrl: _iconCache[item.repo] ?? item.avatarUrl,
                      stars: item.stars,
                      installed: _isInstalled(item.repo),
                      onInstall: () => _install(item),
                      onUninstall: () => _uninstall(item),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CommunityCard extends StatefulWidget {
  final String title;
  final String author;
  final String? iconUrl;
  final int stars;
  final bool installed;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;

  const _CommunityCard({
    required this.title,
    required this.author,
    required this.iconUrl,
    required this.stars,
    required this.installed,
    required this.onInstall,
    required this.onUninstall,
  });

  @override
  State<_CommunityCard> createState() => _CommunityCardState();
}

class _CommunityCardState extends State<_CommunityCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hover
                ? _accent.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.07),
                    const Color(0xFF12161E).withValues(alpha: 0.95),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: widget.iconUrl != null &&
                                widget.iconUrl!.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: widget.iconUrl!,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => _fallback(),
                              )
                            : _fallback(),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.stars > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded,
                                size: 14, color: Color(0xFFFFC857)),
                            const SizedBox(width: 2),
                            Text(
                              '${widget.stars}',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 40,
                    width: double.infinity,
                    child: widget.installed
                        ? OutlinedButton(
                            onPressed: widget.onUninstall,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side: const BorderSide(
                                  color: Colors.redAccent, width: 1.4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                            child: const Text(
                              'Desinstalar',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                          )
                        : FilledButton(
                            onPressed: widget.onInstall,
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                            child: const Text(
                              'Instalar',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
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

  Widget _fallback() {
    final t = widget.title;
    return Container(
      color: const Color(0xFF1A222D),
      alignment: Alignment.center,
      child: Text(
        t.isNotEmpty ? t[0].toUpperCase() : '?',
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}