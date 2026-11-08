import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Proxy HTTP local con soporte HLS:
/// - Reescribe master.m3u8 y playlists para que variantes/segmentos
///   pasen por el móvil (con headers/token).
/// - Sirve .ts / mp4 en passthrough.
class StreamProxy {
  StreamProxy._();
  static final StreamProxy instance = StreamProxy._();

  HttpServer? _server;
  int? _port;
  String? _upstreamUrl;
  Map<String, String> _upstreamHeaders = {};

  bool get isRunning => _server != null;
  int? get port => _port;

  static Future<String?> localIpv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      String? fallback;
      for (final iface in ifaces) {
        final name = iface.name.toLowerCase();
        final preferred = name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('en0') ||
            name.contains('rmnet') ||
            name.contains('eth');
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final ip = addr.address;
          final private = ip.startsWith('10.') ||
              ip.startsWith('192.168.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip);
          if (!private) continue;
          if (preferred) return ip;
          fallback ??= ip;
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('[StreamProxy] localIpv4: $e');
      return null;
    }
  }

  static bool isHls(String url) {
    final u = url.toLowerCase();
    return u.contains('.m3u8') ||
        u.contains('format=m3u8') ||
        u.contains('type=hls') ||
        u.contains('/hls');
  }

  /// MPEG-TS puro (archivo .ts o stream ts). Muchas TV/DLNA/Chromecast no lo
  /// reproducen directo; se envuelve en HLS.
  static bool isMpegTs(String url) {
    final u = url.toLowerCase();
    if (isHls(u)) return false;
    return u.contains('.ts') ||
        u.contains('mpegts') ||
        u.contains('mpeg-ts') ||
        u.contains('format=ts') ||
        u.contains('mime=video/mp2t') ||
        u.contains('video/mp2t') ||
        u.contains('/ts/');
  }

  static String guessContentType(String url) {
    final u = url.toLowerCase();
    if (isHls(u)) return 'application/vnd.apple.mpegurl';
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (isMpegTs(u)) return 'video/mp2t';
    if (u.contains('.mkv')) return 'video/x-matroska';
    if (u.contains('.webm')) return 'video/webm';
    if (u.contains('.mp4') || u.contains('.m4v')) return 'video/mp4';
    return 'video/mpeg';
  }

  /// URL que debe usar la TV: http://IP:PORT/media.m3u8 o media.mp4
  /// (LG / Chromecast miran la extensión para el tipo MIME).
  Future<String> start({
    required String upstreamUrl,
    Map<String, String> headers = const {},
  }) async {
    _upstreamUrl = upstreamUrl;
    _upstreamHeaders = Map<String, String>.from(headers);
    _upstreamHeaders.removeWhere((k, _) {
      final l = k.toLowerCase();
      return l == 'host' ||
          l == 'connection' ||
          l == 'content-length' ||
          l == 'accept-encoding' ||
          l == 'transfer-encoding';
    });

    if (_server == null) {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      _server!.listen(_handle, onError: (e) => debugPrint('[StreamProxy] $e'));
      debugPrint('[StreamProxy] listening on 0.0.0.0:$_port');
    }

    final ip = await localIpv4();
    if (ip == null) {
      throw Exception(
          'Sin IP local. Conecta el PC a la misma Wi‑Fi que la TV.');
    }

    // Extensión según contenido: LG webOS y Cast fallan sin ella
    final asHls = isHls(upstreamUrl) || isMpegTs(upstreamUrl);
    final path = asHls ? '/media.m3u8' : '/media.mp4';
    final url = 'http://$ip:$_port$path';
    debugPrint('[StreamProxy] public URL → $url (upstream=$upstreamUrl)');
    return url;
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _port = null;
    _upstreamUrl = null;
  }

  Uri _proxyUriFor(String absoluteUrl) {
    final ipHost = _server!.address.address == '0.0.0.0'
        ? '127.0.0.1'
        : _server!.address.address;
    // Usamos path /p?u=  (la TV usará la IP LAN que le dimos en /media)
    return Uri(
      scheme: 'http',
      host: 'HOST_PLACEHOLDER',
      port: _port,
      path: '/p',
      queryParameters: {'u': absoluteUrl},
    );
  }

  String _rewritePlaylist(String body, Uri playlistUri, String publicBase) {
    // publicBase = http://192.168.x.x:PORT
    final lines = const LineSplitter().convert(body);
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        // URI en atributos: URI="..."
        if (trimmed.contains('URI="')) {
          out.add(trimmed.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) {
              final raw = m.group(1)!;
              final abs = playlistUri.resolve(raw).toString();
              final proxied =
                  '$publicBase/p?u=${Uri.encodeComponent(abs)}';
              return 'URI="$proxied"';
            },
          ));
        } else {
          out.add(line);
        }
        continue;
      }
      // Línea de URL de segmento o variante
      final abs = playlistUri.resolve(trimmed).toString();
      out.add('$publicBase/p?u=${Uri.encodeComponent(abs)}');
    }
    return out.join('\n');
  }

  Future<void> _handle(HttpRequest req) async {
    req.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      ..set('Access-Control-Allow-Headers', '*')
      ..set('Access-Control-Expose-Headers', '*');

    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    final publicBase =
        'http://${req.headers.host?.split(':').first ?? '127.0.0.1'}:$_port';

    try {
      if (path == '/media' ||
          path == '/media.m3u8' ||
          path == '/media.mp4' ||
          path == '/') {
        final up = _upstreamUrl;
        if (up == null) {
          req.response.statusCode = 503;
          await req.response.close();
          return;
        }
        // TS puro → playlist HLS mínima (TV/Cast lo leen mejor que video/mp2t)
        if (isMpegTs(up) && !isHls(up)) {
          await _serveTsAsHls(req, up, publicBase);
          return;
        }
        await _proxyFetch(req, up, publicBase, isEntry: true);
        return;
      }

      // Playlist HLS generada para un .ts concreto
      if (path == '/ts.m3u8') {
        final u = req.uri.queryParameters['u'] ?? _upstreamUrl;
        if (u == null || u.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        await _serveTsAsHls(req, u, publicBase);
        return;
      }

      if (path == '/p') {
        final u = req.uri.queryParameters['u'];
        if (u == null || u.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        await _proxyFetch(req, u, publicBase, isEntry: false);
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    } catch (e, st) {
      debugPrint('[StreamProxy] error: $e\n$st');
      try {
        req.response.statusCode = 502;
        req.response.write('proxy error: $e');
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Envuelve un MPEG-TS en un playlist HLS de un solo segmento para que
  /// Chromecast / DLNA / Smart TV puedan reproducirlo.
  Future<void> _serveTsAsHls(
    HttpRequest req,
    String tsUrl,
    String publicBase,
  ) async {
    final segment = '$publicBase/p?u=${Uri.encodeComponent(tsUrl)}';
    // TARGETDURATION alto: un único segmento "largo" (VOD / archivo .ts)
    final body = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:36000
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:36000.0,
$segment
#EXT-X-ENDLIST
'''.trimLeft();
    final out = utf8.encode(body);
    req.response.statusCode = 200;
    req.response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.contentLength = out.length;
    if (req.method != 'HEAD') {
      req.response.add(out);
    }
    await req.response.close();
    debugPrint('[StreamProxy] TS→HLS wrapper for $tsUrl');
  }

  Future<void> _proxyFetch(
    HttpRequest req,
    String targetUrl,
    String publicBase, {
    required bool isEntry,
  }) async {
    final target = Uri.parse(targetUrl);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.autoUncompress = false;
    client.badCertificateCallback = (cert, host, port) => true;

    final method = req.method == 'HEAD' ? 'HEAD' : 'GET';
    final creq = await client.openUrl(method, target);
    _upstreamHeaders.forEach(creq.headers.set);
    final range = req.headers.value('range');
    if (range != null) creq.headers.set('Range', range);
    creq.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    // User-Agent de navegador ayuda con algunos CDN
    if (!_upstreamHeaders.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      creq.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36');
    }

    final cres = await creq.close().timeout(const Duration(seconds: 25));
    final status = cres.statusCode;
    final ctHeader =
        cres.headers.value('content-type') ?? guessContentType(targetUrl);
    final isPlaylist = ctHeader.contains('mpegurl') ||
        ctHeader.contains('m3u8') ||
        targetUrl.toLowerCase().contains('.m3u8');

    if (isPlaylist && method == 'GET') {
      final bytes = await consolidateHttpClientResponseBytes(cres);
      var body = utf8.decode(bytes, allowMalformed: true);
      body = _rewritePlaylist(body, target, publicBase);
      final out = utf8.encode(body);
      req.response.statusCode = status;
      req.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
      req.response.headers.set('Cache-Control', 'no-cache');
      req.response.contentLength = out.length;
      req.response.add(out);
      await req.response.close();
      client.close(force: true);
      debugPrint(
          '[StreamProxy] playlist ${target.path} → ${out.length} bytes rewritten');
      return;
    }

    req.response.statusCode = status;
    // Forzar MIME correcto en TS (algunos CDN mandan application/octet-stream)
    var outCt = ctHeader;
    if (isMpegTs(targetUrl) &&
        !outCt.contains('mp2t') &&
        !outCt.contains('mpegurl')) {
      outCt = 'video/mp2t';
    }
    try {
      req.response.headers.contentType = ContentType.parse(outCt);
    } catch (_) {
      req.response.headers.set('Content-Type', outCt);
    }
    req.response.headers.set('Accept-Ranges', 'bytes');
    // Ayuda a players DLNA
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    final cl = cres.contentLength;
    if (cl >= 0) req.response.contentLength = cl;
    final cr = cres.headers.value('content-range');
    if (cr != null) req.response.headers.set('Content-Range', cr);

    if (method == 'HEAD') {
      await req.response.close();
      client.close(force: true);
      return;
    }

    await req.response.addStream(cres);
    await req.response.close();
    client.close(force: true);
  }
}
