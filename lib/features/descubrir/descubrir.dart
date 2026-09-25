import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/tmdb_apis.dart';
import '../contenido/page_contenido.dart';

class DescubrirPage extends StatefulWidget {
  const DescubrirPage({super.key});

  @override
  State<DescubrirPage> createState() => _DescubrirPageState();
}

class _DescubrirPageState extends State<DescubrirPage> {
  String _type = 'movie';
  int? _genreId;
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  int _page = 1;
  bool _hasMore = true;

  static const _movieGenres = [
    (28, 'Acción'),
    (12, 'Aventura'),
    (16, 'Animación'),
    (35, 'Comedia'),
    (80, 'Crimen'),
    (18, 'Drama'),
    (14, 'Fantasía'),
    (27, 'Terror'),
    (10749, 'Romance'),
    (878, 'Sci-Fi'),
  ];

  static const _tvGenres = [
    (10759, 'Acción'),
    (16, 'Animación'),
    (35, 'Comedia'),
    (80, 'Crimen'),
    (18, 'Drama'),
    (10765, 'Sci-Fi'),
    (9648, 'Misterio'),
  ];

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _page = 1;
      _hasMore = true;
      setState(() {
        _loading = true;
        _items = [];
      });
    }
    try {
      final key = await TmdbApis.getApiKey();
      final lang = await TmdbApis.getLanguage();
      final path = _type == 'movie' ? '/discover/movie' : '/discover/tv';
      final q = <String, String>{
        'api_key': key,
        'language': lang,
        'sort_by': 'popularity.desc',
        'page': '$_page',
        'include_adult': 'false',
      };
      if (_genreId != null) q['with_genres'] = '$_genreId';
      final uri =
          Uri.parse('https://api.themoviedb.org/3$path').replace(queryParameters: q);
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (body['results'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final totalPages = body['total_pages'] as int? ?? 1;
      if (!mounted) return;
      setState(() {
        _items = reset ? list : [..._items, ...list];
        _hasMore = _page < totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _open(Map<String, dynamic> item) {
    final id = item['id'];
    if (id == null) return;
    final tmdbId = int.tryParse(id.toString()) ?? 0;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PageContenido(
          idcontenido: tmdbId,
          tmdbId: tmdbId,
          mediaType: _type,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final genres = _type == 'movie' ? _movieGenres : _tvGenres;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Text(
            'Descubrir',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Películas'),
                selected: _type == 'movie',
                selectedColor: const Color(0xFFE50914),
                onSelected: (_) {
                  setState(() {
                    _type = 'movie';
                    _genreId = null;
                  });
                  _load(reset: true);
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Series'),
                selected: _type == 'tv',
                selectedColor: const Color(0xFFE50914),
                onSelected: (_) {
                  setState(() {
                    _type = 'tv';
                    _genreId = null;
                  });
                  _load(reset: true);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            children: [
              FilterChip(
                label: const Text('Todos'),
                selected: _genreId == null,
                selectedColor: const Color(0xFFE50914),
                onSelected: (_) {
                  setState(() => _genreId = null);
                  _load(reset: true);
                },
              ),
              const SizedBox(width: 8),
              for (final g in genres) ...[
                FilterChip(
                  label: Text(g.$2),
                  selected: _genreId == g.$1,
                  selectedColor: const Color(0xFFE50914),
                  onSelected: (_) {
                    setState(() => _genreId = g.$1);
                    _load(reset: true);
                  },
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _loading && _items.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFE50914)),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.pixels >=
                            n.metrics.maxScrollExtent - 200 &&
                        _hasMore &&
                        !_loading) {
                      _page++;
                      _load();
                    }
                    return false;
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      childAspectRatio: 0.55,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final item = _items[i];
                      final title =
                          (item['title'] ?? item['name'] ?? '').toString();
                      final path = item['poster_path'];
                      final url = path != null
                          ? 'https://image.tmdb.org/t/p/w342$path'
                          : null;
                      return GestureDetector(
                        onTap: () => _open(item),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: url != null
                                    ? CachedNetworkImage(
                                        imageUrl: url,
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                      )
                                    : Container(
                                        color: const Color(0xFF1C1C24)),
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
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}