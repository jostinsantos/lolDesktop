import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/repo_manifest.dart';
import 'github_service.dart';

/// Carga manifests, contract.json y código JS desde GitHub o URL directa.
class RepoLoader {
  RepoLoader(this._github);

  final GithubService _github;

  static const _manifestNames = [
    'lol.json',
    'nuvio.json',
    'manifest.json',
    'addon.json',
  ];

  static const _contractNames = [
    'contract.json',
    'kino.contract.json',
  ];

  /// Límites de descarga para no saturar memoria en la app.
  static const maxContractBytes = 256 * 1024; // 256 KB
  static const maxEntryBytes = 1024 * 1024; // 1 MB
  static const maxIconPeekBytes = 64 * 1024;

  /// Parseo robusto de JSON (Windows a veces trae BOM, comas finales o HTML de error).
  static Map<String, dynamic> parseJsonMap(String raw, {String label = 'JSON'}) {
    var s = raw.trim();
    // UTF-8 BOM
    if (s.startsWith('\uFEFF')) s = s.substring(1).trim();
    if (s.isEmpty) {
      throw FormatException('$label vacío');
    }
    if (s.startsWith('<!') || s.toLowerCase().startsWith('<html')) {
      throw FormatException(
        '$label no es JSON (recibió HTML). Revisa la URL del manifest.',
      );
    }
    // Comas finales antes de ] o } (común al editar a mano)
    s = s.replaceAll(RegExp(r',\s*]'), ']');
    s = s.replaceAll(RegExp(r',\s*}'), '}');
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw FormatException('$label no es un objeto JSON');
    } on FormatException catch (e) {
      debugPrint('[RepoLoader] $label parse error: $e');
      debugPrint(
          '[RepoLoader] preview: ${s.length > 200 ? s.substring(0, 200) : s}');
      rethrow;
    }
  }

  static String decodeBody(http.Response res) {
    try {
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return res.body;
    }
  }

  /// Resultado de carga (manifest + JS + contract opcional).
  Future<({RepoManifest manifest, String? jsCode, String sourceUrl, RepoContract? contract})>
      fromGithub(String userRepo) async {
    userRepo = userRepo.trim().replaceAll(RegExp(r'^https?://github\.com/'), '');
    if (userRepo.endsWith('/')) userRepo = userRepo.substring(0, userRepo.length - 1);

    String? manifestUrl;
    for (final name in _manifestNames) {
      manifestUrl = await _github.resolveRawUrl(userRepo, name);
      if (manifestUrl != null) break;
    }
    if (manifestUrl == null) {
      throw Exception(
        'No se encontró lol.json / nuvio.json / manifest.json en $userRepo (branch main/master)',
      );
    }

    final body = await _github.fetchRaw(manifestUrl);
    final map = parseJsonMap(body, label: 'manifest');
    var manifest = RepoManifest.fromJson(map, repo: userRepo);

    String? jsCode;
    final entry = manifest.entryJs ?? 'plugin.js';
    if (entry.toLowerCase().endsWith('.js')) {
      final jsUrl = await _github.resolveRawUrl(userRepo, entry);
      if (jsUrl != null) {
        try {
          final code = await _github.fetchRaw(jsUrl);
          if (code.length <= maxEntryBytes) jsCode = code;
        } catch (_) {}
      }
    }

    final icon = await _resolveAsset(userRepo, manifest.icon);
    final banner = await _resolveAsset(userRepo, manifest.banner);
    manifest = manifest.copyWith(icon: icon, banner: banner);

    final contract = await _loadContractGithub(userRepo);

    return (
      manifest: manifest,
      jsCode: jsCode,
      sourceUrl: manifestUrl,
      contract: contract,
    );
  }

  Future<RepoContract?> _loadContractGithub(String userRepo) async {
    for (final name in _contractNames) {
      final url = await _github.resolveRawUrl(userRepo, name);
      if (url == null) continue;
      try {
        final body = await _github.fetchRaw(url);
        if (body.length > maxContractBytes) {
          // Truncar JSON grande: intentar parseo completo solo si cabe
          // Si supera el límite, devolver null (el modal usará solo el manifest)
          return null;
        }
        final map = parseJsonMap(body, label: 'contract');
        return RepoContract.fromJson(map);
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _resolveAsset(String userRepo, String? path) async {
    if (path == null || path.isEmpty) return path;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return await _github.resolveRawUrl(userRepo, path) ?? path;
  }

  Future<({RepoManifest manifest, String? jsCode, String sourceUrl, RepoContract? contract})>
      fromUrl(String url) async {
    final res = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'LOLLiteDesktop/1.0',
        'Accept': 'application/json, text/plain, */*',
      },
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('No se pudo descargar el manifest (${res.statusCode})');
    }
    final body = decodeBody(res);
    final map = parseJsonMap(body, label: 'manifest');
    var manifest = RepoManifest.fromJson(map);

    final base = url.contains('/') ? url.substring(0, url.lastIndexOf('/') + 1) : url;

    String? jsCode;
    final entry = (map['entry'] ?? map['main'] ?? manifest.entryJs ?? 'plugin.js').toString();
    if (entry.toLowerCase().endsWith('.js')) {
      try {
        final entryUrl = entry.startsWith('http') ? entry : '$base$entry';
        final jsRes = await http.get(
          Uri.parse(entryUrl),
          headers: {'User-Agent': 'LOLLiteDesktop/1.0'},
        ).timeout(const Duration(seconds: 20));
        if (jsRes.statusCode == 200) {
          final code = decodeBody(jsRes).trim();
          if (code.isNotEmpty) jsCode = code;
        }
      } catch (_) {}
    }

    String? resolveRel(String? p) {
      if (p == null || p.isEmpty) return p;
      if (p.startsWith('http://') || p.startsWith('https://')) return p;
      return '$base$p';
    }

    manifest = manifest.copyWith(
      icon: resolveRel(manifest.icon),
      banner: resolveRel(manifest.banner),
    );

    RepoContract? contract;
    for (final name in _contractNames) {
      try {
        final cUrl = '$base$name';
        final cRes = await http.get(
          Uri.parse(cUrl),
          headers: {'User-Agent': 'LOLLiteDesktop/1.0'},
        ).timeout(const Duration(seconds: 10));
        if (cRes.statusCode == 200) {
          final cMap = parseJsonMap(decodeBody(cRes), label: 'contract');
          contract = RepoContract.fromJson(cMap);
          break;
        }
      } catch (_) {}
    }

    return (manifest: manifest, jsCode: jsCode, sourceUrl: url, contract: contract);
  }

  /// Icono de un repo de comunidad sin instalarlo (icon del manifest o icon.png).
  Future<String?> peekIcon(String userRepo) async {
    userRepo = userRepo.trim().replaceAll(RegExp(r'^https?://github\.com/'), '');
    for (final name in _manifestNames) {
      final url = await _github.resolveRawUrl(userRepo, name);
      if (url == null) continue;
      try {
        final body = await _github.fetchRaw(url);
        final map = parseJsonMap(body, label: 'manifest');
        final icon = (map['icon'] ?? map['logo'])?.toString();
        if (icon == null || icon.isEmpty) continue;
        if (icon.startsWith('http')) return icon;
        return await _github.resolveRawUrl(userRepo, icon) ?? icon;
      } catch (_) {}
    }
    return await _github.resolveRawUrl(userRepo, 'icon.png');
  }
}