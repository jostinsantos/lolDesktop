import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../contenido/contenido.dart';

const _kAccent = Color(0xFFE50914);
const _kBg = Color(0xFF0B0E14);
const _kFilterBg = Color(0xFF2A2A38);
const _kSheetBg = Color(0xFF1C1C1E);

/// Filtro declarado por el repo (máx. 3 en pantalla).
class _RepoFilter {
  final String id;
  final String label;
  final List<({String id, String label})> options;
  String? selectedId;

  _RepoFilter({
    required this.id,
    required this.label,
    required this.options,
    this.selectedId,
  });

  String get selectedLabel {
    if (selectedId == null || selectedId!.isEmpty) return label;
    for (final o in options) {
      if (o.id == selectedId) return o.label;
    }
    return label;
  }
}

class RepoDiscoverPage extends StatefulWidget {
  final InstalledRepo repo;
  const RepoDiscoverPage({super.key, required this.repo});

  @override
  State<RepoDiscoverPage> createState() => _RepoDiscoverPageState();
}

class _RepoDiscoverPageState extends State<RepoDiscoverPage> {
  final _scroll = ScrollController();
  final List<_RepoFilter> _filters = [];
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
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 280) {
      _loadMore();
    }
  }

  Future<void> _bootstrap() async {
    await _loadFilterDefs();
    await _reload();
  }

  Future<void> _loadFilterDefs() async {
    final raw = await ContentService.instance.getDiscoverFilters(
      widget.repo,
      filters: _filterMap,
    );
    final parsed = <_RepoFilter>[];
    for (final f in raw.take(3)) {
      final id = (f['id'] ?? f['key'] ?? '').toString();
      final label = (f['label'] ?? f['name'] ?? id).toString();
      final optsRaw = f['options'] ?? f['values'] ?? f['items'];
      final options = <({String id, String label})>[];
      if (optsRaw is List) {
        for (final o in optsRaw) {
          if (o is Map) {
            final oid = (o['id'] ?? o['value'] ?? o['key'] ?? '').toString();
            final olab = (o['label'] ?? o['name'] ?? oid).toString();
            if (oid.isNotEmpty) options.add((id: oid, label: olab));
          } else if (o != null) {
            final s = o.toString();
            options.add((id: s, label: s));
          }
        }
      }
      // Compat: filtro plano tipo {id, label} sin options
      if (options.isEmpty && id.isNotEmpty) {
        options.add((id: id, label: label));
      }
      if (id.isNotEmpty) {
        parsed.add(_RepoFilter(
          id: id,
          label: label,
          options: options,
          selectedId: options.isNotEmpty ? options.first.id : null,
        ));
      }
    }
    // Si el repo devolvió lista plana de opciones (formato antiguo), un solo filtro
    if (parsed.isEmpty && raw.isNotEmpty) {
      final options = raw.map((f) {
        final id = (f['id'] ?? '').toString();
        final label = (f['label'] ?? id).toString();
        return (id: id, label: label);
      }).where((e) => e.id.isNotEmpty).toList();
      if (options.isNotEmpty) {
        parsed.add(_RepoFilter(id: 'filter', label: 'Filtro', options: options, selectedId: options.first.id));
      }
    }
    // Preservar selección si sigue existiendo
    for (final f in parsed) {
      final prev = _filters.where((x) => x.id == f.id).toList();
      if (prev.isNotEmpty && prev.first.selectedId != null) {
        final still = f.options.any((o) => o.id == prev.first.selectedId);
        if (still) f.selectedId = prev.first.selectedId;
      }
    }
    if (!mounted) return;
    setState(() {
      _filters
        ..clear()
        ..addAll(parsed);
    });
  }

  Map<String, dynamic> get _filterMap {
    final m = <String, dynamic>{};
    for (final f in _filters) {
      if (f.selectedId != null && f.selectedId!.isNotEmpty) {
        m[f.id] = f.selectedId;
      }
    }
    return m;
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasMore = true;
      _items = [];
    });
    final page = await ContentService.instance.getDiscover(
      widget.repo,
      filters: _filterMap,
      page: 1,
    );
    if (!mounted) return;
    setState(() {
      _items = page.items;
      _hasMore = page.hasMore;
      _page = 1;
      _loading = false;
      _error = page.items.isEmpty ? 'Sin resultados' : null;
    });
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loadingMore) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    final page = await ContentService.instance.getDiscover(
      widget.repo,
      filters: _filterMap,
      page: next,
    );
    if (!mounted) return;
    setState(() {
      _items = [..._items, ...page.items];
      _hasMore = page.hasMore && page.items.isNotEmpty;
      _page = next;
      _loadingMore = false;
    });
  }

  void _openFilterSheet(_RepoFilter filter) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _kSheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(filter.label,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontWeight: FontWeight.w600)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filter.options.length,
                  itemBuilder: (_, i) {
                    final o = filter.options[i];
                    final sel = o.id == filter.selectedId;
                    return ListTile(
                      title: Text(o.label, style: const TextStyle(color: Colors.white)),
                      trailing: sel ? const Icon(Icons.check, color: _kAccent) : null,
                      selected: sel,
                      selectedTileColor: _kAccent.withValues(alpha: 0.15),
                      onTap: () async {
                        Navigator.pop(ctx);
                        setState(() => filter.selectedId = o.id);
                        await _loadFilterDefs();
                        await _reload();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _kBg,
      child: Column(
        children: [
          if (_filters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  for (var i = 0; i < _filters.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: Focusable(
                        onTap: () => _openFilterSheet(_filters[i]),
                        builder: (f) => AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          decoration: BoxDecoration(
                            color: f ? Colors.white.withValues(alpha: 0.18) : _kFilterBg,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: f ? Colors.white : Colors.white24, width: f ? 2 : 1),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_filters[i].label,
                                        style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
                                    Text(_filters[i].selectedLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                                  ],
                                ),
                              ),
                              Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white.withValues(alpha: 0.65)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kAccent, strokeWidth: 2.5));
    }
    if (_items.isEmpty) {
      return Center(child: Text(_error ?? 'Sin resultados', style: const TextStyle(color: Colors.white54)));
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 8,
        childAspectRatio: 0.68,
      ),
      itemCount: _items.length + (_loadingMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= _items.length) {
          return const Center(child: CircularProgressIndicator(color: _kAccent, strokeWidth: 2));
        }
        final item = _items[i];
        return Focusable(
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
            ));
          },
          builder: (f) => AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: f ? Colors.white : Colors.transparent, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: item.poster != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(imageUrl: item.poster!, fit: BoxFit.cover, memCacheWidth: 240),
                        Positioned(
                          left: 0, right: 0, top: 0, height: 42,
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
    );
  }
}
