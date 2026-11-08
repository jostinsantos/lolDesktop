import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/content_service.dart';
import '../../../data/models/repo_manifest.dart';
import '../repo/contenido/contenido.dart';

/// Buscador del launcher móvil: busca en TODOS los repos.
/// Resultados en slider horizontal, una fila por repositorio.
class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key});

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final _controller = TextEditingController();
  final Map<String, ({InstalledRepo repo, List<ContentItem> items})> _byRepo = {};
  bool _loading = false;
  bool _searched = false;
  String _query = '';

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _byRepo.clear();
        _searched = false;
        _query = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _searched = true;
      _query = query;
      _byRepo.clear();
    });

    final mgr = context.read<RepoManager>();
    final list = mgr.enabled.isNotEmpty ? mgr.enabled : mgr.installed;

    await Future.wait(list.map((repo) async {
      try {
        final items = await ContentService.instance.search(repo, query);
        if (items.isEmpty || !mounted) return;
        setState(() {
          _byRepo[repo.manifest.id] = (repo: repo, items: items);
        });
      } catch (e) {
        debugPrint('[GlobalSearch] ${repo.manifest.id}: $e');
      }
    }));

    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = _byRepo.values.toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white70),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Buscar en todos los repositorios…',
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: const Color(0xFF1A222D),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.search, color: Colors.white54),
                        suffixIcon: _controller.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, color: Colors.white38),
                                onPressed: () {
                                  _controller.clear();
                                  _search('');
                                },
                              )
                            : null,
                      ),
                      onChanged: (v) {
                        setState(() {});
                        if (v.isEmpty) _search('');
                      },
                      onSubmitted: _search,
                    ),
                  ),
                ],
              ),
            ),
            if (_loading && sections.isEmpty)
              const Expanded(child: Center(child: CircularProgressIndicator(color: Color(0xFFE50914))))
            else if (!_searched)
              const Expanded(
                child: Center(
                  child: Text(
                    'Busca en todos los repositorios instalados',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              )
            else if (!_loading && sections.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'Sin resultados para "$_query"',
                    style: const TextStyle(color: Colors.white38),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: sections.length + (_loading ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (_loading && i == sections.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFE50914),
                            ),
                          ),
                        ),
                      );
                    }
                    final s = sections[i];
                    return _MobileRepoRow(repo: s.repo, items: s.items);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileRepoRow extends StatelessWidget {
  final InstalledRepo repo;
  final List<ContentItem> items;

  const _MobileRepoRow({required this.repo, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                repo.manifest.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${items.length}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final item = items[i];
              final poster = item.poster ?? '';
              return GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DetailsPage(repo: repo, itemId: item.id),
                    ),
                  );
                },
                child: SizedBox(
                  width: 100,
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
                                  memCacheWidth: 200,
                                  errorWidget: (_, __, ___) =>
                                      const ColoredBox(color: Color(0xFF1A222D)),
                                )
                              : const ColoredBox(color: Color(0xFF1A222D)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                    ],
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
