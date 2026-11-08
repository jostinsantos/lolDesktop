/// Badges de calidad / fuente / audio + banderas de idioma para servidores.
library;

class StreamBadge {
  final String id;
  final String groupId;
  final String name;
  final String pattern;
  final String imageUrl;

  const StreamBadge({
    required this.id,
    required this.groupId,
    required this.name,
    required this.pattern,
    required this.imageUrl,
  });
}

class StreamLangInfo {
  final String label;
  final String? flagUrl; // null = sin bandera (SUB genérico)
  final String code; // lat, es, en, sub...

  const StreamLangInfo(this.label, this.flagUrl, this.code);
}

/// Elite-Badges (leonevz) + patrones estilo Stremio filters.
class StreamBadgeCatalog {
  StreamBadgeCatalog._();

  static const _base =
      'https://raw.githubusercontent.com/leonevz/Elite-Badges/main/Badges';

  static final List<StreamBadge> filters = [
    StreamBadge(id: 'remux', groupId: 'source', name: 'REMUX', pattern: r'(?i)\bremux\b', imageUrl: '$_base/remux.png'),
    StreamBadge(id: 'blu-ray-disc', groupId: 'source', name: 'Blu-ray Disc', pattern: r'(?i)\b(blu[\s._-]?ray|bluray|bdrip|bdremux)\b', imageUrl: '$_base/blu_ray_disc.png'),
    StreamBadge(id: 'webdl', groupId: 'source', name: 'WEB-DL', pattern: r'(?i)\b(web[\s._-]?dl|webdl)\b', imageUrl: '$_base/WEBDL_transparent_4x.png'),
    StreamBadge(id: 'webrip', groupId: 'source', name: 'WEBRip', pattern: r'(?i)\b(web[\s._-]?rip|webrip)\b', imageUrl: '$_base/WEBRip_transparent_4x.png'),
    StreamBadge(id: 'hdtv', groupId: 'source', name: 'HDTV', pattern: r'(?i)\bhdtv\b', imageUrl: '$_base/HDTV_transparent_4x.png'),
    StreamBadge(id: 'dvd-rip', groupId: 'source', name: 'DVD RIP', pattern: r'(?i)\b(dvd[\s._-]?rip|dvdrip)\b', imageUrl: '$_base/DVD_RIP_transparent_4x.png'),
    StreamBadge(id: '4k-ultra-hd', groupId: 'resolution', name: '4K Ultra HD', pattern: r'(?i)\b(4k|2160p?|uhd|ultra\s*hd)\b', imageUrl: '$_base/4k_ultra_hd.png'),
    StreamBadge(id: '1080p-full-hd', groupId: 'resolution', name: '1080p Full HD', pattern: r'(?i)\b(1080p?|fhd|full\s*hd)\b', imageUrl: '$_base/1080p_full_hd.png'),
    StreamBadge(id: '720p-hd', groupId: 'resolution', name: '720p HD', pattern: r'(?i)\b720p?\b', imageUrl: '$_base/720p_hd.png'),
    StreamBadge(id: '480p-sd', groupId: 'resolution', name: '480p SD', pattern: r'(?i)\b480p?\b', imageUrl: '$_base/480p_sd.png'),
    StreamBadge(id: 'dolby-vision', groupId: 'video-tech', name: 'Dolby Vision', pattern: r'(?i)\b(dolby\s*vision|dovi|\bdv\b)\b', imageUrl: '$_base/dolby_vision.png'),
    StreamBadge(id: 'hdr10-plus', groupId: 'video-tech', name: 'HDR10+', pattern: r'(?i)\b(hdr10\+|hdr10\s*plus|hdr\s*10\s*\+)', imageUrl: '$_base/hdr10_plus.png'),
    StreamBadge(id: 'hdr10', groupId: 'video-tech', name: 'HDR10', pattern: r'(?i)\b(hdr10|hdr\s*10)\b(?!\s*\+|\s*plus)', imageUrl: '$_base/hdr10.png'),
    StreamBadge(id: 'hdr', groupId: 'video-tech', name: 'HDR', pattern: r'(?i)\bhdr\b', imageUrl: '$_base/hdr.png'),
    StreamBadge(id: 'sdr', groupId: 'video-tech', name: 'SDR', pattern: r'(?i)\bsdr\b', imageUrl: '$_base/SDR_transparent_4x.png'),
    StreamBadge(id: 'imax-enhanced', groupId: 'video-tech', name: 'IMAX Enhanced', pattern: r'(?i)\b(imax[\s._-]*enhanced)\b', imageUrl: '$_base/imax_enhanced.png'),
    StreamBadge(id: 'imax', groupId: 'video-tech', name: 'IMAX', pattern: r'(?i)\b(imax)\b(?![\s._-]*enhanced)', imageUrl: '$_base/imax.png'),
    StreamBadge(id: 'hevc', groupId: 'video-codec', name: 'HEVC', pattern: r'(?i)\b(hevc|h[\s._-]?265|x265)\b', imageUrl: '$_base/HEVC_transparent_4x.png'),
    StreamBadge(id: 'avc', groupId: 'video-codec', name: 'AVC', pattern: r'(?i)\b(avc|h[\s._-]?264|x264)\b', imageUrl: '$_base/AVC_transparent_4x.png'),
    StreamBadge(id: '10bit', groupId: 'bit-depth', name: '10Bit', pattern: r'(?i)\b(10[\s._-]?bit|10b|hi10p)\b', imageUrl: '$_base/10Bit_transparent_4x.png'),
    StreamBadge(id: '8bit', groupId: 'bit-depth', name: '8Bit', pattern: r'(?i)\b(8[\s._-]?bit|8b)\b', imageUrl: '$_base/8Bit_transparent_4x.png'),
    StreamBadge(id: 'dolby-atmos', groupId: 'audio-tech', name: 'Dolby Atmos', pattern: r'(?i)\b(dolby\s*atmos|atmos)\b', imageUrl: '$_base/dolby_atmos.png'),
    StreamBadge(id: 'truehd', groupId: 'audio-tech', name: 'TrueHD', pattern: r'(?i)\b(truehd|true\s*hd|dolby\s*truehd)\b', imageUrl: '$_base/truehd.png'),
    StreamBadge(id: 'dolby-digital-plus', groupId: 'audio-tech', name: 'Dolby Digital Plus', pattern: r'(?i)\b(ddp[\s._-]*[0-9][\s._-]*[0-9]|ddp|dd\+|dolby[\s._-]*digital[\s._-]*plus|e-?ac-?3)(?![a-z])', imageUrl: '$_base/dolby_digital_plus.png'),
    StreamBadge(id: 'dolby-digital', groupId: 'audio-tech', name: 'Dolby Digital', pattern: r'(?i)\b(dd[\s._-]*[0-9][\s._-]*[0-9]|\bdd\b|dolby[\s._-]*digital|ac-?3)(?![\s._-]*plus|\+|p|[a-z])', imageUrl: '$_base/dolby_digital.png'),
    StreamBadge(id: 'dts-x', groupId: 'audio-tech', name: 'DTS:X', pattern: r'(?i)\b(dts[:\s._-]*x)\b', imageUrl: '$_base/dts_x.png'),
    StreamBadge(id: 'dts-hd-master-audio', groupId: 'audio-tech', name: 'DTS-HD Master Audio', pattern: r'(?i)\b(dts[\s._-]*hd[\s._-]*ma|dtshd\s*ma|dts[\s._-]*hd[\s._-]*master)\b', imageUrl: '$_base/dts_hd_master_audio.png'),
    StreamBadge(id: 'dts-hd', groupId: 'audio-tech', name: 'DTS-HD', pattern: r'(?i)\b(dts[\s._-]*hd|dtshd)(?![\s._-]*(ma|master)|ma)\b', imageUrl: '$_base/dts_hd.png'),
    StreamBadge(id: 'dts', groupId: 'audio-tech', name: 'DTS', pattern: r'(?i)\bdts\b(?![\s._:-]*(x|hd))', imageUrl: '$_base/dts.png'),
    StreamBadge(id: '71-audio', groupId: 'audio-channels', name: '7.1 Audio', pattern: r'(?i)\b(7\.1|7-1|8ch|8\s*channel)\b', imageUrl: '$_base/7_1_audio.png'),
    StreamBadge(id: '51-audio', groupId: 'audio-channels', name: '5.1 Audio', pattern: r'(?i)\b(5\.1|5-1|6ch|6\s*channel)\b', imageUrl: '$_base/5_1_audio.png'),
  ];

  static final Map<String, RegExp> _regexCache = {};

  static RegExp _re(String pattern) =>
      _regexCache.putIfAbsent(pattern, () => RegExp(pattern));

  /// Texto compuesto del servidor para matching.
  /// Normaliza "720" → "720p", "1080" → "1080p", etc. para que matchee badges.
  static String normalizeQuality(String? q) {
    if (q == null) return '';
    var s = q.trim();
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    // Evitar tratar HLS/TS/MP4 como calidad
    if (lower == 'hls' || lower == 'ts' || lower == 'mp4' || lower == 'dash' ||
        lower == 'auto' || lower == 'stream') {
      return '';
    }
    final m = RegExp(r'^(4k|2160|1080|720|480)$', caseSensitive: false).firstMatch(lower);
    if (m != null) {
      final v = m.group(1)!.toLowerCase();
      if (v == '4k') return '4k 2160p';
      return '${v}p';
    }
    // "720 HD" / "1080 Full"
    final m2 = RegExp(r'\b(2160|1080|720|480)\b', caseSensitive: false).firstMatch(s);
    if (m2 != null && !RegExp(r'\b(2160|1080|720|480)p\b', caseSensitive: false).hasMatch(s)) {
      s = '$s ${m2.group(1)}p';
    }
    return s;
  }

  static String haystack({
    String? name,
    String? quality,
    String? language,
    String? provider,
    Map<String, dynamic>? extra,
  }) {
    final nq = normalizeQuality(quality);
    final parts = <String>[
      if (name != null) name,
      if (nq.isNotEmpty) nq,
      if (quality != null && quality != nq) quality,
      if (language != null) language,
      if (provider != null) provider,
      if (extra != null) ...extra.values.map((e) => '$e'),
    ];
    return parts.join(' ');
  }

  /// Una badge por grupo (la primera que coincida en el orden del catálogo).
  static List<StreamBadge> matchBadges(String text, {int max = 6}) {
    if (text.trim().isEmpty) return const [];
    final seenGroups = <String>{};
    final out = <StreamBadge>[];
    for (final f in filters) {
      if (seenGroups.contains(f.groupId)) continue;
      try {
        if (_re(f.pattern).hasMatch(text)) {
          seenGroups.add(f.groupId);
          out.add(f);
          if (out.length >= max) break;
        }
      } catch (_) {}
    }
    return out;
  }

  static StreamLangInfo detectLanguage(String? language, [String? name]) {
    final t = '${language ?? ''} ${name ?? ''}'.toLowerCase();
    if (t.contains('lat') || t.contains('latino') || t.contains('mex') || t.contains('es-mx') || t.contains('es_mx')) {
      return const StreamLangInfo('Latino', 'https://flagcdn.com/w40/mx.png', 'lat');
    }
    if (t.contains('castellano') || t.contains('español') || t.contains('espanol') ||
        t.contains('spain') || RegExp(r'\besp\b').hasMatch(t) || t.contains('es-es') || t.contains('es_es')) {
      return const StreamLangInfo('Castellano', 'https://flagcdn.com/w40/es.png', 'es');
    }
    if (t.contains('subtit') || RegExp(r'\bsub\b').hasMatch(t) || t.contains('subs')) {
      return const StreamLangInfo('Subtitulado', 'https://flagcdn.com/w40/us.png', 'sub');
    }
    if (t.contains('english') || RegExp(r'\ben\b').hasMatch(t) || t.contains('inglés') || t.contains('ingles') || t.contains('eng')) {
      return const StreamLangInfo('Inglés', 'https://flagcdn.com/w40/us.png', 'en');
    }
    if (t.contains('portug') || t.contains('brazil') || t.contains('pt-br') || RegExp(r'\bpt\b').hasMatch(t)) {
      return const StreamLangInfo('Portugués', 'https://flagcdn.com/w40/br.png', 'pt');
    }
    if (t.contains('french') || t.contains('francés') || t.contains('frances') || RegExp(r'\bfr\b').hasMatch(t)) {
      return const StreamLangInfo('Francés', 'https://flagcdn.com/w40/fr.png', 'fr');
    }
    if (t.contains('italian') || t.contains('italiano') || RegExp(r'\bit\b').hasMatch(t)) {
      return const StreamLangInfo('Italiano', 'https://flagcdn.com/w40/it.png', 'it');
    }
    if (t.contains('german') || t.contains('alemán') || t.contains('aleman') || RegExp(r'\bde\b').hasMatch(t)) {
      return const StreamLangInfo('Alemán', 'https://flagcdn.com/w40/de.png', 'de');
    }
    if (t.contains('japanese') || t.contains('japonés') || t.contains('japones') || RegExp(r'\bja\b').hasMatch(t)) {
      return const StreamLangInfo('Japonés', 'https://flagcdn.com/w40/jp.png', 'ja');
    }
    if (t.contains('korean') || t.contains('coreano') || RegExp(r'\bko\b').hasMatch(t)) {
      return const StreamLangInfo('Coreano', 'https://flagcdn.com/w40/kr.png', 'ko');
    }
    final raw = (language ?? '').trim();
    if (raw.isEmpty) return const StreamLangInfo('—', null, '');
    return StreamLangInfo(raw, null, raw.toLowerCase());
  }
}
