import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Proxy HTTP local estilo Nuvio Desktop.
///
/// Problema: CDNs sirven segmentos HLS con cabecera de imagen
/// (PNG/JPEG/GIF/WebP) delante del MPEG-TS → FFmpeg ve solo audio o nada.
///
/// Solución:
///  1. Reescribe la playlist para que todo pase por este proxy.
///  2. En cada segmento recorta la basura hasta el primer 0x47 alineado
///     cada 188 bytes.
///  3. TS puro / fMP4 / CMAF → no se toca.
class HlsProxyServer {
  HttpServer? _server;
  final Map<String, String> extraHeaders;
  final Duration requestTimeout;

  final http.Client _client = http.Client();

  int _playlistsOk = 0;
  int _segmentsOk = 0;
  int _segmentsStripped = 0;
  int _segmentsPassthrough = 0;

  HlsProxyServer({
    this.extraHeaders = const {},
    this.requestTimeout = const Duration(seconds: 20),
  });

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    debugPrint('[LOL+] HlsProxyServer en 127.0.0.1:${_server!.port}');
    _server!.listen(_handle, onError: (e) {
      debugPrint('[LOL+] HlsProxyServer socket error: $e');
    });
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    try {
      _client.close();
    } catch (_) {}
    debugPrint(
      '[LOL+] HlsProxy stats: playlists=$_playlistsOk '
      'segments=$_segmentsOk stripped=$_segmentsStripped '
      'passthrough=$_segmentsPassthrough',
    );
  }

  String buildEntryUrl(String originalM3u8Url) {
    final p = port;
    if (p == null) {
      throw StateError('HlsProxyServer no iniciado — llama a start() antes');
    }
    final encoded = base64Url.encode(utf8.encode(originalM3u8Url));
    return 'http://127.0.0.1:$p/playlist?u=$encoded';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      req.response.headers.set('Access-Control-Allow-Origin', '*');
      req.response.headers
          .set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
      req.response.headers.set('Access-Control-Allow-Headers', '*');

      if (req.method == 'OPTIONS') {
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }

      final path = req.uri.path;
      final encoded = req.uri.queryParameters['u'];
      if (encoded == null || encoded.isEmpty) {
        req.response.statusCode = 400;
        req.response.write('missing u');
        await req.response.close();
        return;
      }

      final originalUrl =
          utf8.decode(base64Url.decode(_padBase64(encoded)));

      if (path == '/playlist') {
        await _servePlaylist(req, originalUrl);
      } else if (path == '/segment') {
        await _serveSegment(req, originalUrl);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (e, st) {
      debugPrint('[LOL+] HlsProxy excepción: $e');
      if (e is TimeoutException) {
        debugPrint('[LOL+]   → timeout al CDN (headers / token / IP bloqueada)');
      }
      debugPrint('$st');
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  String _padBase64(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s + ('=' * (4 - mod));
  }

  Map<String, String> _reqHeaders({String? urlHint}) {
    final h = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
      // identity = sin gzip → el strip de TS funciona sobre bytes reales
      'Accept-Encoding': 'identity',
      'Connection': 'keep-alive',
      ...extraHeaders,
    };

    final hasRef = h.keys.any((k) => k.toLowerCase() == 'referer');
    final hasOrigin = h.keys.any((k) => k.toLowerCase() == 'origin');
    if ((!hasRef || !hasOrigin) && urlHint != null && urlHint.isNotEmpty) {
      try {
        final u = Uri.parse(urlHint);
        final origin = '${u.scheme}://${u.host}';
        if (!hasRef) h['Referer'] = '$origin/';
        if (!hasOrigin) h['Origin'] = origin;
      } catch (_) {}
    }
    return h;
  }

  Future<void> _servePlaylist(HttpRequest req, String originalUrl) async {
    final headers = _reqHeaders(urlHint: originalUrl);
    debugPrint('[LOL+] proxy GET playlist: $originalUrl');

    final res = await _client
        .get(Uri.parse(originalUrl), headers: headers)
        .timeout(requestTimeout);

    debugPrint(
      '[LOL+] proxy playlist HTTP ${res.statusCode} (${res.bodyBytes.length} B)',
    );

    if (res.statusCode != 200) {
      req.response.statusCode = res.statusCode;
      if (res.bodyBytes.isNotEmpty) req.response.add(res.bodyBytes);
      await req.response.close();
      return;
    }

    final base = Uri.parse(originalUrl);
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    final lines = const LineSplitter().convert(body);
    final out = StringBuffer();
    final p = port!;

    for (final rawLine in lines) {
      final line = rawLine.trimRight();

      if (line.startsWith('#EXT-X-KEY') ||
          line.startsWith('#EXT-X-MAP') ||
          line.startsWith('#EXT-X-MEDIA') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF') ||
          line.startsWith('#EXT-X-SESSION-KEY')) {
        out.writeln(_rewriteAttrLine(line, base, p));
        continue;
      }

      if (line.isEmpty || line.startsWith('#')) {
        out.writeln(line);
        continue;
      }

      final resolved = base.resolve(line.trim());
      final encoded = base64Url.encode(utf8.encode(resolved.toString()));
      final kind = _isPlaylistUri(resolved) ? 'playlist' : 'segment';
      out.writeln('http://127.0.0.1:$p/$kind?u=$encoded');
    }

    req.response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.write(out.toString());
    await req.response.close();
    _playlistsOk++;
  }

  bool _isPlaylistUri(Uri u) {
    final path = u.path.toLowerCase();
    if (path.endsWith('.m3u8') || path.endsWith('.m3u')) return true;
    final q = u.query.toLowerCase();
    if (q.contains('m3u8') || q.contains('playlist')) return true;
    if (path.contains('/playlist') || path.contains('/index')) return true;
    return false;
  }

  String _rewriteAttrLine(String line, Uri base, int p) {
    return line.replaceAllMapped(
      RegExp(r'URI="([^"]+)"', caseSensitive: false),
      (m) {
        final uriValue = m.group(1)!;
        final resolved = base.resolve(uriValue);
        final encoded = base64Url.encode(utf8.encode(resolved.toString()));
        final kind = _isPlaylistUri(resolved) ? 'playlist' : 'segment';
        return 'URI="http://127.0.0.1:$p/$kind?u=$encoded"';
      },
    );
  }

  Future<void> _serveSegment(HttpRequest req, String originalUrl) async {
    final headers = _reqHeaders(urlHint: originalUrl);

    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.isNotEmpty) {
      headers['Range'] = range;
    }

    final res = await _client
        .get(Uri.parse(originalUrl), headers: headers)
        .timeout(requestTimeout);

    if (res.statusCode != 200 && res.statusCode != 206) {
      debugPrint(
        '[LOL+] proxy segmento HTTP ${res.statusCode}: $originalUrl',
      );
      req.response.statusCode = res.statusCode;
      await req.response.close();
      return;
    }

    final bytes = res.bodyBytes;
    final cleaned = _stripFakeImageHeader(bytes);
    final stripped = cleaned.length != bytes.length;

    // Tras strip (o si ya es TS) forzar video/mp2t para que FFmpeg no dude
    if (stripped || (bytes.isNotEmpty && bytes[0] == 0x47)) {
      req.response.headers.contentType = ContentType('video', 'mp2t');
    } else {
      final ct = res.headers['content-type'];
      if (ct != null && ct.isNotEmpty) {
        try {
          req.response.headers.set(HttpHeaders.contentTypeHeader, ct);
        } catch (_) {
          req.response.headers.contentType = ContentType('video', 'mp2t');
        }
      } else {
        req.response.headers.contentType = ContentType('video', 'mp2t');
      }
    }

    req.response.statusCode = res.statusCode;
    req.response.headers.contentLength = cleaned.length;
    req.response.headers.set('Cache-Control', 'no-store');
    final cr = res.headers['content-range'];
    if (cr != null) {
      req.response.headers.set(HttpHeaders.contentRangeHeader, cr);
    }

    req.response.add(cleaned);
    await req.response.close();

    _segmentsOk++;
    if (stripped) {
      _segmentsStripped++;
    } else {
      _segmentsPassthrough++;
    }
  }

  /// Recorta basura (imagen falsa) delante del primer paquete TS válido.
  Uint8List _stripFakeImageHeader(Uint8List bytes) {
    if (bytes.isEmpty) return bytes;

    // TS puro
    if (bytes[0] == 0x47 && _isAlignedTs(bytes, 0, packets: 3)) {
      return bytes;
    }

    // fMP4 / CMAF
    if (_looksLikeFmp4(bytes)) return bytes;

    const packetSize = 188;
    const minPackets = 3;
    final maxScan = bytes.length < 131072 ? bytes.length : 131072;

    int preferredStart = 0;
    if (_hasImageSignature(bytes)) {
      preferredStart = _imageHeaderMinSize(bytes);
      if (preferredStart > maxScan) preferredStart = 0;
    }

    final found =
        _findTsStart(bytes, preferredStart, maxScan, packetSize, minPackets);
    if (found != null) {
      if (found > 0) {
        debugPrint(
          '[LOL+] proxy: strip $found B cabecera falsa → TS '
          '(${bytes.length - found} B útiles)',
        );
      }
      return found == 0 ? bytes : Uint8List.sublistView(bytes, found);
    }

    if (preferredStart > 0) {
      final found2 =
          _findTsStart(bytes, 0, preferredStart, packetSize, minPackets);
      if (found2 != null) {
        debugPrint('[LOL+] proxy: strip $found2 B (2ª pasada) → TS');
        return found2 == 0 ? bytes : Uint8List.sublistView(bytes, found2);
      }
    }

    // Alineación parcial (segmentos muy cortos)
    for (int i = 0; i < maxScan; i++) {
      if (bytes[i] != 0x47) continue;
      if (i + packetSize < bytes.length && bytes[i + packetSize] == 0x47) {
        debugPrint('[LOL+] proxy: strip $i B (alineación parcial 2 pkt)');
        return Uint8List.sublistView(bytes, i);
      }
    }

    return bytes;
  }

  int? _findTsStart(
    Uint8List bytes,
    int from,
    int to,
    int packetSize,
    int minPackets,
  ) {
    final limit = to < bytes.length ? to : bytes.length;
    for (int i = from; i < limit; i++) {
      if (bytes[i] != 0x47) continue;
      if (_isAlignedTs(bytes, i, packets: minPackets, packetSize: packetSize)) {
        return i;
      }
    }
    return null;
  }

  bool _isAlignedTs(
    Uint8List bytes,
    int offset, {
    int packets = 3,
    int packetSize = 188,
  }) {
    for (int k = 0; k < packets; k++) {
      final idx = offset + (k * packetSize);
      if (idx >= bytes.length || bytes[idx] != 0x47) return false;
    }
    return true;
  }

  bool _hasImageSignature(Uint8List b) {
    if (b.length < 4) return false;
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true; // PNG
    }
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true; // JPEG
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
      return true; // GIF
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true; // WebP
    }
    if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
    return false;
  }

  int _imageHeaderMinSize(Uint8List b) {
    if (b.length < 4) return 0;
    if (b[0] == 0x89 && b[1] == 0x50) return 8;
    if (b[0] == 0xFF && b[1] == 0xD8) return 2;
    if (b[0] == 0x47 && b[1] == 0x49) return 6;
    if (b[0] == 0x52 && b[1] == 0x49) return 12;
    if (b[0] == 0x42 && b[1] == 0x4D) return 14;
    return 0;
  }

  bool _looksLikeFmp4(Uint8List b) {
    if (b.length < 8) return false;
    final type = String.fromCharCodes([b[4], b[5], b[6], b[7]]);
    const boxes = {
      'ftyp', 'styp', 'moof', 'sidx', 'free', 'mdat', 'moov', 'skip',
    };
    return boxes.contains(type);
  }
}