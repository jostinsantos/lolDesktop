import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../contenido/contenido.dart';

const _card = Color(0xFF161A22);
const _accent = Color(0xFFE50914);

class RepoSearchPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoSearchPage({super.key, required this.repo});

  @override
  State<RepoSearchPage> createState() => _RepoSearchPageState();
}

class _RepoSearchPageState extends State<RepoSearchPage> {
  final _ctrl = TextEditingController();
  List<ContentItem> _results = [];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.length < 2) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final items = await ContentService.instance.search(widget.repo, query);
      if (!mounted) return;
      setState(() {
        _results = items;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            onSubmitted: _search,
            decoration: InputDecoration(
              hintText: 'Buscar en ${widget.repo.manifest.name}...',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1A1F2A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
                  : _results.isEmpty
                      ? const Center(child: Text('Escribe para buscar', style: TextStyle(color: Colors.white38)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(24),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisSpacing: 16,
                            crossAxisSpacing: 16,
                            childAspectRatio: 0.58,
                          ),
                          itemCount: _results.length,
                          itemBuilder: (context, i) {
                            final item = _results[i];
                            return GestureDetector(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
                                  ),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: item.poster != null
                                          ? CachedNetworkImage(imageUrl: item.poster!, fit: BoxFit.cover)
                                          : Container(color: const Color(0xFF12151C)),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
