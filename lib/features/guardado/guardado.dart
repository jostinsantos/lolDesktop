import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../supabase/guardados_service.dart';
import '../contenido/page_contenido.dart';
import '../player/player_page.dart'; // Player Windows (media_kit)

const _kAccent = Color(0xFFE50914);
const _kCardBg = Color(0xFF1a1a2e);

class GuardadoPage extends StatefulWidget {
  const GuardadoPage({super.key});

  @override
  State<GuardadoPage> createState() => _GuardadoPageState();
}

class _GuardadoPageState extends State<GuardadoPage> {
  List<Map<String, dynamic>> _historial = [];
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final historial = await _loadHistorial();
      final list = await GuardadosService.getAll();
      if (!mounted) return;
      setState(() {
        _historial = historial;
        _items = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historial = [];
        _items = [];
        _loading = false;
      });
    }
  }

  /// Misma clave que el player PC/móvil: cachePlayer_*
  Future<List<Map<String, dynamic>>> _loadHistorial() async {
    final prefs = await SharedPreferences.getInstance();
    final keys =
        prefs.getKeys().where((k) => k.startsWith('cachePlayer_')).toList();

    final result = <Map<String, dynamic>>[];
    for (final key in keys) {
      // Saltar las claves "Rapido" para no duplicar
      if (key.contains('Rapido')) continue;
      try {
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final segundo = data['segundo'];
        final sec = segundo is int
            ? segundo
            : (segundo is num ? segundo.toInt() : 0);
        if (sec < 8) continue;
        result.add(data);
      } catch (_) {}
    }

    result.sort((a, b) {
      final ta = a['timestamp']?.toString() ?? '';
      final tb = b['timestamp']?.toString() ?? '';
      return tb.compareTo(ta);
    });

    // Deduplicar por id + temporada + capítulo (quedarse el más reciente)
    final seen = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final item in result) {
      final id = item['idcontenido']?.toString() ?? '';
      final t = item['temporada']?.toString() ?? '0';
      final c = item['capitulo']?.toString() ?? '0';
      final k = '$id-$t-$c';
      if (seen.contains(k)) continue;
      seen.add(k);
      unique.add(item);
    }
    return unique;
  }

  // ── Continuar viendo → Player PC ─────────────────────────────────────────
  void _openHistorial(Map<String, dynamic> item) {
    final id = int.tryParse('${item['idcontenido'] ?? 0}') ?? 0;
    if (id <= 0) return;

    final temporada = item['temporada'] is int
        ? item['temporada'] as int
        : int.tryParse('${item['temporada'] ?? ''}');
    final capitulo = item['capitulo'] is int
        ? item['capitulo'] as int
        : int.tryParse('${item['capitulo'] ?? ''}');
    final tipo = (item['tipo'] ?? 'movie').toString().toLowerCase();
    final titulo = item['titulo']?.toString() ?? '';
    final videoUrl = item['videoUrl']?.toString() ?? '';
    final backdrop = item['backdrop']?.toString();

    // Si hay URL guardada → player directo; si no → ficha de contenido
    if (videoUrl.isNotEmpty) {
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => PlayerPage(
                videoUrl: videoUrl,
                idcontenido: id,
                tmdbId: id,
                temporada: temporada,
                capitulo: capitulo,
                tipo: tipo,
                titulo: titulo,
                backdropUrl: (backdrop != null && backdrop.isNotEmpty)
                    ? backdrop
                    : null,
              ),
            ),
          )
          .then((_) => _load());
    } else {
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => PageContenido(
                idcontenido: id,
                tmdbId: id,
                mediaType: tipo == 'tv' || tipo == 'serie' ? 'tv' : 'movie',
              ),
            ),
          )
          .then((_) => _load());
    }
  }

  // ── Mi lista → ficha ─────────────────────────────────────────────────────
  void _open(Map<String, dynamic> item) {
    final rawTmdb = item['tmdb_id'] ?? item['tmdbId'];
    final rawId = item['idcontenido'] ?? item['id'];

    int? parsed;
    if (rawTmdb != null) {
      parsed = int.tryParse(rawTmdb.toString());
    }
    parsed ??= int.tryParse((rawId ?? '').toString());

    if (parsed == null || parsed == 0) return;
    final tmdbId = parsed;

    final rawType =
        (item['media_type'] ?? item['type'] ?? item['tipo'] ?? 'movie')
            .toString()
            .toLowerCase();

    final mediaType =
        (rawType == 'tv' || rawType == 'serie' || rawType == 'series')
            ? 'tv'
            : 'movie';

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => PageContenido(
              idcontenido: tmdbId,
              tmdbId: tmdbId,
              mediaType: mediaType,
            ),
          ),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Row(
            children: [
              const Text(
                'Guardados',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: _load,
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh, color: Colors.white54),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: _kAccent),
                )
              : CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    // ── Continuar viendo (slider horizontal) ──────────────
                    if (_historial.isNotEmpty) ...[
                      const SliverToBoxAdapter(
                        child: _SectionHeader(
                          title: 'Continuar viendo',
                          icon: Icons.history_rounded,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 160,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                            itemCount: _historial.length,
                            itemBuilder: (context, index) {
                              final item = _historial[index];
                              final image =
                                  (item['backdrop']?.toString().isNotEmpty ==
                                          true)
                                      ? item['backdrop'].toString()
                                      : (item['poster']?.toString() ?? '');
                              return _HistorialBanner(
                                title: item['titulo']?.toString() ??
                                    'Sin título',
                                image: image,
                                tipo: item['tipo']?.toString() ?? 'movie',
                                temporada: item['temporada'],
                                capitulo: item['capitulo'],
                                segundo: item['segundo'] is int
                                    ? item['segundo'] as int
                                    : int.tryParse(
                                            '${item['segundo'] ?? 0}') ??
                                        0,
                                onTap: () => _openHistorial(item),
                              );
                            },
                          ),
                        ),
                      ),
                    ],

                    // ── Mi lista ──────────────────────────────────────────
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        title: 'Mi lista',
                        icon: Icons.bookmark_rounded,
                        count: _items.length,
                      ),
                    ),

                    if (_items.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(
                            child: Column(
                              children: [
                                Icon(
                                  Icons.bookmark_border_rounded,
                                  size: 52,
                                  color: Colors.white24,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'No hay contenido guardado',
                                  style: TextStyle(
                                    color: Colors.white38,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 160,
                            childAspectRatio: 0.55,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final item = _items[i];
                              final title = (item['titulo'] ??
                                      item['title'] ??
                                      item['name'] ??
                                      '')
                                  .toString();
                              final path = item['poster'] ??
                                  item['poster_path'] ??
                                  item['imagen'];
                              String? url;
                              if (path != null) {
                                final s = path.toString();
                                url = s.startsWith('http')
                                    ? s
                                    : 'https://image.tmdb.org/t/p/w342$s';
                              }
                              return _PosterTile(
                                title: title,
                                imageUrl: url,
                                onTap: () => _open(item),
                              );
                            },
                            childCount: _items.length,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

// ─── Header de sección ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final int? count;

  const _SectionHeader({
    required this.title,
    required this.icon,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 10),
      child: Row(
        children: [
          Icon(icon, color: _kAccent, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (count != null && count! > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Banner Continuar viendo ────────────────────────────────────────────────

class _HistorialBanner extends StatelessWidget {
  final String title;
  final String image;
  final String tipo;
  final dynamic temporada;
  final dynamic capitulo;
  final int segundo;
  final VoidCallback onTap;

  const _HistorialBanner({
    required this.title,
    required this.image,
    required this.tipo,
    this.temporada,
    this.capitulo,
    required this.segundo,
    required this.onTap,
  });

  String get _timeLabel {
    final m = segundo ~/ 60;
    final s = segundo % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get _meta {
    if ((tipo == 'tv' || tipo == 'serie') &&
        temporada != null &&
        capitulo != null) {
      return 'T${temporada.toString().padLeft(2, '0')} · E${capitulo.toString().padLeft(2, '0')}';
    }
    return (tipo == 'tv' || tipo == 'serie') ? 'Serie' : 'Película';
  }

  String get _imageUrl {
    if (image.isEmpty) return '';
    if (image.startsWith('http')) return image;
    return 'https://image.tmdb.org/t/p/w780$image';
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 280,
          margin: const EdgeInsets.only(right: 14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _imageUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: _imageUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            const ColoredBox(color: Color(0xFF1a1a1a)),
                        errorWidget: (_, __, ___) => const ColoredBox(
                          color: Color(0xFF1a1a1a),
                          child: Icon(Icons.movie,
                              color: Colors.white24, size: 36),
                        ),
                      )
                    : const ColoredBox(
                        color: Color(0xFF1a1a1a),
                        child: Icon(Icons.movie,
                            color: Colors.white24, size: 36),
                      ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 32, 12, 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.92),
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _meta,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Barra de progreso
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: 3,
                    color: Colors.white.withValues(alpha: 0.2),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (segundo / 4200).clamp(0.06, 1.0),
                      child: const ColoredBox(color: _kAccent),
                    ),
                  ),
                ),
                // Tiempo visto
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _timeLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                // Play overlay sutil
                const Center(
                  child: Icon(
                    Icons.play_circle_outline_rounded,
                    color: Colors.white54,
                    size: 42,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Poster Mi lista ────────────────────────────────────────────────────────

class _PosterTile extends StatelessWidget {
  final String title;
  final String? imageUrl;
  final VoidCallback onTap;

  const _PosterTile({
    required this.title,
    required this.imageUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: imageUrl != null
                    ? CachedNetworkImage(
                        imageUrl: imageUrl!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        placeholder: (_, __) =>
                            const ColoredBox(color: _kCardBg),
                        errorWidget: (_, __, ___) => const ColoredBox(
                          color: _kCardBg,
                          child: Icon(Icons.movie,
                              color: Colors.white24, size: 28),
                        ),
                      )
                    : const ColoredBox(color: _kCardBg),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}