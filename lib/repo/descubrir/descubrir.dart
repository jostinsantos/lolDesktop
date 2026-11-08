import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/repo_manifest.dart';
import '../../../data/services/content_service.dart';
import '../contenido/contenido.dart';
import '../home/catalogo_individual.dart';

const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _accent = Color(0xFFE50914);

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

class DiscoverPage extends StatefulWidget {
  final InstalledRepo repo;
  const DiscoverPage({super.key, required this.repo});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _scroll = ScrollController();
  final List<_RepoFilter> _filters = [];

  List<ContentItem> _items = [];
  bool _loading = true;       // carga inicial / cambio de filtro
  bool _loadingMore = false;  // solo paginación
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  // Evita llamadas concurrentes
  bool _busy = false;

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
    if (_busy || _loading || _loadingMore || !_hasMore) return;
    if (!_scroll.hasClients) return;

    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  Future<void> _bootstrap() async {
    await _loadFilterDefs();
    await _reload(reset: true);
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

  Future<void> _loadFilterDefs() async {
    try {
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

      // Formato antiguo (lista plana)
      if (parsed.isEmpty && raw.isNotEmpty) {
        final options = raw.map((f) {
          final id = (f['id'] ?? '').toString();
          final label = (f['label'] ?? id).toString();
          return (id: id, label: label);
        }).where((e) => e.id.isNotEmpty).toList();

        if (options.isNotEmpty) {
          parsed.add(_RepoFilter(
            id: 'filter',
            label: 'Filtro',
            options: options,
            selectedId: options.first.id,
          ));
        }
      }

      // Preservar selección anterior si sigue válida
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
    } catch (_) {
      // silencioso: si fallan los filtros, seguimos con lo que haya
    }
  }

  /// Carga SOLO la página solicitada del filtro actual.
  Future<void> _reload({bool reset = true}) async {
    if (_busy) return;
    _busy = true;

    if (reset) {
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
          _page = 1;
          _items = [];
          _hasMore = true;
          _loadingMore = false;
        });
      }
    }

    try {
      final result = await ContentService.instance.getDiscover(
        widget.repo,
        filters: _filterMap, // ← solo el filtro seleccionado
        page: 1,
      );

      if (!mounted) return;

      setState(() {
        _items = result.items;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _page = 1;
        _loading = false;
        _error = result.items.isEmpty ? 'Sin resultados' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _items = [];
        _hasMore = false;
      });
    } finally {
      _busy = false;
    }
  }

  Future<void> _loadMore() async {
    if (_busy || _loading || _loadingMore || !_hasMore) return;
    _busy = true;

    if (mounted) setState(() => _loadingMore = true);

    try {
      final nextPage = _page + 1;
      final result = await ContentService.instance.getDiscover(
        widget.repo,
        filters: _filterMap, // ← siempre el filtro actual
        page: nextPage,
      );

      if (!mounted) return;

      setState(() {
        if (result.items.isNotEmpty) {
          _items = [..._items, ...result.items];
          _page = nextPage;
        }
        // Solo seguimos si el backend dice que hay más Y trajo items
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingMore = false;
          _hasMore = false; // evitamos reintentos infinitos
        });
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _onFilterChanged(_RepoFilter filter, String newId) async {
    if (newId == filter.selectedId || _busy) return;

    // Actualizamos selección y mostramos loading inmediatamente
    setState(() {
      filter.selectedId = newId;
      _loading = true;
      _error = null;
      _items = []; // liberamos memoria de la página anterior
      _hasMore = true;
      _page = 1;
    });

    // Recargamos definiciones (filtros en cascada) + contenido del nuevo filtro
    await _loadFilterDefs();
    await _reload(reset: false); // ya limpiamos arriba
  }

  void _pickFilter(_RepoFilter f) {
    if (_busy || _loading) return;

    showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    f.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: f.options.length,
                    itemBuilder: (_, i) {
                      final o = f.options[i];
                      final active = o.id == f.selectedId;
                      return ListTile(
                        title: Text(
                          o.label,
                          style: TextStyle(
                            color: active ? _accent : Colors.white,
                          ),
                        ),
                        trailing: active
                            ? const Icon(Icons.check, color: _accent)
                            : null,
                        onTap: () => Navigator.pop(ctx, o.id),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ).then((selected) {
      if (selected != null && mounted) {
        _onFilterChanged(f, selected);
      }
    });
  }

  Future<void> _refreshAll() async {
    if (_busy) return;
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    await _loadFilterDefs();
    await _reload(reset: false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filtros + botón actualizar
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: _filters.map((f) {
                    return ActionChip(
                      label: Text(f.selectedLabel),
                      avatar: const Icon(
                        Icons.filter_list_rounded,
                        size: 16,
                        color: Colors.white70,
                      ),
                      backgroundColor: _card,
                      side: const BorderSide(color: _border),
                      labelStyle: const TextStyle(color: Colors.white),
                      onPressed: (_loading || _busy) ? null : () => _pickFilter(f),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Actualizar',
                onPressed: (_loading || _busy) ? null : _refreshAll,
                icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
                style: IconButton.styleFrom(
                  backgroundColor: _card,
                  side: const BorderSide(color: _border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Barra de progreso solo cuando cambia filtro o refresh
        if (_loading)
          const LinearProgressIndicator(
            minHeight: 2,
            color: _accent,
            backgroundColor: Colors.transparent,
          ),

        Expanded(
          child: _buildBody(),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }

    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => _reload(reset: true),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: _accent,
      onRefresh: _refreshAll,
      child: _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(
                  child: Text(
                    'No hay contenido',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              ],
            )
          : GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              controller: _scroll,
              padding: const EdgeInsets.all(24),
              // Importante: no precargar demasiado
              cacheExtent: 400,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.58,
              ),
              itemCount: _items.length + (_loadingMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _items.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          color: _accent,
                          strokeWidth: 2.5,
                        ),
                      ),
                    ),
                  );
                }

                final item = _items[i];
                return _ItemCard(
                  item: item,
                  onTap: () {
                    if (item.type == 'catalog') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CatalogDetailPage(
                            repo: widget.repo,
                            catalogId: item.id,
                            title: item.title,
                          ),
                        ),
                      );
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DetailsPage(
                            repo: widget.repo,
                            itemId: item.id,
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}

/// Widget separado para evitar rebuilds innecesarios de la imagen
class _ItemCard extends StatelessWidget {
  final ContentItem item;
  final VoidCallback onTap;

  const _ItemCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
                      memCacheWidth: 360, // limita memoria
                      fadeInDuration: const Duration(milliseconds: 150),
                      errorWidget: (_, __, ___) => Container(
                        color: const Color(0xFF12151C),
                      ),
                      placeholder: (_, __) => Container(
                        color: const Color(0xFF12151C),
                      ),
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
  }
}