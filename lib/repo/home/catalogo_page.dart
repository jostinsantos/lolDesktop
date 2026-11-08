import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../contenido/contenido.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

class CatalogPage extends StatefulWidget {
  final InstalledRepo repo;
  final String catalogId;
  final String title;

  const CatalogPage({
    super.key,
    required this.repo,
    required this.catalogId,
    required this.title,
  });

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  List<ContentItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ContentService.instance.getCatalogItems(widget.repo, widget.catalogId);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
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
                      padding: const EdgeInsets.all(24),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.58,
                      ),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        return _GridPoster(
                          item: item,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}

class _GridPoster extends StatefulWidget {
  final ContentItem item;
  final VoidCallback onTap;
  const _GridPoster({required this.item, required this.onTap});

  @override
  State<_GridPoster> createState() => _GridPosterState();
}

class _GridPosterState extends State<_GridPoster> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final poster = widget.item.poster;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _hover ? _accent.withValues(alpha: 0.55) : Colors.transparent, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: poster != null && poster.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: poster,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(color: const Color(0xFF12151C)),
                      )
                    : Container(color: const Color(0xFF12151C)),
              ),
              Container(
                color: _card,
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                child: Text(
                  widget.item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
