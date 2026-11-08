import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'stream_proxy.dart';

/// Protocolos de transmisión.
enum CastProtocol {
  dlna,
  chromecast,
}

extension CastProtocolX on CastProtocol {
  String get label {
    switch (this) {
      case CastProtocol.dlna:
        return 'DLNA / Smart TV';
      case CastProtocol.chromecast:
        return 'Chromecast';
    }
  }

  String get subtitle {
    switch (this) {
      case CastProtocol.dlna:
        return 'TVs y dispositivos compatibles con DLNA/UPnP';
      case CastProtocol.chromecast:
        return 'Google Chromecast y TVs con Google Cast';
    }
  }
}

class CastDevice {
  final String id;
  final String name;
  final CastProtocol protocol;
  final String? host;
  final int? port;
  final String? controlUrl;
  final String? location;
  final String? model;
  final Map<String, dynamic> extra;

  const CastDevice({
    required this.id,
    required this.name,
    required this.protocol,
    this.host,
    this.port,
    this.controlUrl,
    this.location,
    this.model,
    this.extra = const {},
  });

  @override
  String toString() => '$name (${protocol.label})';
}

enum CastSessionState {
  idle,
  connecting,
  connected,
  playing,
  paused,
  buffering,
  error,
  ended,
}

class CastSession extends ChangeNotifier {
  CastSession({
    required this.device,
    required this.mediaUrl,
    required this.title,
    this.headers = const {},
    this.poster,
    this.duration = Duration.zero,
    Duration startPosition = Duration.zero,
    this.mediaContentType,
  }) : _position = startPosition;

  final CastDevice device;
  String mediaUrl;
  /// MIME real (no inferir solo de la URL del proxy).
  String? mediaContentType;
  String title;
  Map<String, String> headers;
  String? poster;
  Duration duration;

  CastSessionState _state = CastSessionState.connecting;
  Duration _position = Duration.zero;
  String? _error;
  Timer? _tick;
  bool _disposed = false;
  Socket? _castSocket;
  int _castRequestId = 1;
  String _castTransportId = 'receiver-0';
  int? _mediaSessionId;

  CastSessionState get state => _state;
  Duration get position => _position;
  String? get error => _error;
  bool get isPlaying =>
      _state == CastSessionState.playing || _state == CastSessionState.buffering;

  // Compat API usada por PlayerTransmissionPage / CastController
  StreamController<Duration>? _posCtrl;
  StreamController<Duration>? _durCtrl;
  StreamController<CastSessionState>? _stateCtrl;

  Stream<Duration> get positionStream {
    _posCtrl ??= StreamController<Duration>.broadcast();
    return _posCtrl!.stream;
  }

  Stream<Duration> get durationStream {
    _durCtrl ??= StreamController<Duration>.broadcast();
    return _durCtrl!.stream;
  }

  Stream<CastSessionState> get stateStream {
    _stateCtrl ??= StreamController<CastSessionState>.broadcast();
    return _stateCtrl!.stream;
  }

  void _setState(CastSessionState s, {String? error}) {
    if (_disposed) return;
    _state = s;
    if (error != null) _error = error;
    notifyListeners();
    if (_stateCtrl != null && !_stateCtrl!.isClosed) {
      _stateCtrl!.add(s);
    }
  }

  bool _isAlreadyProxied(String url) {
    final u = url.toLowerCase();
    return u.contains('/media.m3u8') ||
        u.contains('/media.mp4') ||
        u.contains('/media') && (u.contains('192.168.') || u.contains('10.'));
  }

  Future<void> connectAndPlay() async {
    _setState(CastSessionState.connecting);
    try {
      final originalUrl = mediaUrl;

      if (device.protocol == CastProtocol.dlna) {
        // DLNA: siempre proxy (TV no envía headers; HLS se reescribe)
        // Si prepareCastMedia ya puso el proxy, no re-proxificar.
        if (!_isAlreadyProxied(originalUrl)) {
          try {
            final localUrl = await StreamProxy.instance.start(
              upstreamUrl: originalUrl,
              headers: headers,
            );
            debugPrint(
                '[Cast] DLNA proxy: $localUrl (upstream=$originalUrl)');
            mediaUrl = localUrl;
          } catch (e) {
            debugPrint('[Cast] proxy falló, URL directa: $e');
          }
        } else {
          debugPrint('[Cast] DLNA ya proxied: $originalUrl');
        }
        // MIME según extensión del proxy / URL
        mediaContentType ??= _guessMime(mediaUrl);
        await _dlnaPlay();
      } else {
        // Chromecast: proxy si headers auth o TS/HLS sin extensión usable
        final needsProxy = (!_isAlreadyProxied(originalUrl)) &&
            (headers.isNotEmpty &&
                    headers.keys.any((k) {
                      final l = k.toLowerCase();
                      return l == 'referer' ||
                          l == 'origin' ||
                          l == 'authorization' ||
                          l == 'cookie';
                    }) ||
                StreamProxy.isMpegTs(originalUrl));
        if (needsProxy) {
          try {
            final localUrl = await StreamProxy.instance.start(
              upstreamUrl: originalUrl,
              headers: headers,
            );
            debugPrint('[Cast] Chromecast proxy: $localUrl');
            mediaUrl = localUrl;
          } catch (e) {
            debugPrint('[Cast] proxy falló: $e');
          }
        } else {
          debugPrint('[Cast] Chromecast URL: $originalUrl');
        }
        mediaContentType ??= _guessMime(mediaUrl);
        await _chromecastPlay();
      }
      _setState(CastSessionState.playing);
      _startTicker();
    } catch (e, st) {
      debugPrint('[Cast] connect error: $e\n$st');
      _setState(CastSessionState.error, error: e.toString());
      rethrow;
    }
  }

  Future<void> play() async {
    try {
      if (device.protocol == CastProtocol.dlna) {
        await _dlnaAction('Play', {'InstanceID': '0', 'Speed': '1'});
      } else {
        await _castMediaCommand('PLAY');
      }
      _setState(CastSessionState.playing);
      _startTicker();
    } catch (e) {
      _setState(CastSessionState.error, error: e.toString());
    }
  }

  Future<void> pause() async {
    try {
      if (device.protocol == CastProtocol.dlna) {
        await _dlnaAction('Pause', {'InstanceID': '0'});
      } else {
        await _castMediaCommand('PAUSE');
      }
      _tick?.cancel();
      _setState(CastSessionState.paused);
    } catch (e) {
      _setState(CastSessionState.error, error: e.toString());
    }
  }

  Future<void> seek(Duration to) async {
    _position = to;
    notifyListeners();
    if (_posCtrl != null && !_posCtrl!.isClosed) _posCtrl!.add(_position);
    try {
      if (device.protocol == CastProtocol.dlna) {
        await _dlnaAction('Seek', {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': _fmtDlnaTime(to),
        });
      } else {
        await _castMediaCommand('SEEK', extra: {
          'currentTime': to.inMilliseconds / 1000.0,
          'resumeState': 'PLAYBACK_START',
        });
      }
    } catch (e) {
      debugPrint('[Cast] seek error: $e');
    }
  }

  Future<void> loadMedia({
    required String url,
    required String title,
    Map<String, String> headers = const {},
    String? poster,
    Duration start = Duration.zero,
  }) async {
    mediaUrl = url;
    this.title = title;
    this.headers = headers;
    this.poster = poster;
    _position = start;
    notifyListeners();
    await connectAndPlay();
  }

  /// Alias de stop+dispose para CastController.
  Future<void> disconnect() async {
    await stop();
    dispose();
  }

  /// Detiene en el dispositivo remoto. No llamar al solo cerrar la UI.
  Future<void> stop() async {
    _tick?.cancel();
    try {
      if (device.protocol == CastProtocol.dlna) {
        await _dlnaAction('Stop', {'InstanceID': '0'});
      } else {
        await _castMediaCommand('STOP');
        try {
          await _castSocket?.close();
        } catch (_) {}
        _castSocket = null;
      }
    } catch (_) {}
    try {
      await StreamProxy.instance.stop();
    } catch (_) {}
    _setState(CastSessionState.ended);
  }

  void _startTicker() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || _state != CastSessionState.playing) return;
      _position += const Duration(seconds: 1);
      if (duration > Duration.zero && _position > duration) {
        _position = duration;
      if (_posCtrl != null && !_posCtrl!.isClosed) _posCtrl!.add(_position);
      if (_durCtrl != null && !_durCtrl!.isClosed && duration > Duration.zero) {
        _durCtrl!.add(duration);
      }
        _setState(CastSessionState.ended);
        _tick?.cancel();
      } else {
        notifyListeners();
      }
    });
  }

  // ═══════════════════════ DLNA ═══════════════════════

  Future<void> _dlnaPlay() async {
    final control = device.controlUrl;
    if (control == null || control.isEmpty) {
      throw Exception(
          'Dispositivo DLNA sin URL de control. Elige otro de la lista.');
    }

    // Stop previo (ignorar error)
    try {
      await _dlnaAction('Stop', {'InstanceID': '0'});
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final mime = _guessMime(mediaUrl);
    final variants = <Map<String, String>>[
      // 1) Sin metadata (algunas TV antiguas)
      {
        'InstanceID': '0',
        'CurrentURI': mediaUrl,
        'CurrentURIMetaData': '',
      },
      // 2) DIDL simple
      {
        'InstanceID': '0',
        'CurrentURI': mediaUrl,
        'CurrentURIMetaData': _didlMeta(
          title: title.isEmpty ? 'Video' : title,
          url: mediaUrl,
          poster: poster,
          mime: mime,
          dlnaFlags: false,
        ),
      },
      // 3) DIDL con flags DLNA (LG webOS suele preferir esto)
      {
        'InstanceID': '0',
        'CurrentURI': mediaUrl,
        'CurrentURIMetaData': _didlMeta(
          title: title.isEmpty ? 'Video' : title,
          url: mediaUrl,
          poster: poster,
          mime: mime,
          dlnaFlags: true,
        ),
      },
      // 4) Forzar video/mp4 en protocolInfo (LG a veces solo acepta mp4)
      {
        'InstanceID': '0',
        'CurrentURI': mediaUrl,
        'CurrentURIMetaData': _didlMeta(
          title: title.isEmpty ? 'Video' : title,
          url: mediaUrl,
          poster: poster,
          mime: 'video/mp4',
          dlnaFlags: true,
        ),
      },
      // 5) video/mpeg genérico
      {
        'InstanceID': '0',
        'CurrentURI': mediaUrl,
        'CurrentURIMetaData': _didlMeta(
          title: title.isEmpty ? 'Video' : title,
          url: mediaUrl,
          poster: poster,
          mime: 'video/mpeg',
          dlnaFlags: true,
        ),
      },
    ];

    Object? lastErr;
    var ok = false;
    for (var i = 0; i < variants.length; i++) {
      try {
        debugPrint('[Cast] DLNA SetAVTransportURI intento ${i + 1}/${variants.length}');
        await _dlnaAction('SetAVTransportURI', variants[i]);
        ok = true;
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        debugPrint('[Cast] SetAVTransportURI #$i → $e');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    if (!ok && lastErr != null) {
      throw Exception(
          'DLNA no aceptó la URL (posible HLS/HTTPS o firewall). '
          'Prueba otro servidor MP4 o revisa que PC y TV estén en la misma Wi‑Fi.\n$lastErr');
    }

    await Future<void>.delayed(const Duration(milliseconds: 350));

    if (_position > const Duration(seconds: 2)) {
      try {
        await _dlnaAction('Seek', {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': _fmtDlnaTime(_position),
        });
      } catch (_) {}
    }

    // Play con reintento
    Object? playErr;
    for (var i = 0; i < 3; i++) {
      try {
        await _dlnaAction('Play', {'InstanceID': '0', 'Speed': '1'});
        playErr = null;
        break;
      } catch (e) {
        playErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    if (playErr != null) throw playErr;

    try {
      await _dlnaAction('GetTransportInfo', {'InstanceID': '0'});
    } catch (_) {}
  }

  Future<void> _dlnaAction(String action, Map<String, String> args) async {
    final control = device.controlUrl!;
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..write('<s:Body>')
      ..write(
          '<u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">');
    args.forEach((k, v) {
      buf.write('<$k>${_xmlEscape(v)}</$k>');
    });
    buf
      ..write('</u:$action>')
      ..write('</s:Body>')
      ..write('</s:Envelope>');

    final res = await http
        .post(
          Uri.parse(control),
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPAction':
                '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
            'User-Agent': 'UPnP/1.0 DLNADOC/1.50 LOLPlus/1.0',
            'Connection': 'close',
          },
          body: buf.toString(),
        )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode >= 400) {
      // Incluir un trozo del body para depurar
      final snippet = res.body.length > 180
          ? '${res.body.substring(0, 180)}…'
          : res.body;
      throw Exception('DLNA $action falló (${res.statusCode}) $snippet');
    }
  }

  static String _fmtDlnaTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _guessMime(String url) {
    final u = url.toLowerCase();
    // Proxy local con extensión explícita
    if (u.endsWith('/media.m3u8') || u.contains('media.m3u8')) {
      return 'application/x-mpegURL';
    }
    if (u.endsWith('/media.mp4') || u.contains('media.mp4')) {
      return 'video/mp4';
    }
    if (u.contains('.m3u8') || u.contains('format=m3u8') || u.contains('type=hls')) {
      return 'application/x-mpegURL';
    }
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (u.contains('.ts') ||
        u.contains('mpegts') ||
        u.contains('mpeg-ts') ||
        u.contains('format=ts') ||
        u.contains('/ts/')) {
      return 'video/mp2t';
    }
    if (u.contains('.mkv')) return 'video/x-matroska';
    if (u.contains('.webm')) return 'video/webm';
    if (u.contains('.mp4') || u.contains('.m4v')) return 'video/mp4';
    // Por defecto: muchos TV aceptan video/mpeg para TS/unknown
    return 'video/mpeg';
  }

  static String _didlMeta({
    required String title,
    required String url,
    String? poster,
    required String mime,
    bool dlnaFlags = false,
  }) {
    final t = _xmlEscape(title);
    final u = _xmlEscape(url);
    final art = poster != null && poster.isNotEmpty
        ? '<upnp:albumArtURI>${_xmlEscape(poster)}</upnp:albumArtURI>'
        : '';
    String proto;
    if (dlnaFlags) {
      // Flags DLNA.ORG ayudan en LG / Samsung
      proto =
          'http-get:*:$mime:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
    } else {
      proto = 'http-get:*:$mime:*';
    }
    final didl =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>$t</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '$art'
        '<res protocolInfo="$proto">$u</res>'
        '</item></DIDL-Lite>';
    return didl;
  }

  // ═══════════════════════ Chromecast (CAST v2 + protobuf mínimo) ═══

  Future<void> _chromecastPlay() async {
    final host = device.host;
    final port = device.port ?? 8009;
    if (host == null || host.isEmpty) {
      throw Exception('Chromecast sin IP');
    }

    try {
      _castSocket = await SecureSocket.connect(
        host,
        port,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 8),
      );
    } catch (e) {
      throw Exception(
          'No se pudo conectar al Chromecast ($host:$port): $e');
    }

    // Escuchar respuestas (para transport-id / mediaSessionId)
    _castSocket!.listen(
      (data) {
        try {
          _onCastData(data);
        } catch (e) {
          debugPrint('[Cast] parse resp: $e');
        }
      },
      onError: (e) => debugPrint('[Cast] socket error: $e'),
      onDone: () => debugPrint('[Cast] socket closed'),
      cancelOnError: false,
    );

    // CONNECT
    await _castSendPb(
      namespace: 'urn:x-cast:com.google.cast.tp.connection',
      destination: 'receiver-0',
      payload: {
        'type': 'CONNECT',
        'origin': <String, dynamic>{},
        'userAgent': 'lolplus',
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 300));

    // PING periódico simple no obligatorio para LOAD

    // LAUNCH Default Media Receiver
    _castTransportId = 'receiver-0';
    await _castSendPb(
      namespace: 'urn:x-cast:com.google.cast.receiver',
      destination: 'receiver-0',
      payload: {
        'type': 'LAUNCH',
        'appId': 'CC1AD845',
        'requestId': _castRequestId++,
      },
    );

    // Esperar transportId real (hasta 5s)
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 5)) {
      if (_castTransportId != null &&
          _castTransportId != 'receiver-0' &&
          _castTransportId!.isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final dest = (_castTransportId != null && _castTransportId!.isNotEmpty)
        ? _castTransportId!
        : 'receiver-0';
    debugPrint('[Cast] transportId=$dest');

    // contentType correcto: HLS vs MP4 (proxy usa .m3u8/.mp4)
    var contentType = mediaContentType ?? _guessMime(mediaUrl);
    final lowUrl = mediaUrl.toLowerCase();
    if (lowUrl.contains('.m3u8') ||
        contentType.contains('mpegurl') ||
        contentType.contains('m3u8')) {
      contentType = 'application/x-mpegURL';
    } else if (lowUrl.contains('.mp4') || contentType.contains('mp4')) {
      contentType = 'video/mp4';
    }
    debugPrint('[Cast] LOAD contentType=$contentType url=$mediaUrl');

    await _castSendPb(
      namespace: 'urn:x-cast:com.google.cast.media',
      destination: dest,
      payload: {
        'type': 'LOAD',
        'requestId': _castRequestId++,
        'media': {
          'contentId': mediaUrl,
          'streamType': 'BUFFERED',
          'contentType': contentType,
          'metadata': {
            'metadataType': 0,
            'title': title,
            if (poster != null && poster!.isNotEmpty)
              'images': [
                {'url': poster}
              ],
          },
        },
        'autoplay': true,
        'currentTime': _position.inMilliseconds / 1000.0,
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  void _onCastData(List<int> data) {
    // Paquetes pueden venir concatenados: [len u32][protobuf]...
    var offset = 0;
    while (offset + 4 <= data.length) {
      final len = ByteData.sublistView(
              Uint8List.fromList(data), offset, offset + 4)
          .getUint32(0, Endian.big);
      offset += 4;
      if (offset + len > data.length) break;
      final msg = data.sublist(offset, offset + len);
      offset += len;
      final json = _decodeCastMessageJson(msg);
      if (json == null) continue;
      final type = json['type']?.toString();
      if (type == 'RECEIVER_STATUS') {
        final status = json['status'];
        if (status is Map) {
          final apps = status['applications'];
          if (apps is List && apps.isNotEmpty) {
            final app = apps.first;
            if (app is Map && app['transportId'] != null) {
              _castTransportId = app['transportId'].toString();
            }
          }
        }
      } else if (type == 'MEDIA_STATUS') {
        final status = json['status'];
        if (status is List && status.isNotEmpty) {
          final s0 = status.first;
          if (s0 is Map && s0['mediaSessionId'] != null) {
            _mediaSessionId = (s0['mediaSessionId'] as num).toInt();
          }
        }
      }
    }
  }

  Future<void> _castMediaCommand(String type,
      {Map<String, dynamic>? extra}) async {
    if (_castSocket == null) return;
    final body = <String, dynamic>{
      'type': type,
      'requestId': _castRequestId++,
      if (_mediaSessionId != null) 'mediaSessionId': _mediaSessionId,
      ...?extra,
    };
    await _castSendPb(
      namespace: 'urn:x-cast:com.google.cast.media',
      destination: _castTransportId,
      payload: body,
    );
  }

  Future<void> _castSendPb({
    required String namespace,
    required String destination,
    required Map<String, dynamic> payload,
  }) async {
    final sock = _castSocket;
    if (sock == null || sock.port == 0) {
      throw Exception('Socket Cast cerrado');
    }
    final utf8Payload = jsonEncode(payload);
    final pb = _encodeCastMessage(
      sourceId: 'sender-0',
      destinationId: destination,
      namespace: namespace,
      payloadUtf8: utf8Payload,
    );
    final header = ByteData(4)..setUint32(0, pb.length, Endian.big);
    try {
      sock.add(Uint8List.fromList([...header.buffer.asUint8List(), ...pb]));
      await sock.flush();
    } catch (e) {
      throw Exception('Error enviando a Chromecast: $e');
    }
  }

  /// Protobuf mínimo de CastMessage (campos 1–6).
  static Uint8List _encodeCastMessage({
    required String sourceId,
    required String destinationId,
    required String namespace,
    required String payloadUtf8,
  }) {
    final out = BytesBuilder();
    // protocol_version = 0 (field 1, varint)
    out.add([0x08, 0x00]);
    out.add(_pbString(2, sourceId));
    out.add(_pbString(3, destinationId));
    out.add(_pbString(4, namespace));
    // payload_type = STRING = 0 (field 5, varint)
    out.add([0x28, 0x00]);
    out.add(_pbString(6, payloadUtf8));
    return out.toBytes();
  }

  static List<int> _pbString(int field, String value) {
    final bytes = utf8.encode(value);
    final tag = (field << 3) | 2; // length-delimited
    return [..._pbVarint(tag), ..._pbVarint(bytes.length), ...bytes];
  }

  static List<int> _pbVarint(int value) {
    final parts = <int>[];
    var v = value;
    while (v > 0x7f) {
      parts.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
    parts.add(v & 0x7f);
    return parts;
  }

  /// Extrae payload_utf8 (field 6) de un CastMessage y lo parsea como JSON.
  static Map<String, dynamic>? _decodeCastMessageJson(List<int> pb) {
    var i = 0;
    String? payload;
    while (i < pb.length) {
      final tag = pb[i++];
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (wire == 0) {
        // varint
        while (i < pb.length && (pb[i] & 0x80) != 0) {
          i++;
        }
        i++;
      } else if (wire == 2) {
        var len = 0, shift = 0;
        while (i < pb.length) {
          final b = pb[i++];
          len |= (b & 0x7f) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (i + len > pb.length) break;
        final slice = pb.sublist(i, i + len);
        i += len;
        if (field == 6) {
          payload = utf8.decode(slice, allowMalformed: true);
        }
      } else {
        break;
      }
    }
    if (payload == null) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    try { _posCtrl?.close(); } catch (_) {}
    try { _durCtrl?.close(); } catch (_) {}
    try { _stateCtrl?.close(); } catch (_) {}
    _tick?.cancel();
    // NO cerramos el socket Cast ni enviamos STOP aquí:
    // la TV sigue reproduciendo aunque se cierre la app/UI.
    super.dispose();
  }
}

class CastService {
  CastService._();
  static final CastService instance = CastService._();

  /// Compat: discovery es one-shot; no hay escaneo continuo.
  Future<void> startDiscovery() async {}
  void stopDiscovery() {}

  Future<List<CastDevice>> discover(
    CastProtocol protocol, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    switch (protocol) {
      case CastProtocol.dlna:
        return _discoverDlna(timeout);
      case CastProtocol.chromecast:
        return _discoverChromecast(timeout);
    }
  }

  Future<CastSession> connect({
    required CastDevice device,
    required String mediaUrl,
    required String title,
    Map<String, String> headers = const {},
    String? poster,
    Duration startPosition = Duration.zero,
    Duration duration = Duration.zero,
    String? mediaContentType,
  }) async {
    final session = CastSession(
      device: device,
      mediaUrl: mediaUrl,
      title: title,
      headers: headers,
      poster: poster,
      duration: duration,
      startPosition: startPosition,
      mediaContentType: mediaContentType,
    );
    await session.connectAndPlay();
    return session;
  }

  Future<List<CastDevice>> _discoverDlna(Duration timeout) async {
    final found = <String, CastDevice>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.multicastHops = 4;

      final dest = InternetAddress('239.255.255.250');
      void sendSearch(String st) {
        final msg = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: 239.255.255.250:1900\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $st\r\n'
            '\r\n';
        socket!.send(utf8.encode(msg), dest, 1900);
      }

      for (var i = 0; i < 2; i++) {
        sendSearch('urn:schemas-upnp-org:service:AVTransport:1');
        sendSearch('urn:schemas-upnp-org:device:MediaRenderer:1');
        sendSearch('ssdp:all');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        final loc = _header(text, 'LOCATION') ?? _header(text, 'Location');
        if (loc == null || loc.isEmpty) return;
        if (found.containsKey(loc)) return;
        found[loc] = CastDevice(
          id: loc,
          name: 'DLNA ${dg.address.address}',
          protocol: CastProtocol.dlna,
          host: dg.address.address,
          location: loc,
        );
      });

      await Future<void>.delayed(timeout);
      await sub.cancel();

      final resolved = <CastDevice>[];
      for (final d in found.values) {
        try {
          resolved.add(await _resolveDlnaDevice(d));
        } catch (_) {
          resolved.add(d);
        }
      }
      // Solo los que tengan controlUrl son útiles para reproducir
      final withControl =
          resolved.where((d) => d.controlUrl != null && d.controlUrl!.isNotEmpty);
      final list = withControl.isNotEmpty ? withControl.toList() : resolved;
      return list;
    } catch (e) {
      debugPrint('[Cast] DLNA discover: $e');
      return found.values.toList();
    } finally {
      socket?.close();
    }
  }

  Future<CastDevice> _resolveDlnaDevice(CastDevice d) async {
    final loc = d.location;
    if (loc == null) return d;
    final res =
        await http.get(Uri.parse(loc)).timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return d;
    final xml = res.body;
    final name = _xmlTag(xml, 'friendlyName') ?? d.name;
    final model = _xmlTag(xml, 'modelName');
    final baseUri = Uri.parse(loc);
    // URLBase opcional en device description
    final urlBase = _xmlTag(xml, 'URLBase');
    final base = (urlBase != null && urlBase.isNotEmpty)
        ? Uri.parse(urlBase)
        : baseUri;

    String? controlUrl;
    // Buscar todos los bloques de servicio AVTransport
    final serviceRe = RegExp(
      r'<service>([\s\S]*?)</service>',
      caseSensitive: false,
    );
    for (final m in serviceRe.allMatches(xml)) {
      final block = m.group(1) ?? '';
      if (!block.contains('AVTransport')) continue;
      final cu = _xmlTag(block, 'controlURL');
      if (cu == null || cu.isEmpty) continue;
      if (cu.startsWith('http')) {
        controlUrl = cu;
      } else {
        controlUrl = base.resolve(cu).toString();
      }
      break;
    }
    // Fallback por índice AVTransport
    if (controlUrl == null) {
      final avIdx = xml.indexOf('urn:schemas-upnp-org:service:AVTransport');
      if (avIdx >= 0) {
        final slice = xml.substring(avIdx, (avIdx + 1500).clamp(0, xml.length));
        final cu = _xmlTag(slice, 'controlURL');
        if (cu != null) {
          controlUrl = cu.startsWith('http') ? cu : base.resolve(cu).toString();
        }
      }
    }

    return CastDevice(
      id: d.id,
      name: name,
      protocol: CastProtocol.dlna,
      host: d.host,
      location: loc,
      controlUrl: controlUrl,
      model: model,
    );
  }

  Future<List<CastDevice>> _discoverChromecast(Duration timeout) async {
    final devices = <String, CastDevice>{};

    // 1) mDNS _googlecast._tcp
    try {
      final mdnsDevices = await _discoverChromecastMdns(timeout);
      for (final d in mdnsDevices) {
        devices[d.id] = d;
      }
    } catch (e) {
      debugPrint('[Cast] Chromecast mDNS: $e');
    }

    // 2) SSDP DIAL (muchas Smart TV / Chromecast responden)
    try {
      final dial = await _discoverDialSsdp(timeout);
      for (final d in dial) {
        devices.putIfAbsent(d.id, () => d);
      }
    } catch (e) {
      debugPrint('[Cast] DIAL SSDP: $e');
    }

    final list = devices.values.toList();
    debugPrint('[Cast] Chromecast encontrados: ${list.length}');
    return list;
  }

  Future<List<CastDevice>> _discoverChromecastMdns(Duration timeout) async {
    final devices = <String, CastDevice>{};
    final client = MDnsClient(
      rawDatagramSocketFactory: (host, port,
          {bool reuseAddress = false, bool reusePort = false, int ttl = 1}) {
        return RawDatagramSocket.bind(
          host,
          port,
          reuseAddress: true,
          reusePort: false,
          ttl: ttl,
        );
      },
    );
    try {
      await client.start();
      // Varias consultas en paralelo con timeout mayor
      final ptrs = <PtrResourceRecord>[];
      try {
        await for (final ptr in client
            .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer('_googlecast._tcp.local'),
            )
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          ptrs.add(ptr);
        }
      } catch (_) {}

      for (final ptr in ptrs) {
        final domain = ptr.domainName;
        String? host;
        int port = 8009;
        var name = domain.replaceAll('._googlecast._tcp.local', '');

        try {
          await for (final SrvResourceRecord srv in client
              .lookup<SrvResourceRecord>(ResourceRecordQuery.service(domain))
              .timeout(const Duration(seconds: 3),
                  onTimeout: (sink) => sink.close())) {
            port = srv.port;
            try {
              await for (final IPAddressResourceRecord ip in client
                  .lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target),
                  )
                  .timeout(const Duration(seconds: 2),
                      onTimeout: (sink) => sink.close())) {
                host = ip.address.address;
                break;
              }
            } catch (_) {}
            break;
          }
        } catch (_) {}

        try {
          await for (final TxtResourceRecord txt in client
              .lookup<TxtResourceRecord>(ResourceRecordQuery.text(domain))
              .timeout(const Duration(seconds: 2),
                  onTimeout: (sink) => sink.close())) {
            // txt.text puede ser List o String según versión
            final raw = txt.text.toString();
            final fn = RegExp(r'fn=([^\x00]+)').firstMatch(raw);
            if (fn != null) name = fn.group(1)!.trim();
            break;
          }
        } catch (_) {}

        if (host == null || host.isEmpty) continue;
        final id = '$host:$port';
        devices[id] = CastDevice(
          id: id,
          name: name.isNotEmpty ? name : 'Chromecast',
          protocol: CastProtocol.chromecast,
          host: host,
          port: port,
          model: 'Chromecast',
        );
      }
    } finally {
      client.stop();
    }
    return devices.values.toList();
  }

  /// Descubrimiento por SSDP del servicio DIAL (Chromecast / Android TV / etc.).
  Future<List<CastDevice>> _discoverDialSsdp(Duration timeout) async {
    final found = <String, CastDevice>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.multicastHops = 4;

      final dest = InternetAddress('239.255.255.250');
      void send(String st) {
        final msg = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: 239.255.255.250:1900\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 3\r\n'
            'ST: $st\r\n'
            '\r\n';
        socket!.send(utf8.encode(msg), dest, 1900);
      }

      for (var i = 0; i < 3; i++) {
        send('urn:dial-multiscreen-org:service:dial:1');
        send('urn:dial-multiscreen-org:device:dial:1');
        send('ssdp:all');
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        final low = text.toLowerCase();
        // Filtrar respuestas que parezcan Cast / DIAL / Google
        final isCast = low.contains('dial') ||
            low.contains('google') ||
            low.contains('chromecast') ||
            low.contains('android') ||
            low.contains('cast');
        if (!isCast) return;
        final loc = _header(text, 'LOCATION') ?? _header(text, 'Location');
        final host = dg.address.address;
        final id = loc ?? 'dial-$host';
        if (found.containsKey(id)) return;
        found[id] = CastDevice(
          id: id,
          name: 'Cast $host',
          protocol: CastProtocol.chromecast,
          host: host,
          port: 8009,
          location: loc,
          model: 'DIAL',
        );
      });

      await Future<void>.delayed(timeout);
      await sub.cancel();

      // Resolver nombres desde device-desc.xml si hay LOCATION
      final resolved = <CastDevice>[];
      for (final d in found.values) {
        var name = d.name;
        var port = d.port ?? 8009;
        final loc = d.location;
        if (loc != null) {
          try {
            final res = await http
                .get(Uri.parse(loc))
                .timeout(const Duration(seconds: 3));
            if (res.statusCode == 200) {
              final fn = _xmlTag(res.body, 'friendlyName');
              if (fn != null && fn.isNotEmpty) name = fn;
            }
          } catch (_) {}
        }
        resolved.add(CastDevice(
          id: d.id,
          name: name,
          protocol: CastProtocol.chromecast,
          host: d.host,
          port: port,
          location: loc,
          model: d.model,
        ));
      }
      return resolved;
    } finally {
      socket?.close();
    }
  }

  static String? _header(String raw, String name) {
    final re = RegExp(
      '^${RegExp.escape(name)}:\\s*(.+)\$',
      multiLine: true,
      caseSensitive: false,
    );
    return re.firstMatch(raw)?.group(1)?.trim();
  }

  static String? _xmlTag(String xml, String tag) {
    final re = RegExp('<$tag[^>]*>([^<]*)</$tag>', caseSensitive: false);
    return re.firstMatch(xml)?.group(1)?.trim();
  }
}
