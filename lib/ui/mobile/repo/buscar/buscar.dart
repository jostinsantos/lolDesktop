import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../../repo/contenido/contenido.dart';

class RepoSearchPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoSearchPage({super.key, required this.repo});
  @override
  State<RepoSearchPage> createState() => _RepoSearchPageState();
}

class _RepoSearchPageState extends State<RepoSearchPage> {
  final _controller = TextEditingController();
  List<ContentItem> _results = [];
  bool _loading = false;

  // Historial de búsquedas recientes
  final List<String> _history = [];

  /// true si el campo está vacío y no hay resultados activos
  bool get _showingHistory => _controller.text.trim().isEmpty && !_loading;

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
      });
      return;
    }

    // Guardar en historial (sin duplicados, más reciente primero)
    setState(() {
      _history.remove(query);
      _history.insert(0, query);
      if (_history.length > 10) _history.removeLast();
    });

    setState(() => _loading = true);
    final list = await ContentService.instance.search(widget.repo, query);
    if (mounted) {
      setState(() {
        _results = list;
        _loading = false;
      });
    }
  }

  void _onHistoryTap(String query) {
    _controller.text = query;
    _search(query);
  }

  void _clearHistory() {
    setState(() => _history.clear());
  }

  void _removeHistoryItem(String query) {
    setState(() => _history.remove(query));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildHistory() {
    if (_history.isEmpty) {
      return const Expanded(
        child: Center(
          child: Text(
            'Busca algo para empezar',
            style: TextStyle(color: Colors.white38, fontSize: 15),
          ),
        ),
      );
    }

    return Expanded(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Búsquedas recientes',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextButton(
                  onPressed: _clearHistory,
                  child: const Text(
                    'Limpiar',
                    style: TextStyle(color: Color(0xFFFF2D2D), fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          ..._history.map(
            (query) => Focusable(
              onTap: () => _onHistoryTap(query),
              builder: (focused) => AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A222D),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: focused
                        ? const Color(0xFFFF2D2D)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, color: Colors.white54),
                  title: Text(
                    query,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                    onPressed: () => _removeHistoryItem(query),
                  ),
                  onTap: () => _onHistoryTap(query),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    return Expanded(
      child: GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          childAspectRatio: 0.65,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: _results.length,
        itemBuilder: (context, i) {
          final item = _results[i];
          return Focusable(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
            )),
            builder: (focused) => AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: focused ? const Color(0xFFFF2D2D) : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: item.poster != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedNetworkImage(
                            imageUrl: item.poster!,
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            height: 42,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.white.withValues(alpha: 0.22),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Container(color: const Color(0xFF1A222D)),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: TextField(
            controller: _controller,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Buscar en ${widget.repo.manifest.name}...',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1A222D),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _results = []);
                      },
                    )
                  : null,
            ),
            onSubmitted: _search,
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_loading)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_showingHistory)
          _buildHistory()
        else
          _buildResults(),
      ],
    );
  }
}