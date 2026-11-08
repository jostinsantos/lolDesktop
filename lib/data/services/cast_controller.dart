import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cast_service.dart';
import '../models/stream_server.dart';
import '../models/repo_manifest.dart';
import '../../repo/player/player_transmission.dart';

/// Controlador global de la sesión de Cast activa.
/// Permite notificación en segundo plano, reabrir la pantalla de control
/// y sincronizar play/pause desde la notificación.
class CastController extends ChangeNotifier {
  CastController._();
  static final CastController instance = CastController._();

  static const _channel = MethodChannel('com.lol.lite/cast_notif');

  CastService? service;
  CastSession? session;
  CastDevice? device;

  String title = '';
  String? poster;
  String? backdrop;
  String? logo;
  List<StreamServer> servers = const [];
  int serverIndex = 0;
  Map<String, String>? headers;
  int? season;
  int? episode;
  String? episodeTitle;
  int? nextSeason;
  int? nextEpisode;
  String? nextEpisodeId;
  String? nextEpisodeTitle;
  List<Map<String, dynamic>> episodeList = const [];
  InstalledRepo? loadRepo;
  String? repoId;
  String? contentId;
  String contentType = 'movie';
  String preferredLanguage = '';
  double introStartSec = -1;
  double introEndSec = -1;
  double outroStartSec = -1;
  double outroEndSec = -1;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool active = false;

  /// Callback que la UI registra para reabrir la pantalla de cast.
  VoidCallback? onOpenCastScreen;

  /// Navegador global (se asigna desde app.dart).
  GlobalKey<NavigatorState>? navigatorKey;

  StreamSubscription? _posSub;
  Timer? _notifTimer;

  bool get hasSession => active && session != null;

  Future<void> bind({
    required CastService castService,
    required CastSession castSession,
    required CastDevice castDevice,
    required String title,
    String? poster,
    String? backdrop,
    String? logo,
    List<StreamServer> servers = const [],
    int serverIndex = 0,
    Map<String, String>? headers,
    int? season,
    int? episode,
    String? episodeTitle,
    int? nextSeason,
    int? nextEpisode,
    String? nextEpisodeId,
    String? nextEpisodeTitle,
    List<Map<String, dynamic>> episodeList = const [],
    InstalledRepo? loadRepo,
    String? repoId,
    String? contentId,
    String contentType = 'movie',
    String preferredLanguage = '',
    double introStartSec = -1,
    double introEndSec = -1,
    double outroStartSec = -1,
    double outroEndSec = -1,
    Duration? startPosition,
    Duration? startDuration,
  }) async {
    service = castService;
    session = castSession;
    device = castDevice;
    this.title = title;
    this.poster = poster;
    this.backdrop = backdrop;
    this.logo = logo;
    this.servers = servers;
    this.serverIndex = serverIndex;
    this.headers = headers;
    this.season = season;
    this.episode = episode;
    this.episodeTitle = episodeTitle;
    this.nextSeason = nextSeason;
    this.nextEpisode = nextEpisode;
    this.nextEpisodeId = nextEpisodeId;
    this.nextEpisodeTitle = nextEpisodeTitle;
    this.episodeList = episodeList;
    this.loadRepo = loadRepo;
    this.repoId = repoId;
    this.contentId = contentId;
    this.contentType = contentType;
    this.preferredLanguage = preferredLanguage;
    this.introStartSec = introStartSec;
    this.introEndSec = introEndSec;
    this.outroStartSec = outroStartSec;
    this.outroEndSec = outroEndSec;
    position = startPosition ?? Duration.zero;
    duration = startDuration ?? Duration.zero;
    playing = true;
    active = true;

    _channel.setMethodCallHandler(_onNativeCall);
    await _showNotification();
    _startNotifUpdates();
    notifyListeners();
  }

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'play':
        await play();
        break;
      case 'pause':
        await pause();
        break;
      case 'open':
        onOpenCastScreen?.call();
        openCastScreen();
        break;
      case 'stop':
        await stopAndClear();
        break;
    }
  }

  /// Reabre la pantalla de control de Cast (desde notificación o deep link).
  void openCastScreen() {
    if (!hasSession || session == null || service == null || device == null) return;
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    // Evitar apilar muchas pantallas iguales
    nav.push(
      MaterialPageRoute(
        builder: (_) => PlayerTransmissionPage(
          castService: service!,
          session: session!,
          device: device!,
          title: title,
          poster: poster,
          backdrop: backdrop,
          logo: logo,
          servers: servers,
          initialServerIndex: serverIndex,
          headers: headers,
          season: season,
          episode: episode,
          episodeTitle: episodeTitle,
          nextSeason: nextSeason,
          nextEpisode: nextEpisode,
          nextEpisodeId: nextEpisodeId,
          nextEpisodeTitle: nextEpisodeTitle,
          episodeList: episodeList,
          loadRepo: loadRepo,
          repoId: repoId,
          contentId: contentId,
          contentType: contentType,
          preferredLanguage: preferredLanguage,
          introStartSec: introStartSec,
          introEndSec: introEndSec,
          outroStartSec: outroStartSec,
          outroEndSec: outroEndSec,
        ),
      ),
    );
  }

  Future<void> play() async {
    try {
      await session?.play();
      playing = true;
      await _updateNotification();
      notifyListeners();
    } catch (e) {
      debugPrint('[CastController] play: $e');
    }
  }

  Future<void> pause() async {
    try {
      await session?.pause();
      playing = false;
      await _updateNotification();
      notifyListeners();
    } catch (e) {
      debugPrint('[CastController] pause: $e');
    }
  }

  Future<void> togglePlay() async {
    if (playing) {
      await pause();
    } else {
      await play();
    }
  }

  void updateProgress(Duration pos, Duration dur, {bool? isPlaying}) {
    position = pos;
    if (dur > Duration.zero) duration = dur;
    if (isPlaying != null) playing = isPlaying;
  }

  Future<void> stopAndClear() async {
    try {
      await session?.stop();
    } catch (_) {}
    try {
      await session?.disconnect();
    } catch (_) {}
    try {
      service?.stopDiscovery();
    } catch (_) {}
    await clear();
  }

  Future<void> clear({bool hideNotif = true}) async {
    active = false;
    playing = false;
    _notifTimer?.cancel();
    _notifTimer = null;
    _posSub?.cancel();
    _posSub = null;
    if (hideNotif) await _hideNotification();
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {}
    session = null;
    service = null;
    device = null;
    notifyListeners();
  }

  void _startNotifUpdates() {
    _notifTimer?.cancel();
    _notifTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!active) return;
      _updateNotification();
    });
  }

  Future<void> _showNotification() async {
    try {
      await _channel.invokeMethod('show', {
        'title': title.isNotEmpty ? title : 'Reproduciendo',
        'device': device?.name ?? 'Cast',
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'imageUrl': poster ?? backdrop,
      });
    } catch (e) {
      debugPrint('[CastController] show notif: $e');
    }
  }

  Future<void> _updateNotification() async {
    if (!active) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title.isNotEmpty ? title : 'Reproduciendo',
        'device': device?.name ?? 'Cast',
        'playing': playing,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'imageUrl': poster ?? backdrop,
      });
    } catch (_) {}
  }

  Future<void> _hideNotification() async {
    try {
      await _channel.invokeMethod('hide');
    } catch (_) {}
  }
}
