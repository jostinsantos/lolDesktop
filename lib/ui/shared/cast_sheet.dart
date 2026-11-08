import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/models/repo_manifest.dart';
import '../../data/models/stream_server.dart';
import '../../data/services/content_service.dart';
import '../../data/services/cast_service.dart';
import '../../data/services/cast_controller.dart';
import '../../repo/player/cast_sheets.dart' show prepareCastMedia, CastMediaType;
import '../../repo/player/player_transmission.dart';

const _bg = Color(0xFF141A22);
const _accent = Color(0xFFE50914);

/// Flujo Transmitir: servidores → protocolo (DLNA/Cast) → dispositivo → pantalla de control.
class CastSheet {
  static Future<void> show({
    required BuildContext context,
    required InstalledRepo repo,
    required ContentItem item,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeId,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: _bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: _CastFlow(
            repo: repo,
            item: item,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            episodeId: episodeId,
          ),
        ),
      ),
    );
  }
}

class _CastFlow extends StatefulWidget {
  final InstalledRepo repo;
  final ContentItem item;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final String? episodeId;

  const _CastFlow({
    required this.repo,
    required this.item,
    this.season,
    this.episode,
    this.episodeTitle,
    this.episodeId,
  });

  @override
  State<_CastFlow> createState() => _CastFlowState();
}

class _CastFlowState extends State<_CastFlow> {
  int _step = 0; // 0 servers, 1 protocol, 2 devices, 3 connecting
  bool _loading = true;
  String? _error;
  List<StreamServer> _servers = [];
  StreamServer? _selected;
  CastProtocol? _protocol;
  List<CastDevice> _devices = [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final servers = await ContentService.instance.getStreams(
        widget.repo,
        widget.item.id,
        type: widget.item.type,
        season: widget.season,
        episode: widget.episode,
      );
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _loading = false;
        if (servers.isEmpty) _error = 'No hay servidores disponibles';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Error al cargar servidores: $e';
      });
    }
  }

  Future<void> _scanDevices() async {
    setState(() {
      _scanning = true;
      _devices = [];
      _error = null;
    });
    try {
      final list = await CastService.instance.discover(
         _protocol!,
        timeout: const Duration(seconds: 12),
      );
      if (!mounted) return;
      setState(() {
        _devices = list;
        _scanning = false;
        if (list.isEmpty) {
          _error = 'No se encontraron dispositivos. Revisa Wi‑Fi y permisos.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = 'Error buscando dispositivos: $e';
      });
    }
  }

  Future<void> _connect(CastDevice device) async {
    final server = _selected;
    if (server == null || _protocol == null) return;
    setState(() {
      _step = 3;
      _error = null;
    });
    try {
      final prepared = await prepareCastMedia(
        videoUrl: server.url,
        headers: server.headers,
        protocol: _protocol!,
      );
      final mime = switch (prepared.type) {
        CastMediaType.hls => 'application/x-mpegURL',
        CastMediaType.mp4 => 'video/mp4',
        CastMediaType.mkv => 'video/x-matroska',
        CastMediaType.unknown => null,
      };
      final session = await CastService.instance.connect(
        device: device,
        mediaUrl: prepared.url,
        title: widget.item.title,
        headers: server.headers,
        poster: widget.item.poster,
        mediaContentType: mime,
      );
      if (!mounted) return;

      // Intro/outro desde segments del servidor
      final seg = server.segments;
      final introS = (seg?.intro != null && seg!.intro!.length >= 2) ? seg.intro![0].toDouble() : -1.0;
      final introE = (seg?.intro != null && seg!.intro!.length >= 2) ? seg.intro![1].toDouble() : -1.0;
      final outroS = (seg?.outro != null && seg!.outro!.length >= 2) ? seg.outro![0].toDouble() : -1.0;
      final outroE = (seg?.outro != null && seg!.outro!.length >= 2) ? seg.outro![1].toDouble() : -1.0;

      CastController.instance.bind(
        castService: CastService.instance,
        castSession: session,
        castDevice: device,
        title: widget.episodeTitle?.isNotEmpty == true
            ? '${widget.item.title} · ${widget.episodeTitle}'
            : widget.item.title,
        poster: widget.item.poster,
        servers: _servers,
        serverIndex: _servers.indexOf(server).clamp(0, _servers.length - 1),
        headers: server.headers,
        season: widget.season,
        episode: widget.episode,
        episodeTitle: widget.episodeTitle,
        loadRepo: widget.repo,
        repoId: widget.repo.manifest.id,
        contentId: widget.item.id,
        contentType: widget.item.type,
        introStartSec: introS,
        introEndSec: introE,
        outroStartSec: outroS,
        outroEndSec: outroE,
      );

      Navigator.of(context).pop(); // cierra el modal
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerTransmissionPage(
            castService: CastService.instance,
            session: session,
            device: device,
            title: widget.episodeTitle?.isNotEmpty == true
                ? '${widget.item.title} · ${widget.episodeTitle}'
                : widget.item.title,
            poster: widget.item.poster,
            servers: _servers,
            initialServerIndex:
                _servers.indexOf(server).clamp(0, _servers.length - 1),
            headers: server.headers,
            season: widget.season,
            episode: widget.episode,
            episodeTitle: widget.episodeTitle,
            loadRepo: widget.repo,
            repoId: widget.repo.manifest.id,
            contentId: widget.item.id,
            contentType: widget.item.type,
            introStartSec: introS,
            introEndSec: introE,
            outroStartSec: outroS,
            outroEndSec: outroE,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = 2;
        _error = 'No se pudo conectar: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (_step > 0 && _step < 3)
                IconButton(
                  onPressed: () => setState(() {
                    _step--;
                    _error = null;
                  }),
                  icon: const Icon(Icons.arrow_back, color: Colors.white70),
                ),
              Expanded(
                child: Text(
                  _step == 0
                      ? 'Transmitir · Servidor'
                      : _step == 1
                          ? 'Tipo de transmisión'
                          : _step == 2
                              ? 'Elegir dispositivo'
                              : 'Conectando…',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading || _step == 3)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(color: _accent),
              ),
            )
          else if (_error != null && _step == 0)
            Expanded(
              child: Center(
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            )
          else if (_step == 0)
            Expanded(
              child: ListView.separated(
                itemCount: _servers.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final s = _servers[i];
                  return ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    tileColor: Colors.white.withValues(alpha: 0.06),
                    title: Text(s.name,
                        style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      [s.quality, s.language, s.provider]
                          .where((e) => e != null && e!.isNotEmpty)
                          .join(' · '),
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: const Icon(Icons.cast, color: Colors.white38),
                    onTap: () => setState(() {
                      _selected = s;
                      _step = 1;
                    }),
                  );
                },
              ),
            )
          else if (_step == 1)
            Expanded(
              child: Column(
                children: [
                  _protoTile(
                    CastProtocol.dlna,
                    Icons.tv_rounded,
                  ),
                  const SizedBox(height: 10),
                  _protoTile(
                    CastProtocol.chromecast,
                    Icons.cast_rounded,
                  ),
                ],
              ),
            )
          else if (_step == 2)
            Expanded(
              child: Column(
                children: [
                  if (_scanning)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(color: _accent),
                    )
                  else ...[
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Colors.orangeAccent, fontSize: 12)),
                      ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _devices.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final d = _devices[i];
                          return ListTile(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            tileColor: Colors.white.withValues(alpha: 0.06),
                            leading: Icon(
                              d.protocol == CastProtocol.dlna
                                  ? Icons.tv
                                  : Icons.cast,
                              color: Colors.white70,
                            ),
                            title: Text(d.name,
                                style: const TextStyle(color: Colors.white)),
                            subtitle: Text(d.protocol.label,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                            onTap: () => _connect(d),
                          );
                        },
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _scanDevices,
                      icon: const Icon(Icons.refresh, color: Colors.white54),
                      label: const Text('Buscar de nuevo',
                          style: TextStyle(color: Colors.white54)),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _protoTile(CastProtocol p, IconData icon) {
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: Colors.white.withValues(alpha: 0.06),
      leading: Icon(icon, color: _accent, size: 28),
      title: Text(p.label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(p.subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: () {
        setState(() {
          _protocol = p;
          _step = 2;
        });
        _scanDevices();
      },
    );
  }
}
