// home.dart — Diseño TV (hero fijo + sliders) · Datos del home móvil

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../contenido/page_contenido.dart';
import '../../data/datasources/remote/tmdb/tmdb_home_mobile_api.dart';

const kAccentColor = Color(0xFFE50914);
const kBgColor = Colors.black;

class HomePage extends StatefulWidget {
  final VoidCallback? onRequestMenuFocus;
  final ValueChanged<FocusNode>? onMainFocusNodeCreated;

  const HomePage({
    super.key,
    this.onRequestMenuFocus,
    this.onMainFocusNodeCreated,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  final TmdbHomeMobileService _tmdb = TmdbHomeMobileService();

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;
  List<_SectionData> _sections = [];

  final List<FocusNode> _sectionFocusNodes = [];
  bool _reportedMainNode = false;

  final ValueNotifier<Map<String, dynamic>?> _focusedItemNotifier =
      ValueNotifier(null);
  final ValueNotifier<String> _heroBackdropNotifier = ValueNotifier('');
  Timer? _focusDebounce;
  int _backdropRequestId = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _fetchHome();
  }

  @override
  void dispose() {
    _focusDebounce?.cancel();
    _focusedItemNotifier.dispose();
    _heroBackdropNotifier.dispose();
    for (final node in _sectionFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncFocusNodes(int count) {
    while (_sectionFocusNodes.length < count) {
      _sectionFocusNodes.add(
        FocusNode(debugLabel: 'home_section_${_sectionFocusNodes.length}'),
      );
    }
    while (_sectionFocusNodes.length > count) {
      _sectionFocusNodes.removeLast().dispose();
    }
  }

  // ── Historial (Continuar viendo) ────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _loadHistorial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where((k) => k.startsWith('cachePlayer_'))
          .toList();

      final result = <Map<String, dynamic>>[];
      for (final key in keys) {
        try {
          final raw = prefs.getString(key);
          if (raw == null) continue;
          final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          final segundo = data['segundo'] as int? ?? 0;
          if (segundo < 8) continue;
          result.add(data);
        } catch (_) {}
      }
      result.sort((a, b) {
        final ta = a['timestamp']?.toString() ?? '';
        final tb = b['timestamp']?.toString() ?? '';
        return tb.compareTo(ta);
      });
      return result;
    } catch (_) {
      return [];
    }
  }

  // ── Construcción de secciones (robusta) ─────────────────────────────────
  List<_SectionData> _buildSections(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> historial,
  ) {
    final sections = <_SectionData>[];

    // Normalizamos a Map<String, {items|results: [...]}>
    Map<String, dynamic> normalized = {};

    final looksLikeFlat = data.values.any(
      (v) => v is Map && (v['items'] is List || v['results'] is List),
    );

    if (looksLikeFlat) {
      normalized = data;
    } else if (data['results'] is List) {
      for (final s in data['results'] as List) {
        if (s is Map && s['key'] != null) {
          normalized[s['key'].toString()] = s;
        }
      }
    } else if (data['sections'] is List) {
      for (final s in data['sections'] as List) {
        if (s is Map && s['key'] != null) {
          normalized[s['key'].toString()] = s;
        }
      }
    } else {
      normalized = data;
    }

    void addSection(String key, {bool horizontalCards = false}) {
      final section = normalized[key];
      if (section is! Map) return;
      final raw = section['items'] ?? section['results'];
      if (raw is! List) return;
      final items = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (items.isEmpty) return;
      sections.add(
        _SectionData(
          title: (section['title'] ?? section['name'] ?? key).toString(),
          items: items,
          horizontalCards: horizontalCards,
        ),
      );
    }

    if (historial.isNotEmpty) {
      sections.add(
        _SectionData(
          title: 'Continuar Viendo',
          items: historial,
          isHistorial: true,
        ),
      );
    }

    addSection('recent_movies');
    addSection('recent_tv');
    addSection('recent_episodes', horizontalCards: true);
    addSection('top_movies');
    addSection('top_tv');
    addSection('popular_movies');
    addSection('popular_tv');
    addSection('trending_movies');
    addSection('trending_tv');

    final genreSliders = normalized['movie_genre_sliders'];
    if (genreSliders is List) {
      for (final genre in genreSliders) {
        if (genre is! Map) continue;
        final raw = genre['items'] ?? genre['results'];
        if (raw is! List) continue;
        final items = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (items.isEmpty) continue;
        sections.add(
          _SectionData(
            title: (genre['name'] ?? 'Género').toString(),
            items: items,
          ),
        );
      }
    } else if (genreSliders is Map) {
      genreSliders.forEach((name, value) {
        if (value is! Map) return;
        final raw = value['items'] ?? value['results'];
        if (raw is! List) return;
        final items = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (items.isEmpty) return;
        sections.add(
          _SectionData(
            title: value['name']?.toString() ?? name.toString(),
            items: items,
          ),
        );
      });
    }

    return sections;
  }

  Map<String, dynamic>? _pickInitialFocusedItem(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> historial,
  ) {
    if (historial.isNotEmpty) return historial.first;

    Map<String, dynamic> normalized = {};
    final looksLikeFlat = data.values.any(
      (v) => v is Map && (v['items'] is List || v['results'] is List),
    );
    if (looksLikeFlat) {
      normalized = data;
    } else if (data['results'] is List) {
      for (final s in data['results'] as List) {
        if (s is Map && s['key'] != null) {
          normalized[s['key'].toString()] = s;
        }
      }
    } else if (data['sections'] is List) {
      for (final s in data['sections'] as List) {
        if (s is Map && s['key'] != null) {
          normalized[s['key'].toString()] = s;
        }
      }
    } else {
      normalized = data;
    }

    const candidates = [
      'main_slider',
      'recent_movies',
      'recent_tv',
      'recent_episodes',
      'top_movies',
      'top_tv',
      'popular_movies',
      'popular_tv',
      'trending_movies',
      'trending_tv',
    ];
    for (final key in candidates) {
      final section = normalized[key];
      if (section is Map) {
        final raw = section['items'] ?? section['results'];
        if (raw is List && raw.isNotEmpty) {
          final first = raw.first;
          if (first is Map) return Map<String, dynamic>.from(first);
        }
      }
    }

    final genreSliders = normalized['movie_genre_sliders'];
    if (genreSliders is List) {
      for (final genre in genreSliders) {
        if (genre is Map) {
          final raw = genre['items'] ?? genre['results'];
          if (raw is List && raw.isNotEmpty) {
            final first = raw.first;
            if (first is Map) return Map<String, dynamic>.from(first);
          }
        }
      }
    } else if (genreSliders is Map) {
      for (final value in genreSliders.values) {
        if (value is Map) {
          final raw = value['items'] ?? value['results'];
          if (raw is List && raw.isNotEmpty) {
            final first = raw.first;
            if (first is Map) return Map<String, dynamic>.from(first);
          }
        }
      }
    }

    return null;
  }

  Future<void> _fetchHome() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final json = await _tmdb.fetchHome();
      if (!mounted) return;

      if (json['success'] != true || json['data'] is! Map) {
        setState(() {
          _error = 'Error en la respuesta de TMDB';
          _loading = false;
        });
        return;
      }

      final data = Map<String, dynamic>.from(json['data'] as Map);
      final historial = await _loadHistorial();
      if (!mounted) return;

      // Diagnóstico (quítalo cuando ya funcione)
      debugPrint('[HOME] keys = ${data.keys.toList()}');
      debugPrint('[HOME] historial = ${historial.length}');
      for (final k in data.keys) {
        final v = data[k];
        if (v is Map) {
          final items = v['items'] ?? v['results'];
          debugPrint(
            '[HOME] $k → title=${v['title'] ?? v['name']} '
            'items=${items is List ? items.length : items.runtimeType}',
          );
        } else if (v is List) {
          debugPrint('[HOME] $k → List(len=${v.length})');
        } else {
          debugPrint('[HOME] $k → ${v.runtimeType}');
        }
      }

      final allSections = _buildSections(data, historial);
      final initialItem = _pickInitialFocusedItem(data, historial);

      debugPrint('[HOME] allSections = ${allSections.length}');

      if (allSections.isEmpty) {
        setState(() {
          _data = data;
          _sections = [];
          _focusedItemNotifier.value = initialItem;
          if (initialItem != null) {
            _heroBackdropNotifier.value = _fallbackBackdrop(initialItem);
          }
          _loading = false;
          _error = 'Sin contenido disponible';
        });
        return;
      }

      final firstBatch = allSections.take(3).toList();
      _syncFocusNodes(1 + allSections.length);

      setState(() {
        _data = data;
        _sections = firstBatch;
        _loading = false;
      });

      _focusedItemNotifier.value = initialItem;
      if (initialItem != null) {
        _refreshHeroBackdrop(initialItem);
      }

      if (allSections.length > 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _sections = allSections);
        });
      }
    } catch (e, st) {
      debugPrint('[HOME] _fetchHome error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = 'Sin conexión o error de red';
        _loading = false;
      });
    }
  }

  void _refreshHeroBackdrop(Map<String, dynamic> item) {
    final id = item['tmdb_id'] as int? ??
        item['idcontenido'] as int? ??
        item['id'] as int? ??
        0;
    if (id <= 0) {
      _heroBackdropNotifier.value = _fallbackBackdrop(item);
      return;
    }
    _backdropRequestId++;
    _heroBackdropNotifier.value = _fallbackBackdrop(item);
  }

  String _fallbackBackdrop(Map? item) {
    if (item == null) return '';
    final backdrop = item['backdrop_path']?.toString() ??
        item['backdrop']?.toString() ??
        '';
    if (backdrop.isEmpty || backdrop == 'null') {
      final poster = item['poster_path']?.toString() ??
          item['poster']?.toString() ??
          '';
      if (poster.isEmpty || poster == 'null') return '';
      return poster.startsWith('http')
          ? poster
          : 'https://image.tmdb.org/t/p/w780$poster';
    }
    return backdrop.startsWith('http')
        ? backdrop
        : 'https://image.tmdb.org/t/p/w1280$backdrop';
  }

  void _onItemFocused(Map<String, dynamic> item) {
    final cur = _focusedItemNotifier.value;
    if (cur != null &&
        cur['idcontenido'] == item['idcontenido'] &&
        cur['media_type'] == item['media_type'] &&
        cur['titulo'] == item['titulo']) {
      _refreshHeroBackdrop(item);
      return;
    }
    _focusDebounce?.cancel();
    _focusDebounce = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) return;
      _focusedItemNotifier.value = item;
      _refreshHeroBackdrop(item);
    });
  }

  void _openContent(Map<String, dynamic> item) {
    final id = item['tmdb_id'] as int? ??
        item['idcontenido'] as int? ??
        item['id'] as int? ??
        0;
    if (id <= 0) return;
    final tipo =
        (item['media_type'] ?? item['tipo'] ?? item['type'] ?? 'movie')
            .toString()
            .toLowerCase();
    final tipoNorm = (tipo == 'tv' || tipo == 'serie' || tipo == 'series')
        ? 'tv'
        : 'movie';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PageContenido(
          idcontenido: id,
          tmdbId: id,
          mediaType: tipoNorm,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading) {
      return const Scaffold(
        backgroundColor: kBgColor,
        body: _HomeSkeleton(),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: kBgColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _fetchHome,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccentColor,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    final sections = _sections;

    if (_sectionFocusNodes.length < sections.length + 1) {
      _syncFocusNodes(sections.length + 1);
    }

    if (!_reportedMainNode && _sectionFocusNodes.isNotEmpty) {
      _reportedMainNode = true;
      final node = _sectionFocusNodes.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onMainFocusNodeCreated?.call(node);
      });
    }

    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 1.6);
    final heroHeight = size.height * 0.52;
    final bgMemW = math.min(size.width * dpr, 1280).round();
    final bgMemH = math.min(size.height * dpr, 720).round();

    return Scaffold(
      backgroundColor: kBgColor,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ValueListenableBuilder<String>(
              valueListenable: _heroBackdropNotifier,
              builder: (context, backdropUrl, _) {
                if (backdropUrl.isEmpty) {
                  return const ColoredBox(color: Color(0xFF0a0a0a));
                }
                return CachedNetworkImage(
                  imageUrl: backdropUrl,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  memCacheWidth: bgMemW,
                  memCacheHeight: bgMemH,
                  fadeInDuration: const Duration(milliseconds: 280),
                  placeholder: (_, __) =>
                      const ColoredBox(color: Color(0xFF0a0a0a)),
                  errorWidget: (_, __, ___) =>
                      const ColoredBox(color: Color(0xFF0a0a0a)),
                );
              },
            ),
          ),
          const _HomeOverlayGradient(),
          Column(
            children: [
              SizedBox(
                height: heroHeight,
                width: double.infinity,
                child: RepaintBoundary(
                  child: ValueListenableBuilder<Map<String, dynamic>?>(
                    valueListenable: _focusedItemNotifier,
                    builder: (context, item, _) {
                      if (_sectionFocusNodes.isEmpty) {
                        return const ColoredBox(color: Color(0xFF0a0a0a));
                      }
                      return _HeroSection(
                        item: item,
                        focusNode: _sectionFocusNodes[0],
                        onRequestMenuFocus: widget.onRequestMenuFocus,
                        onRequestNextFocus:
                            (_sectionFocusNodes.length > 1 &&
                                    sections.isNotEmpty)
                                ? () => _sectionFocusNodes[1].requestFocus()
                                : null,
                        onTap: _openContent,
                      );
                    },
                  ),
                ),
              ),
              Expanded(
                child: sections.isEmpty
                    ? const Center(
                        child: Text(
                          'Sin contenido',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : CustomScrollView(
                        cacheExtent: 300,
                        slivers: [
                          SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, i) {
                                if (i >= sections.length) {
                                  return const SizedBox.shrink();
                                }
                                if (i + 1 >= _sectionFocusNodes.length) {
                                  return const SizedBox.shrink();
                                }
                                final section = sections[i];
                                final node = _sectionFocusNodes[i + 1];
                                final upNode = _sectionFocusNodes[i];

                                final hasDown =
                                    (i + 2) < _sectionFocusNodes.length &&
                                        (i + 1) < sections.length;
                                final downNode =
                                    hasDown ? _sectionFocusNodes[i + 2] : null;

                                return RepaintBoundary(
                                  child: _HorizontalSlider(
                                    title: section.title,
                                    items: section.items,
                                    onTap: _openContent,
                                    focusNode: node,
                                    onRequestFocusUp: () =>
                                        upNode.requestFocus(),
                                    onRequestFocusDown: downNode != null
                                        ? () => downNode.requestFocus()
                                        : null,
                                    onRequestMenuFocus:
                                        widget.onRequestMenuFocus,
                                    onItemFocused: _onItemFocused,
                                    horizontalCards: section.horizontalCards,
                                    isHistorial: section.isHistorial,
                                  ),
                                );
                              },
                              childCount: sections.length,
                              addRepaintBoundaries: false,
                            ),
                          ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 48),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Skeleton ─────────────────────────────────────────────────────────────
class _HomeSkeleton extends StatefulWidget {
  const _HomeSkeleton();

  @override
  State<_HomeSkeleton> createState() => _HomeSkeletonState();
}

class _HomeSkeletonState extends State<_HomeSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.18, end: 0.38).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final heroHeight = size.height * 0.52;

    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, _) {
        final bone = Color.fromRGBO(255, 255, 255, _opacity.value);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: heroHeight,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF0a0a0a)),
                  Positioned(
                    left: 36,
                    bottom: 28,
                    right: size.width * 0.36,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: size.width * 0.28,
                          height: 36,
                          decoration: BoxDecoration(
                            color: bone,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          width: size.width * 0.32,
                          height: 12,
                          decoration: BoxDecoration(
                            color: bone,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: 3,
                itemBuilder: (_, row) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 0, 28, 10),
                          child: Container(
                            width: 140 + (row * 18).toDouble(),
                            height: 16,
                            decoration: BoxDecoration(
                              color: bone,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 124,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            physics: const NeverScrollableScrollPhysics(),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 22),
                            itemCount: 6,
                            itemBuilder: (_, i) => Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Container(
                                width: 210,
                                height: 118,
                                decoration: BoxDecoration(
                                  color: bone,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeOverlayGradient extends StatelessWidget {
  const _HomeOverlayGradient();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0xF0000000),
                Color(0xC4000000),
                Color(0x9C000000),
                Color(0x7A000000),
                Color(0x7A000000),
              ],
              stops: [0.0, 0.28, 0.50, 0.78, 1.0],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Color(0x59000000),
                Color(0xD1000000),
              ],
              stops: [0.35, 0.58, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionData {
  final String title;
  final List<Map<String, dynamic>> items;
  final bool horizontalCards;
  final bool isHistorial;

  _SectionData({
    required this.title,
    required this.items,
    this.horizontalCards = false,
    this.isHistorial = false,
  });
}

// ── Hero ────────────────────────────────────────────────────────────────
class _HeroSection extends StatelessWidget {
  final Map<String, dynamic>? item;
  final FocusNode focusNode;
  final VoidCallback? onRequestMenuFocus;
  final VoidCallback? onRequestNextFocus;
  final void Function(Map<String, dynamic> item) onTap;

  const _HeroSection({
    required this.item,
    required this.focusNode,
    this.onRequestMenuFocus,
    this.onRequestNextFocus,
    required this.onTap,
  });

  String _logo(Map? item) {
    if (item == null) return '';
    final logo = item['logo_path']?.toString() ?? '';
    if (logo.startsWith('http') && !logo.contains('[')) return logo;
    return '';
  }

  String _title(Map? item) =>
      item?['title']?.toString() ??
      item?['series_title']?.toString() ??
      item?['titulo']?.toString() ??
      item?['name']?.toString() ??
      '';

  String _genres(Map? item) {
    final g = item?['genres']?.toString() ??
        item?['genre']?.toString() ??
        item?['genres_text']?.toString() ??
        '';
    return g;
  }

  String _year(Map? item) {
    final rd = item?['release_date']?.toString() ??
        item?['first_air_date']?.toString() ??
        '';
    if (rd.length >= 4) return rd.substring(0, 4);
    return item?['year']?.toString() ?? '';
  }

  String _runtime(Map? item) {
    final r = item?['runtime'];
    if (r == null) return '';
    final mins = r is int ? r : int.tryParse(r.toString()) ?? 0;
    if (mins <= 0) return '';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }

  String _overview(Map? item) => item?['overview']?.toString() ?? '';

  double? _tmdbRating(Map? item) {
    final v = item?['vote_average'];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final logoUrl = _logo(item);
    final title = _title(item);
    final genres = _genres(item);
    final year = _year(item);
    final runtime = _runtime(item);
    final overview = _overview(item);
    final tmdb = _tmdbRating(item);
    final id = item?['tmdb_id'] as int? ??
        item?['idcontenido'] as int? ??
        item?['id'] as int? ??
        0;

    final topSafe = MediaQuery.paddingOf(context).top + 72;

    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          onRequestMenuFocus?.call();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          onRequestNextFocus?.call();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          if (item != null && id > 0) {
            onTap(Map<String, dynamic>.from(item!));
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: (item != null && id > 0)
                ? () => onTap(Map<String, dynamic>.from(item!))
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasFocus)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 36,
                  top: topSafe,
                  right: size.width * 0.36,
                  bottom: 14,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: SizedBox(
                      key: ValueKey('${id}_${item?['media_type']}'),
                      width: double.infinity,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (logoUrl.isNotEmpty)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: size.width * 0.42,
                                maxHeight: 52,
                              ),
                              child: CachedNetworkImage(
                                imageUrl: logoUrl,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                errorWidget: (_, __, ___) => Text(
                                  title.toUpperCase(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    height: 1.08,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                              ),
                            )
                          else
                            Text(
                              title.toUpperCase(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                height: 1.08,
                                letterSpacing: -0.4,
                              ),
                            ),
                          const SizedBox(height: 6),
                          if (year.isNotEmpty ||
                              genres.isNotEmpty ||
                              runtime.isNotEmpty ||
                              (tmdb != null && tmdb > 0))
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    [
                                      if (year.isNotEmpty) year,
                                      if (genres.isNotEmpty) genres,
                                      if (runtime.isNotEmpty) runtime,
                                    ].join('  ·  '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white
                                          .withValues(alpha: 0.88),
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (tmdb != null && tmdb > 0) ...[
                                  const SizedBox(width: 10),
                                  _RatingBadge(
                                    label: 'TMDB',
                                    value: tmdb.toStringAsFixed(1),
                                    color: const Color(0xFF01B4E4),
                                  ),
                                ],
                              ],
                            ),
                          if (overview.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              overview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.82),
                                fontSize: 12,
                                height: 1.28,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
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

class _RatingBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _RatingBadge({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Slider horizontal ───────────────────────────────────────────────────
class _HorizontalSlider extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> items;
  final void Function(Map<String, dynamic> item) onTap;
  final FocusNode focusNode;
  final VoidCallback? onRequestFocusUp;
  final VoidCallback? onRequestFocusDown;
  final VoidCallback? onRequestMenuFocus;
  final ValueChanged<Map<String, dynamic>> onItemFocused;
  final bool horizontalCards;
  final bool isHistorial;

  const _HorizontalSlider({
    required this.title,
    required this.items,
    required this.onTap,
    required this.focusNode,
    required this.onItemFocused,
    this.onRequestFocusUp,
    this.onRequestFocusDown,
    this.onRequestMenuFocus,
    this.horizontalCards = false,
    this.isHistorial = false,
  });

  @override
  State<_HorizontalSlider> createState() => _HorizontalSliderState();
}

class _HorizontalSliderState extends State<_HorizontalSlider> {
  static const double _cardW = 210;
  static const double _cardH = 118;
  static const int _maxVisible = 7;

  int _focusedIndex = 0;

  void _cycle(int delta) {
    if (widget.items.isEmpty) return;
    final len = widget.items.length;
    final next = _focusedIndex + delta;
    if (next < 0 || next >= len) return;
    setState(() => _focusedIndex = next);
    widget.onItemFocused(widget.items[_focusedIndex]);
  }

  @override
  void didUpdateWidget(covariant _HorizontalSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _focusedIndex = 0;
    }
  }

  String _imageUrl(Map item) {
    final backdrop = item['backdrop_path']?.toString() ??
        item['backdrop']?.toString() ??
        '';
    if (backdrop.isNotEmpty && backdrop != 'null' && !backdrop.contains('[')) {
      return backdrop.startsWith('http')
          ? backdrop
          : 'https://image.tmdb.org/t/p/w780$backdrop';
    }
    final poster =
        item['poster_path']?.toString() ?? item['poster']?.toString() ?? '';
    if (poster.isNotEmpty && poster != 'null' && !poster.contains('[')) {
      return poster.startsWith('http')
          ? poster
          : 'https://image.tmdb.org/t/p/w500$poster';
    }
    return '';
  }

  String _logoUrl(Map item) {
    final logo = item['logo_path']?.toString() ?? '';
    if (logo.isNotEmpty &&
        logo != 'null' &&
        logo.startsWith('http') &&
        !logo.contains('[')) {
      return logo;
    }
    return '';
  }

  String _titleOf(Map item) {
    return item['title']?.toString() ??
        item['series_title']?.toString() ??
        item['titulo']?.toString() ??
        item['name']?.toString() ??
        '';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 1.8);
    final memW = (_cardW * dpr).round();
    final memH = (_cardH * dpr).round();

    final visibleCount =
        widget.items.length < _maxVisible ? widget.items.length : _maxVisible;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _cycle(1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (_focusedIndex <= 0) {
            widget.onRequestMenuFocus?.call();
            return KeyEventResult.handled;
          }
          _cycle(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          widget.onRequestFocusUp?.call();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          widget.onRequestFocusDown?.call();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          if (widget.items.isNotEmpty) {
            final idx = _focusedIndex.clamp(0, widget.items.length - 1);
            widget.onTap(widget.items[idx]);
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      onFocusChange: (hasFocus) {
        setState(() {});
        if (hasFocus && widget.items.isNotEmpty) {
          final idx = _focusedIndex.clamp(0, widget.items.length - 1);
          widget.onItemFocused(widget.items[idx]);
          Scrollable.ensureVisible(
            context,
            alignment: 0.25,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
          );
        }
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'ver más +',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: _cardH + 6,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    itemCount: visibleCount,
                    physics: const NeverScrollableScrollPhysics(),
                    itemBuilder: (context, slot) {
                      final itemIndex = _focusedIndex + slot;
                      if (itemIndex >= widget.items.length) {
                        return const SizedBox.shrink();
                      }
                      final item = widget.items[itemIndex];
                      final isFocusedSlot = slot == 0 && hasFocus;

                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: _PosterCard(
                          posterUrl: _imageUrl(item),
                          logoUrl: _logoUrl(item),
                          title: _titleOf(item),
                          isFocused: isFocusedSlot,
                          width: _cardW,
                          height: _cardH,
                          memW: memW,
                          memH: memH,
                          onTap: () => widget.onTap(item),
                        ),
                      );
                    },
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

class _PosterCard extends StatelessWidget {
  final String posterUrl;
  final String logoUrl;
  final String title;
  final bool isFocused;
  final double width;
  final double height;
  final int memW;
  final int memH;
  final VoidCallback onTap;

  const _PosterCard({
    required this.posterUrl,
    this.logoUrl = '',
    this.title = '',
    required this.isFocused,
    required this.width,
    required this.height,
    required this.memW,
    required this.memH,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const radius = 12.0;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: isFocused ? Colors.white : Colors.transparent,
            width: 2.5,
          ),
          boxShadow: isFocused
              ? [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.2),
                    blurRadius: 6,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1.5),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (posterUrl.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: posterUrl,
                  fit: BoxFit.cover,
                  width: width,
                  height: height,
                  memCacheWidth: memW,
                  memCacheHeight: memH,
                  fadeInDuration: const Duration(milliseconds: 90),
                  placeholder: (_, __) =>
                      Container(color: const Color(0xFF1a1a1a)),
                  errorWidget: (_, __, ___) => Container(
                    color: const Color(0xFF1a1a1a),
                    child: const Icon(
                      Icons.movie,
                      color: Colors.white24,
                      size: 28,
                    ),
                  ),
                )
              else
                Container(
                  color: const Color(0xFF1a1a1a),
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (logoUrl.isNotEmpty) ...[
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Color(0x99000000),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  right: width * 0.28,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: height * 0.32,
                        maxWidth: width * 0.62,
                      ),
                      child: CachedNetworkImage(
                        imageUrl: logoUrl,
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomLeft,
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}