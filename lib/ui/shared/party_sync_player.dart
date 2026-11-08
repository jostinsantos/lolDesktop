import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/models/repo_manifest.dart';
import '../../data/models/stream_server.dart';
import '../../data/services/content_service.dart';
import '../../data/services/party_service.dart';

const _accent = Color(0xFFE50914);
const _panel = Color(0xFF0E1117);
const _card = Color(0xFF161A22);
const _border = Color(0xFF1E2430);
const _muted = Color(0x99FFFFFF);

const _quickEmojis = ['😂', '🔥', '❤️', '👏', '😮', '🎉', '👍', '💀'];

/// Player dedicado de sala Party.
class PartySyncPlayer extends StatefulWidget {
  final PartyRoom room;
  final InstalledRepo repo;
  final bool isTv;

  const PartySyncPlayer({
    super.key,
    required this.room,
    required this.repo,
    this.isTv = false,
  });

  @override
  State<PartySyncPlayer> createState() => _PartySyncPlayerState();
}

class _PartySyncPlayerState extends State<PartySyncPlayer>
    with TickerProviderStateMixin {
  final PartyService _party = PartyService.instance;

  List<StreamServer> _servers = [];
  StreamServer? _selected;
  bool _loading = true;
  String? _error;

  Player? _player;
  VideoController? _video;
  VideoPlayerController? _vp;
  bool _useMediaKit = true;
  final List<StreamSubscription> _subs = [];

  bool _playing = false;
  bool _buffering = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _dragging = false;

  bool _showUi = true;
  Timer? _hideTimer;

  int _mobileTab = 0;
  bool _mobileFullscreen = false;

  /// Desktop Meet: sidebar derecha
  bool _sidebarOpen = true;
  int _sidebarTab = 0; // 0 chat, 1 miembros, 2 ajustes

  /// TV modals
  bool _modalChat = false;
  bool _modalMembers = false;
  bool _modalSettings = false;

  /// Audio / subtítulos (mismo enfoque que player principal)
  bool _showTracks = false;
  List<AudioTrack> _audioTracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  AudioTrack? _selectedAudio;
  SubtitleTrack? _selectedSubtitle;
  List<ExternalSubtitle> _externalSubs = [];
  bool _externalSubActive = false;

  // PC: pantalla completa y PiP (como player principal)
  bool _isFullscreen = false;
  bool _isPip = false;
  Rect? _windowBoundsBeforeSpecial;
  static const _pipChannel = MethodChannel('com.lol.lite/channel');


  final _chatCtrl = TextEditingController();
  final _chatScroll = ScrollController();
  bool _applyingRemote = false;
  bool _syncStarted = false;
  Timer? _hostPushTimer;
  Timer? _pollTimer;
  String? _lastAppliedKey;
  String? _lastContentKey;

  /// Emojis flotantes en pantalla
  final List<_FlyingEmoji> _flying = [];

  /// Solo host real según BD/servicio (NO widget.room)
  bool get _isHost => _party.isHost;

  /// Ancho de pantalla cacheado tras el primer frame (evita MediaQuery en initState).
  double _screenWidth = 800;
  bool _depsReady = false;

  bool get _twitchLayout {
    if (widget.isTv || _mobileFullscreen) return false;
    if (!_depsReady) return !widget.isTv; // fallback móvil hasta tener size
    return _screenWidth < 700;
  }

  bool get _meetLayout {
    if (widget.isTv || _twitchLayout) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    // Nada de MediaQuery / Theme / ScaffoldMessenger aquí.
    try {
      WakelockPlus.enable();
    } catch (_) {}
    try {
      MediaKit.ensureInitialized();
    } catch (_) {}
    if (widget.isTv) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _party.addListener(_onParty);
    // Bootstrap DESPUÉS del primer frame (context ya tiene InheritedWidgets)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _depsReady = true;
      _screenWidth = MediaQuery.sizeOf(context).width;
      _lockDesktopIfNeeded();
      _bootstrap();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Seguro: se llama tras initState y cuando cambian dependencias.
    _depsReady = true;
    _screenWidth = MediaQuery.sizeOf(context).width;
  }

  void _applyOrientation() {
    if (!mounted || !_depsReady) return;
    if (widget.isTv || _mobileFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (_screenWidth < 700) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    try {
      await _party.init();
      if (!mounted) return;
      // Si no estamos en esta sala, unirse (invitado)
      if (_party.currentRoom?.id != widget.room.id) {
        try {
          await _party.joinRoom(widget.room.code);
        } catch (e) {
          debugPrint('[Party] join bootstrap: $e');
        }
      }
      if (!mounted) return;
      // Sala privada pendiente: no cargar vídeo hasta aceptación
      if (_party.isPendingMember && !_party.isHost) {
        setState(() {
          _loading = false;
          _error = null;
        });
        return;
      }
      await _loadStreams();
    } catch (e) {
      debugPrint('[Party] bootstrap error: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hostPushTimer?.cancel();
    _pollTimer?.cancel();
    _party.removeListener(_onParty);
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    _vp?.dispose();
    _chatCtrl.dispose();
    _chatScroll.dispose();
    // No cerrar sala al dispose si es host — el usuario elige en el diálogo
    if (!_isHost) {
      unawaited(_party.leaveCurrentRoom(silent: true));
    }
    WakelockPlus.disable();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onParty() {
    if (!mounted || !_depsReady) return;
    if (_party.kickedFromRoom) {
      // Salir de la sala/player de inmediato (tiempo real)
      _party.kickedFromRoom = false;
      _hostPushTimer?.cancel();
      _pollTimer?.cancel();
      _syncStarted = false;
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('El host te ha quitado de la sala')),
        );
      } catch (_) {}
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    if (_party.currentRoom == null) {
      _hostPushTimer?.cancel();
      _pollTimer?.cancel();
      _syncStarted = false;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }
    if (_party.isRoomExpired) {
      unawaited(_party.leaveCurrentRoom());
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    // Detectar reacciones nuevas
    for (final m in _party.messages) {
      if (m.message.startsWith('__reaction__:') &&
          m.id != null &&
          !_seenReactions.contains(m.id)) {
        _seenReactions.add(m.id!);
        final emoji = m.message.replaceFirst('__reaction__:', '');
        _spawnEmoji(emoji);
      }
    }

    // Pasó de pending → accepted
    if (!_loading && _selected == null && _party.isAcceptedMember && !_party.isPendingMember) {
      unawaited(_loadStreams());
    }
    // Host cambió de capítulo: recargar streams
    final cr = _party.currentRoom;
    if (cr != null) {
      final ck = '${cr.contentId}|${cr.season}|${cr.episode}|${cr.title}';
      if (_lastContentKey != null && _lastContentKey != ck) {
        _lastContentKey = ck;
        _syncStarted = false;
        _selected = null;
        unawaited(_loadStreams());
      } else {
        _lastContentKey ??= ck;
      }
    }
    // Actualizar UI de miembros/chat en tiempo real
    setState(() {});
    _tryStartSync();
    // Solo aplicar remoto si el estado cambió (sin force) para no trabar el vídeo
    if (!_isHost) _applyRemote(force: false);
    if (_chatScroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_chatScroll.hasClients) {
          _chatScroll.animateTo(
            _chatScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  final Set<String> _seenReactions = {};

  void _spawnEmoji(String emoji) {
    final rnd = math.Random();
    // Varias partículas grandes para que se note en toda la pantalla
    final batch = <_FlyingEmoji>[];
    for (var i = 0; i < 7; i++) {
      final id =
          DateTime.now().microsecondsSinceEpoch + rnd.nextInt(99999) + i * 17;
      batch.add(_FlyingEmoji(
        id: id,
        emoji: emoji,
        x: 0.05 + rnd.nextDouble() * 0.9,
        size: 52.0 + rnd.nextDouble() * 36,
        drift: (rnd.nextDouble() - 0.5) * 80,
        rise: 180.0 + rnd.nextDouble() * 220,
        durationMs: 1800 + rnd.nextInt(1200),
      ));
    }
    setState(() => _flying.addAll(batch));
    for (final fe in batch) {
      Future.delayed(Duration(milliseconds: fe.durationMs + 200), () {
        if (mounted) setState(() => _flying.removeWhere((e) => e.id == fe.id));
      });
    }
  }

  int _pickPreferred(List<StreamServer> list) {
    final pref = ((_party.currentRoom ?? widget.room).language ?? '').trim().toLowerCase();
    if (pref.isEmpty || list.isEmpty) return 0;
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      final name = list[i].name.toLowerCase();
      if (lang.contains(pref) || pref.contains(lang) || name.contains(pref)) {
        return i;
      }
    }
    for (var i = 0; i < list.length; i++) {
      final lang = (list[i].language ?? '').toLowerCase();
      if (pref.startsWith('lat') && lang.contains('lat')) return i;
      if (pref.startsWith('cast') && lang.contains('cast')) return i;
      if (pref.startsWith('ing') && (lang.contains('ing') || lang.contains('en'))) {
        return i;
      }
      if (pref.startsWith('sub') && lang.contains('sub')) return i;
    }
    return 0;
  }

  Future<void> _loadStreams() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // SIEMPRE sala actual (tras cambiar capítulo ya no es widget.room)
      final room = _party.currentRoom ?? widget.room;
      final list = await ContentService.instance.getStreams(
        widget.repo,
        room.contentId,
        type: room.contentType,
        season: room.season,
        episode: room.episode,
      );
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No hay servidores para este contenido';
        });
        return;
      }
      _servers = list;
      _selected = list[_pickPreferred(list)];
      setState(() => _loading = false);
      await _openServer(_selected!);
      await _party.setServerReady(true);
      if (_isHost) {
        // Publicar URL/servidor nuevo para que los invitados cambien de capítulo
        await _push(forcePlay: false);
      }
      _tryStartSync();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Se fija en el primer frame; NO depende del ancho actual (PiP reduce la ventana).
  bool _desktopLocked = false;
  bool _desktopLockDone = false;

  bool get _isDesktopParty {
    if (widget.isTv) return false;
    if (_desktopLockDone) return _desktopLocked;
    return _screenWidth >= 700;
  }

  void _lockDesktopIfNeeded() {
    if (_desktopLockDone || widget.isTv) return;
    _desktopLocked = _screenWidth >= 700;
    _desktopLockDone = true;
  }

  String _detectKind(StreamServer s) {
    final u = s.url.toLowerCase();
    if (s.isHls || u.contains('.m3u8') || u.contains('type=hls')) return 'hls';
    if (u.contains('.ts') || u.contains('mpegts') || u.contains('mpeg-ts')) {
      return 'ts';
    }
    return 'other';
  }

  /// PC: SIEMPRE media_kit.
  /// Móvil / TV: HLS → video_player, TS/other → media_kit.
  /// Cada dispositivo elige su motor local; no se hereda el del host
  /// (si el host es PC publica media_kit y rompería HLS en móvil/TV).
  String _engineForLocal(StreamServer s) {
    if (_isDesktopParty) return 'media_kit';
    return _detectKind(s) == 'hls' ? 'video_player' : 'media_kit';
  }

  bool _shouldUseMediaKit(StreamServer s) {
    // PC siempre media_kit
    if (_isDesktopParty) return true;
    // Móvil / TV: solo por tipo de stream local
    return _detectKind(s) != 'hls';
  }

  Future<void> _disposeEngines() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    _player = null;
    _video = null;
    await _vp?.dispose();
    _vp = null;
  }

  Future<void> _openServer(StreamServer server) async {
    await _disposeEngines();
    final url = server.url.trim();
    if (url.isEmpty) {
      setState(() => _error = 'URL de stream vacía');
      return;
    }
    final kind = _detectKind(server);
    final useMk = _shouldUseMediaKit(server);
    _useMediaKit = useMk;
    _selected = server;

    final headers = <String, String>{...server.headers};
    headers.putIfAbsent(
      'User-Agent',
      () =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    );

    debugPrint(
        '[Party] engine=${useMk ? "media_kit" : "video_player"} kind=$kind desktop=$_isDesktopParty');

    try {
      if (useMk) {
        try {
          MediaKit.ensureInitialized();
        } catch (_) {}
        // Misma configuración que el player original (PC/móvil/TV) para carga estable
        final player = Player(
          configuration: const PlayerConfiguration(
            title: 'LOL Party',
            bufferSize: 32 * 1024 * 1024,
          ),
        );
        try {
          final platform = player.platform;
          if (platform != null) {
            await (platform as dynamic).setProperty('demuxer-lavf-analyzeduration', '15');
            await (platform as dynamic).setProperty('demuxer-lavf-probesize', '50000000');
            await (platform as dynamic).setProperty('network-timeout', '60');
            await (platform as dynamic).setProperty('cache', 'yes');
            await (platform as dynamic).setProperty('cache-secs', '30');
            await (platform as dynamic).setProperty('tls-verify', 'no');
            await (platform as dynamic).setProperty('sub-visibility', 'yes');
            // Una sola capa de subtítulos con estilo (como player principal)
            await (platform as dynamic).setProperty('sub-ass-override', 'force');
            await (platform as dynamic).setProperty('sub-font-size', '42');
            await (platform as dynamic).setProperty('sub-margin-y', '18');
            await (platform as dynamic).setProperty('sub-border-size', '2');
            await (platform as dynamic).setProperty('sub-bold', 'yes');
          }
        } catch (_) {}
        final video = VideoController(
          player,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _player = player;
        _video = video;
        _audioTracks = [];
        _subtitleTracks = [];
        _selectedAudio = null;
        _selectedSubtitle = null;
        _externalSubs = List.from(server.subtitles);
        _externalSubActive = false;
        _subs.add(player.stream.playing.listen((v) {
          if (!mounted || _applyingRemote) return;
          setState(() => _playing = v);
          if (v) _armHide();
          if (_isHost && _syncStarted) unawaited(_push(forcePlay: v));
        }));
        _subs.add(player.stream.buffering.listen((v) {
          if (mounted) setState(() => _buffering = v);
        }));
        _subs.add(player.stream.position.listen((v) {
          if (!mounted || _dragging) return;
          setState(() => _position = v);
        }));
        _subs.add(player.stream.duration.listen((v) {
          if (mounted) setState(() => _duration = v);
        }));
        _subs.add(player.stream.tracks.listen((tracks) {
          if (!mounted) return;
          final audios = tracks.audio
              .where((t) => t.id != 'auto' && t.id != 'no')
              .toList();
          final subs = tracks.subtitle
              .where((t) => t.id != 'auto' && t.id != 'no')
              .toList();
          setState(() {
            _audioTracks = audios;
            _subtitleTracks = subs;
          });
        }));
        await player.open(Media(url, httpHeaders: headers), play: false);
        // No auto-cargar subtítulo: el usuario elige en el panel (evita doble capa motor+estilo)
        try {
          await player.setSubtitleTrack(SubtitleTrack.no());
        } catch (_) {}
      } else {
        _externalSubs = List.from(server.subtitles);
        _audioTracks = [];
        _subtitleTracks = [];
        _selectedAudio = null;
        _selectedSubtitle = null;
        _externalSubActive = false;
        final ctrl = VideoPlayerController.networkUrl(
          Uri.parse(url),
          httpHeaders: headers,
          formatHint: VideoFormat.hls,
        );
        await ctrl.initialize();
        await ctrl.pause();
        _vp = ctrl;
        _subs.add(
            Stream.periodic(const Duration(milliseconds: 400)).listen((_) {
          if (!mounted || _vp == null || _dragging) return;
          final v = _vp!.value;
          setState(() {
            _playing = v.isPlaying;
            _buffering = v.isBuffering;
            _position = v.position;
            _duration = v.duration;
          });
        }));
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[Party] open failed: $e');
      if (mounted) setState(() => _error = 'No se pudo abrir el stream: $e');
    }
  }

  void _tryStartSync() {
    if (_syncStarted) return;
    if (!_party.allMembersHaveServer) return;
    if (_selected == null) return;
    // No iniciar sync si estamos pendientes de aceptación
    if (_party.isPendingMember && !_isHost) return;
    _syncStarted = true;

    if (_isHost) {
      unawaited(_push(forcePlay: false));
      _hostPushTimer?.cancel();
      // Host publica cada 2s (suficiente; los cambios de play/seek se empujan al instante)
      _hostPushTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_isHost && _syncStarted && !_applyingRemote) {
          unawaited(_push());
        }
      });
    } else {
      _applyRemote(force: true);
      _pollTimer?.cancel();
      // Invitado: poll suave cada 2.5s SOLO para refrescar sala (playback + miembros).
      // NO forzar apply siempre: solo cuando el estado remoto cambie de verdad.
      // Así se evita seek/pause constante que traba el vídeo en móvil.
      _pollTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        if (!mounted || _isHost) return;
        await _party.refreshRoom();
        // También refrescar miembros por si el realtime falló (kick, joins)
        // refreshRoom no trae members; _onParty ya reacciona a notifyListeners.
        _applyRemote(force: false);
      });
    }
    if (mounted) setState(() {});
  }

  Future<void> _push({bool? forcePlay}) async {
    if (!_isHost || _selected == null) return;
    final kind = _detectKind(_selected!);
    // PC siempre publica media_kit; móvil publica el motor real
    final engine = _isDesktopParty ? 'media_kit' : _engineForLocal(_selected!);
    final state = PlaybackState(
      isPlaying: forcePlay ?? _playing,
      positionMs: _position.inMilliseconds,
      serverIndex: _servers.indexOf(_selected!),
      serverName: _selected!.name,
      streamUrl: _selected!.url,
      headers: Map<String, String>.from(_selected!.headers),
      isHls: kind == 'hls',
      engine: engine,
      streamKind: kind,
    );
    await _party.updatePlayback(state);
  }

  void _applyRemote({bool force = false}) {
    if (_isHost) return;
    if (!_syncStarted && !force) return;
    final room = _party.currentRoom;
    if (room == null) return;
    final pb = room.playbackState;
    if (pb.streamUrl == null || pb.streamUrl!.isEmpty) return;

    // Clave más gruesa: posición en bloques de ~2s para no re-aplicar por drift normal
    final key =
        '${pb.isPlaying}|${pb.positionMs ~/ 2000}|${pb.streamUrl}|${pb.updatedAt?.millisecondsSinceEpoch}';
    if (!force && key == _lastAppliedKey) return;
    _lastAppliedKey = key;

    final needServer = _selected?.url != pb.streamUrl;
    if (needServer) {
      StreamServer? match;
      for (final s in _servers) {
        if (s.url == pb.streamUrl) {
          match = s;
          break;
        }
      }
      match ??= StreamServer(
        name: pb.serverName ?? 'Party',
        url: pb.streamUrl!,
        headers: pb.headers,
        isHls: pb.isHls,
      );
      unawaited(_openServer(match).then((_) => _applyPosAndPlay(pb)));
    } else {
      unawaited(_applyPosAndPlay(pb));
    }
  }

  Future<void> _applyPosAndPlay(PlaybackState pb) async {
    if (_applyingRemote) return;
    _applyingRemote = true;
    try {
      final target = Duration(milliseconds: pb.positionMs);
      // Umbral amplio (2s): evita seeks constantes que cortan el buffer en móvil.
      // Solo corregir si el desfase es grande; el vídeo local sigue su ritmo.
      const seekThreshold = Duration(milliseconds: 2000);
      if (_useMediaKit && _player != null) {
        final p = _player!;
        // No buscar mientras está bufferizando: empeora el stutter
        final buffering = p.state.buffering;
        final diff = (p.state.position - target).abs();
        if (!buffering && diff > seekThreshold) {
          await p.seek(target);
        }
        if (pb.isPlaying && !p.state.playing) {
          await p.play();
        } else if (!pb.isPlaying && p.state.playing) {
          await p.pause();
        }
      } else if (_vp != null) {
        final buffering = _vp!.value.isBuffering;
        final diff = (_vp!.value.position - target).abs();
        if (!buffering && diff > seekThreshold) {
          await _vp!.seekTo(target);
        }
        if (pb.isPlaying && !_vp!.value.isPlaying) {
          await _vp!.play();
        } else if (!pb.isPlaying && _vp!.value.isPlaying) {
          await _vp!.pause();
        }
      }
    } finally {
      _applyingRemote = false;
    }
  }

  Future<void> _togglePlay() async {
    if (!_isHost || !_syncStarted) return;
    if (_useMediaKit && _player != null) {
      if (_player!.state.playing) {
        await _player!.pause();
      } else {
        await _player!.play();
      }
    } else if (_vp != null) {
      if (_vp!.value.isPlaying) {
        await _vp!.pause();
      } else {
        await _vp!.play();
      }
    }
    await _push();
  }

  Future<void> _seek(Duration d) async {
    if (!_isHost || !_syncStarted) return;
    if (_useMediaKit) {
      await _player?.seek(d);
    } else {
      await _vp?.seekTo(d);
    }
    setState(() => _position = d);
    await _push();
  }

  Future<void> _selectServer(StreamServer s) async {
    if (!_isHost) return;
    await _openServer(s);
    await _party.setServerReady(true);
    await _push(forcePlay: false);
  }

  Future<void> _copyCode() async {
    final code = (_party.currentRoom ?? widget.room).code;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Código $code copiado')),
    );
  }

  Future<void> _onLeavePressed() async {
    if (_isHost) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text('Salir de la sala',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            'Eres el host. ¿Qué quieres hacer?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'transfer'),
              child: const Text('Ceder host y salir'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(ctx, 'close'),
              child: const Text('Cerrar sala'),
            ),
          ],
        ),
      );
      if (action == 'close') {
        await _party.endAndDeleteRoom();
        if (mounted) Navigator.of(context).maybePop();
      } else if (action == 'transfer') {
        final members = _party.members
            .where((m) => m.status == 'accepted' && m.userId != _party.userId)
            .toList();
        if (members.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('No hay nadie a quien ceder el host')),
            );
          }
          return;
        }
        final chosen = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _card,
            title: const Text('Ceder host a…',
                style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: members
                    .map((m) => ListTile(
                          title: Text(m.username,
                              style: const TextStyle(color: Colors.white)),
                          onTap: () => Navigator.pop(ctx, m.userId),
                        ))
                    .toList(),
              ),
            ),
          ),
        );
        if (chosen != null) {
          await _party.transferHost(chosen);
          await _party.leaveAsMember();
          if (mounted) Navigator.of(context).maybePop();
        }
      }
    } else {
      await _party.leaveAsMember();
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  void _toggleMobileFullscreen() {
    final next = !_mobileFullscreen;
    setState(() {
      _mobileFullscreen = next;
      _showUi = true;
    });
    // Forzar orientación de forma explícita (horizontal ↔ vertical)
    if (next) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // Reaplicar tras un frame (algunos dispositivos ignoran el primer set)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyOrientation();
      setState(() {});
    });
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (_showTracks || _isPip) return;
    _hideTimer = Timer(const Duration(milliseconds: 3000), () {
      if (!mounted) return;
      if (_showTracks || _isPip) return;
      if (_playing || _syncStarted) {
        setState(() => _showUi = false);
      }
    });
  }

  Future<void> _toggleDesktopFullscreen() async {
    try {
      if (_isFullscreen) {
        // Salir de pantalla completa y forzar que la barra superior reaparezca
        await windowManager.setFullScreen(false);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        // Por si el evento onWindowLeaveFullScreen no llega a CustomTitleBar
        try {
          final still = await windowManager.isFullScreen();
          if (still) {
            await windowManager.setFullScreen(false);
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
        } catch (_) {}
        if (mounted) setState(() => _isFullscreen = false);
      } else {
        if (_isPip) await _exitPip(restoreFullscreen: false);
        // Marcar antes para no reconstruir UI pesada a medias
        if (mounted) setState(() => _isFullscreen = true);
        await windowManager.setFullScreen(true);
      }
    } catch (e) {
      debugPrint('[Party] fullscreen: $e');
      if (mounted) setState(() => _isFullscreen = !_isFullscreen);
    }
  }

  Future<void> _togglePip() async {
    // Móvil: MethodChannel nativo
    if (!_isDesktopParty) {
      try {
        if (_useMediaKit && _player != null && !_player!.state.playing) {
          await _player!.play();
        } else if (_vp != null && !_vp!.value.isPlaying) {
          await _vp!.play();
        }
        final ok = await _pipChannel.invokeMethod<bool>('enterPip');
        if (ok != true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Picture-in-Picture no disponible en este dispositivo'),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo activar PiP: $e')),
          );
        }
      }
      return;
    }
    // PC: ventana pequeña always-on-top
    try {
      if (_isPip) {
        await _exitPip();
      } else {
        try {
          _windowBoundsBeforeSpecial = await windowManager.getBounds();
        } catch (_) {}
        if (_isFullscreen) {
          await windowManager.setFullScreen(false);
          if (mounted) setState(() => _isFullscreen = false);
        }
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setSize(const Size(420, 260));
        await windowManager.setAlignment(Alignment.bottomRight);
        if (mounted) setState(() => _isPip = true);
      }
    } catch (e) {
      debugPrint('[Party] pip: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PiP requiere window_manager')),
        );
      }
    }
  }

  Future<void> _exitPip({bool restoreFullscreen = false}) async {
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(900, 560));
      if (_windowBoundsBeforeSpecial != null) {
        await windowManager.setBounds(_windowBoundsBeforeSpecial!);
      } else {
        await windowManager.setSize(const Size(1280, 720));
        await windowManager.center();
      }
      // Restaurar UI completa (controles, sidebar, etc.)
      if (mounted) {
        setState(() {
          _isPip = false;
          _showUi = true;
        });
        _armHide();
      }
      if (restoreFullscreen) {
        await windowManager.setFullScreen(true);
        if (mounted) setState(() => _isFullscreen = true);
      }
    } catch (e) {
      debugPrint('[Party] exit pip: $e');
      if (mounted) {
        setState(() {
          _isPip = false;
          _showUi = true;
        });
      }
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  List<PartyMessage> get _chatMessages => _party.messages
      .where((m) => !m.message.startsWith('__reaction__:'))
      .toList();

  // ══════════════════════ BUILD ══════════════════════

  @override
  Widget build(BuildContext context) {
    // Página completa de espera (sala privada)
    if (_party.isPendingMember && !_isHost) {
      return _buildWaitingRoomPage();
    }
    // PiP: SOLO vídeo + botón salir (sin chat, barra, sidebar…)
    if (_isPip) {
      return Material(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoSurface(),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => unawaited(_exitPip()),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.picture_in_picture_alt_rounded,
                            color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text('Salir de PiP',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    // Atrás del sistema / gesto = mismo modal que colgar sala
    Widget child;
    if (_twitchLayout) {
      child = _buildMobileTwitch();
    } else if (_meetLayout) {
      child = _buildMeetDesktop();
    } else {
      child = _buildImmersive();
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showTracks) {
          setState(() => _showTracks = false);
          return;
        }
        if (_modalChat || _modalMembers || _modalSettings) {
          setState(() {
            _modalChat = false;
            _modalMembers = false;
            _modalSettings = false;
          });
          return;
        }
        unawaited(_onLeavePressed());
      },
      child: child,
    );
  }

  Widget _buildWaitingRoomPage() {
    final room = _party.currentRoom ?? widget.room;
    return Scaffold(
      backgroundColor: _panel,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: _card,
                      shape: BoxShape.circle,
                      border: Border.all(color: _accent.withValues(alpha: 0.5), width: 2),
                    ),
                    child: const Icon(Icons.hourglass_top_rounded,
                        color: _accent, size: 48),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'En espera de ser aceptado',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'El host de la sala debe aceptar tu entrada.\nCódigo: ${room.code}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    room.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 28),
                  const CircularProgressIndicator(color: _accent),
                  const SizedBox(height: 28),
                  OutlinedButton(
                    onPressed: () async {
                      await _party.leaveAsMember();
                      if (mounted) Navigator.of(context).maybePop();
                    },
                    child: const Text('Cancelar y salir'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── DESKTOP MEET (sidebar derecha empuja el player) ───

  Widget _buildMeetDesktop() {
    final room = _party.currentRoom ?? widget.room;
    final members =
        _party.members.where((m) => m.status == 'accepted').toList();
    final pending =
        _party.members.where((m) => m.status == 'pending').toList();
    final readyCount = members.where((m) => m.hasServerReady).length;
    const sidebarW = 340.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(
        children: [
          // PLAYER
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildVideoSurface(),
                if (_loading || _error != null || !_syncStarted)
                  _waitOverlay(room, readyCount, members.length),
                if (_buffering && _syncStarted && _error == null)
                  const Center(
                      child: CircularProgressIndicator(color: _accent)),
                ..._buildFlyingEmojis(),
                // Tap vídeo → mostrar/ocultar controles
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      setState(() => _showUi = !_showUi);
                      if (_showUi) _armHide();
                    },
                  ),
                ),
                if (_showUi) _meetTopBar(room, members),
                if (_showUi && _syncStarted) _meetBottomBar(),
                if (_showTracks) _tracksPanel(),
                // Toggle sidebar — solo visible con controles
                if (_showUi)
                  Positioned(
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Material(
                        color: _card,
                        borderRadius: BorderRadius.circular(20),
                        child: IconButton(
                          tooltip: _sidebarOpen
                              ? 'Ocultar panel'
                              : 'Mostrar chat / miembros',
                          onPressed: () =>
                              setState(() => _sidebarOpen = !_sidebarOpen),
                          icon: Icon(
                            _sidebarOpen
                                ? Icons.chevron_right
                                : Icons.chevron_left,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // SIDEBAR
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: _sidebarOpen ? sidebarW : 0,
            child: _sidebarOpen
                ? Material(
                    color: _panel,
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _sideTab(0, Icons.chat_rounded, 'Chat'),
                            _sideTab(1, Icons.group_rounded, 'Gente',
                                badge: pending.isNotEmpty && _isHost
                                    ? pending.length
                                    : null),
                            _sideTab(2, Icons.tune_rounded, 'Sala'),
                          ],
                        ),
                        const Divider(height: 1, color: _border),
                        Expanded(
                          child: _sidebarTab == 0
                              ? _chatBody()
                              : _sidebarTab == 1
                                  ? _membersBody(members, pending)
                                  : _settingsBody(),
                        ),
                        // Emojis rápidos
                        _emojiBar(),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _sideTab(int i, IconData icon, String label, {int? badge}) {
    final sel = _sidebarTab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _sidebarTab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: sel ? _accent : Colors.transparent, width: 2),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: sel ? _accent : Colors.white54),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: sel ? _accent : Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                      color: _accent, borderRadius: BorderRadius.circular(8)),
                  child: Text('$badge',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _meetTopBar(PartyRoom room, List<PartyMember> members) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 48, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Abandonar sala',
              icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
              onPressed: _onLeavePressed,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  Text(
                    '${_isHost ? "HOST" : "INVITADO"} · ${members.length} en sala',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            // Código + copiar
            Material(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: _copyCode,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(room.code,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                              fontSize: 13)),
                      const SizedBox(width: 6),
                      const Icon(Icons.copy_rounded,
                          color: Colors.white70, size: 16),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (_isHost)
              IconButton(
                tooltip: 'Cerrar / ceder sala',
                onPressed: _onLeavePressed,
                icon: const Icon(Icons.call_end_rounded,
                    color: Colors.redAccent),
              ),
          ],
        ),
      ),
    );
  }

  Widget _meetBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: _accent,
              ),
              child: Slider(
                value: _duration.inMilliseconds <= 0
                    ? 0
                    : (_position.inMilliseconds / _duration.inMilliseconds)
                        .clamp(0.0, 1.0),
                onChangeStart:
                    _isHost ? (_) => setState(() => _dragging = true) : null,
                onChanged: _isHost
                    ? (v) => setState(() {
                          _position = Duration(
                              milliseconds:
                                  (v * _duration.inMilliseconds).round());
                        })
                    : null,
                onChangeEnd: _isHost
                    ? (v) async {
                        setState(() => _dragging = false);
                        await _seek(Duration(
                            milliseconds:
                                (v * _duration.inMilliseconds).round()));
                      }
                    : null,
              ),
            ),
            Row(
              children: [
                Text(_fmt(_position),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
                const Spacer(),
                IconButton(
                  iconSize: 42,
                  onPressed: _isHost ? _togglePlay : null,
                  icon: Icon(
                    _playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: _isHost ? Colors.white : Colors.white38,
                  ),
                ),
                const Spacer(),
                Text(_fmt(_duration),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
                IconButton(
                  tooltip: 'Audio y subtítulos',
                  icon: Icon(Icons.subtitles_rounded,
                      color: _showTracks ? _accent : Colors.white),
                  onPressed: () {
                    setState(() {
                      _showTracks = !_showTracks;
                      if (_showTracks) _showUi = true;
                    });
                    if (!_showTracks) _armHide();
                  },
                ),
                IconButton(
                  tooltip: _isPip ? 'Salir de PiP' : 'PiP',
                  icon: Icon(
                    Icons.picture_in_picture_alt_rounded,
                    color: _isPip ? _accent : Colors.white,
                  ),
                  onPressed: _togglePip,
                ),
                IconButton(
                  tooltip: _isFullscreen ? 'Salir de pantalla completa' : 'Pantalla completa',
                  icon: Icon(
                    _isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                  ),
                  onPressed: _toggleDesktopFullscreen,
                ),
              ],
            ),
            if (!_isHost)
              const Text('El host controla la reproducción',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  // ─── MÓVIL TWITCH ───

  Widget _buildMobileTwitch() {
    final room = _party.currentRoom ?? widget.room;
    final members =
        _party.members.where((m) => m.status == 'accepted').toList();
    final pending =
        _party.members.where((m) => m.status == 'pending').toList();
    final readyCount = members.where((m) => m.hasServerReady).length;

    // Horizontal / pantalla completa: SOLO vídeo + salir de completa
    // (sin chat, usuarios ni ajustes)
    if (_mobileFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoSurface(),
            if (_loading || _error != null || !_syncStarted)
              _waitOverlay(room, readyCount, members.length),
            if (_buffering && _syncStarted && _error == null)
              const Center(child: CircularProgressIndicator(color: _accent)),
            ..._buildFlyingEmojis(),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  setState(() => _showUi = !_showUi);
                  if (_showUi) _armHide();
                },
              ),
            ),
            // Siempre visible: volver a vertical (aunque controles ocultos)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              right: 12,
              child: IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                tooltip: 'Volver a vista vertical',
                icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white),
                onPressed: _toggleMobileFullscreen,
              ),
            ),
            if (_showUi) ...[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                      8, 16, 8, MediaQuery.paddingOf(context).bottom + 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Salir de la sala',
                        icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
                        onPressed: _onLeavePressed,
                      ),
                      Text(_fmt(_position),
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      const Spacer(),
                      IconButton(
                        iconSize: 40,
                        onPressed: _isHost && _syncStarted ? _togglePlay : null,
                        icon: Icon(
                          _playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                          color: _isHost ? Colors.white : Colors.white38,
                        ),
                      ),
                      const Spacer(),
                      Text(_fmt(_duration),
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      IconButton(
                        tooltip: 'Audio y subtítulos',
                        icon: Icon(Icons.subtitles_rounded,
                            color: _showTracks ? _accent : Colors.white),
                        onPressed: () {
                          setState(() {
                            _showTracks = !_showTracks;
                            if (_showTracks) _showUi = true;
                          });
                          if (!_showTracks) _armHide();
                        },
                      ),
                      IconButton(
                        tooltip: 'PiP',
                        icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                        onPressed: _togglePip,
                      ),
                      IconButton(
                        tooltip: 'Salir de pantalla completa',
                        icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white),
                        onPressed: _toggleMobileFullscreen,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_showTracks) _tracksPanel(),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: _panel,
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child: _buildVideoSurface(),
                  ),
                  if (_loading || _error != null || !_syncStarted)
                    _waitOverlay(room, readyCount, members.length),
                  if (_buffering && _syncStarted && _error == null)
                    const Center(
                        child: CircularProgressIndicator(color: _accent)),
                  ..._buildFlyingEmojis(),
                  // Tap en el vídeo para mostrar/ocultar controles
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        setState(() => _showUi = !_showUi);
                        if (_showUi) _armHide();
                      },
                    ),
                  ),
                  if (_showUi)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black87, Colors.transparent],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_syncStarted)
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2.5,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6),
                                activeTrackColor: _accent,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: _accent,
                              ),
                              child: Slider(
                                value: _duration.inMilliseconds <= 0
                                    ? 0
                                    : (_position.inMilliseconds /
                                            _duration.inMilliseconds)
                                        .clamp(0.0, 1.0),
                                onChangeStart: _isHost
                                    ? (_) =>
                                        setState(() => _dragging = true)
                                    : null,
                                onChanged: _isHost
                                    ? (v) => setState(() {
                                          _position = Duration(
                                              milliseconds: (v *
                                                      _duration
                                                          .inMilliseconds)
                                                  .round());
                                        })
                                    : null,
                                onChangeEnd: _isHost
                                    ? (v) async {
                                        setState(() => _dragging = false);
                                        await _seek(Duration(
                                            milliseconds: (v *
                                                    _duration
                                                        .inMilliseconds)
                                                .round()));
                                      }
                                    : null,
                              ),
                            ),
                          Row(
                            children: [
                              // Solo colgar sala (sin flecha atrás) — atrás del sistema abre el mismo modal
                              IconButton(
                                tooltip: 'Salir de la sala',
                                icon: const Icon(Icons.call_end_rounded,
                                    color: Colors.redAccent, size: 22),
                                onPressed: _onLeavePressed,
                              ),
                              Text(_fmt(_position),
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11)),
                              const Spacer(),
                              IconButton(
                                iconSize: 36,
                                onPressed: _isHost && _syncStarted
                                    ? _togglePlay
                                    : null,
                                icon: Icon(
                                  _playing
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  color: _isHost
                                      ? Colors.white
                                      : Colors.white38,
                                ),
                              ),
                              const Spacer(),
                              Text(_fmt(_duration),
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11)),
                              // Audio / subtítulos (como player principal)
                              IconButton(
                                tooltip: 'Audio y subtítulos',
                                icon: Icon(
                                  Icons.subtitles_rounded,
                                  color: _showTracks ? _accent : Colors.white,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _showTracks = !_showTracks;
                                    if (_showTracks) _showUi = true;
                                  });
                                  if (!_showTracks) _armHide();
                                },
                              ),
                              IconButton(
                                tooltip: 'PiP',
                                icon: const Icon(Icons.picture_in_picture_alt_rounded,
                                    color: Colors.white),
                                onPressed: _togglePip,
                              ),
                              IconButton(
                                tooltip: 'Pantalla completa',
                                icon: const Icon(Icons.fullscreen_rounded,
                                    color: Colors.white),
                                onPressed: _toggleMobileFullscreen,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: GestureDetector(
                      onTap: _copyCode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'PARTY ${room.code}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.copy,
                                color: Colors.white, size: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _isHost ? 'HOST' : 'INVITADO',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  if (_showTracks) _tracksPanel(),
                ],
              ),
            ),
            Container(
              color: _card,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  Text(
                    '${members.length} viendo · ${_isHost ? "Tú controlas" : "Sigue al host"}',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _tabChip(0, Icons.chat_rounded, 'Chat'),
                      const SizedBox(width: 8),
                      _tabChip(1, Icons.group_rounded, 'Miembros',
                          badge: pending.isNotEmpty && _isHost
                              ? pending.length
                              : null),
                      const SizedBox(width: 8),
                      _tabChip(2, Icons.tune_rounded, 'Ajustes'),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: _panel,
                child: Column(
                  children: [
                    Expanded(
                      child: _mobileTab == 0
                          ? _chatBody()
                          : _mobileTab == 1
                              ? _membersBody(members, pending)
                              : _settingsBody(),
                    ),
                    _emojiBar(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabChip(int i, IconData icon, String label, {int? badge}) {
    final sel = _mobileTab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mobileTab = i),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: sel ? _accent : Colors.transparent, width: 2),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: sel ? _accent : Colors.white54),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: sel ? _accent : Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                      color: _accent, borderRadius: BorderRadius.circular(8)),
                  child: Text('$badge',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ─── TV / FULLSCREEN ───

  Widget _buildImmersive() {
    final room = _party.currentRoom ?? widget.room;
    final members =
        _party.members.where((m) => m.status == 'accepted').toList();
    final pending =
        _party.members.where((m) => m.status == 'pending').toList();
    final readyCount = members.where((m) => m.hasServerReady).length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.escape ||
              k == LogicalKeyboardKey.goBack ||
              k == LogicalKeyboardKey.browserBack) {
            if (_modalChat || _modalMembers || _modalSettings) {
              setState(() {
                _modalChat = false;
                _modalMembers = false;
                _modalSettings = false;
              });
              return KeyEventResult.handled;
            }
            if (_mobileFullscreen && !widget.isTv) {
              _toggleMobileFullscreen();
              return KeyEventResult.handled;
            }
            _onLeavePressed();
            return KeyEventResult.handled;
          }
          if (_isHost &&
              (k == LogicalKeyboardKey.select ||
                  k == LogicalKeyboardKey.enter ||
                  k == LogicalKeyboardKey.space)) {
            _togglePlay();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowLeft && _isHost) {
            _seek(_position - const Duration(seconds: 10));
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowRight && _isHost) {
            _seek(_position + const Duration(seconds: 10));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: () {
            setState(() => _showUi = !_showUi);
            if (_showUi) _armHide();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildVideoSurface(),
              if (_party.isPendingMember && !_isHost)
                Container(
                  color: Colors.black87,
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.hourglass_top_rounded,
                              color: _accent, size: 42),
                          SizedBox(height: 14),
                          Text(
                            'Sala privada',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 18),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Espera a que el host acepte tu entrada.\nNo se reproduce nada hasta entonces.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else if (_loading || _error != null || !_syncStarted)
                _waitOverlay(room, readyCount, members.length),
              if (_buffering && _syncStarted && _error == null)
                const Center(
                    child: CircularProgressIndicator(color: _accent)),
              ..._buildFlyingEmojis(),
              if (_showUi) _immersiveTopBar(room, members, pending),
              if (_showUi && _syncStarted) _immersiveBottomBar(),
              if (_showTracks) _tracksPanel(),
              if (_modalChat)
                _modalShell(
                    title: widget.isTv ? 'Reacciones' : 'Chat',
                    onClose: () => setState(() => _modalChat = false),
                    child: widget.isTv
                        ? Center(child: _emojiBar())
                        : Column(
                            children: [
                              Expanded(child: _chatBody()),
                              _emojiBar(),
                            ],
                          )),
              if (_modalMembers)
                _modalShell(
                    title: 'Miembros',
                    onClose: () => setState(() => _modalMembers = false),
                    child: _membersBody(members, pending)),
              if (_modalSettings)
                _modalShell(
                    title: 'Ajustes',
                    onClose: () => setState(() => _modalSettings = false),
                    child: _settingsBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _immersiveTopBar(
      PartyRoom room, List<PartyMember> members, List<PartyMember> pending) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            widget.isTv ? 28 : 12, widget.isTv ? 20 : 8, 8, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Abandonar sala',
                icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
                onPressed: _onLeavePressed,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(room.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16)),
                    Text(
                      '${_isHost ? "HOST" : "INVITADO"} · ${members.length}',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Material(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: _copyCode,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(room.code,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2)),
                        const SizedBox(width: 6),
                        const Icon(Icons.copy, color: Colors.white70, size: 16),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() {
                  _modalMembers = true;
                  _modalChat = false;
                  _modalSettings = false;
                }),
                icon: Badge(
                  isLabelVisible: pending.isNotEmpty && _isHost,
                  label: Text('${pending.length}'),
                  child:
                      const Icon(Icons.group_rounded, color: Colors.white),
                ),
              ),
              // TV: solo reacciones (sin chat de texto). Otras UIs: chat completo.
              if (widget.isTv)
                IconButton(
                  tooltip: 'Reacciones',
                  onPressed: () => setState(() {
                    _modalChat = true;
                    _modalMembers = false;
                    _modalSettings = false;
                  }),
                  icon: const Icon(Icons.emoji_emotions_rounded,
                      color: Colors.white),
                )
              else
                IconButton(
                  onPressed: () => setState(() {
                    _modalChat = true;
                    _modalMembers = false;
                    _modalSettings = false;
                  }),
                  icon: const Icon(Icons.chat_rounded, color: Colors.white),
                ),
              IconButton(
                onPressed: () => setState(() {
                  _modalSettings = true;
                  _modalChat = false;
                  _modalMembers = false;
                }),
                icon: const Icon(Icons.tune_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _immersiveBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            widget.isTv ? 28 : 12, 8, 12, widget.isTv ? 20 : 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: _accent,
              ),
              child: Slider(
                value: _duration.inMilliseconds <= 0
                    ? 0
                    : (_position.inMilliseconds / _duration.inMilliseconds)
                        .clamp(0.0, 1.0),
                onChangeStart:
                    _isHost ? (_) => setState(() => _dragging = true) : null,
                onChanged: _isHost
                    ? (v) => setState(() {
                          _position = Duration(
                              milliseconds:
                                  (v * _duration.inMilliseconds).round());
                        })
                    : null,
                onChangeEnd: _isHost
                    ? (v) async {
                        setState(() => _dragging = false);
                        await _seek(Duration(
                            milliseconds:
                                (v * _duration.inMilliseconds).round()));
                      }
                    : null,
              ),
            ),
            Row(
              children: [
                Text(_fmt(_position),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
                const Spacer(),
                IconButton(
                  iconSize: 42,
                  onPressed: _isHost ? _togglePlay : null,
                  icon: Icon(
                    _playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: _isHost ? Colors.white : Colors.white38,
                  ),
                ),
                const Spacer(),
                Text(_fmt(_duration),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
                IconButton(
                  tooltip: 'Audio y subtítulos',
                  icon: Icon(Icons.subtitles_rounded,
                      color: _showTracks ? _accent : Colors.white),
                  onPressed: () {
                    setState(() {
                      _showTracks = !_showTracks;
                      if (_showTracks) _showUi = true;
                    });
                    if (!_showTracks) _armHide();
                  },
                ),
                if (!widget.isTv)
                  IconButton(
                    tooltip: _isPip ? 'Salir de PiP' : 'PiP',
                    icon: Icon(
                      Icons.picture_in_picture_alt_rounded,
                      color: _isPip ? _accent : Colors.white,
                    ),
                    onPressed: _togglePip,
                  ),
                if (_isDesktopParty)
                  IconButton(
                    tooltip: _isFullscreen ? 'Salir de pantalla completa' : 'Pantalla completa',
                    icon: Icon(
                      _isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: Colors.white,
                    ),
                    onPressed: _toggleDesktopFullscreen,
                  ),
              ],
            ),
            if (!_isHost)
              const Text('El host controla la reproducción',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  // ─── SHARED WIDGETS ───

  Widget _buildVideoSurface() {
    if (_useMediaKit && _video != null) {
      return Center(
        child: Video(
          controller: _video!,
          controls: NoVideoControls,
        ),
      );
    }
    if (!_useMediaKit && _vp != null && _vp!.value.isInitialized) {
      final ar = _vp!.value.aspectRatio;
      return Center(
        child: AspectRatio(
          aspectRatio: ar == 0 ? 16 / 9 : ar,
          child: VideoPlayer(_vp!),
        ),
      );
    }
    return const ColoredBox(color: Colors.black);
  }

  List<Widget> _buildFlyingEmojis() {
    return _flying.map((e) {
      return Positioned(
        left: _screenWidth * e.x - e.size / 2,
        bottom: 40,
        child: TweenAnimationBuilder<double>(
          key: ValueKey(e.id),
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: e.durationMs),
          curve: Curves.easeOutCubic,
          builder: (_, v, child) {
            return Opacity(
              opacity: (1 - v * 0.85).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(e.drift * v, -e.rise * v),
                child: Transform.scale(
                  scale: 0.7 + 0.5 * (1 - v),
                  child: child,
                ),
              ),
            );
          },
          child: Text(e.emoji, style: TextStyle(fontSize: e.size)),
        ),
      );
    }).toList();
  }

  Widget _emojiBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _border)),
        color: _card,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _quickEmojis
            .map((e) => InkWell(
                  onTap: () async {
                    await _party.sendReaction(e);
                    _spawnEmoji(e);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(e, style: const TextStyle(fontSize: 22)),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _waitOverlay(PartyRoom room, int ready, int total) {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) ...[
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 42),
                const SizedBox(height: 12),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _loadStreams,
                  child: const Text('Reintentar'),
                ),
              ] else ...[
                const CircularProgressIndicator(color: _accent),
                const SizedBox(height: 14),
                Text(
                  _loading
                      ? 'Cargando servidores…'
                      : 'Esperando a todos ($ready/$total)…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sala ${room.code} · ${_isHost ? "HOST (en pausa)" : "INVITADO"}',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _modalShell({
    required String title,
    required VoidCallback onClose,
    required Widget child,
  }) {
    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: widget.isTv ? 520 : 400,
              maxHeight: MediaQuery.of(context).size.height * 0.75,
            ),
            child: Material(
              color: _panel,
              borderRadius: BorderRadius.circular(16),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Row(
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16)),
                        const Spacer(),
                        IconButton(
                          icon:
                              const Icon(Icons.close, color: Colors.white70),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: _border),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Panel audio + subtítulos (igual idea que player principal).
  /// Solo pistas de audio embebidas + subtítulos externos del repo con estilo.
  Widget _tracksPanel() {
    return Positioned(
      right: 12,
      bottom: 100,
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        elevation: 8,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300, maxHeight: 380),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Audio y subtítulos',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            color: Colors.white54, size: 20),
                        onPressed: () {
                          setState(() => _showTracks = false);
                          _armHide();
                        },
                      ),
                    ],
                  ),
                ),
                if (_audioTracks.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text('Audio',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  for (final t in _audioTracks)
                    ListTile(
                      dense: true,
                      selected: _selectedAudio?.id == t.id,
                      selectedTileColor: _accent.withValues(alpha: 0.12),
                      title: Text(
                        t.language ?? t.title ?? t.id,
                        style: TextStyle(
                          color: _selectedAudio?.id == t.id
                              ? _accent
                              : Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      onTap: () async {
                        await _player?.setAudioTrack(t);
                        setState(() => _selectedAudio = t);
                      },
                    ),
                ],
                // Solo subtítulos del repo (estilo unificado). No listar pistas nativas
                // del motor para evitar doble capa sin estilo.
                if (_externalSubs.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('Subtítulos',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  ListTile(
                    dense: true,
                    title: const Text('Desactivados',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                    onTap: () async {
                      try {
                        await _player?.setSubtitleTrack(SubtitleTrack.no());
                      } catch (_) {}
                      setState(() {
                        _selectedSubtitle = null;
                        _externalSubActive = false;
                      });
                    },
                  ),
                  for (final s in _externalSubs)
                    ListTile(
                      dense: true,
                      selected: _externalSubActive &&
                          _selectedSubtitle?.title == s.label,
                      selectedTileColor: _accent.withValues(alpha: 0.12),
                      title: Text(s.label,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      subtitle: Text(s.lang,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                      onTap: () async {
                        try {
                          await _player?.setSubtitleTrack(
                            SubtitleTrack.uri(s.url,
                                title: s.label, language: s.lang),
                          );
                          setState(() {
                            _externalSubActive = true;
                            _selectedSubtitle = SubtitleTrack.uri(s.url,
                                title: s.label, language: s.lang);
                          });
                        } catch (e) {
                          debugPrint('[Party] sub error: $e');
                        }
                      },
                    ),
                ],
                if (_audioTracks.isEmpty && _externalSubs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No hay pistas de audio ni subtítulos disponibles',
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chatBody() {
    final messages = _chatMessages;
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Text('Sin mensajes aún',
                      style: TextStyle(color: _muted)))
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[i];
                    final mine = m.userId == _party.userId;
                    return Align(
                      alignment:
                          mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * 0.7,
                        ),
                        decoration: BoxDecoration(
                          color: mine ? _accent.withValues(alpha: 0.85) : _card,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(12),
                            topRight: const Radius.circular(12),
                            bottomLeft: Radius.circular(mine ? 12 : 4),
                            bottomRight: Radius.circular(mine ? 4 : 12),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: mine
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            if (!mine)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(m.username,
                                      style: const TextStyle(
                                          color: _accent,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11)),
                                  if (m.userId ==
                                      (_party.currentRoom ?? widget.room)
                                          .hostUserId) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.workspace_premium_rounded,
                                        color: Color(0xFFFFD54F), size: 12),
                                  ],
                                ],
                              ),
                            Text(m.message,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Enviar mensaje…',
                    hintStyle: const TextStyle(color: _muted),
                    isDense: true,
                    filled: true,
                    fillColor: _card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                  ),
                  onSubmitted: (t) {
                    _party.sendMessage(t);
                    _chatCtrl.clear();
                  },
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.send_rounded, color: _accent),
                onPressed: () {
                  _party.sendMessage(_chatCtrl.text);
                  _chatCtrl.clear();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<PartyMember> _sortedMembers(List<PartyMember> members) {
    final hostId = (_party.currentRoom ?? widget.room).hostUserId;
    final list = List<PartyMember>.from(members);
    list.sort((a, b) {
      final aHost = a.isHost || a.userId == hostId;
      final bHost = b.isHost || b.userId == hostId;
      if (aHost && !bHost) return -1;
      if (!aHost && bHost) return 1;
      return a.joinedAt.compareTo(b.joinedAt);
    });
    return list;
  }

  Widget _membersBody(List<PartyMember> members, List<PartyMember> pending) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('En la sala',
            style:
                TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ..._sortedMembers(members).map((m) {
          final isRoomHost = m.isHost ||
              m.userId == (_party.currentRoom ?? widget.room).hostUserId;
          return ListTile(
              dense: true,
              leading: Icon(
                isRoomHost
                    ? Icons.workspace_premium_rounded
                    : Icons.person_rounded,
                color: isRoomHost ? const Color(0xFFFFD54F) : Colors.white54,
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(m.username,
                        style: const TextStyle(color: Colors.white)),
                  ),
                  if (isRoomHost) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.workspace_premium_rounded,
                        color: Color(0xFFFFD54F), size: 16),
                  ],
                ],
              ),
              subtitle: m.hasServerReady
                  ? const Text('Listo',
                      style: TextStyle(color: Colors.greenAccent, fontSize: 11))
                  : const Text('Cargando…',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
              trailing: _isHost && m.userId != _party.userId
                  ? IconButton(
                      tooltip: 'Expulsar',
                      icon: const Icon(Icons.person_remove_rounded,
                          color: Colors.redAccent, size: 20),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: _card,
                            title: const Text('Expulsar',
                                style: TextStyle(color: Colors.white)),
                            content: Text(
                              '¿Expulsar a ${m.username}?',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('No')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Expulsar')),
                            ],
                          ),
                        );
                        if (ok == true) await _party.kickMember(m.userId);
                      },
                    )
                  : null,
            );
        }),
        if (_isHost && pending.isNotEmpty) ...[
          const Divider(color: _border),
          const Text('Solicitudes',
              style: TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.w600)),
          ...pending.map((m) => ListTile(
                dense: true,
                title: Text(m.username,
                    style: const TextStyle(color: Colors.white)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.greenAccent),
                      onPressed: () =>
                          _party.respondJoinRequest(m.userId, true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.redAccent),
                      onPressed: () =>
                          _party.respondJoinRequest(m.userId, false),
                    ),
                  ],
                ),
              )),
        ],
      ],
    );
  }

  Widget _settingsBody() {
    final room = _party.currentRoom ?? widget.room;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Código: ${room.code}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3)),
            ),
            IconButton(
              tooltip: 'Copiar código',
              onPressed: _copyCode,
              icon: const Icon(Icons.copy_rounded, color: Colors.white70),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _isHost
              ? 'Eres el HOST. La sala inicia en pausa; al dar play todos siguen.'
              : 'Eres INVITADO: solo ves lo que hace el host.',
          style: const TextStyle(color: _muted, fontSize: 13),
        ),
        const SizedBox(height: 16),
        if (_isHost) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_rounded, color: Colors.white70),
            title: const Text('Título de la sala',
                style: TextStyle(color: Colors.white70)),
            subtitle: Text(room.title,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
            onTap: _editRoomTitle,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.image_rounded, color: Colors.white70),
            title: const Text('Banner / poster de la sala',
                style: TextStyle(color: Colors.white70)),
            subtitle: Text(
              (room.backdrop ?? room.poster ?? 'Sin imagen').toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            onTap: _editRoomBanner,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.playlist_play_rounded, color: _accent),
            title: const Text('Cambiar capítulo / episodio',
                style: TextStyle(color: Colors.white)),
            subtitle: Text(
              room.season != null
                  ? 'Ahora: T${room.season} E${room.episode ?? "-"}'
                  : 'Elegir otro episodio en esta misma sala',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            onTap: _changeEpisodeInRoom,
          ),
          const Divider(color: _border),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sala pública',
                style: TextStyle(color: Colors.white70)),
            value: room.isPublic,
            activeColor: _accent,
            onChanged: (v) => _party.updateRoomSettings(isPublic: v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Máximo de personas',
                style: TextStyle(color: Colors.white70)),
            subtitle: Text('${room.maxMembers}',
                style: const TextStyle(color: Colors.white)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove, color: Colors.white70),
                  onPressed: () => _party.updateRoomSettings(
                      maxMembers: (room.maxMembers - 1).clamp(2, 50)),
                ),
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.white70),
                  onPressed: () => _party.updateRoomSettings(
                      maxMembers: (room.maxMembers + 1).clamp(2, 50)),
                ),
              ],
            ),
          ),
          const Divider(color: _border),
          const Text('Servidores',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ..._servers.map((s) {
            final sel = _selected?.url == s.url;
            return ListTile(
              dense: true,
              selected: sel,
              title:
                  Text(s.name, style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                [
                  if ((s.language ?? '').isNotEmpty) s.language!,
                  if (s.isHls || s.url.toLowerCase().contains('.m3u8')) 'HLS' else 'TS',
                ].join(' · '),
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              trailing: sel ? const Icon(Icons.check, color: _accent) : null,
              onTap: () => _selectServer(s),
            );
          }),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: _onLeavePressed,
            icon: const Icon(Icons.call_end),
            label: const Text('Salir / Cerrar sala'),
          ),
        ] else ...[
          const Text(
            'Solo el host puede cambiar título, capítulo, privacidad y servidor.',
            style: TextStyle(color: _muted),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _onLeavePressed,
            child: const Text('Salir de la sala'),
          ),
        ],
      ],
    );
  }

  Future<void> _editRoomTitle() async {
    final room = _party.currentRoom ?? widget.room;
    final ctrl = TextEditingController(text: room.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Título de la sala', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Nombre visible de la sala',
            labelStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await _party.updateRoomSettings(title: ctrl.text.trim());
      if (mounted) setState(() {});
    }
  }

  Future<void> _editRoomBanner() async {
    final room = _party.currentRoom ?? widget.room;
    final ctrl = TextEditingController(text: room.backdrop ?? room.poster ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Banner de la sala', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'URL de imagen (backdrop/poster)',
            labelStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok == true) {
      final url = ctrl.text.trim();
      await _party.updateRoomSettings(
        backdrop: url.isEmpty ? null : url,
        poster: url.isEmpty ? null : url,
      );
      if (mounted) setState(() {});
    }
  }

  Future<void> _changeEpisodeInRoom() async {
    if (!_isHost) return;
    final room = _party.currentRoom ?? widget.room;
    try {
      final meta = await ContentService.instance.getDetails(
        widget.repo,
        room.contentId,
      );
      if (!mounted) return;
      if (meta == null || meta.seasons.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay episodios disponibles para este contenido')),
        );
        return;
      }
      int seasonIdx = 0;
      for (var i = 0; i < meta.seasons.length; i++) {
        if (meta.seasons[i].number == (room.season ?? 1)) {
          seasonIdx = i;
          break;
        }
      }
      final chosen = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (ctx, setLocal) {
            final season = meta.seasons[seasonIdx];
            return AlertDialog(
              backgroundColor: _card,
              title: const Text('Cambiar episodio', style: TextStyle(color: Colors.white)),
              content: SizedBox(
                width: 360,
                height: 420,
                child: Column(
                  children: [
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: meta.seasons.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final s = meta.seasons[i];
                          final sel = i == seasonIdx;
                          return ChoiceChip(
                            label: Text('T${s.number}'),
                            selected: sel,
                            onSelected: (_) => setLocal(() => seasonIdx = i),
                            selectedColor: _accent,
                            labelStyle: TextStyle(color: sel ? Colors.white : Colors.white70),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.builder(
                        itemCount: season.episodes.length,
                        itemBuilder: (_, i) {
                          final ep = season.episodes[i];
                          final current = season.number == room.season && ep.number == room.episode;
                          return ListTile(
                            dense: true,
                            selected: current,
                            title: Text(
                              'E${ep.number}${ep.title != null ? " · ${ep.title}" : ""}',
                              style: const TextStyle(color: Colors.white),
                            ),
                            trailing: current
                                ? const Icon(Icons.play_arrow, color: _accent)
                                : null,
                            onTap: () => Navigator.pop(ctx, {
                              'season': season.number,
                              'episode': ep.number,
                              'contentId': ep.id,
                              'epTitle': ep.title ?? '',
                            }),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
              ],
            );
          });
        },
      );
      if (chosen == null || !mounted) return;
      final s = chosen['season'] as int;
      final e = chosen['episode'] as int;
      final epContentId = (chosen['contentId'] as String?)?.trim();
      final epTitle = (chosen['epTitle'] as String?)?.trim();
      final titleBase = meta.title ?? room.title;
      final newTitle = (epTitle != null && epTitle.isNotEmpty)
          ? '$titleBase · T$s E$e · $epTitle'
          : '$titleBase · T$s E$e';
      // contentId del episodio si el repo lo da; si no, el de la serie + season/episode
      final newContentId =
          (epContentId != null && epContentId.isNotEmpty) ? epContentId : room.contentId;
      await _party.updateRoomContent(
        contentId: newContentId,
        contentType: room.contentType,
        title: newTitle,
        poster: meta.poster ?? room.poster,
        backdrop: meta.backdrop ?? room.backdrop,
        season: s,
        episode: e,
        language: room.language,
      );
      // Reset sync y recargar servidores del nuevo capítulo
      _syncStarted = false;
      _hostPushTimer?.cancel();
      _pollTimer?.cancel();
      _selected = null;
      _servers = [];
      _lastAppliedKey = null;
      _lastContentKey =
          '$newContentId|$s|$e|$newTitle';
      await _disposeEngines();
      await _loadStreams();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capítulo cambiado: T$s E$e')),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cambiar episodio: $err')),
        );
      }
    }
  }
}

class _FlyingEmoji {
  final int id;
  final String emoji;
  final double x;
  final double size;
  final double drift;
  final double rise;
  final int durationMs;
  _FlyingEmoji({
    required this.id,
    required this.emoji,
    required this.x,
    this.size = 64,
    this.drift = 0,
    this.rise = 220,
    this.durationMs = 2200,
  });
}