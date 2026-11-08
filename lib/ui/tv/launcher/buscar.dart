import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/services/repo_manager.dart';
import '../../../data/services/content_service.dart';
import '../../../data/models/repo_manifest.dart';
import '../widgets/focusable.dart';
import '../widgets/tv_keyboard.dart';
import '../widgets/glass.dart';
import '../repo/contenido/contenido.dart';

/// Buscador global del launcher TV.
/// Busca en TODOS los repos y muestra un slider horizontal por cada repo.
class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key});

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final _controller = TextEditingController();
  /// Resultados agrupados: repoId → (repo, items)
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

    final repos = context.read<RepoManager>().enabled;
    // Si no hay "enabled", usar todos los instalados
    final list = repos.isNotEmpty
        ? repos
        : context.read<RepoManager>().installed;

    // Buscar en paralelo y agrupar por repo
    await Future.wait(list.map((repo) async {
      try {
        final items = await ContentService.instance.search(repo, query);
        if (items.isEmpty) return;
        if (!mounted) return;
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
    final total = sections.fold<int>(0, (a, s) => a + s.items.length);

    return Scaffold(
      backgroundColor: kTvBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 12),
              child: Row(
                children: [
                  Focusable(
                    onTap: () => Navigator.pop(context),
                    builder: (f) => AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: f
                            ? Colors.white.withValues(alpha: 0.16)
                            : Colors.white.withValues(alpha: 0.06),
                        border: Border.all(
                          color: f ? Colors.white : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        size: 20,
                        color: f ? Colors.white : Colors.white60,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: TvTextField(
                      controller: _controller,
                      hint: 'Buscar en todos los repositorios…',
                      label: 'Búsqueda global',
                      autofocus: true,
                      onSubmitted: _search,
                      onChanged: (v) {
                        if (v.isEmpty) {
                          setState(() {
                            _byRepo.clear();
                            _searched = false;
                            _query = '';
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            if (_loading && sections.isEmpty)
              const Expanded(
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: kTvAccent,
                    ),
                  ),
                ),
              )
            else if (!_searched)
              Expanded(
                child: Center(
                  child: Text(
                    'Escribe y confirma para buscar en todos los repos',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.32),
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            else if (!_loading && sections.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'Sin resultados para "$_query"',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.32),
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 28),
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
                              color: kTvAccent,
                            ),
                          ),
                        ),
                      );
                    }
                    final s = sections[i];
                    return _RepoResultRow(
                      repo: s.repo,
                      items: s.items,
                      totalHint: i == 0 ? total : null,
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

class _RepoResultRow extends StatelessWidget {
  final InstalledRepo repo;
  final List<ContentItem> items;
  final int? totalHint;

  const _RepoResultRow({
    required this.repo,
    required this.items,
    this.totalHint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 14, 28, 8),
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
              const SizedBox(width: 10),
              Text(
                '${items.length} resultado${items.length == 1 ? '' : 's'}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final item = items[i];
              final poster = item.poster ?? '';
              return Focusable(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DetailsPage(
                        repo: repo,
                        itemId: item.id,
                      ),
                    ),
                  );
                },
                builder: (f) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 110,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: f ? Colors.white : Colors.transparent,
                      width: 2.5,
                    ),
                    boxShadow: f
                        ? [
                            BoxShadow(
                              color: kTvAccent.withValues(alpha: 0.35),
                              blurRadius: 14,
                            )
                          ]
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: poster.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: poster,
                                fit: BoxFit.cover,
                                memCacheWidth: 220,
                                errorWidget: (_, __, ___) =>
                                    const ColoredBox(color: Color(0xFF1A222D)),
                              )
                            : const ColoredBox(color: Color(0xFF1A222D)),
                      ),
                      Container(
                        color: const Color(0xFF12161E),
                        padding: const EdgeInsets.fromLTRB(6, 5, 6, 6),
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.2,
                            fontWeight: FontWeight.w500,
                          ),
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
