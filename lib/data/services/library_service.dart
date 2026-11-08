import 'package:flutter/foundation.dart';
import '../../core/storage/local_storage.dart';
import '../models/repo_manifest.dart';

/// Entrada de "continuar viendo".
class WatchEntry {
  final String repoId;
  final String contentId;
  final String title;
  final String? poster;
  final String type;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  WatchEntry({
    required this.repoId,
    required this.contentId,
    required this.title,
    this.poster,
    this.type = 'movie',
    this.positionMs = 0,
    this.durationMs = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'repoId': repoId,
        'contentId': contentId,
        'title': title,
        'poster': poster,
        'type': type,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory WatchEntry.fromJson(Map<String, dynamic> j) => WatchEntry(
        repoId: (j['repoId'] ?? '').toString(),
        contentId: (j['contentId'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        poster: j['poster']?.toString(),
        type: (j['type'] ?? 'movie').toString(),
        positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(j['updatedAt']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// Favorito por repo.
class FavoriteEntry {
  final String repoId;
  final String contentId;
  final String title;
  final String? poster;
  final String type;
  final DateTime addedAt;

  FavoriteEntry({
    required this.repoId,
    required this.contentId,
    required this.title,
    this.poster,
    this.type = 'movie',
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'repoId': repoId,
        'contentId': contentId,
        'title': title,
        'poster': poster,
        'type': type,
        'addedAt': addedAt.toIso8601String(),
      };

  factory FavoriteEntry.fromJson(Map<String, dynamic> j) => FavoriteEntry(
        repoId: (j['repoId'] ?? '').toString(),
        contentId: (j['contentId'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        poster: j['poster']?.toString(),
        type: (j['type'] ?? 'movie').toString(),
        addedAt: DateTime.tryParse(j['addedAt']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// Continuar viendo + favoritos, aislados por repoId.
class LibraryService extends ChangeNotifier {
  LibraryService(this._storage);

  final LocalStorage _storage;
  static const _keyWatch = 'library_watch';
  static const _keyFav = 'library_favorites';

  final List<WatchEntry> _watch = [];
  final List<FavoriteEntry> _favs = [];

  Future<void> init() async {
    final w = _storage.getJson(_keyWatch);
    if (w is List) {
      for (final e in w) {
        if (e is Map) {
          try {
            _watch.add(WatchEntry.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
    }
    final f = _storage.getJson(_keyFav);
    if (f is List) {
      for (final e in f) {
        if (e is Map) {
          try {
            _favs.add(FavoriteEntry.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
    }
    notifyListeners();
  }

  Future<void> _persistWatch() async {
    await _storage.setJson(_keyWatch, _watch.map((e) => e.toJson()).toList());
  }

  Future<void> _persistFav() async {
    await _storage.setJson(_keyFav, _favs.map((e) => e.toJson()).toList());
  }

  // ---- continuar viendo ----

  List<WatchEntry> continueWatchingAll() {
    final list = List<WatchEntry>.from(_watch)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  List<WatchEntry> continueWatching(String repoId) {
    final list = _watch.where((e) => e.repoId == repoId).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<void> saveProgress({
    required String repoId,
    required String contentId,
    required String title,
    String? poster,
    String type = 'movie',
    required int positionMs,
    required int durationMs,
  }) async {
    _watch.removeWhere((e) => e.repoId == repoId && e.contentId == contentId);
    // Si terminó (>90%), no guardar
    if (durationMs > 0 && positionMs / durationMs > 0.9) {
      await _persistWatch();
      notifyListeners();
      return;
    }
    _watch.insert(
      0,
      WatchEntry(
        repoId: repoId,
        contentId: contentId,
        title: title,
        poster: poster,
        type: type,
        positionMs: positionMs,
        durationMs: durationMs,
      ),
    );
    // Limitar a 50 por repo
    final forRepo = _watch.where((e) => e.repoId == repoId).toList();
    if (forRepo.length > 50) {
      for (final old in forRepo.skip(50)) {
        _watch.remove(old);
      }
    }
    await _persistWatch();
    notifyListeners();
  }

  Future<void> removeWatch(String repoId, String contentId) async {
    _watch.removeWhere((e) => e.repoId == repoId && e.contentId == contentId);
    await _persistWatch();
    notifyListeners();
  }

  // ---- favoritos ----

  List<FavoriteEntry> favorites(String repoId) {
    return _favs.where((e) => e.repoId == repoId).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  }

  bool isFavorite(String repoId, String contentId) =>
      _favs.any((e) => e.repoId == repoId && e.contentId == contentId);

  Future<void> toggleFavorite({
    required String repoId,
    required String contentId,
    required String title,
    String? poster,
    String type = 'movie',
  }) async {
    final i = _favs.indexWhere(
        (e) => e.repoId == repoId && e.contentId == contentId);
    if (i >= 0) {
      _favs.removeAt(i);
    } else {
      _favs.insert(
        0,
        FavoriteEntry(
          repoId: repoId,
          contentId: contentId,
          title: title,
          poster: poster,
          type: type,
        ),
      );
    }
    await _persistFav();
    notifyListeners();
  }

  /// Elimina continuar-viendo y favoritos de un repo (al desinstalar).
  Future<void> clearRepoData(String repoId) async {
    _watch.removeWhere((e) => e.repoId == repoId);
    _favs.removeWhere((e) => e.repoId == repoId);
    await _persistWatch();
    await _persistFav();
    notifyListeners();
  }
}
