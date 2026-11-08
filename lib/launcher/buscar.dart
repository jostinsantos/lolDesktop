import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../data/services/repo_manager.dart';
import '../data/services/content_service.dart';
import '../data/models/repo_manifest.dart';
import '../repo/contenido/contenido.dart';
import '../widgets/h_scroller.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

/// Buscador launcher: un slider horizontal por cada repo instalado.
class LauncherSearchPage extends StatefulWidget {
  const LauncherSearchPage({super.key});

  @override
  State<LauncherSearchPage> createState() => _LauncherSearchPageState();
}

class _LauncherSearchPageState extends State<LauncherSearchPage> {
  final _ctrl = TextEditingController();
  final Map<String, List<ContentItem>> _resultsByRepo = {};
  final Map<String, bool> _loadingByRepo = {};
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    setState(() {
      _query = query;
      _resultsByRepo.clear();
      _loadingByRepo.clear();
    });
    if (query.length < 2) {
      setState(() => _searching = false);
      return;
    }
    setState(() => _searching = true);
    final repos = context.read<RepoManager>().installed;
    // Buscar en paralelo por repo
    await Future.wait(repos.map((repo) async {
      setState(() => _loadingByRepo[repo.manifest.id] = true);
      try {
        final items = await ContentService.instance.search(repo, query);
        if (!mounted) return;
        setState(() {
          _resultsByRepo[repo.manifest.id] = items;
          _loadingByRepo[repo.manifest.id] = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _resultsByRepo[repo.manifest.id] = [];
          _loadingByRepo[repo.manifest.id] = false;
        });
      }
    }));
    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final repos = context.watch<RepoManager>().installed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
          child: TextField(
            controller: _ctrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Buscar en todos los repositorios…',
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () {
                        _ctrl.clear();
                        _search('');
                      },
                    )
                  : null,
            ),
            onSubmitted: _search,
            onChanged: (v) {
              if (v.trim().length >= 2) {
                _search(v);
              } else if (v.trim().isEmpty) {
                _search('');
              }
            },
          ),
        ),
        if (_searching && _resultsByRepo.isEmpty)
          const Expanded(child: Center(child: CircularProgressIndicator(color: _accent)))
        else if (_query.length < 2)
          const Expanded(
            child: Center(
              child: Text('Escribe al menos 2 caracteres', style: TextStyle(color: Colors.white38)),
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                for (final repo in repos) ...[
                  _RepoResultSlider(
                    repo: repo,
                    items: _resultsByRepo[repo.manifest.id] ?? [],
                    loading: _loadingByRepo[repo.manifest.id] == true,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _RepoResultSlider extends StatelessWidget {
  final InstalledRepo repo;
  final List<ContentItem> items;
  final bool loading;

  const _RepoResultSlider({
    required this.repo,
    required this.items,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    if (!loading && items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 10),
          child: Row(
            children: [
              Text(
                repo.manifest.name,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(width: 10),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
                )
              else
                Text(
                  '${items.length}',
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
            ],
          ),
        ),
        loading && items.isEmpty
            ? const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator(color: _accent)),
              )
            : HScroller(
                height: 220,
                itemCount: items.length,
                itemExtent: 130,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                itemBuilder: (context, i) {
                  final item = items[i];
                  return SizedBox(
                    width: 130,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => DetailsPage(repo: repo, itemId: item.id),
                          ));
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: item.poster != null && item.poster!.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: item.poster!,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, __, ___) =>
                                            Container(color: const Color(0xFF12151C)),
                                      )
                                    : Container(color: const Color(0xFF12151C)),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ],
    );
  }
}
