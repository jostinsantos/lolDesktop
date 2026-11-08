import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../data/models/repo_manifest.dart';
import '../../../../data/services/content_service.dart';
import '../../widgets/focusable.dart';
import '../contenido/contenido.dart';
import '../main_home.dart';

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
    final optionNodes = List.generate(filter.options.length, (_) => FocusNode());
    final optionKeys = List.generate(filter.options.length, (_) => GlobalKey());
    int selectedIndex = filter.options.indexWhere((o) => o.id == filter.selectedId);
    if (selectedIndex < 0) selectedIndex = 0;

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (optionNodes.isNotEmpty && selectedIndex < optionNodes.length) {
            optionNodes[selectedIndex].requestFocus();
          }
        });
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 100),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 320,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                ),
                decoration: BoxDecoration(
                  color: _kSheetBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.55),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                      child: Text(
                        filter.label,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        itemCount: filter.options.length,
                        itemBuilder: (_, i) {
                          final o = filter.options[i];
                          final isCurrent = o.id == filter.selectedId;
                          return Focus(
                            key: optionKeys[i],
                            focusNode: optionNodes[i],
                            onFocusChange: (has) {
                              if (!has) return;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                final c = optionKeys[i].currentContext;
                                if (c != null) {
                                  Scrollable.ensureVisible(
                                    c,
                                    duration: const Duration(milliseconds: 180),
                                    curve: Curves.easeOut,
                                    alignment: 0.4,
                                  );
                                }
                              });
                            },
                            onKeyEvent: (node, event) {
                              if (event is! KeyDownEvent) return KeyEventResult.ignored;
                              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                                if (i > 0) optionNodes[i - 1].requestFocus();
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                                if (i < optionNodes.length - 1) optionNodes[i + 1].requestFocus();
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey == LogicalKeyboardKey.select ||
                                  event.logicalKey == LogicalKeyboardKey.enter) {
                                Navigator.pop(ctx);
                                setState(() => filter.selectedId = o.id);
                                _loadFilterDefs().then((_) => _reload());
                                return KeyEventResult.handled;
                              }
                              if (event.logicalKey == LogicalKeyboardKey.escape ||
                                  event.logicalKey == LogicalKeyboardKey.goBack) {
                                Navigator.pop(ctx);
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: Builder(builder: (context) {
                              final hasFocus = Focus.of(context).hasFocus;
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  setState(() => filter.selectedId = o.id);
                                  _loadFilterDefs().then((_) => _reload());
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  margin: const EdgeInsets.only(bottom: 5),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                                  decoration: BoxDecoration(
                                    color: hasFocus
                                        ? Colors.white.withValues(alpha: 0.18)
                                        : (isCurrent ? _kAccent.withValues(alpha: 0.22) : Colors.transparent),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: hasFocus
                                          ? Colors.white
                                          : (isCurrent ? _kAccent.withValues(alpha: 0.6) : Colors.transparent),
                                      width: hasFocus ? 2 : 1.2,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          o.label,
                                          style: TextStyle(
                                            color: hasFocus || isCurrent ? Colors.white : Colors.white70,
                                            fontSize: 15,
                                            fontWeight: hasFocus || isCurrent ? FontWeight.w700 : FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      if (isCurrent)
                                        const Icon(Icons.check_rounded, color: _kAccent, size: 20),
                                    ],
                                  ),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      for (final n in optionNodes) {
        n.dispose();
      }
    });
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
                        isFirstInRow: i == 0,
                        onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
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
        crossAxisCount: 6,
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
          isFirstInRow: (i % 6) == 0,
          onLeftEdge: () => RepoNavScope.of(context)?.requestMenuFocus(),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DetailsPage(repo: widget.repo, itemId: item.id),
            ));
          },
          builder: (f) => ClipRRect(
            borderRadius: BorderRadius.circular(8),
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
        );
      },
    );
  }
}
