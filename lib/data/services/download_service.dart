import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/storage/local_storage.dart';
import '../models/download_item.dart';
import '../models/stream_server.dart';

/// Servicio global de descargas (películas / episodios).
/// - Progresivo (mp4/mkv/ts)
/// - HLS (m3u8 + segmentos)
/// - Subtítulos externos
/// - Notificación nativa (Android)
/// - Segundo plano en móvil vía foreground service nativo
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const _storageKey = 'downloads_v1';
  static const _channel = MethodChannel('com.lol.lite/downloads');

  LocalStorage? _storage;
  final List<DownloadItem> _items = [];
  final Map<String, http.Client> _clients = {};
  final Map<String, bool> _cancelFlags = {};
  /// Último muestreo para calcular velocidad / ETA por descarga.
  final Map<String, _SpeedSample> _speedSamples = {};
  final Set<String> _runningIds = {};
  bool _pumping = false;
  /// Hilos/conexiones por descarga (segmentos HLS).
  int maxParallel = 3;
  /// Descargas completas simultáneas (1–3).
  int maxConcurrent = 1;
  /// TV: toasts cortos en vez de notificación del sistema.
  bool softToast = false;
  /// La UI pide ocultar el overlay (player / página descargas).
  bool hideOverlay = false;

  void setHideOverlay(bool v) {
    if (hideOverlay == v) return;
    hideOverlay = v;
    notifyListeners();
  }

  static const _parallelKey = 'download_max_parallel';
  static const _concurrentKey = 'download_max_concurrent';

  List<DownloadItem> get items => List.unmodifiable(_items);
  List<DownloadItem> get active =>
      _items.where((e) => e.status == DownloadStatus.downloading || e.status == DownloadStatus.queued).toList();
  List<DownloadItem> get completed =>
      _items.where((e) => e.status == DownloadStatus.completed).toList();
  int get activeCount => active.length;
  int get downloadingCount =>
      _items.where((e) => e.status == DownloadStatus.downloading).length;

  /// Bytes/s estimados de una descarga activa (0 si no hay datos).
  double speedBps(String id) => _speedSamples[id]?.bps ?? 0;

  /// ETA en segundos (null si desconocido).
  int? etaSeconds(String id) {
    final item = _items.cast<DownloadItem?>().firstWhere(
          (e) => e?.id == id,
          orElse: () => null,
        );
    if (item == null || item.totalBytes == null || item.totalBytes! <= 0) return null;
    final bps = speedBps(id);
    if (bps < 512) return null;
    final left = item.totalBytes! - item.receivedBytes;
    if (left <= 0) return 0;
    return (left / bps).ceil();
  }

  /// Texto legible de ETA (ej. "2m 15s").
  String? etaLabel(String id) {
    final sec = etaSeconds(id);
    if (sec == null) return null;
    if (sec < 60) return '${sec}s';
    if (sec < 3600) {
      final m = sec ~/ 60;
      final s = sec % 60;
      return s > 0 ? '${m}m ${s}s' : '${m}m';
    }
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return m > 0 ? '${h}h ${m}m' : '${h}h';
  }

  void _recordSpeed(String id, int receivedBytes) {
    final now = DateTime.now();
    final prev = _speedSamples[id];
    if (prev != null) {
      final dt = now.difference(prev.at).inMilliseconds / 1000.0;
      if (dt >= 0.4) {
        final db = receivedBytes - prev.bytes;
        final bps = db > 0 ? db / dt : prev.bps * 0.7;
        // Suavizado
        final smooth = prev.bps > 0 ? (prev.bps * 0.6 + bps * 0.4) : bps;
        _speedSamples[id] = _SpeedSample(now, receivedBytes, smooth);
        return;
      }
    }
    _speedSamples[id] = _SpeedSample(now, receivedBytes, prev?.bps ?? 0);
  }

  /// Busca una descarga completada para reproducir offline.
  DownloadItem? findCompleted({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) {
    for (final e in _items) {
      if (e.status != DownloadStatus.completed) continue;
      if (e.repoId != repoId) continue;
      if (e.contentId != contentId && !e.contentId.startsWith('$contentId:')) continue;
      if (season != null && episode != null) {
        if (e.season == season && e.episode == episode) return e;
        continue;
      }
      if (season == null && episode == null) return e;
    }
    // fallback: cualquier completed del contentId
    for (final e in _items) {
      if (e.status == DownloadStatus.completed &&
          e.repoId == repoId &&
          (e.contentId == contentId || e.contentId.startsWith('$contentId:'))) {
        if (season == null || e.season == season) {
          if (episode == null || e.episode == episode) return e;
        }
      }
    }
    return null;
  }

  bool isDownloaded({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) =>
      findCompleted(repoId: repoId, contentId: contentId, season: season, episode: episode) != null;

  /// StreamServer local para el player (file:// o path absoluto).
  StreamServer? offlineServerFor({
    required String repoId,
    required String contentId,
    int? season,
    int? episode,
  }) {
    final d = findCompleted(
      repoId: repoId,
      contentId: contentId,
      season: season,
      episode: episode,
    );
    if (d == null || d.localPath == null || d.localPath!.isEmpty) return null;
    final path = d.localPath!;
    final file = File(path);
    if (!file.existsSync()) return null;
    final uri = path.startsWith('file:') ? path : Uri.file(path).toString();
    final subs = d.subtitles
        .where((s) => s.localPath != null && s.localPath!.isNotEmpty)
        .map((s) => ExternalSubtitle(
              lang: s.lang,
              label: s.label,
              url: s.localPath!.startsWith('file:')
                  ? s.localPath!
                  : Uri.file(s.localPath!).toString(),
            ))
        .toList();
    return StreamServer(
      url: uri,
      name: 'Descarga local',
      quality: d.quality ?? 'Offline',
      language: 'local',
      provider: d.repoName,
      isHls: path.endsWith('.m3u8'),
      subtitles: subs,
    );
  }

  void bind(LocalStorage storage) {
    _storage = storage;
  }

  Future<void> init() async {
    final s = _storage;
    if (s == null) return;
    final raw = s.getJson(_storageKey);
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          try {
            final item = DownloadItem.fromJson(Map<String, dynamic>.from(e));
            // Reanudar como queued si estaba downloading al cerrar
            // Reanudar sin perder progreso (Range / segmentos ya bajados)
            if (item.status == DownloadStatus.downloading) {
              item.status = DownloadStatus.queued;
            }
            _items.add(item);
          } catch (err) {
            debugPrint('[Download] skip: $err');
          }
        }
      }
    }
    final parRaw = s.getJson(_parallelKey);
    final par = parRaw is int ? parRaw : int.tryParse('${parRaw ?? ''}');
    if (par != null && par >= 1 && par <= 8) maxParallel = par;
    final concRaw = s.getJson(_concurrentKey);
    final conc = concRaw is int ? concRaw : int.tryParse('${concRaw ?? ''}');
    if (conc != null && conc >= 1 && conc <= 3) maxConcurrent = conc;
    notifyListeners();
    unawaited(_pumpQueue());
  }

  Future<void> setMaxParallel(int n) async {
    maxParallel = n.clamp(1, 8);
    final s = _storage;
    if (s != null) await s.setJson(_parallelKey, maxParallel);
    notifyListeners();
  }

  Future<void> setMaxConcurrent(int n) async {
    maxConcurrent = n.clamp(1, 3);
    final s = _storage;
    if (s != null) await s.setJson(_concurrentKey, maxConcurrent);
    notifyListeners();
    unawaited(_pumpQueue());
  }

  Future<void> convertItem(String id) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final item = _items[i];
    if (item.localPath == null) return;
    _items[i] = item.copyWith(status: DownloadStatus.converting);
    notifyListeners();
    try {
      final local = item.localPath!;
      final folder = File(local).parent.path;
      final subArgs = item.subtitles
          .where((s) => s.localPath != null && s.localPath!.isNotEmpty)
          .map((s) => {
                'path': s.localPath!,
                'lang': s.lang,
                'label': s.label,
              })
          .toList();
      // Preferir ffmpeg local (desktop) con audios + subtítulos.
      final dir = Directory(folder);
      final mkv = await _convertToMkv(
        inputPath: local,
        folder: dir,
        title: item.displayTitle,
        subtitles: item.subtitles,
      );
      if (mkv != null && mkv.isNotEmpty) {
        _items[i] = _items[i].copyWith(
          status: DownloadStatus.completed,
          localPath: mkv,
          progress: 1,
        );
      } else {
        final out = await _channel.invokeMethod<String>('convert', {
          'input': local,
          'kind': item.kind.name,
          'outputDir': folder,
          'title': item.displayTitle,
          'subtitles': subArgs,
        });
        if (out != null && out.isNotEmpty) {
          _items[i] = _items[i].copyWith(
            status: DownloadStatus.completed,
            localPath: out,
            progress: 1,
          );
        } else {
          _items[i] = item.copyWith(
            status: DownloadStatus.failed,
            error: 'No se pudo convertir a MKV (¿ffmpeg instalado?)',
          );
        }
      }
    } catch (e) {
      _items[i] = item.copyWith(status: DownloadStatus.failed, error: 'Convert: $e');
    }
    await _persist();
    notifyListeners();
    await _notifyNative(hide: active.isEmpty);
  }

  Future<void> _persist() async {
    final s = _storage;
    if (s == null) return;
    await s.setJson(_storageKey, _items.map((e) => e.toJson()).toList());
  }

  DownloadKind _kindFor(String url, bool isHls) {
    final u = url.toLowerCase();
    if (isHls || u.contains('.m3u8')) return DownloadKind.hls;
    if (u.contains('.ts') && !u.contains('.m3u8')) return DownloadKind.ts;
    return DownloadKind.progressive;
  }

  /// Encola una descarga y arranca la cola.
  Future<DownloadItem> enqueue({
    required String repoId,
    required String repoName,
    required String contentId,
    required String title,
    String? poster,
    String type = 'movie',
    int? season,
    int? episode,
    String? episodeTitle,
    required StreamServer server,
    bool convertOnMobile = false,
  }) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
    final kind = _kindFor(server.url, server.isHls);
    final subs = server.subtitles
        .where((s) => s.url.isNotEmpty)
        .map((s) => SubtitleDownload(lang: s.lang, label: s.label, url: s.url))
        .toList();

    final item = DownloadItem(
      id: id,
      repoId: repoId,
      repoName: repoName,
      contentId: contentId,
      title: title,
      poster: poster,
      type: type,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      serverName: server.name,
      quality: server.quality,
      url: server.url,
      headers: Map<String, String>.from(server.headers),
      isHls: server.isHls || kind == DownloadKind.hls,
      subtitles: subs,
      kind: kind,
      convertOnMobile: convertOnMobile,
      status: DownloadStatus.queued,
    );
    _items.insert(0, item);
    // Asegurar que el overlay flotante pueda mostrarse
    hideOverlay = false;
    await _persist();
    notifyListeners();
    unawaited(_pumpQueue());
    return item;
  }

  Future<void> cancel(String id) async {
    _cancelFlags[id] = true;
    _clients[id]?.close();
    final i = _items.indexWhere((e) => e.id == id);
    if (i >= 0) {
      _items[i] = _items[i].copyWith(status: DownloadStatus.cancelled, error: 'Cancelado');
      await _persist();
      notifyListeners();
      await _notifyNative();
    }
  }

  Future<void> remove(String id) async {
    await cancel(id);
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final item = _items[i];
    final path = item.localPath;

    // Solo borra caché interna de la app (lol_downloads/...).
    // NO toca Descargas/lollite (archivo convertido del usuario).
    if (path != null && path.isNotEmpty) {
      try {
        // Si el path ya es público (lollite / content://), no borrar
        final lower = path.toLowerCase();
        final isPublic = lower.contains('${Platform.pathSeparator}download') ||
            lower.contains('/download') ||
            lower.contains('lollite') ||
            path.startsWith('content:');
        if (!isPublic) {
          final f = File(path);
          Directory? root;
          if (await f.exists() || await Directory(path).exists()) {
            var parent = f.existsSync() ? f.parent : Directory(path);
            if (parent.path.endsWith('${Platform.pathSeparator}hls') ||
                parent.path.endsWith('/hls')) {
              parent = parent.parent;
            }
            if (parent.path.contains('lol_downloads')) {
              root = parent;
            }
          }
          if (root != null && await root.exists()) {
            await root.delete(recursive: true);
          } else if (await File(path).exists()) {
            await File(path).delete();
          }
        }
      } catch (e) {
        debugPrint('[Download] remove cache: $e');
      }
    }

    _items.removeAt(i);
    await _persist();
    notifyListeners();
    await _notifyNative(hide: active.isEmpty);
  }

  Future<void> retry(String id) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _cancelFlags[id] = false;
    _items[i] = _items[i].copyWith(
      status: DownloadStatus.queued,
      progress: 0,
      receivedBytes: 0,
      error: null,
    );
    await _persist();
    notifyListeners();
    unawaited(_pumpQueue());
  }

  Future<void> _pumpQueue() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        _runningIds.removeWhere((id) {
          final i = _items.indexWhere((e) => e.id == id);
          if (i < 0) return true;
          final st = _items[i].status;
          return st != DownloadStatus.downloading &&
              st != DownloadStatus.converting;
        });

        final slots = maxConcurrent - _runningIds.length;
        if (slots <= 0) break;

        final queued = _items
            .where((e) =>
                e.status == DownloadStatus.queued &&
                !_runningIds.contains(e.id))
            .take(slots)
            .toList();
        if (queued.isEmpty) break;

        for (final item in queued) {
          _runningIds.add(item.id);
          unawaited(_runOne(item).whenComplete(() {
            _runningIds.remove(item.id);
            unawaited(_pumpQueue());
          }));
        }
        break;
      }
    } finally {
      _pumping = false;
      await _notifyNative(hide: active.isEmpty);
    }
  }

  Future<Directory> _baseDir() async {
    Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }
    final d = Directory('${dir.path}/lol_downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _runOne(DownloadItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) return;
    _cancelFlags[item.id] = false;
    _items[idx] = item.copyWith(status: DownloadStatus.downloading);
    await _persist();
    notifyListeners();
    await _notifyNative();

    try {
      final base = await _baseDir();
      final safe = item.title.replaceAll(RegExp(r'[^\w\s\-\.]'), '_').trim();
      final folder = Directory('${base.path}/${item.id}_$safe');
      if (!await folder.exists()) await folder.create(recursive: true);

      // Metadatos JSON
      final metaFile = File('${folder.path}/meta.json');
      await metaFile.writeAsString(jsonEncode({
        'title': item.title,
        'poster': item.poster,
        'repoId': item.repoId,
        'repoName': item.repoName,
        'contentId': item.contentId,
        'type': item.type,
        'season': item.season,
        'episode': item.episode,
        'episodeTitle': item.episodeTitle,
        'serverName': item.serverName,
        'quality': item.quality,
      }));

      // Poster
      if (item.poster != null && item.poster!.startsWith('http')) {
        try {
          final r = await http.get(Uri.parse(item.poster!)).timeout(const Duration(seconds: 15));
          if (r.statusCode == 200) {
            await File('${folder.path}/poster.jpg').writeAsBytes(r.bodyBytes);
          }
        } catch (_) {}
      }

      String? videoPath;
      if (item.kind == DownloadKind.hls) {
        videoPath = await _downloadHls(item, folder);
      } else {
        videoPath = await _downloadProgressive(item, folder);
      }

      if (_cancelFlags[item.id] == true) {
        final i2 = _items.indexWhere((e) => e.id == item.id);
        if (i2 >= 0) {
          _items[i2] = _items[i2].copyWith(status: DownloadStatus.cancelled);
          await _persist();
          notifyListeners();
        }
        return;
      }

      // Subtítulos
      final subsOut = <SubtitleDownload>[];
      for (var s = 0; s < item.subtitles.length; s++) {
        final sub = item.subtitles[s];
        try {
          final r = await http.get(Uri.parse(sub.url), headers: item.headers)
              .timeout(const Duration(seconds: 20));
          if (r.statusCode == 200) {
            final ext = sub.url.contains('.vtt')
                ? 'vtt'
                : (sub.url.contains('.srt') ? 'srt' : 'txt');
            final path = '${folder.path}/sub_$s.${sub.lang}.$ext';
            await File(path).writeAsBytes(r.bodyBytes);
            subsOut.add(SubtitleDownload(
              lang: sub.lang,
              label: sub.label,
              url: sub.url,
              localPath: path,
            ));
          }
        } catch (_) {}
      }

      // Siempre convertir a MKV (desktop/ffmpeg o canal nativo) para reproducción continua
      var finalPath = videoPath;
      if (videoPath != null && !kIsWeb) {
        final i3 = _items.indexWhere((e) => e.id == item.id);
        if (i3 >= 0) {
          _items[i3] = _items[i3].copyWith(status: DownloadStatus.converting);
          notifyListeners();
          await _notifyNative();
        }
        try {
          final mkv = await _convertToMkv(
            inputPath: videoPath,
            folder: folder,
            title: item.displayTitle,
            subtitles: subsOut,
          );
          if (mkv != null && mkv.isNotEmpty) {
            finalPath = mkv;
            // Limpiar temporales (ts, m3u8, segmentos, subs sueltos)
            await _cleanupAfterMkv(folder, keepPath: mkv);
          }
        } catch (e) {
          debugPrint('[Download] convert MKV: $e');
        }
      }

      final i4 = _items.indexWhere((e) => e.id == item.id);
      if (i4 >= 0) {
        final done = _items[i4].copyWith(
          status: DownloadStatus.completed,
          progress: 1,
          localPath: finalPath,
        );
        _items[i4] = done;
        await _persist();
        notifyListeners();
        await _notifyNative();
      }
    } catch (e) {
      debugPrint('[Download] error ${item.id}: $e');
      final i5 = _items.indexWhere((e) => e.id == item.id);
      if (i5 >= 0 && _cancelFlags[item.id] != true) {
        _items[i5] = _items[i5].copyWith(
          status: DownloadStatus.failed,
          error: e.toString(),
        );
        await _persist();
        notifyListeners();
        await _notifyNative();
      }
    }
  }

  Future<String> _downloadProgressive(DownloadItem item, Directory folder) async {
    final client = http.Client();
    _clients[item.id] = client;
    try {
      final ext = _extFromUrl(item.url, item.kind);
      final out = File('${folder.path}/video.$ext');
      final threads = maxParallel.clamp(1, 8);

      // 1) Descubrir tamaño y soporte de Range (HEAD o GET bytes=0-0)
      int? totalBytes;
      var acceptsRanges = false;
      try {
        final head = await client
            .head(Uri.parse(item.url), headers: item.headers)
            .timeout(const Duration(seconds: 12));
        if (head.statusCode >= 200 && head.statusCode < 400) {
          totalBytes = int.tryParse(head.headers['content-length'] ?? '');
          final ar = (head.headers['accept-ranges'] ?? '').toLowerCase();
          acceptsRanges = ar.contains('bytes');
        }
      } catch (_) {}
      if (totalBytes == null || totalBytes <= 0 || !acceptsRanges) {
        try {
          final probe = http.Request('GET', Uri.parse(item.url));
          item.headers.forEach((k, v) => probe.headers[k] = v);
          probe.headers['Range'] = 'bytes=0-0';
          final pr = await client.send(probe).timeout(const Duration(seconds: 12));
          if (pr.statusCode == 206) {
            acceptsRanges = true;
            final cr = pr.headers['content-range']; // bytes 0-0/123456
            final m = RegExp(r'/(\d+)\s*$').firstMatch(cr ?? '');
            if (m != null) totalBytes = int.tryParse(m.group(1)!);
          }
          // drenar cuerpo
          await pr.stream.drain();
        } catch (_) {}
      }

      // 2) Multi-hilo por rangos (igual idea que segmentos HLS)
      if (threads > 1 &&
          acceptsRanges &&
          totalBytes != null &&
          totalBytes > 256 * 1024) {
        return await _downloadProgressiveMulti(
          item: item,
          client: client,
          out: out,
          totalBytes: totalBytes,
          threads: threads,
        );
      }

      // 3) Fallback single-stream (resume con Range si hay parcial)
      var existing = 0;
      if (await out.exists()) {
        existing = await out.length();
      }
      final req = http.Request('GET', Uri.parse(item.url));
      item.headers.forEach((k, v) => req.headers[k] = v);
      if (existing > 0) {
        req.headers['Range'] = 'bytes=$existing-';
      }
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode == 416) {
        return out.path;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final total = (res.contentLength != null && res.statusCode == 206)
          ? existing + res.contentLength!
          : (res.contentLength ?? totalBytes ?? item.totalBytes);
      final sink =
          out.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      var received = existing;
      await for (final chunk in res.stream) {
        if (_cancelFlags[item.id] == true) break;
        sink.add(chunk);
        received += chunk.length;
        final i = _items.indexWhere((e) => e.id == item.id);
        if (i >= 0) {
          final p = total != null && total > 0 ? received / total : 0.0;
          _items[i] = _items[i].copyWith(
            progress: p.clamp(0.0, 0.99),
            receivedBytes: received,
            totalBytes: total,
          );
          _recordSpeed(item.id, received);
          if (received % (256 * 1024) < chunk.length) {
            notifyListeners();
            unawaited(_notifyNative());
          }
        }
      }
      await sink.flush();
      await sink.close();
      if (_cancelFlags[item.id] == true) {
        throw Exception('Cancelado');
      }
      return out.path;
    } finally {
      client.close();
      _clients.remove(item.id);
    }
  }

  /// Descarga progressive/.ts en paralelo por rangos HTTP (N hilos).
  Future<String> _downloadProgressiveMulti({
    required DownloadItem item,
    required http.Client client,
    required File out,
    required int totalBytes,
    required int threads,
  }) async {
    final partDir = Directory('${out.parent.path}/parts');
    if (!await partDir.exists()) await partDir.create(recursive: true);

    final chunkSize = (totalBytes / threads).ceil();
    final ranges = <(int, int)>[]; // inclusive start-end
    for (var t = 0; t < threads; t++) {
      final start = t * chunkSize;
      if (start >= totalBytes) break;
      final end = min((start + chunkSize - 1), totalBytes - 1);
      ranges.add((start, end));
    }

    var received = 0;
    final partReceived = List<int>.filled(ranges.length, 0);

    Future<void> downloadPart(int idx) async {
      final start = ranges[idx].$1;
      final end = ranges[idx].$2;
      final partFile = File('${partDir.path}/part_$idx.bin');
      var already = 0;
      if (await partFile.exists()) {
        already = await partFile.length();
        final expected = end - start + 1;
        if (already >= expected) {
          partReceived[idx] = expected;
          received += expected;
          return;
        }
      }
      // Reintentos por parte
      for (var attempt = 0; attempt < 3; attempt++) {
        if (_cancelFlags[item.id] == true) return;
        try {
          final req = http.Request('GET', Uri.parse(item.url));
          item.headers.forEach((k, v) => req.headers[k] = v);
          final from = start + already;
          req.headers['Range'] = 'bytes=$from-$end';
          final res =
              await client.send(req).timeout(const Duration(seconds: 45));
          if (res.statusCode != 206 && res.statusCode != 200) {
            throw Exception('HTTP ${res.statusCode} part $idx');
          }
          final sink = partFile.openWrite(
              mode: already > 0 ? FileMode.append : FileMode.write);
          var local = already;
          await for (final chunk in res.stream) {
            if (_cancelFlags[item.id] == true) break;
            sink.add(chunk);
            local += chunk.length;
            final delta = local - partReceived[idx];
            if (delta > 0) {
              received += delta;
              partReceived[idx] = local;
            }
            final i = _items.indexWhere((e) => e.id == item.id);
            if (i >= 0) {
              final p = received / totalBytes;
              _items[i] = _items[i].copyWith(
                progress: p.clamp(0.0, 0.99),
                receivedBytes: received,
                totalBytes: totalBytes,
              );
              _recordSpeed(item.id, received);
              if (received % (512 * 1024) < chunk.length) {
                notifyListeners();
                unawaited(_notifyNative());
              }
            }
          }
          await sink.flush();
          await sink.close();
          final expected = end - start + 1;
          if (local >= expected) return;
          already = local;
        } catch (e) {
          if (attempt == 2) rethrow;
          await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
        }
      }
    }

    await Future.wait(List.generate(ranges.length, (i) => downloadPart(i)));
    if (_cancelFlags[item.id] == true) throw Exception('Cancelado');

    // Ensamblar partes en orden
    final sink = out.openWrite(mode: FileMode.write);
    try {
      for (var i = 0; i < ranges.length; i++) {
        final partFile = File('${partDir.path}/part_$i.bin');
        if (!await partFile.exists()) {
          throw Exception('Falta parte $i');
        }
        await sink.addStream(partFile.openRead());
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    // Limpiar partes
    try {
      await partDir.delete(recursive: true);
    } catch (_) {}

    final i = _items.indexWhere((e) => e.id == item.id);
    if (i >= 0) {
      _items[i] = _items[i].copyWith(
        progress: 0.99,
        receivedBytes: totalBytes,
        totalBytes: totalBytes,
      );
      notifyListeners();
    }
    return out.path;
  }

  Future<String> _downloadHls(DownloadItem item, Directory folder) async {
    // 1) Descargar playlist
    final playlistRes = await http
        .get(Uri.parse(item.url), headers: item.headers)
        .timeout(const Duration(seconds: 20));
    if (playlistRes.statusCode != 200) {
      throw Exception('No se pudo leer el m3u8 (${playlistRes.statusCode})');
    }
    var body = playlistRes.body;
    final baseUri = Uri.parse(item.url);

    // Master playlist → elegir la variante de mayor BANDWIDTH
    if (body.contains('#EXT-X-STREAM-INF')) {
      final lines = body.split('\n');
      String? bestUrl;
      var bestBw = -1;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
          final bw = int.tryParse(bwMatch?.group(1) ?? '') ?? 0;
          final next = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
          if (next.isNotEmpty && !next.startsWith('#') && bw >= bestBw) {
            bestBw = bw;
            bestUrl = next;
          }
        }
      }
      if (bestUrl != null) {
        final variantUri = bestUrl.startsWith('http')
            ? Uri.parse(bestUrl)
            : baseUri.resolve(bestUrl);
        final vRes = await http
            .get(variantUri, headers: item.headers)
            .timeout(const Duration(seconds: 20));
        if (vRes.statusCode == 200) {
          body = vRes.body;
          // actualizar base
          final segFolder = Directory('${folder.path}/hls');
          if (!await segFolder.exists()) await segFolder.create(recursive: true);
          return _downloadHlsSegments(item, body, variantUri, segFolder);
        }
      }
    }

    final segFolder = Directory('${folder.path}/hls');
    if (!await segFolder.exists()) await segFolder.create(recursive: true);
    return _downloadHlsSegments(item, body, baseUri, segFolder);
  }

  Future<String> _downloadHlsSegments(
    DownloadItem item,
    String playlistBody,
    Uri baseUri,
    Directory segFolder,
  ) async {
    final lines = playlistBody.split('\n');
    final segmentUrls = <String>[];
    final segmentDurations = <double>[];
    double? pendingDur;
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#EXTINF:')) {
        final m = RegExp(r'#EXTINF:([\d.]+)').firstMatch(t);
        pendingDur = double.tryParse(m?.group(1) ?? '') ?? 6.0;
        continue;
      }
      if (t.startsWith('#')) continue;
      segmentUrls.add(t.startsWith('http') ? t : baseUri.resolve(t).toString());
      segmentDurations.add(pendingDur ?? 6.0);
      pendingDur = null;
    }
    if (segmentUrls.isEmpty) throw Exception('Playlist HLS sin segmentos');

    final total = segmentUrls.length;
    final names = List<String>.generate(
        total, (i) => 'seg_${i.toString().padLeft(5, '0')}.ts');
    var done = 0;
    var received = 0;
    final threads = maxParallel.clamp(1, 8);

    // Cliente compartido: reutiliza conexiones TCP → más hilos = más velocidad real.
    final client = http.Client();
    _clients[item.id] = client;

    Future<void> downloadOne(int i) async {
      if (_cancelFlags[item.id] == true) return;
      final file = File('${segFolder.path}/${names[i]}');
      if (await file.exists() && await file.length() > 0) {
        received += await file.length();
        done++;
        return;
      }
      for (var attempt = 0; attempt < 3; attempt++) {
        if (_cancelFlags[item.id] == true) return;
        try {
          final r = await client
              .get(Uri.parse(segmentUrls[i]), headers: item.headers)
              .timeout(const Duration(seconds: 25));
          if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
            await file.writeAsBytes(r.bodyBytes);
            received += r.bodyBytes.length;
            break;
          }
        } catch (_) {
          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          }
        }
      }
      done++;
      final idx = _items.indexWhere((e) => e.id == item.id);
      if (idx >= 0) {
        _items[idx] = _items[idx].copyWith(
          progress: (done / total).clamp(0.0, 0.99),
          receivedBytes: received,
        );
        _recordSpeed(item.id, received);
        if (done % threads == 0 || done == total) {
          notifyListeners();
          unawaited(_notifyNative());
        }
      }
    }

    // Pool de trabajadores concurrentes (índice síncrono, sin race en Dart).
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (_cancelFlags[item.id] == true) return;
        final i = next;
        next++;
        if (i >= total) return;
        await downloadOne(i);
      }
    }

    try {
      await Future.wait(List.generate(threads, (_) => worker()));
    } finally {
      client.close();
      _clients.remove(item.id);
    }
    if (_cancelFlags[item.id] == true) throw Exception('Cancelado');

    // Playlist local con duraciones REALES (para que el player muestre tiempo total correcto)
    final localPlaylist = StringBuffer();
    localPlaylist.writeln('#EXTM3U');
    localPlaylist.writeln('#EXT-X-VERSION:3');
    localPlaylist.writeln('#EXT-X-TARGETDURATION:${(segmentDurations.fold<double>(0, (a, b) => a > b ? a : b).ceil()).clamp(1, 60)}');
    localPlaylist.writeln('#EXT-X-MEDIA-SEQUENCE:0');
    localPlaylist.writeln('#EXT-X-PLAYLIST-TYPE:VOD');
    for (var i = 0; i < total; i++) {
      final f = File('${segFolder.path}/${names[i]}');
      if (await f.exists()) {
        final dur = i < segmentDurations.length ? segmentDurations[i] : 6.0;
        localPlaylist.writeln('#EXTINF:${dur.toStringAsFixed(3)},');
        localPlaylist.writeln(names[i]);
      }
    }
    localPlaylist.writeln('#EXT-X-ENDLIST');
    final pl = File('${segFolder.path}/index.m3u8');
    await pl.writeAsString(localPlaylist.toString());

    // Unificar segmentos .ts en un solo archivo (mejor para el player: duración total continua)
    try {
      final merged = File('${segFolder.parent.path}/video.ts');
      final sink = merged.openWrite();
      for (var i = 0; i < total; i++) {
        final f = File('${segFolder.path}/${names[i]}');
        if (await f.exists()) {
          await sink.addStream(f.openRead());
        }
      }
      await sink.flush();
      await sink.close();
      if (await merged.exists() && await merged.length() > 0) {
        // Preferir el archivo unificado
        return merged.path;
      }
    } catch (e) {
      debugPrint('[Download] merge TS skip: $e');
    }

    return pl.path;
  }

  String _extFromUrl(String url, DownloadKind kind) {
    final u = url.toLowerCase().split('?').first;
    if (u.endsWith('.mp4')) return 'mp4';
    if (u.endsWith('.mkv')) return 'mkv';
    if (u.endsWith('.webm')) return 'webm';
    if (u.endsWith('.ts') || kind == DownloadKind.ts) return 'ts';
    if (kind == DownloadKind.hls) return 'm3u8';
    return 'mp4';
  }

  /// Estima tamaño: HEAD Content-Length, o para HLS suma de segmentos / bandwidth.
  static Future<int?> estimateSize(String url, Map<String, String> headers) async {
    try {
      final res = await http.head(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 400) {
        final cl = res.headers['content-length'];
        if (cl != null) {
          final n = int.tryParse(cl);
          if (n != null && n > 0) return n;
        }
      }
    } catch (_) {}

    // HLS: leer playlist
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) {
      try {
        final res = await http
            .get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) return null;
        final body = res.body;
        final base = Uri.parse(url);

        // Master: estimar por BANDWIDTH * duración aprox
        if (body.contains('#EXT-X-STREAM-INF')) {
          var bestBw = 0;
          final lines = body.split('\n');
          for (final line in lines) {
            if (line.contains('BANDWIDTH=')) {
              final m = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
              final bw = int.tryParse(m?.group(1) ?? '') ?? 0;
              if (bw > bestBw) bestBw = bw;
            }
          }
          // ~45 min típico si no hay duración; 45*60*bw/8
          if (bestBw > 0) return (bestBw / 8 * 45 * 60).round();
        }

        // Media playlist: sumar EXTINF y HEAD del primer segmento * n
        final segUrls = <String>[];
        double duration = 0;
        final lines = body.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final t = lines[i].trim();
          if (t.startsWith('#EXTINF:')) {
            final m = RegExp(r'#EXTINF:([\d.]+)').firstMatch(t);
            duration += double.tryParse(m?.group(1) ?? '') ?? 0;
          } else if (t.isNotEmpty && !t.startsWith('#')) {
            segUrls.add(t.startsWith('http') ? t : base.resolve(t).toString());
          }
        }
        if (segUrls.isEmpty) return null;
        // HEAD del primer segmento
        int? one;
        try {
          final h = await http
              .head(Uri.parse(segUrls.first), headers: headers)
              .timeout(const Duration(seconds: 6));
          final cl = h.headers['content-length'];
          if (cl != null) one = int.tryParse(cl);
        } catch (_) {}
        if (one != null && one > 0) return one * segUrls.length;
        // fallback bandwidth-ish: 2.5 Mbps * duration
        if (duration > 0) return (2.5 * 1000 * 1000 / 8 * duration).round();
      } catch (_) {}
    }
    return null;
  }

  Future<void> _notifyNative({bool hide = false}) async {
    try {
      if (hide) {
        await _channel.invokeMethod('hide');
        return;
      }
      final activeItems = active;
      if (activeItems.isEmpty) {
        await _channel.invokeMethod('hide');
        return;
      }
      final cur = activeItems.first;
      await _channel.invokeMethod('update', {
        'title': cur.displayTitle,
        'progress': (cur.progress * 100).round(),
        'status': cur.status.name,
        'count': activeItems.length,
        'repo': cur.repoName,
        'soft': softToast,
      });
    } catch (e) {
      debugPrint('[Download] notif: $e');
    }
  }

  /// Espacio ocupado por todas las descargas (bytes).
  Future<int> usedDownloadBytes() async {
    try {
      final base = await _baseDir();
      if (!await base.exists()) return 0;
      var total = 0;
      await for (final e in base.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Intenta obtener espacio libre del almacenamiento de la app (bytes).
  /// En plataformas sin soporte retorna null.
  Future<int?> freeSpaceBytes() async {
    try {
      // Intento nativo (si el canal lo implementa)
      final v = await _channel.invokeMethod<int>('freeSpace');
      if (v != null && v > 0) return v;
    } catch (_) {}
    try {
      final base = await _baseDir();
      // Fallback: en Linux/desktop a veces StatVFS; en Android limitado.
      // Reportamos null si no hay dato fiable.
      if (Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('df', ['-B1', base.path]);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).trim().split('\n');
          if (lines.length >= 2) {
            final parts = lines.last.trim().split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              return int.tryParse(parts[3]);
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Convierte video (+ subs externos) a un único .mkv con ffmpeg.
  Future<String?> _convertToMkv({
    required String inputPath,
    required Directory folder,
    required String title,
    List<SubtitleDownload> subtitles = const [],
  }) async {
    final safe = title.replaceAll(RegExp(r'[^\w\s\-\.]'), '_').trim();
    final outPath = '${folder.path}/${safe.isEmpty ? 'video' : safe}.mkv';

    // Ya es mkv usable
    if (inputPath.toLowerCase().endsWith('.mkv') &&
        File(inputPath).existsSync() &&
        inputPath != outPath) {
      try {
        await File(inputPath).copy(outPath);
        return outPath;
      } catch (_) {
        return inputPath;
      }
    }
    if (inputPath.toLowerCase().endsWith('.mkv') && inputPath == outPath) {
      return outPath;
    }

    // 1) Intent nativo Android
    if (Platform.isAndroid) {
      try {
        final out = await _channel.invokeMethod<String>('convert', {
          'input': inputPath,
          'kind': 'mkv',
          'outputDir': folder.path,
          'title': title,
          'subtitles': subtitles
              .where((s) => s.localPath != null)
              .map((s) => {
                    'path': s.localPath,
                    'lang': s.lang,
                    'label': s.label,
                  })
              .toList(),
        });
        if (out != null && out.isNotEmpty && File(out).existsSync()) return out;
      } catch (e) {
        debugPrint('[Download] native convert: $e');
      }
    }

    // 2) ffmpeg en PATH (desktop)
    final ffmpeg = await _findFfmpeg();
    if (ffmpeg == null) {
      debugPrint('[Download] ffmpeg no encontrado; se deja archivo original');
      return null;
    }

    final args = <String>['-y', '-hide_banner', '-loglevel', 'error'];

    // Input principal
    final lower = inputPath.toLowerCase();
    if (lower.endsWith('.m3u8')) {
      // Playlist local
      args.addAll(['-allowed_extensions', 'ALL', '-i', inputPath]);
    } else {
      args.addAll(['-i', inputPath]);
    }

    // Subtítulos externos como pistas
    final subFiles = <SubtitleDownload>[];
    for (final s in subtitles) {
      final sp = s.localPath;
      if (sp != null && File(sp).existsSync()) {
        args.addAll(['-i', sp]);
        subFiles.add(s);
      }
    }

    // Mapear streams: video+audio del input 0, subs de inputs siguientes
    args.addAll(['-map', '0:v?', '-map', '0:a?']);
    for (var i = 0; i < subFiles.length; i++) {
      args.addAll(['-map', '${i + 1}:0']);
    }

    // Códec: copy cuando sea posible (ts/mp4 → mkv)
    args.addAll(['-c', 'copy']);
    // Subs a srt/ass dentro del mkv
    if (subFiles.isNotEmpty) {
      args.addAll(['-c:s', 'srt']);
      for (var i = 0; i < subFiles.length; i++) {
        final lang = subFiles[i].lang;
        if (lang.isNotEmpty) {
          args.addAll(['-metadata:s:s:$i', 'language=$lang']);
        }
        final label = subFiles[i].label;
        if (label.isNotEmpty) {
          args.addAll(['-metadata:s:s:$i', 'title=$label']);
        }
      }
    }

    // Algunos TS necesitan bitstream filter al pasar a mp4; en mkv copy suele bastar
    args.add(outPath);

    try {
      debugPrint('[Download] ffmpeg ${args.join(' ')}');
      final r = await Process.run(ffmpeg, args, workingDirectory: folder.path)
          .timeout(const Duration(minutes: 45));
      if (r.exitCode == 0 && File(outPath).existsSync() && File(outPath).lengthSync() > 0) {
        return outPath;
      }
      debugPrint('[Download] ffmpeg exit=${r.exitCode} stderr=${r.stderr}');
      // Reintento re-encode video si copy falla (incluye subtítulos)
      final args2 = <String>[
        '-y', '-hide_banner', '-loglevel', 'error',
        if (lower.endsWith('.m3u8')) ...['-allowed_extensions', 'ALL'],
        '-i', inputPath,
      ];
      for (final s in subFiles) {
        args2.addAll(['-i', s.localPath!]);
      }
      args2.addAll(['-map', '0:v?', '-map', '0:a?']);
      for (var i = 0; i < subFiles.length; i++) {
        args2.addAll(['-map', '${i + 1}:0']);
      }
      args2.addAll([
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
        '-c:a', 'aac', '-b:a', '192k',
      ]);
      if (subFiles.isNotEmpty) {
        args2.addAll(['-c:s', 'srt']);
        for (var i = 0; i < subFiles.length; i++) {
          final lang = subFiles[i].lang;
          if (lang.isNotEmpty) {
            args2.addAll(['-metadata:s:s:$i', 'language=$lang']);
          }
          final label = subFiles[i].label;
          if (label.isNotEmpty) {
            args2.addAll(['-metadata:s:s:$i', 'title=$label']);
          }
        }
      }
      args2.add(outPath);
      final r2 = await Process.run(ffmpeg, args2, workingDirectory: folder.path)
          .timeout(const Duration(minutes: 90));
      if (r2.exitCode == 0 && File(outPath).existsSync()) return outPath;
      debugPrint('[Download] ffmpeg reencode fail: ${r2.stderr}');
    } catch (e) {
      debugPrint('[Download] ffmpeg error: $e');
    }
    return null;
  }

  Future<String?> _findFfmpeg() async {
    for (final name in ['ffmpeg', 'ffmpeg.exe']) {
      try {
        final r = await Process.run(name, ['-version']);
        if (r.exitCode == 0) return name;
      } catch (_) {}
    }
    // Rutas típicas Windows
    if (Platform.isWindows) {
      final candidates = [
        r'C:\ffmpeg\bin\ffmpeg.exe',
        r'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
    }
    return null;
  }

  /// Borra segmentos/ts/m3u8/subs sueltos; deja solo el mkv (+ poster opcional).
  Future<void> _cleanupAfterMkv(Directory folder, {required String keepPath}) async {
    try {
      final keep = File(keepPath).absolute.path;
      await for (final e in folder.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final p = e.absolute.path;
          if (p == keep) continue;
          final name = e.path.toLowerCase();
          if (name.endsWith('.mkv') && p != keep) {
            // otro mkv residual
            try { await e.delete(); } catch (_) {}
            continue;
          }
          if (name.endsWith('.ts') ||
              name.endsWith('.m3u8') ||
              name.endsWith('.mp4') ||
              name.endsWith('.txt') ||
              name.endsWith('meta.json')) {
            // Conservamos .srt/.vtt/.ass para el selector del player
            try { await e.delete(); } catch (_) {}
          }
        } else if (e is Directory) {
          // carpeta hls vacía
          try {
            final kids = await e.list().toList();
            if (kids.isEmpty) await e.delete();
          } catch (_) {}
        }
      }
      // segundo paso: borrar dirs hls vacíos
      final hls = Directory('${folder.path}/hls');
      if (await hls.exists()) {
        try {
          await hls.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[Download] cleanup: $e');
    }
  }

  /// Árbol de archivos de descargas para el modal de espacio.
  Future<List<Map<String, dynamic>>> listDownloadTree() async {
    final out = <Map<String, dynamic>>[];
    try {
      final base = await _baseDir();
      if (!await base.exists()) return out;
      await for (final e in base.list(followLinks: false)) {
        if (e is Directory) {
          var size = 0;
          final files = <Map<String, dynamic>>[];
          await for (final f in e.list(recursive: true, followLinks: false)) {
            if (f is File) {
              try {
                final len = await f.length();
                size += len;
                files.add({
                  'path': f.path,
                  'name': f.uri.pathSegments.isNotEmpty
                      ? f.uri.pathSegments.last
                      : f.path,
                  'size': len,
                });
              } catch (_) {}
            }
          }
          out.add({
            'path': e.path,
            'name': e.uri.pathSegments.where((s) => s.isNotEmpty).isNotEmpty
                ? e.uri.pathSegments.where((s) => s.isNotEmpty).last
                : e.path,
            'size': size,
            'files': files,
          });
        } else if (e is File) {
          try {
            final len = await e.length();
            out.add({
              'path': e.path,
              'name': e.uri.pathSegments.last,
              'size': len,
              'files': [
                {'path': e.path, 'name': e.uri.pathSegments.last, 'size': len}
              ],
            });
          } catch (_) {}
        }
      }
      out.sort((a, b) => (b['size'] as int).compareTo(a['size'] as int));
    } catch (e) {
      debugPrint('[Download] listTree: $e');
    }
    return out;
  }

  Future<void> deleteDownloadFolder(String path) async {
    try {
      final d = Directory(path);
      if (await d.exists()) {
        await d.delete(recursive: true);
      } else {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
      // Quitar items cuyo localPath esté bajo esa carpeta
      _items.removeWhere((it) {
        final lp = it.localPath;
        if (lp == null) return false;
        return lp == path || lp.startsWith('$path${Platform.pathSeparator}') || lp.startsWith('$path/');
      });
      await _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('[Download] delete folder: $e');
    }
  }

  Future<String> downloadsRootPath() async {
    final d = await _baseDir();
    return d.path;
  }

  Future<void> openDownloadsFolder([String? path]) async {
    final target = path ?? await downloadsRootPath();
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [target]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [target]);
      } else {
        await Process.run('xdg-open', [target]);
      }
    } catch (e) {
      debugPrint('[Download] open folder: $e');
    }
  }

  static String formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _SpeedSample {
  final DateTime at;
  final int bytes;
  final double bps;
  _SpeedSample(this.at, this.bytes, this.bps);
}
