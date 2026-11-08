import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../contenido/contenido.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

/// Página de un catálogo individual (misma lógica que TV).
class CatalogDetailPage extends StatefulWidget {
  final InstalledRepo repo;
  final String catalogId;
  final String title;
  const CatalogDetailPage({
    super.key,
    required this.repo,
    required this.catalogId,
    required this.title,
  });

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
  String? _error;

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
      setState(() {
        _loading = true;
        _items = [];
        _page = 1;
        _hasMore = true;
        _error = null;
      });
    }
    try {
      final res = await ContentService.instance.getCatalogItems(
        widget.repo,
        widget.catalogId,
        page: page,
      );
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D10),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
              : _items.isEmpty
                  ? const Center(child: Text('Sin contenido', style: TextStyle(color: Colors.white38)))
                  : GridView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(24),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.58,
                      ),
                      itemCount: _items.length + (_loadingMore ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _items.length) {
                          return const Center(child: CircularProgressIndicator(color: _accent));
                        }
                        final item = _items[i];
                        return GestureDetector(
                          onTap: () {
                            if (item.type == 'catalog') {
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CatalogDetailPage(
                                  repo: widget.repo,
                                  catalogId: item.id,
                                  title: item.title,
                                ),
                              ));
                              return;
                            }
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => DetailsPage(
                                repo: widget.repo,
                                itemId: item.id,
                              ),
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
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}
