import 'dart:convert';

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  converting,
  cancelled,
}

enum DownloadKind {
  progressive, // mp4, mkv, etc.
  hls, // m3u8 + segments
  ts, // MPEG-TS
}

/// Una descarga de película / episodio.
class DownloadItem {
  final String id;
  final String repoId;
  final String repoName;
  final String contentId;
  final String title;
  final String? poster;
  final String type; // movie | series | episode
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final String serverName;
  final String? quality;
  final String url;
  final Map<String, String> headers;
  final bool isHls;
  final List<SubtitleDownload> subtitles;
  final DownloadKind kind;
  final bool convertOnMobile; // HLS→MP4 / TS→MKV (solo móvil)
  DownloadStatus status;
  double progress; // 0..1
  int receivedBytes;
  int? totalBytes;
  String? localPath;
  String? error;
  final DateTime createdAt;
  DateTime? updatedAt;

  DownloadItem({
    required this.id,
    required this.repoId,
    required this.repoName,
    required this.contentId,
    required this.title,
    this.poster,
    this.type = 'movie',
    this.season,
    this.episode,
    this.episodeTitle,
    required this.serverName,
    this.quality,
    required this.url,
    this.headers = const {},
    this.isHls = false,
    this.subtitles = const [],
    this.kind = DownloadKind.progressive,
    this.convertOnMobile = false,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes,
    this.localPath,
    this.error,
    DateTime? createdAt,
    this.updatedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get displayTitle {
    if (season != null && episode != null) {
      final ep = episodeTitle != null && episodeTitle!.isNotEmpty
          ? ' · $episodeTitle'
          : '';
      return '$title · T$season E$episode$ep';
    }
    return title;
  }

  String get sizeLabel {
    if (totalBytes != null && totalBytes! > 0) {
      return _fmt(totalBytes!);
    }
    if (receivedBytes > 0) return _fmt(receivedBytes);
    return '—';
  }

  static String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'repoId': repoId,
        'repoName': repoName,
        'contentId': contentId,
        'title': title,
        if (poster != null) 'poster': poster,
        'type': type,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        if (episodeTitle != null) 'episodeTitle': episodeTitle,
        'serverName': serverName,
        if (quality != null) 'quality': quality,
        'url': url,
        'headers': headers,
        'isHls': isHls,
        'subtitles': subtitles.map((e) => e.toJson()).toList(),
        'kind': kind.name,
        'convertOnMobile': convertOnMobile,
        'status': status.name,
        'progress': progress,
        'receivedBytes': receivedBytes,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (localPath != null) 'localPath': localPath,
        if (error != null) 'error': error,
        'createdAt': createdAt.toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) {
    final subs = <SubtitleDownload>[];
    final raw = j['subtitles'];
    if (raw is List) {
      for (final s in raw) {
        if (s is Map) {
          subs.add(SubtitleDownload.fromJson(Map<String, dynamic>.from(s)));
        }
      }
    }
    DownloadKind kind = DownloadKind.progressive;
    final k = (j['kind'] ?? '').toString();
    if (k == 'hls') kind = DownloadKind.hls;
    if (k == 'ts') kind = DownloadKind.ts;

    DownloadStatus status = DownloadStatus.queued;
    final st = (j['status'] ?? '').toString();
    for (final v in DownloadStatus.values) {
      if (v.name == st) status = v;
    }

    final headers = <String, String>{};
    final h = j['headers'];
    if (h is Map) {
      h.forEach((k, v) {
        if (v != null) headers['$k'] = '$v';
      });
    }

    return DownloadItem(
      id: (j['id'] ?? '').toString(),
      repoId: (j['repoId'] ?? '').toString(),
      repoName: (j['repoName'] ?? '').toString(),
      contentId: (j['contentId'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      poster: j['poster']?.toString(),
      type: (j['type'] ?? 'movie').toString(),
      season: j['season'] is int ? j['season'] as int : int.tryParse('${j['season'] ?? ''}'),
      episode: j['episode'] is int ? j['episode'] as int : int.tryParse('${j['episode'] ?? ''}'),
      episodeTitle: j['episodeTitle']?.toString(),
      serverName: (j['serverName'] ?? 'Servidor').toString(),
      quality: j['quality']?.toString(),
      url: (j['url'] ?? '').toString(),
      headers: headers,
      isHls: j['isHls'] == true,
      subtitles: subs,
      kind: kind,
      convertOnMobile: j['convertOnMobile'] == true,
      status: status,
      progress: (j['progress'] as num?)?.toDouble() ?? 0,
      receivedBytes: (j['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (j['totalBytes'] as num?)?.toInt(),
      localPath: j['localPath']?.toString(),
      error: j['error']?.toString(),
      createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: j['updatedAt'] != null
          ? DateTime.tryParse(j['updatedAt'].toString())
          : null,
    );
  }

  DownloadItem copyWith({
    DownloadStatus? status,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? localPath,
    String? error,
    bool? convertOnMobile,
  }) {
    return DownloadItem(
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
      serverName: serverName,
      quality: quality,
      url: url,
      headers: headers,
      isHls: isHls,
      subtitles: subtitles,
      kind: kind,
      convertOnMobile: convertOnMobile ?? this.convertOnMobile,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      localPath: localPath ?? this.localPath,
      error: error ?? this.error,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

class SubtitleDownload {
  final String lang;
  final String label;
  final String url;
  String? localPath;

  SubtitleDownload({
    required this.lang,
    required this.label,
    required this.url,
    this.localPath,
  });

  Map<String, dynamic> toJson() => {
        'lang': lang,
        'label': label,
        'url': url,
        if (localPath != null) 'localPath': localPath,
      };

  factory SubtitleDownload.fromJson(Map<String, dynamic> j) => SubtitleDownload(
        lang: (j['lang'] ?? 'und').toString(),
        label: (j['label'] ?? 'Sub').toString(),
        url: (j['url'] ?? '').toString(),
        localPath: j['localPath']?.toString(),
      );
}

/// Opción de calidad mostrada en el modal (con tamaño estimado).
class DownloadQualityOption {
  final String label;
  final String url;
  final String? quality;
  final int? estimatedBytes;
  final Map<String, String> headers;
  final bool isHls;
  final List<SubtitleDownload> subtitles;
  final String serverName;

  const DownloadQualityOption({
    required this.label,
    required this.url,
    this.quality,
    this.estimatedBytes,
    this.headers = const {},
    this.isHls = false,
    this.subtitles = const [],
    required this.serverName,
  });

  String get sizeLabel {
    if (estimatedBytes == null || estimatedBytes! <= 0) return 'Tamaño desconocido';
    final b = estimatedBytes!;
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
