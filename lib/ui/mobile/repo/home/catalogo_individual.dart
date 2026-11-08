import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../contenido/contenido.dart';

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
      appBar: AppBar(backgroundColor: const Color(0xFF141A22), title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)))
          : GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                childAspectRatio: 0.65,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _items.length + (_loadingMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _items.length) {
                  return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                }
                final item = _items[i];
                return Focusable(
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
                    ));
                  },
                  builder: (focused) => AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: focused ? const Color(0xFFFF2D2D) : Colors.transparent, width: 2.5),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: item.poster != null
                          ? CachedNetworkImage(imageUrl: item.poster!, fit: BoxFit.cover, memCacheWidth: 280)
                          : Container(color: const Color(0xFF1A222D)),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
