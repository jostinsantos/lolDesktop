import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/repo_manager.dart';
import '../../data/services/library_service.dart';
import '../../data/services/github_service.dart';
import '../../data/models/repo_manifest.dart';
import '../../ui/shared/install_repo_dialog.dart';

const _card = Color(0xFF141820);
const _accent = Color(0xFFE50914);
const _border = Color(0xFF1C222C);
const _textMuted = Color(0x8AFFFFFF);

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

/// Caché persistente de iconos de comunidad (sobrevive entre visitas).
class _IconCache {
  static final Map<String, String?> memory = {};
  static const _prefsKey = 'community_icon_cache_v1';
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getStringList(_prefsKey) ?? [];
      for (final entry in raw) {
        final parts = entry.split('|||');
        if (parts.length == 2) {
          memory[parts[0]] = parts[1].isEmpty ? null : parts[1];
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  static Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = memory.entries
          .map((e) => '${e.key}|||${e.value ?? ''}')
          .toList();
      // Limitar a ~80 entradas
      if (list.length > 80) list.removeRange(80, list.length);
      await p.setStringList(_prefsKey, list);
    } catch (_) {}
  }

  static String? get(String repo) => memory[repo];

  static void set(String repo, String? url) {
    memory[repo] = url;
    unawaited(save());
  }
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
  final Map<String, String> _nameCache = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _IconCache.load();
    await _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefreshIcons = false}) async {
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
      unawaited(_prefetchIcons(list, force: forceRefreshIcons));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _prefetchIcons(List<CommunityRepoItem> list,
      {bool force = false}) async {
    final mgr = context.read<RepoManager>();
    final limit = list.length > 40 ? 40 : list.length;
    for (var i = 0; i < limit; i++) {
      if (!mounted) return;
      final item = list[i];
      if (!force && _IconCache.get(item.repo) != null) continue;
      try {
        final icon = await mgr.peekIcon(item.repo);
        final url = icon ?? item.avatarUrl;
        _IconCache.set(item.repo, url);
        if (mounted) setState(() {});
      } catch (_) {
        _IconCache.set(item.repo, item.avatarUrl);
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
            FilledButton(onPressed: () => _load(), child: const Text('Reintentar')),
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
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Buscar repositorios…',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: Colors.white38, size: 20),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded,
                                color: Colors.white38, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Actualizar (recarga iconos)',
                onPressed: () => _load(forceRefreshIcons: true),
                icon: const Icon(Icons.refresh_rounded, color: Colors.white54),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 2, 24, 8),
          child: Text(
            '${list.length} repositorio${list.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
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
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cross,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: cross >= 3 ? 1.75 : 1.6,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final item = list[i];
                    return _CommunityCard(
                      title: _titleFor(item),
                      author: displayAuthor(item.repo),
                      iconUrl: _IconCache.get(item.repo) ?? item.avatarUrl,
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
      child: AnimatedScale(
        scale: _hover ? 1.015 : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hover
                  ? _accent.withValues(alpha: 0.4)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.06),
                      const Color(0xFF10141C).withValues(alpha: 0.92),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: widget.iconUrl != null &&
                                  widget.iconUrl!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: widget.iconUrl!,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 96,
                                  memCacheHeight: 96,
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
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      Colors.white.withValues(alpha: 0.4),
                                  fontSize: 11,
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
                                  size: 13, color: Color(0xFFFFC857)),
                              const SizedBox(width: 2),
                              Text(
                                '${widget.stars}',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 10.5),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const Spacer(),
                    SizedBox(
                      height: 36,
                      width: double.infinity,
                      child: widget.installed
                          ? OutlinedButton(
                              onPressed: widget.onUninstall,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                side: const BorderSide(
                                    color: Colors.redAccent, width: 1.2),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text(
                                'Desinstalar',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                            )
                          : FilledButton(
                              onPressed: widget.onInstall,
                              style: FilledButton.styleFrom(
                                backgroundColor: _accent,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text(
                                'Instalar',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
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
      ),
    );
  }

  Widget _fallback() {
    final t = widget.title;
    return Container(
      color: const Color(0xFF161C26),
      alignment: Alignment.center,
      child: Text(
        t.isNotEmpty ? t[0].toUpperCase() : '?',
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
