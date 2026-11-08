import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../data/services/cast_service.dart';
import 'cast_sheets.dart' show prepareCastMedia;
import '../../data/models/stream_server.dart';
import '../../data/models/repo_manifest.dart';
import '../../data/services/content_service.dart';
import '../../data/services/cast_controller.dart';

const _bg = Color(0xFF0B0F14);
const _card = Color(0xFF1A222D);
const _accent = Color(0xFFE50914);

/// Pantalla de control de transmisión (Cast / DLNA) — API local CastService.
class PlayerTransmissionPage extends StatefulWidget {
  final CastService castService;
  final CastSession session;
  final CastDevice device;
  final String title;
  final String? poster;
  final String? backdrop;
  final String? logo;
  final List<StreamServer> servers;
  final int initialServerIndex;
  final Map<String, String>? headers;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final int? nextSeason;
  final int? nextEpisode;
  final String? nextEpisodeId;
  final String? nextEpisodeTitle;
  final List<Map<String, dynamic>> episodeList;
  final InstalledRepo? loadRepo;
  final String? repoId;
  final String? contentId;
  final String contentType;
  final String preferredLanguage;
  final double introStartSec;
  final double introEndSec;
  final double outroStartSec;
  final double outroEndSec;

  const PlayerTransmissionPage({
    super.key,
    required this.castService,
    required this.session,
    required this.device,
    required this.title,
    this.poster,
    this.backdrop,
    this.logo,
    this.servers = const [],
    this.initialServerIndex = 0,
    this.headers,
    this.season,
    this.episode,
    this.episodeTitle,
    this.nextSeason,
    this.nextEpisode,
    this.nextEpisodeId,
    this.nextEpisodeTitle,
    this.episodeList = const [],
    this.loadRepo,
    this.repoId,
    this.contentId,
    this.contentType = 'movie',
    this.preferredLanguage = '',
    this.introStartSec = -1,
    this.introEndSec = -1,
    this.outroStartSec = -1,
    this.outroEndSec = -1,
  });

  @override
  State<PlayerTransmissionPage> createState() => _PlayerTransmissionPageState();
}

class _PlayerTransmissionPageState extends State<PlayerTransmissionPage> {
  late CastSession _session;
  late List<StreamServer> _servers;
  late int _serverIndex;
  bool _busy = false;
  bool _showServers = false;
  bool _isPlaying = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durSub;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _servers = List.of(widget.servers);
    _serverIndex = widget.initialServerIndex.clamp(
      0,
      _servers.isEmpty ? 0 : _servers.length - 1,
    );
    _position = _session.position;
    _duration = _session.duration;
    _isPlaying = _session.isPlaying;
    _bindStreams();
    _session.addListener(_onSessionNotify);
  }

  void _onSessionNotify() {
    if (!mounted) return;
    setState(() {
      _position = _session.position;
      _duration = _session.duration;
      _isPlaying = _session.isPlaying;
    });
    CastController.instance.updateProgress(
      _session.position,
      _session.duration,
      isPlaying: _session.isPlaying,
    );
  }

  void _bindStreams() {
    _posSub = _session.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = _session.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _stateSub = _session.stateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _isPlaying = s == CastSessionState.playing ||
            s == CastSessionState.buffering;
      });
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _session.removeListener(_onSessionNotify);
    super.dispose();
  }

  bool get _hasNext =>
      widget.nextSeason != null && widget.nextEpisode != null;

  bool get _canSkipIntro {
    final a = widget.introStartSec;
    final b = widget.introEndSec;
    if (a < 0 || b <= a) return false;
    final sec = _position.inMilliseconds / 1000.0;
    return sec >= a && sec < b;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  Future<void> _togglePlay() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_isPlaying) {
        await _session.pause();
      } else {
        await _session.play();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seekTo(Duration to) async {
    final max = _duration > Duration.zero ? _duration : to;
    final clamped = to < Duration.zero
        ? Duration.zero
        : (to > max ? max : to);
    try {
      await _session.seek(clamped);
      if (mounted) setState(() => _position = clamped);
    } catch (_) {}
  }

  Future<void> _skipIntro() async {
    final end = widget.introEndSec;
    if (end <= 0) return;
    await _seekTo(Duration(milliseconds: (end * 1000).round() + 300));
  }

  Future<void> _changeServer(int index) async {
    if (index < 0 || index >= _servers.length || _busy) return;
    setState(() {
      _busy = true;
      _showServers = false;
      _serverIndex = index;
    });
    try {
      final s = _servers[index];
      final prepared = await prepareCastMedia(
        videoUrl: s.url,
        headers: s.headers,
        protocol: widget.device.protocol,
      );
      await _session.loadMedia(
        url: prepared.url,
        title: widget.title,
        headers: s.headers,
        poster: widget.poster,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cambiar servidor: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _nextEpisode() async {
    if (!_hasNext || widget.loadRepo == null || _busy) return;
    setState(() => _busy = true);
    try {
      final id = widget.nextEpisodeId ?? widget.contentId ?? '';
      final servers = await ContentService.instance.getStreams(
        widget.loadRepo!,
        id,
        type: widget.contentType,
        season: widget.nextSeason,
        episode: widget.nextEpisode,
      );
      if (servers.isEmpty) throw Exception('Sin servidores');
      final s = servers.first;
      final prepared = await prepareCastMedia(
        videoUrl: s.url,
        headers: s.headers,
        protocol: widget.device.protocol,
      );
      final title = widget.nextEpisodeTitle ??
          '${widget.title} · T${widget.nextSeason} E${widget.nextEpisode}';
      await _session.loadMedia(
        url: prepared.url,
        title: title,
        headers: s.headers,
        poster: widget.poster,
      );
      if (mounted) {
        setState(() {
          _servers = servers;
          _serverIndex = 0;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Siguiente episodio: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopAndClose() async {
    try {
      await CastController.instance.stopAndClear();
    } catch (_) {}
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Stack(
          children: [
            // Poster de fondo
            if (widget.poster != null && widget.poster!.isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.25,
                  child: CachedNetworkImage(
                    imageUrl: widget.poster!,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              '${widget.device.name} · ${widget.device.protocol.label}',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _accent,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: 'Detener',
                        onPressed: _stopAndClose,
                        icon: const Icon(Icons.stop_circle_outlined,
                            color: Colors.redAccent),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Controles
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Barra de progreso
                      Row(
                        children: [
                          Text(_fmt(_position),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: _accent,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 7),
                              ),
                              child: Slider(
                                value: progress,
                                onChanged: (v) {
                                  if (_duration.inMilliseconds <= 0) return;
                                  final to = Duration(
                                    milliseconds:
                                        (v * _duration.inMilliseconds).round(),
                                  );
                                  setState(() => _position = to);
                                },
                                onChangeEnd: (v) {
                                  if (_duration.inMilliseconds <= 0) return;
                                  final to = Duration(
                                    milliseconds:
                                        (v * _duration.inMilliseconds).round(),
                                  );
                                  _seekTo(to);
                                },
                              ),
                            ),
                          ),
                          Text(_fmt(_duration),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Botones principales
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: () => _seekTo(
                                _position - const Duration(seconds: 10)),
                            icon: const Icon(Icons.replay_10,
                                color: Colors.white, size: 32),
                          ),
                          const SizedBox(width: 12),
                          IconButton.filled(
                            onPressed: _togglePlay,
                            style: IconButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.all(16),
                            ),
                            icon: Icon(
                              _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 36,
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            onPressed: () => _seekTo(
                                _position + const Duration(seconds: 10)),
                            icon: const Icon(Icons.forward_10,
                                color: Colors.white, size: 32),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          if (_canSkipIntro)
                            OutlinedButton.icon(
                              onPressed: _skipIntro,
                              icon: const Icon(Icons.skip_next, size: 18),
                              label: const Text('Saltar intro'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white38),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                setState(() => _showServers = !_showServers),
                            icon: const Icon(Icons.dns_outlined, size: 18),
                            label: Text(
                              _servers.isEmpty
                                  ? 'Servidor'
                                  : _servers[_serverIndex.clamp(
                                      0, _servers.length - 1)].name,
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white38),
                            ),
                          ),
                          if (_hasNext)
                            FilledButton.icon(
                              onPressed: _nextEpisode,
                              icon: const Icon(Icons.skip_next_rounded),
                              label: const Text('Siguiente'),
                              style: FilledButton.styleFrom(
                                backgroundColor: _accent,
                              ),
                            ),
                        ],
                      ),
                      if (_showServers && _servers.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _servers.length,
                            itemBuilder: (_, i) {
                              final s = _servers[i];
                              final sel = i == _serverIndex;
                              return ListTile(
                                dense: true,
                                selected: sel,
                                title: Text(s.name,
                                    style: const TextStyle(color: Colors.white)),
                                subtitle: Text(
                                  [s.quality, s.language]
                                      .where((e) => e != null && e!.isNotEmpty)
                                      .join(' · '),
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 11),
                                ),
                                trailing: sel
                                    ? const Icon(Icons.check,
                                        color: _accent, size: 18)
                                    : null,
                                onTap: () => _changeServer(i),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
