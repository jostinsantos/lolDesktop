import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/storage/local_storage.dart';
import '../models/repo_manifest.dart';
import 'content_cache.dart';
import 'content_service.dart';
import 'github_service.dart';
import 'repo_loader.dart';

/// Resultado de health-check real de un repo.
class RepoHealthResult {
  final String status; // ok | no_js | disabled | home_fail | streams_fail | error
  final String label;
  final String? detail;
  const RepoHealthResult(this.status, this.label, {this.detail});
  bool get isOk => status == 'ok';
}

/// Gestiona repos instalados: instalar, desinstalar, actualizar, configs de usuario.
class RepoManager extends ChangeNotifier {
  RepoManager(this._storage);

  final LocalStorage _storage;
  final GithubService _github = GithubService();
  late final RepoLoader _loader = RepoLoader(_github);

  static const _keyInstalled = 'installed_repos';
  static const _keyUsage = 'repo_usage_counts';
  static const _bgChannel = MethodChannel('com.lol.lite/bg_updates');

  final List<InstalledRepo> _installed = [];
  List<InstalledRepo> get installed => List.unmodifiable(_installed);
  List<InstalledRepo> get enabled => _installed.where((r) => r.enabled).toList();

  /// repoId → versión remota disponible (si hay update)
  final Map<String, String> _availableUpdates = {};
  Map<String, String> get availableUpdates => Map.unmodifiable(_availableUpdates);
  bool hasUpdate(String repoId) => _availableUpdates.containsKey(repoId);
  String? remoteVersion(String repoId) => _availableUpdates[repoId];
  int get updateCount => _availableUpdates.length;

  /// repoId → veces usado (abrir home / streams)
  final Map<String, int> _usage = {};
  int usageOf(String repoId) => _usage[repoId] ?? 0;

  /// Health cache (último check)
  final Map<String, RepoHealthResult> _healthCache = {};
  RepoHealthResult? lastHealth(String repoId) => _healthCache[repoId];

  /// Estado rápido (sin red).
  String healthOf(InstalledRepo r) {
    if (!r.enabled) return 'disabled';
    if (r.jsCode == null || r.jsCode!.trim().isEmpty) return 'no_js';
    final h = _healthCache[r.manifest.id];
    if (h != null) return h.status;
    return 'ok';
  }

  /// Instalados recientemente (más nuevo primero).
  List<InstalledRepo> get recentlyInstalled {
    final list = List<InstalledRepo>.from(_installed);
    list.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    return list;
  }

  /// Más usados primero.
  List<InstalledRepo> get mostUsed {
    final list = List<InstalledRepo>.from(_installed);
    list.sort((a, b) => usageOf(b.manifest.id).compareTo(usageOf(a.manifest.id)));
    return list;
  }

  RepoLoader get loader => _loader;

  Future<void> init() async {
    final raw = _storage.getJson(_keyInstalled);
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          try {
            _installed.add(InstalledRepo.fromJson(Map<String, dynamic>.from(e)));
          } catch (err) {
            debugPrint('[RepoManager] skip invalid: $err');
          }
        }
      }
    }
    final usageRaw = _storage.getJson(_keyUsage);
    if (usageRaw is Map) {
      usageRaw.forEach((k, v) {
        final n = int.tryParse('$v') ?? 0;
        if (n > 0) _usage[k.toString()] = n;
      });
    }
    // Programar worker de updates en background (Android)
    try {
      await _bgChannel.invokeMethod('schedule');
    } catch (e) {
      debugPrint('[RepoManager] schedule bg updates: $e');
    }
    notifyListeners();
  }

  Future<void> _persistUsage() async {
    await _storage.setJson(_keyUsage, _usage);
  }

  /// Incrementa contador de uso del repo.
  Future<void> recordUsage(String repoId) async {
    _usage[repoId] = (_usage[repoId] ?? 0) + 1;
    await _persistUsage();
    notifyListeners();
  }

  /// Health-check real: intenta getHome (y opcionalmente streams vacíos).
  Future<RepoHealthResult> runHealthCheck(InstalledRepo repo) async {
    if (!repo.enabled) {
      final r = const RepoHealthResult('disabled', 'Desactivado');
      _healthCache[repo.manifest.id] = r;
      notifyListeners();
      return r;
    }
    if (repo.jsCode == null || repo.jsCode!.trim().isEmpty) {
      final r = const RepoHealthResult('no_js', 'Sin JS');
      _healthCache[repo.manifest.id] = r;
      notifyListeners();
      return r;
    }
    try {
      final home = await ContentService.instance
          .getHome(repo, forceRefresh: true)
          .timeout(const Duration(seconds: 20));
      if (home.isEmpty) {
        final r = const RepoHealthResult('home_fail', 'Home vacío',
            detail: 'getHome no devolvió filas');
        _healthCache[repo.manifest.id] = r;
        notifyListeners();
        return r;
      }
      final r = RepoHealthResult('ok', 'OK', detail: '${home.length} filas');
      _healthCache[repo.manifest.id] = r;
      notifyListeners();
      return r;
    } catch (e) {
      final r = RepoHealthResult('error', 'Error', detail: e.toString());
      _healthCache[repo.manifest.id] = r;
      notifyListeners();
      return r;
    }
  }

  /// Ejecuta health-check de todos los repos enabled.
  Future<void> runAllHealthChecks() async {
    for (final r in enabled) {
      await runHealthCheck(r);
    }
  }

  /// Invalida caché de contenido de todos los repos (o uno).
  Future<void> refreshAllContent({String? repoId}) async {
    if (repoId != null) {
      await ContentCache.instance.clearRepo(repoId);
    } else {
      for (final r in _installed) {
        try {
          await ContentCache.instance.clearRepo(r.manifest.id);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  /// Comprueba actualizaciones de todos los repos instalados (en paralelo, limitado).
  Future<int> checkAllUpdates() async {
    _availableUpdates.clear();
    final list = List<InstalledRepo>.from(_installed);
    // Paralelismo moderado para no saturar red
    const batch = 4;
    for (var i = 0; i < list.length; i += batch) {
      final chunk = list.skip(i).take(batch);
      await Future.wait(chunk.map((repo) async {
        try {
          final remote = await checkForUpdate(repo);
          if (remote != null) {
            _availableUpdates[repo.manifest.id] = remote.version;
          }
        } catch (e) {
          debugPrint('[RepoManager] checkAllUpdates ${repo.manifest.id}: $e');
        }
      }));
    }
    notifyListeners();
    return _availableUpdates.length;
  }

  Future<void> _persist() async {
    await _storage.setJson(
      _keyInstalled,
      _installed.map((e) => e.toJson()).toList(),
    );
  }

  /// Carga manifest + contract sin instalar (para el modal de confirmación).
  Future<({RepoManifest manifest, String? jsCode, String sourceUrl, RepoContract? contract})>
      previewFromGithub(String userRepo) {
    return _loader.fromGithub(userRepo);
  }

  Future<({RepoManifest manifest, String? jsCode, String sourceUrl, RepoContract? contract})>
      previewFromUrl(String url) {
    return _loader.fromUrl(url);
  }

  /// Instala desde "user/repo" de GitHub.
  Future<InstalledRepo> installFromGithub(String userRepo) async {
    final result = await _loader.fromGithub(userRepo);
    return _commitInstall(result);
  }

  /// Instala desde un resultado ya cargado (tras confirmar el modal).
  Future<InstalledRepo> installFromPreview(
    ({RepoManifest manifest, String? jsCode, String sourceUrl, RepoContract? contract}) result,
  ) {
    return _commitInstall(result);
  }

  Future<InstalledRepo> _commitInstall(
    ({RepoManifest manifest, String? jsCode, String sourceUrl, RepoContract? contract}) result,
  ) async {
    final existing = _installed.indexWhere((r) => r.manifest.repo == result.manifest.repo);
    final byId = existing < 0
        ? _installed.indexWhere((r) => r.manifest.id == result.manifest.id)
        : existing;
    final idx = byId;
    final repo = InstalledRepo(
      manifest: result.manifest,
      sourceUrl: result.sourceUrl,
      installedAt: idx >= 0 ? _installed[idx].installedAt : DateTime.now(),
      updatedAt: DateTime.now(),
      enabled: true,
      jsCode: result.jsCode,
      userConfig: idx >= 0 ? _installed[idx].userConfig : {},
      contract: result.contract,
    );
    if (idx >= 0) {
      _installed[idx] = repo;
    } else {
      _installed.add(repo);
    }
    // Si se actualizó, quitar del mapa de updates pendientes
    _availableUpdates.remove(result.manifest.id);
    await _persist();
    notifyListeners();
    return repo;
  }

  Future<InstalledRepo> installFromUrl(String url) async {
    final result = await _loader.fromUrl(url);
    return _commitInstall(result);
  }

  Future<void> uninstall(String id) async {
    _installed.removeWhere((r) => r.manifest.id == id);
    _availableUpdates.remove(id);
    await _persist();
    try {
      await ContentCache.instance.clearRepo(id);
      final prefix = 'repo_pref_' + id + '_';
      final cachePrefix = 'content_cache_' + id;
      final keys = _storage.prefs
          .getKeys()
          .where((k) => k.startsWith(prefix) || k.startsWith(cachePrefix))
          .toList();
      for (final k in keys) {
        await _storage.remove(k);
      }
      debugPrint('[RepoManager] uninstalled and cleaned ' + id);
    } catch (e) {
      debugPrint('[RepoManager] cleanup on uninstall: ' + e.toString());
    }
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _installed.indexWhere((r) => r.manifest.id == id);
    if (i < 0) return;
    _installed[i] = _installed[i].copyWith(enabled: enabled);
    await _persist();
    notifyListeners();
  }

  Future<void> saveUserConfig(String id, Map<String, String> config) async {
    final i = _installed.indexWhere((r) => r.manifest.id == id);
    if (i < 0) return;
    _installed[i] = _installed[i].copyWith(userConfig: Map.from(config));
    await _persist();
    notifyListeners();
  }

  /// Guarda config, la inyecta en el runtime JS e invalida caché del repo.
  Future<InstalledRepo?> applyUserConfig(String id, Map<String, String> config) async {
    await saveUserConfig(id, config);
    final repo = getById(id);
    if (repo == null) return null;
    try {
      final code = repo.jsCode;
      if (code != null && code.trim().isNotEmpty) {
        // Re-load + setConfig se hace desde la UI con JsAddonRuntime;
        // aquí solo garantizamos el modelo actualizado.
      }
    } catch (_) {}
    try {
      await ContentCache.instance.clearRepo(id);
    } catch (_) {}
    notifyListeners();
    return getById(id);
  }

  InstalledRepo? getById(String id) {
    try {
      return _installed.firstWhere((r) => r.manifest.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Comprueba si hay una versión más nueva en el origen del plugin.
  /// Devuelve el manifest remoto si la versión difiere; null si está al día o falla.
  Future<RepoManifest?> checkForUpdate(InstalledRepo repo) async {
    try {
      final source = repo.sourceUrl;
      final result = source.contains('github.com') ||
              RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(source)
          ? await _loader.fromGithub(
              source.contains('github.com')
                  ? source
                      .replaceFirst(RegExp(r'https?://github\.com/'), '')
                      .replaceAll(RegExp(r'/$'), '')
                      .split('/')
                      .take(2)
                      .join('/')
                  : source)
          : await _loader.fromUrl(source);
      final remote = result.manifest;
      if (remote.version != repo.manifest.version) {
        return remote;
      }
      return null;
    } catch (e) {
      debugPrint('[RepoManager] checkForUpdate: $e');
      return null;
    }
  }

  /// Reinstala / actualiza el plugin desde su origen.
  Future<InstalledRepo> updateRepo(InstalledRepo repo) async {
    final source = repo.sourceUrl;
    if (source.contains('github.com') ||
        RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(source)) {
      final userRepo = source.contains('github.com')
          ? source
              .replaceFirst(RegExp(r'https?://github\.com/'), '')
              .replaceAll(RegExp(r'/$'), '')
              .split('/')
              .take(2)
              .join('/')
          : source;
      return installFromGithub(userRepo);
    }
    return installFromUrl(source);
  }

  Future<List<CommunityRepoItem>> fetchCommunity() => _github.fetchCommunity();

  Future<String?> peekIcon(String userRepo) => _loader.peekIcon(userRepo);
}

