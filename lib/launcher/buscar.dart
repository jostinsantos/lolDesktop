import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../data/services/repo_manager.dart';
import '../data/services/content_service.dart';
import '../data/models/repo_manifest.dart';
import '../repo/contenido/contenido.dart';
import '../widgets/h_scroller.dart';

const _card = Color(0xFF141820);
const _accent = Color(0xFFE50914);
const _border = Color(0xFF1C222C);
const _textMuted = Color(0x8AFFFFFF);

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
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 10),
          child: TextField(
            controller: _ctrl,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Buscar en todos los repositorios…',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
              prefixIcon: const Icon(Icons.search_rounded,
                  color: Colors.white54, size: 22),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      onPressed: () {
                        _ctrl.clear();
                        _search('');
                      },
                    )
                  : null,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
          const Expanded(
              child: Center(
                  child: CircularProgressIndicator(color: _accent)))
        else if (_query.length < 2)
          const Expanded(
            child: Center(
              child: Text('Escribe al menos 2 caracteres',
                  style: TextStyle(color: Colors.white38, fontSize: 14)),
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
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
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
          child: Row(
            children: [
              Text(
                repo.manifest.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: -0.2),
              ),
              const SizedBox(width: 8),
              if (loading)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: _accent),
                )
              else
                Text(
                  '${items.length}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12.5),
                ),
            ],
          ),
        ),
        loading && items.isEmpty
            ? const SizedBox(
                height: 200,
                child: Center(
                    child: CircularProgressIndicator(color: _accent)),
              )
            : HScroller(
                height: 200,
                itemCount: items.length,
                itemExtent: 120,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                itemBuilder: (context, i) {
                  final item = items[i];
                  return SizedBox(
                    width: 120,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                DetailsPage(repo: repo, itemId: item.id),
                          ));
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: item.poster != null &&
                                        item.poster!.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: item.poster!,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, __, ___) =>
                                            Container(
                                                color:
                                                    const Color(0xFF10131A)),
                                      )
                                    : Container(
                                        color: const Color(0xFF10131A)),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                height: 1.25,
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
