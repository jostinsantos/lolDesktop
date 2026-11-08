import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Configura aquí tu proyecto Supabase.
/// Reemplaza con tu URL y anon key reales.
class PartyConfig {
  static const String supabaseUrl = 'https://swcvzwrweewxsuobqrsm.supabase.co';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3Y3Z6d3J3ZWV3eHN1b2JxcnNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM0NDY2MDEsImV4cCI6MjEwOTAyMjYwMX0.Gy9jTK_SbORMSCNdHpVLK6tW0iie4ttnSKIzXLfRgX8';
}

/// Estado de reproducción sincronizado.
/// [engine]: "video_player" | "media_kit"
/// [streamKind]: "hls" | "ts" | "other"
class PlaybackState {
  final bool isPlaying;
  final int positionMs;
  final int serverIndex;
  final String? serverName;
  final String? streamUrl;
  final Map<String, String> headers;
  final bool isHls;
  final String? engine;
  final String? streamKind;
  final DateTime? updatedAt;
  final String? updatedBy;

  const PlaybackState({
    this.isPlaying = false,
    this.positionMs = 0,
    this.serverIndex = 0,
    this.serverName,
    this.streamUrl,
    this.headers = const {},
    this.isHls = false,
    this.engine,
    this.streamKind,
    this.updatedAt,
    this.updatedBy,
  });

  factory PlaybackState.fromJson(Map<String, dynamic> j) {
    final headersRaw = j['headers'];
    Map<String, String> headers = {};
    if (headersRaw is Map) {
      headers = headersRaw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    final isHls = j['is_hls'] == true;
    final kind = (j['stream_kind'] as String?) ??
        (isHls ? 'hls' : (j['stream_kind'] as String?));
    return PlaybackState(
      isPlaying: j['is_playing'] == true,
      positionMs: (j['position_ms'] as num?)?.toInt() ?? 0,
      serverIndex: (j['server_index'] as num?)?.toInt() ?? 0,
      serverName: j['server_name'] as String?,
      streamUrl: j['stream_url'] as String?,
      headers: headers,
      isHls: isHls,
      engine: j['engine'] as String?,
      streamKind: kind,
      updatedAt: j['updated_at'] != null
          ? DateTime.tryParse(j['updated_at'].toString())
          : null,
      updatedBy: j['updated_by'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'is_playing': isPlaying,
        'position_ms': positionMs,
        'server_index': serverIndex,
        'server_name': serverName,
        'stream_url': streamUrl,
        'headers': headers,
        'is_hls': isHls,
        'engine': engine,
        'stream_kind': streamKind,
        'updated_at': (updatedAt ?? DateTime.now()).toIso8601String(),
        'updated_by': updatedBy,
      };

  PlaybackState copyWith({
    bool? isPlaying,
    int? positionMs,
    int? serverIndex,
    String? serverName,
    String? streamUrl,
    Map<String, String>? headers,
    bool? isHls,
    String? engine,
    String? streamKind,
    DateTime? updatedAt,
    String? updatedBy,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      positionMs: positionMs ?? this.positionMs,
      serverIndex: serverIndex ?? this.serverIndex,
      serverName: serverName ?? this.serverName,
      streamUrl: streamUrl ?? this.streamUrl,
      headers: headers ?? this.headers,
      isHls: isHls ?? this.isHls,
      engine: engine ?? this.engine,
      streamKind: streamKind ?? this.streamKind,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }
}

class PartyRoom {
  final String id;
  final String code;
  final String title;
  final String contentId;
  final String repoId;
  final String contentType;
  final String? poster;
  final String? backdrop;
  final int? season;
  final int? episode;
  final String? language;
  final bool isPublic;
  final String hostUserId;
  final String hostUsername;
  final int maxMembers;
  final String status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final PlaybackState playbackState;
  final int memberCount;

  PartyRoom({
    required this.id,
    required this.code,
    required this.title,
    required this.contentId,
    required this.repoId,
    required this.contentType,
    this.poster,
    this.backdrop,
    this.season,
    this.episode,
    this.language,
    required this.isPublic,
    required this.hostUserId,
    required this.hostUsername,
    required this.maxMembers,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    required this.playbackState,
    this.memberCount = 0,
  });

  factory PartyRoom.fromMap(Map<String, dynamic> m, {int memberCount = 0}) {
    final pb = m['playback_state'];
    return PartyRoom(
      id: m['id'].toString(),
      code: m['code'] as String,
      title: m['title'] as String,
      contentId: m['content_id'] as String,
      repoId: m['repo_id'] as String,
      contentType: m['content_type'] as String? ?? 'movie',
      poster: m['poster'] as String?,
      backdrop: m['backdrop'] as String?,
      season: (m['season'] as num?)?.toInt(),
      episode: (m['episode'] as num?)?.toInt(),
      language: m['language'] as String?,
      isPublic: m['is_public'] == true,
      hostUserId: m['host_user_id'] as String,
      hostUsername: m['host_username'] as String,
      maxMembers: (m['max_members'] as num?)?.toInt() ?? 10,
      status: m['status'] as String? ?? 'waiting',
      createdAt: DateTime.parse(m['created_at'].toString()),
      expiresAt: DateTime.parse(m['expires_at'].toString()),
      playbackState: pb is Map
          ? PlaybackState.fromJson(Map<String, dynamic>.from(pb))
          : const PlaybackState(),
      memberCount: memberCount,
    );
  }
}

class PartyMember {
  final String id;
  final String roomId;
  final String userId;
  final String username;
  final bool isHost;
  final String status;
  final bool hasServerReady;
  final DateTime joinedAt;

  PartyMember({
    required this.id,
    required this.roomId,
    required this.userId,
    required this.username,
    required this.isHost,
    required this.status,
    required this.hasServerReady,
    required this.joinedAt,
  });

  factory PartyMember.fromMap(Map<String, dynamic> m) {
    return PartyMember(
      id: m['id'].toString(),
      roomId: m['room_id'].toString(),
      userId: m['user_id'] as String,
      username: m['username'] as String,
      isHost: m['is_host'] == true,
      status: m['status'] as String? ?? 'pending',
      hasServerReady: m['has_server_ready'] == true,
      joinedAt: DateTime.parse(m['joined_at'].toString()),
    );
  }
}

class PartyMessage {
  final String id;
  final String roomId;
  final String userId;
  final String username;
  final String message;
  final DateTime createdAt;

  PartyMessage({
    required this.id,
    required this.roomId,
    required this.userId,
    required this.username,
    required this.message,
    required this.createdAt,
  });

  factory PartyMessage.fromMap(Map<String, dynamic> m) {
    return PartyMessage(
      id: m['id'].toString(),
      roomId: m['room_id'].toString(),
      userId: m['user_id'] as String,
      username: m['username'] as String,
      message: m['message'] as String,
      createdAt: DateTime.parse(m['created_at'].toString()),
    );
  }
}

/// Servicio de salas party / sincronización.
class PartyService extends ChangeNotifier {
  PartyService._();
  static final PartyService instance = PartyService._();

  SupabaseClient? _client;
  bool _initialized = false;
  String? _userId;
  String? _username;

  String? get userId => _userId;
  String? get username => _username;
  bool get isReady => _initialized && _client != null;

  // Sala actual
  PartyRoom? _currentRoom;
  List<PartyMember> _members = [];
  List<PartyMessage> _messages = [];
  RealtimeChannel? _roomChannel;

  PartyRoom? get currentRoom => _currentRoom;
  List<PartyMember> get members => List.unmodifiable(_members);
  List<PartyMessage> get messages => List.unmodifiable(_messages);
  bool get isHost =>
      _currentRoom != null && _currentRoom!.hostUserId == _userId;

  /// Estado del miembro local en la sala actual: accepted | pending | null
  String? get myMemberStatus {
    if (_userId == null) return null;
    for (final m in _members) {
      if (m.userId == _userId) return m.status;
    }
    return null;
  }

  bool get isAcceptedMember => myMemberStatus == 'accepted' || isHost;
  bool get isPendingMember => myMemberStatus == 'pending';

  /// True si teníamos sala y ya no estamos en la lista (expulsados).
  bool _wasInRoom = false;
  bool kickedFromRoom = false;

  /// Inicializa Supabase (llamar una vez en main o al abrir Salas).
  Future<void> init() async {
    if (_initialized) return;
    try {
      if (PartyConfig.supabaseUrl.contains('YOUR_PROJECT')) {
        debugPrint(
            '[PartyService] Configura PartyConfig.supabaseUrl y supabaseAnonKey');
        return;
      }
      await Supabase.initialize(
        url: PartyConfig.supabaseUrl,
        anonKey: PartyConfig.supabaseAnonKey,
      );
      _client = Supabase.instance.client;
      await _loadOrCreateIdentity();
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[PartyService] init error: $e');
    }
  }

  Future<void> _loadOrCreateIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('party_user_id');
    _username = prefs.getString('party_username');
    if (_userId == null || _userId!.isEmpty) {
      _userId = const Uuid().v4();
      await prefs.setString('party_user_id', _userId!);
    }
  }

  /// Crear o actualizar el nombre de usuario de la sesión.
  Future<void> setUsername(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 24) {
      throw ArgumentError('Nombre inválido (1-24 caracteres)');
    }
    final prefs = await SharedPreferences.getInstance();
    _username = clean;
    await prefs.setString('party_username', clean);
    notifyListeners();
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Crear una sala para el contenido actual.
  Future<PartyRoom> createRoom({
    required String title,
    required String contentId,
    required String repoId,
    required String contentType,
    String? poster,
    String? backdrop,
    int? season,
    int? episode,
    String? language,
    bool isPublic = true,
    int maxMembers = 10,
  }) async {
    await init();
    if (_client == null) throw StateError('Supabase no configurado');
    if (_username == null || _username!.isEmpty) {
      throw StateError('Primero configura un nombre de usuario');
    }

    String code;
    // Reintentar si el código colisiona
    for (var i = 0; i < 5; i++) {
      code = _generateCode();
      try {
        final row = await _client!.from('party_rooms').insert({
          'code': code,
          'title': title,
          'content_id': contentId,
          'repo_id': repoId,
          'content_type': contentType,
          'poster': poster,
          'backdrop': backdrop,
          'season': season,
          'episode': episode,
          'language': language,
          'is_public': isPublic,
          'host_user_id': _userId,
          'host_username': _username,
          'max_members': maxMembers,
          'status': 'waiting',
        }).select().single();

        // Insertar host como miembro aceptado
        await _client!.from('party_members').insert({
          'room_id': row['id'],
          'user_id': _userId,
          'username': _username,
          'is_host': true,
          'status': 'accepted',
          'has_server_ready': false,
        });

        final room = PartyRoom.fromMap(Map<String, dynamic>.from(row));
        await _joinLocal(room);
        return room;
      } catch (e) {
        if (i == 4) rethrow;
      }
    }
    throw StateError('No se pudo generar código de sala');
  }

  /// Unirse a una sala por código.
  Future<PartyRoom> joinRoom(String code) async {
    await init();
    if (_client == null) throw StateError('Supabase no configurado');
    if (_username == null || _username!.isEmpty) {
      throw StateError('Primero configura un nombre de usuario');
    }

    final cleaned = code.trim().toUpperCase();
    final rows = await _client!
        .from('party_rooms')
        .select()
        .eq('code', cleaned)
        .gt('expires_at', DateTime.now().toIso8601String())
        .neq('status', 'ended')
        .limit(1);

    if (rows.isEmpty) {
      throw StateError('Sala no encontrada o expirada');
    }

    final roomMap = Map<String, dynamic>.from(rows.first);
    final room = PartyRoom.fromMap(roomMap);

    // Contar miembros aceptados
    final mems = await _client!
        .from('party_members')
        .select('id')
        .eq('room_id', room.id)
        .eq('status', 'accepted');
    if (mems.length >= room.maxMembers) {
      throw StateError('La sala está llena');
    }

    if (room.isPublic) {
      // Entrada directa
      await _client!.from('party_members').upsert({
        'room_id': room.id,
        'user_id': _userId,
        'username': _username,
        'is_host': false,
        'status': 'accepted',
        'has_server_ready': false,
        'last_seen_at': DateTime.now().toIso8601String(),
      }, onConflict: 'room_id,user_id');
      await _joinLocal(room);
      return room;
    } else {
      // Sala privada → solicitud; el cliente entra al player en modo espera
      await _client!.from('party_join_requests').upsert({
        'room_id': room.id,
        'user_id': _userId,
        'username': _username,
        'status': 'pending',
      }, onConflict: 'room_id,user_id');

      await _client!.from('party_members').upsert({
        'room_id': room.id,
        'user_id': _userId,
        'username': _username,
        'is_host': false,
        'status': 'pending',
        'has_server_ready': false,
      }, onConflict: 'room_id,user_id');

      await _joinLocal(room);
      return room;
    }
  }

  Future<void> _joinLocal(PartyRoom room) async {
    await leaveCurrentRoom(silent: true);
    kickedFromRoom = false;
    _wasInRoom = true;
    _currentRoom = room;
    await _refreshMembers();
    await _refreshMessages();
    _subscribeRoom(room.id);
    notifyListeners();
  }

  void _subscribeRoom(String roomId) {
    _roomChannel?.unsubscribe();
    _roomChannel = _client!
        .channel('party_room_$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'party_rooms',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: roomId,
          ),
          callback: (payload) {
            // DELETE: sala borrada por host o expiración
            if (payload.eventType == PostgresChangeEvent.delete ||
                payload.newRecord.isEmpty) {
              _roomChannel?.unsubscribe();
              _roomChannel = null;
              _currentRoom = null;
              _members = [];
              _messages = [];
              notifyListeners();
              return;
            }
            if (payload.newRecord.isNotEmpty) {
              _currentRoom = PartyRoom.fromMap(
                Map<String, dynamic>.from(payload.newRecord),
                memberCount: _members.where((m) => m.status == 'accepted').length,
              );
              notifyListeners();
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'party_members',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (payload) {
            // Respuesta inmediata en UI: si es DELETE, quitar del listado local ya
            if (payload.eventType == PostgresChangeEvent.delete) {
              final old = payload.oldRecord;
              final uid = old['user_id']?.toString();
              if (uid != null && uid.isNotEmpty) {
                _members = _members.where((m) => m.userId != uid).toList();
                // Si nos borraron a nosotros → kick
                if (uid == _userId) {
                  kickedFromRoom = true;
                  _roomChannel?.unsubscribe();
                  _roomChannel = null;
                  _currentRoom = null;
                  _members = [];
                  _messages = [];
                  _wasInRoom = false;
                  notifyListeners();
                  return;
                }
                notifyListeners();
              }
            }
            // Siempre revalidar con SELECT para mantener consistencia
            unawaited(_refreshMembers());
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'party_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (payload) {
            if (payload.newRecord.isNotEmpty) {
              final msg =
                  PartyMessage.fromMap(Map<String, dynamic>.from(payload.newRecord));
              // Evitar duplicar si ya está por optimistic local
              final exists = _messages.any((m) =>
                  m.id == msg.id ||
                  (m.message == msg.message &&
                      m.userId == msg.userId &&
                      m.id.startsWith('local_')));
              if (exists) {
                _messages = _messages
                    .map((m) => (m.id.startsWith('local_') &&
                            m.message == msg.message &&
                            m.userId == msg.userId)
                        ? msg
                        : m)
                    .toList();
              } else {
                _messages = [..._messages, msg];
              }
              if (_messages.length > 200) {
                _messages = _messages.sublist(_messages.length - 200);
              }
              notifyListeners();
            }
          },
        )
        .subscribe();
  }

  Future<void> _refreshMembers() async {
    if (_currentRoom == null || _client == null) return;
    final rows = await _client!
        .from('party_members')
        .select()
        .eq('room_id', _currentRoom!.id)
        .order('joined_at');
    _members = rows
        .map((e) => PartyMember.fromMap(Map<String, dynamic>.from(e)))
        .toList();

    // Detectar expulsión: estábamos en la sala y ya no hay fila nuestra
    if (_wasInRoom && _userId != null && _currentRoom != null) {
      final mine = _members.where((m) => m.userId == _userId).toList();
      if (mine.isEmpty) {
        kickedFromRoom = true;
        _roomChannel?.unsubscribe();
        _roomChannel = null;
        _currentRoom = null;
        _members = [];
        _messages = [];
        _wasInRoom = false;
        notifyListeners();
        return;
      }
      // Rechazado en privada
      if (mine.isNotEmpty && mine.first.status == 'rejected') {
        kickedFromRoom = true;
        _roomChannel?.unsubscribe();
        _roomChannel = null;
        _currentRoom = null;
        _members = [];
        _messages = [];
        _wasInRoom = false;
        notifyListeners();
        return;
      }
    }
    notifyListeners();
  }


  Future<void> _refreshMessages() async {
    if (_currentRoom == null || _client == null) return;
    final rows = await _client!
        .from('party_messages')
        .select()
        .eq('room_id', _currentRoom!.id)
        .order('created_at', ascending: true)
        .limit(100);
    _messages = rows
        .map((r) => PartyMessage.fromMap(Map<String, dynamic>.from(r)))
        .toList();
    notifyListeners();
  }

  /// Marcar que este usuario ya tiene un servidor listo.
  Future<void> setServerReady(bool ready) async {
    if (_currentRoom == null || _client == null || _userId == null) return;
    await _client!
        .from('party_members')
        .update({
          'has_server_ready': ready,
          'last_seen_at': DateTime.now().toIso8601String(),
        })
        .eq('room_id', _currentRoom!.id)
        .eq('user_id', _userId!);
    await _refreshMembers();
  }

  /// ¿Todos los miembros aceptados tienen servidor listo?
  bool get allMembersHaveServer {
    final accepted =
        _members.where((m) => m.status == 'accepted').toList();
    if (accepted.isEmpty) return false;
    return accepted.every((m) => m.hasServerReady);
  }


  Future<void> refreshRoom() async {
    if (_currentRoom == null || _client == null) return;
    final rows = await _client!
        .from('party_rooms')
        .select()
        .eq('id', _currentRoom!.id)
        .limit(1);
    if (rows.isEmpty) {
      _currentRoom = null;
      notifyListeners();
      return;
    }
    _currentRoom = PartyRoom.fromMap(
      Map<String, dynamic>.from(rows.first),
      memberCount: _members.where((m) => m.status == 'accepted').length,
    );
    notifyListeners();
  }

  /// Actualizar estado de reproducción (solo host) — tiempo real.
  Future<void> updatePlayback(PlaybackState state) async {
    if (!isHost || _currentRoom == null || _client == null) return;
    final payload = state.copyWith(
      updatedAt: DateTime.now(),
      updatedBy: _userId,
    ).toJson();
    await _client!
        .from('party_rooms')
        .update({
          'playback_state': payload,
          'status': state.isPlaying ? 'playing' : 'waiting',
        })
        .eq('id', _currentRoom!.id);
    // Reflejar localmente al instante
    _currentRoom = PartyRoom(
      id: _currentRoom!.id,
      code: _currentRoom!.code,
      title: _currentRoom!.title,
      contentId: _currentRoom!.contentId,
      repoId: _currentRoom!.repoId,
      contentType: _currentRoom!.contentType,
      poster: _currentRoom!.poster,
      backdrop: _currentRoom!.backdrop,
      season: _currentRoom!.season,
      episode: _currentRoom!.episode,
      language: _currentRoom!.language,
      isPublic: _currentRoom!.isPublic,
      hostUserId: _currentRoom!.hostUserId,
      hostUsername: _currentRoom!.hostUsername,
      maxMembers: _currentRoom!.maxMembers,
      status: state.isPlaying ? 'playing' : 'waiting',
      createdAt: _currentRoom!.createdAt,
      expiresAt: _currentRoom!.expiresAt,
      playbackState: PlaybackState.fromJson(payload),
      memberCount: _members.where((m) => m.status == 'accepted').length,
    );
    notifyListeners();
  }

  /// Host: cambiar privacidad y/o máximo de miembros.
  Future<void> updateRoomSettings({
    bool? isPublic,
    int? maxMembers,
    String? title,
    String? poster,
    String? backdrop,
  }) async {
    if (!isHost || _currentRoom == null || _client == null) return;
    final patch = <String, dynamic>{};
    if (isPublic != null) patch['is_public'] = isPublic;
    if (maxMembers != null) {
      final n = maxMembers.clamp(2, 50);
      patch['max_members'] = n;
    }
    if (title != null && title.trim().isNotEmpty) {
      patch['title'] = title.trim();
    }
    if (poster != null) patch['poster'] = poster;
    if (backdrop != null) patch['backdrop'] = backdrop;
    if (patch.isEmpty) return;
    await _client!
        .from('party_rooms')
        .update(patch)
        .eq('id', _currentRoom!.id);
    final m = _currentRoom!;
    _currentRoom = PartyRoom(
      id: m.id,
      code: m.code,
      title: (title != null && title.trim().isNotEmpty) ? title.trim() : m.title,
      contentId: m.contentId,
      repoId: m.repoId,
      contentType: m.contentType,
      poster: poster ?? m.poster,
      backdrop: backdrop ?? m.backdrop,
      season: m.season,
      episode: m.episode,
      language: m.language,
      isPublic: isPublic ?? m.isPublic,
      hostUserId: m.hostUserId,
      hostUsername: m.hostUsername,
      maxMembers: maxMembers?.clamp(2, 50) ?? m.maxMembers,
      status: m.status,
      createdAt: m.createdAt,
      expiresAt: m.expiresAt,
      playbackState: m.playbackState,
      memberCount: m.memberCount,
    );
    notifyListeners();
  }

  /// Cambiar capítulo/contenido de la sala (misma sala, otro episodio).
  Future<void> updateRoomContent({
    required String contentId,
    required String contentType,
    required String title,
    String? poster,
    String? backdrop,
    int? season,
    int? episode,
    String? language,
  }) async {
    if (!isHost || _currentRoom == null || _client == null) return;
    final patch = <String, dynamic>{
      'content_id': contentId,
      'content_type': contentType,
      'title': title,
      'season': season,
      'episode': episode,
      'playback_state': PlaybackState().toJson(),
      'status': 'waiting',
    };
    if (poster != null) patch['poster'] = poster;
    if (backdrop != null) patch['backdrop'] = backdrop;
    if (language != null) patch['language'] = language;
    await _client!
        .from('party_rooms')
        .update(patch)
        .eq('id', _currentRoom!.id);
    final m = _currentRoom!;
    _currentRoom = PartyRoom(
      id: m.id,
      code: m.code,
      title: title,
      contentId: contentId,
      repoId: m.repoId,
      contentType: contentType,
      poster: poster ?? m.poster,
      backdrop: backdrop ?? m.backdrop,
      season: season,
      episode: episode,
      language: language ?? m.language,
      isPublic: m.isPublic,
      hostUserId: m.hostUserId,
      hostUsername: m.hostUsername,
      maxMembers: m.maxMembers,
      status: 'waiting',
      createdAt: m.createdAt,
      expiresAt: m.expiresAt,
      playbackState: const PlaybackState(),
      memberCount: m.memberCount,
    );
    notifyListeners();
  }

  /// Enviar mensaje de chat (optimistic + realtime).
  Future<void> sendMessage(String text) async {
    final msg = text.trim();
    if (msg.isEmpty || _currentRoom == null || _client == null) return;
    // Optimistic UI
    final temp = PartyMessage(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      roomId: _currentRoom!.id,
      userId: _userId ?? '',
      username: _username ?? 'Yo',
      message: msg,
      createdAt: DateTime.now(),
    );
    _messages = [..._messages, temp];
    notifyListeners();
    try {
      await _client!.from('party_messages').insert({
        'room_id': _currentRoom!.id,
        'user_id': _userId,
        'username': _username,
        'message': msg,
      });
    } catch (e) {
      debugPrint('[PartyService] sendMessage: $e');
    }
  }

  /// Aceptar / rechazar solicitud (solo host, salas privadas).
  Future<void> respondJoinRequest(String userId, bool accept) async {
    if (!isHost || _currentRoom == null || _client == null) return;
    final status = accept ? 'accepted' : 'rejected';
    await _client!
        .from('party_members')
        .update({'status': status})
        .eq('room_id', _currentRoom!.id)
        .eq('user_id', userId);
    try {
      await _client!
          .from('party_join_requests')
          .update({'status': status})
          .eq('room_id', _currentRoom!.id)
          .eq('user_id', userId);
    } catch (_) {}
    await _refreshMembers();
  }

  /// Listar salas públicas en vivo (con conteo de miembros).
  Future<List<PartyRoom>> listPublicRooms({String? query}) async {
    await init();
    if (_client == null) return [];
    // Borrar expiradas al listar (sin historial)
    try {
      await _client!
          .from('party_rooms')
          .delete()
          .lt('expires_at', DateTime.now().toIso8601String());
    } catch (_) {}

    var q = _client!
        .from('party_rooms')
        .select()
        .eq('is_public', true)
        .neq('status', 'ended')
        .gt('expires_at', DateTime.now().toIso8601String())
        .order('created_at', ascending: false)
        .limit(80);

    final rows = await q;
    final rooms = <PartyRoom>[];
    for (final r in rows) {
      final map = Map<String, dynamic>.from(r);
      final mems = await _client!
          .from('party_members')
          .select('id')
          .eq('room_id', map['id'])
          .eq('status', 'accepted');
      rooms.add(PartyRoom.fromMap(map, memberCount: mems.length));
    }

    if (query != null && query.trim().isNotEmpty) {
      final qq = query.trim().toLowerCase();
      return rooms
          .where((r) =>
              r.title.toLowerCase().contains(qq) ||
              r.hostUsername.toLowerCase().contains(qq) ||
              r.code.toLowerCase().contains(qq) ||
              (r.contentType.toLowerCase().contains(qq)))
          .toList();
    }
    return rooms;
  }

  /// Salas donde yo soy el host (para reentrar si salí).
  Future<List<PartyRoom>> listMyRooms() async {
    await init();
    if (_client == null || _userId == null) return [];
    try {
      await _client!
          .from('party_rooms')
          .delete()
          .lt('expires_at', DateTime.now().toIso8601String());
    } catch (_) {}

    final rows = await _client!
        .from('party_rooms')
        .select()
        .eq('host_user_id', _userId!)
        .neq('status', 'ended')
        .gt('expires_at', DateTime.now().toIso8601String())
        .order('created_at', ascending: false)
        .limit(40);

    final rooms = <PartyRoom>[];
    for (final r in rows) {
      final map = Map<String, dynamic>.from(r);
      final mems = await _client!
          .from('party_members')
          .select('id')
          .eq('room_id', map['id'])
          .eq('status', 'accepted');
      rooms.add(PartyRoom.fromMap(map, memberCount: mems.length));
    }
    return rooms;
  }

  /// Terminar sala (host): borra TODO de la BD al instante (CASCADE).
  /// Si no queda nadie aceptado, borra la sala (o tras 5 min vacía en servidor).
  Future<void> deleteRoomIfEmpty() async {
    if (_client == null || _currentRoom == null) return;
    final roomId = _currentRoom!.id;
    final rows = await _client!
        .from('party_members')
        .select('id')
        .eq('room_id', roomId)
        .eq('status', 'accepted');
    if (rows.isEmpty) {
      try {
        await _client!.from('party_rooms').delete().eq('id', roomId);
      } catch (e) {
        debugPrint('[PartyService] deleteRoomIfEmpty: $e');
      }
    }
  }

  Future<void> endAndDeleteRoom() async {
    if (!isHost || _currentRoom == null || _client == null) return;
    final id = _currentRoom!.id;
    try {
      // DELETE borra room + members + messages + join_requests (ON DELETE CASCADE)
      await _client!.from('party_rooms').delete().eq('id', id);
    } catch (e) {
      debugPrint('[PartyService] endAndDeleteRoom: $e');
    }
    _roomChannel?.unsubscribe();
    _roomChannel = null;
    _currentRoom = null;
    _members = [];
    _messages = [];
    notifyListeners();
  }

  /// Eliminar una sala mía (host) aunque no esté unido ahora.
  Future<void> deleteMyRoom(String roomId) async {
    await init();
    if (_client == null || _userId == null) return;
    try {
      await _client!
          .from('party_rooms')
          .delete()
          .eq('id', roomId)
          .eq('host_user_id', _userId!);
    } catch (e) {
      debugPrint('[PartyService] deleteMyRoom: $e');
      rethrow;
    }
    if (_currentRoom?.id == roomId) {
      _roomChannel?.unsubscribe();
      _roomChannel = null;
      _currentRoom = null;
      _members = [];
      _messages = [];
      notifyListeners();
    }
  }

  /// Salir de la sala actual.
  /// - Host: borra la sala completa (sin historial).
  /// - Miembro: solo se marca left / se elimina su fila.

  /// Expulsar miembro (solo host).
  Future<void> kickMember(String userId) async {
    if (!isHost || _currentRoom == null || _client == null) return;
    if (userId == _userId) return;
    // Actualización optimista local: desaparece al instante en la UI del host
    _members = _members.where((m) => m.userId != userId).toList();
    notifyListeners();
    await _client!
        .from('party_members')
        .delete()
        .eq('room_id', _currentRoom!.id)
        .eq('user_id', userId);
    await _client!
        .from('party_join_requests')
        .delete()
        .eq('room_id', _currentRoom!.id)
        .eq('user_id', userId);
    await _refreshMembers();
    notifyListeners();
  }

  /// Ceder el host a otro miembro aceptado.
  Future<void> transferHost(String newHostUserId) async {
    if (!isHost || _currentRoom == null || _client == null) return;
    if (newHostUserId == _userId) return;
    final ok = _members.any(
        (m) => m.userId == newHostUserId && m.status == 'accepted');
    if (!ok) throw StateError('El usuario no está en la sala');

    await _client!
        .from('party_rooms')
        .update({
          'host_user_id': newHostUserId,
          'host_username': _members
              .firstWhere((m) => m.userId == newHostUserId)
              .username,
        })
        .eq('id', _currentRoom!.id);

    // Actualizar flags is_host
    await _client!
        .from('party_members')
        .update({'is_host': false})
        .eq('room_id', _currentRoom!.id);
    await _client!
        .from('party_members')
        .update({'is_host': true})
        .eq('room_id', _currentRoom!.id)
        .eq('user_id', newHostUserId);

    await refreshRoom();
    await _refreshMembers();
    notifyListeners();
  }

  /// Salir sin ser host (o tras ceder host).
  Future<void> leaveAsMember() async {
    if (_currentRoom == null || _client == null || _userId == null) return;
    if (isHost) {
      throw StateError('Eres host: cede el host o cierra la sala');
    }
    final roomId = _currentRoom!.id;
    await _client!
        .from('party_members')
        .delete()
        .eq('room_id', roomId)
        .eq('user_id', _userId!);
    // Si no queda nadie, borrar sala
    final left = await _client!
        .from('party_members')
        .select('id')
        .eq('room_id', roomId)
        .eq('status', 'accepted');
    if (left.isEmpty) {
      try {
        await _client!.from('party_rooms').delete().eq('id', roomId);
      } catch (_) {}
    }
    _roomChannel?.unsubscribe();
    _roomChannel = null;
    _currentRoom = null;
    _members = [];
    _messages = [];
    _wasInRoom = false;
    notifyListeners();
  }

  /// Reacción emoji (usa chat con prefijo especial, sin cambiar esquema).
  Future<void> sendReaction(String emoji) async {
    await sendMessage('__reaction__:$emoji');
  }

  Future<void> leaveCurrentRoom({bool silent = false}) async {
    if (_currentRoom != null && _client != null && _userId != null) {
      try {
        if (isHost) {
          await _client!
              .from('party_rooms')
              .delete()
              .eq('id', _currentRoom!.id);
        } else {
          await _client!
              .from('party_members')
              .delete()
              .eq('room_id', _currentRoom!.id)
              .eq('user_id', _userId!);
        }
      } catch (_) {}
    }
    _roomChannel?.unsubscribe();
    _roomChannel = null;
    _currentRoom = null;
    _members = [];
    _messages = [];
    if (!silent) notifyListeners();
  }

  /// Limpiar salas expiradas (DELETE real, sin historial).
  Future<void> cleanupExpired() async {
    if (_client == null) return;
    try {
      await _client!.rpc('cleanup_expired_party_rooms');
    } catch (_) {
      await _client!
          .from('party_rooms')
          .delete()
          .lt('expires_at', DateTime.now().toIso8601String());
    }
  }

  /// ¿La sala actual ya expiró (4h)?
  bool get isRoomExpired {
    final r = _currentRoom;
    if (r == null) return false;
    return DateTime.now().isAfter(r.expiresAt);
  }

  Duration? get roomTimeLeft {
    final r = _currentRoom;
    if (r == null) return null;
    final d = r.expiresAt.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  @override
  void dispose() {
    _roomChannel?.unsubscribe();
    super.dispose();
  }
}