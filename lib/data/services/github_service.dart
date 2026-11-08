import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Item de la comunidad (repo público etiquetado).
class CommunityRepoItem {
  final String id;
  final String repo; // user/repo
  final String name;
  final String description;
  final String? avatarUrl;
  final int stars;
  final String? topic;

  CommunityRepoItem({
    required this.id,
    required this.repo,
    required this.name,
    required this.description,
    this.avatarUrl,
    this.stars = 0,
    this.topic,
  });
}

/// Servicio de comunidad: busca repos en GitHub por topic (como en lolapp).
/// Topics recomendados: nuvio-addon, nuvio-repo, lol-addon-catalog
class GithubService {
  static const _userAgent = 'NuvioLauncher/1.0';
  /// Topic oficial de la comunidad: https://github.com/topics/lol-plus-repos
  static const topicPrimary = 'lol-plus-repos';
  static const topicAlt = <String>[];

  /// Seeds de ejemplo (siempre visibles aunque GitHub falle).
  static const recommendedSeed = <Map<String, dynamic>>[
    {
      'id': 'demo-movies',
      'repo': 'nuvio-community/demo-movies',
      'name': 'Demo Movies',
      'description': 'Repositorio de ejemplo con películas de demostración.',
    },
  ];

  Future<http.Response> _get(String url) {
    return http
        .get(
          Uri.parse(url),
          headers: {
            'Accept': 'application/vnd.github+json, application/json, */*',
            'User-Agent': _userAgent,
          },
        )
        .timeout(const Duration(seconds: 15));
  }

  List<CommunityRepoItem> recommended() {
    return recommendedSeed
        .map((e) => CommunityRepoItem(
              id: e['id'] as String,
              repo: e['repo'] as String,
              name: e['name'] as String,
              description: (e['description'] ?? '') as String,
            ))
        .toList();
  }

  Future<List<CommunityRepoItem>> fetchCommunity({String? topic}) async {
    final topics = topic != null ? [topic] : [topicPrimary, ...topicAlt]; // solo lol-plus-repos
    final results = <CommunityRepoItem>[];
    final seen = <String>{};

    for (final t in topics) {
      try {
        final url =
            'https://api.github.com/search/repositories?q=topic:$t+fork:false&sort=stars&order=desc&per_page=30';
        final res = await _get(url);
        if (res.statusCode != 200) {
          debugPrint('[Github] topic:$t status ${res.statusCode}');
          continue;
        }
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        for (final raw in (body['items'] as List? ?? [])) {
          if (raw is! Map) continue;
          final full = (raw['full_name'] ?? '').toString();
          if (full.isEmpty || !seen.add(full)) continue;
          final owner = raw['owner'] as Map?;
          results.add(CommunityRepoItem(
            id: full.replaceAll('/', '-').toLowerCase(),
            repo: full,
            name: (raw['name'] ?? full).toString(),
            description: (raw['description'] ?? '').toString(),
            avatarUrl: owner?['avatar_url']?.toString(),
            stars: (raw['stargazers_count'] as num?)?.toInt() ?? 0,
            topic: t,
          ));
        }
      } catch (e) {
        debugPrint('[Github] error topic $t: $e');
      }
    }

    if (results.isEmpty) return recommended();
    results.sort((a, b) => b.stars.compareTo(a.stars));
    return results;
  }

  /// Resuelve la URL raw de un archivo en un repo (branch main o master).
  Future<String?> resolveRawUrl(String userRepo, String path) async {
    for (final branch in ['main', 'master']) {
      final url = 'https://raw.githubusercontent.com/$userRepo/$branch/$path';
      try {
        final res = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) return url;
      } catch (_) {}
    }
    return null;
  }

  /// Descarga texto de raw.githubusercontent.com (UTF-8 seguro en Windows).
  Future<String> fetchRaw(String url) async {
    final res = await http
        .get(
          Uri.parse(url),
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/json, text/plain, */*',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('No se pudo descargar (${res.statusCode}): $url');
    }
    try {
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return res.body;
    }
  }
}