/// Subtítulo externo que puede devolver el repo junto a un StreamServer.
class ExternalSubtitle {
  final String lang;
  final String label;
  final String url;
  final String? format; // vtt | srt | ass

  const ExternalSubtitle({
    required this.lang,
    required this.label,
    required this.url,
    this.format,
  });

  factory ExternalSubtitle.fromJson(Map<String, dynamic> j) {
    final url = (j['url'] ?? j['src'] ?? j['file'] ?? '').toString();
    final lang =
        (j['lang'] ?? j['language'] ?? j['idioma'] ?? j['code'] ?? 'und')
            .toString();
    final label = (j['label'] ?? j['name'] ?? j['title'] ?? lang).toString();
    String? format = j['format']?.toString() ?? j['type']?.toString();
    if (format == null || format.isEmpty) {
      final lower = url.toLowerCase();
      if (lower.contains('.vtt')) {
        format = 'vtt';
      } else if (lower.contains('.srt')) {
        format = 'srt';
      } else if (lower.contains('.ass') || lower.contains('.ssa')) {
        format = 'ass';
      }
    }
    return ExternalSubtitle(
        lang: lang, label: label, url: url, format: format);
  }

  Map<String, dynamic> toJson() => {
        'lang': lang,
        'label': label,
        'url': url,
        if (format != null) 'format': format,
      };
}

/// Pista de audio externa / alternativa descrita por el repo.
class ExternalAudioTrack {
  final String lang;
  final String label;
  final String? url;
  final int? index;

  const ExternalAudioTrack({
    required this.lang,
    required this.label,
    this.url,
    this.index,
  });

  factory ExternalAudioTrack.fromJson(Map<String, dynamic> j) {
    return ExternalAudioTrack(
      lang: (j['lang'] ?? j['language'] ?? j['idioma'] ?? j['code'] ?? 'und')
          .toString(),
      label: (j['label'] ?? j['name'] ?? j['title'] ?? 'Audio').toString(),
      url: (j['url'] ?? j['src'])?.toString(),
      index: (j['index'] as num?)?.toInt() ?? (j['id'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'lang': lang,
        'label': label,
        if (url != null) 'url': url,
        if (index != null) 'index': index,
      };
}

/// Segmentos de tiempo (skip intro / outro) en segundos.
class StreamSegments {
  final List<int>? intro; // [start, end]
  final List<int>? outro;

  const StreamSegments({this.intro, this.outro});

  factory StreamSegments.fromJson(dynamic raw) {
    if (raw is! Map) return const StreamSegments();
    List<int>? parseRange(dynamic v) {
      if (v is List && v.length >= 2) {
        final a =
            (v[0] is num) ? (v[0] as num).toInt() : int.tryParse('${v[0]}');
        final b =
            (v[1] is num) ? (v[1] as num).toInt() : int.tryParse('${v[1]}');
        if (a != null && b != null && b > a) return [a, b];
      }
      return null;
    }

    return StreamSegments(
      intro: parseRange(raw['intro'] ?? raw['skipIntro'] ?? raw['opening']),
      outro: parseRange(
          raw['outro'] ?? raw['skipOutro'] ?? raw['ending'] ?? raw['credits']),
    );
  }

  Map<String, dynamic> toJson() => {
        if (intro != null) 'intro': intro,
        if (outro != null) 'outro': outro,
      };

  bool get hasAny =>
      (intro != null && intro!.length >= 2) ||
      (outro != null && outro!.length >= 2);
}

/// Servidor de reproducción que devuelve el repo (como addons de lolapp).
class StreamServer {
  final String url;
  final String name;
  final String? quality;
  final String? language; // es, es_MX, en, lat...
  final String? provider;
  final Map<String, String> headers;
  final bool isHls;
  final String? infoHash; // torrents opcionales
  final List<ExternalSubtitle> subtitles;
  final List<ExternalAudioTrack> tracks;
  final StreamSegments? segments;
  final Map<String, dynamic> extra;

  const StreamServer({
    required this.url,
    required this.name,
    this.quality,
    this.language,
    this.provider,
    this.headers = const {},
    this.isHls = false,
    this.infoHash,
    this.subtitles = const [],
    this.tracks = const [],
    this.segments,
    this.extra = const {},
  });

  factory StreamServer.fromJson(Map<String, dynamic> j) {
    final headers = <String, String>{};
    final h = j['headers'] ?? j['httpHeaders'] ?? j['requestHeaders'];
    if (h is Map) {
      h.forEach((k, v) {
        if (v != null) headers['$k'] = '$v';
      });
    }
    // behaviorHints.proxyHeaders.request (estilo Stremio/lol)
    final hints = j['behaviorHints'];
    if (hints is Map) {
      final proxy = hints['proxyHeaders'];
      if (proxy is Map) {
        final req = proxy['request'];
        if (req is Map) {
          req.forEach((k, v) {
            if (v != null) headers['$k'] = '$v';
          });
        }
      }
    }
    final url = (j['url'] ?? j['file'] ?? j['src'] ?? '').toString();
    final isHls = j['isHls'] == true ||
        url.contains('.m3u8') ||
        (j['type']?.toString().toLowerCase().contains('hls') ?? false);

    final subtitles = <ExternalSubtitle>[];
    final rawSubs = j['subtitles'] ?? j['subs'] ?? j['captions'];
    if (rawSubs is List) {
      for (final s in rawSubs) {
        if (s is Map) {
          final sub = ExternalSubtitle.fromJson(Map<String, dynamic>.from(s));
          if (sub.url.isNotEmpty) subtitles.add(sub);
        } else if (s is String && s.isNotEmpty) {
          subtitles
              .add(ExternalSubtitle(lang: 'und', label: 'Subtítulo', url: s));
        }
      }
    }

    final tracks = <ExternalAudioTrack>[];
    final rawTracks = j['tracks'] ?? j['audioTracks'] ?? j['audios'];
    if (rawTracks is List) {
      for (final t in rawTracks) {
        if (t is Map) {
          tracks.add(ExternalAudioTrack.fromJson(Map<String, dynamic>.from(t)));
        }
      }
    }

    StreamSegments? segments;
    final rawSeg = j['segments'] ?? j['skip'] ?? j['markers'];
    if (rawSeg != null) {
      final seg = StreamSegments.fromJson(rawSeg);
      if (seg.hasAny) segments = seg;
    }

    return StreamServer(
      url: url,
      name: (j['name'] ?? j['title'] ?? j['provider'] ?? 'Servidor').toString(),
      quality: (j['quality'] ?? j['resolution'] ?? j['q'])?.toString(),
      language:
          (j['language'] ?? j['idioma'] ?? j['lang'] ?? j['audio'])?.toString(),
      provider: (j['provider'] ?? j['source'] ?? j['addon'])?.toString(),
      headers: headers,
      isHls: isHls,
      infoHash: j['infoHash']?.toString() ?? j['info_hash']?.toString(),
      subtitles: subtitles,
      tracks: tracks,
      segments: segments,
      extra: Map<String, dynamic>.from(j),
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        if (quality != null) 'quality': quality,
        if (language != null) 'language': language,
        if (provider != null) 'provider': provider,
        'headers': headers,
        'isHls': isHls,
        if (infoHash != null) 'infoHash': infoHash,
        if (subtitles.isNotEmpty)
          'subtitles': subtitles.map((e) => e.toJson()).toList(),
        if (tracks.isNotEmpty) 'tracks': tracks.map((e) => e.toJson()).toList(),
        if (segments != null) 'segments': segments!.toJson(),
      };

  String get label {
    final parts = <String>[name];
    if (quality != null && quality!.isNotEmpty) parts.add(quality!);
    if (language != null && language!.isNotEmpty) parts.add(language!);
    return parts.join(' · ');
  }
}
