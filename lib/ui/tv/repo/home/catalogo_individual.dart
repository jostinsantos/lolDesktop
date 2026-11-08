import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../contenido/contenido.dart';
import '../main_home.dart';

class CatalogDetailPage extends StatefulWidget {
  final InstalledRepo repo;
  final String catalogId;
  final String title;
  const CatalogDetailPage({super.key, required this.repo, required this.catalogId, required this.title});

  @override
  State<CatalogDetailPage> createState() => _CatalogDetailPageState();
}

class _CatalogDetailPageState extends State<CatalogDetailPage> {
  final _scroll = ScrollController();
  List<ContentItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(1);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 280) {
      _load(_page + 1, more: true);
    }
  }

  Future<void> _load(int page, {bool more = false}) async {
    if (more) {
      setState(() => _loadingMore = true);
    } else {
      setState(() { _loading = true; _items = []; _page = 1; _hasMore = true; });
    }
    final res = await ContentService.instance.getCatalogItems(widget.repo, widget.catalogId, page: page);
    if (!mounted) return;
    setState(() {
      if (more) {
        _items = [..._items, ...res.items];
        _loadingMore = false;
      } else {
        _items = res.items;
        _loading = false;
      }
      _hasMore = res.hasMore && res.items.isNotEmpty;
      _page = page;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                  child: Text(
                    widget.title,
                    style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      childAspectRatio: 0.65,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: _items.length + (_loadingMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _items.length) {
                        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                      }
                      final item = _items[i];
                      return Focusable(
                        autofocus: i == 0,
                        isFirstInRow: (i % 7) == 0,
                        onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
                          ));
                        },
                        builder: (focused) => ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: item.poster != null
                              ? CachedNetworkImage(imageUrl: item.poster!, fit: BoxFit.cover, memCacheWidth: 220)
                              : Container(color: const Color(0xFF1A222D)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
