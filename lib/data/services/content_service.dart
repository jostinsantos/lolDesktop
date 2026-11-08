import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/repo_manifest.dart';
import '../models/stream_server.dart';
import 'content_cache.dart';
import 'js_runtime.dart';

/// Contenido de un repo vía JS (getHome, getDiscover, search, getMeta, getStreams).
/// El repo decide cómo presentar; la app solo renderiza y reproduce.
///
/// Caché: home y news se guardan 24h. Solo se vuelve a pedir al JS con
/// [forceRefresh] (pull-to-refresh) o cuando el TTL expira.
class ContentService {
  ContentService._();
  static final ContentService instance = ContentService._();

  final _js = JsAddonRuntime.instance;
  final _cache = ContentCache.instance;

  Future<void> _ensureJs(InstalledRepo repo) async {
    final code = repo.jsCode;
    if (code == null || code.trim().isEmpty) return;
    await _js.loadAddonCode(repo.manifest.id, code);
    if (repo.userConfig.isNotEmpty) {
      await _js.setConfig(repo.manifest.id, repo.userConfig);
    }
  }

  /// Novedades del repo (solo para el launcher).
  Future<List<Map<String, dynamic>>> getNews(
    InstalledRepo repo, {
    bool forceRefresh = false,
  }) async {
    final id = repo.manifest.id;
    if (!forceRefresh) {
      final hit = _cache.get(id, 'getNews');
      if (hit is List) {
        return hit
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final data = await _js.callMethod(
          addonId: id,
          method: 'getNews',
          timeout: const Duration(seconds: 25),
        );
        List<Map<String, dynamic>> items = const [];
        if (data is List) {
          items = data
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        } else if (data is Map && data['items'] is List) {
          items = (data['items'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        } else if (data is Map && data['news'] is List) {
          items = (data['news'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
        if (items.isNotEmpty) {
          await _cache.set(id, 'getNews', items);
        }
        return items;
      }
    } catch (e) {
      debugPrint('[Content] getNews: $e');
    }
    return const [];
  }

  // ─── Home ───────────────────────────────────────────────────────────────
  Future<List<HomeRow>> getHome(
    InstalledRepo repo, {
    bool forceRefresh = false,
  }) async {
    final id = repo.manifest.id;
    if (!forceRefresh) {
      final hit = _cache.get(id, 'getHome');
      if (hit is List) {
        try {
          final rows = hit
              .whereType<Map>()
              .map((e) => HomeRow.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (rows.isNotEmpty) return rows;
        } catch (e) {
          debugPrint('[Content] getHome cache parse: $e');
        }
      }
    }
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final data = await _js.callMethod(
          addonId: id,
          method: 'getHome',
          timeout: const Duration(seconds: 45),
        );
        final rows = _parseHomeRows(data);
        if (rows.isNotEmpty) {
          // Guardar como JSON serializable
          await _cache.set(
            id,
            'getHome',
            rows.map((r) => r.toJson()).toList(),
          );
          return rows;
        }
      }
    } catch (e) {
      debugPrint('[Content] getHome: $e');
    }
    return const [];
  }

  /// Estructura del home para carga progresiva real a la API.
  ///
  /// Estrategia (compatible con repos antiguos):
  /// 1. Intenta `getHome({ structureOnly: true })` / `lightweight` → filas sin items
  ///    o con pocos items + catalogId.
  /// 2. Si no, intenta `getCatalogs` como lista de filas.
  /// 3. Fallback: `getHome()` completo (legado). En ese caso [HomeProgressiveResult.legacy]
  ///    es true y las filas ya traen items; la UI puede revelarlos uno a uno sin más API.
  Future<HomeProgressiveResult> getHomeProgressive(
    InstalledRepo repo, {
    bool forceRefresh = false,
  }) async {
    final id = repo.manifest.id;

    // Caché de estructura progresiva
    if (!forceRefresh) {
      final hit = _cache.get(id, 'getHomeProgressive');
      if (hit is Map) {
        try {
          final legacy = hit['legacy'] == true;
          final rows = (hit['rows'] as List? ?? [])
              .whereType<Map>()
              .map((e) => HomeRow.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (rows.isNotEmpty) {
            return HomeProgressiveResult(rows: rows, legacy: legacy);
          }
        } catch (e) {
          debugPrint('[Content] getHomeProgressive cache: $e');
        }
      }
    }

    await _ensureJs(repo);
    if (repo.jsCode == null || repo.jsCode!.trim().isEmpty) {
      return const HomeProgressiveResult(rows: [], legacy: true);
    }

    // 1) Intentos de estructura ligera (addons nuevos)
    for (final args in [
      [
        {'structureOnly': true, 'lightweight': true, 'page': 1}
      ],
      [
        {'structureOnly': true}
      ],
      [
        {'lightweight': true}
      ],
    ]) {
      try {
        final data = await _js.callMethod(
          addonId: id,
          method: 'getHome',
          args: args,
          timeout: const Duration(seconds: 20),
        );
        final rows = _parseHomeRows(data);
        if (rows.isEmpty) continue;
        // Consideramos "progresivo" si la mayoría de filas tienen pocos items
        // o traen catalogId (el contenido se pide fila a fila).
        final needFetch = rows.where((r) {
          final cid = r.catalogId;
          return (cid != null && cid.isNotEmpty) || r.items.length <= 2;
        }).length;
        final progressive = needFetch >= (rows.length / 2).ceil() ||
            rows.every((r) => r.items.isEmpty);
        if (progressive || rows.any((r) => (r.catalogId ?? '').isNotEmpty)) {
          await _cache.set(id, 'getHomeProgressive', {
            'legacy': false,
            'rows': rows.map((r) => r.toJson()).toList(),
          });
          return HomeProgressiveResult(rows: rows, legacy: false);
        }
        // Si ya viene todo lleno, es legado usable
        if (rows.any((r) => r.items.isNotEmpty)) {
          await _cache.set(id, 'getHome', rows.map((r) => r.toJson()).toList());
          await _cache.set(id, 'getHomeProgressive', {
            'legacy': true,
            'rows': rows.map((r) => r.toJson()).toList(),
          });
          return HomeProgressiveResult(rows: rows, legacy: true);
        }
      } catch (e) {
        debugPrint('[Content] getHome structure: $e');
      }
    }

    // 2) getCatalogs como esqueleto de filas
    try {
      final catalogs = await getCatalogs(repo);
      if (catalogs.isNotEmpty) {
        final rows = catalogs
            .map((c) => HomeRow(
                  id: c.id,
                  title: c.title,
                  type: HomeRowType.row,
                  items: const [],
                  catalogId: c.id,
                  imageStyle: 'poster',
                ))
            .toList();
        await _cache.set(id, 'getHomeProgressive', {
          'legacy': false,
          'rows': rows.map((r) => r.toJson()).toList(),
        });
        return HomeProgressiveResult(rows: rows, legacy: false);
      }
    } catch (e) {
      debugPrint('[Content] getHomeProgressive catalogs: $e');
    }

    // 3) Fallback legado: getHome completo
    final full = await getHome(repo, forceRefresh: forceRefresh);
    await _cache.set(id, 'getHomeProgressive', {
      'legacy': true,
      'rows': full.map((r) => r.toJson()).toList(),
    });
    return HomeProgressiveResult(rows: full, legacy: true);
  }

  /// Carga el contenido de una fila del home (petición real a la API).
  ///
  /// Orden de intentos:
  /// 1. `getCatalog(catalogId, {page})` si hay catalogId
  /// 2. `getHome({ rowId / catalogId / id, page })` sección
  /// 3. Si [fallbackItems] no está vacío (modo legado), devuelve esa página local
  Future<DiscoverPage> loadHomeRow(
    InstalledRepo repo, {
    required String rowId,
    String? catalogId,
    int page = 1,
    List<ContentItem> fallbackItems = const [],
  }) async {
    final id = repo.manifest.id;
    final cacheKey = 'homeRow:${catalogId ?? rowId}:$page';

    final hit = _cache.get(id, cacheKey);
    if (hit is Map) {
      try {
        final items = _parseItems(hit['items']);
        final hasMore = hit['hasMore'] == true;
        if (items.isNotEmpty || hit.containsKey('items')) {
          return DiscoverPage(items: items, hasMore: hasMore, page: page);
        }
      } catch (_) {}
    }

    await _ensureJs(repo);
    if (repo.jsCode == null || repo.jsCode!.trim().isEmpty) {
      return _pageFromList(fallbackItems, page);
    }

    // 1) getCatalog
    final cat = (catalogId != null && catalogId.isNotEmpty) ? catalogId : rowId;
    if (cat.isNotEmpty) {
      try {
        final pageResult = await getCatalogItems(repo, cat, page: page);
        if (pageResult.items.isNotEmpty || page == 1) {
          await _cache.set(id, cacheKey, {
            'items': pageResult.items.map((e) => e.toJson()).toList(),
            'hasMore': pageResult.hasMore,
          });
          if (pageResult.items.isNotEmpty || pageResult.hasMore || page > 1) {
            return pageResult;
          }
        }
      } catch (e) {
        debugPrint('[Content] loadHomeRow getCatalog: $e');
      }
    }

    // 2) getHome sección / fila
    for (final args in [
      [
        {'rowId': rowId, 'id': rowId, 'catalogId': cat, 'page': page}
      ],
      [
        {'catalogId': cat, 'page': page}
      ],
      [
        rowId,
        {'page': page}
      ],
    ]) {
      try {
        final data = await _js.callMethod(
          addonId: id,
          method: 'getHome',
          args: args,
          timeout: const Duration(seconds: 25),
        );
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          if (map['items'] != null || map['metas'] != null) {
            final pageResult = _parseDiscoverPage(map, page);
            if (pageResult.items.isNotEmpty) {
              await _cache.set(id, cacheKey, {
                'items': pageResult.items.map((e) => e.toJson()).toList(),
                'hasMore': pageResult.hasMore,
              });
              return pageResult;
            }
          }
          final rows = _parseHomeRows(data);
          final match = rows.cast<HomeRow?>().firstWhere(
                (r) =>
                    r != null &&
                    (r.id == rowId ||
                        r.catalogId == cat ||
                        r.id == cat ||
                        r.title.toLowerCase() == rowId.toLowerCase()),
                orElse: () => rows.isNotEmpty ? rows.first : null,
              );
          if (match != null && match.items.isNotEmpty) {
            final pageResult = _pageFromList(match.items, page);
            await _cache.set(id, cacheKey, {
              'items': pageResult.items.map((e) => e.toJson()).toList(),
              'hasMore': pageResult.hasMore,
            });
            return pageResult;
          }
        } else if (data is List) {
          final asRows = _parseHomeRows(data);
          if (asRows.isNotEmpty) {
            final match = asRows.firstWhere(
              (r) => r.id == rowId || r.catalogId == cat,
              orElse: () => asRows.first,
            );
            if (match.items.isNotEmpty) {
              final pageResult = _pageFromList(match.items, page);
              await _cache.set(id, cacheKey, {
                'items': pageResult.items.map((e) => e.toJson()).toList(),
                'hasMore': pageResult.hasMore,
              });
              return pageResult;
            }
          }
          final items = _parseItems(data);
          if (items.isNotEmpty) {
            final pageResult = DiscoverPage(
              items: items,
              hasMore: items.length >= 20,
              page: page,
            );
            await _cache.set(id, cacheKey, {
              'items': items.map((e) => e.toJson()).toList(),
              'hasMore': pageResult.hasMore,
            });
            return pageResult;
          }
        }
      } catch (e) {
        debugPrint('[Content] loadHomeRow getHome section: $e');
      }
    }

    // 3) Fallback local (legado): paginar items ya traídos en getHome
    return _pageFromList(fallbackItems, page);
  }

  DiscoverPage _pageFromList(List<ContentItem> all, int page, {int pageSize = 20}) {
    if (all.isEmpty) return DiscoverPage.empty;
    final start = (page - 1) * pageSize;
    if (start >= all.length) {
      return DiscoverPage(items: const [], hasMore: false, page: page);
    }
    final end = (start + pageSize).clamp(0, all.length);
    return DiscoverPage(
      items: all.sublist(start, end),
      hasMore: end < all.length,
      page: page,
    );
  }

  /// Categorías live + carga paginada de canales (API real cuando sea posible).
  ///
  /// Devuelve filas de categorías. Si [legacy] es true, los items ya vienen
  /// completos y [loadLiveCategory] paginará en memoria. Si no, hay que llamar
  /// [loadLiveCategory] para pedir cada página a la API.
  Future<HomeProgressiveResult> getLiveCategories(
    InstalledRepo repo, {
    bool forceRefresh = false,
  }) async {
    final result = await getHomeProgressive(repo, forceRefresh: forceRefresh);
    final channelRows = result.rows.where((r) {
      if (r.items.isEmpty && (r.catalogId ?? '').isNotEmpty) return true;
      if (r.items.isEmpty) {
        final t = r.title.toLowerCase();
        return t.contains('canal') ||
            t.contains('tv') ||
            t.contains('live') ||
            t.contains('vivo') ||
            t.contains('iptv');
      }
      final hasChannel = r.items.any((i) => i.isChannel);
      final t = r.title.toLowerCase();
      return hasChannel ||
          t.contains('canal') ||
          t.contains('tv') ||
          t.contains('live') ||
          t.contains('vivo') ||
          t.contains('iptv');
    }).toList();

    final use = channelRows.isNotEmpty ? channelRows : result.rows;
    return HomeProgressiveResult(rows: use, legacy: result.legacy);
  }

  /// Página de canales de una categoría live (API o fallback local).
  Future<DiscoverPage> loadLiveCategory(
    InstalledRepo repo, {
    required String categoryId,
    String? catalogId,
    int page = 1,
    List<ContentItem> fallbackItems = const [],
  }) {
    return loadHomeRow(
      repo,
      rowId: categoryId,
      catalogId: catalogId,
      page: page,
      fallbackItems: fallbackItems,
    );
  }

  // ─── Discover + filtros ─────────────────────────────────────────────────
  /// Filtros que el repo expone (género, año, tipo...).
  Future<List<Map<String, dynamic>>> getDiscoverFilters(InstalledRepo repo, {Map<String, dynamic>? filters}) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'getDiscoverFilters',
          args: filters != null ? [filters] : const [],
        );
        if (data is List) {
          return data.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        }
        if (data is Map && data['filters'] is List) {
          return (data['filters'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    } catch (e) {
      debugPrint('[Content] getDiscoverFilters: $e');
    }
    // Sin filtros demo: lista vacía si el repo no define
    return const [];
  }

  /// Descubrir con paginación.
  /// [filters] = valores elegidos { filterId: optionId }
  /// Respuesta del repo: lista o { items, hasMore }
  Future<DiscoverPage> getDiscover(
    InstalledRepo repo, {
    String? filterId,
    Map<String, dynamic>? filters,
    int page = 1,
  }) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final opts = <String, dynamic>{
          'page': page,
          ...?filters,
        };
        if (filterId != null) {
          opts.putIfAbsent('filter', () => filterId);
          opts.putIfAbsent('genre', () => filterId);
        }
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'getDiscover',
          args: [opts],
        );
        return _parseDiscoverPage(data, page);
      }
    } catch (e) {
      debugPrint('[Content] getDiscover: $e');
    }
    return DiscoverPage.empty;
  }

  DiscoverPage _parseDiscoverPage(dynamic data, int page) {
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final items = _parseItems(map['items'] ?? map['results'] ?? map['data'] ?? data);
      final hasMore = map['hasMore'] == true ||
          map['has_more'] == true ||
          (map['page'] != null && map['totalPages'] != null &&
              (map['page'] as num).toInt() < (map['totalPages'] as num).toInt()) ||
          items.length >= 20;
      return DiscoverPage(items: items, hasMore: hasMore, page: page);
    }
    final items = _parseItems(data);
    return DiscoverPage(items: items, hasMore: items.length >= 20, page: page);
  }

  // ─── Search ─────────────────────────────────────────────────────────────
  Future<List<ContentItem>> search(InstalledRepo repo, String query) async {
    if (query.trim().isEmpty) return [];
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'search',
          args: [query],
        );
        final items = _parseItems(data);
        if (items.isNotEmpty) return items;
      }
    } catch (e) {
      debugPrint('[Content] search: $e');
    }
    return const [];
  }

  Future<List<({InstalledRepo repo, ContentItem item})>> searchAll(
    List<InstalledRepo> repos,
    String query,
  ) async {
    if (query.trim().isEmpty) return [];
    final results = <({InstalledRepo repo, ContentItem item})>[];
    // Búsqueda en paralelo; cada repo aporta sus resultados
    await Future.wait(repos.map((repo) async {
      try {
        final items = await search(repo, query);
        for (final item in items) {
          results.add((repo: repo, item: item));
        }
      } catch (e) {
        debugPrint('[Content] searchAll ${repo.manifest.id}: $e');
      }
    }));
    return results;
  }

  /// Busca el mismo título/episodio en otros repos usando tmdbId / imdbId.
  Future<List<({InstalledRepo repo, ContentItem item})>> searchByExternalId({
    required List<InstalledRepo> repos,
    String? tmdbId,
    String? imdbId,
    String? titleFallback,
    String? excludeRepoId,
  }) async {
    final results = <({InstalledRepo repo, ContentItem item})>[];
    final targets = repos
        .where((r) => excludeRepoId == null || r.manifest.id != excludeRepoId)
        .toList();
    if (targets.isEmpty) return results;

    final queries = <String>[];
    if (tmdbId != null && tmdbId.isNotEmpty) {
      queries.add('tmdb:$tmdbId');
      queries.add(tmdbId);
    }
    if (imdbId != null && imdbId.isNotEmpty) {
      queries.add('imdb:$imdbId');
      queries.add(imdbId);
    }
    if (titleFallback != null && titleFallback.trim().isNotEmpty) {
      queries.add(titleFallback.trim());
    }
    if (queries.isEmpty) return results;

    await Future.wait(targets.map((repo) async {
      for (final q in queries) {
        try {
          final items = await search(repo, q);
          for (final item in items) {
            final matchTmdb = tmdbId != null &&
                tmdbId.isNotEmpty &&
                (item.tmdbId == tmdbId ||
                    item.id == tmdbId ||
                    item.id.contains(tmdbId));
            final matchImdb = imdbId != null &&
                imdbId.isNotEmpty &&
                (item.imdbId == imdbId ||
                    item.id == imdbId ||
                    item.id.contains(imdbId));
            final matchTitle = titleFallback != null &&
                item.title.toLowerCase().contains(titleFallback.toLowerCase());
            if (matchTmdb || matchImdb || matchTitle) {
              results.add((repo: repo, item: item));
              return;
            }
          }
        } catch (_) {}
      }
    }));
    return results;
  }

  // ─── Meta / detalles (movie o series con temporadas) ────────────────────
  Future<ContentItem?> getDetails(
    InstalledRepo repo,
    String id, {
    int? season,
    int? episode,
  }) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final args = <dynamic>[id];
        if (season != null || episode != null) {
          args.add({
            if (season != null) 'season': season,
            if (episode != null) 'episode': episode,
          });
        }
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'getMeta',
          args: args,
        );
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          // Algunos repos envuelven en { item: {...} }
          if (map['item'] is Map) {
            return ContentItem.fromJson(Map<String, dynamic>.from(map['item'] as Map));
          }
          return ContentItem.fromJson(map);
        }
      }
    } catch (e) {
      debugPrint('[Content] getMeta: $e');
    }
    return null;
  }

  // ─── Streams / servidores ───────────────────────────────────────────────
  /// El repo devuelve lista de servidores con url, headers, idioma, calidad...
  /// Args típicos: id, type, season?, episode?
  Future<List<StreamServer>> getStreams(
    InstalledRepo repo,
    String id, {
    String? type,
    int? season,
    int? episode,
  }) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        // Compat: getStreams(id) o getStreams(id, type, season, episode) o getStreams({...})
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'getStreams',
          args: [
            id,
            type ?? 'movie',
            season,
            episode,
          ],
        );
        final list = _parseStreams(data);
        if (list.isNotEmpty) return list;
      }
    } catch (e) {
      debugPrint('[Content] getStreams: $e');
    }
    // Sin demos: lista vacía si el repo no devolvió servidores
    return const [];
  }



  // ─── Anuncios / avisos del repo (opcional) ───────────────────────────────
  /// Solo si el desarrollador implementa getAds / getAnnouncements o
  /// declara ads en lol.json / respuesta de getHome.
  Future<List<Map<String, dynamic>>> getAds(InstalledRepo repo) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        for (final method in ['getAds', 'getAnnouncements', 'getNotices']) {
          try {
            final data = await _js.callMethod(
              addonId: repo.manifest.id,
              method: method,
              args: const [],
            );
            final list = _parseAds(data);
            if (list.isNotEmpty) return list;
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[Content] getAds: $e');
    }
    // lol.json: ads / announcements
    final raw = repo.manifest.raw;
    final declared = raw['ads'] ?? raw['announcements'] ?? raw['notices'];
    return _parseAds(declared);
  }

  List<Map<String, dynamic>> _parseAds(dynamic data) {
    if (data == null) return const [];
    List? list;
    if (data is List) {
      list = data;
    } else if (data is Map) {
      final m = Map<String, dynamic>.from(data);
      // { enabled: false } → nada
      if (m['enabled'] == false) return const [];
      list = m['items'] as List? ??
          m['ads'] as List? ??
          m['announcements'] as List? ??
          m['notices'] as List?;
      // un solo anuncio plano
      if (list == null && (m['title'] != null || m['image'] != null || m['message'] != null)) {
        return [m];
      }
    }
    if (list == null) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) =>
            (e['title'] ?? e['message'] ?? e['image'] ?? e['imageUrl'] ?? e['url']) !=
            null)
        .toList();
  }

  // ─── Catálogos ──────────────────────────────────────────────────────────
  Future<List<CatalogInfo>> getCatalogs(InstalledRepo repo) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'getCatalogs',
        );
        List? list;
        if (data is Map) list = data['catalogs'] as List? ?? data['items'] as List?;
        if (data is List) list = data;
        if (list != null) {
          return list
              .whereType<Map>()
              .map((e) => CatalogInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      }
    } catch (e) {
      debugPrint('[Content] getCatalogs: $e');
    }
    return const [];
  }

  Future<DiscoverPage> getCatalogItems(InstalledRepo repo, String catalogId, {int page = 1}) async {
    try {
      await _ensureJs(repo);
      if (repo.jsCode != null && repo.jsCode!.trim().isNotEmpty) {
        final data = await _js.callMethod(
          addonId: repo.manifest.id,
          method: 'getCatalog',
          args: [catalogId, {'page': page}],
        );
        return _parseDiscoverPage(data, page);
      }
    } catch (e) {
      debugPrint('[Content] getCatalogItems: $e');
    }
    return DiscoverPage.empty;
  }

  // ─── parsers ────────────────────────────────────────────────────────────

  List<HomeRow> _parseHomeRows(dynamic data) {
    if (data == null) return [];
    List? list;
    if (data is Map) {
      list = data['rows'] as List? ?? data['catalogs'] as List?;
    } else if (data is List) {
      list = data;
    }
    if (list == null) return [];
    return list
        .whereType<Map>()
        .map((e) => HomeRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  List<ContentItem> _parseItems(dynamic data) {
    if (data == null) return [];
    List? list;
    if (data is Map) {
      list = data['items'] as List? ??
          data['metas'] as List? ??
          data['results'] as List?;
    } else if (data is List) {
      list = data;
    }
    if (list == null) return [];
    return list
        .whereType<Map>()
        .map((e) => ContentItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  List<StreamServer> _parseStreams(dynamic data) {
    if (data == null) return [];
    List? list;
    if (data is Map) {
      list = data['streams'] as List? ??
          data['sources'] as List? ??
          data['servers'] as List? ??
          data['servidores'] as List?;
    } else if (data is List) {
      list = data;
    }
    if (list == null) return [];
    return list
        .whereType<Map>()
        .map((e) => StreamServer.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.url.isNotEmpty)
        .toList();
  }

  // ─── demo ───────────────────────────────────────────────────────────────

  ContentItem _demoSeries(ContentItem base) {
    final seasons = List.generate(2, (si) {
      final sn = si + 1;
      return SeasonInfo(
        number: sn,
        name: 'Temporada $sn',
        episodes: List.generate(5, (ei) {
          final en = ei + 1;
          return EpisodeInfo(
            number: en,
            id: '${base.id}_s${sn}e$en',
            title: 'Episodio $en',
            overview: 'Episodio demo $en de la temporada $sn',
            still: base.backdrop ?? base.poster,
          );
        }),
      );
    });
    return ContentItem(
      id: base.id,
      title: base.title,
      poster: base.poster,
      backdrop: base.backdrop,
      overview: base.overview,
      type: 'series',
      rating: base.rating,
      year: base.year,
      genres: const ['Drama', 'Acción'],
      seasons: seasons,
      extra: base.extra,
    );
  }

  List<HomeRow> _demoHome(InstalledRepo repo) {
    final items = _demoItems(repo, count: 8);
    return [
      HomeRow(
        id: 'hero',
        title: 'Destacados',
        type: HomeRowType.hero,
        items: items.take(5).toList(),
        imageStyle: 'backdrop',
      ),
      HomeRow(
        id: 'banner_promo',
        title: 'Promo',
        type: HomeRowType.banner,
        items: const [],
        bannerImage: items.isNotEmpty ? items.first.backdrop ?? items.first.poster : null,
      ),
      HomeRow(
        id: 'trending',
        title: 'Tendencias',
        type: HomeRowType.row,
        items: _demoItems(repo, count: 10, offset: 2),
        imageStyle: 'poster',
      ),
      HomeRow(
        id: 'catalogs',
        title: 'Catálogos',
        type: HomeRowType.catalog,
        items: [
          ContentItem(id: 'cat_1', title: 'Top 10', type: 'catalog', poster: items[0].poster),
          ContentItem(id: 'cat_2', title: 'Estrenos', type: 'catalog', poster: items[1].poster),
          ContentItem(id: 'cat_3', title: 'Clásicos', type: 'catalog', poster: items[2].poster),
        ],
        imageStyle: 'poster',
      ),
      HomeRow(
        id: 'backdrop_row',
        title: 'Destacados wide',
        type: HomeRowType.row,
        items: _demoItems(repo, count: 6, offset: 4),
        imageStyle: 'backdrop',
      ),
    ];
  }

  List<ContentItem> _demoItems(InstalledRepo repo, {int count = 8, int offset = 0}) {
    const posters = [
      'https://image.tmdb.org/t/p/w500/1E5baAaEse26fej7uHcjOgEE2t2.jpg',
      'https://image.tmdb.org/t/p/w500/qNBAXBIQlnOThrUvAENXhjTdxsD.jpg',
      'https://image.tmdb.org/t/p/w500/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg',
      'https://image.tmdb.org/t/p/w500/t6HIqrRAclMCA60NsSmeqe9RmNV.jpg',
      'https://image.tmdb.org/t/p/w500/vZloFAK7NmvMGKE7Os1NRW4F6D.jpg',
      'https://image.tmdb.org/t/p/w500/d5NXSklXo0qyIYkgV94XAgMIckC.jpg',
      'https://image.tmdb.org/t/p/w500/4m1Au3YDxws8A7PdYAhRfJZrj7E.jpg',
      'https://image.tmdb.org/t/p/w500/gPbM0MK8CP8A174gCChWpvuI2iR.jpg',
    ];
    final titles = [
      'Spider-Man: Brand New Day',
      'East of Eden',
      'Buddy',
      'Visionquest',
      'Disclosure Day',
      'The Diplomat',
      'Neon Horizon',
      'Silent Harbor',
      'Crimson Tide',
      'Golden Hour',
      'Series Demo',
      'Movie Demo',
    ];
    return List.generate(count, (i) {
      final idx = (i + offset) % titles.length;
      final isSeries = idx % 4 == 0;
      return ContentItem(
        id: '${repo.manifest.id}_$idx',
        title: titles[idx],
        poster: posters[idx % posters.length],
        backdrop: posters[idx % posters.length],
        type: isSeries ? 'series' : 'movie',
        rating: 7.0 + (idx % 30) / 10,
        year: '${2018 + idx}',
        overview: 'Contenido de demostración del repositorio ${repo.manifest.name}.',
        genres: isSeries ? const ['Serie', 'Drama'] : const ['Película'],
      );
    });
  }
}


/// Página de resultados (descubrir / catálogo) con soporte de scroll infinito.
class DiscoverPage {
  final List<ContentItem> items;
  final bool hasMore;
  final int page;
  const DiscoverPage({required this.items, this.hasMore = false, this.page = 1});
  static const empty = DiscoverPage(items: [], hasMore: false, page: 1);
}

/// Resultado de [ContentService.getHomeProgressive] / [getLiveCategories].
///
/// [legacy] = true → el addon devolvió el home completo (comportamiento anterior);
/// las filas ya traen items y no hace falta pedir fila a fila a la API
/// (aunque [loadHomeRow] puede paginar en memoria).
///
/// [legacy] = false → hay que cargar cada fila/categoría con [loadHomeRow] /
/// [loadLiveCategory] (petición real a la API).
class HomeProgressiveResult {
  final List<HomeRow> rows;
  final bool legacy;
  const HomeProgressiveResult({required this.rows, this.legacy = true});
}