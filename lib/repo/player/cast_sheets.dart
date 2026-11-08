import 'package:flutter/foundation.dart';
import '../../data/services/cast_service.dart';
import '../../data/services/stream_proxy.dart';

enum CastMediaType { hls, mp4, mkv, unknown }

/// Prepara URL + tipo de media para Cast/DLNA.
Future<({String url, CastMediaType type})> prepareCastMedia({
  required String videoUrl,
  Map<String, String> headers = const {},
  required CastProtocol protocol,
}) async {
  final isHls = StreamProxy.isHls(videoUrl);
  final isTs = !isHls && StreamProxy.isMpegTs(videoUrl);

  final hasAuthHeaders = headers.keys.any((k) {
    final l = k.toLowerCase();
    return l == 'referer' ||
        l == 'origin' ||
        l == 'authorization' ||
        l == 'cookie';
  });

  final needsProxy =
      isTs || protocol == CastProtocol.dlna || hasAuthHeaders;

  var playUrl = videoUrl;
  if (needsProxy) {
    try {
      playUrl = await StreamProxy.instance.start(
        upstreamUrl: videoUrl,
        headers: headers,
      );
      debugPrint(
          '[Cast] proxy → $playUrl (ts=$isTs hls=$isHls dlna=${protocol == CastProtocol.dlna})');
    } catch (e) {
      debugPrint('[Cast] proxy falló, URL directa: $e');
    }
  }

  final CastMediaType type;
  final lower = playUrl.toLowerCase();
  if (isHls || lower.contains('.m3u8')) {
    type = CastMediaType.hls;
  } else if (isTs || lower.contains('.ts')) {
    type = CastMediaType.hls;
  } else if (lower.contains('.mkv')) {
    type = CastMediaType.mkv;
  } else if (lower.contains('.mp4')) {
    type = CastMediaType.mp4;
  } else {
    type = CastMediaType.mp4;
  }

  return (url: playUrl, type: type);
}
