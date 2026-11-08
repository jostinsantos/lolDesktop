import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../core/storage/local_storage.dart';

/// Caché de contenido de repos (home, news, discover, etc.).
/// TTL por defecto 24 horas. Se invalida con pull-to-refresh o al desinstalar.
class ContentCache {
  ContentCache._();
  static final ContentCache instance = ContentCache._();

  LocalStorage? _storage;

  /// TTL de 24 horas.
  static const Duration defaultTtl = Duration(hours: 24);

  static const String _prefix = 'content_cache_';
  static const String _indexKey = 'content_cache_index';

  void bind(LocalStorage storage) {
    _storage = storage;
  }

  LocalStorage get _s {
    final s = _storage;
    if (s == null) throw StateError('ContentCache no inicializado');
    return s;
  }

  String _key(String repoId, String method, [String? suffix]) {
    final base = '$_prefix${repoId}_$method';
    if (suffix == null || suffix.isEmpty) return base;
    // Hash simple del sufijo para no explotar la longitud de la key
    final h = suffix.hashCode.toRadixString(16);
    return '${base}_$h';
  }

  Future<void> _trackKey(String key) async {
    final raw = _s.getJson(_indexKey);
    final list = <String>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is String) list.add(e);
      }
    }
    if (!list.contains(key)) {
      list.add(key);
      await _s.setJson(_indexKey, list);
    }
  }

  Future<void> set(
    String repoId,
    String method,
    dynamic data, {
    String? suffix,
    Duration ttl = defaultTtl,
  }) async {
    try {
      final key = _key(repoId, method, suffix);
      final payload = {
        'expiresAt': DateTime.now().add(ttl).toIso8601String(),
        'savedAt': DateTime.now().toIso8601String(),
        'data': data,
      };
      await _s.setJson(key, payload);
      await _trackKey(key);
    } catch (e) {
      debugPrint('[ContentCache] set error: $e');
    }
  }

  /// Devuelve datos si existen y no han expirado. null = miss o caducado.
  dynamic get(String repoId, String method, {String? suffix}) {
    try {
      final key = _key(repoId, method, suffix);
      final raw = _s.getJson(key);
      if (raw is! Map) return null;
      final expires = DateTime.tryParse(raw['expiresAt']?.toString() ?? '');
      if (expires == null || DateTime.now().isAfter(expires)) {
        // Caducado: borrar en background
        _s.remove(key);
        return null;
      }
      return raw['data'];
    } catch (e) {
      debugPrint('[ContentCache] get error: $e');
      return null;
    }
  }

  Future<void> invalidate(String repoId, String method, {String? suffix}) async {
    try {
      final key = _key(repoId, method, suffix);
      await _s.remove(key);
    } catch (_) {}
  }

  /// Invalida todo lo de un método de un repo (p. ej. home al hacer pull-refresh).
  Future<void> invalidateMethod(String repoId, String method) async {
    try {
      final raw = _s.getJson(_indexKey);
      if (raw is! List) return;
      final prefix = '$_prefix${repoId}_$method';
      final keep = <String>[];
      for (final e in raw) {
        if (e is! String) continue;
        if (e.startsWith(prefix)) {
          await _s.remove(e);
        } else {
          keep.add(e);
        }
      }
      await _s.setJson(_indexKey, keep);
    } catch (e) {
      debugPrint('[ContentCache] invalidateMethod: $e');
    }
  }

  /// Borra TODO el caché asociado a un repo (desinstalación).
  Future<void> clearRepo(String repoId) async {
    try {
      final raw = _s.getJson(_indexKey);
      if (raw is! List) return;
      final prefix = '$_prefix${repoId}_';
      final keep = <String>[];
      for (final e in raw) {
        if (e is! String) continue;
        if (e.startsWith(prefix) || e.startsWith('$_prefix$repoId')) {
          await _s.remove(e);
        } else {
          keep.add(e);
        }
      }
      await _s.setJson(_indexKey, keep);
      // También limpia posibles keys sueltas de prefs del repo
      debugPrint('[ContentCache] cleared cache for repo $repoId');
    } catch (e) {
      debugPrint('[ContentCache] clearRepo: $e');
    }
  }

  /// Limpia entradas caducadas del índice.
  Future<void> purgeExpired() async {
    try {
      final raw = _s.getJson(_indexKey);
      if (raw is! List) return;
      final keep = <String>[];
      for (final e in raw) {
        if (e is! String) continue;
        final data = _s.getJson(e);
        if (data is Map) {
          final expires = DateTime.tryParse(data['expiresAt']?.toString() ?? '');
          if (expires != null && DateTime.now().isBefore(expires)) {
            keep.add(e);
            continue;
          }
        }
        await _s.remove(e);
      }
      await _s.setJson(_indexKey, keep);
    } catch (_) {}
  }
}
