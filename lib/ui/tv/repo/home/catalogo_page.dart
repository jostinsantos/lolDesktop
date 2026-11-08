import 'package:flutter/material.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../../widgets/cached_poster.dart';
import 'catalogo_individual.dart';
import '../main_home.dart';

class CatalogsPage extends StatefulWidget {
  final InstalledRepo repo;
  const CatalogsPage({super.key, required this.repo});
  @override
  State<CatalogsPage> createState() => _CatalogsPageState();
}

class _CatalogsPageState extends State<CatalogsPage> {
  List<CatalogInfo> _catalogs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ContentService.instance.getCatalogs(widget.repo);
    if (mounted) setState(() { _catalogs = list; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      
      body:  _loading
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: List.generate(
                4,
                (_) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: const SizedBox(height: 90, child: ColoredBox(color: Color(0xFF1A222D))),
                  ),
                ),
              ),
            )
          : RefreshIndicator(
              color: const Color(0xFFE50914),
              onRefresh: () async {
                setState(() => _loading = true);
                await _load();
              },
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _catalogs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final c = _catalogs[i];
                  return Focusable(
                    autofocus: i == 0,
                    isFirstInRow: true,
                    onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CatalogDetailPage(
                          repo: widget.repo,
                          catalogId: c.id,
                          title: c.title,
                        ),
                      ));
                    },
                    builder: (focused) => AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      height: 96,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: focused ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (c.backdrop != null || c.poster != null)
                              CachedPoster.backdrop(c.backdrop ?? c.poster, height: 96)
                            else
                              Container(color: const Color(0xFF1A222D)),
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(horizontal: 18),
                              color: Colors.black45,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(c.title,
                                      style: const TextStyle(
                                          color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                                  if (c.description != null && c.description!.isNotEmpty)
                                    Text(c.description!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
